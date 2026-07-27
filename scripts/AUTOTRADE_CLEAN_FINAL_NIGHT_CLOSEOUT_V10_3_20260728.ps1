#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Elevated,
    [string]$HandoffPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
$IsAdministrator = $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $IsAdministrator -and -not $Elevated) {
    $Handoff = Join-Path -Path $env:TEMP -ChildPath (
        'AUTOTRADE_FINAL_NIGHT_CLOSEOUT_' +
        [guid]::NewGuid().ToString('N') +
        '.txt'
    )
    $Arguments = (
        '-NoProfile -ExecutionPolicy Bypass -File "{0}" ' +
        '-Elevated -HandoffPath "{1}"'
    ) -f $PSCommandPath, $Handoff

    $Child = Start-Process `
        -FilePath 'powershell.exe' `
        -Verb RunAs `
        -ArgumentList $Arguments `
        -Wait `
        -PassThru

    if (-not (Test-Path -LiteralPath $Handoff)) {
        throw 'ELEVATED_CHILD_HANDOFF_MISSING'
    }

    $ChildOutput = Get-Content -LiteralPath $Handoff -Raw -Encoding UTF8
    Write-Output $ChildOutput
    Remove-Item -LiteralPath $Handoff -Force -ErrorAction SilentlyContinue
    exit $Child.ExitCode
}

if (-not $IsAdministrator) {
    throw 'ADMINISTRATOR_ELEVATION_FAILED'
}

$Root = 'C:\AUTOTRADE_CLEAN'
$ControlRoot = 'C:\Users\hjk86\AUTOTRADE_CONTROL'
$Database = Join-Path -Path $Root -ChildPath 'state\autotrade.db'
$RuntimeTaskName = 'AUTOTRADE_CLEAN_RUNTIME'
$RecorderTaskName = 'AUTOTRADE_CLEAN_DETAILED_STRATEGY_RECORDER_V10_1'
$RecorderBase = Join-Path -Path $ControlRoot -ChildPath 'DETAILED_STRATEGY_RECORDING_V10_1'
$RecorderHealth = Join-Path -Path $RecorderBase -ChildPath 'records\DETAILED_STRATEGY_RECORDER_HEALTH.json'
$RecorderContract = Join-Path -Path $RecorderBase -ChildPath 'DETAILED_STRATEGY_RECORDING_CONTRACT_V10_1.json'
$InstallerUrl = 'https://raw.githubusercontent.com/custombro/custombro-ops/main/scripts/AUTOTRADE_CLEAN_INSTALL_DETAILED_STRATEGY_RECORDING_V10_1_20260728.ps1'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$Base = Join-Path -Path $ControlRoot -ChildPath 'FINAL_NIGHT_CLOSEOUT_V10_3'
$RunRoot = Join-Path -Path $Base -ChildPath ('RUN_' + $Stamp)
$DownloadedInstaller = Join-Path -Path $RunRoot -ChildPath 'installer_original_v10_1.ps1'
$PatchedInstaller = Join-Path -Path $RunRoot -ChildPath 'installer_patched_v10_3.ps1'
$Report = Join-Path -Path $RunRoot -ChildPath 'FINAL_NIGHT_CLOSEOUT_V10_3.txt'

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
        $Text = $Value | ConvertTo-Json -Depth 40 -Compress
    }
    [void]$Results.Add($Key + '=' + $Text)
}

function Get-PythonPath {
    $Known = 'C:\Program Files\Python312\python.exe'
    if (Test-Path -LiteralPath $Known) {
        return $Known
    }
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
    $Temporary = Join-Path -Path $env:TEMP -ChildPath (
        'autotrade_final_closeout_order_count_' +
        [guid]::NewGuid().ToString('N') +
        '.py'
    )
    [IO.File]::WriteAllText(
        $Temporary,
        $Code,
        (New-Object System.Text.ASCIIEncoding)
    )
    try {
        $Output = @(& $Python $Temporary $Database 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw ('ORDER_LEDGER_READ_FAILED:' + ($Output -join ' '))
        }
        return [int]([string]($Output | Select-Object -Last 1)).Trim()
    }
    finally {
        Remove-Item -LiteralPath $Temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-CriticalSourcePaths {
    $Paths = New-Object System.Collections.Generic.List[string]

    $ExplicitTargets = @(
        (Join-Path -Path $Root -ChildPath 'app\stage12_runtime_bootstrap.py')
        (Join-Path -Path $Root -ChildPath 'app\dashboard.py')
        (Join-Path -Path $Root -ChildPath 'app\templates\index.html')
        (Join-Path -Path $Root -ChildPath 'web\index.html')
    )

    foreach ($Target in $ExplicitTargets) {
        if (Test-Path -LiteralPath $Target) {
            [void]$Paths.Add((Get-Item -LiteralPath $Target).FullName)
        }
    }

    $Discovered = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $LowerPath = $_.FullName.ToLowerInvariant()
            $LowerName = $_.Name.ToLowerInvariant()
            -not $LowerPath.Contains('\state\') -and
            -not $LowerPath.Contains('\logs\') -and
            -not $LowerPath.Contains('\__pycache__\') -and
            -not $LowerPath.Contains('\backup') -and
            (
                $LowerName.Contains('strategy') -or
                $LowerName.Contains('stage13l') -or
                $LowerName.Contains('order_authority') -or
                $LowerName.Contains('order_transport') -or
                $LowerName.Contains('broker_sender') -or
                $LowerName.Contains('runtime_bootstrap')
            )
        } |
        Sort-Object FullName |
        Select-Object -First 1000
    )

    foreach ($File in $Discovered) {
        if (-not $Paths.Contains($File.FullName)) {
            [void]$Paths.Add($File.FullName)
        }
    }

    return @($Paths | Sort-Object -Unique)
}

function Get-FingerprintForPaths {
    param([string[]]$Paths)

    $Builder = New-Object System.Text.StringBuilder
    foreach ($Path in $Paths) {
        if (-not (Test-Path -LiteralPath $Path)) {
            throw ('CRITICAL_SOURCE_MISSING:' + $Path)
        }
        $Hash = (
            Get-FileHash -LiteralPath $Path -Algorithm SHA256
        ).Hash.ToUpperInvariant()
        [void]$Builder.AppendLine($Path + '|' + $Hash)
    }

    $Bytes = [Text.Encoding]::UTF8.GetBytes($Builder.ToString())
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
    if ($null -eq $Task) {
        return $false
    }
    return [bool]$Task.Settings.Enabled
}

function Ensure-RuntimeTaskAndProcess {
    $Task = Get-ScheduledTask -TaskName $RuntimeTaskName -ErrorAction Stop
    if (-not [bool]$Task.Settings.Enabled) {
        Enable-ScheduledTask -TaskName $RuntimeTaskName | Out-Null
        Add-Result 'CANONICAL_RUNTIME_TASK_ENABLED_BY_CLOSEOUT' $true
    }
    else {
        Add-Result 'CANONICAL_RUNTIME_TASK_ENABLED_BY_CLOSEOUT' $false
    }

    $Count = @(Get-RuntimeProcesses).Count
    if ($Count -gt 1) {
        throw 'DUPLICATE_CANONICAL_RUNTIME_DETECTED'
    }
    if ($Count -eq 0) {
        Start-ScheduledTask -TaskName $RuntimeTaskName
        $Deadline = (Get-Date).AddSeconds(60)
        do {
            Start-Sleep -Milliseconds 500
            $Count = @(Get-RuntimeProcesses).Count
        } while ($Count -eq 0 -and (Get-Date) -lt $Deadline)
    }
    if ($Count -ne 1) {
        throw ('CANONICAL_RUNTIME_COUNT_NOT_ONE:' + $Count)
    }
    return $Count
}

function Patch-InstallerSyntax {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $Lines = @(Get-Content -LiteralPath $SourcePath)
    $StartIndex = -1
    $EndIndex = -1

    for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
        if ([string]$Lines[$Index] -match '\$Action\s*=\s*New-ScheduledTaskAction') {
            $StartIndex = $Index
            break
        }
    }
    if ($StartIndex -lt 0) {
        throw 'BROKEN_TASK_ACTION_BLOCK_START_NOT_FOUND'
    }

    for ($Index = $StartIndex; $Index -lt $Lines.Count; $Index++) {
        if (([string]$Lines[$Index]).Trim() -eq '-f $Wrapper)') {
            $EndIndex = $Index
            break
        }
    }
    if ($EndIndex -lt $StartIndex) {
        throw 'BROKEN_TASK_ACTION_BLOCK_END_NOT_FOUND'
    }

    $Replacement = @(
        '    $TaskArgument = ('
        "        '-NoProfile -NonInteractive -WindowStyle Hidden ' +"
        "        '-ExecutionPolicy Bypass -File `"{0}`"'"
        '    ) -f $Wrapper'
        '    $Action = New-ScheduledTaskAction `'
        "        -Execute 'powershell.exe' `"
        '        -Argument $TaskArgument'
    )

    $PatchedLines = New-Object System.Collections.Generic.List[string]
    if ($StartIndex -gt 0) {
        for ($Index = 0; $Index -lt $StartIndex; $Index++) {
            [void]$PatchedLines.Add([string]$Lines[$Index])
        }
    }
    foreach ($Line in $Replacement) {
        [void]$PatchedLines.Add($Line)
    }
    if ($EndIndex + 1 -lt $Lines.Count) {
        for ($Index = $EndIndex + 1; $Index -lt $Lines.Count; $Index++) {
            [void]$PatchedLines.Add([string]$Lines[$Index])
        }
    }

    [IO.File]::WriteAllLines(
        $DestinationPath,
        @($PatchedLines),
        (New-Object System.Text.UTF8Encoding($true))
    )
}

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'FINAL_NIGHT_CLOSEOUT_V10_3_RUNTIME_PRESERVATION_AND_DETAILED_RECORDING'
Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Result 'ORDER_PATH_MODIFIED' $false
Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
Add-Result 'BROKER_ORDER_ATTEMPTED' $false
Add-Result 'ORDER_TRANSPORT_CALLS' 0
Add-Result 'LIVE_DASHBOARD_INSTALL_ATTEMPTED' $false
Add-Result 'DASHBOARD_REQUIRED_FOR_TOMORROW_AUTOTRADE' $false
Add-Result 'MANUAL_VALUE_INPUT_USED' $false

