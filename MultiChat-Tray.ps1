param(
    [switch]$StartHidden,
    [string]$InstanceName='ChatGPTMultiChatAgentV2'
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference='SilentlyContinue'
$root=$PSScriptRoot
Import-Module (Join-Path $root 'ChatMulti.psm1') -Force -DisableNameChecking
. (Join-Path $root 'MultiChat.UI.ps1')
$cfg=Get-ChatConfig

$createdNew=$false
$mutex=New-Object Threading.Mutex($true,$InstanceName,[ref]$createdNew)
$activationEventName=$InstanceName+'-Activate'
if(-not $createdNew){
    $signaled=$false
    for($attempt=0;$attempt -lt 10 -and -not $signaled;$attempt++){
        try{
            $existingEvent=[Threading.EventWaitHandle]::OpenExisting($activationEventName)
            [void]$existingEvent.Set()
            $existingEvent.Dispose()
            $signaled=$true
        }catch{
            Start-Sleep -Milliseconds 100
        }
    }
    if(-not $signaled){
        [Windows.Forms.MessageBox]::Show('ChatGPT MultiChat is already running in the system tray. Double-click its tray icon to open the dashboard.','MultiChat')|Out-Null
    }
    exit 0
}
$activationEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,$activationEventName)

$script:exiting=$false
$script:lastRemoteRestart=[datetime]::MinValue
$script:lastMaintenanceStart=[datetime]::MinValue
$script:lastHistoryCheck=[datetime]::MinValue
$script:lastCleanupScanStart=[datetime]::MinValue
$script:maintenanceProcess=$null
$script:maintenanceResultFile=$null
$script:dcOnline=$false
$script:dcChecked=$false
$script:dcDesiredOnline=$false
$script:dcConnecting=$false
$script:suppressConnectionToggle=$false
$script:lastActiveChatAt=Get-Date
$script:remoteIdleNoticeShown=$false
$script:remoteLockedOff=$false
$script:gitCache=@{}
$script:cleanupCandidates=@()
$script:cachedSafe=0
$script:cachedPending=0
$script:cleanupScanProcess=$null
$script:cleanupProcess=$null
$script:cleanupScanResultFile=$null
$script:cleanupApplyResultFile=$null
$script:lastHistoryText=''
$script:updateProcess=$null
$script:updateResultFile=$null
$script:lastUpdateCheckStart=[datetime]::MinValue
$script:updateAvailable=$false
$script:updateDismissed=$false
$script:updateNotified=$false
$script:manualUpdateCheckPending=$false
$script:suppressChannelChange=$false
$script:latestVersion=''
$script:latestReleaseUrl=''
$script:latestReleaseNotes=''
$script:latestPrerelease=$false
$script:latestAssets=@()
$script:currentVersion=if(Test-Path (Join-Path $root 'VERSION')){(Get-Content (Join-Path $root 'VERSION') -Raw).Trim()}else{'0.0.0'}

$stateCacheRoot=Join-Path $root 'state\cache'
New-Item -ItemType Directory -Path $stateCacheRoot -Force|Out-Null
$script:updateCacheFile=Join-Path $stateCacheRoot 'update-cache.json'
$script:desktopCommanderPackage='@wonderwhy-er/desktop-commander@0.2.51'
$script:remoteCommanderKillSwitch=Join-Path $stateCacheRoot 'desktop-commander.disabled'
if(Test-Path -LiteralPath $script:remoteCommanderKillSwitch){
    $script:dcDesiredOnline=$false
    $script:dcConnecting=$false
    $script:dcChecked=$true
}

function Test-RemoteCommanderEmergencyStop {
    Test-Path -LiteralPath $script:remoteCommanderKillSwitch
}

