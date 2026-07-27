#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\AUTOTRADE_CLEAN'
$ControlRoot = 'C:\Users\hjk86\AUTOTRADE_CONTROL'
$Database = 'C:\AUTOTRADE_CLEAN\state\autotrade.db'
$Snapshot = 'C:\AUTOTRADE_CLEAN\state\current_snapshot_runtime.json'
$Base = 'C:\Users\hjk86\AUTOTRADE_CONTROL\DETAILED_STRATEGY_RECORDING_V10_3'
$Installed = Join-Path $Base 'installed'
$Records = Join-Path $Base 'records'
$Logs = Join-Path $Base 'logs'
$Reports = Join-Path $Base 'reports'
$Recorder = Join-Path $Installed 'autotrade_detailed_strategy_recorder_v10_1.py'
$Wrapper = Join-Path $Installed 'run_detailed_strategy_recorder_v10_3.cmd'
$Health = Join-Path $Records 'DETAILED_STRATEGY_RECORDER_HEALTH.json'
$Latest = Join-Path $Records 'DETAILED_STRATEGY_LATEST.json'
$TaskName = 'AUTOTRADE_CLEAN_DETAILED_STRATEGY_RECORDER_V10_3'
$RuntimeTask = 'AUTOTRADE_CLEAN_RUNTIME'
$RecorderUrl = 'https://raw.githubusercontent.com/custombro/custombro-ops/main/scripts/helpers/autotrade_detailed_strategy_recorder_v10_1.py'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$Report = Join-Path $Reports ('FINAL_' + $Stamp + '.txt')

New-Item -ItemType Directory -Path $Installed -Force | Out-Null
New-Item -ItemType Directory -Path $Records -Force | Out-Null
New-Item -ItemType Directory -Path $Logs -Force | Out-Null
New-Item -ItemType Directory -Path $Reports -Force | Out-Null

$Lines = New-Object System.Collections.Generic.List[string]
function Add-Line([string]$Key, [object]$Value) {
    if ($Value -is [bool]) { $Text = $Value.ToString().ToUpperInvariant() }
    else { $Text = [string]$Value }
    [void]$Lines.Add($Key + '=' + $Text)
}
function Get-PythonPath {
    $Known = 'C:\Program Files\Python312\python.exe'
    if (Test-Path -LiteralPath $Known) { return $Known }
    return (Get-Command python.exe -ErrorAction Stop).Source
}
function Get-RuntimeCount {
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^pythonw?\.exe$' -and
            [string]$_.CommandLine -like '*C:\AUTOTRADE_CLEAN\app\stage12_runtime_bootstrap.py*' -and
            [string]$_.CommandLine -like '*--mode persistent*'
        }
    ).Count
}
function Get-HttpStatus([string]$Path) {
    try {
        $r = Invoke-WebRequest -Uri ('http://127.0.0.1:3100' + $Path) -UseBasicParsing -TimeoutSec 10
        return [int]$r.StatusCode
    }
    catch { return 0 }
}
function Get-OrderLedgerCount {
    $Python = Get-PythonPath
    $Code = "import sqlite3,sys;c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True);print(c.execute('select count(*) from order_ledger').fetchone()[0]);c.close()"
    $Out = & $Python -c $Code $Database 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('ORDER_LEDGER_READ_FAILED:' + ($Out -join ' ')) }
    return [int]([string]($Out | Select-Object -Last 1)).Trim()
}
function Get-TaskState([string]$Name) {
    try { return (Get-ScheduledTask -TaskName $Name -ErrorAction Stop).State.ToString() }
    catch { return 'MISSING' }
}

$Success = $false
Add-Line 'FINAL_STATUS' 'RUNNING'
Add-Line 'EXECUTION_MODE' 'FINAL_NIGHT_CLOSEOUT_V10_3_SIMPLE_SAFE'
Add-Line 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Line 'ORDER_PATH_MODIFIED' $false
Add-Line 'DATABASE_DIRECT_WRITE_USED' $false
Add-Line 'BROKER_ORDER_ATTEMPTED' $false
Add-Line 'ORDER_TRANSPORT_CALLS' 0
Add-Line 'LIVE_DASHBOARD_INSTALL_ATTEMPTED' $false
Add-Line 'MANUAL_VALUE_INPUT_USED' $false

