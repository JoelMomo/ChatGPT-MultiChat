Set-StrictMode -Version Latest

$script:ManagerRoot = $PSScriptRoot
$script:StateRoot = Join-Path $script:ManagerRoot 'state'
$script:SessionRoot = Join-Path $script:StateRoot 'sessions'
$script:LockRoot = Join-Path $script:StateRoot 'locks'
$script:SlotRoot = Join-Path $script:StateRoot 'slots'
$script:WorkspaceRoot = Join-Path $script:ManagerRoot 'workspaces'
$script:AutoResourceLocks = @()

function Initialize-ChatMulti {
    foreach ($p in @($script:SessionRoot,$script:LockRoot,$script:SlotRoot,$script:WorkspaceRoot)) {
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
}

function Get-ChatEmoji([int]$Slot) {
    return '#'
}

function Get-ChatColor([int]$Slot) {
    # Deliberately high-contrast, stable color per slot.
    $colors = @('Green','Cyan','Magenta','Yellow','Blue','Red','White','DarkCyan')
    return $colors[($Slot-1) % $colors.Count]
}

function Test-ChatProcessAlive([int]$PidValue) {
    if ($PidValue -le 0) { return $false }
    return $null -ne (Get-Process -Id $PidValue -ErrorAction SilentlyContinue)
}
function Read-ChatJson([string]$Path) {
    try { return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch { return $null }
}

function Write-ChatJson([string]$Path, $Object) {
    $tmp = "$Path.$PID.tmp"
    $json = $Object | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-ManagedChatSession {
    param([string]$Id = $env:CHATGPT_SESSION_ID)
    if (-not $Id) { return $null }
    return Read-ChatJson (Join-Path $script:SessionRoot "$Id.json")
}

function Get-ManagedChatSessions {
    [CmdletBinding()]
    param(
        [switch]$SkipLivenessCheck,
        [switch]$ActiveOnly
    )

    Initialize-ChatMulti
    $sessionFiles = @()

    if ($ActiveOnly) {
        $seen = @{}
        foreach ($slotFile in Get-ChildItem -LiteralPath $script:SlotRoot -Filter 'slot-*.json' -File -ErrorAction SilentlyContinue) {
            $slotState = Read-ChatJson $slotFile.FullName
            $sessionId = [string](Get-ChatProp $slotState 'sessionId' '')
            if (-not $sessionId -or $seen.ContainsKey($sessionId)) { continue }

            $sessionFile = Join-Path $script:SessionRoot "$sessionId.json"
            if (Test-Path -LiteralPath $sessionFile) {
                $seen[$sessionId] = $true
                $sessionFiles += Get-Item -LiteralPath $sessionFile
            }
        }
    } else {
        $sessionFiles = @(
            Get-ChildItem -LiteralPath $script:SessionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue
        )
    }

    $items = @()
    foreach ($file in $sessionFiles) {
        $s = Read-ChatJson $file.FullName
        if ($null -eq $s) { continue }

        if (-not $SkipLivenessCheck) {
            $alive = Test-ChatProcessAlive ([int](Get-ChatProp $s 'pid' 0))
            if ([bool](Get-ChatProp $s 'active' $false) -and -not $alive) {
                $protected=$false
                if (Get-Command Test-SessionProtectedByLease -ErrorAction SilentlyContinue) {
                    $protected=Test-SessionProtectedByLease $s
                }

                if ($protected) {
                    $s.active = $true
                    $s.status = 'LEASED_EXTERNAL'
                    $s | Add-Member -NotePropertyName shellAlive -NotePropertyValue $false -Force
                    Write-ChatJson $file.FullName $s
                } else {
                    $s.active = $false
                    $s.status = 'STALE'
                    $s.updatedAt = (Get-Date).ToString('o')
                    Release-SessionReservations $s | Out-Null
                    Write-ChatHistory $s 'PROCESS_GONE'
                    Write-ChatJson $file.FullName $s
                }
            }
        }

        if (-not $ActiveOnly -or [bool](Get-ChatProp $s 'active' $false)) {
            $items += $s
        }
    }
    return $items
}

function Expire-IdleManagedChatSessions {
    [CmdletBinding()]
    param(
        [int]$IdleMinutes = 0,
        [string[]]$SessionId=@()
    )

    Initialize-ChatMulti
    $now = Get-Date
    $expired = @()

    foreach ($s in @(Get-ManagedChatSessions -ActiveOnly -SkipLivenessCheck)) {
        if ($SessionId.Count -and [string](Get-ChatProp $s 'id' '') -notin $SessionId) { continue }
        if (Get-Command Test-SessionProtectedByLease -ErrorAction SilentlyContinue) {
            if (Test-SessionProtectedByLease $s) { continue }
        }
        if ([string](Get-ChatProp $s 'status' '') -ne 'READY') { continue }

        $idle = Get-SessionIdleInfo $s
        $shouldExpire = if ($IdleMinutes -gt 0) {
            $idle.minutes -ge $IdleMinutes
        } else {
            $idle.expired
        }
        if (-not $shouldExpire) { continue }

        $pidToStop = [int](Get-ChatProp $s 'pid' 0)
        $s.active = $false
        $s.status = if ($idle.dirty) { 'IDLE_EXPIRED_DIRTY' } else { 'IDLE_EXPIRED' }
        $s.updatedAt = $now.ToString('o')
        Release-SessionReservations $s
        Write-ChatHistory $s 'IDLE_EXPIRED'
        Write-ChatJson (Join-Path $script:SessionRoot "$($s.id).json") $s
        $expired += $s

        if ($pidToStop -gt 0 -and $pidToStop -ne $PID -and (Test-ChatProcessAlive $pidToStop)) {
            Stop-Process -Id $pidToStop -Force -ErrorAction SilentlyContinue
        }
    }

    return $expired
}

function Claim-ChatSlot([string]$SessionId) {
    Initialize-ChatMulti
    Expire-IdleManagedChatSessions | Out-Null
    $maxSlots = [int](Get-ChatConfig).maxSlots
    for ($slot=1; $slot -le $maxSlots; $slot++) {
        $slotFile = Join-Path $script:SlotRoot ("slot-{0}.json" -f $slot)
        if (Test-Path $slotFile) {
            $old = Read-ChatJson $slotFile
            if ($old -and (Test-ChatProcessAlive ([int](Get-ChatProp $old 'pid' 0)))) { continue }

            $oldSession=$null
            $oldSessionId=[string](Get-ChatProp $old 'sessionId' '')
            if ($oldSessionId) {$oldSession=Get-ManagedChatSession -Id $oldSessionId}
            if ($oldSession -and (Get-Command Test-SessionProtectedByLease -ErrorAction SilentlyContinue)) {
                if (Test-SessionProtectedByLease $oldSession) { continue }
            }

            Remove-Item $slotFile -Force -ErrorAction SilentlyContinue
        }
        try {
            $payload = @{sessionId=$SessionId;pid=$PID;claimedAt=(Get-Date).ToString('o')}
            $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
            $fs = [IO.File]::Open($slotFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $fs.Write($bytes,0,$bytes.Length) } finally { $fs.Dispose() }
            return $slot
        } catch {}
    }
    throw ("No free slots remain (maximum {0} simultaneous managed sessions)." -f $maxSlots)
}

function Resolve-ChatCommandStatus([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return 'READY' }
    $x = $Line.ToLowerInvariant()
    if ($x -match '(^|[ ;|&])(emulator|avdmanager|sdkmanager)(\.exe)?\b') { return 'EMULATOR' }
    if ($x -match '(^|[ ;|&])(adb|fastboot|scrcpy)(\.exe)?\b|gradlew.*\binstall|install.*\.apk') { return 'ADB' }
    if ($x -match 'gradlew.*(assemble|build|bundle)|npm\s+run\s+build|pnpm.*\bbuild\b|yarn.*\bbuild\b|dotnet\s+build') { return 'BUILD' }
    if ($x -match 'pytest|jest|vitest|gradlew.*\btest\b|npm\s+(run\s+)?test\b|pnpm.*\btest\b|yarn.*\btest\b|dotnet\s+test\b|go\s+test\b|cargo\s+test\b') { return 'TEST' }
    if ($x -match '(^|[ ;|&])start-sleep\b|(^|[ ;|&])timeout\b') { return 'WAIT' }
    if ($x -match '(^|[ ;|&])git\b') { return 'GIT' }
    if ($x -match 'npm\s+run\s+(dev|start)|pnpm\s+(dev|start)|yarn\s+(dev|start)|vite\b|next\s+dev|python.*http\.server') { return 'SERVER' }
    if ($x -match '(^|[ ;|&])(npm|pnpm|yarn|node)\b') { return 'NODE' }
    if ($x -match '(^|[ ;|&])(python|py)\b') { return 'PYTHON' }
    return 'RUN'
}
function Set-ManagedChatState {
    param([string]$Status='READY',[string]$LastCommand='')
    $s = Get-ManagedChatSession
    if ($null -eq $s) { return }
    $s.status = $Status
    $s.updatedAt = (Get-Date).ToString('o')
    if ($LastCommand) { $s.lastCommand = $LastCommand }
    if ($s.workspace -and (Test-Path -LiteralPath $s.workspace)) {
        try {
            $b = (& git -C $s.workspace branch --show-current 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0 -and $b) { $s.branch = $b.Trim() }
        } catch {}
    }
    Write-ChatJson (Join-Path $script:SessionRoot "$($s.id).json") $s
    Set-ManagedChatWindowTitle -State $s
}

function Set-ManagedChatWindowTitle {
    param($State = (Get-ManagedChatSession))
    if ($null -eq $State) { return }
    $emoji = Get-ChatEmoji ([int]$State.slot)
    $branch = if ($State.branch) { " | $($State.branch)" } else { '' }
    try { $Host.UI.RawUI.WindowTitle = "$emoji CHAT-$($State.slot) | $($State.project)$branch | $($State.status)" } catch {}
}
function Get-ChatResourceLock {
    param([Parameter(Mandatory)][string]$Resource)
    $name = ($Resource -replace '[^a-zA-Z0-9._-]','_').ToLowerInvariant()
    $path = Join-Path $script:LockRoot "$name.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Read-ChatJson $path
}

function Acquire-ChatResource {
    param(
        [Parameter(Mandatory)][string]$Resource,
        [string]$SessionId=$env:CHATGPT_SESSION_ID,
        [string]$LeaseId=''
    )
    Initialize-ChatMulti
    if (-not $SessionId) { throw 'This operation requires a managed ChatGPT session.' }
    $s = Get-ManagedChatSession -Id $SessionId
    if ($null -eq $s) { throw "Managed session '$SessionId' was not found." }
    $name = ($Resource -replace '[^a-zA-Z0-9._-]','_').ToLowerInvariant()
    $path = Join-Path $script:LockRoot "$name.json"

    if (Get-Command Test-ChatResourceIdentityConflict -ErrorAction SilentlyContinue) {
        foreach($lockFile in Get-ChildItem -LiteralPath $script:LockRoot -Filter '*.json' -File -ErrorAction SilentlyContinue){
            $existing=Read-ChatJson $lockFile.FullName
            if (-not $existing) {
                Remove-Item $lockFile.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            $existingResource=[string](Get-ChatProp $existing 'resource' '')
            if (-not $existingResource -or -not (Test-ChatResourceIdentityConflict -Requested $Resource -Existing $existingResource)) {
                continue
            }

            $existingSessionId=[string](Get-ChatProp $existing 'sessionId' '')
            if ($existingSessionId -eq $s.id) { continue }

            $existingAlive=Test-ChatProcessAlive ([int](Get-ChatProp $existing 'pid' 0))
            $existingProtected=$false
            if ($existingSessionId) {
                $existingSession=Get-ManagedChatSession -Id $existingSessionId
                if ($existingSession) {$existingProtected=Test-SessionProtectedByLease $existingSession}
            }

            if ($existingAlive -or $existingProtected) {
                Write-Host ("Resource '{0}' conflicts with '{1}' held by CHAT-{2} ({3})." -f $Resource,$existingResource,(Get-ChatProp $existing 'slot' '?'),(Get-ChatProp $existing 'project' 'unknown')) -ForegroundColor Red
                return $false
            }

            Remove-Item $lockFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path $path) {
        $old = Read-ChatJson $path
        if ($old -and [string](Get-ChatProp $old 'sessionId' '') -eq $s.id) {
            $oldLease=[string](Get-ChatProp $old 'leaseId' '')
            if ($LeaseId -and $oldLease -ne $LeaseId) {
                Write-Host ("Resource '{0}' is already held by this session under another owner." -f $Resource) -ForegroundColor Red
                return $false
            }
            return $true
        }

        $oldAlive=$old -and (Test-ChatProcessAlive ([int](Get-ChatProp $old 'pid' 0)))
        $oldProtected=$false
        if ($old) {
            $oldSessionId=[string](Get-ChatProp $old 'sessionId' '')
            if ($oldSessionId -and (Get-Command Test-SessionProtectedByLease -ErrorAction SilentlyContinue)) {
                $oldSession=Get-ManagedChatSession -Id $oldSessionId
                if ($oldSession) {$oldProtected=Test-SessionProtectedByLease $oldSession}
            }
        }

        if ($oldAlive -or $oldProtected) {
            Write-Host ("Resource '{0}' is in use by CHAT-{1} ({2})." -f $Resource,(Get-ChatProp $old 'slot' '?'),(Get-ChatProp $old 'project' 'unknown')) -ForegroundColor Red
            return $false
        }
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }

    try {
        $payload = @{
            resource=$Resource
            sessionId=$s.id
            slot=$s.slot
            project=$s.project
            pid=$PID
            leaseId=$LeaseId
            claimedAt=(Get-Date).ToString('o')
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
        $fs = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $fs.Write($bytes,0,$bytes.Length) } finally { $fs.Dispose() }
        return $true
    } catch {
        Write-Host ("Could not acquire lock for '{0}'." -f $Resource) -ForegroundColor Red
        return $false
    }
}

function Release-ChatResource {
    param(
        [Parameter(Mandatory)][string]$Resource,
        [string]$SessionId=$env:CHATGPT_SESSION_ID,
        [string]$LeaseId=''
    )
    if (-not $SessionId) { return }
    $name = ($Resource -replace '[^a-zA-Z0-9._-]','_').ToLowerInvariant()
    $path = Join-Path $script:LockRoot "$name.json"
    $lock = Read-ChatJson $path
    if (-not $lock) { return }
    if ([string](Get-ChatProp $lock 'sessionId' '') -ne $SessionId) { return }

    $lockLease=[string](Get-ChatProp $lock 'leaseId' '')
    if ($LeaseId -and $lockLease -ne $LeaseId) { return }
    if (-not $LeaseId -and $lockLease) { return }

    Remove-Item $path -Force -ErrorAction SilentlyContinue
}

function Get-ChatResourceLocks {
    Initialize-ChatMulti
    foreach ($file in Get-ChildItem -LiteralPath $script:LockRoot -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $l = Read-ChatJson $file.FullName
        if (-not $l) {
            Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            continue
        }

        $alive=Test-ChatProcessAlive ([int](Get-ChatProp $l 'pid' 0))
        $protected=$false
        $ownerId=[string](Get-ChatProp $l 'sessionId' '')
        if ($ownerId -and (Get-Command Test-SessionProtectedByLease -ErrorAction SilentlyContinue)) {
            $owner=Get-ManagedChatSession -Id $ownerId
            if ($owner) {$protected=Test-SessionProtectedByLease $owner}
        }

        if ($alive -or $protected) { $l }
        else { Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Install-ManagedChatPrompt {
    if (-not $env:CHATGPT_SESSION_ID) { throw 'There is no active managed session.' }

    function global:prompt {
        try {
            if ($script:AutoResourceLocks.Count) {
                foreach($resource in @($script:AutoResourceLocks)){
                    Release-ChatResource -Resource $resource
                }
                $script:AutoResourceLocks=@()
            }
            Set-ManagedChatState -Status 'READY'
            $s = Get-ManagedChatSession
            $emoji = Get-ChatEmoji ([int]$s.slot)
            $color = Get-ChatColor ([int]$s.slot)
            Write-Host "$emoji [CHAT-$($s.slot)] " -NoNewline -ForegroundColor $color
            Write-Host "$($s.project)" -NoNewline -ForegroundColor White
            if ($s.branch) { Write-Host " | $($s.branch)" -NoNewline -ForegroundColor DarkGray }
            Write-Host " | READY" -ForegroundColor Green
            return "$(Get-Location)> "
        } catch {
            return "PS $(Get-Location)> "
        }
    }

    if (Get-Module PSReadLine -ErrorAction SilentlyContinue) {
        Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {
            $line = $null
            $cursor = 0
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line,[ref]$cursor)
            $status = Resolve-ChatCommandStatus $line

            $resources=@(Get-ConfiguredResourceNames -Line $line)
            $acquired=@()
            foreach($resource in $resources){
                if (Acquire-ChatResource -Resource $resource) {
                    $acquired+=$resource
                } else {
                    foreach($held in $acquired){Release-ChatResource -Resource $held}
                    Write-Host ''
                    Write-Host ("Command blocked: resource '{0}' is already in use." -f $resource) -ForegroundColor Red
                    return
                }
            }
            $script:AutoResourceLocks=$acquired
            Set-ManagedChatState -Status $status -LastCommand $line
            [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        }
    }
    Set-ManagedChatWindowTitle
}

function New-ManagedChatSession {
    [CmdletBinding()]
    param(
        [string]$ProjectPath,
        [string]$Task = 'work',
        [switch]$NoWorktree,
        [string]$BaseRef,
        [string]$BaseSha,
        [string]$CanonicalRef
    )

    Initialize-ChatMulti
    Initialize-HardeningState

    $id='session-'+[guid]::NewGuid().ToString('N').Substring(0,12)
    $slot=Claim-ChatSlot $id
    $emoji=Get-ChatEmoji $slot
    $color=Get-ChatColor $slot

    $workspace=$script:ManagerRoot
    $project='General'
    $originRepo=$null
    $branch=$null
    $isolated=$false
    $devPort=$null
    $baseInfo=$null
    $canonicalShaAtStart=''
    $createdWorktree=$false

    try {
        if (-not $ProjectPath) {
            $ProjectPath=Resolve-ChatProjectPath -Task $Task -CurrentPath (Get-Location).Path
        }

        if ($ProjectPath) {
            $resolved=(Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop).Path
            $workspace=$resolved
            $project=Split-Path $resolved -Leaf

            $repoOutput=@(& git -C $resolved rev-parse --show-toplevel 2>$null)
            $repoExit=$LASTEXITCODE
            $repoRoot=$repoOutput | Select-Object -First 1
            if ($repoExit -eq 0 -and $repoRoot) {
                $repoRoot=([string]$repoRoot).Trim()
                $originRepo=$repoRoot
                $project=Split-Path $repoRoot -Leaf
                Register-ChatProject -Path $repoRoot

                $baseInfo=Resolve-ExactGitBase -Repo $repoRoot -BaseRef $BaseRef -BaseSha $BaseSha
                if ($CanonicalRef) {
                    $canonicalShaAtStart=Resolve-ChatCanonicalRef -Repo $repoRoot -CanonicalRef $CanonicalRef
                }

                if (-not $NoWorktree) {
                    $slug=($Task.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
                    if (-not $slug) {$slug='work'}
                    if ($slug.Length -gt 28) {$slug=$slug.Substring(0,28).Trim('-')}

                    $branch="chat/$slot/$slug-"+(Get-Date -Format 'HHmmss')+'-'+$id.Substring($id.Length-4)
                    $workspace=Join-Path (Join-Path $script:WorkspaceRoot $project) $id
                    New-Item -ItemType Directory -Path (Split-Path $workspace -Parent) -Force | Out-Null

                    & git -C $repoRoot worktree add -b $branch $workspace $baseInfo.BaseSha | Out-Null
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $workspace '.git'))) {
                        throw 'Could not create the isolated Git worktree from the requested base.'
                    }
                    $createdWorktree=$true
                    $isolated=$true

                    $headCheck=Invoke-ChatGitCapture -Repo $workspace -Arguments @('rev-parse','HEAD^{commit}')
                    if ($headCheck.ExitCode -ne 0 -or -not $headCheck.First) {
                        throw 'Could not verify the new worktree HEAD.'
                    }
                    $createdHead=([string]$headCheck.First).Trim().ToLowerInvariant()
                    if ($createdHead -ne $baseInfo.BaseSha) {
                        throw "Worktree base mismatch: created at $createdHead, expected $($baseInfo.BaseSha)."
                    }
                } else {
                    $branchOutput=@(& git -C $workspace branch --show-current 2>$null)
                    if ($LASTEXITCODE -eq 0) {$branch=($branchOutput | Select-Object -First 1)}
                    if ($baseInfo.ExactRequested) {
                        $headCheck=Invoke-ChatGitCapture -Repo $workspace -Arguments @('rev-parse','HEAD^{commit}')
                        $currentHead=if($headCheck.First){([string]$headCheck.First).Trim().ToLowerInvariant()}else{''}
                        if ($headCheck.ExitCode -ne 0 -or $currentHead -ne $baseInfo.BaseSha) {
                            throw "NoWorktree exact-base mismatch: current HEAD is '$currentHead', expected '$($baseInfo.BaseSha)'."
                        }
                    }
                }
            } elseif ($BaseRef -or $BaseSha -or $CanonicalRef) {
                throw 'BaseRef/BaseSha/CanonicalRef require ProjectPath to resolve to a Git repository.'
            }
        }

        $devPort=Claim-ChatPort -SessionId $id -Slot $slot

        $env:CHATGPT_SESSION_ID=$id
        $env:CHATGPT_SLOT=[string]$slot
        $env:CHATGPT_PROJECT=$project
        $env:CHATGPT_WORKSPACE=$workspace
        if ($baseInfo) {
            $env:CHATGPT_BASE_REF=[string]$baseInfo.BaseRef
            $env:CHATGPT_BASE_SHA=[string]$baseInfo.BaseSha
        }
        if ($CanonicalRef) {$env:CHATGPT_CANONICAL_REF=$CanonicalRef}
        if ($devPort) {
            $env:CHATGPT_PORT=[string]$devPort
            $env:PORT=[string]$devPort
        }

        $state=[ordered]@{
            schemaVersion=2
            id=$id;slot=$slot;emoji=$emoji;color=$color;project=$project;task=$Task
            workspace=$workspace;originRepo=$originRepo;branch=$branch;isolated=$isolated
            baseRef=if($baseInfo){[string]$baseInfo.BaseRef}else{''}
            baseSha=if($baseInfo){[string]$baseInfo.BaseSha}else{''}
            exactBaseRequested=if($baseInfo){[bool]$baseInfo.ExactRequested}else{$false}
            canonicalRef=[string]$CanonicalRef
            canonicalShaAtStart=[string]$canonicalShaAtStart
            pid=$PID;active=$true;shellAlive=$true;status='READY';lastCommand=''
            devPort=$devPort;historyWritten=$false
            startedAt=(Get-Date).ToString('o');updatedAt=(Get-Date).ToString('o')
        }
        Write-ChatJson (Join-Path $script:SessionRoot "$id.json") $state
        Set-Location -LiteralPath $workspace
        Set-ManagedChatWindowTitle -State $state
        return [pscustomobject]$state
    } catch {
        if ($createdWorktree -and $originRepo -and $workspace) {
            try { & git -C $originRepo worktree remove --force $workspace 2>$null | Out-Null } catch {}
        }
        if ($branch -and $originRepo) {
            try { & git -C $originRepo branch -D $branch 2>$null | Out-Null } catch {}
        }
        if ($devPort) {Release-ChatPort -SessionId $id}

        $slotFile=Join-Path $script:SlotRoot ("slot-{0}.json" -f $slot)
        $slotState=Read-ChatJson $slotFile
        if ($slotState -and [string](Get-ChatProp $slotState 'sessionId' '') -eq $id) {
            Remove-Item -LiteralPath $slotFile -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Stop-ManagedChatSession {
    $s = Get-ManagedChatSession
    if ($null -eq $s) { return }

    $protected=$false
    if (Get-Command Test-SessionProtectedByLease -ErrorAction SilentlyContinue) {
        $protected=Test-SessionProtectedByLease $s
    }

    $s | Add-Member -NotePropertyName shellAlive -NotePropertyValue $false -Force
    $s.updatedAt=(Get-Date).ToString('o')
    if ($protected) {
        $s.active=$true
        $s.status='LEASED_EXTERNAL'
        Write-ChatJson (Join-Path $script:SessionRoot "$($s.id).json") $s
        return
    }

    $s.active=$false
    $s.status='ENDED'
    Release-SessionReservations $s | Out-Null
    Write-ChatHistory $s 'NORMAL_EXIT'
    Write-ChatJson (Join-Path $script:SessionRoot "$($s.id).json") $s
}
function Show-ManagedChatStatus {
    $sessions = @(Get-ManagedChatSessions | Where-Object active | Sort-Object slot)
    if (-not $sessions.Count) {
        Write-Host 'There are no active managed sessions.'
        return
    }

    foreach ($s in $sessions) {
        $emoji = Get-ChatEmoji ([int]$s.slot)
        $color = Get-ChatColor ([int]$s.slot)
        $branch = if ($s.branch) { " | $($s.branch)" } else { '' }
        Write-Host ("{0} CHAT-{1} | {2}{3} | {4} | {5}" -f $emoji,$s.slot,$s.project,$branch,$s.status,$s.task) -ForegroundColor $color
        if ($s.lastCommand) {
            Write-Host ("   last: " + $s.lastCommand) -ForegroundColor DarkGray
        }
    }

    foreach ($l in @(Get-ChatResourceLocks)) {
        Write-Host ("   LOCK {0} -> CHAT-{1} ({2})" -f $l.resource,$l.slot,$l.project) -ForegroundColor Yellow
    }
}

. (Join-Path $PSScriptRoot 'ChatMulti.Advanced.ps1')
. (Join-Path $PSScriptRoot 'ChatMulti.Hardening.ps1')

Export-ModuleMember -Function Initialize-ChatMulti,Get-ChatColor,Get-ChatConfig,Get-ManagedChatSession,Get-ManagedChatSessions,Expire-IdleManagedChatSessions,New-ManagedChatSession,Stop-ManagedChatSession,Install-ManagedChatPrompt,Set-ManagedChatState,Show-ManagedChatStatus,Acquire-ChatResource,Release-ChatResource,Get-ChatResourceLock,Get-ChatResourceLocks,Resolve-ChatCommandStatus,Get-ConfiguredResourceNames,Resolve-ChatCommandResources,Resolve-AndroidCommandResources,Invoke-WithChatResource,Invoke-WithChatResources,Invoke-WithChatLease,New-ChatLease,Update-ChatLease,Close-ChatLease,Get-ChatLeases,Get-SessionLeaseState,Test-SessionProtectedByLease,Resolve-ExactGitBase,Resolve-ChatCanonicalRef,Get-ManagedWorktreeIdentity,Get-ManagedCommitSafety,Test-ManagedChatSessionInvariant,Claim-ChatPort,Release-ChatPort,Get-RegisteredChatProjects,Register-ChatProject,Resolve-ChatProjectPath,Get-ChatHistory,Get-ChatGitSummary,Get-WorktreeCleanupCandidates,Invoke-SafeWorktreeCleanup,Get-SessionIdleInfo,Get-ChatPortReservations,Get-ProjectConflictGroups,Get-ChatProp
