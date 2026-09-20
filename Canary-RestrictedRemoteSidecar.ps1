param(
    [string]$CanonicalRoot='C:\Users\joele\Documents\ChatGPT-MultiChat',
    [int]$TrialSeconds=20
)

$ErrorActionPreference='Stop'
$labRoot=$PSScriptRoot
$canonicalRoot=[IO.Path]::GetFullPath($CanonicalRoot).TrimEnd('\')
$canonicalModule=Join-Path $canonicalRoot 'RestrictedRemote.psm1'
$labLauncher=Join-Path $labRoot 'RestrictedRemote-Launcher.ps1'
$shortcut=Join-Path $env:USERPROFILE 'Desktop\ChatGPT MultiChat v2.4.0.lnk'
if(-not(Test-Path -LiteralPath $canonicalModule)){throw 'Canonical RestrictedRemote.psm1 was not found.'}
if(-not(Test-Path -LiteralPath $labLauncher)){throw 'Lab RestrictedRemote-Launcher.ps1 was not found.'}
if(-not(Test-Path -LiteralPath $shortcut)){throw 'Stable MultiChat shortcut was not found.'}

Import-Module $canonicalModule -Force -DisableNameChecking
$config=Get-RestrictedRemoteConfig
if(-not $config){throw 'Stable Restricted Remote configuration is not enabled.'}

$statusPath=Get-RestrictedRemoteStatusPath
$readyPath=Join-Path ([string]$config.stateRoot) 'restricted-remote-ready.json'
$readyDiagnosticPath=Join-Path ([string]$config.stateRoot) 'restricted-remote-ready-diagnostic.json'
$stdoutPath=Join-Path ([string]$config.stateRoot) 'restricted-remote-child.stdout.tmp'
$resultPath=Join-Path (Get-RestrictedRemoteSecurityRoot) 'restricted-remote-sidecar-canary.json'
$restoreSignal=Join-Path $env:TEMP ('multichat-sidecar-restore-'+[guid]::NewGuid().ToString('N')+'.signal')
$keeperReady=Join-Path $env:TEMP ('multichat-sidecar-keeper-'+[guid]::NewGuid().ToString('N')+'.ready')
$trialLauncher=$null

function Stop-CanonicalTray {
    foreach($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
        [string]$_.CommandLine -match 'MultiChat-Tray\.ps1' -and
        [string]$_.CommandLine -like ('*'+$canonicalRoot+'*')
    })){
        Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue
    }
}

function Stop-RecordedLauncher {
    try{
        $status=Get-RestrictedRemoteStatus
        if($status -and [int]$status.launcherPid -gt 0){
            Stop-Process -Id ([int]$status.launcherPid) -Force -ErrorAction SilentlyContinue
        }
    }catch{}
}

$keeperTemplate=@'
$ErrorActionPreference='SilentlyContinue'
$canonicalRoot='__CANONICAL__'
$canonicalModule=Join-Path $canonicalRoot 'RestrictedRemote.psm1'
$shortcut='__SHORTCUT__'
$signal='__SIGNAL__'
$keeperReady='__KEEPER_READY__'
$statusPath='__STATUS__'
[IO.File]::WriteAllText($keeperReady,'READY',(New-Object Text.UTF8Encoding($false)))
$deadline=(Get-Date).AddSeconds(55)
while((Get-Date) -lt $deadline -and -not(Test-Path -LiteralPath $signal)){
    Start-Sleep -Milliseconds 250
}
foreach($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
    [string]$_.CommandLine -match 'RestrictedRemote-Launcher\.ps1' -and
    [string]$_.CommandLine -notlike ('*'+$canonicalRoot+'*')
})){
    Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 700
$launcher=Start-Process powershell.exe -ArgumentList @(
    '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
    '-File',(Join-Path $canonicalRoot 'RestrictedRemote-Launcher.ps1'),
    '-ParentPid',$PID,
    '-ModulePath',$canonicalModule
) -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 3
Start-Process $shortcut
$handoffDeadline=(Get-Date).AddMinutes(5)
while((Get-Date) -lt $handoffDeadline){
    try{
        if(Test-Path -LiteralPath $statusPath){
            $status=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json
            if([int]$status.launcherPid -gt 0 -and [int]$status.launcherPid -ne $launcher.Id){
                break
            }
        }
    }catch{}
    Start-Sleep -Seconds 2
}
try{if($launcher -and -not $launcher.HasExited){Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue}}catch{}
Remove-Item -LiteralPath $signal,$keeperReady -Force -ErrorAction SilentlyContinue
'@
$keeper=$keeperTemplate.Replace('__CANONICAL__',$canonicalRoot.Replace("'","''")).
    Replace('__SHORTCUT__',$shortcut.Replace("'","''")).
    Replace('__SIGNAL__',$restoreSignal.Replace("'","''")).
    Replace('__KEEPER_READY__',$keeperReady.Replace("'","''")).
    Replace('__STATUS__',$statusPath.Replace("'","''"))
$keeperEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($keeper))
$keeperProcess=Start-Process powershell.exe -ArgumentList @(
    '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$keeperEncoded
) -WindowStyle Hidden -PassThru

$keeperDeadline=(Get-Date).AddSeconds(5)
while((Get-Date) -lt $keeperDeadline -and -not(Test-Path -LiteralPath $keeperReady)){
    Start-Sleep -Milliseconds 100
}
if(-not(Test-Path -LiteralPath $keeperReady)){
    throw 'Recovery keeper did not initialize; refusing to stop the stable Remote.'
}

