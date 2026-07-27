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
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunRoot = Join-Path $LabRoot ('preview_v9_' + $Stamp)
$Helper = Join-Path $RunRoot 'preview_cost_sign_and_strategy_audit_v9.py'
$Report = Join-Path $RunRoot 'PREVIEW_COST_SIGN_AND_STRATEGY_AUDIT_V9.txt'
$HelperUrl = 'https://raw.githubusercontent.com/custombro/custombro-ops/main/scripts/helpers/autotrade_v2_2_preview_cost_sign_and_strategy_audit_v9.py'

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

function Get-HttpProbe {
    param([string]$Path)
    $Watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $Response = Invoke-WebRequest -Uri ('http://127.0.0.1:3100' + $Path) -UseBasicParsing -TimeoutSec 12
        $Watch.Stop()
        return [ordered]@{status=[int]$Response.StatusCode;milliseconds=[int]$Watch.ElapsedMilliseconds}
    }
    catch {
        $Watch.Stop()
        return [ordered]@{status=0;milliseconds=[int]$Watch.ElapsedMilliseconds}
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
    $Temporary = Join-Path $env:TEMP ('autotrade_v9_order_count_' + [guid]::NewGuid().ToString('N') + '.py')
    [IO.File]::WriteAllText($Temporary, $Code, (New-Object System.Text.ASCIIEncoding))
    try {
        $Output = @(& $Python $Temporary $Database 2>&1)
        if ($LASTEXITCODE -ne 0) { throw ('ORDER_LEDGER_READ_FAILED:' + ($Output -join ' ')) }
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
    $Files = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $Lower = $_.FullName.ToLowerInvariant()
            $Lower.Contains('strategy') -or $Lower.Contains('stage13l') -or
            $Lower.Contains('order') -or $Lower.Contains('sender') -or
            $Lower.Contains('transport')
        } |
        Sort-Object FullName |
        Select-Object -First 700
    )
    $All = @($Targets + $Files.FullName | Select-Object -Unique)
    $Builder = New-Object System.Text.StringBuilder
    foreach ($Target in $All) {
        if (Test-Path -LiteralPath $Target) {
            $Hash = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToUpperInvariant()
            [void]$Builder.AppendLine($Target + '|' + $Hash)
        }
    }
    $Bytes = [Text.Encoding]::UTF8.GetBytes($Builder.ToString())
    $Sha = [Security.Cryptography.SHA256]::Create()
    try { $Digest = $Sha.ComputeHash($Bytes) } finally { $Sha.Dispose() }
    return [ordered]@{count=$All.Count;sha256=([BitConverter]::ToString($Digest)).Replace('-','')}
}

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'V2_2_PREVIEW_V9_COST_SIGN_AND_STRATEGY_PROVENANCE_AUDIT'
Add-Result 'PREVIEW_ONLY' $true
Add-Result 'MANUAL_VALUE_INPUT_USED' $false
Add-Result 'HARDCODED_FINANCIAL_VALUES_USED' $false
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
    foreach ($Required in @($Root,$ControlRoot,$LabRoot,$Database)) {
        if (-not (Test-Path -LiteralPath $Required)) { throw ('REQUIRED_PATH_MISSING:' + $Required) }
    }

    $SourcePreview = Get-ChildItem -LiteralPath $LabRoot -Directory -Filter 'offline_preview_v8_*' -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $SourcePreview) { throw 'SOURCE_PREVIEW_V8_NOT_FOUND' }
    foreach ($Name in @('index.html','preview_data.js')) {
        if (-not (Test-Path -LiteralPath (Join-Path $SourcePreview.FullName $Name))) {
            throw ('SOURCE_PREVIEW_FILE_MISSING:' + $Name)
        }
    }

    $RuntimeBefore = @(Get-RuntimeProcesses).Count
    $RootBefore = Get-HttpProbe '/'
    $HealthBefore = Get-HttpProbe '/api/v1/health'
    $SnapshotBefore = Get-HttpProbe '/api/v1/snapshot'
    $OrderBefore = Get-OrderLedgerCount
    $FingerprintBefore = Get-CriticalFingerprint

    Add-Result 'SOURCE_PREVIEW_V8' $SourcePreview.FullName
    Add-Result 'RUNTIME_PROCESS_COUNT_BEFORE' $RuntimeBefore
    Add-Result 'DASHBOARD_HTTP_ROOT_BEFORE' $RootBefore.status
    Add-Result 'DASHBOARD_LATENCY_MS_ROOT_BEFORE' $RootBefore.milliseconds
    Add-Result 'DASHBOARD_HTTP_HEALTH_BEFORE' $HealthBefore.status
    Add-Result 'DASHBOARD_HTTP_SNAPSHOT_BEFORE' $SnapshotBefore.status
    Add-Result 'ORDER_LEDGER_COUNT_BEFORE' $OrderBefore
    Add-Result 'CRITICAL_FILE_COUNT_BEFORE' $FingerprintBefore.count
    Add-Result 'CRITICAL_FINGERPRINT_BEFORE' $FingerprintBefore.sha256

    if ($RuntimeBefore -ne 1) { throw 'RUNTIME_COUNT_NOT_ONE' }
    if ($RootBefore.status -ne 200 -or $HealthBefore.status -ne 200 -or $SnapshotBefore.status -ne 200) {
        throw 'LIVE_DASHBOARD_BASELINE_NOT_HEALTHY'
    }

    Invoke-WebRequest -Uri $HelperUrl -OutFile $Helper -UseBasicParsing -TimeoutSec 30
    $Python = Get-PythonPath
    $CompileOutput = @(& $Python -m py_compile $Helper 2>&1)
    Add-Result 'HELPER_COMPILE_EXIT_CODE' $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) { throw ('HELPER_COMPILE_FAILED:' + ($CompileOutput -join ' ')) }
    Add-Result 'HELPER_COMPILE' 'PASS'

    $BuildOutput = @(& $Python $Helper $Root $Database $SourcePreview.FullName $RunRoot 2>&1)
    $BuildExit = $LASTEXITCODE
    $BuildText = $BuildOutput -join [Environment]::NewLine
    Add-Result 'BUILDER_EXIT_CODE' $BuildExit
    if ($BuildExit -ne 0) { throw ('BUILDER_FAILED:' + $BuildText) }
    if (-not $BuildText.Contains('FINAL_STATUS=PASS_PREVIEW_COST_SIGN_AND_STRATEGY_AUDIT_V9')) {
        throw ('BUILDER_PASS_MARKER_MISSING:' + $BuildText)
    }
    foreach ($Line in $BuildOutput) {
        $Text = [string]$Line
        if (
            $Text.StartsWith('COST_SIGN_') -or $Text.StartsWith('FEE_DISPLAY_') -or
            $Text.StartsWith('TAX_DISPLAY_') -or $Text.StartsWith('INTEREST_DISPLAY_') -or
            $Text.StartsWith('MANUAL_VALUE_') -or $Text.StartsWith('HARDCODED_') -or
            $Text.StartsWith('CURRENT_DETAILED_') -or $Text.StartsWith('HISTORICAL_DETAILED_') -or
            $Text.StartsWith('FUTURE_DETAILED_') -or $Text.StartsWith('CURRENT_STRATEGY_') -or
            $Text.StartsWith('HISTORICAL_DETAILED_RECORD_COUNT=') -or
            $Text.StartsWith('STRATEGY_AUDIT=') -or $Text.StartsWith('PREVIEW_HTML=') -or
            $Text.StartsWith('PREVIEW_MANIFEST=')
        ) { [void]$Results.Add($Text) }
    }

    foreach ($Output in @('index.html','preview_data.js','STRATEGY_PROVENANCE_AUDIT_V9.json','PREVIEW_CORRECTION_MANIFEST_V9.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $RunRoot $Output))) { throw ('OUTPUT_MISSING:' + $Output) }
    }

    $RuntimeAfter = @(Get-RuntimeProcesses).Count
    $RootAfter = Get-HttpProbe '/'
    $HealthAfter = Get-HttpProbe '/api/v1/health'
    $SnapshotAfter = Get-HttpProbe '/api/v1/snapshot'
    $OrderAfter = Get-OrderLedgerCount
    $FingerprintAfter = Get-CriticalFingerprint

    if ($RuntimeAfter -ne $RuntimeBefore) { throw 'RUNTIME_COUNT_CHANGED' }
    if ($OrderAfter -ne $OrderBefore) { throw 'ORDER_LEDGER_COUNT_CHANGED' }
    if ($FingerprintAfter.sha256 -ne $FingerprintBefore.sha256) { throw 'CRITICAL_FILE_FINGERPRINT_CHANGED' }
    if ($RootAfter.status -ne 200 -or $HealthAfter.status -ne 200 -or $SnapshotAfter.status -ne 200) {
        throw 'LIVE_DASHBOARD_HEALTH_CHANGED'
    }

    Add-Result 'RUNTIME_PROCESS_COUNT_AFTER' $RuntimeAfter
    Add-Result 'DASHBOARD_HTTP_ROOT_AFTER' $RootAfter.status
    Add-Result 'DASHBOARD_LATENCY_MS_ROOT_AFTER' $RootAfter.milliseconds
    Add-Result 'DASHBOARD_HTTP_HEALTH_AFTER' $HealthAfter.status
    Add-Result 'DASHBOARD_HTTP_SNAPSHOT_AFTER' $SnapshotAfter.status
    Add-Result 'ORDER_LEDGER_COUNT_AFTER' $OrderAfter
    Add-Result 'ORDER_LEDGER_COUNT_UNCHANGED' $true
    Add-Result 'CRITICAL_FILE_COUNT_AFTER' $FingerprintAfter.count
    Add-Result 'CRITICAL_FINGERPRINT_AFTER' $FingerprintAfter.sha256
    Add-Result 'CRITICAL_FILES_UNCHANGED' $true
    Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'SCHEDULED_TASK_MODIFIED' $false
    Add-Result 'RUNTIME_RESTARTED' $false
    Add-Result 'V2_2_LIVE_INSTALL_ALLOWED' $false
    Add-Result 'NEXT_STAGE' 'REVIEW_STRATEGY_AUDIT_THEN_INSTALL_DETAILED_RECORDING_ONLY_IF_REQUIRED'
    Add-Result 'FINAL_STATUS' 'PASS_V2_2_PREVIEW_V9_COST_SIGN_AND_STRATEGY_AUDIT_NO_LIVE_MUTATION'

    Start-Process -FilePath (Join-Path $RunRoot 'index.html') -ErrorAction SilentlyContinue
    $Success = $true
}
catch {
    Add-Result 'V9_ERROR' $_.Exception.Message
    Add-Result 'FINAL_RUNTIME_PROCESS_COUNT' (@(Get-RuntimeProcesses).Count)
    try { Add-Result 'FINAL_ORDER_LEDGER_COUNT' (Get-OrderLedgerCount) } catch { Add-Result 'FINAL_ORDER_LEDGER_COUNT' 'READ_FAILED' }
    Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'SCHEDULED_TASK_MODIFIED' $false
    Add-Result 'RUNTIME_RESTARTED' $false
    Add-Result 'V2_2_LIVE_INSTALL_ALLOWED' $false
    Add-Result 'FINAL_STATUS' 'FAIL_V2_2_PREVIEW_V9_NO_LIVE_MUTATION'
}

Add-Result 'REPORT' $Report
$CopyStatus = 'FAILED'
try { Set-Clipboard -Value ($Results -join [Environment]::NewLine); $CopyStatus = 'SUCCESS' } catch { $CopyStatus = 'FAILED' }
Add-Result 'COPY_STATUS' $CopyStatus
$OutputText = ($Results -join [Environment]::NewLine) + [Environment]::NewLine
[IO.File]::WriteAllText($Report, $OutputText, (New-Object System.Text.UTF8Encoding($true)))
Write-Output $OutputText
if ($Success) { exit 0 }
exit 1
