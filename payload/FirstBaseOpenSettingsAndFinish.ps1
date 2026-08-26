# FirstBase 2230: operator manual Settings + pipeline finalize (Shift+F10 escape).
# Opens ms-settings:sound, waits for SystemSettings exit, runs FirstBaseOobeOperatorFinalize.ps1.
# 5.0.38 (Option B): added -GateOnly mode. When -GateOnly is set, this script is used purely as
# the INTERACTIVE operator Settings gate in the Administrator audit session (launched pre-sysprep
# by Invoke-FbOperatorSettingsGateInSession). It opens Settings, waits for the operator to close
# SystemSettings, writes -ClosedMarker, and exits WITHOUT running finalize or shutting down - the
# SYSTEM WU loop performs the inline scrub / seal / sysprep after this marker appears. The legacy
# (no -GateOnly) behavior is unchanged for the Shift+F10 manual-escape path.
# For Internal Use Only.

param(
    [switch]$Shutdown,
    [string]$SettingsUri = 'ms-settings:sound',
    [switch]$GateOnly,
    [string]$ClosedMarker = '',
    # 5.0.40 (2381): bound the two phases of the WINDOW-based close-wait separately. Acquire = time to wait
    # for the Settings window to appear after launch; CloseWait = time to wait for the operator to close it.
    [int]$WindowAcquireSec = 180,
    [int]$WindowCloseWaitSec = 1800,
    # 5.0.41 (2382): once the tracked window stops qualifying as live, wait this long for a qualifying
    # live+visible+uncloaked Settings window to reappear (re-host) before concluding the operator closed it.
    [int]$WindowCloseGraceSec = 6,
    # Hardware-gate PASS: private YouTube window; close -> caller seals then sysprep /oobe /reboot.
# Walk-away close-timeout must NOT seal or power off. FAIL keeps Settings (default).
    # PASS also drops default-render volume to 20% for the video, then restores (Fail/Settings is untouched).
    [switch]$YouTubePass,
    [string]$YouTubeUrl = 'https://www.youtube.com/watch?v=s-UFPhz2nZ0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$FbPd = 'C:\ProgramData\FirstBase'
$FbSetup = 'C:\Windows\Setup\FirstBase'
$FbLogDir = Join-Path $FbSetup 'Logs'
$MirrorLog = Join-Path $FbLogDir 'WU-manual-settings-finish-mirror.log'
# 5.0.39 (2380): while this marker exists the FirstBase splash stands down (drops topmost + minimizes)
# so the operator's Settings window is visible/usable. Written just before we open Settings, removed
# once SystemSettings exits. Same interactive Administrator session as the splash, so window activation works.
$FbSplashOperatorGateActive = Join-Path $FbPd '.operator-settings-gate-active'

$fbVerCandidates = @(
    (Join-Path $FbPd 'FirstBaseVersion.ps1')
    (Join-Path $FbSetup 'FirstBaseVersion.ps1')
)
foreach ($c in $fbVerCandidates) {
    if (Test-Path -LiteralPath $c) { . $c; break }
}
if (-not (Get-Variable -Name FirstBasePayloadRevision -ErrorAction SilentlyContinue)) {
    $FirstBaseProductVersion = '1.0.0'
    $FirstBasePayloadRevision = 'unknown'
    $FirstBaseScriptVersion = @{}
}
$script:ThisScriptVersion = [string]$FirstBaseScriptVersion['FirstBaseOpenSettingsAndFinish.ps1']
if ([string]::IsNullOrWhiteSpace($script:ThisScriptVersion)) { $script:ThisScriptVersion = $FirstBaseProductVersion }

function Write-FbManualSettingsFinishLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('[{0}] [{1}] [PID {2}] {3}' -f (Get-Date -Format 'o'), $Level, $PID, $Message)
    try {
        if (-not (Test-Path -LiteralPath $FbLogDir)) {
            New-Item -ItemType Directory -Path $FbLogDir -Force | Out-Null
        }
        Add-Content -LiteralPath $MirrorLog -Value $line -Encoding ascii -ErrorAction SilentlyContinue
    } catch {}
}

