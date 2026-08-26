<#
.SYNOPSIS
    FirstBase Windows Update splash explorer-presence watcher.
    For Internal Use Only.

.DESCRIPTION
    2026.05.19.2213q Bug MM watcher. Replaces the OnLogon trigger on
    FirstBase\UpdateSplash that races Explorer startup on Dell hardware.

    2026.05.20.2213w Bug OO + 2026.05.20.2213x Bug PP: SetupComplete
    creates FirstBase\UpdateSplash with schtasks /Create /IT (interactive
    token when the task runs), but field dump (F:\fbdump, 5/20/2026) still
    showed Show-UpdateProgress.ps1 in Session 0 after watcher schtasks
    /Run exit=0. Bug PP: SYSTEM calling schtasks /Run does not reliably
    deliver Session 1 even with /IT on the task definition. Primary launch
    is CreateProcessAsUser (duplicated explorer.exe primary token) to
    winsta0\default; schtasks /Run remains fallback only if token bridge
    returns pid=0 (see LastLaunchWin32Error in splash-watcher.log).

    Field evidence from Dell Latitude dump 1142 (5/19/2026) proved that
    the Layer 2 OnLogon trigger fires ~1 second BEFORE explorer.exe
    becomes the interactive shell on Dell hardware. The first launch
    attempt silently fizzles (launcher exits 0, no splash-ui.log, no
    WPF window, no PIDs in tasklist). The splash only appears ~10
    minutes later when a second OnLogon-class event happens to fire
    the same task again after the desktop has stabilized. Lenovo does
    not hit the race because Explorer starts faster there. The fix is
    NOT to chase Dell-specific timing - it is to make the trigger fire
    AFTER Explorer is provably ready instead of before it.

    This script runs as SYSTEM under scheduled task
    FirstBase\SplashWatcher (trigger ONSTART). It polls Win32 for an
    explorer.exe process owned by an interactive session (SessionId
    >= 1) every 1 second. On first hit it waits 3 additional seconds
    for the desktop to stabilize (avoids firing on transient explorer
    .exe restarts during driver install),     then runs CreateProcessAsUser (explorer token) to invoke
    FirstBaseSplashLauncher.cmd in the interactive user's session; if
    that fails, falls back to:
        schtasks /Run /TN FirstBase\UpdateSplash
    The launcher invokes the WPF splash (via FirstBaseSplashSingleInstance.ps1
    wrapper). As of 2214i, SetupComplete no longer auto-starts the console
    fallback from the launcher shim (optional manual FirstBaseConsoleSplash.cmd).
    A single /Run of FirstBase\UpdateSplash triggers the WPF path with the
    existing dedupe locks intact.

    Single-instance gate: FileShare::None lock on splash-watcher.lock
    (consistent with FirstBaseSplashSingleInstance.ps1 wrapper and the
    console-splash.lock helper). If a second watcher process spawns
    (e.g. ONSTART task somehow re-fires), the second invocation hits
    IOException on File.Open and exits 0 cleanly.

    Idempotency: before firing /Run, checks whether UpdateSplash is
    already Running via Get-ScheduledTask (.State is locale-invariant).
    If that cmdlet path fails: schtasks /Query /FO CSV (column layout stable;
    ``Running`` cell text may still localize on some SKUs), then /V /FO LIST
    ``Status: Running`` (English-centric label). If already Running, logs
    SKIP-RUN and exits without double-firing.

    Hard timeout: 20 minutes from start. If Explorer never appears (eg
    the device is sitting at the AutoLogon Winlogon screen with no user
    session, or some hardware-specific shell init failure), the watcher
    logs WARN and exits 0. The splash is not critical to update success
    - it is a UX nicety - so a missing splash MUST NOT block the loop
    from continuing. The four backup splash launch layers (RunOnce
    !FirstBaseWuSplash, the /IT bridge UpdateSplashLayer4, Run reg key
    if any future layer adds it, and Layer 5 fallback in the loop)
    still apply, but in practice this OnStart watcher is now the
    PRIMARY path on every build.

    Log: C:\Windows\Setup\FirstBase\Logs\splash-watcher.log
        Captures every poll iteration (compact), the Explorer PID +
        SessionId when first seen, the schtasks /Run exit code, and
        the final disposition (FIRED / SKIPPED / TIMEOUT / ERROR).
        Append-only; survives reboots so multi-boot timing can be
        reconstructed post-mortem.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$fbVerPs1 = Join-Path 'C:\Windows\Setup\FirstBase' 'FirstBaseVersion.ps1'
