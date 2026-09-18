function Get-ChatConfig {
    $path = Join-Path $script:ManagerRoot 'config.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Falta config.json en $($script:ManagerRoot)"
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Initialize-AdvancedChatState {
    foreach ($p in @(
        (Join-Path $script:StateRoot 'ports'),
        (Join-Path $script:StateRoot 'logs')
    )) {
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }
}

function Get-ConfiguredResourceNames {
    param([Parameter(Mandatory)][string]$Line)
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
        return $null -ne (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1)
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
            if ($old -and (Test-ChatProcessAlive ([int]$old.pid))) { continue }
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
        if (Test-ChatPortListening -Port $port) { continue }

        try {
            $payload = @{sessionId=$SessionId;slot=$Slot;pid=$PID;port=$port;claimedAt=(Get-Date).ToString('o')}
            $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
            $fs = [IO.File]::Open($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $fs.Write($bytes,0,$bytes.Length) } finally { $fs.Dispose() }
            return $port
        } catch {}
    }
    return $null
}

function Release-ChatPort {
    param([Parameter(Mandatory)][string]$SessionId)
    $portRoot = Join-Path $script:StateRoot 'ports'
    if (-not (Test-Path -LiteralPath $portRoot)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $portRoot -Filter 'port-*.json' -File -ErrorAction SilentlyContinue) {
        $p = Read-ChatJson $file.FullName
        if ($p -and $p.sessionId -eq $SessionId) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-RegisteredChatProjects {
    $path = Join-Path $script:StateRoot 'projects.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { return @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
    catch { return @() }
}
function Register-ChatProject {
    param([Parameter(Mandatory)][string]$Path)
    try { $root = (& git -C $Path rev-parse --show-toplevel 2>$null | Select-Object -First 1) } catch { $root = $null }
    if (-not $root) { return }
    $root = $root.Trim()
    $name = Split-Path $root -Leaf
    $items = @(Get-RegisteredChatProjects | Where-Object { $_.path -ne $root })
    $items += [pscustomobject]@{name=$name;path=$root;lastUsed=(Get-Date).ToString('o')}
    $target = Join-Path $script:StateRoot 'projects.json'
    [IO.File]::WriteAllText($target,($items | Sort-Object name | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
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
            if ($root -ne $script:ManagerRoot) { return $root }
        }
    } catch {}

    $taskLower = $Task.ToLowerInvariant()
    $matches = @(Get-RegisteredChatProjects | Where-Object {
        $taskLower.Contains(([string]$_.name).ToLowerInvariant())
    })
    if ($matches.Count -eq 1 -and (Test-Path -LiteralPath $matches[0].path)) { return [string]$matches[0].path }

    $roots = @(
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'source\repos'),
        (Join-Path $env:USERPROFILE 'AndroidStudioProjects')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $candidates = @()
    foreach ($base in $roots) {
        foreach ($dir in Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue) {
            if ($taskLower.Contains($dir.Name.ToLowerInvariant())) { $candidates += $dir.FullName }
        }
    }
    $candidates = @($candidates | Select-Object -Unique)
    if ($candidates.Count -eq 1) { return $candidates[0] }
    return $null
}

function Write-ChatHistory {
    param($Session,[string]$Reason)
    Initialize-AdvancedChatState
    if ((Get-ChatProp $Session 'historyWritten' $false) -eq $true) { return }
    $ended = Get-Date
    try { $started = [DateTimeOffset]::Parse([string]$Session.startedAt).LocalDateTime } catch { $started = $ended }
    $entry = [ordered]@{
        id=$Session.id; slot=$Session.slot; project=$Session.project; task=$Session.task
        reason=$Reason; status=$Session.status; startedAt=$Session.startedAt; endedAt=$ended.ToString('o')
        durationSeconds=[int](($ended-$started).TotalSeconds); branch=$Session.branch
        originRepo=$Session.originRepo; workspace=$Session.workspace; lastCommand=$Session.lastCommand
        devPort=(Get-ChatProp $Session 'devPort' $null)
    }
    [IO.File]::AppendAllText((Join-Path $script:StateRoot 'history.jsonl'),(($entry|ConvertTo-Json -Compress)+"
"),(New-Object Text.UTF8Encoding($false)))
    $Session | Add-Member -NotePropertyName historyWritten -NotePropertyValue $true -Force
}

function Get-ChatHistory {
    param([int]$Limit = 20)
    $path = Join-Path $script:StateRoot 'history.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $lines = @(Get-Content -LiteralPath $path -Tail $Limit -ErrorAction SilentlyContinue)
    return @($lines | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
}
function Get-ChatGitSummary {
    param($Session)
    $workspace = [string]$Session.workspace
    if (-not $workspace -or -not (Test-Path -LiteralPath $workspace)) {
        return [pscustomobject]@{hasGit=$false;modified=0;untracked=0;ahead=0;behind=0;dirty=$false;text=''}
    }
    try { $gitRoot = (& git -C $workspace rev-parse --show-toplevel 2>$null | Select-Object -First 1) } catch { $gitRoot = $null }
    if (-not $gitRoot) {
        return [pscustomobject]@{hasGit=$false;modified=0;untracked=0;ahead=0;behind=0;dirty=$false;text=''}
    }

    $lines = @(& git -C $workspace status --porcelain 2>$null)
    $untracked = @($lines | Where-Object { $_ -like '??*' }).Count
    $modified = @($lines | Where-Object { $_ -notlike '??*' }).Count
    $ahead = 0
    $behind = 0

    if ($Session.branch -and $Session.originRepo -and (Test-Path -LiteralPath $Session.originRepo)) {
        try {
            $counts = (& git -C $Session.originRepo rev-list --left-right --count "$($Session.branch)...HEAD" 2>$null | Select-Object -First 1)
            if ($counts) {
                $parts = $counts -split '\s+'
                if ($parts.Count -ge 2) { $ahead=[int]$parts[0]; $behind=[int]$parts[1] }
            }
        } catch {}
    }

    $bits = @()
    if ($modified) { $bits += "~$modified" }
    if ($untracked) { $bits += "?$untracked" }
    if ($ahead) { $bits += "up$ahead" }
    if ($behind) { $bits += "down$behind" }
    return [pscustomobject]@{
        hasGit=$true; modified=$modified; untracked=$untracked; ahead=$ahead; behind=$behind
        dirty=(($modified+$untracked) -gt 0); text=($bits -join ' ')
    }
}

function Get-WorktreeCleanupCandidates {
    $results = @()
    foreach ($file in Get-ChildItem -LiteralPath $script:SessionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $s = Read-ChatJson $file.FullName
        if (-not $s -or $s.active -or -not $s.isolated -or -not $s.workspace -or -not $s.originRepo) { continue }
        if (-not (Test-Path -LiteralPath $s.workspace)) { continue }
        $git = Get-ChatGitSummary $s
        $safe = $git.hasGit -and -not $git.dirty -and ($git.ahead -eq 0)
        $reason = if ($safe) {'SAFE'} elseif ($git.dirty) {'DIRTY'} elseif ($git.ahead -gt 0) {'UNMERGED_COMMITS'} else {'UNKNOWN'}
        $results += [pscustomobject]@{
            id=$s.id; project=$s.project; workspace=$s.workspace; originRepo=$s.originRepo
            branch=$s.branch; safe=$safe; reason=$reason; git=$git
        }
    }
    return $results
}

function Invoke-SafeWorktreeCleanup {
    $removed = @()
    foreach ($item in @(Get-WorktreeCleanupCandidates | Where-Object safe)) {
        & git -C $item.originRepo worktree remove --force $item.workspace 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $item.workspace)) {
            if ($item.branch) { & git -C $item.originRepo branch -D $item.branch 2>$null | Out-Null }
            $removed += $item
        }
    }
    return $removed
}
function Get-ChatProp {
    param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

function Get-SessionIdleInfo {
    param($Session)
    $cfg = Get-ChatConfig
    try { $since = [DateTimeOffset]::Parse([string]$Session.updatedAt).LocalDateTime }
    catch { $since = Get-Date }
    $minutes = ((Get-Date) - $since).TotalMinutes
    $isReady = ([string]$Session.status -eq 'READY')
    $git = if ($isReady) { Get-ChatGitSummary $Session } else { $null }
    $dirty = $false
    if ($git -and $git.hasGit) { $dirty = [bool]$git.dirty }
    $limit = if ($dirty) { [int]$cfg.dirtyExpireMinutes } else { [int]$cfg.cleanExpireMinutes }
    return [pscustomobject]@{
        isReady=$isReady
        minutes=$minutes
        abandoned=($isReady -and $minutes -ge [int]$cfg.abandonedAfterMinutes)
        dirty=$dirty
        expireAfterMinutes=$limit
        expired=($isReady -and $minutes -ge $limit)
    }
}

function Get-ChatPortReservations {
    Initialize-AdvancedChatState
    $portRoot = Join-Path $script:StateRoot 'ports'
    $items = @()
    foreach ($file in Get-ChildItem -LiteralPath $portRoot -Filter 'port-*.json' -File -ErrorAction SilentlyContinue) {
        $p = Read-ChatJson $file.FullName
        if (-not $p) { continue }
        if (-not (Test-ChatProcessAlive ([int]$p.pid))) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        $items += $p
    }
    return $items
}

function Get-ProjectConflictGroups {
    param([array]$Sessions = @())
    $groups = @()
    foreach ($g in @($Sessions | Where-Object { $_.originRepo } | Group-Object originRepo)) {
        if ($g.Count -gt 1) {
            $groups += [pscustomobject]@{originRepo=$g.Name;count=$g.Count;sessions=@($g.Group)}
        }
    }
    return $groups
}
function Release-SessionReservations {
    param([Parameter(Mandatory)]$Session)
    $sessionId = [string]$Session.id

    foreach ($lockFile in Get-ChildItem -LiteralPath $script:LockRoot -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $lock = Read-ChatJson $lockFile.FullName
        if ($lock -and $lock.sessionId -eq $sessionId) {
            Remove-Item -LiteralPath $lockFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    Release-ChatPort -SessionId $sessionId

    $slotFile = Join-Path $script:SlotRoot ("slot-{0}.json" -f $Session.slot)
    $slot = Read-ChatJson $slotFile
    if ($slot -and $slot.sessionId -eq $sessionId) {
        Remove-Item -LiteralPath $slotFile -Force -ErrorAction SilentlyContinue
    }
}