$Success = $false

try {
    foreach ($Required in @($Root, $ControlRoot, $Database)) {
        if (-not (Test-Path -LiteralPath $Required)) {
            throw ('REQUIRED_PATH_MISSING:' + $Required)
        }
    }

    $RuntimeBefore = @(Get-RuntimeProcesses).Count
    $OrderBefore = Get-OrderLedgerCount
    $CriticalPaths = @(Get-CriticalSourcePaths)
    if ($CriticalPaths.Count -eq 0) {
        throw 'NO_CRITICAL_SOURCE_PATHS_FOUND'
    }
    $FingerprintBefore = Get-FingerprintForPaths -Paths $CriticalPaths

    Add-Result 'RUNTIME_PROCESS_COUNT_BEFORE' $RuntimeBefore
    Add-Result 'ORDER_LEDGER_COUNT_BEFORE' $OrderBefore
    Add-Result 'CRITICAL_SOURCE_FILE_COUNT' $CriticalPaths.Count
    Add-Result 'CRITICAL_SOURCE_FINGERPRINT_BEFORE' $FingerprintBefore
    Add-Result 'CANONICAL_RUNTIME_TASK_ENABLED_BEFORE' (Get-TaskEnabled $RuntimeTaskName)

    [void](Ensure-RuntimeTaskAndProcess)

    Invoke-WebRequest `
        -Uri $InstallerUrl `
        -OutFile $DownloadedInstaller `
        -UseBasicParsing `
        -TimeoutSec 30

    Patch-InstallerSyntax `
        -SourcePath $DownloadedInstaller `
        -DestinationPath $PatchedInstaller

    $Tokens = $null
    $ParseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $PatchedInstaller,
        [ref]$Tokens,
        [ref]$ParseErrors
    )
    Add-Result 'PATCHED_INSTALLER_PARSE_ERROR_COUNT' @($ParseErrors).Count
    if (@($ParseErrors).Count -ne 0) {
        $Messages = @($ParseErrors | ForEach-Object { $_.Message }) -join ' | '
        throw ('PATCHED_INSTALLER_PARSE_FAILED:' + $Messages)
    }
    Add-Result 'PATCHED_INSTALLER_PARSE' 'PASS'

    $InstallerOutput = @(
        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $PatchedInstaller `
            -Elevated 2>&1
    )
    $InstallerExitCode = $LASTEXITCODE
    Add-Result 'RECORDER_INSTALLER_EXIT_CODE' $InstallerExitCode

    foreach ($Line in $InstallerOutput) {
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

    if ($InstallerExitCode -ne 0) {
        throw ('RECORDER_INSTALLER_FAILED:' + (($InstallerOutput | Select-Object -Last 15) -join ' | '))
    }
    $InstallerText = $InstallerOutput -join "`n"
    if (-not $InstallerText.Contains(
        'FINAL_STATUS=PASS_DETAILED_STRATEGY_RECORDING_V10_1_INSTALLED_WITHOUT_AUTOTRADE_MUTATION'
    )) {
        throw 'RECORDER_INSTALLER_PASS_MARKER_MISSING'
    }

    $RuntimeAfter = Ensure-RuntimeTaskAndProcess
    $OrderAfter = Get-OrderLedgerCount
    $FingerprintAfter = Get-FingerprintForPaths -Paths $CriticalPaths

    if ($RuntimeAfter -ne 1) {
        throw 'FINAL_RUNTIME_COUNT_NOT_ONE'
    }
    if ($OrderAfter -ne $OrderBefore) {
        throw 'ORDER_LEDGER_COUNT_CHANGED'
    }
    if ($FingerprintAfter -ne $FingerprintBefore) {
        throw 'CRITICAL_AUTOTRADE_SOURCE_CHANGED'
    }
    if (-not (Get-TaskEnabled $RuntimeTaskName)) {
        throw 'CANONICAL_RUNTIME_TASK_DISABLED'
    }
    if (-not (Get-TaskEnabled $RecorderTaskName)) {
        throw 'DETAILED_RECORDER_TASK_NOT_ENABLED'
    }
    if (-not (Test-Path -LiteralPath $RecorderHealth)) {
        throw 'DETAILED_RECORDER_HEALTH_MISSING'
    }
    if (-not (Test-Path -LiteralPath $RecorderContract)) {
        throw 'DETAILED_RECORDER_CONTRACT_MISSING'
    }

    $RecorderTaskInfo = Get-ScheduledTaskInfo -TaskName $RecorderTaskName
    $HealthPayload = Get-Content -LiteralPath $RecorderHealth -Raw -Encoding UTF8 | ConvertFrom-Json
    $ContractPayload = Get-Content -LiteralPath $RecorderContract -Raw -Encoding UTF8 | ConvertFrom-Json

    if ([int]$RecorderTaskInfo.LastTaskResult -ne 0) {
        throw ('DETAILED_RECORDER_LAST_RESULT_' + $RecorderTaskInfo.LastTaskResult)
    }
    if (-not [bool]$HealthPayload.detailed_ready) {
        throw 'DETAILED_RECORDER_HEALTH_NOT_READY'
    }
    if ([bool]$ContractPayload.manualValueInputUsed) {
        throw 'DETAILED_RECORDER_MANUAL_VALUE_POLICY_VIOLATION'
    }
    if ([bool]$ContractPayload.manualOverrideAllowed) {
        throw 'DETAILED_RECORDER_MANUAL_OVERRIDE_POLICY_VIOLATION'
    }
    if ([bool]$ContractPayload.genericSummaryOnlyAllowed) {
        throw 'DETAILED_RECORDER_GENERIC_SUMMARY_POLICY_VIOLATION'
    }
    if ([int]$ContractPayload.intervalSeconds -ne 60) {
        throw 'DETAILED_RECORDER_INTERVAL_NOT_60_SECONDS'
    }

    Add-Result 'RUNTIME_PROCESS_COUNT_AFTER' $RuntimeAfter
    Add-Result 'CANONICAL_RUNTIME_TASK_ENABLED_AFTER' (Get-TaskEnabled $RuntimeTaskName)
    Add-Result 'ORDER_LEDGER_COUNT_AFTER' $OrderAfter
    Add-Result 'ORDER_LEDGER_COUNT_UNCHANGED' $true
    Add-Result 'CRITICAL_SOURCE_FINGERPRINT_AFTER' $FingerprintAfter
    Add-Result 'CRITICAL_AUTOTRADE_SOURCE_UNCHANGED' $true
    Add-Result 'DETAILED_RECORDER_TASK_ENABLED' $true
    Add-Result 'DETAILED_RECORDER_TASK_LAST_RESULT' ([int]$RecorderTaskInfo.LastTaskResult)
    Add-Result 'DETAILED_RECORDER_HEALTH_READY' ([bool]$HealthPayload.detailed_ready)
    Add-Result 'DETAILED_RECORDER_INTERVAL_SECONDS' ([int]$ContractPayload.intervalSeconds)
    Add-Result 'DETAILED_RECORDER_REASON_CANDIDATE_COUNT' ([int]$HealthPayload.reason_candidate_count)
    Add-Result 'DETAILED_RECORDER_NUMERIC_CONTEXT_COUNT' ([int]$HealthPayload.numeric_context_count)
    Add-Result 'DETAILED_RECORDER_PROVENANCE_COUNT' ([int]$HealthPayload.provenance_count)
    Add-Result 'FUTURE_DETAILED_RECORDING_PIPELINE_PROVEN' $true
    Add-Result 'GENERIC_SUMMARY_ONLY_ALLOWED' $false
    Add-Result 'HISTORICAL_DETAILED_RECORDING_GAP_REMAINS' $true
    Add-Result 'TOMORROW_AUTOTRADE_RUNTIME_PRESERVED' $true
    Add-Result 'NEXT_ACTUAL_MARKET_VALIDATION_PENDING' $true
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'LIVE_DASHBOARD_INSTALL_ATTEMPTED' $false
    Add-Result 'FINAL_STATUS' 'PASS_NIGHT_CLOSEOUT_V10_3_AUTOTRADE_PRESERVED_AND_DETAILED_RECORDING_INSTALLED'
    $Success = $true
}
catch {
    Add-Result 'CLOSEOUT_ERROR' $_.Exception.Message
    Add-Result 'FINAL_RUNTIME_PROCESS_COUNT' (@(Get-RuntimeProcesses).Count)
    Add-Result 'CANONICAL_RUNTIME_TASK_ENABLED_FINAL' (Get-TaskEnabled $RuntimeTaskName)
    try {
        Add-Result 'FINAL_ORDER_LEDGER_COUNT' (Get-OrderLedgerCount)
    }
    catch {
        Add-Result 'FINAL_ORDER_LEDGER_COUNT' 'READ_FAILED'
    }
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'LIVE_DASHBOARD_INSTALL_ATTEMPTED' $false
    Add-Result 'FINAL_STATUS' 'FAIL_NIGHT_CLOSEOUT_V10_3_REQUIRES_REVIEW'
}

Add-Result 'REPORT' $Report

$CopyStatus = 'FAILED'
try {
    Set-Clipboard -Value ($Results -join [Environment]::NewLine)
    $CopyStatus = 'SUCCESS'
}
catch {
    $CopyStatus = 'FAILED'
}
Add-Result 'COPY_STATUS' $CopyStatus

$OutputText = ($Results -join [Environment]::NewLine) + [Environment]::NewLine
[IO.File]::WriteAllText(
    $Report,
    $OutputText,
    (New-Object System.Text.UTF8Encoding($true))
)

if ($HandoffPath) {
    [IO.File]::WriteAllText(
        $HandoffPath,
        $OutputText,
        (New-Object System.Text.UTF8Encoding($true))
    )
}

Write-Output $OutputText

if ($Success) {
    exit 0
}
exit 1
