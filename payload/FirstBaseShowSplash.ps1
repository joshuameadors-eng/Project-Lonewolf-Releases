# FirstBase 2230: operator manual splash - run from a Shift+F10 command prompt.
# Re-launches Show-UpdateProgress in the interactive session (CreateProcessAsUser / schtasks / direct).
# For Internal Use Only.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$FbSetupRoot = 'C:\Windows\Setup\FirstBase'
$FbPdRoot = 'C:\ProgramData\FirstBase'
$FbLogDir = Join-Path $FbSetupRoot 'Logs'
$ManualLog = Join-Path $FbLogDir 'WU-manual-splash.log'

$fbVerCandidates = @(
    (Join-Path $FbPdRoot 'FirstBaseVersion.ps1')
    (Join-Path $FbSetupRoot 'FirstBaseVersion.ps1')
    (Join-Path $PSScriptRoot 'FirstBaseVersion.ps1')
)
foreach ($c in $fbVerCandidates) {
    if (Test-Path -LiteralPath $c) { . $c; break }
}
if (-not (Get-Variable -Name FirstBasePayloadRevision -ErrorAction SilentlyContinue)) {
    $FirstBaseProductVersion = '1.0.0'
    $FirstBasePayloadRevision = 'unknown'
    $FirstBaseScriptVersion = @{}
}
$script:ThisScriptVersion = [string]$FirstBaseScriptVersion['FirstBaseShowSplash.ps1']
if ([string]::IsNullOrWhiteSpace($script:ThisScriptVersion)) { $script:ThisScriptVersion = $FirstBaseProductVersion }

