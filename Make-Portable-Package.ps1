param([string]$Version='2.3.0')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$dist=Join-Path $root 'dist'
$stage=Join-Path $dist ("ChatGPT-MultiChat-"+$Version)
$zip=Join-Path $dist ("ChatGPT-MultiChat-"+$Version+"-portable.zip")

if(Test-Path $stage){Remove-Item $stage -Recurse -Force}
if(Test-Path $zip){Remove-Item $zip -Force}
New-Item -ItemType Directory -Path $stage -Force|Out-Null

$exclude=@('state','workspaces','dist')
foreach($item in Get-ChildItem -LiteralPath $root){
    if($item.Name -in $exclude){continue}
    Copy-Item $item.FullName -Destination $stage -Recurse -Force
}
foreach($dir in @('state\locks','state\sessions','state\slots','state\ports','state\logs','state\leases','workspaces')){
    New-Item -ItemType Directory -Path (Join-Path $stage $dir) -Force|Out-Null
}

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force
Write-Host ('Portable package created: '+$zip) -ForegroundColor Green
