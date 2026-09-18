param([switch]$StartHidden)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'SilentlyContinue'
$root = $PSScriptRoot
Import-Module (Join-Path $root 'ChatMulti.psm1') -Force -DisableNameChecking
$cfg = Get-ChatConfig

$createdNew = $false
$mutex = New-Object Threading.Mutex($true,'ChatGPTMultiChatAgentV2',[ref]$createdNew)
if (-not $createdNew) {
    [Windows.Forms.MessageBox]::Show('ChatGPT MultiChat Agent ya esta abierto.','MultiChat') | Out-Null
    exit 0
}

$script:exiting = $false
$script:lastRemoteRestart = [datetime]::MinValue
$script:gitCache = @{}
$script:cleanupCandidates = @()
$script:lastRemoteCheck = [datetime]::MinValue
$script:remoteProcesses = @()
$script:lastCleanupCheck = [datetime]::MinValue
$script:cachedSafe = 0
$script:cachedPending = 0

function Get-RemoteCommanderProcess {
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -match 'desktop-commander' -and $_.CommandLine -match '\bremote\b'
    })
}

function Start-RemoteCommanderHidden {
    if (-not (Get-Command npx.cmd -ErrorAction SilentlyContinue)) { return $false }
    $log = Join-Path $root 'state\logs\desktop-commander.log'
    $cmd = 'npx.cmd @wonderwhy-er/desktop-commander@latest remote >> "' + $log + '" 2>&1'
    Start-Process cmd.exe -ArgumentList '/c',$cmd -WindowStyle Hidden | Out-Null
    $script:lastRemoteRestart = Get-Date
    return $true
}

function Restart-RemoteCommander {
    foreach ($proc in @(Get-RemoteCommanderProcess)) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 700
    Start-RemoteCommanderHidden | Out-Null
}

function Get-SlotColor([int]$slot) {
    switch ($slot) {
        1 { [Drawing.Color]::LimeGreen }
        2 { [Drawing.Color]::Cyan }
        3 { [Drawing.Color]::Magenta }
        4 { [Drawing.Color]::Gold }
        5 { [Drawing.Color]::DodgerBlue }
        6 { [Drawing.Color]::Tomato }
        7 { [Drawing.Color]::White }
        default { [Drawing.Color]::DarkCyan }
    }
}

function Format-Age($Session) {
    try { $since=[DateTimeOffset]::Parse([string]$Session.updatedAt).LocalDateTime }
    catch { return '--:--' }
    $span=(Get-Date)-$since
    if ($span.TotalHours -ge 1) {
        return ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($span.TotalHours),$span.Minutes,$span.Seconds)
    }
    return ('{0:00}:{1:00}' -f $span.Minutes,$span.Seconds)
}

function Get-GitCached($Session) {
    if (-not $Session.originRepo) { return $null }
    $id=[string]$Session.id
    $cached=$script:gitCache[$id]
    $now=Get-Date
    if ($cached -and (($now-$cached.at).TotalSeconds -lt [int]$cfg.gitRefreshSeconds)) {
        return $cached.value
    }
    $value=Get-ChatGitSummary $Session
    $script:gitCache[$id]=@{at=$now;value=$value}
    return $value
}

$form = New-Object Windows.Forms.Form
$form.Text = 'ChatGPT MultiChat Agent'
$form.Size = New-Object Drawing.Size(1040,650)
$form.MinimumSize = New-Object Drawing.Size(820,500)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [Drawing.Color]::FromArgb(24,24,24)
$form.ForeColor = [Drawing.Color]::Gainsboro

$top = New-Object Windows.Forms.Panel
$top.Dock='Top'
$top.Height=62
$top.Padding=New-Object Windows.Forms.Padding(12,8,12,6)
$form.Controls.Add($top)

$title = New-Object Windows.Forms.Label
$title.Text='CHATGPT MULTICHAT'
$title.Font=New-Object Drawing.Font('Consolas',16,[Drawing.FontStyle]::Bold)
$title.AutoSize=$true
$title.ForeColor=[Drawing.Color]::Cyan
$title.Location=New-Object Drawing.Point(12,7)
$top.Controls.Add($title)

