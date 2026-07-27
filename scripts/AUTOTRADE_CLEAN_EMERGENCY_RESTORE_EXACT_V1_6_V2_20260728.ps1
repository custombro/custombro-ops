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
    $Handoff = Join-Path $env:TEMP (
        'AUTOTRADE_EXACT_V16_RESTORE_V2_' +
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

    $Output = Get-Content `
        -LiteralPath $Handoff `
        -Raw `
        -Encoding UTF8
    Write-Output $Output
    Remove-Item `
        -LiteralPath $Handoff `
        -Force `
        -ErrorAction SilentlyContinue
    exit $Child.ExitCode
}

if (-not $IsAdministrator) {
    throw 'ADMINISTRATOR_ELEVATION_FAILED'
}

$Root = 'C:\AUTOTRADE_CLEAN'
$ControlRoot = 'C:\Users\hjk86\AUTOTRADE_CONTROL'
$RuntimeTask = 'AUTOTRADE_CLEAN_RUNTIME'
$RefreshTask = 'AUTOTRADE_CLEAN_FACT_PNL_REFRESH_30M'
$CloseTask = 'AUTOTRADE_CLEAN_FACT_PNL_CLOSE_1625'
$FactBackups = Join-Path $ControlRoot 'FACT_DASHBOARD_V2\backups'
$LiveDashboard = Join-Path $Root 'app\dashboard.py'
$LiveTemplate = Join-Path $Root 'web\index.html'
$Database = Join-Path $Root 'state\autotrade.db'
$ExpectedDashboardHash = '42B687C8A4EA294EA9E8CF81AFFF0379BB71AFE4EFEBCB80A6EBEA982CD2620D'
$ExpectedTemplateHash = 'ADDEC81E61C8847694948773C9C903B68D4F57F55A2E7E8DD9A142F58025F370'
$ReportRoot = Join-Path $ControlRoot 'EMERGENCY_EXACT_V1_6_RESTORE_V2'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupRoot = Join-Path $ReportRoot 'pre_restore_backups'
$Report = Join-Path $ReportRoot ('RESTORE_' + $Stamp + '.txt')
New-Item -ItemType Directory -Path $ReportRoot, $BackupRoot -Force | Out-Null

$CurrentDashboardBackup = Join-Path $BackupRoot ('dashboard_' + $Stamp + '.py')
$CurrentTemplateBackup = Join-Path $BackupRoot ('index_' + $Stamp + '.html')
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
        $Text = $Value | ConvertTo-Json -Depth 20 -Compress
    }
    [void]$Results.Add($Key + '=' + $Text)
}

function Get-Sha256 {
    param([string]$Path)
    return (
        Get-FileHash -LiteralPath $Path -Algorithm SHA256
    ).Hash.ToUpperInvariant()
}

