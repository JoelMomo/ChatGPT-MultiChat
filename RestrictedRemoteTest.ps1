$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$errors=New-Object Collections.Generic.List[string]

function Add-RestrictedFailure {
    param([string]$Message)
    $errors.Add($Message)
}

foreach($name in @(
    'RestrictedRemote.psm1',
    'RestrictedRemote-Launcher.ps1',
    'RestrictedRemote-Child.ps1',
    'RestrictedRemote-Revoke.ps1',
    'Install-RestrictedRemote.ps1',
    'Repair-RestrictedRemoteRuntime.ps1',
    'Activate-RestrictedRemote.ps1',
    'Uninstall-RestrictedRemote.ps1',
    'Import-RestrictedRemoteChanges.ps1'
)){
    $path=Join-Path $root $name
    if(-not(Test-Path -LiteralPath $path)){
        Add-RestrictedFailure ("Missing "+$name)
        continue
    }
    $tokens=$null;$parseErrors=$null
    [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)|Out-Null
    if(@($parseErrors).Count){
        Add-RestrictedFailure ("PowerShell parse error in "+$name)
    }
}

$installerPath=Join-Path $root 'Install-RestrictedRemote.ps1'
$repairPath=Join-Path $root 'Repair-RestrictedRemoteRuntime.ps1'
$activatorPath=Join-Path $root 'Activate-RestrictedRemote.ps1'
$launcherPath=Join-Path $root 'RestrictedRemote-Launcher.ps1'
$childPath=Join-Path $root 'RestrictedRemote-Child.ps1'
if(Test-Path -LiteralPath $installerPath){
    $installer=[IO.File]::ReadAllText($installerPath)
    if($installer -match '(?s)gitDir.*\(OI\)\(CI\)M'){
        Add-RestrictedFailure 'Installer grants write access to canonical .git metadata.'
    }
    if($installer -notmatch 'shared clones'){
        Add-RestrictedFailure 'Installer does not declare shared-clone Git isolation.'
    }
    if(-not $installer.Contains("Join-Path $env:ProgramData 'ChatGPT-MultiChat\restricted-runtime'")){
        Add-RestrictedFailure 'Installer leaves the restricted runtime under the interactive user profile.'
    }
    if($installer -match "Invoke-IcaclsChecked @\(\$runtime\.Root,'/grant'"){
        Add-RestrictedFailure 'Installer grants the restricted account direct access to the interactive user npm cache.'
    }
    $descriptionMatch=[regex]::Match($installer,"\$accountDescription='([^']*)'")
    if(-not $descriptionMatch.Success -or $descriptionMatch.Groups[1].Value.Length -gt 48){
        Add-RestrictedFailure 'Restricted Windows account description exceeds the 48-character LocalAccounts limit.'
    }
}
if(Test-Path -LiteralPath $repairPath){
    $repair=[IO.File]::ReadAllText($repairPath)
    if(-not $repair.Contains("Join-Path $env:ProgramData 'ChatGPT-MultiChat\restricted-runtime'")){
        Add-RestrictedFailure 'Runtime repair does not migrate the reviewed runtime out of the interactive user profile.'
    }
    if(-not $repair.Contains('Get-RestrictedRemoteInstalledConfig')){
        Add-RestrictedFailure 'Runtime repair does not preserve the installed Restricted Remote configuration.'
    }
    if($repair -match '(?i)Remove-Item.+\.desktop-commander-device'){
        Add-RestrictedFailure 'Runtime repair can remove Restricted Remote authorization.'
    }
}
if(Test-Path -LiteralPath $activatorPath){
    $activator=[IO.File]::ReadAllText($activatorPath)
    if($activator -match '\$config\.activatedAt\s*='){
        Add-RestrictedFailure 'Activator assigns missing PSCustomObject activatedAt property directly.'
    }
    if($activator -notmatch "Add-Member -NotePropertyName activatedAt"){
        Add-RestrictedFailure 'Activator does not create activatedAt safely on first activation.'
    }
    $trayStop=$activator.IndexOf('MultiChat-Tray\.ps1')
    $authRemove=$activator.IndexOf('Remove-Item -LiteralPath $currentAuth -Force')
    if($trayStop -lt 0 -or $authRemove -lt 0 -or $trayStop -gt $authRemove){
        Add-RestrictedFailure 'Activator can remove normal authorization before stopping the tray.'
    }
}
if(Test-Path -LiteralPath $launcherPath){
    $launcher=[IO.File]::ReadAllText($launcherPath)
    if($launcher -notmatch '-UseNewEnvironment'){
        Add-RestrictedFailure 'Restricted launcher can inherit the interactive user environment.'
    }
    if(-not $launcher.Contains("GetEnvironmentVariable('SystemRoot','Machine')")){
        Add-RestrictedFailure 'Restricted launcher does not restore SystemRoot in its clean child environment.'
    }
    if(-not $launcher.Contains('restricted-remote-child.cmd')){
        Add-RestrictedFailure 'Restricted launcher does not use the native bootstrap required by Windows PowerShell clean-environment isolation.'
    }
    if($launcher.Contains('Start-Process powershell.exe') -and $launcher.Contains('-UseNewEnvironment')){
        Add-RestrictedFailure 'Restricted launcher still starts Windows PowerShell directly with UseNewEnvironment.'
    }
    if($launcher -notmatch '\$failed=\$false' -or $launcher -notmatch 'if\(-not \$failed\)'){
        Add-RestrictedFailure 'Restricted launcher can overwrite FAILED state with STOPPED.'
    }
    if($launcher -notmatch 'Restricted Remote child exited unexpectedly'){
        Add-RestrictedFailure 'Restricted launcher does not surface an unexpected child exit.'
    }
    if($launcher -notmatch 'CreateProcessWithLogonW' -or $launcher -notmatch 'CREATE_SUSPENDED'){
        Add-RestrictedFailure 'Restricted launcher does not create the credentialed child suspended before containment.'
    }
    if($launcher -match 'OpenProcess\('){
        Add-RestrictedFailure 'Restricted launcher reopens the cross-user child instead of retaining its creation handle.'
    }
    if($launcher -match '\$child\.Handle'){
        Add-RestrictedFailure 'Restricted launcher still depends on the nullable managed Handle returned by Start-Process -Credential.'
    }
    if($launcher -match '(?im)^\s*\$error\s*='){
        Add-RestrictedFailure 'Restricted launcher overwrites the reserved PowerShell Error automatic variable.'
    }
    if($launcher.Contains('IndexOf(''\\'')')){
        Add-RestrictedFailure 'Restricted launcher searches for two backslashes when splitting DOMAIN\user.'
    }
    if(-not $launcher.Contains('IndexOf(''\'')')){
        Add-RestrictedFailure 'Restricted launcher does not split DOMAIN\user on a single backslash.'
    }
    if(-not $launcher.Contains('restricted-remote-child.stderr.tmp')){
        Add-RestrictedFailure 'Restricted launcher does not capture child startup stderr for diagnosis.'
    }
    if(-not $launcher.Contains('Diagnostic:')){
        Add-RestrictedFailure 'Restricted launcher does not surface bounded child startup diagnostics.'
    }
    if(-not $launcher.Contains('<redacted>')){
        Add-RestrictedFailure 'Restricted launcher diagnostics do not redact credential-like values.'
    }
}
if(Test-Path -LiteralPath $childPath){
    $child=[IO.File]::ReadAllText($childPath)
    if($child -notmatch "MULTICHAT_RESTRICTED_REMOTE='1'"){
        Add-RestrictedFailure 'Restricted child does not enable restricted session isolation.'
    }
    if($child -notmatch "GIT_CONFIG_NOSYSTEM='1'"){
        Add-RestrictedFailure 'Restricted child does not suppress system Git configuration.'
    }
    if($child -notmatch 'MULTICHAT_STATE_ROOT' -or $child -notmatch 'MULTICHAT_WORKSPACE_ROOT'){
        Add-RestrictedFailure 'Restricted child does not isolate MultiChat state and workspace roots.'
    }
}

