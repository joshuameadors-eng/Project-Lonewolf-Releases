<#
.SYNOPSIS
    FirstBase pre-seal OOBE handoff indicator (non-blocking).
.DESCRIPTION
    Visual status only. Shown while the OOBE handoff prepares, while hardware
    checks actually run, and while sealing or a fail-restart is in progress.
    It must never arm RunOnce / scheduled tasks, never wait for an
    Acknowledge click, and never delay shutdown or restart. Callers
    launch it with Start-Process (no Wait) so the pipeline keeps moving.
#>

[CmdletBinding()]
param(
    # Off-device preview. Redirects logs into a temp sandbox.
    [switch]$Preview,

    # What the device is doing. Callers pass this explicitly.
    [ValidateSet('preparing-handoff', 'restart-for-checks', 'running-checks', 'checks-pass', 'checks-fail', 'sealing', 'gate-fail-restart', 'close-wait')]
    [string]$Phase = 'preparing-handoff',

    # Auto-close after N seconds (default long enough to read; reboot also kills it).
    [int]$AutoCloseSeconds = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$script:PreviewMode = [bool]$Preview
$script:PhaseName = $Phase
$script:FbSplashLogoB64 = $null
if ($AutoCloseSeconds -lt 5) { $AutoCloseSeconds = 5 }
if ($AutoCloseSeconds -gt 120) { $AutoCloseSeconds = 120 }

if ($script:PreviewMode) {
    $FbRoot = Join-Path $env:TEMP (Join-Path 'FirstBaseHandoffPreview' $Phase)
    $FbPd = Join-Path $FbRoot 'ProgramData'
} else {
    $FbRoot = 'C:\Windows\Setup\FirstBase'
    $FbPd = 'C:\ProgramData\FirstBase'
}
$FbStateDir = Join-Path $FbRoot 'State'
$LockPath = Join-Path $FbStateDir 'handoff-indicator.lock'
$LogPath = Join-Path $FbPd 'firstbase-handoff-splash.log'
$lockStream = $null

function Write-FbHandoffLog {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        if (-not (Test-Path -LiteralPath $FbPd)) {
            New-Item -ItemType Directory -Path $FbPd -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value ('[{0}] [{1}] [pid={2}] {3}' -f (Get-Date -Format 'o'), $Level, $PID, $Message) -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

function Get-FbSplashLogoB64 {
    if ($null -ne $script:FbSplashLogoB64 -and $script:FbSplashLogoB64.Length -gt 0) {
        return $script:FbSplashLogoB64
    }
    $candidates = @(
        (Join-Path $PSScriptRoot 'Show-UpdateProgress.ps1'),
        'C:\Windows\Setup\FirstBase\Show-UpdateProgress.ps1'
    )
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
            $m = [regex]::Match($raw, '\$script:FbSplashLogoB64\s*=\s*''([^'']+)''')
            if ($m.Success) {
                $script:FbSplashLogoB64 = $m.Groups[1].Value
                return $script:FbSplashLogoB64
            }
        } catch {}
    }
    return $null
}

function Set-FbWpfLogoBrush {
    param([System.Windows.Media.ImageBrush]$LogoBrush)
    if (-not $LogoBrush) { return }
    $b64 = Get-FbSplashLogoB64
    if ([string]::IsNullOrWhiteSpace($b64)) { return }
    try {
        $logoBytes = [Convert]::FromBase64String($b64)
        $logoMs = New-Object System.IO.MemoryStream(,$logoBytes)
        $bmpImg = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmpImg.BeginInit()
        $bmpImg.CacheOption = 'OnLoad'
        $bmpImg.StreamSource = $logoMs
        $bmpImg.EndInit()
        $bmpImg.Freeze()
        $LogoBrush.ImageSource = $bmpImg
    } catch {
        Write-FbHandoffLog ("Logo load failed: {0}" -f $_.Exception.Message) 'WARN'
    }
}

function Get-FbHandoffCopy {
    param([string]$Name)
    switch ($Name) {
        'running-checks' {
            @{
                Eyebrow = 'HARDWARE CHECKS IN PROGRESS'
                Header  = 'Verifying Wi-Fi, camera, and sound'
                Detail  = 'FirstBase is confirming Windows can see the microphone, speakers, camera, and Wi-Fi (scan capable). Volume sliders are usable when active audio endpoints exist.'
                Next    = 'No action needed. Checks continue automatically.'
                Status  = 'Running hardware checks'
                Accent  = '#FF22D3EE'
            }
        }
        'checks-pass' {
            @{
                Eyebrow = 'HARDWARE CHECKS PASSED'
                Header  = 'Opening a private YouTube window'
                Detail  = 'Wi-Fi, camera, and sound are visible to Windows. Close the YouTube window when you are done to seal and restart into Windows setup.'
                Next    = 'A private browser window opens next. Closing it continues to customer OOBE. Walking away does not shut the device down.'
                Status  = 'Checks passed'
                Accent  = '#FF66BB6A'
            }
        }
        'checks-fail' {
            @{
                Eyebrow = 'HARDWARE CHECKS FAILED'
                Header  = 'Opening Windows Settings'
                Detail  = 'One or more of Wi-Fi, camera, or sound is not visible to Windows. Close Settings to remove FirstBase scripts and restart.'
                Next    = 'Settings opens next. Closing it scrubs scripts (logs and markers stay) and restarts - it does not shut down.'
                Status  = 'Checks failed'
                Accent  = '#FFEF5350'
            }
        }
        'sealing' {
            @{
                Eyebrow = 'SEALING'
                Header  = 'Finishing preparation'
                Detail  = 'Hardware checks passed. FirstBase is writing seal markers and removing deployment scripts. The device will restart into Windows setup (OOBE).'
                Next    = 'Restart continues automatically. FirstBase will not run again after this reboot.'
                Status  = 'Sealing'
                Accent  = '#FF66BB6A'
            }
        }
        'close-wait' {
            @{
                Eyebrow = 'WAITING ON YOU'
                Header  = 'Close YouTube or Settings to continue'
                Detail  = 'FirstBase will not seal or restart until you close the private YouTube window or Sound settings. Walking away does not shut the device down.'
                Next    = 'Close the YouTube window (pass) or Settings (fail). The device stays on until you do.'
                Status  = 'Waiting for you to close the window'
                Accent  = '#FFF0C14B'
            }
        }
        'gate-fail-restart' {
            @{
                Eyebrow = 'HARDWARE CHECK FAILED'
                Header  = 'Restarting after a failed check'
                Detail  = 'Scripts are being removed (logs and markers stay). The device will restart into Windows setup (OOBE). FirstBase will not run as defaultuser0.'
                Next    = 'Leave the device powered on. Restart into customer OOBE is already in progress.'
                Status  = 'Restarting after failed checks'
                Accent  = '#FFF0C14B'
            }
        }
        'restart-for-checks' {
            @{
                Eyebrow = 'OOBE HANDOFF'
                Header  = 'Restarting to continue preparation'
                Detail  = 'Windows still needs a restart before FirstBase can run hardware checks in this session.'
                Next    = 'Leave the device powered on. After restart, Wi-Fi, camera, and sound checks run automatically.'
                Status  = 'Restarting to continue'
                Accent  = '#FF22D3EE'
            }
        }
        default {
            @{
                Eyebrow = 'OOBE HANDOFF'
                Header  = 'Preparing hardware checks'
                Detail  = 'Updates are complete. FirstBase will verify Wi-Fi, camera, and sound in this session, then open YouTube or Settings.'
                Next    = 'No action needed until a YouTube window or Settings appears.'
                Status  = 'Preparing hardware checks'
                Accent  = '#FF22D3EE'
            }
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath $FbStateDir)) {
        New-Item -ItemType Directory -Path $FbStateDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $lockStream = [System.IO.File]::Open(
        $LockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $stamp = [System.Text.Encoding]::ASCII.GetBytes(("pid={0}`nphase={1}`nstarted={2}`n" -f $PID, $script:PhaseName, (Get-Date -Format 'o')))
        $lockStream.SetLength(0)
        $lockStream.Write($stamp, 0, $stamp.Length)
        $lockStream.Flush()
    } catch {}
} catch [System.IO.IOException] {
    Write-FbHandoffLog 'Another handoff indicator already owns the lock; exiting without blocking the pipeline.'
    exit 0
} catch {
    Write-FbHandoffLog ("Could not acquire handoff lock: {0}; continuing to show indicator anyway." -f $_.Exception.Message) 'WARN'
}

try {
    $copy = Get-FbHandoffCopy -Name $script:PhaseName

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FirstBase Handoff"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        WindowState="Maximized"
        ResizeMode="NoResize"
        Topmost="True"
        Background="#FF000000"
        ShowInTaskbar="False">
    <Grid Background="#FF000000">
    <Viewbox Stretch="Uniform" StretchDirection="Both" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
        <Grid Name="DesignCanvas" Width="1280" Height="800" Background="#FF000000">
            <Grid.RowDefinitions>
                <RowDefinition Height="44"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Name="DevBuildIndicator" Grid.Row="0" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="16,0,0,0" Padding="10,4,10,4" Background="#FF2A0A0A" BorderBrush="#FFEF5350" BorderThickness="1" CornerRadius="14" Visibility="Collapsed">
                <TextBlock Name="DevBuildIndicatorText" Text="DEV" FontSize="12" Foreground="#FFEF5350" FontWeight="SemiBold"/>
            </Border>
            <StackPanel Grid.Row="1" HorizontalAlignment="Center" Margin="0,4,0,14">
                <Grid Name="LogoHost" Width="168" Height="168" HorizontalAlignment="Center">
                    <Ellipse Width="168" Height="168">
                        <Ellipse.Fill>
                            <ImageBrush x:Name="LogoBrush" Stretch="UniformToFill" Viewbox="0.06,0.06,0.88,0.88"/>
                        </Ellipse.Fill>
                    </Ellipse>
                    <Ellipse Width="168" Height="168" Stroke="#FF22D3EE" StrokeThickness="2.5"/>
                </Grid>
                <TextBlock HorizontalAlignment="Center" Margin="0,12,0,0">
                    <Run Text="Project " Foreground="#FFFFFFFF" FontSize="33" FontWeight="Light"/><Run Text="LoneWolf" Foreground="#FF22D3EE" FontSize="33" FontWeight="Light"/>
                </TextBlock>
                <TextBlock Text="FirstBase For Internal Use Only" Foreground="#FFEF5350" FontSize="14" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,4,0,0"/>
            </StackPanel>
            <Border Grid.Row="2" Width="1060" MaxWidth="1060" Background="#FF071428" BorderBrush="#FF22D3EE" BorderThickness="1" CornerRadius="10" Padding="50,38" HorizontalAlignment="Center" VerticalAlignment="Center" MinHeight="280">
                <StackPanel>
                    <Border Name="PassStatusHost" HorizontalAlignment="Center" VerticalAlignment="Center" Padding="12,4,12,4" Background="#FF050A12" BorderBrush="#FFFF9800" BorderThickness="1" CornerRadius="14" Margin="0,0,0,22">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Name="PassStatusLabel" Text="STATUS" FontSize="11" FontWeight="Bold" Foreground="#FFFF9800" VerticalAlignment="Center" Margin="0,0,8,0"/>
                            <TextBlock Name="PassText" Text="Preparing OOBE handoff" FontSize="13" FontFamily="Segoe UI" FontWeight="SemiBold" Foreground="#FFFF9800" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Border>
                    <TextBlock Name="EyebrowText" Text="OOBE HANDOFF" Foreground="#FF22D3EE" FontSize="14" FontWeight="Bold" HorizontalAlignment="Center"/>
                    <TextBlock Name="HeaderText" Text="Preparing hardware checks" Foreground="White" FontSize="32" FontWeight="SemiBold" TextAlignment="Center" HorizontalAlignment="Center" TextWrapping="Wrap" Margin="0,14,0,10"/>
                    <TextBlock Name="DetailText" Text="" Foreground="#FF87CEEB" FontSize="18" TextAlignment="Center" TextWrapping="Wrap" HorizontalAlignment="Center" MaxWidth="760"/>
                    <Border Background="#FF050A12" BorderBrush="#FF1E4A7A" BorderThickness="1" CornerRadius="5" Padding="22,18" Margin="0,28,0,0">
                        <StackPanel>
                            <TextBlock Text="WHAT HAPPENS NEXT" Foreground="#FF6B8CB0" FontSize="12" FontWeight="Bold"/>
                            <TextBlock Name="NextStepText" Text="" Foreground="White" FontSize="17" TextWrapping="Wrap" Margin="0,8,0,0"/>
                        </StackPanel>
                    </Border>
                </StackPanel>
            </Border>
        </Grid>
    </Viewbox>
    </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $eyebrowText = $window.FindName('EyebrowText')
    $headerText = $window.FindName('HeaderText')
    $detailText = $window.FindName('DetailText')
    $nextStepText = $window.FindName('NextStepText')
    $passText = $window.FindName('PassText')
    $logoBrush = $window.FindName('LogoBrush')
    $devBuildIndicator = $window.FindName('DevBuildIndicator')
    $devBuildIndicatorText = $window.FindName('DevBuildIndicatorText')

    Set-FbWpfLogoBrush -LogoBrush $logoBrush

    try {
        $techMenu = Join-Path $PSScriptRoot 'FirstBaseSplashTechMenu.ps1'
        if (-not (Test-Path -LiteralPath $techMenu)) {
            $techMenu = 'C:\Windows\Setup\FirstBase\WUPayload\FirstBaseSplashTechMenu.ps1'
        }
        if (Test-Path -LiteralPath $techMenu) {
            . $techMenu
            Register-FbSplashTechChrome -Window $window -WriteLog { param($m, $l) Write-FbHandoffLog $m $l }
            if (-not $script:PreviewMode) { Enable-FbSplashNoMinimize -Window $window }
            Write-FbHandoffLog 'tech chrome: radial menu armed' 'INFO'
        }
    } catch {
        Write-FbHandoffLog ("tech chrome failed: {0}" -f $_.Exception.Message) 'WARN'
    }

    try {
        $fbIdentityPs1 = Join-Path $PSScriptRoot 'FirstBaseBuildIdentity.ps1'
        if (-not (Test-Path -LiteralPath $fbIdentityPs1)) {
            $fbIdentityPs1 = 'C:\Windows\Setup\FirstBase\FirstBaseBuildIdentity.ps1'
        }
        if (Test-Path -LiteralPath $fbIdentityPs1) {
            . $fbIdentityPs1
            $fbIdentity = Get-FbBuildIdentityForScript -ScriptRoot $PSScriptRoot -Layout Payload
            if ($fbIdentity -and $fbIdentity.Dev -and $devBuildIndicator) {
                $devBuildIndicator.Visibility = [System.Windows.Visibility]::Visible
                if ($devBuildIndicatorText) {
                    $devLabel = 'DEV'
                    $devVer = if ($fbIdentity.Launcher) { $fbIdentity.Launcher } else { '' }
                    if ($devVer) { $devLabel = "DEV  v$devVer" }
                    $devBuildIndicatorText.Text = $devLabel
                }
            }
        }
    } catch {
        Write-FbHandoffLog ("DEV pill resolve failed (release assumed): {0}" -f $_.Exception.Message) 'WARN'
    }

    $eyebrowText.Text = [string]$copy.Eyebrow
    $eyebrowText.Foreground = $copy.Accent
    $headerText.Text = [string]$copy.Header
    $detailText.Text = [string]$copy.Detail
    $nextStepText.Text = [string]$copy.Next
    if ($passText) {
        $statusLine = [string]$copy.Status
        if ([string]::IsNullOrWhiteSpace($statusLine)) { $statusLine = 'Preparing OOBE handoff' }
        $passText.Text = $statusLine
    }

    if ($script:PreviewMode) {
        $window.Title = ('FirstBase Handoff - PREVIEW ({0})' -f $script:PhaseName)
        $window.ShowInTaskbar = $true
        $window.WindowStyle = [System.Windows.WindowStyle]::SingleBorderWindow
        $window.WindowState = [System.Windows.WindowState]::Normal
        $window.Width = 1100
        $window.Height = 820
        $window.Topmost = $false
        $window.ResizeMode = [System.Windows.ResizeMode]::CanResize
    }

    $script:FbHandoffRemain = [int]$AutoCloseSeconds

    $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $closeTimer.Interval = [TimeSpan]::FromSeconds(1)
    $closeTimer.Add_Tick({
        try {
            if ($script:FbSplashFbImOpen -or $script:FbSplashRadialOpen) { return }
            $script:FbHandoffRemain--
            if ($script:FbHandoffRemain -le 0) {
                $closeTimer.Stop()
                try { $window.Close() } catch {}
            }
        } catch {}
    })
    $closeTimer.Start()
    $window.Add_Closed({ try { $closeTimer.Stop() } catch {} })

    $window.Add_Loaded({
        try {
            $script:SplashNativeHwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        } catch {}
        try { Invoke-FbSplashCoverScreen -Window $window } catch {}
    })

    if (-not $script:PreviewMode) {
        $zTimer = New-Object System.Windows.Threading.DispatcherTimer
        $zTimer.Interval = [TimeSpan]::FromSeconds(1.5)
        $zTimer.Add_Tick({
            try {
                try {
                    if (Test-FbSplashNeedsCoverScreen -Window $window) {
                        Invoke-FbSplashCoverScreen -Window $window
                    }
                } catch {}
                $yield = $false
                try { $yield = [bool](Invoke-FbSplashHonorOperatorForeground) } catch { $yield = $false }
                if (-not $yield) {
                    $window.Topmost = $true
                    try {
                        $hw = $script:SplashNativeHwnd
                        if ($hw -ne [IntPtr]::Zero) {
                            $flags = [uint32]([FbSplashWin32Z]::SWP_NOMOVE -bor [FbSplashWin32Z]::SWP_NOSIZE -bor [FbSplashWin32Z]::SWP_NOACTIVATE -bor [FbSplashWin32Z]::SWP_SHOWWINDOW)
                            [void][FbSplashWin32Z]::SetWindowPos($hw, [FbSplashWin32Z]::HWND_TOPMOST, 0, 0, 0, 0, $flags)
                        }
                    } catch {}
                    try { [void]$window.Activate() } catch {}
                }
            } catch {}
        })
        $zTimer.Start()
        $window.Add_Closed({ try { $zTimer.Stop() } catch {} })
        $window.Add_KeyDown({
            param($sender, $eventArgs)
            if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
                try {
                    if ($script:FbSplashFbImOpen) { Hide-FbSplashFbImHost; $eventArgs.Handled = $true; return }
                    if ($script:FbSplashRadialOpen) { Hide-FbSplashRadialMenu; $eventArgs.Handled = $true; return }
                } catch {}
            }
        })
    }

    # Esc closes early in preview only - production must not require operator input.
    if ($script:PreviewMode) {
        $window.Add_KeyDown({
            param($sender, $eventArgs)
            if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
                $eventArgs.Handled = $true
                try { $window.Close() } catch {}
            }
        })
    }

    Write-FbHandoffLog ("Showing non-blocking handoff indicator phase='{0}' autoClose={1}s preview={2}." -f $script:PhaseName, $AutoCloseSeconds, $script:PreviewMode)
    # ShowDialog keeps the WPF dispatcher alive in this dedicated process.
    # Callers must Start-Process without -Wait so the pipeline is never blocked.
    [void]$window.ShowDialog()
} catch {
    Write-FbHandoffLog ("Handoff indicator failed safely (pipeline continues): {0}" -f $_.Exception.Message) 'ERROR'
} finally {
    if ($null -ne $lockStream) {
        try { $lockStream.Close() } catch {}
        try { $lockStream.Dispose() } catch {}
    }
}

exit 0