# 5.0.39 (2380): ApplicationFrameHost-aware window activation. The visible top-level window for a
# ms-settings: URI is an ApplicationFrameWindow hosted by ApplicationFrameHost.exe (NOT SystemSettings.exe's
# own window), so we enumerate top-level ApplicationFrameWindows and match the one whose hosted
# Windows.UI.Core.CoreWindow child thread belongs to a SystemSettings process; then SW_SHOWMAXIMIZED +
# SetForegroundWindow. All enumeration is done in C# to avoid PowerShell delegate/StrictMode pitfalls.
$FbSettingsWin32Src = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class FbSettingsWin32 {
    delegate bool EnumWindowsProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int pid);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
    const int SW_SHOWMAXIMIZED = 3;
    const int ASFW_ANY = -1;
    const int DWMWA_CLOAKED = 14;

    static string ClassOf(IntPtr h){ var sb = new StringBuilder(256); GetClassName(h, sb, sb.Capacity); return sb.ToString(); }
    static string TextOf(IntPtr h){ int n = GetWindowTextLength(h); var sb = new StringBuilder(n + 2); GetWindowText(h, sb, sb.Capacity); return sb.ToString(); }

    // A closed / suspended / minimized-to-background UWP ApplicationFrameWindow typically lingers with
    // IsWindow()==true and even IsWindowVisible()==true, but DWM reports it CLOAKED. This is the key
    // discriminator that separates a genuinely-open Settings window from a zombie frame (5.0.41 fix).
    public static bool IsCloaked(IntPtr h){
        try { int v = 0; int hr = DwmGetWindowAttribute(h, DWMWA_CLOAKED, out v, sizeof(int)); if (hr != 0) return false; return v != 0; }
        catch { return false; }
    }

    static HashSet<uint> SettingsPids(){
        var set = new HashSet<uint>();
        try { foreach (var p in Process.GetProcessesByName("SystemSettings")) { try { set.Add((uint)p.Id); } catch {} } } catch {}
        return set;
    }

    // True only if the frame currently hosts a Windows.UI.Core.CoreWindow child owned by a live SystemSettings PID.
    static bool FrameHostsSettings(IntPtr h, HashSet<uint> ssPids){
        bool hit = false;
        try {
            EnumChildWindows(h, (ch, cp) => {
                try {
                    if (ClassOf(ch) == "Windows.UI.Core.CoreWindow") {
                        uint cpid; GetWindowThreadProcessId(ch, out cpid);
                        if (ssPids.Contains(cpid)) { hit = true; return false; }
                    }
                } catch {}
                return true;
            }, IntPtr.Zero);
        } catch {}
        return hit;
    }

    // 5.0.41: strict liveness for a tracked handle - must be a real window, visible, NOT cloaked, an
    // ApplicationFrameWindow, and still hosting a live SystemSettings CoreWindow. Excludes zombie/cloaked frames.
    public static bool IsSettingsWindowLive(IntPtr h){
        if (h == IntPtr.Zero) return false;
        if (!IsWindow(h)) return false;
        if (!IsWindowVisible(h)) return false;
        if (IsCloaked(h)) return false;
        if (ClassOf(h) != "ApplicationFrameWindow") return false;
        return FrameHostsSettings(h, SettingsPids());
    }

    // 5.0.41: find a genuinely LIVE + VISIBLE + UNCLOAKED Settings ApplicationFrameWindow. No title/any-frame
    // fallback (those matched leftover frames and kept the gate open forever - dump PF4VGG7V-1132-Lenovo).
    public static IntPtr FindLiveSettingsWindow(){
        var ssPids = SettingsPids();
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            try {
                if (!IsWindowVisible(h)) return true;
                if (ClassOf(h) != "ApplicationFrameWindow") return true;
                if (IsCloaked(h)) return true;
                if (FrameHostsSettings(h, ssPids)) { found = h; return false; }
            } catch {}
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Dump-capturable breakdown of why a handle is/ isn't considered a live Settings window.
    public static string DescribeWindow(IntPtr h){
        try {
            bool isw = IsWindow(h);
            bool vis = isw && IsWindowVisible(h);
            bool clk = isw && IsCloaked(h);
            string cls = isw ? ClassOf(h) : "(none)";
            bool host = isw && FrameHostsSettings(h, SettingsPids());
            return string.Format("isWindow={0};visible={1};cloaked={2};class={3};hostsSettings={4}", isw, vis, clk, cls, host);
        } catch (Exception ex) { return "describe-error:" + ex.Message; }
    }

    public static IntPtr FindSettingsWindow(){
        var ssPids = SettingsPids();
        IntPtr byPid = IntPtr.Zero;
        IntPtr byTitle = IntPtr.Zero;
        IntPtr anyFrame = IntPtr.Zero;
        EnumWindows((h, p) => {
            try {
                if (!IsWindowVisible(h)) return true;
                if (ClassOf(h) != "ApplicationFrameWindow") return true;
                if (anyFrame == IntPtr.Zero) anyFrame = h;
                string t = TextOf(h);
                if (byTitle == IntPtr.Zero && t != null && t.IndexOf("Settings", StringComparison.OrdinalIgnoreCase) >= 0) byTitle = h;
                IntPtr matched = IntPtr.Zero;
                EnumChildWindows(h, (ch, cp) => {
                    try {
                        if (ClassOf(ch) == "Windows.UI.Core.CoreWindow") {
                            uint cpid; GetWindowThreadProcessId(ch, out cpid);
                            if (ssPids.Contains(cpid)) { matched = h; return false; }
                        }
                    } catch {}
                    return true;
                }, IntPtr.Zero);
                if (matched != IntPtr.Zero && byPid == IntPtr.Zero) byPid = matched;
            } catch {}
            return true;
        }, IntPtr.Zero);
        if (byPid != IntPtr.Zero) return byPid;   // definite: CoreWindow owned by SystemSettings
        if (byTitle != IntPtr.Zero) return byTitle; // strong heuristic: frame titled "Settings"
        return anyFrame;                            // audit OOBE fallback: only Settings is open
    }

    public static bool ForegroundMaximize(IntPtr h){
        if (h == IntPtr.Zero) return false;
        try { AllowSetForegroundWindow(ASFW_ANY); } catch {}
        ShowWindowAsync(h, SW_SHOWMAXIMIZED);
        BringWindowToTop(h);
        return SetForegroundWindow(h);
    }
}
'@

