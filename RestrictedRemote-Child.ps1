param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$NodePath,
    [Parameter(Mandatory)][string]$EntryPoint,
    [Parameter(Mandatory)][string]$ManagerRoot,
    [int]$StartupDelayMilliseconds=1200
)

$ErrorActionPreference='Stop'
if($StartupDelayMilliseconds -gt 0){
    Start-Sleep -Milliseconds $StartupDelayMilliseconds
}

$profile=[IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
$env:USERPROFILE=$profile
$env:HOME=$profile
$env:HOMEDRIVE=[IO.Path]::GetPathRoot($profile).TrimEnd('\')
$env:HOMEPATH=$profile.Substring($env:HOMEDRIVE.Length)
$env:APPDATA=Join-Path $profile 'AppData\Roaming'
$env:LOCALAPPDATA=Join-Path $profile 'AppData\Local'
$env:TEMP=Join-Path $env:LOCALAPPDATA 'Temp'
$env:TMP=$env:TEMP
$env:DC_REMOTE_DEVICE='true'
$env:MULTICHAT_RESTRICTED_REMOTE='1'
$env:MULTICHAT_STATE_ROOT=Join-Path $ManagerRoot 'state\restricted'
$env:MULTICHAT_WORKSPACE_ROOT=Join-Path $ManagerRoot 'workspaces\restricted'
$env:GIT_CONFIG_NOSYSTEM='1'
$env:GIT_TERMINAL_PROMPT='0'

foreach($dir in @($env:APPDATA,$env:LOCALAPPDATA,$env:TEMP)){
    if(-not(Test-Path -LiteralPath $dir)){
        New-Item -ItemType Directory -Path $dir -Force|Out-Null
    }
}

if(-not(Test-Path -LiteralPath $NodePath)){throw 'Node.js executable is missing.'}
if(-not(Test-Path -LiteralPath $EntryPoint)){throw 'Restricted Remote entry point is missing.'}

try{
    & $NodePath $EntryPoint remote
    exit $LASTEXITCODE
}finally{
    $historyRoot=Join-Path $profile '.claude-server-commander'
    if(Test-Path -LiteralPath $historyRoot){
        foreach($file in @(Get-ChildItem -LiteralPath $historyRoot -File -Force -ErrorAction SilentlyContinue|Where-Object{
            $_.Name -like 'claude_tool_call*.log' -or $_.Name -like 'tool-history*.jsonl'
        })){
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}
