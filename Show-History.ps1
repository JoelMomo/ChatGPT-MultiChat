param([int]$Limit=20)

Import-Module (Join-Path $PSScriptRoot 'ChatMulti.psm1') -Force -DisableNameChecking
$history=@(Get-ChatHistory -Limit $Limit)
foreach($h in $history){
    Write-Host ("{0} | CHAT-{1} | {2} | {3} | {4}s | {5}" -f $h.endedAt,$h.slot,$h.project,$h.reason,$h.durationSeconds,$h.task)
}
