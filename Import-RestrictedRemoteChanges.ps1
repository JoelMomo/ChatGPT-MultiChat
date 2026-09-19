param(
    [Parameter(Mandatory)][string]$SessionId,
    [string]$InstallRoot=$PSScriptRoot,
    [string]$ReviewBranch
)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($InstallRoot)
Import-Module (Join-Path $root 'RestrictedRemote.psm1') -Force -DisableNameChecking
$config=Get-RestrictedRemoteInstalledConfig
if(-not $config){throw 'Restricted Remote is not installed.'}
if(-not(Test-RestrictedRemoteInstallMatches)){
    throw 'Restricted Remote belongs to a different MultiChat folder. Repair the installation before importing work.'
}

function Test-PathWithin {
    param([string]$Path,[string]$Parent)
    $child=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootPath=[IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if([string]::Equals($child,$rootPath,[StringComparison]::OrdinalIgnoreCase)){return $true}
    $child.StartsWith($rootPath+'\',[StringComparison]::OrdinalIgnoreCase)
}

function Read-Json {
    param([string]$Path)
    try{Get-Content -LiteralPath $Path -Raw -ErrorAction Stop|ConvertFrom-Json}catch{$null}
}

if($SessionId -notmatch '^session-[a-z0-9]+$'){throw 'Invalid restricted session id.'}
$sessionPath=Join-Path ([string]$config.stateRoot) ('sessions\'+$SessionId+'.json')
$session=Read-Json $sessionPath
if(-not $session){throw 'Restricted session was not found.'}
if([bool]$session.active){throw 'The restricted session is still active. End it before importing changes.'}

$workspace=[string]$session.workspace
$origin=[string]$session.originRepo
$head=[string]$session.head
if(-not $head -or $head -notmatch '^[0-9a-fA-F]{40}$'){
    $head=[string](& git -C $workspace rev-parse 'HEAD^{commit}' 2>$null)
    $head=$head.Trim()
}
$base=[string]$session.baseSha
if($base -notmatch '^[0-9a-fA-F]{40}$'){throw 'Restricted session has no trusted base commit.'}
if($head -notmatch '^[0-9a-fA-F]{40}$'){throw 'Restricted session HEAD is invalid.'}
if(-not(Test-PathWithin -Path $workspace -Parent ([string]$config.workspaceRoot))){
    throw 'Restricted workspace is outside its configured containment root.'
}
if(-not(Test-Path -LiteralPath (Join-Path $workspace '.git') -PathType Container)){
    throw 'Restricted workspace is not an isolated clone.'
}

$approved=$false
foreach($path in @($config.projectRoots)){
    if($path -and [string]::Equals(
        [IO.Path]::GetFullPath([string]$path).TrimEnd('\'),
        [IO.Path]::GetFullPath($origin).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )){
        $approved=$true
        break
    }
}
if(-not $approved){throw 'Restricted session origin is not an approved canonical project.'}

$remote=[string](& git -C $workspace config --get remote.origin.url 2>$null)
if($LASTEXITCODE -ne 0 -or -not $remote -or -not [string]::Equals(
    [IO.Path]::GetFullPath($remote.Trim()).TrimEnd('\'),
    [IO.Path]::GetFullPath($origin).TrimEnd('\'),
    [StringComparison]::OrdinalIgnoreCase
)){
    throw 'Restricted clone origin does not match the approved canonical project.'
}

& git -C $workspace diff --quiet --ignore-submodules --
$worktreeDirty=($LASTEXITCODE -ne 0)
& git -C $workspace diff --cached --quiet --ignore-submodules --
$indexDirty=($LASTEXITCODE -ne 0)
$untracked=@(& git -C $workspace ls-files --others --exclude-standard)
if($worktreeDirty -or $indexDirty -or $untracked.Count){
    throw 'Restricted workspace has uncommitted changes. Commit or discard them before importing.'
}

& git -C $workspace merge-base --is-ancestor $base $head 2>$null
if($LASTEXITCODE -ne 0){throw 'Restricted HEAD is not descended from the trusted session base.'}
if($head -eq $base){throw 'Restricted session contains no commits to import.'}

if(-not(Test-Path -LiteralPath $origin)){throw 'Canonical project is missing.'}
$originTop=[string](& git -C $origin rev-parse --show-toplevel 2>$null)
if($LASTEXITCODE -ne 0 -or -not $originTop){throw 'Canonical project is not a Git repository.'}
if(-not [string]::Equals(
    [IO.Path]::GetFullPath($originTop.Trim()).TrimEnd('\'),
    [IO.Path]::GetFullPath($origin).TrimEnd('\'),
    [StringComparison]::OrdinalIgnoreCase
)){throw 'Canonical project identity changed.'}
if(-not $ReviewBranch){
    $shortId=$SessionId -replace '^session-',''
    $ReviewBranch='restricted/review-'+$shortId
}
if($ReviewBranch -notmatch '^[A-Za-z0-9._/-]+$' -or $ReviewBranch.Contains('..')){
    throw 'Invalid review branch name.'
}
$existing=@(& git -C $origin branch --list $ReviewBranch)
if($existing.Count){throw "Review branch already exists: $ReviewBranch"}

$ref='refs/heads/'+$ReviewBranch
& git -c core.hooksPath=NUL -C $origin fetch --no-tags --no-write-fetch-head --no-recurse-submodules -- $workspace ($head+':'+$ref)
if($LASTEXITCODE -ne 0){throw 'Could not import the restricted commit into the canonical repository.'}

$imported=[string](& git -C $origin rev-parse ($ref+'^{commit}') 2>$null)
if($LASTEXITCODE -ne 0 -or $imported.Trim().ToLowerInvariant() -ne $head.ToLowerInvariant()){
    try{& git -C $origin branch -D $ReviewBranch 2>$null|Out-Null}catch{}
    throw 'Imported review branch did not resolve to the expected commit.'
}

$session|Add-Member -NotePropertyName importedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
$session|Add-Member -NotePropertyName importedBranch -NotePropertyValue $ReviewBranch -Force
[IO.File]::WriteAllText($sessionPath,($session|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))

Write-Host 'Restricted Remote work imported for review.' -ForegroundColor Green
Write-Host ('Project: '+$origin)
Write-Host ('Review branch: '+$ReviewBranch)
Write-Host ('Commit: '+$head)
Write-Host 'Nothing was merged or checked out automatically.'
