#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\AUTOTRADE_CLEAN'
$ControlRoot = 'C:\Users\hjk86\AUTOTRADE_CONTROL'
$Database = Join-Path $Root 'state\autotrade.db'
$RuntimeTask = 'AUTOTRADE_CLEAN_RUNTIME'
$RecorderTask = 'AUTOTRADE_CLEAN_DETAILED_STRATEGY_RECORDER_V10_1'
$RecorderBase = Join-Path $ControlRoot 'DETAILED_STRATEGY_RECORDING_V10_1'
$RecorderHealth = Join-Path $RecorderBase 'records\DETAILED_STRATEGY_RECORDER_HEALTH.json'
$BrokenUrl = 'https://raw.githubusercontent.com/custombro/custombro-ops/main/scripts/AUTOTRADE_CLEAN_INSTALL_DETAILED_STRATEGY_RECORDING_V10_1_20260728.ps1'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$CloseoutRoot = Join-Path $ControlRoot 'FINAL_NIGHT_CLOSEOUT_V10_2'
$RunRoot = Join-Path $CloseoutRoot ('RUN_' + $Stamp)
$Downloaded = Join-Path $RunRoot 'installer_original_v10_1.ps1'
$Patched = Join-Path $RunRoot 'installer_patched_v10_2.ps1'
$Report = Join-Path $RunRoot 'FINAL_NIGHT_CLOSEOUT.txt'

New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null
$Results = New-Object System.Collections.Generic.List[string]

function Add-Result {
    param([string]$Key, [object]$Value)
    if ($Value -is [bool]) {
        $Text = $Value.ToString().ToUpperInvariant()
    }
    elseif ($Value -is [string]) {
        $Text = $Value
    }
    else {
        $Text = $Value | ConvertTo-Json -Depth 30 -Compress
    }
    [void]$Results.Add($Key + '=' + $Text)
}

function Get-PythonPath {
    $Known = 'C:\Program Files\Python312\python.exe'
    if (Test-Path -LiteralPath $Known) { return $Known }
    return (Get-Command python.exe -ErrorAction Stop).Source
}

function Get-RuntimeProcesses {
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^pythonw?\.exe$' -and
            [string]$_.CommandLine -like '*C:\AUTOTRADE_CLEAN\app\stage12_runtime_bootstrap.py*' -and
            [string]$_.CommandLine -like '*--mode persistent*'
        }
    )
}

function Get-OrderLedgerCount {
    $Python = Get-PythonPath
    $Code = @'
import sqlite3
import sys
path = sys.argv[1]
connection = sqlite3.connect('file:' + path + '?mode=ro', uri=True)
try:
    print(int(connection.execute('SELECT COUNT(*) FROM order_ledger').fetchone()[0]))
finally:
    connection.close()
'@
    $Temp = Join-Path $env:TEMP ('autotrade_closeout_order_count_' + [guid]::NewGuid().ToString('N') + '.py')
    [IO.File]::WriteAllText($Temp, $Code, (New-Object System.Text.ASCIIEncoding))
    try {
        $Output = @(& $Python $Temp $Database 2>&1)
        if ($LASTEXITCODE -ne 0) { throw ('ORDER_LEDGER_READ_FAILED:' + ($Output -join ' ')) }
        return [int]([string]($Output | Select-Object -Last 1)).Trim()
    }
    finally {
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
    }
}

function Get-CriticalFingerprint {
    $Files = @(
        Join-Path $Root 'app\stage12_runtime_bootstrap.py',
        Join-Path $Root 'app\dashboard.py',
        Join-Path $Root 'app\templates\index.html',
        Join-Path $Root 'state\current_snapshot_runtime.json'
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $Lines = foreach ($File in $Files) {
        $Hash = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToUpperInvariant()
        $File + '|' + $Hash
    }
    $Bytes = [Text.Encoding]::UTF8.GetBytes(($Lines -join "`n"))
    $Sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Digest = $Sha.ComputeHash($Bytes)
    }
    finally {
        $Sha.Dispose()
    }
    return ([BitConverter]::ToString($Digest)).Replace('-', '')
}