if (-not (Test-Path -LiteralPath $fbVerPs1)) {
    $fbVerPs1 = Join-Path $PSScriptRoot 'FirstBaseVersion.ps1'
}
if (Test-Path -LiteralPath $fbVerPs1) {
    . $fbVerPs1
} else {
    $FirstBaseProductVersion  = '1.0.0'
    $FirstBasePayloadRevision = 'unknown'
    $FirstBaseScriptVersion   = @{}
}
$fbWatchLeaf = 'FirstBaseSplashWatcher.ps1'
try {
    if ($MyInvocation.MyCommand.Path) { $fbWatchLeaf = Split-Path -Leaf $MyInvocation.MyCommand.Path }
} catch {}
$script:ThisScriptVersion = [string]$FirstBaseScriptVersion[$fbWatchLeaf]
if ([string]::IsNullOrWhiteSpace($script:ThisScriptVersion)) { $script:ThisScriptVersion = $FirstBaseProductVersion }

$FbRoot       = 'C:\Windows\Setup\FirstBase'
$FbStateDir   = Join-Path $FbRoot 'State'
$FbLogDir     = Join-Path $FbRoot 'Logs'
$LockPath     = Join-Path $FbStateDir 'splash-watcher.lock'
$LogPath      = Join-Path $FbLogDir 'splash-watcher.log'
$SplashTask   = 'FirstBase\UpdateSplash'
$SplashLauncher = Join-Path $FbRoot 'FirstBaseSplashLauncher.cmd'

# Hard upper bound: stop polling after this many seconds even if
# Explorer never appears. 20 minutes is intentionally generous - on
# slow Dell devices we have observed Explorer-start delays of 10+
# minutes after Audit auto-logon when driver install is competing for
# CPU. Going higher than 20m risks the watcher still running when the
# loop tries to sysprep, so 20m is the ceiling.
$TimeoutSeconds = 20 * 60

# After the first interactive Explorer is seen, wait this many seconds
# before firing /Run. Driver install sometimes restarts explorer.exe
# transiently within the first few seconds of logon; the stabilization
# window lets the FINAL Explorer settle before we hand it the splash.
$StabilizationSeconds = 3

function Write-FbWatcherLog {
    param([string]$Level, [string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $FbLogDir)) {
            New-Item -ItemType Directory -Path $FbLogDir -Force | Out-Null
        }
        $line = ('[{0}] [{1}] [watcher pid={2}] {3}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fff'), $Level, $PID, $Message)
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

