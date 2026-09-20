param(
    [string]$Root=$PSScriptRoot
)

$ErrorActionPreference='Stop'
$launcherPath=Join-Path $Root 'RestrictedRemote-Launcher.ps1'
if(-not(Test-Path -LiteralPath $launcherPath)){throw 'Launcher not found.'}

$launcher=[IO.File]::ReadAllText($launcherPath)
$match=[regex]::Match($launcher,"(?s)\$watcher=@'\r?\n(?<body>.*?)\r?\n'@")
if(-not $match.Success){throw 'Embedded readiness watcher was not found.'}
$watcher=$match.Groups['body'].Value
$watcherEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watcher))

$temp=Join-Path $env:TEMP ('MultiChat-HeartbeatSandbox-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force|Out-Null
$ready=Join-Path $temp 'restricted-remote-ready.json'
$diagnostic=Join-Path $temp 'restricted-remote-ready-diagnostic.json'
$watcherStdout=Join-Path $temp 'watcher.stdout.txt'
$watcherStderr=Join-Path $temp 'watcher.stderr.txt'
$serverJs=Join-Path $temp 'sandbox-443-server.js'
$fakeJs=Join-Path $temp 'sandbox-fake-remote.js'
$cmdFile=Join-Path $temp 'sandbox.cmd'
$server=$null
$bootstrap=$null

try{
    @'
const net = require('net');
const server = net.createServer(socket => { socket.setKeepAlive(true, 1000); });
server.listen(443, '127.0.0.1');
setInterval(() => {}, 1000);
'@ | Set-Content -LiteralPath $serverJs -Encoding UTF8

    @'
const net = require('net');
const socket = net.connect(443, '127.0.0.1', () => socket.setKeepAlive(true, 1000));
socket.on('error', () => process.exit(2));
setInterval(() => {}, 1000);
'@ | Set-Content -LiteralPath $fakeJs -Encoding UTF8

    $node=(Get-Command node.exe -ErrorAction Stop).Source
    $systemRoot=if($env:SystemRoot){$env:SystemRoot}else{[Environment]::GetEnvironmentVariable('SystemRoot','Machine')}
    $ps=Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $cmd=Join-Path $systemRoot 'System32\cmd.exe'
    $server=Start-Process -FilePath $node -ArgumentList @('"'+$serverJs+'"') -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500

    $lines=@(
        '@echo off',
        ('set "MULTICHAT_READY_PATH='+$ready+'"'),
        ('set "MULTICHAT_READY_DIAGNOSTIC_PATH='+$diagnostic+'"'),
        ('set "MULTICHAT_ENTRY_POINT='+$fakeJs+'"'),
        ('start "" /b "'+$ps+'" -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$watcherEncoded+' 1>"'+$watcherStdout+'" 2>"'+$watcherStderr+'"'),
        ('"'+$node+'" "'+$fakeJs+'" remote >nul 2>&1')
    )
    [IO.File]::WriteAllLines($cmdFile,$lines,(New-Object Text.UTF8Encoding($false)))
    $bootstrap=Start-Process -FilePath $cmd -ArgumentList @('/d','/c','"'+$cmdFile+'"') -WindowStyle Hidden -PassThru

    $deadline=(Get-Date).AddSeconds(8)
    while((Get-Date) -lt $deadline -and -not(Test-Path -LiteralPath $ready)){
        Start-Sleep -Milliseconds 200
    }
    if(-not(Test-Path -LiteralPath $ready)){
        $parts=New-Object Collections.Generic.List[string]
        if(Test-Path -LiteralPath $diagnostic){
            try{[void]$parts.Add('diagnostic='+([IO.File]::ReadAllText($diagnostic).Trim()))}catch{}
        }
        if(Test-Path -LiteralPath $watcherStderr){
            try{
                $err=([IO.File]::ReadAllText($watcherStderr).Trim())
                if($err.Length -gt 800){$err=$err.Substring(0,800)+'...'}
                if($err){[void]$parts.Add('stderr='+$err)}
            }catch{}
        }
        if(Test-Path -LiteralPath $watcherStdout){
            try{
                $out=([IO.File]::ReadAllText($watcherStdout).Trim())
                if($out.Length -gt 800){$out=$out.Substring(0,800)+'...'}
                if($out){[void]$parts.Add('stdout='+$out)}
            }catch{}
        }
        $detail=($parts -join ' | ')
        if($detail){throw ('Readiness marker was not created. '+$detail)}
        throw 'Readiness marker was not created and the watcher produced no diagnostic output.'
    }

    $first=Get-Content -LiteralPath $ready -Raw|ConvertFrom-Json
    $firstTime=[datetimeoffset]::Parse([string]$first.updatedAt)
    Start-Sleep -Seconds 5
    if(-not(Test-Path -LiteralPath $ready)){throw 'Readiness marker disappeared while the synthetic Remote stayed connected.'}
    $second=Get-Content -LiteralPath $ready -Raw|ConvertFrom-Json
    $secondTime=[datetimeoffset]::Parse([string]$second.updatedAt)
    if($secondTime -le $firstTime){throw 'Readiness marker did not refresh.'}
    if([int]$second.remotePid -le 0){throw 'Readiness marker does not contain a Remote PID.'}

    Write-Host 'SANDBOX RESTRICTED HEARTBEAT TEST: OK' -ForegroundColor Green
} finally {
    if($bootstrap -and -not $bootstrap.HasExited){
        Stop-Process -Id $bootstrap.Id -Force -ErrorAction SilentlyContinue
    }
    if($server -and -not $server.HasExited){
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }

    $needle=[regex]::Escape($temp)
    foreach($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
        [string]$_.CommandLine -match $needle
    })){
        if([int]$proc.ProcessId -ne $PID){
            Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 800
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
