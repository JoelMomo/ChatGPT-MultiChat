param(
    [Parameter(Mandatory)][string]$ResultFile
)

$ErrorActionPreference='SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'ChatMulti.psm1') -Force -DisableNameChecking

$started=Get-Date
$expired=@(Expire-IdleManagedChatSessions)
$sessions=@(Get-ManagedChatSessions -ActiveOnly)

$dcOnline=$false
try{
    $dcOnline=@(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -match 'desktop-commander' -and
            $_.CommandLine -match '\bremote\b'
        }
    ).Count -gt 0
}catch{}

$git=@()
foreach($session in $sessions){
    $summary=Get-ChatGitSummary $session
    $git+=[ordered]@{
        id=[string](Get-ChatProp $session 'id' '')
        hasGit=[bool]$summary.hasGit
        modified=[int]$summary.modified
        untracked=[int]$summary.untracked
        ahead=[int]$summary.ahead
        behind=[int]$summary.behind
        dirty=[bool]$summary.dirty
        text=[string]$summary.text
    }
}

$result=[ordered]@{
    generatedAt=(Get-Date).ToString('o')
    durationMs=[int](((Get-Date)-$started).TotalMilliseconds)
    desktopCommanderOnline=$dcOnline
    activeCount=$sessions.Count
    expiredCount=$expired.Count
    git=$git
}

$directory=Split-Path $ResultFile -Parent
if($directory){
    New-Item -ItemType Directory -Path $directory -Force|Out-Null
}
$tmp="$ResultFile.$PID.tmp"
[IO.File]::WriteAllText(
    $tmp,
    ($result|ConvertTo-Json -Depth 6),
    (New-Object Text.UTF8Encoding($false))
)
Move-Item -LiteralPath $tmp -Destination $ResultFile -Force
