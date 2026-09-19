$script:LeaseRoot = Join-Path $script:StateRoot 'leases'

function Initialize-HardeningState {
    if (-not (Test-Path -LiteralPath $script:LeaseRoot)) {
        New-Item -ItemType Directory -Path $script:LeaseRoot -Force | Out-Null
    }
}

function ConvertTo-ChatCanonicalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $separators=[char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    try {
        return [IO.Path]::GetFullPath($Path).
            Replace([IO.Path]::AltDirectorySeparatorChar,[IO.Path]::DirectorySeparatorChar).
            TrimEnd($separators)
    } catch {
        return $Path.Trim().Replace([IO.Path]::AltDirectorySeparatorChar,[IO.Path]::DirectorySeparatorChar).TrimEnd($separators)
    }
}

function Test-ChatPathEqual {
    param([string]$Left,[string]$Right)
    $a=ConvertTo-ChatCanonicalPath $Left
    $b=ConvertTo-ChatCanonicalPath $Right
    if (-not $a -or -not $b) { return $false }
    return [string]::Equals($a,$b,[StringComparison]::OrdinalIgnoreCase)
}

function Test-ChatPathWithin {
    param([string]$Path,[string]$Root)
    $child=ConvertTo-ChatCanonicalPath $Path
    $parent=ConvertTo-ChatCanonicalPath $Root
    if (-not $child -or -not $parent) { return $false }
    if ([string]::Equals($child,$parent,[StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix=$parent+[IO.Path]::DirectorySeparatorChar
    return $child.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
}

function Invoke-ChatGitCapture {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $output=@(& git -C $Repo @Arguments 2>$null)
    $exitCode=$LASTEXITCODE
    return [pscustomobject]@{
        ExitCode=$exitCode
        Output=$output
        First=($output | Select-Object -First 1)
    }
}

function Resolve-ExactGitBase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$BaseRef,
        [string]$BaseSha
    )

    $exactRequested=(-not [string]::IsNullOrWhiteSpace($BaseRef) -or -not [string]::IsNullOrWhiteSpace($BaseSha))
    if ($exactRequested -and ([string]::IsNullOrWhiteSpace($BaseRef) -or [string]::IsNullOrWhiteSpace($BaseSha))) {
        throw 'Exact base mode requires both BaseRef and BaseSha.'
    }

    if (-not $exactRequested) {
        $head=Invoke-ChatGitCapture -Repo $Repo -Arguments @('rev-parse','HEAD^{commit}')
        if ($head.ExitCode -ne 0 -or -not $head.First) {
            throw 'Could not resolve repository HEAD.'
        }
        return [pscustomobject]@{
            BaseRef='HEAD'
            BaseSha=([string]$head.First).Trim().ToLowerInvariant()
            ExactRequested=$false
        }
    }

    $shaText=$BaseSha.Trim().ToLowerInvariant()
    if ($shaText -notmatch '^[0-9a-f]{40}$') {
        throw 'BaseSha must be a full 40-character Git commit SHA.'
    }

    $shaCheck=Invoke-ChatGitCapture -Repo $Repo -Arguments @('rev-parse',"$shaText^{commit}")
    if ($shaCheck.ExitCode -ne 0 -or -not $shaCheck.First) {
        throw "BaseSha '$BaseSha' is not a commit available in the repository."
    }
    $resolvedSha=([string]$shaCheck.First).Trim().ToLowerInvariant()

    $refCheck=Invoke-ChatGitCapture -Repo $Repo -Arguments @('rev-parse',"$BaseRef^{commit}")
    if ($refCheck.ExitCode -ne 0 -or -not $refCheck.First) {
        throw "BaseRef '$BaseRef' cannot be resolved to a commit."
    }
    $resolvedRef=([string]$refCheck.First).Trim().ToLowerInvariant()

    if ($resolvedRef -ne $resolvedSha) {
        throw "Base mismatch: '$BaseRef' resolves to $resolvedRef, expected $resolvedSha."
    }

    return [pscustomobject]@{
        BaseRef=$BaseRef
        BaseSha=$resolvedSha
        ExactRequested=$true
    }
}

function Resolve-ChatCanonicalRef {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$CanonicalRef
    )
    if ([string]::IsNullOrWhiteSpace($CanonicalRef)) { return $null }
    $check=Invoke-ChatGitCapture -Repo $Repo -Arguments @('rev-parse',"$CanonicalRef^{commit}")
    if ($check.ExitCode -ne 0 -or -not $check.First) {
        throw "CanonicalRef '$CanonicalRef' cannot be resolved to a commit."
    }
    return ([string]$check.First).Trim().ToLowerInvariant()
}