function Write-FbManualSplashLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('[{0}] [{1}] [PID {2}] {3}' -f (Get-Date -Format 'o'), $Level, $PID, $Message)
    try {
        if (-not (Test-Path -LiteralPath $FbLogDir)) {
            New-Item -ItemType Directory -Path $FbLogDir -Force | Out-Null
        }
        Add-Content -LiteralPath $ManualLog -Value $line -Encoding ascii -ErrorAction SilentlyContinue
    } catch {}
    try {
        $latest = Get-ChildItem -LiteralPath $FbLogDir -Filter 'WU-*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) {
            Add-Content -LiteralPath $latest.FullName -Value ("[2230-manual-splash] {0}" -f $line) -Encoding ascii -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Get-FbManualSplashPathCandidates {
    param([string]$Leaf)
    @(
        (Join-Path $FbPdRoot $Leaf)
        (Join-Path $FbSetupRoot $Leaf)
        (Join-Path $PSScriptRoot $Leaf)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Resolve-FbManualSplashPath {
    param([string]$Leaf)
    foreach ($p in (Get-FbManualSplashPathCandidates -Leaf $Leaf)) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-FbManualSplashInteractiveExplorer {
    try {
        return Get-Process -Name 'explorer' -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -ge 1 } |
            Select-Object -First 1
    } catch {
        return $null
    }
}

function Ensure-FbManualSplashNativeLoaded {
    if ([type]'FbFirstBaseNative.ManualSplashLaunch' -ne $null) { return }
    $src = @'
namespace FbFirstBaseNative {
    public static class ManualSplashLaunch {
        public static int LastWin32Error;
        public static string LastFailureStage = "";
        const uint TOKEN_QUERY = 0x0008;
        const uint TOKEN_DUPLICATE = 0x0002;
        const uint MAXIMUM_ALLOWED = 0x02000000;
        const int SecurityImpersonation = 2;
        const int TokenPrimary = 1;
        const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        const uint CREATE_DEFAULT_ERROR_MODE = 0x04000000;
        const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);
        [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError=true)]
        static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
        [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError=true)]
        static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess, IntPtr lpTokenAttributes, int ImpersonationLevel, int TokenType, out IntPtr phNewToken);
        [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
        static extern bool CreateProcessAsUserW(IntPtr hToken, string lpApplicationName, System.Text.StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFOW lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
        static extern bool CloseHandle(IntPtr hObject);

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
        struct STARTUPINFOW {
            public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
            public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars; public int dwYCountChars;
            public int dwFillAttribute; public int dwFlags; public short wShowWindow; public short cbReserved2;
            public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
        }
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }

        static void RecordLastError(string stage) {
            LastWin32Error = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
            LastFailureStage = stage;
        }

        public static int LaunchFromExplorerPid(int explorerPid, string commandLineFull, string workingDirectory) {
            LastWin32Error = 0; LastFailureStage = "";
            IntPtr hProc = IntPtr.Zero; IntPtr hTok = IntPtr.Zero; IntPtr hDup = IntPtr.Zero;
            PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
            try {
                hProc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, explorerPid);
                if (hProc == IntPtr.Zero) { RecordLastError("OpenProcess"); return 0; }
                if (!OpenProcessToken(hProc, TOKEN_QUERY | TOKEN_DUPLICATE, out hTok) || hTok == IntPtr.Zero) { RecordLastError("OpenProcessToken"); return 0; }
                if (!DuplicateTokenEx(hTok, MAXIMUM_ALLOWED, IntPtr.Zero, SecurityImpersonation, TokenPrimary, out hDup) || hDup == IntPtr.Zero) { RecordLastError("DuplicateTokenEx"); return 0; }
                STARTUPINFOW si = new STARTUPINFOW();
                si.cb = System.Runtime.InteropServices.Marshal.SizeOf(typeof(STARTUPINFOW));
                si.lpDesktop = "winsta0\\default";
                int cap = System.Math.Max(commandLineFull.Length + 256, 32768);
                System.Text.StringBuilder sb = new System.Text.StringBuilder(commandLineFull, cap);
                uint flags = CREATE_UNICODE_ENVIRONMENT | CREATE_DEFAULT_ERROR_MODE;
                if (!CreateProcessAsUserW(hDup, null, sb, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, workingDirectory, ref si, out pi)) {
                    RecordLastError("CreateProcessAsUserW"); return 0;
                }
                return pi.dwProcessId;
            } finally {
                if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
                if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
                if (hDup != IntPtr.Zero) CloseHandle(hDup);
                if (hTok != IntPtr.Zero) CloseHandle(hTok);
                if (hProc != IntPtr.Zero) CloseHandle(hProc);
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $src -ErrorAction Stop
}

function Invoke-FbManualSplashViaToken {
    param([int]$ExplorerPid, [string]$LauncherPath)
    Ensure-FbManualSplashNativeLoaded
    $sysDir = Join-Path $env:WINDIR 'System32'
    $cmdExe = Join-Path $sysDir 'cmd.exe'
    $cmdLine = ('"{0}" /c call "{1}"' -f $cmdExe, $LauncherPath)
    $child = [int][FbFirstBaseNative.ManualSplashLaunch]::LaunchFromExplorerPid($ExplorerPid, $cmdLine, $sysDir)
    if ($child -le 0) {
        $le = [int][FbFirstBaseNative.ManualSplashLaunch]::LastWin32Error
        $st = [string][FbFirstBaseNative.ManualSplashLaunch]::LastFailureStage
        Write-FbManualSplashLog ("CreateProcessAsUser failed explorerPid={0} stage={1} gle={2}" -f $ExplorerPid, $st, $le) 'WARN'
        return $false
    }
    Write-FbManualSplashLog ("CreateProcessAsUser childPid={0} launcher={1}" -f $child, $LauncherPath) 'INFO'
    return $true
}

function Invoke-FbManualSplashViaSchtasks {
    $tn = 'FirstBase\UpdateSplash'
    try {
        $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Run', '/TN', $tn) -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
        $ec = if ($null -ne $p) { [int]$p.ExitCode } else { -1 }
        if ($ec -eq 0) {
            Write-FbManualSplashLog ("schtasks /Run {0} exit 0" -f $tn) 'INFO'
            return $true
        }
        Write-FbManualSplashLog ("schtasks /Run {0} exit {1}" -f $tn, $ec) 'WARN'
    } catch {
        Write-FbManualSplashLog ("schtasks /Run threw: {0}" -f $_.Exception.Message) 'WARN'
    }
    return $false
}

function Invoke-FbManualSplashDirectWrapper {
    $wrapper = Resolve-FbManualSplashPath -Leaf 'FirstBaseSplashSingleInstance.ps1'
    $splash = Resolve-FbManualSplashPath -Leaf 'Show-UpdateProgress.ps1'
    if (-not $wrapper -or -not $splash) {
        Write-FbManualSplashLog ("direct wrapper abort: wrapper={0} splash={1}" -f $wrapper, $splash) 'WARN'
        return $false
    }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        $proc = Start-Process -FilePath $psExe -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Normal', '-File', $wrapper
        ) -WindowStyle Normal -PassThru -ErrorAction Stop
        Write-FbManualSplashLog ("Start-Process wrapper PID={0} path={1}" -f $proc.Id, $wrapper) 'INFO'
        return $true
    } catch {
        Write-FbManualSplashLog ("Start-Process wrapper threw: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

$fbManualSplashSessionId = -1
try { $fbManualSplashSessionId = [int][System.Diagnostics.Process]::GetCurrentProcess().SessionId } catch {}
Write-FbManualSplashLog ("2230: FirstBaseShowSplash entry payload={0} script={1} user={2} session={3}" -f $FirstBasePayloadRevision, $script:ThisScriptVersion, $env:USERNAME, $fbManualSplashSessionId)

$launcher = Resolve-FbManualSplashPath -Leaf 'FirstBaseSplashLauncher.cmd'
$explorer = Get-FbManualSplashInteractiveExplorer

if ($null -ne $explorer -and $launcher) {
    if (Invoke-FbManualSplashViaToken -ExplorerPid $explorer.Id -LauncherPath $launcher) { exit 0 }
}

if (Invoke-FbManualSplashViaSchtasks) { exit 0 }

if (Invoke-FbManualSplashDirectWrapper) { exit 0 }

Write-FbManualSplashLog '2230: all manual splash launch paths failed; ensure ProgramData kit was staged at sysprep (2230) or run from audit before scrub.' 'ERROR'
exit 1
