param(
    [switch]$KeepLocalAuthorization,
    [switch]$SkipServerRevocation,
    [switch]$DryRun
)

$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$restrictedModule=Join-Path $root 'RestrictedRemote.psm1'
if(Test-Path -LiteralPath $restrictedModule){
    Import-Module $restrictedModule -Force -DisableNameChecking
}

$securityRoot=if(Get-Command Get-RestrictedRemoteSecurityRoot -ErrorAction SilentlyContinue){
    Get-RestrictedRemoteSecurityRoot
}else{
    Join-Path $env:LOCALAPPDATA 'ChatGPT-MultiChat\security'
}
New-Item -ItemType Directory -Path $securityRoot -Force|Out-Null
$flag=Join-Path $securityRoot 'desktop-commander.disabled'
$resultFile=Join-Path $securityRoot 'emergency-stop-last-result.json'
$deviceFile=Join-Path $env:USERPROFILE '.desktop-commander-device\device.json'
$historyRoot=Join-Path $env:USERPROFILE '.claude-server-commander'

function Get-NormalRemoteProcesses {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
        $_.CommandLine -match 'desktop-commander' -and $_.CommandLine -match '\bremote\b'
    })
}

function Clear-SensitiveHistory {
    param([string]$Path=$historyRoot)
    if(-not(Test-Path -LiteralPath $Path)){return}
    foreach($file in @(Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue|Where-Object{
        $_.Name -like 'claude_tool_call*.log' -or $_.Name -like 'tool-history*.jsonl'
    })){
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-NormalAuthorization {
    if(-not(Test-Path -LiteralPath $deviceFile)){return $null}
    try{return Get-Content -LiteralPath $deviceFile -Raw|ConvertFrom-Json}catch{return $null}
}

function Get-RemoteServerInfo {
    Invoke-RestMethod -Uri 'https://mcp.desktopcommander.app/api/mcp-info' -Method Get -TimeoutSec 15
}
function Get-FreshAccessToken {
    param($Authorization,$ServerInfo)
    $access=[string]$Authorization.session.access_token
    $refresh=[string]$Authorization.session.refresh_token
    if(-not $refresh){return $access}

    $uri=([string]$ServerInfo.supabaseUrl).TrimEnd('/')+'/auth/v1/token?grant_type=refresh_token'
    $headers=@{apikey=[string]$ServerInfo.supabasePublishableKey;'Content-Type'='application/json'}
    try{
        $body=@{refresh_token=$refresh}|ConvertTo-Json -Compress
        $response=Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -TimeoutSec 15
        if($response.access_token){return [string]$response.access_token}
    }catch{}
    return $access
}

function Revoke-NormalAuthorization {
    param($Authorization)
    $result=[ordered]@{device=$false;session=$false;message=''}
    if(-not $Authorization){
        $result.message='No saved Remote Desktop Commander authorization was present.'
        return $result
    }

    try{
        $info=Get-RemoteServerInfo
        $access=Get-FreshAccessToken -Authorization $Authorization -ServerInfo $info
        if(-not $access){throw 'No usable access token was available for server revocation.'}
        $base=([string]$info.supabaseUrl).TrimEnd('/')
        $headers=@{
            apikey=[string]$info.supabasePublishableKey
            Authorization=('Bearer '+$access)
            Prefer='return=representation'
        }

        if($Authorization.deviceId){
            $deviceId=[uri]::EscapeDataString([string]$Authorization.deviceId)
            Invoke-RestMethod -Uri ($base+'/rest/v1/mcp_devices?id=eq.'+$deviceId) -Method Delete -Headers $headers -TimeoutSec 15|Out-Null
            $result.device=$true
        }

        try{
            Invoke-WebRequest -UseBasicParsing -Uri ($base+'/auth/v1/logout?scope=local') -Method Post -Headers @{
                apikey=[string]$info.supabasePublishableKey
                Authorization=('Bearer '+$access)
            } -TimeoutSec 15|Out-Null
            $result.session=$true
        }catch{}

        $result.message=if($result.device -and $result.session){
            'Server device and authentication session were revoked.'
        }else{
            'Server revocation was only partially confirmed.'
        }
    }catch{
        $result.message='Server revocation failed: '+$_.Exception.Message
    }
    return $result
}
function Stop-RestrictedRemote {
    $cfg=$null
    if(Get-Command Get-RestrictedRemoteConfig -ErrorAction SilentlyContinue){
        $cfg=Get-RestrictedRemoteConfig
    }
    if(-not $cfg){return $null}

    $status=Get-RestrictedRemoteStatus
    if($status -and [int]$status.launcherPid -gt 0){
        Stop-Process -Id ([int]$status.launcherPid) -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 700
    }

    $result=[ordered]@{
        localAuthorizationRemoved=$false
        serverDeviceRevoked=$false
        serverSessionRevoked=$false
        message='Restricted Remote stopped.'
    }

    $helper=Join-Path $root 'RestrictedRemote-Revoke.ps1'
    if(-not(Test-Path -LiteralPath $helper)){
        $result.message='Restricted Remote revoke helper is missing.'
        return $result
    }

    try{
        $credential=Get-RestrictedRemoteCredential -Config $cfg
        $readerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $remoteResult=Join-Path ([string]$cfg.profilePath) ('AppData\Local\ChatGPT-MultiChat\security\revoke-'+[guid]::NewGuid().ToString('N')+'.json')
        $args=@(
            '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
            '-File',$helper,
            '-ProfilePath',[string]$cfg.profilePath,
            '-ResultPath',$remoteResult,
            '-ResultReaderSid',$readerSid
        )
        if($KeepLocalAuthorization){$args+='-KeepLocalAuthorization'}
        if($SkipServerRevocation){$args+='-SkipServerRevocation'}

        $proc=Start-Process powershell.exe -ArgumentList $args -Credential $credential -LoadUserProfile -UseNewEnvironment -WindowStyle Hidden -Wait -PassThru
        $exitCode=$proc.ExitCode
        $proc.Dispose()

        if(Test-Path -LiteralPath $remoteResult){
            $payload=Get-Content -LiteralPath $remoteResult -Raw|ConvertFrom-Json
            $result.localAuthorizationRemoved=[bool]$payload.localAuthorizationRemoved
            $result.serverDeviceRevoked=[bool]$payload.serverDeviceRevoked
            $result.serverSessionRevoked=[bool]$payload.serverSessionRevoked
            $result.message=[string]$payload.message
            Remove-Item -LiteralPath $remoteResult -Force -ErrorAction SilentlyContinue
        }elseif($exitCode -ne 0){
            $result.message='Restricted Remote revocation helper failed with exit code '+$exitCode+'.'
        }
    }catch{
        $result.message='Restricted Remote revocation failed: '+$_.Exception.Message
    }

    return $result
}
function Write-Result {
    param(
        [string]$Mode,
        [bool]$LocalStopped,
        [bool]$LocalAuthorizationRemoved,
        [bool]$ServerDeviceRevoked,
        [bool]$ServerSessionRevoked,
        [string]$Message
    )
    $payload=[ordered]@{
        completedAt=(Get-Date).ToString('o')
        mode=$Mode
        localStopped=$LocalStopped
        localAuthorizationRemoved=$LocalAuthorizationRemoved
        serverDeviceRevoked=$ServerDeviceRevoked
        serverSessionRevoked=$ServerSessionRevoked
        message=$Message
    }
    [IO.File]::WriteAllText($resultFile,($payload|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
}

$restricted=$null
if(Get-Command Get-RestrictedRemoteConfig -ErrorAction SilentlyContinue){
    $restricted=Get-RestrictedRemoteConfig
}
$mode=if($restricted){'restricted-user'}else{'normal-user'}

if($DryRun){
    Write-Host 'Emergency-stop dry run:' -ForegroundColor Cyan
    Write-Host ('Mode: '+$mode)
    if($restricted){
        $status=Get-RestrictedRemoteStatus
        Write-Host ('Restricted launcher running: '+[bool]($status -and [int]$status.launcherPid -gt 0 -and (Get-Process -Id ([int]$status.launcherPid) -ErrorAction SilentlyContinue)))
    }else{
        Write-Host ('Remote processes: '+@(Get-NormalRemoteProcesses).Count)
        Write-Host ('Saved authorization: '+[bool](Get-NormalAuthorization))
    }
    Write-Host ('Would revoke server authorization: '+(-not $KeepLocalAuthorization -and -not $SkipServerRevocation))
    Write-Host ('Would remove local authorization: '+(-not $KeepLocalAuthorization))
    exit 0
}

[IO.File]::WriteAllText($flag,((Get-Date).ToString('o')+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))

$localStopped=$false
$localRemoved=$false
$serverDevice=$false
$serverSession=$false
$message=''
if($restricted){
    $rr=Stop-RestrictedRemote
    $localStopped=$true
    if($rr){
        $localRemoved=[bool]$rr.localAuthorizationRemoved
        $serverDevice=[bool]$rr.serverDeviceRevoked
        $serverSession=[bool]$rr.serverSessionRevoked
        $message=[string]$rr.message
    }else{
        $message='Restricted Remote was enabled but could not be stopped cleanly.'
        $localStopped=$false
    }
}else{
    $authorization=Get-NormalAuthorization
    foreach($proc in @(Get-NormalRemoteProcesses)){
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 350
    foreach($proc in @(Get-NormalRemoteProcesses)){
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Clear-SensitiveHistory

    $server=[ordered]@{device=$false;session=$false;message='Server revocation skipped.'}
    if(-not $KeepLocalAuthorization -and -not $SkipServerRevocation){
        $server=Revoke-NormalAuthorization -Authorization $authorization
    }
    $serverDevice=[bool]$server.device
    $serverSession=[bool]$server.session
    $message=[string]$server.message

    if(-not $KeepLocalAuthorization){
        Remove-Item -LiteralPath $deviceFile -Force -ErrorAction SilentlyContinue
        $localRemoved=-not(Test-Path -LiteralPath $deviceFile)
    }
    $localStopped=(@(Get-NormalRemoteProcesses).Count -eq 0)
}

if($KeepLocalAuthorization){
    $message='Remote access stopped. Saved local authorization was preserved.'
}

Write-Result -Mode $mode -LocalStopped $localStopped -LocalAuthorizationRemoved $localRemoved -ServerDeviceRevoked $serverDevice -ServerSessionRevoked $serverSession -Message $message

Write-Host 'Desktop Commander remote access is stopped.' -ForegroundColor Green
Write-Host ('Mode: '+$mode)
Write-Host ('Kill switch: '+$flag)
if($KeepLocalAuthorization){
    Write-Host 'Saved local authorization was preserved.' -ForegroundColor DarkGray
}else{
    Write-Host ('Local authorization removed: '+$localRemoved)
    Write-Host ('Server device revoked: '+$serverDevice)
    Write-Host ('Server session revoked: '+$serverSession)
}
