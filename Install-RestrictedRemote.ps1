param(
    [string]$AccountName='MultiChatRemote',
    [string]$InstallRoot=$PSScriptRoot,
    [switch]$DryRun
)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($InstallRoot)
$packageVersion='0.2.51'
$packageIntegrity='sha512-BF/ZV06c7mh+tzfJEkQpjcOg6UaQtzp2vRadIpA9hI+WpPDwkQ2ekdY0fbN7I4xOrCQX6NajyEPouEDXFJc1kA=='
Import-Module (Join-Path $root 'ChatMulti.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'RestrictedRemote.psm1') -Force -DisableNameChecking

function Test-Administrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ReviewedRuntime {
    $npxRoot=Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
    if(-not(Test-Path -LiteralPath $npxRoot)){return $null}
    foreach($manifest in @(Get-ChildItem -LiteralPath $npxRoot -Filter package-lock.json -File -Recurse -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending)){
        try{
            $raw=[IO.File]::ReadAllText($manifest.FullName)
            if(-not $raw.Contains('"node_modules/@wonderwhy-er/desktop-commander"')){continue}
            if(-not $raw.Contains(('"version": "{0}"' -f $packageVersion))){continue}
            if(-not $raw.Contains(('"integrity": "{0}"' -f $packageIntegrity))){continue}
            $runtimeRoot=Split-Path $manifest.FullName -Parent
            $entry=Join-Path $runtimeRoot 'node_modules\@wonderwhy-er\desktop-commander\dist\index.js'
            if(Test-Path -LiteralPath $entry){
                return [pscustomobject]@{Root=$runtimeRoot;EntryPoint=$entry;Lock=$manifest.FullName}
            }
        }catch{}
    }
    return $null
}

function Get-CanonicalProjectRoots {
    $paths=New-Object Collections.Generic.List[string]
    [void]$paths.Add($root)
    $projectsFile=Join-Path $root 'state\projects.json'
    if(Test-Path -LiteralPath $projectsFile){
        try{
            $projectData=Get-Content -LiteralPath $projectsFile -Raw|ConvertFrom-Json
            foreach($project in $projectData){
                $path=[string]$project.path
                if(-not $path){continue}
                if($path -match '[\\/]workspaces[\\/]'){continue}
                if(Test-Path -LiteralPath $path){[void]$paths.Add([IO.Path]::GetFullPath($path))}
            }
        }catch{}
    }
    return @($paths|Sort-Object -Unique)
}
function New-RandomPassword {
    param([int]$Length=48)
    $alphabet='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%_-+='
    $bytes=New-Object byte[] $Length
    $rng=New-Object Security.Cryptography.RNGCryptoServiceProvider
    try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
    $chars=for($i=0;$i -lt $Length;$i++){$alphabet[$bytes[$i] % $alphabet.Length]}
    -join $chars
}

function Invoke-IcaclsChecked {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & icacls.exe @Arguments|Out-Null
    if($LASTEXITCODE -ne 0){
        throw ("icacls failed ({0}): {1}" -f $LASTEXITCODE,($Arguments -join ' '))
    }
}

function Protect-OwnerOnlyDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    New-Item -ItemType Directory -Path $Path -Force|Out-Null
    Invoke-IcaclsChecked @($Path,'/inheritance:r')
    Invoke-IcaclsChecked @($Path,'/grant:r',('*'+$currentSid+':(OI)(CI)F'))
    Invoke-IcaclsChecked @($Path,'/grant','*S-1-5-18:(OI)(CI)F')
    Invoke-IcaclsChecked @($Path,'/grant','*S-1-5-32-544:(OI)(CI)F')
}

function Protect-RestrictedProfileState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RestrictedSid
    )
    New-Item -ItemType Directory -Path $Path -Force|Out-Null
    Invoke-IcaclsChecked @($Path,'/inheritance:r')
    Invoke-IcaclsChecked @($Path,'/grant:r',('*'+$RestrictedSid+':(OI)(CI)F'))
    Invoke-IcaclsChecked @($Path,'/grant','*S-1-5-18:(OI)(CI)F')
    Invoke-IcaclsChecked @($Path,'/grant','*S-1-5-32-544:(OI)(CI)F')
}

