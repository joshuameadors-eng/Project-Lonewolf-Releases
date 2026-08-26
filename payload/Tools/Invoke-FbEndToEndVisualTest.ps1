<#
    Invoke-FbEndToEndVisualTest.ps1  (Project LoneWolf)

    Single entry point for every on-stick / on-device visual preview. Builds a
    throwaway sandbox under %TEMP% that mirrors the nested FirstBase\ layout,
    then opens the surfaces for the chosen workflow.

    Interactive menu (default when -Workflow is omitted):

      1  WinPE preview (Full)           deploy success (dev + release)
      2  Windows pulling updates        animated check -> download -> install
      3  Windows updates previews       static sample + checking + DEV/RELEASE pills
      4  OOBE handoff preview           pre-seal status (restart / checks / sealing)
      5  End pipeline                   WinPE success -> pulling updates -> pre-seal handoff
      6  End error pipeline             WinPE fail -> gate-fail-restart handoff
      A  All independent workflows      1-4 side by side (not sequential)
      Q  Quit

    Parameters:
      -Workflow   skip the menu: WinPE | PullingUpdates | Updates | Handoff |
                  EndPipeline | EndError | All
      -Root       sandbox location (default %TEMP%\FirstBaseE2EVisualTest)
      -KeepRoot   do not wipe an existing sandbox first
      -List       print workflows and exit
      -NoPause    end-pipeline stages advance without waiting for Enter
#>
[CmdletBinding()]
param(
    [ValidateSet('', 'WinPE', 'PullingUpdates', 'Updates', 'Handoff', 'EndPipeline', 'EndError', 'All')]
    [string] $Workflow = '',
    [string] $Root = (Join-Path $env:TEMP 'FirstBaseE2EVisualTest'),
    [switch] $KeepRoot,
    [switch] $List,
    [switch] $NoPause
)

$ErrorActionPreference = 'Stop'

# src\payload\Tools\ -> src\payload\
$PayloadRoot   = Split-Path -Path $PSScriptRoot -Parent
$DeployUiSrc   = Join-Path $PayloadRoot 'Deploy\Invoke-FbDeployUi.ps1'
$BannerSrc     = Join-Path $PayloadRoot 'Deploy\Show-DeployBanner.ps1'
$UpdateSplash  = Join-Path $PayloadRoot 'Show-UpdateProgress.ps1'
$HandoffSplash = Join-Path $PayloadRoot 'FirstBaseHandoffSplash.ps1'
$IdentitySrc   = Join-Path $PayloadRoot 'FirstBaseBuildIdentity.ps1'
$VersionSrc    = Join-Path $PayloadRoot 'FirstBaseVersion.ps1'
$Ps            = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$workflowCatalog = @(
    @{ Id = 'WinPE';          Key = '1'; Text = 'WinPE preview (Full) - deploy success (dev + release)' }
    @{ Id = 'PullingUpdates'; Key = '2'; Text = 'Windows pulling updates - animated check/download/install' }
    @{ Id = 'Updates';        Key = '3'; Text = 'Windows updates previews - static / checking / DEV vs RELEASE' }
    @{ Id = 'Handoff';        Key = '4'; Text = 'OOBE handoff preview - pre-seal status (restart / checks / sealing)' }
    @{ Id = 'EndPipeline';    Key = '5'; Text = 'End pipeline - WinPE success -> pulling updates -> pre-seal handoff' }
    @{ Id = 'EndError';       Key = '6'; Text = 'End error pipeline - WinPE fail -> gate-fail-restart handoff' }
    @{ Id = 'All';            Key = 'A'; Text = 'All independent workflows (1-4, side by side)' }
)

if ($List) {
    Write-Host ''
    Write-Host '  Workflows:' -ForegroundColor Cyan
    foreach ($w in $workflowCatalog) {
        Write-Host ('    [{0}] {1,-16} {2}' -f $w.Key, $w.Id, $w.Text)
    }
    Write-Host ''
    Write-Host '  Example:  powershell -File Invoke-FbEndToEndVisualTest.ps1 -Workflow EndPipeline'
    Write-Host ''
    return
}

