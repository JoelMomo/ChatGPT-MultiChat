$script:UiColors = @{
    Bg       = [Drawing.Color]::FromArgb(14,16,20)
    Surface  = [Drawing.Color]::FromArgb(21,24,30)
    Surface2 = [Drawing.Color]::FromArgb(28,32,40)
    Surface3 = [Drawing.Color]::FromArgb(35,40,49)
    Border   = [Drawing.Color]::FromArgb(48,55,67)
    Text     = [Drawing.Color]::FromArgb(235,238,244)
    Muted    = [Drawing.Color]::FromArgb(139,148,165)
    Accent   = [Drawing.Color]::FromArgb(94,211,243)
    Good     = [Drawing.Color]::FromArgb(91,214,153)
    Warn     = [Drawing.Color]::FromArgb(245,190,75)
    Bad      = [Drawing.Color]::FromArgb(244,106,106)
}

function Enable-ControlDoubleBuffer {
    param([Parameter(Mandatory)]$Control)
    try {
        $property = $Control.GetType().GetProperty(
            'DoubleBuffered',
            ([Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic)
        )
        if ($property) { $property.SetValue($Control,$true,$null) }
    } catch {}
}

function New-FlatButton {
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$Width = 150,
        [switch]$Accent
    )

    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = 34
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = if($Accent){$script:UiColors.Accent}else{$script:UiColors.Border}
    $button.BackColor = if($Accent){[Drawing.Color]::FromArgb(31,70,82)}else{$script:UiColors.Surface2}
    $button.ForeColor = $script:UiColors.Text
    $button.Font = New-Object Drawing.Font('Segoe UI',9,[Drawing.FontStyle]::Regular)
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    $button.Margin = New-Object Windows.Forms.Padding(6,0,0,0)
    $button.TabStop = $false

    $normalBack = $button.BackColor
    $hoverBack = if($Accent){[Drawing.Color]::FromArgb(38,84,98)}else{$script:UiColors.Surface3}
    $button.Add_MouseEnter({$this.BackColor=$hoverBack}.GetNewClosure())
    $button.Add_MouseLeave({$this.BackColor=$normalBack}.GetNewClosure())
    return $button
}

function New-MetricCard {
    param(
        [Parameter(Mandatory)][string]$Title,
        [int]$Width = 190
    )

    $card = New-Object Windows.Forms.Panel
    $card.Width = $Width
    $card.Height = 56
    $card.BackColor = $script:UiColors.Surface2
    $card.Margin = New-Object Windows.Forms.Padding(0,0,10,0)

    $titleLabel = New-Object Windows.Forms.Label
    $titleLabel.Text = $Title.ToUpperInvariant()
    $titleLabel.AutoSize = $true
    $titleLabel.Font = New-Object Drawing.Font('Segoe UI Semibold',7.5)
    $titleLabel.ForeColor = $script:UiColors.Muted
    $titleLabel.Location = New-Object Drawing.Point(12,8)
    $card.Controls.Add($titleLabel)

    $valueLabel = New-Object Windows.Forms.Label
    $valueLabel.Text = '--'
    $valueLabel.AutoSize = $true
    $valueLabel.Font = New-Object Drawing.Font('Segoe UI Semibold',12)
    $valueLabel.ForeColor = $script:UiColors.Text
    $valueLabel.Location = New-Object Drawing.Point(11,27)
    $card.Controls.Add($valueLabel)

    $card | Add-Member -NotePropertyName MetricValueLabel -NotePropertyValue $valueLabel
    return $card
}

function Set-MetricCard {
    param(
        [Parameter(Mandatory)]$Card,
        [Parameter(Mandatory)][string]$Value,
        [ValidateSet('Neutral','Good','Warn','Bad')][string]$Tone = 'Neutral'
    )
    if ($Card.MetricValueLabel.Text -ne $Value) { $Card.MetricValueLabel.Text = $Value }
    $color = switch($Tone) {
        'Good' { $script:UiColors.Good }
        'Warn' { $script:UiColors.Warn }
        'Bad' { $script:UiColors.Bad }
        default { $script:UiColors.Text }
    }
    if ($Card.MetricValueLabel.ForeColor -ne $color) { $Card.MetricValueLabel.ForeColor = $color }
}

