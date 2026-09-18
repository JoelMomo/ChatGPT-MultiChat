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
if(-not $createdNew){
    [Windows.Forms.MessageBox]::Show('ChatGPT MultiChat Agent is already running.','MultiChat')|Out-Null
    exit 0
}

$script:exiting=$false
$script:lastRemoteRestart=[datetime]::MinValue
$script:lastMaintenanceStart=[datetime]::MinValue
$script:lastHistoryCheck=[datetime]::MinValue
$script:lastCleanupScanStart=[datetime]::MinValue
$script:maintenanceProcess=$null
$script:maintenanceResultFile=$null
$script:dcOnline=$false
$script:dcChecked=$false
$script:gitCache=@{}
$script:cleanupCandidates=@()
$script:cachedSafe=0
$script:cachedPending=0
$script:cleanupScanProcess=$null
$script:cleanupProcess=$null
$script:cleanupScanResultFile=$null
$script:cleanupApplyResultFile=$null
$script:lastHistoryText=''

$stateCacheRoot=Join-Path $root 'state\cache'
New-Item -ItemType Directory -Path $stateCacheRoot -Force|Out-Null

function Get-RemoteCommanderProcess {
    @(Get-CimInstance Win32_Process|Where-Object{
        $_.CommandLine -match 'desktop-commander' -and $_.CommandLine -match '\bremote\b'
    })
}

function Start-RemoteCommanderHidden {
    if(-not(Get-Command npx.cmd -ErrorAction SilentlyContinue)){return $false}
    $log=Join-Path $root 'state\logs\desktop-commander.log'
    $cmd='npx.cmd @wonderwhy-er/desktop-commander@latest remote >> "'+$log+'" 2>&1'
    Start-Process cmd.exe -ArgumentList '/c',$cmd -WindowStyle Hidden|Out-Null
    $script:lastRemoteRestart=Get-Date
    $script:dcChecked=$false
    $script:lastMaintenanceStart=[datetime]::MinValue
    return $true
}

