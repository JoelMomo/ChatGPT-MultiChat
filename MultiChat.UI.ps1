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
