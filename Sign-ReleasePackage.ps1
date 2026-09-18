param(
    [Parameter(Mandatory)][string]$PackagePath,
    [string]$PrivateKeyPath,
    [string]$SignaturePath
)

$ErrorActionPreference='Stop'

if(-not $PrivateKeyPath){
    if($env:MULTICHAT_SIGNING_KEY_FILE){
        $PrivateKeyPath=$env:MULTICHAT_SIGNING_KEY_FILE
    }else{
        $PrivateKeyPath=Join-Path $env:LOCALAPPDATA 'ChatGPT-MultiChat\signing\release-private.xml'
    }
}
if(-not $SignaturePath){$SignaturePath=$PackagePath+'.sig'}
if(-not(Test-Path -LiteralPath $PackagePath)){throw "Package not found: $PackagePath"}
if(-not(Test-Path -LiteralPath $PrivateKeyPath)){throw "Release signing key not found: $PrivateKeyPath"}

$csp=New-Object Security.Cryptography.CspParameters
$csp.ProviderType=24
$rsa=New-Object Security.Cryptography.RSACryptoServiceProvider($csp)
$sha=[Security.Cryptography.SHA256]::Create()
try{
    $rsa.FromXmlString([IO.File]::ReadAllText($PrivateKeyPath))
    $bytes=[IO.File]::ReadAllBytes($PackagePath)
    $hash=$sha.ComputeHash($bytes)
    $signature=$rsa.SignHash($hash,[Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
    [IO.File]::WriteAllText($SignaturePath,[Convert]::ToBase64String($signature),(New-Object Text.UTF8Encoding($false)))
}finally{
    $sha.Dispose()
    $rsa.Dispose()
}
Write-Host ("Signed: {0}" -f $PackagePath)
Write-Host ("Signature: {0}" -f $SignaturePath)
