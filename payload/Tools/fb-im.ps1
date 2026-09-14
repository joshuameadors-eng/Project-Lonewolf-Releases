#Requires -Version 3
<#
.SYNOPSIS
    fb-im.ps1 -- FirstBase technician tool (LoneWolf-themed WPF)
.DESCRIPTION
    Bench-friendly window for non-technical operators:

      Status headline  - red NOT READY / orange CHECK / green READY / purple MANUAL SEAL
                       (purple only after a completed technician seal, never CanSeal)
      Restart updates  - clears stale locks and starts the update loop
      Collect logs     - runs fb-dump while the tech types issue notes

    Runs FROM THE STICK against the C: install. Elevation via fb-im.cmd (-STA).
    fb-im.cmd copies this file to %LOCALAPPDATA% (or %TEMP%) and re-launches with
    -LaunchHost so UAC RunAs is not aimed at a USB working directory.
.PARAMETER Action
    Menu (default WPF), Status, Updates, or Dump (opens WPF focused on that job).
.PARAMETER Force
    Accepted for compatibility; restart no longer prompts on the happy path.
.PARAMETER LaunchHost
    Unelevated local-disk trampoline: Unblock-File, then Start-Process -Verb RunAs
    of this same copy with WorkingDirectory on local disk.
.PARAMETER UsbToolsDir
    Stick Tools folder (FirstBase\WUPayload\Tools). Required when this file is
    running from a TEMP/LOCALAPPDATA copy so identity and fb-dump still resolve.
#>
param(
    [ValidateSet('Menu', 'Status', 'Updates', 'Dump')]
    [string] $Action = 'Menu',

    [switch] $Force,

    # When set (splash dotsource), define functions only - do not open a window.
    [switch] $Library,

    [switch] $LaunchHost,

    [string] $UsbToolsDir = ''
)

Set-StrictMode -Off

