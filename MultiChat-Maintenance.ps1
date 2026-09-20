param(
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$StateRoot,
    [string]$WorkspaceRoot
)

$ErrorActionPreference='SilentlyContinue'
if($StateRoot){$env:MULTICHAT_STATE_ROOT=[IO.Path]::GetFullPath($StateRoot)}
if($WorkspaceRoot){$env:MULTICHAT_WORKSPACE_ROOT=[IO.Path]::GetFullPath($WorkspaceRoot)}
Import-Module (Join-Path $PSScriptRoot 'ChatMulti.psm1') -Force -DisableNameChecking
$restrictedModule=Join-Path $PSScriptRoot 'RestrictedRemote.psm1'
if(Test-Path -LiteralPath $restrictedModule){
    Import-Module $restrictedModule -Force -DisableNameChecking
}

$started=Get-Date
$expired=@(Expire-IdleManagedChatSessions)
$sessions=@(Get-ManagedChatSessions -ActiveOnly)

$dcOnline=$false
try{
    $restricted=$null
    if(Get-Command Get-RestrictedRemoteConfig -ErrorAction SilentlyContinue){
        $restricted=Get-RestrictedRemoteConfig
    }

    if($restricted){
        $status=Get-RestrictedRemoteStatus
        $launcherPid=if($status){[int]$status.launcherPid}else{0}
        if($status -and [string]$status.state -eq 'RUNNING' -and $launcherPid -gt 0 -and (Get-Process -Id $launcherPid -ErrorAction SilentlyContinue)){
            if(Get-Command Test-RestrictedRemoteReady -ErrorAction SilentlyContinue){
                $dcOnline=[bool](Test-RestrictedRemoteReady)
            }
            if(-not $dcOnline){
                $all=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Select-Object ProcessId,ParentProcessId)
                $tree=New-Object Collections.Generic.List[int]
                [void]$tree.Add($launcherPid)
                for($pass=0;$pass -lt 8;$pass++){
                    $added=$false
                    foreach($proc in $all){
                        if($tree.Contains([int]$proc.ParentProcessId) -and -not $tree.Contains([int]$proc.ProcessId)){
                            [void]$tree.Add([int]$proc.ProcessId)
                            $added=$true
                        }
                    }
                    if(-not $added){break}
                }
                $dcOnline=@(
                    Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
                    Where-Object { $_.OwningProcess -in @($tree) -and $_.RemotePort -eq 443 }
                ).Count -gt 0
            }
        }
    }else{
        $remoteProcesses=@(
            Get-CimInstance Win32_Process |
            Where-Object {
                $_.CommandLine -match 'desktop-commander' -and
                $_.CommandLine -match '\bremote\b'
            }
        )
        $deviceFile=Join-Path $env:USERPROFILE '.desktop-commander-device\device.json'
        $authenticated=$false
        if($remoteProcesses.Count -gt 0 -and (Test-Path -LiteralPath $deviceFile)){
            $device=Get-Content -LiteralPath $deviceFile -Raw|ConvertFrom-Json
            $authenticated=[bool]$device.deviceId -and
                [bool]$device.session.access_token -and
                [bool]$device.session.refresh_token
        }

        $connected=$false
        if($authenticated){
            $remotePids=@($remoteProcesses|Select-Object -ExpandProperty ProcessId)
            $connected=@(
                Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.OwningProcess -in $remotePids -and
                    $_.RemotePort -eq 443
                }
            ).Count -gt 0
        }
        $dcOnline=$authenticated -and $connected
    }
}catch{}

$git=@()
foreach($session in $sessions){
    $summary=Get-ChatGitSummary $session
    $git+=[ordered]@{
        id=[string](Get-ChatProp $session 'id' '')
        hasGit=[bool]$summary.hasGit
        modified=[int]$summary.modified
        untracked=[int]$summary.untracked
        ahead=[int]$summary.ahead
        behind=[int]$summary.behind
        dirty=[bool]$summary.dirty
        text=[string]$summary.text
    }
}

$result=[ordered]@{
    generatedAt=(Get-Date).ToString('o')
    durationMs=[int](((Get-Date)-$started).TotalMilliseconds)
    desktopCommanderOnline=$dcOnline
    activeCount=$sessions.Count
    expiredCount=$expired.Count
    git=$git
}

$directory=Split-Path $ResultFile -Parent
if($directory){
    New-Item -ItemType Directory -Path $directory -Force|Out-Null
}
$tmp="$ResultFile.$PID.tmp"
[IO.File]::WriteAllText(
    $tmp,
    ($result|ConvertTo-Json -Depth 6),
    (New-Object Text.UTF8Encoding($false))
)
Move-Item -LiteralPath $tmp -Destination $ResultFile -Force
