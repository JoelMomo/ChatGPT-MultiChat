param(
    [Parameter(Mandatory)][string]$SessionId,
    [string]$ExpectedWorkspace,
    [string]$ExpectedBaseSha,
    [switch]$RequireLease,
    [switch]$Json
)

$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ChatMulti.psm1') -Force -DisableNameChecking

$result=Test-ManagedChatSessionInvariant -SessionId $SessionId -ExpectedWorkspace $ExpectedWorkspace -ExpectedBaseSha $ExpectedBaseSha -RequireLease:$RequireLease

if($Json){
    $result | ConvertTo-Json -Depth 10
}else{
    if($result.Valid){
        Write-Host 'VALID' -ForegroundColor Green
    }else{
        Write-Host ('INVALID: '+($result.Codes -join ', ')) -ForegroundColor Red
    }
    Write-Host ('Session: '+$result.SessionId)
    if($result.Workspace){Write-Host ('Workspace: '+$result.Workspace)}
    if($result.BaseSha){Write-Host ('Base: '+$result.BaseRef+' @ '+$result.BaseSha)}
    Write-Host ('Lease: '+$result.LeaseState)
}

if(-not $result.Valid){exit 2}
exit 0
