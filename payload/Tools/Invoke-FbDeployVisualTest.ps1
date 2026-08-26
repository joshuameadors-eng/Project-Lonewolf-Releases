<#
    Invoke-FbDeployVisualTest.ps1  (Project LoneWolf)

    Visual test harness for the WinPE PowerShell deploy screen and the two WPF
    splashes. Builds a throwaway sandbox under %TEMP% that mimics the on-stick
    layout (payload root with LW_VERSION.json + Deploy\), then opens one window
    per scenario so each surface can be eyeballed side by side.

    Nothing here touches a real device: the deploy UI writes its state into the
    sandbox, and the handoff splash is launched with -Preview so its arming
    cleanup (scheduled task / RunOnce / markers) is disabled.

      -Root      sandbox location (default %TEMP%\FirstBaseDeployVisualTest)
      -Only      run a subset, e.g. -Only deploy-dev,handoff-sealed
      -KeepRoot  do not delete an existing sandbox first
      -List      print the scenarios and exit

    Console scenarios open in their own window and stay open. WPF scenarios are
    full-screen and topmost - close each one before judging the next.
#>
[CmdletBinding()]
param(
    [string]   $Root = (Join-Path $env:TEMP 'FirstBaseDeployVisualTest'),
    [string[]] $Only,
    [switch]   $KeepRoot,
    [switch]   $List
)

$ErrorActionPreference = 'Stop'

# src\payload\Tools\ -> src\payload\
$PayloadRoot = Split-Path -Path $PSScriptRoot -Parent
$DeployUiSrc = Join-Path $PayloadRoot 'Deploy\Invoke-FbDeployUi.ps1'
$BannerSrc   = Join-Path $PayloadRoot 'Deploy\Show-DeployBanner.ps1'
$UpdateSplash = Join-Path $PayloadRoot 'Show-UpdateProgress.ps1'
$HandoffSplash = Join-Path $PayloadRoot 'FirstBaseHandoffSplash.ps1'
$IdentitySrc = Join-Path $PayloadRoot 'FirstBaseBuildIdentity.ps1'
$VersionSrc = Join-Path $PayloadRoot 'FirstBaseVersion.ps1'
$Ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$scenarios = @(
    @{ Id = 'deploy-dev';      Kind = 'console'; Text = 'Deploy screen - dev build, full 7-step run to completion' }
    @{ Id = 'deploy-fail';     Kind = 'console'; Text = 'Deploy screen - failure at step 4 with log tail' }
    @{ Id = 'deploy-release';  Kind = 'console'; Text = 'Deploy screen - release build (no DEV tag)' }
    @{ Id = 'banner-dev';      Kind = 'console'; Text = 'Animated WinPE banner - dev build' }
    @{ Id = 'splash-updates';  Kind = 'wpf';     Text = 'Updates splash - dev device, DEV pill SHOWN' }
    @{ Id = 'splash-release';  Kind = 'wpf';     Text = 'Updates splash - release device, NO DEV pill' }
    @{ Id = 'handoff-restart';  Kind = 'wpf';     Text = 'Handoff - restart-for-checks (pre-seal, non-blocking)' }
    @{ Id = 'handoff-checks';   Kind = 'wpf';     Text = 'Handoff - running-checks (pre-seal, non-blocking)' }
    @{ Id = 'handoff-pass';     Kind = 'wpf';     Text = 'Handoff - checks-pass (pre-seal, non-blocking)' }
    @{ Id = 'handoff-fail';     Kind = 'wpf';     Text = 'Handoff - checks-fail (pre-seal, non-blocking)' }
    @{ Id = 'handoff-sealing';  Kind = 'wpf';     Text = 'Handoff - sealing (pre-seal, non-blocking)' }
)

if ($List) {
    Write-Host ''
    Write-Host '  Scenarios:' -ForegroundColor Cyan
    foreach ($s in $scenarios) {
        Write-Host ('    {0,-16} {1,-8} {2}' -f $s.Id, ('[' + $s.Kind + ']'), $s.Text)
    }
    Write-Host ''
    return
}

foreach ($required in @($DeployUiSrc, $BannerSrc, $UpdateSplash, $HandoffSplash, $IdentitySrc)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing payload file: $required"
    }
}

