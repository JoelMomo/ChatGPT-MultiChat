param(
    [string]$InstallRoot=$PSScriptRoot
)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($InstallRoot)
$packageVersion='0.2.51'
$packageIntegrity='sha512-BF/ZV06c7mh+tzfJEkQpjcOg6UaQtzp2vRadIpA9hI+WpPDwkQ2ekdY0fbN7I4xOrCQX6NajyEPouEDXFJc1kA=='
Import-Module (Join-Path $root 'RestrictedRemote.psm1') -Force -DisableNameChecking

function Test-Administrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-IcaclsChecked {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & icacls.exe @Arguments|Out-Null
    if($LASTEXITCODE -ne 0){
        throw ("icacls failed ({0}): {1}" -f $LASTEXITCODE,($Arguments -join ' '))
    }
}

function Get-ReviewedRuntime {
    param($Config)

    $candidates=New-Object Collections.Generic.List[string]
    if($Config -and [string]$Config.runtimeRoot){
        [void]$candidates.Add([string]$Config.runtimeRoot)
    }

    $npxRoot=Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
    if(Test-Path -LiteralPath $npxRoot){
        foreach($manifest in @(Get-ChildItem -LiteralPath $npxRoot -Filter package-lock.json -File -Recurse -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending)){
            $candidate=Split-Path $manifest.FullName -Parent
            if(-not $candidates.Contains($candidate)){[void]$candidates.Add($candidate)}
        }
    }

    foreach($candidate in $candidates){
        try{
            $lock=Join-Path $candidate 'package-lock.json'
            $entry=Join-Path $candidate 'node_modules\@wonderwhy-er\desktop-commander\dist\index.js'
            if(-not(Test-Path -LiteralPath $lock) -or -not(Test-Path -LiteralPath $entry)){continue}
            $raw=[IO.File]::ReadAllText($lock)
            if(-not $raw.Contains(('"node_modules/@wonderwhy-er/desktop-commander"'))){continue}
            if(-not $raw.Contains(('"version": "{0}"' -f $packageVersion))){continue}
            if(-not $raw.Contains(('"integrity": "{0}"' -f $packageIntegrity))){continue}
            return [pscustomobject]@{Root=[IO.Path]::GetFullPath($candidate);EntryPoint=$entry}
        }catch{}
    }
    return $null
}

