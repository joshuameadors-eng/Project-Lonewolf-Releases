#Requires -Version 5.1
<#
.SYNOPSIS
    Splash logo radial menu + on-device fb-im embed + operator-over-splash z-order.

.DESCRIPTION
    Dotsourced by Show-UpdateProgress.ps1 and FirstBaseHandoffSplash.ps1.
    Click the wolf for a left/bottom/right arc (fb-im, Close, Restart, UEFI).
    fb-im loads from C:\Windows\Setup\FirstBase when present - a USB stick is
    not required to open tools. Collect logs still needs a removable stick or
    a folder the operator maps.

    Z-order: keep splash above OOBE (caller still runs HWND_TOPMOST + 2214l).
    Settings / Explorer sit above the splash. Cmd / conhost stay in the topmost
    band above OOBE but behind the splash.
#>

Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'

function Ensure-FbSplashTechWin32 {
    try { $null = [FbSplashWin32Z]; return } catch {}
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FbSplashWin32Z {
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;
    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
}
'@ -ErrorAction Stop
    } catch {}
}

function Write-FbSplashTechLog {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        if ($script:FbSplashTechLog) {
            & $script:FbSplashTechLog $Message $Level
            return
        }
    } catch {}
    try { Write-Host ("[splash-tech] {0}" -f $Message) } catch {}
}

function Get-FbSplashWindowText {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return '' }
    try {
        $sb = New-Object System.Text.StringBuilder 512
        [void][FbSplashWin32Z]::GetWindowText($Hwnd, $sb, $sb.Capacity)
        return [string]$sb.ToString()
    } catch { return '' }
}

function Get-FbSplashWindowKind {
    param(
        [string]$ProcessName,
        [string]$Title = '',
        [int]$ProcessId = 0
    )
    if ($ProcessId -ne 0 -and $ProcessId -eq $PID) { return 'splash' }
    $n = ([string]$ProcessName).ToLowerInvariant()
    $title = ([string]$Title).ToLowerInvariant()
    $operatorNames = @(
        'systemsettings', 'explorer', 'taskmgr', 'mmc', 'notepad', 'control', 'regedit'
    )
    if ($operatorNames -contains $n) { return 'operator' }
    # Win11 Settings often lives in ApplicationFrameHost. OOBE uses it too -
    # only treat titled Settings windows as operator.
    if ($n -eq 'applicationframehost' -and $title -match 'setting') { return 'operator' }

    $consoleNames = @('cmd', 'conhost', 'windowsterminal', 'wt', 'powershell_ise', 'pwsh')
    if ($consoleNames -contains $n -or ($n -eq 'powershell' -and $ProcessId -ne $PID)) {
        return 'console'
    }

    $oobeNames = @('oobeldr', 'useroobebroker', 'cloudexperiencehost', 'shellexperiencehost', 'wwahost')
    if ($oobeNames -contains $n) { return 'oobe' }
    if ($n -eq 'applicationframehost') { return 'oobe' }
    if ($n) { return 'operator' }
    return 'splash'
}

function Get-FbSplashForegroundKind {
    # splash | oobe | operator | console
    $info = [ordered]@{ Kind = 'splash'; Hwnd = [IntPtr]::Zero; Name = ''; Title = '' }
    try {
        $null = [FbSplashWin32Z]
        $fg = [FbSplashWin32Z]::GetForegroundWindow()
        $info.Hwnd = $fg
        if ($fg -eq [IntPtr]::Zero) { return [pscustomobject]$info }
        if ($script:SplashNativeHwnd -ne [IntPtr]::Zero -and $fg -eq $script:SplashNativeHwnd) {
            $info.Kind = 'splash'
            return [pscustomobject]$info
        }
        $pidFg = [uint32]0
        [void][FbSplashWin32Z]::GetWindowThreadProcessId($fg, [ref]$pidFg)
        if ($pidFg -eq 0) { return [pscustomobject]$info }
        if ([int]$pidFg -eq $PID) {
            $info.Kind = 'splash'
            return [pscustomobject]$info
        }
        $procName = ''
        try {
            $p = Get-Process -Id ([int]$pidFg) -ErrorAction SilentlyContinue
            if ($p) { $procName = [string]$p.ProcessName }
        } catch {}
        $info.Name = $procName
        $info.Title = Get-FbSplashWindowText -Hwnd $fg
        $info.Kind = Get-FbSplashWindowKind -ProcessName $procName -Title $info.Title -ProcessId ([int]$pidFg)
        return [pscustomobject]$info
    } catch {
        $info.Kind = 'splash'
        return [pscustomobject]$info
    }
}

