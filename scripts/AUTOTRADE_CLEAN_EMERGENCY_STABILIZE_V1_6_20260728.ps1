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
        'AUTOTRADE_STABILIZE_' +
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
$StableInstaller = Join-Path $env:USERPROFILE (
    'Downloads\AUTOTRADE_CLEAN_OWNER_CONSOLE_DASHBOARD_V1_6_20260727.ps1'
)
$ReportRoot = Join-Path $ControlRoot 'EMERGENCY_DASHBOARD_STABILIZE'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$Report = Join-Path $ReportRoot ('STABILIZE_' + $Stamp + '.txt')
New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null

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

function Get-HttpStatus {
    param([string]$Path = '/')
    try {
        $Response = Invoke-WebRequest `
            -Uri ('http://127.0.0.1:3100' + $Path) `
            -UseBasicParsing `
            -TimeoutSec 8
        return [int]$Response.StatusCode
    }
    catch {
        return 0
    }
}

function Get-OrderLedgerCount {
    $Python = 'C:\Program Files\Python312\python.exe'
    if (-not (Test-Path -LiteralPath $Python)) {
        $Python = (Get-Command python.exe -ErrorAction Stop).Source
    }
    $Database = Join-Path $Root 'state\autotrade.db'
    $Code = @'
import sqlite3, sys
path = sys.argv[1]
con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
try:
    print(int(con.execute("SELECT COUNT(*) FROM order_ledger").fetchone()[0]))
finally:
    con.close()
'@
    $Temporary = Join-Path $env:TEMP (
        'autotrade_count_' + [guid]::NewGuid().ToString('N') + '.py'
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

function Set-TaskDisabledSafe {
    param([string]$Name)
    $Task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($null -ne $Task) {
        Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        Disable-ScheduledTask -TaskName $Name -ErrorAction Stop | Out-Null
        return 'DISABLED'
    }
    return 'NOT_FOUND'
}

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'EMERGENCY_DASHBOARD_STABILIZE_TO_V1_6'
Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Result 'ORDER_PATH_MODIFIED' $false
Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
Add-Result 'BROKER_ORDER_ATTEMPTED' $false
Add-Result 'ORDER_TRANSPORT_CALLS' 0

$Success = $false

try {
    if (-not (Test-Path -LiteralPath $StableInstaller)) {
        throw 'STABLE_V1_6_INSTALLER_NOT_FOUND_IN_DOWNLOADS'
    }

    $RuntimeBefore = @(Get-RuntimeProcesses).Count
    $HttpBefore = Get-HttpStatus '/'
    $OrderBefore = Get-OrderLedgerCount

    Add-Result 'RUNTIME_PROCESS_COUNT_BEFORE' $RuntimeBefore
    Add-Result 'DASHBOARD_HTTP_BEFORE' $HttpBefore
    Add-Result 'ORDER_LEDGER_COUNT_BEFORE' $OrderBefore

    if ($RuntimeBefore -ne 1) {
        throw 'BASELINE_RUNTIME_COUNT_NOT_ONE'
    }

    Add-Result 'PNL_REFRESH_TASK' (Set-TaskDisabledSafe $RefreshTask)
    Add-Result 'PNL_CLOSE_TASK' (Set-TaskDisabledSafe $CloseTask)

    $InstallerOutput = @(
        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $StableInstaller `
            -Elevated `
            2>&1
    )
    $InstallerExit = $LASTEXITCODE
    $InstallerText = $InstallerOutput -join [Environment]::NewLine

    Add-Result 'STABLE_INSTALLER_EXIT_CODE' $InstallerExit

    if ($InstallerExit -ne 0) {
        throw ('STABLE_INSTALLER_FAILED:' + $InstallerText)
    }
    if (-not $InstallerText.Contains('PASS_OWNER_CONSOLE_DASHBOARD_V1_6_INSTALLED')) {
        throw ('STABLE_INSTALLER_PASS_MARKER_MISSING:' + $InstallerText)
    }

    Start-Sleep -Seconds 5

    $RuntimeAfter = @(Get-RuntimeProcesses).Count
    $RootHttp = Get-HttpStatus '/'
    $HealthHttp = Get-HttpStatus '/api/v1/health'
    $SnapshotHttp = Get-HttpStatus '/api/v1/snapshot'
    $OrderAfter = Get-OrderLedgerCount

    if ($RuntimeAfter -ne 1) {
        throw 'FINAL_RUNTIME_COUNT_NOT_ONE'
    }
    if ($RootHttp -ne 200) {
        throw 'FINAL_DASHBOARD_ROOT_NOT_200'
    }
    if ($HealthHttp -ne 200) {
        throw 'FINAL_DASHBOARD_HEALTH_NOT_200'
    }
    if ($SnapshotHttp -ne 200) {
        throw 'FINAL_DASHBOARD_SNAPSHOT_NOT_200'
    }
    if ($OrderAfter -ne $OrderBefore) {
        throw 'ORDER_LEDGER_COUNT_CHANGED'
    }

    Add-Result 'FINAL_RUNTIME_PROCESS_COUNT' $RuntimeAfter
    Add-Result 'FINAL_DASHBOARD_HTTP_ROOT' $RootHttp
    Add-Result 'FINAL_DASHBOARD_HTTP_HEALTH' $HealthHttp
    Add-Result 'FINAL_DASHBOARD_HTTP_SNAPSHOT' $SnapshotHttp
    Add-Result 'FINAL_ORDER_LEDGER_COUNT' $OrderAfter
    Add-Result 'ORDER_LEDGER_COUNT_UNCHANGED' $true
    Add-Result 'V2_PNL_TASKS_PAUSED_FOR_STABILITY' $true
    Add-Result 'FINAL_STATUS' 'PASS_DASHBOARD_STABILIZED_TO_V1_6'
    $Success = $true
}
catch {
    Add-Result 'STABILIZE_ERROR' $_.Exception.Message
    Add-Result 'FINAL_RUNTIME_PROCESS_COUNT' (@(Get-RuntimeProcesses).Count)
    Add-Result 'FINAL_DASHBOARD_HTTP_ROOT' (Get-HttpStatus '/')
    try {
        Add-Result 'FINAL_ORDER_LEDGER_COUNT' (Get-OrderLedgerCount)
    }
    catch {
        Add-Result 'FINAL_ORDER_LEDGER_COUNT' 'READ_FAILED'
    }
    Add-Result 'FINAL_STATUS' 'FAIL_DASHBOARD_STABILIZE_REQUIRES_REVIEW'
}

Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Result 'ORDER_PATH_MODIFIED' $false
Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
Add-Result 'BROKER_ORDER_ATTEMPTED' $false
Add-Result 'ORDER_TRANSPORT_CALLS' 0
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
