param(
    [switch]$Apply,
    [string]$CandidatesFile,
    [string]$ResultFile,
    [switch]$Quiet
)

$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ChatMulti.psm1') -Force -DisableNameChecking

function Write-ResultFile {
    param($Result)
    if ([string]::IsNullOrWhiteSpace($ResultFile)) { return }
    $json = $Result | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($ResultFile,$json,(New-Object Text.UTF8Encoding($false)))
}

$items = @()
if ($CandidatesFile -and (Test-Path -LiteralPath $CandidatesFile)) {
    try { $items = @(Get-Content -LiteralPath $CandidatesFile -Raw | ConvertFrom-Json) }
    catch { $items = @() }
} else {
    $items = @(Get-WorktreeCleanupCandidates)
}

$safe = @($items | Where-Object { [bool](Get-ChatProp $_ 'safe' $false) })
$pending = @($items | Where-Object { -not [bool](Get-ChatProp $_ 'safe' $false) })

if (-not $Quiet) {
    if (-not $items.Count) {
        Write-Host 'There are no finished worktrees pending cleanup.'
    } else {
        foreach ($i in $items) {
            $mark=if([bool](Get-ChatProp $i 'safe' $false)){'SAFE'}else{'KEEP'}
            Write-Host ("[{0}] {1} | {2} | {3}" -f $mark,$i.project,$i.branch,$i.reason)
            Write-Host ("       " + $i.workspace) -ForegroundColor DarkGray
        }
    }
}

$removed = @()
if ($Apply -and $safe.Count) {
    $removed = @(Invoke-SafeWorktreeCleanup -Candidates $safe)
    if (-not $Quiet) {
        Write-Host ''
        Write-Host ("Safely removed: " + $removed.Count) -ForegroundColor Green
    }
} elseif (-not $Apply -and -not $Quiet -and $items.Count) {
    Write-Host ''
    Write-Host 'Use -Apply to remove ONLY the entries marked SAFE.' -ForegroundColor DarkGray
}

$result = [ordered]@{
    scannedAt = (Get-Date).ToString('o')
    candidateCount = $items.Count
    safeCount = $safe.Count
    pendingCount = $pending.Count
    removedCount = $removed.Count
    items = @($items | ForEach-Object {
        [ordered]@{
            id = [string](Get-ChatProp $_ 'id' '')
            project = [string](Get-ChatProp $_ 'project' '')
            workspace = [string](Get-ChatProp $_ 'workspace' '')
            originRepo = [string](Get-ChatProp $_ 'originRepo' '')
            branch = [string](Get-ChatProp $_ 'branch' '')
            safe = [bool](Get-ChatProp $_ 'safe' $false)
            reason = [string](Get-ChatProp $_ 'reason' '')
        }
    })
}

Write-ResultFile $result
