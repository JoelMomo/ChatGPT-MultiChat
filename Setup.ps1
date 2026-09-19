$ErrorActionPreference='Stop'
$root=$PSScriptRoot

foreach($dir in @('state','state\locks','state\sessions','state\slots','state\ports','state\logs','workspaces','dist')){
    $path=Join-Path $root $dir
    if(-not(Test-Path -LiteralPath $path)){New-Item -ItemType Directory -Path $path -Force|Out-Null}
}

$desktop=[Environment]::GetFolderPath('Desktop')
$version=if(Test-Path -LiteralPath (Join-Path $root 'VERSION')){(Get-Content (Join-Path $root 'VERSION') -Raw).Trim()}else{'current'}
$lnk=Join-Path $desktop ("ChatGPT MultiChat v{0}.lnk" -f $version)
$legacyLnk=Join-Path $desktop 'ChatGPT MultiChat Agent.lnk'
if(Test-Path -LiteralPath $legacyLnk){Remove-Item -LiteralPath $legacyLnk -Force -ErrorAction SilentlyContinue}
$ws=New-Object -ComObject WScript.Shell
$s=$ws.CreateShortcut($lnk)
$s.TargetPath=Join-Path $root 'Start-MultiChat-Agent.cmd'
$s.WorkingDirectory=$root
$s.Description='ChatGPT MultiChat Agent'
$s.IconLocation='powershell.exe,0'
$s.Save()

$panicLnk=Join-Path $desktop 'EMERGENCY - Disconnect Desktop Commander.lnk'
$p=$ws.CreateShortcut($panicLnk)
$p.TargetPath='powershell.exe'
$p.Arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Emergency-Stop-DesktopCommander.ps1')+'"'
$p.WorkingDirectory=$root
$p.Description='Immediately stop Desktop Commander remote access and remove saved local authorization'
$p.IconLocation='shell32.dll,78'
$p.Save()

try{
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Harden-DesktopCommander.ps1')|Out-Null
}catch{
    Write-Warning ('Desktop Commander hardening could not be applied: '+$_.Exception.Message)
}

Write-Host 'ChatGPT MultiChat is ready.' -ForegroundColor Green
Write-Host ('Folder: '+$root)
Write-Host ('Shortcut: '+$lnk)
Write-Host ('Emergency shortcut: '+$panicLnk)
Write-Host ''
Write-Host 'Automatic startup has not been configured.' -ForegroundColor DarkGray