function Find-FbSplashYieldWindows {
    # Visible operator windows that must stay above splash even when splash
    # is still WS_EX_TOPMOST (Settings, Explorer, etc.). Console is excluded.
    $found = New-Object System.Collections.Generic.List[object]
    $splashHw = $script:SplashNativeHwnd
    try { $null = [FbSplashWin32Z] } catch { return @() }
    try {
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            $h = [IntPtr]::Zero
            try { $h = $_.MainWindowHandle } catch { return }
            if ($h -eq [IntPtr]::Zero) { return }
            if ($splashHw -ne [IntPtr]::Zero -and $h -eq $splashHw) { return }
            try { if ([int]$_.Id -eq $PID) { return } } catch {}
            try { if ([FbSplashWin32Z]::IsIconic($h)) { return } } catch {}
            try { if (-not [FbSplashWin32Z]::IsWindowVisible($h)) { return } } catch {}
            $title = Get-FbSplashWindowText -Hwnd $h
            $kind = Get-FbSplashWindowKind -ProcessName $_.ProcessName -Title $title -ProcessId ([int]$_.Id)
            if ($kind -ne 'operator') { return }
            $found.Add([pscustomobject]@{ Hwnd = $h; Name = [string]$_.ProcessName; Title = $title })
        }
    } catch {}
    return @($found)
}

function Invoke-FbSplashRaiseYieldWindows {
    param($Windows, [switch]$ActivateFirst)
    try {
        $null = [FbSplashWin32Z]
        $flags = [uint32]([FbSplashWin32Z]::SWP_NOMOVE -bor [FbSplashWin32Z]::SWP_NOSIZE -bor [FbSplashWin32Z]::SWP_NOACTIVATE -bor [FbSplashWin32Z]::SWP_SHOWWINDOW)
        foreach ($w in @($Windows)) {
            if (-not $w -or $w.Hwnd -eq [IntPtr]::Zero) { continue }
            [void][FbSplashWin32Z]::SetWindowPos($w.Hwnd, [FbSplashWin32Z]::HWND_TOPMOST, 0, 0, 0, 0, $flags)
        }
        if ($ActivateFirst) {
            $first = @($Windows) | Select-Object -First 1
            if ($first -and $first.Hwnd -ne [IntPtr]::Zero) {
                try { [void][FbSplashWin32Z]::SetForegroundWindow($first.Hwnd) } catch {}
            }
        }
    } catch {}
}

function Invoke-FbSplashParkConsoleBehindSplash {
    # Console (Shift+F10 cmd) stays in the topmost band above OOBE, but splash
    # is restacked last so the prompt is hidden behind the splash.
    param($FgInfo)
    try {
        $null = [FbSplashWin32Z]
        $hwSplash = $script:SplashNativeHwnd
        $con = $FgInfo.Hwnd
        if ($hwSplash -eq [IntPtr]::Zero -or $con -eq [IntPtr]::Zero) { return }
        $flags = [uint32]([FbSplashWin32Z]::SWP_NOMOVE -bor [FbSplashWin32Z]::SWP_NOSIZE -bor [FbSplashWin32Z]::SWP_NOACTIVATE -bor [FbSplashWin32Z]::SWP_SHOWWINDOW)
        [void][FbSplashWin32Z]::SetWindowPos($con, [FbSplashWin32Z]::HWND_TOPMOST, 0, 0, 0, 0, $flags)
        [void][FbSplashWin32Z]::SetWindowPos($hwSplash, [FbSplashWin32Z]::HWND_TOPMOST, 0, 0, 0, 0, $flags)
    } catch {}
}

function Invoke-FbSplashRaiseOperatorAbove {
    param($FgInfo)
    if (-not $FgInfo) { return }
    Invoke-FbSplashRaiseYieldWindows -Windows @($FgInfo) -ActivateFirst:$false
}

function Test-FbSplashShouldYieldToOperator {
    $wins = @(Find-FbSplashYieldWindows)
    if ($wins.Count -gt 0) { return $true }
    $fg = Get-FbSplashForegroundKind
    return ($fg.Kind -eq 'operator')
}

