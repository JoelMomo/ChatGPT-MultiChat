param(
    [string]$ProjectPath,
    [string]$Task = 'work',
    [switch]$NoWorktree,
    [string]$BaseRef,
    [string]$BaseSha,
    [string]$CanonicalRef
)

Import-Module (Join-Path $PSScriptRoot 'ChatMulti.psm1') -Force -DisableNameChecking
$session = New-ManagedChatSession -ProjectPath $ProjectPath -Task $Task -NoWorktree:$NoWorktree -BaseRef $BaseRef -BaseSha $BaseSha -CanonicalRef $CanonicalRef

Write-Host ''
Write-Host ("[CHAT-{0}] ACTIVE | {1} | {2}" -f $session.slot,$session.project,$session.task) -ForegroundColor $session.color
Write-Host ('Workspace: ' + $session.workspace) -ForegroundColor DarkGray
if ($session.branch) { Write-Host ('Branch: ' + $session.branch) -ForegroundColor DarkGray }
if ($session.baseSha) { Write-Host ('Base: ' + $session.baseRef + ' @ ' + $session.baseSha) -ForegroundColor DarkGray }
if ($session.canonicalRef) { Write-Host ('Canonical ref: ' + $session.canonicalRef) -ForegroundColor DarkGray }
if ($session.devPort) { Write-Host ('Reserved port: ' + $session.devPort) -ForegroundColor DarkGray }
Write-Host ''

try {
    while ($true) {
        $current = Get-ManagedChatSession
        $color = $current.color
        Write-Host ("[CHAT-{0}] {1} | READY" -f $current.slot,$current.project) -NoNewline -ForegroundColor $color
        $line = Read-Host "`n$((Get-Location).Path)>"
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Trim().ToLowerInvariant() -in @('exit','quit')) { break }

        $status = Resolve-ChatCommandStatus $line
        $resources = @(Get-ConfiguredResourceNames -Line $line)
        $acquired = @()
        $blocked = $false

        foreach ($resource in $resources) {
            if (Acquire-ChatResource -Resource $resource) {
                $acquired += $resource
            } else {
                $blocked = $true
                break
            }
        }
        if ($blocked) {
            foreach ($resource in $acquired) { Release-ChatResource -Resource $resource }
            continue
        }

        Set-ManagedChatState -Status $status -LastCommand $line
        try { Invoke-Expression $line }
        catch { Write-Error $_ }
        finally {
            foreach ($resource in $acquired) { Release-ChatResource -Resource $resource }
            Set-ManagedChatState -Status 'READY'
        }
        Write-Host ''
    }
}
finally {
    Stop-ManagedChatSession
    Write-Host ("[CHAT-{0}] session closed." -f $session.slot) -ForegroundColor DarkGray
}
