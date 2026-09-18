param(
    [string]$CurrentVersion,
    [string]$ResultFile,
    [string]$CacheFile,
    [int]$CacheHours=24,
    [string]$Repository='JoelMomo/ChatGPT-MultiChat',
    [string]$MockLatestVersion,
    [string]$MockReleaseUrl
)

$ErrorActionPreference='Stop'

function ConvertTo-VersionSafe {
    param([string]$Value)
    if([string]::IsNullOrWhiteSpace($Value)){return $null}
    $clean=$Value.Trim()
    if($clean.StartsWith('v',[StringComparison]::OrdinalIgnoreCase)){$clean=$clean.Substring(1)}
    $match=[regex]::Match($clean,'^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?')
    if(-not $match.Success){return $null}
    $build=if($match.Groups[4].Success){[int]$match.Groups[4].Value}else{0}
    return New-Object System.Version -ArgumentList @(
        [int]$match.Groups[1].Value,
        [int]$match.Groups[2].Value,
        [int]$match.Groups[3].Value,
        $build
    )
}

function Write-JsonUtf8 {
    param([string]$Path,$Value)
    if(-not $Path){return}
    $dir=Split-Path $Path -Parent
    if($dir){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
    [IO.File]::WriteAllText(
        $Path,
        ($Value|ConvertTo-Json -Depth 8),
        (New-Object Text.UTF8Encoding($false))
    )
}

if(-not $CurrentVersion){
    $versionPath=Join-Path $PSScriptRoot 'VERSION'
    if(Test-Path -LiteralPath $versionPath){
        $CurrentVersion=(Get-Content -LiteralPath $versionPath -Raw).Trim()
    }
}
if(-not $CurrentVersion){throw 'CurrentVersion is required.'}
if($CacheHours -lt 1){$CacheHours=24}

$now=[DateTimeOffset]::UtcNow
$cached=$null
if($CacheFile -and (Test-Path -LiteralPath $CacheFile) -and -not $MockLatestVersion){
    try{
        $cached=Get-Content -LiteralPath $CacheFile -Raw|ConvertFrom-Json
        $checkedAt=[DateTimeOffset]::Parse([string]$cached.checkedAt)
        if(($now-$checkedAt).TotalHours -lt $CacheHours){
            $currentParsed=ConvertTo-VersionSafe $CurrentVersion
            $latestParsed=ConvertTo-VersionSafe ([string]$cached.latestVersion)
            if($currentParsed -and $latestParsed){
                $cached.currentVersion=$CurrentVersion.Trim().TrimStart('v','V')
                $cached.updateAvailable=($latestParsed -gt $currentParsed)
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
    if($MockLatestVersion){
        $latest=$MockLatestVersion.Trim()
        $releaseUrl=if($MockReleaseUrl){$MockReleaseUrl}else{'https://example.invalid/release'}
        $releaseName="Mock $latest"
        $publishedAt=$now.ToString('o')
        $source='mock'
    }else{
        $headers=@{
            'User-Agent'="ChatGPT-MultiChat/$CurrentVersion"
            'Accept'='application/vnd.github+json'
            'X-GitHub-Api-Version'='2022-11-28'
        }
        $api="https://api.github.com/repos/$Repository/releases/latest"
        $release=Invoke-RestMethod -Uri $api -Headers $headers -Method Get -TimeoutSec 10
        $latest=[string]$release.tag_name
        $releaseUrl=[string]$release.html_url
        $releaseName=[string]$release.name
        $publishedAt=[string]$release.published_at
        $source='github'
    }

    $currentParsed=ConvertTo-VersionSafe $CurrentVersion
    $latestParsed=ConvertTo-VersionSafe $latest
    if(-not $currentParsed -or -not $latestParsed){throw 'Could not parse update version.'}

    $payload=[ordered]@{
        success=$true
        checkedAt=$now.ToString('o')
        currentVersion=$CurrentVersion.Trim().TrimStart('v','V')
        latestVersion=$latest.Trim().TrimStart('v','V')
        updateAvailable=($latestParsed -gt $currentParsed)
        releaseUrl=$releaseUrl
        releaseName=$releaseName
        publishedAt=$publishedAt
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
        currentVersion=$CurrentVersion.Trim().TrimStart('v','V')
        latestVersion=''
        updateAvailable=$false
        releaseUrl=''
        repository=$Repository
        source='error'
        error=$_.Exception.Message
    }
    Write-JsonUtf8 -Path $ResultFile -Value $payload
    exit 0
}
