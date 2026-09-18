param(
    [Parameter(Mandatory)][string]$TargetVersion,
    [string]$InstallRoot,
    [string]$Repository='JoelMomo/ChatGPT-MultiChat',
    [string]$ReleaseUrl,
    [int]$ParentPid=0,
    [switch]$NoRestart,
    [string]$LocalPackagePath,
    [string]$LocalChecksumPath,
    [string]$LocalSignaturePath
)

$ErrorActionPreference='Stop'
if(-not $InstallRoot){$InstallRoot=$PSScriptRoot}
$InstallRoot=[IO.Path]::GetFullPath($InstallRoot)
$stateCache=Join-Path $InstallRoot 'state\cache'
New-Item -ItemType Directory -Path $stateCache -Force|Out-Null
$resultPath=Join-Path $stateCache 'update-last-result.json'
$publicKeyPath=Join-Path $InstallRoot 'RELEASE-PUBLIC-KEY.xml'
$startedAt=[DateTimeOffset]::UtcNow
$tempRoot=Join-Path $env:TEMP ("ChatGPT-MultiChat-update-"+[guid]::NewGuid().ToString('N'))
$downloadDir=Join-Path $tempRoot 'download'
$stagingDir=Join-Path $tempRoot 'staging'
$backupDir=Join-Path $tempRoot 'backup'
$excludedTop=@('state','workspaces','dist','.git')
$oldConfig=$null
$backupCreated=$false

