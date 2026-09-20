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
$failed=$false
try{
    Write-RestrictedRemoteStatus -State 'STARTING' -LauncherPid $PID
    $job=[MultiChatRestrictedJob]::CreateKillOnCloseJob()

    # PowerShell 5.1 cannot initialize when Start-Process -UseNewEnvironment
    # omits SystemRoot (it fails with 8009001d). Keep the clean environment
    # boundary, but bootstrap through native cmd.exe and explicitly construct
    # the restricted environment before starting Node.
    $systemRoot=[Environment]::GetEnvironmentVariable('SystemRoot','Machine')
    if(-not $systemRoot){$systemRoot=$env:SystemRoot}
    if(-not $systemRoot){throw 'SystemRoot is unavailable for Restricted Remote.'}
    $systemDrive=[IO.Path]::GetPathRoot($systemRoot).TrimEnd('\\')
    $cmdPath=Join-Path $systemRoot 'System32\\cmd.exe'
    if(-not(Test-Path -LiteralPath $cmdPath)){throw 'cmd.exe is unavailable for Restricted Remote.'}

    function Escape-BatchValue {
        param([string]$Value)
        if($null -eq $Value){return ''}
        return $Value.Replace('%','%%').Replace('^','^^')
    }

    $profile=[IO.Path]::GetFullPath([string]$config.profilePath).TrimEnd('\\')
    $localAppData=Join-Path $profile 'AppData\\Local'
    $appData=Join-Path $profile 'AppData\\Roaming'
    $temp=Join-Path $localAppData 'Temp'
    $homeDrive=[IO.Path]::GetPathRoot($profile).TrimEnd('\\')
    $homePath=$profile.Substring($homeDrive.Length)
    $machinePath=[Environment]::GetEnvironmentVariable('Path','Machine')
    $machinePathExt=[Environment]::GetEnvironmentVariable('PATHEXT','Machine')
    $bootstrap=Join-Path ([string]$config.stateRoot) 'restricted-remote-child.cmd'

    $lines=@(
        '@echo off',
        'setlocal',
        ('set "SystemRoot='+$(Escape-BatchValue $systemRoot)+'"'),
        ('set "windir='+$(Escape-BatchValue $systemRoot)+'"'),
        ('set "SystemDrive='+$(Escape-BatchValue $systemDrive)+'"'),
        ('set "ComSpec='+$(Escape-BatchValue $cmdPath)+'"'),
        ('set "USERPROFILE='+$(Escape-BatchValue $profile)+'"'),
        ('set "HOME='+$(Escape-BatchValue $profile)+'"'),
        ('set "HOMEDRIVE='+$(Escape-BatchValue $homeDrive)+'"'),
        ('set "HOMEPATH='+$(Escape-BatchValue $homePath)+'"'),
        ('set "APPDATA='+$(Escape-BatchValue $appData)+'"'),
        ('set "LOCALAPPDATA='+$(Escape-BatchValue $localAppData)+'"'),
        ('set "TEMP='+$(Escape-BatchValue $temp)+'"'),
        ('set "TMP='+$(Escape-BatchValue $temp)+'"'),
        ('set "PATH='+$(Escape-BatchValue $machinePath)+'"'),
        ('set "PATHEXT='+$(Escape-BatchValue $machinePathExt)+'"'),
        'set "DC_REMOTE_DEVICE=true"',
        'set "MULTICHAT_RESTRICTED_REMOTE=1"',
        ('set "MULTICHAT_STATE_ROOT='+$(Escape-BatchValue ([string]$config.stateRoot))+'"'),
        ('set "MULTICHAT_WORKSPACE_ROOT='+$(Escape-BatchValue ([string]$config.workspaceRoot))+'"'),
        'set "GIT_CONFIG_NOSYSTEM=1"',
        'set "GIT_TERMINAL_PROMPT=0"',
        'if not exist "%TEMP%" mkdir "%TEMP%" >nul 2>&1',
        '"%SystemRoot%\\System32\\ping.exe" -n 2 127.0.0.1 >nul',
        ('"'+$(Escape-BatchValue ([string]$config.nodePath))+'" "'+$(Escape-BatchValue ([string]$config.entryPoint))+'" remote'),
        'set "rc=%errorlevel%"',
        'del /q "%USERPROFILE%\\.claude-server-commander\\claude_tool_call*.log" >nul 2>&1',
        'del /q "%USERPROFILE%\\.claude-server-commander\\tool-history*.jsonl" >nul 2>&1',
        'exit /b %rc%'
    )
    [IO.File]::WriteAllLines($bootstrap,$lines,(New-Object Text.UTF8Encoding($false)))

    $child=Start-Process $cmdPath `
        -ArgumentList @('/d','/c',('"'+$bootstrap+'"')) `
        -Credential $credential `
        -LoadUserProfile `
        -UseNewEnvironment `
        -WindowStyle Hidden `
        -PassThru

    try{
        $handle=$child.Handle
    }catch{
        $exitCode=try{$child.ExitCode}catch{-1}
        throw "Restricted Remote bootstrap exited before containment (exit $exitCode)."
    }
    if($handle -eq [IntPtr]::Zero){
        throw 'Restricted Remote bootstrap did not expose a process handle.'
    }
    if(-not [MultiChatRestrictedJob]::AssignProcessToJobObject($job,$handle)){
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
        if($child.HasExited){
            $exitCode=try{$child.ExitCode}catch{-1}
            throw "Restricted Remote child exited unexpectedly (exit $exitCode)."
        }
    }
}catch{
    $failed=$true
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
    if(-not $failed){
        try{Write-RestrictedRemoteStatus -State 'STOPPED' -LauncherPid $PID}catch{}
    }
}
