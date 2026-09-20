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

$readyPath=Join-Path $env:MULTICHAT_STATE_ROOT 'restricted-remote-ready.json'
Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue

function Write-ReadyMarker {
    param([int]$RemotePid)
    $payload=[ordered]@{
        schemaVersion=1
        state='CONNECTED'
        remotePid=$RemotePid
        updatedAt=(Get-Date).ToString('o')
    }
    $tmp=$readyPath+'.tmp'
    [IO.File]::WriteAllText($tmp,($payload|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $readyPath -Force
}

function Get-ChildProcessTreeIds {
    param([int]$RootPid)
    $all=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Select-Object ProcessId,ParentProcessId)
    $ids=New-Object Collections.Generic.List[int]
    [void]$ids.Add($RootPid)
    for($pass=0;$pass -lt 8;$pass++){
        $added=$false
        foreach($proc in $all){
            if($ids.Contains([int]$proc.ParentProcessId) -and -not $ids.Contains([int]$proc.ProcessId)){
                [void]$ids.Add([int]$proc.ProcessId)
                $added=$true
            }
        }
        if(-not $added){break}
    }
    return @($ids)
}

$node=$null
$stdoutTask=$null
$stderrTask=$null
$connected=$false
try{
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$NodePath
    $escapedEntry=$EntryPoint.Replace('"','\"')
    $psi.Arguments=('"'+$escapedEntry+'" remote')
    $psi.WorkingDirectory=Split-Path $EntryPoint -Parent
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true

    # Preserve only the already-sanitized restricted environment. The remote
    # process inherits this ProcessStartInfo environment automatically.
    $node=New-Object Diagnostics.Process
    $node.StartInfo=$psi
    if(-not $node.Start()){throw 'Restricted Remote node process did not start.'}

    $stdoutTask=$node.StandardOutput.ReadLineAsync()
    $stderrTask=$node.StandardError.ReadLineAsync()

    while($true){
        $node.Refresh()

        # Drain stdout/stderr continuously in memory so Desktop Commander cannot
        # block on a full pipe. Never persist or echo remote tool arguments/results.
        while($stdoutTask -and $stdoutTask.IsCompleted){
            $line=$stdoutTask.Result
            if($null -eq $line){
                $stdoutTask=$null
                break
            }
            if($line -match '(?i)Device ready:|Presence tracked|visible as online'){
                $connected=$true
            }elseif($line -match '(?i)device.*offline|connection.*closed|disconnected'){
                $connected=$false
                Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
            }
            $stdoutTask=$node.StandardOutput.ReadLineAsync()
        }
        while($stderrTask -and $stderrTask.IsCompleted){
            $null=$stderrTask.Result
            $stderrTask=$node.StandardError.ReadLineAsync()
        }

        if($connected){
            Write-ReadyMarker -RemotePid $node.Id
        }

        if($node.HasExited){break}
        Start-Sleep -Milliseconds 200
    }

    # Drain completion without writing remote output anywhere.
    try{if($stdoutTask){$null=$stdoutTask.GetAwaiter().GetResult()}}catch{}
    try{if($stderrTask){$null=$stderrTask.GetAwaiter().GetResult()}}catch{}
    exit $node.ExitCode
}finally{
    Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
    if($node){
        try{
            if(-not $node.HasExited){$node.Kill()}
        }catch{}
        $node.Dispose()
    }
    $historyRoot=Join-Path $profile '.claude-server-commander'
    if(Test-Path -LiteralPath $historyRoot){
        foreach($file in @(Get-ChildItem -LiteralPath $historyRoot -File -Force -ErrorAction SilentlyContinue|Where-Object{
            $_.Name -like 'claude_tool_call*.log' -or $_.Name -like 'tool-history*.jsonl'
        })){
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}
