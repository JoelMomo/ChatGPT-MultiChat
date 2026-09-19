$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$tempRoot=Join-Path $env:TEMP ("multichat-capacity-test-"+[guid]::NewGuid().ToString('N'))

function Set-TestCapacity {
    param(
        [Parameter(Mandatory)]$Module,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][int]$Capacity
    )
    $cfg=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
    $cfg.maxSlots=$Capacity
    [IO.File]::WriteAllText($ConfigPath,($cfg|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
    & $Module { $script:ChatConfigCache=$null; $script:ChatConfigStamp=[datetime]::MinValue }
}

function Seed-OccupiedSlots {
    param(
        [Parameter(Mandatory)][string]$SlotRoot,
        [Parameter(Mandatory)][int]$Count
    )
    Remove-Item (Join-Path $SlotRoot 'slot-*.json') -Force -ErrorAction SilentlyContinue
    for($slot=1;$slot -le $Count;$slot++){
        $payload=[ordered]@{
            sessionId=("capacity-fixture-{0}" -f $slot)
            pid=$PID
            claimedAt=(Get-Date).ToString('o')
        }
        [IO.File]::WriteAllText(
            (Join-Path $SlotRoot ("slot-{0}.json" -f $slot)),
            ($payload|ConvertTo-Json -Compress),
            (New-Object Text.UTF8Encoding($false))
        )
    }
}

function Assert-NextSlot {
    param(
        [Parameter(Mandatory)]$Module,
        [Parameter(Mandatory)][int]$Expected
    )
    $actual=& $Module { param($id) Claim-ChatSlot -SessionId $id -SkipExpiry } ("capacity-next-{0}" -f $Expected)
    if([int]$actual -ne $Expected){
        throw "Expected CHAT-$Expected, got CHAT-$actual."
    }
}

function Assert-OverflowBlocked {
    param(
        [Parameter(Mandatory)]$Module,
        [Parameter(Mandatory)][string]$SessionId
    )
    $blocked=$false
    try{[void](& $Module { param($id) Claim-ChatSlot -SessionId $id -SkipExpiry } $SessionId)}
    catch{$blocked=$true}
    if(-not $blocked){throw "Expected overflow to be blocked for $SessionId."}
}

try{
    New-Item -ItemType Directory -Path $tempRoot -Force|Out-Null
    foreach($name in @('ChatMulti.psm1','ChatMulti.Advanced.ps1','ChatMulti.Hardening.ps1','config.json')){
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $tempRoot $name) -Force
    }

    $configPath=Join-Path $tempRoot 'config.json'
    $module=Import-Module (Join-Path $tempRoot 'ChatMulti.psm1') -Force -DisableNameChecking -PassThru
    & $module { Initialize-ChatMulti }
    $slotRoot=Join-Path $tempRoot 'state\slots'

    Set-TestCapacity -Module $module -ConfigPath $configPath -Capacity 12
    Seed-OccupiedSlots -SlotRoot $slotRoot -Count 11
    Assert-NextSlot -Module $module -Expected 12
    Assert-OverflowBlocked -Module $module -SessionId 'capacity-overflow-13'

    Set-TestCapacity -Module $module -ConfigPath $configPath -Capacity 32
    Seed-OccupiedSlots -SlotRoot $slotRoot -Count 31
    Assert-NextSlot -Module $module -Expected 32
    Assert-OverflowBlocked -Module $module -SessionId 'capacity-overflow-33'

    Set-TestCapacity -Module $module -ConfigPath $configPath -Capacity 99
    Seed-OccupiedSlots -SlotRoot $slotRoot -Count 32
    Assert-OverflowBlocked -Module $module -SessionId 'capacity-clamp-overflow'

    Write-Host 'CAPACITY-TEST: OK' -ForegroundColor Green
    Write-Host 'Dynamic capacity validated at 12 and 32 chats; CHAT-33 is rejected.'
    exit 0
}catch{
    Write-Host 'CAPACITY-TEST: FAIL' -ForegroundColor Red
    Write-Host (' - '+$_.Exception.Message) -ForegroundColor Red
    exit 1
}finally{
    Remove-Module ChatMulti -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
