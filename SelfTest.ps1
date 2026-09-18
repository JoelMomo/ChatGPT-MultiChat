$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$errors=@()

foreach($name in @('git.exe','npx.cmd','powershell.exe')){
    if(-not (Get-Command $name -ErrorAction SilentlyContinue)){
        $errors+="Missing dependency: $name"
    }
}

foreach($required in @(
    'ChatMulti.psm1','ChatMulti.Advanced.ps1','ChatMulti.Performance.ps1',
    'MultiChat-Tray.ps1','MultiChat.UI.ps1','Cleanup-Worktrees.ps1',
    'config.json','PROMPT-FOR-CHATGPT.txt'
)){
    if(-not (Test-Path -LiteralPath (Join-Path $root $required))){
        $errors+="Missing file: $required"
    }
}

foreach($file in Get-ChildItem $root -File | Where-Object Extension -in '.ps1','.psm1'){
    $tokens=$null
    $parse=$null
    [Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,[ref]$tokens,[ref]$parse
    ) | Out-Null
    foreach($error in @($parse)){
        $errors+=("$($file.Name): "+$error.Message)
    }
}

try{
    Import-Module (Join-Path $root 'ChatMulti.psm1') -Force -DisableNameChecking
    $cfg=Get-ChatConfig
    if([int]$cfg.maxSlots -lt 2){$errors+='Invalid maxSlots value'}
    if([int]$cfg.cleanupScanSeconds -lt 10){$errors+='cleanupScanSeconds is too low'}

    $session=New-ManagedChatSession -Task 'PORTABLE-SELFTEST' -NoWorktree
    if(-not $session.devPort){$errors+='No port was reserved'}
    if((Get-ChatColor 1) -eq (Get-ChatColor 2)){
        $errors+='CHAT-1/2 colors are identical'
    }
    Stop-ManagedChatSession
}catch{
    $errors+=$_.Exception.Message
}

if($errors.Count){
    Write-Host 'SELF-TEST: FAIL' -ForegroundColor Red
    $errors | ForEach-Object {
        Write-Host (' - '+$_) -ForegroundColor Red
    }
    exit 1
}

Write-Host 'SELF-TEST: OK' -ForegroundColor Green
Write-Host 'Dependencies, scripts, configuration, slots, colors and ports: OK.'
