param(
    [Parameter(Mandatory)][int]$ParentPid,
    [string]$ModulePath
)

$ErrorActionPreference='Stop'
$root=$PSScriptRoot
if(-not $ModulePath){
    $ModulePath=Join-Path $root 'RestrictedRemote.psm1'
}
Import-Module $ModulePath -Force -DisableNameChecking
$config=Get-RestrictedRemoteConfig
if(-not $config){throw 'Restricted Remote is not enabled.'}
$credential=Get-RestrictedRemoteCredential -Config $config
$securityRoot=Get-RestrictedRemoteSecurityRoot
$killSwitch=Join-Path $securityRoot 'desktop-commander.disabled'
$childScript=Join-Path $root 'RestrictedRemote-Child.ps1'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MultiChatRestrictedJob {
    [StructLayout(LayoutKind.Sequential)]
    public struct BasicLimitInformation {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IoCounters {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ExtendedLimitInformation {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    const int JobObjectExtendedLimitInformation = 9;

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetInformationJobObject(
        IntPtr hJob,
        int infoType,
        IntPtr lpJobObjectInfo,
        uint cbJobObjectInfo);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool TerminateJobObject(IntPtr hJob, uint exitCode);

    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);

    public static IntPtr CreateKillOnCloseJob() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }

        ExtendedLimitInformation info = new ExtendedLimitInformation();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int length = Marshal.SizeOf(typeof(ExtendedLimitInformation));
        IntPtr ptr = Marshal.AllocHGlobal(length);
        try {
            Marshal.StructureToPtr(info, ptr, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ptr, (uint)length)) {
                int error = Marshal.GetLastWin32Error();
                CloseHandle(job);
                throw new System.ComponentModel.Win32Exception(error);
            }
        } finally {
            Marshal.FreeHGlobal(ptr);
        }
        return job;
    }
}
'@
$job=[IntPtr]::Zero
$child=$null
try{
    Write-RestrictedRemoteStatus -State 'STARTING' -LauncherPid $PID
    $job=[MultiChatRestrictedJob]::CreateKillOnCloseJob()

    $arguments=@(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',$childScript,
        '-ProfilePath',[string]$config.profilePath,
        '-NodePath',[string]$config.nodePath,
        '-EntryPoint',[string]$config.entryPoint,
        '-ManagerRoot',$root
    )
    $child=Start-Process powershell.exe `
        -ArgumentList $arguments `
        -Credential $credential `
        -LoadUserProfile `
        -UseNewEnvironment `
        -WindowStyle Hidden `
        -PassThru

    if(-not [MultiChatRestrictedJob]::AssignProcessToJobObject($job,$child.Handle)){
        $error=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        throw "Could not place Restricted Remote in its containment job (Win32 $error)."
    }

    Write-RestrictedRemoteStatus -State 'RUNNING' -LauncherPid $PID -ChildPid $child.Id
    while($true){
        Start-Sleep -Milliseconds 500
        if(Test-Path -LiteralPath $killSwitch){break}
        if(-not(Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)){break}
        $child.Refresh()
        if($child.HasExited){break}
    }
}catch{
    try{
        Write-RestrictedRemoteStatus -State 'FAILED' -LauncherPid $PID -ChildPid $(if($child){$child.Id}else{0}) -Message $_.Exception.Message
    }catch{}
    throw
}finally{
    if($job -ne [IntPtr]::Zero){
        [void][MultiChatRestrictedJob]::TerminateJobObject($job,0)
        [void][MultiChatRestrictedJob]::CloseHandle($job)
    }
    if($child){$child.Dispose()}
    try{Write-RestrictedRemoteStatus -State 'STOPPED' -LauncherPid $PID}catch{}
}