function Write-FbImLaunchLog {
    param([string]$Message)
    $log = $env:FB_IM_LOG
    if (-not $log) { return }
    try { Add-Content -LiteralPath $log -Value $Message -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
}

if ($LaunchHost -and -not $Library) {
    $ErrorActionPreference = 'Stop'
    try {
        $here = $PSScriptRoot
        if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
        $run = Join-Path $here 'fb-im.ps1'
        try { Unblock-File -LiteralPath $run -ErrorAction SilentlyContinue } catch {}
        $usb = [string]$UsbToolsDir
        if (-not $usb) { $usb = [string]$env:FB_IM_USB_TOOLS }
        if ($usb) {
            $usb = $usb.TrimEnd('\')
            try { Unblock-File -LiteralPath (Join-Path $usb 'fb-im.ps1') -ErrorAction SilentlyContinue } catch {}
        }
        $psExe = [string]$env:FB_PS
        if (-not $psExe) {
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        }
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($a in @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $run)) {
            [void]$list.Add($a)
        }
        if ($usb) { [void]$list.Add('-UsbToolsDir'); [void]$list.Add($usb) }
        if ($env:FB_IM_ARGS) {
            foreach ($p in @($env:FB_IM_ARGS -split ' ' | Where-Object { $_ })) { [void]$list.Add([string]$p) }
        }
        $sp = @{
            FilePath         = $psExe
            WorkingDirectory = $here
            WindowStyle      = 'Hidden'
            ArgumentList     = $list.ToArray()
        }
        $wid = [Security.Principal.WindowsIdentity]::GetCurrent()
        $admin = (New-Object Security.Principal.WindowsPrincipal($wid)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $admin) { $sp.Verb = 'RunAs' }
        Write-FbImLaunchLog ('LaunchHost run=' + $run)
        Write-FbImLaunchLog ('LaunchHost usb=' + $usb)
        Write-FbImLaunchLog ('LaunchHost admin=' + $admin)
        Write-FbImLaunchLog ('LaunchHost wd=' + $here)
        Start-Process @sp
        Write-FbImLaunchLog 'LaunchHost Start-Process ok'
        exit 0
    } catch {
        $failMsg = [string]$_.Exception.Message
        Write-FbImLaunchLog ('LaunchHost FAIL ' + $failMsg)
        $cancelled = $failMsg -match '(?i)cancel'
        if (-not $cancelled) {
            try {
                Add-Type -AssemblyName PresentationFramework
                [void][System.Windows.MessageBox]::Show(
                    ('fb-im could not start. ' + $failMsg),
                    'Project LoneWolf'
                )
            } catch {}
        }
        exit 1
    }
}

$ErrorActionPreference = 'SilentlyContinue'

$FbImVersion = '2.0.34'

function Initialize-FbImWpf {
    # Must run BEFORE Show-FbImWindow is invoked. Parameter binding resolves
    # [System.Windows.*] types before the function body (Add-Type) runs.
    # Standalone fb-im.cmd died with: Unable to find type [System.Windows.Controls.Panel].
    foreach ($asm in @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml')) {
        try { Add-Type -AssemblyName $asm -ErrorAction Stop } catch {}
    }
}
Initialize-FbImWpf

# =============================================================================
# PATHS -- must match Invoke-WindowsUpdateLoop.ps1 / FirstBaseOobeOperatorFinalize.ps1
# =============================================================================
$FbImFileDir = $null
if ($UsbToolsDir) { $FbImFileDir = [string]$UsbToolsDir }
elseif ($env:FB_IM_USB_TOOLS) { $FbImFileDir = [string]$env:FB_IM_USB_TOOLS }
elseif ($PSScriptRoot) { $FbImFileDir = $PSScriptRoot }
if ($FbImFileDir) { $FbImFileDir = $FbImFileDir.TrimEnd('\') }
if (-not $FbImFileDir) {
    try { $FbImFileDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {}
}

$FbRoot           = 'C:\Windows\Setup\FirstBase'
$FbStateDir       = Join-Path $FbRoot 'State'
$FbLogDir         = Join-Path $FbRoot 'Logs'
$FbPd             = 'C:\ProgramData\FirstBase'
$FbScriptsDir     = 'C:\Windows\Setup\Scripts'

$SealedMarker     = Join-Path $FbPd '.firstbase-sealed'
$ManualSealMarker = Join-Path $FbPd '.manual-seal'
$PipelineMarker   = Join-Path $FbPd '.pipeline-completed'
$GateFailMarker   = Join-Path $FbPd '.hardware-gate-fail-restart'
$HwDoneMarker     = Join-Path $FbPd '.hardware-gate-complete'
$HwResultMarker   = Join-Path $FbPd '.hardware-gate-result.json'
$ArmSuppressed    = Join-Path $FbPd '.firstbase-specialize-arm-suppressed'

$DoneFlag         = Join-Path $FbScriptsDir 'FirstBase-Updates-Done.flag'
$CompleteFlag     = Join-Path $FbScriptsDir 'FirstBase-Updates-Complete.flag'
$HandoffPendingMarker = Join-Path $FbPd '.wu-handoff-pending'
$OperatorGateActive   = Join-Path $FbPd '.operator-settings-gate-active'
$SetupCompleteCmd = Join-Path $FbScriptsDir 'SetupComplete.cmd'

$LoopScript       = Join-Path $FbRoot 'Invoke-WindowsUpdateLoop.ps1'
$EngineScript     = Join-Path $FbRoot 'FirstBaseWuEngine.ps1'
$LoopLauncher     = Join-Path $FbRoot 'FirstBaseLoopLauncher.cmd'
$StateFile        = Join-Path $FbRoot 'wu-state.json'
$StatusFile       = Join-Path $FbRoot 'wu-status.json'
$HeartbeatFile    = Join-Path $FbRoot 'wu-loop-heartbeat.txt'
$LockFile         = Join-Path $FbStateDir 'wu-loop.lock'

$LoopTaskName     = 'FirstBase\WindowsUpdateLoop'
$LogonTaskName    = 'FirstBase\WindowsUpdateLoopOnLogon'

$RunOnceKey       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$RunKey           = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$SetupStateKey    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'

# =============================================================================
# BUILD IDENTITY
# =============================================================================
function Get-FbImBuildIdentity {
    $id = [ordered]@{
        StickRev = ''; DeviceRev = ''; Product = ''; Dev = $false
        Destage = $false
        Launcher = ''; ShareLauncher = ''
    }
    $stickPayload = $null
    $toolsDir = $FbImFileDir
    if (-not $toolsDir) { $toolsDir = $PSScriptRoot }
    try { if ($toolsDir) { $stickPayload = Split-Path -Path $toolsDir -Parent } } catch {}

    foreach ($probe in @(
            @{ Dir = $stickPayload; Field = 'StickRev' },
            @{ Dir = $FbRoot;       Field = 'DeviceRev' }
        )) {
        if (-not $probe.Dir) { continue }
        $verFile = Join-Path $probe.Dir 'FirstBaseVersion.ps1'
        if (-not (Test-Path -LiteralPath $verFile)) { continue }
        try {
            $FirstBasePayloadRevision = $null; $FirstBaseProductVersion = $null
            . $verFile
            if ($FirstBasePayloadRevision) { $id[$probe.Field] = [string]$FirstBasePayloadRevision }
            if ($FirstBaseProductVersion -and -not $id.Product) { $id.Product = [string]$FirstBaseProductVersion }
        } catch {}
    }

    $identityPs1 = $null
    foreach ($cand in @($stickPayload, $FbRoot)) {
        if (-not $cand) { continue }
        $probePath = Join-Path $cand 'FirstBaseBuildIdentity.ps1'
        if (Test-Path -LiteralPath $probePath) { $identityPs1 = $probePath; break }
    }
    if ($identityPs1) {
        try {
            . $identityPs1
            $roots = @()
            if ($stickPayload) {
                $roots += $stickPayload
                $payloadParent = Split-Path -Path $stickPayload -Parent
                if ($payloadParent) { $roots += $payloadParent }
            }
            try {
                $qualifier = Split-Path -Path $toolsDir -Qualifier
                if ($qualifier) { $roots += ($qualifier + '\') }
            } catch {}
            if ($FbRoot) { $roots += $FbRoot }
            $build = Get-FbBuildIdentity -PayloadRoot $roots
            if ($build) {
                $id.Dev           = [bool]$build.Dev
                try { if ($build.PSObject.Properties['Destage']) { $id.Destage = [bool]$build.Destage } } catch {}
                $id.Launcher      = [string]$build.Launcher
                $id.ShareLauncher = [string]$build.ShareLauncher
            }
        } catch {}
    }

    # Fallback: LW_VERSION.json / .dev-build when identity helper is missing
    if (-not $id.Launcher -or -not $id.Dev) {
        $stampRoots = @()
        if ($stickPayload) {
            $stampRoots += $stickPayload
            $fbParent = Split-Path -Path $stickPayload -Parent
            if ($fbParent) { $stampRoots += $fbParent }
        }
        foreach ($root in $stampRoots) {
            if (-not $root) { continue }
            $lw = Join-Path $root 'LW_VERSION.json'
            if (-not (Test-Path -LiteralPath $lw)) { $lw = Join-Path (Split-Path $root -Parent) 'LW_VERSION.json' }
            if (Test-Path -LiteralPath $lw) {
                try {
                    $j = Get-Content -LiteralPath $lw -Raw -ErrorAction Stop | ConvertFrom-Json
                    if (-not $id.Launcher -and $j.launcherVersion) { $id.Launcher = [string]$j.launcherVersion }
                    if ($j.destage -or [string]$j.channel -eq 'destage') { $id.Destage = $true; $id.Dev = $true }
                    elseif ($j.devBuild) { $id.Dev = $true }
                } catch {}
            }
            $devMarker = Join-Path $root '.dev-build'
            if (Test-Path -LiteralPath $devMarker) {
                $id.Dev = $true
                $id.Destage = $true
                if (-not $id.Launcher) {
                    try {
                        foreach ($line in (Get-Content -LiteralPath $devMarker -ErrorAction Stop)) {
                            if ($line -match '^\s*launcherVersion\s*=\s*(.+)$') {
                                $id.Launcher = $Matches[1].Trim()
                                break
                            }
                        }
                    } catch {}
                }
            }
        }
    }

    return $id
}

$FbBuild = Get-FbImBuildIdentity

# =============================================================================
# STATE PROBES
# =============================================================================
function Test-FbAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-FbMarkerDetail {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $line = (Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop)
        if ($line) { return ([string]$line).Trim() }
    } catch {}
    try { return ('written ' + (Get-Item -LiteralPath $Path).LastWriteTime.ToString('s')) } catch {}
    return 'present'
}

function Get-FbLoopProcess {
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop
        foreach ($p in $procs) {
            if ($p.CommandLine -and $p.CommandLine -match 'Invoke-WindowsUpdateLoop\.ps1') { return $p }
        }
    } catch {}
    return $null
}

function Get-FbFirstBaseTasks {
    # Prefer the on-disk task tree. Get-ScheduledTask COM can hang in Audit and
    # freeze the status panel on "Checking...".
    $names = @()
    $taskDir = Join-Path $env:SystemRoot 'System32\Tasks\FirstBase'
    try {
        if (Test-Path -LiteralPath $taskDir) {
            $files = @(Get-ChildItem -LiteralPath $taskDir -Recurse -File -Force -ErrorAction SilentlyContinue)
            foreach ($f in $files) {
                $rel = $f.FullName.Substring($taskDir.Length).TrimStart('\')
                if (-not [string]::IsNullOrWhiteSpace($rel)) { $names += ('FirstBase\' + $rel) }
            }
        }
    } catch {}
    if ($names.Count -gt 0) { return $names }
    try {
        $out = & schtasks.exe /Query /FO LIST 2>$null
        foreach ($line in $out) {
            if ($line -match '^TaskName:\s+\\(FirstBase\\.+)$') { $names += $Matches[1].Trim() }
        }
    } catch {}
    return $names
}

function Get-FbAutostartValues {
    $hits = @()
    foreach ($key in @($RunOnceKey, $RunKey)) {
        try {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                if ($p.Name -match '(?i)firstbase') { $hits += ((Split-Path $key -Leaf) + '\' + $p.Name) }
            }
        } catch {}
    }
    try {
        $out = & reg.exe query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnceEx' /s 2>$null
        foreach ($line in $out) {
            if ($line -match '(?i)\s(FirstBase\S*)\s+REG_') { $hits += ('RunOnceEx\' + $Matches[1]) }
        }
    } catch {}
    return $hits
}

function Get-FbExecutableResidue {
    $hits = @()
    if (-not (Test-Path -LiteralPath $FbRoot)) { return $hits }
    try {
        $files = Get-ChildItem -LiteralPath $FbRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike ($FbLogDir + '\*') }
        foreach ($f in $files) {
            if ($f.FullName -like ($FbLogDir + '\*')) { continue }
            if (@('.ps1', '.cmd', '.bat', '.vbs', '.exe') -contains $f.Extension.ToLower()) {
                $hits += $f.FullName
            }
        }
    } catch {}
    return $hits
}

function Get-FbWuState {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try { return (Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Get-FbHeartbeatAge {
    if (-not (Test-Path -LiteralPath $HeartbeatFile)) { return $null }
    try { return ((Get-Date) - (Get-Item -LiteralPath $HeartbeatFile).LastWriteTime) } catch { return $null }
}

function Get-FbImageState {
    try { return [string](Get-ItemProperty -LiteralPath $SetupStateKey -ErrorAction Stop).ImageState } catch { return '' }
}

function Test-FbImAuditMode {
    param([string]$ImageState = '')
    if ([string]::IsNullOrWhiteSpace($ImageState)) { $ImageState = Get-FbImageState }
    if ($ImageState -match '(?i)UNDEPLOYABLE|RESEAL_TO_AUDIT') { return $true }
    try {
        if (Test-Path -LiteralPath 'HKLM:\SYSTEM\Setup\AuditInProgress') { return $true }
    } catch {}
    return $false
}

# =============================================================================
# STATUS / RESTART (structured)
# =============================================================================
function Get-FbImWuStatusObject {
    if (-not (Test-Path -LiteralPath $StatusFile)) { return $null }
    try { return (Get-Content -LiteralPath $StatusFile -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Test-FbImTechStopPresent {
    try { return [bool](Test-Path -LiteralPath (Join-Path $FbStateDir '.wu-tech-stop')) } catch { return $false }
}

function Test-FbImWuPhaseFailed {
    param($Wu)
    if (-not $Wu) { return $false }
    $phase = [string]$Wu.phase
    $msg = [string]$Wu.message
    # Word-bounded: '(?i)fail' must not treat a leftover 'Stopped' as success,
    # and '(?i)install' must not treat 'Installed' as installing.
    if ($phase -match '(?i)^(fail|failed|error)(\b|$)') { return $true }
    if ($msg -match '(?i)escape valve|INCOMPLETE state|Failed - tech') { return $true }
    try {
        foreach ($u in @($Wu.updates)) {
            if (-not $u) { continue }
            $st = [string]$u.Status
            if ($st -match '(?i)^(fail|failed|error)(\b|$)') { return $true }
        }
    } catch {}
    return $false
}

function Test-FbImWuPhaseIncomplete {
    param($Wu)
    if (-not $Wu) { return $false }
    $phase = [string]$Wu.phase
    # Stopped is technician abort / incomplete - never success.
    if ($phase -match '(?i)^(stopped)(\b|$)') { return $true }
    if ($phase -match '(?i)^(downloading|download|installing|applying|applyingupdates|rebooting|scanning|waiting|checkforupdates)(\b|$)') { return $true }
    return $false
}

function Test-FbImWuRowInstalling {
    param([string]$Status)
    if ([string]::IsNullOrWhiteSpace($Status)) { return $false }
    # Word-bounded. Must not treat 'Installed' as installing.
    return [bool]($Status -match '(?i)^(downloading|download|installing)(\b|$)')
}

function Test-FbImHeartbeatFresh {
    param([int]$MaxAgeSeconds = 90)
    $age = $null
    try { $age = Get-FbHeartbeatAge } catch { $age = $null }
    if (-not $age) { return $false }
    try { return [bool]($age.TotalSeconds -ge 0 -and $age.TotalSeconds -lt $MaxAgeSeconds) } catch { return $false }
}

function Test-FbImWuActuallyInstalling {
    param($Wu = $null)
    if (-not $Wu) {
        try { $Wu = Get-FbImWuStatusObject } catch { $Wu = $null }
    }
    $hbFresh = [bool](Test-FbImHeartbeatFresh)
    $phase = ''
    if ($Wu) {
        $phase = [string]$Wu.phase
        try {
            foreach ($u in @($Wu.updates)) {
                if (-not $u) { continue }
                if (Test-FbImWuRowInstalling -Status ([string]$u.Status)) { return $true }
            }
        } catch {}
    }
    if ($hbFresh -and ($phase -match '(?i)^(downloading|download|installing|applying|applyingupdates)(\b|$)')) {
        return $true
    }
    try {
        foreach ($p in @(Get-Process -Name 'poqexec','dismhost' -ErrorAction SilentlyContinue)) {
            if ($p) { return $true }
        }
    } catch {}
    return $false
}

function Test-FbImStuckCompleteWithoutHandoff {
    param(
        $Wu = $null,
        [bool]$Sealed = $false,
        [bool]$HwDone = $false,
        [bool]$ActuallyInstalling = $false
    )
    if ($Sealed) { return $false }
    if ($HwDone) { return $false }
    if ($ActuallyInstalling) { return $false }
    $complete = $false
    try { if (Test-Path -LiteralPath $CompleteFlag) { $complete = $true } } catch {}
    try { if (Test-Path -LiteralPath $DoneFlag) { $complete = $true } } catch {}
    try { if (Test-Path -LiteralPath $HandoffPendingMarker) { $complete = $true } } catch {}
    if (-not $complete -and $Wu) {
        $phase = [string]$Wu.phase
        if ($phase -match '(?i)^(completed|hardwaregate|handoff)(\b|$)') { $complete = $true }
    }
    return [bool]$complete
}

function Get-FbImStatusKind {
    param(
        [bool]$ScriptsPresent,
        [bool]$IncompleteUpdates,
        [bool]$Audit,
        [bool]$HardwareFailed,
        [bool]$UpdatesFailed,
        [bool]$NeedsManualSeal
    )
    # Purple only after a completed technician seal (persisted .manual-seal).
    # CanSeal / "should seal manually" must not turn the lamp purple.
    if ($NeedsManualSeal) {
        return [pscustomobject]@{
            ColorKind = 'Purple'
            Headline  = 'MANUAL SEAL'
            Ready     = $false
        }
    }
    # Red wins over Orange when audit / scripts / incomplete also apply.
    if ($ScriptsPresent -or $IncompleteUpdates -or $Audit) {
        return [pscustomobject]@{
            ColorKind = 'Red'
            Headline  = 'NOT READY'
            Ready     = $false
        }
    }
    if ($HardwareFailed -or $UpdatesFailed) {
        return [pscustomobject]@{
            ColorKind = 'Orange'
            Headline  = 'CHECK'
            Ready     = $false
        }
    }
    return [pscustomobject]@{
        ColorKind = 'Green'
        Headline  = 'READY'
        Ready     = $true
    }
}

function Test-FbImCbsRebootUnsafe {
    # True only while CBS is actively committing boot files or WU is still
    # downloading/installing. Do not treat 'Installed' or a owed reboot as unsafe:
    # '(?i)download|install' matches Installed and greys Seal on every updated device.
    $reasons = New-Object System.Collections.Generic.List[string]
    try {
        if (Test-Path -LiteralPath $StatusFile) {
            $obj = Get-Content -LiteralPath $StatusFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $phase = [string]$obj.phase
            $msg = [string]$obj.message
            $hbFresh = [bool](Test-FbImHeartbeatFresh)
            # Stale phase=Rebooting after a completed reboot is not CBS-unsafe.
            if ($phase -match '(?i)^rebooting(\b|$)' -and $hbFresh) {
                [void]$reasons.Add('Update loop is in the reboot/CBS-commit phase')
            }
            if ($msg -match '(?i)cbs pre-reboot|servicing to finish|ntoskrnl|waiting for shutdown') {
                if ($hbFresh -or ($phase -match '(?i)^rebooting(\b|$)')) {
                    [void]$reasons.Add('Splash/loop reports boot-file commit or shutdown in progress')
                }
            }
            foreach ($u in @($obj.updates)) {
                if (-not $u) { continue }
                $st = [string]$u.Status
                if (Test-FbImWuRowInstalling -Status $st) {
                    [void]$reasons.Add('Updates are still downloading or installing')
                    break
                }
            }
        }
    } catch {}
    try {
        foreach ($p in @(Get-Process -Name 'poqexec','dismhost' -ErrorAction SilentlyContinue)) {
            if ($p) {
                [void]$reasons.Add(('Servicing worker {0} is still running' -f $p.Name))
                break
            }
        }
    } catch {}
    $unsafe = ($reasons.Count -gt 0)
    return [pscustomobject]@{
        Unsafe  = [bool]$unsafe
        Reasons = @($reasons | Select-Object -Unique)
        Detail  = if ($unsafe) { [string]::Join('; ', @($reasons | Select-Object -Unique)) } else { '' }
    }
}

function Get-FbImDeviceStatus {
    $sealed    = Test-Path -LiteralPath $SealedMarker
    $pipeline  = Test-Path -LiteralPath $PipelineMarker
    $gateFail  = Test-Path -LiteralPath $GateFailMarker
    $hwDone    = Test-Path -LiteralPath $HwDoneMarker
    $suppress  = Test-Path -LiteralPath $ArmSuppressed
    $tasks     = @(Get-FbFirstBaseTasks)
    $autostart = @(Get-FbAutostartValues)
    $residue   = @(Get-FbExecutableResidue)
    $loopProc  = Get-FbLoopProcess
    $imgState  = Get-FbImageState
    $sysFail   = Test-Path -LiteralPath 'C:\Windows\System32\sysprep\Sysprep_failed.tag'
    $setupPresent = Test-Path -LiteralPath $SetupCompleteCmd
    $loopScriptPresent = Test-Path -LiteralPath $LoopScript
    $enginePresent = Test-Path -LiteralPath $EngineScript
    $admin     = [bool](Test-FbAdmin)
    $audit     = [bool](Test-FbImAuditMode -ImageState $imgState)
    $destage   = $false
    try { if ($FbBuild) { $destage = [bool]$FbBuild.Destage } } catch {}
    $hwPassed  = [bool]((-not $gateFail) -and $hwDone)
    $techStopped = [bool](Test-FbImTechStopPresent)
    $wuObj = $null
    try { $wuObj = Get-FbImWuStatusObject } catch { $wuObj = $null }
    $wuFailed = [bool](Test-FbImWuPhaseFailed -Wu $wuObj)
    if ($sysFail) { $wuFailed = $true }
    $wuPhaseIncomplete = [bool](Test-FbImWuPhaseIncomplete -Wu $wuObj)
    $actuallyInstalling = $false
    try { $actuallyInstalling = [bool](Test-FbImWuActuallyInstalling -Wu $wuObj) } catch { $actuallyInstalling = $false }
    $operatorGate = $false
    try { $operatorGate = [bool](Test-Path -LiteralPath $OperatorGateActive) } catch {}
    $hwDonePath = $hwDone

    $scriptsPresent = ($residue.Count -gt 0) -or $setupPresent -or $loopScriptPresent -or
        $enginePresent -or ($tasks.Count -gt 0) -or ($autostart.Count -gt 0)

    $cbsGate = $null
    try { $cbsGate = Test-FbImCbsRebootUnsafe } catch { $cbsGate = $null }
    $cbsUnsafe = $false
    if ($cbsGate -and [bool]$cbsGate.Unsafe) { $cbsUnsafe = $true }

    $updatesFinished = $sealed -or (Test-Path -LiteralPath $DoneFlag) -or (Test-Path -LiteralPath $CompleteFlag)
    $stuckCompleteNoGate = [bool](Test-FbImStuckCompleteWithoutHandoff -Wu $wuObj -Sealed $sealed -HwDone $hwDonePath -ActuallyInstalling $actuallyInstalling)

    # Stale Rebooting/Stopped/Installing in wu-status.json is not "updates still running"
    # once WU is idle and the completion marker is on disk.
    if ($stuckCompleteNoGate -or ($updatesFinished -and -not $actuallyInstalling)) {
        if (-not $actuallyInstalling) { $wuPhaseIncomplete = $false }
    }

    $incompleteUpdates = $false
    if ($actuallyInstalling) { $incompleteUpdates = $true }
    if ($techStopped -and -not $stuckCompleteNoGate -and -not $updatesFinished) { $incompleteUpdates = $true }
    if ($loopProc -and $actuallyInstalling) { $incompleteUpdates = $true }
    if ($cbsUnsafe) { $incompleteUpdates = $true }
    if ($wuPhaseIncomplete -and -not $stuckCompleteNoGate) { $incompleteUpdates = $true }
    if ($sealed -and (-not $actuallyInstalling) -and (-not $cbsUnsafe)) {
        $incompleteUpdates = $false
    }

    $hwOkForSeal = (-not $gateFail) -and ($hwPassed -or $destage)
    $modeOkForSeal = $destage -or $audit
    $canSeal = $admin -and (-not $sealed) -and (-not $cbsUnsafe) -and $hwOkForSeal -and $modeOkForSeal
    $manualSealed = $false
    try { $manualSealed = [bool](Test-Path -LiteralPath $ManualSealMarker) } catch { $manualSealed = $false }
    # Purple is a completed technician seal, not CanSeal / "seal is available".
    $needsManualSeal = [bool]$manualSealed

    $kind = Get-FbImStatusKind -ScriptsPresent $scriptsPresent -IncompleteUpdates $incompleteUpdates `
        -Audit $audit -HardwareFailed $gateFail -UpdatesFailed $wuFailed -NeedsManualSeal $needsManualSeal

    $issues = New-Object System.Collections.ArrayList
    $addIssue = {
        param([string]$Text, [string]$Level)
        if ([string]::IsNullOrWhiteSpace($Text)) { return }
        [void]$issues.Add([pscustomobject]@{ Text = $Text; Level = $Level })
    }

    if (-not $admin) {
        & $addIssue 'Not running as Administrator' 'fail'
    }
    if ($sysFail) {
        & $addIssue 'Sysprep failed on this device' 'fail'
    }
    if ($gateFail) {
        & $addIssue 'Hardware check failed' 'fail'
    } elseif ((-not $hwDone) -and (-not $destage) -and (-not $sealed)) {
        & $addIssue 'Hardware check not recorded' 'warn'
    }
    if ($actuallyInstalling) {
        & $addIssue 'Updates are still running' 'fail'
    } elseif ($stuckCompleteNoGate) {
        & $addIssue 'Updates finished but hardware check did not start' 'fail'
    } elseif ($loopProc -and $operatorGate -and (-not $hwDone)) {
        & $addIssue 'Hardware check is waiting on the operator step' 'warn'
    } elseif ($loopProc -and $wuPhaseIncomplete) {
        & $addIssue 'Updates are still running' 'fail'
    }
    if ($techStopped -and (-not $stuckCompleteNoGate) -and (-not $updatesFinished)) {
        & $addIssue 'Updates were stopped (incomplete)' 'fail'
    }
    if ($wuFailed -and (-not $sysFail)) {
        & $addIssue 'Updates failed' 'fail'
    }
    if ($wuPhaseIncomplete -and (-not $techStopped) -and (-not $loopProc) -and (-not $stuckCompleteNoGate) -and (-not $actuallyInstalling)) {
        & $addIssue 'Updates are not finished' 'fail'
    }
    if ($scriptsPresent -and (-not $sealed)) {
        & $addIssue 'FirstBase scripts are still on the device' 'fail'
    }
    if ($audit) {
        & $addIssue 'Device is in Audit mode' 'fail'
    }
    if ($sealed) {
        if (-not $pipeline) { & $addIssue 'Seal is incomplete (pipeline mark missing)' 'fail' }
        if ($tasks.Count -gt 0) { & $addIssue 'Leftover scheduled tasks still registered' 'warn' }
        if ($autostart.Count -gt 0) { & $addIssue 'Leftover startup entries still registered' 'warn' }
        if ($residue.Count -gt 0) { & $addIssue 'Leftover FirstBase files still on the device' 'fail' }
        if ($setupPresent) { & $addIssue 'Setup leftovers still present' 'fail' }
    }
    if ($suppress -and -not $sealed) {
        & $addIssue 'Finalize did not finish' 'warn'
    }
    if ($cbsUnsafe) {
        & $addIssue 'Windows is still committing boot files' 'fail'
    }
    if ($manualSealed -and ([string]$kind.ColorKind -eq 'Purple')) {
        & $addIssue 'Technician completed a manual seal' 'warn'
    }

    $hasFail = $false
    $hasWarn = $false
    foreach ($issue in $issues) {
        if (-not $issue) { continue }
        if ($issue.Level -eq 'fail') { $hasFail = $true }
        elseif ($issue.Level -eq 'warn') { $hasWarn = $true }
    }

    $sealBlock = ''
    if ($sealed) { $sealBlock = 'This device is already sealed.' }
    elseif (-not $admin) { $sealBlock = 'Not running as Administrator - open fb-im.cmd from the USB stick.' }
    elseif ($cbsUnsafe) { $sealBlock = 'Seal is blocked while Windows is committing boot files. Wait for the update loop to reboot.' }
    elseif ($gateFail) { $sealBlock = 'Pass the hardware check before sealing.' }
    elseif ((-not $hwPassed) -and (-not $destage)) { $sealBlock = 'Pass the hardware check before sealing.' }
    elseif (-not $modeOkForSeal) { $sealBlock = 'Seal is available in Audit mode, after the hardware check, or on a destage stick.' }

    $facts = New-Object System.Collections.ArrayList
    $pc = [string]$env:COMPUTERNAME
    if (-not [string]::IsNullOrWhiteSpace($pc)) { [void]$facts.Add('PC: ' + $pc) }
    if ($imgState) { [void]$facts.Add('Windows: ' + $imgState) }
    elseif ($audit) { [void]$facts.Add('Mode: Audit') }
    else { [void]$facts.Add('Mode: not Audit') }
    if ($destage) { [void]$facts.Add('Stick: destage') }
    if ($hwPassed) { [void]$facts.Add('Hardware: passed') }
    elseif ($gateFail) { [void]$facts.Add('Hardware: failed') }
    else { [void]$facts.Add('Hardware: not recorded') }
    if ($actuallyInstalling) { [void]$facts.Add('Updates: running') }
    elseif ($stuckCompleteNoGate) { [void]$facts.Add('Updates: finished (hardware check not started)') }
    elseif ($loopProc -and $operatorGate) { [void]$facts.Add('Updates: finished (operator step)') }
    elseif ($techStopped -and (-not $updatesFinished)) { [void]$facts.Add('Updates: stopped (incomplete)') }
    elseif ($wuFailed) { [void]$facts.Add('Updates: failed') }
    elseif ($updatesFinished) { [void]$facts.Add('Updates: finished') }
    else { [void]$facts.Add('Updates: not running') }
    if ($admin) { [void]$facts.Add('fb-im: Administrator') }
    else { [void]$facts.Add('fb-im: not Administrator') }
    if ($manualSealed) { [void]$facts.Add('Seal: manual (technician)') }
    elseif ($sealed) { [void]$facts.Add('Seal: finished') }
    else { [void]$facts.Add('Seal: not finished') }

    $factArr = @($facts.ToArray())
    return [pscustomobject]@{
        Ready      = [bool]$kind.Ready
        Headline   = [string]$kind.Headline
        ColorKind  = [string]$kind.ColorKind
        Issues     = @($issues.ToArray())
        Reasons    = @($issues | ForEach-Object { $_.Text })
        Details    = $factArr
        Facts      = $factArr
        Sealed     = [bool]$sealed
        Pipeline   = [bool]$pipeline
        CanRestart = (-not $sealed) -and (-not $pipeline)
        CanSeal    = [bool]$canSeal
        NeedsManualSeal = [bool]$needsManualSeal
        ManualSealed = [bool]$manualSealed
        SealBlock  = $sealBlock
        LoopRunning = [bool]$loopProc
        HardwareFailed = [bool]$gateFail
        HardwarePassed = [bool]$hwPassed
        ScriptsPresent = [bool]$scriptsPresent
        IncompleteUpdates = [bool]$incompleteUpdates
        UpdatesFailed = [bool]$wuFailed
        TechStopped = [bool]$techStopped
        ActuallyInstalling = [bool]$actuallyInstalling
        StuckCompleteWithoutHandoff = [bool]$stuckCompleteNoGate
        OperatorGateActive = [bool]$operatorGate
        Audit      = [bool]$audit
        Destage    = [bool]$destage
        Admin      = [bool]$admin
        HasFail    = [bool]$hasFail
        HasWarn    = [bool]$hasWarn
        ImageState = [string]$imgState
    }
}

function Test-FbImDestageStopEnabled {
    # Destage USB (npm start): destage=true, channel=destage, .dev-build, or legacy devBuild.
    # Packaged Launcher Dev (channel=dev, destage off) and production stay hidden.
    try {
        if ($FbBuild -and ($FbBuild.Destage -or $FbBuild.Dev)) { return $true }
    } catch {}
    return $false
}

function Get-FbImTechStopFlagPath {
    return (Join-Path $FbStateDir '.wu-tech-stop')
}

function Clear-FbImTechStopFlag {
    $p = Get-FbImTechStopFlagPath
    try { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } } catch {}
}

function Write-FbImWuStoppedStatus {
    param([string]$Message = 'Updates stopped by technician (destage).')
    try {
        if (-not (Test-Path -LiteralPath $FbRoot)) {
            New-Item -ItemType Directory -Path $FbRoot -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $payload = @{
            phase     = 'Stopped'
            message   = $Message
            updatedAt = (Get-Date).ToString('o')
            updates   = @()
        }
        ($payload | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $StatusFile -Encoding UTF8 -Force
    } catch {}
}

function Stop-FbWindowsUpdatePipeline {
    # Destage technician tool: cancel in-flight FirstBase WU + Windows Update Agent
    # work. Does not persist pause policies, disable services, or block future WU.
    $result = [ordered]@{
        Ok      = $false
        Message = ''
        Detail  = ''
    }
    $notes = New-Object System.Collections.Generic.List[string]
    try {
        if (-not (Test-Path -LiteralPath $FbStateDir)) {
            New-Item -ItemType Directory -Path $FbStateDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $flag = Get-FbImTechStopFlagPath
        $stamp = "stoppedAt={0}`r`npid={1}`r`n" -f (Get-Date).ToString('o'), $PID
        [System.IO.File]::WriteAllText($flag, $stamp, [System.Text.UTF8Encoding]::new($false))
        [void]$notes.Add('Wrote stop sentinel')
    } catch {
        [void]$notes.Add('Could not write stop sentinel')
    }

    try { Write-FbImWuStoppedStatus -Message 'Updates stopped by technician (destage). Restart updates from fb-im to resume.' } catch {}

    $self = $PID
    $killedLoop = 0
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue
        foreach ($p in @($procs)) {
            if (-not $p) { continue }
            if ([int]$p.ProcessId -eq [int]$self) { continue }
            $cmd = [string]$p.CommandLine
            if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
            $isLoop = ($cmd -match 'Invoke-WindowsUpdateLoop\.ps1') -or ($cmd -match 'FirstBaseLoopLauncher\.cmd')
            if (-not $isLoop) { continue }
            try {
                Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
                $killedLoop++
            } catch {}
        }
    } catch {}
    if ($killedLoop -gt 0) { [void]$notes.Add(('Stopped {0} update-loop process(es)' -f $killedLoop)) }

    try {
        $uso = Join-Path $env:SystemRoot 'System32\UsoClient.exe'
        if (Test-Path -LiteralPath $uso) {
            Start-Process -FilePath $uso -ArgumentList 'StopScan' -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}

    $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
    if (-not (Test-Path -LiteralPath $taskkill)) { $taskkill = 'taskkill.exe' }
    foreach ($name in @('UsoClient.exe', 'wuauclt.exe', 'MoUsoCoreWorker.exe', 'MusNotification.exe', 'MusNotifyIcon.exe', 'wuapihost.exe')) {
        try {
            Start-Process -FilePath $taskkill -ArgumentList @('/F', '/IM', $name, '/T') -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }
    [void]$notes.Add('Cancelled Windows Update Agent / USO workers')

    foreach ($svc in @('wuauserv', 'bits', 'usosvc')) {
        try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch {}
    }
    [void]$notes.Add('Stopped wuauserv, bits, and usosvc (startup type unchanged)')

    Start-Sleep -Milliseconds 400
    try {
        if (Test-Path -LiteralPath $LockFile) {
            Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    $result.Ok = $true
    $result.Message = 'Windows Update pipeline stopped'
    $result.Detail = [string]::Join('. ', @($notes))
    return [pscustomobject]$result
}

function Invoke-FbImStopUpdates {
    $result = [ordered]@{
        Ok      = $false
        Message = ''
        Detail  = ''
    }
    if (-not (Test-FbImDestageStopEnabled)) {
        $result.Message = 'Stop updates is destage only'
        $result.Detail = 'This control is hidden on production and packaged Launcher Dev sticks.'
        return [pscustomobject]$result
    }
    if (-not (Test-FbAdmin)) {
        $result.Message = 'Administrator access is required'
        $result.Detail = 'Close this window and open fb-im.cmd from the USB stick.'
        return [pscustomobject]$result
    }
    return (Stop-FbWindowsUpdatePipeline)
}

function Invoke-FbImRestartUpdates {
    $result = [ordered]@{
        Ok      = $false
        Message = ''
        Detail  = ''
        Pid     = $null
    }

    if (-not (Test-FbAdmin)) {
        $result.Message = 'Administrator access is required'
        $result.Detail = 'Close this window and open fb-im.cmd from the USB stick.'
        return [pscustomobject]$result
    }

    if ((Test-Path -LiteralPath $SealedMarker) -or (Test-Path -LiteralPath $PipelineMarker)) {
        $result.Message = 'This device is already sealed'
        $result.Detail = 'Updates cannot be restarted here. Re-image the device if more updates are needed.'
        return [pscustomobject]$result
    }

    if (-not (Test-Path -LiteralPath $LoopScript)) {
        $result.Message = 'Update software is missing on this device'
        $result.Detail = 'Collect logs, then re-image the device.'
        return [pscustomobject]$result
    }
    if (-not (Test-Path -LiteralPath $EngineScript)) {
        $result.Message = 'Update engine is missing on this device'
        $result.Detail = 'Collect logs, then re-image the device.'
        return [pscustomobject]$result
    }

    $running = Get-FbLoopProcess
    if ($running) {
        $result.Ok = $true
        $result.Message = 'Updates are already running'
        $result.Detail = 'Leave the device on power. The progress screen should appear shortly.'
        $result.Pid = $running.ProcessId
        return [pscustomobject]$result
    }

    # Auto-clear destage Stop sentinel + stale lock so the loop may run again.
    try { Clear-FbImTechStopFlag } catch {}
    if (Test-Path -LiteralPath $LockFile) {
        try { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue } catch {}
    }

    $started = $false
    $via = ''
    $tasks = @(Get-FbFirstBaseTasks)

    foreach ($task in @($LoopTaskName, $LogonTaskName)) {
        if ($started) { break }
        if ($tasks -notcontains $task) { continue }
        & schtasks.exe /Run /TN $task 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $started = $true; $via = 'scheduled task' }
    }

    if (-not $started -and (Test-Path -LiteralPath $LoopLauncher)) {
        try {
            Start-Process -FilePath $LoopLauncher -WindowStyle Hidden -ErrorAction Stop | Out-Null
            $started = $true; $via = 'launcher'
        } catch {}
    }

    if (-not $started) {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
        try {
            Start-Process -FilePath $psExe -WindowStyle Hidden -ErrorAction Stop -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-WindowStyle', 'Hidden', '-File', $LoopScript, '-FinalizeToOobe'
            ) | Out-Null
            $started = $true; $via = 'direct start'
        } catch {
            $result.Message = 'Could not start updates'
            $result.Detail = $_.Exception.Message
            return [pscustomobject]$result
        }
    }

    if (-not $started) {
        $result.Message = 'Could not start updates'
        $result.Detail = 'Collect logs for support.'
        return [pscustomobject]$result
    }

    $seen = $null
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 2
        $seen = Get-FbLoopProcess
        if ($seen) { break }
    }

    if ($seen) {
        $result.Ok = $true
        $result.Message = 'Updates started'
        $result.Detail = 'The progress screen should appear shortly. Leave the device on power.'
        $result.Pid = $seen.ProcessId
    } else {
        $result.Ok = $false
        $result.Message = 'Start was sent, but updates were not seen'
        $result.Detail = 'Wait a minute, or collect logs for support. ({0})' -f $via
    }
    return [pscustomobject]$result
}

function Find-FbDumpScript {
    $candidates = @()
    # USB destage first so splash does not keep using a stale C: copy.
    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue | ForEach-Object {
            $root = $_.DeviceID + '\'
            $candidates += (Join-Path $root 'FirstBase\WUPayload\Tools\fb-dump.ps1')
            $candidates += (Join-Path $root 'WUPayload\Tools\fb-dump.ps1')
            $candidates += (Join-Path $root 'Tools\fb-dump.ps1')
        }
    } catch {}
    $toolDir = $FbImFileDir
    if (-not $toolDir) { $toolDir = $PSScriptRoot }
    if ($toolDir) {
        $candidates += (Join-Path $toolDir 'fb-dump.ps1')
        $payloadDir = Split-Path -Path $toolDir -Parent
        if ($payloadDir) {
            $candidates += (Join-Path $payloadDir 'Tools\fb-dump.ps1')
            $stickRoot = Split-Path -Path $payloadDir -Parent
            if ($stickRoot) { $candidates += (Join-Path $stickRoot 'WUPayload\Tools\fb-dump.ps1') }
        }
        try {
            $qualifier = Split-Path -Path $toolDir -Qualifier
            if ($qualifier) {
                $volumeRoot = $qualifier + '\'
                $candidates += (Join-Path $volumeRoot 'FirstBase\WUPayload\Tools\fb-dump.ps1')
                $candidates += (Join-Path $volumeRoot 'WUPayload\Tools\fb-dump.ps1')
            }
        } catch {}
    }
    $candidates += (Join-Path $FbRoot 'Tools\fb-dump.ps1')
    $candidates += (Join-Path $FbRoot 'WUPayload\Tools\fb-dump.ps1')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Write-FbImAsciiNote {
    param([string]$Path, [string]$Text)
    if (-not $Path) { return }
    try {
        $body = [string]$Text
        if (-not $body.EndsWith("`r`n") -and -not $body.EndsWith("`n")) { $body = $body + "`r`n" }
        [System.IO.File]::WriteAllText($Path, $body, [System.Text.Encoding]::ASCII)
    } catch {}
}

function Copy-FbImOnDeviceLogs {
    param([string]$DestFolder)
    if (-not $DestFolder) { return 0 }
    try {
        if (-not (Test-Path -LiteralPath $DestFolder)) {
            New-Item -ItemType Directory -Path $DestFolder -Force -ErrorAction Stop | Out-Null
        }
    } catch { return 0 }

    $copied = 0
    $copyOne = {
        param([string]$Source, [string]$DestDir, [string]$Label)
        $safeLabel = ($Label -replace '[^\w\-]', '-')
        if (-not $safeLabel) { $safeLabel = 'source' }
        $missingPath = Join-Path $DestFolder ($safeLabel + '-MISSING.txt')
        if (-not $Source -or -not (Test-Path -LiteralPath $Source)) {
            Write-FbImAsciiNote -Path $missingPath -Text ('Source missing: ' + [string]$Source)
            return 0
        }
        $n = 0
        try { New-Item -ItemType Directory -Path $DestDir -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        $files = @()
        try { $files = @(Get-ChildItem -LiteralPath $Source -Force -Recurse -File -ErrorAction SilentlyContinue) } catch { $files = @() }
        foreach ($f in $files) {
            try {
                $rel = $f.FullName.Substring($Source.Length).TrimStart('\')
                $target = Join-Path $DestDir $rel
                $parent = Split-Path -Parent $target
                if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue | Out-Null
                }
                Copy-Item -LiteralPath $f.FullName -Destination $target -Force -ErrorAction Stop
                $n++
            } catch {
                $skipPath = Join-Path $DestFolder 'COPY-SKIP.txt'
                $msg = 'SKIP: ' + $f.FullName + ' :: ' + $_.Exception.Message
                try { Add-Content -LiteralPath $skipPath -Value $msg -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
            }
        }
        return $n
    }

    $copied += & $copyOne 'C:\Windows\Setup\FirstBase\Logs' (Join-Path $DestFolder 'Logs') 'Setup-FirstBase-Logs'
    $copied += & $copyOne 'C:\Windows\Setup\FirstBase\State' (Join-Path $DestFolder 'State') 'Setup-FirstBase-State'
    $copied += & $copyOne 'C:\ProgramData\FirstBase' (Join-Path $DestFolder 'ProgramData-FirstBase') 'ProgramData-FirstBase'
    $wuRoot = 'C:\Windows\Setup\FirstBase'
    $wuDest = Join-Path $DestFolder 'Logs'
    try { New-Item -ItemType Directory -Path $wuDest -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    $extra = @()
    try {
        $extra = @(Get-ChildItem -LiteralPath $wuRoot -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'WU-*.log' -or $_.Name -like '*.log' })
    } catch { $extra = @() }
    foreach ($f in $extra) {
        try {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $wuDest $f.Name) -Force -ErrorAction Stop
            $copied++
        } catch {
            $skipPath = Join-Path $DestFolder 'COPY-SKIP.txt'
            $msg = 'SKIP: ' + $f.FullName + ' :: ' + $_.Exception.Message
            try { Add-Content -LiteralPath $skipPath -Value $msg -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
        }
    }
    return $copied
}

function Copy-FbImDumpExtras {
    param([string]$DestFolder)
    if (-not $DestFolder) { return 0 }
    $n = Copy-FbImOnDeviceLogs -DestFolder $DestFolder
    $usbRoot = Join-Path $DestFolder 'UsbStickRoot'
    try { New-Item -ItemType Directory -Path $usbRoot -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue | ForEach-Object {
            $dl = ([string]$_.DeviceID).TrimEnd(':').ToUpper()
            if (-not $dl -or $dl -eq 'C') { return }
            foreach ($leaf in @(
                    'FirstBase-Deploy.log', 'FirstBase-Trace.log', 'FirstBase-DISM.log',
                    'FirstBase-DISM-wrapper.log', 'FirstBase-winpe.log', 'FirstBase-disksetup.log',
                    'fb-im-last-launch.log', 'FirstBase-Layout.txt', 'FirstBase-WIPE-PENDING.txt'
                )) {
                $src = $dl + ':\' + $leaf
                if (Test-Path -LiteralPath $src) {
                    try {
                        $dstName = [IO.Path]::GetFileNameWithoutExtension($leaf) + '-' + $dl + [IO.Path]::GetExtension($leaf)
                        Copy-Item -LiteralPath $src -Destination (Join-Path $usbRoot $dstName) -Force -ErrorAction Stop
                        $n++
                    } catch {}
                }
            }
        }
    } catch {}
    try {
        $tl = Join-Path $DestFolder 'tasklist.txt'
        (Get-Process | Select-Object Name, Id, CPU | Format-Table -AutoSize | Out-String) |
            Set-Content -LiteralPath $tl -Encoding ASCII -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $tl) { $n++ }
    } catch {}
    try {
        $si = Join-Path $DestFolder 'sysinfo.txt'
        $lines = @(
            ('Computer=' + $env:COMPUTERNAME)
            ('Captured=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            '=== Disk volumes ==='
        )
        try {
            $lines += @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
                ForEach-Object { '{0} {1} {2}' -f $_.DeviceID, $_.VolumeName, $_.FileSystem })
        } catch {}
        [System.IO.File]::WriteAllLines($si, $lines, [System.Text.Encoding]::ASCII)
        $n++
    } catch {}
    return $n
}

function Get-FbImDumpFileCount {
    param([string]$DestFolder)
    if (-not $DestFolder -or -not (Test-Path -LiteralPath $DestFolder)) { return 0 }
    try {
        return @(Get-ChildItem -LiteralPath $DestFolder -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -ne 'FirstBase-Issue.md' -and
                $_.Name -ne 'DUMP-SUMMARY.txt' -and
                $_.Name -ne 'fb-dump-host.txt'
            }).Count
    } catch { return 0 }
}

function Start-FbImDumpProcess {
    param([string]$DumpScript, [string]$DestFolder)
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
    $workDir = Split-Path -Parent $DumpScript
    if (-not $workDir) { $workDir = $env:SystemRoot }
    $esc = {
        param([string]$s)
        if ($null -eq $s) { return '' }
        return ([string]$s).Replace("'", "''")
    }
    $dumpQ = & $esc $DumpScript
    $destQ = & $esc $DestFolder
    # One -Command string so -Dest binds as a named parameter. Do not use -File:
    # Start-Process Hidden + -File often dropped -Dest on PS 5.1.
    $command = "& { & '$dumpQ' -Dest '$destQ' -NoPrompt }"
    $arg = '-NoProfile -ExecutionPolicy Bypass -NoLogo -NonInteractive -Command "' + $command + '"'
    $hostLog = Join-Path $DestFolder 'fb-dump-host.txt'
    $hostLines = @(
        ('ps=' + $psExe)
        ('file=' + $DumpScript)
        ('dest=' + $DestFolder)
        ('args=' + $arg)
        ('cwd=' + $workDir)
        ('started=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    )
    try { [System.IO.File]::WriteAllLines($hostLog, $hostLines, [System.Text.Encoding]::ASCII) } catch {}
    $p = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $psExe
        $psi.Arguments = $arg
        $psi.WorkingDirectory = $workDir
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
    } catch {
        $p = $null
    }
    if (-not $p) {
        try {
            $p = Start-Process -FilePath $psExe -ArgumentList $arg -WorkingDirectory $workDir -WindowStyle Hidden -PassThru -ErrorAction Stop
        } catch {
            $p = $null
        }
    }
    if (-not $p) {
        # Last resort: nested runspace so fb-dump's `exit` cannot kill splash ShowDialog.
        return Start-FbImDumpRunspace -DumpScript $DumpScript -DestFolder $DestFolder
    }
    return $p
}

function Start-FbImDumpRunspace {
    param([string]$DumpScript, [string]$DestFolder)
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript(@"
param(`$DumpScript, `$DestFolder)
`$ErrorActionPreference = 'Continue'
& `$DumpScript -Dest `$DestFolder -NoPrompt
"@).AddArgument($DumpScript).AddArgument($DestFolder)
    $handle = $ps.BeginInvoke()
    if (-not $handle) { throw 'Dump helper runspace did not start.' }
    return [pscustomobject]@{
        PSObject        = $true
        IsRunspace      = $true
        PowerShell      = $ps
        Handle          = $handle
        Runspace        = $rs
        HasExited       = $false
        ExitCode        = 0
        Refresh         = $null
    }
}

function Update-FbImDumpHandle {
    param($Handle)
    if (-not $Handle) { return $null }
    try {
        if ($Handle.PSObject.Properties.Name -contains 'IsRunspace' -and $Handle.IsRunspace) {
            $done = [bool]$Handle.Handle.IsCompleted
            $Handle.HasExited = $done
            if ($done) {
                try { $Handle.PowerShell.EndInvoke($Handle.Handle) | Out-Null } catch {}
                try { $Handle.ExitCode = 0 } catch {}
                try { $Handle.PowerShell.Dispose() } catch {}
                try { $Handle.Runspace.Close(); $Handle.Runspace.Dispose() } catch {}
            }
            return $Handle
        }
    } catch {}
    try { $Handle.Refresh() } catch {}
    return $Handle
}

function Invoke-FbImImmediatePower {
    param(
        [ValidateSet('Restart', 'Shutdown', 'Firmware')]
        [string]$Kind = 'Shutdown'
    )
    $result = [ordered]@{
        Ok      = $false
        Message = ''
    }
    $shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    if (-not (Test-Path -LiteralPath $shutdown)) { $shutdown = 'shutdown.exe' }
    # /fw with /r enters UEFI/firmware setup on the next boot (Windows shutdown.exe).
    # No /c comment: PS 5.1 Start-Process does not quote ArgumentList items with spaces.
    $shutArgs = @()
    $okMsg = 'Shutting down.'
    if ($Kind -eq 'Firmware') {
        $shutArgs = @('/r', '/fw', '/f', '/t', '0')
        $okMsg = 'Restarting to firmware.'
    } elseif ($Kind -eq 'Restart') {
        $shutArgs = @('/r', '/f', '/t', '0')
        $okMsg = 'Restarting.'
    } else {
        $shutArgs = @('/s', '/f', '/t', '0')
        $okMsg = 'Shutting down.'
    }
    try {
        Start-Process -FilePath $shutdown -ArgumentList $shutArgs -WindowStyle Hidden -ErrorAction Stop | Out-Null
        $result.Ok = $true
        $result.Message = $okMsg
        return [pscustomobject]$result
    } catch {}
    if ($Kind -eq 'Firmware') {
        $result.Message = 'Firmware restart did not start (shutdown /r /fw).'
        return [pscustomobject]$result
    }
    try {
        if ($Kind -eq 'Restart') { Restart-Computer -Force -ErrorAction Stop }
        else { Stop-Computer -Force -ErrorAction Stop }
        $result.Ok = $true
        $result.Message = $okMsg
    } catch {
        $result.Message = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Invoke-FbImImmediateShutdown {
    return Invoke-FbImImmediatePower -Kind 'Shutdown'
}

function Invoke-FbImImmediateRestart {
    return Invoke-FbImImmediatePower -Kind 'Restart'
}

function Invoke-FbImImmediateFirmware {
    return Invoke-FbImImmediatePower -Kind 'Firmware'
}

function Write-FbImManualSealMarker {
    param([string]$PowerAction = '')
    try {
        if (-not (Test-Path -LiteralPath $FbPd)) {
            New-Item -ItemType Directory -Path $FbPd -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
    $stamp = Get-Date -Format 'o'
    $payload = @{
        sealedAt = $stamp
        source   = 'fb-im'
        action   = [string]$PowerAction
    }
    try {
        ($payload | ConvertTo-Json -Compress) | Set-Content -LiteralPath $ManualSealMarker -Encoding UTF8 -Force
    } catch {
        try {
            Set-Content -LiteralPath $ManualSealMarker -Value ("manual-seal at {0} source=fb-im action={1}" -f $stamp, $PowerAction) -Encoding UTF8 -Force
        } catch {}
    }
}

function Get-FbImRemovableDumpRoot {
    try {
        $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue)
        foreach ($d in $disks) {
            $id = [string]$d.DeviceID
            if (-not $id) { continue }
            if ($id -match '^C') { continue }
            $root = $id.TrimEnd('\') + '\'
            if (Test-Path -LiteralPath $root) { return $id.TrimEnd('\') }
        }
    } catch {}
    try {
        if ($env:FB_USB_DRIVE) {
            $letter = ($env:FB_USB_DRIVE -replace ':$', '').ToUpper()
            if ($letter -and $letter -ne 'C' -and (Test-Path -LiteralPath ($letter + ':\'))) {
                return ($letter + ':')
            }
        }
    } catch {}
    return $null
}

function Get-FbImDumpNameLeaf {
    $sn = 'NOSN'
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        if ($bios.SerialNumber) { $sn = ($bios.SerialNumber -replace '[^\w\-]', '').Trim() }
        if ([string]::IsNullOrWhiteSpace($sn)) { $sn = 'NOSN' }
    } catch {}
    $hhmm = Get-Date -Format 'HHmm'
    $mfr = 'UNK'
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.Manufacturer) {
            $mfr = ($cs.Manufacturer -replace '[^\w]', '')
            if ($mfr.Length -gt 12) { $mfr = $mfr.Substring(0, 12) }
        }
    } catch {}
    return ('{0}-{1}-{2}' -f $sn, $hhmm, $mfr)
}

function Show-FbImDumpFolderPicker {
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { return $false }
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Choose a folder for support logs (USB stick or any writable folder).'
    $d.ShowNewFolderButton = $true
    if ($script:FbImManualDumpRoot -and (Test-Path -LiteralPath $script:FbImManualDumpRoot)) {
        $d.SelectedPath = $script:FbImManualDumpRoot
    }
    try {
        if ([System.Windows.Forms.DialogResult]::OK -eq $d.ShowDialog()) {
            $script:FbImManualDumpRoot = $d.SelectedPath
            return $true
        }
    } catch { return $false }
    return $false
}

function Get-FbImDumpDestFolder {
    # USB stick first; otherwise the folder the operator mapped. Never guess D:.
    $destRoot = Get-FbImRemovableDumpRoot
    if (-not $destRoot -and $script:FbImManualDumpRoot) {
        $destRoot = [string]$script:FbImManualDumpRoot
    }
    if (-not $destRoot) { return $null }
    $destRoot = $destRoot.TrimEnd('\')
    $logsRoot = Join-Path $destRoot 'FirstBase-Logs'
    try {
        if (-not (Test-Path -LiteralPath $logsRoot)) {
            New-Item -ItemType Directory -Path $logsRoot -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
    return (Join-Path $logsRoot (Get-FbImDumpNameLeaf))
}

function Write-FbImIssueMarkdown {
    param(
        [string]$DestFolder,
        [string]$IssueText
    )
    if (-not $DestFolder) { return }
    if ([string]::IsNullOrWhiteSpace($IssueText)) { $IssueText = 'No description provided' }
    $issOutPath = Join-Path $DestFolder 'FirstBase-Issue.md'
    try {
        if (-not (Test-Path -LiteralPath $DestFolder)) {
            New-Item -ItemType Directory -Path $DestFolder -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $dt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $cn = $env:COMPUTERNAME
        $files = @()
        try {
            $files = Get-ChildItem -Path $DestFolder -Recurse -File -EA SilentlyContinue |
                Where-Object { $_.Name -ne 'FirstBase-Issue.md' } |
                Sort-Object FullName |
                ForEach-Object { '- ' + $_.FullName.Substring($DestFolder.Length + 1).TrimStart('\') }
        } catch {}
        $mdLines = @(
            '# FirstBase Diagnostic Report'
            ''
            "**Date:** $dt"
            "**Machine:** $cn"
            ''
            '**Issue Description:**'
            $IssueText
            ''
            '## Logs Included'
        ) + @($files)
        [System.IO.File]::WriteAllLines($issOutPath, $mdLines, [System.Text.Encoding]::UTF8)
    } catch {}
}

function Clear-FbImWinlogonAutologon {
    # Same fence as Invoke-FbPreSysprepScrub STEP 3b. Audit ARM_AUTOLOGIN leaves
    # AutoAdminLogon=Administrator; a prior fb-im seal left DefaultUserName=defaultuser0.
    # Clearing only defaultuser0 leaves Administrator autologon. After sysprep /oobe
    # that bypasses customer OOBE and lands on the DefaultUser0 desktop.
    $wlPs = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $names = @(
        'AutoAdminLogon'
        'DefaultUserName'
        'DefaultPassword'
        'DefaultDomainName'
        'AutoLogonCount'
        'ForceAutoLogon'
        'AutoLogonSID'
        'SystemAutoLogon'
        'LastUsedUsername'
        'DisableLockWorkstation'
        'EnableFirstLogonAnimation'
    )
    foreach ($name in $names) {
        try { Remove-ItemProperty -LiteralPath $wlPs -Name $name -Force -ErrorAction SilentlyContinue } catch {}
        try {
            $regPath = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            & reg.exe delete $regPath /v $name /f 2>$null | Out-Null
        } catch {}
    }
    try {
        Set-ItemProperty -LiteralPath $wlPs -Name 'AutoAdminLogon' -Value '0' -Type String -Force -ErrorAction SilentlyContinue
    } catch {}
    try {
        Set-ItemProperty -LiteralPath $wlPs -Name 'Userinit' -Value 'C:\Windows\system32\userinit.exe,' -Type String -Force -ErrorAction SilentlyContinue
    } catch {}
    foreach ($oobeName in @('SkipMachineOOBE', 'SkipUserOOBE')) {
        try {
            Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' -Name $oobeName -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

function Clear-FbImDefaultUser0Autologon {
    Clear-FbImWinlogonAutologon
}

function Write-FbImWuHandoffStatus {
    param([string]$Message = 'Updates complete; starting hardware check.')
    try {
        if (-not (Test-Path -LiteralPath $FbRoot)) {
            New-Item -ItemType Directory -Path $FbRoot -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $updates = @()
        try {
            if (Test-Path -LiteralPath $StatusFile) {
                $prev = Get-Content -LiteralPath $StatusFile -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($prev -and $prev.updates) { $updates = @($prev.updates) }
            }
        } catch {}
        $payload = @{
            phase     = 'HardwareGate'
            message   = $Message
            updatedAt = (Get-Date).ToString('o')
            updates   = $updates
        }
        ($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatusFile -Encoding UTF8 -Force
    } catch {}
}

function Invoke-FbImStartHardwareGate {
    $result = [ordered]@{
        Ok      = $false
        Message = ''
        Detail  = ''
    }
    if (-not (Test-FbAdmin)) {
        $result.Message = 'Administrator access is required'
        $result.Detail = 'Close this window and open fb-im.cmd from the USB stick.'
        return [pscustomobject]$result
    }
    if ((Test-Path -LiteralPath $SealedMarker) -or (Test-Path -LiteralPath $PipelineMarker)) {
        $result.Message = 'This device is already sealed'
        $result.Detail = 'Hardware check cannot be started after seal.'
        return [pscustomobject]$result
    }
    if (Test-FbImWuActuallyInstalling) {
        $result.Message = 'Updates are still installing'
        $result.Detail = 'Do not start the hardware check while Windows Update is downloading or installing. Wait, then try again.'
        return [pscustomobject]$result
    }
    $updatesDone = $false
    try { if (Test-Path -LiteralPath $CompleteFlag) { $updatesDone = $true } } catch {}
    try { if (Test-Path -LiteralPath $DoneFlag) { $updatesDone = $true } } catch {}
    try { if (Test-Path -LiteralPath $HandoffPendingMarker) { $updatesDone = $true } } catch {}
    try {
        $wuNow = Get-FbImWuStatusObject
        if (Test-FbImStuckCompleteWithoutHandoff -Wu $wuNow -Sealed $false -HwDone $false -ActuallyInstalling $false) {
            $updatesDone = $true
        }
    } catch {}
    if (-not $updatesDone) {
        $result.Message = 'Updates are not finished'
        $result.Detail = 'This clears stale update-running markers and starts the hardware check only after Windows Update is idle and complete.'
        return [pscustomobject]$result
    }

    $notes = New-Object System.Collections.Generic.List[string]
    try { Clear-FbImTechStopFlag; [void]$notes.Add('Cleared leftover stop marker') } catch {}
    try {
        $self = $PID
        $killed = 0
        $procs = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue
        foreach ($p in @($procs)) {
            if (-not $p) { continue }
            if ([int]$p.ProcessId -eq [int]$self) { continue }
            $cmd = [string]$p.CommandLine
            if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
            $isLoop = ($cmd -match 'Invoke-WindowsUpdateLoop\.ps1') -or ($cmd -match 'FirstBaseLoopLauncher\.cmd')
            if (-not $isLoop) { continue }
            try {
                Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
                $killed++
            } catch {}
        }
        if ($killed -gt 0) { [void]$notes.Add(('Stopped {0} idle update-loop process(es)' -f $killed)) }
    } catch {}
    Start-Sleep -Milliseconds 400
    try {
        if (Test-Path -LiteralPath $LockFile) {
            Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
            [void]$notes.Add('Cleared update loop lock')
        }
    } catch {}
    try {
        if (Test-Path -LiteralPath $OperatorGateActive) {
            Remove-Item -LiteralPath $OperatorGateActive -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    try {
        if (Test-Path -LiteralPath $HwDoneMarker) {
            Remove-Item -LiteralPath $HwDoneMarker -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    try {
        if (Test-Path -LiteralPath $GateFailMarker) {
            Remove-Item -LiteralPath $GateFailMarker -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    try {
        if (-not (Test-Path -LiteralPath $FbPd)) {
            New-Item -ItemType Directory -Path $FbPd -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $line = ('handoff-pending at {0} pid={1} reason=fb-im start hardware gate' -f (Get-Date -Format 'o'), $PID)
        Set-Content -LiteralPath $HandoffPendingMarker -Value $line -Encoding ascii -Force
        [void]$notes.Add('Wrote hardware-gate pending marker')
    } catch {}
    try {
        if (-not (Test-Path -LiteralPath $CompleteFlag)) {
            Set-Content -LiteralPath $CompleteFlag -Value ("Completed at {0} (fb-im hardware-gate kick)" -f (Get-Date -Format s)) -Encoding ASCII -Force
            [void]$notes.Add('Wrote updates-complete marker')
        }
    } catch {}
    try { Write-FbImWuHandoffStatus -Message 'Updates complete; starting hardware check.' } catch {}
    [void]$notes.Add('Cleared stale updates-running status')

    if (-not (Test-Path -LiteralPath $LoopScript)) {
        $result.Message = 'Update software is missing on this device'
        $result.Detail = [string]::Join('. ', @($notes))
        return [pscustomobject]$result
    }

    $started = $false
    $via = ''
    $tasks = @(Get-FbFirstBaseTasks)
    foreach ($task in @($LoopTaskName, $LogonTaskName)) {
        if ($started) { break }
        if ($tasks -notcontains $task) { continue }
        & schtasks.exe /Run /TN $task 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $started = $true; $via = 'scheduled task' }
    }
    if (-not $started -and (Test-Path -LiteralPath $LoopLauncher)) {
        try {
            Start-Process -FilePath $LoopLauncher -WindowStyle Hidden -ErrorAction Stop | Out-Null
            $started = $true; $via = 'launcher'
        } catch {}
    }
    if (-not $started) {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
        try {
            Start-Process -FilePath $psExe -WindowStyle Hidden -ErrorAction Stop -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-WindowStyle', 'Hidden', '-File', $LoopScript, '-FinalizeToOobe'
            ) | Out-Null
            $started = $true; $via = 'direct start'
        } catch {
            $result.Message = 'Could not start the hardware check'
            $result.Detail = $_.Exception.Message
            return [pscustomobject]$result
        }
    }

    $seen = $null
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 2
        $seen = Get-FbLoopProcess
        if ($seen) { break }
    }
    if ($seen) {
        [void]$notes.Add('Hardware check loop started ({0})' -f $via)
        $result.Ok = $true
        $result.Message = 'Starting hardware check'
        $result.Detail = ([string]::Join('. ', @($notes)) + '. Rechecking device status.')
    } else {
        $result.Ok = $false
        $result.Message = 'Markers cleared, but hardware check was not seen'
        $result.Detail = ([string]::Join('. ', @($notes)) + '. Wait a minute, or collect logs. ({0})' -f $via)
    }
    return [pscustomobject]$result
}

function Invoke-FbImPassHardwareCheck {
    $result = [ordered]@{ Ok = $false; Message = ''; Detail = '' }
    if (-not (Test-FbAdmin)) {
        $result.Message = 'Administrator access is required'
        $result.Detail = 'Close this window and open fb-im.cmd from the USB stick.'
        return [pscustomobject]$result
    }
    try {
        if (-not (Test-Path -LiteralPath $FbPd)) {
            New-Item -ItemType Directory -Path $FbPd -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
    try {
        if (Test-Path -LiteralPath $GateFailMarker) {
            Remove-Item -LiteralPath $GateFailMarker -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    $stamp = Get-Date -Format 'o'
    try {
        Set-Content -LiteralPath $HwDoneMarker -Value ("hardware-gate PASS at {0} fb-im-manual" -f $stamp) -Encoding ascii -Force
    } catch {}
    $payload = [ordered]@{
        Passed     = $true
        At         = $stamp
        Summary    = 'manual-pass'
        ManualPass = $true
        Failed     = @()
        Checks     = @()
    }
    try {
        ($payload | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $HwResultMarker -Encoding UTF8 -Force
    } catch {}
    $result.Ok = $true
    $result.Message = 'Hardware check marked passed'
    $result.Detail = 'Fail marker cleared. Rechecking device status.'
    return [pscustomobject]$result
}

function Invoke-FbImSealToOobe {
    param(
        [ValidateSet('Restart', 'Shutdown')]
        [string]$PowerAction
    )
    $result = [ordered]@{ Ok = $false; Message = ''; Detail = '' }

    if (-not (Test-FbAdmin)) {
        $result.Message = 'Administrator access is required'
        $result.Detail = 'Close this window and open fb-im.cmd from the USB stick.'
        return [pscustomobject]$result
    }

    $cbsGate = $null
    try { $cbsGate = Test-FbImCbsRebootUnsafe } catch { $cbsGate = $null }
    if ($cbsGate -and [bool]$cbsGate.Unsafe) {
        $result.Message = 'Seal blocked - Windows is still committing boot files'
        $result.Detail = ('A forced restart now can cause 0xc000000f / missing ntoskrnl. Wait for the update loop to reboot. {0}' -f $cbsGate.Detail)
        return [pscustomobject]$result
    }

    # Stop update loop if still running.
    try {
        $loop = Get-FbLoopProcess
        if ($loop) {
            Stop-Process -Id $loop.ProcessId -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
        }
    } catch {}
    if (Test-Path -LiteralPath $LockFile) {
        try { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue } catch {}
    }

    # Remove FirstBase scheduled tasks.
    $taskNames = @(Get-FbFirstBaseTasks)
    foreach ($tn in $taskNames) {
        try {
            $leaf = ($tn -replace '^FirstBase\\', '')
            Unregister-ScheduledTask -TaskName $leaf -TaskPath '\FirstBase\' -Confirm:$false -ErrorAction SilentlyContinue
        } catch {}
        try { & schtasks.exe /Delete /TN $tn /F 2>$null | Out-Null } catch {}
    }

    # Remove FirstBase autostart values.
    foreach ($key in @($RunOnceKey, $RunKey)) {
        try {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                if ($p.Name -match '(?i)firstbase') {
                    try { Remove-ItemProperty -LiteralPath $key -Name $p.Name -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
        } catch {}
    }

    # Remove SetupComplete and runnable residue under Setup\FirstBase (keep Logs).
    if (Test-Path -LiteralPath $SetupCompleteCmd) {
        try { Remove-Item -LiteralPath $SetupCompleteCmd -Force -ErrorAction SilentlyContinue } catch {}
    }
    foreach ($path in @(Get-FbExecutableResidue)) {
        try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch {}
    }
    try {
        if (Test-Path -LiteralPath $FbPd) {
            Get-ChildItem -LiteralPath $FbPd -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { @('.ps1', '.cmd', '.bat') -contains $_.Extension.ToLower() } |
                ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
                }
        }
    } catch {}

    $sysprepExe = Join-Path $env:SystemRoot 'System32\Sysprep\Sysprep.exe'
    if (-not (Test-Path -LiteralPath $sysprepExe)) {
        $result.Message = 'Sysprep is missing on this device'
        $result.Detail = 'Cannot seal to customer OOBE. Collect logs, then re-image. Do not restart or shut down.'
        return [pscustomobject]$result
    }

    try {
        if (-not (Test-Path -LiteralPath $FbPd)) {
            New-Item -ItemType Directory -Path $FbPd -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $stamp = Get-Date -Format 'o'
        Set-Content -LiteralPath $PipelineMarker -Value ("Pipeline completed at {0} (fb-im seal)." -f $stamp) -Encoding UTF8 -Force
        Set-Content -LiteralPath $SealedMarker -Value ("Sealed at {0} (fb-im seal); device ready for customer OOBE after sysprep /oobe." -f $stamp) -Encoding UTF8 -Force
        Set-Content -LiteralPath $ArmSuppressed -Value ("Specialize arm suppressed at {0} (fb-im seal)" -f $stamp) -Encoding UTF8 -Force
    } catch {}

    # Scrub BEFORE sysprep (loop STEP 3b). Leaving AutoAdminLogon=Administrator
    # (or a prior defaultuser0 stamp) makes OOBE autologon DefaultUser0's desktop.
    Clear-FbImWinlogonAutologon
    try {
        Start-Process -FilePath 'net.exe' -ArgumentList @('user', 'Administrator', '/active:no') -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
    } catch {}

    # Same command as the automated loop. /oobe reseals to customer OOBE.
    # Do not fake AutoAdminLogon=defaultuser0. Do not fall back to shutdown.exe.
    # ArgumentList items have no spaces (PS 5.1 Start-Process quoting).
    $powerFlag = if ($PowerAction -eq 'Shutdown') { '/shutdown' } else { '/reboot' }
    $sysprepExit = $null
    try {
        $proc = Start-Process -FilePath $sysprepExe -ArgumentList @('/oobe', $powerFlag, '/quiet') -NoNewWindow -PassThru -Wait -ErrorAction Stop
        if ($proc) {
            try { $sysprepExit = [int]$proc.ExitCode } catch { $sysprepExit = $null }
        }
    } catch {
        try {
            Start-Process -FilePath 'net.exe' -ArgumentList @('user', 'Administrator', '/active:yes') -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
        } catch {}
        $result.Message = 'Sysprep did not start'
        $result.Detail = $_.Exception.Message
        return [pscustomobject]$result
    }

    if ($sysprepExit -ne 0) {
        try {
            Start-Process -FilePath 'net.exe' -ArgumentList @('user', 'Administrator', '/active:yes') -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
        } catch {}
        $result.Message = 'Sysprep refused to seal'
        $result.Detail = ('Sysprep exit {0}. Device stays in Audit. Do not restart or shut down until this is resolved (pending reboot is a common cause).' -f $sysprepExit)
        return [pscustomobject]$result
    }

    try { Write-FbImManualSealMarker -PowerAction $PowerAction } catch {}

    $result.Ok = $true
    $result.Message = if ($PowerAction -eq 'Shutdown') { 'Sealed. Shutting down into customer OOBE.' } else { 'Sealed. Restarting into customer OOBE.' }
    $result.Detail = 'Sysprep /oobe accepted. Next boot is the customer region/language screen, not DefaultUser0.'
    return [pscustomobject]$result
}

function Get-FbImLogoB64 {
    $toolsDir = $FbImFileDir
    if (-not $toolsDir) { $toolsDir = $PSScriptRoot }
    $candidates = @(
        (Join-Path (Split-Path -Path $toolsDir -Parent) 'Show-UpdateProgress.ps1'),
        (Join-Path $FbRoot 'Show-UpdateProgress.ps1'),
        (Join-Path $toolsDir '..\Show-UpdateProgress.ps1')
    )
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
            $m = [regex]::Match($raw, '\$script:FbSplashLogoB64\s*=\s*''([^'']+)''')
            if ($m.Success) { return $m.Groups[1].Value }
        } catch {}
    }
    return $null
}

# =============================================================================
# WPF SHELL
# =============================================================================
function Show-FbImWindow {
    param(
        [string]$FocusAction = 'Menu',
        [object]$EmbedHost = $null,
        [scriptblock]$OnEmbedClose = $null
    )

    # Caller (fb-im.cmd entry) may have set Stop; wiring uses null-safe clicks.
    # Do not inherit Stop or a missing FindName kills the host splash ShowDialog.
    $ErrorActionPreference = 'Continue'

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase -ErrorAction Stop
        Add-Type -AssemblyName System.Xaml -ErrorAction Stop
    } catch {
        Write-Host ''
        Write-Host '  Unable to open the technician window on this device.' -ForegroundColor Red
        Write-Host '  Windows presentation components are missing or blocked.' -ForegroundColor DarkGray
        Write-Host ''
        try { [void][Console]::ReadLine() } catch {}
        return
    }

    $logoB64 = Get-FbImLogoB64
    $logoXaml = '<Border Width="44" Height="44" Margin="0,0,10,0" VerticalAlignment="Center"/>'
    if ($logoB64) {
        $logoXaml = '<Ellipse Name="LogoEllipse" Width="44" Height="44" Margin="0,0,10,0" VerticalAlignment="Center"/>'
    }

    $devVisibility = if ($FbBuild.Dev) { 'Visible' } else { 'Collapsed' }
    $stopVisibility = if (Test-FbImDestageStopEnabled) { 'Visible' } else { 'Collapsed' }
    $rawVer = ''
    if ($FbBuild.Launcher) { $rawVer = [string]$FbBuild.Launcher }
    $rawVer = ($rawVer -replace '[^0-9.]', '').Trim('.')
    if ([string]::IsNullOrWhiteSpace($rawVer)) { $rawVer = '5.4.12' }
    $subtitle = 'v' + $rawVer
    $embedBackVisibility = if ($EmbedHost) { 'Visible' } else { 'Collapsed' }
    $script:FbImEmbedHosted = [bool]$EmbedHost
    $footerText = 'For Internal Use Only'

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Project LoneWolf - Technician Tools"
        Width="1100" Height="700" MinWidth="640" MinHeight="480"
        WindowStartupLocation="CenterScreen"
        WindowState="Maximized"
        Background="#FF02040A"
        FontFamily="Segoe UI"
        ResizeMode="CanResize">
  <!-- ScrollViewer is the embed root. Nested Viewbox plus a fixed 640px canvas
       clipped notes off the splash DesignCanvas with no wheel target.
       Fill the host; scroll only if details overflow. -->
  <ScrollViewer Name="FbImScroller"
                VerticalScrollBarVisibility="Auto"
                HorizontalScrollBarVisibility="Disabled"
                CanContentScroll="False"
                PanningMode="VerticalOnly"
                HorizontalAlignment="Stretch"
                VerticalAlignment="Stretch"
                Background="#FF02040A"
                Focusable="True">
  <Grid Name="FbImRoot" Margin="14,10,14,10" MinWidth="560">
    <Grid.Resources>
    <Style TargetType="Button" x:Key="PrimaryBtn">
      <Setter Property="Background" Value="#FF0A1B33"/>
      <Setter Property="Foreground" Value="#FFE8F4FF"/>
      <Setter Property="BorderBrush" Value="#FF22D3EE"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#FF123154"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="#FF1A5A88"/>
          <Setter Property="Opacity" Value="0.9"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Opacity" Value="0.45"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="Button" x:Key="QuietBtn" BasedOn="{StaticResource PrimaryBtn}">
      <Setter Property="BorderBrush" Value="#FF123154"/>
      <Setter Property="Foreground" Value="#FFB0C4DE"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>
    </Grid.Resources>

    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <Button Name="BtnEmbedBack" DockPanel.Dock="Right" Content="Back to splash tools"
              Style="{StaticResource QuietBtn}" VerticalAlignment="Center" Margin="12,0,0,0"
              Visibility="$embedBackVisibility"/>
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
        $logoXaml
        <StackPanel VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="PROJECT LONEWOLF" FontSize="18" FontWeight="Bold" Foreground="#FFE8F4FF"/>
            <Border Margin="10,0,0,0" Padding="6,1" Background="#FF1A0A0A" BorderBrush="#FFEF5350"
                    BorderThickness="1" CornerRadius="4" VerticalAlignment="Center"
                    Visibility="$devVisibility">
              <TextBlock Text="DEV" Foreground="#FFFFCDD2" FontSize="10" FontWeight="Bold"/>
            </Border>
          </StackPanel>
          <TextBlock Text="Technician tools" FontSize="12" Foreground="#FF6B8CB0" Margin="0,1,0,0"/>
          <TextBlock Text="$subtitle" FontSize="10" Foreground="#FF4A6A88" Margin="0,2,0,0"/>
        </StackPanel>
      </StackPanel>
    </DockPanel>

    <!-- Status | actions on one row; notes take leftover height (on-screen in splash). -->
    <Grid Name="MainWorkArea" Grid.Row="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*" MinHeight="132"/>
      </Grid.RowDefinitions>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="340"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

    <Border Grid.Row="0" Grid.Column="0" Name="StatusHero" CornerRadius="8" Padding="14,12"
            Margin="0,0,10,8" Background="#FF071325" BorderBrush="#FF123154" BorderThickness="1"
            VerticalAlignment="Stretch">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0" Margin="0,0,0,10">
          <Ellipse Name="StatusLamp" Width="18" Height="18" Fill="#FF6B8CB0"
                   Stroke="#FF8FB4D9" StrokeThickness="2"
                   DockPanel.Dock="Left" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <Button Name="BtnRefresh" DockPanel.Dock="Right" Content="Check"
                  Style="{StaticResource QuietBtn}" Padding="8,4" FontSize="11" MinWidth="64"/>
          <TextBlock Name="StatusLabel" Text="Device" FontSize="12" Foreground="#FF6B8CB0"
                     FontWeight="SemiBold" VerticalAlignment="Center"/>
        </DockPanel>
        <StackPanel Grid.Row="1">
          <Border Name="StatusSealChipBorder" Padding="10,3" CornerRadius="4" HorizontalAlignment="Left"
                  Background="#FF1A0A0A" BorderBrush="#FFC62828" BorderThickness="1" Margin="0,0,0,10">
            <TextBlock Name="StatusSealChip" Text="..." FontSize="12" FontWeight="Bold"
                       Foreground="#FFEF5350"/>
          </Border>
          <TextBlock Name="StatusHeadline" Text="..." FontSize="36" FontWeight="Bold"
                     Foreground="#FFB0C4DE" TextWrapping="Wrap"/>
          <TextBlock Name="StatusIdentity" Text="" FontSize="12" Foreground="#FF8FB4D9" Margin="0,6,0,8"
                     TextWrapping="Wrap"/>
          <TextBlock Name="ActionMessage" Text="" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,8"
                     Foreground="#FF22D3EE"/>
          <StackPanel Name="StatusIssues" Margin="0,4,0,0"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="0" Grid.Column="1" Name="ActionsPanel" CornerRadius="8" Padding="10,10"
            Margin="0,0,0,8" Background="#FF071325" BorderBrush="#FF123154" BorderThickness="1">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Actions" FontSize="11" Foreground="#FF6B8CB0"
                   FontWeight="SemiBold" Margin="0,0,0,6"/>
        <UniformGrid Grid.Row="1" Name="ActionsGrid" Rows="2" Columns="2" Margin="0,0,0,0">
          <StackPanel Margin="0,0,6,6">
            <Button Name="BtnRestart" Content="Restart updates" Style="{StaticResource PrimaryBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34"/>
            <Button Name="BtnStopUpdates" Content="Stop updates" Style="{StaticResource PrimaryBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34" Margin="0,6,0,0"
                    BorderBrush="#FFEF5350" Visibility="$stopVisibility" IsEnabled="False"/>
          </StackPanel>
          <StackPanel Margin="6,0,0,6">
            <Button Name="BtnCollect" Content="Collect logs" Style="{StaticResource PrimaryBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34"/>
            <Button Name="BtnChooseDumpFolder" Content="Choose export folder" Style="{StaticResource QuietBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34" Margin="0,6,0,0"/>
          </StackPanel>
          <StackPanel Margin="0,6,6,0">
            <Button Name="BtnBios" Content="BIOS" Style="{StaticResource PrimaryBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34" Visibility="Collapsed"/>
            <Button Name="BtnPowerRestart" Content="Restart" Style="{StaticResource PrimaryBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34" Margin="0,6,0,0"
                    Visibility="Collapsed"/>
            <Button Name="BtnShutdown" Content="Shutdown" Style="{StaticResource PrimaryBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34" Margin="0,6,0,0"
                    BorderBrush="#FFEF5350" Visibility="Collapsed"/>
          </StackPanel>
          <StackPanel Margin="6,6,0,0">
            <Button Name="BtnStartHardwareGate" Content="Start Hardware Checks"
                    Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Stretch" MinHeight="34"
                    BorderBrush="#FFFFB74D" Visibility="Collapsed" IsEnabled="False"/>
            <Button Name="BtnPassHardware" Content="Pass hardware check" Style="{StaticResource PrimaryBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34" Margin="0,6,0,0"/>
            <Button Name="BtnSeal" Content="Seal device" Style="{StaticResource PrimaryBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34" Margin="0,6,0,0"
                    BorderBrush="#FFEF5350"/>
          </StackPanel>
        </UniformGrid>
      </Grid>
    </Border>

    <Border Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Name="NotesPanel" CornerRadius="8"
            Padding="12,10" Background="#FF071325" BorderBrush="#FF22D3EE" BorderThickness="1"
            Visibility="Collapsed" MinHeight="132">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*" MinHeight="88"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Name="CollectBanner" Margin="0,0,0,8" Visibility="Collapsed">
          <TextBlock Text="Collecting logs" FontSize="13" FontWeight="SemiBold" Foreground="#FF22D3EE" Margin="0,0,0,6"/>
          <ProgressBar Name="CollectProgress" Height="8" Margin="0,0,0,6"
                       IsIndeterminate="False" Minimum="0" Maximum="100" Value="0"
                       Background="#FF0A1B33" Foreground="#FF22D3EE" BorderThickness="0"/>
          <TextBlock Name="CollectStatus" Text="Gathering logs... You can type notes below."
                     FontSize="12" Foreground="#FF6B8CB0" TextWrapping="Wrap"/>
        </StackPanel>
        <TextBlock Grid.Row="1" Text="What went wrong?" FontSize="13" FontWeight="SemiBold"
                   Foreground="#FFE8F4FF" Margin="0,0,0,6"/>
        <TextBox Grid.Row="2" Name="NotesBox" AcceptsReturn="True" TextWrapping="Wrap"
                 VerticalScrollBarVisibility="Auto" FontSize="14"
                 Background="#FF030609" Foreground="#FFE8F4FF" BorderBrush="#FF123154"
                 BorderThickness="1" Padding="8" CaretBrush="#FF22D3EE" MinHeight="88"/>
        <DockPanel Grid.Row="3" Margin="0,8,0,0">
          <Button Name="BtnSaveNotes" DockPanel.Dock="Right" Content="Save notes"
                  Style="{StaticResource QuietBtn}" Margin="12,0,0,0" Visibility="Collapsed"/>
          <Button Name="BtnOpenFolder" DockPanel.Dock="Right" Content="Open folder"
                  Style="{StaticResource QuietBtn}" Margin="12,0,0,0" Visibility="Collapsed"/>
          <TextBlock Text="Notes save into FirstBase-Issue.md while collection runs."
                     FontSize="11" Foreground="#FF6B8CB0" TextWrapping="Wrap" VerticalAlignment="Center"/>
        </DockPanel>
      </Grid>
    </Border>
    </Grid>

    <!-- Seal page (same window; Restart / Shutdown) -->
    <Border Name="SealPage" Grid.Row="1" CornerRadius="8" Padding="28,20"
            Background="#FF071325" BorderBrush="#FF123154" BorderThickness="1"
            Visibility="Collapsed" VerticalAlignment="Center" HorizontalAlignment="Center"
            Width="520" MaxWidth="520">
      <StackPanel>
        <TextBlock Text="Seal device" FontSize="20" FontWeight="Bold" Foreground="#FFE8F4FF" HorizontalAlignment="Center"/>
        <TextBlock Text="Both options scrub FirstBase leftovers and run sysprep /oobe. Restart uses /reboot. Shutdown uses /shutdown. Next boot is customer OOBE, not DefaultUser0."
                   FontSize="13" Foreground="#FF6B8CB0" TextWrapping="Wrap" TextAlignment="Center"
                   HorizontalAlignment="Center" Margin="0,10,0,20"/>
        <Button Name="BtnSealRestart" Content="Restart" Style="{StaticResource PrimaryBtn}"
                HorizontalAlignment="Stretch" Margin="0,0,0,10" Padding="14,10" FontSize="15"/>
        <Button Name="BtnSealShutdown" Content="Shutdown" Style="{StaticResource PrimaryBtn}"
                HorizontalAlignment="Stretch" Margin="0,0,0,14" Padding="14,10" FontSize="15"/>
        <TextBlock Name="SealStatus" Text="" FontSize="12" Foreground="#FF22D3EE"
                   TextWrapping="Wrap" TextAlignment="Center" HorizontalAlignment="Center" MinHeight="18" Margin="0,0,0,12"/>
        <Button Name="BtnSealCancel" Content="Cancel" Style="{StaticResource QuietBtn}"
                HorizontalAlignment="Center" Padding="12,8"/>
      </StackPanel>
    </Border>

    <TextBlock Grid.Row="2" Margin="0,8,0,0" FontSize="10" Foreground="#FF4A6A88"
               Text="$footerText"/>

    <Grid Name="FbImBusyOverlay" Grid.Row="0" Grid.RowSpan="3" Visibility="Collapsed"
          Background="#CC02040A" Panel.ZIndex="100" IsHitTestVisible="False">
      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Width="360">
        <TextBlock Name="FbImBusyText" Text="Working..." FontSize="18" FontWeight="SemiBold"
                   Foreground="#FFE8F4FF" HorizontalAlignment="Center" TextAlignment="Center"
                   TextWrapping="Wrap" Margin="0,0,0,14"/>
        <ProgressBar IsIndeterminate="True" Width="280" Height="4" Background="#FF0A1B33"
                     Foreground="#FF22D3EE" BorderThickness="0" HorizontalAlignment="Center"/>
      </StackPanel>
    </Grid>
  </Grid>
  </ScrollViewer>
</Window>
"@

    $reader = $null
    $window = $null
    try {
        $reader = New-Object System.Xml.XmlNodeReader $xaml
        $window = [Windows.Markup.XamlReader]::Load($reader)
    } catch {
        Write-Host ''
        Write-Host '  fb-im window failed to load.' -ForegroundColor Red
        Write-Host ("  {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
        Write-Host ''
        try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 12 }
        throw
    }
    if (-not $window) {
        Write-Host '  fb-im window loaded empty.' -ForegroundColor Red
        try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 12 }
        throw 'XamlReader returned no window'
    }
    $uiRoot = $window.FindName('FbImRoot')
    if (-not $uiRoot) { $uiRoot = $window.Content }
    $scroller = $null
    try { $scroller = $window.FindName('FbImScroller') } catch {}
    $scaleBox = $scroller

    $dispatcher = if ($EmbedHost) { $EmbedHost.Dispatcher } else { $window.Dispatcher }

    # Embedding loads a second Window via XamlReader. Default ShutdownMode is
    # OnLastWindowClose — closing that unused shell exits the splash with no error.
    if ($EmbedHost) {
        try {
            $app = [System.Windows.Application]::Current
            if ($app) {
                $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
            }
        } catch {}
    }

    if ($logoB64) {
        try {
            $bytes = [Convert]::FromBase64String($logoB64)
            $ms = New-Object System.IO.MemoryStream(,$bytes)
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.StreamSource = $ms
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit()
            $bmp.Freeze()
            $brush = New-Object System.Windows.Media.ImageBrush $bmp
            $brush.Stretch = [System.Windows.Media.Stretch]::UniformToFill
            $logoEl = $window.FindName('LogoEllipse')
            if (-not $logoEl -and $uiRoot) { $logoEl = $uiRoot.FindName('LogoEllipse') }
            if ($logoEl) { $logoEl.Fill = $brush }
        } catch {}
    }

    $find = {
        param([string]$Name)
        $el = $null
        try { $el = $window.FindName($Name) } catch {}
        if (-not $el -and $uiRoot) { try { $el = $uiRoot.FindName($Name) } catch {} }
        return $el
    }

    $statusHero     = & $find 'StatusHero'
    $statusLamp     = & $find 'StatusLamp'
    $statusLabel    = & $find 'StatusLabel'
    $statusHeadline = & $find 'StatusHeadline'
    $statusSealChip = & $find 'StatusSealChip'
    $statusSealChipBorder = & $find 'StatusSealChipBorder'
    $statusIdentity = & $find 'StatusIdentity'
    $statusIssues   = & $find 'StatusIssues'
    $btnRefresh     = & $find 'BtnRefresh'
    $btnRestart     = & $find 'BtnRestart'
    $btnStopUpdates = & $find 'BtnStopUpdates'
    $btnStartHardwareGate = & $find 'BtnStartHardwareGate'
    $btnCollect     = & $find 'BtnCollect'
    $btnChooseDump  = & $find 'BtnChooseDumpFolder'
    $btnSeal        = & $find 'BtnSeal'
    $btnPassHardware = & $find 'BtnPassHardware'
    $btnPowerRestart = & $find 'BtnPowerRestart'
    $btnBios        = & $find 'BtnBios'
    $btnShutdown    = & $find 'BtnShutdown'
    $btnSealRestart = & $find 'BtnSealRestart'
    $btnSealShutdown = & $find 'BtnSealShutdown'
    $btnSealCancel  = & $find 'BtnSealCancel'
    $btnOpenFolder  = & $find 'BtnOpenFolder'
    $btnSaveNotes   = & $find 'BtnSaveNotes'
    $btnEmbedBack   = & $find 'BtnEmbedBack'
    $actionMessage  = & $find 'ActionMessage'
    $actionsPanel   = & $find 'ActionsPanel'
    $notesPanel     = & $find 'NotesPanel'
    $notesBox       = & $find 'NotesBox'
    $collectBanner  = & $find 'CollectBanner'
    $collectProgress = & $find 'CollectProgress'
    $collectStatus  = & $find 'CollectStatus'
    $mainWorkArea   = & $find 'MainWorkArea'
    $sealPage       = & $find 'SealPage'
    $sealStatus     = & $find 'SealStatus'
    $busyOverlay    = & $find 'FbImBusyOverlay'
    $busyText       = & $find 'FbImBusyText'

    foreach ($tipEl in @($window, $uiRoot, $btnRefresh, $btnRestart, $btnStopUpdates, $btnStartHardwareGate, $btnCollect, $btnChooseDump, $btnSeal, $btnPassHardware, $btnBios, $btnPowerRestart, $btnShutdown, $btnSealRestart, $btnSealShutdown, $btnSealCancel, $btnOpenFolder, $btnSaveNotes, $btnEmbedBack, $statusHero, $actionsPanel, $notesPanel, $notesBox, $sealPage)) {
        if (-not $tipEl) { continue }
        try { $tipEl.ClearValue([System.Windows.FrameworkElement]::ToolTipProperty) } catch {}
        try { $tipEl.ToolTip = $null } catch {}
    }

    # Click handlers resolve names at invoke time. Embed mode used to return from
    # Show-FbImWindow immediately, so these locals vanished and Collect logs
    # threw into an empty catch (no notes, no progress, no error). Keep a script
    # copy for Collect / dump-timer even if the stack frame is gone.
    $script:FbImUi = @{
        BtnCollect       = $btnCollect
        BtnOpenFolder    = $btnOpenFolder
        BtnSaveNotes     = $btnSaveNotes
        BtnPassHardware  = $btnPassHardware
        BtnStartHardwareGate = $btnStartHardwareGate
        BtnBios          = $btnBios
        BtnPowerRestart  = $btnPowerRestart
        ActionMessage    = $actionMessage
        NotesPanel       = $notesPanel
        NotesBox         = $notesBox
        CollectBanner    = $collectBanner
        CollectProgress  = $collectProgress
        CollectStatus    = $collectStatus
        BusyOverlay      = $busyOverlay
    }

    if ($statusIdentity) {
        $idBits = New-Object System.Collections.Generic.List[string]
        if ($subtitle) { [void]$idBits.Add([string]$subtitle) }
        if ($FbBuild.Dev) { [void]$idBits.Add('DEV') }
        $statusIdentity.Text = [string]::Join('  ', @($idBits))
    }

    $script:FbImFitRoot = {
        $sv = $script:FbImScroller
        $root = $script:FbImRootEl
        if (-not $sv -or -not $root) { return }
        try {
            $vh = [double]$sv.ViewportHeight
            if ($vh -lt 1) { $vh = [double]$sv.ActualHeight }
            $m = $root.Margin
            $need = $vh - [double]$m.Top - [double]$m.Bottom
            if ($need -gt 80) { $root.MinHeight = $need }
        } catch {}
    }
    $script:FbImScroller = $scroller
    $script:FbImRootEl = $uiRoot
    if ($scroller) {
        $scroller.Add_SizeChanged({
            try { if ($script:FbImFitRoot) { & $script:FbImFitRoot } } catch {}
        })
        $scroller.Add_Loaded({
            try { if ($script:FbImFitRoot) { & $script:FbImFitRoot } } catch {}
        })
        $scroller.Add_PreviewMouseWheel({
            $e = $null
            try { $e = $args[1] } catch {}
            if (-not $e) { return }
            try {
                $walk = $e.OriginalSource
                $tb = $null
                try { if ($script:FbImUi) { $tb = $script:FbImUi.NotesBox } } catch {}
                while ($walk) {
                    if ($tb -and [object]::ReferenceEquals($walk, $tb)) { return }
                    $parent = $null
                    try { $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($walk) } catch {}
                    if (-not $parent) { try { $parent = $walk.Parent } catch {} }
                    $walk = $parent
                }
                $scroller.ScrollToVerticalOffset($scroller.VerticalOffset - [double]$e.Delta)
                $e.Handled = $true
            } catch {}
        })
        try { if ($script:FbImFitRoot) { & $script:FbImFitRoot } } catch {}
    }

    # Reparent after FindName so the Window namescope still resolves controls.
    if ($EmbedHost) {
        try {
            $window.Content = $null
            $EmbedHost.Children.Clear()
            $toHost = $scroller
            if (-not $toHost) { $toHost = $uiRoot }
            [void]$EmbedHost.Children.Add($toHost)
            try { if ($script:FbImFitRoot) { & $script:FbImFitRoot } } catch {}
            # Close the unused Window shell. ShutdownMode is OnExplicitShutdown
            # so this must not tear down the splash ShowDialog.
            try { $window.Close() } catch {}
        } catch {
            throw ("Embed into splash failed: {0}" -f $_.Exception.Message)
        }
    }

    $script:FbImDumpDest = $null
    $script:FbImDumpProc = $null
    $script:FbImNotesIdleArmed = $false
    $script:FbImBusy = $false

    $showFbImBusy = {
        param([string]$Message = 'Working...', [string]$Headline = 'WORKING')
        $script:FbImBusy = $true
        if ($busyText) { $busyText.Text = $Message }
        if ($busyOverlay) {
            $busyOverlay.IsHitTestVisible = $true
            $busyOverlay.Visibility = 'Visible'
        }
        try {
            $bcBusy = [System.Windows.Media.BrushConverter]::new()
            $workBrush = $bcBusy.ConvertFromString('#FF22D3EE')
            if ($statusLabel) { $statusLabel.Text = 'Device' }
            if ($statusHeadline -and $Headline) {
                $statusHeadline.Text = $Headline
                $statusHeadline.Foreground = $workBrush
            }
            if ($statusLamp) {
                $statusLamp.Fill = $workBrush
                $statusLamp.Stroke = $workBrush
                $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation
                $pulse.From = 1.0
                $pulse.To = 0.28
                $pulse.Duration = [TimeSpan]::FromMilliseconds(420)
                $pulse.AutoReverse = $true
                $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
                $statusLamp.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
            }
            if ($actionMessage -and $Message) {
                $actionMessage.Foreground = $workBrush
                $actionMessage.Text = $Message
            }
        } catch {}
        # Do not Dispatcher.Invoke(Background) here. That deadlocks the UI thread
        # (current handler never finishes, so Background never runs) and leaves
        # "Checking device status..." on screen forever.
    }
    $hideFbImBusy = {
        if ($busyOverlay) {
            $busyOverlay.Visibility = 'Collapsed'
            $busyOverlay.IsHitTestVisible = $false
        }
        try {
            if ($statusLamp) {
                $statusLamp.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                $statusLamp.Opacity = 1
            }
        } catch {}
        $script:FbImBusy = $false
    }

    $showSealPage = {
        if ($mainWorkArea) { $mainWorkArea.Visibility = 'Collapsed' }
        if ($sealPage) { $sealPage.Visibility = 'Visible' }
        if ($sealStatus) { $sealStatus.Text = '' }
    }

    $hideSealPage = {
        if ($sealPage) { $sealPage.Visibility = 'Collapsed' }
        if ($mainWorkArea) { $mainWorkArea.Visibility = 'Visible' }
        if ($sealStatus) { $sealStatus.Text = '' }
    }

    $runSealWithPower = {
        param([string]$PowerAction)
        if ($script:FbImBusy) { return }
        & $showFbImBusy ('Sealing device, then {0}...' -f $PowerAction.ToLower()) 'SEALING'
        if ($btnSealRestart) { $btnSealRestart.IsEnabled = $false }
        if ($btnSealShutdown) { $btnSealShutdown.IsEnabled = $false }
        if ($btnSealCancel) { $btnSealCancel.IsEnabled = $false }
        if ($sealStatus) {
            $sealStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
            $sealStatus.Text = ('Sealing device, then {0}...' -f $PowerAction.ToLower())
        }
        $sealOk = $false
        try {
            $r = Invoke-FbImSealToOobe -PowerAction $PowerAction
            if ($r -and $r.Ok) { $sealOk = $true }
            if ($sealStatus) {
                if ($sealOk) {
                    $sealStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
                } else {
                    $sealStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                }
                $sealStatus.Text = ($r.Message + "`n" + $r.Detail).Trim()
            }
            $actionMessage.Text = ($r.Message + "`n" + $r.Detail).Trim()
            if ($sealOk) {
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
            } else {
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
            }
        } finally {
            if ($sealOk) {
                # sysprep exit 0 stages async /reboot or /shutdown. Do not refresh
                # status: that can stall the power action on the UI thread.
            } else {
                & $hideFbImBusy
                if ($btnSealRestart) { $btnSealRestart.IsEnabled = $true }
                if ($btnSealShutdown) { $btnSealShutdown.IsEnabled = $true }
                if ($btnSealCancel) { $btnSealCancel.IsEnabled = $true }
                [void](& $runStatus)
            }
        }
    }

    $showNotesPanel = {
        $ui = $script:FbImUi
        if (-not $ui) { return }
        if ($ui.NotesPanel) { $ui.NotesPanel.Visibility = 'Visible' }
        if ($ui.CollectBanner) { $ui.CollectBanner.Visibility = 'Visible' }
        if ($ui.CollectProgress) { $ui.CollectProgress.Visibility = 'Visible' }
        try { if ($script:FbImFitRoot) { & $script:FbImFitRoot } } catch {}
        try { if ($ui.NotesBox) { [void]$ui.NotesBox.Focus() } } catch {}
    }

    $hideNotesPanel = {
        $ui = $script:FbImUi
        if (-not $ui) { return }
        if ($ui.NotesPanel) { $ui.NotesPanel.Visibility = 'Collapsed' }
        if ($ui.CollectBanner) { $ui.CollectBanner.Visibility = 'Collapsed' }
        if ($ui.CollectProgress) { $ui.CollectProgress.Visibility = 'Collapsed' }
        if ($ui.BtnOpenFolder) { $ui.BtnOpenFolder.Visibility = 'Collapsed' }
        if ($ui.BtnSaveNotes) { $ui.BtnSaveNotes.Visibility = 'Collapsed' }
        try { if ($ui.NotesBox) { $ui.NotesBox.Text = '' } } catch {}
    }

    $writeNotesLive = {
        $ui = $script:FbImUi
        if (-not $script:FbImDumpDest) { return }
        $text = ''
        try { if ($ui -and $ui.NotesBox) { $text = [string]$ui.NotesBox.Text } } catch {}
        if ([string]::IsNullOrWhiteSpace($text)) { $text = 'No description provided' }
        Write-FbImIssueMarkdown -DestFolder $script:FbImDumpDest -IssueText $text
    }

    $restartNotesIdleTimer = {
        $t = $script:FbImNotesHideTimer
        try { if ($t) { $t.Stop() } } catch {}
        # Only auto-hide after dump finished (or notes were explicitly saved) and
        # the tech has been idle for 8s - never hide solely because collection ended.
        if (-not $script:FbImNotesIdleArmed) { return }
        try { if ($t) { $t.Start() } } catch {}
    }
    $script:FbImRestartNotesIdleTimer = $restartNotesIdleTimer

    $finishNotesKeepOpen = {
        param([string]$StatusText)
        $ui = $script:FbImUi
        & $writeNotesLive
        if ($ui -and $ui.BtnSaveNotes) { $ui.BtnSaveNotes.Visibility = 'Collapsed' }
        if ($script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
            if ($ui -and $ui.CollectStatus) {
                $ui.CollectStatus.Text = ('Logs saved to {0}' -f $script:FbImDumpDest)
                $ui.CollectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
            }
            if ($ui -and $ui.CollectBanner) { $ui.CollectBanner.Visibility = 'Visible' }
            if ($ui -and $ui.BtnOpenFolder) { $ui.BtnOpenFolder.Visibility = 'Visible' }
            if ($ui -and $ui.ActionMessage) {
                $ui.ActionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
                if ([string]::IsNullOrWhiteSpace($StatusText)) {
                    $ui.ActionMessage.Text = 'Log collection finished. Keep typing notes - they save live; panel hides after 8s idle.'
                } else {
                    $ui.ActionMessage.Text = $StatusText
                }
            }
        }
        $script:FbImNotesIdleArmed = $true
        if ($script:FbImRestartNotesIdleTimer) { & $script:FbImRestartNotesIdleTimer }
    }

    $script:FbImShowNotesPanel = $showNotesPanel
    $script:FbImWriteNotesLive = $writeNotesLive
    $script:FbImFinishNotesKeepOpen = $finishNotesKeepOpen
    $script:FbImHideBusy = $hideFbImBusy

    $notesHideTimer = New-Object System.Windows.Threading.DispatcherTimer
    $notesHideTimer.Interval = [TimeSpan]::FromSeconds(8)
    $script:FbImNotesHideTimer = $notesHideTimer
    $notesHideTimer.Add_Tick({
        try { $script:FbImNotesHideTimer.Stop() } catch {}
        if ($script:FbImWriteNotesLive) { & $script:FbImWriteNotesLive }
        $ui = $script:FbImUi
        if ($ui) {
            if ($ui.NotesPanel) { $ui.NotesPanel.Visibility = 'Collapsed' }
            if ($ui.CollectBanner) { $ui.CollectBanner.Visibility = 'Collapsed' }
            if ($ui.CollectProgress) { $ui.CollectProgress.Visibility = 'Collapsed' }
            if ($ui.BtnOpenFolder) { $ui.BtnOpenFolder.Visibility = 'Collapsed' }
            if ($ui.BtnSaveNotes) { $ui.BtnSaveNotes.Visibility = 'Collapsed' }
            try { if ($ui.NotesBox) { $ui.NotesBox.Text = '' } } catch {}
        }
        $script:FbImNotesIdleArmed = $false
    })

    if ($notesBox) {
        $notesBox.Add_TextChanged({
            $ui = $script:FbImUi
            if (-not $ui -or -not $ui.NotesPanel) { return }
            if ($ui.NotesPanel.Visibility -ne 'Visible') { return }
            if (-not $script:FbImDumpDest) { return }
            if ($script:FbImWriteNotesLive) { & $script:FbImWriteNotesLive }
            if ($script:FbImNotesIdleArmed -and $script:FbImRestartNotesIdleTimer) {
                & $script:FbImRestartNotesIdleTimer
            }
        })
    }

    $applyStatus = {
        param($st)
        if (-not $st) { return }
        $bc = [System.Windows.Media.BrushConverter]::new()
        $kind = 'Red'
        try { if ($st.PSObject.Properties['ColorKind'] -and $st.ColorKind) { $kind = [string]$st.ColorKind } } catch {}
        $lampBrush = '#FFEF5350'
        $headBrush = '#FFEF5350'
        $heroBg = '#FF1A0A0A'
        $heroBd = '#FFC62828'
        if ($kind -eq 'Green') {
            $lampBrush = '#FF66BB6A'
            $headBrush = '#FF66BB6A'
            $heroBg = '#FF0A1F12'
            $heroBd = '#FF2E7D32'
        } elseif ($kind -eq 'Orange') {
            $lampBrush = '#FFFF9800'
            $headBrush = '#FFFF9800'
            $heroBg = '#FF1A1408'
            $heroBd = '#FFF57C00'
        } elseif ($kind -eq 'Purple') {
            $lampBrush = '#FFCE93D8'
            $headBrush = '#FFE1BEE7'
            $heroBg = '#FF1A1024'
            $heroBd = '#FFAB47BC'
        }
        if ($statusLabel) { $statusLabel.Text = 'Device' }
        if ($statusHeadline) {
            $statusHeadline.Text = [string]$st.Headline
            $statusHeadline.Foreground = $bc.ConvertFromString($headBrush)
        }
        if ($statusHero) {
            $statusHero.BorderBrush = $bc.ConvertFromString($heroBd)
            $statusHero.Background = $bc.ConvertFromString($heroBg)
        }
        if ($statusLamp) {
            $statusLamp.Fill = $bc.ConvertFromString($lampBrush)
            $statusLamp.Stroke = $bc.ConvertFromString($heroBd)
        }
        if ($statusSealChip -and $statusSealChipBorder) {
            $manualChip = $false
            try { if ($st.PSObject.Properties['ManualSealed'] -and $st.ManualSealed) { $manualChip = $true } } catch {}
            if (-not $manualChip -and $kind -eq 'Purple') { $manualChip = $true }
            if ($manualChip) {
                $statusSealChip.Text = 'MANUAL SEAL'
                $statusSealChip.Foreground = $bc.ConvertFromString('#FFE1BEE7')
                $statusSealChipBorder.Background = $bc.ConvertFromString('#FF2A1038')
                $statusSealChipBorder.BorderBrush = $bc.ConvertFromString('#FFCE93D8')
            } elseif ($st.Sealed) {
                $statusSealChip.Text = 'SEALED'
                $statusSealChip.Foreground = $bc.ConvertFromString('#FF66BB6A')
                $statusSealChipBorder.Background = $bc.ConvertFromString('#FF0A1F12')
                $statusSealChipBorder.BorderBrush = $bc.ConvertFromString('#FF2E7D32')
            } else {
                $statusSealChip.Text = 'NOT SEALED'
                $statusSealChip.Foreground = $bc.ConvertFromString('#FFEF5350')
                $statusSealChipBorder.Background = $bc.ConvertFromString('#FF1A0A0A')
                $statusSealChipBorder.BorderBrush = $bc.ConvertFromString('#FFC62828')
            }
        }
        $factBits = New-Object System.Collections.Generic.List[string]
        if ($subtitle) { [void]$factBits.Add([string]$subtitle) }
        try { if ($FbBuild.Dev) { [void]$factBits.Add('DEV') } } catch {}
        $factList = @()
        try {
            if ($st.PSObject.Properties['Facts'] -and $st.Facts) { $factList = @($st.Facts) }
            elseif ($st.PSObject.Properties['Details'] -and $st.Details) { $factList = @($st.Details) }
        } catch { $factList = @() }
        foreach ($f in $factList) {
            if (-not [string]::IsNullOrWhiteSpace([string]$f)) { [void]$factBits.Add([string]$f) }
        }
        if ($statusIdentity) {
            $statusIdentity.Text = [string]::Join('   ', @($factBits))
        }
        if ($statusIssues) {
            try { $statusIssues.Children.Clear() } catch {}
            foreach ($f in $factList) {
                if ([string]::IsNullOrWhiteSpace([string]$f)) { continue }
                $factTb = New-Object System.Windows.Controls.TextBlock
                $factTb.Text = [string]$f
                $factTb.FontSize = 14
                $factTb.Foreground = $bc.ConvertFromString('#FF8FB4D9')
                $factTb.TextWrapping = [System.Windows.TextWrapping]::Wrap
                $factTb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
                [void]$statusIssues.Children.Add($factTb)
            }
            foreach ($issue in @($st.Issues)) {
                if (-not $issue) { continue }
                $tb = New-Object System.Windows.Controls.TextBlock
                $tb.Text = [string]$issue.Text
                $tb.FontSize = 16
                $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
                $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
                $tb.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
                $issueColor = '#FFFF9800'
                if ([string]$issue.Level -eq 'fail') { $issueColor = '#FFEF5350' }
                elseif ($kind -eq 'Purple') { $issueColor = '#FFCE93D8' }
                $tb.Foreground = $bc.ConvertFromString($issueColor)
                [void]$statusIssues.Children.Add($tb)
            }
        }
        if ($btnRestart) {
            $btnRestart.IsEnabled = [bool]$st.CanRestart
        }
        $canSeal = $true
        try { if ($st.PSObject.Properties.Name -contains 'CanSeal') { $canSeal = [bool]$st.CanSeal } } catch {}
        if ($btnSeal) {
            $btnSeal.IsEnabled = [bool]$canSeal
            if ($kind -eq 'Purple') {
                $btnSeal.BorderBrush = $bc.ConvertFromString('#FFCE93D8')
            } else {
                $btnSeal.BorderBrush = $bc.ConvertFromString('#FFEF5350')
            }
        }
        $showShutdown = $true
        try {
            if ($script:FbImEmbedHosted) {
                $showShutdown = [bool]$st.Sealed
            }
        } catch { $showShutdown = -not [bool]$script:FbImEmbedHosted }
        if ($btnShutdown) {
            $btnShutdown.Visibility = $(if ($showShutdown) { 'Visible' } else { 'Collapsed' })
        }
        if ($btnPowerRestart) {
            $btnPowerRestart.Visibility = $(if ($showShutdown) { 'Visible' } else { 'Collapsed' })
        }
        if ($btnBios) {
            $btnBios.Visibility = $(if ($showShutdown) { 'Visible' } else { 'Collapsed' })
        }
        $hwFailed = $false
        $hwPassed = $false
        try { if ($st.PSObject.Properties.Name -contains 'HardwareFailed') { $hwFailed = [bool]$st.HardwareFailed } } catch {}
        try { if ($st.PSObject.Properties.Name -contains 'HardwarePassed') { $hwPassed = [bool]$st.HardwarePassed } } catch {}
        if ($btnPassHardware) {
            $btnPassHardware.IsEnabled = [bool]$st.Admin -and (-not $hwPassed)
            if ($hwFailed) {
                $btnPassHardware.BorderBrush = $bc.ConvertFromString('#FFFFB74D')
            } else {
                $btnPassHardware.BorderBrush = $bc.ConvertFromString('#FF22D3EE')
            }
        }
        $loopRunning = $false
        try { if ($st.PSObject.Properties.Name -contains 'LoopRunning') { $loopRunning = [bool]$st.LoopRunning } } catch {}
        if ($btnStopUpdates) {
            $btnStopUpdates.IsEnabled = [bool]$st.Admin -and $loopRunning
        }
        $showGateKick = $false
        $stuckGate = $false
        $actuallyInstalling = $false
        try { if ($st.PSObject.Properties.Name -contains 'StuckCompleteWithoutHandoff') { $stuckGate = [bool]$st.StuckCompleteWithoutHandoff } } catch {}
        try { if ($st.PSObject.Properties.Name -contains 'ActuallyInstalling') { $actuallyInstalling = [bool]$st.ActuallyInstalling } } catch {}
        try {
            if ($st.Destage -and (-not $st.Sealed) -and (-not $hwPassed)) { $showGateKick = $true }
            if ($stuckGate) { $showGateKick = $true }
            if ($st.Sealed) { $showGateKick = $false }
        } catch {}
        if ($btnStartHardwareGate) {
            $btnStartHardwareGate.Visibility = $(if ($showGateKick) { 'Visible' } else { 'Collapsed' })
            $btnStartHardwareGate.IsEnabled = [bool]$st.Admin -and $showGateKick -and (-not $actuallyInstalling) -and (-not $st.Sealed)
        }
    }

    $script:FbImApplyStatus = $applyStatus
    $statusTimer = New-Object System.Windows.Threading.DispatcherTimer
    $statusTimer.Interval = [TimeSpan]::FromMilliseconds(40)
    $script:FbImStatusTimer = $statusTimer
    $statusTimer.Add_Tick({
        try { $script:FbImStatusTimer.Stop() } catch {}
        try {
            $st = Get-FbImDeviceStatus
            if (-not $st) { throw 'Status probe returned nothing.' }
            if ($script:FbImApplyStatus) { & $script:FbImApplyStatus $st }
        } catch {
            try {
                $errText = [string]$_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($errText)) { $errText = [string]$_ }
                $bc = [System.Windows.Media.BrushConverter]::new()
                if ($statusLabel) { $statusLabel.Text = 'Device' }
                if ($statusHeadline) {
                    $statusHeadline.Text = 'CHECK FAILED'
                    $statusHeadline.Foreground = $bc.ConvertFromString('#FFEF5350')
                }
                if ($statusIdentity) { $statusIdentity.Text = $errText }
                if ($statusIssues) {
                    try { $statusIssues.Children.Clear() } catch {}
                    $tb = New-Object System.Windows.Controls.TextBlock
                    $tb.Text = ('Could not finish the status check: {0}' -f $errText)
                    $tb.FontSize = 16
                    $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
                    $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
                    $tb.Foreground = $bc.ConvertFromString('#FFEF5350')
                    [void]$statusIssues.Children.Add($tb)
                }
                if ($actionMessage) {
                    $actionMessage.Foreground = $bc.ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Status check failed: {0}' -f $errText)
                }
            } catch {}
        } finally {
            $script:FbImBusy = $false
            $script:FbImStatusQueued = $false
            $cb = $null
            try { $cb = $script:FbImStatusAfter } catch {}
            $script:FbImStatusAfter = $null
            if ($cb) { try { & $cb } catch {} }
        }
    })

    $runStatus = {
        param($After)
        if ($script:FbImStatusQueued) { return }
        $script:FbImStatusQueued = $true
        $script:FbImBusy = $true
        $script:FbImStatusAfter = $After
        try {
            if ($statusLabel) { $statusLabel.Text = 'Device' }
            if ($statusHeadline) {
                $statusHeadline.Text = 'Checking...'
                $statusHeadline.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFB0C4DE')
            }
            if ($statusIdentity) { $statusIdentity.Text = 'Reading computer, Windows state, hardware, and updates.' }
            if ($statusIssues) { try { $statusIssues.Children.Clear() } catch {} }
        } catch {}
        $started = $false
        try {
            $script:FbImStatusTimer.Stop()
            $script:FbImStatusTimer.Start()
            $started = $true
        } catch { $started = $false }
        if (-not $started) {
            try {
                $st = Get-FbImDeviceStatus
                if ($script:FbImApplyStatus) { & $script:FbImApplyStatus $st }
            } catch {}
            $script:FbImBusy = $false
            $script:FbImStatusQueued = $false
            $cb = $null
            try { $cb = $script:FbImStatusAfter } catch {}
            $script:FbImStatusAfter = $null
            if ($cb) { try { & $cb } catch {} }
        }
    }

    # Every Click handler is try/caught so a missing command / unexpected throw
    # cannot bubble into the host splash ShowDialog and exit the whole preview.
    if ($btnRefresh) {
        $btnRefresh.Add_Click({
            try {
                if ($script:FbImBusy) { return }
                [void](& $runStatus)
            } catch {
                try {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Status check failed: {0}' -f $_.Exception.Message)
                } catch {}
            }
        })
    }

    if ($btnRestart) {
    $btnRestart.Add_Click({
        try {
            if ($script:FbImBusy) { return }
            & $showFbImBusy 'Starting updates...' 'STARTING'
            $btnRestart.IsEnabled = $false
            $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
            $actionMessage.Text = 'Starting updates...'
            try {
                $r = Invoke-FbImRestartUpdates
                if ($r.Ok) {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
                } else {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                }
                $actionMessage.Text = ($r.Message + "`n" + $r.Detail).Trim()
            } finally {
                & $hideFbImBusy
                [void](& $runStatus)
            }
        } catch {
            try {
                & $hideFbImBusy
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = ('Restart updates failed: {0}' -f $_.Exception.Message)
            } catch {}
        }
    })
    }

    if ($btnStopUpdates) {
    $btnStopUpdates.Add_Click({
        try {
            if ($script:FbImBusy) { return }
            & $showFbImBusy 'Stopping Windows Update...' 'STOPPING'
            $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
            $actionMessage.Text = 'Stopping Windows Update...'
            try {
                $r = Invoke-FbImStopUpdates
                if ($r.Ok) {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFB74D')
                } else {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                }
                $actionMessage.Text = ($r.Message + "`n" + $r.Detail).Trim()
            } finally {
                & $hideFbImBusy
                [void](& $runStatus)
            }
        } catch {
            try {
                & $hideFbImBusy
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = ('Stop updates failed: {0}' -f $_.Exception.Message)
            } catch {}
        }
    })
    }

    if ($btnStartHardwareGate) {
    $btnStartHardwareGate.Add_Click({
        try {
            if ($script:FbImBusy) { return }
            & $showFbImBusy 'Starting hardware checks...' 'HARDWARE'
            $btnStartHardwareGate.IsEnabled = $false
            $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
            $actionMessage.Text = 'Starting hardware checks...'
            try {
                $r = Invoke-FbImStartHardwareGate
                if ($r.Ok) {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
                } else {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                }
                $actionMessage.Text = ($r.Message + "`n" + $r.Detail).Trim()
            } finally {
                & $hideFbImBusy
                [void](& $runStatus)
            }
        } catch {
            try {
                & $hideFbImBusy
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = ('Start hardware gate failed: {0}' -f $_.Exception.Message)
            } catch {}
        }
    })
    }

    $dumpTimer = New-Object System.Windows.Threading.DispatcherTimer
    $dumpTimer.Interval = [TimeSpan]::FromMilliseconds(800)
    $script:FbImDumpTimer = $dumpTimer
    $dumpTimer.Add_Tick({
        try {
            if (-not $script:FbImDumpProc) { return }
            $ui = $script:FbImUi
            $collectStatus = $null
            $collectProgress = $null
            $btnCollect = $null
            $btnOpenFolder = $null
            if ($ui) {
                $collectStatus = $ui.CollectStatus
                $collectProgress = $ui.CollectProgress
                $btnCollect = $ui.BtnCollect
                $btnOpenFolder = $ui.BtnOpenFolder
            }
            try {
                $script:FbImDumpProc = Update-FbImDumpHandle -Handle $script:FbImDumpProc
                if ($script:FbImDumpProc -and -not $script:FbImDumpProc.HasExited) {
                    if ($collectStatus) { $collectStatus.Text = 'Gathering logs... You can keep typing notes.' }
                    return
                }
            } catch { return }
            try { $script:FbImDumpTimer.Stop() } catch { try { $dumpTimer.Stop() } catch {} }
            $exitCode = 0
            try { $exitCode = [int]$script:FbImDumpProc.ExitCode } catch {}
            $script:FbImDumpProc = $null
            if ($collectProgress) {
                $collectProgress.IsIndeterminate = $false
                $collectProgress.Value = 100
            }
            if ($script:FbImHideBusy) { & $script:FbImHideBusy } else { $script:FbImBusy = $false }
            if ($btnCollect) { $btnCollect.IsEnabled = $true }
            $summaryPath = $null
            if ($script:FbImDumpDest) { $summaryPath = Join-Path $script:FbImDumpDest 'DUMP-SUMMARY.txt' }
            $copiedCount = 0
            try { $copiedCount = Get-FbImDumpFileCount -DestFolder $script:FbImDumpDest } catch { $copiedCount = 0 }
            if ($script:FbImDumpDest -and (-not $summaryPath -or -not (Test-Path -LiteralPath $summaryPath))) {
                try { $copiedCount = Copy-FbImDumpExtras -DestFolder $script:FbImDumpDest } catch {}
                try { $copiedCount = Get-FbImDumpFileCount -DestFolder $script:FbImDumpDest } catch { $copiedCount = 0 }
            } elseif ($copiedCount -le 0 -and $script:FbImDumpDest) {
                try { $copiedCount = Copy-FbImDumpExtras -DestFolder $script:FbImDumpDest } catch { $copiedCount = 0 }
                if ($copiedCount -le 0) {
                    try { $copiedCount = Get-FbImDumpFileCount -DestFolder $script:FbImDumpDest } catch { $copiedCount = 0 }
                }
            }
            # Dump finished mid-edit is common — keep the notes panel open and only
            # auto-hide after 8s of inactivity. Live MD writes happen on keystrokes.
            if ($copiedCount -le 0) {
                $failMsg = 'Dump copied 0 files. Collection failed.'
                if ($script:FbImFinishNotesKeepOpen) { & $script:FbImFinishNotesKeepOpen $failMsg }
                if ($collectStatus) {
                    $collectStatus.Text = $failMsg
                    $collectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                }
                try {
                    if (Get-Command Set-FbSplashTechStatus -ErrorAction SilentlyContinue) {
                        Set-FbSplashTechStatus $failMsg '#FFEF5350'
                    }
                } catch {}
                if ($script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
                    $btnOpenFolder.Visibility = 'Visible'
                }
            } elseif ($exitCode -eq 0 -and $script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
                if ($script:FbImFinishNotesKeepOpen) {
                    & $script:FbImFinishNotesKeepOpen 'Log collection finished. Keep typing notes - they save live; panel hides after 8s idle.'
                }
            } else {
                if ($script:FbImFinishNotesKeepOpen) {
                    & $script:FbImFinishNotesKeepOpen 'Log collection finished with problems. Notes still save live; panel hides after 8s idle.'
                }
                $collectStatus.Text = 'Log collection finished with problems. Check the USB stick for a partial folder.'
                $collectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFB74D')
                if ($script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
                    $btnOpenFolder.Visibility = 'Visible'
                }
            }
        } catch {}
    })

    if ($btnChooseDump) {
        $btnChooseDump.Add_Click({
            try {
                if (Show-FbImDumpFolderPicker) {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
                    $actionMessage.Text = ('Export folder set to {0}' -f $script:FbImManualDumpRoot)
                    if ($dumpDestHint) {
                        $dumpDestHint.Text = ('Logs will export to: {0}' -f $script:FbImManualDumpRoot)
                    }
                }
            } catch {
                try {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Could not choose a folder: {0}' -f $_.Exception.Message)
                } catch {}
            }
        })
    }

    if ($btnCollect) {
    $btnCollect.Add_Click({
        try {
            $ui = $script:FbImUi
            $actionMessage = $null
            $btnCollectUi = $null
            $collectProgress = $null
            $collectStatus = $null
            $busyOverlay = $null
            $notesBox = $null
            if ($ui) {
                $actionMessage = $ui.ActionMessage
                $btnCollectUi = $ui.BtnCollect
                $collectProgress = $ui.CollectProgress
                $collectStatus = $ui.CollectStatus
                $busyOverlay = $ui.BusyOverlay
                $notesBox = $ui.NotesBox
            }
            $setMsg = {
                param($Text, $Color)
                if (-not $actionMessage) { return }
                try {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
                    $actionMessage.Text = $Text
                } catch {}
            }
            # Immediate UI - never a silent no-op, even if dump dest is missing.
            if ($script:FbImShowNotesPanel) { & $script:FbImShowNotesPanel }
            if ($collectProgress) {
                $collectProgress.Visibility = 'Visible'
                $collectProgress.IsIndeterminate = $true
            }
            if ($collectStatus) {
                try {
                    $collectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF6B8CB0')
                    $collectStatus.Text = 'Collecting logs... You can type notes below.'
                } catch {}
            }
            & $setMsg 'Collecting logs. Type notes below.' '#FF22D3EE'

            if ($script:FbImBusy) {
                & $setMsg 'Wait - another action is still running.' '#FFFFB74D'
                return
            }

            $dump = Find-FbDumpScript
            if (-not $dump) {
                & $setMsg 'Log collector (fb-dump) was not found on this device.' '#FFEF5350'
                if ($collectStatus) { $collectStatus.Text = 'fb-dump was not found on this device.' }
                return
            }
            $script:FbImDumpDest = Get-FbImDumpDestFolder
            if (-not $script:FbImDumpDest) {
                & $setMsg 'Plug in a USB stick, or choose an export folder, then Collect logs again.' '#FFFFB74D'
                if (-not (Show-FbImDumpFolderPicker)) { return }
                $script:FbImDumpDest = Get-FbImDumpDestFolder
                if (-not $script:FbImDumpDest) { return }
                & $setMsg 'Collecting logs. Type notes below.' '#FF22D3EE'
            }
            try {
                if (-not (Test-Path -LiteralPath $script:FbImDumpDest)) {
                    New-Item -ItemType Directory -Path $script:FbImDumpDest -Force -ErrorAction Stop | Out-Null
                }
            } catch {
                & $setMsg 'Could not create the log folder. Choose another export folder or insert a USB stick.' '#FFEF5350'
                return
            }

            try { [void](Copy-FbImOnDeviceLogs -DestFolder $script:FbImDumpDest) } catch {}

            # Keep the notes panel interactive during dump - busy flag only (no full-screen overlay).
            $script:FbImBusy = $true
            $script:FbImNotesIdleArmed = $false
            if ($btnCollectUi) { $btnCollectUi.IsEnabled = $false }
            if ($ui -and $ui.BtnOpenFolder) { $ui.BtnOpenFolder.Visibility = 'Collapsed' }
            if ($ui -and $ui.BtnSaveNotes) { $ui.BtnSaveNotes.Visibility = 'Collapsed' }
            try { if ($script:FbImNotesHideTimer) { $script:FbImNotesHideTimer.Stop() } } catch {}
            if ($script:FbImWriteNotesLive) { & $script:FbImWriteNotesLive }
            if ($collectStatus) {
                $collectStatus.Text = 'Gathering logs... You can keep typing notes.'
            }

            try {
                $script:FbImDumpProc = Start-FbImDumpProcess -DumpScript $dump -DestFolder $script:FbImDumpDest
                if ($script:FbImDumpTimer) { $script:FbImDumpTimer.Start() }
                try { if ($notesBox) { [void]$notesBox.Focus() } } catch {}
            } catch {
                $script:FbImBusy = $false
                if ($busyOverlay) {
                    $busyOverlay.Visibility = 'Collapsed'
                    try { $busyOverlay.IsHitTestVisible = $false } catch {}
                }
                if ($btnCollectUi) { $btnCollectUi.IsEnabled = $true }
                $fallbackCount = 0
                try { $fallbackCount = Copy-FbImDumpExtras -DestFolder $script:FbImDumpDest } catch { $fallbackCount = 0 }
                if ($fallbackCount -le 0) {
                    try { $fallbackCount = Get-FbImDumpFileCount -DestFolder $script:FbImDumpDest } catch { $fallbackCount = 0 }
                }
                if ($fallbackCount -gt 0) {
                    & $setMsg 'Dump helper did not start; on-device logs were still copied to the export folder.' '#FFFFB74D'
                    if ($ui -and $ui.BtnOpenFolder) { $ui.BtnOpenFolder.Visibility = 'Visible' }
                    if ($script:FbImFinishNotesKeepOpen) {
                        & $script:FbImFinishNotesKeepOpen 'On-device logs were copied. Keep typing notes if needed.'
                    }
                } else {
                    & $setMsg ('Could not start log collection: {0}' -f $_.Exception.Message) '#FFEF5350'
                    if ($collectStatus) { $collectStatus.Text = 'Could not start log collection.' }
                }
            }
        } catch {
            try {
                $script:FbImBusy = $false
                $ui2 = $script:FbImUi
                if ($ui2 -and $ui2.BtnCollect) { $ui2.BtnCollect.IsEnabled = $true }
                if ($ui2 -and $ui2.ActionMessage) {
                    $ui2.ActionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $ui2.ActionMessage.Text = ('Collect logs failed: {0}' -f $_.Exception.Message)
                }
            } catch {}
        }
    })
    }

    if ($btnOpenFolder) {
    $btnOpenFolder.Add_Click({
        try {
            if ($script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList $script:FbImDumpDest | Out-Null
            }
        } catch {}
    })
    }

    if ($btnSaveNotes) {
    $btnSaveNotes.Add_Click({
        try {
            $text = [string]$notesBox.Text
            if ([string]::IsNullOrWhiteSpace($text)) {
                $confirm = [System.Windows.MessageBox]::Show(
                    $window,
                    "No notes were entered.`n`nSave with no description?",
                    'No notes entered',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Question
                )
                if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
            }
            $script:FbImNotesIdleArmed = $true
            & $script:FbImFinishNotesKeepOpen 'Notes saved. Keep typing if needed - panel hides after 8s idle.'
        } catch {
            try {
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = ('Save notes failed: {0}' -f $_.Exception.Message)
            } catch {}
        }
    })
    }

    if ($btnShutdown) {
        $btnShutdown.Add_Click({
            try {
                if ($script:FbImBusy) { return }
                if ($script:FbImEmbedHosted -and -not (Test-Path -LiteralPath $SealedMarker)) { return }
                & $showFbImBusy 'Please wait - shutting down...' 'SHUTDOWN'
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
                $actionMessage.Text = 'Please wait - shutting down...'
                $r = Invoke-FbImImmediateShutdown
                if (-not $r.Ok) {
                    & $hideFbImBusy
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Shutdown did not start. {0}' -f $r.Message)
                }
            } catch {
                try {
                    & $hideFbImBusy
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Shutdown failed: {0}' -f $_.Exception.Message)
                } catch {}
            }
        })
    }

    if ($btnPowerRestart) {
        $btnPowerRestart.Add_Click({
            try {
                if ($script:FbImBusy) { return }
                if ($script:FbImEmbedHosted -and -not (Test-Path -LiteralPath $SealedMarker)) { return }
                & $showFbImBusy 'Please wait - restarting...' 'RESTART'
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
                $actionMessage.Text = 'Please wait - restarting...'
                $r = Invoke-FbImImmediateRestart
                if (-not $r.Ok) {
                    & $hideFbImBusy
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Restart did not start. {0}' -f $r.Message)
                }
            } catch {
                try {
                    & $hideFbImBusy
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Restart failed: {0}' -f $_.Exception.Message)
                } catch {}
            }
        })
    }

    if ($btnBios) {
        $btnBios.Add_Click({
            try {
                if ($script:FbImBusy) { return }
                if ($script:FbImEmbedHosted -and -not (Test-Path -LiteralPath $SealedMarker)) { return }
                & $showFbImBusy 'Please wait - restarting to BIOS...' 'BIOS'
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
                $actionMessage.Text = 'Please wait - restarting to firmware...'
                $r = Invoke-FbImImmediateFirmware
                if (-not $r.Ok) {
                    & $hideFbImBusy
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('BIOS restart did not start. {0}' -f $r.Message)
                }
            } catch {
                try {
                    & $hideFbImBusy
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('BIOS restart failed: {0}' -f $_.Exception.Message)
                } catch {}
            }
        })
    }

    if ($btnPassHardware) {
        $btnPassHardware.Add_Click({
            try {
                if ($script:FbImBusy) { return }
                & $showFbImBusy 'Marking hardware check passed...' 'HARDWARE'
                $btnPassHardware.IsEnabled = $false
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
                $actionMessage.Text = 'Marking hardware check passed...'
                try {
                    $r = Invoke-FbImPassHardwareCheck
                    if ($r.Ok) {
                        $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
                    } else {
                        $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    }
                    $actionMessage.Text = ($r.Message + "`n" + $r.Detail).Trim()
                } finally {
                    & $hideFbImBusy
                    [void](& $runStatus)
                }
            } catch {
                try {
                    & $hideFbImBusy
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Hardware pass failed: {0}' -f $_.Exception.Message)
                    [void](& $runStatus)
                } catch {}
            }
        })
    }

    if ($btnSeal) {
    $btnSeal.Add_Click({
        try {
            if ($script:FbImBusy) { return }
            & $showSealPage
        } catch {
            try {
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = ('Seal page failed: {0}' -f $_.Exception.Message)
            } catch {}
        }
    })
    }

    if ($btnSealRestart) {
        $btnSealRestart.Add_Click({
            try { & $runSealWithPower 'Restart' } catch {
                try {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Seal+restart failed: {0}' -f $_.Exception.Message)
                } catch {}
            }
        })
    }
    if ($btnSealShutdown) {
        $btnSealShutdown.Add_Click({
            try { & $runSealWithPower 'Shutdown' } catch {
                try {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Seal+shutdown failed: {0}' -f $_.Exception.Message)
                } catch {}
            }
        })
    }
    if ($btnSealCancel) {
        $btnSealCancel.Add_Click({
            try {
                if ($script:FbImBusy) { return }
                & $hideSealPage
            } catch {}
        })
    }

    if ($btnEmbedBack) {
        # Persist callback on $script: — locals vanish after Show-FbImWindow returns in embed mode,
        # and WPF Click handlers resolve variables at invoke time.
        $script:FbImOnEmbedClose = $OnEmbedClose
        $script:FbImHideBusy = $hideFbImBusy
        $btnEmbedBack.Add_Click({
            try {
                if ($script:FbImHideBusy) { & $script:FbImHideBusy }
                $script:FbImBusy = $false
                if ($script:FbImOnEmbedClose) {
                    & $script:FbImOnEmbedClose
                }
            } catch {
                try { Write-Host ("fb-im embed back failed: {0}" -f $_.Exception.Message) } catch {}
            } finally {
                try {
                    if ($script:FbImEmbedFrame) { $script:FbImEmbedFrame.Continue = $false }
                } catch {}
            }
        })
    } else {
        try { Write-Host 'fb-im: BtnEmbedBack not found — Back to splash tools will not work' } catch {}
    }

    $startUi = {
        $afterOpen = $null
        if ($FocusAction -eq 'Updates' -or $FocusAction -eq 'Dump') {
            $afterOpen = {
                if ($FocusAction -eq 'Updates' -and $btnRestart) {
                    $btnRestart.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
                } elseif ($FocusAction -eq 'Dump' -and $btnCollect) {
                    $btnCollect.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
                }
            }
        }
        [void](& $runStatus $afterOpen)
    }

    if ($EmbedHost) {
        try { & $startUi } catch {
            try { Write-Host ("fb-im embed start failed: {0}" -f $_.Exception.Message) } catch {}
        }
        # Nested dispatcher frame keeps this function on the stack so other Click
        # handlers (Restart, Seal, Check again) can still see their locals - the
        # same reason Collect used to be a silent no-op after an immediate return.
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $script:FbImEmbedFrame = $frame
        try {
            [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        } finally {
            $script:FbImEmbedFrame = $null
        }
        return
    }

    try { $window.Topmost = $true } catch {}
    $window.Add_ContentRendered({
        try { & $startUi } catch {
            try { Write-Host ("fb-im ContentRendered failed: {0}" -f $_.Exception.Message) } catch {}
        }
    })
    [void]$window.ShowDialog()
}

# =============================================================================
# ENTRY
# =============================================================================
if (-not $Library) {
    $focus = switch ($Action) {
        'Status'  { 'Status' }
        'Updates' { 'Updates' }
        'Dump'    { 'Dump' }
        default   { 'Menu' }
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        Initialize-FbImWpf
        Show-FbImWindow -FocusAction $focus
    } catch {
        $failMsg = $_.Exception.Message
        $shown = $false
        try {
            Initialize-FbImWpf
            [void][System.Windows.MessageBox]::Show(
                ('fb-im failed to open.' + [Environment]::NewLine + $failMsg),
                'Project LoneWolf',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
            $shown = $true
        } catch {}
        if (-not $shown) {
            Write-Host ''
            Write-Host '  fb-im failed to open.' -ForegroundColor Red
            Write-Host ("  {0}" -f $failMsg) -ForegroundColor Yellow
            Write-Host ''
            Write-Host '  Press Enter to close.' -ForegroundColor DarkGray
            try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 15 }
        }
        $ErrorActionPreference = $prevEap
        exit 1
    }
    $ErrorActionPreference = $prevEap
}
