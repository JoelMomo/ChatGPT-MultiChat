$script:ChatConfigCache = $null
$script:ChatConfigStamp = [datetime]::MinValue

function Get-ChatConfig {
    $path = Join-Path $script:ManagerRoot 'config.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing config.json in $($script:ManagerRoot)"
    }

    $stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc
    if ($script:ChatConfigCache -and $script:ChatConfigStamp -eq $stamp) {
        return $script:ChatConfigCache
    }

    $script:ChatConfigCache = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $script:ChatConfigStamp = $stamp
    return $script:ChatConfigCache
}

function Initialize-AdvancedChatState {
    foreach ($path in @(
        (Join-Path $script:StateRoot 'ports'),
        (Join-Path $script:StateRoot 'logs')
    )) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Get-ConfiguredResourceNames {
    param([Parameter(Mandatory)][string]$Line)

    if (Get-Command Resolve-ChatCommandResources -ErrorAction SilentlyContinue) {
        return @(Resolve-ChatCommandResources -Line $Line)
    }

    $cfg = Get-ChatConfig
    $names = @()
    foreach ($rule in @($cfg.resourceRules)) {
        if ($Line -match [string]$rule.pattern) {
            $names += [string]$rule.name
        }
    }
    return @($names | Select-Object -Unique)
}

function Test-ChatPortListening {
    param([Parameter(Mandatory)][int]$Port)

    try {
        return $null -ne (
            Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
        )
    } catch {
        return $false
    }
}

function Claim-ChatPort {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][int]$Slot
    )

    Initialize-AdvancedChatState
    $cfg = Get-ChatConfig
    $portRoot = Join-Path $script:StateRoot 'ports'
    $start = [int]$cfg.portRangeStart
    $count = [int]$cfg.portRangeCount

    for ($port = $start; $port -lt ($start + $count); $port++) {
        $file = Join-Path $portRoot ("port-{0}.json" -f $port)

        if (Test-Path -LiteralPath $file) {
            $old = Read-ChatJson $file
            if ($old -and (Test-ChatProcessAlive ([int](Get-ChatProp $old 'pid' 0)))) {
                continue
            }

            $protected=$false
            $oldSessionId=[string](Get-ChatProp $old 'sessionId' '')
            if ($oldSessionId -and (Get-Command Test-SessionProtectedByLease -ErrorAction SilentlyContinue)) {
                $oldSession=Get-ManagedChatSession -Id $oldSessionId
                if ($oldSession) {$protected=Test-SessionProtectedByLease $oldSession}
            }
            if ($protected) { continue }

            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }

        if (Test-ChatPortListening -Port $port) {
            continue
        }

        try {
            $payload = @{
                sessionId = $SessionId
                slot = $Slot
                pid = $PID
                port = $port
                claimedAt = (Get-Date).ToString('o')
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
            $stream = [IO.File]::Open(
                $file,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            try {
                $stream.Write($bytes,0,$bytes.Length)
            } finally {
                $stream.Dispose()
            }
            return $port
        } catch {}
    }

    return $null
}

function Release-ChatPort {
    param([Parameter(Mandatory)][string]$SessionId)

    $portRoot = Join-Path $script:StateRoot 'ports'
    if (-not (Test-Path -LiteralPath $portRoot)) {
        return
    }

    foreach ($file in Get-ChildItem -LiteralPath $portRoot -Filter 'port-*.json' -File -ErrorAction SilentlyContinue) {
        $reservation = Read-ChatJson $file.FullName
        if ($reservation -and [string](Get-ChatProp $reservation 'sessionId' '') -eq $SessionId) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-RegisteredChatProjects {
    $registryName=if($script:RestrictedRemoteMode){'restricted-projects.json'}else{'projects.json'}
    $path = Join-Path $script:StateRoot $registryName
    if (-not (Test-Path -LiteralPath $path)) {
        return @()
    }

    try {
        $parsed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        return @()
    }

    $valid = @()
    foreach ($item in $parsed) {
        $itemPath = [string](Get-ChatProp $item 'path' '')
        if ([string]::IsNullOrWhiteSpace($itemPath)) {
            continue
        }

        $itemName = [string](Get-ChatProp $item 'name' '')
        if ([string]::IsNullOrWhiteSpace($itemName)) {
            $itemName = Split-Path $itemPath -Leaf
        }

        $valid += [pscustomobject]@{
            name = $itemName
            path = $itemPath
            lastUsed = [string](Get-ChatProp $item 'lastUsed' '')
        }
    }

    return $valid
}

function Register-ChatProject {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $root = (& git -C $Path rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    } catch {
        $root = $null
    }
    if (-not $root) {
        return
    }

    $root = $root.Trim()

    if($script:RestrictedRemoteMode){
        $approved=@(Get-RegisteredChatProjects|Where-Object{
            $candidate=[string](Get-ChatProp $_ 'path' '')
            $candidate -and [string]::Equals(
                [IO.Path]::GetFullPath($candidate).TrimEnd('\'),
                [IO.Path]::GetFullPath($root).TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase
            )
        })
        if($approved.Count -eq 0){
            throw 'Restricted Remote can only use project roots approved during local setup.'
        }
        return
    }

    $name = Split-Path $root -Leaf
    $items = @(
        Get-RegisteredChatProjects |
        Where-Object { [string](Get-ChatProp $_ 'path' '') -ne $root }
    )

    $items += [pscustomobject]@{
        name = $name
        path = $root
        lastUsed = (Get-Date).ToString('o')
    }

    $target = Join-Path $script:StateRoot 'projects.json'
    [IO.File]::WriteAllText(
        $target,
        ($items | Sort-Object name | ConvertTo-Json -Depth 5),
        (New-Object Text.UTF8Encoding($false))
    )
}

function Resolve-ChatProjectPath {
    param(
        [string]$Task = '',
        [string]$CurrentPath = (Get-Location).Path
    )

    try {
        $root = (& git -C $CurrentPath rev-parse --show-toplevel 2>$null | Select-Object -First 1)
        if ($root) {
            $root = $root.Trim()
            if ($root -ne $script:ManagerRoot) {
                return $root
            }
        }
    } catch {}

    $taskLower = $Task.ToLowerInvariant()
    $matches = @(
        Get-RegisteredChatProjects |
        Where-Object {
            $name = [string](Get-ChatProp $_ 'name' '')
            $name -and $taskLower.Contains($name.ToLowerInvariant())
        }
    )
    if ($matches.Count -eq 1) {
        $matchPath = [string](Get-ChatProp $matches[0] 'path' '')
        if ($matchPath -and (Test-Path -LiteralPath $matchPath)) {
            return $matchPath
        }
    }

    $roots = @(
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'source\repos'),
        (Join-Path $env:USERPROFILE 'AndroidStudioProjects')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $candidates = @()
    foreach ($base in $roots) {
        foreach ($directory in Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue) {
            if ($taskLower.Contains($directory.Name.ToLowerInvariant())) {
                $candidates += $directory.FullName
            }
        }
    }

    $candidates = @($candidates | Select-Object -Unique)
    if ($candidates.Count -eq 1) {
        return $candidates[0]
    }
    return $null
}

function Write-ChatHistory {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Reason
    )

    Initialize-AdvancedChatState
    if ((Get-ChatProp $Session 'historyWritten' $false) -eq $true) {
        return
    }

    $ended = Get-Date
    try {
        $started = [DateTimeOffset]::Parse(
            [string](Get-ChatProp $Session 'startedAt' '')
        ).LocalDateTime
    } catch {
        $started = $ended
    }

    $entry = [ordered]@{
        id = [string](Get-ChatProp $Session 'id' '')
        slot = Get-ChatProp $Session 'slot' $null
        project = [string](Get-ChatProp $Session 'project' '')
        task = [string](Get-ChatProp $Session 'task' '')
        reason = $Reason
        status = [string](Get-ChatProp $Session 'status' '')
        startedAt = [string](Get-ChatProp $Session 'startedAt' '')
        endedAt = $ended.ToString('o')
        durationSeconds = [int](($ended-$started).TotalSeconds)
        branch = [string](Get-ChatProp $Session 'branch' '')
        originRepo = [string](Get-ChatProp $Session 'originRepo' '')
        workspace = [string](Get-ChatProp $Session 'workspace' '')
        lastCommand = [string](Get-ChatProp $Session 'lastCommand' '')
        devPort = Get-ChatProp $Session 'devPort' $null
    }

    [IO.File]::AppendAllText(
        (Join-Path $script:StateRoot 'history.jsonl'),
        (($entry | ConvertTo-Json -Compress) + [Environment]::NewLine),
        (New-Object Text.UTF8Encoding($false))
    )
    $Session | Add-Member -NotePropertyName historyWritten -NotePropertyValue $true -Force
}

function Get-ChatHistory {
    param([int]$Limit = 20)

    $path = Join-Path $script:StateRoot 'history.jsonl'
    if (-not (Test-Path -LiteralPath $path)) {
        return @()
    }

    $lines = @(Get-Content -LiteralPath $path -Tail $Limit -ErrorAction SilentlyContinue)
    return @(
        $lines |
        ForEach-Object {
            try { $_ | ConvertFrom-Json } catch {}
        }
    )
}

function Get-ChatProp {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function Get-ChatGitSummary {
    param([Parameter(Mandatory)]$Session)

    $workspace = [string](Get-ChatProp $Session 'workspace' '')
    if (-not $workspace -or -not (Test-Path -LiteralPath $workspace)) {
        return [pscustomobject]@{
            hasGit = $false; modified = 0; untracked = 0
            ahead = 0; behind = 0; dirty = $false; text = ''
        }
    }

    try {
        $topLevelOutput = @(& git -C $workspace rev-parse --show-toplevel 2>$null)
        $topLevelExitCode = $LASTEXITCODE
        $topLevel = $topLevelOutput | Select-Object -First 1
        if ($topLevelExitCode -ne 0 -or -not $topLevel) { throw 'Not a Git worktree' }

        $trimSeparators = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        $workspaceFull = [IO.Path]::GetFullPath($workspace).Replace([IO.Path]::AltDirectorySeparatorChar,[IO.Path]::DirectorySeparatorChar).TrimEnd($trimSeparators)
        $topLevelFull = [IO.Path]::GetFullPath(([string]$topLevel).Trim()).Replace([IO.Path]::AltDirectorySeparatorChar,[IO.Path]::DirectorySeparatorChar).TrimEnd($trimSeparators)
        if (-not [string]::Equals($workspaceFull,$topLevelFull,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Workspace resolves to a parent Git repository'
        }

        $lines = @(& git -C $workspace status --porcelain --untracked-files=all 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'Not a Git worktree' }
    } catch {
        return [pscustomobject]@{
            hasGit = $false; modified = 0; untracked = 0
            ahead = 0; behind = 0; dirty = $false; text = ''
        }
    }

    $untracked = @($lines | Where-Object { $_ -like '??*' }).Count
    $modified = @($lines | Where-Object { $_ -notlike '??*' }).Count
    $ahead = 0
    $behind = 0
    $branch = [string](Get-ChatProp $Session 'branch' '')
    $originRepo = [string](Get-ChatProp $Session 'originRepo' '')
    $workspaceKind = [string](Get-ChatProp $Session 'workspaceKind' '')

    if ($workspaceKind -eq 'clone') {
        $baseSha=[string](Get-ChatProp $Session 'baseSha' '')
        if ($baseSha -match '^[0-9a-fA-F]{40}$') {
            try {
                $countOutput=@(& git -C $workspace rev-list --count "$baseSha..HEAD" 2>$null)
                if ($LASTEXITCODE -eq 0 -and $countOutput) {
                    $ahead=[int]([string]($countOutput|Select-Object -First 1)).Trim()
                }
            } catch {}
        }
    } elseif ($branch -and $originRepo -and (Test-Path -LiteralPath $originRepo)) {
        try {
            $countOutput = @(& git -C $originRepo rev-list --left-right --count "$branch...HEAD" 2>$null)
            $countExitCode = $LASTEXITCODE
            $counts = $countOutput | Select-Object -First 1
            if ($countExitCode -eq 0 -and $counts) {
                $parts = $counts -split '\s+'
                if ($parts.Count -ge 2) {
                    $ahead = [int]$parts[0]
                    $behind = [int]$parts[1]
                }
            }
        } catch {}
    }

    $bits = @()
    if ($modified) { $bits += "~$modified" }
    if ($untracked) { $bits += "?$untracked" }
    if ($ahead) { $bits += "up$ahead" }
    if ($behind) { $bits += "down$behind" }

    return [pscustomobject]@{
        hasGit = $true
        modified = $modified
        untracked = $untracked
        ahead = $ahead
        behind = $behind
        dirty = (($modified+$untracked) -gt 0)
        text = ($bits -join ' ')
    }
}

function Get-WorktreeCleanupCandidateState {
    param([Parameter(Mandatory)]$Session)

    if (Get-Command Get-HardenedWorktreeCleanupCandidateState -ErrorAction SilentlyContinue) {
        return Get-HardenedWorktreeCleanupCandidateState -Session $Session
    }

    $git = Get-ChatGitSummary $Session
    return [pscustomobject]@{
        id = [string](Get-ChatProp $Session 'id' '')
        project = [string](Get-ChatProp $Session 'project' '')
        workspace = [string](Get-ChatProp $Session 'workspace' '')
        originRepo = [string](Get-ChatProp $Session 'originRepo' '')
        branch = [string](Get-ChatProp $Session 'branch' '')
        safe = $false
        reason = if($git.dirty){'DIRTY'}else{'HARDENING_UNAVAILABLE'}
        git = $git
    }
}

function Get-WorktreeCleanupCandidates {
    [CmdletBinding()]
    param([array]$Sessions)

    if (-not $PSBoundParameters.ContainsKey('Sessions')) {
        $Sessions = @()
        foreach ($file in Get-ChildItem -LiteralPath $script:SessionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            $session = Read-ChatJson $file.FullName
            if ($session) { $Sessions += $session }
        }
    }

    $activeWorkspaces = @{}
    foreach ($knownSession in @($Sessions)) {
        if (-not $knownSession) { continue }
        if (-not [bool](Get-ChatProp $knownSession 'active' $false)) { continue }
        $activeWorkspace = [string](Get-ChatProp $knownSession 'workspace' '')
        if ($activeWorkspace) { $activeWorkspaces[$activeWorkspace] = $true }
    }

    $results = @()
    foreach ($session in @($Sessions)) {
        if (-not $session) { continue }
        if ([bool](Get-ChatProp $session 'active' $false)) { continue }
        if (-not [bool](Get-ChatProp $session 'isolated' $false)) { continue }

        # A session can be marked ended just before its shell actually exits.
        # Never auto-clean a worktree while that owner PID is still alive.
        $ownerPid = [int](Get-ChatProp $session 'pid' 0)
        if ($ownerPid -gt 0 -and (Test-ChatProcessAlive $ownerPid)) { continue }

        $workspace = [string](Get-ChatProp $session 'workspace' '')
        $originRepo = [string](Get-ChatProp $session 'originRepo' '')
        if (-not $workspace -or -not $originRepo) { continue }
        if ($activeWorkspaces.ContainsKey($workspace)) { continue }
        if (-not (Test-Path -LiteralPath $workspace)) { continue }

        $results += Get-WorktreeCleanupCandidateState $session
    }
    return $results
}

function Invoke-SafeWorktreeCleanup {
    [CmdletBinding()]
    param(
        [array]$Candidates,
        [switch]$SkipRevalidation
    )

    if (-not $PSBoundParameters.ContainsKey('Candidates')) {
        $Candidates = @(Get-WorktreeCleanupCandidates | Where-Object safe)
    } else {
        $Candidates = @($Candidates | Where-Object { [bool](Get-ChatProp $_ 'safe' $false) })
    }

    $removed = @()
    $reposToPrune = @{}
    foreach ($item in $Candidates) {
        $candidate = if ($SkipRevalidation) { $item } else { Get-WorktreeCleanupCandidateState $item }
        if (-not $candidate.safe) { continue }

        $workspace = [string](Get-ChatProp $candidate 'workspace' '')
        $originRepo = [string](Get-ChatProp $candidate 'originRepo' '')
        if (-not $workspace -or -not $originRepo) { continue }

        $workspaceKind=[string](Get-ChatProp $candidate 'workspaceKind' '')
        if (-not $workspaceKind) {$workspaceKind='worktree'}

        if ($workspaceKind -eq 'clone') {
            # Clone cleanup never trusts an arbitrary session path. The target
            # must still validate as a managed clone and stay under WorkspaceRoot.
            $identity=Get-ManagedWorktreeIdentity -Session $candidate
            if (-not $identity.Valid -or -not (Test-ChatPathWithin -Path $workspace -Root $script:WorkspaceRoot)) {
                continue
            }
            try {
                Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction Stop
            } catch {
                continue
            }
            if (-not (Test-Path -LiteralPath $workspace)) {
                $removed += $candidate
            }
            continue
        }

        $oldErrorActionPreference = $ErrorActionPreference
        $removeExitCode = 1
        try {
            $ErrorActionPreference = 'Continue'
            & git -C $originRepo worktree remove --force $workspace 2>$null | Out-Null
            $removeExitCode = $LASTEXITCODE
        } catch {
            $removeExitCode = 1
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }

        if ($removeExitCode -ne 0) { continue }

        if (-not (Test-Path -LiteralPath $workspace)) {
            $branch = [string](Get-ChatProp $candidate 'branch' '')
            if ($branch) {
                $oldErrorActionPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    & git -C $originRepo branch -D $branch 2>$null | Out-Null
                } catch {
                } finally {
                    $ErrorActionPreference = $oldErrorActionPreference
                }
            }
            $reposToPrune[$originRepo] = $true
            $removed += $candidate
        }
    }

    foreach ($repo in @($reposToPrune.Keys)) {
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & git -C $repo worktree prune 2>$null | Out-Null
        } catch {
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
    }
    return $removed
}

function Get-SessionIdleInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        $GitSummary = $null,
        [switch]$SkipGit
    )

    $cfg = Get-ChatConfig
    try {
        $since = [DateTimeOffset]::Parse([string](Get-ChatProp $Session 'updatedAt' '')).LocalDateTime
    } catch {
        $since = Get-Date
    }

    $minutes = ((Get-Date)-$since).TotalMinutes
    $isReady = ([string](Get-ChatProp $Session 'status' '') -eq 'READY')
    $idleAfter = [int](Get-ChatProp $cfg 'idleAfterMinutes' 10)
    if ($idleAfter -lt 1) { $idleAfter = 10 }

    # A quiet managed shell is not proof that the ChatGPT conversation was
    # abandoned. By default, keep live READY shells allocated until the user
    # closes them or their owner process disappears. Legacy clean/dirty expiry
    # thresholds are only active when explicitly opted in.
    $autoExpire = [bool](Get-ChatProp $cfg 'autoExpireIdleSessions' $false)
    $cleanLimit = [int](Get-ChatProp $cfg 'cleanExpireMinutes' 10)
    $dirtyLimit = [int](Get-ChatProp $cfg 'dirtyExpireMinutes' 20)
    if ($cleanLimit -lt 1) { $cleanLimit = 10 }
    if ($dirtyLimit -lt 1) { $dirtyLimit = 20 }
    $firstExpiryThreshold = [Math]::Min($cleanLimit,$dirtyLimit)

    $git = $GitSummary
    if ($autoExpire -and -not $SkipGit -and $null -eq $git -and $isReady -and $minutes -ge $firstExpiryThreshold) {
        $git = Get-ChatGitSummary $Session
    }

    $dirty = $false
    if ($git -and $git.hasGit) { $dirty = [bool]$git.dirty }
    $limit = if ($dirty) { $dirtyLimit } else { $cleanLimit }
    $idle = ($isReady -and $minutes -ge $idleAfter)

    return [pscustomobject]@{
        isReady = $isReady
        minutes = $minutes
        idle = $idle
        abandoned = $idle
        autoExpireEnabled = $autoExpire
        dirty = $dirty
        expireAfterMinutes = $limit
        expired = ($autoExpire -and $isReady -and $minutes -ge $limit)
    }
}

function Get-ChatPortReservations {
    Initialize-AdvancedChatState

    $portRoot = Join-Path $script:StateRoot 'ports'
    $items = @()
    foreach ($file in Get-ChildItem -LiteralPath $portRoot -Filter 'port-*.json' -File -ErrorAction SilentlyContinue) {
        $reservation = Read-ChatJson $file.FullName
        if (-not $reservation) { continue }

        $pidValue = [int](Get-ChatProp $reservation 'pid' 0)
        if (-not (Test-ChatProcessAlive $pidValue)) {
            $protected=$false
            $sessionId=[string](Get-ChatProp $reservation 'sessionId' '')
            if ($sessionId -and (Get-Command Test-SessionProtectedByLease -ErrorAction SilentlyContinue)) {
                $session=Get-ManagedChatSession -Id $sessionId
                if ($session) {$protected=Test-SessionProtectedByLease $session}
            }
            if (-not $protected) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                continue
            }
        }
        $items += $reservation
    }
    return $items
}

function Get-ProjectConflictGroups {
    param([array]$Sessions = @())

    $withRepos = @($Sessions | Where-Object { [string](Get-ChatProp $_ 'originRepo' '') })
    $groups = @()
    foreach ($group in @($withRepos | Group-Object { [string](Get-ChatProp $_ 'originRepo' '') })) {
        if ($group.Count -gt 1) {
            $groups += [pscustomobject]@{
                originRepo = $group.Name
                count = $group.Count
                sessions = @($group.Group)
            }
        }
    }
    return $groups
}

function Release-SessionReservations {
    param(
        [Parameter(Mandatory)]$Session,
        [switch]$Force
    )

    $sessionId = [string](Get-ChatProp $Session 'id' '')
    if (-not $sessionId) { return $false }

    if (-not $Force -and (Get-Command Test-SessionProtectedByLease -ErrorAction SilentlyContinue)) {
        if (Test-SessionProtectedByLease $Session) { return $false }
    }

    foreach ($lockFile in Get-ChildItem -LiteralPath $script:LockRoot -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $lock = Read-ChatJson $lockFile.FullName
        if ($lock -and [string](Get-ChatProp $lock 'sessionId' '') -eq $sessionId) {
            Remove-Item -LiteralPath $lockFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    Release-ChatPort -SessionId $sessionId

    $slot = Get-ChatProp $Session 'slot' $null
    if ($null -ne $slot) {
        $slotFile = Join-Path $script:SlotRoot ("slot-{0}.json" -f $slot)
        $slotState = Read-ChatJson $slotFile
        if ($slotState -and [string](Get-ChatProp $slotState 'sessionId' '') -eq $sessionId) {
            Remove-Item -LiteralPath $slotFile -Force -ErrorAction SilentlyContinue
        }
    }
    return $true
}
