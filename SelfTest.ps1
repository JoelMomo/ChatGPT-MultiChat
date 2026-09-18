$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$errors=@()

foreach($name in @('git.exe','npx.cmd','powershell.exe')){
    if(-not(Get-Command $name -ErrorAction SilentlyContinue)){
        $errors+="Missing dependency: $name"
    }
}

foreach($required in @(
    'ChatMulti.psm1','ChatMulti.Advanced.ps1','ChatMulti.Hardening.ps1',
    'MultiChat-Tray.ps1','MultiChat.UI.ps1','MultiChat-Maintenance.ps1',
    'Cleanup-Worktrees.ps1','Validate-ManagedSession.ps1','Invoke-ManagedExternal.ps1','HardeningTest.ps1',
    'Check-Updates.ps1','config.json','PROMPT-FOR-CHATGPT.txt'
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
    if([int](Get-ChatProp $cfg 'defaultLeaseTtlMinutes' 0) -lt 1){$errors+='defaultLeaseTtlMinutes is invalid'}
    if(-not [bool](Get-ChatProp $cfg 'checkForUpdates' $false)){$errors+='checkForUpdates should default to true'}
    if([int](Get-ChatProp $cfg 'updateCheckHours' 0) -lt 1){$errors+='updateCheckHours is invalid'}

    $updateResult=Join-Path $root 'state\selftest-update.json'
    Remove-Item $updateResult -Force -ErrorAction SilentlyContinue
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Check-Updates.ps1') -CurrentVersion '2.2.1' -ResultFile $updateResult -MockLatestVersion '9.9.9' -MockReleaseUrl 'https://example.invalid/v9.9.9'
    if($LASTEXITCODE -ne 0 -or -not (Test-Path $updateResult)){
        $errors+='Update checker mock-newer test did not produce a result'
    }else{
        $updateProbe=Get-Content $updateResult -Raw|ConvertFrom-Json
        if(-not [bool]$updateProbe.updateAvailable -or [string]$updateProbe.latestVersion -ne '9.9.9'){
            $errors+='Update checker did not detect a newer version'
        }
    }
    Remove-Item $updateResult -Force -ErrorAction SilentlyContinue

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Check-Updates.ps1') -CurrentVersion '9.9.9' -ResultFile $updateResult -MockLatestVersion '9.9.9'
    if($LASTEXITCODE -ne 0 -or -not (Test-Path $updateResult)){
        $errors+='Update checker mock-current test did not produce a result'
    }else{
        $updateProbe=Get-Content $updateResult -Raw|ConvertFrom-Json
        if([bool]$updateProbe.updateAvailable){
            $errors+='Update checker incorrectly flagged the installed version as outdated'
        }
    }
    Remove-Item $updateResult -Force -ErrorAction SilentlyContinue

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

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    . (Join-Path $root 'MultiChat.UI.ps1')
    $gitView=Format-GitSummary ([pscustomobject]@{
        hasGit=$true;modified=2;untracked=3;ahead=1;behind=0
    })
    if($gitView.Text -ne '2 changed  3 new  ahead 1'){
        $errors+="Unexpected Git presentation: $($gitView.Text)"
    }
    $testForm=New-Object Windows.Forms.Form
    $testForm.FormBorderStyle='None'
    $testForm.Size=New-Object Drawing.Size(900,560)
    $testForm.BackColor=$script:UiColors.Bg
    if($testForm.FormBorderStyle -ne 'None'){
        $errors+='Borderless window mode is unavailable'
    }
    Add-WindowResizeGrips -Form $testForm -Grip 6
    $resizeGrips=@($testForm.Controls|Where-Object{$_.Name -like 'ResizeGrip*'})
    if($resizeGrips.Count -ne 8){
        $errors+="Expected 8 resize grips, found $($resizeGrips.Count)"
    }
    $windowButton=New-WindowButton -Text ([char]0x2212)
    if($windowButton.Width -ne 34 -or $windowButton.Height -ne 34){
        $errors+="Window button is not square: $($windowButton.Width)x$($windowButton.Height)"
    }
    if($windowButton.FlatAppearance.MouseOverBackColor -eq $windowButton.BackColor){
        $errors+='Window button hover state is not distinct'
    }

    $windowPanel=New-Object Windows.Forms.Panel
    $windowPanel.Size=New-Object Drawing.Size(76,36)
    $windowButton.Location=New-Object Drawing.Point(4,0)
    $windowPanel.Controls.Add($windowButton)
    $closeButton=New-WindowButton -Text ([char]0x00D7) -CloseButton
    $closeButton.Location=New-Object Drawing.Point(40,0)
    $windowPanel.Controls.Add($closeButton)
    if($windowButton.Right -gt $windowPanel.Width -or $closeButton.Right -gt $windowPanel.Width){
        $errors+='Window controls are clipped by their container'
    }

    $statusLed=New-StatusLed -Size 10
    $connectionSwitch=New-ToggleSwitch -Checked $true
    if($statusLed.Width -ne 10 -or $statusLed.Height -ne 10){
        $errors+='Status LED has an unexpected size'
    }
    if(-not (Get-ToggleSwitchChecked -Toggle $connectionSwitch)){
        $errors+='Desktop Commander switch does not default to On'
    }
    if($connectionSwitch.GetType().FullName -ne 'System.Windows.Forms.Panel'){
        $errors+='Desktop Commander switch still uses a native button/checkbox control'
    }
    if($connectionSwitch.BackColor -ne $script:UiColors.Bg){
        $errors+='Desktop Commander switch background does not match the header'
    }
    if($gitView.ToolTip -notmatch 'not tracked by Git'){
        $errors+="Unexpected Git tooltip: $($gitView.ToolTip)"
    }

    $statusLed.Dispose()
    $connectionSwitch.Dispose()
    $closeButton.Dispose()
    $windowPanel.Dispose()
    $testForm.Dispose()

    $nestedNotWorktree=Join-Path $root 'state\selftest-not-worktree'
    try{
        New-Item -ItemType Directory -Path $nestedNotWorktree -Force|Out-Null
        Set-Content (Join-Path $nestedNotWorktree 'probe.txt') 'not a worktree' -Encoding ascii
        $nestedGit=Get-ChatGitSummary ([pscustomobject]@{
            workspace=$nestedNotWorktree;originRepo=$root;branch=''
        })
        if($nestedGit.hasGit){
            $errors+='A nested plain directory was incorrectly detected as a Git worktree'
        }
    }finally{
        Remove-Item $nestedNotWorktree -Recurse -Force -ErrorAction SilentlyContinue
    }

    $cleanupBase=Join-Path $root 'state\selftest-cleanup'
    try{
        $repo=Join-Path $cleanupBase 'repo'
        $worktree=Join-Path $cleanupBase 'worktree'
        Remove-Item $cleanupBase -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $repo -Force|Out-Null
        & git -C $repo init -q
        & git -C $repo config user.email 'selftest@local'
        & git -C $repo config user.name 'MultiChat SelfTest'
        Set-Content (Join-Path $repo 'probe.txt') 'ok' -Encoding ascii
        & git -C $repo add probe.txt
        & git -C $repo commit -qm 'probe'
        $cleanupBaseSha=([string](& git -C $repo rev-parse HEAD)).Trim().ToLowerInvariant()
        & git -C $repo worktree add -q -b cleanup-probe $worktree $cleanupBaseSha

        $liveSession=[pscustomobject]@{
            id='selftest-live';project='selftest';workspace=$worktree
            originRepo=$repo;branch='cleanup-probe';active=$false
            isolated=$true;pid=$PID
        }
        if(@(Get-WorktreeCleanupCandidates -Sessions @($liveSession)).Count -ne 0){
            $errors+='Cleanup candidates included a worktree whose owner PID is still alive'
        }

        $staleSession=[pscustomobject]@{
            id='selftest-stale';project='selftest';workspace=$worktree
            originRepo=$repo;branch='cleanup-probe';active=$false
            isolated=$true;pid=999999
        }
        $replacementSession=[pscustomobject]@{
            id='selftest-replacement';project='selftest';workspace=$worktree
            originRepo=$repo;branch='cleanup-probe';active=$true
            isolated=$false;pid=$PID
        }
        if(@(Get-WorktreeCleanupCandidates -Sessions @($staleSession,$replacementSession)).Count -ne 0){
            $errors+='Cleanup candidates included a workspace currently referenced by another active session'
        }

        $candidate=[pscustomobject]@{
            id='selftest';project='selftest';workspace=$worktree
            originRepo=$repo;branch='cleanup-probe';safe=$true;reason='SAFE'
            baseRef='HEAD';baseSha=$cleanupBaseSha;canonicalRef=''
        }
        $removed=@(Invoke-SafeWorktreeCleanup -Candidates @($candidate))
        if($removed.Count -ne 1 -or (Test-Path -LiteralPath $worktree)){
            $errors+='Safe worktree cleanup did not remove the test worktree'
        }
        if((& git -C $repo branch --list cleanup-probe)){
            $errors+='Safe worktree cleanup did not remove the test branch'
        }
    }finally{
        Remove-Item $cleanupBase -Recurse -Force -ErrorAction SilentlyContinue
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'HardeningTest.ps1')
    if($LASTEXITCODE -ne 0){
        $errors+="HardeningTest.ps1 failed with exit code $LASTEXITCODE"
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
