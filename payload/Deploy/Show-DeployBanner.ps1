<#
    Show-DeployBanner.ps1  (Project LoneWolf)

    ScriptVersion: 1.1.4  (5.4.24: private-load cascadiamono.ttf then Braille)

    Animated, colored WinPE deploy banner. Rendered with Write-Host
    -ForegroundColor so it works in the WinPE PowerShell console with no
    VT/ANSI dependency. Framed "PROJECT / LONEWOLF" title on the left, a blue
    Braille wolf on the right, a top-down line-by-line reveal, then a blinking
    subtitle.

      -Subtitle : workflow tag under the title (e.g. "Updates" / "No Updates").
      -Dev      : Auto (detect from the stick), Yes or No. Auto is the default;
                  Yes/No exist so the banner can be previewed off a stick.

    2318: a dev-built stick shows a red DEV tag beside the workflow tag and a red
    version footer. Detection is self-contained - the banner reads LW_VERSION.json
    from the payload root (the parent of this Deploy folder, i.e. FirstBase\ on a
    nested stick), which both workflows stamp, and falls back to
    WUPayload\.dev-build, which only Updates builds carry. Nothing is passed in
    from TechInstall.cmd.

    NOTE: the wolf is the original Braille silhouette (U+28xx) built from code
    points so this file stays ASCII. Frames are box-drawing from code points
    (5.4.8). WinPE raster OEM has no U+28xx: private-load staged
    Deploy\Fonts\cascadiamono.ttf (AddFontResourceEx), then select Cascadia
    Mono / Cascadia Code after probing U+28FF (once). Snapshot and restore
    window+buffer once; chcp 65001 once. Displayed wolf is always U+28xx.
    Keep in sync with Invoke-FbDeployUi.ps1.
#>
param(
    [string] $Subtitle = 'Install',

    [ValidateSet('Auto', 'Yes', 'No')]
    [string] $Dev = 'Auto'
)

$ErrorActionPreference = 'SilentlyContinue'

# --- Console font / encoding (once per process) ------------------------------
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

# --- Build identity (dev flag + versions) ------------------------------------
# Runs before anything is drawn: the banner is the first thing WinPE shows, and
# at that point only paths relative to this script are known-good ($SRC is not
# resolved yet, and the data volume's drive letter varies per machine).
#
# The decision itself lives in FirstBaseBuildIdentity.ps1, staged into this same
# Deploy\ folder, so the banner, the deploy screen, the on-device splashes and
# fb-im all answer "is this a dev build?" identically. If that file is missing
# the build is treated as RELEASE - a dev stick losing its tag is cosmetic,
# whereas a release build claiming DEV is the failure mode worth avoiding.
function Get-FbBannerBuildInfo {
    $info = [ordered]@{
        Dev           = $false
        Launcher      = ''
        Script        = ''
        ShareLauncher = ''
        ShareScript   = ''
    }
    if (-not $PSScriptRoot) { return $info }

    $identityPs1 = Join-Path $PSScriptRoot 'FirstBaseBuildIdentity.ps1'
    if (-not (Test-Path -LiteralPath $identityPs1)) { return $info }

    try {
        . $identityPs1
        $resolved = Get-FbBuildIdentityForScript -ScriptRoot $PSScriptRoot -Layout Deploy
        if ($resolved) {
            $info.Dev           = [bool]$resolved.Dev
            $info.Launcher      = [string]$resolved.Launcher
            $info.Script        = [string]$resolved.Script
            $info.ShareLauncher = [string]$resolved.ShareLauncher
            $info.ShareScript   = [string]$resolved.ShareScript
        }
    } catch {}

    return $info
}

$build = Get-FbBannerBuildInfo
switch ($Dev) {
    'Yes' { $isDev = $true }
    'No'  { $isDev = $false }
    default { $isDev = [bool]$build.Dev }
}

