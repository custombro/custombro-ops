#requires -Version 5.1
[CmdletBinding()]
param([switch]$Elevated,[string]$HandoffPath='')

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

$Id=[Security.Principal.WindowsIdentity]::GetCurrent()
$P=New-Object Security.Principal.WindowsPrincipal($Id)
$Admin=$P.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if(-not $Admin -and -not $Elevated){
    $H=Join-Path $env:TEMP ('AUTOTRADE_0900_'+[guid]::NewGuid().ToString('N')+'.txt')
    $A=('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated -HandoffPath "{1}"') -f $PSCommandPath,$H
    $C=Start-Process powershell.exe -Verb RunAs -ArgumentList $A -Wait -PassThru
    if(-not(Test-Path -LiteralPath $H)){throw 'ELEVATED_HANDOFF_MISSING'}
    Get-Content -LiteralPath $H -Raw -Encoding UTF8 | Write-Output
    Remove-Item -LiteralPath $H -Force -ErrorAction SilentlyContinue
    exit $C.ExitCode
}
if(-not $Admin){throw 'ADMINISTRATOR_ELEVATION_FAILED'}

$Root='C:\AUTOTRADE_CLEAN'
$Control='C:\Users\hjk86\AUTOTRADE_CONTROL'
$RuntimeTask='AUTOTRADE_CLEAN_RUNTIME'
$GuardTask='AUTOTRADE_CLEAN_MARKET_OPEN_GUARD_0900'
$GuardDir=Join-Path $Control 'MARKET_OPEN_AUTOSTART_GUARD_V1'
$GuardFile=Join-Path $GuardDir 'market_open_guard.ps1'
$Report=Join-Path $GuardDir 'INSTALL_REPORT.txt'
$Bootstrap=Join-Path $Root 'app\stage12_runtime_bootstrap.py'
New-Item -ItemType Directory -Path $GuardDir -Force | Out-Null

$R=New-Object System.Collections.Generic.List[string]
function Add-R([string]$K,[object]$V){
    if($V -is [bool]){$T=$V.ToString().ToUpperInvariant()}else{$T=[string]$V}
    [void]$R.Add($K+'='+$T)
}
function Runtime-Count{
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object{
            $_.Name -match '^pythonw?\.exe$' -and
            [string]$_.CommandLine -like '*C:\AUTOTRADE_CLEAN\app\stage12_runtime_bootstrap.py*' -and
            [string]$_.CommandLine -like '*--mode persistent*'
        }
    ).Count
}

Add-R 'FINAL_STATUS' 'RUNNING'
Add-R 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-R 'ORDER_PATH_MODIFIED' $false
Add-R 'DATABASE_DIRECT_WRITE_USED' $false
Add-R 'BROKER_ORDER_ATTEMPTED' $false
Add-R 'ORDER_TRANSPORT_CALLS' 0
Add-R 'MANUAL_SYMBOL_PRICE_QUANTITY_USED' $false
$Ok=$false

