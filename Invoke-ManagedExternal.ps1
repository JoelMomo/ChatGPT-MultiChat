param(
    [string]$SessionId=$env:CHATGPT_SESSION_ID,
    [string]$Owner='external',
    [string[]]$Resource=@(),
    [int]$LeaseTtlMinutes=0,
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$ArgumentList=@()
)

$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ChatMulti.psm1') -Force -DisableNameChecking

if(-not $SessionId){throw 'SessionId is required.'}
if($LeaseTtlMinutes -le 0){
    $LeaseTtlMinutes=[int](Get-ChatProp (Get-ChatConfig) 'defaultLeaseTtlMinutes' 60)
}
$renewEverySeconds=[Math]::Max(5,[int](($LeaseTtlMinutes*60)/3))
$lease=New-ChatLease -SessionId $SessionId -Owner $Owner -TtlMinutes $LeaseTtlMinutes -Resources $Resource
$process=$null
$exitCode=1

try{
    $startParams=@{
        FilePath=$FilePath
        PassThru=$true
    }
    if($ArgumentList -and $ArgumentList.Count -gt 0){
        $startParams.ArgumentList=$ArgumentList
    }
    $process=Start-Process @startParams
    $lastRenew=Get-Date

    while(-not $process.WaitForExit(1000)){
        if(((Get-Date)-$lastRenew).TotalSeconds -ge $renewEverySeconds){
            Update-ChatLease -LeaseId $lease.id -TtlMinutes $LeaseTtlMinutes|Out-Null
            $lastRenew=Get-Date
        }
    }

    $process.Refresh()
    $exitCode=$process.ExitCode
}finally{
    if($process -and -not $process.HasExited){
        try{$process.Kill()}catch{}
    }
    Close-ChatLease -LeaseId $lease.id|Out-Null
}

exit $exitCode