function Invoke-FbSplashHonorOperatorForeground {
    # Keep Settings / Explorer / other operator windows above splash without
    # restacking splash to HWND_TOPMOST first (that flash-covers the operator
    # window on every 1.5s tick). Returns $true if the caller must skip
    # splash Activate / HWND_TOPMOST refresh this tick. OOBE stays behind via
    # 2214l. Console stays parked behind splash.
    try {
        $fg = Get-FbSplashForegroundKind
        if ($fg.Kind -eq 'console') {
            Invoke-FbSplashParkConsoleBehindSplash -FgInfo $fg
        }
        $wins = New-Object System.Collections.Generic.List[object]
        foreach ($w in @(Find-FbSplashYieldWindows)) { [void]$wins.Add($w) }
        if ($fg.Kind -eq 'operator' -and $fg.Hwnd -ne [IntPtr]::Zero) {
            $already = $false
            foreach ($w in $wins) {
                if ($w.Hwnd -eq $fg.Hwnd) { $already = $true; break }
            }
            if (-not $already) { [void]$wins.Add($fg) }
        }
        if ($wins.Count -lt 1) {
            $script:FbSplashYieldLatched = $false
            return $false
        }
        $rising = -not [bool]$script:FbSplashYieldLatched
        $script:FbSplashYieldLatched = $true
        Invoke-FbSplashRaiseYieldWindows -Windows $wins -ActivateFirst:$rising
        return $true
    } catch { return $false }
}

function Find-FbSplashFbImScript {
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(
            'C:\Windows\Setup\FirstBase\Tools\fb-im.ps1',
            'C:\Windows\Setup\FirstBase\WUPayload\Tools\fb-im.ps1'
        )) { [void]$cands.Add($p) }
    if ($PSScriptRoot) {
        [void]$cands.Add((Join-Path $PSScriptRoot 'Tools\fb-im.ps1'))
        [void]$cands.Add((Join-Path $PSScriptRoot 'fb-im.ps1'))
        try {
            $parent = Split-Path -Path $PSScriptRoot -Parent
            if ($parent) {
                [void]$cands.Add((Join-Path $parent 'Tools\fb-im.ps1'))
                [void]$cands.Add((Join-Path $parent 'WUPayload\Tools\fb-im.ps1'))
            }
        } catch {}
    }
    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue | ForEach-Object {
            $root = $_.DeviceID + '\'
            [void]$cands.Add((Join-Path $root 'FirstBase\WUPayload\Tools\fb-im.ps1'))
            [void]$cands.Add((Join-Path $root 'WUPayload\Tools\fb-im.ps1'))
        }
    } catch {}
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Import-FbSplashFbImLibrary {
    if (Get-Module -Name FbImSplash -ErrorAction SilentlyContinue) { return $true }
    $path = Find-FbSplashFbImScript
    if (-not $path) {
        Write-FbSplashTechLog 'fb-im.ps1 not found on device (C: payload) or USB.' 'WARN'
        return $false
    }
    try {
        New-Module -Name FbImSplash -ScriptBlock {
            param([string]$FbImPath)
            Set-StrictMode -Off
            $ErrorActionPreference = 'SilentlyContinue'
            . $FbImPath -Library
            Export-ModuleMember -Function * -Variable * -Alias *
        } -ArgumentList $path | Import-Module -Global -Force
        Write-FbSplashTechLog ("fb-im library loaded from {0}" -f $path) 'INFO'
        return $true
    } catch {
        Write-FbSplashTechLog ("fb-im library import failed: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Set-FbSplashBusyOverlay {
    param([string]$Text = '', [switch]$Hide)
    $ov = $script:FbSplashBusyOverlay
    $tx = $script:FbSplashBusyText
    if (-not $ov) { return }
    if ($Hide) {
        try { $ov.Visibility = [System.Windows.Visibility]::Collapsed } catch {}
        try { $ov.IsHitTestVisible = $false } catch {}
        try { $ov.Opacity = 0 } catch {}
        return
    }
    if ($tx -and $Text) { try { $tx.Text = $Text } catch {} }
    try { $ov.Opacity = 1 } catch {}
    try { $ov.IsHitTestVisible = $true } catch {}
    try { $ov.Visibility = [System.Windows.Visibility]::Visible } catch {}
}

function Hide-FbSplashRadialMenu {
    $layer = $script:FbSplashRadialLayer
    if (-not $layer) { return }
    if (-not $script:FbSplashRadialOpen -and $layer.Visibility -ne [System.Windows.Visibility]::Visible) { return }
    $script:FbSplashRadialOpen = $false
    try {
        $easeIn = New-Object System.Windows.Media.Animation.CubicEase
        $easeIn.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fade.To = 0.0
        $fade.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(160))
        $fade.EasingFunction = $easeIn
        $fade.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
        $layer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
        foreach ($item in @($script:FbSplashRadialItems)) {
            $st = $item.Scale
            if ($st) {
                $sc = $fade.Clone()
                $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $sc)
                $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $sc.Clone())
            }
        }
        $done = New-Object System.Windows.Threading.DispatcherTimer
        $done.Interval = [TimeSpan]::FromMilliseconds(180)
        $done.Add_Tick({
            try { $args[0].Stop() } catch {}
            try {
                $ly = $script:FbSplashRadialLayer
                if ($ly -and -not $script:FbSplashRadialOpen) {
                    $ly.Visibility = [System.Windows.Visibility]::Collapsed
                    $ly.IsHitTestVisible = $false
                    $ly.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                    $ly.Opacity = 1
                }
                if ($script:FbSplashUpdatesPanel) { $script:FbSplashUpdatesPanel.Effect = $null }
            } catch {}
        })
        $done.Start()
    } catch {
        try { $layer.Visibility = [System.Windows.Visibility]::Collapsed } catch {}
        try { $layer.IsHitTestVisible = $false } catch {}
        try { if ($script:FbSplashUpdatesPanel) { $script:FbSplashUpdatesPanel.Effect = $null } } catch {}
    }
}

