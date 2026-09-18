param([switch]$Apply)

Import-Module (Join-Path $PSScriptRoot 'ChatMulti.psm1') -Force -DisableNameChecking
$items=@(Get-WorktreeCleanupCandidates)

if (-not $items.Count) {
    Write-Host 'No hay worktrees terminados pendientes.'
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
    Write-Host ("Eliminados de forma segura: " + $removed.Count) -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host 'Usa -Apply para eliminar SOLO los marcados SAFE.' -ForegroundColor DarkGray
}