function Get-ManagedWorktreeIdentity {
    param([Parameter(Mandatory)]$Session)

    $workspace=[string](Get-ChatProp $Session 'workspace' '')
    $originRepo=[string](Get-ChatProp $Session 'originRepo' '')
    $branch=[string](Get-ChatProp $Session 'branch' '')
    $workspaceKind=[string](Get-ChatProp $Session 'workspaceKind' '')
    if (-not $workspaceKind) {
        if([bool](Get-ChatProp $Session 'isolated' $false)){
            $workspaceKind='worktree'
        }elseif($workspace -and $originRepo -and -not(Test-ChatPathEqual $workspace $originRepo)){
            # Revalidation candidates may omit the original isolated property.
            # Legacy worktrees are still distinguishable from direct sessions by path.
            $workspaceKind='worktree'
        }else{
            $workspaceKind='direct'
        }
    }
    if (-not $workspace -or -not $originRepo -or -not (Test-Path -LiteralPath $workspace) -or -not (Test-Path -LiteralPath $originRepo)) {
        return [pscustomobject]@{Valid=$false;Reason='WORKSPACE_MISSING';Head='';Branch=''}
    }

    $top=Invoke-ChatGitCapture -Repo $workspace -Arguments @('rev-parse','--show-toplevel')
    if ($top.ExitCode -ne 0 -or -not $top.First -or -not (Test-ChatPathEqual $workspace ([string]$top.First))) {
        return [pscustomobject]@{Valid=$false;Reason='WORKSPACE_MISMATCH';Head='';Branch=''}
    }

    if ($workspaceKind -eq 'clone') {
        if (-not (Test-ChatPathWithin -Path $workspace -Root $script:WorkspaceRoot)) {
            return [pscustomobject]@{Valid=$false;Reason='WORKSPACE_OUTSIDE_ROOT';Head='';Branch=''}
        }
        if (-not (Test-Path -LiteralPath (Join-Path $workspace '.git') -PathType Container)) {
            return [pscustomobject]@{Valid=$false;Reason='FOREIGN_CLONE_STATE';Head='';Branch=''}
        }

        $remote=Invoke-ChatGitCapture -Repo $workspace -Arguments @('config','--get','remote.origin.url')
        if ($remote.ExitCode -ne 0 -or -not $remote.First -or -not (Test-ChatPathEqual ([string]$remote.First) $originRepo)) {
            return [pscustomobject]@{Valid=$false;Reason='FOREIGN_CLONE_ORIGIN';Head='';Branch=''}
        }
        $head=Invoke-ChatGitCapture -Repo $workspace -Arguments @('rev-parse','HEAD^{commit}')
        $branchNow=Invoke-ChatGitCapture -Repo $workspace -Arguments @('branch','--show-current')
        $headText=if($head.First){([string]$head.First).Trim()}else{''}
        $branchText=if($branchNow.First){([string]$branchNow.First).Trim()}else{''}
        if ($head.ExitCode -ne 0 -or -not $headText -or ($branch -and $branchText -ne $branch)) {
            return [pscustomobject]@{Valid=$false;Reason='FOREIGN_CLONE_STATE';Head=$headText;Branch=$branchText}
        }
        return [pscustomobject]@{Valid=$true;Reason='OK';Head=$headText;Branch=$branchText}
    }

    if ($workspaceKind -ne 'worktree') {
        return [pscustomobject]@{Valid=$false;Reason='WORKSPACE_NOT_ISOLATED';Head='';Branch=''}
    }

    $listing=Invoke-ChatGitCapture -Repo $originRepo -Arguments @('worktree','list','--porcelain')
    if ($listing.ExitCode -ne 0) {
        return [pscustomobject]@{Valid=$false;Reason='FOREIGN_WORKTREE_STATE';Head='';Branch=''}
    }

    $found=$false
    $foundHead=''
    $foundBranch=''
    $currentPath=''
    $currentHead=''
    $currentBranch=''
    foreach($line in @($listing.Output)+@('')){
        if ([string]::IsNullOrWhiteSpace([string]$line)) {
            if ($currentPath -and (Test-ChatPathEqual $currentPath $workspace)) {
                $found=$true
                $foundHead=$currentHead
                $foundBranch=$currentBranch
                break
            }
            $currentPath='';$currentHead='';$currentBranch=''
            continue
        }
        if ($line -like 'worktree *') {$currentPath=[string]$line.Substring(9)}
        elseif ($line -like 'HEAD *') {$currentHead=[string]$line.Substring(5)}
        elseif ($line -like 'branch *') {$currentBranch=[string]$line.Substring(7)}
    }

    if (-not $found) {
        return [pscustomobject]@{Valid=$false;Reason='FOREIGN_WORKTREE_STATE';Head='';Branch=''}
    }

    if ($branch) {
        $expected="refs/heads/$branch"
        if (-not [string]::Equals($foundBranch,$expected,[StringComparison]::Ordinal)) {
            return [pscustomobject]@{Valid=$false;Reason='FOREIGN_WORKTREE_STATE';Head=$foundHead;Branch=$foundBranch}
        }
    }

    return [pscustomobject]@{Valid=$true;Reason='OK';Head=$foundHead;Branch=$foundBranch}
}