function Find-ExactBackup {
    param(
        [string]$Folder,
        [string]$Filter,
        [string]$ExpectedHash
    )

    $Matches = @(
        Get-ChildItem -LiteralPath $Folder -Filter $Filter -File -ErrorAction Stop |
        Where-Object {
            (Get-Sha256 $_.FullName) -eq $ExpectedHash
        } |
        Sort-Object LastWriteTime -Descending
    )

    if ($Matches.Count -lt 1) {
        throw ('EXACT_BACKUP_NOT_FOUND:' + $Filter + ':' + $ExpectedHash)
    }

    return $Matches[0].FullName
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

function Get-PythonPath {
    $Known = 'C:\Program Files\Python312\python.exe'
    if (Test-Path -LiteralPath $Known) {
        return $Known
    }
    return (Get-Command python.exe -ErrorAction Stop).Source
}

function Get-OrderLedgerCount {
    $Python = Get-PythonPath
    $Code = @'
import sqlite3
import sys
path = sys.argv[1]
con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
try:
    print(int(con.execute("SELECT COUNT(*) FROM order_ledger").fetchone()[0]))
finally:
    con.close()
'@
    $Temporary = Join-Path $env:TEMP (
        'autotrade_order_count_' + [guid]::NewGuid().ToString('N') + '.py'
    )
    [IO.File]::WriteAllText(
        $Temporary,
        $Code,
        (New-Object System.Text.UTF8Encoding($false))
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

function Stop-CanonicalRuntime {
    Stop-ScheduledTask -TaskName $RuntimeTask -ErrorAction SilentlyContinue
    foreach ($Process in @(Get-RuntimeProcesses)) {
        Stop-Process -Id $Process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $Deadline = (Get-Date).AddSeconds(30)
    while (
        @(Get-RuntimeProcesses).Count -gt 0 -and
        (Get-Date) -lt $Deadline
    ) {
        Start-Sleep -Milliseconds 500
    }
    if (@(Get-RuntimeProcesses).Count -ne 0) {
        throw 'RUNTIME_STOP_FAILED'
    }
}

function Start-CanonicalRuntime {
    Start-ScheduledTask -TaskName $RuntimeTask -ErrorAction Stop
    $Deadline = (Get-Date).AddSeconds(50)
    while (
        @(Get-RuntimeProcesses).Count -ne 1 -and
        (Get-Date) -lt $Deadline
    ) {
        Start-Sleep -Milliseconds 500
    }
    if (@(Get-RuntimeProcesses).Count -ne 1) {
        throw 'RUNTIME_START_FAILED'
    }
}

function Set-AtomicFile {
    param([string]$Target, [string]$Source)
    $Temporary = $Target + '.exact_v16_restore_v2_tmp'
    [IO.File]::WriteAllBytes($Temporary, [IO.File]::ReadAllBytes($Source))
    Move-Item -LiteralPath $Temporary -Destination $Target -Force
}

function Disable-TaskSafe {
    param([string]$Name)
    $Task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($null -eq $Task) {
        return 'NOT_FOUND'
    }
    Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName $Name -ErrorAction Stop | Out-Null
    return 'DISABLED'
}

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'EXACT_V1_6_RESTORE_V2_HASH_AND_HTTP_ONLY'
Add-Result 'FALSE_UI_MARKER_CHECK_REMOVED' $true
Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Result 'ORDER_PATH_MODIFIED' $false
Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
Add-Result 'BROKER_ORDER_ATTEMPTED' $false
Add-Result 'ORDER_TRANSPORT_CALLS' 0

$MutationStarted = $false
$Success = $false
$RollbackState = 'NOT_REQUIRED'

try {
    foreach ($RequiredPath in @(
        $Root,
        $FactBackups,
        $LiveDashboard,
        $LiveTemplate,
        $Database
    )) {
        if (-not (Test-Path -LiteralPath $RequiredPath)) {
            throw ('REQUIRED_PATH_MISSING:' + $RequiredPath)
        }
    }

    $ExactDashboard = Find-ExactBackup `
        -Folder $FactBackups `
        -Filter 'dashboard_*.py' `
        -ExpectedHash $ExpectedDashboardHash
    $ExactTemplate = Find-ExactBackup `
        -Folder $FactBackups `
        -Filter 'index_*.html' `
        -ExpectedHash $ExpectedTemplateHash

    $RuntimeBefore = @(Get-RuntimeProcesses).Count
    $RootBefore = Get-HttpProbe '/'
    $OrderBefore = Get-OrderLedgerCount

    Add-Result 'EXACT_V1_6_DASHBOARD_SOURCE' $ExactDashboard
    Add-Result 'EXACT_V1_6_TEMPLATE_SOURCE' $ExactTemplate
    Add-Result 'RUNTIME_PROCESS_COUNT_BEFORE' $RuntimeBefore
    Add-Result 'DASHBOARD_HTTP_BEFORE' $RootBefore.status
    Add-Result 'DASHBOARD_LATENCY_MS_BEFORE' $RootBefore.milliseconds
    Add-Result 'ORDER_LEDGER_COUNT_BEFORE' $OrderBefore

    if ($RuntimeBefore -ne 1) {
        throw 'BASELINE_RUNTIME_COUNT_NOT_ONE'
    }
    if ($OrderBefore -lt 0) {
        throw 'BASELINE_ORDER_LEDGER_UNREADABLE'
    }

    Add-Result 'PNL_REFRESH_TASK' (Disable-TaskSafe $RefreshTask)
    Add-Result 'PNL_CLOSE_TASK' (Disable-TaskSafe $CloseTask)

    [IO.File]::WriteAllBytes(
        $CurrentDashboardBackup,
        [IO.File]::ReadAllBytes($LiveDashboard)
    )
    [IO.File]::WriteAllBytes(
        $CurrentTemplateBackup,
        [IO.File]::ReadAllBytes($LiveTemplate)
    )

    Stop-CanonicalRuntime
    $MutationStarted = $true

    Set-AtomicFile -Target $LiveDashboard -Source $ExactDashboard
    Set-AtomicFile -Target $LiveTemplate -Source $ExactTemplate

    if ((Get-Sha256 $LiveDashboard) -ne $ExpectedDashboardHash) {
        throw 'RESTORED_DASHBOARD_HASH_MISMATCH'
    }
    if ((Get-Sha256 $LiveTemplate) -ne $ExpectedTemplateHash) {
        throw 'RESTORED_TEMPLATE_HASH_MISMATCH'
    }

    $PyCache = Join-Path $Root 'app\__pycache__'
    if (Test-Path -LiteralPath $PyCache) {
        Remove-Item -LiteralPath $PyCache -Recurse -Force -ErrorAction SilentlyContinue
    }

    $Python = Get-PythonPath
    $CompileOutput = @(& $Python -m py_compile $LiveDashboard 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ('RESTORED_DASHBOARD_COMPILE_FAILED:' + ($CompileOutput -join ' '))
    }

    Add-Result 'TOKEN_REUSE_GUARD_WAIT_SECONDS' 65
    Start-Sleep -Seconds 65
    Start-CanonicalRuntime

    $Deadline = (Get-Date).AddSeconds(60)
    $RootAfter = [ordered]@{status=0;milliseconds=0}
    $HealthAfter = [ordered]@{status=0;milliseconds=0}
    $SnapshotAfter = [ordered]@{status=0;milliseconds=0}

    while ((Get-Date) -lt $Deadline) {
        $RootAfter = Get-HttpProbe '/'
        $HealthAfter = Get-HttpProbe '/api/v1/health'
        $SnapshotAfter = Get-HttpProbe '/api/v1/snapshot'
        if (
            $RootAfter.status -eq 200 -and
            $HealthAfter.status -eq 200 -and
            $SnapshotAfter.status -eq 200
        ) {
            break
        }
        Start-Sleep -Seconds 2
    }

    $RuntimeAfter = @(Get-RuntimeProcesses).Count
    $OrderAfter = Get-OrderLedgerCount

    if ($RuntimeAfter -ne 1) {
        throw 'FINAL_RUNTIME_COUNT_NOT_ONE'
    }
    if ($RootAfter.status -ne 200) {
        throw 'FINAL_DASHBOARD_ROOT_NOT_200'
    }
    if ($HealthAfter.status -ne 200) {
        throw 'FINAL_DASHBOARD_HEALTH_NOT_200'
    }
    if ($SnapshotAfter.status -ne 200) {
        throw 'FINAL_DASHBOARD_SNAPSHOT_NOT_200'
    }
    if ($OrderAfter -ne $OrderBefore) {
        throw 'ORDER_LEDGER_COUNT_CHANGED'
    }

    Add-Result 'FINAL_RUNTIME_PROCESS_COUNT' $RuntimeAfter
    Add-Result 'FINAL_DASHBOARD_HTTP_ROOT' $RootAfter.status
    Add-Result 'FINAL_DASHBOARD_HTTP_HEALTH' $HealthAfter.status
    Add-Result 'FINAL_DASHBOARD_HTTP_SNAPSHOT' $SnapshotAfter.status
    Add-Result 'FINAL_DASHBOARD_LATENCY_MS_ROOT' $RootAfter.milliseconds
    Add-Result 'FINAL_DASHBOARD_LATENCY_MS_HEALTH' $HealthAfter.milliseconds
    Add-Result 'FINAL_DASHBOARD_LATENCY_MS_SNAPSHOT' $SnapshotAfter.milliseconds
    Add-Result 'FINAL_ORDER_LEDGER_COUNT' $OrderAfter
    Add-Result 'ORDER_LEDGER_COUNT_UNCHANGED' $true
    Add-Result 'FINAL_DASHBOARD_HASH' (Get-Sha256 $LiveDashboard)
    Add-Result 'FINAL_TEMPLATE_HASH' (Get-Sha256 $LiveTemplate)
    Add-Result 'V2_PNL_TASKS_PAUSED_FOR_STABILITY' $true
    Add-Result 'FINAL_STATUS' 'PASS_EXACT_V1_6_RESTORED_HASH_HTTP_200'
    $Success = $true
}
catch {
    Add-Result 'RESTORE_ERROR' $_.Exception.Message

    if ($MutationStarted) {
        $RollbackState = 'STARTED'
        try {
            Stop-CanonicalRuntime
            Set-AtomicFile -Target $LiveDashboard -Source $CurrentDashboardBackup
            Set-AtomicFile -Target $LiveTemplate -Source $CurrentTemplateBackup
            Start-Sleep -Seconds 65
            Start-CanonicalRuntime
            $RollbackState = 'COMPLETED'
        }
        catch {
            $RollbackState = 'FAILED'
            Add-Result 'ROLLBACK_ERROR' $_.Exception.Message
        }
    }

    Add-Result 'ROLLBACK_STATE' $RollbackState
    Add-Result 'FINAL_RUNTIME_PROCESS_COUNT' (@(Get-RuntimeProcesses).Count)
    $FinalProbe = Get-HttpProbe '/'
    Add-Result 'FINAL_DASHBOARD_HTTP_ROOT' $FinalProbe.status
    Add-Result 'FINAL_DASHBOARD_LATENCY_MS_ROOT' $FinalProbe.milliseconds
    try {
        Add-Result 'FINAL_ORDER_LEDGER_COUNT' (Get-OrderLedgerCount)
    }
    catch {
        Add-Result 'FINAL_ORDER_LEDGER_COUNT' 'READ_FAILED'
    }
    Add-Result 'FINAL_STATUS' 'FAIL_EXACT_V1_6_RESTORE_V2_REQUIRES_REVIEW'
}

Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Result 'ORDER_PATH_MODIFIED' $false
Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
Add-Result 'BROKER_ORDER_ATTEMPTED' $false
Add-Result 'ORDER_TRANSPORT_CALLS' 0
Add-Result 'PRE_RESTORE_DASHBOARD_BACKUP' $CurrentDashboardBackup
Add-Result 'PRE_RESTORE_TEMPLATE_BACKUP' $CurrentTemplateBackup
Add-Result 'FINAL_REPORT' $Report

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
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($Report, $OutputText, $Utf8Bom)

if (-not [string]::IsNullOrWhiteSpace($HandoffPath)) {
    [IO.File]::WriteAllText($HandoffPath, $OutputText, $Utf8Bom)
}

Write-Output $OutputText
if ($Success) {
    exit 0
}
exit 1
