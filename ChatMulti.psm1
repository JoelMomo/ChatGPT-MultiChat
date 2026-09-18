Set-StrictMode -Version Latest

$script:ManagerRoot = $PSScriptRoot
$script:StateRoot = Join-Path $script:ManagerRoot 'state'
$script:SessionRoot = Join-Path $script:StateRoot 'sessions'
$script:LockRoot = Join-Path $script:StateRoot 'locks'
$script:SlotRoot = Join-Path $script:StateRoot 'slots'
$script:WorkspaceRoot = Join-Path $script:ManagerRoot 'workspaces'
$script:AutoResourceLock = $null

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
    Initialize-ChatMulti
    $items = @()
    foreach ($file in Get-ChildItem -LiteralPath $script:SessionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $s = Read-ChatJson $file.FullName
        if ($null -eq $s) { continue }
        $alive = Test-ChatProcessAlive ([int]$s.pid)
        if ($s.active -and -not $alive) {
            $s.active = $false
            $s.status = 'STALE'
            $s.updatedAt = (Get-Date).ToString('o')
            Release-SessionReservations $s
            Write-ChatHistory $s 'PROCESS_GONE'
            Write-ChatJson $file.FullName $s
        }
        $items += $s
    }
    return $items
}

function Expire-IdleManagedChatSessions {
    [CmdletBinding()]
    param([int]$IdleMinutes = 0)

    Initialize-ChatMulti
    $now = Get-Date
    $expired = @()

    foreach ($file in Get-ChildItem -LiteralPath $script:SessionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $s = Read-ChatJson $file.FullName
        if ($null -eq $s -or -not $s.active -or $s.status -ne 'READY') { continue }

        $idle = Get-SessionIdleInfo $s
        $shouldExpire = if ($IdleMinutes -gt 0) { $idle.minutes -ge $IdleMinutes } else { $idle.expired }
        if (-not $shouldExpire) { continue }

        $pidToStop = [int]$s.pid
        $s.active = $false
        $s.status = if ($idle.dirty) { 'IDLE_EXPIRED_DIRTY' } else { 'IDLE_EXPIRED' }
        $s.updatedAt = $now.ToString('o')
        Release-SessionReservations $s
        Write-ChatHistory $s 'IDLE_EXPIRED'
        Write-ChatJson $file.FullName $s
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
            if ($old -and (Test-ChatProcessAlive ([int]$old.pid))) { continue }
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
    throw ("No quedan slots libres (maximo {0} sesiones gestionadas simultaneas)." -f $maxSlots)
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
function Acquire-ChatResource {
    param([Parameter(Mandatory)][string]$Resource)
    Initialize-ChatMulti
    $s = Get-ManagedChatSession
    if ($null -eq $s) { throw 'Esta PowerShell no es una sesion ChatGPT gestionada.' }
    $name = ($Resource -replace '[^a-zA-Z0-9._-]','_').ToLowerInvariant()
    $path = Join-Path $script:LockRoot "$name.json"

    if (Test-Path $path) {
        $old = Read-ChatJson $path
        if ($old -and $old.sessionId -eq $s.id) { return $true }
        if ($old -and (Test-ChatProcessAlive ([int]$old.pid))) {
            Write-Host ("Recurso '{0}' ocupado por CHAT-{1} ({2})." -f $Resource,$old.slot,$old.project) -ForegroundColor Red
            return $false
        }
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }

    try {
        $payload = @{resource=$Resource;sessionId=$s.id;slot=$s.slot;project=$s.project;pid=$PID;claimedAt=(Get-Date).ToString('o')}
        $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
        $fs = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $fs.Write($bytes,0,$bytes.Length) } finally { $fs.Dispose() }
        return $true
    } catch {
        Write-Host ("No se pudo bloquear '{0}'." -f $Resource) -ForegroundColor Red
        return $false
    }
}
function Release-ChatResource {
    param([Parameter(Mandatory)][string]$Resource)
    $s = Get-ManagedChatSession
    if ($null -eq $s) { return }
    $name = ($Resource -replace '[^a-zA-Z0-9._-]','_').ToLowerInvariant()
    $path = Join-Path $script:LockRoot "$name.json"
    $lock = Read-ChatJson $path
    if ($lock -and $lock.sessionId -eq $s.id) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }
}