function Get-ManagedCommitSafety {
    param([Parameter(Mandatory)]$Session)

    $workspace=[string](Get-ChatProp $Session 'workspace' '')
    $originRepo=[string](Get-ChatProp $Session 'originRepo' '')
    $baseSha=[string](Get-ChatProp $Session 'baseSha' '')
    $baseRef=[string](Get-ChatProp $Session 'baseRef' '')
    $canonicalRef=[string](Get-ChatProp $Session 'canonicalRef' '')

    if ($baseSha -notmatch '^[0-9a-fA-F]{40}$') {
        return [pscustomobject]@{Safe=$false;Reason='BASE_UNKNOWN';OwnCommits=-1;Integrated=$false;BaseMoved=$false;CanonicalSha=''}
    }

    $baseCheck=Invoke-ChatGitCapture -Repo $originRepo -Arguments @('rev-parse',"$baseSha^{commit}")
    if ($baseCheck.ExitCode -ne 0 -or -not $baseCheck.First) {
        return [pscustomobject]@{Safe=$false;Reason='BASE_INCORRECT';OwnCommits=-1;Integrated=$false;BaseMoved=$false;CanonicalSha=''}
    }

    $ancestor=Invoke-ChatGitCapture -Repo $workspace -Arguments @('merge-base','--is-ancestor',$baseSha,'HEAD')
    if ($ancestor.ExitCode -ne 0) {
        return [pscustomobject]@{Safe=$false;Reason='BASE_INCORRECT';OwnCommits=-1;Integrated=$false;BaseMoved=$false;CanonicalSha=''}
    }

    $count=Invoke-ChatGitCapture -Repo $workspace -Arguments @('rev-list','--count',"$baseSha..HEAD")
    if ($count.ExitCode -ne 0 -or -not $count.First) {
        return [pscustomobject]@{Safe=$false;Reason='BASE_INCORRECT';OwnCommits=-1;Integrated=$false;BaseMoved=$false;CanonicalSha=''}
    }
    $own=[int]([string]$count.First).Trim()

    $baseMoved=$false
    if ($baseRef -and $baseRef -ne 'HEAD') {
        $refNow=Invoke-ChatGitCapture -Repo $originRepo -Arguments @('rev-parse',"$baseRef^{commit}")
        if ($refNow.ExitCode -ne 0 -or -not $refNow.First) {
            $baseMoved=$true
        } else {
            $baseMoved=(([string]$refNow.First).Trim().ToLowerInvariant() -ne $baseSha.ToLowerInvariant())
        }
    }

    if ($own -eq 0) {
        return [pscustomobject]@{Safe=$true;Reason='NO_OWN_COMMITS';OwnCommits=0;Integrated=$true;BaseMoved=$baseMoved;CanonicalSha=''}
    }

    if (-not $canonicalRef) {
        return [pscustomobject]@{Safe=$false;Reason='CANONICAL_REF_MISSING';OwnCommits=$own;Integrated=$false;BaseMoved=$baseMoved;CanonicalSha=''}
    }

    $canonical=Invoke-ChatGitCapture -Repo $originRepo -Arguments @('rev-parse',"$canonicalRef^{commit}")
    if ($canonical.ExitCode -ne 0 -or -not $canonical.First) {
        return [pscustomobject]@{Safe=$false;Reason='CANONICAL_REF_UNRESOLVED';OwnCommits=$own;Integrated=$false;BaseMoved=$baseMoved;CanonicalSha=''}
    }
    $canonicalSha=([string]$canonical.First).Trim().ToLowerInvariant()
    $head=Invoke-ChatGitCapture -Repo $workspace -Arguments @('rev-parse','HEAD^{commit}')
    if ($head.ExitCode -ne 0 -or -not $head.First) {
        return [pscustomobject]@{Safe=$false;Reason='FOREIGN_WORKTREE_STATE';OwnCommits=$own;Integrated=$false;BaseMoved=$baseMoved;CanonicalSha=$canonicalSha}
    }
    $headSha=([string]$head.First).Trim().ToLowerInvariant()
    $integratedCheck=Invoke-ChatGitCapture -Repo $originRepo -Arguments @('merge-base','--is-ancestor',$headSha,$canonicalRef)
    $integrated=($integratedCheck.ExitCode -eq 0)

    return [pscustomobject]@{
        Safe=$integrated
        Reason=if($integrated){'INTEGRATED'}else{'UNMERGED_COMMITS'}
        OwnCommits=$own
        Integrated=$integrated
        BaseMoved=$baseMoved
        CanonicalSha=$canonicalSha
    }
}