foreach ($required in @($DeployUiSrc, $BannerSrc, $UpdateSplash, $HandoffSplash, $IdentitySrc)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing payload file: $required"
    }
}

function Show-FbE2EMenu {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host '   Project LoneWolf  -  End-to-end visual test' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host ''
    foreach ($w in $workflowCatalog) {
        Write-Host ('    [{0}]  {1}' -f $w.Key, $w.Text)
    }
    Write-Host '    [Q]  Quit'
    Write-Host ''
    $choice = Read-Host '  Select workflow'
    switch -Regex ($choice.Trim()) {
        '^(1)$'          { return 'WinPE' }
        '^(2)$'          { return 'PullingUpdates' }
        '^(3)$'          { return 'Updates' }
        '^(4)$'          { return 'Handoff' }
        '^(5)$'          { return 'EndPipeline' }
        '^(6)$'          { return 'EndError' }
        '^(?i:a|all)$'   { return 'All' }
        '^(?i:q|quit)$'  { return '' }
        default {
            Write-Host '  Unknown selection.' -ForegroundColor Yellow
            return (Show-FbE2EMenu)
        }
    }
}

if ([string]::IsNullOrWhiteSpace($Workflow)) {
    $Workflow = Show-FbE2EMenu
    if (-not $Workflow) {
        Write-Host '  Cancelled.' -ForegroundColor DarkGray
        return
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

function New-FbMockPayload {
    param([string] $Path, [bool] $DevBuild, [string] $Launcher, [string] $Scripts)

    New-FbDir (Join-Path $Path 'Deploy')
    New-FbDir (Join-Path $Path 'WUPayload')
    Copy-Item -LiteralPath $DeployUiSrc -Destination (Join-Path $Path 'Deploy\Invoke-FbDeployUi.ps1') -Force
    Copy-Item -LiteralPath $BannerSrc   -Destination (Join-Path $Path 'Deploy\Show-DeployBanner.ps1') -Force
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
            -Value "devBuild=1`r`nlauncherVersion=5.2.114`r`nscriptVersion=2322`r`n" -Encoding ASCII
        @{
            builtBy = 'LoneWolfLauncher'; launcherVersion = '5.2.114'; scriptVersion = '2322'
            devBuild = $true; shareLauncherVersion = '5.2.108'; shareScriptVersion = '2319'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'LW_VERSION.json') -Encoding UTF8
    }
    return (Join-Path $dir 'Show-UpdateProgress.ps1')
}

New-FbDir $Root
$devRoot     = Join-Path $Root 'dev'
$releaseRoot = Join-Path $Root 'release'
New-FbMockPayload -Path $devRoot     -DevBuild $true  -Launcher '5.2.114' -Scripts '2322'
New-FbMockPayload -Path $releaseRoot -DevBuild $false -Launcher '5.2.108' -Scripts '2319'

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
    param(
        [string] $Title,
        [string[]] $ArgumentList,
        [switch] $Wait,
        [string] $WorkingDirectory = $Root
    )
    $p = Start-Process -FilePath $Ps -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory `
        -WindowStyle Normal -PassThru
    Write-Host ('  opened  ' + $Title) -ForegroundColor DarkGray
    if ($Wait -and $p) {
        Write-Host ('  waiting  ' + $Title + ' ...') -ForegroundColor DarkGray
        $null = $p.WaitForExit()
        Write-Host ('  closed   ' + $Title) -ForegroundColor DarkGray
    }
    return $p
}

function Wait-FbOperator([string] $Prompt) {
    if ($NoPause) {
        Start-Sleep -Seconds 1
        return
    }
    Write-Host ''
    Write-Host ('  >>> ' + $Prompt) -ForegroundColor Yellow
    $null = Read-Host '  Press Enter to continue'
}

function New-FbDeployDriver {
    param([string] $Name, [string] $PayloadRootPath, [string] $Mode, [switch] $AutoClose)

    $ui = Join-Path $PayloadRootPath 'Deploy\Invoke-FbDeployUi.ps1'
    $state = Join-Path $Root ($Name + '.json')
    $driver = Join-Path $Root ($Name + '-driver.ps1')
    $autoCloseLiteral = if ($AutoClose) { '$true' } else { '$false' }

    $body = @"
`$ui    = '$ui'
`$state = '$state'
`$plan  = '$plan'
`$log   = '$mockLog'
`$auto  = $autoCloseLiteral
`$host.UI.RawUI.WindowTitle = 'FirstBase E2E - $Name'

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

if (`$auto) {
    Start-Sleep -Seconds 3
} else {
    Write-Host ''
    Write-Host '  [E2E] scenario complete - close this window when done.' -ForegroundColor DarkGray
    `$null = `$host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
"@
    Set-Content -LiteralPath $driver -Value $body -Encoding UTF8
    return $driver
}