function Update-FbSplashRadialItemPositions {
    $layer = $script:FbSplashRadialLayer
    $logo = $script:FbSplashLogoHost
    $canvas = $script:FbSplashDesignCanvas
    if (-not $layer -or -not $logo -or -not $canvas) { return }
    try {
        $origin = $logo.TransformToVisual($canvas).Transform((New-Object System.Windows.Point(($logo.ActualWidth / 2.0), ($logo.ActualHeight / 2.0))))
    } catch { return }
    $cx = [double]$origin.X
    $cy = [double]$origin.Y
    $script:FbSplashRadialLogoX = $cx
    $script:FbSplashRadialLogoY = $cy
    $orbit = 172.0
    $halfW = 40.0
    $halfCircle = 34.0
    $maxX = [double]$canvas.ActualWidth
    $maxY = [double]$canvas.ActualHeight
    if ($maxX -lt 100) { $maxX = 1280 }
    if ($maxY -lt 100) { $maxY = 800 }
    foreach ($item in @($script:FbSplashRadialItems)) {
        if (-not $item.Button) { continue }
        $rad = [math]::PI * [double]$item.Deg / 180.0
        $x = $cx + [math]::Cos($rad) * $orbit - $halfW
        $y = $cy + [math]::Sin($rad) * $orbit - $halfCircle
        if ($x -lt 8) { $x = 8 }
        if ($y -lt 48) { $y = 48 }
        if ($x -gt ($maxX - 88)) { $x = $maxX - 88 }
        if ($y -gt ($maxY - 110)) { $y = $maxY - 110 }
        $item.TargetX = $x
        $item.TargetY = $y
        if ($script:FbSplashRadialOpen) {
            try {
                [System.Windows.Controls.Canvas]::SetLeft($item.Button, $x)
                [System.Windows.Controls.Canvas]::SetTop($item.Button, $y)
            } catch {}
        }
    }
}

function Show-FbSplashRadialMenu {
    if ($script:FbSplashFbImOpen) { return }
    $layer = $script:FbSplashRadialLayer
    if (-not $layer) { return }
    Update-FbSplashRadialItemPositions
    $cx = [double]$script:FbSplashRadialLogoX
    $cy = [double]$script:FbSplashRadialLogoY
    try { $layer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null) } catch {}
    $layer.Opacity = 0
    try { $layer.Visibility = [System.Windows.Visibility]::Visible } catch {}
    try { $layer.IsHitTestVisible = $true } catch {}
    $script:FbSplashRadialOpen = $true
    try {
        if ($script:FbSplashUpdatesPanel) {
            $script:FbSplashUpdatesPanel.Effect = (New-Object System.Windows.Media.Effects.BlurEffect -Property @{ Radius = 8 })
        }
    } catch {}

    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fadeIn.From = 0.0
    $fadeIn.To = 1.0
    $fadeIn.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(220))
    $fadeIn.EasingFunction = $ease
    $layer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)

    $i = 0
    foreach ($item in @($script:FbSplashRadialItems)) {
        $btn = $item.Button
        if (-not $btn) { continue }
        $tx = [double]$item.TargetX
        $ty = [double]$item.TargetY
        $startX = $cx - 40.0
        $startY = $cy - 34.0
        try {
            [System.Windows.Controls.Canvas]::SetLeft($btn, $startX)
            [System.Windows.Controls.Canvas]::SetTop($btn, $startY)
        } catch {}
        $st = $item.Scale
        if ($st) {
            $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
            $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
            $st.ScaleX = 0.28
            $st.ScaleY = 0.28
        }
        $delay = [TimeSpan]::FromMilliseconds(30 * $i)
        $moveMs = 280
        $ax = New-Object System.Windows.Media.Animation.DoubleAnimation
        $ax.From = $startX
        $ax.To = $tx
        $ax.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($moveMs))
        $ax.BeginTime = $delay
        $ax.EasingFunction = $ease
        $ay = $ax.Clone()
        $ay.From = $startY
        $ay.To = $ty
        $sc = New-Object System.Windows.Media.Animation.DoubleAnimation
        $sc.From = 0.28
        $sc.To = 1.0
        $sc.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($moveMs))
        $sc.BeginTime = $delay
        $sc.EasingFunction = $ease
        try {
            $btn.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty, $ax)
            $btn.BeginAnimation([System.Windows.Controls.Canvas]::TopProperty, $ay)
            if ($st) {
                $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $sc)
                $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $sc.Clone())
            }
        } catch {}
        $i++
    }
}

