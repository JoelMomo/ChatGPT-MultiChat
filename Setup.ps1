$ErrorActionPreference='Stop'
$root=$PSScriptRoot

foreach($dir in @('state','state\locks','state\sessions','state\slots','state\ports','state\logs','workspaces','dist')){
    $path=Join-Path $root $dir
    if(-not(Test-Path -LiteralPath $path)){New-Item -ItemType Directory -Path $path -Force|Out-Null}
}

$desktop=[Environment]::GetFolderPath('Desktop')
$lnk=Join-Path $desktop 'ChatGPT MultiChat Agent.lnk'
$ws=New-Object -ComObject WScript.Shell
$s=$ws.CreateShortcut($lnk)
$s.TargetPath=Join-Path $root 'Start-MultiChat-Agent.cmd'
$s.WorkingDirectory=$root
$s.Description='ChatGPT MultiChat Agent'
$s.IconLocation='powershell.exe,0'
$s.Save()

Write-Host 'ChatGPT MultiChat is ready.' -ForegroundColor Green
Write-Host ('Folder: '+$root)
Write-Host ('Shortcut: '+$lnk)
Write-Host ''
Write-Host 'Automatic startup has not been configured.' -ForegroundColor DarkGray
