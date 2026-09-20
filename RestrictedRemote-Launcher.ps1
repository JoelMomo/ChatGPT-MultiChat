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

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CreateProcessWithLogonW(
        string lpUsername,
        string lpDomain,
        string lpPassword,
        uint dwLogonFlags,
        string lpApplicationName,
        System.Text.StringBuilder lpCommandLine,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint ResumeThread(IntPtr hThread);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

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
$childProcessHandle=[IntPtr]::Zero
$childThreadHandle=[IntPtr]::Zero
$childPid=0
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
    $childStdout=Join-Path ([string]$config.stateRoot) 'restricted-remote-child.stdout.tmp'
    $childStderr=Join-Path ([string]$config.stateRoot) 'restricted-remote-child.stderr.tmp'
    Remove-Item -LiteralPath $childStdout,$childStderr -Force -ErrorAction SilentlyContinue

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
        ('"'+$(Escape-BatchValue ([string]$config.nodePath))+'" "'+$(Escape-BatchValue ([string]$config.entryPoint))+'" remote 1>"'+$(Escape-BatchValue $childStdout)+'" 2>"'+$(Escape-BatchValue $childStderr)+'"'),
        'set "rc=%errorlevel%"',
        'del /q "%USERPROFILE%\\.claude-server-commander\\claude_tool_call*.log" >nul 2>&1',
        'del /q "%USERPROFILE%\\.claude-server-commander\\tool-history*.jsonl" >nul 2>&1',
        'exit /b %rc%'
    )
    [IO.File]::WriteAllLines($bootstrap,$lines,(New-Object Text.UTF8Encoding($false)))

    # Create the restricted bootstrap suspended under the target identity.
    # The returned native process handle belongs to this launcher even though
    # the child runs as another user, so containment can be applied before any
    # Node code executes. This avoids cross-user OpenProcess access (Win32 5).
    $credentialName=[string]$credential.UserName
    $slash=$credentialName.IndexOf('\')
    if($slash -gt 0){
        $logonDomain=$credentialName.Substring(0,$slash)
        $logonUser=$credentialName.Substring($slash+1)
    }else{
        $logonDomain='.'
        $logonUser=$credentialName
    }

    $cleanEnvironment=@{
        'SystemRoot'=$systemRoot
        'windir'=$systemRoot
        'SystemDrive'=$systemDrive
        'ComSpec'=$cmdPath
        'USERPROFILE'=$profile
        'HOME'=$profile
        'HOMEDRIVE'=$homeDrive
        'HOMEPATH'=$homePath
        'APPDATA'=$appData
        'LOCALAPPDATA'=$localAppData
        'TEMP'=$temp
        'TMP'=$temp
        'PATH'=$machinePath
        'PATHEXT'=$machinePathExt
        'USERNAME'=$logonUser
        'USERDOMAIN'=$logonDomain
        'COMPUTERNAME'=[Environment]::MachineName
        'DC_REMOTE_DEVICE'='true'
        'MULTICHAT_RESTRICTED_REMOTE'='1'
        'MULTICHAT_STATE_ROOT'=[string]$config.stateRoot
        'MULTICHAT_WORKSPACE_ROOT'=[string]$config.workspaceRoot
        'GIT_CONFIG_NOSYSTEM'='1'
        'GIT_TERMINAL_PROMPT'='0'
    }
    $environmentText=(
        @($cleanEnvironment.GetEnumerator()|Sort-Object Key|ForEach-Object{
            [string]$_.Key+'='+[string]$_.Value
        }) -join [char]0
    )+[char]0+[char]0
    $environmentBytes=[Text.Encoding]::Unicode.GetBytes($environmentText)
    $environmentPtr=[Runtime.InteropServices.Marshal]::AllocHGlobal($environmentBytes.Length)

    $passwordBstr=[IntPtr]::Zero
    try{
        [Runtime.InteropServices.Marshal]::Copy(
            $environmentBytes,0,$environmentPtr,$environmentBytes.Length
        )
        $passwordBstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)
        $plainPassword=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordBstr)

        $startup=New-Object MultiChatRestrictedJob+STARTUPINFO
        $startup.cb=[Runtime.InteropServices.Marshal]::SizeOf([type][MultiChatRestrictedJob+STARTUPINFO])
        $startup.dwFlags=0x00000001 # STARTF_USESHOWWINDOW
        $startup.wShowWindow=0      # SW_HIDE
        $processInfo=New-Object MultiChatRestrictedJob+PROCESS_INFORMATION

        $CREATE_SUSPENDED=0x00000004
        $CREATE_UNICODE_ENVIRONMENT=0x00000400
        $CREATE_NO_WINDOW=0x08000000
        $LOGON_WITH_PROFILE=0x00000001
        $creationFlags=$CREATE_SUSPENDED -bor $CREATE_UNICODE_ENVIRONMENT -bor $CREATE_NO_WINDOW
        $commandLine=New-Object Text.StringBuilder
        [void]$commandLine.Append('"'+$cmdPath+'" /d /c ""'+$bootstrap+'""')

        $created=[MultiChatRestrictedJob]::CreateProcessWithLogonW(
            $logonUser,
            $logonDomain,
            $plainPassword,
            [uint32]$LOGON_WITH_PROFILE,
            $cmdPath,
            $commandLine,
            [uint32]$creationFlags,
            $environmentPtr,
            [string]$config.stateRoot,
            [ref]$startup,
            [ref]$processInfo
        )
        if(-not $created){
            $win32Error=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Could not create Restricted Remote bootstrap (Win32 $win32Error)."
        }
        $childProcessHandle=$processInfo.hProcess
        $childThreadHandle=$processInfo.hThread
        $childPid=[int]$processInfo.dwProcessId
    }finally{
        $plainPassword=$null
        if($passwordBstr -ne [IntPtr]::Zero){
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBstr)
        }
        if($environmentPtr -ne [IntPtr]::Zero){
            [Runtime.InteropServices.Marshal]::FreeHGlobal($environmentPtr)
        }
    }

    if(-not [MultiChatRestrictedJob]::AssignProcessToJobObject($job,$childProcessHandle)){
        $win32Error=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Could not place Restricted Remote in its containment job (Win32 $win32Error)."
    }
    $resumeResult=[MultiChatRestrictedJob]::ResumeThread($childThreadHandle)
    if($resumeResult -eq 0xFFFFFFFF){
        $win32Error=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Could not resume Restricted Remote bootstrap (Win32 $win32Error)."
    }

    Write-RestrictedRemoteStatus -State 'RUNNING' -LauncherPid $PID -ChildPid $childPid
    while($true){
        Start-Sleep -Milliseconds 500
        if(Test-Path -LiteralPath $killSwitch){break}
        if(-not(Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)){break}
        $wait=[MultiChatRestrictedJob]::WaitForSingleObject($childProcessHandle,0)
        if($wait -eq 0){
            [uint32]$exitCode=0
            [void][MultiChatRestrictedJob]::GetExitCodeProcess($childProcessHandle,[ref]$exitCode)

            $diagnosticParts=New-Object Collections.Generic.List[string]
            foreach($capture in @($childStderr,$childStdout)){
                if(-not(Test-Path -LiteralPath $capture)){continue}
                try{
                    $tail=@(Get-Content -LiteralPath $capture -Tail 20 -ErrorAction Stop)
                    if($tail.Count){
                        $text=($tail -join ' ; ').Trim()
                        $text=$text -replace '(?i)(authorization|bearer|token|secret|password)(\s*[:=]\s*)[^\s;]+','$1$2<redacted>'
                        $text=$text -replace '[\r\n]+',' '
                        if($text.Length -gt 1200){$text=$text.Substring(0,1200)+'...'}
                        if($text){[void]$diagnosticParts.Add($text)}
                    }
                }catch{}
            }
            Remove-Item -LiteralPath $childStdout,$childStderr -Force -ErrorAction SilentlyContinue
            $diagnostic=($diagnosticParts -join ' | ')
            if($diagnostic){
                throw "Restricted Remote child exited unexpectedly (exit $exitCode). Diagnostic: $diagnostic"
            }
            throw "Restricted Remote child exited unexpectedly (exit $exitCode) with no diagnostic output."
        }
        if($wait -ne 258){
            $win32Error=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Could not query Restricted Remote child state (Win32 $win32Error)."
        }
    }
}catch{
    $failed=$true
    try{
        Write-RestrictedRemoteStatus -State 'FAILED' -LauncherPid $PID -ChildPid $childPid -Message $_.Exception.Message
    }catch{}
    throw
}finally{
    if($job -ne [IntPtr]::Zero){
        [void][MultiChatRestrictedJob]::TerminateJobObject($job,0)
    }
    if($childThreadHandle -ne [IntPtr]::Zero){
        [void][MultiChatRestrictedJob]::CloseHandle($childThreadHandle)
    }
    if($childProcessHandle -ne [IntPtr]::Zero){
        [void][MultiChatRestrictedJob]::CloseHandle($childProcessHandle)
    }
    if($job -ne [IntPtr]::Zero){
        [void][MultiChatRestrictedJob]::CloseHandle($job)
    }
    Remove-Item -LiteralPath $childStdout,$childStderr -Force -ErrorAction SilentlyContinue
    if(-not $failed){
        try{Write-RestrictedRemoteStatus -State 'STOPPED' -LauncherPid $PID}catch{}
    }
}