function Get-SlotColor([int]$Slot) {
    switch ($Slot) {
        1 { [Drawing.Color]::FromArgb(91,214,153) }
        2 { [Drawing.Color]::FromArgb(94,211,243) }
        3 { [Drawing.Color]::FromArgb(217,125,255) }
        4 { [Drawing.Color]::FromArgb(245,190,75) }
        5 { [Drawing.Color]::FromArgb(102,153,255) }
        6 { [Drawing.Color]::FromArgb(255,126,108) }
        7 { [Drawing.Color]::FromArgb(225,229,238) }
        default { [Drawing.Color]::FromArgb(87,180,180) }
    }
}

function Format-SessionAge {
    param($Session)
    try { $since=[DateTimeOffset]::Parse([string]$Session.updatedAt).LocalDateTime }
    catch { return '--:--' }

    $span=(Get-Date)-$since
    if ($span.TotalHours -ge 1) {
        return ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($span.TotalHours),$span.Minutes,$span.Seconds)
    }
    return ('{0:00}:{1:00}' -f $span.Minutes,$span.Seconds)
}

function Set-GridCellValue {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Column,
        $Value
    )
    $text = if($null -eq $Value){''}else{[string]$Value}
    if ([string]$Row.Cells[$Column].Value -ne $text) {
        $Row.Cells[$Column].Value = $text
    }
}


if (-not ('MultiChatNativeWindow' -as [type])) {
    Add-Type -TypeDefinition @"
using System;

public static class MultiChatNativeWindow
{
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ReleaseCapture();

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
}
"@
}

function Enable-WindowDrag {
    param(
        [Parameter(Mandatory)]$Control,
        [Parameter(Mandatory)]$Form
    )

    $Control.Add_MouseDown({
        param($sender,$eventArgs)
        if ($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left -and $Form.WindowState -eq 'Normal') {
            [MultiChatNativeWindow]::ReleaseCapture() | Out-Null
            [MultiChatNativeWindow]::SendMessage($Form.Handle,0x00A1,2,0) | Out-Null
        }
    }.GetNewClosure())
}

function Format-GitSummary {
    param($Summary)

    if (-not $Summary -or -not [bool](Get-ChatProp $Summary 'hasGit' $false)) {
        return [pscustomobject]@{ Text='--'; Tone='Neutral'; ToolTip='No Git worktree detected' }
    }

    $modified = [int](Get-ChatProp $Summary 'modified' 0)
    $untracked = [int](Get-ChatProp $Summary 'untracked' 0)
    $ahead = [int](Get-ChatProp $Summary 'ahead' 0)
    $behind = [int](Get-ChatProp $Summary 'behind' 0)

    $parts = @()
    if ($modified -gt 0) { $parts += "$modified changed" }
    if ($untracked -gt 0) { $parts += "$untracked new" }
    if ($ahead -gt 0) { $parts += "ahead $ahead" }
    if ($behind -gt 0) { $parts += "behind $behind" }

    if (-not $parts.Count) {
        return [pscustomobject]@{ Text='Clean'; Tone='Good'; ToolTip='Working tree clean and branch aligned with the base checkout' }
    }

    $tipParts = @()
    if ($modified -gt 0) { $tipParts += "$modified tracked file(s) changed" }
    if ($untracked -gt 0) { $tipParts += "$untracked untracked file(s)" }
    if ($ahead -gt 0) { $tipParts += "$ahead commit(s) ahead" }
    if ($behind -gt 0) { $tipParts += "$behind commit(s) behind" }

    return [pscustomobject]@{
        Text = ($parts -join '  ')
        Tone = if($behind -gt 0){'Warn'}elseif($modified -gt 0 -or $untracked -gt 0){'Warn'}else{'Neutral'}
        ToolTip = ($tipParts -join '; ')
    }
}