function Ensure-FbWatcherSplashNativeLoaded {
    if ([type]::GetType('FbFirstBaseNative.SplashInteractiveLaunch', $false)) { return }
    $src = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace FbFirstBaseNative {
    public static class SplashInteractiveLaunch {
        // Populated on LaunchFromExplorerPid failure (0 return) for PowerShell logging.
        // Call Marshal.GetLastWin32Error immediately after the failing Win32 API.
        public static int LastWin32Error = 0;
        public static string LastFailureStage = "";

        private static void RecordLastError(string stage) {
            LastFailureStage = stage;
            LastWin32Error = Marshal.GetLastWin32Error();
        }

        public const uint TOKEN_ASSIGN_PRIMARY = 0x0001;
        public const uint TOKEN_DUPLICATE = 0x0002;
        public const uint TOKEN_QUERY = 0x0008;
        public const uint MAXIMUM_ALLOWED = 0x02000000;
        public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        public const int SecurityImpersonation = 2;
        public const int TokenPrimary = 1;
        public const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        public const uint CREATE_DEFAULT_ERROR_MODE = 0x04000000;

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess, IntPtr lpTokenAttributes, int ImpersonationLevel, int TokenType, out IntPtr phNewToken);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessAsUserW(IntPtr hToken, string lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFOW lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_INFORMATION {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFOW {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        public static int LaunchFromExplorerPid(int explorerPid, string commandLineFull, string workingDirectory) {
            LastWin32Error = 0;
            LastFailureStage = "";
            IntPtr hProc = IntPtr.Zero;
            IntPtr hTok = IntPtr.Zero;
            IntPtr hDup = IntPtr.Zero;
            PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
            try {
                hProc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, explorerPid);
                if (hProc == IntPtr.Zero) { RecordLastError("OpenProcess"); return 0; }
                if (!OpenProcessToken(hProc, TOKEN_QUERY | TOKEN_DUPLICATE, out hTok) || hTok == IntPtr.Zero) { RecordLastError("OpenProcessToken"); return 0; }
                if (!DuplicateTokenEx(hTok, MAXIMUM_ALLOWED, IntPtr.Zero, SecurityImpersonation, TokenPrimary, out hDup) || hDup == IntPtr.Zero) { RecordLastError("DuplicateTokenEx"); return 0; }
                STARTUPINFOW si = new STARTUPINFOW();
                si.cb = Marshal.SizeOf(typeof(STARTUPINFOW));
                si.lpDesktop = "winsta0\\default";
                int cap = Math.Max(commandLineFull.Length + 256, 32768);
                StringBuilder sb = new StringBuilder(commandLineFull, cap);
                uint flags = CREATE_UNICODE_ENVIRONMENT | CREATE_DEFAULT_ERROR_MODE;
                if (!CreateProcessAsUserW(hDup, null, sb, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, workingDirectory, ref si, out pi)) {
                    RecordLastError("CreateProcessAsUserW");
                    return 0;
                }
                LastWin32Error = 0;
                LastFailureStage = "";
                return pi.dwProcessId;
            } finally {
                if (pi.hThread != IntPtr.Zero) { CloseHandle(pi.hThread); }
                if (pi.hProcess != IntPtr.Zero) { CloseHandle(pi.hProcess); }
                if (hDup != IntPtr.Zero) { CloseHandle(hDup); }
                if (hTok != IntPtr.Zero) { CloseHandle(hTok); }
                if (hProc != IntPtr.Zero) { CloseHandle(hProc); }
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $src -ErrorAction Stop
}

function Invoke-FbWatcherLaunchSplashInteractive {
    param([int]$ExplorerPid)
    try {
        if ($ExplorerPid -le 0) {
            Write-FbWatcherLog 'WARN' 'Invoke-FbWatcherLaunchSplashInteractive: ExplorerPid<=0; cannot duplicate token'
            return 0
        }
        if (-not (Test-Path -LiteralPath $SplashLauncher)) {
            Write-FbWatcherLog 'WARN' ("Invoke-FbWatcherLaunchSplashInteractive: launcher missing: {0}" -f $SplashLauncher)
            return 0
        }
        $sysDir = Join-Path $env:WINDIR 'System32'
        if (-not (Test-Path -LiteralPath $sysDir)) { $sysDir = $env:WINDIR }
        $cmdExe = Join-Path $sysDir 'cmd.exe'
        if (-not (Test-Path -LiteralPath $cmdExe)) {
            Write-FbWatcherLog 'WARN' ("Invoke-FbWatcherLaunchSplashInteractive: cmd.exe not found: {0}" -f $cmdExe)
            return 0
        }
        $cmdLine = ('"{0}" /c call "{1}"' -f $cmdExe, $SplashLauncher)
        Ensure-FbWatcherSplashNativeLoaded
        $launchedPid = [int][FbFirstBaseNative.SplashInteractiveLaunch]::LaunchFromExplorerPid($ExplorerPid, $cmdLine, $sysDir)
        if ($launchedPid -le 0) {
            $lastErr = [FbFirstBaseNative.SplashInteractiveLaunch]::LastWin32Error
            $stage = [string][FbFirstBaseNative.SplashInteractiveLaunch]::LastFailureStage
            $w32msg = '<Win32Exception>'
            try { $w32msg = (New-Object System.ComponentModel.Win32Exception($lastErr)).Message } catch { }
            Write-FbWatcherLog 'WARN' ("Invoke-FbWatcherLaunchSplashInteractive: native launch failed; explorerPid={0}; stage={1}; Win32Error={2} ({3})" -f $ExplorerPid, $stage, $lastErr, $w32msg)
            return 0
        }
        return $launchedPid
    } catch {
        $leN = 0
        $stN = ''
        try {
            $null = [FbFirstBaseNative.SplashInteractiveLaunch]
            $leN = [int][FbFirstBaseNative.SplashInteractiveLaunch]::LastWin32Error
            $stN = [string][FbFirstBaseNative.SplashInteractiveLaunch]::LastFailureStage
        } catch {}
        Write-FbWatcherLog 'WARN' ("Invoke-FbWatcherLaunchSplashInteractive: exception: {0}; lastNativeStage={1}; lastNativeWin32={2}" -f $_.Exception.ToString(), $stN, $leN)
        return 0
    }
}

try {
    if (-not (Test-Path -LiteralPath $FbStateDir)) {
        New-Item -ItemType Directory -Path $FbStateDir -Force | Out-Null
    }
} catch {
    Write-FbWatcherLog 'WARN' ("State dir create threw: {0}" -f $_.Exception.Message)
}

# Entry banner: captures the SYSTEM-side process identity, session
# (always 0 for SYSTEM-context scheduled tasks), and host. Lets a
# post-mortem confirm the watcher actually ran (vs. silently being
# squelched by Defender, AppLocker, or a degraded scheduled-task
# context the way Layer 2 OnLogon was in 2213b/b1).
$entrySession = -1
try { $entrySession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId } catch {}
$entryUser = '<unknown>'
try { $entryUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch {}
$entryOs = '<unknown>'
try { $entryOs = ((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime).ToString('o') } catch {}
Write-FbWatcherLog 'INFO' ("watcher started; user={0}; session={1}; lastBoot={2}; timeoutSec={3}; stabilizationSec={4}; product={5}; script={6}; payload={7}" -f $entryUser, $entrySession, $entryOs, $TimeoutSeconds, $StabilizationSeconds, $FirstBaseProductVersion, $script:ThisScriptVersion, $FirstBasePayloadRevision)

# 2250/2254/2295: Safety gate - never launch splash if delivery started, pipeline complete, or device sealed
$fbPipelineMarker = 'C:\ProgramData\FirstBase\.pipeline-completed'
$fbDeliveryStartedMarker = 'C:\ProgramData\FirstBase\.oobe-sound-delivery-started'
$fbSealedMarker   = 'C:\ProgramData\FirstBase\.firstbase-sealed'
$fb2295LegacyDeliveryStarted = $false
if (Test-Path -LiteralPath $fbPipelineMarker) {
    try {
        $fb2295LegacyTxt = [string](Get-Content -LiteralPath $fbPipelineMarker -Raw -ErrorAction SilentlyContinue)
        $fb2295LegacyDeliveryStarted = ($fb2295LegacyTxt -match 'Pipeline started')
    } catch {}
}
if ((Test-Path -LiteralPath $fbPipelineMarker) -or (Test-Path -LiteralPath $fbDeliveryStartedMarker) -or $fb2295LegacyDeliveryStarted -or (Test-Path -LiteralPath $fbSealedMarker)) {
    Write-FbWatcherLog 'INFO' '2295: delivery-started, pipeline-completed, or sealed present; splash suppressed.'
    exit 0
}

$lockStream = $null
try {
    $lockStream = [System.IO.File]::Open(
        $LockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $stamp = ("pid={0}`nstarted={1}`nuser={2}`nversion={3}`nmode=FileShare::None hold`n" -f $PID, (Get-Date).ToString('o'), $entryUser, $FirstBasePayloadRevision)
        $stampBytes = [System.Text.Encoding]::ASCII.GetBytes($stamp)
        $lockStream.SetLength(0)
        $lockStream.Write($stampBytes, 0, $stampBytes.Length)
        $lockStream.Flush()
    } catch {}
    Write-FbWatcherLog 'ACQUIRE' ("acquired FileShare::None lock {0}" -f $LockPath)
} catch [System.IO.IOException] {
    Write-FbWatcherLog 'SKIP' ("sibling watcher holds lock {0}: {1}; exiting clean" -f $LockPath, $_.Exception.Message)
    exit 0
} catch {
    Write-FbWatcherLog 'ERROR' ("lock-attempt threw (non-IO): {0}; bailing out to avoid duplicate" -f $_.Exception.Message)
    exit 0
}

$fired = $false
$iter = 0
try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastLoggedIter = 0
    while ((Get-Date) -lt $deadline) {
        $iter++

        $interactiveExplorer = $null
        try {
            $interactiveExplorer = Get-Process -Name 'explorer' -ErrorAction SilentlyContinue |
                Where-Object { $_.SessionId -ge 1 } |
                Select-Object -First 1
        } catch {
            # Get-Process can throw if the process snapshot is mid-flight
            # during driver init; treat as "not seen yet" and try again.
            $interactiveExplorer = $null
        }

        if ($null -ne $interactiveExplorer) {
            Write-FbWatcherLog 'SEEN' ("interactive Explorer detected on iter={0}; pid={1}; sessionId={2}; waiting {3}s for desktop stabilization" -f $iter, $interactiveExplorer.Id, $interactiveExplorer.SessionId, $StabilizationSeconds)

            Start-Sleep -Seconds $StabilizationSeconds

            # Re-check after stabilization. If Explorer disappeared (rare
            # but possible if the shell restarted mid-wait), drop back
            # into the poll loop instead of firing into thin air.
            $stillThere = $null
            try {
                $stillThere = Get-Process -Name 'explorer' -ErrorAction SilentlyContinue |
                    Where-Object { $_.SessionId -ge 1 } |
                    Select-Object -First 1
            } catch {}
            if ($null -eq $stillThere) {
                Write-FbWatcherLog 'WARN' ("Explorer vanished during stabilization wait; resuming poll")
                continue
            }
            Write-FbWatcherLog 'STABLE' ("Explorer still present post-stabilization; pid={0}; sessionId={1}" -f $stillThere.Id, $stillThere.SessionId)

            # 2254: Operator finalize can write markers during the stabilization window; re-check before launch.
            if ((Test-Path -LiteralPath $fbPipelineMarker) -or (Test-Path -LiteralPath $fbSealedMarker)) {
                Write-FbWatcherLog 'INFO' '2254: pipeline/sealed marker appeared during stabilization; splash suppressed.'
                exit 0
            }

            # Idempotency check: if FirstBase\UpdateSplash is already
            # Running (operator manually fired it, or Layer 4 bridge
            # raced ahead), don't double-fire.
            # Prefer Get-ScheduledTask: .State uses invariant enum names (not MUI task UI strings).
            # If cmdlet fails: schtasks /Query /FO CSV (``Running`` cell may localize); then /V /FO LIST
            # ``Status: Running`` (English-centric). Both are best-effort when Get-ScheduledTask is unavailable.
            $alreadyRunning = $false
            try {
                $stPath = '\FirstBase\'
                $stName = 'UpdateSplash'
                $sched = Get-ScheduledTask -TaskPath $stPath -TaskName $stName -ErrorAction Stop
                if ($sched.State -eq 'Running') {
                    $alreadyRunning = $true
                }
            } catch {
                try {
                    $queryCsv = & schtasks.exe /Query /TN $SplashTask /FO CSV 2>&1
                    if ($LASTEXITCODE -eq 0 -and $queryCsv) {
                        $rows = @($queryCsv | ConvertFrom-Csv -ErrorAction SilentlyContinue)
                        foreach ($r in $rows) {
                            try {
                                $stCell = [string]$r.Status
                                if ($stCell -match '(?i)\bRunning\b') {
                                    $alreadyRunning = $true
                                    break
                                }
                            } catch {}
                        }
                    }
                } catch {}
                if (-not $alreadyRunning) {
                    try {
                        $queryOut = & schtasks.exe /Query /TN $SplashTask /V /FO LIST 2>&1
                        if ($LASTEXITCODE -eq 0 -and $queryOut) {
                            foreach ($qline in @($queryOut)) {
                                if ($qline -match '^\s*Status:\s*Running\s*$') {
                                    $alreadyRunning = $true
                                    break
                                }
                            }
                        }
                    } catch {
                        Write-FbWatcherLog 'WARN' ("idempotency check (Get-ScheduledTask + schtasks CSV + LIST fallback) threw: {0}; proceeding with /Run" -f $_.Exception.Message)
                    }
                }
            }
            if ($alreadyRunning) {
                Write-FbWatcherLog 'SKIP-RUN' ("{0} already Running; skipping /Run to avoid duplicate splash" -f $SplashTask)
                $fired = $true
                break
            }

            # 2213x Bug PP: launch via CreateProcessAsUser (explorer token).
            # schtasks /Run from SYSTEM still landed Session 0 on field dump.
            try {
                $childPid = Invoke-FbWatcherLaunchSplashInteractive -ExplorerPid ([int]$stillThere.Id)
                if ($childPid -gt 0) {
                    Write-FbWatcherLog 'FIRED-TOKEN' ("CreateProcessAsUser via explorer pid={0} child cmd pid={1}; schtasks fallback skipped" -f $stillThere.Id, $childPid)
                    $fired = $true
                    break
                }
                # Wrapper already logged Win32 stage/error or preflight failure; note fallback here for trace continuity.
                Write-FbWatcherLog 'WARN' ("token-launch returned no child pid (explorer pid={0}); falling back to schtasks /Run (see Bug PP: SYSTEM /Run may still not yield interactive session)" -f $stillThere.Id)
            } catch {
                $leN = 0
                $stN = ''
                try {
                    $null = [FbFirstBaseNative.SplashInteractiveLaunch]
                    $leN = [int][FbFirstBaseNative.SplashInteractiveLaunch]::LastWin32Error
                    $stN = [string][FbFirstBaseNative.SplashInteractiveLaunch]::LastFailureStage
                } catch {}
                Write-FbWatcherLog 'WARN' ("token-launch outer catch: {0}; lastNativeStage={1}; lastNativeWin32={2}; falling back to schtasks /Run" -f $_.Exception.ToString(), $stN, $leN)
            }

            # Bug PP (2213x): UpdateSplash is registered with schtasks /IT for an interactive token,
            # but field dumps showed splash still in Session 0 after plain `schtasks /Run` from SYSTEM.
            # We do NOT add `/IT` here: `schtasks /Run` from a SYSTEM scheduled task often cannot
            # elevate to the logged-on user's interactive session the way `/IT` implies; mixing `/IT`
            # with `/Run` is policy- and build-sensitive and risks opaque failures. Primary launch is
            # CreateProcessAsUser above; this `/Run` line remains last-resort only (backup layers still apply).
            try {
                $runOut = & schtasks.exe /Run /TN $SplashTask 2>&1
                $runExit = $LASTEXITCODE
                $runOutStr = ''
                try { $runOutStr = (@($runOut) -join ' ').Trim() } catch {}
                if ($runExit -eq 0) {
                    Write-FbWatcherLog 'FIRED' ("schtasks /Run /TN {0} succeeded (fallback); exit={1}; output={2}" -f $SplashTask, $runExit, $runOutStr)
                    $fired = $true
                    break
                } else {
                    Write-FbWatcherLog 'ERROR' ("schtasks /Run /TN {0} failed; exit={1}; output={2}; backup layers (RunOnce + UpdateSplashLayer4) remain" -f $SplashTask, $runExit, $runOutStr)
                    # Don't retry indefinitely - one failed /Run means the
                    # task is broken at the OS level (deleted, disabled,
                    # principal mismatch). Backup layers handle it.
                    break
                }
            } catch {
                Write-FbWatcherLog 'ERROR' ("schtasks /Run /TN {0} threw: {1}; backup layers remain" -f $SplashTask, $_.Exception.Message)
                break
            }
        }

        # Compact log cadence: log every 30 iterations (~30s) so a
        # 20-minute wait produces ~40 status lines instead of 1200.
        # Always log iter 1 so we know polling actually started.
        if ($iter -eq 1 -or ($iter - $lastLoggedIter) -ge 30) {
            Write-FbWatcherLog 'POLL' ("iter={0}; no interactive Explorer yet; continuing" -f $iter)
            $lastLoggedIter = $iter
        }

        Start-Sleep -Seconds 1
    }

    if (-not $fired) {
        Write-FbWatcherLog 'TIMEOUT' ("hard timeout reached after {0}s and {1} iterations; Explorer never appeared in an interactive session; splash will rely on backup layers (RunOnce / UpdateSplashLayer4 / Layer 5 fallback)" -f $TimeoutSeconds, $iter)
    }
} catch {
    Write-FbWatcherLog 'ERROR' ("watcher main loop threw: {0}; releasing lock and exiting" -f $_.Exception.Message)
} finally {
    if ($null -ne $lockStream) {
        try { $lockStream.Close() } catch {}
        try { $lockStream.Dispose() } catch {}
    }
    Write-FbWatcherLog 'EXIT' ("watcher exiting; fired={0}; iterations={1}" -f $fired, $iter)
}

exit 0