function Get-ChatResourceLocks {
    Initialize-ChatMulti
    foreach ($file in Get-ChildItem -LiteralPath $script:LockRoot -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $l = Read-ChatJson $file.FullName
        if ($l -and (Test-ChatProcessAlive ([int]$l.pid))) { $l }
        else { Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Install-ManagedChatPrompt {
    if (-not $env:CHATGPT_SESSION_ID) { throw 'No hay sesion gestionada activa.' }

    function global:prompt {
        try {
            if ($script:AutoResourceLock) {
                Release-ChatResource -Resource $script:AutoResourceLock
                $script:AutoResourceLock = $null
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

            if ($status -eq 'ADB') {
                if (-not (Acquire-ChatResource -Resource 'adb-thor')) {
                    Write-Host ''
                    Write-Host 'Comando ADB bloqueado para evitar colision con otra sesion.' -ForegroundColor Red
                    return
                }
                $script:AutoResourceLock = 'adb-thor'
            }
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
        [switch]$NoWorktree
    )
    Initialize-ChatMulti
    $id = 'session-' + [guid]::NewGuid().ToString('N').Substring(0,12)
    $slot = Claim-ChatSlot $id
    $emoji = Get-ChatEmoji $slot
    $color = Get-ChatColor $slot

    $workspace = $script:ManagerRoot
    $project = 'General'
    $originRepo = $null
    $branch = $null
    $isolated = $false

    if (-not $ProjectPath) {
        $ProjectPath = Resolve-ChatProjectPath -Task $Task -CurrentPath (Get-Location).Path
    }

    if ($ProjectPath) {
        $resolved = (Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop).Path
        $workspace = $resolved
        $project = Split-Path $resolved -Leaf
        $repoRoot = $null
        try { $repoRoot = (& git -C $resolved rev-parse --show-toplevel 2>$null | Select-Object -First 1) } catch {}
        if ($repoRoot) {
            $repoRoot = $repoRoot.Trim()
            $originRepo = $repoRoot
            $project = Split-Path $repoRoot -Leaf
            Register-ChatProject -Path $repoRoot
            if (-not $NoWorktree) {
                $slug = ($Task.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
                if (-not $slug) { $slug = 'work' }
                if ($slug.Length -gt 28) { $slug = $slug.Substring(0,28).Trim('-') }
                $branch = "chat/$slot/$slug-" + (Get-Date -Format 'HHmmss') + '-' + $id.Substring($id.Length-4)
                $workspace = Join-Path (Join-Path $script:WorkspaceRoot $project) $id
                New-Item -ItemType Directory -Path (Split-Path $workspace -Parent) -Force | Out-Null
                & git -C $repoRoot worktree add -b $branch $workspace HEAD | Out-Null
                if (-not (Test-Path -LiteralPath (Join-Path $workspace '.git'))) {
                    Remove-Item (Join-Path $script:SlotRoot "slot-$slot.json") -Force -ErrorAction SilentlyContinue
                    throw 'No se pudo crear el git worktree aislado.'
                }
                $isolated = $true
            } else {
                $branch = (& git -C $workspace branch --show-current 2>$null | Select-Object -First 1)
            }
        }
    }

    $devPort = Claim-ChatPort -SessionId $id -Slot $slot

    $env:CHATGPT_SESSION_ID = $id
    $env:CHATGPT_SLOT = [string]$slot
    $env:CHATGPT_PROJECT = $project
    $env:CHATGPT_WORKSPACE = $workspace
    if ($devPort) {
        $env:CHATGPT_PORT = [string]$devPort
        $env:PORT = [string]$devPort
    }
    $state = [ordered]@{
        id=$id; slot=$slot; emoji=$emoji; color=$color; project=$project; task=$Task
        workspace=$workspace; originRepo=$originRepo; branch=$branch; isolated=$isolated
        pid=$PID; active=$true; status='READY'; lastCommand=''; devPort=$devPort; historyWritten=$false
        startedAt=(Get-Date).ToString('o'); updatedAt=(Get-Date).ToString('o')
    }
    Write-ChatJson (Join-Path $script:SessionRoot "$id.json") $state
    Set-Location -LiteralPath $workspace
    Set-ManagedChatWindowTitle -State $state
    return [pscustomobject]$state
}

function Stop-ManagedChatSession {
    $s = Get-ManagedChatSession
    if ($null -eq $s) { return }
    $s.active = $false
    $s.status = 'ENDED'
    $s.updatedAt = (Get-Date).ToString('o')
    Release-SessionReservations $s
    Write-ChatHistory $s 'NORMAL_EXIT'
    Write-ChatJson (Join-Path $script:SessionRoot "$($s.id).json") $s
}
function Show-ManagedChatStatus {
    $sessions = @(Get-ManagedChatSessions | Where-Object active | Sort-Object slot)
    if (-not $sessions.Count) {
        Write-Host 'No hay sesiones gestionadas activas.'
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

Export-ModuleMember -Function Initialize-ChatMulti,Get-ChatColor,Get-ChatConfig,Get-ManagedChatSession,Get-ManagedChatSessions,Expire-IdleManagedChatSessions,New-ManagedChatSession,Stop-ManagedChatSession,Install-ManagedChatPrompt,Set-ManagedChatState,Show-ManagedChatStatus,Acquire-ChatResource,Release-ChatResource,Get-ChatResourceLocks,Resolve-ChatCommandStatus,Get-ConfiguredResourceNames,Claim-ChatPort,Release-ChatPort,Get-RegisteredChatProjects,Register-ChatProject,Resolve-ChatProjectPath,Get-ChatHistory,Get-ChatGitSummary,Get-WorktreeCleanupCandidates,Invoke-SafeWorktreeCleanup,Get-SessionIdleInfo,Get-ChatPortReservations,Get-ProjectConflictGroups,Get-ChatProp