$statusLabel = New-Object Windows.Forms.Label
$statusLabel.AutoSize=$true
$statusLabel.Font=New-Object Drawing.Font('Consolas',10)
$statusLabel.Location=New-Object Drawing.Point(14,37)
$top.Controls.Add($statusLabel)

$cleanupButton = New-Object Windows.Forms.Button
$cleanupButton.Text='Limpiar worktrees seguros'
$cleanupButton.Width=190
$cleanupButton.Height=30
$cleanupButton.Anchor='Top,Right'
$cleanupButton.Location=New-Object Drawing.Point(824,16)
$top.Controls.Add($cleanupButton)

$split = New-Object Windows.Forms.SplitContainer
$split.Dock='Fill'
$split.Orientation='Horizontal'
$split.SplitterDistance=365
$split.BackColor=$form.BackColor
$form.Controls.Add($split)
$split.BringToFront()

$grid = New-Object Windows.Forms.DataGridView
$grid.Dock='Fill'
$grid.ReadOnly=$true
$grid.AllowUserToAddRows=$false
$grid.AllowUserToDeleteRows=$false
$grid.AllowUserToResizeRows=$false
$grid.RowHeadersVisible=$false
$grid.AutoSizeColumnsMode='Fill'
$grid.BackgroundColor=$form.BackColor
$grid.BorderStyle='None'
$grid.EnableHeadersVisualStyles=$false
$grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(40,40,40)
$grid.ColumnHeadersDefaultCellStyle.ForeColor=[Drawing.Color]::White
$grid.DefaultCellStyle.BackColor=$form.BackColor
$grid.DefaultCellStyle.ForeColor=[Drawing.Color]::Gainsboro
$grid.DefaultCellStyle.SelectionBackColor=[Drawing.Color]::FromArgb(55,55,55)
$grid.DefaultCellStyle.SelectionForeColor=[Drawing.Color]::White
$grid.Font=New-Object Drawing.Font('Consolas',9)
$grid.TabStop=$false
try { $db=$grid.GetType().GetProperty('DoubleBuffered',([Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic)); if($db){$db.SetValue($grid,$true,$null)} } catch {}
$split.Panel1.Controls.Add($grid)

foreach ($col in @(
    @('Chat','Chat',62),@('Project','Proyecto',140),@('Activity','Actividad',105),
    @('Detail','Detalle',80),@('Time','Tiempo',62),@('Git','Git',95),
    @('Port','Puerto',58),@('Task','Tarea',190),@('Warning','Aviso',155)
)) {
    $c=New-Object Windows.Forms.DataGridViewTextBoxColumn
    $c.Name=$col[0]
    $c.HeaderText=$col[1]
    $c.FillWeight=[int]$col[2]
    [void]$grid.Columns.Add($c)
}

$historyTitle=New-Object Windows.Forms.Label
$historyTitle.Text='Historial reciente'
$historyTitle.Dock='Top'
$historyTitle.Height=25
$historyTitle.Padding=New-Object Windows.Forms.Padding(8,4,0,0)
$historyTitle.ForeColor=[Drawing.Color]::DarkGray
$split.Panel2.Controls.Add($historyTitle)

$historyBox=New-Object Windows.Forms.TextBox
$historyBox.Dock='Fill'
$historyBox.Multiline=$true
$historyBox.ReadOnly=$true
$historyBox.ScrollBars='Vertical'
$historyBox.BackColor=$form.BackColor
$historyBox.ForeColor=[Drawing.Color]::Silver
$historyBox.BorderStyle='None'
$historyBox.Font=New-Object Drawing.Font('Consolas',9)
$split.Panel2.Controls.Add($historyBox)
$historyBox.BringToFront()

$notify = New-Object Windows.Forms.NotifyIcon
$notify.Icon=[Drawing.SystemIcons]::Application
$notify.Text='ChatGPT MultiChat Agent'
$notify.Visible=$true

$menu=New-Object Windows.Forms.ContextMenuStrip
$miOpen=$menu.Items.Add('Abrir panel')
$miHide=$menu.Items.Add('Ocultar panel')
[void]$menu.Items.Add('-')
$miClean=$menu.Items.Add('Limpiar worktrees seguros')
$miRestart=$menu.Items.Add('Reiniciar Desktop Commander')
$miFolder=$menu.Items.Add('Abrir carpeta MultiChat')
[void]$menu.Items.Add('-')
$miExit=$menu.Items.Add('Salir')
$notify.ContextMenuStrip=$menu

$miOpen.Add_Click({$form.Show();$form.WindowState='Normal';$form.Activate()})
$miHide.Add_Click({$form.Hide()})
$miFolder.Add_Click({Start-Process explorer.exe -ArgumentList $root})
$miRestart.Add_Click({Restart-RemoteCommander})
$notify.Add_DoubleClick({$form.Show();$form.WindowState='Normal';$form.Activate()})

function Invoke-CleanupFromUi {
    $safe=@($script:cleanupCandidates | Where-Object safe)
    if (-not $safe.Count) {
        [Windows.Forms.MessageBox]::Show('No hay worktrees seguros para limpiar.','MultiChat') | Out-Null
        return
    }
    $msg="Se eliminaran $($safe.Count) worktrees limpios y sin commits pendientes. Continuar?"
    if ([Windows.Forms.MessageBox]::Show($msg,'MultiChat','YesNo','Question') -eq 'Yes') {
        $removed=@(Invoke-SafeWorktreeCleanup)
        [Windows.Forms.MessageBox]::Show("Eliminados: $($removed.Count)",'MultiChat') | Out-Null
    }
}
$cleanupButton.Add_Click({Invoke-CleanupFromUi})
$miClean.Add_Click({Invoke-CleanupFromUi})

$form.Add_FormClosing({
    param($sender,$e)
    if (-not $script:exiting) {
        $e.Cancel=$true
        $form.Hide()
        $notify.ShowBalloonTip(1000,'MultiChat','Sigue activo en la bandeja.','Info')
    }
})

$miExit.Add_Click({
    $script:exiting=$true
    $notify.Visible=$false
    $form.Close()
    [Windows.Forms.Application]::Exit()
})

function Refresh-Dashboard {
    Expire-IdleManagedChatSessions | Out-Null
    $now=Get-Date
    $sessions=@(Get-ManagedChatSessions | Where-Object active | Sort-Object slot)
    if (($now-$script:lastRemoteCheck).TotalSeconds -ge 5) {
        $script:remoteProcesses=@(Get-RemoteCommanderProcess)
        $script:lastRemoteCheck=$now
    }
    $remote=@($script:remoteProcesses)

    if (-not $remote.Count -and ((Get-Date)-$script:lastRemoteRestart).TotalSeconds -ge 10) {
        Start-RemoteCommanderHidden | Out-Null
    }

    $conflicts=@(Get-ProjectConflictGroups -Sessions $sessions)
    $conflictRepos=@{}
    foreach ($g in $conflicts) { $conflictRepos[$g.originRepo]=$g.count }

    while ($grid.Rows.Count -lt $sessions.Count) { [void]$grid.Rows.Add() }
    while ($grid.Rows.Count -gt $sessions.Count) { $grid.Rows.RemoveAt($grid.Rows.Count-1) }
    $rowIndex=0
    foreach ($s in $sessions) {
        $idle=Get-SessionIdleInfo $s
        if ($s.status -eq 'READY') {
            $activity=if($idle.abandoned){'ABANDONADO'}else{'LIBRE'}
            $detail=''
        } else {
            $activity='TRABAJANDO'
            $detail=[string]$s.status
        }

        $git=Get-GitCached $s
        $gitText=if($git -and $git.text){$git.text}elseif($git -and $git.hasGit){'clean'}else{''}
        $port=Get-ChatProp $s 'devPort' ''
        $warning=''
        if ($s.originRepo -and $conflictRepos.ContainsKey([string]$s.originRepo)) {
            $warning="MISMO PROYECTO x$($conflictRepos[[string]$s.originRepo])"
        }

        $row=$rowIndex; $rowIndex++; $grid.Rows[$row].SetValues(
            "CHAT-$($s.slot)",$s.project,$activity,$detail,(Format-Age $s),
            $gitText,$port,$s.task,$warning
        )
        $grid.Rows[$row].Cells['Chat'].Style.BackColor=Get-SlotColor ([int]$s.slot)
        $grid.Rows[$row].Cells['Chat'].Style.ForeColor=[Drawing.Color]::Black
        $grid.Rows[$row].Cells['Chat'].Style.SelectionBackColor=Get-SlotColor ([int]$s.slot)
        $grid.Rows[$row].Cells['Chat'].Style.SelectionForeColor=[Drawing.Color]::Black
        if ($activity -eq 'TRABAJANDO') {
            $grid.Rows[$row].Cells['Activity'].Style.ForeColor=[Drawing.Color]::Gold
        } elseif ($activity -eq 'ABANDONADO') {
            $grid.Rows[$row].Cells['Activity'].Style.ForeColor=[Drawing.Color]::OrangeRed
        } else {
            $grid.Rows[$row].Cells['Activity'].Style.ForeColor=[Drawing.Color]::LimeGreen
        }
        $grid.Rows[$row].Cells['Warning'].Style.ForeColor=[Drawing.Color]::Gainsboro
        if ($warning) {
            $grid.Rows[$row].Cells['Warning'].Style.ForeColor=[Drawing.Color]::Orange
        }
    }

    $grid.ClearSelection()
    $grid.CurrentCell=$null

    if (($now-$script:lastCleanupCheck).TotalSeconds -ge 5) {
        $script:cleanupCandidates=@(Get-WorktreeCleanupCandidates)
        $script:cachedSafe=@($script:cleanupCandidates | Where-Object safe).Count
        $script:cachedPending=@($script:cleanupCandidates | Where-Object { -not $_.safe }).Count
        $script:lastCleanupCheck=$now
    }
    $safe=$script:cachedSafe
    $pending=$script:cachedPending


    $dc=if($remote.Count){'ONLINE'}else{'RECONECTANDO'}
    $statusLabel.Text="Desktop Commander: $dc   |   Chats: $($sessions.Count)/$($cfg.maxSlots)   |   Worktrees: $safe limpiables, $pending pendientes"
    $statusLabel.ForeColor=if($remote.Count){[Drawing.Color]::LimeGreen}else{[Drawing.Color]::OrangeRed}

    $history=@(Get-ChatHistory -Limit 12 | Select-Object -Last 12)
    $lines=@()
    foreach ($h in $history) {
        try { $ended=(Get-Date $h.endedAt -Format 'HH:mm:ss') } catch { $ended='--:--:--' }
        $lines += ("{0}  CHAT-{1}  {2,-18}  {3,-14}  {4}s  {5}" -f $ended,$h.slot,$h.project,$h.reason,$h.durationSeconds,$h.task)
    }
    $historyBox.Text=($lines -join [Environment]::NewLine)

    $notify.Text=("MultiChat: {0} chats | DC {1}" -f $sessions.Count,$dc)
}

$timer=New-Object Windows.Forms.Timer
$timer.Interval=[Math]::Max(500,([int]$cfg.refreshSeconds*1000))
$timer.Add_Tick({Refresh-Dashboard})
$form.Add_ResizeBegin({ $timer.Stop() })
$form.Add_ResizeEnd({ Refresh-Dashboard; $timer.Start() })
$timer.Start()

Refresh-Dashboard
if (-not $StartHidden) { $form.Show() }
[Windows.Forms.Application]::Run()
$notify.Visible=$false
$mutex.ReleaseMutex()
$mutex.Dispose()