function Set-FbSettingsForegroundMaximized {
    param([int]$TimeoutSec = 60)
    try {
        if (-not ([System.Management.Automation.PSTypeName]'FbSettingsWin32').Type) {
            Add-Type -TypeDefinition $FbSettingsWin32Src -ErrorAction Stop
        }
    } catch {
        Write-FbManualSettingsFinishLog ("2380: Add-Type for Settings foreground failed: {0}" -f $_.Exception.Message) 'WARN'
        return
    }
    # ms-settings: launches asynchronously via ApplicationFrameHost, so the window can take a moment to
    # appear - poll (bounded) until we find the frame, then maximize + foreground it.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $h = [IntPtr]::Zero
        try { $h = [FbSettingsWin32]::FindSettingsWindow() } catch {}
        if ($h -ne [IntPtr]::Zero) {
            $ok = $false
            try { $ok = [FbSettingsWin32]::ForegroundMaximize($h) } catch {}
            Write-FbManualSettingsFinishLog ("2380: Settings window hwnd={0} SW_SHOWMAXIMIZED + foreground applied (SetForegroundWindow={1})." -f $h, $ok) 'INFO'
            return
        }
        Start-Sleep -Milliseconds 750
    }
    Write-FbManualSettingsFinishLog '2380: Settings ApplicationFrameWindow not found within timeout; splash stand-down still applied so the desktop is usable.' 'WARN'
}

function Set-FbOperatorGateMarker {
    param([bool]$Active)
    try {
        if ($Active) {
            if (-not (Test-Path -LiteralPath $FbPd)) { New-Item -ItemType Directory -Path $FbPd -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-Content -LiteralPath $FbSplashOperatorGateActive -Value ('operator Settings gate open since {0} (PID {1})' -f (Get-Date -Format 'o'), $PID) -Encoding ascii -Force -ErrorAction SilentlyContinue
            Write-FbManualSettingsFinishLog ('2380: wrote operator-settings-gate-active marker; splash will stand aside ({0}).' -f $FbSplashOperatorGateActive) 'INFO'
        } else {
            if (Test-Path -LiteralPath $FbSplashOperatorGateActive) { Remove-Item -LiteralPath $FbSplashOperatorGateActive -Force -ErrorAction SilentlyContinue }
            Write-FbManualSettingsFinishLog '2380: removed operator-settings-gate-active marker (operator closed Settings).' 'INFO'
        }
    } catch {
        Write-FbManualSettingsFinishLog ('2380: gate marker update (Active={0}) failed: {1}' -f $Active, $_.Exception.Message) 'WARN'
    }
}

function Start-FbGateCloseWaitSplash {
    try {
        $candidates = @(
            (Join-Path $FbSetup 'FirstBaseHandoffSplash.ps1')
            (Join-Path $FbPd 'FirstBaseHandoffSplash.ps1')
        )
        $ps1 = $null
        foreach ($c in $candidates) {
            if (Test-Path -LiteralPath $c) { $ps1 = $c; break }
        }
        if (-not $ps1) { return }
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
            '-File', $ps1, '-Phase', 'close-wait', '-AutoCloseSeconds', '120'
        ) -WindowStyle Normal -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

function Wait-FbManualInteractiveExplorer {
    param([int]$MaxSec = 120)
    $deadline = (Get-Date).AddSeconds($MaxSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $ex = @(Get-Process -Name 'explorer' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ge 1 })
            if ($ex.Count -gt 0) { return $true }
        } catch {}
        Start-Sleep -Seconds 2
    }
    return $false
}

# Stable default used by the hardware-gate PASS path (embed + autoplay; play once).
$script:FbHardwareGateYoutubeUrl = 'https://www.youtube.com/embed/mD3v1B_aXw0?autoplay=1'
$script:FbHardwareGateBrowserProfile = Join-Path $env:TEMP 'FirstBaseHwGateBrowser'

function Get-FbHardwareGateBrowser {
    $edge = @(
        (Join-Path ${env:ProgramFiles} 'Microsoft\Edge\Application\msedge.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($p in $edge) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            return [pscustomobject]@{ Path = $p; PrivateArg = '--inprivate'; Name = 'msedge' }
        }
    }
    $chrome = @(
        (Join-Path ${env:ProgramFiles} 'Google\Chrome\Application\chrome.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($p in $chrome) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            return [pscustomobject]@{ Path = $p; PrivateArg = '--incognito'; Name = 'chrome' }
        }
    }
    return $null
}

function Get-FbHardwareGateBrowserProcs {
    param([string]$ProfileDir)
    $hits = @()
    try {
        $needle = [string]$ProfileDir
        $hits = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^(msedge|chrome)\.exe$' -and $_.CommandLine -and ($_.CommandLine -like ('*{0}*' -f $needle))
        })
    } catch {}
    return @($hits)
}

function Test-FbHardwareGateBrowserWindowLive {
    param([string]$ProfileDir)
    foreach ($cim in @(Get-FbHardwareGateBrowserProcs -ProfileDir $ProfileDir)) {
        if (-not $cim) { continue }
        try {
            $gp = Get-Process -Id ([int]$cim.ProcessId) -ErrorAction SilentlyContinue
            if ($gp -and $gp.MainWindowHandle -ne [IntPtr]::Zero -and [int64]$gp.MainWindowHandle -ne 0) {
                return $true
            }
        } catch {}
    }
    return $false
}

