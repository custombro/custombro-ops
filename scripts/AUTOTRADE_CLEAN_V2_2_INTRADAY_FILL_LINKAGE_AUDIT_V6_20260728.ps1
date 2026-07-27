#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\AUTOTRADE_CLEAN'
$ControlRoot = 'C:\Users\hjk86\AUTOTRADE_CONTROL'
$LabRoot = Join-Path $ControlRoot 'FACT_DASHBOARD_V2_2_LAB'
$Source = Join-Path $ControlRoot 'FACT_DASHBOARD_V2\data\OFFICIAL_PNL_FACT_LATEST.json'
$Database = Join-Path $Root 'state\autotrade.db'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunRoot = Join-Path $LabRoot ('intraday_linkage_v6_' + $Stamp)
$Report = Join-Path $RunRoot 'INTRADAY_FILL_LINKAGE_AUDIT_V6.txt'
$Contract = Join-Path $RunRoot 'INTRADAY_FILL_LINKAGE_CONTRACT_V6.json'
$Helper = Join-Path $RunRoot 'intraday_fill_linkage_auditor_v6.py'
$HelperUrl = 'https://raw.githubusercontent.com/custombro/custombro-ops/main/scripts/helpers/autotrade_v2_2_intraday_fill_linkage_auditor_v6.py'

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
        'autotrade_intraday_linkage_order_count_' +
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
    $Targets = @(
        (Join-Path $Root 'app\dashboard.py'),
        (Join-Path $Root 'web\index.html'),
        (Join-Path $Root 'app\stage12_runtime_bootstrap.py')
    )

    $Builder = New-Object System.Text.StringBuilder

    foreach ($Target in $Targets) {
        if (Test-Path -LiteralPath $Target) {
            $Hash = (
                Get-FileHash -LiteralPath $Target -Algorithm SHA256
            ).Hash.ToUpperInvariant()
            [void]$Builder.AppendLine($Target + '|' + $Hash)
        }
    }

    $StrategyFiles = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $Name = $_.Name.ToLowerInvariant()
            $Name.Contains('strategy') -or
            $Name.Contains('stage13l') -or
            $Name.Contains('order_authority')
        } |
        Sort-Object FullName |
        Select-Object -First 500
    )

    foreach ($File in $StrategyFiles) {
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
        count = $Targets.Count + $StrategyFiles.Count
        sha256 = ([BitConverter]::ToString($Digest)).Replace('-', '')
    }
}

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'V2_2_INTRADAY_FILL_LINKAGE_AUDIT_V6_READ_ONLY'
Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Result 'ORDER_PATH_MODIFIED' $false
Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
Add-Result 'BROKER_ORDER_ATTEMPTED' $false
Add-Result 'ORDER_TRANSPORT_CALLS' 0
Add-Result 'SCHEDULED_TASK_MODIFIED' $false
Add-Result 'RUNTIME_RESTARTED' $false
Add-Result 'V2_2_LIVE_INSTALL_ALLOWED' $false

$Success = $false

