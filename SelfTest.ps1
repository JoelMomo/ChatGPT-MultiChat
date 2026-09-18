$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$errors=@()

foreach($name in @('git.exe','npx.cmd','powershell.exe')){
    if(-not(Get-Command $name -ErrorAction SilentlyContinue)){
        $errors+="Missing dependency: $name"
    }
}

foreach($required in @(
    'ChatMulti.psm1','ChatMulti.Advanced.ps1',
    'MultiChat-Tray.ps1','MultiChat.UI.ps1','MultiChat-Maintenance.ps1',
    'Cleanup-Worktrees.ps1',
    'config.json','PROMPT-FOR-CHATGPT.txt'
)){
    if(-not(Test-Path -LiteralPath (Join-Path $root $required))){
        $errors+="Missing file: $required"
    }
}

foreach($file in Get-ChildItem $root -File|Where-Object Extension -in '.ps1','.psm1'){
    $tokens=$null
    $parse=$null
    [Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,[ref]$tokens,[ref]$parse
    )|Out-Null
    foreach($error in @($parse)){
        $errors+=("$($file.Name): "+$error.Message)
    }
}

try{
    Import-Module (Join-Path $root 'ChatMulti.psm1') -Force -DisableNameChecking
    $cfg=Get-ChatConfig

    if([int]$cfg.maxSlots -lt 2){$errors+='Invalid maxSlots value'}
    if([int]$cfg.refreshSeconds -lt 1){$errors+='refreshSeconds is too low'}
    if([int]$cfg.maintenanceRefreshSeconds -lt 5){$errors+='maintenanceRefreshSeconds is too low'}
    if([int]$cfg.cleanupScanSeconds -lt 10){$errors+='cleanupScanSeconds is too low'}

    $projectsPath=Join-Path $root 'state\projects.json'
    $hadProjects=Test-Path -LiteralPath $projectsPath
    $projectsBackup=if($hadProjects){[IO.File]::ReadAllText($projectsPath)}else{$null}
    try{
        New-Item -ItemType Directory -Path (Split-Path $projectsPath -Parent) -Force|Out-Null
        $fixture=@(
            [pscustomobject]@{name='broken'},
            [pscustomobject]@{name='valid';path=$root}
        )|ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText($projectsPath,$fixture,(New-Object Text.UTF8Encoding($false)))
        $registered=@(Get-RegisteredChatProjects)
        if($registered.Count -ne 1 -or $registered[0].path -ne $root){
            $errors+='Project registry does not ignore incomplete entries correctly'
        }
    }finally{
        if($hadProjects){
            [IO.File]::WriteAllText($projectsPath,$projectsBackup,(New-Object Text.UTF8Encoding($false)))
        }else{
            Remove-Item -LiteralPath $projectsPath -Force -ErrorAction SilentlyContinue
        }
    }

    $session=New-ManagedChatSession -Task 'PORTABLE-SELFTEST' -NoWorktree
    if(-not $session.devPort){$errors+='No port was reserved'}

    $indexed=@(Get-ManagedChatSessions -ActiveOnly -SkipLivenessCheck)
    if(-not ($indexed | Where-Object { $_.id -eq $session.id })){
        $errors+='Active-slot session index did not return the current session'
    }

    if((Get-ChatColor 1) -eq (Get-ChatColor 2)){
        $errors+='CHAT-1/2 colors are identical'
    }
    Stop-ManagedChatSession
}catch{
    $errors+=$_.Exception.Message
}

if($errors.Count){
    Write-Host 'SELF-TEST: FAIL' -ForegroundColor Red
    $errors|ForEach-Object{
        Write-Host (' - '+$_) -ForegroundColor Red
    }
    exit 1
}

Write-Host 'SELF-TEST: OK' -ForegroundColor Green
Write-Host 'Dependencies, scripts, configuration, registry robustness, slots, colors and ports: OK.'