function Get-ChatLeasePath {
    param([Parameter(Mandatory)][string]$LeaseId)
    Initialize-HardeningState
    $safe=($LeaseId -replace '[^a-zA-Z0-9._-]','_')
    return Join-Path $script:LeaseRoot "$safe.json"
}

function Get-ChatLeases {
    [CmdletBinding()]
    param(
        [string]$SessionId,
        [switch]$IncludeReleased
    )
    Initialize-HardeningState
    $items=@()
    $safeSession=if($SessionId){($SessionId -replace '[^a-zA-Z0-9._-]','_')}else{''}
    foreach($file in Get-ChildItem -LiteralPath $script:LeaseRoot -Filter '*.json' -File -ErrorAction SilentlyContinue){
        $lease=Read-ChatJson $file.FullName
        if (-not $lease) {
            if ($SessionId -and $file.BaseName -like "*$safeSession*") {
                $items+=[pscustomobject]@{
                    id=$file.BaseName
                    sessionId=$SessionId
                    state='UNKNOWN'
                    unreadable=$true
                }
            }
            continue
        }
        if ($SessionId -and [string](Get-ChatProp $lease 'sessionId' '') -ne $SessionId) { continue }
        if (-not $IncludeReleased -and [string](Get-ChatProp $lease 'state' '') -eq 'RELEASED') { continue }
        $items+=$lease
    }
    return $items
}

function Get-SessionLeaseState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session
    )

    $sessionId=[string](Get-ChatProp $Session 'id' '')
    if (-not $sessionId) {
        return [pscustomobject]@{State='NONE';Protective=$false;Leases=@()}
    }

    $leases=@(Get-ChatLeases -SessionId $sessionId)
    if (-not $leases.Count) {
        return [pscustomobject]@{State='NONE';Protective=$false;Leases=@()}
    }

    $state='ACTIVE'
    foreach($lease in $leases){
        $leaseRecordState=[string](Get-ChatProp $lease 'state' '')
        if ([bool](Get-ChatProp $lease 'unreadable' $false) -or $leaseRecordState -notin @('ACTIVE','RELEASED')) {
            $state='UNKNOWN'
            break
        }

        $mismatch=$false
        foreach($pair in @(
            @('workspace','workspace'),
            @('originRepo','originRepo'),
            @('baseSha','baseSha')
        )){
            $leaseValue=[string](Get-ChatProp $lease $pair[0] '')
            $sessionValue=[string](Get-ChatProp $Session $pair[1] '')
            if ($sessionValue -and -not $leaseValue) {
                $mismatch=$true
            } elseif ($leaseValue -and $sessionValue) {
                if ($pair[0] -in @('workspace','originRepo')) {
                    if (-not (Test-ChatPathEqual $leaseValue $sessionValue)) {$mismatch=$true}
                } elseif (-not [string]::Equals($leaseValue,$sessionValue,[StringComparison]::OrdinalIgnoreCase)) {
                    $mismatch=$true
                }
            }
        }
        if ($mismatch) {$state='MISMATCH';break}

        $expires=[string](Get-ChatProp $lease 'expiresAt' '')
        if ($expires) {
            try {
                if ([DateTimeOffset]::Parse($expires) -lt [DateTimeOffset]::UtcNow -and $state -ne 'MISMATCH') {
                    $state='STALE'
                }
            } catch {
                $state='MISMATCH'
                break
            }
        }
    }

    return [pscustomobject]@{
        State=$state
        Protective=($state -ne 'NONE')
        Leases=$leases
    }
}

