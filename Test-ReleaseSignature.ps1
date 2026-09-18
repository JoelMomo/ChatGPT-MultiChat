param(
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$SignaturePath,
    [string]$PublicKeyPath
)

$ErrorActionPreference='Stop'
if(-not $PublicKeyPath){$PublicKeyPath=Join-Path $PSScriptRoot 'RELEASE-PUBLIC-KEY.xml'}
foreach($path in @($PackagePath,$SignaturePath,$PublicKeyPath)){
    if(-not(Test-Path -LiteralPath $path)){throw "File not found: $path"}
}

$csp=New-Object Security.Cryptography.CspParameters
$csp.ProviderType=24
$rsa=New-Object Security.Cryptography.RSACryptoServiceProvider($csp)
$sha=[Security.Cryptography.SHA256]::Create()
try{
    $rsa.FromXmlString([IO.File]::ReadAllText($PublicKeyPath))
    $bytes=[IO.File]::ReadAllBytes($PackagePath)
    $hash=$sha.ComputeHash($bytes)
    $signature=[Convert]::FromBase64String(([IO.File]::ReadAllText($SignaturePath)).Trim())
    $valid=$rsa.VerifyHash($hash,[Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'),$signature)
}finally{
    $sha.Dispose()
    $rsa.Dispose()
}
if(-not $valid){
    Write-Host 'SIGNATURE: INVALID' -ForegroundColor Red
    exit 2
}
Write-Host 'SIGNATURE: VALID' -ForegroundColor Green
exit 0
