param(
    [switch]$PurgeHistory
)

$ErrorActionPreference='Stop'
$userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$codexGroupSid=$null
try{$codexGroupSid=(Get-LocalGroup -Name 'CodexSandboxUsers' -ErrorAction Stop).SID.Value}catch{}

function Invoke-Icacls {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & icacls.exe @Arguments | Out-Null
    if($LASTEXITCODE -ne 0){
        throw ("icacls failed with exit code {0}: {1}" -f $LASTEXITCODE,($Arguments -join ' '))
    }
}

function Protect-PrivatePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$Directory
    )
    if(-not(Test-Path -LiteralPath $Path)){return}

    Invoke-Icacls @($Path,'/inheritance:r')
    if($Directory){
        Invoke-Icacls @($Path,'/grant:r',('*'+$userSid+':(OI)(CI)F'))
        Invoke-Icacls @($Path,'/grant','*S-1-5-18:(OI)(CI)F')
        Invoke-Icacls @($Path,'/grant','*S-1-5-32-544:(OI)(CI)F')
    }else{
        Invoke-Icacls @($Path,'/grant:r',('*'+$userSid+':F'))
        Invoke-Icacls @($Path,'/grant','*S-1-5-18:F')
        Invoke-Icacls @($Path,'/grant','*S-1-5-32-544:F')
    }
    if($codexGroupSid){
        Invoke-Icacls @($Path,'/remove:g',('*'+$codexGroupSid))
    }
}

function Protect-PrivateDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path)){return}

    Protect-PrivatePath -Path $Path -Directory $true
    foreach($item in @(Get-ChildItem -LiteralPath $Path -Force -Recurse)){
        Protect-PrivatePath -Path $item.FullName -Directory ([bool]$item.PSIsContainer)
    }
}

$remoteDir=Join-Path $env:USERPROFILE '.desktop-commander-device'
$configDir=Join-Path $env:USERPROFILE '.claude-server-commander'
$configPath=Join-Path $configDir 'config.json'
$securityDir=Join-Path $env:LOCALAPPDATA 'ChatGPT-MultiChat\security'
New-Item -ItemType Directory -Path $securityDir -Force|Out-Null

if(Test-Path -LiteralPath $configPath){
    $cfg=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
    if($cfg.PSObject.Properties['telemetryEnabled']){
        $cfg.telemetryEnabled=$false
    }else{
        $cfg|Add-Member -NotePropertyName telemetryEnabled -NotePropertyValue $false
    }
    $json=$cfg|ConvertTo-Json -Depth 30
    $tmp=$configPath+'.hardening.tmp'
    [IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $configPath -Force
}

if($PurgeHistory){
    foreach($name in @('claude_tool_call.log','tool-history.jsonl')){
        $file=Join-Path $configDir $name
        if(Test-Path -LiteralPath $file){
            try{[IO.File]::WriteAllText($file,'',(New-Object Text.UTF8Encoding($false)))}catch{}
        }
    }
}

Protect-PrivateDirectory -Path $remoteDir
Protect-PrivateDirectory -Path $configDir
Protect-PrivateDirectory -Path $securityDir

Write-Host 'Desktop Commander local hardening applied.' -ForegroundColor Green
if(Test-Path -LiteralPath $remoteDir){Write-Host ('Protected: '+$remoteDir)}
if(Test-Path -LiteralPath $configDir){Write-Host ('Protected: '+$configDir)}
if(Test-Path -LiteralPath $configPath){Write-Host 'Telemetry: disabled'}
if($PurgeHistory){Write-Host 'Local tool history: purge requested'}