function Test-SessionProtectedByLease {
    param($Session)
    if (-not $Session) { return $false }
    return [bool](Get-SessionLeaseState -Session $Session).Protective
}

function New-ChatLease {
    [CmdletBinding()]
    param(
        [string]$SessionId=$env:CHATGPT_SESSION_ID,
        [string]$Owner='external',
        [int]$TtlMinutes=0,
        [string[]]$Resources=@()
    )

    if (-not $SessionId) { throw 'A managed SessionId is required.' }
    $session=Get-ManagedChatSession -Id $SessionId
    if (-not $session) { throw "Managed session '$SessionId' was not found." }
    if ($TtlMinutes -le 0) {$TtlMinutes=[int](Get-ChatProp (Get-ChatConfig) 'defaultLeaseTtlMinutes' 60)}
    if ($TtlMinutes -lt 1) { throw 'TtlMinutes must be at least 1.' }

    $leaseId='lease-'+$SessionId+'-'+[guid]::NewGuid().ToString('N')
    $acquired=@()
    try {
        foreach($resource in @($Resources | Where-Object {$_} | Select-Object -Unique)){
            if (-not (Acquire-ChatResource -Resource $resource -SessionId $SessionId -LeaseId $leaseId)) {
                throw "Could not acquire resource '$resource' for lease."
            }
            $lock=Get-ChatResourceLock -Resource $resource
            if ($lock -and [string](Get-ChatProp $lock 'leaseId' '') -eq $leaseId) {
                $acquired+=$resource
            }
        }

        $now=[DateTimeOffset]::UtcNow
        $lease=[ordered]@{
            schemaVersion=1
            id=$leaseId
            state='ACTIVE'
            sessionId=$SessionId
            owner=$Owner
            ownerPid=$PID
            workspace=[string](Get-ChatProp $session 'workspace' '')
            originRepo=[string](Get-ChatProp $session 'originRepo' '')
            baseRef=[string](Get-ChatProp $session 'baseRef' '')
            baseSha=[string](Get-ChatProp $session 'baseSha' '')
            canonicalRef=[string](Get-ChatProp $session 'canonicalRef' '')
            resources=@($Resources | Where-Object {$_} | Select-Object -Unique)
            ownedResources=$acquired
            createdAt=$now.ToString('o')
            renewedAt=$now.ToString('o')
            expiresAt=$now.AddMinutes($TtlMinutes).ToString('o')
        }
        Write-ChatJson (Get-ChatLeasePath $leaseId) $lease
        return [pscustomobject]$lease
    } catch {
        foreach($resource in $acquired){Release-ChatResource -Resource $resource -SessionId $SessionId -LeaseId $leaseId}
        throw
    }
}

function Update-ChatLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LeaseId,
        [int]$TtlMinutes=0
    )
    if ($TtlMinutes -le 0) {$TtlMinutes=[int](Get-ChatProp (Get-ChatConfig) 'defaultLeaseTtlMinutes' 60)}
    $path=Get-ChatLeasePath $LeaseId
    $lease=Read-ChatJson $path
    if (-not $lease) { throw "Lease '$LeaseId' was not found." }
    if ([string](Get-ChatProp $lease 'state' '') -ne 'ACTIVE') { throw "Lease '$LeaseId' is not ACTIVE." }
    $now=[DateTimeOffset]::UtcNow
    $lease.renewedAt=$now.ToString('o')
    $lease.expiresAt=$now.AddMinutes($TtlMinutes).ToString('o')
    Write-ChatJson $path $lease
    return $lease
}

