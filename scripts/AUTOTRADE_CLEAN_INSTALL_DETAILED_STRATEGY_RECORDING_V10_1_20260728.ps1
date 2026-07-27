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
$PrincipalCheck = New-Object Security.Principal.WindowsPrincipal($Identity)
$IsAdministrator = $PrincipalCheck.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $IsAdministrator -and -not $Elevated) {
    $Handoff = Join-Path $env:TEMP (
        'AUTOTRADE_DETAILED_STRATEGY_RECORDING_' +
        [guid]::NewGuid().ToString('N') +
        '.txt'
    )
    $Arguments = (
        '-NoProfile -ExecutionPolicy Bypass ' +
        '-File "{0}" -Elevated -HandoffPath "{1}"'
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
$Database = Join-Path $Root 'state\autotrade.db'
$Snapshot = Join-Path $Root 'state\current_snapshot_runtime.json'
$Base = Join-Path $ControlRoot 'DETAILED_STRATEGY_RECORDING_V10_1'
$Installed = Join-Path $Base 'installed'
$Records = Join-Path $Base 'records'
$Logs = Join-Path $Base 'logs'
$Reports = Join-Path $Base 'reports'
$Backups = Join-Path $Base 'backups'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$Report = Join-Path $Reports ('INSTALL_' + $Stamp + '.txt')
$Recorder = Join-Path $Installed 'autotrade_detailed_strategy_recorder_v10_1.py'
$Wrapper = Join-Path $Installed 'run_detailed_strategy_recorder_v10_1.ps1'
$TaskName = 'AUTOTRADE_CLEAN_DETAILED_STRATEGY_RECORDER_V10_1'
$RecorderUrl = 'https://raw.githubusercontent.com/custombro/custombro-ops/main/scripts/helpers/autotrade_detailed_strategy_recorder_v10_1.py'
$TaskBackup = Join-Path $Backups ('TASK_' + $Stamp + '.xml')
$Contract = Join-Path $Base 'DETAILED_STRATEGY_RECORDING_CONTRACT_V10_1.json'
$Health = Join-Path $Records 'DETAILED_STRATEGY_RECORDER_HEALTH.json'
$LatestRecord = Join-Path $Records 'DETAILED_STRATEGY_LATEST.json'
$LogFile = Join-Path $Logs 'recorder.log'

New-Item -ItemType Directory -Path $Installed, $Records, $Logs, $Reports, $Backups -Force | Out-Null

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

function Get-HttpProbe {
    param([string]$Path)

    $Watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $Response = Invoke-WebRequest `
            -Uri ('http://127.0.0.1:3100' + $Path) `
            -UseBasicParsing `
            -TimeoutSec 12
        $Watch.Stop()
        return [ordered]@{
            status = [int]$Response.StatusCode
            milliseconds = [int]$Watch.ElapsedMilliseconds
        }
    }
    catch {
        $Watch.Stop()
        return [ordered]@{
            status = 0
            milliseconds = [int]$Watch.ElapsedMilliseconds
        }
    }
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
    $Temporary = Join-Path $env:TEMP (
        'autotrade_detailed_recording_order_count_' +
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

function Get-CriticalFingerprint {
    $Files = New-Object System.Collections.Generic.List[System.IO.FileInfo]

    foreach ($Target in @(
        (Join-Path $Root 'app\dashboard.py'),
        (Join-Path $Root 'web\index.html'),
        (Join-Path $Root 'app\stage12_runtime_bootstrap.py')
    )) {
        if (Test-Path -LiteralPath $Target) {
            [void]$Files.Add((Get-Item -LiteralPath $Target))
        }
    }

    foreach ($File in @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $LowerPath = $_.FullName.ToLowerInvariant()
            $LowerName = $_.Name.ToLowerInvariant()
            -not $LowerPath.Contains('\state\') -and
            (
                $LowerName.Contains('strategy') -or
                $LowerName.Contains('stage13l') -or
                $LowerName.Contains('order_authority') -or
                $LowerName.Contains('order_transport')
            )
        } |
        Sort-Object FullName |
        Select-Object -First 700
    )) {
        if (-not ($Files.FullName -contains $File.FullName)) {
            [void]$Files.Add($File)
        }
    }

    $Builder = New-Object System.Text.StringBuilder
    foreach ($File in @($Files | Sort-Object FullName)) {
        $Hash = (
            Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256
        ).Hash.ToUpperInvariant()
        [void]$Builder.AppendLine($File.FullName + '|' + $Hash)
    }

    $Bytes = [Text.Encoding]::UTF8.GetBytes($Builder.ToString())
    $Sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Digest = $Sha.ComputeHash($Bytes)
    }
    finally {
        $Sha.Dispose()
    }

    return [ordered]@{
        count = $Files.Count
        sha256 = ([BitConverter]::ToString($Digest)).Replace('-', '')
    }
}

function Get-FileHashSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return 'MISSING'
    }
    return (
        Get-FileHash -LiteralPath $Path -Algorithm SHA256
    ).Hash.ToUpperInvariant()
}

function Get-RecorderOutputValue {
    param(
        [string[]]$Lines,
        [string]$Key
    )
    $Prefix = $Key + '='
    foreach ($Line in $Lines) {
        $Text = [string]$Line
        if ($Text.StartsWith($Prefix)) {
            return $Text.Substring($Prefix.Length)
        }
    }
    return $null
}

function Invoke-RecorderDirect {
    $Python = Get-PythonPath
    $Output = @(& $Python $Recorder $Root $ControlRoot $Records 2>&1)
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0) {
        throw ('RECORDER_DIRECT_RUN_FAILED:' + ($Output -join ' '))
    }
    if (-not (($Output -join "`n").Contains('FINAL_STATUS=PASS_DETAILED_STRATEGY_RECORDER_V10_1'))) {
        throw ('RECORDER_PASS_MARKER_MISSING:' + ($Output -join ' '))
    }
    return @($Output | ForEach-Object { [string]$_ })
}

function Restore-TaskState {
    param(
        [bool]$PreviouslyExisted,
        [string]$BackupPath
    )

    if ($PreviouslyExisted -and (Test-Path -LiteralPath $BackupPath)) {
        $Xml = Get-Content -LiteralPath $BackupPath -Raw -Encoding Unicode
        Register-ScheduledTask -TaskName $TaskName -Xml $Xml -Force | Out-Null
    }
    else {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'INSTALL_APPEND_ONLY_DETAILED_STRATEGY_RECORDING_V10_1'
Add-Result 'MANUAL_VALUE_INPUT_USED' $false
Add-Result 'GENERIC_SUMMARY_ONLY_ALLOWED' $false
Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Result 'ORDER_PATH_MODIFIED' $false
Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
Add-Result 'BROKER_ORDER_ATTEMPTED' $false
Add-Result 'ORDER_TRANSPORT_CALLS' 0
Add-Result 'RUNTIME_RESTARTED' $false
Add-Result 'SCHEDULED_TASK_MODIFIED' $true
Add-Result 'RECORDER_INTERVAL_SECONDS' 60
Add-Result 'RECORDER_WRITE_TARGET' $Records

$Success = $false
$TaskPreviouslyExisted = $false
$TaskRegisteredByThisRun = $false

try {
    foreach ($Required in @($Root, $ControlRoot, $Database, $Snapshot)) {
        if (-not (Test-Path -LiteralPath $Required)) {
            throw ('REQUIRED_PATH_MISSING:' + $Required)
        }
    }

    $RuntimeBefore = @(Get-RuntimeProcesses).Count
    $RootBefore = Get-HttpProbe '/'
    $HealthBefore = Get-HttpProbe '/api/v1/health'
    $SnapshotHttpBefore = Get-HttpProbe '/api/v1/snapshot'
    $OrderBefore = Get-OrderLedgerCount
    $FingerprintBefore = Get-CriticalFingerprint
    $SnapshotHashBefore = Get-FileHashSafe $Snapshot

    Add-Result 'RUNTIME_PROCESS_COUNT_BEFORE' $RuntimeBefore
    Add-Result 'DASHBOARD_HTTP_ROOT_BEFORE' $RootBefore.status
    Add-Result 'DASHBOARD_LATENCY_MS_ROOT_BEFORE' $RootBefore.milliseconds
    Add-Result 'DASHBOARD_HTTP_HEALTH_BEFORE' $HealthBefore.status
    Add-Result 'DASHBOARD_HTTP_SNAPSHOT_BEFORE' $SnapshotHttpBefore.status
    Add-Result 'ORDER_LEDGER_COUNT_BEFORE' $OrderBefore
    Add-Result 'CRITICAL_FILE_COUNT_BEFORE' $FingerprintBefore.count
    Add-Result 'CRITICAL_FINGERPRINT_BEFORE' $FingerprintBefore.sha256
    Add-Result 'SOURCE_SNAPSHOT_HASH_BEFORE' $SnapshotHashBefore

    if ($RuntimeBefore -ne 1) {
        throw 'RUNTIME_COUNT_NOT_ONE'
    }
    if ($RootBefore.status -ne 200 -or $HealthBefore.status -ne 200 -or $SnapshotHttpBefore.status -ne 200) {
        throw 'LIVE_DASHBOARD_NOT_HEALTHY_BEFORE_INSTALL'
    }

    $ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $TaskPreviouslyExisted = $null -ne $ExistingTask
    Add-Result 'TASK_PREVIOUSLY_EXISTED' $TaskPreviouslyExisted
    if ($TaskPreviouslyExisted) {
        Export-ScheduledTask -TaskName $TaskName | Out-File -LiteralPath $TaskBackup -Encoding Unicode -Force
        Add-Result 'TASK_BACKUP' $TaskBackup
    }

    Invoke-WebRequest -Uri $RecorderUrl -OutFile $Recorder -UseBasicParsing -TimeoutSec 30
    $Python = Get-PythonPath
    $CompileOutput = @(& $Python -m py_compile $Recorder 2>&1)
    $CompileExit = $LASTEXITCODE
    Add-Result 'RECORDER_COMPILE_EXIT_CODE' $CompileExit
    if ($CompileExit -ne 0) {
        throw ('RECORDER_COMPILE_FAILED:' + ($CompileOutput -join ' '))
    }
    Add-Result 'RECORDER_COMPILE' 'PASS'

    $WrapperContent = @"
`$ErrorActionPreference = 'Stop'
`$Python = '$Python'
`$Recorder = '$Recorder'
`$Root = '$Root'
`$ControlRoot = '$ControlRoot'
`$Records = '$Records'
`$LogFile = '$LogFile'
try {
    `$Output = @(& `$Python `$Recorder `$Root `$ControlRoot `$Records 2>&1)
    `$ExitCode = `$LASTEXITCODE
    `$Stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'
    Add-Content -LiteralPath `$LogFile -Value ('[' + `$Stamp + '] EXIT=' + `$ExitCode) -Encoding UTF8
    foreach (`$Line in `$Output) {
        Add-Content -LiteralPath `$LogFile -Value ([string]`$Line) -Encoding UTF8
    }
    exit `$ExitCode
}
catch {
    `$Stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'
    Add-Content -LiteralPath `$LogFile -Value ('[' + `$Stamp + '] ERROR=' + `$_.Exception.Message) -Encoding UTF8
    exit 1
}
"@
    [IO.File]::WriteAllText(
        $Wrapper,
        $WrapperContent,
        (New-Object System.Text.UTF8Encoding($true))
    )

    $FirstOutput = Invoke-RecorderDirect
    foreach ($Key in @(
        'EVENT_RECORDED',
        'DETAILED_RECORD_READY',
        'STRATEGY_ACTION',
        'REASON_CANDIDATE_COUNT',
        'NUMERIC_CONTEXT_COUNT',
        'PROVENANCE_FIELD_COUNT',
        'STRATEGY_SECTION_COUNT',
        'MARKET_SECTION_COUNT',
        'RISK_SECTION_COUNT',
        'DAILY_RECORD_FILE',
        'LATEST_RECORD_FILE',
        'HEALTH_FILE'
    )) {
        $Value = Get-RecorderOutputValue -Lines $FirstOutput -Key $Key
        if ($null -ne $Value) {
            Add-Result ('FIRST_' + $Key) $Value
        }
    }

    if ((Get-RecorderOutputValue -Lines $FirstOutput -Key 'DETAILED_RECORD_READY') -ne 'TRUE') {
        throw 'CURRENT_SNAPSHOT_NOT_DETAILED_ENOUGH_FOR_CONFIRMED_RECORDING'
    }
    if ((Get-RecorderOutputValue -Lines $FirstOutput -Key 'MANUAL_VALUE_INPUT_USED') -ne 'FALSE') {
        throw 'MANUAL_VALUE_POLICY_VIOLATION'
    }
    if ((Get-RecorderOutputValue -Lines $FirstOutput -Key 'GENERIC_SUMMARY_ONLY') -ne 'FALSE') {
        throw 'GENERIC_SUMMARY_ONLY_POLICY_VIOLATION'
    }

    $SecondOutput = Invoke-RecorderDirect
    $SecondDuplicate = Get-RecorderOutputValue -Lines $SecondOutput -Key 'DUPLICATE_EVENT'
    Add-Result 'SECOND_RUN_DUPLICATE_EVENT' $SecondDuplicate
    if ($SecondDuplicate -ne 'TRUE') {
        throw 'RECORDER_DEDUPLICATION_NOT_PROVEN'
    }

    $ContractPayload = [ordered]@{
        contractType = 'AUTOTRADE_CLEAN_DETAILED_STRATEGY_RECORDING_CONTRACT_V10_1'
        installedAt = (Get-Date).ToString('o')
        sourceSnapshot = $Snapshot
        outputRoot = $Records
        taskName = $TaskName
        intervalSeconds = 60
        appendOnly = $true
        deduplicateByStrategyEventHash = $true
        manualValueInputUsed = $false
        manualOverrideAllowed = $false
        genericSummaryOnlyAllowed = $false
        captures = @(
            'strategy_action_and_timestamp',
            'all_reason_evidence_fields',
            'market_numeric_context',
            'candidate_scores_and_reasons',
            'risk_and_gate_context',
            'account_generation_and_hash_provenance',
            'raw_sanitized_snapshot'
        )
        liveDashboardModified = $false
        autotradeStrategyModified = $false
        orderPathModified = $false
        databaseDirectWriteUsed = $false
        brokerOrderAttempted = $false
    }
    [IO.File]::WriteAllText(
        $Contract,
        ($ContractPayload | ConvertTo-Json -Depth 20),
        (New-Object System.Text.UTF8Encoding($true))
    )

    $Action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument (
            '-NoProfile -NonInteractive -WindowStyle Hidden ' +
            '-ExecutionPolicy Bypass -File "{0}"'
        -f $Wrapper)
    $Trigger = New-ScheduledTaskTrigger `
        -Once `
        -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 1) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $Principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable `
        -Hidden

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Principal $Principal `
        -Settings $Settings `
        -Force |
        Out-Null
    $TaskRegisteredByThisRun = $true

    $TaskXml = Export-ScheduledTask -TaskName $TaskName
    if (-not $TaskXml.Contains('<Interval>PT1M</Interval>')) {
        throw 'TASK_ONE_MINUTE_INTERVAL_NOT_PROVEN'
    }

    $HealthWriteBeforeTask = if (Test-Path -LiteralPath $Health) {
        (Get-Item -LiteralPath $Health).LastWriteTimeUtc
    }
    else {
        [datetime]::MinValue
    }

    Start-ScheduledTask -TaskName $TaskName
    $Deadline = (Get-Date).AddSeconds(45)
    do {
        Start-Sleep -Milliseconds 500
        $TaskState = (Get-ScheduledTask -TaskName $TaskName).State
    } while ($TaskState -eq 'Running' -and (Get-Date) -lt $Deadline)

    if ($TaskState -eq 'Running') {
        throw 'SCHEDULED_RECORDER_DID_NOT_FINISH_WITHIN_LIMIT'
    }

    $TaskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
    Add-Result 'TASK_LAST_RUN_TIME' $TaskInfo.LastRunTime.ToString('o')
    Add-Result 'TASK_LAST_RESULT' $TaskInfo.LastTaskResult
    if ([int]$TaskInfo.LastTaskResult -ne 0) {
        throw ('SCHEDULED_RECORDER_LAST_RESULT_NOT_ZERO:' + $TaskInfo.LastTaskResult)
    }

    if (-not (Test-Path -LiteralPath $Health)) {
        throw 'RECORDER_HEALTH_FILE_MISSING_AFTER_TASK_RUN'
    }
    $HealthWriteAfterTask = (Get-Item -LiteralPath $Health).LastWriteTimeUtc
    if ($HealthWriteAfterTask -le $HealthWriteBeforeTask) {
        throw 'SCHEDULED_RECORDER_HEALTH_NOT_REFRESHED'
    }

    $HealthPayload = Get-Content -LiteralPath $Health -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Result 'TASK_HEALTH_DETAILED_READY' ([bool]$HealthPayload.detailed_ready)
    Add-Result 'TASK_HEALTH_REASON_CANDIDATE_COUNT' ([int]$HealthPayload.reason_candidate_count)
    Add-Result 'TASK_HEALTH_NUMERIC_CONTEXT_COUNT' ([int]$HealthPayload.numeric_context_count)
    Add-Result 'TASK_HEALTH_PROVENANCE_COUNT' ([int]$HealthPayload.provenance_count)
    if (-not [bool]$HealthPayload.detailed_ready) {
        throw 'SCHEDULED_RECORDER_DETAILED_READY_FALSE'
    }

    $RuntimeAfter = @(Get-RuntimeProcesses).Count
    $RootAfter = Get-HttpProbe '/'
    $HealthAfter = Get-HttpProbe '/api/v1/health'
    $SnapshotHttpAfter = Get-HttpProbe '/api/v1/snapshot'
    $OrderAfter = Get-OrderLedgerCount
    $FingerprintAfter = Get-CriticalFingerprint
    $SnapshotHashAfter = Get-FileHashSafe $Snapshot

    if ($RuntimeAfter -ne $RuntimeBefore) {
        throw 'RUNTIME_COUNT_CHANGED'
    }
    if ($RootAfter.status -ne 200 -or $HealthAfter.status -ne 200 -or $SnapshotHttpAfter.status -ne 200) {
        throw 'LIVE_DASHBOARD_HEALTH_CHANGED'
    }
    if ($OrderAfter -ne $OrderBefore) {
        throw 'ORDER_LEDGER_COUNT_CHANGED'
    }
    if ($FingerprintAfter.sha256 -ne $FingerprintBefore.sha256) {
        throw 'CRITICAL_FILE_FINGERPRINT_CHANGED'
    }

    Add-Result 'RUNTIME_PROCESS_COUNT_AFTER' $RuntimeAfter
    Add-Result 'DASHBOARD_HTTP_ROOT_AFTER' $RootAfter.status
    Add-Result 'DASHBOARD_LATENCY_MS_ROOT_AFTER' $RootAfter.milliseconds
    Add-Result 'DASHBOARD_HTTP_HEALTH_AFTER' $HealthAfter.status
    Add-Result 'DASHBOARD_HTTP_SNAPSHOT_AFTER' $SnapshotHttpAfter.status
    Add-Result 'ORDER_LEDGER_COUNT_AFTER' $OrderAfter
    Add-Result 'ORDER_LEDGER_COUNT_UNCHANGED' $true
    Add-Result 'CRITICAL_FILE_COUNT_AFTER' $FingerprintAfter.count
    Add-Result 'CRITICAL_FINGERPRINT_AFTER' $FingerprintAfter.sha256
    Add-Result 'CRITICAL_FILES_UNCHANGED' $true
    Add-Result 'SOURCE_SNAPSHOT_HASH_AFTER' $SnapshotHashAfter
    Add-Result 'SOURCE_SNAPSHOT_NATURAL_CHANGE_DETECTED' ($SnapshotHashAfter -ne $SnapshotHashBefore)
    Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'RUNTIME_RESTARTED' $false
    Add-Result 'SCHEDULED_TASK_MODIFIED' $true
    Add-Result 'APPEND_ONLY_DETAILED_RECORDER_INSTALLED' $true
    Add-Result 'CURRENT_DETAILED_RECORD_CAPTURED' $true
    Add-Result 'SCHEDULED_TASK_EXECUTION_PROVEN' $true
    Add-Result 'FUTURE_DETAILED_RECORDING_PIPELINE_PROVEN' $true
    Add-Result 'NEXT_ACTUAL_STRATEGY_CHANGE_CAPTURE_PENDING' $true
    Add-Result 'HISTORICAL_DETAILED_RECORDING_GAP_REMAINS' $true
    Add-Result 'MANUAL_VALUE_INPUT_USED' $false
    Add-Result 'GENERIC_SUMMARY_ONLY_ALLOWED' $false
    Add-Result 'RECORDER_TASK' $TaskName
    Add-Result 'RECORDING_CONTRACT' $Contract
    Add-Result 'LATEST_DETAILED_RECORD' $LatestRecord
    Add-Result 'RECORDER_HEALTH' $Health
    Add-Result 'NEXT_STAGE' 'VERIFY_NEXT_ACTUAL_STRATEGY_CHANGE_AUTO_CAPTURE_THEN_LINK_DASHBOARD_HISTORY'
    Add-Result 'FINAL_STATUS' 'PASS_DETAILED_STRATEGY_RECORDING_V10_1_INSTALLED_WITHOUT_AUTOTRADE_MUTATION'
    $Success = $true
}
catch {
    $FailureMessage = $_.Exception.Message
    if ($TaskRegisteredByThisRun) {
        try {
            Restore-TaskState -PreviouslyExisted $TaskPreviouslyExisted -BackupPath $TaskBackup
            Add-Result 'TASK_ROLLBACK_STATE' 'COMPLETED'
        }
        catch {
            Add-Result 'TASK_ROLLBACK_STATE' ('FAILED:' + $_.Exception.Message)
        }
    }

    Add-Result 'INSTALL_ERROR' $FailureMessage
    Add-Result 'FINAL_RUNTIME_PROCESS_COUNT' (@(Get-RuntimeProcesses).Count)
    try {
        Add-Result 'FINAL_ORDER_LEDGER_COUNT' (Get-OrderLedgerCount)
    }
    catch {
        Add-Result 'FINAL_ORDER_LEDGER_COUNT' 'READ_FAILED'
    }
    Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'RUNTIME_RESTARTED' $false
    Add-Result 'FUTURE_DETAILED_RECORDING_PIPELINE_PROVEN' $false
    Add-Result 'FINAL_STATUS' 'FAIL_DETAILED_STRATEGY_RECORDING_V10_1_REQUIRES_REVIEW'
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