# --- Workflow runners --------------------------------------------------------

function Invoke-FbWorkflowWinPE {
    param([switch] $Sequential, [switch] $AutoClose)
    Write-Host ''
    Write-Host '  [WinPE] deploy success (dev) + deploy success (release)' -ForegroundColor Cyan

    $dDev = New-FbDeployDriver -Name 'winpe-dev' -PayloadRootPath $devRoot -Mode 'success' -AutoClose:$AutoClose
    if ($Sequential) {
        Start-FbTestWindow 'deploy-dev' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dDev) -Wait | Out-Null
    } else {
        Start-FbTestWindow 'deploy-dev' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dDev) | Out-Null
    }

    $dRel = New-FbDeployDriver -Name 'winpe-release' -PayloadRootPath $releaseRoot -Mode 'success' -AutoClose:$AutoClose
    Start-FbTestWindow 'deploy-release' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dRel) -Wait:$Sequential | Out-Null
}

function Invoke-FbWorkflowPullingUpdates {
    param([switch] $Wait)
    Write-Host ''
    Write-Host '  [Pulling] animated Windows updates splash' -ForegroundColor Cyan
    $splash = New-FbMockDevice -Name 'device-pulling' -DevBuild $true
    Start-FbTestWindow 'updates-pulling' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
        '-File', $splash, '-Preview', '-PreviewScenario', 'Pulling'
    ) -Wait:$Wait | Out-Null
}

function Invoke-FbWorkflowUpdates {
    Write-Host ''
    Write-Host '  [Updates] static sample + checking placeholder + DEV/RELEASE pills' -ForegroundColor Cyan

    $devStatic = New-FbMockDevice -Name 'device-dev-static' -DevBuild $true
    Start-FbTestWindow 'updates-static-dev' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
        '-File', $devStatic, '-Preview', '-PreviewScenario', 'Static'
    ) | Out-Null
    Start-Sleep -Milliseconds 350

    $checking = New-FbMockDevice -Name 'device-checking' -DevBuild $true
    Start-FbTestWindow 'updates-checking' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
        '-File', $checking, '-Preview', '-PreviewScenario', 'Checking'
    ) | Out-Null
    Start-Sleep -Milliseconds 350

    $rel = New-FbMockDevice -Name 'device-release-static' -DevBuild $false
    Start-FbTestWindow 'updates-static-release' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
        '-File', $rel, '-Preview', '-PreviewScenario', 'Static'
    ) | Out-Null
}

function Invoke-FbWorkflowHandoff {
    param(
        [string[]] $Phases = @('preparing-handoff', 'running-checks', 'checks-pass', 'checks-fail', 'sealing', 'gate-fail-restart'),
        [switch] $Wait
    )
    Write-Host ''
    Write-Host ('  [Handoff] pre-seal phases: ' + ($Phases -join ', ')) -ForegroundColor Cyan
    Write-Host '  Non-blocking status only — auto-closes; Esc closes early in preview.' -ForegroundColor DarkGray
    foreach ($phase in $Phases) {
        $label = 'handoff-' + $phase
        Start-FbTestWindow $label @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
            '-File', $HandoffSplash, '-Preview', '-Phase', $phase, '-AutoCloseSeconds', '40'
        ) -Wait:$Wait | Out-Null
        if (-not $Wait) { Start-Sleep -Milliseconds 400 }
    }
}