function Grant-ProjectAccess {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$RestrictedSid
    )

    # Remove grants from a previous Restricted Remote installation before
    # rebuilding the least-privilege view.
    & icacls.exe $ProjectPath /remove:g ('*'+$RestrictedSid) /T /C /Q|Out-Null

    # The canonical working tree is not exposed. Access to the directory itself
    # is enough to reach Git metadata; committed files are materialized later in
    # a restricted session clone. Untracked .env/secrets therefore stay private.
    Invoke-IcaclsChecked @($ProjectPath,'/grant',('*'+$RestrictedSid+':(RX)'))

    $gitPaths=New-Object Collections.Generic.List[string]
    foreach($query in @('--git-dir','--git-common-dir')){
        $value=[string](& git -C $ProjectPath rev-parse --path-format=absolute $query 2>$null)
        if($LASTEXITCODE -ne 0 -or -not $value){continue}
        $full=[IO.Path]::GetFullPath($value.Trim())
        if(-not $gitPaths.Contains($full)){[void]$gitPaths.Add($full)}
    }
    if($gitPaths.Count -eq 0){throw "Project is not a readable Git repository: $ProjectPath"}

    foreach($gitPath in $gitPaths){
        if(Test-Path -LiteralPath $gitPath -PathType Container){
            Invoke-IcaclsChecked @($gitPath,'/grant',('*'+$RestrictedSid+':(OI)(CI)RX'))
        }elseif(Test-Path -LiteralPath $gitPath -PathType Leaf){
            Invoke-IcaclsChecked @($gitPath,'/grant',('*'+$RestrictedSid+':R'))
        }
    }

    # MultiChat's own tracked top-level runtime files must remain readable so
    # the restricted identity can launch the managed-session scripts. Untracked
    # local files in the manager folder are intentionally excluded.
    if([string]::Equals(
        [IO.Path]::GetFullPath($ProjectPath).TrimEnd('\'),
        [IO.Path]::GetFullPath($root).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )){
        foreach($relative in @(& git -C $root ls-files)){
            if($relative -match '[\\/]'){continue}
            $file=Join-Path $root $relative
            if(Test-Path -LiteralPath $file -PathType Leaf){
                Invoke-IcaclsChecked @($file,'/grant',('*'+$RestrictedSid+':RX'))
            }
        }
    }
}
$runtime=Get-ReviewedRuntime
$projects=@(Get-CanonicalProjectRoots)
$securityRoot=Get-RestrictedRemoteSecurityRoot
$configPath=Get-RestrictedRemoteConfigPath
$passwordFile=Join-Path $securityRoot 'restricted-remote-password.dpapi'
$nodePath=(Get-Command node.exe -ErrorAction SilentlyContinue).Source

if($DryRun){
    Write-Host 'RESTRICTED REMOTE DRY RUN' -ForegroundColor Cyan
    Write-Host ('Account: '+$AccountName)
    Write-Host ('Node: '+$(if($nodePath){$nodePath}else{'MISSING'}))
    Write-Host ('Reviewed runtime: '+$(if($runtime){$runtime.Root}else{'MISSING'}))
    Write-Host ('Runtime integrity pinned: '+[bool]$runtime)
    Write-Host ('Current Remote authorization: '+(Test-Path (Join-Path $env:USERPROFILE '.desktop-commander-device\device.json')))
    Write-Host ('Project roots: '+$projects.Count)
    foreach($project in $projects){Write-Host ('  READ-ONLY: '+$project)}
    Write-Host ('  MODIFY: '+(Join-Path (Join-Path $root 'state') 'restricted'))
    Write-Host ('  MODIFY: '+(Join-Path (Join-Path $root 'workspaces') 'restricted'))
    Write-Host 'Normal state/workspaces: read-only'
    Write-Host 'Git isolation: session-local shared clones; canonical .git stays read-only'
    Write-Host 'No system changes were made.'
    if(-not $nodePath -or -not $runtime){exit 2}
    exit 0
}

if(-not(Test-Administrator)){
    $args=@(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',$PSCommandPath,
        '-AccountName',$AccountName,
        '-InstallRoot',$root
    )
    $elevated=Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait -PassThru
    $exitCode=$elevated.ExitCode
    $elevated.Dispose()
    exit $exitCode
}

