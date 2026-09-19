param(
    [switch]$KeepLocalAuthorization,
    [switch]$SkipServerRevocation,
    [switch]$DryRun
)

$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$cache=Join-Path $root 'state\cache'
$flag=Join-Path $cache 'desktop-commander.disabled'
$resultFile=Join-Path $cache 'emergency-stop-last-result.json'
$deviceFile=Join-Path $env:USERPROFILE '.desktop-commander-device\device.json'
$historyRoot=Join-Path $env:USERPROFILE '.claude-server-commander'

function Get-RemoteProcesses {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
        $_.CommandLine -match 'desktop-commander' -and $_.CommandLine -match '\bremote\b'
    })
}

function Clear-SensitiveHistory {
    if(-not(Test-Path -LiteralPath $historyRoot)){return}
    foreach($file in @(Get-ChildItem -LiteralPath $historyRoot -File -Force -ErrorAction SilentlyContinue|Where-Object{
        $_.Name -like 'claude_tool_call*.log' -or $_.Name -like 'tool-history*.jsonl'
    })){
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-RemoteAuthorization {
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
    $headers=@{
        apikey=[string]$ServerInfo.supabasePublishableKey
        'Content-Type'='application/json'
    }
    try{
        $body=@{refresh_token=$refresh}|ConvertTo-Json -Compress
        $response=Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -TimeoutSec 15
        if($response.access_token){return [string]$response.access_token}
    }catch{}
    return $access
}

function Revoke-RemoteAuthorization {
    param($Authorization)
    $result=[ordered]@{device=$false;session=$false;message=''}
    if(-not $Authorization){
        $result.message='No saved Remote Desktop Commander authorization was present.'
        return $result
    }
    if(-not $Authorization.deviceId){
        $result.message='Saved authorization had no device ID.'
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
        $deviceId=[uri]::EscapeDataString([string]$Authorization.deviceId)
        $deleted=@(Invoke-RestMethod -Uri ($base+'/rest/v1/mcp_devices?id=eq.'+$deviceId) -Method Delete -Headers $headers -TimeoutSec 15)
        $result.device=($deleted.Count -gt 0)

        try{
            Invoke-WebRequest -UseBasicParsing -Uri ($base+'/auth/v1/logout?scope=local') -Method Post -Headers @{
                apikey=[string]$info.supabasePublishableKey
                Authorization=('Bearer '+$access)
            } -TimeoutSec 15|Out-Null
            $result.session=$true
        }catch{
            $result.session=$false
        }

        $result.message=if($result.device -and $result.session){
            'Server device and authentication session were revoked.'
        }elseif($result.device){
            'Server device was revoked; authentication-session revocation could not be confirmed.'
        }else{
            'Server revocation could not be confirmed.'
        }
    }catch{
        $result.message='Server revocation failed: '+$_.Exception.Message
    }
    return $result
}

function Write-Result {
    param(
        [bool]$LocalStopped,
        [bool]$LocalAuthorizationRemoved,
        [bool]$ServerDeviceRevoked,
        [bool]$ServerSessionRevoked,
        [string]$Message
    )
    New-Item -ItemType Directory -Path $cache -Force|Out-Null
    $payload=[ordered]@{
        completedAt=(Get-Date).ToString('o')
        localStopped=$LocalStopped
        localAuthorizationRemoved=$LocalAuthorizationRemoved
        serverDeviceRevoked=$ServerDeviceRevoked
        serverSessionRevoked=$ServerSessionRevoked
        message=$Message
    }
    [IO.File]::WriteAllText(
        $resultFile,
        ($payload|ConvertTo-Json -Depth 5),
        (New-Object Text.UTF8Encoding($false))
    )
}

$authorization=Get-RemoteAuthorization
$processes=@(Get-RemoteProcesses)

if($DryRun){
    Write-Host 'Emergency-stop dry run:' -ForegroundColor Cyan
    Write-Host ('Remote processes: '+$processes.Count)
    Write-Host ('Saved authorization: '+[bool]$authorization)
    Write-Host ('Would revoke server authorization: '+(-not $KeepLocalAuthorization -and -not $SkipServerRevocation))
    Write-Host ('Would remove local authorization: '+(-not $KeepLocalAuthorization))
    exit 0
}

New-Item -ItemType Directory -Path $cache -Force|Out-Null
[IO.File]::WriteAllText($flag,((Get-Date).ToString('o')+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))

foreach($proc in $processes){
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 350
foreach($proc in @(Get-RemoteProcesses)){
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
}
Clear-SensitiveHistory

$server=[ordered]@{device=$false;session=$false;message='Server revocation skipped.'}
if(-not $KeepLocalAuthorization -and -not $SkipServerRevocation){
    $server=Revoke-RemoteAuthorization -Authorization $authorization
}

$localRemoved=$false
if(-not $KeepLocalAuthorization){
    Remove-Item -LiteralPath $deviceFile -Force -ErrorAction SilentlyContinue
    $localRemoved=-not(Test-Path -LiteralPath $deviceFile)
}

$localStopped=(@(Get-RemoteProcesses).Count -eq 0)
$message=if($KeepLocalAuthorization){
    'Remote access stopped. Saved local authorization was preserved.'
}else{
    'Remote access stopped. '+[string]$server.message
}

Write-Result -LocalStopped $localStopped -LocalAuthorizationRemoved $localRemoved -ServerDeviceRevoked ([bool]$server.device) -ServerSessionRevoked ([bool]$server.session) -Message $message

Write-Host 'Desktop Commander remote access is stopped.' -ForegroundColor Green
Write-Host ('Kill switch: '+$flag)
if($KeepLocalAuthorization){
    Write-Host 'Saved local authorization was preserved.' -ForegroundColor DarkGray
}else{
    Write-Host ('Local authorization removed: '+$localRemoved)
    Write-Host ('Server device revoked: '+[bool]$server.device)
    Write-Host ('Server session revoked: '+[bool]$server.session)
}