function Show-MultiChatConfirm {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$Message,
        [string]$Title = 'MultiChat'
    )

    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.Size = New-Object Drawing.Size(510,178)
    $dialog.MinimumSize = $dialog.Size
    $dialog.MaximumSize = $dialog.Size
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $script:UiColors.Surface
    $dialog.ForeColor = $script:UiColors.Text
    $dialog.FormBorderStyle = 'None'
    $dialog.ShowInTaskbar = $false
    $dialog.Padding = New-Object Windows.Forms.Padding(18)
    Enable-ControlDoubleBuffer $dialog

    $titleLabel = New-Object Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.AutoSize = $true
    $titleLabel.Font = New-Object Drawing.Font('Segoe UI Semibold',11)
    $titleLabel.ForeColor = $script:UiColors.Text
    $titleLabel.Location = New-Object Drawing.Point(18,15)
    $dialog.Controls.Add($titleLabel)

    $messageLabel = New-Object Windows.Forms.Label
    $messageLabel.Text = $Message
    $messageLabel.Size = New-Object Drawing.Size(470,52)
    $messageLabel.Font = New-Object Drawing.Font('Segoe UI',9.5)
    $messageLabel.ForeColor = $script:UiColors.Text
    $messageLabel.Location = New-Object Drawing.Point(18,52)
    $dialog.Controls.Add($messageLabel)

    $noButton = New-FlatButton -Text 'Cancel' -Width 105
    $noButton.Location = New-Object Drawing.Point(270,122)
    $noButton.DialogResult = [Windows.Forms.DialogResult]::No
    $dialog.Controls.Add($noButton)

    $yesButton = New-FlatButton -Text 'Clean' -Width 105 -Accent
    $yesButton.Location = New-Object Drawing.Point(383,122)
    $yesButton.DialogResult = [Windows.Forms.DialogResult]::Yes
    $dialog.Controls.Add($yesButton)

    $dialog.AcceptButton = $yesButton
    $dialog.CancelButton = $noButton
    Enable-WindowDrag -Control $titleLabel -Form $dialog

    try {
        return ($dialog.ShowDialog($Owner) -eq [Windows.Forms.DialogResult]::Yes)
    } finally {
        $dialog.Dispose()
    }
}

function Show-MultiChatInfo {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$Message,
        [string]$Title = 'MultiChat'
    )

    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.Size = New-Object Drawing.Size(450,155)
    $dialog.MinimumSize = $dialog.Size
    $dialog.MaximumSize = $dialog.Size
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $script:UiColors.Surface
    $dialog.ForeColor = $script:UiColors.Text
    $dialog.FormBorderStyle = 'None'
    $dialog.ShowInTaskbar = $false

    $titleLabel = New-Object Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.AutoSize = $true
    $titleLabel.Font = New-Object Drawing.Font('Segoe UI Semibold',11)
    $titleLabel.ForeColor = $script:UiColors.Text
    $titleLabel.Location = New-Object Drawing.Point(18,15)
    $dialog.Controls.Add($titleLabel)

    $messageLabel = New-Object Windows.Forms.Label
    $messageLabel.Text = $Message
    $messageLabel.Size = New-Object Drawing.Size(410,48)
    $messageLabel.Font = New-Object Drawing.Font('Segoe UI',9.5)
    $messageLabel.ForeColor = $script:UiColors.Text
    $messageLabel.Location = New-Object Drawing.Point(18,50)
    $dialog.Controls.Add($messageLabel)

    $okButton = New-FlatButton -Text 'OK' -Width 105 -Accent
    $okButton.Location = New-Object Drawing.Point(325,108)
    $okButton.DialogResult = [Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($okButton)
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $okButton
    Enable-WindowDrag -Control $titleLabel -Form $dialog

    try {
        [void]$dialog.ShowDialog($Owner)
    } finally {
        $dialog.Dispose()
    }
}
