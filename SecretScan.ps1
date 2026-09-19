param(
    [switch]$History
)

$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$patterns=[ordered]@{
    GitHubPAT='(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})'
    OpenAIKey='sk-(?:proj-)?[A-Za-z0-9_-]{20,}'
    AWSAccessKey='AKIA[0-9A-Z]{16}'
    PrivateKey='BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY'
    SlackToken='xox[baprs]-[A-Za-z0-9-]{10,}'
    GoogleApiKey='AIza[0-9A-Za-z_-]{30,}'
    StripeLiveKey='sk_live_[0-9A-Za-z]{16,}'
}

$findings=New-Object Collections.Generic.List[object]
Push-Location $root
try{
    foreach($relative in @(git ls-files)){
        $path=Join-Path $root $relative
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){continue}
        try{
            $bytes=[IO.File]::ReadAllBytes($path)
            if($bytes.Length -gt 8MB){continue}
            if($bytes -contains 0){continue}
            $text=[Text.Encoding]::UTF8.GetString($bytes)
            foreach($name in $patterns.Keys){
                if([regex]::IsMatch($text,$patterns[$name])){
                    $findings.Add([pscustomobject]@{Type=$name;File=$relative})
                }
            }
        }catch{}
    }

    if($History){
        $historyCounts=@{}
        foreach($name in $patterns.Keys){$historyCounts[$name]=0}
        git log -p --all --no-color --no-ext-diff --text | ForEach-Object {
            $line=[string]$_
            foreach($name in $patterns.Keys){
                $historyCounts[$name]+=[regex]::Matches($line,$patterns[$name]).Count
            }
        }
        foreach($name in $patterns.Keys){
            if($historyCounts[$name] -gt 0){
                $findings.Add([pscustomobject]@{Type=('History:'+ $name);File=('<'+$historyCounts[$name]+' match(es)>')})
            }
        }
    }
}finally{
    Pop-Location
}
if($findings.Count){
    Write-Host 'SECRET SCAN: FAIL' -ForegroundColor Red
    foreach($f in $findings){
        Write-Host (" - {0}: {1}" -f $f.Type,$f.File) -ForegroundColor Red
    }
    Write-Host 'Matched secret values are intentionally not printed.' -ForegroundColor Yellow
    exit 1
}

Write-Host 'SECRET SCAN: OK' -ForegroundColor Green
if($History){
    Write-Host 'Tracked files and Git patch history contain no recognized high-confidence credential patterns.'
}else{
    Write-Host 'Tracked files contain no recognized high-confidence credential patterns.'
}