function Get-RemoteCommanderAllowedDirectories {
    $candidates=New-Object Collections.Generic.List[string]
    [void]$candidates.Add($root)

    $projectsFile=Join-Path $root 'state\projects.json'
    if(Test-Path -LiteralPath $projectsFile){
        $projects=$null
        for($attempt=0;$attempt -lt 3 -and $null -eq $projects;$attempt++){
            try{$projects=Get-Content -LiteralPath $projectsFile -Raw|ConvertFrom-Json}catch{Start-Sleep -Milliseconds 100}
        }
        foreach($project in @($projects|ForEach-Object{$_})){
            $path=[string]$project.path
            if($path -and (Test-Path -LiteralPath $path)){[void]$candidates.Add($path)}
        }
    }

    $sourceRepos=Join-Path $env:USERPROFILE 'source\repos'
    if(Test-Path -LiteralPath $sourceRepos){[void]$candidates.Add($sourceRepos)}

    $normalized=@($candidates|ForEach-Object{
        try{[IO.Path]::GetFullPath($_).TrimEnd('\')}catch{}
    }|Where-Object{$_}|Sort-Object Length,ToLowerInvariant -Unique)

    $result=New-Object Collections.Generic.List[string]
    foreach($path in $normalized){
        $nested=$false
        foreach($parent in $result){
            if($path.Equals($parent,[StringComparison]::OrdinalIgnoreCase) -or
               $path.StartsWith(($parent+'\'),[StringComparison]::OrdinalIgnoreCase)){
                $nested=$true
                break
            }
        }
        if(-not $nested){[void]$result.Add($path)}
    }
    return @($result)
}

function Sync-RemoteCommanderAllowedDirectories {
    $configPath=Join-Path $env:USERPROFILE '.claude-server-commander\config.json'
    if(-not(Test-Path -LiteralPath $configPath)){return}
    try{
        $obj=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
        $allowed=@(Get-RemoteCommanderAllowedDirectories)
        $prop=$obj.PSObject.Properties['allowedDirectories']
        if($prop){$prop.Value=$allowed}else{$obj|Add-Member -NotePropertyName allowedDirectories -NotePropertyValue $allowed}
        $tmp=$configPath+'.scope.tmp'
        [IO.File]::WriteAllText($tmp,($obj|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $configPath -Force
    }catch{}
}

function Test-RemoteCommanderReady {
    try{
        $processes=@(Get-RemoteCommanderProcess)
        if($processes.Count -eq 0){return $false}

        $deviceFile=Join-Path $env:USERPROFILE '.desktop-commander-device\device.json'
        if(-not(Test-Path -LiteralPath $deviceFile)){return $false}
        $device=Get-Content -LiteralPath $deviceFile -Raw|ConvertFrom-Json
        if(-not [bool]$device.deviceId -or
           -not [bool]$device.session.access_token -or
           -not [bool]$device.session.refresh_token){
            return $false
        }

        $pids=@($processes|Select-Object -ExpandProperty ProcessId)
        return @(
            Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -in $pids -and $_.RemotePort -eq 443 }
        ).Count -gt 0
    }catch{
        return $false
    }
}

function Get-RemoteCommanderProcess {
    @(Get-CimInstance Win32_Process|Where-Object{
        $_.CommandLine -match 'desktop-commander' -and $_.CommandLine -match '\bremote\b'
    })
}

function Start-RemoteCommanderHidden {
    Sync-RemoteCommanderAllowedDirectories
    if(Test-RemoteCommanderEmergencyStop){
        $script:dcDesiredOnline=$false
        $script:dcOnline=$false
        $script:dcChecked=$true
        $script:dcConnecting=$false
        return $false
    }
    if(-not(Get-Command npx.cmd -ErrorAction SilentlyContinue)){
        $script:dcConnecting=$false
        return $false
    }
    $log=Join-Path $root 'state\logs\desktop-commander.log'
    try{
        Add-Content -LiteralPath $log -Value ((Get-Date).ToString('o')+' START '+$script:desktopCommanderPackage) -Encoding UTF8
    }catch{}
    # Do not persist Remote Desktop Commander stdout/stderr: upstream output contains tool arguments and results.
    $cmd='npx.cmd '+$script:desktopCommanderPackage+' remote > NUL 2>&1'
    Start-Process cmd.exe -ArgumentList '/c',$cmd -WindowStyle Hidden|Out-Null
    $script:lastRemoteRestart=Get-Date
    $script:dcChecked=$false
    $script:dcOnline=$false
    $script:dcConnecting=$true
    $script:lastMaintenanceStart=[datetime]::MinValue
    return $true
}

function Clear-RemoteCommanderSensitiveHistory {
    if(-not [bool](Get-ChatProp $cfg 'remotePurgeHistoryOnDisconnect' $true)){return}
    $historyRoot=Join-Path $env:USERPROFILE '.claude-server-commander'
    if(-not(Test-Path -LiteralPath $historyRoot)){return}
    foreach($file in @(Get-ChildItem -LiteralPath $historyRoot -File -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like 'claude_tool_call*.log' -or $_.Name -like 'tool-history*.jsonl'
    })){
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Stop-RemoteCommander {
    foreach($proc in @(Get-RemoteCommanderProcess)){
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 150
    Clear-RemoteCommanderSensitiveHistory
    $script:dcOnline=$false
    $script:dcChecked=$true
    $script:dcConnecting=$false
    $script:lastMaintenanceStart=[datetime]::MinValue
}

function Set-DesktopCommanderEnabled {
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [switch]$ForceRestart
    )

    if($Enabled -and (Test-RemoteCommanderEmergencyStop)){
        Remove-Item -LiteralPath $script:remoteCommanderKillSwitch -Force -ErrorAction SilentlyContinue
    }
    if($Enabled){
        $script:lastActiveChatAt=Get-Date
        $script:remoteIdleNoticeShown=$false
        $script:remoteLockedOff=$false
    }
    $script:dcDesiredOnline=$Enabled
    if(-not $Enabled){
        Stop-RemoteCommander
        return
    }

    if($ForceRestart){Stop-RemoteCommander}
    $existing=@(Get-RemoteCommanderProcess)
    if($existing.Count -gt 0){
        $script:dcOnline=Test-RemoteCommanderReady
        $script:dcChecked=$true
        $script:dcConnecting=(-not $script:dcOnline)
        $script:lastMaintenanceStart=[datetime]::MinValue
        return
    }

    [void](Start-RemoteCommanderHidden)
}

function Restart-RemoteCommander {
    $script:suppressConnectionToggle=$true
    if($connectionToggle){Set-ToggleSwitchChecked -Toggle $connectionToggle -Checked $true}
    $script:suppressConnectionToggle=$false
    Set-DesktopCommanderEnabled -Enabled $true -ForceRestart
}

function Test-WorkstationLocked {
    try{return [bool](Get-Process LogonUI -ErrorAction SilentlyContinue)}catch{return $false}
}

function Apply-RemoteExposurePolicy {
    param([Parameter(Mandatory)][array]$Sessions)

    if(-not $script:dcDesiredOnline -and @(Get-RemoteCommanderProcess).Count -gt 0){
        Stop-RemoteCommander
        return
    }

    if([bool](Get-ChatProp $cfg 'remoteDisconnectOnLock' $true) -and (Test-WorkstationLocked)){
        if($script:dcDesiredOnline -or @(Get-RemoteCommanderProcess).Count -gt 0){
            $script:remoteLockedOff=$true
            Set-DesktopCommanderEnabled -Enabled $false
        }
        return
    }

    if($Sessions.Count -gt 0){
        $script:lastActiveChatAt=Get-Date
        $script:remoteIdleNoticeShown=$false
        return
    }

    $minutes=[int](Get-ChatProp $cfg 'remoteIdleDisconnectMinutes' 30)
    if($minutes -le 0 -or -not $script:dcDesiredOnline){return}
    if(((Get-Date)-$script:lastActiveChatAt).TotalMinutes -lt $minutes){return}

    Set-DesktopCommanderEnabled -Enabled $false
    if(-not $script:remoteIdleNoticeShown){
        $script:remoteIdleNoticeShown=$true
        try{$notify.ShowBalloonTip(3500,'Desktop Commander disconnected',("No managed chats were active for {0} minutes. Remote access was turned off." -f $minutes),'Info')}catch{}
    }
}

function Invoke-DesktopCommanderEmergencyStop {
    param([switch]$ForgetRemoteSession)

    $script:dcDesiredOnline=$false
    $emergencyScript=Join-Path $root 'Emergency-Stop-DesktopCommander.ps1'
    if(Test-Path -LiteralPath $emergencyScript){
        $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$emergencyScript)
        if(-not $ForgetRemoteSession){
            $args+='-KeepLocalAuthorization'
            $args+='-SkipServerRevocation'
        }
        try{
            $proc=Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru
            $proc.WaitForExit(30000)|Out-Null
            $proc.Dispose()
        }catch{
            Stop-RemoteCommander
        }
    }else{
        Stop-RemoteCommander
    }

    $script:dcOnline=$false
    $script:dcChecked=$true
    $script:dcConnecting=$false
}

function Get-GitSnapshot {
    param($Session)
    $id=[string](Get-ChatProp $Session 'id' '')
    if(-not $id){return $null}
    return $script:gitCache[$id]
}

function Set-ConfigProperty {
    param([Parameter(Mandatory)][string]$Name,$Value)
    $configPath=Join-Path $root 'config.json'
    try{
        $obj=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
        $prop=$obj.PSObject.Properties[$Name]
        if($prop){$prop.Value=$Value}else{$obj|Add-Member -NotePropertyName $Name -NotePropertyValue $Value}
        [IO.File]::WriteAllText($configPath,($obj|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
        $cfgProp=$cfg.PSObject.Properties[$Name]
        if($cfgProp){$cfgProp.Value=$Value}else{$cfg|Add-Member -NotePropertyName $Name -NotePropertyValue $Value}
        return $true
    }catch{
        return $false
    }
}

function Get-ChatCapacity {
    try{$value=[int](Get-ChatConfig).maxSlots}catch{$value=8}
    if($value -lt 2){$value=2}
    if($value -gt 32){$value=32}
    return $value
}

function Get-HighestActiveSlot {
    $highest=0
    foreach($session in @(Get-ManagedChatSessions -ActiveOnly -SkipLivenessCheck)){
        $slot=[int](Get-ChatProp $session 'slot' 0)
        if($slot -gt $highest){$highest=$slot}
    }
    return $highest
}

function Update-CapacityUi {
    if(-not $capacityValueButton){return}
    $value=Get-ChatCapacity
    if($capacityValueButton.Text -ne [string]$value){$capacityValueButton.Text=[string]$value}
    $highest=Get-HighestActiveSlot
    $capacityMinusButton.Enabled=($value -gt [Math]::Max(2,$highest))
    $capacityPlusButton.Enabled=($value -lt 32)
    $capacityToolTip.SetToolTip(
        $capacityValueButton,
        ("Maximum managed chat sessions: {0}. Click for presets." -f $value)
    )
}

function Set-ChatCapacity {
    param([Parameter(Mandatory)][int]$Value)

    if($Value -lt 2 -or $Value -gt 32){
        Show-MultiChatInfo -Owner $form -Title 'Invalid chat capacity' -Message 'Chat capacity must be between 2 and 32.'
        return $false
    }

    $highest=Get-HighestActiveSlot
    if($highest -gt $Value){
        Show-MultiChatInfo -Owner $form -Title 'Capacity is in use' -Message ("CHAT-{0} is currently active. Close higher-numbered sessions before reducing capacity below {0}." -f $highest)
        return $false
    }

    if(-not(Set-ConfigProperty -Name 'maxSlots' -Value $Value)){
        Show-MultiChatInfo -Owner $form -Title 'Could not save capacity' -Message 'MultiChat could not update config.json.'
        return $false
    }

    Update-CapacityUi
    Refresh-Dashboard
    return $true
}

function Get-UpdateChannel {
    $channel=[string](Get-ChatProp $cfg 'updateChannel' 'stable')
    if($channel -notin @('stable','beta')){$channel='stable'}
    return $channel
}

function Start-UpdateCheck {
    param(
        [switch]$Force,
        [switch]$Manual
    )
    if(-not [bool](Get-ChatProp $cfg 'checkForUpdates' $true) -and -not $Force){return}
    if($script:updateProcess -and -not $script:updateProcess.HasExited){return}

    $result=Join-Path $stateCacheRoot 'update-result.json'
    Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue
    $hours=[int](Get-ChatProp $cfg 'updateCheckHours' 24)
    if($hours -lt 1){$hours=24}
    $channel=Get-UpdateChannel
    $args=@(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',(Join-Path $root 'Check-Updates.ps1'),
        '-CurrentVersion',$script:currentVersion,
        '-ResultFile',$result,
        '-CacheFile',$script:updateCacheFile,
        '-CacheHours',$hours,
        '-Channel',$channel
    )
    if($Force){$args+='-Force'}
    $script:manualUpdateCheckPending=[bool]$Manual
    $script:updateResultFile=$result
    $script:updateProcess=Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru
    $script:lastUpdateCheckStart=Get-Date
}

function Complete-UpdateCheck {
    if(-not $script:updateProcess -or -not $script:updateProcess.HasExited){return $false}

    $success=$false
    if($script:updateResultFile -and (Test-Path -LiteralPath $script:updateResultFile)){
        try{
            $result=Get-Content -LiteralPath $script:updateResultFile -Raw|ConvertFrom-Json
            if([bool](Get-ChatProp $result 'success' $false)){
                $success=$true
                $previousLatest=$script:latestVersion
                $script:updateAvailable=[bool](Get-ChatProp $result 'updateAvailable' $false)
                $script:latestVersion=[string](Get-ChatProp $result 'latestVersion' '')
                $script:latestReleaseUrl=[string](Get-ChatProp $result 'releaseUrl' '')
                $script:latestReleaseNotes=[string](Get-ChatProp $result 'releaseNotes' '')
                $script:latestPrerelease=[bool](Get-ChatProp $result 'prerelease' $false)
                $script:latestAssets=@(Get-ChatProp $result 'assets' @())
                if($previousLatest -and $previousLatest -ne $script:latestVersion){
                    $script:updateDismissed=$false
                    $script:updateNotified=$false
                }
            }
        }catch{}
    }

    $manual=$script:manualUpdateCheckPending
    $script:manualUpdateCheckPending=$false
    $script:updateProcess.Dispose()
    $script:updateProcess=$null
    if($script:updateResultFile){Remove-Item -LiteralPath $script:updateResultFile -Force -ErrorAction SilentlyContinue}
    $script:updateResultFile=$null

    if($manual -and $success -and -not $script:updateAvailable){
        try{$notify.ShowBalloonTip(2500,'MultiChat',"v$($script:currentVersion) is up to date.",'Info')}catch{}
    }
    return $true
}

function Update-UpdateUi {
    if(-not [bool](Get-ChatProp $cfg 'checkForUpdates' $true)){
        $versionLabel.Text="v$($script:currentVersion)"
        $versionLabel.ForeColor=$script:UiColors.Muted
        $updateButton.Visible=$false
        $notesButton.Visible=$false
        $laterButton.Visible=$false
        return
    }

    if($script:updateAvailable -and -not $script:updateDismissed){
        $versionLabel.Text="v$($script:currentVersion)  -  v$($script:latestVersion) available"
        $versionLabel.ForeColor=$script:UiColors.Warn
        $updateButton.Text='Install update'
        $updateButton.Visible=$true
        $notesButton.Visible=$true
        $laterButton.Visible=$true

        if(-not $script:updateNotified){
            $script:updateNotified=$true
            try{$notify.ShowBalloonTip(3500,'MultiChat update available',"Version $($script:latestVersion) is ready to install.",'Info')}catch{}
        }
    }else{
        $versionLabel.Text="v$($script:currentVersion)"
        $versionLabel.ForeColor=$script:UiColors.Muted
        $updateButton.Visible=$false
        $notesButton.Visible=$false
        $laterButton.Visible=$false
    }
}

function Start-SelfUpdate {
    if(-not $script:updateAvailable -or -not $script:latestVersion){return}

    if(Test-Path -LiteralPath (Join-Path $root '.git')){
        Show-MultiChatInfo -Owner $form -Title 'Git checkout detected' -Message 'Automatic in-place updates are disabled for Git checkouts. The release page will be opened instead.'
        if($script:latestReleaseUrl){Start-Process -FilePath $script:latestReleaseUrl}
        return
    }

    $zip="ChatGPT-MultiChat-$($script:latestVersion)-portable.zip"
    $required=@($zip,"$zip.sha256","$zip.sig")
    $missing=@($required|Where-Object{$_ -notin $script:latestAssets})
    if($missing.Count){
        Show-MultiChatInfo -Owner $form -Title 'Signed update unavailable' -Message 'This release does not contain the complete signed update package. The release page will be opened instead.'
        if($script:latestReleaseUrl){Start-Process -FilePath $script:latestReleaseUrl}
        return
    }

    $ok=Show-MultiChatConfirm -Owner $form -Title 'Install MultiChat update?' -Message ("Install v{0} now? MultiChat will restart automatically after signature verification." -f $script:latestVersion)
    if(-not $ok){return}

    $args=@(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',(Join-Path $root 'Update-MultiChat.ps1'),
        '-TargetVersion',$script:latestVersion,
        '-InstallRoot',$root,
        '-Repository','JoelMomo/ChatGPT-MultiChat',
        '-ReleaseUrl',$script:latestReleaseUrl,
        '-ParentPid',[string]$PID
    )
    Start-Process powershell.exe -WorkingDirectory $env:TEMP -ArgumentList $args -WindowStyle Hidden|Out-Null

    $script:exiting=$true
    Stop-RemoteCommander
    if($script:maintenanceProcess -and -not $script:maintenanceProcess.HasExited){$script:maintenanceProcess.Kill()}
    if($script:cleanupScanProcess -and -not $script:cleanupScanProcess.HasExited){$script:cleanupScanProcess.Kill()}
    if($script:cleanupProcess -and -not $script:cleanupProcess.HasExited){$script:cleanupProcess.Kill()}
    if($script:updateProcess -and -not $script:updateProcess.HasExited){$script:updateProcess.Kill()}
    $notify.Visible=$false
    $form.Close()
    [Windows.Forms.Application]::Exit()
}

function Start-MaintenanceWorker {
    if($script:maintenanceProcess -and -not $script:maintenanceProcess.HasExited){return}

    $result=Join-Path $stateCacheRoot 'maintenance.json'
    Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue
    $args=@(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',(Join-Path $root 'MultiChat-Maintenance.ps1'),
        '-ResultFile',$result
    )
    $script:maintenanceResultFile=$result
    $script:maintenanceProcess=Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru
    $script:lastMaintenanceStart=Get-Date
}

function Complete-MaintenanceWorker {
    if(-not $script:maintenanceProcess -or -not $script:maintenanceProcess.HasExited){return $false}

    if($script:maintenanceResultFile -and (Test-Path -LiteralPath $script:maintenanceResultFile)){
        try{
            $result=Get-Content -LiteralPath $script:maintenanceResultFile -Raw|ConvertFrom-Json
            $nextGit=@{}
            foreach($item in $result.git){
                $id=[string](Get-ChatProp $item 'id' '')
                if($id){$nextGit[$id]=$item}
            }
            $script:gitCache=$nextGit
            if($script:dcDesiredOnline){
                $script:dcOnline=[bool]$result.desktopCommanderOnline
                $script:dcChecked=$true
                $script:dcConnecting=(-not $script:dcOnline -and ((Get-Date)-$script:lastRemoteRestart).TotalSeconds -lt 12)
            }else{
                $script:dcOnline=$false
                $script:dcChecked=$true
                $script:dcConnecting=$false
            }
        }catch{}
    }

    $script:maintenanceProcess.Dispose()
    $script:maintenanceProcess=$null
    if($script:maintenanceResultFile){
        Remove-Item -LiteralPath $script:maintenanceResultFile -Force -ErrorAction SilentlyContinue
    }
    $script:maintenanceResultFile=$null
    return $true
}

function Start-WorktreeScan {
    if($script:cleanupScanProcess -and -not $script:cleanupScanProcess.HasExited){return}
    $result=Join-Path $stateCacheRoot 'worktree-scan.json'
    Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue
    $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'Cleanup-Worktrees.ps1'),'-ResultFile',$result,'-Quiet')
    if([bool](Get-ChatProp $cfg 'autoCleanSafeWorktrees' $true)){$args+='-AutoCleanSafe'}
    $script:cleanupScanResultFile=$result
    $script:cleanupScanProcess=Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru
    $script:lastCleanupScanStart=Get-Date
}

function Complete-WorktreeScan {
    if(-not $script:cleanupScanProcess -or -not $script:cleanupScanProcess.HasExited){return $false}
    if($script:cleanupScanResultFile -and (Test-Path -LiteralPath $script:cleanupScanResultFile)){
        try{
            $result=Get-Content -LiteralPath $script:cleanupScanResultFile -Raw|ConvertFrom-Json
            $script:cleanupCandidates=@()
            foreach($candidate in $result.items){$script:cleanupCandidates+=$candidate}
            $script:cachedSafe=[int]$result.safeCount
            $script:cachedPending=[int]$result.pendingCount
        }catch{}
    }
    $script:cleanupScanProcess.Dispose()
    $script:cleanupScanProcess=$null
    if($script:cleanupScanResultFile){Remove-Item -LiteralPath $script:cleanupScanResultFile -Force -ErrorAction SilentlyContinue}
    $script:cleanupScanResultFile=$null
    return $true
}

function Start-WorktreeCleanup {
    if($script:cleanupProcess -and -not $script:cleanupProcess.HasExited){return}
    $safe=@($script:cleanupCandidates|Where-Object{[bool](Get-ChatProp $_ 'safe' $false)})
    if(-not $safe.Count){
        Show-MultiChatInfo -Owner $form -Message 'There are no safe worktrees to clean.'
        return
    }
    $msg="$($safe.Count) clean worktrees with no pending commits will be removed."
    if(-not (Show-MultiChatConfirm -Owner $form -Message $msg)){return}

    $candidateFile=Join-Path $stateCacheRoot 'cleanup-input.json'
    $resultFile=Join-Path $stateCacheRoot 'cleanup-result.json'
    [IO.File]::WriteAllText($candidateFile,($safe|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
    Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue

    $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'Cleanup-Worktrees.ps1'),'-Apply','-CandidatesFile',$candidateFile,'-ResultFile',$resultFile,'-Quiet')
    $script:cleanupApplyResultFile=$resultFile
    $script:cleanupProcess=Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru

    # The displayed count is now stale by definition. Hide it until the post-cleanup scan finishes.
    $script:cleanupCandidates=@()
    $script:cachedSafe=0
    $cleanupButton.Enabled=$false
    $cleanupButton.Text='Cleaning...'
    $cleanupHint.Text='Validating and removing safe worktrees in the background.'
}

function Complete-WorktreeCleanup {
    if(-not $script:cleanupProcess -or -not $script:cleanupProcess.HasExited){return $false}
    $removed=0
    $failed=0
    if($script:cleanupApplyResultFile -and (Test-Path -LiteralPath $script:cleanupApplyResultFile)){
        try{
            $cleanupResult=Get-Content -LiteralPath $script:cleanupApplyResultFile -Raw|ConvertFrom-Json
            $removed=[int](Get-ChatProp $cleanupResult 'removedCount' 0)
            $failed=[int](Get-ChatProp $cleanupResult 'failedCount' 0)
        }catch{}
    }
    $script:cleanupProcess.Dispose()
    $script:cleanupProcess=$null
    if($script:cleanupApplyResultFile){Remove-Item -LiteralPath $script:cleanupApplyResultFile -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath (Join-Path $stateCacheRoot 'cleanup-input.json') -Force -ErrorAction SilentlyContinue
    $script:cleanupApplyResultFile=$null
    $script:cachedSafe=0
    $script:cleanupCandidates=@()
    $cleanupButton.Enabled=$true
    $cleanupButton.Text='Clean safe worktrees'
    $cleanupHint.Text=if($failed -gt 0){
        "$removed removed; $failed could not be removed. Rescanning..."
    }elseif($removed -eq 1){
        '1 worktree removed. Rescanning...'
    }else{
        "$removed worktrees removed. Rescanning..."
    }
    $script:lastCleanupScanStart=[datetime]::MinValue
    Start-WorktreeScan
    return $true
}

function Close-DashboardSession {
    param([Parameter(Mandatory)][string]$SessionId)

    $session=Get-ManagedChatSession -Id $SessionId
    if(-not $session -or -not [bool](Get-ChatProp $session 'active' $false)){
        Show-MultiChatInfo -Owner $form -Title 'Session already closed' -Message 'That managed chat session is no longer active.'
        Refresh-Dashboard
        return
    }

    if(Get-Command Test-SessionProtectedByLease -ErrorAction SilentlyContinue){
        if(Test-SessionProtectedByLease $session){
            Show-MultiChatInfo -Owner $form -Title 'Session is protected' -Message 'This chat has an active or protective lease. Close the external work first, then close the session.'
            return
        }
    }

    $slot=[int](Get-ChatProp $session 'slot' 0)
    $project=[string](Get-ChatProp $session 'project' '')
    $task=[string](Get-ChatProp $session 'task' '')
    $message=("Close CHAT-{0} ({1})?`r`n`r`nTask: {2}`r`n`r`nThe managed shell will be terminated and its slot released. Its Git worktree and uncommitted files will be kept." -f $slot,$project,$task)
    if(-not(Show-MultiChatConfirm -Owner $form -Title 'Close managed chat session?' -Message $message)){return}

    $result=Close-ManagedChatSession -Id $SessionId -TerminateProcess -Reason 'DASHBOARD_CLOSE'
    if(-not [bool]$result.Success){
        $detail=switch([string]$result.Reason){
            'LEASE_PROTECTED'{'The session is protected by an active lease.'}
            'PID_MISMATCH'{'The recorded process no longer matches a managed MultiChat shell, so it was not terminated.'}
            'PROCESS_STOP_FAILED'{'Windows did not allow the managed shell to be terminated.'}
            'SELF_PROCESS'{'MultiChat refused to terminate its own dashboard process.'}
            default{("MultiChat could not close the session ({0})." -f [string]$result.Reason)}
        }
        Show-MultiChatInfo -Owner $form -Title 'Could not close session' -Message $detail
        return
    }

    Refresh-Dashboard
}

function Update-SessionRows {
    param([array]$Sessions)

    $conflicts=@(Get-ProjectConflictGroups -Sessions $Sessions)
    $conflictRepos=@{}
    foreach($group in $conflicts){$conflictRepos[$group.originRepo]=$group.count}

    $structureChanged=$false
    while($grid.Rows.Count -lt $Sessions.Count){
        [void]$grid.Rows.Add()
        $structureChanged=$true
    }
    while($grid.Rows.Count -gt $Sessions.Count){
        $grid.Rows.RemoveAt($grid.Rows.Count-1)
        $structureChanged=$true
    }

    $working=0
    for($i=0;$i -lt $Sessions.Count;$i++){
        $s=$Sessions[$i]
        $idle=Get-SessionIdleInfo -Session $s -SkipGit
        if([string]$s.status -eq 'READY'){
            $activity=if($idle.abandoned){'ABANDONED'}else{'FREE'}
            $detail=''
        }else{
            $activity='WORKING'
            $detail=[string]$s.status
            $working++
        }

        $git=Get-GitSnapshot $s
        $gitView=Format-GitSummary $git
        $gitText=$gitView.Text
        $port=Get-ChatProp $s 'devPort' ''
        $warning=''
        $originRepo=[string](Get-ChatProp $s 'originRepo' '')
        if($originRepo -and $conflictRepos.ContainsKey($originRepo)){
            $warning="SAME PROJECT x$($conflictRepos[$originRepo])"
        }

        $row=$grid.Rows[$i]
        $row.Cells['Chat'].Tag=[string]$s.id
        Set-GridCellValue $row 'Chat' "CHAT-$($s.slot)"
        Set-GridCellValue $row 'Project' $s.project
        Set-GridCellValue $row 'Activity' $activity
        Set-GridCellValue $row 'Detail' $detail
        Set-GridCellValue $row 'Time' (Format-SessionAge $s)
        Set-GridCellValue $row 'Git' $gitText
        Set-GridCellValue $row 'Port' $port
        Set-GridCellValue $row 'Task' $s.task
        Set-GridCellValue $row 'Warning' $warning

        $gitCell=$row.Cells['Git']
        if($gitCell.ToolTipText -ne $gitView.ToolTip){$gitCell.ToolTipText=$gitView.ToolTip}
        $gitColor=switch($gitView.Tone){
            'Good'{$script:UiColors.Good}
            'Warn'{$script:UiColors.Warn}
            default{$script:UiColors.Muted}
        }
        if($gitCell.Style.ForeColor -ne $gitColor){$gitCell.Style.ForeColor=$gitColor}

        $presentationKey="$($s.slot)|$activity|$warning"
        if([string]$row.Tag -ne $presentationKey){
            $slotColor=Get-SlotColor([int]$s.slot)
            $chatCell=$row.Cells['Chat']
            $darkText=[Drawing.Color]::FromArgb(15,17,21)
            $chatCell.Style.BackColor=$slotColor
            $chatCell.Style.ForeColor=$darkText
            $chatCell.Style.SelectionBackColor=$slotColor
            $chatCell.Style.SelectionForeColor=$darkText

            $row.Cells['Activity'].Style.ForeColor=switch($activity){
                'WORKING'{$script:UiColors.Warn}
                'ABANDONED'{$script:UiColors.Bad}
                default{$script:UiColors.Good}
            }
            $row.Cells['Warning'].Style.ForeColor=if($warning){$script:UiColors.Warn}else{$script:UiColors.Muted}
            $row.Tag=$presentationKey
        }
    }

    if($structureChanged){
        $grid.ClearSelection()
        $grid.CurrentCell=$null
    }
    return $working
}

function Update-History {
    $now=Get-Date
    $interval=[int](Get-ChatProp $cfg 'historyRefreshSeconds' 5)
    if(($now-$script:lastHistoryCheck).TotalSeconds -lt $interval){return}
    $history=@(Get-ChatHistory -Limit 12|Select-Object -Last 12)
    $lines=@()
    foreach($h in $history){
        try{$ended=(Get-Date $h.endedAt -Format 'HH:mm:ss')}catch{$ended='--:--:--'}
        $lines+=("{0}   CHAT-{1}   {2,-18}   {3,-14}   {4}s   {5}" -f $ended,$h.slot,$h.project,$h.reason,$h.durationSeconds,$h.task)
    }
    $text=$lines -join [Environment]::NewLine
    if($text -ne $script:lastHistoryText){$historyBox.Text=$text;$script:lastHistoryText=$text}
    $script:lastHistoryCheck=$now
}

function Refresh-Dashboard {
    $now=Get-Date

    [void](Complete-UpdateCheck)
    $updateHours=[int](Get-ChatProp $cfg 'updateCheckHours' 24)
    if($updateHours -lt 1){$updateHours=24}
    if([bool](Get-ChatProp $cfg 'checkForUpdates' $true) -and -not $script:updateProcess -and (($now-$script:lastUpdateCheckStart).TotalHours -ge $updateHours)){
        Start-UpdateCheck
    }

    [void](Complete-MaintenanceWorker)
    $maintenanceInterval=[int](Get-ChatProp $cfg 'maintenanceRefreshSeconds' 15)
    if(-not $script:maintenanceProcess -and (($now-$script:lastMaintenanceStart).TotalSeconds -ge $maintenanceInterval)){
        Start-MaintenanceWorker
    }

    $sessions=@(Get-ManagedChatSessions -ActiveOnly -SkipLivenessCheck|Sort-Object slot)
    Apply-RemoteExposurePolicy -Sessions $sessions
    if($script:dcDesiredOnline -and $script:dcChecked -and -not $script:dcOnline -and (($now-$script:lastRemoteRestart).TotalSeconds -ge 10)){
        [void](Start-RemoteCommanderHidden)
    }

    [void](Complete-WorktreeScan)
    [void](Complete-WorktreeCleanup)
    $cleanupInterval=[int](Get-ChatProp $cfg 'cleanupScanSeconds' 30)
    if(-not $script:cleanupScanProcess -and -not $script:cleanupProcess -and (($now-$script:lastCleanupScanStart).TotalSeconds -ge $cleanupInterval)){
        Start-WorktreeScan
    }

    $working=Update-SessionRows -Sessions $sessions
    if(-not $script:dcDesiredOnline){
        $dc='OFFLINE'
        $dcTone='Bad'
        $dcColor=$script:UiColors.Bad
    }elseif($script:dcOnline){
        $dc='ONLINE'
        $dcTone='Good'
        $dcColor=$script:UiColors.Good
    }elseif(-not $script:dcChecked -or $script:dcConnecting){
        $dc='CONNECTING'
        $dcTone='Warn'
        $dcColor=$script:UiColors.Warn
    }else{
        $dc='OFFLINE'
        $dcTone='Bad'
        $dcColor=$script:UiColors.Bad
    }

    Set-MetricCard $dcCard $dc $dcTone
    Set-MetricCard $chatCard "$($sessions.Count)/$(Get-ChatCapacity)" 'Neutral'
    Set-MetricCard $workCard "$working" $(if($working){'Warn'}else{'Good'})
    Set-MetricCard $treeCard "$($script:cachedSafe) safe / $($script:cachedPending) pending" $(if($script:cachedPending){'Warn'}else{'Good'})

    if(-not $script:cleanupProcess){
        $cleanupButton.Text=if($script:cachedSafe -gt 0){"Clean safe worktrees ($($script:cachedSafe))"}else{'Clean safe worktrees'}
        $cleanupHint.Text=if($script:cleanupScanProcess -and -not $script:cleanupScanProcess.HasExited){
            'Scanning worktrees in the background...'
        }elseif($script:cachedSafe -gt 0){
            "$($script:cachedSafe) safe worktree(s) can be removed."
        }elseif($script:cachedPending -gt 0){
            'No safe cleanup available; pending worktrees need attention.'
        }else{
            'No finished worktrees waiting for cleanup.'
        }
    }

    $connectionLabel.Text="Desktop Commander  $dc"
    $connectionLabel.ForeColor=$dcColor
    Set-StatusLed -Led $connectionLed -Color $dcColor

    if((Get-ToggleSwitchChecked -Toggle $connectionToggle) -ne $script:dcDesiredOnline){
        $script:suppressConnectionToggle=$true
        Set-ToggleSwitchChecked -Toggle $connectionToggle -Checked $script:dcDesiredOnline
        $script:suppressConnectionToggle=$false
    }

    $notify.Text=("MultiChat: {0} chats | {1} working" -f $sessions.Count,$working)
    Update-UpdateUi
    Update-CapacityUi
    Update-History
}

$form=New-Object Windows.Forms.Form
$form.Text='ChatGPT MultiChat'
$form.FormBorderStyle='None'
$form.Size=New-Object Drawing.Size(1120,700)
$form.MinimumSize=New-Object Drawing.Size(900,560)
$form.StartPosition='CenterScreen'
$form.BackColor=$script:UiColors.Bg
$form.ForeColor=$script:UiColors.Text
$form.Font=New-Object Drawing.Font('Segoe UI',9)
$form.Padding=New-Object Windows.Forms.Padding(18)
Enable-ControlDoubleBuffer $form

$header=New-Object Windows.Forms.Panel
$header.Dock='Top'
$header.Height=72
$header.BackColor=$script:UiColors.Bg
$form.Controls.Add($header)

$title=New-Object Windows.Forms.Label
$title.Text='ChatGPT MultiChat'
$title.Font=New-Object Drawing.Font('Segoe UI Semibold',20)
$title.ForeColor=$script:UiColors.Text
$title.AutoSize=$true
$title.Location=New-Object Drawing.Point(0,0)
$header.Controls.Add($title)

$subtitle=New-Object Windows.Forms.Label
$subtitle.Text='Parallel Desktop Commander sessions, without collisions.'
$subtitle.Font=New-Object Drawing.Font('Segoe UI',9)
$subtitle.ForeColor=$script:UiColors.Muted
$subtitle.AutoSize=$true
$subtitle.Location=New-Object Drawing.Point(2,39)
$header.Controls.Add($subtitle)

$rightHeader=New-Object Windows.Forms.Panel
$rightHeader.Dock='Right'
$rightHeader.Width=508
$rightHeader.Height=38
$rightHeader.BackColor=$script:UiColors.Bg
$header.Controls.Add($rightHeader)

$connectionPanel=New-Object Windows.Forms.Panel
$connectionPanel.Location=New-Object Drawing.Point(0,0)
$connectionPanel.Size=New-Object Drawing.Size(270,36)
$connectionPanel.BackColor=$script:UiColors.Bg
$rightHeader.Controls.Add($connectionPanel)

$connectionLed=New-StatusLed -Size 10
$connectionLed.Location=New-Object Drawing.Point(0,12)
$connectionPanel.Controls.Add($connectionLed)

$connectionLabel=New-Object Windows.Forms.Label
$connectionLabel.AutoSize=$true
$connectionLabel.Font=New-Object Drawing.Font('Segoe UI Semibold',9)
$connectionLabel.Location=New-Object Drawing.Point(18,8)
$connectionPanel.Controls.Add($connectionLabel)

$connectionToggle=New-ToggleSwitch -Checked $script:dcDesiredOnline
$connectionToggle.Location=New-Object Drawing.Point(220,7)
$connectionPanel.Controls.Add($connectionToggle)

$connectionToolTip=New-Object Windows.Forms.ToolTip
$connectionToolTip.SetToolTip($connectionToggle,'Remote access starts Off. Turn it On locally when needed; it also disconnects on Windows lock and after 30 minutes without managed chats.')

$capacityPanel=New-Object Windows.Forms.Panel
$capacityPanel.Location=New-Object Drawing.Point(274,0)
$capacityPanel.Size=New-Object Drawing.Size(154,36)
$capacityPanel.BackColor=$script:UiColors.Bg
$rightHeader.Controls.Add($capacityPanel)

$capacityLabel=New-Object Windows.Forms.Label
$capacityLabel.Text='CHATS'
$capacityLabel.AutoSize=$true
$capacityLabel.Font=New-Object Drawing.Font('Segoe UI Semibold',7.5)
$capacityLabel.ForeColor=$script:UiColors.Muted
$capacityLabel.Location=New-Object Drawing.Point(0,11)
$capacityPanel.Controls.Add($capacityLabel)

$capacityMinusButton=New-FlatButton -Text ([char]0x2212) -Width 28
$capacityMinusButton.Height=30
$capacityMinusButton.Location=New-Object Drawing.Point(40,3)
$capacityPanel.Controls.Add($capacityMinusButton)

$capacityValueButton=New-FlatButton -Text ([string](Get-ChatCapacity)) -Width 38
$capacityValueButton.Height=30
$capacityValueButton.Font=New-Object Drawing.Font('Segoe UI Semibold',9)
$capacityValueButton.Location=New-Object Drawing.Point(72,3)
$capacityPanel.Controls.Add($capacityValueButton)

$capacityPlusButton=New-FlatButton -Text '+' -Width 28
$capacityPlusButton.Height=30
$capacityPlusButton.Location=New-Object Drawing.Point(114,3)
$capacityPanel.Controls.Add($capacityPlusButton)

$capacityToolTip=New-Object Windows.Forms.ToolTip
$capacityToolTip.SetToolTip($capacityMinusButton,'Reduce managed chat capacity')
$capacityToolTip.SetToolTip($capacityPlusButton,'Increase managed chat capacity')

$capacityMenu=New-Object Windows.Forms.ContextMenuStrip
foreach($preset in @(4,6,8,10,12,16,20,24,32)){
    $item=$capacityMenu.Items.Add([string]$preset)
    $item.Tag=$preset
    $item.Add_Click({
        param($sender,$eventArgs)
        [void](Set-ChatCapacity -Value ([int]$sender.Tag))
    })
}

$windowControls=New-Object Windows.Forms.Panel
$windowControls.Location=New-Object Drawing.Point(432,0)
$windowControls.Size=New-Object Drawing.Size(76,36)
$windowControls.BackColor=$script:UiColors.Bg
$rightHeader.Controls.Add($windowControls)

$minimizeButton=New-WindowButton -Text ([char]0x2212)
$minimizeButton.Location=New-Object Drawing.Point(4,0)
$minimizeButton.Add_Click({$form.WindowState='Minimized'})
$windowControls.Controls.Add($minimizeButton)

$closeButton=New-WindowButton -Text ([char]0x00D7) -CloseButton
$closeButton.Location=New-Object Drawing.Point(40,0)
$closeButton.Add_Click({$form.Close()})
$windowControls.Controls.Add($closeButton)

$connectionToggle.Add_Click({
    if($script:suppressConnectionToggle){return}
    $next=-not (Get-ToggleSwitchChecked -Toggle $connectionToggle)
    Set-ToggleSwitchChecked -Toggle $connectionToggle -Checked $next
    Set-DesktopCommanderEnabled -Enabled $next
    Refresh-Dashboard
})

$capacityMinusButton.Add_Click({
    [void](Set-ChatCapacity -Value ((Get-ChatCapacity)-1))
})
$capacityPlusButton.Add_Click({
    [void](Set-ChatCapacity -Value ((Get-ChatCapacity)+1))
})
$capacityValueButton.Add_Click({
    $capacityMenu.Show(
        $capacityValueButton,
        (New-Object Drawing.Point(0,$capacityValueButton.Height))
    )
})
Update-CapacityUi

Enable-WindowDrag -Control $header -Form $form
Enable-WindowDrag -Control $title -Form $form
Enable-WindowDrag -Control $subtitle -Form $form
Enable-WindowDrag -Control $connectionLabel -Form $form

$toggleMaximize={
    if($form.WindowState -eq 'Maximized'){$form.WindowState='Normal'}else{$form.WindowState='Maximized'}
}
$header.Add_DoubleClick($toggleMaximize)
$title.Add_DoubleClick($toggleMaximize)
$subtitle.Add_DoubleClick($toggleMaximize)

$metrics=New-Object Windows.Forms.FlowLayoutPanel
$metrics.Dock='Top'
$metrics.Height=70
$metrics.WrapContents=$false
$metrics.FlowDirection='LeftToRight'
$metrics.BackColor=$script:UiColors.Bg
$metrics.Padding=New-Object Windows.Forms.Padding(0,4,0,8)
$form.Controls.Add($metrics)
$metrics.BringToFront()

$dcCard=New-MetricCard -Title 'DESKTOP COMMANDER' -Width 200
$chatCard=New-MetricCard -Title 'ACTIVE CHATS' -Width 165
$workCard=New-MetricCard -Title 'WORKING NOW' -Width 155
$treeCard=New-MetricCard -Title 'WORKTREES' -Width 260
$metrics.Controls.AddRange(@($dcCard,$chatCard,$workCard,$treeCard))

$actionPanel=New-Object Windows.Forms.Panel
$actionPanel.Dock='Bottom'
$actionPanel.Height=68
$actionPanel.BackColor=$script:UiColors.Surface
$actionPanel.Padding=New-Object Windows.Forms.Padding(12,8,12,8)
$form.Controls.Add($actionPanel)

$actionButtons=New-Object Windows.Forms.Panel
$actionButtons.Dock='Right'
$actionButtons.Width=540
$actionButtons.BackColor=$script:UiColors.Surface
$actionPanel.Controls.Add($actionButtons)

$notesButton=New-FlatButton -Text "What's new" -Width 100
$notesButton.Location=New-Object Drawing.Point(0,8)
$notesButton.Visible=$false
$actionButtons.Controls.Add($notesButton)

$updateButton=New-FlatButton -Text 'Install update' -Width 130
$updateButton.Location=New-Object Drawing.Point(108,8)
$updateButton.Visible=$false
$actionButtons.Controls.Add($updateButton)

$laterButton=New-FlatButton -Text 'Later' -Width 70
$laterButton.Location=New-Object Drawing.Point(246,8)
$laterButton.Visible=$false
$actionButtons.Controls.Add($laterButton)

$cleanupButton=New-FlatButton -Text 'Clean safe worktrees' -Width 205 -Accent
$cleanupButton.Location=New-Object Drawing.Point(324,8)
$actionButtons.Controls.Add($cleanupButton)

$cleanupHint=New-Object Windows.Forms.Label
$cleanupHint.Text='Worktree checks run in the background.'
$cleanupHint.AutoSize=$true
$cleanupHint.ForeColor=$script:UiColors.Muted
$cleanupHint.Font=New-Object Drawing.Font('Segoe UI',9)
$cleanupHint.Location=New-Object Drawing.Point(12,9)
$actionPanel.Controls.Add($cleanupHint)

$versionLabel=New-Object Windows.Forms.Label
$versionLabel.Text="v$($script:currentVersion)"
$versionLabel.AutoSize=$true
$versionLabel.ForeColor=$script:UiColors.Muted
$versionLabel.Font=New-Object Drawing.Font('Segoe UI',8.5)
$versionLabel.Location=New-Object Drawing.Point(12,39)
$actionPanel.Controls.Add($versionLabel)

$channelCombo=New-Object Windows.Forms.ComboBox
$channelCombo.DropDownStyle='DropDownList'
$channelCombo.FlatStyle='Flat'
$channelCombo.BackColor=$script:UiColors.Surface2
$channelCombo.ForeColor=$script:UiColors.Text
$channelCombo.Font=New-Object Drawing.Font('Segoe UI',8.5)
$channelCombo.Size=New-Object Drawing.Size(82,24)
$channelCombo.Location=New-Object Drawing.Point(74,32)
[void]$channelCombo.Items.Add('Stable')
[void]$channelCombo.Items.Add('Beta')
$script:suppressChannelChange=$true
$channelCombo.SelectedItem=if((Get-UpdateChannel) -eq 'beta'){'Beta'}else{'Stable'}
$script:suppressChannelChange=$false
$actionPanel.Controls.Add($channelCombo)

$checkNowButton=New-FlatButton -Text 'Check now' -Width 92
$checkNowButton.Location=New-Object Drawing.Point(165,28)
$actionPanel.Controls.Add($checkNowButton)

$split=New-Object Windows.Forms.SplitContainer
$split.Dock='Fill'
$split.Orientation='Horizontal'
$split.SplitterDistance=360
$split.SplitterWidth=8
$split.BackColor=$script:UiColors.Bg
$split.Panel1.BackColor=$script:UiColors.Surface
$split.Panel2.BackColor=$script:UiColors.Surface
$form.Controls.Add($split)
$split.BringToFront()

$grid=New-Object Windows.Forms.DataGridView
$grid.Dock='Fill'
$grid.ReadOnly=$true
$grid.AllowUserToAddRows=$false
$grid.AllowUserToDeleteRows=$false
$grid.AllowUserToResizeRows=$false
$grid.RowHeadersVisible=$false
$grid.AutoSizeColumnsMode='Fill'
$grid.BackgroundColor=$script:UiColors.Surface
$grid.BorderStyle='None'
$grid.CellBorderStyle='SingleHorizontal'
$grid.GridColor=$script:UiColors.Border
$grid.EnableHeadersVisualStyles=$false
$grid.ColumnHeadersHeight=36
$grid.ColumnHeadersHeightSizeMode='DisableResizing'
$grid.ColumnHeadersDefaultCellStyle.BackColor=$script:UiColors.Surface2
$grid.ColumnHeadersDefaultCellStyle.ForeColor=$script:UiColors.Muted
$grid.ColumnHeadersDefaultCellStyle.Font=New-Object Drawing.Font('Segoe UI Semibold',8.5)
$grid.DefaultCellStyle.BackColor=$script:UiColors.Surface
$grid.DefaultCellStyle.ForeColor=$script:UiColors.Text
$grid.DefaultCellStyle.SelectionBackColor=$script:UiColors.Surface3
$grid.DefaultCellStyle.SelectionForeColor=$script:UiColors.Text
$grid.DefaultCellStyle.Padding=New-Object Windows.Forms.Padding(5,2,5,2)
$grid.DefaultCellStyle.Font=New-Object Drawing.Font('Segoe UI',8.5)
$grid.RowTemplate.Height=34
$grid.SelectionMode='FullRowSelect'
$grid.MultiSelect=$false
$grid.TabStop=$false
Enable-ControlDoubleBuffer $grid
$split.Panel1.Controls.Add($grid)

foreach($col in @(
    @('Chat','CHAT',58),@('Project','PROJECT',130),@('Activity','STATUS',90),
    @('Detail','DETAIL',75),@('Time','AGE',60),@('Git','GIT',135),
    @('Port','PORT',52),@('Task','TASK',180),@('Warning','WARNING',130)
)){
    $column=New-Object Windows.Forms.DataGridViewTextBoxColumn
    $column.Name=$col[0]
    $column.HeaderText=$col[1]
    $column.FillWeight=[int]$col[2]
    [void]$grid.Columns.Add($column)
}

$chatRowMenu=New-Object Windows.Forms.ContextMenuStrip
$closeChatMenuItem=$chatRowMenu.Items.Add('Close session')
$script:contextSessionId=''
$grid.Add_CellMouseDown({
    param($sender,$eventArgs)
    if($eventArgs.Button -ne [Windows.Forms.MouseButtons]::Right -or $eventArgs.RowIndex -lt 0){return}

    $row=$sender.Rows[$eventArgs.RowIndex]
    $sessionId=[string]$row.Cells['Chat'].Tag
    if(-not $sessionId){return}

    $sender.ClearSelection()
    $row.Selected=$true
    $sender.CurrentCell=$row.Cells['Chat']
    $script:contextSessionId=$sessionId
    $closeChatMenuItem.Text=("Close {0} session" -f [string]$row.Cells['Chat'].Value)
    $point=$sender.PointToClient([Windows.Forms.Cursor]::Position)
    $chatRowMenu.Show($sender,$point)
})
$closeChatMenuItem.Add_Click({
    $sessionId=[string]$script:contextSessionId
    if($sessionId){Close-DashboardSession -SessionId $sessionId}
})

$historyHeader=New-Object Windows.Forms.Panel
$historyHeader.Dock='Top'
$historyHeader.Height=38
$historyHeader.BackColor=$script:UiColors.Surface2
$split.Panel2.Controls.Add($historyHeader)

$historyTitle=New-Object Windows.Forms.Label
$historyTitle.Text='Recent activity'
$historyTitle.AutoSize=$true
$historyTitle.Font=New-Object Drawing.Font('Segoe UI Semibold',9.5)
$historyTitle.ForeColor=$script:UiColors.Text
$historyTitle.Location=New-Object Drawing.Point(12,10)
$historyHeader.Controls.Add($historyTitle)

$historyBox=New-Object Windows.Forms.TextBox
$historyBox.Dock='Fill'
$historyBox.Multiline=$true
$historyBox.ReadOnly=$true
$historyBox.ScrollBars='Vertical'
$historyBox.BackColor=$script:UiColors.Surface
$historyBox.ForeColor=$script:UiColors.Muted
$historyBox.BorderStyle='None'
$historyBox.Font=New-Object Drawing.Font('Consolas',8.5)
$split.Panel2.Controls.Add($historyBox)
$historyBox.BringToFront()

# Dedicated edge/corner controls make borderless resizing reliable even when child controls fill the window.
Add-WindowResizeGrips -Form $form -Grip 6

$notify=New-Object Windows.Forms.NotifyIcon
$notify.Icon=[Drawing.SystemIcons]::Application
$notify.Text='ChatGPT MultiChat'
$notify.Visible=$true

$showDashboard={
    $form.Show()
    if($form.WindowState -eq 'Minimized'){$form.WindowState='Normal'}
    $form.BringToFront()
    [void]$form.Activate()
}

$menu=New-Object Windows.Forms.ContextMenuStrip
$miOpen=$menu.Items.Add('Open dashboard')
$miHide=$menu.Items.Add('Hide dashboard')
[void]$menu.Items.Add('-')
$miClean=$menu.Items.Add('Clean safe worktrees')
$miCheckUpdate=$menu.Items.Add('Check for updates now')
$miRestart=$menu.Items.Add('Restart Desktop Commander')
$miEmergency=$menu.Items.Add('Emergency disconnect Desktop Commander')
$miFolder=$menu.Items.Add('Open MultiChat folder')
[void]$menu.Items.Add('-')
$miExit=$menu.Items.Add('Exit')
$notify.ContextMenuStrip=$menu

$previousUpdateResult=Join-Path $stateCacheRoot 'update-last-result.json'
if(Test-Path -LiteralPath $previousUpdateResult){
    try{
        $updateResult=Get-Content -LiteralPath $previousUpdateResult -Raw|ConvertFrom-Json
        if([bool](Get-ChatProp $updateResult 'success' $false)){
            $notify.ShowBalloonTip(3000,'MultiChat updated',[string](Get-ChatProp $updateResult 'message' 'Update completed.'),'Info')
        }else{
            $notify.ShowBalloonTip(4500,'MultiChat update failed',[string](Get-ChatProp $updateResult 'message' 'The previous update could not be completed.'),'Warning')
        }
    }catch{}
    Remove-Item -LiteralPath $previousUpdateResult -Force -ErrorAction SilentlyContinue
}

$miOpen.Add_Click({& $showDashboard})
$miHide.Add_Click({$form.Hide()})
$miFolder.Add_Click({Start-Process explorer.exe -ArgumentList $root})
$miRestart.Add_Click({Restart-RemoteCommander})
$miEmergency.Add_Click({
    $ok=Show-MultiChatConfirm -Owner $form -Title 'Emergency disconnect?' -Message 'This immediately stops Desktop Commander, revokes the current Remote Commander device/session when possible, and removes local authorization. Reconnecting will require authorization again.'
    if($ok){
        Invoke-DesktopCommanderEmergencyStop -ForgetRemoteSession
        try{$notify.ShowBalloonTip(3000,'Desktop Commander disconnected','Remote access is stopped and local authorization was removed.','Warning')}catch{}
    }
})
$miClean.Add_Click({Start-WorktreeCleanup})
$miCheckUpdate.Add_Click({
    $script:updateDismissed=$false
    $script:updateNotified=$false
    Start-UpdateCheck -Force -Manual
})
$cleanupButton.Add_Click({Start-WorktreeCleanup})
$updateButton.Add_Click({Start-SelfUpdate})
$notesButton.Add_Click({
    if($script:latestVersion){
        Show-MultiChatReleaseNotes -Owner $form -Version $script:latestVersion -Notes $script:latestReleaseNotes -ReleaseUrl $script:latestReleaseUrl
    }
})
$laterButton.Add_Click({
    $script:updateDismissed=$true
    Update-UpdateUi
})
$checkNowButton.Add_Click({
    $script:updateDismissed=$false
    $script:updateNotified=$false
    $versionLabel.Text='Checking for updates...'
    $versionLabel.ForeColor=$script:UiColors.Muted
    Start-UpdateCheck -Force -Manual
})
$channelCombo.Add_SelectedIndexChanged({
    if($script:suppressChannelChange){return}
    $selected=if([string]$channelCombo.SelectedItem -eq 'Beta'){'beta'}else{'stable'}
    if(Set-ConfigProperty -Name 'updateChannel' -Value $selected){
        $script:updateDismissed=$false
        $script:updateNotified=$false
        $script:latestVersion=''
        $script:updateAvailable=$false
        Remove-Item -LiteralPath $script:updateCacheFile -Force -ErrorAction SilentlyContinue
        Start-UpdateCheck -Force -Manual
    }
})
$notify.Add_DoubleClick({& $showDashboard})

$form.Add_FormClosing({
    param($sender,$e)
    if(-not $script:exiting){
        $e.Cancel=$true
        $form.Hide()
        $notify.ShowBalloonTip(1000,'MultiChat','Still running in the system tray.','Info')
    }
})

$miExit.Add_Click({
    $script:exiting=$true
    Stop-RemoteCommander
    if($script:maintenanceProcess -and -not $script:maintenanceProcess.HasExited){$script:maintenanceProcess.Kill()}
    if($script:cleanupScanProcess -and -not $script:cleanupScanProcess.HasExited){$script:cleanupScanProcess.Kill()}
    if($script:cleanupProcess -and -not $script:cleanupProcess.HasExited){$script:cleanupProcess.Kill()}
    if($script:updateProcess -and -not $script:updateProcess.HasExited){$script:updateProcess.Kill()}
    $notify.Visible=$false
    $form.Close()
    [Windows.Forms.Application]::Exit()
})

$timer=New-Object Windows.Forms.Timer
$timer.Interval=[Math]::Max(750,([int]$cfg.refreshSeconds*1000))
$timer.Add_Tick({
    if($activationEvent.WaitOne(0)){& $showDashboard}
    Refresh-Dashboard
})
$form.Add_ResizeBegin({$timer.Stop()})
$form.Add_ResizeEnd({Refresh-Dashboard;$timer.Start()})

Sync-RemoteCommanderAllowedDirectories
if(@(Get-RemoteCommanderProcess).Count -gt 0){
    $script:dcDesiredOnline=$true
    $script:dcConnecting=$true
}
Start-UpdateCheck
Start-MaintenanceWorker
Start-WorktreeScan
Refresh-Dashboard
$timer.Start()
if(-not $StartHidden){$form.Show()}
[Windows.Forms.Application]::Run()

Stop-RemoteCommander
$notify.Visible=$false
$activationEvent.Dispose()
$mutex.ReleaseMutex()
$mutex.Dispose()
