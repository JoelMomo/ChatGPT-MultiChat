param(
    [switch]$Runtime
)

$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$errors=@()

function Add-Failure {
    param([Parameter(Mandatory)][string]$Message)
    $script:errors+=$Message
}

$trayPath=Join-Path $root 'MultiChat-Tray.ps1'
$maintenancePath=Join-Path $root 'MultiChat-Maintenance.ps1'
$emergencyPath=Join-Path $root 'Emergency-Stop-DesktopCommander.ps1'
$hardeningPath=Join-Path $root 'Harden-DesktopCommander.ps1'
$gitIgnorePath=Join-Path $root '.gitignore'

foreach($required in @($trayPath,$maintenancePath,$emergencyPath,$hardeningPath,$gitIgnorePath)){
    if(-not(Test-Path -LiteralPath $required)){
        Add-Failure ("Missing security component: "+$required)
    }
}

if(Test-Path -LiteralPath $trayPath){
    $tray=[IO.File]::ReadAllText($trayPath)
    if($tray -match '@wonderwhy-er/desktop-commander@latest'){
        Add-Failure 'Desktop Commander still uses @latest'
    }
    if($tray -notmatch '@wonderwhy-er/desktop-commander@0\.2\.51'){
        Add-Failure 'Desktop Commander is not pinned to reviewed version 0.2.51'
    }
    if($tray -notmatch 'remote > NUL 2>&1'){
        Add-Failure 'Desktop Commander stdout/stderr is not suppressed'
    }
    if($tray -notmatch 'desktop-commander\.disabled'){
        Add-Failure 'Emergency kill switch is missing'
    }
    if($tray -notmatch 'Test-RemoteCommanderReady'){
        Add-Failure 'Readiness validation is missing'
    }
    if(-not $tray.Contains("Get-ChatProp `$cfg 'remoteDisconnectOnLock' `$true")){
        Add-Failure 'Remote disconnect-on-lock secure default is missing'
    }
    if(-not $tray.Contains("Get-ChatProp `$cfg 'remoteIdleDisconnectMinutes' 30")){
        Add-Failure 'Remote idle-disconnect secure default is missing'
    }
    if(-not $tray.Contains("Get-ChatProp `$cfg 'remotePurgeHistoryOnDisconnect' `$true")){
        Add-Failure 'Remote history purge-on-disconnect secure default is missing'
    }
    if($tray -notmatch 'Clear-RemoteCommanderSensitiveHistory'){
        Add-Failure 'Remote sensitive history cleanup is missing'
    }
    if($tray -notmatch '\$miExit\.Add_Click\(\{[\s\S]*?Stop-RemoteCommander'){
        Add-Failure 'Desktop Commander is not stopped when MultiChat exits'
    }
}

if(Test-Path -LiteralPath $gitIgnorePath){
    $gitIgnore=[IO.File]::ReadAllText($gitIgnorePath)
    if($gitIgnore -notmatch '(?m)^Configure-ThorGitHubSigningSecrets\.ps1$'){
        Add-Failure 'Local GitHub signing helper is not protected by .gitignore'
    }
    foreach($pattern in @('.env','*.pem','*.key','*.pfx','*.p12')){
        if(-not $gitIgnore.Contains($pattern)){
            Add-Failure ("Missing secret ignore pattern: "+$pattern)
        }
    }
}

if(Test-Path -LiteralPath $maintenancePath){
    $maintenance=[IO.File]::ReadAllText($maintenancePath)
    if($maintenance -notmatch 'device\.json'){
        Add-Failure 'Maintenance does not require persisted authorization'
    }
    if($maintenance -notmatch 'Get-NetTCPConnection'){
        Add-Failure 'Maintenance does not validate active network connectivity'
    }
}

if($Runtime){
    $configDir=Join-Path $env:USERPROFILE '.claude-server-commander'
    $remoteDir=Join-Path $env:USERPROFILE '.desktop-commander-device'
    $deviceFile=Join-Path $remoteDir 'device.json'
    $configFile=Join-Path $configDir 'config.json'
    $sandboxSid=$null
    try{$sandboxSid=(Get-LocalGroup -Name 'CodexSandboxUsers').SID.Value}catch{}
    foreach($privatePath in @($remoteDir,$deviceFile,$configDir,$configFile)){
        if(-not(Test-Path -LiteralPath $privatePath)){continue}
        if($sandboxSid){
            $acl=Get-Acl -LiteralPath $privatePath
            $bad=@($acl.Access|Where-Object{
                $_.AccessControlType -eq 'Allow' -and
                $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $sandboxSid
            })
            if($bad.Count){
                Add-Failure ("CodexSandboxUsers can access "+$privatePath)
            }
        }
    }

    if(Test-Path -LiteralPath $configFile){
        try{
            $cfg=Get-Content -LiteralPath $configFile -Raw|ConvertFrom-Json
            if([bool]$cfg.telemetryEnabled){
                Add-Failure 'Desktop Commander telemetry is enabled'
            }
        }catch{
            Add-Failure 'Desktop Commander config could not be read'
        }
    }

    if(Test-Path -LiteralPath $deviceFile){
        try{
            $device=Get-Content -LiteralPath $deviceFile -Raw|ConvertFrom-Json
            if(-not [bool]$device.deviceId -or
               -not [bool]$device.session.access_token -or
               -not [bool]$device.session.refresh_token){
                Add-Failure 'Remote authorization record is incomplete'
            }
        }catch{
            Add-Failure 'Remote authorization record could not be parsed'
        }
    }
    $tempHelpers=@(
        (Join-Path $env:LOCALAPPDATA 'Temp\multichat-security-restart.ps1'),
        (Join-Path $env:LOCALAPPDATA 'Temp\multichat-format-hardening.py'),
        (Join-Path $root 'state\cache\security-restart-result.json')
    )
    foreach($helper in $tempHelpers){
        if(Test-Path -LiteralPath $helper){
            Add-Failure ("Temporary security helper remains: "+$helper)
        }
    }
}

if($errors.Count){
    Write-Host 'SECURITY TEST: FAIL' -ForegroundColor Red
    $errors|ForEach-Object{Write-Host (' - '+$_) -ForegroundColor Red}
    exit 1
}

Write-Host 'SECURITY TEST: OK' -ForegroundColor Green
if($Runtime){
    Write-Host 'Static hardening, local ACLs, authorization storage and telemetry: OK.'
}else{
    Write-Host 'Static Desktop Commander hardening: OK.'
}
