param(
    [switch]$Apply,
    [switch]$AutoCleanSafe,
    [string]$CandidatesFile,
    [string]$ResultFile,
    [string]$StateRoot,
    [string]$WorkspaceRoot,
    [switch]$Quiet
)

$ErrorActionPreference='Stop'
if($StateRoot){$env:MULTICHAT_STATE_ROOT=[IO.Path]::GetFullPath($StateRoot)}
if($WorkspaceRoot){$env:MULTICHAT_WORKSPACE_ROOT=[IO.Path]::GetFullPath($WorkspaceRoot)}
Import-Module (Join-Path $PSScriptRoot 'ChatMulti.psm1') -Force -DisableNameChecking

function Write-ResultFile {
    param($Result)
    if ([string]::IsNullOrWhiteSpace($ResultFile)) { return }
    $json = $Result | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($ResultFile,$json,(New-Object Text.UTF8Encoding($false)))
}

$items = @()
if ($CandidatesFile -and (Test-Path -LiteralPath $CandidatesFile)) {
    try {
        $parsed = Get-Content -LiteralPath $CandidatesFile -Raw | ConvertFrom-Json
        foreach ($candidate in $parsed) { $items += $candidate }
    }
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
$applyCleanup = ($Apply -or $AutoCleanSafe)
$safeBeforeCount = $safe.Count
if ($applyCleanup -and $safe.Count) {
    $removed = @(Invoke-SafeWorktreeCleanup -Candidates $safe)
    if (-not $Quiet) {
        Write-Host ''
        Write-Host ("Safely removed: " + $removed.Count) -ForegroundColor Green
    }

    if($AutoCleanSafe){
        # Return the state after automatic cleanup, not the stale pre-cleanup candidate list.
        $items = @(Get-WorktreeCleanupCandidates)
        $safe = @($items | Where-Object { [bool](Get-ChatProp $_ 'safe' $false) })
        $pending = @($items | Where-Object { -not [bool](Get-ChatProp $_ 'safe' $false) })
    }
} elseif (-not $applyCleanup -and -not $Quiet -and $items.Count) {
    Write-Host ''
    Write-Host 'Use -Apply to remove ONLY the entries marked SAFE.' -ForegroundColor DarkGray
}

$failedCount = if($applyCleanup){[Math]::Max(0,$safeBeforeCount-$removed.Count)}else{0}

$result = [ordered]@{
    scannedAt = (Get-Date).ToString('o')
    candidateCount = $items.Count
    safeCount = $safe.Count
    pendingCount = $pending.Count
    removedCount = $removed.Count
    failedCount = $failedCount
    autoClean = [bool]$AutoCleanSafe
    items = @($items | ForEach-Object {
        [ordered]@{
            id = [string](Get-ChatProp $_ 'id' '')
            project = [string](Get-ChatProp $_ 'project' '')
            workspace = [string](Get-ChatProp $_ 'workspace' '')
            originRepo = [string](Get-ChatProp $_ 'originRepo' '')
            branch = [string](Get-ChatProp $_ 'branch' '')
            baseRef = [string](Get-ChatProp $_ 'baseRef' '')
            baseSha = [string](Get-ChatProp $_ 'baseSha' '')
            canonicalRef = [string](Get-ChatProp $_ 'canonicalRef' '')
            leaseState = [string](Get-ChatProp $_ 'leaseState' '')
            ownCommits = if((Get-ChatProp $_ 'commitSafety' $null)){Get-ChatProp (Get-ChatProp $_ 'commitSafety' $null) 'OwnCommits' $null}else{$null}
            safe = [bool](Get-ChatProp $_ 'safe' $false)
            reason = [string](Get-ChatProp $_ 'reason' '')
        }
    })
}

Write-ResultFile $result