function Close-ChatLease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LeaseId)

    $path=Get-ChatLeasePath $LeaseId
    $lease=Read-ChatJson $path
    if (-not $lease) { return $false }

    $sessionId=[string](Get-ChatProp $lease 'sessionId' '')
    foreach($resource in @(Get-ChatProp $lease 'ownedResources' @())){
        Release-ChatResource -Resource ([string]$resource) -SessionId $sessionId -LeaseId $LeaseId
    }

    $lease.state='RELEASED'
    $lease | Add-Member -NotePropertyName releasedAt -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
    Write-ChatJson $path $lease

    $session=Get-ManagedChatSession -Id $sessionId
    if ($session -and -not (Test-SessionProtectedByLease $session)) {
        $ownerPid=[int](Get-ChatProp $session 'pid' 0)
        if ($ownerPid -le 0 -or -not (Test-ChatProcessAlive $ownerPid)) {
            $session | Add-Member -NotePropertyName active -NotePropertyValue $false -Force
            $session | Add-Member -NotePropertyName status -NotePropertyValue 'ENDED_EXTERNAL' -Force
            $session | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
            Release-SessionReservations $session -Force | Out-Null
            Write-ChatHistory $session 'LEASE_RELEASED_AFTER_SHELL_EXIT'
            Write-ChatJson (Join-Path $script:SessionRoot "$sessionId.json") $session
        }
    }
    return $true
}

function Invoke-WithChatResources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Resource,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$SessionId=$env:CHATGPT_SESSION_ID
    )
    $acquired=@()
    try{
        foreach($name in @($Resource | Where-Object {$_} | Select-Object -Unique)){
            if (-not (Acquire-ChatResource -Resource $name -SessionId $SessionId)) {
                throw "Resource '$name' is already in use."
            }
            $acquired+=$name
        }
        return & $ScriptBlock
    } finally {
        foreach($name in $acquired){Release-ChatResource -Resource $name -SessionId $SessionId}
    }
}

function Invoke-WithChatResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Resource,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$SessionId=$env:CHATGPT_SESSION_ID
    )
    return Invoke-WithChatResources -Resource @($Resource) -ScriptBlock $ScriptBlock -SessionId $SessionId
}

function Invoke-WithChatLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$SessionId=$env:CHATGPT_SESSION_ID,
        [string]$Owner='external',
        [int]$TtlMinutes=0,
        [string[]]$Resources=@()
    )
    $lease=New-ChatLease -SessionId $SessionId -Owner $Owner -TtlMinutes $TtlMinutes -Resources $Resources
    try {
        return & $ScriptBlock $lease
    } finally {
        Close-ChatLease -LeaseId $lease.id | Out-Null
    }
}

function Resolve-AndroidCommandResources {
    param([Parameter(Mandatory)][string]$Line)

    $resources=@()
    $isAndroid=($Line -match '(?i)(^|[ ;|&])(adb|fastboot|scrcpy|emulator)(\.exe)?\b|gradlew.*(install|connectedandroidtest)|install.*\.apk')
    if (-not $isAndroid) { return @() }

    $isFastboot=($Line -match '(?i)(^|[ ;|&])fastboot(\.exe)?\b')
    $serial=$null
    $serialMatch=[regex]::Match($Line,'(?i)(?:^|\s)(?:-s|--serial)(?:\s+|=)["'']?([^"''\s]+)')
    if ($serialMatch.Success) {$serial=$serialMatch.Groups[1].Value}
    elseif (-not $isFastboot -and $env:ANDROID_SERIAL) {$serial=$env:ANDROID_SERIAL}

    $avd=$null
    $avdMatch=[regex]::Match($Line,'(?i)(?:^|[ ;|&])emulator(?:\.exe)?\s+(?:-avd\s+|@)(["'']?)([A-Za-z0-9._-]+)\1')
    if ($avdMatch.Success) {$avd=$avdMatch.Groups[2].Value}

    if ($avd) {$resources+="android:avd:$($avd.ToLowerInvariant())"}
    if ($serial) {
        $resources+="android:serial:$($serial.ToLowerInvariant())"
    } elseif ($isFastboot) {
        $resources+='android:fastboot-default'
    } elseif ($Line -match '(?i)(^|[ ;|&])(adb|scrcpy)(\.exe)?\b|gradlew.*(install|connectedandroidtest)|install.*\.apk') {
        try{
            $deviceOutput=@(& adb devices 2>$null)
            $deviceExit=$LASTEXITCODE
            $deviceLines=@($deviceOutput | Select-Object -Skip 1 | Where-Object {$_ -match '\sdevice$'})
            if ($deviceExit -eq 0 -and $deviceLines.Count -eq 1) {
                $detected=($deviceLines[0] -split '\s+')[0]
                if ($detected) {$resources+="android:serial:$($detected.ToLowerInvariant())"}
            } else {
                $resources+='android:adb-default'
            }
        } catch {
            $resources+='android:adb-default'
        }
    }
    return @($resources | Select-Object -Unique)
}

