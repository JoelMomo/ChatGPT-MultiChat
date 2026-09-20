param(
    [string]$InstallRoot=$PSScriptRoot,
    [switch]$DryRun
)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($InstallRoot)
Import-Module (Join-Path $root 'RestrictedRemote.psm1') -Force -DisableNameChecking
$config=Get-RestrictedRemoteInstalledConfig

function Test-Administrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-RestrictedAce {
    param([string]$Path,[string]$Sid)
    if(-not $Path -or -not(Test-Path -LiteralPath $Path)){return}
    & icacls.exe $Path /remove:g ('*'+$Sid) /T /C /Q | Out-Null
}

if(-not $config){
    Write-Host 'Restricted Remote is not installed.' -ForegroundColor DarkGray
    exit 0
}

$accountName=[string]$config.accountName
$userSid=[string]$config.userSid
$profilePath=[string]$config.profilePath
$securityRoot=Get-RestrictedRemoteSecurityRoot

if($DryRun){
    Write-Host 'RESTRICTED REMOTE UNINSTALL DRY RUN' -ForegroundColor Cyan
    Write-Host ('Account: '+$accountName)
    Write-Host ('Enabled: '+[bool]$config.enabled)
    Write-Host ('Profile: '+$profilePath)
    Write-Host ('Project ACL roots: '+@($config.projectRoots).Count)
    Write-Host 'Would revoke server authorization: True'
    Write-Host 'No system changes were made.'
    exit 0
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

$status=Get-RestrictedRemoteStatus
if($status -and [int]$status.launcherPid -gt 0){
    Stop-Process -Id ([int]$status.launcherPid) -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
}

# The uninstaller is elevated, so the Administrators ACE on the restricted
# profile lets it revoke the cloud device/session even if the portable folder
# was moved and the restricted account cannot execute scripts from the new path.
$revokeHelper=Join-Path $root 'RestrictedRemote-Revoke.ps1'
if($profilePath -and (Test-Path -LiteralPath $revokeHelper)){
    $revokeResult=Join-Path $securityRoot 'restricted-remote-uninstall-revoke.json'
    $revokeArgs=@(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',$revokeHelper,
        '-ProfilePath',$profilePath,
        '-ResultPath',$revokeResult
    )
    & powershell.exe @revokeArgs
    if($LASTEXITCODE -ne 0){
        Write-Warning 'Restricted Remote local authorization was removed, but complete server-side revocation could not be confirmed.'
    }
    Remove-Item -LiteralPath $revokeResult -Force -ErrorAction SilentlyContinue
}

$aclRoots=New-Object Collections.Generic.List[string]
foreach($p in @($config.projectRoots)){if($p){[void]$aclRoots.Add([string]$p)}}
foreach($p in @([string]$config.stateRoot,[string]$config.workspaceRoot,[string]$config.runtimeRoot)){
    if($p){[void]$aclRoots.Add($p)}
}
foreach($p in @($aclRoots|Sort-Object -Unique)){
    Remove-RestrictedAce -Path $p -Sid $userSid
}

$account=Get-LocalUser -Name $accountName -ErrorAction SilentlyContinue
if($account -and [string]$account.SID.Value -ne $userSid){
    throw "Account '$accountName' exists but its SID does not match the Restricted Remote configuration."
}
if($account){
    Remove-LocalUser -Name $accountName
}

$hideKey='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
if(Test-Path -LiteralPath $hideKey){
    Remove-ItemProperty -Path $hideKey -Name $accountName -Force -ErrorAction SilentlyContinue
}
try{
    $profile=Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue|Where-Object{$_.SID -eq $userSid}|Select-Object -First 1
    if($profile -and -not [bool]$profile.Loaded){
        Remove-CimInstance -InputObject $profile -ErrorAction Stop
    }elseif($profilePath -and (Test-Path -LiteralPath $profilePath)){
        Write-Warning 'Restricted Remote profile is still loaded; Windows will remove it after it is no longer in use.'
    }
}catch{
    Write-Warning ('Could not remove the Restricted Remote Windows profile: '+$_.Exception.Message)
}

$identityMarkerPath=[string]$config.identityMarkerPath
if(-not $identityMarkerPath -and $userSid){
    $commonData=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    $identityMarkerPath=Join-Path (Join-Path $commonData 'ChatGPT-MultiChat\restricted-identities') ($userSid+'.json')
}
if($identityMarkerPath){
    Remove-Item -LiteralPath $identityMarkerPath -Force -ErrorAction SilentlyContinue
}

foreach($file in @(
    (Get-RestrictedRemoteConfigPath),
    (Get-RestrictedRemoteStatusPath),
    (Join-Path $securityRoot 'restricted-remote-password.dpapi'),
    (Join-Path $securityRoot 'restricted-remote-activation-result.json'),
    (Join-Path ([string]$config.stateRoot) 'restricted-projects.json')
)){
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}

# Keep the emergency kill switch in place. Returning to normal-user mode
# therefore requires an explicit local On action rather than silently exposing
# Remote Desktop Commander after the containment identity is removed.
Write-Host 'Restricted Remote has been removed.' -ForegroundColor Green
Write-Host 'Remote access remains Off until explicitly enabled locally.'