# --- Blue wolf (always U+28xx Braille; keep in sync with DeployUi) ----------
function Get-FbDeployWolfLines {
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
try { $null = Initialize-FbPeConsole } catch {}
$wolf = Get-FbDeployWolfLines

# --- Framed title (left column) ---------------------------------------------
# Box-drawing glyphs are emitted from code points so this .ps1 stays ASCII.
$innerW = 26
function New-FbFrameLine([string] $s) {
    if ($s.Length -gt $innerW) { $s = $s.Substring(0, $innerW) }
    return ([char]0x2551) + $s.PadRight($innerW) + ([char]0x2551)
}
$fTop = ([char]0x2554) + ([string]([char]0x2550) * $innerW) + ([char]0x2557)
$fBot = ([char]0x255A) + ([string]([char]0x2550) * $innerW) + ([char]0x255D)

# The subtitle row is the only one drawn in pieces, so the DEV tag can be red
# while the frame around it stays cyan. Both pieces are kept here so the reveal
# and the blink render identical text.
$subLabel = '   [ ' + $Subtitle + ' ]'
$subTag   = if ($isDev) { '  DEV' } else { '' }
if (($subLabel.Length + $subTag.Length) -gt $innerW) {
    $subLabel = $subLabel.Substring(0, [Math]::Max($innerW - $subTag.Length, 0))
}
$subFill = ' ' * [Math]::Max($innerW - ($subLabel.Length + $subTag.Length), 0)

$title = @(
    $fTop,
    (New-FbFrameLine ''),
    (New-FbFrameLine '   P R O J E C T'),
    (New-FbFrameLine '   L O N E W O L F'),
    (New-FbFrameLine ''),
    (New-FbFrameLine ($subLabel + $subTag)),
    (New-FbFrameLine ''),
    $fBot
)
$subTitleIdx = 5   # index within $title of the subtitle row

# --- Compose the left column, vertically centered against the wolf ----------
$rows = $wolf.Count
$top  = [int]([Math]::Max($rows - $title.Count, 0) / 2)
$left = New-Object 'string[]' $rows
for ($i = 0; $i -lt $rows; $i++) { $left[$i] = '' }
for ($i = 0; $i -lt $title.Count; $i++) {
    $ri = $top + $i
    if ($ri -lt $rows) { $left[$ri] = $title[$i] }
}
$subRow = $top + $subTitleIdx
$lmax   = $innerW + 2
$pad    = '  '
$gap    = '   '

# Writes the subtitle row without a trailing newline: frame + label in $Color,
# the DEV tag always red. Column widths match the single-write rows above.
$bar = [string][char]0x2551
function Write-FbSubtitleRow {
    param([string] $Color = 'Cyan')
    Write-Host ($pad + $bar + $subLabel) -ForegroundColor $Color -NoNewline
    if ($subTag) { Write-Host $subTag -ForegroundColor Red -NoNewline }
    Write-Host ($subFill + $bar) -ForegroundColor $Color -NoNewline
}

# --- Reveal top-down --------------------------------------------------------
Clear-Host
Write-Host ''
for ($r = 0; $r -lt $rows; $r++) {
    $lt = $left[$r]; if ($null -eq $lt) { $lt = '' }
    if ($r -eq $subRow) {
        Write-FbSubtitleRow -Color Cyan
    } else {
        Write-Host ($pad + $lt.PadRight($lmax)) -ForegroundColor Cyan -NoNewline
    }
    Write-Host ($gap + $wolf[$r]) -ForegroundColor Blue
    Start-Sleep -Milliseconds 20
}

# --- Blink the subtitle a few times -----------------------------------------
try {
    $blinkRow = 1 + $subRow
    foreach ($c in @('DarkCyan', 'White', 'DarkCyan', 'White', 'Cyan')) {
        [Console]::SetCursorPosition(0, $blinkRow)
        Write-FbSubtitleRow -Color $c
        Start-Sleep -Milliseconds 150
    }
    [Console]::SetCursorPosition(0, 1 + $rows)
} catch {}
Write-Host ''

# --- Version footer ----------------------------------------------------------
# Doubles as the visual confirmation that the stick in the machine is the one
# that was just built: the numbers change every build, so an operator can tell a
# stale stick from a fresh one without opening a log.
$verParts = @()
if ($build.Launcher) { $verParts += ('launcher ' + $build.Launcher) }
if ($build.Script)   { $verParts += ('scripts '  + $build.Script) }
if ($verParts.Count -gt 0) {
    if ($isDev) {
        $shareParts = @()
        if ($build.ShareLauncher) { $shareParts += $build.ShareLauncher }
        if ($build.ShareScript)   { $shareParts += $build.ShareScript }
        $line = '  [ DEV BUILD ]  ' + ($verParts -join '   ')
        if ($shareParts.Count -gt 0) { $line += ('   (share ' + ($shareParts -join ' / ') + ')') }
        Write-Host $line -ForegroundColor Red
    } else {
        Write-Host ('  ' + ($verParts -join '   ')) -ForegroundColor DarkGray
    }
    Write-Host ''
} elseif ($isDev) {
    Write-Host '  [ DEV BUILD ]' -ForegroundColor Red
    Write-Host ''
}

