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

$remote=@(
    Get-CimInstance Win32_Process -ErrorAction Stop |
    Where-Object {
        $_.Name -ieq 'node.exe' -and
        [string]$_.CommandLine -match '(?i)desktop-commander.*\\dist\\index\.js.*\bremote\b'
    } |
    Select-Object -First 1
)
if(-not $remote){throw 'No live restricted Remote node process was found.'}

$cmdLine=[string]$remote.CommandLine
$entryMatch=[regex]::Match($cmdLine,'(?i)"(?<entry>[^"]+\\dist\\index\.js)"\s+remote\b')
if(-not $entryMatch.Success){throw 'Could not resolve the live Remote entry point.'}
$entryPoint=$entryMatch.Groups['entry'].Value
$bootstrapPid=[int]$remote.ParentProcessId
if($bootstrapPid -le 0){throw 'Live Remote bootstrap PID is unavailable.'}

$temp=Join-Path $env:TEMP ('MultiChat-LiveHeartbeatProbe-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force|Out-Null
$ready=Join-Path $temp 'restricted-remote-ready.json'
$watcherProcess=$null
$oldReady=$env:MULTICHAT_READY_PATH
$oldEntry=$env:MULTICHAT_ENTRY_POINT
$oldBootstrap=$env:MULTICHAT_WATCH_BOOTSTRAP_PID

try{
    $env:MULTICHAT_READY_PATH=$ready
    $env:MULTICHAT_ENTRY_POINT=$entryPoint
    $env:MULTICHAT_WATCH_BOOTSTRAP_PID=[string]$bootstrapPid

    $systemRoot=if($env:SystemRoot){$env:SystemRoot}else{[Environment]::GetEnvironmentVariable('SystemRoot','Machine')}
    if(-not $systemRoot){throw 'SystemRoot is unavailable in the live probe.'}
    $ps=Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $watcherProcess=Start-Process -FilePath $ps -ArgumentList @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-EncodedCommand',$watcherEncoded
    ) -WindowStyle Hidden -PassThru

    $deadline=(Get-Date).AddSeconds(8)
    while((Get-Date) -lt $deadline -and -not(Test-Path -LiteralPath $ready)){
        Start-Sleep -Milliseconds 200
    }
    if(-not(Test-Path -LiteralPath $ready)){throw 'Live watcher did not publish readiness.'}

    $first=Get-Content -LiteralPath $ready -Raw|ConvertFrom-Json
    if([int]$first.remotePid -ne [int]$remote.ProcessId){
        throw 'Live watcher selected the wrong Remote process.'
    }
    $firstTime=[datetimeoffset]::Parse([string]$first.updatedAt)

    Start-Sleep -Seconds 5
    if(-not(Test-Path -LiteralPath $ready)){throw 'Live readiness marker disappeared unexpectedly.'}
    $second=Get-Content -LiteralPath $ready -Raw|ConvertFrom-Json
    $secondTime=[datetimeoffset]::Parse([string]$second.updatedAt)
    if($secondTime -le $firstTime){throw 'Live readiness marker did not refresh.'}

    Write-Host ('LIVE RESTRICTED HEARTBEAT PROBE: OK (remote PID '+$remote.ProcessId+')') -ForegroundColor Green
} finally {
    $env:MULTICHAT_READY_PATH=$oldReady
    $env:MULTICHAT_ENTRY_POINT=$oldEntry
    $env:MULTICHAT_WATCH_BOOTSTRAP_PID=$oldBootstrap

    if($watcherProcess -and -not $watcherProcess.HasExited){
        Stop-Process -Id $watcherProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