function Resolve-ChatCommandResources {
    param([Parameter(Mandatory)][string]$Line)

    $resources=@(Resolve-AndroidCommandResources -Line $Line)
    $cfg=Get-ChatConfig
    foreach($rule in @($cfg.resourceRules)){
        $name=[string](Get-ChatProp $rule 'name' '')
        $pattern=[string](Get-ChatProp $rule 'pattern' '')
        if (-not $name -or -not $pattern) { continue }
        if ($name -in @('adb-thor','android-emulator')) { continue }
        if ($Line -match $pattern) {$resources+=$name}
    }
    return @($resources | Select-Object -Unique)
}

function Get-HardenedWorktreeCleanupCandidateState {
    param([Parameter(Mandatory)]$Session)

    $lease=Get-SessionLeaseState -Session $Session
    if ($lease.Protective) {
        return [pscustomobject]@{
            id=[string](Get-ChatProp $Session 'id' '')
            project=[string](Get-ChatProp $Session 'project' '')
            workspace=[string](Get-ChatProp $Session 'workspace' '')
            originRepo=[string](Get-ChatProp $Session 'originRepo' '')
            branch=[string](Get-ChatProp $Session 'branch' '')
            workspaceKind=[string](Get-ChatProp $Session 'workspaceKind' '')
            baseRef=[string](Get-ChatProp $Session 'baseRef' '')
            baseSha=[string](Get-ChatProp $Session 'baseSha' '')
            canonicalRef=[string](Get-ChatProp $Session 'canonicalRef' '')
            safe=$false
            reason="LEASE_$($lease.State)"
            leaseState=$lease.State
            git=$null
            commitSafety=$null
        }
    }

    $identity=Get-ManagedWorktreeIdentity -Session $Session
    if (-not $identity.Valid) {
        return [pscustomobject]@{
            id=[string](Get-ChatProp $Session 'id' '')
            project=[string](Get-ChatProp $Session 'project' '')
            workspace=[string](Get-ChatProp $Session 'workspace' '')
            originRepo=[string](Get-ChatProp $Session 'originRepo' '')
            branch=[string](Get-ChatProp $Session 'branch' '')
            workspaceKind=[string](Get-ChatProp $Session 'workspaceKind' '')
            baseRef=[string](Get-ChatProp $Session 'baseRef' '')
            baseSha=[string](Get-ChatProp $Session 'baseSha' '')
            canonicalRef=[string](Get-ChatProp $Session 'canonicalRef' '')
            safe=$false
            reason=$identity.Reason
            leaseState='NONE'
            git=$null
            commitSafety=$null
        }
    }

    $git=Get-ChatGitSummary $Session
    if (-not $git.hasGit) {$reason='NOT_A_WORKTREE'}
    elseif ($git.dirty) {$reason='DIRTY'}
    else {$reason=''}

    if ($reason) {
        return [pscustomobject]@{
            id=[string](Get-ChatProp $Session 'id' '')
            project=[string](Get-ChatProp $Session 'project' '')
            workspace=[string](Get-ChatProp $Session 'workspace' '')
            originRepo=[string](Get-ChatProp $Session 'originRepo' '')
            branch=[string](Get-ChatProp $Session 'branch' '')
            workspaceKind=[string](Get-ChatProp $Session 'workspaceKind' '')
            baseRef=[string](Get-ChatProp $Session 'baseRef' '')
            baseSha=[string](Get-ChatProp $Session 'baseSha' '')
            canonicalRef=[string](Get-ChatProp $Session 'canonicalRef' '')
            safe=$false
            reason=$reason
            leaseState='NONE'
            git=$git
            commitSafety=$null
        }
    }

    $commitSafety=Get-ManagedCommitSafety -Session $Session
    return [pscustomobject]@{
        id=[string](Get-ChatProp $Session 'id' '')
        project=[string](Get-ChatProp $Session 'project' '')
        workspace=[string](Get-ChatProp $Session 'workspace' '')
        originRepo=[string](Get-ChatProp $Session 'originRepo' '')
        branch=[string](Get-ChatProp $Session 'branch' '')
        workspaceKind=[string](Get-ChatProp $Session 'workspaceKind' '')
        baseRef=[string](Get-ChatProp $Session 'baseRef' '')
        baseSha=[string](Get-ChatProp $Session 'baseSha' '')
        canonicalRef=[string](Get-ChatProp $Session 'canonicalRef' '')
        safe=[bool]$commitSafety.Safe
        reason=if($commitSafety.Safe){'SAFE'}else{$commitSafety.Reason}
        leaseState='NONE'
        git=$git
        commitSafety=$commitSafety
    }
}

