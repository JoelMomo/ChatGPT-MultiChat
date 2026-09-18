param(
    [string]$Version,
    [switch]$SkipTests
)

$ErrorActionPreference='Stop'
$root=$PSScriptRoot
if(-not $Version){$Version=(Get-Content (Join-Path $root 'VERSION') -Raw).Trim()}
if(-not $Version){throw 'Version is required.'}

if(-not $SkipTests){
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'SelfTest.ps1')
    if($LASTEXITCODE -ne 0){throw 'SelfTest failed.'}
}

& (Join-Path $root 'Make-Portable-Package.ps1') -Version $Version
$zip=Join-Path $root ("dist\ChatGPT-MultiChat-$Version-portable.zip")
$shaPath=$zip+'.sha256'
$sigPath=$zip+'.sig'
$sha=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($shaPath,("$sha  "+[IO.Path]::GetFileName($zip)),(New-Object Text.UTF8Encoding($false)))

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Sign-ReleasePackage.ps1') -PackagePath $zip -SignaturePath $sigPath
if($LASTEXITCODE -ne 0){throw 'Package signing failed.'}
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Test-ReleaseSignature.ps1') -PackagePath $zip -SignaturePath $sigPath
if($LASTEXITCODE -ne 0){throw 'Package signature verification failed.'}

$tag='v'+$Version
$oldErrorActionPreference=$ErrorActionPreference
try{
    $ErrorActionPreference='Continue'
    $existing=& gh release view $tag --repo JoelMomo/ChatGPT-MultiChat --json tagName 2>$null
    $existingExit=$LASTEXITCODE
}finally{
    $ErrorActionPreference=$oldErrorActionPreference
}
if($existingExit -eq 0){throw "Release $tag already exists."}

$args=@(
    'release','create',$tag,
    $zip,$shaPath,$sigPath,
    '--repo','JoelMomo/ChatGPT-MultiChat',
    '--target','main',
    '--title',"ChatGPT MultiChat $tag",
    '--generate-notes'
)
if($Version -match '-'){$args+='--prerelease'}
& gh @args
if($LASTEXITCODE -ne 0){throw 'GitHub release creation failed.'}

Write-Host ("Published signed release {0}" -f $tag) -ForegroundColor Green
Write-Host ("SHA-256: {0}" -f $sha)
