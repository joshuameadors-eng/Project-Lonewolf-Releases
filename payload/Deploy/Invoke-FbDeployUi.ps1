<#
    Invoke-FbDeployUi.ps1  (Project LoneWolf)

    ScriptVersion: 1.1.4  (5.4.24: private-load cascadiamono.ttf then Braille)

    The WinPE deploy screen. One console surface: splash branding (wolf +
    framed title) is the header - there is no separate title ribbon and no
    second PowerShell process for Show-DeployBanner on the Init path.
    TechInstall seeds the step plan here; each Step/Detail/Fail/Done call
    repaints this same layout.

    WHY A STATE FILE
    Batch cannot hold a PowerShell process open across steps, so every call is a
    fresh process with no memory of what came before. The screen state therefore
    lives in a JSON file (default X:\FirstBase-DeployUi.json - X: is the WinPE
    scratch volume and always exists, unlike %TEMP% this early) and each
    invocation mutates it and repaints the whole screen. Repainting rather than
    appending is what keeps the display from scrolling away.

    RENDERING CONSTRAINTS
    Write-Host -ForegroundColor only - no VT/ANSI. Box-drawing glyphs AND the
    wolf are emitted from code points so this file stays ASCII-safe on disk
    (WinPE powershell.exe reads no-BOM .ps1 as ANSI; literal UTF-8 Braille was
    garbled). WinPE raster OEM has no U+28xx, so Cascadia must be staged
    (Deploy\Fonts\cascadiamono.ttf) and AddFontResourceEx private-loaded
    before SetCurrentConsoleFontEx. Probe U+28FF, then any face that has
    it. Snapshot window+buffer before that single font set and restore
    geometry once. Do not use mode con. UTF-8 / chcp 65001 is set once
    per process. Displayed wolf is always U+28xx (no ASCII cat). Never
    re-set the font or restore geometry on later paints or DISM ticks.
    Keep wolf art in sync with Show-DeployBanner.ps1.

    ACTIONS
      Init     -Workflow <tag> -Steps "a;b;c"   splash reveal + seed plan
      Step     -Step <n> [-Label <s>]           mark n active, earlier ones done
      Detail   -Text <s>                        update the detail line only
      Fail     -Reason <s> [-LogFile <p>]       red failure screen + log tail
      Done     [-Text <s>]                      completion screen
      Repaint                                   redraw from existing state

    Progress is shown by a |/-\ spinner next to the active step (no overall
    percent bar). DISM apply paints a themed "Applying image" bar (cyan/dark
    gray/green, same palette as this screen) under the step list.

    This script must never break a deploy: every action is wrapped, and it
    always exits 0.
#>
[CmdletBinding()]
param(
    [ValidateSet('Init', 'Step', 'Detail', 'Fail', 'Done', 'Repaint', 'SpinWatch')]
    [string] $Action = 'Repaint',

    [string] $StateFile = 'X:\FirstBase-DeployUi.json',
    [string] $Workflow = 'Install',
    [string] $Steps = '',
    [int]    $Step = 0,
    [string] $Label = '',
    [string] $Text = '',
    [string] $Reason = '',
    [string] $LogFile = '',
    [int]    $Tail = 10,

    [ValidateSet('Auto', 'Yes', 'No')]
    [string] $Dev = 'Auto',

    # Init only: play the top-down splash reveal once before the first paint.
    [switch] $SkipSplashReveal
)

$ErrorActionPreference = 'SilentlyContinue'

