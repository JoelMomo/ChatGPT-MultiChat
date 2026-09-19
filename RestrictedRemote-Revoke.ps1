param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$ResultPath,
    [string]$ResultReaderSid,
    [switch]$KeepLocalAuthorization,
    [switch]$SkipServerRevocation
)

$ErrorActionPreference='Stop'
$profile=[IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
$deviceFile=Join-Path $profile '.desktop-commander-device\device.json'
$historyRoot=Join-Path $profile '.claude-server-commander'

function Get-Authorization {
    if(-not(Test-Path -LiteralPath $deviceFile)){return $null}
    try{return Get-Content -LiteralPath $deviceFile -Raw|ConvertFrom-Json}catch{return $null}
}

function Get-ServerInfo {
    Invoke-RestMethod -Uri 'https://mcp.desktopcommander.app/api/mcp-info' -Method Get -TimeoutSec 15
}

function Get-FreshAccessToken {
    param($Authorization,$ServerInfo)
    $access=[string]$Authorization.session.access_token
    $refresh=[string]$Authorization.session.refresh_token
    if(-not $refresh){return $access}
    try{
        $uri=([string]$ServerInfo.supabaseUrl).TrimEnd('/')+'/auth/v1/token?grant_type=refresh_token'
        $headers=@{apikey=[string]$ServerInfo.supabasePublishableKey;'Content-Type'='application/json'}
        $body=@{refresh_token=$refresh}|ConvertTo-Json -Compress
        $response=Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -TimeoutSec 15
        if($response.access_token){return [string]$response.access_token}
    }catch{}
    return $access
}

function Revoke-ServerAuthorization {
    param($Authorization)
    $result=[ordered]@{device=$false;session=$false;message=''}
    if(-not $Authorization){
        $result.message='No saved authorization was present.'
        return $result
    }
    try{
        $info=Get-ServerInfo
        $access=Get-FreshAccessToken -Authorization $Authorization -ServerInfo $info
        if(-not $access){throw 'No usable access token was available.'}
        $base=([string]$info.supabaseUrl).TrimEnd('/')
        $headers=@{apikey=[string]$info.supabasePublishableKey;Authorization=('Bearer '+$access);Prefer='return=representation'}
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
        $result.message=if($result.device -and $result.session){'Server authorization revoked.'}else{'Server revocation was only partially confirmed.'}
    }catch{
        $result.message='Server revocation failed: '+$_.Exception.Message
    }
    return $result
}

$authorization=Get-Authorization
$server=[ordered]@{device=$false;session=$false;message='Server revocation skipped.'}
if(-not $KeepLocalAuthorization -and -not $SkipServerRevocation){
    $server=Revoke-ServerAuthorization -Authorization $authorization
}

if(Test-Path -LiteralPath $historyRoot){
    foreach($file in @(Get-ChildItem -LiteralPath $historyRoot -File -Force -ErrorAction SilentlyContinue|Where-Object{
        $_.Name -like 'claude_tool_call*.log' -or $_.Name -like 'tool-history*.jsonl'
    })){
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
}
$localRemoved=$false
if(-not $KeepLocalAuthorization){
    Remove-Item -LiteralPath $deviceFile -Force -ErrorAction SilentlyContinue
    $localRemoved=-not(Test-Path -LiteralPath $deviceFile)
}

$payload=[ordered]@{
    completedAt=(Get-Date).ToString('o')
    localAuthorizationRemoved=$localRemoved
    serverDeviceRevoked=[bool]$server.device
    serverSessionRevoked=[bool]$server.session
    message=[string]$server.message
}
$parent=Split-Path $ResultPath -Parent
if($parent){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
[IO.File]::WriteAllText($ResultPath,($payload|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
if($ResultReaderSid){
    & icacls.exe $ResultPath /inheritance:r /grant:r ('*'+$ResultReaderSid+':F')|Out-Null
}

if($KeepLocalAuthorization){exit 0}
if(-not $localRemoved){exit 3}
if($SkipServerRevocation){exit 0}
if([bool]$server.device -and [bool]$server.session){exit 0}
exit 2
