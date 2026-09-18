param(
    [string]$CurrentVersion,
    [string]$ResultFile,
    [string]$CacheFile,
    [int]$CacheHours=24,
    [ValidateSet('stable','beta')][string]$Channel='stable',
    [string]$Repository='JoelMomo/ChatGPT-MultiChat',
    [switch]$Force,
    [string]$MockLatestVersion,
    [string]$MockReleaseUrl,
    [string]$MockReleaseNotes='',
    [switch]$MockPrerelease
)

$ErrorActionPreference='Stop'

function ConvertTo-SemVerInfo {
    param([string]$Value)
    if([string]::IsNullOrWhiteSpace($Value)){return $null}
    $clean=$Value.Trim()
    if($clean.StartsWith('v',[StringComparison]::OrdinalIgnoreCase)){$clean=$clean.Substring(1)}
    $match=[regex]::Match($clean,'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$')
    if(-not $match.Success){return $null}
    $pre=if($match.Groups[4].Success){$match.Groups[4].Value}else{''}
    [pscustomobject]@{
        Raw=$clean
        Major=[int]$match.Groups[1].Value
        Minor=[int]$match.Groups[2].Value
        Patch=[int]$match.Groups[3].Value
        PreRelease=$pre
    }
}

function Compare-SemVer {
    param($Left,$Right)
    foreach($prop in @('Major','Minor','Patch')){
        if($Left.$prop -lt $Right.$prop){return -1}
        if($Left.$prop -gt $Right.$prop){return 1}
    }

    $leftPre=[string]$Left.PreRelease
    $rightPre=[string]$Right.PreRelease
    if(-not $leftPre -and -not $rightPre){return 0}
    if(-not $leftPre){return 1}
    if(-not $rightPre){return -1}

    $leftParts=@($leftPre -split '\.')
    $rightParts=@($rightPre -split '\.')
    $count=[Math]::Max($leftParts.Count,$rightParts.Count)
    for($i=0;$i -lt $count;$i++){
        if($i -ge $leftParts.Count){return -1}
        if($i -ge $rightParts.Count){return 1}
        $a=[string]$leftParts[$i]
        $b=[string]$rightParts[$i]
        $aNum=0;$bNum=0
        $aIsNum=[int]::TryParse($a,[ref]$aNum)
        $bIsNum=[int]::TryParse($b,[ref]$bNum)
        if($aIsNum -and $bIsNum){
            if($aNum -lt $bNum){return -1}
            if($aNum -gt $bNum){return 1}
        }elseif($aIsNum -and -not $bIsNum){
            return -1
        }elseif(-not $aIsNum -and $bIsNum){
            return 1
        }else{
            $cmp=[string]::CompareOrdinal($a,$b)
            if($cmp -lt 0){return -1}
            if($cmp -gt 0){return 1}
        }
    }
    return 0
}