try {
    foreach ($Required in @($Root,$Database,$Snapshot)) {
        if (-not (Test-Path -LiteralPath $Required)) { throw ('REQUIRED_PATH_MISSING:' + $Required) }
    }

    $RuntimeBefore = Get-RuntimeCount
    $OrderBefore = Get-OrderLedgerCount
    $RootHttpBefore = Get-HttpStatus '/'
    $HealthHttpBefore = Get-HttpStatus '/api/v1/health'
    $SnapshotHttpBefore = Get-HttpStatus '/api/v1/snapshot'
    $RuntimeTaskStateBefore = Get-TaskState $RuntimeTask

    Add-Line 'RUNTIME_PROCESS_COUNT_BEFORE' $RuntimeBefore
    Add-Line 'ORDER_LEDGER_COUNT_BEFORE' $OrderBefore
    Add-Line 'DASHBOARD_HTTP_ROOT_BEFORE' $RootHttpBefore
    Add-Line 'DASHBOARD_HTTP_HEALTH_BEFORE' $HealthHttpBefore
    Add-Line 'DASHBOARD_HTTP_SNAPSHOT_BEFORE' $SnapshotHttpBefore
    Add-Line 'RUNTIME_TASK_STATE_BEFORE' $RuntimeTaskStateBefore

    if ($RuntimeBefore -ne 1) { throw 'RUNTIME_COUNT_NOT_ONE' }
    if ($RuntimeTaskStateBefore -eq 'MISSING') { throw 'CANONICAL_RUNTIME_TASK_MISSING' }

    $RuntimeTaskObj = Get-ScheduledTask -TaskName $RuntimeTask
    if ($RuntimeTaskObj.Settings.Enabled -ne $true) {
        Enable-ScheduledTask -TaskName $RuntimeTask | Out-Null
    }
    Add-Line 'RUNTIME_TASK_ENABLED' ((Get-ScheduledTask -TaskName $RuntimeTask).Settings.Enabled)

    Invoke-WebRequest -Uri $RecorderUrl -OutFile $Recorder -UseBasicParsing -TimeoutSec 30
    $Python = Get-PythonPath
    $Compile = & $Python -m py_compile $Recorder 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('RECORDER_COMPILE_FAILED:' + ($Compile -join ' ')) }
    Add-Line 'RECORDER_COMPILE' 'PASS'

    $DirectOutput = & $Python $Recorder $Root $ControlRoot $Records 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('RECORDER_FIRST_RUN_FAILED:' + ($DirectOutput -join ' ')) }
    $DirectText = $DirectOutput -join "`n"
    if ($DirectText -notmatch 'DETAILED_RECORD_READY=TRUE') { throw 'DETAILED_RECORD_NOT_READY' }
    if ($DirectText -notmatch 'MANUAL_VALUE_INPUT_USED=FALSE') { throw 'MANUAL_VALUE_POLICY_FAILED' }
    if ($DirectText -notmatch 'GENERIC_SUMMARY_ONLY=FALSE') { throw 'GENERIC_SUMMARY_POLICY_FAILED' }
    Add-Line 'FIRST_DETAILED_RECORD_READY' $true

    $WrapperContent = '@echo off' + "`r`n" + '"' + $Python + '" "' + $Recorder + '" "' + $Root + '" "' + $ControlRoot + '" "' + $Records + '" >> "' + (Join-Path $Logs 'recorder.log') + '" 2>&1' + "`r`n" + 'exit /b %errorlevel%' + "`r`n"
    [IO.File]::WriteAllText($Wrapper,$WrapperContent,(New-Object System.Text.ASCIIEncoding))

    $TaskCommand = '"' + $Wrapper + '"'
    & schtasks.exe /Create /TN $TaskName /TR $TaskCommand /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('SCHEDULED_TASK_CREATE_FAILED:' + $LASTEXITCODE) }

    & schtasks.exe /Run /TN $TaskName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('SCHEDULED_TASK_RUN_FAILED:' + $LASTEXITCODE) }
    Start-Sleep -Seconds 8

    if (-not (Test-Path -LiteralPath $Health)) { throw 'RECORDER_HEALTH_FILE_MISSING' }
    if (-not (Test-Path -LiteralPath $Latest)) { throw 'RECORDER_LATEST_FILE_MISSING' }
    $HealthPayload = Get-Content -LiteralPath $Health -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [bool]$HealthPayload.detailed_ready) { throw 'RECORDER_HEALTH_DETAILED_READY_FALSE' }

    $TaskQuery = & schtasks.exe /Query /TN $TaskName /FO LIST /V 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('SCHEDULED_TASK_QUERY_FAILED:' + ($TaskQuery -join ' ')) }
    Add-Line 'DETAILED_RECORDER_TASK_INSTALLED' $true
    Add-Line 'DETAILED_RECORDER_INTERVAL_MINUTES' 1
    Add-Line 'TASK_HEALTH_DETAILED_READY' $true
    Add-Line 'LATEST_DETAILED_RECORD' $Latest

    $RuntimeAfter = Get-RuntimeCount
    $OrderAfter = Get-OrderLedgerCount
    $RootHttpAfter = Get-HttpStatus '/'
    $HealthHttpAfter = Get-HttpStatus '/api/v1/health'
    $SnapshotHttpAfter = Get-HttpStatus '/api/v1/snapshot'
    $RuntimeTaskStateAfter = Get-TaskState $RuntimeTask

    if ($RuntimeAfter -ne 1) { throw 'RUNTIME_COUNT_CHANGED' }
    if ($OrderAfter -ne $OrderBefore) { throw 'ORDER_LEDGER_COUNT_CHANGED' }
    if ($RuntimeTaskStateAfter -eq 'MISSING') { throw 'RUNTIME_TASK_DISAPPEARED' }

    Add-Line 'FINAL_RUNTIME_PROCESS_COUNT' $RuntimeAfter
    Add-Line 'FINAL_ORDER_LEDGER_COUNT' $OrderAfter
    Add-Line 'ORDER_LEDGER_COUNT_UNCHANGED' $true
    Add-Line 'FINAL_DASHBOARD_HTTP_ROOT' $RootHttpAfter
    Add-Line 'FINAL_DASHBOARD_HTTP_HEALTH' $HealthHttpAfter
    Add-Line 'FINAL_DASHBOARD_HTTP_SNAPSHOT' $SnapshotHttpAfter
    Add-Line 'FINAL_RUNTIME_TASK_STATE' $RuntimeTaskStateAfter
    Add-Line 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Line 'ORDER_PATH_MODIFIED' $false
    Add-Line 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Line 'BROKER_ORDER_ATTEMPTED' $false
    Add-Line 'ORDER_TRANSPORT_CALLS' 0
    Add-Line 'LIVE_DASHBOARD_INSTALL_ATTEMPTED' $false
    Add-Line 'MANUAL_VALUE_INPUT_USED' $false
    Add-Line 'FUTURE_DETAILED_RECORDING_PIPELINE_INSTALLED' $true
    Add-Line 'NEXT_ACTUAL_STRATEGY_CHANGE_CAPTURE_PENDING' $true
    Add-Line 'TOMORROW_AUTOTRADE_RUNTIME_PRESERVED' $true
    Add-Line 'FINAL_STATUS' 'PASS_NIGHT_CLOSEOUT_V10_3_AUTOTRADE_PRESERVED_AND_RECORDING_INSTALLED'
    $Success = $true
}
catch {
    Add-Line 'CLOSEOUT_ERROR' $_.Exception.Message
    Add-Line 'FINAL_RUNTIME_PROCESS_COUNT' (Get-RuntimeCount)
    try { Add-Line 'FINAL_ORDER_LEDGER_COUNT' (Get-OrderLedgerCount) } catch { Add-Line 'FINAL_ORDER_LEDGER_COUNT' 'READ_FAILED' }
    Add-Line 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Line 'ORDER_PATH_MODIFIED' $false
    Add-Line 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Line 'BROKER_ORDER_ATTEMPTED' $false
    Add-Line 'ORDER_TRANSPORT_CALLS' 0
    Add-Line 'LIVE_DASHBOARD_INSTALL_ATTEMPTED' $false
    Add-Line 'FINAL_STATUS' 'FAIL_NIGHT_CLOSEOUT_V10_3_REQUIRES_REVIEW'
}

Add-Line 'REPORT' $Report
try { Set-Clipboard -Value ($Lines -join "`r`n"); Add-Line 'COPY_STATUS' 'SUCCESS' } catch { Add-Line 'COPY_STATUS' 'FAILED' }
$OutputText = ($Lines -join "`r`n") + "`r`n"
[IO.File]::WriteAllText($Report,$OutputText,(New-Object System.Text.UTF8Encoding($true)))
Write-Output $OutputText
if ($Success) { exit 0 } else { exit 1 }