function Toggle-FbSplashRadialMenu {
    if ($script:FbSplashFbImOpen) { return }
    if ($script:FbSplashRadialOpen) { Hide-FbSplashRadialMenu } else { Show-FbSplashRadialMenu }
}

function Hide-FbSplashFbImHost {
    $hostGrid = $script:FbSplashFbImHost
    $script:FbSplashFbImOpen = $false
    try {
        if ($hostGrid) {
            $hostGrid.Visibility = [System.Windows.Visibility]::Collapsed
            $hostGrid.Children.Clear()
        }
    } catch {}
    Set-FbSplashBusyOverlay -Hide
}

function Show-FbSplashEmbeddedFbIm {
    Hide-FbSplashRadialMenu
    Set-FbSplashBusyOverlay -Hide
    if (-not (Import-FbSplashFbImLibrary)) {
        Set-FbSplashBusyOverlay 'fb-im was not found on this device.'
        Start-Sleep -Milliseconds 50
        try {
            $t = New-Object System.Windows.Threading.DispatcherTimer
            $t.Interval = [TimeSpan]::FromSeconds(2)
            $t.Add_Tick({
                try { $args[0].Stop() } catch {}
                Set-FbSplashBusyOverlay -Hide
            })
            $t.Start()
        } catch { Set-FbSplashBusyOverlay -Hide }
        return
    }
    $hostGrid = $script:FbSplashFbImHost
    if (-not $hostGrid) { return }
    try { $hostGrid.Children.Clear() } catch {}
    try { $hostGrid.Visibility = [System.Windows.Visibility]::Visible } catch {}
    $script:FbSplashFbImOpen = $true
    try {
        $cmd = Get-Command Show-FbImWindow -ErrorAction Stop
        & $cmd -EmbedHost $hostGrid -OnEmbedClose {
            Hide-FbSplashFbImHost
        }
    } catch {
        Write-FbSplashTechLog ("embed fb-im failed: {0}" -f $_.Exception.Message) 'WARN'
        Hide-FbSplashFbImHost
        Set-FbSplashBusyOverlay 'Could not open fb-im in the splash.'
    }
}

function Start-FbSplashOpenSettings {
    Hide-FbSplashRadialMenu
    Write-FbSplashTechLog 'tech tools: opening Windows Settings'
    $uri = 'ms-settings:'
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    if (-not (Test-Path -LiteralPath $cmdExe)) { $cmdExe = 'cmd.exe' }
    $explorerExe = Join-Path $env:SystemRoot 'explorer.exe'
    $opened = $false
    try {
        Start-Process -FilePath $cmdExe -ArgumentList @('/c', 'start', '""', $uri) -WindowStyle Hidden -ErrorAction Stop | Out-Null
        $opened = $true
    } catch {}
    if (-not $opened -and (Test-Path -LiteralPath $explorerExe)) {
        try {
            Start-Process -FilePath $explorerExe -ArgumentList $uri -WindowStyle Hidden -ErrorAction Stop | Out-Null
            $opened = $true
        } catch {}
    }
    if (-not $opened) {
        try {
            Start-Process -FilePath $uri -ErrorAction Stop | Out-Null
            $opened = $true
        } catch {}
    }
    if (-not $opened) {
        Write-FbSplashTechLog 'tech tools: could not open ms-settings:' 'WARN'
        Set-FbSplashBusyOverlay 'Could not open Settings.'
        try {
            $t = New-Object System.Windows.Threading.DispatcherTimer
            $t.Interval = [TimeSpan]::FromSeconds(2)
            $t.Add_Tick({
                try { $args[0].Stop() } catch {}
                Set-FbSplashBusyOverlay -Hide
            })
            $t.Start()
        } catch { Set-FbSplashBusyOverlay -Hide }
    }
}