try {
    foreach ($Required in @($Root, $ControlRoot, $LabRoot, $Source, $Database)) {
        if (-not (Test-Path -LiteralPath $Required)) {
            throw ('REQUIRED_PATH_MISSING:' + $Required)
        }
    }

    $RuntimeBefore = @(Get-RuntimeProcesses).Count
    $RootBefore = Get-HttpProbe '/'
    $HealthBefore = Get-HttpProbe '/api/v1/health'
    $SnapshotBefore = Get-HttpProbe '/api/v1/snapshot'
    $OrderBefore = Get-OrderLedgerCount
    $FingerprintBefore = Get-CriticalFingerprint
    $SourceHashBefore = (
        Get-FileHash -LiteralPath $Source -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    Add-Result 'RUNTIME_PROCESS_COUNT_BEFORE' $RuntimeBefore
    Add-Result 'DASHBOARD_HTTP_ROOT_BEFORE' $RootBefore.status
    Add-Result 'DASHBOARD_LATENCY_MS_ROOT_BEFORE' $RootBefore.milliseconds
    Add-Result 'DASHBOARD_HTTP_HEALTH_BEFORE' $HealthBefore.status
    Add-Result 'DASHBOARD_LATENCY_MS_HEALTH_BEFORE' $HealthBefore.milliseconds
    Add-Result 'DASHBOARD_HTTP_SNAPSHOT_BEFORE' $SnapshotBefore.status
    Add-Result 'DASHBOARD_LATENCY_MS_SNAPSHOT_BEFORE' $SnapshotBefore.milliseconds
    Add-Result 'ORDER_LEDGER_COUNT_BEFORE' $OrderBefore
    Add-Result 'CRITICAL_FILE_COUNT_BEFORE' $FingerprintBefore.count
    Add-Result 'CRITICAL_FINGERPRINT_BEFORE' $FingerprintBefore.sha256
    Add-Result 'OFFICIAL_PNL_SOURCE_HASH_BEFORE' $SourceHashBefore

    if ($RuntimeBefore -ne 1) {
        throw 'RUNTIME_COUNT_NOT_ONE'
    }
    if ($OrderBefore -lt 0) {
        throw 'ORDER_LEDGER_UNREADABLE'
    }

    Invoke-WebRequest `
        -Uri $HelperUrl `
        -OutFile $Helper `
        -UseBasicParsing `
        -TimeoutSec 30

    $Python = Get-PythonPath
    $CompileOutput = @(& $Python -m py_compile $Helper 2>&1)
    $CompileExit = $LASTEXITCODE
    Add-Result 'LINKAGE_AUDITOR_COMPILE_EXIT_CODE' $CompileExit

    if ($CompileExit -ne 0) {
        throw ('LINKAGE_AUDITOR_COMPILE_FAILED:' + ($CompileOutput -join ' '))
    }
    Add-Result 'LINKAGE_AUDITOR_COMPILE' 'PASS'

    $AuditOutput = @(
        & $Python $Helper $Root $ControlRoot $Database $Source $Contract 2>&1
    )
    $AuditExit = $LASTEXITCODE
    $AuditText = $AuditOutput -join [Environment]::NewLine
    Add-Result 'LINKAGE_AUDITOR_EXIT_CODE' $AuditExit

    if ($AuditExit -ne 0) {
        throw ('LINKAGE_AUDITOR_FAILED:' + $AuditText)
    }
    if (-not $AuditText.Contains('FINAL_STATUS=PASS_INTRADAY_FILL_LINKAGE_AUDIT_V6')) {
        throw ('LINKAGE_AUDITOR_PASS_MARKER_MISSING:' + $AuditText)
    }

    foreach ($Line in $AuditOutput) {
        $Text = [string]$Line
        if (
            $Text.StartsWith('LATEST_BUSINESS_DATE=') -or
            $Text.StartsWith('LATEST_DATE_TRADE_ROW_COUNT=') -or
            $Text.StartsWith('RAW_SQLITE_TIMESTAMP_RECORD_COUNT=') -or
            $Text.StartsWith('RAW_JSON_TIMESTAMP_RECORD_COUNT=') -or
            $Text.StartsWith('DEDUPLICATED_TIMESTAMP_RECORD_COUNT=') -or
            $Text.StartsWith('LATEST_DATE_TIMESTAMP_RECORD_COUNT=') -or
            $Text.StartsWith('ORDER_ID_EXACT_LINK_COUNT=') -or
            $Text.StartsWith('QTY_PRICE_EXACT_LINK_COUNT=') -or
            $Text.StartsWith('UNIQUE_SYMBOL_DATE_TIMESTAMP_LINK_COUNT=') -or
            $Text.StartsWith('AMBIGUOUS_LINK_COUNT=') -or
            $Text.StartsWith('UNLINKED_TRADE_ROW_COUNT=') -or
            $Text.StartsWith('MISSING_SYMBOL_ROW_COUNT=') -or
            $Text.StartsWith('INTRADAY_GRAPH_READY=') -or
            $Text.StartsWith('DAILY_WEEK_MONTH_GRAPH_READY=') -or
            $Text.StartsWith('LINKAGE_CONTRACT=')
        ) {
            [void]$Results.Add($Text)
        }
    }

    $RuntimeAfter = @(Get-RuntimeProcesses).Count
    $RootAfter = Get-HttpProbe '/'
    $HealthAfter = Get-HttpProbe '/api/v1/health'
    $SnapshotAfter = Get-HttpProbe '/api/v1/snapshot'
    $OrderAfter = Get-OrderLedgerCount
    $FingerprintAfter = Get-CriticalFingerprint
    $SourceHashAfter = (
        Get-FileHash -LiteralPath $Source -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($RuntimeAfter -ne $RuntimeBefore) {
        throw 'RUNTIME_COUNT_CHANGED'
    }
    if ($OrderAfter -ne $OrderBefore) {
        throw 'ORDER_LEDGER_COUNT_CHANGED'
    }
    if ($FingerprintAfter.sha256 -ne $FingerprintBefore.sha256) {
        throw 'CRITICAL_FILE_FINGERPRINT_CHANGED'
    }
    if ($SourceHashAfter -ne $SourceHashBefore) {
        throw 'OFFICIAL_PNL_SOURCE_CHANGED'
    }

    Add-Result 'RUNTIME_PROCESS_COUNT_AFTER' $RuntimeAfter
    Add-Result 'DASHBOARD_HTTP_ROOT_AFTER' $RootAfter.status
    Add-Result 'DASHBOARD_LATENCY_MS_ROOT_AFTER' $RootAfter.milliseconds
    Add-Result 'DASHBOARD_HTTP_HEALTH_AFTER' $HealthAfter.status
    Add-Result 'DASHBOARD_LATENCY_MS_HEALTH_AFTER' $HealthAfter.milliseconds
    Add-Result 'DASHBOARD_HTTP_SNAPSHOT_AFTER' $SnapshotAfter.status
    Add-Result 'DASHBOARD_LATENCY_MS_SNAPSHOT_AFTER' $SnapshotAfter.milliseconds
    Add-Result 'ORDER_LEDGER_COUNT_AFTER' $OrderAfter
    Add-Result 'ORDER_LEDGER_COUNT_UNCHANGED' $true
    Add-Result 'CRITICAL_FILE_COUNT_AFTER' $FingerprintAfter.count
    Add-Result 'CRITICAL_FINGERPRINT_AFTER' $FingerprintAfter.sha256
    Add-Result 'CRITICAL_FILES_UNCHANGED' $true
    Add-Result 'OFFICIAL_PNL_SOURCE_HASH_AFTER' $SourceHashAfter
    Add-Result 'OFFICIAL_PNL_SOURCE_UNCHANGED' $true
    Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'SCHEDULED_TASK_MODIFIED' $false
    Add-Result 'RUNTIME_RESTARTED' $false
    Add-Result 'V2_2_LIVE_INSTALL_ALLOWED' $false
    Add-Result 'NEXT_STAGE' 'BUILD_OFFLINE_V2_2_PREVIEW_WITH_INTRADAY_ONLY_IF_LINKAGE_READY'
    Add-Result 'FINAL_STATUS' 'PASS_V2_2_INTRADAY_FILL_LINKAGE_AUDIT_V6_NO_LIVE_MUTATION'
    $Success = $true
}
catch {
    Add-Result 'LINKAGE_AUDIT_ERROR' $_.Exception.Message
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
    Add-Result 'SCHEDULED_TASK_MODIFIED' $false
    Add-Result 'RUNTIME_RESTARTED' $false
    Add-Result 'V2_2_LIVE_INSTALL_ALLOWED' $false
    Add-Result 'FINAL_STATUS' 'FAIL_V2_2_INTRADAY_FILL_LINKAGE_AUDIT_V6_NO_LIVE_MUTATION'
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
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($Report, $OutputText, $Utf8Bom)
Write-Output $OutputText

if ($Success) {
    exit 0
}
exit 1
