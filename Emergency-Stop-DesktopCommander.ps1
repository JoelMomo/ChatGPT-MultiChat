param(
    [switch]$KeepLocalAuthorization
)

$ErrorActionPreference='SilentlyContinue'
$root=$PSScriptRoot
$cache=Join-Path $root 'state\cache'
$flag=Join-Path $cache 'desktop-commander.disabled'

New-Item -ItemType Directory -Path $cache -Force|Out-Null
[IO.File]::WriteAllText(
    $flag,
    ((Get-Date).ToString('o')+"\r\n"),
    (New-Object Text.UTF8Encoding($false))
)

$targets=@(Get-CimInstance Win32_Process|Where-Object{
    $_.CommandLine -match 'desktop-commander' -and $_.CommandLine -match '\bremote\b'
})
foreach($proc in $targets){
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 350
foreach($proc in @(Get-CimInstance Win32_Process|Where-Object{
    $_.CommandLine -match 'desktop-commander' -and $_.CommandLine -match '\bremote\b'
})){
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
}

if(-not $KeepLocalAuthorization){
    Remove-Item -LiteralPath (Join-Path $env:USERPROFILE '.desktop-commander-device\device.json') -Force -ErrorAction SilentlyContinue
}

Write-Host 'Desktop Commander remote access is stopped.' -ForegroundColor Green
Write-Host ('Kill switch: '+$flag)
if($KeepLocalAuthorization){
    Write-Host 'Saved local authorization was preserved.' -ForegroundColor DarkGray
}else{
    Write-Host 'Saved local authorization was removed. Reauthorization will be required.' -ForegroundColor Yellow
}
