$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$errors=@()

foreach($name in @('git.exe','npx.cmd','powershell.exe')){
    if(-not(Get-Command $name -ErrorAction SilentlyContinue)){$errors+="Falta $name"}
}

foreach($f in Get-ChildItem $root -File | Where-Object Extension -in '.ps1','.psm1'){
    $tokens=$null;$parse=$null
    [Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$parse)|Out-Null
    foreach($e in @($parse)){$errors+=("$($f.Name): "+$e.Message)}
}

try{
    Import-Module (Join-Path $root 'ChatMulti.psm1') -Force -DisableNameChecking
    $cfg=Get-ChatConfig
    if([int]$cfg.maxSlots -lt 2){$errors+='maxSlots invalido'}
    $s=New-ManagedChatSession -Task 'PORTABLE-SELFTEST' -NoWorktree
    if(-not $s.devPort){$errors+='No port was reserved'}
    if((Get-ChatColor 1) -eq (Get-ChatColor 2)){$errors+='CHAT-1/2 colors are identical'}
    Stop-ManagedChatSession
}catch{$errors+=$_.Exception.Message}

if($errors.Count){
    Write-Host 'SELF-TEST: FAIL' -ForegroundColor Red
    $errors|ForEach-Object{Write-Host (' - '+$_) -ForegroundColor Red}
    exit 1
}
Write-Host 'SELF-TEST: OK' -ForegroundColor Green
Write-Host 'Git, Node/npx, scripts, configuration, slots, colors and ports: OK.'
