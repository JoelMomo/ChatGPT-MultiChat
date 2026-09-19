param(
    [string]$InstallRoot=$PSScriptRoot,
    [switch]$DryRun
)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($InstallRoot)
Import-Module (Join-Path $PSScriptRoot 'RestrictedRemote.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'ChatMulti.psm1') -Force -DisableNameChecking

function Test-Administrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-IcaclsChecked {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & icacls.exe @Arguments|Out-Null
    if($LASTEXITCODE -ne 0){
        throw ("icacls failed ({0}): {1}" -f $LASTEXITCODE,($Arguments -join ' '))
    }
}

$configPath=Get-RestrictedRemoteConfigPath
if(-not(Test-Path -LiteralPath $configPath)){
    throw 'Restricted Remote is not installed. Run Install-RestrictedRemote.ps1 first.'
}
$config=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
if(-not(Test-RestrictedRemoteInstallMatches)){
    throw 'Restricted Remote was prepared for a different MultiChat folder. Re-run Install-RestrictedRemote.ps1 from this portable copy.'
}
$activeNormal=@(Get-ManagedChatSessions -ActiveOnly)
$currentAuth=Join-Path $env:USERPROFILE '.desktop-commander-device\device.json'
$restrictedAuthRoot=Join-Path ([string]$config.profilePath) '.desktop-commander-device'
$restrictedAuth=Join-Path $restrictedAuthRoot 'device.json'

if($DryRun){
    Write-Host 'RESTRICTED REMOTE ACTIVATION DRY RUN' -ForegroundColor Cyan
    Write-Host ('Account: '+[string]$config.userName)
    Write-Host ('Current authorization available: '+(Test-Path -LiteralPath $currentAuth))
    Write-Host ('Restricted profile: '+[string]$config.profilePath)
    Write-Host ('Runtime: '+[string]$config.runtimeRoot)
    Write-Host ('Active normal managed sessions: '+$activeNormal.Count)
    Write-Host 'Activation will stop Remote Desktop Commander and MultiChat, transfer the authorization record, and enable the restricted identity.'
    Write-Host 'No changes were made.'
    if(-not(Test-Path -LiteralPath $currentAuth)){exit 2}
    if($activeNormal.Count){exit 3}
    exit 0
}
if($activeNormal.Count){
    throw 'End all normal managed chat sessions before activating Restricted Remote.'
}
if(-not(Test-Administrator)){
    $args=@(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',$PSCommandPath,
        '-InstallRoot',$root
    )
    $elevated=Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait -PassThru
    $exitCode=$elevated.ExitCode
    $elevated.Dispose()
    exit $exitCode
}

$config=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
if(-not(Test-Path -LiteralPath $currentAuth)){
    throw 'Current Remote Desktop Commander authorization is missing; authorize the normal mode before migration.'
}

foreach($proc in @(Get-CimInstance Win32_Process|Where-Object{
    $_.CommandLine -match 'desktop-commander' -and $_.CommandLine -match '\bremote\b'
})){
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 700

New-Item -ItemType Directory -Path $restrictedAuthRoot -Force|Out-Null
Copy-Item -LiteralPath $currentAuth -Destination $restrictedAuth -Force
Invoke-IcaclsChecked @($restrictedAuthRoot,'/inheritance:r')
Invoke-IcaclsChecked @($restrictedAuthRoot,'/grant:r',('*'+[string]$config.userSid+':(OI)(CI)F'))
Invoke-IcaclsChecked @($restrictedAuthRoot,'/grant','*S-1-5-18:(OI)(CI)F')
Invoke-IcaclsChecked @($restrictedAuthRoot,'/grant','*S-1-5-32-544:(OI)(CI)F')
Invoke-IcaclsChecked @($restrictedAuth,'/inheritance:e')

Remove-Item -LiteralPath $currentAuth -Force
$config.enabled=$true
$config.activatedAt=(Get-Date).ToString('o')
[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
$securityRoot=Get-RestrictedRemoteSecurityRoot
$killSwitch=Join-Path $securityRoot 'desktop-commander.disabled'
Remove-Item -LiteralPath $killSwitch -Force -ErrorAction SilentlyContinue

foreach($proc in @(Get-CimInstance Win32_Process|Where-Object{
    $_.CommandLine -match 'MultiChat-Tray\.ps1'
})){
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
}

$result=[ordered]@{
    success=$true
    mode='restricted-user'
    userName=[string]$config.userName
    activatedAt=(Get-Date).ToString('o')
    authorizationTransferred=(Test-Path -LiteralPath $restrictedAuth)
    currentUserAuthorizationRemoved=(-not(Test-Path -LiteralPath $currentAuth))
}
$resultPath=Join-Path $securityRoot 'restricted-remote-activation-result.json'
[IO.File]::WriteAllText($resultPath,($result|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))

Write-Host 'Restricted Remote is activated.' -ForegroundColor Green
Write-Host 'MultiChat was stopped so the new execution identity can take effect.'
Write-Host 'Open the ChatGPT MultiChat shortcut, then turn Desktop Commander On locally.'
