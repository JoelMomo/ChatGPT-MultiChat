$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$errors=@()
Import-Module (Join-Path $root 'ChatMulti.psm1') -Force -DisableNameChecking
$chatModule=Get-Module ChatMulti
if($chatModule){
    # Keep the test independent of how many production chat slots are currently occupied.
    # This changes only this test process's module cache; config.json is never modified.
    & $chatModule {
        $testConfig=Get-ChatConfig
        if([int]$testConfig.maxSlots -lt 32){$testConfig.maxSlots=32}
        $script:ChatConfigCache=$testConfig
    }
}

function Add-Failure([string]$Message){$script:errors+=$Message}
function Assert-True($Condition,[string]$Message){if(-not $Condition){Add-Failure $Message}}
function Write-TestJson([string]$Path,$Value){
    [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
}

$token=[guid]::NewGuid().ToString('N').Substring(0,8)
$testRoot=Join-Path $root ("state\hardening-selftest-$token")
$sessionRoot=Join-Path $root 'state\sessions'
$slotRoot=Join-Path $root 'state\slots'
$leaseRoot=Join-Path $root 'state\leases'
$projectsPath=Join-Path $root 'state\projects.json'
$projectsBackup=if(Test-Path $projectsPath){[IO.File]::ReadAllText($projectsPath)}else{$null}
$projectsExisted=Test-Path $projectsPath
$createdSessionIds=@()
$createdResources=@()
$managed=$null

try{
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    New-Item -ItemType Directory -Path $sessionRoot -Force|Out-Null

    # Dynamic Android identities: same real identity collides, distinct identities do not.
    $thor=@(Resolve-ChatCommandResources -Line 'adb -s THOR-123 shell getprop')
    $other=@(Resolve-ChatCommandResources -Line 'adb -s EMU-5554 shell getprop')
    $equalsSerial=@(Resolve-ChatCommandResources -Line 'adb --serial=USB-777 shell getprop')
    $avd=@(Resolve-ChatCommandResources -Line 'emulator -avd Pixel_Test')
    Assert-True ($thor -contains 'android:serial:thor-123') 'Explicit Android serial was not resolved to a serial-scoped resource.'
    Assert-True ($other -contains 'android:serial:emu-5554') 'Second Android serial was not resolved independently.'
    Assert-True ($equalsSerial -contains 'android:serial:usb-777') '--serial=<value> was not resolved to a serial-scoped resource.'
    Assert-True ($avd -contains 'android:avd:pixel_test') 'AVD name was not resolved to an AVD-scoped resource.'

    $sessionAId="hardening-a-$token"
    $sessionBId="hardening-b-$token"
    $fakeA=[ordered]@{
        id=$sessionAId;slot=71;project='hardening-a';pid=$PID;active=$true;status='READY'
        workspace=$root;originRepo=$root;baseRef='HEAD';baseSha='';canonicalRef=''
    }
    $fakeB=[ordered]@{
        id=$sessionBId;slot=72;project='hardening-b';pid=$PID;active=$true;status='READY'
        workspace=$root;originRepo=$root;baseRef='HEAD';baseSha='';canonicalRef=''
    }
    Write-TestJson (Join-Path $sessionRoot "$sessionAId.json") $fakeA
    Write-TestJson (Join-Path $sessionRoot "$sessionBId.json") $fakeB
    $createdSessionIds+=@($sessionAId,$sessionBId)

    $same='android:serial:hardening-same'
    $different='android:serial:hardening-other'
    Assert-True (Acquire-ChatResource -Resource $same -SessionId $sessionAId) 'First session could not acquire a serial-scoped resource.'
    $createdResources+=$same
    Assert-True (-not (Acquire-ChatResource -Resource $same -SessionId $sessionBId)) 'Same serial was not blocked across sessions.'
    Assert-True (Acquire-ChatResource -Resource $different -SessionId $sessionBId) 'Different serial was incorrectly blocked.'
    $createdResources+=$different
    Release-ChatResource -Resource $same -SessionId $sessionAId
    Release-ChatResource -Resource $different -SessionId $sessionBId

    $thorCoexist='android:serial:thor-coexist'
    $avdOne='android:avd:pixel-one'
    $avdTwo='android:avd:pixel-two'
    Assert-True (Acquire-ChatResource -Resource $thorCoexist -SessionId $sessionAId) 'Thor serial resource could not be acquired for coexistence test.'
    Assert-True (Acquire-ChatResource -Resource $avdOne -SessionId $sessionBId) 'Thor + AVD were incorrectly treated as conflicting resources.'
    Release-ChatResource -Resource $thorCoexist -SessionId $sessionAId
    Assert-True (Acquire-ChatResource -Resource $avdTwo -SessionId $sessionAId) 'Second distinct AVD could not be acquired concurrently.'
    Assert-True (-not (Acquire-ChatResource -Resource $avdOne -SessionId $sessionAId)) 'Same AVD identity was not blocked across sessions.'
    Release-ChatResource -Resource $avdOne -SessionId $sessionBId
    Release-ChatResource -Resource $avdTwo -SessionId $sessionAId

    $ambiguous='android:adb-default'
    $specific='android:serial:ambiguous-target'
    Assert-True (Acquire-ChatResource -Resource $ambiguous -SessionId $sessionAId) 'Ambiguous ADB resource could not be acquired.'
    Assert-True (-not (Acquire-ChatResource -Resource $specific -SessionId $sessionBId)) 'Serial-specific operation was not blocked by an ambiguous ADB lock.'
    Release-ChatResource -Resource $ambiguous -SessionId $sessionAId
    Assert-True (Acquire-ChatResource -Resource $specific -SessionId $sessionBId) 'Specific serial resource could not be acquired after ambiguous lock release.'
    Assert-True (-not (Acquire-ChatResource -Resource $ambiguous -SessionId $sessionAId)) 'Ambiguous ADB operation was not blocked by an existing serial lock.'
    Release-ChatResource -Resource $specific -SessionId $sessionBId

    $wrapperResource='android:serial:wrapper-hold'
    $heldInside=$false
    Invoke-WithChatResource -Resource $wrapperResource -SessionId $sessionAId -ScriptBlock {
        $lock=Get-ChatResourceLock -Resource $wrapperResource
        $script:heldInside=($null -ne $lock -and [string]$lock.sessionId -eq $sessionAId)
    } | Out-Null
    Assert-True $heldInside 'Resource wrapper did not hold the lock for the full operation.'
    Assert-True ($null -eq (Get-ChatResourceLock -Resource $wrapperResource)) 'Resource wrapper did not release the lock after the operation.'

    $externalResource="hardening:external-wrapper:$token"
    $externalArgs=@(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',(Join-Path $root 'Invoke-ManagedExternal.ps1'),
        '-SessionId',$sessionAId,
        '-Owner','hardening-wrapper-test',
        '-Resource',$externalResource,
        '-FilePath','whoami.exe'
    )
    $externalProcess=Start-Process powershell.exe -ArgumentList $externalArgs -WindowStyle Hidden -PassThru -Wait
    Assert-True ($externalProcess.ExitCode -eq 0) 'Invoke-ManagedExternal.ps1 did not return the external process exit code.'
    Assert-True ($null -eq (Get-ChatResourceLock -Resource $externalResource)) 'External wrapper left its resource lock behind.'
    $externalLeases=@(Get-ChatLeases -SessionId $sessionAId -IncludeReleased|Where-Object{[string]$_.owner -eq 'hardening-wrapper-test'})
    Assert-True ($externalLeases.Count -eq 1 -and [string]$externalLeases[0].state -eq 'RELEASED') 'External wrapper did not close its lease cleanly.'

    # Build an isolated Git fixture with two commits.
    $repo=Join-Path $testRoot 'repo'
    New-Item -ItemType Directory -Path $repo -Force|Out-Null
    & git -C $repo init -q
    & git -C $repo config user.email 'hardening@local'
    & git -C $repo config user.name 'MultiChat Hardening Test'
    Set-Content (Join-Path $repo 'probe.txt') 'A' -Encoding ascii
    & git -C $repo add probe.txt
    & git -C $repo commit -qm 'A'
    & git -C $repo branch -M main
    $shaA=([string](& git -C $repo rev-parse HEAD)).Trim().ToLowerInvariant()
    Set-Content (Join-Path $repo 'probe.txt') 'B' -Encoding ascii
    & git -C $repo commit -qam 'B'
    $shaB=([string](& git -C $repo rev-parse HEAD)).Trim().ToLowerInvariant()
    & git -C $repo branch base-a $shaA

    $mismatchBlocked=$false
    try{Resolve-ExactGitBase -Repo $repo -BaseRef 'main' -BaseSha $shaA|Out-Null}
    catch{$mismatchBlocked=$true}
    Assert-True $mismatchBlocked 'Exact base mismatch did not fail closed.'

    $exact=Resolve-ExactGitBase -Repo $repo -BaseRef 'base-a' -BaseSha $shaA
    Assert-True ($exact.BaseSha -eq $shaA -and $exact.ExactRequested) 'Exact base resolution did not preserve the requested SHA.'

    # High-level session creation must create the worktree at the exact SHA.
    $managed=New-ManagedChatSession -ProjectPath $repo -Task "hardening-$token" -BaseRef 'base-a' -BaseSha $shaA -CanonicalRef 'main'
    $createdSessionIds+=$managed.id
    $managedHead=([string](& git -C $managed.workspace rev-parse HEAD)).Trim().ToLowerInvariant()
    Assert-True ($managedHead -eq $shaA) 'Managed worktree was not created at the requested exact SHA.'
    Assert-True ([string]$managed.baseSha -eq $shaA) 'Session state did not persist baseSha.'

    $withoutLease=Test-ManagedChatSessionInvariant -SessionId $managed.id -ExpectedWorkspace $managed.workspace -ExpectedBaseSha $shaA -RequireLease
    Assert-True (-not $withoutLease.Valid -and $withoutLease.Codes -contains 'LEASE_MISSING') 'Validator did not report LEASE_MISSING.'

    # ACTIVE lease must veto expiry, reservation release, resource release, and cleanup.
    $leaseResource="hardening:lease-resource:$token"
    $lease=New-ChatLease -SessionId $managed.id -Owner 'hardening-test' -TtlMinutes 5 -Resources @($leaseResource)
    $withLease=Test-ManagedChatSessionInvariant -SessionId $managed.id -ExpectedWorkspace $managed.workspace -ExpectedBaseSha $shaA -RequireLease
    Assert-True ($withLease.Valid -and $withLease.LeaseState -eq 'ACTIVE') 'ACTIVE lease was not accepted by the validator.'
    Assert-True ($null -ne (Get-ChatResourceLock -Resource $leaseResource)) 'Lease-owned resource lock was not retained.'

    $validatorArgs=@(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',(Join-Path $root 'Validate-ManagedSession.ps1'),
        '-SessionId',$managed.id,
        '-ExpectedWorkspace',$managed.workspace,
        '-ExpectedBaseSha',$shaA,
        '-RequireLease'
    )
    $validatorProcess=Start-Process powershell.exe -ArgumentList $validatorArgs -WindowStyle Hidden -PassThru -Wait
    Assert-True ($validatorProcess.ExitCode -eq 0) 'Validate-ManagedSession.ps1 rejected a valid exact-base leased session.'

    $sessionPath=Join-Path $sessionRoot "$($managed.id).json"
    $aged=Get-Content $sessionPath -Raw|ConvertFrom-Json
    $aged.updatedAt=(Get-Date).AddHours(-2).ToString('o')
    $aged.status='READY'
    Write-TestJson $sessionPath $aged
    $expired=@(Expire-IdleManagedChatSessions -IdleMinutes 1 -SessionId $managed.id)
    Assert-True (-not ($expired|Where-Object{$_.id -eq $managed.id})) 'ACTIVE lease did not veto session expiry.'

    $cleanupProbe=[pscustomobject]@{
        id=$managed.id;project=$managed.project;workspace=$managed.workspace;originRepo=$managed.originRepo
        branch=$managed.branch;baseRef=$managed.baseRef;baseSha=$managed.baseSha;canonicalRef=$managed.canonicalRef
        safe=$true
    }
    $removed=@(Invoke-SafeWorktreeCleanup -Candidates @($cleanupProbe))
    Assert-True ($removed.Count -eq 0 -and (Test-Path $managed.workspace)) 'ACTIVE lease did not veto worktree cleanup.'

    # A stale lease remains protective and must never trigger deletion.
    $leasePath=Join-Path $leaseRoot "$($lease.id).json"
    $stale=Get-Content $leasePath -Raw|ConvertFrom-Json
    $stale.expiresAt=[DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')
    Write-TestJson $leasePath $stale
    $leaseState=Get-SessionLeaseState -Session (Get-ManagedChatSession -Id $managed.id)
    Assert-True ($leaseState.State -eq 'STALE' -and $leaseState.Protective) 'Expired lease was not classified as protective STALE.'
    $removed=@(Invoke-SafeWorktreeCleanup -Candidates @($cleanupProbe))
    Assert-True ($removed.Count -eq 0 -and (Test-Path $managed.workspace)) 'STALE lease allowed automatic cleanup.'

    Update-ChatLease -LeaseId $lease.id -TtlMinutes 5|Out-Null

    # Stop must preserve slot/port while an external lease is ACTIVE.
    Stop-ManagedChatSession
    $afterStop=Get-ManagedChatSession -Id $managed.id
    $slotFile=Join-Path $slotRoot ("slot-{0}.json" -f $managed.slot)
    Assert-True ($afterStop.active -and $afterStop.status -eq 'LEASED_EXTERNAL') 'Shell exit did not leave the leased session active.'
    Assert-True (Test-Path $slotFile) 'ACTIVE lease did not preserve the slot reservation.'
    Assert-True (@(Get-ChatPortReservations|Where-Object{[string]$_.sessionId -eq $managed.id}).Count -eq 1) 'ACTIVE lease did not preserve the port reservation.'

    Close-ChatLease -LeaseId $lease.id|Out-Null
    Assert-True ($null -eq (Get-ChatResourceLock -Resource $leaseResource)) 'Lease-owned resource lock remained after lease close.'
    Stop-ManagedChatSession
    Set-Location -LiteralPath $root
    Assert-True (-not (Test-Path $slotFile)) 'Slot was not released after the lease closed.'

    # Moving the declared BaseRef is detectable even though baseSha remains immutable.
    & git -C $repo branch -f base-a $shaB
    $baseMoved=Test-ManagedChatSessionInvariant -SessionId $managed.id -ExpectedWorkspace $managed.workspace -ExpectedBaseSha $shaA
    Assert-True ($baseMoved.Codes -contains 'BASE_MOVED') 'Validator did not report BASE_MOVED.'
    & git -C $repo branch -f base-a $shaA

    # No own commits relative to baseSha is sufficient for SAFE cleanup.
    $removed=@(Invoke-SafeWorktreeCleanup -Candidates @($cleanupProbe))
    Assert-True ($removed.Count -eq 1 -and -not (Test-Path $managed.workspace)) 'Clean worktree with no own commits was not safely removed.'

    # High-level mismatch must fail before creating a worktree.
    $sessionCountBefore=@(Get-ChildItem $sessionRoot -Filter '*.json' -File).Count
    $highLevelMismatch=$false
    try{New-ManagedChatSession -ProjectPath $repo -Task 'mismatch' -BaseRef 'main' -BaseSha $shaA|Out-Null}
    catch{$highLevelMismatch=$true}
    Assert-True $highLevelMismatch 'New-ManagedChatSession accepted a mismatched BaseRef/BaseSha pair.'
    $sessionCountAfter=@(Get-ChildItem $sessionRoot -Filter '*.json' -File).Count
    Assert-True ($sessionCountAfter -eq $sessionCountBefore) 'Failed exact-base session left a session record behind.'

    # A branch with own commits is KEEP until integration in canonicalRef is demonstrable.
    $integrationWt=Join-Path $testRoot 'integration-worktree'
    & git -C $repo worktree add -q -b integration-probe $integrationWt $shaA
    Set-Content (Join-Path $integrationWt 'feature.txt') 'feature' -Encoding ascii
    & git -C $integrationWt add feature.txt
    & git -C $integrationWt commit -qm 'feature'
    $integrationSession=[pscustomobject]@{
        id="integration-$token";project='fixture';workspace=$integrationWt;originRepo=$repo
        branch='integration-probe';baseRef='base-a';baseSha=$shaA;canonicalRef='main'
        active=$false;isolated=$true;pid=999999
    }
    $pending=@(Get-WorktreeCleanupCandidates -Sessions @($integrationSession))
    Assert-True ($pending.Count -eq 1 -and -not $pending[0].safe -and $pending[0].reason -eq 'UNMERGED_COMMITS') 'Unmerged own commits were not kept.'

    & git -C $repo checkout -q main
    & git -C $repo merge --no-ff -m 'integrate feature' integration-probe | Out-Null
    $integrated=@(Get-WorktreeCleanupCandidates -Sessions @($integrationSession))
    Assert-True ($integrated.Count -eq 1 -and $integrated[0].safe) 'Integrated branch was not classified SAFE.'
    $removed=@(Invoke-SafeWorktreeCleanup -Candidates $integrated)
    Assert-True ($removed.Count -eq 1 -and -not (Test-Path $integrationWt)) 'Integrated SAFE worktree was not removed.'

    # An unreadable lease is UNKNOWN/protective and forces KEEP.
    $corruptWt=Join-Path $testRoot 'corrupt-lease-worktree'
    & git -C $repo worktree add -q -b corrupt-lease-probe $corruptWt $shaB
    $corruptSessionId="lease-corrupt-$token"
    $corruptSession=[ordered]@{
        id=$corruptSessionId;slot=74;project='lease-corrupt';pid=999999;active=$false;isolated=$true
        workspace=$corruptWt;originRepo=$repo;branch='corrupt-lease-probe'
        baseRef='main';baseSha=$shaB;canonicalRef='main'
    }
    Write-TestJson (Join-Path $sessionRoot "$corruptSessionId.json") $corruptSession
    $createdSessionIds+=$corruptSessionId
    $corruptLeasePath=Join-Path $leaseRoot ("lease-$corruptSessionId-corrupt.json")
    [IO.File]::WriteAllText($corruptLeasePath,'{"broken":',(New-Object Text.UTF8Encoding($false)))

    $unknownState=Get-SessionLeaseState -Session (Get-ManagedChatSession -Id $corruptSessionId)
    Assert-True ($unknownState.State -eq 'UNKNOWN' -and $unknownState.Protective) 'Unreadable lease was not classified UNKNOWN/protective.'
    $unknownCandidate=@(Get-WorktreeCleanupCandidates -Sessions @([pscustomobject]$corruptSession))
    Assert-True ($unknownCandidate.Count -eq 1 -and -not $unknownCandidate[0].safe -and $unknownCandidate[0].reason -eq 'LEASE_UNKNOWN') 'Unreadable lease did not force KEEP during cleanup.'
    Assert-True (Test-Path $corruptWt) 'Unreadable lease allowed its worktree to be removed.'
    Remove-Item $corruptLeasePath -Force -ErrorAction SilentlyContinue
    & git -C $repo worktree remove --force $corruptWt 2>$null|Out-Null
    & git -C $repo branch -D corrupt-lease-probe 2>$null|Out-Null

    # Lease snapshot mismatch is protective.
    $mismatchLeaseSession=[ordered]@{
        id="lease-mismatch-$token";slot=73;project='lease-mismatch';pid=999999;active=$false
        workspace=$repo;originRepo=$repo;baseRef='main';baseSha=$shaB;canonicalRef='main'
    }
    $mismatchId=$mismatchLeaseSession.id
    Write-TestJson (Join-Path $sessionRoot "$mismatchId.json") $mismatchLeaseSession
    $createdSessionIds+=$mismatchId
    $leaseId="lease-mismatch-$token"
    $leaseFixture=[ordered]@{
        schemaVersion=1;id=$leaseId;state='ACTIVE';sessionId=$mismatchId;owner='fixture';ownerPid=999999
        workspace=(Join-Path $repo 'wrong');originRepo=$repo;baseRef='main';baseSha=$shaB;canonicalRef='main'
        resources=@();ownedResources=@();createdAt=[DateTimeOffset]::UtcNow.ToString('o')
        renewedAt=[DateTimeOffset]::UtcNow.ToString('o');expiresAt=[DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o')
    }
    Write-TestJson (Join-Path $leaseRoot "$leaseId.json") $leaseFixture
    $mismatchState=Get-SessionLeaseState -Session (Get-ManagedChatSession -Id $mismatchId)
    Assert-True ($mismatchState.State -eq 'MISMATCH' -and $mismatchState.Protective) 'Lease snapshot mismatch was not fail-closed.'
} catch {
    Add-Failure ("Unexpected exception: "+$_.Exception.Message)
} finally {
    foreach($resource in $createdResources){
        foreach($sid in @($sessionAId,$sessionBId)){
            if($sid){Release-ChatResource -Resource $resource -SessionId $sid}
        }
    }

    foreach($sid in @($createdSessionIds|Select-Object -Unique)){
        if(-not $sid){continue}
        Remove-Item (Join-Path $sessionRoot "$sid.json") -Force -ErrorAction SilentlyContinue
        foreach($slot in Get-ChildItem $slotRoot -Filter 'slot-*.json' -File -ErrorAction SilentlyContinue){
            $state=Get-Content $slot.FullName -Raw -ErrorAction SilentlyContinue|ConvertFrom-Json
            if($state -and [string]$state.sessionId -eq $sid){Remove-Item $slot.FullName -Force -ErrorAction SilentlyContinue}
        }
        foreach($leaseFile in Get-ChildItem $leaseRoot -Filter '*.json' -File -ErrorAction SilentlyContinue){
            $leaseState=Get-Content $leaseFile.FullName -Raw -ErrorAction SilentlyContinue|ConvertFrom-Json
            if($leaseState -and [string]$leaseState.sessionId -eq $sid){Remove-Item $leaseFile.FullName -Force -ErrorAction SilentlyContinue}
        }
    }

    if($projectsExisted){
        [IO.File]::WriteAllText($projectsPath,$projectsBackup,(New-Object Text.UTF8Encoding($false)))
    }else{
        Remove-Item $projectsPath -Force -ErrorAction SilentlyContinue
    }

    if(Test-Path $testRoot){Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

if($errors.Count){
    Write-Host 'HARDENING-TEST: FAIL' -ForegroundColor Red
    $errors|ForEach-Object{Write-Host (' - '+$_) -ForegroundColor Red}
    exit 1
}
Write-Host 'HARDENING-TEST: OK' -ForegroundColor Green
Write-Host 'Dynamic resources, exact base, leases, fail-closed cleanup, and canonical integration: OK.'