try{
    foreach($X in @($Root,$Control,$Bootstrap)){if(-not(Test-Path -LiteralPath $X)){throw ('MISSING:'+ $X)}}
    $RT=Get-ScheduledTask -TaskName $RuntimeTask -ErrorAction Stop
    if(-not [bool]$RT.Settings.Enabled){Enable-ScheduledTask -TaskName $RuntimeTask | Out-Null}

    $Guard=@'
#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$RuntimeTask='AUTOTRADE_CLEAN_RUNTIME'
$Dir='C:\Users\hjk86\AUTOTRADE_CONTROL\MARKET_OPEN_AUTOSTART_GUARD_V1'
$Log=Join-Path $Dir ('GUARD_'+(Get-Date -Format 'yyyyMMdd')+'.log')
New-Item -ItemType Directory -Path $Dir -Force | Out-Null
function L([string]$M){Add-Content -LiteralPath $Log -Encoding UTF8 -Value ('['+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'] '+$M)}
function C{return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '^pythonw?\.exe$' -and [string]$_.CommandLine -like '*C:\AUTOTRADE_CLEAN\app\stage12_runtime_bootstrap.py*' -and [string]$_.CommandLine -like '*--mode persistent*'}).Count}
try{
    $T=Get-ScheduledTask -TaskName $RuntimeTask -ErrorAction Stop
    if(-not [bool]$T.Settings.Enabled){Enable-ScheduledTask -TaskName $RuntimeTask|Out-Null;L 'RUNTIME_TASK_ENABLED'}
    $N=C
    if($N -gt 1){L ('FAIL_DUPLICATE_RUNTIME='+$N);exit 2}
    if($N -eq 0){
        L 'RUNTIME_START_REQUESTED'
        Start-ScheduledTask -TaskName $RuntimeTask
        $D=(Get-Date).AddSeconds(60)
        do{Start-Sleep -Milliseconds 500;$N=C}while($N -eq 0 -and (Get-Date) -lt $D)
    }
    if($N -ne 1){L ('FAIL_RUNTIME_COUNT='+$N);exit 3}
    L 'PASS_CANONICAL_RUNTIME_ONE'
    exit 0
}catch{L ('FAIL_EXCEPTION='+$_.Exception.Message);exit 10}
'@

    [IO.File]::WriteAllText($GuardFile,$Guard,(New-Object Text.UTF8Encoding($true)))
    $Tok=$null;$Err=$null
    [void][Management.Automation.Language.Parser]::ParseFile($GuardFile,[ref]$Tok,[ref]$Err)
    if(@($Err).Count -ne 0){throw ('GUARD_PARSE_FAILED:'+((@($Err|ForEach-Object{$_.Message}))-join ' | '))}

    $Arg=('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"') -f $GuardFile
    $Act=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $Arg
    $Tr1=New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At '09:00'
    $Tr2=New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At '09:05'
    $Pri=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $Set=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    Register-ScheduledTask -TaskName $GuardTask -Action $Act -Trigger @($Tr1,$Tr2) -Principal $Pri -Settings $Set -Force | Out-Null
    Enable-ScheduledTask -TaskName $GuardTask | Out-Null

    $Now=Get-Date
    if($Now.Hour -ge 9 -and $Now.Hour -lt 16 -and $Now.DayOfWeek -notin @('Saturday','Sunday')){Start-ScheduledTask -TaskName $GuardTask}

    $N=Runtime-Count
    if($N -gt 1){throw ('DUPLICATE_CANONICAL_RUNTIME='+$N)}
    Add-R 'CANONICAL_RUNTIME_PROCESS_COUNT_NOW' $N
    Add-R 'CANONICAL_RUNTIME_TASK_ENABLED' ([bool](Get-ScheduledTask -TaskName $RuntimeTask).Settings.Enabled)
    Add-R 'MARKET_OPEN_GUARD_TASK_INSTALLED' $true
    Add-R 'MARKET_OPEN_GUARD_TASK_ENABLED' ([bool](Get-ScheduledTask -TaskName $GuardTask).Settings.Enabled)
    Add-R 'MARKET_OPEN_GUARD_TRIGGERS' 'WEEKDAYS_09:00_AND_09:05_KST'
    Add-R 'SEPARATE_CODE_AFTER_0900_REQUIRED' $false
    Add-R 'SAFETY_GATES_BYPASSED' $false
    Add-R 'FINAL_STATUS' 'PASS_0900_AUTOSTART_GUARD_INSTALLED'
    $Ok=$true
}catch{
    Add-R 'ERROR' $_.Exception.Message
    Add-R 'FINAL_STATUS' 'FAIL_0900_AUTOSTART_GUARD_INSTALL'
}

$Out=$R -join [Environment]::NewLine
[IO.File]::WriteAllText($Report,$Out+[Environment]::NewLine,(New-Object Text.UTF8Encoding($true)))
try{Set-Clipboard -Value $Out;$Out+=[Environment]::NewLine+'COPY_STATUS=SUCCESS'}catch{$Out+=[Environment]::NewLine+'COPY_STATUS=FAILED'}
if($HandoffPath){[IO.File]::WriteAllText($HandoffPath,$Out+[Environment]::NewLine,(New-Object Text.UTF8Encoding($true)))}else{Write-Output $Out}
if($Ok){exit 0}else{exit 1}
