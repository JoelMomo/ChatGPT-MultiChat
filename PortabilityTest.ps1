$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$errors=New-Object Collections.Generic.List[string]

function Add-PortabilityFailure {
    param([string]$Message)
    $errors.Add($Message)
}

$extensions=@('.ps1','.psm1','.cmd')
foreach($item in @(Get-ChildItem -LiteralPath $root -File -Force)){
    if($item.Extension.ToLowerInvariant() -notin $extensions){continue}
    $text=[IO.File]::ReadAllText($item.FullName)

    if($text -match '(?i)[A-Z]:[\\/]+Users[\\/]+[^\\/''"\s]+'){
        Add-PortabilityFailure ("Hard-coded user profile path in "+$item.Name)
    }
    if($env:COMPUTERNAME -and $text.Contains($env:COMPUTERNAME,[StringComparison]::OrdinalIgnoreCase)){
        Add-PortabilityFailure ("Current computer name is embedded in "+$item.Name)
    }
}

$restrictedModule=Join-Path $root 'RestrictedRemote.psm1'
if(Test-Path -LiteralPath $restrictedModule){
    $oldLocal=$env:LOCALAPPDATA
    $probe=Join-Path $env:TEMP ('MultiChat-Portability-'+[guid]::NewGuid().ToString('N'))
    try{
        $env:LOCALAPPDATA=$probe
        Import-Module $restrictedModule -Force -DisableNameChecking
        $actual=Get-RestrictedRemoteSecurityRoot
        $expected=Join-Path $probe 'ChatGPT-MultiChat\security'
        if(-not [string]::Equals([IO.Path]::GetFullPath($actual),[IO.Path]::GetFullPath($expected),[StringComparison]::OrdinalIgnoreCase)){
            Add-PortabilityFailure 'Restricted Remote security root does not follow LOCALAPPDATA.'
        }
    }finally{
        $env:LOCALAPPDATA=$oldLocal
        Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if($errors.Count){
    Write-Host 'PORTABILITY TEST: FAIL' -ForegroundColor Red
    $errors|ForEach-Object{Write-Host (' - '+$_) -ForegroundColor Red}
    exit 1
}
Write-Host 'PORTABILITY TEST: OK' -ForegroundColor Green
Write-Host 'No machine-specific user profile or computer-name dependency was found in executable scripts.'
