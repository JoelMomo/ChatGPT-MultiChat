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
    'Cleanup-Worktrees.ps1','Validate-ManagedSession.ps1','Invoke-ManagedExternal.ps1','HardeningTest.ps1','CapacityTest.ps1',
    'Emergency-Stop-DesktopCommander.ps1','Harden-DesktopCommander.ps1','SecurityTest.ps1','SecretScan.ps1',
    'PortabilityTest.ps1','RestrictedRemoteTest.ps1','RestrictedRemote.psm1','RestrictedRemote-Launcher.ps1','RestrictedRemote-Child.ps1','RestrictedRemote-Revoke.ps1','Install-RestrictedRemote.ps1','Activate-RestrictedRemote.ps1','Uninstall-RestrictedRemote.ps1','Import-RestrictedRemoteChanges.ps1',
    'Check-Updates.ps1','Update-MultiChat.ps1','Sign-ReleasePackage.ps1','Test-ReleaseSignature.ps1','Publish-Release.ps1',
    'RELEASE-PUBLIC-KEY.xml','config.json','PROMPT-FOR-CHATGPT.txt'
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

    if([int]$cfg.maxSlots -lt 2 -or [int]$cfg.maxSlots -gt 32){$errors+='Invalid maxSlots value'}
    if([int]$cfg.refreshSeconds -lt 1){$errors+='refreshSeconds is too low'}
    if([int]$cfg.maintenanceRefreshSeconds -lt 5){$errors+='maintenanceRefreshSeconds is too low'}
    if([int]$cfg.cleanupScanSeconds -lt 10){$errors+='cleanupScanSeconds is too low'}
    if([int](Get-ChatProp $cfg 'defaultLeaseTtlMinutes' 0) -lt 1){$errors+='defaultLeaseTtlMinutes is invalid'}
    if(-not [bool](Get-ChatProp $cfg 'checkForUpdates' $false)){$errors+='checkForUpdates should default to true'}
    if([int](Get-ChatProp $cfg 'updateCheckHours' 0) -lt 1){$errors+='updateCheckHours is invalid'}
    if([string](Get-ChatProp $cfg 'updateChannel' '') -notin @('stable','beta')){$errors+='updateChannel is invalid'}

    $idleProbe=[pscustomobject]@{status='READY';updatedAt=(Get-Date).AddHours(-2).ToString('o')}
    $idleInfo=Get-SessionIdleInfo -Session $idleProbe -SkipGit
    if(-not [bool]$idleInfo.idle){$errors+='Quiet READY sessions are not classified as IDLE'}
    if([bool]$idleInfo.expired){$errors+='Live READY sessions must not auto-expire unless explicitly opted in'}
    if([bool]$idleInfo.autoExpireEnabled){$errors+='autoExpireIdleSessions must default to false when absent'}

    $trayText=[IO.File]::ReadAllText((Join-Path $root 'MultiChat-Tray.ps1'))
    if($trayText -match '@wonderwhy-er/desktop-commander@latest'){
        $errors+='Desktop Commander must not be launched from @latest'
    }
    if($trayText -notmatch '@wonderwhy-er/desktop-commander@0\.2\.51'){
        $errors+='Desktop Commander package version is not pinned to the reviewed release'
    }
    if($trayText -notmatch 'remote > NUL 2>&1'){
        $errors+='Desktop Commander stdout/stderr is not suppressed'
    }
    if($trayText -notmatch 'desktop-commander\.disabled'){
        $errors+='Desktop Commander emergency kill switch is missing'
    }
    if($trayText -notmatch 'Test-RemoteCommanderReady'){
        $errors+='Desktop Commander readiness validation is missing'
    }
    if($trayText -notmatch 'Close-DashboardSession' -or $trayText -notmatch 'Add_CellMouseDown'){
        $errors+='Dashboard right-click session close action is missing'
    }
    if($trayText -notmatch 'activationEventName' -or $trayText -notmatch 'OpenExisting' -or $trayText -notmatch 'WaitOne\(0\)'){
        $errors+='Single-instance dashboard activation signal is missing'
    }
    $moduleText=[IO.File]::ReadAllText((Join-Path $root 'ChatMulti.psm1'))
    if($moduleText -notmatch 'function Close-ManagedChatSession' -or $moduleText -notmatch 'PID_MISMATCH'){
        $errors+='Managed chat close safety checks are missing'
    }
    $maintenanceText=[IO.File]::ReadAllText((Join-Path $root 'MultiChat-Maintenance.ps1'))
    if($maintenanceText -notmatch 'device\.json' -or $maintenanceText -notmatch 'Get-NetTCPConnection'){
        $errors+='Desktop Commander maintenance status does not validate authorization and connectivity'
    }

    try{
        $csp=New-Object Security.Cryptography.CspParameters
        $csp.ProviderType=24
        $rsa=New-Object Security.Cryptography.RSACryptoServiceProvider($csp)
        try{
            $rsa.FromXmlString([IO.File]::ReadAllText((Join-Path $root 'RELEASE-PUBLIC-KEY.xml')))
            if($rsa.KeySize -lt 3072){$errors+='Release public key is too small'}
        }finally{$rsa.Dispose()}
    }catch{
        $errors+='Release public key could not be loaded'
    }

    $updateResult=Join-Path $root 'state\selftest-update.json'
    Remove-Item $updateResult -Force -ErrorAction SilentlyContinue
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Check-Updates.ps1') -CurrentVersion '2.3.0' -ResultFile $updateResult -MockLatestVersion '9.9.9' -MockReleaseUrl 'https://example.invalid/v9.9.9'
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

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Check-Updates.ps1') -CurrentVersion '2.3.0-beta.1' -ResultFile $updateResult -Channel beta -MockLatestVersion '2.3.0-beta.2' -MockPrerelease
    if($LASTEXITCODE -ne 0 -or -not (Test-Path $updateResult)){
        $errors+='Update checker prerelease test did not produce a result'
    }else{
        $updateProbe=Get-Content $updateResult -Raw|ConvertFrom-Json
        if(-not [bool]$updateProbe.updateAvailable){
            $errors+='Update checker did not order beta prereleases correctly'
        }
    }
    Remove-Item $updateResult -Force -ErrorAction SilentlyContinue

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Check-Updates.ps1') -CurrentVersion '2.3.0' -ResultFile $updateResult -Channel beta -MockLatestVersion '2.3.0-beta.9' -MockPrerelease
    if($LASTEXITCODE -ne 0 -or -not (Test-Path $updateResult)){
        $errors+='Update checker stable-vs-beta test did not produce a result'
    }else{
        $updateProbe=Get-Content $updateResult -Raw|ConvertFrom-Json
        if([bool]$updateProbe.updateAvailable){
            $errors+='Update checker incorrectly ranked a prerelease above the same stable version'
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

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'CapacityTest.ps1')
    if($LASTEXITCODE -ne 0){
        $errors+="CapacityTest.ps1 failed with exit code $LASTEXITCODE"
    }

    $chatModule=Get-Module ChatMulti
    if($chatModule){
        # Test sessions must remain runnable while the user's configured production slots are full.
        # Raise capacity only in this SelfTest process; config.json is left unchanged.
        & $chatModule {
            $testConfig=Get-ChatConfig
            if([int]$testConfig.maxSlots -lt 32){$testConfig.maxSlots=32}
            $script:ChatConfigCache=$testConfig
        }
    }

    $session=New-ManagedChatSession -Task 'PORTABLE-SELFTEST' -NoWorktree
    Set-ManagedChatState -Status 'WORKING' -LastCommand 'SelfTest'
    if(-not $session.devPort){$errors+='No port was reserved'}

    $indexed=@(Get-ManagedChatSessions -ActiveOnly -SkipLivenessCheck)
    if(-not ($indexed | Where-Object { $_.id -eq $session.id })){
        $errors+='Active-slot session index did not return the current session'
    }

    $consoleColors=@(1..12|ForEach-Object{Get-ChatColor $_})
    if(@($consoleColors|Select-Object -Unique).Count -ne 12){
        $errors+='CHAT-1..12 console colors are not distinct'
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    . (Join-Path $root 'MultiChat.UI.ps1')
    $uiColors=@(1..32|ForEach-Object{(Get-SlotColor $_).ToArgb()})
    if(@($uiColors|Select-Object -Unique).Count -ne 32){
        $errors+='CHAT-1..32 dashboard colors are not distinct'
    }
    $gitView=Format-GitSummary ([pscustomobject]@{
        hasGit=$true;modified=2;untracked=3;ahead=1;behind=0
    })
    if($gitView.Text -ne '2 changed  3 new  ahead 1'){
        $errors+="Unexpected Git presentation: $($gitView.Text)"
    }
    $subtitleFont=New-Object Drawing.Font('Segoe UI',9)
    $connectionFont=New-Object Drawing.Font('Segoe UI Semibold',9)
    try{
        $subtitleWidth=[Windows.Forms.TextRenderer]::MeasureText('Parallel Desktop Commander sessions, without collisions.',$subtitleFont).Width
        $connectionWidth=[Windows.Forms.TextRenderer]::MeasureText('Desktop Commander  CONNECTING',$connectionFont).Width
        if($subtitleWidth -gt (900-36-508)){
            $errors+="Header subtitle would overlap right-side controls at minimum width: $subtitleWidth px"
        }
        if((18+$connectionWidth) -gt 220){
            $errors+="Desktop Commander status text would overlap its toggle: $connectionWidth px"
        }
    }finally{
        $subtitleFont.Dispose()
        $connectionFont.Dispose()
    }

    $expectedUiBg=[Drawing.Color]::FromArgb(14,16,20)
    $testForm=New-Object Windows.Forms.Form
    $testForm.FormBorderStyle='None'
    $testForm.Size=New-Object Drawing.Size(900,560)
    $testForm.BackColor=$expectedUiBg
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
    if($connectionSwitch.BackColor -ne $expectedUiBg){
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

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'SecurityTest.ps1')
    if($LASTEXITCODE -ne 0){
        $errors+="SecurityTest.ps1 failed with exit code $LASTEXITCODE"
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'SecretScan.ps1')
    if($LASTEXITCODE -ne 0){
        $errors+="SecretScan.ps1 failed with exit code $LASTEXITCODE"
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'PortabilityTest.ps1')
    if($LASTEXITCODE -ne 0){
        $errors+="PortabilityTest.ps1 failed with exit code $LASTEXITCODE"
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'RestrictedRemoteTest.ps1')
    if($LASTEXITCODE -ne 0){
        $errors+="RestrictedRemoteTest.ps1 failed with exit code $LASTEXITCODE"
    }

    Stop-ManagedChatSession
}catch{
    $errors+=$_.Exception.Message
    if($_.ScriptStackTrace){$errors+=("Stack: "+$_.ScriptStackTrace)}
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