$temp=Join-Path $env:TEMP ('MultiChat-RestrictedClone-'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $temp 'source'
$testState=Join-Path $temp 'state'
$testWorkspaces=Join-Path $temp 'workspaces'
$session=$null
$oldRestricted=$env:MULTICHAT_RESTRICTED_REMOTE
$oldStateRoot=$env:MULTICHAT_STATE_ROOT
$oldWorkspaceRoot=$env:MULTICHAT_WORKSPACE_ROOT
$oldSession=$env:CHATGPT_SESSION_ID
$oldSlot=$env:CHATGPT_SLOT
$oldProject=$env:CHATGPT_PROJECT
$oldWorkspace=$env:CHATGPT_WORKSPACE
$env:MULTICHAT_RESTRICTED_REMOTE='1'
$env:MULTICHAT_STATE_ROOT=$testState
$env:MULTICHAT_WORKSPACE_ROOT=$testWorkspaces
Import-Module (Join-Path $root 'ChatMulti.psm1') -Force -DisableNameChecking
$restrictedRegistry=Join-Path $testState 'restricted-projects.json'
try{
    New-Item -ItemType Directory -Path $source -Force|Out-Null
    & git -C $source init -q
    & git -C $source config user.name 'MultiChat Test'
    & git -C $source config user.email 'multichat-test@example.invalid'
    [IO.File]::WriteAllText((Join-Path $source 'probe.txt'),'restricted clone probe',(New-Object Text.UTF8Encoding($false)))
    & git -C $source add probe.txt
    & git -C $source commit -q -m 'probe'
    if($LASTEXITCODE -ne 0){throw 'Could not create restricted-clone test repository.'}
    $sha=([string](& git -C $source rev-parse HEAD)).Trim()

    New-Item -ItemType Directory -Path (Split-Path $restrictedRegistry -Parent) -Force|Out-Null
    $approved=@([pscustomobject]@{name='source';path=$source;lastUsed=(Get-Date).ToString('o')})
    [IO.File]::WriteAllText($restrictedRegistry,($approved|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))

    $env:MULTICHAT_RESTRICTED_REMOTE='1'
    $session=New-ManagedChatSession -ProjectPath $source -Task 'restricted-clone-test' -BaseRef 'HEAD' -BaseSha $sha -CanonicalRef 'HEAD'
    if([string](Get-ChatProp $session 'workspaceKind' '') -ne 'clone'){
        Add-RestrictedFailure 'Restricted session did not create a clone workspace.'
    }
    $workspaceFull=[IO.Path]::GetFullPath([string]$session.workspace)
    $expectedWorkspaceRoot=[IO.Path]::GetFullPath($testWorkspaces).TrimEnd('\')+'\'
    if(-not $workspaceFull.StartsWith($expectedWorkspaceRoot,[StringComparison]::OrdinalIgnoreCase)){
        Add-RestrictedFailure 'Restricted session escaped its dedicated workspace root.'
    }
    if(-not(Test-Path -LiteralPath (Join-Path $testState ('sessions\'+$session.id+'.json')))){
        Add-RestrictedFailure 'Restricted session state was not isolated in its dedicated state root.'
    }
    if(-not(Test-Path -LiteralPath (Join-Path $session.workspace '.git') -PathType Container)){
        Add-RestrictedFailure 'Restricted workspace does not have an independent .git directory.'
    }
    $sourceBranch=@(& git -C $source branch --list ([string]$session.branch))
    if($sourceBranch.Count){
        Add-RestrictedFailure 'Restricted session branch leaked into the canonical repository.'
    }

    $identity=Get-ManagedWorktreeIdentity -Session $session
    if(-not $identity.Valid){
        Add-RestrictedFailure ("Restricted clone identity validation failed: "+$identity.Reason)
    }

    Stop-ManagedChatSession
    Set-Location -LiteralPath $root
    $ended=Get-ManagedChatSession -Id ([string]$session.id)
    $ended|Add-Member -NotePropertyName pid -NotePropertyValue 0 -Force
    $candidates=@(Get-WorktreeCleanupCandidates -Sessions @($ended))
    if($candidates.Count -ne 1 -or -not $candidates[0].safe){
        $reason=if($candidates.Count){[string]$candidates[0].reason}else{'NO_CANDIDATE'}
        Add-RestrictedFailure ("Clean restricted clone was not safe to clean: "+$reason)
    }else{
        $removed=@(Invoke-SafeWorktreeCleanup -Candidates @($candidates[0]))
        if($removed.Count -ne 1 -or (Test-Path -LiteralPath ([string]$session.workspace))){
            Add-RestrictedFailure 'Restricted clone cleanup did not remove the isolated clone.'
        }
    }
}catch{
    Add-RestrictedFailure $_.Exception.Message
}finally{
    if($session){
        Remove-Item -LiteralPath (Join-Path $testState ('sessions\'+$session.id+'.json')) -Force -ErrorAction SilentlyContinue
        if(Test-Path -LiteralPath ([string]$session.workspace)){
            Remove-Item -LiteralPath ([string]$session.workspace) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $env:MULTICHAT_RESTRICTED_REMOTE=$oldRestricted
    $env:MULTICHAT_STATE_ROOT=$oldStateRoot
    $env:MULTICHAT_WORKSPACE_ROOT=$oldWorkspaceRoot
    $env:CHATGPT_SESSION_ID=$oldSession
    $env:CHATGPT_SLOT=$oldSlot
    $env:CHATGPT_PROJECT=$oldProject
    $env:CHATGPT_WORKSPACE=$oldWorkspace
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if($errors.Count){
    Write-Host 'RESTRICTED REMOTE TEST: FAIL' -ForegroundColor Red
    $errors|ForEach-Object{Write-Host (' - '+$_) -ForegroundColor Red}
    exit 1
}
Write-Host 'RESTRICTED REMOTE TEST: OK' -ForegroundColor Green
Write-Host 'Canonical Git metadata remained untouched; restricted sessions used isolated shared clones.'