if (-not $KeepRoot -and (Test-Path -LiteralPath $Root)) {
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

function New-FbDir([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# Two mock payload roots. The deploy UI derives dev/release and the version
# footer from LW_VERSION.json in the PARENT of its own Deploy folder, exactly
# as it does on a stick, so the sandbox has to reproduce that shape.
function New-FbMockPayload {
    param([string] $Path, [bool] $DevBuild, [string] $Launcher, [string] $Scripts)

    New-FbDir (Join-Path $Path 'Deploy')
    New-FbDir (Join-Path $Path 'WUPayload')
    Copy-Item -LiteralPath $DeployUiSrc -Destination (Join-Path $Path 'Deploy\Invoke-FbDeployUi.ps1') -Force
    Copy-Item -LiteralPath $BannerSrc   -Destination (Join-Path $Path 'Deploy\Show-DeployBanner.ps1') -Force
    # The banner and the deploy screen dot-source the shared resolver from their
    # own folder and fall back to release without it, so the mock stick has to
    # carry it exactly like a real build does.
    Copy-Item -LiteralPath $IdentitySrc -Destination (Join-Path $Path 'Deploy\FirstBaseBuildIdentity.ps1') -Force
    Copy-Item -LiteralPath $IdentitySrc -Destination (Join-Path $Path 'WUPayload\FirstBaseBuildIdentity.ps1') -Force

    $stamp = [ordered]@{
        builtBy              = 'LoneWolfLauncher'
        version              = $Launcher
        launcherVersion      = $Launcher
        scriptVersion        = $Scripts
        devBuild             = $DevBuild
        shareLauncherVersion = '5.2.108'
        shareScriptVersion   = '2319'
    }
    $stamp | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Path 'LW_VERSION.json') -Encoding UTF8

    if ($DevBuild) {
        Set-Content -LiteralPath (Join-Path $Path 'WUPayload\.dev-build') `
            -Value "devBuild=1`r`nlauncherVersion=$Launcher`r`nscriptVersion=$Scripts`r`n" -Encoding ASCII
    }
}

New-FbDir $Root
$devRoot     = Join-Path $Root 'dev'
$releaseRoot = Join-Path $Root 'release'
New-FbMockPayload -Path $devRoot     -DevBuild $true  -Launcher '5.2.113' -Scripts '2321'
New-FbMockPayload -Path $releaseRoot -DevBuild $false -Launcher '5.2.108' -Scripts '2319'

# A believable deploy log so the failure screen's log tail has real content.
$mockLog = Join-Path $Root 'FirstBase-Deploy.log'
@(
    '[2026-08-07 09:12:41.02] FirstBase deploy started'
    '[2026-08-07 09:12:41.05] TechInstall revision: 2026-08-07.1'
    '[2026-08-07 09:12:41.44] PRE: Source=D:'
    '[2026-08-07 09:12:42.10] SCRIPTVOL=D: PAYLOAD=D:\FirstBase'
    '[2026-08-07 09:12:58.31] Running disksetup from X:\disksetup.cmd'
    '[2026-08-07 09:13:44.77] MEDIADISK (install volume physical disk)=2 source=detail-volume-colon'
    '[2026-08-07 09:13:45.02] disksetup.cmd exit: 0'
    '[2026-08-07 09:14:02.88] Applying install.wim index 1 to W:'
    '[2026-08-07 09:16:31.19] DISM exit code: 1392'
    '[2026-08-07 09:16:31.20] ERROR: The file or directory is corrupted and unreadable.'
) | Set-Content -LiteralPath $mockLog -Encoding UTF8

$plan = 'WinPE initialized;Disk preparation;Source + image resolved;Applying Windows image;Staging post-install payload;Configuring boot + handoff;Finalizing + reboot'

function Start-FbTestWindow {
    param([string] $Title, [string[]] $ArgumentList)
    Start-Process -FilePath $Ps -ArgumentList $ArgumentList -WindowStyle Normal | Out-Null
    Write-Host ('  opened  ' + $Title) -ForegroundColor DarkGray
}

# Drives the deploy UI through a scenario inside one child window, so the
# operator sees the screen actually transition rather than a single frame.
function New-FbDeployDriver {
    param([string] $Name, [string] $PayloadRootPath, [string] $Mode)

    $ui = Join-Path $PayloadRootPath 'Deploy\Invoke-FbDeployUi.ps1'
    $state = Join-Path $Root ($Name + '.json')
    $driver = Join-Path $Root ($Name + '-driver.ps1')

    $body = @"
`$ui    = '$ui'
`$state = '$state'
`$plan  = '$plan'
`$log   = '$mockLog'
`$host.UI.RawUI.WindowTitle = 'FirstBase visual test - $Name'

# Hashtable splatting, not array splatting: an array splat passes its elements
# positionally, so -Action would arrive as a value rather than a parameter name.
function Ui { param([hashtable] `$p) & `$ui -StateFile `$state @p }

Ui @{ Action = 'Init'; Workflow = 'Updates'; Steps = `$plan }
Start-Sleep -Milliseconds 900

`$labels = `$plan -split ';'
`$stopAt = if ('$Mode' -eq 'fail') { 4 } else { `$labels.Count }

function Get-FbPreviewDismBar([int]`$Pct, [int]`$Width = 28) {
    `$p = [math]::Max(0, [math]::Min(100, `$Pct))
    `$filled = [int][math]::Floor(`$Width * `$p / 100.0)
    `$fullCh = [string][char]0x2588
    `$emptyCh = [string][char]0x2591
    return [pscustomobject]@{
        Filled = (`$fullCh * `$filled)
        Empty  = (`$emptyCh * (`$Width - `$filled))
        Pct    = `$p
    }
}
function Write-FbPreviewDismLine([int]`$Pct, [int]`$Row, [switch]`$Done) {
    `$parts = Get-FbPreviewDismBar `$Pct
    `$spinFrames = @('|', '/', '-', '\')
    `$spin = if (`$Done) { '*' } else { `$spinFrames[`$Pct % 4] }
    `$labelColor = if (`$Done) { 'DarkGreen' } else { 'Cyan' }
    `$pctColor   = if (`$Done) { 'Green' } else { 'White' }
    `$fillColor  = if (`$Done) { 'DarkGreen' } else { 'Cyan' }
    try { [Console]::SetCursorPosition(0, `$Row) } catch {}
    Write-Host '   ' -NoNewline
    Write-Host `$spin -ForegroundColor `$labelColor -NoNewline
    Write-Host '  Applying image  ' -ForegroundColor `$labelColor -NoNewline
    Write-Host '[' -ForegroundColor DarkCyan -NoNewline
    if (`$parts.Filled.Length -gt 0) { Write-Host `$parts.Filled -ForegroundColor `$fillColor -NoNewline }
    if (`$parts.Empty.Length -gt 0)  { Write-Host `$parts.Empty  -ForegroundColor DarkGray -NoNewline }
    Write-Host ']' -ForegroundColor DarkCyan -NoNewline
    Write-Host ('  {0,3}%' -f `$parts.Pct) -ForegroundColor `$pctColor -NoNewline
    Write-Host (' ' * 8) -NoNewline
}

for (`$i = 1; `$i -le `$stopAt; `$i++) {
    Ui @{ Action = 'Step'; Step = `$i; Label = `$labels[`$i - 1] }
    Start-Sleep -Milliseconds 700
    if (`$i -eq 4) {
        # Match themed Invoke-FirstBaseDismApply progress under the step list.
        `$row = [Console]::CursorTop
        `$pcts = if ('$Mode' -eq 'fail') { @(8, 18, 27, 34) } else { @(8, 18, 32, 48, 62, 75, 88, 96) }
        foreach (`$pct in `$pcts) {
            Write-FbPreviewDismLine -Pct `$pct -Row `$row
            Start-Sleep -Milliseconds 280
        }
        if ('$Mode' -ne 'fail') {
            Write-FbPreviewDismLine -Pct 100 -Row `$row -Done
            Write-Host ''
            Start-Sleep -Milliseconds 400
        } else {
            Write-Host ''
            Start-Sleep -Milliseconds 250
        }
    }
}

if ('$Mode' -eq 'fail') {
    Ui @{
        Action  = 'Fail'
        Reason  = 'DISM apply failed (exit 1392).'
        Text    = 'Exit code 4   Log: D:\FirstBase-Deploy.log'
        LogFile = `$log
    }
} else {
    Ui @{
        Action = 'Done'
        Text   = 'Image application complete. Remove the USB drive.'
        Reason = 'Press any key to continue and reboot...'
    }
}

Write-Host ''
Write-Host '  [visual test] scenario complete - close this window when done.' -ForegroundColor DarkGray
`$null = `$host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
"@
    Set-Content -LiteralPath $driver -Value $body -Encoding UTF8
    return $driver
}

# powershell.exe -File passes every argument as a literal string, so
# "-Only a,b,c" arrives as one element rather than three. Split it here so the
# harness behaves the same whether it is dot-sourced or launched with -File.
$onlySet = @()
foreach ($o in @($Only)) {
    if ($null -eq $o) { continue }
    foreach ($part in ([string]$o -split ',')) {
        $t = $part.Trim()
        if ($t) { $onlySet += $t }
    }
}
$run = { param([string] $Id) return ($onlySet.Count -eq 0) -or ($onlySet -contains $Id) }

Write-Host ''
Write-Host '  FirstBase deploy + splash visual test' -ForegroundColor Cyan
Write-Host ('  sandbox: ' + $Root) -ForegroundColor DarkGray
Write-Host ''

if (& $run 'deploy-dev') {
    $d = New-FbDeployDriver -Name 'deploy-dev' -PayloadRootPath $devRoot -Mode 'success'
    Start-FbTestWindow 'deploy-dev      (dev build, runs to completion)' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $d)
}
if (& $run 'deploy-fail') {
    $d = New-FbDeployDriver -Name 'deploy-fail' -PayloadRootPath $devRoot -Mode 'fail'
    Start-FbTestWindow 'deploy-fail     (fails at step 4, shows log tail)' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $d)
}
if (& $run 'deploy-release') {
    $d = New-FbDeployDriver -Name 'deploy-release' -PayloadRootPath $releaseRoot -Mode 'success'
    Start-FbTestWindow 'deploy-release  (release build, no DEV tag)' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $d)
}
if (& $run 'banner-dev') {
    $banner = Join-Path $devRoot 'Deploy\Show-DeployBanner.ps1'
    Start-FbTestWindow 'banner-dev      (animated banner, dev)' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', $banner, '-Subtitle', 'Updates'
    )
}
# Mock the on-device payload folder (C:\Windows\Setup\FirstBase) twice: once
# with the .dev-build marker TechInstall stages on a dev build, once without.
# The splash resolves its DEV pill from its own folder, so running it out of
# these two directories is what proves a release device stays unmarked.
function New-FbMockDevice {
    param([string] $Name, [bool] $DevBuild)
    $dir = Join-Path $Root $Name
    New-FbDir $dir
    Copy-Item -LiteralPath $UpdateSplash -Destination (Join-Path $dir 'Show-UpdateProgress.ps1') -Force
    Copy-Item -LiteralPath $IdentitySrc  -Destination (Join-Path $dir 'FirstBaseBuildIdentity.ps1') -Force
    if (Test-Path -LiteralPath $VersionSrc) {
        Copy-Item -LiteralPath $VersionSrc -Destination (Join-Path $dir 'FirstBaseVersion.ps1') -Force
    }
    if ($DevBuild) {
        Set-Content -LiteralPath (Join-Path $dir '.dev-build') `
            -Value "devBuild=1`r`nlauncherVersion=5.2.113`r`nscriptVersion=2321`r`n" -Encoding ASCII
    }
    return (Join-Path $dir 'Show-UpdateProgress.ps1')
}

if (& $run 'splash-updates') {
    $devSplash = New-FbMockDevice -Name 'device-dev' -DevBuild $true
    Start-FbTestWindow 'splash-updates  (WPF - dev device, expect DEV pill)' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $devSplash, '-Preview'
    )
}
if (& $run 'splash-release') {
    $relSplash = New-FbMockDevice -Name 'device-release' -DevBuild $false
    Start-FbTestWindow 'splash-release  (WPF - release device, expect NO pill)' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $relSplash, '-Preview'
    )
}
foreach ($h in @(
    @{ Id = 'handoff-restart'; Phase = 'restart-for-checks'; Label = 'handoff-restart (WPF - restart for driver checks)' }
    @{ Id = 'handoff-checks';  Phase = 'running-checks';    Label = 'handoff-checks  (WPF - hardware checks in progress)' }
    @{ Id = 'handoff-sealing'; Phase = 'sealing';           Label = 'handoff-sealing (WPF - sealing)' }
)) {
    if (& $run $h.Id) {
        Start-FbTestWindow $h.Label @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
            '-File', $HandoffSplash, '-Preview', '-Phase', $h.Phase, '-AutoCloseSeconds', '40'
        )
        Start-Sleep -Milliseconds 400
    }
}

Write-Host ''
Write-Host '  Check on each window:' -ForegroundColor Cyan
Write-Host '    deploy-dev      step markers advance; step 4 themed Applying image bar (cyan/green); DEV tag red'
Write-Host '    deploy-fail     step 4 partial themed bar then [!!] + log tail'
Write-Host '    deploy-release  same as deploy-dev without DEV tag'
Write-Host '    banner-dev      Braille wolf renders, red DEV beside [ Updates ], red version footer'
Write-Host '    splash-updates  DEV pill top-left, status line NOT blank, list card shows a checking state'
Write-Host '    splash-release  NO DEV pill anywhere - this is the release regression being guarded'
Write-Host '    handoff-*       pre-seal status only; auto-closes; no Acknowledge; Esc closes in preview'
Write-Host ''
Write-Host ('  Remove the sandbox when finished:  Remove-Item -Recurse -Force "' + $Root + '"') -ForegroundColor DarkGray
Write-Host ''