function Stop-FbHardwareGateBrowserLeftovers {
    param([string]$ProfileDir)
    foreach ($cim in @(Get-FbHardwareGateBrowserProcs -ProfileDir $ProfileDir)) {
        if (-not $cim) { continue }
        try { Stop-Process -Id ([int]$cim.ProcessId) -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# Default render endpoint master volume via Core Audio IAudioEndpointVolume (no extra binaries).
# Used only on the YouTube PASS path. Failures must never block opening YouTube.
$FbDefaultRenderVolumeSrc = @'
using System;
using System.Runtime.InteropServices;

public sealed class FbVolumeSnap {
    public float Scalar;
    public bool Muted;
}

public static class FbDefaultRenderVolume {
    const int eRender = 0;
    const int eMultimedia = 1;
    const int eConsole = 0;
    const int eCommunications = 2;
    const int CLSCTX_ALL = 23;

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IntPtr properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out uint count);
        [PreserveSig] int SetMasterVolumeLevel(float levelDb, IntPtr eventContext);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, IntPtr eventContext);
        [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, IntPtr eventContext);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, IntPtr eventContext);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute(int mute, IntPtr eventContext);
        [PreserveSig] int GetMute(out int mute);
        [PreserveSig] int GetVolumeStepInfo(out uint step, out uint stepCount);
        [PreserveSig] int VolumeStepUp(IntPtr eventContext);
        [PreserveSig] int VolumeStepDown(IntPtr eventContext);
        [PreserveSig] int QueryHardwareSupport(out uint mask);
        [PreserveSig] int GetVolumeRange(out float minDb, out float maxDb, out float incrementDb);
    }

    static IAudioEndpointVolume GetEndpointVolume() {
        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        int[] roles = new int[] { eMultimedia, eConsole, eCommunications };
        IMMDevice device = null;
        int hr = -1;
        for (int i = 0; i < roles.Length; i++) {
            IMMDevice candidate;
            hr = enumerator.GetDefaultAudioEndpoint(eRender, roles[i], out candidate);
            if (hr >= 0 && candidate != null) { device = candidate; break; }
        }
        if (device == null) {
            throw new InvalidOperationException("GetDefaultAudioEndpoint failed hr=0x" + hr.ToString("X8"));
        }
        Guid iid = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
        object obj;
        hr = device.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out obj);
        if (hr < 0 || obj == null) {
            throw new InvalidOperationException("IAudioEndpointVolume Activate failed hr=0x" + hr.ToString("X8"));
        }
        return (IAudioEndpointVolume)obj;
    }

    public static FbVolumeSnap Get() {
        IAudioEndpointVolume ep = GetEndpointVolume();
        float scalar;
        int muted;
        int hr = ep.GetMasterVolumeLevelScalar(out scalar);
        if (hr < 0) throw new InvalidOperationException("GetMasterVolumeLevelScalar hr=0x" + hr.ToString("X8"));
        hr = ep.GetMute(out muted);
        if (hr < 0) throw new InvalidOperationException("GetMute hr=0x" + hr.ToString("X8"));
        FbVolumeSnap snap = new FbVolumeSnap();
        snap.Scalar = scalar;
        snap.Muted = (muted != 0);
        return snap;
    }

    public static void Set(float scalar, bool muted) {
        if (scalar < 0f) scalar = 0f;
        if (scalar > 1f) scalar = 1f;
        IAudioEndpointVolume ep = GetEndpointVolume();
        int hr = ep.SetMasterVolumeLevelScalar(scalar, IntPtr.Zero);
        if (hr < 0) throw new InvalidOperationException("SetMasterVolumeLevelScalar hr=0x" + hr.ToString("X8"));
        // S_FALSE (1) means mute already matched the requested state - that is success.
        hr = ep.SetMute(muted ? 1 : 0, IntPtr.Zero);
        if (hr < 0) throw new InvalidOperationException("SetMute hr=0x" + hr.ToString("X8"));
    }
}
'@