if(-not $nodePath){throw 'Node.js is required for Restricted Remote.'}
if(-not $runtime){throw 'Reviewed Desktop Commander 0.2.51 runtime was not found in the npm cache.'}
$plainPassword=New-RandomPassword
$securePassword=ConvertTo-SecureString $plainPassword -AsPlainText -Force
$accountDescription='Restricted identity for ChatGPT MultiChat Remote Desktop Commander'
$account=Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
if($account){
    if([string]$account.Description -ne $accountDescription){
        throw "Local account '$AccountName' already exists and is not owned by ChatGPT MultiChat."
    }
    Set-LocalUser -Name $AccountName -Password $securePassword -PasswordNeverExpires $true -UserMayChangePassword $false
}else{
    $account=New-LocalUser -Name $AccountName -Password $securePassword -PasswordNeverExpires -UserMayNotChangePassword -Description $accountDescription
}
$account=Get-LocalUser -Name $AccountName
$restrictedSid=$account.SID.Value
$adminGroup=Get-LocalGroup -SID 'S-1-5-32-544'
$usersGroup=Get-LocalGroup -SID 'S-1-5-32-545'
try{Remove-LocalGroupMember -Group $adminGroup.Name -Member $AccountName -ErrorAction SilentlyContinue}catch{}
try{Add-LocalGroupMember -Group $usersGroup.Name -Member $AccountName -ErrorAction SilentlyContinue}catch{}

$hideKey='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
New-Item -Path $hideKey -Force|Out-Null
New-ItemProperty -Path $hideKey -Name $AccountName -Value 0 -PropertyType DWord -Force|Out-Null

$credential=New-Object Management.Automation.PSCredential(("$env:COMPUTERNAME\$AccountName"),$securePassword)
$probe=Start-Process cmd.exe -ArgumentList '/d','/c','exit 0' -Credential $credential -LoadUserProfile -WindowStyle Hidden -Wait -PassThru
if($probe.ExitCode -ne 0){throw 'Could not initialize the Restricted Remote Windows profile.'}
$probe.Dispose()
Start-Sleep -Milliseconds 500