function Restart-RemoteCommander {
    foreach($proc in @(Get-RemoteCommanderProcess)){
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
    Start-RemoteCommanderHidden|Out-Null
}

function Get-GitSnapshot {
    param($Session)
    $id=[string](Get-ChatProp $Session 'id' '')
    if(-not $id){return $null}
    return $script:gitCache[$id]
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
            $script:dcOnline=[bool]$result.desktopCommanderOnline
            $script:dcChecked=$true
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

    [void](Complete-MaintenanceWorker)
    $maintenanceInterval=[int](Get-ChatProp $cfg 'maintenanceRefreshSeconds' 15)
    if(-not $script:maintenanceProcess -and (($now-$script:lastMaintenanceStart).TotalSeconds -ge $maintenanceInterval)){
        Start-MaintenanceWorker
    }

    $sessions=@(Get-ManagedChatSessions -ActiveOnly -SkipLivenessCheck|Sort-Object slot)
    if($script:dcChecked -and -not $script:dcOnline -and (($now-$script:lastRemoteRestart).TotalSeconds -ge 10)){
        Start-RemoteCommanderHidden|Out-Null
    }

    [void](Complete-WorktreeScan)
    [void](Complete-WorktreeCleanup)
    $cleanupInterval=[int](Get-ChatProp $cfg 'cleanupScanSeconds' 30)
    if(-not $script:cleanupScanProcess -and -not $script:cleanupProcess -and (($now-$script:lastCleanupScanStart).TotalSeconds -ge $cleanupInterval)){
        Start-WorktreeScan
    }

    $working=Update-SessionRows -Sessions $sessions
    $dc=if(-not $script:dcChecked){'CHECKING'}elseif($script:dcOnline){'ONLINE'}else{'RECONNECTING'}
    $dcTone=if(-not $script:dcChecked){'Neutral'}elseif($script:dcOnline){'Good'}else{'Warn'}

    Set-MetricCard $dcCard $dc $dcTone
    Set-MetricCard $chatCard "$($sessions.Count)/$($cfg.maxSlots)" 'Neutral'
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
    $connectionLabel.ForeColor=if(-not $script:dcChecked){
        $script:UiColors.Muted
    }elseif($script:dcOnline){
        $script:UiColors.Good
    }else{
        $script:UiColors.Warn
    }
    $notify.Text=("MultiChat: {0} chats | {1} working" -f $sessions.Count,$working)
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

$connectionLabel=New-Object Windows.Forms.Label
$connectionLabel.AutoSize=$true
$connectionLabel.Font=New-Object Drawing.Font('Segoe UI Semibold',9)
$connectionLabel.Anchor='Top,Right'
$connectionLabel.Location=New-Object Drawing.Point(840,12)
$header.Controls.Add($connectionLabel)

$windowControls=New-Object Windows.Forms.FlowLayoutPanel
$windowControls.Dock='Right'
$windowControls.Width=78
$windowControls.Height=36
$windowControls.WrapContents=$false
$windowControls.FlowDirection='LeftToRight'
$windowControls.BackColor=$script:UiColors.Bg
$windowControls.Padding=New-Object Windows.Forms.Padding(4,0,0,0)
$header.Controls.Add($windowControls)

$minimizeButton=New-WindowButton -Text ([char]0x2212)
$minimizeButton.Add_Click({$form.WindowState='Minimized'})
$windowControls.Controls.Add($minimizeButton)

$closeButton=New-WindowButton -Text ([char]0x00D7) -CloseButton
$closeButton.Add_Click({$form.Close()})
$windowControls.Controls.Add($closeButton)

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
$actionPanel.Height=58
$actionPanel.BackColor=$script:UiColors.Surface
$actionPanel.Padding=New-Object Windows.Forms.Padding(12,10,12,10)
$form.Controls.Add($actionPanel)

$cleanupButton=New-FlatButton -Text 'Clean safe worktrees' -Width 205 -Accent
$cleanupButton.Dock='Right'
$actionPanel.Controls.Add($cleanupButton)

$cleanupHint=New-Object Windows.Forms.Label
$cleanupHint.Text='Worktree checks run in the background.'
$cleanupHint.AutoSize=$true
$cleanupHint.ForeColor=$script:UiColors.Muted
$cleanupHint.Font=New-Object Drawing.Font('Segoe UI',9)
$cleanupHint.Location=New-Object Drawing.Point(12,19)
$actionPanel.Controls.Add($cleanupHint)

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

$menu=New-Object Windows.Forms.ContextMenuStrip
$miOpen=$menu.Items.Add('Open dashboard')
$miHide=$menu.Items.Add('Hide dashboard')
[void]$menu.Items.Add('-')
$miClean=$menu.Items.Add('Clean safe worktrees')
$miRestart=$menu.Items.Add('Restart Desktop Commander')
$miFolder=$menu.Items.Add('Open MultiChat folder')
[void]$menu.Items.Add('-')
$miExit=$menu.Items.Add('Exit')
$notify.ContextMenuStrip=$menu

$miOpen.Add_Click({$form.Show();$form.WindowState='Normal';$form.Activate()})
$miHide.Add_Click({$form.Hide()})
$miFolder.Add_Click({Start-Process explorer.exe -ArgumentList $root})
$miRestart.Add_Click({Restart-RemoteCommander})
$miClean.Add_Click({Start-WorktreeCleanup})
$cleanupButton.Add_Click({Start-WorktreeCleanup})
$notify.Add_DoubleClick({$form.Show();$form.WindowState='Normal';$form.Activate()})

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
    if($script:maintenanceProcess -and -not $script:maintenanceProcess.HasExited){$script:maintenanceProcess.Kill()}
    if($script:cleanupScanProcess -and -not $script:cleanupScanProcess.HasExited){$script:cleanupScanProcess.Kill()}
    if($script:cleanupProcess -and -not $script:cleanupProcess.HasExited){$script:cleanupProcess.Kill()}
    $notify.Visible=$false
    $form.Close()
    [Windows.Forms.Application]::Exit()
})

$timer=New-Object Windows.Forms.Timer
$timer.Interval=[Math]::Max(750,([int]$cfg.refreshSeconds*1000))
$timer.Add_Tick({Refresh-Dashboard})
$form.Add_ResizeBegin({$timer.Stop()})
$form.Add_ResizeEnd({Refresh-Dashboard;$timer.Start()})

Start-MaintenanceWorker
Start-WorktreeScan
Refresh-Dashboard
$timer.Start()
if(-not $StartHidden){$form.Show()}
[Windows.Forms.Application]::Run()

$notify.Visible=$false
$mutex.ReleaseMutex()
$mutex.Dispose()