function Initialize-FbDefaultRenderVolumeType {
    try {
        if (-not ([System.Management.Automation.PSTypeName]'FbDefaultRenderVolume').Type) {
            Add-Type -TypeDefinition $FbDefaultRenderVolumeSrc -Language CSharp -ErrorAction Stop
        }
        return $true
    } catch {
        Write-FbManualSettingsFinishLog ("hardware-gate PASS: Core Audio IAudioEndpointVolume Add-Type failed: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Set-FbYoutubePassRenderVolumeLow {
    $result = [pscustomobject]@{ Snap = $null; Applied = $false }
    try {
        if (-not (Initialize-FbDefaultRenderVolumeType)) { return $result }
        try {
            $result.Snap = [FbDefaultRenderVolume]::Get()
            Write-FbManualSettingsFinishLog ("hardware-gate PASS: captured default render volume scalar={0:N2} muted={1}" -f $result.Snap.Scalar, $result.Snap.Muted) 'INFO'
        } catch {
            Write-FbManualSettingsFinishLog ("hardware-gate PASS: capture default render volume failed: {0}" -f $_.Exception.Message) 'WARN'
            $result.Snap = $null
        }
        try {
            [FbDefaultRenderVolume]::Set([float]0.20, $false)
            $result.Applied = $true
            Write-FbManualSettingsFinishLog 'hardware-gate PASS: set default render volume to 20% unmuted for YouTube.' 'INFO'
        } catch {
            Write-FbManualSettingsFinishLog ("hardware-gate PASS: set render volume to 20% failed: {0}" -f $_.Exception.Message) 'WARN'
            $result.Applied = $false
        }
    } catch {
        Write-FbManualSettingsFinishLog ("hardware-gate PASS: volume prepare failed: {0}" -f $_.Exception.Message) 'WARN'
        $result.Applied = $false
    }
    return $result
}

function Restore-FbYoutubePassRenderVolume {
    param($CapturedSnap, [bool]$VolumeApplied)
    if (-not $VolumeApplied) { return }
    try {
        if (-not (Initialize-FbDefaultRenderVolumeType)) { return }
        if ($null -ne $CapturedSnap) {
            [FbDefaultRenderVolume]::Set([float]$CapturedSnap.Scalar, [bool]$CapturedSnap.Muted)
            Write-FbManualSettingsFinishLog ("hardware-gate PASS: restored default render volume scalar={0:N2} muted={1}" -f $CapturedSnap.Scalar, $CapturedSnap.Muted) 'INFO'
        } else {
            [FbDefaultRenderVolume]::Set([float]0.50, $false)
            Write-FbManualSettingsFinishLog 'hardware-gate PASS: capture missing; restored default render volume to 50% unmuted.' 'WARN'
        }
    } catch {
        Write-FbManualSettingsFinishLog ("hardware-gate PASS: restore render volume failed: {0}" -f $_.Exception.Message) 'WARN'
    }
}

function Invoke-FbYoutubePassAndWait {
    param(
        [int]$AcquireSec = 180,
        [int]$CloseWaitSec = 1800
    )
    $url = $YouTubeUrl
    if ([string]::IsNullOrWhiteSpace($url)) { $url = $script:FbHardwareGateYoutubeUrl }
    $browser = Get-FbHardwareGateBrowser
    if (-not $browser) {
        Write-FbManualSettingsFinishLog 'hardware-gate PASS: no Edge/Chrome found; cannot open private YouTube.' 'ERROR'
        return 'browser-missing'
    }
    $profileDir = $script:FbHardwareGateBrowserProfile
    try {
        if (-not (Test-Path -LiteralPath $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}

    $capturedSnap = $null
    $volumeApplied = $false
    try {
        $volPrep = Set-FbYoutubePassRenderVolumeLow
        if ($volPrep) {
            $capturedSnap = $volPrep.Snap
            $volumeApplied = [bool]$volPrep.Applied
        }

        Write-FbManualSettingsFinishLog ("hardware-gate PASS: launching {0} {1} url={2} profile={3}" -f $browser.Name, $browser.PrivateArg, $url, $profileDir) 'INFO'
        try {
            $argList = @(
                $browser.PrivateArg
                ('--user-data-dir={0}' -f $profileDir)
                '--no-first-run'
                '--no-default-browser-check'
                '--autoplay-policy=no-user-gesture-required'
                $url
            )
            Start-Process -FilePath $browser.Path -ArgumentList $argList -ErrorAction Stop | Out-Null
        } catch {
            Write-FbManualSettingsFinishLog ("hardware-gate PASS: browser launch threw: {0}" -f $_.Exception.Message) 'ERROR'
            return 'browser-launch-failed'
        }

        $acquired = $false
        $acquireDeadline = (Get-Date).AddSeconds($AcquireSec)
        while ((Get-Date) -lt $acquireDeadline) {
            if (Test-FbHardwareGateBrowserWindowLive -ProfileDir $profileDir) {
                $acquired = $true
                break
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $acquired) {
            Write-FbManualSettingsFinishLog ("hardware-gate PASS: private browser window never appeared within {0}s." -f $AcquireSec) 'WARN'
            Stop-FbHardwareGateBrowserLeftovers -ProfileDir $profileDir
            return 'window-never-appeared'
        }
        Write-FbManualSettingsFinishLog ("hardware-gate PASS: private YouTube window acquired; waiting for operator close. Close = seal then sysprep /oobe /reboot. Walk-away timeout ({0}s) does NOT seal or power off." -f $CloseWaitSec) 'INFO'

        $goneStart = $null
        $graceSec = 3
        $timeoutNotices = 0
        $noticeAt = (Get-Date).AddSeconds($CloseWaitSec)
        while ($true) {
            $live = Test-FbHardwareGateBrowserWindowLive -ProfileDir $profileDir
            if ($live) {
                $goneStart = $null
            } else {
                if ($null -eq $goneStart) { $goneStart = Get-Date }
                elseif (((Get-Date) - $goneStart).TotalSeconds -ge $graceSec) {
                    Write-FbManualSettingsFinishLog 'hardware-gate PASS: operator closed the private YouTube window.' 'INFO'
                    Stop-FbHardwareGateBrowserLeftovers -ProfileDir $profileDir
                    return 'window-closed'
                }
            }
            if ((Get-Date) -ge $noticeAt) {
                $timeoutNotices++
                Write-FbManualSettingsFinishLog ("5.4.8: YouTube close-wait backstop ({0}s) reached (notice {1}); NOT treating as closed. Device stays on. Close the private YouTube window to continue." -f $CloseWaitSec, $timeoutNotices) 'WARN'
                Start-FbGateCloseWaitSplash
                $noticeAt = (Get-Date).AddSeconds($CloseWaitSec)
            }
            Start-Sleep -Milliseconds 500
        }
    } finally {
        Restore-FbYoutubePassRenderVolume -CapturedSnap $capturedSnap -VolumeApplied $volumeApplied
    }
}

Write-FbManualSettingsFinishLog ("2230: manual Settings+finish entry uri={0} shutdown={1} youtubePass={2} payload={3}" -f $SettingsUri, $Shutdown.IsPresent, $YouTubePass.IsPresent, $FirstBasePayloadRevision)

if (-not (Wait-FbManualInteractiveExplorer)) {
    Write-FbManualSettingsFinishLog 'explorer wait TIMEOUT; proceeding anyway.' 'WARN'
}

# 5.0.39 (2380): tell the splash to step aside BEFORE we open Settings so it does not overlay the window.
Set-FbOperatorGateMarker -Active $true

$closeReason = 'unknown'
if ($YouTubePass) {
    $closeReason = Invoke-FbYoutubePassAndWait -AcquireSec $WindowAcquireSec -CloseWaitSec $WindowCloseWaitSec
    Write-FbManualSettingsFinishLog ("hardware-gate PASS YouTube close-wait ended reason={0}." -f $closeReason) 'INFO'
} else {
$cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
$launched = $false
for ($i = 1; $i -le 3; $i++) {
    try {
        Start-Process -FilePath $cmdExe -ArgumentList @('/c', 'start', '""', $SettingsUri) -WindowStyle Normal -ErrorAction Stop
        $launched = $true
        Write-FbManualSettingsFinishLog ("settings URI launch attempt {0}/3 ok" -f $i) 'INFO'
        Start-Sleep -Seconds 3
        $ss = @(Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue)
        if ($ss.Count -gt 0) { break }
    } catch {
        Write-FbManualSettingsFinishLog ("settings URI attempt {0} threw: {1}" -f $i, $_.Exception.Message) 'WARN'
    }
    Start-Sleep -Seconds 4
}
if (-not $launched) {
    Write-FbManualSettingsFinishLog 'all settings URI launch attempts failed.' 'WARN'
}

# 5.0.39 (2380): bring the Settings window to the foreground and maximize it (ApplicationFrameHost-aware,
# bounded poll). Best-effort; the splash has already stood aside so the desktop is usable either way.
Set-FbSettingsForegroundMaximized -TimeoutSec 60

# 5.0.40 (2381): wait for the actual Settings WINDOW to be closed, NOT the SystemSettings.exe process.
# Under ms-settings: / ApplicationFrameHost the process is SUSPENDED (not terminated) when the operator
# closes the window, so process-exit polling never detects a normal close and always runs to the timeout
# (dump PF4VGG7V-1003-Lenovo: SystemSettings.exe stayed alive the full 900s and the cap shut the box down
# while the operator was still in Settings). We now track the ApplicationFrameWindow handle destruction.
$closeReason = 'unknown'
$haveWin32 = $false
try {
    if (-not ([System.Management.Automation.PSTypeName]'FbSettingsWin32').Type) {
        Add-Type -TypeDefinition $FbSettingsWin32Src -ErrorAction Stop
    }
    $haveWin32 = $true
} catch {
    Write-FbManualSettingsFinishLog ("2381: Add-Type unavailable; falling back to process-exit wait: {0}" -f $_.Exception.Message) 'WARN'
}

if ($haveWin32) {
    # Phase 1 - acquire a genuinely LIVE + VISIBLE + UNCLOAKED Settings window (bounded). ms-settings: opens
    # asynchronously via ApplicationFrameHost, so keep polling to acquire the handle first. Do NOT treat the
    # pre-appear interval as "closed".
    $acquiredHwnd = [IntPtr]::Zero
    $acquireDeadline = (Get-Date).AddSeconds($WindowAcquireSec)
    while ((Get-Date) -lt $acquireDeadline) {
        try { $acquiredHwnd = [FbSettingsWin32]::FindLiveSettingsWindow() } catch { $acquiredHwnd = [IntPtr]::Zero }
        if ($acquiredHwnd -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 500
    }

    if ($acquiredHwnd -ne [IntPtr]::Zero) {
        Write-FbManualSettingsFinishLog ("2382: operator Settings WINDOW acquired hwnd={0} ({1}); waiting for the operator to CLOSE it (max {2}s, close-grace {3}s)." -f $acquiredHwnd, [FbSettingsWin32]::DescribeWindow($acquiredHwnd), $WindowCloseWaitSec, $WindowCloseGraceSec) 'INFO'
        # Phase 2 - wait for the operator to close it. Each tick we test STRICT liveness of the tracked handle
        # (real window + visible + NOT DWM-cloaked + still hosting a live SystemSettings CoreWindow). The 5.0.40
        # bug (dump PF4VGG7V-1132-Lenovo) was that a lingering/cloaked frame kept IsWindow()==true forever, so
        # the eager "any frame" re-acquire never concluded closed. Now:
        #   - tracked handle still live            -> keep waiting (cancel any grace)
        #   - a DIFFERENT live Settings window     -> genuine re-host/re-open: re-acquire (cancel grace)
        #   - NO live Settings window anywhere     -> start a bounded grace; if none reappears within
        #                                             $WindowCloseGraceSec, conclude window-closed.
        $closeDeadline = (Get-Date).AddSeconds($WindowCloseWaitSec)
        $graceStart = $null
        while ((Get-Date) -lt $closeDeadline) {
            $live = $false
            try { $live = [FbSettingsWin32]::IsSettingsWindowLive($acquiredHwnd) } catch { $live = $false }
            if ($live) {
                if ($null -ne $graceStart) {
                    Write-FbManualSettingsFinishLog ("2382: tracked Settings hwnd={0} is live again; cancelling close-grace." -f $acquiredHwnd) 'INFO'
                    $graceStart = $null
                }
            } else {
                $re = [IntPtr]::Zero
                try { $re = [FbSettingsWin32]::FindLiveSettingsWindow() } catch { $re = [IntPtr]::Zero }
                if ($re -ne [IntPtr]::Zero) {
                    if ($re -ne $acquiredHwnd) {
                        Write-FbManualSettingsFinishLog ("2382: tracked hwnd={0} no longer live [{1}]; a DIFFERENT live+visible+uncloaked Settings window is present hwnd={2} - re-acquiring (not treating as closed)." -f $acquiredHwnd, [FbSettingsWin32]::DescribeWindow($acquiredHwnd), $re) 'INFO'
                        $acquiredHwnd = $re
                    }
                    $graceStart = $null
                } else {
                    if ($null -eq $graceStart) {
                        $graceStart = Get-Date
                        Write-FbManualSettingsFinishLog ("2382: tracked Settings hwnd={0} no longer live [{1}] and NO live Settings window found; starting {2}s close-grace." -f $acquiredHwnd, [FbSettingsWin32]::DescribeWindow($acquiredHwnd), $WindowCloseGraceSec) 'INFO'
                    } elseif (((Get-Date) - $graceStart).TotalSeconds -ge $WindowCloseGraceSec) {
                        Write-FbManualSettingsFinishLog ("2382: no live Settings window for {0}s grace - concluding operator CLOSED Settings." -f $WindowCloseGraceSec) 'INFO'
                        $closeReason = 'window-closed'
                        break
                    }
                }
            }
            Start-Sleep -Milliseconds 500
        }
        if ($closeReason -ne 'window-closed') {
            Write-FbManualSettingsFinishLog ("5.4.8: Settings close-wait backstop ({0}s) reached WITHOUT a real close; NOT treating as closed. Device stays on. Close Settings to continue." -f $WindowCloseWaitSec) 'WARN'
            Start-FbGateCloseWaitSplash
            $closeDeadline = (Get-Date).AddSeconds($WindowCloseWaitSec)
            while ($true) {
                $live = $false
                try { $live = [FbSettingsWin32]::IsSettingsWindowLive($acquiredHwnd) } catch { $live = $false }
                if (-not $live) {
                    $re = [IntPtr]::Zero
                    try { $re = [FbSettingsWin32]::FindLiveSettingsWindow() } catch { $re = [IntPtr]::Zero }
                    if ($re -ne [IntPtr]::Zero) {
                        $acquiredHwnd = $re
                        $live = $true
                    }
                }
                if (-not $live) {
                    $graceStart2 = Get-Date
                    $closedForSure = $false
                    while (((Get-Date) - $graceStart2).TotalSeconds -lt $WindowCloseGraceSec) {
                        Start-Sleep -Milliseconds 500
                        $re2 = [IntPtr]::Zero
                        try { $re2 = [FbSettingsWin32]::FindLiveSettingsWindow() } catch { $re2 = [IntPtr]::Zero }
                        if ($re2 -ne [IntPtr]::Zero) {
                            $acquiredHwnd = $re2
                            $closedForSure = $false
                            break
                        }
                        $closedForSure = $true
                    }
                    if ($closedForSure) {
                        Write-FbManualSettingsFinishLog '5.4.8: operator CLOSED Settings after close-wait backstop; proceeding.' 'INFO'
                        $closeReason = 'window-closed'
                        break
                    }
                }
                if ((Get-Date) -ge $closeDeadline) {
                    Write-FbManualSettingsFinishLog ("5.4.8: Settings still open after another {0}s; NOT sealing. Close Settings to continue. Device stays on." -f $WindowCloseWaitSec) 'WARN'
                    Start-FbGateCloseWaitSplash
                    $closeDeadline = (Get-Date).AddSeconds($WindowCloseWaitSec)
                }
                Start-Sleep -Milliseconds 500
            }
        }
    } else {
        Write-FbManualSettingsFinishLog ("2382: operator Settings WINDOW never appeared within {0}s (interactive render may have failed); proceeding. Inline scrub runs regardless." -f $WindowAcquireSec) 'WARN'
        $closeReason = 'window-never-appeared'
    }
} else {
    # Fallback ONLY if the Win32 type could not load: legacy process-exit wait (unreliable for UWP, but
    # better than nothing). Uses the same generous close cap.
    $seen = $false
    $deadline = (Get-Date).AddSeconds($WindowCloseWaitSec)
    while ((Get-Date) -lt $deadline) {
        $alive = @(Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue)
        if ($alive.Count -gt 0) { $seen = $true }
        if ($seen -and $alive.Count -eq 0) { $closeReason = 'process-exit'; break }
        Start-Sleep -Seconds 2
    }
    if ($closeReason -eq 'unknown') {
        Write-FbManualSettingsFinishLog '5.4.8: Settings process-exit fallback hit the close-wait cap WITHOUT process-exit; NOT treating as closed. Waiting for SystemSettings to exit. Device stays on.' 'WARN'
        Start-FbGateCloseWaitSplash
        while ($true) {
            $alive = @(Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue)
            if ($seen -and $alive.Count -eq 0) { $closeReason = 'process-exit'; break }
            if ($alive.Count -gt 0) { $seen = $true }
            Start-Sleep -Seconds 2
        }
    }
}

if ($closeReason -eq 'window-closed') {
    Write-FbManualSettingsFinishLog '2381: operator CLOSED the Settings window - proceeding to scrub/seal (real close detected).' 'INFO'
} elseif ($closeReason -eq 'process-exit') {
    Write-FbManualSettingsFinishLog '2381: SystemSettings process exited (Win32 fallback path) - proceeding to scrub/seal.' 'INFO'
} else {
    Write-FbManualSettingsFinishLog ("2381: close-wait ended WITHOUT a confirmed operator close (reason={0}). 5.4.8 will not seal on timeout; this path should only be launch-fail (window-never-appeared)." -f $closeReason) 'WARN'
}

} # end Settings (non-YouTube) wait

# 5.0.39 (2380): operator has closed Settings (or the bounded wait elapsed) - drop the stand-down marker.
# The splash stays minimized and closes on .pipeline-completed / .firstbase-sealed; the loop also removes
# this marker as a backstop in case this process is torn down before reaching here.
Set-FbOperatorGateMarker -Active $false

# 5.0.38 (Option B): GateOnly mode - signal the SYSTEM WU loop that the operator closed Settings,
# then exit. Do NOT run finalize and do NOT shut down; the loop owns the inline scrub / seal / sysprep.
if ($GateOnly) {
    if (-not [string]::IsNullOrWhiteSpace($ClosedMarker)) {
        try {
            $markerDir = Split-Path -Parent $ClosedMarker
            if ($markerDir -and -not (Test-Path -LiteralPath $markerDir)) {
                New-Item -ItemType Directory -Path $markerDir -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Set-Content -LiteralPath $ClosedMarker -Value ('Operator gate ended at {0} (PID {1}) reason={2} youtubePass={3}' -f (Get-Date -Format 'o'), $PID, $closeReason, $YouTubePass.IsPresent) -Encoding ascii -Force -ErrorAction SilentlyContinue
            Write-FbManualSettingsFinishLog ("5.0.38 GateOnly: wrote closed marker {0} (reason={1} youtubePass={2}); exiting (loop owns scrub/seal/sysprep)." -f $ClosedMarker, $closeReason, $YouTubePass.IsPresent) 'INFO'
        } catch {
            Write-FbManualSettingsFinishLog ("5.0.38 GateOnly: closed-marker write failed: {0}" -f $_.Exception.Message) 'WARN'
        }
    } else {
        Write-FbManualSettingsFinishLog '5.0.38 GateOnly: no -ClosedMarker supplied; exiting (loop polls SystemSettings directly).' 'WARN'
    }
    exit 0
}

$finalize = Join-Path $FbPd 'FirstBaseOobeOperatorFinalize.ps1'
if (-not (Test-Path -LiteralPath $finalize)) {
    $finalize = Join-Path $FbSetup 'FirstBaseOobeOperatorFinalize.ps1'
}
if (Test-Path -LiteralPath $finalize) {
    try {
        & $finalize
        Write-FbManualSettingsFinishLog ("FirstBaseOobeOperatorFinalize completed from {0}" -f $finalize) 'INFO'
    } catch {
        Write-FbManualSettingsFinishLog ("finalize threw: {0}" -f $_.Exception.Message) 'ERROR'
    }
} else {
    Write-FbManualSettingsFinishLog 'FirstBaseOobeOperatorFinalize.ps1 missing; cannot write .pipeline-completed.' 'ERROR'
}

if ($Shutdown) {
    $realClose = ($closeReason -eq 'window-closed' -or $closeReason -eq 'process-exit')
    if ($realClose) {
        $shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
        Write-FbManualSettingsFinishLog 'real operator close: scheduling shutdown /s /t 30 (legacy -Shutdown path).' 'INFO'
        Start-Process -FilePath $shutdown -ArgumentList @('/s', '/t', '30', '/f', '/c', 'FirstBase: manual Settings finish.') -WindowStyle Hidden -ErrorAction SilentlyContinue
    } else {
        Write-FbManualSettingsFinishLog ("5.4.8: -Shutdown requested but close was not confirmed (reason={0}); NOT calling shutdown /s. Device stays on." -f $closeReason) 'WARN'
    }
}

exit 0