function Start-FbSplashTechRestart {
    param([switch]$Firmware)
    Hide-FbSplashRadialMenu
    $label = if ($Firmware) { 'Restarting to UEFI...' } else { 'Restarting...' }
    Set-FbSplashBusyOverlay $label
    try {
        if (Get-Command Update-FbSplashRebootCountForManualRestart -ErrorAction SilentlyContinue) {
            [void](Update-FbSplashRebootCountForManualRestart)
        }
    } catch {}
    $shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    if (-not (Test-Path -LiteralPath $shutdown)) { $shutdown = 'shutdown.exe' }
    try {
        if ($Firmware) {
            Start-Process -FilePath $shutdown -ArgumentList @('/r', '/fw', '/f', '/t', '0') -WindowStyle Hidden -ErrorAction Stop | Out-Null
            return
        }
    } catch {
        Write-FbSplashTechLog ("UEFI restart failed, falling back to /r: {0}" -f $_.Exception.Message) 'WARN'
    }
    try {
        Start-Process -FilePath $shutdown -ArgumentList @('/r', '/f', '/t', '0') -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } catch {
        try { Restart-Computer -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function New-FbSplashRadialButton {
    param([string]$Caption, [string]$Glyph, [scriptblock]$Click)
    $btn = New-Object System.Windows.Controls.Button
    $btn.Width = 80
    $btn.Height = 104
    $btn.Cursor = [System.Windows.Input.Cursors]::Hand
    $btn.Background = [System.Windows.Media.Brushes]::Transparent
    $btn.BorderThickness = New-Object System.Windows.Thickness 0
    $btn.Padding = New-Object System.Windows.Thickness 0
    $btn.Focusable = $false

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.HorizontalAlignment = 'Center'
    $stack.VerticalAlignment = 'Top'

    $chip = New-Object System.Windows.Controls.Border
    $chip.Width = 68
    $chip.Height = 68
    $chip.CornerRadius = New-Object System.Windows.CornerRadius 34
    $chip.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF0A1B33')
    $chip.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
    $chip.BorderThickness = New-Object System.Windows.Thickness 1.5
    $chip.HorizontalAlignment = 'Center'
    $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $glow.Color = [System.Windows.Media.Color]::FromRgb(0x22, 0xD3, 0xEE)
    $glow.BlurRadius = 14
    $glow.ShadowDepth = 0
    $glow.Opacity = 0.55
    $chip.Effect = $glow

    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.Text = $Glyph
    $icon.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
    $icon.FontSize = 22
    $icon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFE8F4FF')
    $icon.HorizontalAlignment = 'Center'
    $icon.VerticalAlignment = 'Center'
    $icon.TextAlignment = 'Center'
    $chip.Child = $icon

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Caption
    $label.FontSize = 11
    $label.FontWeight = [System.Windows.FontWeights]::SemiBold
    $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFE8F4FF')
    $label.HorizontalAlignment = 'Center'
    $label.TextAlignment = 'Center'
    $label.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0

    [void]$stack.Children.Add($chip)
    [void]$stack.Children.Add($label)
    $btn.Content = $stack
    try {
        $btn.Template = [Windows.Markup.XamlReader]::Parse(@'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Top"/>
</ControlTemplate>
'@)
    } catch {}
    $btn.Add_MouseEnter({
        try {
            $c = $args[0].RadialChip
            if ($c) { $c.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF123154') }
        } catch {}
    })
    $btn.Add_MouseLeave({
        try {
            $c = $args[0].RadialChip
            if ($c) { $c.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF0A1B33') }
        } catch {}
    })
    $btn.Add_Click($Click)

    $st = New-Object System.Windows.Media.ScaleTransform 1, 1
    $btn.RenderTransform = $st
    $btn.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.34
    $btn | Add-Member -NotePropertyName RadialScale -NotePropertyValue $st -Force
    $btn | Add-Member -NotePropertyName RadialChip -NotePropertyValue $chip -Force
    return $btn
}

function Register-FbSplashTechChrome {
    param(
        [Parameter(Mandatory)] $Window,
        [scriptblock]$WriteLog
    )
    Ensure-FbSplashTechWin32
    $script:FbSplashTechLog = $WriteLog
    $script:FbSplashTechWindow = $Window
    $script:FbSplashLogoHost = $Window.FindName('LogoHost')
    $script:FbSplashDesignCanvas = $Window.FindName('DesignCanvas')
    if (-not $script:FbSplashDesignCanvas) {
        try { $script:FbSplashDesignCanvas = $Window.Content } catch {}
        # Handoff: Window -> Viewbox -> Grid
        try {
            if ($Window.Content -and $Window.Content.Child) {
                $script:FbSplashDesignCanvas = $Window.Content.Child
            }
        } catch {}
    }
    $script:FbSplashUpdatesPanel = $Window.FindName('UpdatesPanel')
    $script:FbSplashRadialOpen = $false
    $script:FbSplashFbImOpen = $false

    $canvas = $script:FbSplashDesignCanvas
    if (-not $canvas) {
        Write-FbSplashTechLog 'tech chrome: no DesignCanvas - radial menu skipped' 'WARN'
        return
    }

    $layer = New-Object System.Windows.Controls.Canvas
    $layer.Name = 'RadialLayer'
    $layer.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $layer.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
    $layer.Visibility = [System.Windows.Visibility]::Collapsed
    $layer.IsHitTestVisible = $false
    try { [System.Windows.Controls.Panel]::SetZIndex($layer, 80) } catch {}

    $dim = New-Object System.Windows.Shapes.Rectangle
    $dim.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CC000000')
    $dim.Width = 2000
    $dim.Height = 2000
    $dim.IsHitTestVisible = $true
    $dim.Add_MouseLeftButtonUp({
        try { Hide-FbSplashRadialMenu } catch {}
    })
    [void]$layer.Children.Add($dim)

    $script:FbSplashRadialItems = @()
    $spec = @(
        @{ Caption = 'fb-im'; Glyph = [string][char]0xE90F; Deg = 180; Click = { Show-FbSplashEmbeddedFbIm } }
        @{ Caption = 'Settings'; Glyph = [string][char]0xE713; Deg = 135; Click = { Start-FbSplashOpenSettings } }
        @{ Caption = 'Close'; Glyph = [string][char]0xE711; Deg = 90; Click = { Hide-FbSplashRadialMenu } }
        @{ Caption = 'Restart'; Glyph = [string][char]0xE72C; Deg = 8; Click = { Start-FbSplashTechRestart } }
        @{ Caption = 'UEFI'; Glyph = [string][char]0xE950; Deg = 48; Click = { Start-FbSplashTechRestart -Firmware } }
    )
    foreach ($s in $spec) {
        $btn = New-FbSplashRadialButton -Caption $s.Caption -Glyph $s.Glyph -Click $s.Click
        [void]$layer.Children.Add($btn)
        $script:FbSplashRadialItems += [pscustomobject]@{
            Deg     = $s.Deg
            Button  = $btn
            Scale   = $btn.RadialScale
            TargetX = 0.0
            TargetY = 0.0
        }
    }
    $script:FbSplashRadialLayer = $layer

    $busy = New-Object System.Windows.Controls.Border
    $busy.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#AA02040A')
    $busy.Visibility = [System.Windows.Visibility]::Collapsed
    $busy.IsHitTestVisible = $false
    $busy.Opacity = 0
    try { [System.Windows.Controls.Panel]::SetZIndex($busy, 200) } catch {}
    $busyText = New-Object System.Windows.Controls.TextBlock
    $busyText.Text = 'Working...'
    $busyText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
    $busyText.FontSize = 22
    $busyText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $busyText.HorizontalAlignment = 'Center'
    $busyText.VerticalAlignment = 'Center'
    $busy.Child = $busyText
    $script:FbSplashBusyOverlay = $busy
    $script:FbSplashBusyText = $busyText

    $imHost = New-Object System.Windows.Controls.Grid
    $imHost.Name = 'FbImHost'
    $imHost.Visibility = [System.Windows.Visibility]::Collapsed
    $imHost.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF02040A')
    try { [System.Windows.Controls.Panel]::SetZIndex($imHost, 120) } catch {}
    $script:FbSplashFbImHost = $imHost

    try {
        if ($canvas -is [System.Windows.Controls.Grid]) {
            $span = $canvas.RowDefinitions.Count
            if ($span -lt 1) { $span = 1 }
            [System.Windows.Controls.Grid]::SetRow($layer, 0)
            [System.Windows.Controls.Grid]::SetRowSpan($layer, $span)
            [System.Windows.Controls.Grid]::SetRow($busy, 0)
            [System.Windows.Controls.Grid]::SetRowSpan($busy, $span)
            [System.Windows.Controls.Grid]::SetRow($imHost, 0)
            [System.Windows.Controls.Grid]::SetRowSpan($imHost, $span)
        }
    } catch {}
    [void]$canvas.Children.Add($layer)
    [void]$canvas.Children.Add($busy)
    [void]$canvas.Children.Add($imHost)

    $logo = $script:FbSplashLogoHost
    if ($logo) {
        try { $logo.Cursor = [System.Windows.Input.Cursors]::Hand } catch {}
        try { $logo.ToolTip = 'Technician tools' } catch {}
        $logo.Add_MouseLeftButtonUp({
            try {
                if ($args.Count -ge 2 -and $args[1]) { $args[1].Handled = $true }
            } catch {}
            Toggle-FbSplashRadialMenu
        })
    }

    try {
        $Window.Add_SizeChanged({ Update-FbSplashRadialItemPositions })
    } catch {}
    Write-FbSplashTechLog 'tech chrome: radial menu registered' 'INFO'
}

function Test-FbSplashNeedsCoverScreen {
    param($Window)
    if (-not $Window) { return $false }
    try {
        if ($Window.WindowState -eq [System.Windows.WindowState]::Minimized) { return $true }
        $needW = [double][System.Windows.SystemParameters]::PrimaryScreenWidth
        $needH = [double][System.Windows.SystemParameters]::PrimaryScreenHeight
        $aw = [double]$Window.ActualWidth
        $ah = [double]$Window.ActualHeight
        if ($aw -lt 2) { $aw = [double]$Window.Width }
        if ($ah -lt 2) { $ah = [double]$Window.Height }
        if ($needW -gt 8 -and $aw -lt ($needW - 8)) { return $true }
        if ($needH -gt 8 -and $ah -lt ($needH - 8)) { return $true }
    } catch {}
    return $false
}

function Invoke-FbSplashCoverScreen {
    # WindowStyle=None + ResizeMode=NoResize + WindowState=Maximized sizes to the
    # Viewbox design canvas (1280x800) instead of the monitor. Pin the HWND to
    # the primary screen so desktop cannot show around the splash.
    param($Window)
    if (-not $Window) { return }
    if ($script:Preview -or $script:PreviewMode) { return }
    if ($script:FbSplashCoveringScreen) { return }
    $script:FbSplashCoveringScreen = $true
    try {
        $Window.WindowStyle = [System.Windows.WindowStyle]::None
        $Window.ResizeMode = [System.Windows.ResizeMode]::NoResize
        $Window.WindowState = [System.Windows.WindowState]::Normal
        $wDip = [double][System.Windows.SystemParameters]::PrimaryScreenWidth
        $hDip = [double][System.Windows.SystemParameters]::PrimaryScreenHeight
        if ($wDip -lt 640) { $wDip = 1280 }
        if ($hDip -lt 480) { $hDip = 800 }
        $Window.Left = 0
        $Window.Top = 0
        $Window.Width = $wDip
        $Window.Height = $hDip

        $hwnd = [IntPtr]::Zero
        try { $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($Window).Handle } catch {}
        if ($hwnd -eq [IntPtr]::Zero) { return }
        try { $null = [FbSplashWin32Z] } catch { return }
        $px = 0
        $py = 0
        $cx = [int][math]::Round($wDip)
        $cy = [int][math]::Round($hDip)
        try {
            $src = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
            if ($src -and $src.CompositionTarget) {
                $toDev = $src.CompositionTarget.TransformToDevice
                $px = [int][math]::Round(([double]$Window.Left) * $toDev.M11)
                $py = [int][math]::Round(([double]$Window.Top) * $toDev.M22)
                $cx = [int][math]::Round(([double]$Window.Width) * $toDev.M11)
                $cy = [int][math]::Round(([double]$Window.Height) * $toDev.M22)
            }
        } catch {}
        try {
            if ($cx -lt 640 -or $cy -lt 480) {
                $cx = [FbSplashWin32Z]::GetSystemMetrics(0)
                $cy = [FbSplashWin32Z]::GetSystemMetrics(1)
                $px = 0
                $py = 0
            }
        } catch {}
        $flags = [uint32]([FbSplashWin32Z]::SWP_NOZORDER -bor [FbSplashWin32Z]::SWP_NOACTIVATE -bor [FbSplashWin32Z]::SWP_SHOWWINDOW)
        [void][FbSplashWin32Z]::SetWindowPos($hwnd, [IntPtr]::Zero, $px, $py, $cx, $cy, $flags)
    } catch {
    } finally {
        $script:FbSplashCoveringScreen = $false
    }
}

function Enable-FbSplashNoMinimize {
    param($Window)
    if (-not $Window) { return }
    try { $Window.ResizeMode = [System.Windows.ResizeMode]::NoResize } catch {}
    try { Invoke-FbSplashCoverScreen -Window $Window } catch {}
    $Window.Add_StateChanged({
        try {
            if ($script:Preview -or $script:PreviewMode) { return }
            $w = $script:FbSplashTechWindow
            if (-not $w) { return }
            if ($w.WindowState -eq [System.Windows.WindowState]::Minimized -or (Test-FbSplashNeedsCoverScreen -Window $w)) {
                Invoke-FbSplashCoverScreen -Window $w
            }
        } catch {}
    })
}
