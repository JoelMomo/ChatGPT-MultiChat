Set-StrictMode -Version 2

function Get-RestrictedRemoteSecurityRoot {
    Join-Path $env:LOCALAPPDATA 'ChatGPT-MultiChat\security'
}

function Get-RestrictedRemoteConfigPath {
    Join-Path (Get-RestrictedRemoteSecurityRoot) 'restricted-remote.json'
}

function Get-RestrictedRemoteStatusPath {
    Join-Path (Get-RestrictedRemoteSecurityRoot) 'restricted-remote-status.json'
}

function Get-RestrictedRemoteInstalledConfig {
    $path=Get-RestrictedRemoteConfigPath
    if(-not(Test-Path -LiteralPath $path)){return $null}
    try{return Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}catch{return $null}
}

function Test-RestrictedRemoteInstallMatches {
    $cfg=Get-RestrictedRemoteInstalledConfig
    if(-not $cfg){return $true}
    $configured=[string]$cfg.installRoot
    if(-not $configured){return $false}
    try{
        return [string]::Equals(
            [IO.Path]::GetFullPath($configured).TrimEnd('\'),
            [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )
    }catch{return $false}
}

function Get-RestrictedRemoteConfig {
    $cfg=Get-RestrictedRemoteInstalledConfig
    if(-not $cfg -or -not [bool]$cfg.enabled -or -not(Test-RestrictedRemoteInstallMatches)){return $null}
    return $cfg
}

function Test-RestrictedRemoteEnabled {
    [bool](Get-RestrictedRemoteConfig)
}

function Test-RestrictedRemoteMisconfigured {
    $cfg=Get-RestrictedRemoteInstalledConfig
    [bool]($cfg -and [bool]$cfg.enabled -and -not(Test-RestrictedRemoteInstallMatches))
}

function Get-RestrictedRemoteCredential {
    param($Config=(Get-RestrictedRemoteConfig))
    if(-not $Config){throw 'Restricted Remote is not configured.'}

    $passwordFile=[string]$Config.passwordFile
    if(-not(Test-Path -LiteralPath $passwordFile)){
        throw 'Restricted Remote credential file is missing.'
    }
    $encrypted=[IO.File]::ReadAllText($passwordFile).Trim()
    if(-not $encrypted){throw 'Restricted Remote credential file is empty.'}
    $secure=$encrypted|ConvertTo-SecureString
    $userName=[string]$Config.userName
    if(-not $userName){throw 'Restricted Remote user name is missing.'}
    return New-Object Management.Automation.PSCredential($userName,$secure)
}

function Get-RestrictedRemoteStatus {
    $path=Get-RestrictedRemoteStatusPath
    if(-not(Test-Path -LiteralPath $path)){return $null}
    try{return Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}catch{return $null}
}

function Write-RestrictedRemoteStatus {
    param(
        [Parameter(Mandatory)][string]$State,
        [int]$LauncherPid=0,
        [int]$ChildPid=0,
        [string]$Message=''
    )
    $root=Get-RestrictedRemoteSecurityRoot
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $path=Get-RestrictedRemoteStatusPath
    $payload=[ordered]@{
        schemaVersion=1
        state=$State
        launcherPid=$LauncherPid
        childPid=$ChildPid
        message=$Message
        updatedAt=(Get-Date).ToString('o')
    }
    $tmp=$path+'.tmp'
    [IO.File]::WriteAllText(
        $tmp,
        ($payload|ConvertTo-Json -Depth 5),
        (New-Object Text.UTF8Encoding($false))
    )
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

Export-ModuleMember -Function @(
    'Get-RestrictedRemoteSecurityRoot',
    'Get-RestrictedRemoteConfigPath',
    'Get-RestrictedRemoteStatusPath',
    'Get-RestrictedRemoteInstalledConfig',
    'Test-RestrictedRemoteInstallMatches',
    'Get-RestrictedRemoteConfig',
    'Test-RestrictedRemoteEnabled',
    'Test-RestrictedRemoteMisconfigured',
    'Get-RestrictedRemoteCredential',
    'Get-RestrictedRemoteStatus',
    'Write-RestrictedRemoteStatus'
)