function Write-JsonUtf8 {
    param([string]$Path,$Value)
    if(-not $Path){return}
    $dir=Split-Path $Path -Parent
    if($dir){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
    [IO.File]::WriteAllText(
        $Path,
        ($Value|ConvertTo-Json -Depth 12),
        (New-Object Text.UTF8Encoding($false))
    )
}

function ConvertTo-BriefNotes {
    param([string]$Text,[int]$MaxLength=5000)
    if([string]::IsNullOrWhiteSpace($Text)){return ''}
    $clean=$Text -replace '\r\n?',[Environment]::NewLine
    if($clean.Length -le $MaxLength){return $clean.Trim()}
    return ($clean.Substring(0,$MaxLength).TrimEnd()+[Environment]::NewLine+[Environment]::NewLine+'...')
}

if(-not $CurrentVersion){
    $versionPath=Join-Path $PSScriptRoot 'VERSION'
    if(Test-Path -LiteralPath $versionPath){
        $CurrentVersion=(Get-Content -LiteralPath $versionPath -Raw).Trim()
    }
}
if(-not $CurrentVersion){throw 'CurrentVersion is required.'}
if($CacheHours -lt 1){$CacheHours=24}
$Channel=$Channel.ToLowerInvariant()

$currentParsed=ConvertTo-SemVerInfo $CurrentVersion
if(-not $currentParsed){throw "Could not parse current version '$CurrentVersion'."}

$now=[DateTimeOffset]::UtcNow
$cached=$null
if($CacheFile -and (Test-Path -LiteralPath $CacheFile) -and -not $MockLatestVersion -and -not $Force){
    try{
        $cached=Get-Content -LiteralPath $CacheFile -Raw|ConvertFrom-Json
        $checkedAt=[DateTimeOffset]::Parse([string]$cached.checkedAt)
        $cachedChannel=[string]$cached.channel
        if(($now-$checkedAt).TotalHours -lt $CacheHours -and $cachedChannel -eq $Channel){
            $latestParsed=ConvertTo-SemVerInfo ([string]$cached.latestVersion)
            if($latestParsed){
                $cached.currentVersion=$currentParsed.Raw
                $cached.updateAvailable=((Compare-SemVer $latestParsed $currentParsed) -gt 0)
                $cached.source='cache'
                Write-JsonUtf8 -Path $ResultFile -Value $cached
                exit 0
            }
        }
    }catch{
        $cached=$null
    }
}

try{
    $headers=@{
        'User-Agent'="ChatGPT-MultiChat/$($currentParsed.Raw)"
        'Accept'='application/vnd.github+json'
        'X-GitHub-Api-Version'='2022-11-28'
    }

    if($MockLatestVersion){
        $release=[pscustomobject]@{
            tag_name=$MockLatestVersion.Trim()
            html_url=if($MockReleaseUrl){$MockReleaseUrl}else{'https://example.invalid/release'}
            name="Mock $($MockLatestVersion.Trim())"
            published_at=$now.ToString('o')
            body=$MockReleaseNotes
            prerelease=[bool]$MockPrerelease
            assets=@()
        }
        $source='mock'
    }elseif($Channel -eq 'stable'){
        $api="https://api.github.com/repos/$Repository/releases/latest"
        $release=Invoke-RestMethod -Uri $api -Headers $headers -Method Get -TimeoutSec 10
        $source='github'
    }else{
        $api="https://api.github.com/repos/$Repository/releases?per_page=30"
        $releases=@(Invoke-RestMethod -Uri $api -Headers $headers -Method Get -TimeoutSec 10 | Where-Object {-not $_.draft})
        $release=$null
        $best=$null
        foreach($candidate in $releases){
            $parsed=ConvertTo-SemVerInfo ([string]$candidate.tag_name)
            if(-not $parsed){continue}
            if(-not $best -or (Compare-SemVer $parsed $best) -gt 0){
                $best=$parsed
                $release=$candidate
            }
        }
        if(-not $release){throw 'No parseable release was found for the beta channel.'}
        $source='github'
    }

    $latest=[string]$release.tag_name
    $latestParsed=ConvertTo-SemVerInfo $latest
    if(-not $latestParsed){throw "Could not parse release version '$latest'."}

    $assetNames=@()
    foreach($asset in @($release.assets)){
        if($asset -and $asset.name){$assetNames+=[string]$asset.name}
    }

    $payload=[ordered]@{
        success=$true
        checkedAt=$now.ToString('o')
        currentVersion=$currentParsed.Raw
        latestVersion=$latestParsed.Raw
        updateAvailable=((Compare-SemVer $latestParsed $currentParsed) -gt 0)
        releaseUrl=[string]$release.html_url
        releaseName=[string]$release.name
        releaseNotes=(ConvertTo-BriefNotes ([string]$release.body))
        publishedAt=[string]$release.published_at
        prerelease=[bool]$release.prerelease
        channel=$Channel
        assets=$assetNames
        repository=$Repository
        source=$source
    }

    if($CacheFile -and -not $MockLatestVersion){Write-JsonUtf8 -Path $CacheFile -Value $payload}
    Write-JsonUtf8 -Path $ResultFile -Value $payload
    exit 0
}catch{
    $payload=[ordered]@{
        success=$false
        checkedAt=$now.ToString('o')
        currentVersion=$currentParsed.Raw
        latestVersion=''
        updateAvailable=$false
        releaseUrl=''
        releaseName=''
        releaseNotes=''
        publishedAt=''
        prerelease=$false
        channel=$Channel
        assets=@()
        repository=$Repository
        source='error'
        error=$_.Exception.Message
    }
    Write-JsonUtf8 -Path $ResultFile -Value $payload
    exit 0
}
