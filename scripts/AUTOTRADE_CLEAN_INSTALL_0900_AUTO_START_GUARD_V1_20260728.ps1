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
        'AUTOTRADE_0900_GUARD_' + [guid]::NewGuid().ToString('N') + '.txt'
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
$RuntimeTaskName = 'AUTOTRADE_CLEAN_RUNTIME'
$GuardTaskName = 'AUTOTRADE_CLEAN_MARKET_OPEN_GUARD_0900'
$GuardRoot = Join-Path -Path $ControlRoot -ChildPath 'MARKET_OPEN_AUTOSTART_GUARD_V1'
$GuardScript = Join-Path -Path $GuardRoot -ChildPath 'market_open_guard.ps1'
$Report = Join-Path -Path $GuardRoot -ChildPath 'INSTALL_REPORT.txt'
$Bootstrap = Join-Path -Path $Root -ChildPath 'app\stage12_runtime_bootstrap.py'

New-Item -ItemType Directory -Path $GuardRoot -Force | Out-Null
$Results = New-Object System.Collections.Generic.List[string]

function Add-Result {
    param([string]$Key, [object]$Value)

    if ($Value -is [bool]) {
        $Text = $Value.ToString().ToUpperInvariant()
    }
    else {
        $Text = [string]$Value
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

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'INSTALL_0900_AUTOSTART_GUARD_FOR_EXISTING_CANONICAL_RUNTIME'
Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Result 'ORDER_PATH_MODIFIED' $false
Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
Add-Result 'BROKER_ORDER_ATTEMPTED' $false
Add-Result 'ORDER_TRANSPORT_CALLS' 0
Add-Result 'MANUAL_SYMBOL_PRICE_QUANTITY_USED' $false
Add-Result 'NEW_AUTOTRADE_ENGINE_CREATED' $false

$Success = $false

try {
    foreach ($Required in @($Root, $ControlRoot, $Bootstrap)) {
        if (-not (Test-Path -LiteralPath $Required)) {
            throw ('REQUIRED_PATH_MISSING:' + $Required)
        }
    }

    $RuntimeTask = Get-ScheduledTask -TaskName $RuntimeTaskName -ErrorAction Stop
    if (-not [bool]$RuntimeTask.Settings.Enabled) {
        Enable-ScheduledTask -TaskName $RuntimeTaskName | Out-Null
    }

    $RuntimeCountBefore = @(Get-RuntimeProcesses).Count
    if ($RuntimeCountBefore -gt 1) {
        throw ('DUPLICATE_CANONICAL_RUNTIME_BEFORE_INSTALL:' + $RuntimeCountBefore)
    }
    if ($RuntimeCountBefore -eq 0) {
        Start-ScheduledTask -TaskName $RuntimeTaskName
        $Deadline = (Get-Date).AddSeconds(45)
        do {
            Start-Sleep -Milliseconds 500
            $RuntimeCountBefore = @(Get-RuntimeProcesses).Count
        } while ($RuntimeCountBefore -eq 0 -and (Get-Date) -lt $Deadline)
    }
    if ($RuntimeCountBefore -ne 1) {
        throw ('CANONICAL_RUNTIME_NOT_ONE_BEFORE_INSTALL:' + $RuntimeCountBefore)
    }

    $GuardSource = @'
#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RuntimeTaskName = 'AUTOTRADE_CLEAN_RUNTIME'
$LogRoot = 'C:\Users\hjk86\AUTOTRADE_CONTROL\MARKET_OPEN_AUTOSTART_GUARD_V1'
$LogPath = Join-Path -Path $LogRoot -ChildPath ('GUARD_' + (Get-Date -Format 'yyyyMMdd') + '.log')
New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null

function Write-GuardLog {
    param([string]$Message)
    $Line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Message
    Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
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

try {
    $Now = Get-Date
    $WindowStart = Get-Date -Hour 8 -Minute 58 -Second 0
    $WindowEnd = Get-Date -Hour 9 -Minute 20 -Second 0

    if ($Now.DayOfWeek -in @('Saturday', 'Sunday')) {
        Write-GuardLog 'SKIP_WEEKEND'
        exit 0
    }

    if ($Now -gt $WindowEnd) {
        Write-GuardLog 'SKIP_AFTER_WINDOW'
        exit 0
    }

    Write-GuardLog 'GUARD_STARTED'

    do {
        $Task = Get-ScheduledTask -TaskName $RuntimeTaskName -ErrorAction Stop
        if (-not [bool]$Task.Settings.Enabled) {
            Enable-ScheduledTask -TaskName $RuntimeTaskName | Out-Null
            Write-GuardLog 'RUNTIME_TASK_ENABLED'
        }

        $Count = @(Get-RuntimeProcesses).Count
        if ($Count -gt 1) {
            Write-GuardLog ('FAIL_DUPLICATE_RUNTIME_COUNT=' + $Count)
            exit 2
        }

        if ($Count -eq 0) {
            Write-GuardLog 'RUNTIME_MISSING_START_REQUESTED'
            Start-ScheduledTask -TaskName $RuntimeTaskName
            $Deadline = (Get-Date).AddSeconds(45)
            do {
                Start-Sleep -Milliseconds 500
                $Count = @(Get-RuntimeProcesses).Count
            } while ($Count -eq 0 -and (Get-Date) -lt $Deadline)

            if ($Count -ne 1) {
                Write-GuardLog ('FAIL_RUNTIME_START_COUNT=' + $Count)
                exit 3
            }
            Write-GuardLog 'RUNTIME_STARTED_AND_VERIFIED_ONE'
        }
        else {
            Write-GuardLog 'RUNTIME_ALREADY_ONE'
        }

        Start-Sleep -Seconds 30
        $Now = Get-Date
    } while ($Now -lt $WindowEnd)

    $FinalCount = @(Get-RuntimeProcesses).Count
    if ($FinalCount -ne 1) {
        Write-GuardLog ('FAIL_FINAL_RUNTIME_COUNT=' + $FinalCount)
        exit 4
    }

    Write-GuardLog 'PASS_MARKET_OPEN_RUNTIME_PRESERVED'
    exit 0
}
catch {
    Write-GuardLog ('FAIL_EXCEPTION=' + $_.Exception.Message)
    exit 10
}
'@

    [IO.File]::WriteAllText(
        $GuardScript,
        $GuardSource,
        (New-Object System.Text.UTF8Encoding($true))
    )

    $Tokens = $null
    $ParseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $GuardScript,
        [ref]$Tokens,
        [ref]$ParseErrors
    )
    if (@($ParseErrors).Count -ne 0) {
        throw ('GUARD_PARSE_FAILED:' + ((@($ParseErrors | ForEach-Object { $_.Message })) -join ' | '))
    }

    $ActionArgument = (
        '-NoProfile -NonInteractive -WindowStyle Hidden ' +
        '-ExecutionPolicy Bypass -File "{0}"'
    ) -f $GuardScript
    $Action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument $ActionArgument

    $Trigger = New-ScheduledTaskTrigger `
        -Weekly `
        -WeeksInterval 1 `
        -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday `
        -At '08:58'

    $Principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $Settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    Register-ScheduledTask `
        -TaskName $GuardTaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Principal $Principal `
        -Settings $Settings `
        -Description '09:00 market-open guard for the existing AUTOTRADE_CLEAN canonical runtime only.' `
        -Force | Out-Null

    Enable-ScheduledTask -TaskName $GuardTaskName | Out-Null

    $InstalledTask = Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction Stop
    $RuntimeCountAfter = @(Get-RuntimeProcesses).Count
    if ($RuntimeCountAfter -ne 1) {
        throw ('CANONICAL_RUNTIME_NOT_ONE_AFTER_INSTALL:' + $RuntimeCountAfter)
    }

    $Now = Get-Date
    $TodayStart = Get-Date -Hour 8 -Minute 58 -Second 0
    $TodayEnd = Get-Date -Hour 9 -Minute 20 -Second 0
    $StartedNow = $false
    if ($Now -ge $TodayStart -and $Now -le $TodayEnd -and $Now.DayOfWeek -notin @('Saturday', 'Sunday')) {
        Start-ScheduledTask -TaskName $GuardTaskName
        $StartedNow = $true
    }

    Add-Result 'CANONICAL_RUNTIME_TASK_ENABLED' ([bool](Get-ScheduledTask -TaskName $RuntimeTaskName).Settings.Enabled)
    Add-Result 'CANONICAL_RUNTIME_PROCESS_COUNT' $RuntimeCountAfter
    Add-Result 'MARKET_OPEN_GUARD_TASK_INSTALLED' $true
    Add-Result 'MARKET_OPEN_GUARD_TASK_ENABLED' ([bool]$InstalledTask.Settings.Enabled)
    Add-Result 'MARKET_OPEN_GUARD_TRIGGER' 'WEEKDAYS_08:58_KST'
    Add-Result 'MARKET_OPEN_GUARD_ACTIVE_WINDOW' '08:58_TO_09:20_KST'
    Add-Result 'GUARD_STARTED_IMMEDIATELY' $StartedNow
    Add-Result 'SEPARATE_CODE_AFTER_0900_REQUIRED' $false
    Add-Result 'AUTOTRADE_RUNTIME_AUTOMATIC_AFTER_0900' $true
    Add-Result 'SAFETY_GATES_BYPASSED' $false
    Add-Result 'FINAL_STATUS' 'PASS_0900_AUTOSTART_GUARD_INSTALLED'
    $Success = $true
}
catch {
    Add-Result 'ERROR' $_.Exception.Message
    Add-Result 'FINAL_STATUS' 'FAIL_0900_AUTOSTART_GUARD_INSTALL'
}

$Output = $Results -join [Environment]::NewLine
[IO.File]::WriteAllText(
    $Report,
    $Output + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($true))
)

try {
    Set-Clipboard -Value $Output
    $Output += [Environment]::NewLine + 'COPY_STATUS=SUCCESS'
}
catch {
    $Output += [Environment]::NewLine + 'COPY_STATUS=FAILED'
}

if ($HandoffPath) {
    [IO.File]::WriteAllText(
        $HandoffPath,
        $Output + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($true))
    )
}
else {
    Write-Output $Output
}

if ($Success) {
    exit 0
}
exit 1
