param([string]$Version='2.4.0')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$dist=Join-Path $root 'dist'
$stage=Join-Path $dist ("ChatGPT-MultiChat-"+$Version)
$zip=Join-Path $dist ("ChatGPT-MultiChat-"+$Version+"-portable.zip")

if(Test-Path $stage){Remove-Item $stage -Recurse -Force}
if(Test-Path $zip){Remove-Item $zip -Force}
New-Item -ItemType Directory -Path $stage -Force|Out-Null

# Build releases from Git-tracked application files only. Developer-local
# helpers, patches, credentials, logs and other untracked files must never
# leak into a portable package just because they are beside the repository.
$tracked=@(& git -C $root ls-files 2>$null)
if($LASTEXITCODE -ne 0 -or -not $tracked.Count){
    throw 'Portable packages must be built from a Git checkout with tracked-file metadata.'
}
foreach($relative in $tracked){
    if([string]::IsNullOrWhiteSpace($relative)){continue}
    $normalized=$relative.Replace('/','\')
    if($normalized -match '^(state|workspaces|dist)(\|$)'){continue}

    $source=Join-Path $root $normalized
    if(-not(Test-Path -LiteralPath $source -PathType Leaf)){
        throw ("Tracked package file is missing: "+$relative)
    }
    $destination=Join-Path $stage $normalized
    $parent=Split-Path $destination -Parent
    if($parent){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    Copy-Item -LiteralPath $source -Destination $destination -Force
}
foreach($dir in @('state\locks','state\sessions','state\slots','state\ports','state\logs','state\leases','workspaces')){
    New-Item -ItemType Directory -Path (Join-Path $stage $dir) -Force|Out-Null
}

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force
Write-Host ('Portable package created: '+$zip) -ForegroundColor Green