$profileKey="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$restrictedSid"
$profilePath=$null
if(Test-Path $profileKey){
    $profilePath=[Environment]::ExpandEnvironmentVariables([string](Get-ItemPropertyValue $profileKey 'ProfileImagePath'))
}
if(-not $profilePath){$profilePath=Join-Path $env:SystemDrive ('Users\'+$AccountName)}
if(-not(Test-Path -LiteralPath $profilePath)){throw 'Restricted Remote profile directory was not created.'}

Protect-OwnerOnlyDirectory -Path $securityRoot
$encrypted=$securePassword|ConvertFrom-SecureString
[IO.File]::WriteAllText($passwordFile,$encrypted,(New-Object Text.UTF8Encoding($false)))
Protect-OwnerOnlyDirectory -Path $securityRoot
$plainPassword=$null
foreach($project in $projects){
    Grant-ProjectAccess -ProjectPath $project -RestrictedSid $restrictedSid
}

$normalStateRoot=Join-Path $root 'state'
$normalWorkspaceRoot=Join-Path $root 'workspaces'
$restrictedStateRoot=Join-Path $normalStateRoot 'restricted'
$restrictedWorkspaceRoot=Join-Path $normalWorkspaceRoot 'restricted'
New-Item -ItemType Directory -Path $normalStateRoot,$normalWorkspaceRoot -Force|Out-Null

# The manager's normal state and normal worktrees are a trust boundary. Keep
# them private to the interactive user so a restricted worker cannot read
# command history or plant files for a later normal-user chat.
Protect-OwnerOnlyDirectory -Path $normalStateRoot
Protect-OwnerOnlyDirectory -Path $normalWorkspaceRoot
New-Item -ItemType Directory -Path $restrictedStateRoot,$restrictedWorkspaceRoot -Force|Out-Null

# Fixed, locally approved project registry lives only inside the restricted
# state tree. The worker can read it but the canonical project registry,
# updater cache, normal chat sessions and normal workspaces stay inaccessible.
$restrictedProjects=@($projects|ForEach-Object{
    [pscustomobject]@{name=(Split-Path $_ -Leaf);path=$_;lastUsed=(Get-Date).ToString('o')}
})
$restrictedProjectsFile=Join-Path $restrictedStateRoot 'restricted-projects.json'
[IO.File]::WriteAllText(
    $restrictedProjectsFile,
    ($restrictedProjects|ConvertTo-Json -Depth 5),
    (New-Object Text.UTF8Encoding($false))
)

# Restricted Remote owns only its dedicated state/workspace trees. This avoids
# a lower-privilege worker planting files or metadata consumed later by a
# normal interactive-user chat.
Invoke-IcaclsChecked @($restrictedStateRoot,'/grant',('*'+$restrictedSid+':(OI)(CI)M'))
Invoke-IcaclsChecked @($restrictedWorkspaceRoot,'/grant',('*'+$restrictedSid+':(OI)(CI)M'))
Invoke-IcaclsChecked @($runtime.Root,'/grant',('*'+$restrictedSid+':(OI)(CI)RX'))

$dcState=Join-Path $profilePath '.desktop-commander-device'
$dcConfigRoot=Join-Path $profilePath '.claude-server-commander'
Protect-RestrictedProfileState -Path $dcState -RestrictedSid $restrictedSid
Protect-RestrictedProfileState -Path $dcConfigRoot -RestrictedSid $restrictedSid

$currentDcConfig=Join-Path $env:USERPROFILE '.claude-server-commander\config.json'
if(Test-Path -LiteralPath $currentDcConfig){
    $dcConfig=Get-Content -LiteralPath $currentDcConfig -Raw|ConvertFrom-Json
}else{
    $dcConfig=[pscustomobject]@{}
}
$allowed=@($projects + $restrictedWorkspaceRoot|Sort-Object -Unique)
foreach($pair in @(
    @('allowedDirectories',$allowed),
    @('telemetryEnabled',$false)
)){
    $prop=$dcConfig.PSObject.Properties[$pair[0]]
    if($prop){$prop.Value=$pair[1]}else{$dcConfig|Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1]}
}
foreach($property in @('usageStats','currentClient')){
    if($dcConfig.PSObject.Properties[$property]){$dcConfig.PSObject.Properties.Remove($property)}
}
$restrictedDcConfig=Join-Path $dcConfigRoot 'config.json'
[IO.File]::WriteAllText($restrictedDcConfig,($dcConfig|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
Protect-RestrictedProfileState -Path $dcConfigRoot -RestrictedSid $restrictedSid

$gitConfig=Join-Path $profilePath '.gitconfig'
Remove-Item -LiteralPath $gitConfig -Force -ErrorAction SilentlyContinue
$name=[string](& git config --global --get user.name)
$email=[string](& git config --global --get user.email)
if($name){& git config --file $gitConfig user.name $name}
if($email){& git config --file $gitConfig user.email $email}
foreach($project in $projects){& git config --file $gitConfig --add safe.directory ([IO.Path]::GetFullPath($project).Replace('\','/'))}
Protect-RestrictedProfileState -Path $profilePath -RestrictedSid $restrictedSid
$config=[ordered]@{
    schemaVersion=1
    enabled=$false
    installRoot=$root
    accountName=$AccountName
    userName=("$env:COMPUTERNAME\$AccountName")
    userSid=$restrictedSid
    profilePath=$profilePath
    nodePath=$nodePath
    runtimeRoot=$runtime.Root
    entryPoint=$runtime.EntryPoint
    packageVersion=$packageVersion
    packageIntegrity=$packageIntegrity
    passwordFile=$passwordFile
    workspaceIsolation='shared-clone'
    projectRoots=@($projects)
    stateRoot=$restrictedStateRoot
    workspaceRoot=$restrictedWorkspaceRoot
    configuredAt=(Get-Date).ToString('o')
}
[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
Protect-OwnerOnlyDirectory -Path $securityRoot

Write-Host 'Restricted Remote system identity is prepared.' -ForegroundColor Green
Write-Host ('Account: '+$AccountName)
Write-Host ('Profile: '+$profilePath)
Write-Host ('Runtime: '+$runtime.Root)
Write-Host 'Mode is not active yet. Run Activate-RestrictedRemote.ps1 locally when ready.'