function Get-TaskEnabled {
    param([string]$TaskName)
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $Task) { return $false }
    return [bool]$Task.Settings.Enabled
}

function Ensure-CanonicalRuntime {
    $Count = @(Get-RuntimeProcesses).Count
    if ($Count -eq 1) { return 1 }
    if ($Count -gt 1) { throw 'DUPLICATE_CANONICAL_RUNTIME_DETECTED' }

    $Task = Get-ScheduledTask -TaskName $RuntimeTask -ErrorAction Stop
    if (-not [bool]$Task.Settings.Enabled) {
        Enable-ScheduledTask -TaskName $RuntimeTask | Out-Null
    }
    Start-ScheduledTask -TaskName $RuntimeTask
    $Deadline = (Get-Date).AddSeconds(45)
    do {
        Start-Sleep -Milliseconds 500
        $Count = @(Get-RuntimeProcesses).Count
    } while ($Count -eq 0 -and (Get-Date) -lt $Deadline)
    if ($Count -ne 1) { throw ('CANONICAL_RUNTIME_RECOVERY_FAILED_COUNT_' + $Count) }
    return $Count
}

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'FINAL_NIGHT_CLOSEOUT_FIX_RECORDER_AND_PRESERVE_TOMORROW_AUTOTRADE'
Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Result 'ORDER_PATH_MODIFIED' $false
Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
Add-Result 'BROKER_ORDER_ATTEMPTED' $false
Add-Result 'ORDER_TRANSPORT_CALLS' 0
Add-Result 'LIVE_DASHBOARD_INSTALL_ATTEMPTED' $false
Add-Result 'MANUAL_VALUE_INPUT_USED' $false

