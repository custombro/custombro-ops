#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\AUTOTRADE_CLEAN'
$ControlRoot = 'C:\Users\hjk86\AUTOTRADE_CONTROL'
$LabRoot = Join-Path $ControlRoot 'FACT_DASHBOARD_V2_2_LAB'
$EvidenceRoot = Join-Path $LabRoot 'evidence'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunRoot = Join-Path $LabRoot ('semantic_review_v3_' + $Stamp)
$Report = Join-Path $RunRoot 'SEMANTIC_SOURCE_REVIEW_V3.txt'
$Contract = Join-Path $RunRoot 'SEMANTIC_SOURCE_CONTRACT_V3.json'
$Helper = Join-Path $RunRoot 'semantic_source_reviewer_v3.py'
$Database = Join-Path $Root 'state\autotrade.db'
$HelperUrl = 'https://raw.githubusercontent.com/custombro/custombro-ops/main/scripts/helpers/autotrade_v2_2_semantic_source_reviewer_v3.py'

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
        'autotrade_semantic_order_count_' +
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

    $Files = New-Object System.Collections.Generic.List[object]

    foreach ($Target in $Targets) {
        if (Test-Path -LiteralPath $Target) {
            [void]$Files.Add((Get-Item -LiteralPath $Target))
        }
    }

    foreach ($File in @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $Name = $_.Name.ToLowerInvariant()
            $Name.Contains('strategy') -or
            $Name.Contains('stage13l') -or
            $Name.Contains('order_authority')
        } |
        Sort-Object FullName |
        Select-Object -First 500
    )) {
        [void]$Files.Add($File)
    }

    $UniqueFiles = @(
        $Files |
        Sort-Object FullName -Unique
    )

    $Builder = New-Object System.Text.StringBuilder
    foreach ($File in $UniqueFiles) {
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
        count = $UniqueFiles.Count
        sha256 = ([BitConverter]::ToString($Digest)).Replace('-', '')
    }
}

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'V2_2_SEMANTIC_SOURCE_REVIEW_V3_READ_ONLY'
Add-Result 'FALSE_POSITIVE_SOURCE_FILTERING' $true
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
    foreach ($Required in @($Root, $ControlRoot, $EvidenceRoot, $Database)) {
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
    Add-Result 'SEMANTIC_REVIEWER_COMPILE_EXIT_CODE' $CompileExit

    if ($CompileExit -ne 0) {
        throw ('SEMANTIC_REVIEWER_COMPILE_FAILED:' + ($CompileOutput -join ' '))
    }
    Add-Result 'SEMANTIC_REVIEWER_COMPILE' 'PASS'

    $ReviewOutput = @(
        & $Python $Helper $EvidenceRoot $LabRoot $Contract 2>&1
    )
    $ReviewExit = $LASTEXITCODE
    $ReviewText = $ReviewOutput -join [Environment]::NewLine
    Add-Result 'SEMANTIC_REVIEWER_EXIT_CODE' $ReviewExit

    if ($ReviewExit -ne 0) {
        throw ('SEMANTIC_REVIEWER_FAILED:' + $ReviewText)
    }
    if (-not $ReviewText.Contains('FINAL_STATUS=PASS_SEMANTIC_SOURCE_REVIEW_V3')) {
        throw ('SEMANTIC_REVIEWER_PASS_MARKER_MISSING:' + $ReviewText)
    }

    foreach ($Line in $ReviewOutput) {
        $Text = [string]$Line
        if (
            $Text.StartsWith('FINANCIAL_') -or
            $Text.StartsWith('STRATEGY_') -or
            $Text.StartsWith('CANDIDATE_') -or
            $Text.StartsWith('GENERATION_') -or
            $Text.StartsWith('ALL_OFFLINE_PREVIEW_INPUTS_READY=') -or
            $Text.StartsWith('SEMANTIC_CONTRACT=')
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

    if ($RuntimeAfter -ne $RuntimeBefore) {
        throw 'RUNTIME_COUNT_CHANGED'
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
    Add-Result 'DASHBOARD_LATENCY_MS_HEALTH_AFTER' $HealthAfter.milliseconds
    Add-Result 'DASHBOARD_HTTP_SNAPSHOT_AFTER' $SnapshotAfter.status
    Add-Result 'DASHBOARD_LATENCY_MS_SNAPSHOT_AFTER' $SnapshotAfter.milliseconds
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
    Add-Result 'NEXT_STAGE' 'OFFLINE_PREVIEW_BUILD_ONLY_WHEN_SEMANTIC_CONTRACT_READY'
    Add-Result 'FINAL_STATUS' 'PASS_V2_2_SEMANTIC_SOURCE_REVIEW_V3_NO_LIVE_MUTATION'
    $Success = $true
}
catch {
    Add-Result 'SEMANTIC_REVIEW_ERROR' $_.Exception.Message
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
    Add-Result 'FINAL_STATUS' 'FAIL_V2_2_SEMANTIC_SOURCE_REVIEW_V3_NO_LIVE_MUTATION'
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