# --- Console font / encoding (once per process; never on DISM ticks) ---------
# Braille (U+28xx) and box-drawing need a face that contains those code points.
# Cascadia Mono/Code usually do; Consolas often does not (console then
# substitutes ?). Snapshot window+buffer BEFORE the single
# SetCurrentConsoleFontEx and restore geometry once if cell size moved.
# Encoding is set once per process. Never Write-Host Braille/box until this
# returns. Later calls are no-ops (no font set, no geometry restore).
function Initialize-FbPeConsole {
    # Returns $true when a Braille-capable face is already active or was set.
    if ($script:FbPeFontEnsured) { return $true }
    try {
        if (-not $script:FbPeEncodingReady) {
            try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
            try { $script:OutputEncoding = [Console]::OutputEncoding } catch {}
            try { $OutputEncoding = [Console]::OutputEncoding } catch {}
            try { cmd.exe /c 'chcp 65001>nul' | Out-Null } catch {}
            $script:FbPeEncodingReady = $true
        }
    } catch {}

    try {
        if (-not ('FbPeConFont' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FbPeConFont {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CONSOLE_FONT_INFOEX {
        public uint cbSize;
        public uint nFont;
        public short dwFontSizeX;
        public short dwFontSizeY;
        public uint FontFamily;
        public uint FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FaceName;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct CONSOLE_SCREEN_BUFFER_INFO {
        public COORD dwSize;
        public COORD dwCursorPosition;
        public short wAttributes;
        public SMALL_RECT srWindow;
        public COORD dwMaximumWindowSize;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetCurrentConsoleFontEx(IntPtr hConsoleOutput, bool bMaximumWindow, ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetCurrentConsoleFontEx(IntPtr hConsoleOutput, bool bMaximumWindow, ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleScreenBufferInfo(IntPtr hConsoleOutput, out CONSOLE_SCREEN_BUFFER_INFO lpConsoleScreenBufferInfo);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleScreenBufferSize(IntPtr hConsoleOutput, COORD dwSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleWindowInfo(IntPtr hConsoleOutput, bool bAbsolute, ref SMALL_RECT lpConsoleWindow);
    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")]
    public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFontW(int cHeight, int cWidth, int cEscapement, int cOrientation, int cWeight, uint bItalic, uint bUnderline, uint bStrikeOut, uint iCharSet, uint iOutPrecision, uint iClipPrecision, uint iQuality, uint iPitchAndFamily, string pszFaceName);
    [DllImport("gdi32.dll")]
    public static extern IntPtr SelectObject(IntPtr hdc, IntPtr h);
    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr ho);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern uint GetGlyphIndicesW(IntPtr hdc, string lpstr, int c, ushort[] pgi, uint fl);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int AddFontResourceEx(string lpszFilename, uint fl, IntPtr pdv);
    public static bool LoadPrivateTtf(string path) {
        if (string.IsNullOrEmpty(path)) { return false; }
        if (!System.IO.File.Exists(path)) { return false; }
        return AddFontResourceEx(path, 0x10, IntPtr.Zero) > 0;
    }

    public static bool HaveSnap;
    public static COORD SnapBuf;
    public static SMALL_RECT SnapWin;
    public static short SnapCellX;
    public static short SnapCellY;
    public static CONSOLE_FONT_INFOEX OriginalFont;
    public static string ChosenFace;
    public static bool ChosenBraille;
    public static bool DidEnsure;

    static IntPtr OutHandle() {
        IntPtr h = GetStdHandle(-11);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) { return IntPtr.Zero; }
        return h;
    }

    public static void CaptureSnap(IntPtr h) {
        if (HaveSnap) { return; }
        CONSOLE_SCREEN_BUFFER_INFO bi;
        if (!GetConsoleScreenBufferInfo(h, out bi)) { return; }
        SnapBuf = bi.dwSize;
        SnapWin = bi.srWindow;
        CONSOLE_FONT_INFOEX fi = new CONSOLE_FONT_INFOEX();
        fi.cbSize = (uint)Marshal.SizeOf(typeof(CONSOLE_FONT_INFOEX));
        if (GetCurrentConsoleFontEx(h, false, ref fi)) {
            SnapCellX = fi.dwFontSizeX;
            SnapCellY = fi.dwFontSizeY;
            OriginalFont = fi;
        }
        if (SnapCellY <= 0) { SnapCellY = 16; }
        HaveSnap = true;
    }

    public static void RestoreGeometry(IntPtr h) {
        if (!HaveSnap) { return; }
        CONSOLE_SCREEN_BUFFER_INFO cur;
        if (!GetConsoleScreenBufferInfo(h, out cur)) { return; }
        short curWW = (short)(cur.srWindow.Right - cur.srWindow.Left + 1);
        short curWH = (short)(cur.srWindow.Bottom - cur.srWindow.Top + 1);
        SMALL_RECT shrink = cur.srWindow;
        bool needShrink = false;
        if (curWW > SnapBuf.X) { shrink.Right = (short)(shrink.Left + SnapBuf.X - 1); needShrink = true; }
        if (curWH > SnapBuf.Y) { shrink.Bottom = (short)(shrink.Top + SnapBuf.Y - 1); needShrink = true; }
        if (needShrink) { SetConsoleWindowInfo(h, true, ref shrink); }
        SetConsoleScreenBufferSize(h, SnapBuf);
        SMALL_RECT wr = SnapWin;
        SetConsoleWindowInfo(h, true, ref wr);
        SetConsoleScreenBufferSize(h, SnapBuf);
    }

    public static bool FaceHasU28FF(string face, short cellY) {
        if (string.IsNullOrEmpty(face)) { return false; }
        IntPtr hwnd = GetConsoleWindow();
        IntPtr hdc = GetDC(hwnd);
        bool created = false;
        if (hdc == IntPtr.Zero) {
            hdc = CreateCompatibleDC(IntPtr.Zero);
            created = true;
            if (hdc == IntPtr.Zero) { return false; }
        }
        int hgt = cellY > 0 ? cellY : 16;
        IntPtr hf = CreateFontW(-hgt, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 0, 0x31, face);
        if (hf == IntPtr.Zero) {
            if (created) { DeleteDC(hdc); } else { ReleaseDC(hwnd, hdc); }
            return false;
        }
        IntPtr old = SelectObject(hdc, hf);
        ushort[] gi = new ushort[1];
        uint r = GetGlyphIndicesW(hdc, "\u28FF", 1, gi, 1);
        SelectObject(hdc, old);
        DeleteObject(hf);
        if (created) { DeleteDC(hdc); } else { ReleaseDC(hwnd, hdc); }
        if (r == 0xFFFFFFFFu) { return false; }
        if (gi[0] == 0xFFFF || gi[0] == 0) { return false; }
        return true;
    }

    public static bool TrySetVerifiedFace(string face) {
        IntPtr h = OutHandle();
        if (h == IntPtr.Zero) { return false; }
        CaptureSnap(h);
        CONSOLE_FONT_INFOEX info = new CONSOLE_FONT_INFOEX();
        info.cbSize = (uint)Marshal.SizeOf(typeof(CONSOLE_FONT_INFOEX));
        GetCurrentConsoleFontEx(h, false, ref info);
        info.FaceName = face;
        info.FontWeight = 400;
        info.FontFamily = 54;
        info.dwFontSizeX = SnapCellX;
        info.dwFontSizeY = SnapCellY;
        if (info.dwFontSizeY <= 0) { info.dwFontSizeY = 16; }
        if (!SetCurrentConsoleFontEx(h, false, ref info)) { RestoreGeometry(h); return false; }
        RestoreGeometry(h);
        CONSOLE_FONT_INFOEX after = new CONSOLE_FONT_INFOEX();
        after.cbSize = (uint)Marshal.SizeOf(typeof(CONSOLE_FONT_INFOEX));
        if (!GetCurrentConsoleFontEx(h, false, ref after)) {
            SetCurrentConsoleFontEx(h, false, ref OriginalFont);
            RestoreGeometry(h);
            return false;
        }
        string got = after.FaceName ?? "";
        if (got.IndexOf(face, StringComparison.OrdinalIgnoreCase) < 0) {
            SetCurrentConsoleFontEx(h, false, ref OriginalFont);
            RestoreGeometry(h);
            return false;
        }
        short cy = after.dwFontSizeY > 0 ? after.dwFontSizeY : SnapCellY;
        if (!FaceHasU28FF(got, cy)) {
            SetCurrentConsoleFontEx(h, false, ref OriginalFont);
            RestoreGeometry(h);
            return false;
        }
        ChosenFace = got;
        ChosenBraille = true;
        return true;
    }

    public static bool CurrentFaceHasBraille(IntPtr h) {
        CONSOLE_FONT_INFOEX after = new CONSOLE_FONT_INFOEX();
        after.cbSize = (uint)Marshal.SizeOf(typeof(CONSOLE_FONT_INFOEX));
        if (!GetCurrentConsoleFontEx(h, false, ref after)) { return false; }
        string got = after.FaceName ?? "";
        short cy = after.dwFontSizeY > 0 ? after.dwFontSizeY : SnapCellY;
        if (!FaceHasU28FF(got, cy)) { return false; }
        ChosenFace = got;
        ChosenBraille = true;
        return true;
    }

    public static bool EnsureOnce() {
        if (DidEnsure) { return ChosenBraille; }
        DidEnsure = true;
        IntPtr h = OutHandle();
        if (h == IntPtr.Zero) { return false; }
        CaptureSnap(h);
        if (CurrentFaceHasBraille(h)) { return true; }
        string[] faces = new string[] { "Cascadia Mono", "Cascadia Code", "Segoe UI Symbol", "Consolas" };
        foreach (string face in faces) {
            try {
                if (FaceHasU28FF(face, SnapCellY) && TrySetVerifiedFace(face)) { return true; }
            } catch { }
        }
        ChosenBraille = false;
        return false;
    }
}
'@ -ErrorAction Stop
        }
        try {
            $ttfCands = New-Object System.Collections.Generic.List[string]
            if ($PSScriptRoot) {
                [void]$ttfCands.Add((Join-Path $PSScriptRoot 'Fonts\cascadiamono.ttf'))
                [void]$ttfCands.Add((Join-Path $PSScriptRoot 'Fonts\CascadiaMono.ttf'))
            }
            [void]$ttfCands.Add('X:\Windows\Fonts\cascadiamono.ttf')
            if ($env:WINDIR) {
                [void]$ttfCands.Add((Join-Path $env:WINDIR 'Fonts\cascadiamono.ttf'))
                [void]$ttfCands.Add((Join-Path $env:WINDIR 'Fonts\seguisym.ttf'))
            }
            foreach ($tp in $ttfCands) {
                if ($tp -and (Test-Path -LiteralPath $tp)) {
                    try { [void][FbPeConFont]::LoadPrivateTtf($tp) } catch {}
                }
            }
        } catch {}
        $ok = [bool][FbPeConFont]::EnsureOnce()
        $script:FbPeFontEnsured = $true
        return $ok
    } catch {
        $script:FbPeFontEnsured = $true
        return $false
    }
}

# --- Glyphs (box-drawing via code points; unused Write-Rule/Write-Row share these) --
$g = @{
    TL  = [char]0x2554; TR  = [char]0x2557; BL  = [char]0x255A; BR  = [char]0x255D
    H   = [char]0x2550; V   = [char]0x2551
    LTL = [char]0x250C; LTR = [char]0x2510; LBL = [char]0x2514; LBR = [char]0x2518
    LH  = [char]0x2500; LV  = [char]0x2502
}
try { $null = Initialize-FbPeConsole } catch {}

$width = 78
try {
    $w = [Console]::WindowWidth
    if ($w -gt 40) { $width = [Math]::Min($w - 2, 100) }
} catch {}
$inner = $width - 2

function Write-Rule {
    param([string] $Left, [string] $Right, [char] $Fill, [string] $Color = 'DarkCyan')
    Write-Host ('  ' + $Left + ([string]$Fill * $inner) + $Right) -ForegroundColor $Color
}

function Write-Row {
    param([string] $Content, [string] $Edge, [string] $Color = 'DarkCyan', [string] $TextColor = 'Gray')
    if ($Content.Length -gt $inner) { $Content = $Content.Substring(0, $inner) }
    Write-Host ('  ' + $Edge) -ForegroundColor $Color -NoNewline
    Write-Host $Content.PadRight($inner) -ForegroundColor $TextColor -NoNewline
    Write-Host $Edge -ForegroundColor $Color
}

# --- Build identity ----------------------------------------------------------
function Get-FbUiBuildInfo {
    $info = [ordered]@{ Dev = $false; Launcher = ''; Script = '' }
    if (-not $PSScriptRoot) { return $info }

    $identityPs1 = Join-Path $PSScriptRoot 'FirstBaseBuildIdentity.ps1'
    if (-not (Test-Path -LiteralPath $identityPs1)) { return $info }

    try {
        . $identityPs1
        $resolved = Get-FbBuildIdentityForScript -ScriptRoot $PSScriptRoot -Layout Deploy
        if ($resolved) {
            $info.Dev      = [bool]$resolved.Dev
            $info.Launcher = [string]$resolved.Launcher
            $info.Script   = [string]$resolved.Script
        }
    } catch {}
    return $info
}

# --- Splash header (replaces the old title ribbon) ---------------------------
# Same art language as Show-DeployBanner.ps1 so Init reveal and later paints
# share one look in the same console layout.
function Get-FbDeployWolfLines {
    # Keep in sync with Show-DeployBanner.ps1. Always U+28xx Braille silhouette.
    $rows = @(
        @(0x2880, 0x28FF, 0x28C6),
        @(0x28F6, 0x28FF, 0x28FF, 0x28F7, 0x28C6),
        @(0x28B8, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28F6, 0x28C4),
        @(0x28B8, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x2801),
        @(0x28FC, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28C7),
        @(0x28B9, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x2846),
        @(0x2838, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28E6, 0x2840),
        @(0x2800, 0x28BB, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28F6, 0x2844),
        @(0x2800, 0x2800, 0x28BB, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x2844),
        @(0x2800, 0x2800, 0x2800, 0x28BB, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28FF, 0x28E7),
        @(0x2800, 0x2800, 0x2800, 0x28B8, 0x28FF, 0x28FF, 0x285F, 0x28FF, 0x28FF, 0x28BF, 0x28FF, 0x28FF, 0x28FF, 0x2844),
        @(0x2800, 0x2800, 0x2800, 0x2818, 0x28FF, 0x28FF, 0x2847, 0x2818, 0x28FF, 0x284C, 0x28BF, 0x28FF, 0x28FF, 0x28FF, 0x28E6, 0x28E4, 0x2864),
        @(0x2800, 0x2800, 0x2800, 0x2880, 0x28FF, 0x28FF, 0x28C7, 0x28F0, 0x285F, 0x2800, 0x28B8, 0x28FF, 0x2808, 0x281B, 0x283B, 0x280B),
        @(0x2800, 0x2800, 0x2830, 0x283F, 0x28FF, 0x28FF, 0x281B, 0x281B, 0x2800, 0x2820, 0x28FE, 0x287F)
    )
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($row in $rows) {
        $sb = New-Object System.Text.StringBuilder
        foreach ($cp in @($row)) {
            [void]$sb.Append([char]$cp)
        }
        [void]$out.Add($sb.ToString())
    }
    return $out.ToArray()
}

function Get-FbUiSplashLines {
    param([string]$Subtitle = 'Install', [bool]$IsDev = $false)

    $innerW = 26
    function New-FbUiFrameLine([string] $s) {
        if ($s.Length -gt $innerW) { $s = $s.Substring(0, $innerW) }
        return ([char]0x2551) + $s.PadRight($innerW) + ([char]0x2551)
    }
    $fTop = ([char]0x2554) + ([string]([char]0x2550) * $innerW) + ([char]0x2557)
    $fBot = ([char]0x255A) + ([string]([char]0x2550) * $innerW) + ([char]0x255D)

    $subLabel = '   [ ' + $Subtitle + ' ]'
    $subTag   = if ($IsDev) { '  DEV' } else { '' }
    if (($subLabel.Length + $subTag.Length) -gt $innerW) {
        $subLabel = $subLabel.Substring(0, [Math]::Max($innerW - $subTag.Length, 0))
    }
    $subFill = ' ' * [Math]::Max($innerW - ($subLabel.Length + $subTag.Length), 0)

    $title = @(
        $fTop,
        (New-FbUiFrameLine ''),
        (New-FbUiFrameLine '   P R O J E C T'),
        (New-FbUiFrameLine '   L O N E W O L F'),
        (New-FbUiFrameLine ''),
        (New-FbUiFrameLine ($subLabel + $subTag)),
        (New-FbUiFrameLine ''),
        $fBot
    )

    $rows = $script:FbUiWolf.Count
    $top  = [int]([Math]::Max($rows - $title.Count, 0) / 2)
    $left = New-Object 'string[]' $rows
    for ($i = 0; $i -lt $rows; $i++) { $left[$i] = '' }
    for ($i = 0; $i -lt $title.Count; $i++) {
        $ri = $top + $i
        if ($ri -lt $rows) { $left[$ri] = $title[$i] }
    }

    return [pscustomobject]@{
        Left       = $left
        Wolf       = $script:FbUiWolf
        SubRow     = ($top + 5)
        SubLabel   = $subLabel
        SubTag     = $subTag
        SubFill    = $subFill
        LeftWidth  = ($innerW + 2)
        Rows       = $rows
    }
}

function Write-FbUiSplashHeader {
    param(
        [string]$Subtitle = 'Install',
        [bool]$IsDev = $false,
        [switch]$Animate
    )
    $script:FbUiWolf = Get-FbDeployWolfLines
    $pack = Get-FbUiSplashLines -Subtitle $Subtitle -IsDev $IsDev
    $pad = '  '
    $gap = '   '
    $bar = [string][char]0x2551
    $lmax = [int]$pack.LeftWidth

    if ($Animate) {
        Clear-Host
        Write-Host ''
        for ($r = 0; $r -lt $pack.Rows; $r++) {
            $lt = $pack.Left[$r]; if ($null -eq $lt) { $lt = '' }
            if ($r -eq $pack.SubRow) {
                Write-Host ($pad + $bar + $pack.SubLabel) -ForegroundColor Cyan -NoNewline
                if ($pack.SubTag) { Write-Host $pack.SubTag -ForegroundColor Red -NoNewline }
                Write-Host ($pack.SubFill + $bar) -ForegroundColor Cyan -NoNewline
            } else {
                Write-Host ($pad + $lt.PadRight($lmax)) -ForegroundColor Cyan -NoNewline
            }
            Write-Host ($gap + $pack.Wolf[$r]) -ForegroundColor Blue
            Start-Sleep -Milliseconds 20
        }
        try {
            $blinkRow = 1 + $pack.SubRow
            foreach ($c in @('DarkCyan', 'White', 'DarkCyan', 'White', 'Cyan')) {
                [Console]::SetCursorPosition(0, $blinkRow)
                Write-Host ($pad + $bar + $pack.SubLabel) -ForegroundColor $c -NoNewline
                if ($pack.SubTag) { Write-Host $pack.SubTag -ForegroundColor Red -NoNewline }
                Write-Host ($pack.SubFill + $bar) -ForegroundColor $c -NoNewline
                Start-Sleep -Milliseconds 120
            }
            [Console]::SetCursorPosition(0, 1 + $pack.Rows)
        } catch {}
        Write-Host ''
        return
    }

    Write-Host ''
    for ($r = 0; $r -lt $pack.Rows; $r++) {
        $lt = $pack.Left[$r]; if ($null -eq $lt) { $lt = '' }
        if ($r -eq $pack.SubRow) {
            Write-Host ($pad + $bar + $pack.SubLabel) -ForegroundColor Cyan -NoNewline
            if ($pack.SubTag) { Write-Host $pack.SubTag -ForegroundColor Red -NoNewline }
            Write-Host ($pack.SubFill + $bar) -ForegroundColor Cyan -NoNewline
        } else {
            Write-Host ($pad + $lt.PadRight($lmax)) -ForegroundColor Cyan -NoNewline
        }
        Write-Host ($gap + $pack.Wolf[$r]) -ForegroundColor Blue
    }
    Write-Host ''
}

# --- State -------------------------------------------------------------------
function Read-FbUiState {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop
        if (-not $raw) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

function Write-FbUiState($state) {
    try {
        $dir = Split-Path -Path $StateFile -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateFile -Encoding UTF8 -ErrorAction Stop
    } catch {}
}

function New-FbUiState {
    $build = Get-FbUiBuildInfo
    switch ($Dev) {
        'Yes' { $isDev = $true }
        'No'  { $isDev = $false }
        default { $isDev = [bool]$build.Dev }
    }

    $plan = @()
    if ($Steps) {
        $n = 0
        foreach ($s in ($Steps -split ';')) {
            $t = $s.Trim()
            if (-not $t) { continue }
            $n++
            $plan += [pscustomobject]@{ N = $n; Label = $t; State = 'pending' }
        }
    }

    return [pscustomobject]@{
        Workflow   = $Workflow
        Dev        = $isDev
        Launcher   = $build.Launcher
        Script     = $build.Script
        Steps      = $plan
        Current    = 0
        Detail     = ''
        Status     = 'running'
        Message    = ''
        Spin       = 0
        SpinCol    = -1
        SpinRow    = -1
        PlanEndRow = -1
        SplashDone = $false
        StartedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-FbUiSpinChar {
    param([int]$Index = 0, [string]$Status = 'running')
    if ($Status -eq 'done') { return '*' }
    if ($Status -eq 'fail') { return 'X' }
    $frames = @('|', '/', '-', '\')
    return $frames[[Math]::Abs($Index) % 4]
}

function Get-FbUiPaintLockPath {
    return ($StateFile + '.lock')
}

function Enter-FbUiPaintLock {
    try { Set-Content -LiteralPath (Get-FbUiPaintLockPath) -Value '1' -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
}

function Exit-FbUiPaintLock {
    try { Remove-Item -LiteralPath (Get-FbUiPaintLockPath) -Force -ErrorAction SilentlyContinue } catch {}
}

function Test-FbUiPaintLock {
    $lock = Get-FbUiPaintLockPath
    if (-not (Test-Path -LiteralPath $lock)) { return $false }
    try {
        $age = (Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime
        if ($age.TotalSeconds -gt 3) {
            Exit-FbUiPaintLock
            return $false
        }
    } catch { return $false }
    return $true
}

function Get-FbUiSpinTarget {
    # Prefer the coordinates captured while painting the active step. If those
    # are missing or land in the wolf header (Quick Update / destage race, or
    # CursorTop reporting 0), derive the row from PlanEndRow + the active index.
    param($Watch)
    $out = [pscustomobject]@{ Col = 3; Row = -1; EndRow = -1; Ok = $false }
    if (-not $Watch) { return $out }
    $col = 3
    $row = -1
    $endRow = -1
    try { if ($null -ne $Watch.SpinCol -and [int]$Watch.SpinCol -ge 0) { $col = [int]$Watch.SpinCol } } catch {}
    try { if ($null -ne $Watch.SpinRow) { $row = [int]$Watch.SpinRow } } catch {}
    try { if ($null -ne $Watch.PlanEndRow) { $endRow = [int]$Watch.PlanEndRow } } catch {}
    $total = 0
    $activeN = 0
    foreach ($s in @($Watch.Steps)) {
        $total++
        try {
            if ([string]$s.State -eq 'active') { $activeN = [int]$s.N }
        } catch {}
    }
    $firstStep = -1
    $computed = -1
    if ($endRow -ge 2 -and $total -gt 0) {
        $firstStep = $endRow - 1 - $total
        if ($activeN -gt 0) { $computed = $firstStep + ($activeN - 1) }
    }
    $use = $row
    $inPlan = $false
    if ($firstStep -ge 0 -and $endRow -gt $firstStep) {
        $inPlan = ($use -ge $firstStep -and $use -lt $endRow)
    }
    if (-not $inPlan -and $computed -ge 0) { $use = $computed }
    $out.Col = $col
    $out.Row = $use
    $out.EndRow = $endRow
    if ($use -ge 0 -and $col -ge 0) {
        if ($firstStep -ge 0) { $out.Ok = ($use -ge $firstStep -and ($endRow -lt 0 -or $use -lt $endRow)) }
        else { $out.Ok = ($use -ge 8) }
    }
    return $out
}

# --- Render ------------------------------------------------------------------
function Show-FbUiScreen($state) {
    try { [Console]::CursorVisible = $false } catch {}
    Enter-FbUiPaintLock
    try {
    Clear-Host

    # Splash branding is the header (no title ribbon).
    $wf = if ($state.Workflow) { [string]$state.Workflow } else { 'Install' }
    Write-FbUiSplashHeader -Subtitle $wf -IsDev ([bool]$state.Dev)

    # Step plan - spinner lives on the active step (no overall loading bar).
    $total = 0
    if ($state.Steps) { $total = @($state.Steps).Count }
    $spinIdx = 0
    try { $spinIdx = [int]$state.Spin } catch {}
    $spinCol = -1
    $spinRow = -1

    foreach ($s in @($state.Steps)) {
        $n = '{0,2}' -f $s.N
        switch ($s.State) {
            'done' {
                Write-Host ('   [ok]  ' + $n + '  ') -ForegroundColor DarkGreen -NoNewline
                Write-Host $s.Label -ForegroundColor DarkGray
            }
            'active' {
                Write-Host '   ' -NoNewline
                try {
                    $spinCol = [Console]::CursorLeft
                    $spinRow = [Console]::CursorTop
                } catch { $spinCol = -1; $spinRow = -1 }
                $spinChar = Get-FbUiSpinChar -Index $spinIdx -Status ([string]$state.Status)
                Write-Host $spinChar -ForegroundColor Cyan -NoNewline
                Write-Host ('     ' + $n + '  ') -ForegroundColor Cyan -NoNewline
                Write-Host $s.Label -ForegroundColor White
                try {
                    $state.SpinCol = $spinCol
                    $state.SpinRow = $spinRow
                } catch {}
            }
            'fail' {
                Write-Host ('   [!!]  ' + $n + '  ') -ForegroundColor Red -NoNewline
                Write-Host $s.Label -ForegroundColor Red
            }
            default {
                Write-Host ('         ' + $n + '  ') -ForegroundColor DarkGray -NoNewline
                Write-Host $s.Label -ForegroundColor DarkGray
            }
        }
    }
    if ($total -gt 0) { Write-Host '' }

    $planEndRow = 0
    try { $planEndRow = [Console]::CursorTop } catch {}
    try { $state.PlanEndRow = $planEndRow } catch {}
    # Persist spinner coordinates before releasing the paint lock so SpinWatch
    # cannot read the previous Step's SpinRow=-1 and freeze the glyph.
    Write-FbUiState $state

    # Leave the cursor on the reserved row under the step list so DISM apply
    # (and any other same-console writer) paints *below* the plan, not over it.
    # SpinWatch keeps the active-step glyph moving; do not animate here - a
    # same-process sleep races the background watcher and steals CursorTop.
    try {
        if ($planEndRow -ge 0) { [Console]::SetCursorPosition(0, $planEndRow) }
    } catch {}

    if ($state.Message) {
        $msgColor = if ($state.Status -eq 'fail') { 'Red' } else { 'Green' }
        foreach ($line in ([string]$state.Message -split "`n")) {
            Write-Host ('   ' + $line.TrimEnd()) -ForegroundColor $msgColor
        }
        Write-Host ''
    } elseif ($state.Status -eq 'fail' -or $state.Status -eq 'done') {
        $detail = [string]$state.Detail
        if ($detail) {
            Write-Host ('   ' + $detail) -ForegroundColor Gray
            Write-Host ''
        }
    }

    } finally {
        Exit-FbUiPaintLock
    }
}

# --- Main --------------------------------------------------------------------
try {
    $state = Read-FbUiState
    $doSplashReveal = $false

    switch ($Action) {
        'Init' {
            $state = New-FbUiState
            if ($Text) { $state.Detail = $Text }
            if (-not $SkipSplashReveal) { $doSplashReveal = $true }
        }

        'Step' {
            if (-not $state) { $state = New-FbUiState }
            if ($Step -gt 0) {
                $state.Current = $Step - 1
                foreach ($s in @($state.Steps)) {
                    if ($s.N -lt $Step) {
                        if ($s.State -ne 'fail') { $s.State = 'done' }
                    } elseif ($s.N -eq $Step) {
                        $s.State = 'active'
                        if ($Label) { $s.Label = $Label }
                    }
                }
                if ($Label) { $state.Detail = $Label }
            }
            if ($Text) { $state.Detail = $Text }
            try { $state.Spin = (([int]$state.Spin) + 1) % 4 } catch { $state.Spin = 1 }
        }

        'Detail' {
            if (-not $state) { $state = New-FbUiState }
            $state.Detail = $Text
            try { $state.Spin = (([int]$state.Spin) + 1) % 4 } catch { $state.Spin = 1 }
        }

        'Fail' {
            if (-not $state) { $state = New-FbUiState }
            $state.Status = 'fail'
            foreach ($s in @($state.Steps)) { if ($s.State -eq 'active') { $s.State = 'fail' } }
            $msg = 'DEPLOYMENT FAILED'
            if ($Reason) { $msg += "`n" + $Reason }
            if ($Text) { $msg += "`n" + $Text }
            if ($LogFile -and (Test-Path -LiteralPath $LogFile)) {
                try {
                    $lines = Get-Content -LiteralPath $LogFile -Tail $Tail -ErrorAction Stop
                    if ($lines) { $msg += "`n`nLast $Tail log lines:`n" + (($lines | ForEach-Object { '  ' + $_ }) -join "`n") }
                } catch {}
            }
            $state.Message = $msg
            $state.Detail = 'Halted'
        }

        'Done' {
            if (-not $state) { $state = New-FbUiState }
            $state.Status = 'done'
            foreach ($s in @($state.Steps)) { if ($s.State -ne 'fail') { $s.State = 'done' } }
            if ($state.Steps) { $state.Current = @($state.Steps).Count }
            $msg = if ($Text) { $Text } else { 'Image application complete. Remove the USB drive.' }
            if ($Reason) { $msg += "`n" + $Reason }
            $state.Message = $msg
            $state.Detail = 'Complete'
        }

        'SpinWatch' {
            # Detached same-console poller: keep the active-step spinner moving
            # between TechInstall Step/Detail calls (those are separate processes).
            # Read-only on the state file - rewriting it raced Step/DISM and
            # dropped SpinRow to 0 (a '/' over the splash). Restore the cursor
            # to PlanEndRow after each glyph so the apply bar stays below steps.
            try { [Console]::CursorVisible = $false } catch {}
            $frames = @('|', '/', '-', '\')
            $idle = 0
            $idx = 0
            while ($idle -lt 18000) {
                if (Test-FbUiPaintLock) {
                    Start-Sleep -Milliseconds 180
                    $idle++
                    continue
                }
                $watch = Read-FbUiState
                if (-not $watch) {
                    # Init/Step may not have flushed JSON yet (Quick Update destage).
                    # Exiting here leaves a frozen glyph for the rest of the apply.
                    Start-Sleep -Milliseconds 180
                    $idle++
                    continue
                }
                $st = [string]$watch.Status
                if ($st -ne 'running') { break }
                $tgt = Get-FbUiSpinTarget -Watch $watch
                $idx = ($idx + 1) % 4
                if ($tgt.Ok) {
                    try {
                        [Console]::SetCursorPosition([int]$tgt.Col, [int]$tgt.Row)
                        Write-Host $frames[$idx] -ForegroundColor Cyan -NoNewline
                    } catch {}
                }
                if ([int]$tgt.EndRow -ge 2) {
                    try { [Console]::SetCursorPosition(0, [int]$tgt.EndRow) } catch {}
                }
                Start-Sleep -Milliseconds 180
                $idle++
            }
            exit 0
        }

        default { if (-not $state) { $state = New-FbUiState } }
    }

    if ($Action -ne 'SpinWatch') {
        if ($doSplashReveal) {
            Write-FbUiSplashHeader -Subtitle ([string]$state.Workflow) -IsDev ([bool]$state.Dev) -Animate
            $state.SplashDone = $true
        }

        Write-FbUiState $state
        Show-FbUiScreen $state
        # Persist spin index advanced during the on-screen animation.
        Write-FbUiState $state
    }
} catch {
    try { Write-Host ("  [{0}] {1} {2}" -f $Action, $Label, $Text) } catch {}
}

exit 0