function Write-UpdateResult {
    param(
        [bool]$Success,
        [string]$Status,
        [string]$Message
    )
    $payload=[ordered]@{
        success=$Success
        status=$Status
        message=$Message
        targetVersion=$TargetVersion
        startedAt=$startedAt.ToString('o')
        finishedAt=[DateTimeOffset]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText(
        $resultPath,
        ($payload|ConvertTo-Json -Depth 6),
        (New-Object Text.UTF8Encoding($false))
    )
}

function Restart-MultiChat {
    if($NoRestart){return}
    $tray=Join-Path $InstallRoot 'MultiChat-Tray.ps1'
    if(Test-Path -LiteralPath $tray){
        Start-Process powershell.exe -WorkingDirectory $InstallRoot -ArgumentList @(
            '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$tray
        ) -WindowStyle Hidden|Out-Null
    }
}

function Wait-ForParentExit {
    if($ParentPid -le 0){return}
    $deadline=(Get-Date).AddSeconds(45)
    while((Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline){
        Start-Sleep -Milliseconds 300
    }
    if(Get-Process -Id $ParentPid -ErrorAction SilentlyContinue){
        throw "MultiChat process $ParentPid did not exit in time."
    }
}

function Get-ReleaseAsset {
    param($Release,[string]$Name)
    return @($Release.assets|Where-Object{[string]$_.name -eq $Name}|Select-Object -First 1)[0]
}

function Test-PackageSignature {
    param(
        [string]$Package,
        [string]$Signature,
        [string]$PublicKey
    )
    foreach($file in @($Package,$Signature,$PublicKey)){
        if(-not(Test-Path -LiteralPath $file)){throw "Verification file not found: $file"}
    }

    $csp=New-Object Security.Cryptography.CspParameters
    $csp.ProviderType=24
    $rsa=New-Object Security.Cryptography.RSACryptoServiceProvider($csp)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $rsa.FromXmlString([IO.File]::ReadAllText($PublicKey))
        $hash=$sha.ComputeHash([IO.File]::ReadAllBytes($Package))
        $signatureBytes=[Convert]::FromBase64String(([IO.File]::ReadAllText($Signature)).Trim())
        return $rsa.VerifyHash(
            $hash,
            [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'),
            $signatureBytes
        )
    }finally{
        $sha.Dispose()
        $rsa.Dispose()
    }
}

function Merge-Config {
    param([string]$DefaultPath,$Existing)
    if(-not(Test-Path -LiteralPath $DefaultPath)){return}
    $merged=Get-Content -LiteralPath $DefaultPath -Raw|ConvertFrom-Json
    if($Existing){
        foreach($prop in $Existing.PSObject.Properties){
            $target=$merged.PSObject.Properties[$prop.Name]
            if($target){
                $target.Value=$prop.Value
            }else{
                $merged|Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
            }
        }
    }
    [IO.File]::WriteAllText(
        $DefaultPath,
        ($merged|ConvertTo-Json -Depth 20),
        (New-Object Text.UTF8Encoding($false))
    )
}

function Backup-ApplicationFiles {
    New-Item -ItemType Directory -Path $backupDir -Force|Out-Null
    foreach($item in Get-ChildItem -LiteralPath $InstallRoot -Force){
        if($item.Name -in $excludedTop){continue}
        Copy-Item -LiteralPath $item.FullName -Destination $backupDir -Recurse -Force
    }
    $script:backupCreated=$true
}

function Restore-Backup {
    if(-not $script:backupCreated -or -not(Test-Path -LiteralPath $backupDir)){return}
    foreach($item in Get-ChildItem -LiteralPath $backupDir -Force){
        Copy-Item -LiteralPath $item.FullName -Destination $InstallRoot -Recurse -Force
    }
}

try{
    if(Test-Path -LiteralPath (Join-Path $InstallRoot '.git')){
        Write-UpdateResult -Success $false -Status 'GIT_CHECKOUT' -Message 'Automatic in-place updates are disabled for Git checkouts.'
        if($ReleaseUrl){Start-Process -FilePath $ReleaseUrl|Out-Null}
        exit 3
    }

    if(-not(Test-Path -LiteralPath $publicKeyPath)){
        throw 'Release public key is missing; signed updates cannot be verified.'
    }

    Wait-ForParentExit

    New-Item -ItemType Directory -Path $downloadDir,$stagingDir -Force|Out-Null
    $zipName="ChatGPT-MultiChat-$TargetVersion-portable.zip"
    $shaName="$zipName.sha256"
    $sigName="$zipName.sig"
    $zipPath=Join-Path $downloadDir $zipName
    $shaPath=Join-Path $downloadDir $shaName
    $sigPath=Join-Path $downloadDir $sigName

    if($LocalPackagePath){
        if(-not $LocalChecksumPath -or -not $LocalSignaturePath){
            throw 'Local update mode requires package, checksum, and signature paths.'
        }
        Copy-Item -LiteralPath $LocalPackagePath -Destination $zipPath -Force
        Copy-Item -LiteralPath $LocalChecksumPath -Destination $shaPath -Force
        Copy-Item -LiteralPath $LocalSignaturePath -Destination $sigPath -Force
    }else{
        $headers=@{
            'User-Agent'="ChatGPT-MultiChat-Updater/$TargetVersion"
            'Accept'='application/vnd.github+json'
            'X-GitHub-Api-Version'='2022-11-28'
        }
        $tag='v'+$TargetVersion
        $api="https://api.github.com/repos/$Repository/releases/tags/$tag"
        $release=Invoke-RestMethod -Uri $api -Headers $headers -Method Get -TimeoutSec 15

        foreach($pair in @(
            @($zipName,$zipPath),
            @($shaName,$shaPath),
            @($sigName,$sigPath)
        )){
            $asset=Get-ReleaseAsset -Release $release -Name $pair[0]
            if(-not $asset){throw "Required release asset is missing: $($pair[0])"}
            Invoke-WebRequest -UseBasicParsing -Uri ([string]$asset.browser_download_url) -Headers @{'User-Agent'="ChatGPT-MultiChat-Updater/$TargetVersion"} -OutFile $pair[1] -TimeoutSec 30
        }
    }

    $expectedHash=(([IO.File]::ReadAllText($shaPath).Trim() -split '\s+')[0]).ToLowerInvariant()
    if($expectedHash -notmatch '^[0-9a-f]{64}$'){throw 'Release checksum file is invalid.'}
    $actualHash=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($actualHash -ne $expectedHash){throw 'Downloaded package failed SHA-256 verification.'}

    if(-not(Test-PackageSignature -Package $zipPath -Signature $sigPath -PublicKey $publicKeyPath)){
        throw 'Downloaded package failed RSA signature verification.'
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $stagingDir -Force
    $stagedVersionPath=Join-Path $stagingDir 'VERSION'
    if(-not(Test-Path -LiteralPath $stagedVersionPath)){throw 'Staged package has no VERSION file.'}
    $stagedVersion=(Get-Content -LiteralPath $stagedVersionPath -Raw).Trim()
    if($stagedVersion -ne $TargetVersion){throw "Staged VERSION '$stagedVersion' does not match '$TargetVersion'."}

    $existingConfigPath=Join-Path $InstallRoot 'config.json'
    if(Test-Path -LiteralPath $existingConfigPath){
        try{$oldConfig=Get-Content -LiteralPath $existingConfigPath -Raw|ConvertFrom-Json}catch{$oldConfig=$null}
    }
    Merge-Config -DefaultPath (Join-Path $stagingDir 'config.json') -Existing $oldConfig

    Backup-ApplicationFiles

    foreach($item in Get-ChildItem -LiteralPath $stagingDir -Force){
        if($item.Name -in $excludedTop){continue}
        Copy-Item -LiteralPath $item.FullName -Destination $InstallRoot -Recurse -Force
    }

    $installedVersion=(Get-Content -LiteralPath (Join-Path $InstallRoot 'VERSION') -Raw).Trim()
    if($installedVersion -ne $TargetVersion){throw 'Installed VERSION validation failed after copy.'}

    Write-UpdateResult -Success $true -Status 'UPDATED' -Message "Updated successfully to $TargetVersion."
    Restart-MultiChat
    exit 0
}catch{
    $message=$_.Exception.Message
    try{Restore-Backup}catch{}
    Write-UpdateResult -Success $false -Status 'FAILED' -Message $message
    try{Restart-MultiChat}catch{}
    exit 2
}finally{
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