function Test-ManagedChatSessionInvariant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$ExpectedWorkspace,
        [string]$ExpectedBaseSha,
        [switch]$RequireLease
    )

    $session=Get-ManagedChatSession -Id $SessionId
    if (-not $session) {
        return [pscustomobject]@{Valid=$false;Codes=@('SESSION_MISSING');SessionId=$SessionId}
    }

    $codes=@()
    if ($ExpectedWorkspace -and -not (Test-ChatPathEqual $ExpectedWorkspace ([string](Get-ChatProp $session 'workspace' '')))) {
        $codes+='WORKSPACE_MISMATCH'
    }

    $identity=Get-ManagedWorktreeIdentity -Session $session
    if (-not $identity.Valid) {$codes+=$identity.Reason}

    $actualBase=[string](Get-ChatProp $session 'baseSha' '')
    if ($ExpectedBaseSha -and -not [string]::Equals($ExpectedBaseSha,$actualBase,[StringComparison]::OrdinalIgnoreCase)) {
        $codes+='BASE_INCORRECT'
    }

    $commit=Get-ManagedCommitSafety -Session $session
    if ($commit.Reason -in @('BASE_UNKNOWN','BASE_INCORRECT')) {$codes+=$commit.Reason}
    if ($commit.BaseMoved) {$codes+='BASE_MOVED'}

    $lease=Get-SessionLeaseState -Session $session
    if ($RequireLease) {
        if ($lease.State -eq 'NONE') {$codes+='LEASE_MISSING'}
        elseif ($lease.State -eq 'STALE') {$codes+='LEASE_STALE'}
        elseif ($lease.State -eq 'MISMATCH') {$codes+='LEASE_MISMATCH'}
        elseif ($lease.State -eq 'UNKNOWN') {$codes+='LEASE_UNKNOWN'}
    } elseif ($lease.State -eq 'STALE') {
        $codes+='LEASE_STALE'
    } elseif ($lease.State -eq 'MISMATCH') {
        $codes+='LEASE_MISMATCH'
    } elseif ($lease.State -eq 'UNKNOWN') {
        $codes+='LEASE_UNKNOWN'
    }

    $codes=@($codes | Select-Object -Unique)
    return [pscustomobject]@{
        Valid=($codes.Count -eq 0)
        Codes=$codes
        SessionId=$SessionId
        Workspace=[string](Get-ChatProp $session 'workspace' '')
        BaseRef=[string](Get-ChatProp $session 'baseRef' '')
        BaseSha=$actualBase
        CanonicalRef=[string](Get-ChatProp $session 'canonicalRef' '')
        LeaseState=$lease.State
        WorktreeIdentity=$identity
        CommitSafety=$commit
    }
}


function Test-ChatResourceIdentityConflict {
    param(
        [Parameter(Mandatory)][string]$Requested,
        [Parameter(Mandatory)][string]$Existing
    )

    $requestedKey=$Requested.ToLowerInvariant()
    $existingKey=$Existing.ToLowerInvariant()
    if ($requestedKey -eq $existingKey) { return $true }

    $requestedIsDefault=$requestedKey -in @('android:adb-default','android:fastboot-default')
    $existingIsDefault=$existingKey -in @('android:adb-default','android:fastboot-default')
    $requestedIsSerial=$requestedKey.StartsWith('android:serial:')
    $existingIsSerial=$existingKey.StartsWith('android:serial:')

    return (($requestedIsDefault -and $existingIsSerial) -or ($existingIsDefault -and $requestedIsSerial))
}