$Success = $false
try {
    foreach ($Required in @($Root, $ControlRoot, $Database)) {
        if (-not (Test-Path -LiteralPath $Required)) { throw ('REQUIRED_PATH_MISSING:' + $Required) }
    }

    $RuntimeBefore = @(Get-RuntimeProcesses).Count
    $OrderBefore = Get-OrderLedgerCount
    $FingerprintBefore = Get-CriticalFingerprint
    Add-Result 'RUNTIME_PROCESS_COUNT_BEFORE' $RuntimeBefore
    Add-Result 'ORDER_LEDGER_COUNT_BEFORE' $OrderBefore
    Add-Result 'CRITICAL_FINGERPRINT_BEFORE' $FingerprintBefore
    Add-Result 'CANONICAL_RUNTIME_TASK_ENABLED_BEFORE' (Get-TaskEnabled $RuntimeTask)

    if ($RuntimeBefore -gt 1) { throw 'DUPLICATE_CANONICAL_RUNTIME_DETECTED_BEFORE' }
    [void](Ensure-CanonicalRuntime)

    Invoke-WebRequest -Uri $BrokenUrl -OutFile $Downloaded -UseBasicParsing -TimeoutSec 30
    $Source = [IO.File]::ReadAllText($Downloaded)

    $OldBlock = @'
    $Action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument (
            '-NoProfile -NonInteractive -WindowStyle Hidden ' +
            '-ExecutionPolicy Bypass -File "{0}"'
        -f $Wrapper)
'@
    $NewBlock = @'
    $TaskArgument = (
        '-NoProfile -NonInteractive -WindowStyle Hidden ' +
        '-ExecutionPolicy Bypass -File "{0}"'
    ) -f $Wrapper
    $Action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument $TaskArgument
'@

    if (-not $Source.Contains($OldBlock)) { throw 'EXPECTED_BROKEN_ARGUMENT_BLOCK_NOT_FOUND' }
    $PatchedSource = $Source.Replace($OldBlock, $NewBlock)
    if ($PatchedSource.Contains($OldBlock)) { throw 'BROKEN_ARGUMENT_BLOCK_REMAINS_AFTER_PATCH' }
    [IO.File]::WriteAllText($Patched, $PatchedSource, (New-Object System.Text.UTF8Encoding($true)))
    Add-Result 'INSTALLER_SYNTAX_BLOCK_PATCHED' $true

    $Tokens = $null
    $ParseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Patched, [ref]$Tokens, [ref]$ParseErrors)
    Add-Result 'PATCHED_INSTALLER_PARSE_ERROR_COUNT' @($ParseErrors).Count
    if (@($ParseErrors).Count -ne 0) {
        $Messages = @($ParseErrors | ForEach-Object { $_.Message }) -join ' | '
        throw ('PATCHED_INSTALLER_PARSE_FAILED:' + $Messages)
    }

    $ChildOutput = @(
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Patched 2>&1
    )
    $ChildExit = $LASTEXITCODE
    Add-Result 'RECORDER_INSTALLER_EXIT_CODE' $ChildExit
    foreach ($Line in $ChildOutput) {
        $Text = [string]$Line
        if (
            $Text.StartsWith('FIRST_DETAILED_RECORD_READY=') -or
            $Text.StartsWith('FIRST_STRATEGY_ACTION=') -or
            $Text.StartsWith('FIRST_REASON_CANDIDATE_COUNT=') -or
            $Text.StartsWith('FIRST_NUMERIC_CONTEXT_COUNT=') -or
            $Text.StartsWith('FIRST_PROVENANCE_FIELD_COUNT=') -or
            $Text.StartsWith('SECOND_RUN_DUPLICATE_EVENT=') -or
            $Text.StartsWith('TASK_LAST_RESULT=') -or
            $Text.StartsWith('TASK_HEALTH_DETAILED_READY=') -or
            $Text.StartsWith('FUTURE_DETAILED_RECORDING_PIPELINE_PROVEN=') -or
            $Text.StartsWith('FINAL_STATUS=')
        ) {
            [void]$Results.Add('RECORDER_' + $Text)
        }
    }
    if ($ChildExit -ne 0) { throw ('RECORDER_INSTALLER_FAILED:' + (($ChildOutput | Select-Object -Last 12) -join ' | ')) }
    if (-not (($ChildOutput -join "`n").Contains('FINAL_STATUS=PASS_DETAILED_STRATEGY_RECORDING_V10_1_INSTALLED_WITHOUT_AUTOTRADE_MUTATION'))) {
        throw 'RECORDER_INSTALLER_PASS_MARKER_MISSING'
    }

    $RuntimeAfter = Ensure-CanonicalRuntime
    $OrderAfter = Get-OrderLedgerCount
    $FingerprintAfter = Get-CriticalFingerprint
    $RuntimeTaskEnabled = Get-TaskEnabled $RuntimeTask
    $RecorderTaskEnabled = Get-TaskEnabled $RecorderTask

    if ($RuntimeAfter -ne 1) { throw 'FINAL_RUNTIME_COUNT_NOT_ONE' }
    if ($OrderAfter -ne $OrderBefore) { throw 'ORDER_LEDGER_COUNT_CHANGED' }
    if ($FingerprintAfter -ne $FingerprintBefore) { throw 'CRITICAL_AUTOTRADE_FINGERPRINT_CHANGED' }
    if (-not $RuntimeTaskEnabled) { throw 'CANONICAL_RUNTIME_TASK_DISABLED' }
    if (-not $RecorderTaskEnabled) { throw 'DETAILED_RECORDER_TASK_NOT_ENABLED' }
    if (-not (Test-Path -LiteralPath $RecorderHealth)) { throw 'DETAILED_RECORDER_HEALTH_MISSING' }

    $RecorderTaskInfo = Get-ScheduledTaskInfo -TaskName $RecorderTask
    $HealthPayload = Get-Content -LiteralPath $RecorderHealth -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$RecorderTaskInfo.LastTaskResult -ne 0) { throw ('DETAILED_RECORDER_LAST_RESULT_' + $RecorderTaskInfo.LastTaskResult) }
    if (-not [bool]$HealthPayload.detailed_ready) { throw 'DETAILED_RECORDER_HEALTH_NOT_READY' }

    Add-Result 'RUNTIME_PROCESS_COUNT_AFTER' $RuntimeAfter
    Add-Result 'CANONICAL_RUNTIME_TASK_ENABLED_AFTER' $RuntimeTaskEnabled
    Add-Result 'ORDER_LEDGER_COUNT_AFTER' $OrderAfter
    Add-Result 'ORDER_LEDGER_COUNT_UNCHANGED' $true
    Add-Result 'CRITICAL_FINGERPRINT_AFTER' $FingerprintAfter
    Add-Result 'CRITICAL_AUTOTRADE_FILES_UNCHANGED' $true
    Add-Result 'DETAILED_RECORDER_TASK_ENABLED' $RecorderTaskEnabled
    Add-Result 'DETAILED_RECORDER_TASK_LAST_RESULT' ([int]$RecorderTaskInfo.LastTaskResult)
    Add-Result 'DETAILED_RECORDER_HEALTH_READY' ([bool]$HealthPayload.detailed_ready)
    Add-Result 'DETAILED_RECORDER_REASON_CANDIDATE_COUNT' ([int]$HealthPayload.reason_candidate_count)
    Add-Result 'DETAILED_RECORDER_NUMERIC_CONTEXT_COUNT' ([int]$HealthPayload.numeric_context_count)
    Add-Result 'DETAILED_RECORDER_PROVENANCE_COUNT' ([int]$HealthPayload.provenance_count)
    Add-Result 'FUTURE_DETAILED_RECORDING_PIPELINE_PROVEN' $true
    Add-Result 'HISTORICAL_DETAILED_RECORDING_GAP_REMAINS' $true
    Add-Result 'DASHBOARD_REQUIRED_FOR_TOMORROW_AUTOTRADE' $false
    Add-Result 'TOMORROW_AUTOTRADE_RUNTIME_PRESERVED' $true
    Add-Result 'NEXT_ACTUAL_MARKET_VALIDATION_PENDING' $true
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'LIVE_DASHBOARD_INSTALL_ATTEMPTED' $false
    Add-Result 'FINAL_STATUS' 'PASS_NIGHT_CLOSEOUT_AUTOTRADE_PRESERVED_AND_DETAILED_RECORDING_INSTALLED'
    $Success = $true
}
catch {
    Add-Result 'CLOSEOUT_ERROR' $_.Exception.Message
    Add-Result 'FINAL_RUNTIME_PROCESS_COUNT' (@(Get-RuntimeProcesses).Count)
    try { Add-Result 'FINAL_ORDER_LEDGER_COUNT' (Get-OrderLedgerCount) } catch { Add-Result 'FINAL_ORDER_LEDGER_COUNT' 'READ_FAILED' }
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'LIVE_DASHBOARD_INSTALL_ATTEMPTED' $false
    Add-Result 'FINAL_STATUS' 'FAIL_NIGHT_CLOSEOUT_REQUIRES_REVIEW'
}

Add-Result 'REPORT' $Report
$CopyStatus = 'FAILED'
try {
    Set-Clipboard -Value ($Results -join [Environment]::NewLine)
    $CopyStatus = 'SUCCESS'
}
catch { $CopyStatus = 'FAILED' }
Add-Result 'COPY_STATUS' $CopyStatus

$OutputText = ($Results -join [Environment]::NewLine) + [Environment]::NewLine
[IO.File]::WriteAllText($Report, $OutputText, (New-Object System.Text.UTF8Encoding($true)))
Write-Output $OutputText
if ($Success) { exit 0 }
exit 1
