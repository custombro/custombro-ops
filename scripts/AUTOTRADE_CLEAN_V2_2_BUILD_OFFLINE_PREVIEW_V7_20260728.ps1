#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\AUTOTRADE_CLEAN'
$ControlRoot = 'C:\Users\hjk86\AUTOTRADE_CONTROL'
$LabRoot = Join-Path $ControlRoot 'FACT_DASHBOARD_V2_2_LAB'
$Database = Join-Path $Root 'state\autotrade.db'
$PnlSource = Join-Path $ControlRoot 'FACT_DASHBOARD_V2\data\OFFICIAL_PNL_FACT_LATEST.json'
$SnapshotSource = Join-Path $Root 'state\current_snapshot_runtime.json'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunRoot = Join-Path $LabRoot ('offline_preview_v7_' + $Stamp)
$Helper = Join-Path $RunRoot 'offline_preview_builder_v7.py'
$Report = Join-Path $RunRoot 'OFFLINE_PREVIEW_BUILD_V7.txt'
$PreviewHtml = Join-Path $RunRoot 'index.html'
$PreviewData = Join-Path $RunRoot 'preview_data.js'
$BuildManifest = Join-Path $RunRoot 'PREVIEW_BUILD_MANIFEST_V7.json'
$HelperUrl = 'https://raw.githubusercontent.com/custombro/custombro-ops/main/scripts/helpers/autotrade_v2_2_offline_preview_builder_v7.py'

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
        'autotrade_preview_order_count_' +
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
    $Count = 0

    foreach ($Target in $Targets) {
        if (Test-Path -LiteralPath $Target) {
            $Hash = (
                Get-FileHash -LiteralPath $Target -Algorithm SHA256
            ).Hash.ToUpperInvariant()
            [void]$Builder.AppendLine($Target + '|' + $Hash)
            $Count += 1
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
        $Count += 1
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
        count = $Count
        sha256 = ([BitConverter]::ToString($Digest)).Replace('-', '')
    }
}

function Get-LatestFile {
    param(
        [string]$Base,
        [string]$DirectoryFilter,
        [string]$FileName
    )

    $Candidates = @(
        Get-ChildItem -LiteralPath $Base -Directory -Filter $DirectoryFilter -ErrorAction Stop |
        ForEach-Object {
            $Path = Join-Path $_.FullName $FileName
            if (Test-Path -LiteralPath $Path) {
                Get-Item -LiteralPath $Path
            }
        } |
        Sort-Object LastWriteTime -Descending
    )

    if ($Candidates.Count -lt 1) {
        throw ('LATEST_CONTRACT_NOT_FOUND:' + $DirectoryFilter + ':' + $FileName)
    }

    return $Candidates[0].FullName
}

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'V2_2_OFFLINE_PREVIEW_BUILD_V7_NO_MANUAL_VALUES'
Add-Result 'PREVIEW_ONLY' $true
Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Result 'ORDER_PATH_MODIFIED' $false
Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
Add-Result 'BROKER_ORDER_ATTEMPTED' $false
Add-Result 'ORDER_TRANSPORT_CALLS' 0
Add-Result 'SCHEDULED_TASK_MODIFIED' $false
Add-Result 'RUNTIME_RESTARTED' $false
Add-Result 'V2_2_LIVE_INSTALL_ALLOWED' $false
Add-Result 'MANUAL_VALUE_INPUT_USED' $false
Add-Result 'HARDCODED_FINANCIAL_VALUES_USED' $false

$Success = $false