function Invoke-FbWorkflowEndPipeline {
    Write-Host ''
    Write-Host '  [End pipeline] WinPE success -> pulling updates -> sealed handoff' -ForegroundColor Cyan
    Write-Host '  Close each stage window (or wait for auto-close) to advance.' -ForegroundColor DarkGray

    Wait-FbOperator 'Stage 1/3 - WinPE deploy (dev success). Banner also opens.'
    $banner = Join-Path $devRoot 'Deploy\Show-DeployBanner.ps1'
    Start-FbTestWindow 'e2e-banner' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', $banner, '-Subtitle', 'Updates'
    ) | Out-Null
    $d = New-FbDeployDriver -Name 'e2e-deploy-ok' -PayloadRootPath $devRoot -Mode 'success' -AutoClose
    Start-FbTestWindow 'e2e-deploy-ok' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $d) -Wait | Out-Null

    Wait-FbOperator 'Stage 2/3 - Windows pulling updates (animated).'
    Invoke-FbWorkflowPullingUpdates -Wait

    Wait-FbOperator 'Stage 3/3 - OOBE handoff indicator (restart-for-checks, non-blocking).'
    Invoke-FbWorkflowHandoff -Phases @('restart-for-checks') -Wait

    Write-Host ''
    Write-Host '  End pipeline complete.' -ForegroundColor Green
}

function Invoke-FbWorkflowEndError {
    Write-Host ''
    Write-Host '  [End error] WinPE fail -> hardware-gate-fail handoff' -ForegroundColor Cyan

    Wait-FbOperator 'Stage 1/2 - WinPE deploy failure (DISM 1392 + log tail).'
    $d = New-FbDeployDriver -Name 'e2e-deploy-fail' -PayloadRootPath $devRoot -Mode 'fail' -AutoClose
    Start-FbTestWindow 'e2e-deploy-fail' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $d) -Wait | Out-Null

    Wait-FbOperator 'Stage 2/2 - OOBE handoff indicator (gate-fail-restart, non-blocking).'
    Invoke-FbWorkflowHandoff -Phases @('gate-fail-restart') -Wait

    Write-Host ''
    Write-Host '  End error pipeline complete.' -ForegroundColor Green
}

# --- Dispatch ----------------------------------------------------------------

Write-Host ''
Write-Host '  FirstBase end-to-end visual test' -ForegroundColor Cyan
Write-Host ('  workflow: ' + $Workflow) -ForegroundColor DarkGray
Write-Host ('  sandbox:  ' + $Root) -ForegroundColor DarkGray

switch ($Workflow) {
    'WinPE' {
        Invoke-FbWorkflowWinPE
        Write-Host ''
        Write-Host '  Check: two windows only (dev + release); step 4 themed Applying image bar; release has no DEV' -ForegroundColor Cyan
    }
    'PullingUpdates' {
        Invoke-FbWorkflowPullingUpdates
        Write-Host ''
        Write-Host '  Check: indicator row STATUS+DEV | REBOOTS+TOTAL ELAPSED+ELAPSED; total > session after reboot story' -ForegroundColor Cyan
    }
    'Updates' {
        Invoke-FbWorkflowUpdates
        Write-Host ''
        Write-Host '  Check: static has mixed statuses; checking is empty placeholder; release has NO DEV pill' -ForegroundColor Cyan
    }
    'Handoff' {
        Invoke-FbWorkflowHandoff
        Write-Host ''
        Write-Host '  Check: pre-seal phases, auto-close countdown, no Acknowledge button, does not block restart' -ForegroundColor Cyan
    }
    'EndPipeline' {
        Invoke-FbWorkflowEndPipeline
    }
    'EndError' {
        Invoke-FbWorkflowEndError
    }
    'All' {
        Invoke-FbWorkflowWinPE
        Invoke-FbWorkflowPullingUpdates
        Invoke-FbWorkflowUpdates
        Invoke-FbWorkflowHandoff
        Write-Host ''
        Write-Host '  All independent workflows opened. Close windows when done reviewing.' -ForegroundColor Cyan
    }
    default { throw "Unknown workflow: $Workflow" }
}

Write-Host ''
Write-Host ('  Remove sandbox:  Remove-Item -Recurse -Force "' + $Root + '"') -ForegroundColor DarkGray
Write-Host ''