function Install-ReviewedRuntime {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$RestrictedSid
    )

    $ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $runtimeBase=Join-Path $env:ProgramData 'ChatGPT-MultiChat\restricted-runtime'
    $target=Join-Path $runtimeBase ('desktop-commander-'+$packageVersion)
    $stage=$target+'.staging-'+[guid]::NewGuid().ToString('N')

    New-Item -ItemType Directory -Path $runtimeBase -Force|Out-Null
    Invoke-IcaclsChecked @($runtimeBase,'/inheritance:r')
    Invoke-IcaclsChecked @($runtimeBase,'/grant:r','*S-1-5-18:(OI)(CI)F')
    Invoke-IcaclsChecked @($runtimeBase,'/grant','*S-1-5-32-544:(OI)(CI)F')
    Invoke-IcaclsChecked @($runtimeBase,'/grant',('*'+$ownerSid+':(OI)(CI)RX'))
    Invoke-IcaclsChecked @($runtimeBase,'/grant',('*'+$RestrictedSid+':(OI)(CI)RX'))

    try{
        Copy-Item -LiteralPath $Source.Root -Destination $stage -Recurse -Force
        $lock=Join-Path $stage 'package-lock.json'
        $entry=Join-Path $stage 'node_modules\@wonderwhy-er\desktop-commander\dist\index.js'
        if(-not(Test-Path -LiteralPath $lock) -or -not(Test-Path -LiteralPath $entry)){
            throw 'Provisioned Restricted Remote runtime is incomplete.'
        }
        $raw=[IO.File]::ReadAllText($lock)
        if(-not $raw.Contains(('"version": "{0}"' -f $packageVersion)) -or
           -not $raw.Contains(('"integrity": "{0}"' -f $packageIntegrity))){
            throw 'Provisioned Restricted Remote runtime failed the pinned package check.'
        }

        if(Test-Path -LiteralPath $target){
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        Move-Item -LiteralPath $stage -Destination $target
        Invoke-IcaclsChecked @($target,'/inheritance:e')
        return [pscustomobject]@{
            Root=$target
            EntryPoint=(Join-Path $target 'node_modules\@wonderwhy-er\desktop-commander\dist\index.js')
        }
    }finally{
        if(Test-Path -LiteralPath $stage){
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if(-not(Test-Administrator)){
    $args=@(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',$PSCommandPath,
        '-InstallRoot',$root
    )
    $elevated=Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait -PassThru
    $exitCode=$elevated.ExitCode
    $elevated.Dispose()
    exit $exitCode
}

$repairResultPath=Join-Path (Get-RestrictedRemoteSecurityRoot) 'restricted-remote-runtime-repair.json'
trap {
    try{
        $failure=[ordered]@{
            success=$false
            error=$_.Exception.Message
            repairedAt=(Get-Date).ToString('o')
        }
        [IO.File]::WriteAllText($repairResultPath,($failure|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    }catch{}
    break
}

$config=Get-RestrictedRemoteInstalledConfig
if(-not $config){throw 'Restricted Remote is not installed.'}
if(-not(Test-RestrictedRemoteInstallMatches)){throw 'Restricted Remote install root does not match this checkout.'}
if(-not [string]$config.userSid){throw 'Restricted Remote SID is missing.'}

$account=Get-LocalUser -Name ([string]$config.accountName) -ErrorAction SilentlyContinue
if(-not $account -or [string]$account.SID.Value -ne [string]$config.userSid){
    throw 'Restricted Remote Windows account does not match the stored configuration.'
}

$source=Get-ReviewedRuntime -Config $config
if(-not $source){throw 'Reviewed Desktop Commander 0.2.51 runtime was not found.'}

foreach($proc in @(Get-CimInstance Win32_Process|Where-Object{
    $_.CommandLine -match 'MultiChat-Tray\.ps1' -or
    $_.CommandLine -match 'RestrictedRemote-Launcher\.ps1' -or
    ($_.CommandLine -match 'desktop-commander' -and $_.CommandLine -match '\bremote\b')
})){
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 700

$oldRuntime=[string]$config.runtimeRoot
$installed=Install-ReviewedRuntime -Source $source -RestrictedSid ([string]$config.userSid)
$config.runtimeRoot=$installed.Root
$config.entryPoint=$installed.EntryPoint
$config.packageVersion=$packageVersion
$config.packageIntegrity=$packageIntegrity

$configPath=Get-RestrictedRemoteConfigPath
$temp=$configPath+'.runtime-repair.tmp'
[IO.File]::WriteAllText($temp,($config|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
Move-Item -LiteralPath $temp -Destination $configPath -Force

# Remove the obsolete explicit read grant from the interactive user's npm cache.
# The cache itself is left untouched.
if($oldRuntime -and -not [string]::Equals(
    [IO.Path]::GetFullPath($oldRuntime).TrimEnd('\'),
    [IO.Path]::GetFullPath($installed.Root).TrimEnd('\'),
    [StringComparison]::OrdinalIgnoreCase
)){
    $ownerProfile=[IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')+'\'
    $oldFull=[IO.Path]::GetFullPath($oldRuntime)
    if($oldFull.StartsWith($ownerProfile,[StringComparison]::OrdinalIgnoreCase) -and
       (Test-Path -LiteralPath $oldFull)){
        & icacls.exe $oldFull /remove:g ('*'+[string]$config.userSid) /T /C /Q|Out-Null
    }
}

$result=[ordered]@{
    success=$true
    runtimeRoot=$installed.Root
    enabled=[bool]$config.enabled
    repairedAt=(Get-Date).ToString('o')
}
[IO.File]::WriteAllText($repairResultPath,($result|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))

Write-Host 'Restricted Remote runtime repaired.' -ForegroundColor Green
Write-Host ('Runtime: '+$installed.Root)
Write-Host ('Still enabled: '+[bool]$config.enabled)
Write-Host 'Reopen ChatGPT MultiChat and turn Desktop Commander On.'