$success=$false
$detail=''
try{
    $stableHead=(& git -C $canonicalRoot rev-parse --short HEAD 2>$null).Trim()
    Write-Host ('Stable main before trial: '+$stableHead)

    Stop-CanonicalTray
    Stop-RecordedLauncher
    Start-Sleep -Seconds 2
    Remove-Item -LiteralPath $readyPath,$readyDiagnosticPath -Force -ErrorAction SilentlyContinue

    $trialLauncher=Start-Process powershell.exe -ArgumentList @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',$labLauncher,
        '-ParentPid',$PID,
        '-ModulePath',$canonicalModule
    ) -WindowStyle Hidden -PassThru

    $deadline=(Get-Date).AddSeconds(25)
    $running=$false
    $ready=$false
    while((Get-Date) -lt $deadline){
        try{
            $status=Get-RestrictedRemoteStatus
            $running=[bool]($status -and [string]$status.state -eq 'RUNNING' -and [int]$status.launcherPid -eq $trialLauncher.Id)
        }catch{$running=$false}
        $ready=Test-Path -LiteralPath $readyPath
        if($running -and $ready){break}
        if($trialLauncher.HasExited){break}
        Start-Sleep -Milliseconds 250
    }
    if(-not $running){throw 'Experimental launcher did not reach RUNNING.'}
    if(-not $ready){
        $watcherDiagnostic=''
        if(Test-Path -LiteralPath $readyDiagnosticPath){
            try{
                $diag=Get-Content -LiteralPath $readyDiagnosticPath -Raw|ConvertFrom-Json
                $watcherDiagnostic=('state={0}; watcherPid={1}; bootstrapPid={2}; remotePid={3}; treeCount={4}; tcp443Count={5}; message={6}' -f
                    [string]$diag.state,[int]$diag.watcherPid,[int]$diag.bootstrapPid,[int]$diag.remotePid,
                    [int]$diag.treeCount,[int]$diag.tcp443Count,[string]$diag.message)
            }catch{}
        }
        if($watcherDiagnostic){
            throw ('Experimental readiness sidecar did not publish CONNECTED. Diagnostic: '+$watcherDiagnostic)
        }
        throw 'Experimental readiness sidecar did not publish CONNECTED. No watcher diagnostic was produced.'
    }

    $presence=$false
    $deviceReady=$false
    $signalDeadline=(Get-Date).AddSeconds(15)
    while((Get-Date) -lt $signalDeadline){
        if(Test-Path -LiteralPath $stdoutPath){
            try{
                $startup=[IO.File]::ReadAllText($stdoutPath)
                $presence=$startup -match 'Presence tracked'
                $deviceReady=$startup -match 'Device ready'
            }catch{}
        }
        if($presence -and $deviceReady){break}
        Start-Sleep -Milliseconds 250
    }
    if(-not $presence){throw 'Remote did not confirm cloud presence during the canary window.'}
    if(-not $deviceReady){throw 'Remote did not reach Device ready during the canary window.'}

    $first=Get-Content -LiteralPath $readyPath -Raw|ConvertFrom-Json
    $firstTime=[datetimeoffset]::Parse([string]$first.updatedAt)
    Start-Sleep -Seconds ([Math]::Max(5,$TrialSeconds))
    if(-not(Test-Path -LiteralPath $readyPath)){throw 'Readiness heartbeat disappeared during the canary window.'}
    $second=Get-Content -LiteralPath $readyPath -Raw|ConvertFrom-Json
    $secondTime=[datetimeoffset]::Parse([string]$second.updatedAt)
    if($secondTime -le $firstTime){throw 'Readiness heartbeat did not refresh during the canary window.'}

    $success=$true
    $detail='Experimental launcher reached RUNNING, cloud presence, Device ready, and sustained heartbeat.'
    Write-Host 'RESTRICTED SIDECAR END-TO-END CANARY: OK' -ForegroundColor Green
}catch{
    $detail=$_.Exception.Message
    Write-Warning ('CANARY FAILED: '+$detail)
}finally{
    try{
        if($trialLauncher -and -not $trialLauncher.HasExited){
            Stop-Process -Id $trialLauncher.Id -Force -ErrorAction SilentlyContinue
        }
    }catch{}
    Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue

    $diagnosticSnapshot=$null
    if(Test-Path -LiteralPath $readyDiagnosticPath){
        try{$diagnosticSnapshot=Get-Content -LiteralPath $readyDiagnosticPath -Raw|ConvertFrom-Json}catch{}
    }
    $payload=[ordered]@{
        success=$success
        detail=$detail
        watcherDiagnostic=$diagnosticSnapshot
        labHead=(& git -C $labRoot rev-parse --short HEAD 2>$null).Trim()
        canonicalHead=(& git -C $canonicalRoot rev-parse --short HEAD 2>$null).Trim()
        completedAt=(Get-Date).ToString('o')
    }
    [IO.File]::WriteAllText($resultPath,($payload|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))

    [IO.File]::WriteAllText($restoreSignal,'RESTORE',(New-Object Text.UTF8Encoding($false)))
    Write-Host ('Stable recovery requested. Result: '+$resultPath)
}

if(-not $success){exit 1}
