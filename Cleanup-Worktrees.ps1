param([switch]$Apply)

Import-Module (Join-Path $PSScriptRoot 'ChatMulti.psm1') -Force -DisableNameChecking
$items=@(Get-WorktreeCleanupCandidates)

if (-not $items.Count) {
    Write-Host 'There are no finished worktrees pending cleanup.'
    exit 0
}

foreach ($i in $items) {
    $mark=if($i.safe){'SAFE'}else{'KEEP'}
    Write-Host ("[{0}] {1} | {2} | {3}" -f $mark,$i.project,$i.branch,$i.reason)
    Write-Host ("       " + $i.workspace) -ForegroundColor DarkGray
}

if ($Apply) {
    $removed=@(Invoke-SafeWorktreeCleanup)
    Write-Host ''
    Write-Host ("Safely removed: " + $removed.Count) -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host 'Use -Apply to remove ONLY the entries marked SAFE.' -ForegroundColor DarkGray
}