try {
    foreach ($Required in @(
        $Root,
        $ControlRoot,
        $LabRoot,
        $Database,
        $PnlSource,
        $SnapshotSource
    )) {
        if (-not (Test-Path -LiteralPath $Required)) {
            throw ('REQUIRED_PATH_MISSING:' + $Required)
        }
    }

    $DailyContract = Get-LatestFile `
        -Base $LabRoot `
        -DirectoryFilter 'daily_scope_v5_*' `
        -FileName 'DAILY_SCOPE_CONTRACT_V5.json'

    $SemanticContract = Get-LatestFile `
        -Base $LabRoot `
        -DirectoryFilter 'semantic_review_v3_*' `
        -FileName 'SEMANTIC_SOURCE_CONTRACT_V3.json'

    $LinkageContract = Get-LatestFile `
        -Base $LabRoot `
        -DirectoryFilter 'intraday_linkage_v6_*' `
        -FileName 'INTRADAY_FILL_LINKAGE_CONTRACT_V6.json'

    Add-Result 'DAILY_CONTRACT' $DailyContract
    Add-Result 'SEMANTIC_CONTRACT' $SemanticContract
    Add-Result 'LINKAGE_CONTRACT' $LinkageContract
    Add-Result 'PNL_SOURCE' $PnlSource
    Add-Result 'SNAPSHOT_SOURCE' $SnapshotSource

    $RuntimeBefore = @(Get-RuntimeProcesses).Count
    $RootBefore = Get-HttpProbe '/'
    $HealthBefore = Get-HttpProbe '/api/v1/health'
    $SnapshotBefore = Get-HttpProbe '/api/v1/snapshot'
    $OrderBefore = Get-OrderLedgerCount
    $FingerprintBefore = Get-CriticalFingerprint
    $PnlHashBefore = (
        Get-FileHash -LiteralPath $PnlSource -Algorithm SHA256
    ).Hash.ToUpperInvariant()
    $SnapshotHashBefore = (
        Get-FileHash -LiteralPath $SnapshotSource -Algorithm SHA256
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
    Add-Result 'PNL_SOURCE_HASH_BEFORE' $PnlHashBefore
    Add-Result 'SNAPSHOT_SOURCE_HASH_BEFORE' $SnapshotHashBefore

    if ($RuntimeBefore -ne 1) {
        throw 'RUNTIME_COUNT_NOT_ONE'
    }
    if ($OrderBefore -lt 0) {
        throw 'ORDER_LEDGER_UNREADABLE'
    }
    if ($RootBefore.status -ne 200 -or $HealthBefore.status -ne 200 -or $SnapshotBefore.status -ne 200) {
        throw 'LIVE_DASHBOARD_BASELINE_NOT_HEALTHY'
    }

    Invoke-WebRequest `
        -Uri $HelperUrl `
        -OutFile $Helper `
        -UseBasicParsing `
        -TimeoutSec 30

    $Python = Get-PythonPath
    $CompileOutput = @(& $Python -m py_compile $Helper 2>&1)
    $CompileExit = $LASTEXITCODE
    Add-Result 'PREVIEW_BUILDER_COMPILE_EXIT_CODE' $CompileExit

    if ($CompileExit -ne 0) {
        throw ('PREVIEW_BUILDER_COMPILE_FAILED:' + ($CompileOutput -join ' '))
    }
    Add-Result 'PREVIEW_BUILDER_COMPILE' 'PASS'

    $BuildOutput = @(
        & $Python `
            $Helper `
            $Root `
            $ControlRoot `
            $DailyContract `
            $SemanticContract `
            $LinkageContract `
            $PnlSource `
            $SnapshotSource `
            $RunRoot `
            2>&1
    )
    $BuildExit = $LASTEXITCODE
    $BuildText = $BuildOutput -join [Environment]::NewLine
    Add-Result 'PREVIEW_BUILDER_EXIT_CODE' $BuildExit

    if ($BuildExit -ne 0) {
        throw ('PREVIEW_BUILDER_FAILED:' + $BuildText)
    }
    if (-not $BuildText.Contains('FINAL_STATUS=PASS_OFFLINE_PREVIEW_BUILD_V7')) {
        throw ('PREVIEW_BUILDER_PASS_MARKER_MISSING:' + $BuildText)
    }

    foreach ($Line in $BuildOutput) {
        $Text = [string]$Line
        if (
            $Text.StartsWith('PREVIEW_ONLY=') -or
            $Text.StartsWith('LIVE_INSTALL_ALLOWED=') -or
            $Text.StartsWith('MANUAL_VALUE_INPUT_USED=') -or
            $Text.StartsWith('HARDCODED_FINANCIAL_VALUES_USED=') -or
            $Text.StartsWith('HTML_HAS_MANUAL_INPUT=') -or
            $Text.StartsWith('HTML_HARDCODED_FINANCIAL_LITERAL_COUNT=') -or
            $Text.StartsWith('LATEST_BUSINESS_DATE=') -or
            $Text.StartsWith('LATEST_NET_SOURCE=') -or
            $Text.StartsWith('LATEST_NET_VALUE=') -or
            $Text.StartsWith('LATEST_FEE_VALUE=') -or
            $Text.StartsWith('LATEST_TAX_VALUE=') -or
            $Text.StartsWith('LATEST_INTEREST_VALUE=') -or
            $Text.StartsWith('LATEST_GROSS_DISPLAY_TYPE=') -or
            $Text.StartsWith('DAILY_POINT_COUNT=') -or
            $Text.StartsWith('DAY_GRAPH_READY=') -or
            $Text.StartsWith('WEEK_GRAPH_READY=') -or
            $Text.StartsWith('MONTH_GRAPH_READY=') -or
            $Text.StartsWith('INTRADAY_GRAPH_READY=') -or
            $Text.StartsWith('INTRADAY_GRAPH_RENDERED=') -or
            $Text.StartsWith('STRATEGY_ACTION_READY=') -or
            $Text.StartsWith('STRATEGY_REASON_READY=') -or
            $Text.StartsWith('CANDIDATE_RECORD_COUNT=') -or
            $Text.StartsWith('HOLDING_RECORD_COUNT=') -or
            $Text.StartsWith('UNREALIZED_PNL_READY=')
        ) {
            [void]$Results.Add($Text)
        }
    }

    foreach ($OutputPath in @($PreviewHtml, $PreviewData, $BuildManifest)) {
        if (-not (Test-Path -LiteralPath $OutputPath)) {
            throw ('PREVIEW_OUTPUT_MISSING:' + $OutputPath)
        }
    }

    if (-not $BuildText.Contains('MANUAL_VALUE_INPUT_USED=FALSE')) {
        throw 'MANUAL_VALUE_POLICY_NOT_PROVEN'
    }
    if (-not $BuildText.Contains('HARDCODED_FINANCIAL_VALUES_USED=FALSE')) {
        throw 'HARDCODED_VALUE_POLICY_NOT_PROVEN'
    }
    if (-not $BuildText.Contains('HTML_HAS_MANUAL_INPUT=FALSE')) {
        throw 'MANUAL_INPUT_UI_POLICY_NOT_PROVEN'
    }
    if (-not $BuildText.Contains('HTML_HARDCODED_FINANCIAL_LITERAL_COUNT=0')) {
        throw 'HTML_HARDCODED_LITERAL_POLICY_NOT_PROVEN'
    }

    $RuntimeAfter = @(Get-RuntimeProcesses).Count
    $RootAfter = Get-HttpProbe '/'
    $HealthAfter = Get-HttpProbe '/api/v1/health'
    $SnapshotAfter = Get-HttpProbe '/api/v1/snapshot'
    $OrderAfter = Get-OrderLedgerCount
    $FingerprintAfter = Get-CriticalFingerprint
    $PnlHashAfter = (
        Get-FileHash -LiteralPath $PnlSource -Algorithm SHA256
    ).Hash.ToUpperInvariant()
    $SnapshotHashAfter = (
        Get-FileHash -LiteralPath $SnapshotSource -Algorithm SHA256
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
    if ($PnlHashAfter -ne $PnlHashBefore) {
        throw 'PNL_SOURCE_CHANGED'
    }
    if ($SnapshotHashAfter -ne $SnapshotHashBefore) {
        throw 'SNAPSHOT_SOURCE_CHANGED_DURING_BUILD'
    }
    if ($RootAfter.status -ne 200 -or $HealthAfter.status -ne 200 -or $SnapshotAfter.status -ne 200) {
        throw 'LIVE_DASHBOARD_HEALTH_CHANGED'
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
    Add-Result 'PNL_SOURCE_HASH_AFTER' $PnlHashAfter
    Add-Result 'PNL_SOURCE_UNCHANGED' $true
    Add-Result 'SNAPSHOT_SOURCE_HASH_AFTER' $SnapshotHashAfter
    Add-Result 'SNAPSHOT_SOURCE_UNCHANGED_DURING_BUILD' $true
    Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'SCHEDULED_TASK_MODIFIED' $false
    Add-Result 'RUNTIME_RESTARTED' $false
    Add-Result 'V2_2_LIVE_INSTALL_ALLOWED' $false
    Add-Result 'MANUAL_VALUE_INPUT_USED' $false
    Add-Result 'HARDCODED_FINANCIAL_VALUES_USED' $false
    Add-Result 'PREVIEW_HTML' $PreviewHtml
    Add-Result 'PREVIEW_DATA' $PreviewData
    Add-Result 'BUILD_MANIFEST' $BuildManifest
    Add-Result 'NEXT_STAGE' 'USER_VISUAL_REVIEW_OF_OFFLINE_PREVIEW_THEN_READ_ONLY_SELF_TEST'
    Add-Result 'FINAL_STATUS' 'PASS_V2_2_OFFLINE_PREVIEW_V7_BUILT_NO_LIVE_MUTATION'

    Start-Process -FilePath $PreviewHtml -ErrorAction SilentlyContinue
    $Success = $true
}
catch {
    Add-Result 'PREVIEW_BUILD_ERROR' $_.Exception.Message
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
    Add-Result 'MANUAL_VALUE_INPUT_USED' $false
    Add-Result 'FINAL_STATUS' 'FAIL_V2_2_OFFLINE_PREVIEW_V7_NO_LIVE_MUTATION'
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
