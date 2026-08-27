#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Project LoneWolf Launcher  -  Headless USB Build Wrapper
  Streams JSON events to stdout for Electron IPC consumption.

.DESCRIPTION
  Called by main.js via spawn. Accepts parameters instead of interactive prompts.
  All progress communication is JSON lines to stdout. No Write-Host.

  Build source priority (automatically selected):
    1. Pre-staged WIM  (Staging\Windows * (arch).wim)   -  fastest
    2. ISO direct mode (Staging\Windows * (arch).iso)   -  slower, no pre-staging needed
    Exception: -NoPayload (WIN-INSTALL) prefers ISO when one exists, even if a staged WIM is present.
    Run Update-Staging.ps1 to convert an ISO to a pre-staged WIM.

.PARAMETER WorkflowType
  'AMD64' or 'ARM64'

.PARAMETER NoPayload
  Build a minimal WIN-INSTALL USB: no WUPayload, no FirstBase post-install scripts.
  Uses the same TechInstall architecture as a full build (Architecture B):
  startnet -> wpeinit -> WinPE-Startnet.cmd -> TechInstall-Install.cmd -> disksetup.cmd + DISM apply + bcdboot.
  The overlay contains Autounattend.xml (offline unattend only) plus Deploy\TechInstall.cmd,
  Deploy\WinPE-Startnet.cmd, and Deploy\disksetup.cmd.
  After install the machine shuts down instead of rebooting to run update scripts.

.PARAMETER QuickInstall
  Build a minimal "quick and easy" WIN install USB, SEPARATE from -NoPayload.
  Reuses the same Architecture B mechanics (ISO source, disksetup partition, DISM
  apply, bcdboot, firmware handoff, shutdown) but stages only the gutted deploy set:
  Deploy\TechInstall-QuickInstall.cmd (renamed to Deploy\TechInstall.cmd) plus the
  offline Policy\autounattend-quickinstall.xml. The install is fully unattended (no
  Windows Setup menus) and lands at a clean Windows OOBE. No FirstBase payload and
  none of the on-boot prereqs (SetupComplete, RunOnce, tasks, update loop, seal).

.PARAMETER DiskNumbers
  Comma-separated list of disk numbers to write (e.g. "1,3").
  Pass "0" with -PreCacheOnly to skip disk selection.

.PARAMETER ShareRoot
  UNC path to the share root.

.PARAMETER ShareUser / SharePassword
  Share credentials (embedded defaults match Build-UsbStick-Remote.ps1).

.PARAMETER CacheRoot
  Optional local folder for the ESP template cache used ONLY by non-ISO (staged-WIM /
  MEDIA-CREATOR) builds that inject boot.wim once into a local EspCache before copying
  to USB. Defaults to %TEMP%\LWCache_<guid> when that path is needed. ISO / PreferIso /
  OverlayOnly builds do NOT use CacheRoot — USB-bound content is copied directly to the
  stick (ISO→ESP, ISO→data, ContentRoot→overlay). User-provided CacheRoot is ignored
  on PreferIso/ISO paths.

.PARAMETER PreCacheOnly
  Build the local ESP cache then exit without writing any USB.

.PARAMETER DataVolumeLabel
  USB data-partition volume label. Defaults to 'LoneWolf' (<=11 chars, FAT32-legal so
  the Single and Split layouts share ONE label). FAT32 stores labels uppercase, so it
  reads back as 'LONEWOLF' - all detection is case-insensitive. Legacy sticks labelled
  'Project LoneWolf' or 'WINSETUP' are still detected for overlay-only updates.

.PARAMETER OverlayOnly
  Skip disk wipe, partition, and DISM steps entirely.
  Only copy the deploy overlay onto the existing data (NTFS) partition.
  Safe when the disk already has a valid data partition from a previous full build.
  Emits phase "overlay-update" instead of "partitioning"/"esp-copy"/"dism".

.PARAMETER Sequential
  Process one disk at a time instead of launching all jobs in parallel.
  Each disk's Start-Job (full pipeline: wipe through WinPE/BCD/done) is fully
  drained and removed before the next disk starts.
  Opt-in only — pass this switch explicitly to force sequential builds (e.g. for debugging).
  Release builds run each disk end-to-end in parallel by default.

.OUTPUTS
  JSON lines to stdout only. Examples:
    {"event":"start","disk":1,"workflow":"AMD64"}
    {"event":"iso-mode","disk":0,"isoFile":"Windows 25H2 (AMD64).iso","message":"No pre-staged WIM found  -  mounting ISO directly"}
    {"event":"phase","disk":1,"phase":"partitioning"}
    {"event":"phase","disk":1,"phase":"esp-copy"}
    {"event":"phase","disk":1,"phase":"data-copy"}            <- ISO mode only (robocopy)
    {"event":"progress","disk":1,"phase":"data-copy","pct":0}
    {"event":"phase","disk":1,"phase":"dism"}                 <- WIM mode only (mount + robocopy)
    {"event":"progress","disk":1,"phase":"dism","pct":45}
    {"event":"phase","disk":1,"phase":"overlay"}
    {"event":"done","disk":1,"success":true}
    {"event":"error","disk":1,"message":"failed: ..."}
    {"event":"summary","succeeded":[1,3],"failed":[2]}
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $WorkflowType,
    [Parameter(Mandatory)] [string]   $DiskNumbers,
    [string] $ShareRoot        = '\\WIN-HQ5JDEACV3S\Images\FB Image Creation',
    [string] $ShareUser        = 'Reflect',
    [string] $SharePassword    = 'mer*HWE0upt*rqe@dud',
    [string] $CacheRoot,
    [string] $DataVolumeLabel  = 'LoneWolf',
    [string] $AppResourcesPath = '',
    [string] $LocalProjectRoot = '',   # When non-empty: skip share auth and use this local path as ProjectRoot
    # WinPE optional-component cabs source. Defaults to the share (NOT a local ADK install).
    # LoneWolf builds pull WinPE-WMI/NetFx/Scripting/PowerShell (+ their _en-us cabs) from here.
    [string] $WpeOcRoot = '\\WIN-HQ5JDEACV3S\Images\FB Image Creation\Remote\Staging\WinPE-OCs',
    [switch] $PreCacheOnly,
    [switch] $OverlayOnly,
    [switch] $ForceIsoMode,
    # LoneWolf flow: always pull + mount the NEWEST *(arch)*.iso from the share ISO folder
    # and build from the mounted drive (Architecture B), ignoring any pre-staged WIM.
    # Set by main.js for the LoneWolf workflow. Fails loudly if no matching ISO is present.
    [switch] $PreferIso,
    [switch] $Sequential,
    [switch] $NoPayload,
    # Quick-and-easy payload-free Windows install: same proven ISO/partition/DISM/bcdboot
    # mechanics as -NoPayload, but stages the minimal QUICK-INSTALL deploy set
    # (Deploy\TechInstall-QuickInstall.cmd + Policy\autounattend-quickinstall.xml). No
    # FirstBase payload, no SetupComplete arming, no update loop, no seal/sysprep, no reaper.
    # Kept independent from -NoPayload so the WIN-INSTALL path is never affected.
    [switch] $QuickInstall,
    # Cleanup-only mode: dismount any share ISO left mounted by a prior cancelled/crashed
    # build (per the mounted-ISO marker), then exit. Invoked by main.js on build:cancel.
    # No disk/share work is performed.
    [switch] $DismountOnly,
    # USB partition layout:
    #   Single (DEFAULT for LoneWolf) - ONE FAT32 Microsoft Basic Data partition
    #     (GPT type {ebd0a0a2-...}, NOT an ESP GUID). Boot files + install media share
    #     the one volume; install.wim is split into install.swm for the FAT32 4 GB limit.
    #     Because the USB has no ESP-GUID partition, only the internal disk's ESP exists
    #     at force-boot time so bcdedit {fwbootmgr} disambiguates cleanly (fixes the
    #     "multiple indistinguishable devices" force-boot failure).
    #   Split - legacy FAT32 ESP ({c12a7328-...}) + NTFS data. Kept as a fallback for
    #     firmware that refuses to boot a non-ESP-GUID removable volume.
    [ValidateSet('Single','Split')]
    [string] $Layout = 'Single',
    # Pre-split fast-copy: deep-verify staged .swm chunks by sha256 (default OFF).
    # Off = size-only integrity check per build (cheap). sha256 of multi-GB chunks on
    # every build is not worth the cost; the producer records hashes for a deep audit.
    [switch] $VerifyPreSplitHash,
    # Dev build: launcher version is ahead of share official (or unpackaged fallback).
    # Stamps LW_VERSION.json + WUPayload\.dev-build so stick cards and on-device splash show DEV.
    [switch] $DevBuild,
    [string] $LauncherVersion = '',
    [string] $ScriptVersion = '',
    [string] $ShareLauncherVersion = '',
    [string] $ShareScriptVersion = ''
)

$ErrorActionPreference = 'Stop'

# --- JSON event emitter -------------------------------------------------------
function Emit {
    param([hashtable]$Data)
    # Write DIRECTLY to the process stdout instead of the PowerShell success stream.
    # Critical: if this used Write-Output, every Emit call inside a function whose return
    # value is captured (e.g. Get-LWPreSplitSet) would leak the JSON event into that return
    # value - which silently corrupted $PreSplitSetDir and disabled the pre-split fast path.
    # [Console]::Out reaches the same stdout main.js parses, but never enters the pipeline.
    [Console]::Out.WriteLine(($Data | ConvertTo-Json -Compress -Depth 3))
}

function EmitPhase   { param([int]$Disk, [string]$Phase) Emit @{ event='phase'; disk=$Disk; phase=$Phase } }
function EmitStart   { param([int]$Disk) Emit @{ event='start'; disk=$Disk; workflow=$WorkflowType } }
function EmitDone    { param([int]$Disk, [bool]$Success, [string]$Msg)
    $d = @{ event='done'; disk=$Disk; success=$Success }
    if ($Msg) { $d['message'] = $Msg }
    Emit $d
}
function EmitError   { param([int]$Disk, [string]$Msg) Emit @{ event='error'; disk=$Disk; message=$Msg } }
function EmitProgress{ param([int]$Disk, [string]$Phase, [int]$Pct) Emit @{ event='progress'; disk=$Disk; phase=$Phase; pct=$Pct } }
function EmitSummary { param([int[]]$Succeeded, [int[]]$Failed) Emit @{ event='summary'; succeeded=@($Succeeded); failed=@($Failed) } }
function EmitLog     { param([int]$Disk, [string]$Msg) Emit @{ event='log'; disk=$Disk; message=$Msg } }

# --- Mounted-ISO marker + self-healing sweep ----------------------------------
# The share ISO is mounted once per build (Mount-DiskImage) and dismounted in the
# finally. That covers thrown errors and `exit 1`, but NOT a hard-kill (build:cancel ->
# killAllBuildProcesses) or a crash. To make dismount reliable across those cases we
# record each mounted ISO path in a marker file; a startup sweep (and the -DismountOnly
# cancel hook from main.js) dismounts anything the previous run left behind.
$script:LwMountMarker = 'C:\ProgramData\LoneWolf\mounted-isos.txt'

function Add-LwMountedIso {
    param([string]$Path)
    try {
        $dir = Split-Path -Parent $script:LwMountMarker
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $script:LwMountMarker -Value $Path -Encoding UTF8
    } catch { }
}

function Remove-LwMountedIso {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $script:LwMountMarker)) { return }
        $remaining = @(Get-Content -LiteralPath $script:LwMountMarker -ErrorAction SilentlyContinue |
            Where-Object { $_ -and ($_.Trim() -ne $Path) })
        if ($remaining.Count -gt 0) {
            Set-Content -LiteralPath $script:LwMountMarker -Value $remaining -Encoding UTF8
        } else {
            Remove-Item -LiteralPath $script:LwMountMarker -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

# Dismount every ISO recorded in the marker that is still attached, then clear it.
# Safe to run before this build mounts its own ISO (the new mount is recorded afterward).
function Invoke-LwIsoSweep {
    try {
        if (-not (Test-Path -LiteralPath $script:LwMountMarker)) { return }
        $recorded = @(Get-Content -LiteralPath $script:LwMountMarker -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        foreach ($p in $recorded) {
            try {
                $img = Get-DiskImage -ImagePath $p -ErrorAction SilentlyContinue
                if ($img -and $img.Attached) {
                    Dismount-DiskImage -ImagePath $p -ErrorAction SilentlyContinue | Out-Null
                    EmitLog -Disk 0 -Msg "iso-sweep: dismounted stale ISO from prior run: $p"
                }
            } catch { }
        }
        Remove-Item -LiteralPath $script:LwMountMarker -Force -ErrorAction SilentlyContinue
    } catch { }
}

# --- Orphan %TEMP% litter sweep (crashed / hard-killed builds) ----------------
# Best-effort: unmount any leftover DISM mount dirs then delete matching folders/logs.
# Safe to run at start, end, and on -DismountOnly (cancel). Never throws.
# -IncludeCache also removes LWCache_* (use at end / cancel — NOT at build-start, so a
# user-provided persistent EspCache under %TEMP% is not wiped before a WIM-mode build).
function Invoke-LwTempOrphanSweep {
    param(
        [string]$Reason = 'orphan-sweep',
        [switch]$IncludeCache
    )
    try {
        $tempRoot = $env:TEMP
        if ([string]::IsNullOrWhiteSpace($tempRoot) -or -not (Test-Path -LiteralPath $tempRoot)) { return }

        $dirPatterns = @('LWMount_*', 'LWPEMount_*', 'LW-WimWork-*', 'LW-WimShared-*')
        if ($IncludeCache) { $dirPatterns = @('LWCache_*') + $dirPatterns }

        foreach ($pat in $dirPatterns) {
            Get-ChildItem -LiteralPath $tempRoot -Directory -Filter $pat -ErrorAction SilentlyContinue | ForEach-Object {
                $dir = $_.FullName
                try {
                    # If this looks like an active/stale DISM mount, discard before delete.
                    $mountProbe = Join-Path $dir 'Windows'
                    $isMountish = (Test-Path -LiteralPath $mountProbe) -or ($_.Name -like 'LWMount_*') -or ($_.Name -like 'LWPEMount_*') -or ($_.Name -like 'LW-Wim*')
                    if ($isMountish) {
                        & dism.exe /Unmount-Image /MountDir:"$dir" /Discard 2>&1 | Out-Null
                        $nestedMount = Join-Path $dir 'mount'
                        if (Test-Path -LiteralPath $nestedMount) {
                            & dism.exe /Unmount-Image /MountDir:"$nestedMount" /Discard 2>&1 | Out-Null
                        }
                    }
                } catch { }
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Get-ChildItem -LiteralPath $tempRoot -File -Filter 'LW-robocopy-disk*.log' -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        EmitLog -Disk 0 -Msg "temp-sweep ($Reason): cleaned leftover mount/work/robocopy litter under $tempRoot"
    } catch { }
}

# --- Cleanup-only mode (build:cancel hook) ------------------------------------
# Runs the marker-based ISO sweep + temp orphan sweep and exits without touching disks.
if ($DismountOnly) {
    Invoke-LwIsoSweep
    Invoke-LwTempOrphanSweep -Reason 'dismount-only' -IncludeCache
    exit 0
}

# Startup sweep: prior cancelled/crashed builds may have left mount dirs in %TEMP%.
# Does not touch LWCache_* (may be a deliberate persistent EspCache for WIM builds).
Invoke-LwTempOrphanSweep -Reason 'build-start'

# --- Parse DiskNumbers arg ----------------------------------------------------
$requestedDisks = @($DiskNumbers -split '[,\s]+' |
    Where-Object { $_ -match '^\d+$' } |
    ForEach-Object { [int]$_ } |
    Select-Object -Unique)

# --- Paths --------------------------------------------------------------------
$wfUpper = $WorkflowType.ToUpper()   # AMD64 or ARM64

if (-not [string]::IsNullOrWhiteSpace($LocalProjectRoot)) {
    $ProjectRoot = $LocalProjectRoot
} else {
    $ProjectRoot = Join-Path $ShareRoot 'Remote'
}
$StagingRoot = Join-Path $ProjectRoot 'Staging'

# Deploy overlay root  -  prefer payload bundled inside the .exe (AppResourcesPath\payload),
# fall back to Staging\Payload on the share when the bundled path is absent.
$bundledPayload = if ($AppResourcesPath) { Join-Path $AppResourcesPath 'payload' } else { '' }
$ContentRoot = if ($bundledPayload -and (Test-Path -LiteralPath $bundledPayload)) {
    $bundledPayload
} else {
    Join-Path $StagingRoot 'Payload'
}

# Refuse to build an Updates stick from a truncated/corrupt loop script.
# Field (52R7X84-0854/0855): packaged 5.3.10 extraResources payload ended mid-function
# (`if ($stage1InlineConverged) {`) so powershell -File exited 1 with no WU-*.log and
# the splash sat on "Checking for updates". Dev sticks (src/payload) were complete.
function Test-LwUpdateLoopPayload {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "FATAL: Invoke-WindowsUpdateLoop.ps1 missing at '$Path'. Cannot build an Updates stick."
    }
    $len = [int64]0
    try { $len = [int64](Get-Item -LiteralPath $Path).Length } catch { $len = [int64]0 }
    # Known truncated extraResources copy is 753480 bytes and ends mid-function.
    if ($len -lt 900000) {
        throw ("FATAL: Invoke-WindowsUpdateLoop.ps1 is truncated ({0} bytes, need >= 900000). Refusing to ship. File: '{1}'." -f $len, $Path)
    }
    $errs = $null
    $toks = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$toks, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        $first = $errs[0]
        $line = 0
        try { $line = [int]$first.Extent.StartLineNumber } catch {}
        throw ("FATAL: Invoke-WindowsUpdateLoop.ps1 does not parse ({0} error(s); first L{1}: {2}). File is truncated or corrupt: '{3}'." -f $errs.Count, $line, $first.Message, $Path)
    }
    $tail = ''
    try { $tail = (Get-Content -LiteralPath $Path -Tail 8 -ErrorAction Stop | Out-String) } catch {}
    if ($tail -notmatch 'Complete-And-Exit') {
        throw "FATAL: Invoke-WindowsUpdateLoop.ps1 is truncated (missing Complete-And-Exit trailer): '$Path'."
    }
    if ($tail -notmatch 'FIRSTBASE-LOOP-EOF-OK') {
        throw "FATAL: Invoke-WindowsUpdateLoop.ps1 is truncated (missing FIRSTBASE-LOOP-EOF-OK marker): '$Path'."
    }
}
function Assert-LwUpdateLoopCopy {
    param([Parameter(Mandatory)][string]$Src, [Parameter(Mandatory)][string]$Dst)
    if (-not (Test-Path -LiteralPath $Dst)) {
        throw "FATAL: Invoke-WindowsUpdateLoop.ps1 missing after copy: '$Dst'"
    }
    $srcLen = [int64](Get-Item -LiteralPath $Src).Length
    $dstLen = [int64](Get-Item -LiteralPath $Dst).Length
    if ($srcLen -ne $dstLen) {
        throw ("FATAL: Invoke-WindowsUpdateLoop.ps1 truncated during copy ({0} -> {1} bytes): '{2}'." -f $srcLen, $dstLen, $Dst)
    }
    Test-LwUpdateLoopPayload -Path $Dst
}
if (-not $NoPayload -and -not $QuickInstall) {
    Test-LwUpdateLoopPayload -Path (Join-Path $ContentRoot 'Invoke-WindowsUpdateLoop.ps1')
    EmitLog -Disk 0 -Msg "payload: update-loop script parse+trailer OK ($ContentRoot)"
}

# New fixed-path layout: Staging\AMD64\ and Staging\AMD64\AMD64.wim
$ArchRoot    = Join-Path $StagingRoot $wfUpper          # e.g. Staging\AMD64
$StagingWim  = Join-Path $ArchRoot    "$wfUpper.wim"    # e.g. Staging\AMD64\AMD64.wim
$IsoRoot     = Join-Path $StagingRoot 'ISO'             # e.g. Staging\ISO
$PreSplitRoot = Join-Path $StagingRoot 'PreSplit'       # e.g. Staging\PreSplit  (\<ARCH>\<imageVersion>\)

# Shared split-helper lib. Dot-sourced on the MAIN thread here (for Get-LWImageVersionId
# + Test-LWPreSplitSet used by Get-LWPreSplitSet below), and its full path is ALSO passed
# into each per-disk Start-Job so the worker runspace can dot-source Split-LWImageForFat32
# (a job runspace cannot see script-scope functions of the parent).
$SplitLibPath = Join-Path $PSScriptRoot 'lib\Split-LWImage.ps1'
if (Test-Path -LiteralPath $SplitLibPath) { . $SplitLibPath }

# WinPE OC source: pull from the share by default (-WpeOcRoot). In LocalProjectRoot
# (dev) mode, prefer a local Staging\WinPE-OCs when one is present so offline dev
# builds still work; otherwise fall back to the share path.
$WpeOcSource = if (-not [string]::IsNullOrWhiteSpace($LocalProjectRoot) -and
                   (Test-Path -LiteralPath (Join-Path $StagingRoot 'WinPE-OCs'))) {
    Join-Path $StagingRoot 'WinPE-OCs'
} elseif (-not [string]::IsNullOrWhiteSpace($WpeOcRoot)) {
    $WpeOcRoot
} else {
    Join-Path $StagingRoot 'WinPE-OCs'
}

# The WinPE-OCs share was restructured into per-architecture subfolders
# (WinPE-OCs\AMD64\, WinPE-OCs\ARM64\) instead of a flat cab dump. Resolve the
# arch subfolder for the current build. Prefer <root>\<ARCH>; fall back to the
# flat <root> only when the arch subfolder is absent but the flat root still
# holds the base PowerShell cab (legacy layout / offline dev). When neither the
# arch subfolder nor a legacy flat set is present, return the arch subfolder
# path so the downstream required-cab guard fails loudly naming that exact path.
function Resolve-WpeOcArchRoot {
    param([string]$BaseRoot, [string]$Arch)

    if ([string]::IsNullOrWhiteSpace($BaseRoot) -or [string]::IsNullOrWhiteSpace($Arch)) { return $BaseRoot }
    $archRoot = Join-Path $BaseRoot $Arch
    if (Test-Path -LiteralPath $archRoot) { return $archRoot }
    # Backward-compat: keep using the flat root if it still carries the base cabs.
    if (Test-Path -LiteralPath (Join-Path $BaseRoot 'WinPE-PowerShell.cab')) { return $BaseRoot }
    return $archRoot
}

# --- Pre-split fast-copy set detection (main thread) --------------------------
# Does a VALID, matching pre-split install*.swm set exist for the ISO this build is
# about to use? Runs once on the main thread (before the per-disk jobs launch); the
# resolved set dir (or '') is passed into every job so each USB robocopies the staged
# .swm instead of running dism /Split-Image. Returns the set dir on a match, else $null.
# A miss/mismatch/corruption is NEVER fatal - the caller passes '' and the worker falls
# back to the on-the-fly split (behaviour identical to before this feature).
function Get-LWPreSplitSet {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo] $Iso,
        [Parameter(Mandatory)] [string] $PreSplitRoot,
        [Parameter(Mandatory)] [string] $Arch,
        [switch] $VerifyHash
    )
    try {
        if (-not (Get-Command -Name Get-LWImageVersionId -ErrorAction SilentlyContinue) -or
            -not (Get-Command -Name Test-LWPreSplitSet -ErrorAction SilentlyContinue)) {
            EmitLog -Disk 0 -Msg 'presplit: shared split lib not loaded - skipping fast path, using on-the-fly split'
            return $null
        }
        $archDir = Join-Path $PreSplitRoot $Arch
        if (-not (Test-Path -LiteralPath $archDir)) {
            EmitLog -Disk 0 -Msg "presplit: no staged sets folder for $Arch at '$archDir' - on-the-fly split will be used"
            return $null
        }
        $currentId = Get-LWImageVersionId -Iso $Iso

        # Candidate order: the 'current' marker's set first, then every <imageVersion>
        # subfolder newest-first. First candidate that validates AND matches the ISO wins.
        $candidates = New-Object System.Collections.Generic.List[string]
        $marker = Join-Path $archDir 'current'
        if (Test-Path -LiteralPath $marker) {
            try {
                $mk = Get-Content -Raw -LiteralPath $marker -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($mk.imageVersion) {
                    $cand = Join-Path $archDir ([string]$mk.imageVersion)
                    if (Test-Path -LiteralPath $cand) { $candidates.Add($cand) }
                }
            } catch {
                EmitLog -Disk 0 -Msg "presplit: 'current' marker unreadable ($($_.Exception.Message)) - scanning set folders instead"
            }
        }
        foreach ($d in @(Get-ChildItem -LiteralPath $archDir -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)) {
            if ($d.Name -like '*.tmp-*') { continue }
            if (-not ($candidates -contains $d.FullName)) { $candidates.Add($d.FullName) }
        }
        if ($candidates.Count -eq 0) {
            EmitLog -Disk 0 -Msg "presplit: no staged set folders under '$archDir' - on-the-fly split will be used"
            return $null
        }

        foreach ($setDir in $candidates) {
            $chk = Test-LWPreSplitSet -SetDir $setDir -VerifyHash:$VerifyHash
            if (-not $chk.Valid) {
                EmitLog -Disk 0 -Msg "presplit: set '$setDir' rejected ($($chk.Reason))"
                continue
            }
            $m   = $chk.Manifest
            $src = $m.source
            $reasons = @()
            if ([string]$src.isoName -ne $Iso.Name) {
                $reasons += "isoName '$([string]$src.isoName)' != '$($Iso.Name)'"
            }
            if ([long]$src.isoSizeBytes -ne [long]$Iso.Length) {
                $reasons += "isoSizeBytes $([long]$src.isoSizeBytes) != $([long]$Iso.Length)"
            }
            $mDate = $null
            try {
                $mDate = [datetime]::Parse([string]$src.isoLastWriteUtc, $null,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
            } catch { }
            if ($mDate) {
                $delta = [math]::Abs(($mDate.ToUniversalTime() - $Iso.LastWriteTimeUtc).TotalSeconds)
                if ($delta -gt 2) {
                    $reasons += "isoLastWriteUtc '$([string]$src.isoLastWriteUtc)' != '$($Iso.LastWriteTimeUtc.ToString('o'))'"
                }
            } else {
                $reasons += "isoLastWriteUtc unparseable '$([string]$src.isoLastWriteUtc)'"
            }
            # imageVersion encapsulates name-slug + last-write stamp: a strong secondary guard.
            if ([string]$m.imageVersion -ne $currentId) {
                $reasons += "imageVersion '$([string]$m.imageVersion)' != '$currentId'"
            }
            if ($reasons.Count -gt 0) {
                EmitLog -Disk 0 -Msg "presplit: set '$setDir' does not match current ISO - $([string]::Join('; ', $reasons))"
                continue
            }
            # isoTitleDate is a secondary/informational check only (never fails a match).
            EmitLog -Disk 0 -Msg "presplit: MATCH - staged set '$setDir' (imageVersion=$currentId); builds will fast-copy install*.swm and skip the on-the-fly split"
            return $setDir
        }
        EmitLog -Disk 0 -Msg "presplit: no staged set matched the current ISO '$($Iso.Name)' - falling back to on-the-fly split"
        return $null
    } catch {
        EmitLog -Disk 0 -Msg "presplit: detection error ($($_.Exception.Message)) - falling back to on-the-fly split"
        return $null
    }
}

# CacheRoot / EspCache is allocated ONLY for non-ISO staged-WIM builds (see ensure block
# after ISO detection). ISO / PreferIso / OverlayOnly copy USB-bound content directly to
# the stick — no local LWCache overlay or ESP staging. PreferIso ignores a user-provided
# -CacheRoot so a persistent EspCache folder cannot accidentally suppress per-disk inject.
$userProvidedCache = (-not [string]::IsNullOrWhiteSpace($CacheRoot))
if ($PreferIso) {
    $CacheRoot = ''
    $userProvidedCache = $false
}
$espCache     = ''
$overlayCache = ''

# --- Share authentication -----------------------------------------------------
function Connect-Share {
    param([string]$ShareHost, [string]$User, [string]$Pass, [string]$ProbePath)

    $cmdkey = Join-Path $env:SystemRoot 'System32\cmdkey.exe'
    if (Test-Path -LiteralPath $cmdkey) {
        & $cmdkey /delete:$ShareHost 2>$null | Out-Null
        & $cmdkey /add:$ShareHost /user:$User /pass:$Pass 2>&1 | Out-Null
    }
    try { $null = & net use "\\$ShareHost\IPC$" /delete 2>$null } catch { }

    if (Test-Path -LiteralPath $ProbePath) { return }

    # Fallback: PSDrive
    try {
        $sec  = ConvertTo-SecureString $Pass -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
        $letter = ('Z','Y','X','W','V','U','T','S' | Where-Object {
            -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue)
        } | Select-Object -First 1)
        if ($letter) {
            New-PSDrive -Name $letter -PSProvider FileSystem -Root "\\$ShareHost" `
                -Credential $cred -Scope Global -ErrorAction Stop | Out-Null
        }
    } catch { }
}

# Stage Cascadia Mono into the USB overlay (and optionally boot.wim Fonts).
# WinPE raster OEM cannot draw U+28xx; AddFontResourceEx at deploy UI time
# loads this TTF. Does not rebuild the share WIM.
function Copy-LwPeBrailleFont {
    param(
        [string]$OverlayRoot = '',
        [string]$WimFontsDir = ''
    )
    $srcList = New-Object System.Collections.Generic.List[string]
    if ($ContentRoot) {
        [void]$srcList.Add((Join-Path $ContentRoot 'Deploy\Fonts\cascadiamono.ttf'))
    }
    if ($env:WINDIR) {
        foreach ($n in @('cascadiamono.ttf', 'CascadiaMono.ttf', 'CascadiaMonoPL.ttf')) {
            [void]$srcList.Add((Join-Path $env:WINDIR ('Fonts\' + $n)))
        }
    }
    $src = $null
    foreach ($c in $srcList) {
        if ($c -and (Test-Path -LiteralPath $c)) { $src = $c; break }
    }
    if (-not $src) {
        EmitLog -Disk 0 -Msg 'WinPE Braille font: cascadiamono.ttf not found in payload Deploy\Fonts or Windows\Fonts (wolf may show as ?)'
        return
    }
    if ($OverlayRoot) {
        $dstDir = Join-Path $OverlayRoot 'FirstBase\Deploy\Fonts'
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        Copy-Item -LiteralPath $src -Destination (Join-Path $dstDir 'cascadiamono.ttf') -Force
        EmitLog -Disk 0 -Msg ("WinPE Braille font staged to overlay: {0}" -f (Join-Path $dstDir 'cascadiamono.ttf'))
    }
    if ($WimFontsDir) {
        New-Item -ItemType Directory -Force -Path $WimFontsDir | Out-Null
        Copy-Item -LiteralPath $src -Destination (Join-Path $WimFontsDir 'cascadiamono.ttf') -Force
        EmitLog -Disk 0 -Msg ("WinPE Braille font staged into boot.wim Fonts: {0}" -f (Join-Path $WimFontsDir 'cascadiamono.ttf'))
    }
}

# --- Build ESP + overlay local cache -----------------------------------------
function Build-Cache {
    param([string]$StagingWindowsDir, [string]$StagingWim)

    New-Item -ItemType Directory -Force -Path $espCache, $overlayCache | Out-Null

    # ESP: copy all staging content except sources\install.* and staged *.wim/*.esd/*.swm files
    # (The arch WIM e.g. AMD64.wim lives alongside the ISO files; exclude it from the ESP copy.)
    EmitProgress -Disk 0 -Phase 'esp-copy' -Pct 0
    $items = Get-ChildItem -LiteralPath $StagingWindowsDir -Force -ErrorAction SilentlyContinue |
        Where-Object { -not (-not $_.PSIsContainer -and $_.Name -match '\.(wim|esd|swm)$') }
    $total = @($items).Count; $i = 0
    foreach ($item in $items) {
        $i++
        $pct = [math]::Min(95, [math]::Round($i / [math]::Max($total,1) * 100))
        EmitProgress -Disk 0 -Phase 'esp-copy' -Pct $pct

        if ($item.PSIsContainer -and $item.Name -ieq 'sources') {
            $dstSrc = Join-Path $espCache 'sources'
            New-Item -ItemType Directory -Force -Path $dstSrc | Out-Null
            # ESP only needs boot.wim (WinPE boot image) and *.sdi from sources/.
            # Skip all subdirectories (sxs/, en-us/, migration/, etc.) and the hundreds of
            # setup DLLs - those belong on the data partition, not the FAT32 ESP.
            foreach ($child in (Get-ChildItem -LiteralPath $item.FullName -File -Force -ErrorAction SilentlyContinue)) {
                if ($child.Name -ieq 'boot.wim' -or $child.Name -match '\.sdi$') {
                    Copy-Item -LiteralPath $child.FullName -Destination $dstSrc -Force -ErrorAction SilentlyContinue
                }
            }
        } elseif ($item.PSIsContainer) {
            Copy-Item -LiteralPath $item.FullName -Destination $espCache -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $espCache -Force -ErrorAction SilentlyContinue
        }
    }

    # Copy pre-injection sentinel alongside boot.wim so the runtime skip-check works.
    # Written by _inject-boot-wim.ps1; contains the SHA256 hash of WinPE-Startnet.cmd.
    #
    # Always delete any existing ESP cache sentinel first: boot.wim was just replaced with
    # a fresh copy from staging whose preserved timestamp may be OLDER than a previous
    # injection sentinel, fooling the age check into skipping injection on a stock boot.wim.
    $sentinelSrc = Join-Path $StagingWindowsDir 'sources\boot.wim.lw-injected'
    $sentinelDst = Join-Path $espCache           'sources\boot.wim.lw-injected'
    $espBootWim  = Join-Path $espCache           'sources\boot.wim'
    Remove-Item -LiteralPath $sentinelDst -Force -ErrorAction SilentlyContinue
    # Only restore the sentinel when the staging copy is newer than the staging boot.wim,
    # which proves the staging boot.wim itself is the pre-injected version.
    if ((Test-Path -LiteralPath $sentinelSrc) -and (Test-Path -LiteralPath $espBootWim)) {
        if ((Get-Item -LiteralPath $sentinelSrc).LastWriteTime -ge (Get-Item -LiteralPath $espBootWim).LastWriteTime) {
            Copy-Item -LiteralPath $sentinelSrc -Destination $sentinelDst -Force -ErrorAction SilentlyContinue
        }
    }

    # Ensure efi\microsoft\boot\bootmgfw.efi exists on the ESP cache.
    # Some custom ISOs only ship efi\boot\bootx64.efi (same binary, different path).
    # The ISO-sourced BCD uses a `locate` device anchored to \EFI\Microsoft\Boot\bootmgfw.efi
    # to establish the Boot Manager's home partition context.  If that file is absent the
    # locate fails, the ramdisk device for \sources\boot.wim cannot be resolved, and the
    # system shows the 0xc0000098 (STATUS_NO_SUCH_FILE) recovery screen.
    $bootmgfwDst = Join-Path $espCache 'efi\microsoft\boot\bootmgfw.efi'
    if (-not (Test-Path -LiteralPath $bootmgfwDst)) {
        $bootmgfwSrc = Join-Path $espCache 'efi\boot\bootx64.efi'
        if (Test-Path -LiteralPath $bootmgfwSrc) {
            New-Item -ItemType Directory -Force -Path (Split-Path $bootmgfwDst -Parent) -ErrorAction SilentlyContinue | Out-Null
            Copy-Item -LiteralPath $bootmgfwSrc -Destination $bootmgfwDst -Force
            EmitLog -Disk 0 -Msg 'esp-cache: synthesised efi\microsoft\boot\bootmgfw.efi from efi\boot\bootx64.efi (ISO omitted it)'
        }
    }

    # EFI\Boot\bootx64.efi fallback (removable-media UEFI path)
    $fallbackDir = Join-Path $espCache 'EFI\Boot'
    $fallbackEfi = Join-Path $fallbackDir 'bootx64.efi'
    if (-not (Test-Path -LiteralPath $fallbackEfi)) {
        New-Item -ItemType Directory -Force -Path $fallbackDir | Out-Null
        $src = Join-Path $espCache 'efi\microsoft\boot\bootmgfw.efi'
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $fallbackEfi -Force
        }
    }

    # SetupConfig.ini in ESP cache
    @('[SetupConfig]','BitLocker=AlwaysSuspend','NoReboot','ShowOOBE=None',
      'Quiet','BypassNRO=1','[Compat]','IgnoreWarning=1') |
        Set-Content -LiteralPath (Join-Path $espCache 'sources\SetupConfig.ini') -Encoding ascii -Force -ErrorAction SilentlyContinue

    EmitProgress -Disk 0 -Phase 'esp-copy' -Pct 100

    # Overlay cache — wipe and recreate so no stale payload files survive across workflow-type
    # switches (e.g. a prior full AMD64 build populates Deploy\, WUPayload\, Scripts\ in the
    # same cache root; New-Item -Force on an existing directory does NOT clear old content).
    Remove-Item -LiteralPath $overlayCache -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $overlayCache | Out-Null

    if (-not $NoPayload -and -not $QuickInstall) {
        # Full build: Deploy\, Policy\, WUPayload\, and Scripts\ carry the deploy entry-point layout.
        New-Item -ItemType Directory -Force -Path (Join-Path $overlayCache 'FirstBase\Deploy'), (Join-Path $overlayCache 'FirstBase\Policy'), (Join-Path $overlayCache 'FirstBase\Scripts'), (Join-Path $overlayCache 'FirstBase\WUPayload'), (Join-Path $overlayCache 'FirstBase\WUPayload\Tools') | Out-Null
        $overlayMap = @(
            @{ Src = (Join-Path $ContentRoot 'Deploy\TechInstall.cmd');                       Dst = 'FirstBase\Deploy\TechInstall.cmd' },
            @{ Src = (Join-Path $ContentRoot 'Deploy\disksetup.cmd');                         Dst = 'FirstBase\Deploy\disksetup.cmd' },
            @{ Src = (Join-Path $ContentRoot 'Deploy\Invoke-FirstBaseRaidProbe.ps1');         Dst = 'FirstBase\Deploy\Invoke-FirstBaseRaidProbe.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Deploy\WinPE-Startnet.cmd');                    Dst = 'FirstBase\Deploy\WinPE-Startnet.cmd' },
            @{ Src = (Join-Path $ContentRoot 'Deploy\Show-DeployBanner.ps1');                 Dst = 'FirstBase\Deploy\Show-DeployBanner.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Deploy\Invoke-FbDeployUi.ps1');                 Dst = 'FirstBase\Deploy\Invoke-FbDeployUi.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseBuildIdentity.ps1');                   Dst = 'FirstBase\Deploy\FirstBaseBuildIdentity.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Scripts\Invoke-FirstBaseDismApply.ps1');        Dst = 'FirstBase\Scripts\Invoke-FirstBaseDismApply.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Policy\autounattend.xml');                      Dst = 'FirstBase\Autounattend.xml' },
            @{ Src = (Join-Path $ContentRoot 'Policy\autounattend.xml');                      Dst = 'FirstBase\Policy\Autounattend.xml' },
            @{ Src = (Join-Path $ContentRoot 'SetupComplete.cmd');                            Dst = 'FirstBase\WUPayload\SetupComplete.cmd' },
            @{ Src = (Join-Path $ContentRoot 'Invoke-WindowsUpdateLoop.ps1');                 Dst = 'FirstBase\WUPayload\Invoke-WindowsUpdateLoop.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Tools\fb-dump.ps1');                             Dst = 'FirstBase\WUPayload\Tools\fb-dump.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Tools\fb-im.cmd');                               Dst = 'fb-im.cmd' },
            @{ Src = (Join-Path $ContentRoot 'Tools\fb-im.ps1');                               Dst = 'FirstBase\WUPayload\Tools\fb-im.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseDebugHotkeyWatcher.ps1');              Dst = 'FirstBase\WUPayload\FirstBaseDebugHotkeyWatcher.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseDeferredOobeSound.ps1');               Dst = 'FirstBase\WUPayload\FirstBaseDeferredOobeSound.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseHandoffSplash.ps1');                   Dst = 'FirstBase\WUPayload\FirstBaseHandoffSplash.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseOobeDeferredSoundBootstrap.ps1');      Dst = 'FirstBase\WUPayload\FirstBaseOobeDeferredSoundBootstrap.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseOobeOperatorFinalize.ps1');            Dst = 'FirstBase\WUPayload\FirstBaseOobeOperatorFinalize.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseOpenSettingsAndFinish.ps1');           Dst = 'FirstBase\WUPayload\FirstBaseOpenSettingsAndFinish.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseHardwareCheck.ps1');                   Dst = 'FirstBase\WUPayload\FirstBaseHardwareCheck.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBasePostSysprepOobeSoundArm.ps1');         Dst = 'FirstBase\WUPayload\FirstBasePostSysprepOobeSoundArm.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseShowSplash.ps1');                      Dst = 'FirstBase\WUPayload\FirstBaseShowSplash.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseSplashSingleInstance.ps1');            Dst = 'FirstBase\WUPayload\FirstBaseSplashSingleInstance.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseSplashWatcher.ps1');                   Dst = 'FirstBase\WUPayload\FirstBaseSplashWatcher.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseVersion.cmd');                         Dst = 'FirstBase\WUPayload\FirstBaseVersion.cmd' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseVersion.ps1');                         Dst = 'FirstBase\WUPayload\FirstBaseVersion.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseBuildIdentity.ps1');                   Dst = 'FirstBase\WUPayload\FirstBaseBuildIdentity.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseWuEngine.ps1');                        Dst = 'FirstBase\WUPayload\FirstBaseWuEngine.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Show-UpdateProgress.ps1');                      Dst = 'FirstBase\WUPayload\Show-UpdateProgress.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseSplashTechMenu.ps1');                  Dst = 'FirstBase\WUPayload\FirstBaseSplashTechMenu.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Tools\seal_command.txt');                       Dst = 'FirstBase\WUPayload\Tools\seal_command.txt' },
            @{ Src = (Join-Path $ContentRoot 'FirstBase.ico');                                Dst = 'FirstBase\FirstBase.ico' }
        )
        foreach ($o in $overlayMap) {
            if (Test-Path -LiteralPath $o.Src) {
                Copy-Item -LiteralPath $o.Src -Destination (Join-Path $overlayCache $o.Dst) -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $NoPayload -and -not $QuickInstall) {
            Assert-LwUpdateLoopCopy -Src (Join-Path $ContentRoot 'Invoke-WindowsUpdateLoop.ps1') -Dst (Join-Path $overlayCache 'FirstBase\WUPayload\Invoke-WindowsUpdateLoop.ps1')
        }
        $scriptsSrc = Join-Path $ContentRoot 'Scripts'
        if (Test-Path -LiteralPath $scriptsSrc) {
            $scriptsDst = Join-Path $overlayCache 'FirstBase\Scripts'
            New-Item -ItemType Directory -Path $scriptsDst -Force | Out-Null
            Copy-Item -Path (Join-Path $scriptsSrc '*') -Destination $scriptsDst -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($DevBuild) {
            try {
                $wuDir = Join-Path $overlayCache 'FirstBase\WUPayload'
                if (-not (Test-Path -LiteralPath $wuDir)) { New-Item -ItemType Directory -Force -Path $wuDir | Out-Null }
                $markerBody = "devBuild=1`r`nlauncherVersion=$LauncherVersion`r`nscriptVersion=$ScriptVersion`r`nshareLauncherVersion=$ShareLauncherVersion`r`nshareScriptVersion=$ShareScriptVersion`r`nbuiltAt=$(Get-Date -Format 'o')`r`n"
                [System.IO.File]::WriteAllText((Join-Path $wuDir '.dev-build'), $markerBody, [System.Text.UTF8Encoding]::new($false))
            } catch {}
        }
    } else {
        # WIN-INSTALL: overlay uses the same TechInstall architecture as a full build.
        # startnet -> wpeinit -> WinPE-Startnet.cmd -> TechInstall.cmd -> disksetup.cmd + DISM apply + bcdboot + shutdown.
        New-Item -ItemType Directory -Force -Path (Join-Path $overlayCache 'FirstBase\Policy'), (Join-Path $overlayCache 'FirstBase\Deploy'), (Join-Path $overlayCache 'FirstBase\WUPayload\Tools') | Out-Null
        # Prefer autounattend-install.xml (no SetupComplete.cmd RunSynchronous) over the full version.
        $autounattendInstallSrc = if ($QuickInstall) { Join-Path $ContentRoot 'Policy\autounattend-quickinstall.xml' } else { Join-Path $ContentRoot 'Policy\autounattend-install.xml' }
        $autounattendSrc = if (Test-Path -LiteralPath $autounattendInstallSrc) { $autounattendInstallSrc } else { Join-Path $ContentRoot 'Policy\autounattend.xml' }
        if (Test-Path -LiteralPath $autounattendSrc) {
            Copy-Item -LiteralPath $autounattendSrc -Destination (Join-Path $overlayCache 'FirstBase\Autounattend.xml') -Force
            Copy-Item -LiteralPath $autounattendSrc -Destination (Join-Path $overlayCache 'FirstBase\Policy\Autounattend.xml') -Force
        }
        # TechInstall-Install.cmd: stripped deploy script (no WU payload staging).
        $techInstallInstallSrc = if ($QuickInstall) { Join-Path $ContentRoot 'Deploy\TechInstall-QuickInstall.cmd' } else { Join-Path $ContentRoot 'Deploy\TechInstall-Install.cmd' }
        if (Test-Path -LiteralPath $techInstallInstallSrc) {
            Copy-Item -LiteralPath $techInstallInstallSrc -Destination (Join-Path $overlayCache 'FirstBase\Deploy\TechInstall.cmd') -Force
        }
        # WinPE-Startnet.cmd: WinPE bootstrap that finds and calls FirstBase\Deploy\TechInstall.cmd on the data partition.
        $winpeStartnetSrc = Join-Path $ContentRoot 'Deploy\WinPE-Startnet.cmd'
        if (Test-Path -LiteralPath $winpeStartnetSrc) {
            Copy-Item -LiteralPath $winpeStartnetSrc -Destination (Join-Path $overlayCache 'FirstBase\Deploy\WinPE-Startnet.cmd') -Force
        }
        # Show-DeployBanner.ps1: PowerShell-rendered animated WinPE title banner.
        $bannerSrc = Join-Path $ContentRoot 'Deploy\Show-DeployBanner.ps1'
        if (Test-Path -LiteralPath $bannerSrc) {
            Copy-Item -LiteralPath $bannerSrc -Destination (Join-Path $overlayCache 'FirstBase\Deploy\Show-DeployBanner.ps1') -Force
        }
        # Invoke-FbDeployUi.ps1: the PowerShell deploy screen that TechInstall*.cmd
        # repaints at every step. Without it the deploy falls back to the plain
        # echo progress bar, so it must ship alongside the banner.
        $deployUiSrc = Join-Path $ContentRoot 'Deploy\Invoke-FbDeployUi.ps1'
        if (Test-Path -LiteralPath $deployUiSrc) {
            Copy-Item -LiteralPath $deployUiSrc -Destination (Join-Path $overlayCache 'FirstBase\Deploy\Invoke-FbDeployUi.ps1') -Force
        }
        # FirstBaseBuildIdentity.ps1: the shared dev/release resolver. The banner
        # and the deploy screen both dot-source it from Deploy\, and default to
        # release without it, so it has to land beside them.
        $identitySrc = Join-Path $ContentRoot 'FirstBaseBuildIdentity.ps1'
        if (Test-Path -LiteralPath $identitySrc) {
            Copy-Item -LiteralPath $identitySrc -Destination (Join-Path $overlayCache 'FirstBase\Deploy\FirstBaseBuildIdentity.ps1') -Force
        }
        # disksetup.cmd: diskpart script that creates ESP + Windows partitions on the target disk.
        $disksetupSrc = Join-Path $ContentRoot 'Deploy\disksetup.cmd'
        if (Test-Path -LiteralPath $disksetupSrc) {
            Copy-Item -LiteralPath $disksetupSrc -Destination (Join-Path $overlayCache 'FirstBase\Deploy\disksetup.cmd') -Force
        }
        # Invoke-FirstBaseDismApply.ps1: PowerShell DISM apply UI (live progress) for the QuickInstall console.
        $dismApplySrc = Join-Path $ContentRoot 'Scripts\Invoke-FirstBaseDismApply.ps1'
        if (Test-Path -LiteralPath $dismApplySrc) {
            New-Item -ItemType Directory -Force -Path (Join-Path $overlayCache 'FirstBase\Scripts') | Out-Null
            Copy-Item -LiteralPath $dismApplySrc -Destination (Join-Path $overlayCache 'FirstBase\Scripts\Invoke-FirstBaseDismApply.ps1') -Force
        }
        # fb-im front-end: cmd launcher stays at volume ROOT; PS backend + fb-dump backend under FirstBase\WUPayload\Tools\.
        $imCmdSrc = Join-Path $ContentRoot 'Tools\fb-im.cmd'
        if (Test-Path -LiteralPath $imCmdSrc) {
            Copy-Item -LiteralPath $imCmdSrc -Destination (Join-Path $overlayCache 'fb-im.cmd') -Force
        }
        $imPs1Src = Join-Path $ContentRoot 'Tools\fb-im.ps1'
        if (Test-Path -LiteralPath $imPs1Src) {
            Copy-Item -LiteralPath $imPs1Src -Destination (Join-Path $overlayCache 'FirstBase\WUPayload\Tools\fb-im.ps1') -Force
        }
        $dumpPs1Src = Join-Path $ContentRoot 'Tools\fb-dump.ps1'
        if (Test-Path -LiteralPath $dumpPs1Src) {
            Copy-Item -LiteralPath $dumpPs1Src -Destination (Join-Path $overlayCache 'FirstBase\WUPayload\Tools\fb-dump.ps1') -Force
        }
        $icoSrc = Join-Path $ContentRoot 'FirstBase.ico'
        if (Test-Path -LiteralPath $icoSrc) {
            Copy-Item -LiteralPath $icoSrc -Destination (Join-Path $overlayCache 'FirstBase\FirstBase.ico') -Force
        }
        Copy-LwPeBrailleFont -OverlayRoot $overlayCache
    }
}

# --- ISO-direct ESP + overlay cache builder -----------------------------------
# Used when no pre-staged WIM exists and the build runs directly from a mounted ISO.
# The ISO must already be mounted; $IsoDrive is the drive root (e.g. "D:\").
function Build-IsoCache {
    param([string]$IsoDrive)

    New-Item -ItemType Directory -Force -Path $espCache, $overlayCache | Out-Null

    EmitProgress -Disk 0 -Phase 'esp-copy' -Pct 0

    # Copy all ISO root items except sources\ (and any loose WIM/ESD/SWM files).
    # Iterate per item so the progress bar advances instead of staying at 0% for minutes.
    $isoEntries = @(Get-ChildItem -LiteralPath $IsoDrive -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ine 'sources' -and
                       -not (-not $_.PSIsContainer -and $_.Name -match '\.(wim|esd|swm)$') })
    $isoEntryTotal = [math]::Max(1, $isoEntries.Count)
    $isoEntryIdx   = 0
    foreach ($isoEntry in $isoEntries) {
        $isoEntryIdx++
        $pct = [math]::Min(79, [math]::Round($isoEntryIdx / $isoEntryTotal * 80))
        EmitProgress -Disk 0 -Phase 'esp-copy' -Pct $pct
        if ($isoEntry.PSIsContainer) {
            Copy-Item -LiteralPath $isoEntry.FullName -Destination $espCache -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Copy-Item -LiteralPath $isoEntry.FullName -Destination $espCache -Force -ErrorAction SilentlyContinue
        }
    }

    # Copy sources\boot.wim only (needed for ESP; install.wim stays on the ISO)
    EmitProgress -Disk 0 -Phase 'esp-copy' -Pct 85
    $espSourcesDir = Join-Path $espCache 'sources'
    New-Item -ItemType Directory -Force -Path $espSourcesDir | Out-Null
    $bootWimSrc = Join-Path $IsoDrive 'sources\boot.wim'
    if (Test-Path -LiteralPath $bootWimSrc) {
        Copy-Item -LiteralPath $bootWimSrc -Destination $espSourcesDir -Force -ErrorAction SilentlyContinue
    }

    # Copy pre-injection sentinel from the staging directory (not from the ISO -
    # the ISO does not carry the sentinel).  Written by _inject-boot-wim.ps1.
    #
    # Always delete any existing ESP cache sentinel first: boot.wim was just replaced
    # from the ISO with a preserved timestamp that may be older than a prior sentinel.
    $sentinelSrc = Join-Path $ArchRoot 'sources\boot.wim.lw-injected'
    $sentinelDst = Join-Path $espSourcesDir 'boot.wim.lw-injected'
    $espBootWim  = Join-Path $espSourcesDir 'boot.wim'
    Remove-Item -LiteralPath $sentinelDst -Force -ErrorAction SilentlyContinue
    # Only restore if the staging sentinel is newer than the ISO's boot.wim, proving
    # the staging already has a pre-injected copy of that boot.wim.
    if ((Test-Path -LiteralPath $sentinelSrc) -and (Test-Path -LiteralPath $espBootWim)) {
        if ((Get-Item -LiteralPath $sentinelSrc).LastWriteTime -ge (Get-Item -LiteralPath $espBootWim).LastWriteTime) {
            Copy-Item -LiteralPath $sentinelSrc -Destination $sentinelDst -Force -ErrorAction SilentlyContinue
        }
    }

    # Ensure efi\microsoft\boot\bootmgfw.efi exists on the ESP cache.
    # Some custom ISOs only ship efi\boot\bootx64.efi (same binary, different path).
    # The ISO-sourced BCD uses a `locate` device anchored to \EFI\Microsoft\Boot\bootmgfw.efi
    # to establish the Boot Manager's home partition context.  If that file is absent the
    # locate fails, the ramdisk device for \sources\boot.wim cannot be resolved, and the
    # system shows the 0xc0000098 (STATUS_NO_SUCH_FILE) recovery screen.
    $bootmgfwDst = Join-Path $espCache 'efi\microsoft\boot\bootmgfw.efi'
    if (-not (Test-Path -LiteralPath $bootmgfwDst)) {
        $bootmgfwSrc = Join-Path $espCache 'efi\boot\bootx64.efi'
        if (Test-Path -LiteralPath $bootmgfwSrc) {
            New-Item -ItemType Directory -Force -Path (Split-Path $bootmgfwDst -Parent) -ErrorAction SilentlyContinue | Out-Null
            Copy-Item -LiteralPath $bootmgfwSrc -Destination $bootmgfwDst -Force
            EmitLog -Disk 0 -Msg 'esp-cache: synthesised efi\microsoft\boot\bootmgfw.efi from efi\boot\bootx64.efi (ISO omitted it)'
        }
    }

    # EFI\Boot\bootx64.efi fallback (removable-media UEFI path)
    $fallbackDir = Join-Path $espCache 'EFI\Boot'
    $fallbackEfi = Join-Path $fallbackDir 'bootx64.efi'
    if (-not (Test-Path -LiteralPath $fallbackEfi)) {
        New-Item -ItemType Directory -Force -Path $fallbackDir | Out-Null
        $src = Join-Path $espCache 'efi\microsoft\boot\bootmgfw.efi'
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $fallbackEfi -Force
        }
    }

    # SetupConfig.ini in ESP cache
    EmitProgress -Disk 0 -Phase 'esp-copy' -Pct 95
    @('[SetupConfig]','BitLocker=AlwaysSuspend','NoReboot','ShowOOBE=None',
      'Quiet','BypassNRO=1','[Compat]','IgnoreWarning=1') |
        Set-Content -LiteralPath (Join-Path $espCache 'sources\SetupConfig.ini') -Encoding ascii -Force -ErrorAction SilentlyContinue

    EmitProgress -Disk 0 -Phase 'esp-copy' -Pct 100

    # Overlay cache — wipe and recreate so no stale payload files survive across workflow-type
    # switches (same logic as Build-Cache; New-Item -Force never clears existing content).
    Remove-Item -LiteralPath $overlayCache -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $overlayCache | Out-Null

    if (-not $NoPayload -and -not $QuickInstall) {
        # Full build: Deploy\, Policy\, WUPayload\, and Scripts\ carry the deploy entry-point layout.
        New-Item -ItemType Directory -Force -Path (Join-Path $overlayCache 'FirstBase\Deploy'), (Join-Path $overlayCache 'FirstBase\Policy'), (Join-Path $overlayCache 'FirstBase\Scripts'), (Join-Path $overlayCache 'FirstBase\WUPayload'), (Join-Path $overlayCache 'FirstBase\WUPayload\Tools') | Out-Null
        $overlayMap = @(
            @{ Src = (Join-Path $ContentRoot 'Deploy\TechInstall.cmd');                       Dst = 'FirstBase\Deploy\TechInstall.cmd' },
            @{ Src = (Join-Path $ContentRoot 'Deploy\disksetup.cmd');                         Dst = 'FirstBase\Deploy\disksetup.cmd' },
            @{ Src = (Join-Path $ContentRoot 'Deploy\Invoke-FirstBaseRaidProbe.ps1');         Dst = 'FirstBase\Deploy\Invoke-FirstBaseRaidProbe.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Deploy\WinPE-Startnet.cmd');                    Dst = 'FirstBase\Deploy\WinPE-Startnet.cmd' },
            @{ Src = (Join-Path $ContentRoot 'Deploy\Show-DeployBanner.ps1');                 Dst = 'FirstBase\Deploy\Show-DeployBanner.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Deploy\Invoke-FbDeployUi.ps1');                 Dst = 'FirstBase\Deploy\Invoke-FbDeployUi.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseBuildIdentity.ps1');                   Dst = 'FirstBase\Deploy\FirstBaseBuildIdentity.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Scripts\Invoke-FirstBaseDismApply.ps1');        Dst = 'FirstBase\Scripts\Invoke-FirstBaseDismApply.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Policy\autounattend.xml');                      Dst = 'FirstBase\Autounattend.xml' },
            @{ Src = (Join-Path $ContentRoot 'Policy\autounattend.xml');                      Dst = 'FirstBase\Policy\Autounattend.xml' },
            @{ Src = (Join-Path $ContentRoot 'SetupComplete.cmd');                            Dst = 'FirstBase\WUPayload\SetupComplete.cmd' },
            @{ Src = (Join-Path $ContentRoot 'Invoke-WindowsUpdateLoop.ps1');                 Dst = 'FirstBase\WUPayload\Invoke-WindowsUpdateLoop.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Tools\fb-dump.ps1');                             Dst = 'FirstBase\WUPayload\Tools\fb-dump.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Tools\fb-im.cmd');                               Dst = 'fb-im.cmd' },
            @{ Src = (Join-Path $ContentRoot 'Tools\fb-im.ps1');                               Dst = 'FirstBase\WUPayload\Tools\fb-im.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseDebugHotkeyWatcher.ps1');              Dst = 'FirstBase\WUPayload\FirstBaseDebugHotkeyWatcher.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseDeferredOobeSound.ps1');               Dst = 'FirstBase\WUPayload\FirstBaseDeferredOobeSound.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseHandoffSplash.ps1');                   Dst = 'FirstBase\WUPayload\FirstBaseHandoffSplash.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseOobeDeferredSoundBootstrap.ps1');      Dst = 'FirstBase\WUPayload\FirstBaseOobeDeferredSoundBootstrap.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseOobeOperatorFinalize.ps1');            Dst = 'FirstBase\WUPayload\FirstBaseOobeOperatorFinalize.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseOpenSettingsAndFinish.ps1');           Dst = 'FirstBase\WUPayload\FirstBaseOpenSettingsAndFinish.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseHardwareCheck.ps1');                   Dst = 'FirstBase\WUPayload\FirstBaseHardwareCheck.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBasePostSysprepOobeSoundArm.ps1');         Dst = 'FirstBase\WUPayload\FirstBasePostSysprepOobeSoundArm.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseShowSplash.ps1');                      Dst = 'FirstBase\WUPayload\FirstBaseShowSplash.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseSplashSingleInstance.ps1');            Dst = 'FirstBase\WUPayload\FirstBaseSplashSingleInstance.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseSplashWatcher.ps1');                   Dst = 'FirstBase\WUPayload\FirstBaseSplashWatcher.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseVersion.cmd');                         Dst = 'FirstBase\WUPayload\FirstBaseVersion.cmd' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseVersion.ps1');                         Dst = 'FirstBase\WUPayload\FirstBaseVersion.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseBuildIdentity.ps1');                   Dst = 'FirstBase\WUPayload\FirstBaseBuildIdentity.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseWuEngine.ps1');                        Dst = 'FirstBase\WUPayload\FirstBaseWuEngine.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Show-UpdateProgress.ps1');                      Dst = 'FirstBase\WUPayload\Show-UpdateProgress.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseSplashTechMenu.ps1');                  Dst = 'FirstBase\WUPayload\FirstBaseSplashTechMenu.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Tools\seal_command.txt');                       Dst = 'FirstBase\WUPayload\Tools\seal_command.txt' },
            @{ Src = (Join-Path $ContentRoot 'FirstBase.ico');                                Dst = 'FirstBase\FirstBase.ico' }
        )
        foreach ($o in $overlayMap) {
            if (Test-Path -LiteralPath $o.Src) {
                Copy-Item -LiteralPath $o.Src -Destination (Join-Path $overlayCache $o.Dst) -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $NoPayload -and -not $QuickInstall) {
            Assert-LwUpdateLoopCopy -Src (Join-Path $ContentRoot 'Invoke-WindowsUpdateLoop.ps1') -Dst (Join-Path $overlayCache 'FirstBase\WUPayload\Invoke-WindowsUpdateLoop.ps1')
        }
        $scriptsSrc = Join-Path $ContentRoot 'Scripts'
        if (Test-Path -LiteralPath $scriptsSrc) {
            $scriptsDst = Join-Path $overlayCache 'FirstBase\Scripts'
            New-Item -ItemType Directory -Path $scriptsDst -Force | Out-Null
            Copy-Item -Path (Join-Path $scriptsSrc '*') -Destination $scriptsDst -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($DevBuild) {
            try {
                $wuDir = Join-Path $overlayCache 'FirstBase\WUPayload'
                if (-not (Test-Path -LiteralPath $wuDir)) { New-Item -ItemType Directory -Force -Path $wuDir | Out-Null }
                $markerBody = "devBuild=1`r`nlauncherVersion=$LauncherVersion`r`nscriptVersion=$ScriptVersion`r`nshareLauncherVersion=$ShareLauncherVersion`r`nshareScriptVersion=$ShareScriptVersion`r`nbuiltAt=$(Get-Date -Format 'o')`r`n"
                [System.IO.File]::WriteAllText((Join-Path $wuDir '.dev-build'), $markerBody, [System.Text.UTF8Encoding]::new($false))
            } catch {}
        }
    } else {
        # WIN-INSTALL: overlay uses the same TechInstall architecture as a full build.
        # startnet -> wpeinit -> WinPE-Startnet.cmd -> TechInstall.cmd -> disksetup.cmd + DISM apply + bcdboot + shutdown.
        New-Item -ItemType Directory -Force -Path (Join-Path $overlayCache 'FirstBase\Policy'), (Join-Path $overlayCache 'FirstBase\Deploy'), (Join-Path $overlayCache 'FirstBase\WUPayload\Tools') | Out-Null
        # Prefer autounattend-install.xml (no SetupComplete.cmd RunSynchronous) over the full version.
        $autounattendInstallSrc = if ($QuickInstall) { Join-Path $ContentRoot 'Policy\autounattend-quickinstall.xml' } else { Join-Path $ContentRoot 'Policy\autounattend-install.xml' }
        $autounattendSrc = if (Test-Path -LiteralPath $autounattendInstallSrc) { $autounattendInstallSrc } else { Join-Path $ContentRoot 'Policy\autounattend.xml' }
        if (Test-Path -LiteralPath $autounattendSrc) {
            Copy-Item -LiteralPath $autounattendSrc -Destination (Join-Path $overlayCache 'FirstBase\Autounattend.xml') -Force
            Copy-Item -LiteralPath $autounattendSrc -Destination (Join-Path $overlayCache 'FirstBase\Policy\Autounattend.xml') -Force
        }
        # TechInstall-Install.cmd: stripped deploy script (no WU payload staging).
        $techInstallInstallSrc = if ($QuickInstall) { Join-Path $ContentRoot 'Deploy\TechInstall-QuickInstall.cmd' } else { Join-Path $ContentRoot 'Deploy\TechInstall-Install.cmd' }
        if (Test-Path -LiteralPath $techInstallInstallSrc) {
            Copy-Item -LiteralPath $techInstallInstallSrc -Destination (Join-Path $overlayCache 'FirstBase\Deploy\TechInstall.cmd') -Force
        }
        # WinPE-Startnet.cmd: WinPE bootstrap that finds and calls FirstBase\Deploy\TechInstall.cmd on the data partition.
        $winpeStartnetSrc = Join-Path $ContentRoot 'Deploy\WinPE-Startnet.cmd'
        if (Test-Path -LiteralPath $winpeStartnetSrc) {
            Copy-Item -LiteralPath $winpeStartnetSrc -Destination (Join-Path $overlayCache 'FirstBase\Deploy\WinPE-Startnet.cmd') -Force
        }
        # Show-DeployBanner.ps1: PowerShell-rendered animated WinPE title banner.
        $bannerSrc = Join-Path $ContentRoot 'Deploy\Show-DeployBanner.ps1'
        if (Test-Path -LiteralPath $bannerSrc) {
            Copy-Item -LiteralPath $bannerSrc -Destination (Join-Path $overlayCache 'FirstBase\Deploy\Show-DeployBanner.ps1') -Force
        }
        # Invoke-FbDeployUi.ps1: the PowerShell deploy screen that TechInstall*.cmd
        # repaints at every step. Without it the deploy falls back to the plain
        # echo progress bar, so it must ship alongside the banner.
        $deployUiSrc = Join-Path $ContentRoot 'Deploy\Invoke-FbDeployUi.ps1'
        if (Test-Path -LiteralPath $deployUiSrc) {
            Copy-Item -LiteralPath $deployUiSrc -Destination (Join-Path $overlayCache 'FirstBase\Deploy\Invoke-FbDeployUi.ps1') -Force
        }
        # FirstBaseBuildIdentity.ps1: the shared dev/release resolver. The banner
        # and the deploy screen both dot-source it from Deploy\, and default to
        # release without it, so it has to land beside them.
        $identitySrc = Join-Path $ContentRoot 'FirstBaseBuildIdentity.ps1'
        if (Test-Path -LiteralPath $identitySrc) {
            Copy-Item -LiteralPath $identitySrc -Destination (Join-Path $overlayCache 'FirstBase\Deploy\FirstBaseBuildIdentity.ps1') -Force
        }
        # disksetup.cmd: diskpart script that creates ESP + Windows partitions on the target disk.
        $disksetupSrc = Join-Path $ContentRoot 'Deploy\disksetup.cmd'
        if (Test-Path -LiteralPath $disksetupSrc) {
            Copy-Item -LiteralPath $disksetupSrc -Destination (Join-Path $overlayCache 'FirstBase\Deploy\disksetup.cmd') -Force
        }
        # Invoke-FirstBaseDismApply.ps1: PowerShell DISM apply UI (live progress) for the QuickInstall console.
        $dismApplySrc = Join-Path $ContentRoot 'Scripts\Invoke-FirstBaseDismApply.ps1'
        if (Test-Path -LiteralPath $dismApplySrc) {
            New-Item -ItemType Directory -Force -Path (Join-Path $overlayCache 'FirstBase\Scripts') | Out-Null
            Copy-Item -LiteralPath $dismApplySrc -Destination (Join-Path $overlayCache 'FirstBase\Scripts\Invoke-FirstBaseDismApply.ps1') -Force
        }
        # fb-im front-end: cmd launcher stays at volume ROOT; PS backend + fb-dump backend under FirstBase\WUPayload\Tools\.
        $imCmdSrc = Join-Path $ContentRoot 'Tools\fb-im.cmd'
        if (Test-Path -LiteralPath $imCmdSrc) {
            Copy-Item -LiteralPath $imCmdSrc -Destination (Join-Path $overlayCache 'fb-im.cmd') -Force
        }
        $imPs1Src = Join-Path $ContentRoot 'Tools\fb-im.ps1'
        if (Test-Path -LiteralPath $imPs1Src) {
            Copy-Item -LiteralPath $imPs1Src -Destination (Join-Path $overlayCache 'FirstBase\WUPayload\Tools\fb-im.ps1') -Force
        }
        $dumpPs1Src = Join-Path $ContentRoot 'Tools\fb-dump.ps1'
        if (Test-Path -LiteralPath $dumpPs1Src) {
            Copy-Item -LiteralPath $dumpPs1Src -Destination (Join-Path $overlayCache 'FirstBase\WUPayload\Tools\fb-dump.ps1') -Force
        }
        $icoSrc = Join-Path $ContentRoot 'FirstBase.ico'
        if (Test-Path -LiteralPath $icoSrc) {
            Copy-Item -LiteralPath $icoSrc -Destination (Join-Path $overlayCache 'FirstBase\FirstBase.ico') -Force
        }
        Copy-LwPeBrailleFont -OverlayRoot $overlayCache
    }
}

# Build-OverlayCache removed (5.2.88): USB-bound overlay copies ContentRoot → USB
# directly in the per-disk worker. EspCache (Build-Cache / Build-IsoCache) remains
# only for non-ISO staged-WIM boot.wim template injection.

# --- DISM WIM mount-race helpers ---------------------------------------------
# DISM allows only ONE read-write mount per WIM file at a time - mounting index 2
# while index 1 (or a leftover mount from an earlier crashed build) is still
# registered against the same boot.wim fails with 0xc1420127 ("The specified
# image in the specified wim is already mounted for read/write access"). This
# can happen even when index 1's own /Unmount-Image /Commit reported success,
# because the WIMMount filter driver can release its lock on the file slightly
# after DISM's exit code comes back. Test-WimMounted is read-only (used to wait
# for a just-committed mount to actually clear); Clear-StaleWimMount is used
# defensively before every mount attempt to discard any mount - this run's or
# an older crashed run's - still registered against the WIM.
function Test-WimMounted {
    param([string] $WimPath)
    try {
        Import-Module -Name Dism -ErrorAction SilentlyContinue
        $fullWimPath = [System.IO.Path]::GetFullPath($WimPath)
        return @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object {
            $_.ImagePath -and ([System.IO.Path]::GetFullPath($_.ImagePath) -ieq $fullWimPath)
        })
    } catch {
        return @()
    }
}

function Clear-StaleWimMount {
    param([string] $WimPath)
    $stale = @(Test-WimMounted -WimPath $WimPath)
    foreach ($m in $stale) {
        & dism.exe /Unmount-Image /MountDir:"$($m.MountPath)" /Discard 2>&1 | Out-Null
    }
    if ($stale.Count -gt 0) {
        & dism.exe /Cleanup-Mountpoints 2>&1 | Out-Null
    }
    return $stale.Count
}

# --- Inject WinPE-Startnet.cmd into boot.wim in the ESP cache ----------------
# Mounts boot.wim index 1 offline with DISM, replaces Windows\System32\startnet.cmd
# with our custom launcher (WinPE-Startnet.cmd), then commits and dismounts.
# Called once after Build-Cache / Build-IsoCache so every USB written from this
# cache gets a boot.wim that auto-launches TechInstall.cmd on WinPE start.
# Non-fatal: emits a warning and continues if DISM fails so the build does not
# abort - the USB will boot to a WinPE prompt instead of auto-launching.
function Invoke-StartnetInjection {
    param(
        [string] $BootWimPath,       # espCache\sources\boot.wim
        [string] $StartnetCmdPath,   # payload\Deploy\WinPE-Startnet.cmd
        [string] $WpeOcPath = ''     # Remote\Staging\WinPE-OCs\ (optional; adds PS to WinPE)
    )

    if (-not (Test-Path -LiteralPath $BootWimPath)) {
        EmitLog -Disk 0 -Msg "startnet inject: boot.wim not found at '$BootWimPath' - WinPE will NOT auto-launch TechInstall.cmd"
        return
    }
    if (-not (Test-Path -LiteralPath $StartnetCmdPath)) {
        EmitLog -Disk 0 -Msg "startnet inject: WinPE-Startnet.cmd not found at '$StartnetCmdPath' - WinPE will NOT auto-launch TechInstall.cmd"
        return
    }

    # FAIL LOUD: WinPE PowerShell is mandatory for LoneWolf (TechInstall depends on it).
    # WinPE PowerShell has a strict dependency chain and a language requirement: each
    # base cab MUST be paired with its matching en-us LANGUAGE cab. Adding
    # WinPE-PowerShell.cab without WinPE-NetFx_en-us.cab / WinPE-PowerShell_en-us.cab
    # produces a WinPE where powershell.exe exists on disk but cannot actually start
    # (missing .NET / language resources) - which is exactly the "PowerShell absent on
    # the booted stick" symptom. So the FULL 8-cab set (base + _en-us) is REQUIRED on
    # the share and verified BEFORE mounting anything, so a missing dependency aborts
    # the whole build (naming the exact files) instead of silently shipping a
    # PowerShell-less / broken-PowerShell WinPE (root cause of the re-image loop).
    $requiredOc = @(
        'WinPE-WMI.cab',        'WinPE-WMI_en-us.cab',
        'WinPE-NetFx.cab',      'WinPE-NetFx_en-us.cab',
        'WinPE-Scripting.cab',  'WinPE-Scripting_en-us.cab',
        'WinPE-PowerShell.cab', 'WinPE-PowerShell_en-us.cab')
    if ([string]::IsNullOrWhiteSpace($WpeOcPath) -or -not (Test-Path -LiteralPath $WpeOcPath)) {
        throw "FATAL: WinPE OC folder not found at '$WpeOcPath'. LoneWolf requires the WinPE optional-component cabs in the per-architecture subfolder (WinPE-WMI/NetFx/Scripting/PowerShell plus their _en-us language cabs). Stage them under '$WpeOcPath'."
    }
    # Accept either a flat WinPE-OCs\ layout or one where the _en-us cabs live in an
    # en-us\ subfolder (both are valid ADK layouts).
    $missingOc = @($requiredOc | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $WpeOcPath $_)) -and
        -not (Test-Path -LiteralPath (Join-Path (Join-Path $WpeOcPath 'en-us') $_))
    })
    if ($missingOc.Count -gt 0) {
        throw ("FATAL: Required WinPE OC cab(s) missing in '$WpeOcPath': " + ($missingOc -join ', ') +
               ". WinPE PowerShell needs the base cabs AND their matching en-us language cabs. OPERATOR ACTION: copy the missing file(s) into the arch subfolder '$WpeOcPath' then re-run a Full Rebuild. LoneWolf will not ship a stick without a working PowerShell.")
    }
    EmitLog -Disk 0 -Msg "startnet inject: WinPE OCs verified present at '$WpeOcPath' (full base + en-us set: $($requiredOc -join ', '))"

    # boot.wim copied from a network share often has the ReadOnly attribute set.
    # DISM /Commit must write back to the WIM file - it fails on a read-only file.
    # Clear the attribute unconditionally before mounting.
    try {
        Set-ItemProperty -LiteralPath $BootWimPath -Name IsReadOnly -Value $false -ErrorAction Stop
    } catch {
        EmitLog -Disk 0 -Msg "startnet inject: WARNING - could not clear ReadOnly on boot.wim: $($_.Exception.Message)"
    }

    # Patch both index 1 and index 2 - the Windows BCD boots from index 2 (Windows Setup
    # WinPE image) on standard ISOs, while index 1 is the minimal PE used internally by
    # Windows Setup itself. Leaving index 2 unpatched means setup.exe still launches from
    # the stock winpeshl.ini [LaunchApps] entry, causing the language-selection screen.
    foreach ($wimIndex in 1, 2) {
        $mountDir  = Join-Path $env:TEMP ("LWMount_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $isMounted = $false
        $_winjBase      = if ($wimIndex -eq 1) { 0 } else { 50 }
        $_winjInitPct   = if ($wimIndex -eq 1) { 5 } else { 52 }
        $_winjCommitPct = if ($wimIndex -eq 1) { 50 } else { 95 }
        $_winjOcStep    = 0
        try {
            New-Item -ItemType Directory -Force -Path $mountDir | Out-Null
            EmitProgress -Disk 0 -Phase 'winpe-inject' -Pct $_winjInitPct
            EmitLog -Disk 0 -Msg "startnet inject: mounting boot.wim index $wimIndex at $mountDir ..."

            # Defensively discard any mount already registered against this boot.wim
            # (this run's or a leftover from an earlier crashed build) before mounting -
            # DISM permits only one read-write mount per WIM file.
            Clear-StaleWimMount -WimPath $BootWimPath | Out-Null

            # Use /Mount-Image (/ImageFile:) - the modern non-deprecated DISM syntax.
            # The old /Mount-Wim /WimFile: variant is rejected on some Windows 11 builds.
            # Retry with backoff: mounting a different index of the same WIM right after
            # another index was unmounted can transiently fail with 0xc1420127 ("already
            # mounted for read/write access") if DISM's mount registry has not caught up.
            $__mountAttempt = 0
            $__mountMax     = 3
            do {
                $__mountAttempt++
                $mountOut = & dism.exe /Mount-Image /ImageFile:"$BootWimPath" /Index:$wimIndex /MountDir:"$mountDir" 2>&1
                if ($LASTEXITCODE -eq 0) { break }
                if ($__mountAttempt -ge $__mountMax) {
                    throw "DISM /Mount-Image (index $wimIndex) failed (exit $LASTEXITCODE): $($mountOut -join ' | ')"
                }
                EmitLog -Disk 0 -Msg "startnet inject: /Mount-Image (index $wimIndex) attempt $__mountAttempt failed (exit $LASTEXITCODE) - clearing stale mounts and retrying in 2s ..."
                Clear-StaleWimMount -WimPath $BootWimPath | Out-Null
                Start-Sleep -Seconds 2
            } while ($__mountAttempt -lt $__mountMax)
            $isMounted = $true

            $sysDir = Join-Path $mountDir 'Windows\System32'
            if (-not (Test-Path -LiteralPath $sysDir)) {
                throw "Windows\System32 not found in mounted boot.wim index $wimIndex (unexpected WIM structure)"
            }

            $targetFile = Join-Path $sysDir 'startnet.cmd'
            Copy-Item -LiteralPath $StartnetCmdPath -Destination $targetFile -Force
            EmitLog -Disk 0 -Msg "startnet inject: startnet.cmd written (index $wimIndex) ..."

            # Inject the UEFI pre-flight helper alongside startnet.cmd (mirrors Build-UsbStick.ps1
            # Invoke-TiPatchBootWim). startnet.cmd looks for it at X:\Windows\System32\Invoke-FbUefiPreflight.ps1;
            # without this copy the pre-flight (Secure Boot / RAID) check is silently skipped at boot.
            $preflightSrc = Join-Path (Split-Path -Parent $StartnetCmdPath) 'Invoke-FbUefiPreflight.ps1'
            if (Test-Path -LiteralPath $preflightSrc) {
                Copy-Item -LiteralPath $preflightSrc -Destination (Join-Path $sysDir 'Invoke-FbUefiPreflight.ps1') -Force
                EmitLog -Disk 0 -Msg "startnet inject: Invoke-FbUefiPreflight.ps1 written (index $wimIndex) ..."
            } else {
                EmitLog -Disk 0 -Msg "startnet inject: Invoke-FbUefiPreflight.ps1 not found at '$preflightSrc' (index $wimIndex) - preflight will be skipped at boot"
            }

            # Replace winpeshl.ini to prevent setup.exe from launching alongside startnet.cmd.
            # The stock boot.wim winpeshl.ini has a [LaunchApps] entry pointing to \sources\setup.exe
            # which causes the Windows language-selection UI. Explicitly listing startnet.cmd in
            # [LaunchApps] (matching the reference builder) ensures it runs and setup.exe does not.
            $winpeshlPath = Join-Path $sysDir 'winpeshl.ini'
            Set-ItemProperty -LiteralPath $winpeshlPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
            [System.IO.File]::WriteAllText($winpeshlPath, "[LaunchApps]`r`ncmd.exe, /c X:\Windows\System32\startnet.cmd`r`n", [System.Text.Encoding]::ASCII)
            EmitLog -Disk 0 -Msg "startnet inject: winpeshl.ini set to launch startnet.cmd (index $wimIndex, setup.exe suppressed) ..."

            # WinPE PowerShell optional components, added in STRICT dependency order:
            # each base cab immediately followed by its en-us language cab, WMI -> NetFx
            # -> Scripting -> PowerShell. The pre-mount guard already verified all 8 cabs
            # exist, so ANY /Add-Package failure (base OR language) is FATAL (throws ->
            # build aborts) - a partial add produces a non-functional PowerShell. Each
            # cab's exit code is checked individually and logged per-cab.
            foreach ($oc in @(
                @{ base = 'WinPE-WMI.cab';        lang = 'WinPE-WMI_en-us.cab' },
                @{ base = 'WinPE-NetFx.cab';      lang = 'WinPE-NetFx_en-us.cab' },
                @{ base = 'WinPE-Scripting.cab';  lang = 'WinPE-Scripting_en-us.cab' },
                @{ base = 'WinPE-PowerShell.cab'; lang = 'WinPE-PowerShell_en-us.cab' })) {
                foreach ($cabName in @($oc.base, $oc.lang)) {
                    $cabPath = Join-Path $WpeOcPath $cabName
                    if (-not (Test-Path -LiteralPath $cabPath)) { $cabPath = Join-Path (Join-Path $WpeOcPath 'en-us') $cabName }
                    EmitLog -Disk 0 -Msg "startnet inject: adding $cabName to boot.wim index $wimIndex ..."
                    & dism.exe /Image:"$mountDir" /Add-Package /PackagePath:"$cabPath" /Quiet 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        throw "FATAL: WinPE OC $cabName /Add-Package failed (exit $LASTEXITCODE) on boot.wim index $wimIndex"
                    }
                    EmitLog -Disk 0 -Msg "startnet inject: $cabName added OK (index $wimIndex)"
                }
                $_winjOcStep += 10
                EmitProgress -Disk 0 -Phase 'winpe-inject' -Pct ($_winjBase + $_winjOcStep)
            }

            # Verify PowerShell actually landed in the image before committing.
            $peShellPath = Join-Path $mountDir 'Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $peShellPath)) {
                throw "FATAL: powershell.exe NOT present in boot.wim index $wimIndex after adding WinPE OCs - refusing to ship a PowerShell-less WinPE"
            }
            EmitLog -Disk 0 -Msg "startnet inject: PowerShell verified present in WinPE (index $wimIndex)"

            $peFontsDir = Join-Path $mountDir 'Windows\Fonts'
            Copy-LwPeBrailleFont -WimFontsDir $peFontsDir

            EmitLog -Disk 0 -Msg "startnet inject: committing boot.wim index $wimIndex ..."
            $unmountOut = & dism.exe /Unmount-Image /MountDir:"$mountDir" /Commit 2>&1
            if ($LASTEXITCODE -ne 0) {
                # Do NOT clear $isMounted here - the finally block must still discard
                # the live mount so DISM does not leave a stale registry entry.
                throw "DISM /Unmount-Image /Commit (index $wimIndex) failed (exit $LASTEXITCODE): $($unmountOut -join ' | ')"
            }
            $isMounted = $false
            # /Unmount-Image can report success before the WIMMount filter driver has
            # actually released its lock on the file. Poll (read-only, up to ~5s) so the
            # next index's /Mount-Image does not race the driver and fail with 0xc1420127.
            $__unmountWaitTries = 0
            while ($__unmountWaitTries -lt 10 -and (Test-WimMounted -WimPath $BootWimPath).Count -gt 0) {
                Start-Sleep -Milliseconds 500
                $__unmountWaitTries++
            }
            EmitLog -Disk 0 -Msg "startnet inject: committing boot.wim index $wimIndex complete - WinPE will auto-launch TechInstall.cmd"
            EmitProgress -Disk 0 -Phase 'winpe-inject' -Pct $_winjCommitPct

        } catch {
            $__ocMsg = $_.Exception.Message
            if ($__ocMsg -like 'FATAL:*') {
                # A mandatory dependency (WinPE OCs / PowerShell) failed. Discard the
                # live mount and propagate so the whole build aborts loudly instead of
                # producing a USB that boots a PowerShell-less WinPE.
                if ($isMounted) {
                    & dism.exe /Unmount-Image /MountDir:"$mountDir" /Discard 2>&1 | Out-Null
                    $isMounted = $false
                }
                Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
                throw
            }
            EmitLog -Disk 0 -Msg "WARNING: startnet inject FAILED (index $wimIndex) - $__ocMsg"
            EmitLog -Disk 0 -Msg "WARNING: WinPE may NOT auto-launch TechInstall.cmd; USB boots to PE command prompt"
        } finally {
            if ($isMounted) {
                EmitLog -Disk 0 -Msg "startnet inject: discarding uncommitted WIM mount (index $wimIndex, cleanup) ..."
                & dism.exe /Unmount-Image /MountDir:"$mountDir" /Discard 2>&1 | Out-Null
            }
            Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Per-disk end-to-end worker (runs as background job) ----------------------
# Full pipeline per disk (true parallel across disks):
#   wipe/partition -> ESP copy -> DISM/data -> WinPE inject (this USB's boot.wim) ->
#   overlay / Autounattend -> BCD -> version stamp -> done
# Shared staging WIM / ISO mounts stay on the main thread (read-only); jobs only
# robocopy from them. WinPE DISM inject mounts only the per-USB ESP boot.wim.
# On failure: emits error + done(success=false), then throws (job state = Failed).
$workerDiskBlock = {
    param(
        [int]    $DiskNumber,
        [string] $EspCache,
        [string] $StagingWim,
        [long]   $EspPartitionBytes,
        [bool]   $OverlayOnly,
        [string] $DataVolumeLabel,
        # ISO-mode: when non-empty the build reads install.wim from the mounted ISO drive
        [string] $IsoDrive,
        [bool]   $NoPayload,
        # WIM-mode parallel: shared read-only mount dir prepared on the main thread.
        # When set, this job robocopies from it (no per-disk DISM /Mount-Image).
        [string] $SharedWimMount,
        [string] $OverlayCache,
        [string] $StartnetForInjection,
        [string] $WpeOcStaging,
        [string] $ContentRoot,
        [string] $WorkflowType,
        [string] $StagingVersion,
        # 'Single' (FAT32 Basic-Data, one volume, WIM-split) or 'Split' (FAT32 ESP + NTFS data)
        [string] $Layout,
        # QUICK-INSTALL minimal payload-free install (independent of $NoPayload).
        [bool]   $QuickInstall,
        # Full path to the shared split helper lib (lib\Split-LWImage.ps1). Dot-sourced
        # below so this job runspace gets Split-LWImageForFat32 (script-scope functions
        # are NOT visible inside a Start-Job runspace).
        [string] $SplitLibPath,
        # Pre-split fast-copy set dir for THIS build's ISO ('' when none/mismatch/corrupt).
        # Resolved ONCE on the main thread (Get-LWPreSplitSet). When non-empty the ISO-mode
        # Single branch robocopies the staged install*.swm instead of splitting on the fly.
        [string] $PreSplitSetDir,
        [bool]   $DevBuild,
        [string] $LauncherVersion,
        [string] $ScriptVersion,
        [string] $ShareLauncherVersion,
        [string] $ShareScriptVersion,
        [string] $ImageBuildDate
    )

    $ErrorActionPreference = 'Stop'

    # Dot-source the shared split helper into THIS job runspace (see $SplitLibPath note).
    # The on-the-fly fallback split (Split-LWImageForFat32) and the producer both use this
    # exact file, so a build's fallback output is byte-identical to a staged set.
    if (-not [string]::IsNullOrWhiteSpace($SplitLibPath) -and (Test-Path -LiteralPath $SplitLibPath)) {
        . $SplitLibPath
    }

    function J {
        param([hashtable]$Data)
        $Data | ConvertTo-Json -Compress -Depth 3 | Write-Output
    }
    function JPhase   { param([string]$P) J @{ event='phase'; disk=$DiskNumber; phase=$P } }
    function JProgress{ param([string]$P, [int]$Pct) J @{ event='progress'; disk=$DiskNumber; phase=$P; pct=$Pct } }

    # Job runspaces cannot see script-scope Assert-LwUpdateLoopCopy. Size-only
    # check here; AST parse already ran on the main thread against ContentRoot.
    function Assert-LoopCopyLocal {
        param([string]$Src, [string]$Dst)
        if ([string]::IsNullOrWhiteSpace($Src) -or [string]::IsNullOrWhiteSpace($Dst)) { return }
        if (-not (Test-Path -LiteralPath $Dst)) {
            throw "FATAL: Invoke-WindowsUpdateLoop.ps1 missing after overlay copy: '$Dst'"
        }
        $srcLen = [int64](Get-Item -LiteralPath $Src).Length
        $dstLen = [int64](Get-Item -LiteralPath $Dst).Length
        if ($srcLen -ne $dstLen) {
            throw ("FATAL: Invoke-WindowsUpdateLoop.ps1 truncated during overlay copy ({0} -> {1} bytes): '{2}'." -f $srcLen, $dstLen, $Dst)
        }
        if ($dstLen -lt 900000) {
            throw ("FATAL: Invoke-WindowsUpdateLoop.ps1 on stick is truncated ({0} bytes): '{1}'." -f $dstLen, $Dst)
        }
    }

    function Reset-LwUsbLogFolder {
        param([string]$VolRoot, [switch]$ClearContents)
        if ([string]::IsNullOrWhiteSpace($VolRoot)) { return }
        $vol = $VolRoot.TrimEnd('\') + '\'
        $logDir = Join-Path $vol 'FirstBase-Logs'
        if ($ClearContents -and (Test-Path -LiteralPath $logDir)) {
            & attrib.exe -H -S -R $logDir 2>&1 | Out-Null
            Get-ChildItem -LiteralPath $logDir -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        & attrib.exe -H -S $logDir 2>&1 | Out-Null
    }

    function Write-LwUsbExplorerChrome {
        param([string]$VolRoot, [string]$IcoSrc)
        if ([string]::IsNullOrWhiteSpace($VolRoot)) { return }
        $vol = $VolRoot.TrimEnd('\') + '\'
        $infPath = Join-Path $vol 'autorun.inf'
        $fbDir = Join-Path $vol 'FirstBase'
        $icoPath = Join-Path $fbDir 'FirstBase.ico'
        $rootIco = Join-Path $vol 'FirstBase.ico'
        # Leftover from older sticks that placed FirstBase.ico at volume root.
        if (Test-Path -LiteralPath $rootIco) {
            & attrib.exe -H -S -R $rootIco 2>&1 | Out-Null
            Remove-Item -LiteralPath $rootIco -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $infPath) {
            & attrib.exe -H -S -R $infPath 2>&1 | Out-Null
        }
        if (-not (Test-Path -LiteralPath $fbDir)) {
            New-Item -ItemType Directory -Path $fbDir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $icoPath) {
            & attrib.exe -H -S -R $icoPath 2>&1 | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace($IcoSrc) -and (Test-Path -LiteralPath $IcoSrc)) {
            Copy-Item -LiteralPath $IcoSrc -Destination $icoPath -Force
        }
        # Icon + no AutoRun execute verbs. ASCII/CRLF. Do not fight the volume label.
        # autorun.inf must stay at volume root; the ico lives under FirstBase\.
        [System.IO.File]::WriteAllText($infPath, "[autorun]`r`nicon=FirstBase\FirstBase.ico`r`n", [System.Text.Encoding]::ASCII)
        if (Test-Path -LiteralPath $fbDir) {
            & attrib.exe +H +S $fbDir /D 2>&1 | Out-Null
        }
        if (Test-Path -LiteralPath $infPath) {
            & attrib.exe +H $infPath 2>&1 | Out-Null
        }
        $im = Join-Path $vol 'fb-im.cmd'
        if (Test-Path -LiteralPath $im) {
            & attrib.exe -H -S $im 2>&1 | Out-Null
        }
        $logDir = Join-Path $vol 'FirstBase-Logs'
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        & attrib.exe -H -S $logDir 2>&1 | Out-Null
    }

    # Human-facing workflow label for log/throw messages. The ISO-mode direct-from-ISO boot
    # copy path is SHARED by LoneWolf / WIN-INSTALL / QUICK-INSTALL, so messages must reflect
    # the ACTUAL workflow instead of hardcoding 'WIN-INSTALL'.
    $wfLabel = if ($QuickInstall) { 'QUICK-INSTALL' } elseif ($NoPayload) { 'WIN-INSTALL' } else { 'LoneWolf' }

    # DISM allows only ONE read-write mount per WIM file at a time. This job runspace
    # cannot call script-scope functions, so duplicate the mount-race helpers locally
    # (see Test-WimMounted / Clear-StaleWimMount at script scope for the full rationale).
    function Test-WimMountedLocal {
        param([string]$WimPath)
        try {
            Import-Module -Name Dism -ErrorAction SilentlyContinue
            $fullWimPath = [System.IO.Path]::GetFullPath($WimPath)
            return @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object {
                $_.ImagePath -and ([System.IO.Path]::GetFullPath($_.ImagePath) -ieq $fullWimPath)
            })
        } catch {
            return @()
        }
    }
    function Clear-StaleWimMountLocal {
        param([string]$WimPath)
        $stale = @(Test-WimMountedLocal -WimPath $WimPath)
        foreach ($m in $stale) {
            & dism.exe /Unmount-Image /MountDir:"$($m.MountPath)" /Discard 2>&1 | Out-Null
        }
        if ($stale.Count -gt 0) {
            & dism.exe /Cleanup-Mountpoints 2>&1 | Out-Null
        }
        return $stale.Count
    }

    # Single layout only: install.wim is almost always > 4 GB and CANNOT live on FAT32.
    # The split body now lives in the SHARED helper lib (lib\Split-LWImage.ps1,
    # Split-LWImageForFat32), dot-sourced into this job runspace above. Both the
    # on-the-fly fallback below and the pre-split producer (Stage-PreSplitImage.ps1)
    # call that one function, so a build's fallback output is byte-identical to a
    # staged set (same /FileSize:3800, same /CheckIntegrity, same ESD-export path,
    # same install*.swm naming). The deploy side (TechInstall.cmd /
    # Invoke-FirstBaseDismApply.ps1) already applies from install*.swm via SWMFile
    # when install.wim is absent. An install.wim/esd already <= 4 GB is copied as-is.
    #
    # Thin local wrapper preserving the previous call-site signature (-Disk) while
    # adapting the shared helper's plain-string $Emit into this worker's J log events.
    function Invoke-LWSplitForFat32 {
        param([string]$SourceSourcesDir, [string]$DestSourcesDir, [int]$Disk, [string]$ProgressPhase = 'wim-split')
        Split-LWImageForFat32 -SourceSourcesDir $SourceSourcesDir -DestSourcesDir $DestSourcesDir `
            -Emit { param($m) J @{ event='log'; disk=$Disk; message=$m } } `
            -Progress { param($p) JProgress $ProgressPhase $p }
    }

    try {
        Import-Module Storage -ErrorAction Stop

        $espRoot  = $null
        $dataRoot = $null

        if ($OverlayOnly) {
            # -- Overlay-only: find existing partitions by label ---------------
            JPhase 'overlay-update'

            $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
            foreach ($p in $parts) {
                try {
                    $v = $p | Get-Volume -ErrorAction SilentlyContinue
                    if ($v -and $v.DriveLetter) {
                        # -eq is case-insensitive in PowerShell, so 'LoneWolf' matches the
                        # FAT32 uppercase readback 'LONEWOLF'. Legacy labels are still accepted.
                        if ($v.FileSystemLabel -eq $DataVolumeLabel -or $v.FileSystemLabel -eq 'LoneWolf' -or $v.FileSystemLabel -eq 'Project LoneWolf' -or $v.FileSystemLabel -eq 'WINSETUP' -or $v.FileSystemLabel -eq 'WINDOWS' -or $v.FileSystemLabel -match '^\d{4}-\d{2}-\d{2}$') { $dataRoot = $v.DriveLetter + ':\' }
                        if ($v.FileSystemLabel -eq 'FB_ESP')   { $espRoot  = $v.DriveLetter + ':\' }
                    }
                } catch { }
            }

            if (-not $dataRoot) {
                throw "No '$DataVolumeLabel' or 'WINSETUP' partition found on disk $DiskNumber  -  cannot apply overlay-only update"
            }

        } else {
            # -- Full build: partition + format + DISM -------------------------
            JPhase 'partitioning'

            $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
            $disk | Clear-Disk -RemoveData -Confirm:$false -ErrorAction Stop
            $disk | Set-Disk -PartitionStyle GPT -ErrorAction Stop
            $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop

            if ($Layout -eq 'Single') {
                # Single layout (LoneWolf default): ONE FAT32 Microsoft Basic Data partition
                # (GPT type {ebd0a0a2-...}, deliberately NOT the ESP GUID {c12a7328-...}).
                # Boot files + install media share this single volume. Because the USB carries
                # no ESP-GUID partition, only the internal disk's ESP exists at force-boot time,
                # so bcdedit {fwbootmgr} resolves cleanly instead of failing with "multiple
                # indistinguishable devices". FAT32 is mandatory: UEFI firmware can only load
                # the boot loaders from a FAT volume. install.wim is split into install.swm to
                # satisfy the FAT32 4 GB per-file limit (see Split-LWInstallImageForFat32).
                #
                # Single and Split now share ONE label 'LoneWolf' (8 chars, FAT32-legal).
                # FAT32 stores labels uppercase so it reads back as 'LONEWOLF'; all
                # detection (fb-dump.ps1, Get-UsbDisks.ps1, overlay-only below) is
                # case-insensitive, so the stored case does not matter.
                $fat32Label = $DataVolumeLabel
                J @{ event='log'; disk=$DiskNumber; message='partitioning: Single layout - one FAT32 Basic-Data volume (no ESP GUID); force-boot safe' }
                $data = $disk | New-Partition -UseMaximumSize `
                    -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' `
                    -AssignDriveLetter -ErrorAction Stop
                try {
                    $data | Format-Volume -FileSystem FAT32 -NewFileSystemLabel $fat32Label -Confirm:$false | Out-Null
                } catch {
                    $dl = ($data | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
                    if ($dl) {
                        & cmd /c "format $dl`: /FS:FAT32 /Q /V:$fat32Label /Y" | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw "FAT32 format failed on drive $dl (single-volume layout)" }
                    } else {
                        throw "FAT32 Format-Volume failed and no drive letter available for cmd /c format fallback: $($_.Exception.Message)"
                    }
                }
                # The single volume serves as BOTH boot volume and data volume. Aliasing $esp to
                # $data lets every downstream ESP/data step operate on the one volume unchanged.
                $esp      = $data
                $espRoot  = ($data | Get-Volume).DriveLetter + ':\'
                $dataRoot = $espRoot
            } else {
                # ESP partition (FAT32, 1GB default or measured)
                $esp = $disk | New-Partition -Size $EspPartitionBytes `
                    -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter -ErrorAction Stop
                try {
                    $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'FB_ESP' -Confirm:$false | Out-Null
                } catch {
                    $el = ($esp | Get-Volume).DriveLetter
                    & cmd /c "format $el`: /FS:FAT32 /Q /V:FB_ESP /Y" | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "FAT32 format failed on drive $el" }
                }

                # Data partition (NTFS, Microsoft Basic Data GPT type so Windows always assigns a
                # drive letter and never marks the partition Inaccessible.  Without -GptType the
                # Storage stack can silently choose a non-standard GUID on some Windows builds.)
                $data = $disk | New-Partition -UseMaximumSize `
                    -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' `
                    -AssignDriveLetter -ErrorAction Stop
                try {
                    $data | Format-Volume -FileSystem NTFS -NewFileSystemLabel $DataVolumeLabel -Confirm:$false | Out-Null
                } catch {
                    $dl = ($data | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
                    if ($dl) {
                        & cmd /c "format $dl`: /FS:NTFS /Q /V:$DataVolumeLabel /Y" | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw "NTFS format failed on drive $dl (Format-Volume and cmd /c format fallback both failed)" }
                    } else {
                        throw "NTFS Format-Volume failed and no drive letter available for cmd /c format fallback: $($_.Exception.Message)"
                    }
                }

                $espRoot  = ($esp  | Get-Volume).DriveLetter + ':\'
                $dataRoot = ($data | Get-Volume).DriveLetter + ':\'
            }

            # Wait for volumes to become accessible
            foreach ($volRoot in (@($espRoot, $dataRoot) | Select-Object -Unique)) {
                for ($w = 0; $w -lt 30; $w++) {
                    if (Test-Path -LiteralPath $volRoot) { break }
                    Start-Sleep -Seconds 1
                }
            }

            # ESP copy: ISO mode (LoneWolf / WIN-INSTALL / Architecture B) copies boot files
            # directly from the mounted ISO per disk. WIM mode pre-populates from ESP cache.
            JPhase 'esp-copy'
            if (-not [string]::IsNullOrEmpty($IsoDrive)) {
                JProgress 'esp-copy' 0
                # ISO mode: copy boot files directly from mounted ISO to USB ESP. sources\boot.wim
                # (~600-700 MB) is the bulk; the root EFI/boot items are small. Report live byte
                # progress: copy the small root items first (coarse steps), then boot.wim via a
                # polled background robocopy (mirrors the wim-presplit fast-copy pattern).
                $isoItems = @(Get-ChildItem -LiteralPath $IsoDrive -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ine 'sources' -and -not ($_.Name -match '\.(wim|esd|swm)$') })

                $bootWimSrcW = Join-Path $IsoDrive 'sources\boot.wim'
                if (-not (Test-Path -LiteralPath $bootWimSrcW)) {
                    throw "$wfLabel ESP copy: sources\boot.wim not found on ISO at '$bootWimSrcW'"
                }
                $bootWimBytes = (Get-Item -LiteralPath $bootWimSrcW).Length
                $rootBytes = ($isoItems | ForEach-Object {
                    if ($_.PSIsContainer) {
                        (Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    } else { $_.Length }
                } | Measure-Object -Sum -ErrorAction SilentlyContinue).Sum
                if (-not $rootBytes) { $rootBytes = 0 }
                $espTotalBytes = [math]::Max(1, [long]$rootBytes + [long]$bootWimBytes)

                # Small root EFI/boot items: copy sequentially, emitting coarse progress.
                $espCopied = 0
                foreach ($item in $isoItems) {
                    if ($item.PSIsContainer) {
                        Copy-Item -LiteralPath $item.FullName -Destination $espRoot -Recurse -Force -ErrorAction SilentlyContinue
                        $espCopied += (Get-ChildItem -LiteralPath $item.FullName -Recurse -File -ErrorAction SilentlyContinue |
                            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    } else {
                        Copy-Item -LiteralPath $item.FullName -Destination $espRoot -Force -ErrorAction SilentlyContinue
                        $espCopied += $item.Length
                    }
                    try { JProgress 'esp-copy' ([math]::Min(99, [int](100 * $espCopied / $espTotalBytes))) } catch { }
                }

                # sources\boot.wim (the bulk): background robocopy + byte-poll for live progress.
                $espSources = Join-Path $espRoot 'sources'
                New-Item -ItemType Directory -Force -Path $espSources | Out-Null
                $bootWimDstW = Join-Path $espSources 'boot.wim'
                $espJob = Start-Job -ScriptBlock {
                    param($src, $dst)
                    & robocopy.exe $src $dst 'boot.wim' /R:2 /W:5 /NP /NJH /NJS | Out-Null
                    $LASTEXITCODE
                } -ArgumentList (Join-Path $IsoDrive 'sources'), $espSources
                while ($espJob.State -eq 'Running') {
                    Start-Sleep -Seconds 1
                    try {
                        $dstNow = 0
                        if (Test-Path -LiteralPath $bootWimDstW) { $dstNow = (Get-Item -LiteralPath $bootWimDstW).Length }
                        $espDone = [long]$rootBytes + [long]$dstNow
                        if ($espDone -ge ($espTotalBytes * 0.99)) {
                            # Dest size looks complete but robocopy is still flushing write-back
                            # to the USB. Cap the reported pct low so the UI Finalizing fake bar
                            # has room to climb (do NOT emit 99 — that made the bar look done).
                            J @{ event='progress'; disk=$DiskNumber; phase='esp-copy'; pct=88; flushing=$true; label='Finalizing…' }
                        } else {
                            JProgress 'esp-copy' ([math]::Min(88, [int](100 * $espDone / $espTotalBytes)))
                        }
                    } catch { }
                }
                $espRc = Receive-Job -Job $espJob | Select-Object -Last 1
                Remove-Job -Job $espJob -Force
                if ($espRc -gt 7) {
                    throw "$wfLabel ESP copy: robocopy failed (exit $espRc) copying sources\boot.wim to ESP at '$bootWimDstW'"
                }
                if (-not (Test-Path -LiteralPath $bootWimDstW)) {
                    throw "$wfLabel ESP copy: failed to place sources\boot.wim on ESP at '$bootWimDstW'"
                }
                # ISO boot.wim is often ReadOnly; DISM /Commit fails without clearing it first.
                try { Set-ItemProperty -LiteralPath $bootWimDstW -Name IsReadOnly -Value $false -ErrorAction Stop } catch { }
                # Synthesise efi\microsoft\boot\bootmgfw.efi from efi\boot\bootx64.efi if absent
                $bootmgfwDstW = Join-Path $espRoot 'efi\microsoft\boot\bootmgfw.efi'
                if (-not (Test-Path -LiteralPath $bootmgfwDstW)) {
                    $bootmgfwSrcW = Join-Path $espRoot 'efi\boot\bootx64.efi'
                    if (Test-Path -LiteralPath $bootmgfwSrcW) {
                        New-Item -ItemType Directory -Force -Path (Split-Path $bootmgfwDstW -Parent) -ErrorAction SilentlyContinue | Out-Null
                        Copy-Item -LiteralPath $bootmgfwSrcW -Destination $bootmgfwDstW -Force
                        J @{ event='log'; disk=$DiskNumber; message="esp-copy: synthesised efi\microsoft\boot\bootmgfw.efi from efi\boot\bootx64.efi ($wfLabel)" }
                    }
                }
                if (-not (Test-Path -LiteralPath $bootmgfwDstW)) {
                    throw "$wfLabel ESP copy: efi\microsoft\boot\bootmgfw.efi missing and efi\boot\bootx64.efi unavailable to synthesise it"
                }
                JProgress 'esp-copy' 100
                J @{ event='log'; disk=$DiskNumber; message="esp-copy: boot files copied directly from ISO to USB ESP ($wfLabel cache-bypass); boot.wim=$([math]::Round((Get-Item -LiteralPath $bootWimDstW).Length/1MB))MB" }
            } else {
                Copy-Item -Path "$EspCache\*" -Destination $espRoot -Recurse -Force -ErrorAction SilentlyContinue
                # Safety net: synthesise bootmgfw after cache copy (staging often omits it)
                $bootmgfwDstC = Join-Path $espRoot 'efi\microsoft\boot\bootmgfw.efi'
                if (-not (Test-Path -LiteralPath $bootmgfwDstC)) {
                    $bootmgfwSrcC = Join-Path $espRoot 'efi\boot\bootx64.efi'
                    if (Test-Path -LiteralPath $bootmgfwSrcC) {
                        New-Item -ItemType Directory -Force -Path (Split-Path $bootmgfwDstC -Parent) -ErrorAction SilentlyContinue | Out-Null
                        Copy-Item -LiteralPath $bootmgfwSrcC -Destination $bootmgfwDstC -Force
                        J @{ event='log'; disk=$DiskNumber; message='esp-copy: synthesised efi\microsoft\boot\bootmgfw.efi from efi\boot\bootx64.efi (cache path)' }
                    }
                }
                $espBootWimAfter = Join-Path $espRoot 'sources\boot.wim'
                if (-not (Test-Path -LiteralPath $espBootWimAfter)) {
                    throw "ESP copy: sources\boot.wim missing on ESP after cache copy (espCache may be incomplete)"
                }
            }

            # Re-acquire data letter (USB controllers can re-enumerate)
            $dataRoot = ($data | Get-Volume).DriveLetter + ':\'

            # Data partition write
            # ISO mode: robocopy all ISO contents to data partition (install.wim stays as a file).
            # WIM mode (preferred): robocopy from a shared read-only mount prepared on the main
            # thread — concurrent DISM /Mount-Image across Start-Jobs serializes / fails, so
            # parallel Phase 1 must share one mount and only parallelize the USB writes.
            # WIM mode (fallback): per-disk local copy + Mount-Image when no shared mount exists.
            if (-not [string]::IsNullOrEmpty($IsoDrive)) {
                JPhase 'data-copy'
                JProgress 'data-copy' 0
                # The ISO source is a single network-backed mount shared by all parallel
                # per-disk workers over SMB, so transient hiccups are possible. Give
                # robocopy more tolerance (/R:2 /W:5) and capture a per-disk log so a
                # failure can name the offending file(s). Per-file/dir lines are kept in
                # the log (no /NFL /NDL) so the tail identifies exactly what failed.
                $rcLog = Join-Path $env:TEMP "LW-robocopy-disk$DiskNumber.log"

                $srcBytes = (Get-ChildItem -LiteralPath "$IsoDrive\" -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                if (-not $srcBytes -or $srcBytes -le 0) { $srcBytes = 1 }

                # Single layout writes to FAT32, which cannot hold a > 4 GB install.wim/esd.
                # Exclude the monolithic install images from the bulk copy; they are placed
                # (split into install.swm) by Split-LWInstallImageForFat32 right after.
                $robXf = if ($Layout -eq 'Single') { @('install.wim', 'install.esd', 'install.swm') } else { @() }
                $robJob = Start-Job -ScriptBlock {
                    param($src, $dst, $log, $xf)
                    # Copy the ENTIRE ISO tree verbatim - INCLUDING the root \boot folder
                    # (boot.sdi, the stock BIOS \boot\BCD, fonts, resources). The stock UEFI
                    # BCD resolves the WinPE RAM disk via '{ramdiskoptions} ramdisksdipath
                    # \boot\boot.sdi', so \boot\boot.sdi MUST live on the volume or WinPE
                    # silently resets right after "WinPE initialized". Earlier builds excluded
                    # \boot (/XD) as "UEFI does not need BIOS boot files" - that dropped
                    # boot.sdi and is exactly what broke ISO-mode sticks. This now mirrors the
                    # proven Build-UsbStick.ps1, which robocopies the whole ISO and never
                    # rebuilds the BCD. Only the monolithic install.wim/.esd is excluded here
                    # (FAT32 4 GB limit) and re-added split into install.swm below.
                    $rcArgs = @($src, $dst, '/E', '/R:2', '/W:5', '/NP', '/NJH', '/NJS')
                    if ($xf -and @($xf).Count -gt 0) { $rcArgs += '/XF'; $rcArgs += @($xf) }
                    $rcArgs += "/LOG:$log"
                    & robocopy.exe @rcArgs
                    $LASTEXITCODE
                } -ArgumentList "$IsoDrive\", $dataRoot, $rcLog, $robXf

                while ($robJob.State -eq 'Running') {
                    Start-Sleep -Seconds 2
                    try {
                        $dstBytes = (Get-ChildItem -LiteralPath $dataRoot -Recurse -File -ErrorAction SilentlyContinue |
                            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                        if ($dstBytes -and $srcBytes -gt 0) {
                            $pct = [math]::Min(99, [int](99 * $dstBytes / $srcBytes))
                            JProgress 'data-copy' $pct
                        }
                    } catch { }
                }

                $robOutput = Receive-Job -Job $robJob
                $rcExit    = $robOutput | Select-Object -Last 1
                Remove-Job -Job $robJob -Force

                # The per-disk robocopy log is a diagnostic aid only. Read its failure tail
                # (below) BEFORE deleting it, then guarantee removal in the finally so a
                # completed build never leaves LW-robocopy-disk<N>.log littering %TEMP%.
                try {
                    if ($rcExit -gt 7) {
                        $rcTail = ''
                        try {
                            if (Test-Path -LiteralPath $rcLog) {
                                $rcTail = ((Get-Content -LiteralPath $rcLog -Tail 40 -ErrorAction SilentlyContinue) -join "`n")
                            }
                        } catch { }
                        throw "robocopy failed (exit $rcExit) copying ISO contents to data partition $dataRoot; log: $rcLog`n--- robocopy log tail ---`n$rcTail"
                    }
                } finally {
                    Remove-Item -LiteralPath $rcLog -Force -ErrorAction SilentlyContinue
                }
                JProgress 'data-copy' 100

                # Single layout: place the install image on the FAT32 volume as install*.swm.
                # FAST PATH: when a matching, validated pre-split set was resolved on the main
                # thread (Get-LWPreSplitSet), robocopy the already-split install*.swm straight
                # from the share to the USB - no temp, no mount, no on-the-fly DISM split.
                # FALLBACK: no set (or mismatch/corruption) -> the exact on-the-fly split used
                # before this feature. Pre-split applies to ISO mode ONLY.
                if ($Layout -eq 'Single') {
                    $dataSources = Join-Path $dataRoot 'sources'
                    if (-not [string]::IsNullOrWhiteSpace($PreSplitSetDir) -and (Test-Path -LiteralPath $PreSplitSetDir)) {
                        JPhase 'wim-presplit'
                        JProgress 'wim-presplit' 0
                        J @{ event='log'; disk=$DiskNumber; message="wim-presplit: copying pre-split install*.swm from staged set '$PreSplitSetDir' (fast path - no on-the-fly split)" }
                        New-Item -ItemType Directory -Force -Path $dataSources -ErrorAction SilentlyContinue | Out-Null
                        # install*.swm is the normal set; install.wim/.esd cover the rare
                        # already-<=4 GB image the producer copied as-is (both FAT32-legal).
                        # Source byte total for the live copy-progress denominator.
                        $psSrcBytes = (Get-ChildItem -LiteralPath $PreSplitSetDir -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -match '^install(\d*)\.(swm|wim|esd)$' } |
                            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                        if (-not $psSrcBytes -or $psSrcBytes -le 0) { $psSrcBytes = 1 }
                        # Robocopy the set as a nested job with /MT:3 so the three .swm files
                        # copy in PARALLEL (multi-threaded), while the outer loop polls the
                        # growing destination bytes to emit live wim-presplit progress.
                        $psJob = Start-Job -ScriptBlock {
                            param($src, $dst)
                            & robocopy.exe $src $dst 'install*.swm' 'install.wim' 'install.esd' /MT:3 /R:2 /W:5 /NP /NJH /NJS
                            $LASTEXITCODE
                        } -ArgumentList $PreSplitSetDir, $dataSources

                        while ($psJob.State -eq 'Running') {
                            Start-Sleep -Seconds 1
                            try {
                                $dstBytes = (Get-ChildItem -LiteralPath $dataSources -File -ErrorAction SilentlyContinue |
                                    Where-Object { $_.Name -match '^install(\d*)\.(swm|wim|esd)$' } |
                                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                                if (-not $dstBytes) { $dstBytes = 0 }
                                if ($dstBytes -ge ($psSrcBytes * 0.99)) {
                                    # Dest .swm sizes look complete but robocopy is still flushing
                                    # write-back to FAT32 USB (often many minutes). Emit Finalizing
                                    # at 88 — not 99 — so the UI fake bar can keep climbing.
                                    J @{ event='progress'; disk=$DiskNumber; phase='wim-presplit'; pct=88; flushing=$true; label='Finalizing…' }
                                } else {
                                    $pct = [math]::Min(88, [int](100 * $dstBytes / $psSrcBytes))
                                    JProgress 'wim-presplit' $pct
                                }
                            } catch { }
                        }

                        $psRc = Receive-Job -Job $psJob | Select-Object -Last 1
                        Remove-Job -Job $psJob -Force
                        if ($psRc -gt 7) {
                            throw "wim-presplit: robocopy failed (exit $psRc) copying pre-split set '$PreSplitSetDir' -> '$dataSources'"
                        }
                        $psChunks = @(Get-ChildItem -LiteralPath $dataSources -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -match '^install(\d*)\.(swm|wim|esd)$' })
                        if ($psChunks.Count -eq 0) {
                            throw "wim-presplit: no install image (install*.swm / install.wim / install.esd) landed on the FAT32 volume from '$PreSplitSetDir'"
                        }
                        JProgress 'wim-presplit' 100
                        J @{ event='log'; disk=$DiskNumber; message=("wim-presplit: staged {0} .swm chunk(s) copied - on-the-fly split skipped" -f $psChunks.Count) }
                    } else {
                        # Distinguish the two fallback causes so the log is unambiguous: an EMPTY
                        # set dir means the MAIN-THREAD detector (Get-LWPreSplitSet) found no valid,
                        # matching set - the authoritative reason is the disk 0 'presplit:' line. A
                        # NON-empty-but-unreadable dir means detection matched but this worker's
                        # runspace could not reach the share path (creds / SMB session).
                        $psMiss = if ([string]::IsNullOrWhiteSpace($PreSplitSetDir)) {
                            'no staged set resolved on the main thread (see the disk 0 "presplit:" line for the exact reason)'
                        } else {
                            "staged set was resolved but is not readable from this worker runspace: '$PreSplitSetDir'"
                        }
                        J @{ event='log'; disk=$DiskNumber; message="presplit: $psMiss - falling back to on-the-fly split" }
                        JPhase 'wim-split'
                        Invoke-LWSplitForFat32 -SourceSourcesDir (Join-Path $IsoDrive 'sources') -DestSourcesDir $dataSources -Disk $DiskNumber
                    }
                }
            } elseif (-not [string]::IsNullOrEmpty($SharedWimMount)) {
                # Shared mount path — parallel-safe (read-only mount, concurrent robocopy OK)
                JPhase 'dism'
                JProgress 'dism' 0
                if (-not (Test-Path -LiteralPath $SharedWimMount)) {
                    throw "Shared WIM mount path not found: $SharedWimMount"
                }
                J @{ event='log'; disk=$DiskNumber; message="wim-shared: robocopy from shared mount $SharedWimMount -> $dataRoot" }

                $srcBytes = (Get-ChildItem -LiteralPath $SharedWimMount -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                if (-not $srcBytes -or $srcBytes -le 0) { $srcBytes = 1 }

                $robXf = if ($Layout -eq 'Single') { @('install.wim', 'install.esd', 'install.swm') } else { @() }
                $robJob = Start-Job -ScriptBlock {
                    param($src, $dst, $xf)
                    $rcArgs = @($src, $dst, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:2', '/NP', '/NJH', '/NJS')
                    if ($xf -and @($xf).Count -gt 0) { $rcArgs += '/XF'; $rcArgs += @($xf) }
                    & robocopy.exe @rcArgs
                    $LASTEXITCODE
                } -ArgumentList "$SharedWimMount\", $dataRoot, $robXf

                while ($robJob.State -eq 'Running') {
                    Start-Sleep -Seconds 2
                    try {
                        $dstBytes = (Get-ChildItem -LiteralPath $dataRoot -Recurse -File -ErrorAction SilentlyContinue |
                            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                        if ($dstBytes -and $srcBytes -gt 0) {
                            $pct = [math]::Min(98, [int](98 * $dstBytes / $srcBytes))
                            JProgress 'dism' $pct
                        }
                    } catch { }
                }

                $robOutput = Receive-Job -Job $robJob
                $robExit   = $robOutput | Select-Object -Last 1
                Remove-Job -Job $robJob -Force

                if ($robExit -ge 8) {
                    throw "robocopy failed (exit $robExit) copying shared WIM mount to data partition $dataRoot"
                }
                J @{ event='log'; disk=$DiskNumber; message="wim-shared: robocopy complete (exit $robExit)" }
                if ($Layout -eq 'Single') {
                    Invoke-LWSplitForFat32 -SourceSourcesDir (Join-Path $SharedWimMount 'sources') -DestSourcesDir (Join-Path $dataRoot 'sources') -Disk $DiskNumber -ProgressPhase 'dism'
                }
                JProgress 'dism' 100
            } else {
                # Fallback: per-disk WIM copy + mount (used only when shared mount prep failed)
                JPhase 'dism'
                JProgress 'dism' 0

                $wimWorkDir = Join-Path $env:TEMP ('LW-WimWork-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                $localWim   = Join-Path $wimWorkDir 'staging.wim'
                $mountDir   = Join-Path $wimWorkDir 'mount'
                New-Item -ItemType Directory -Path $wimWorkDir -Force | Out-Null
                New-Item -ItemType Directory -Path $mountDir   -Force | Out-Null

                try {
                    # Prefer mounting the staging WIM DIRECTLY from its share path (read-only),
                    # skipping the full multi-GB copy to %TEMP% first. A read-only mount over
                    # SMB is safe here (no-ISO builds only). If the direct mount throws for any
                    # reason (share hiccup, driver refusing a UNC mount) fall back to the proven
                    # copy-to-temp-then-mount path so resilience is preserved. The mount dir
                    # stays under %TEMP% and the finally unmount+cleanup is unchanged either way.
                    $directMountOk = $false
                    try {
                        J @{ event='log'; disk=$DiskNumber; message="wim-mount: mounting staging WIM directly from share (read-only) -> $mountDir" }
                        $mountResult = & dism.exe /Mount-Image /ImageFile:"$StagingWim" /Index:1 /MountDir:"$mountDir" /ReadOnly 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            throw "DISM /Mount-Image (direct share) failed (exit $LASTEXITCODE): $($mountResult -join '; ')"
                        }
                        $directMountOk = $true
                        J @{ event='log'; disk=$DiskNumber; message='wim-mount: direct share mount ready (no local copy)' }
                        JProgress 'dism' 10
                    } catch {
                        J @{ event='log'; disk=$DiskNumber; message="WARNING: direct share mount failed ($($_.Exception.Message)); falling back to copy-to-temp then mount" }
                        # Discard any partial mount before the fallback re-mounts the same dir.
                        & dism.exe /Unmount-Image /MountDir:"$mountDir" /Discard 2>&1 | Out-Null
                    }

                    if (-not $directMountOk) {
                        J @{ event='log'; disk=$DiskNumber; message="wim-copy: copying WIM to local temp ($localWim)..." }
                        $copyResult = & robocopy.exe (Split-Path $StagingWim) $wimWorkDir (Split-Path $StagingWim -Leaf) /R:1 /W:2 /NP /NJH /NJS /J 2>&1
                        if ($LASTEXITCODE -ge 8) {
                            throw "WIM local copy failed (exit $LASTEXITCODE): $($copyResult -join '; ')"
                        }
                        $srcLeaf = Split-Path $StagingWim -Leaf
                        if ($srcLeaf -ne 'staging.wim') {
                            Rename-Item -LiteralPath (Join-Path $wimWorkDir $srcLeaf) -NewName 'staging.wim' -Force
                        }
                        J @{ event='log'; disk=$DiskNumber; message='wim-copy: local copy complete' }
                        JProgress 'dism' 5

                        J @{ event='log'; disk=$DiskNumber; message="wim-mount: mounting local WIM -> $mountDir (read-only)" }
                        $mountResult = & dism.exe /Mount-Image /ImageFile:"$localWim" /Index:1 /MountDir:"$mountDir" /ReadOnly 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            throw "DISM /Mount-Image failed (exit $LASTEXITCODE): $($mountResult -join '; ')"
                        }
                        JProgress 'dism' 10
                    }
                    J @{ event='log'; disk=$DiskNumber; message='wim-mount: WIM mounted, starting robocopy to data partition...' }

                    $srcBytes = (Get-ChildItem -LiteralPath $mountDir -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    if (-not $srcBytes -or $srcBytes -le 0) { $srcBytes = 1 }

                    $robXf = if ($Layout -eq 'Single') { @('install.wim', 'install.esd', 'install.swm') } else { @() }
                    $robJob = Start-Job -ScriptBlock {
                        param($src, $dst, $xf)
                        $rcArgs = @($src, $dst, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:2', '/NP', '/NJH', '/NJS')
                        if ($xf -and @($xf).Count -gt 0) { $rcArgs += '/XF'; $rcArgs += @($xf) }
                        & robocopy.exe @rcArgs
                        $LASTEXITCODE
                    } -ArgumentList "$mountDir\", $dataRoot, $robXf

                    while ($robJob.State -eq 'Running') {
                        Start-Sleep -Seconds 2
                        try {
                            $dstBytes = (Get-ChildItem -LiteralPath $dataRoot -Recurse -File -ErrorAction SilentlyContinue |
                                Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                            if ($dstBytes -and $srcBytes -gt 0) {
                                $pct = [math]::Min(98, 10 + [int](88 * $dstBytes / $srcBytes))
                                JProgress 'dism' $pct
                            }
                        } catch { }
                    }

                    $robOutput = Receive-Job -Job $robJob
                    $robExit   = $robOutput | Select-Object -Last 1
                    Remove-Job -Job $robJob -Force

                    if ($robExit -ge 8) {
                        throw "robocopy failed (exit $robExit) copying WIM contents to data partition $dataRoot"
                    }
                    J @{ event='log'; disk=$DiskNumber; message="wim-mount: robocopy complete (exit $robExit)" }
                    if ($Layout -eq 'Single') {
                        # Split from the mounted WIM before the finally block unmounts it.
                        Invoke-LWSplitForFat32 -SourceSourcesDir (Join-Path $mountDir 'sources') -DestSourcesDir (Join-Path $dataRoot 'sources') -Disk $DiskNumber -ProgressPhase 'dism'
                    }
                    JProgress 'dism' 100

                } finally {
                    J @{ event='log'; disk=$DiskNumber; message='wim-mount: unmounting WIM and cleaning up temp files' }
                    & dism.exe /Unmount-Image /MountDir:"$mountDir" /Discard 2>&1 | Out-Null
                    Remove-Item -LiteralPath $wimWorkDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            # SetupConfig.ini on data partition
            try {
                $dataSourcesDir = Join-Path $dataRoot 'sources'
                if (Test-Path -LiteralPath $dataSourcesDir) {
                    @('[SetupConfig]','BitLocker=AlwaysSuspend','NoReboot','ShowOOBE=None',
                      'Quiet','BypassNRO=1','[Compat]','IgnoreWarning=1') |
                        Set-Content -LiteralPath (Join-Path $dataSourcesDir 'SetupConfig.ini') -Encoding ascii -Force
                }
            } catch {
                J @{ event='log'; disk=$DiskNumber; message="SetupConfig.ini write skipped (non-fatal): $($_.Exception.Message)" }
            }

            # Re-acquire both drive letters - USB controllers can re-enumerate during the long
            # DISM/robocopy data write, causing the original $espRoot to point to a stale letter.
            $espRoot  = ($esp  | Get-Volume).DriveLetter + ':\'
            $dataRoot = ($data | Get-Volume).DriveLetter + ':\'

            # -- Populate ESP boot files from data partition (WIM mode) or ISO drive (ISO mode) ------
            # In WIM mode espCache contains only sources\SetupConfig.ini because Build-Cache excluded
            # the staging WIM and the staging dir had no other boot files.  DISM applied the full ISO
            # tree to the data partition, so copy boot files from there to make the ESP bootable.
            # In ISO mode the earlier ESP copy may have already placed boot.wim on the ESP; only
            # fall back to the mounted ISO drive if boot.wim is still missing.
            $skipDirs = @('System Volume Information', '$RECYCLE.BIN', '$Recycle.Bin', 'RECYCLER', 'FirstBase-UsbLogs', 'FirstBase-Logs', 'LW_LOGS')
            if ([string]::IsNullOrEmpty($IsoDrive)) {
                # WIM mode: populate ESP from data partition
                J @{ event='log'; disk=$DiskNumber; message='esp-populate: copying boot files from data partition to ESP (WIM mode)' }
                $espSourcesDir2 = Join-Path $espRoot 'sources'
                New-Item -ItemType Directory -Force -Path $espSourcesDir2 -ErrorAction SilentlyContinue | Out-Null

                foreach ($epItem in (Get-ChildItem -LiteralPath $dataRoot -Force -ErrorAction SilentlyContinue)) {
                    if ($epItem.Name -ieq 'sources') { continue }
                    if ($epItem.PSIsContainer -and $skipDirs -contains $epItem.Name) { continue }
                    if (-not $epItem.PSIsContainer -and $epItem.Name -match '\.(wim|esd|swm)$') { continue }
                    $epDst = Join-Path $espRoot $epItem.Name
                    if ($epItem.PSIsContainer) {
                        Copy-Item -LiteralPath $epItem.FullName -Destination $epDst -Recurse -Force -ErrorAction SilentlyContinue
                    } else {
                        Copy-Item -LiteralPath $epItem.FullName -Destination $epDst -Force -ErrorAction SilentlyContinue
                    }
                }
                # Only copy *.sdi from the data partition's sources\ - NOT boot.wim.
                # The injected boot.wim was already placed on the ESP from the ESP cache
                # (line ~649). Copying boot.wim from the data partition here would
                # overwrite it with the stock/uninjected copy that DISM restored, which
                # causes WinPE to boot into the Windows Setup language-selection screen.
                $dataSrcDir = Join-Path $dataRoot 'sources'
                if (Test-Path -LiteralPath $dataSrcDir) {
                    foreach ($f in (Get-ChildItem -LiteralPath $dataSrcDir -File -Force -ErrorAction SilentlyContinue)) {
                        if ($f.Name -match '\.sdi$') {
                            Copy-Item -LiteralPath $f.FullName -Destination $espSourcesDir2 -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                J @{ event='log'; disk=$DiskNumber; message='esp-populate: SDI boot files copied from data partition to ESP (boot.wim retained from ESP cache)' }
                # Synthesise bootmgfw after WIM-mode populate (staging often omits it)
                $bootmgfwDstP = Join-Path $espRoot 'efi\microsoft\boot\bootmgfw.efi'
                if (-not (Test-Path -LiteralPath $bootmgfwDstP)) {
                    $bootmgfwSrcP = Join-Path $espRoot 'efi\boot\bootx64.efi'
                    if (Test-Path -LiteralPath $bootmgfwSrcP) {
                        New-Item -ItemType Directory -Force -Path (Split-Path $bootmgfwDstP -Parent) -ErrorAction SilentlyContinue | Out-Null
                        Copy-Item -LiteralPath $bootmgfwSrcP -Destination $bootmgfwDstP -Force
                        J @{ event='log'; disk=$DiskNumber; message='esp-populate: synthesised efi\microsoft\boot\bootmgfw.efi from efi\boot\bootx64.efi (WIM mode)' }
                    }
                }
            } else {
                # ISO mode: fall back to ISO drive if boot.wim is missing from ESP
                $espBootWimCheck = Join-Path $espRoot 'sources\boot.wim'
                if (-not (Test-Path -LiteralPath $espBootWimCheck)) {
                    J @{ event='log'; disk=$DiskNumber; message='esp-populate: boot.wim missing from ESP; copying from ISO drive (ISO mode)' }
                    $espSourcesDir2 = Join-Path $espRoot 'sources'
                    New-Item -ItemType Directory -Force -Path $espSourcesDir2 -ErrorAction SilentlyContinue | Out-Null

                    foreach ($epItem in (Get-ChildItem -LiteralPath "$IsoDrive\" -Force -ErrorAction SilentlyContinue)) {
                        if ($epItem.Name -ieq 'sources') { continue }
                        if ($epItem.PSIsContainer -and $skipDirs -contains $epItem.Name) { continue }
                        if (-not $epItem.PSIsContainer -and $epItem.Name -match '\.(wim|esd|swm)$') { continue }
                        $epDst = Join-Path $espRoot $epItem.Name
                        if ($epItem.PSIsContainer) {
                            Copy-Item -LiteralPath $epItem.FullName -Destination $epDst -Recurse -Force -ErrorAction SilentlyContinue
                        } else {
                            Copy-Item -LiteralPath $epItem.FullName -Destination $epDst -Force -ErrorAction SilentlyContinue
                        }
                    }
                    $isoSrcDir = Join-Path $IsoDrive 'sources'
                    if (Test-Path -LiteralPath $isoSrcDir) {
                        foreach ($f in (Get-ChildItem -LiteralPath $isoSrcDir -File -Force -ErrorAction SilentlyContinue)) {
                            if ($f.Name -ieq 'boot.wim' -or $f.Name -match '\.sdi$') {
                                Copy-Item -LiteralPath $f.FullName -Destination $espSourcesDir2 -Force -ErrorAction SilentlyContinue
                            }
                        }
                    }
                    J @{ event='log'; disk=$DiskNumber; message='esp-populate: boot files copied from ISO drive to ESP' }
                }
            }

            # Full-build data/ESP populate complete — continue into WinPE/overlay/BCD below.
        }

        # ---------------------------------------------------------------------
        # Post-data steps (formerly Phase 2) — run in this job so Disk A can
        # inject WinPE while Disk B is still in DISM. Injects only THIS USB's
        # ESP sources\boot.wim (never a shared cache WIM).
        # ---------------------------------------------------------------------

        # Re-acquire partition roots — USB controllers can re-enumerate during
        # the long DISM/robocopy, causing cached drive letters to go stale.
        if (-not $OverlayOnly) {
            $espRoot  = $null
            $dataRoot = $null
            $parts    = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
            foreach ($p in $parts) {
                try {
                    $v = $p | Get-Volume -ErrorAction SilentlyContinue
                    if ($v -and $v.DriveLetter) {
                        if ($p.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') { $espRoot  = $v.DriveLetter + ':\' }
                        if ($p.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}') { $dataRoot = $v.DriveLetter + ':\' }
                    }
                } catch { }
            }
            if ($Layout -eq 'Single') {
                # Single layout has one FAT32 Basic-Data volume that is both boot and data.
                if (-not $dataRoot) {
                    throw "Could not locate the single FAT32 volume on disk $DiskNumber (dataRoot='$dataRoot')"
                }
                $espRoot = $dataRoot
            } elseif (-not $espRoot -or -not $dataRoot) {
                throw "Could not locate ESP or data partition on disk $DiskNumber (espRoot='$espRoot' dataRoot='$dataRoot')"
            }
        }

        # -- WinPE injection: per-USB ESP boot.wim only (parallel-safe) --------
        # Each job mounts a different path (E:\sources\boot.wim vs F:\...).
        # Do NOT inject the shared ESP cache here — that stays main-thread only.
        if (-not $OverlayOnly -and $espRoot) {
            JPhase 'winpe-inject'
            $espBootWim  = Join-Path $espRoot 'sources\boot.wim'
            # Prefer StartnetForInjection (ContentRoot\Deploy\WinPE-Startnet.cmd) so ISO /
            # direct-overlay builds work without a local OverlayCache stage. Fall back to
            # OverlayCache only when a WIM-mode EspCache build still populated it.
            $startnetSrc = if (-not [string]::IsNullOrWhiteSpace($StartnetForInjection) -and (Test-Path -LiteralPath $StartnetForInjection)) {
                $StartnetForInjection
            } elseif (-not [string]::IsNullOrWhiteSpace($OverlayCache) -and (Test-Path -LiteralPath (Join-Path $OverlayCache 'Deploy\WinPE-Startnet.cmd'))) {
                Join-Path $OverlayCache 'Deploy\WinPE-Startnet.cmd'
            } else {
                Join-Path $ContentRoot 'Deploy\WinPE-Startnet.cmd'
            }

            if (-not (Test-Path -LiteralPath $espBootWim)) {
                J @{ event='log'; disk=$DiskNumber; message='startnet-inject: boot.wim not found on ESP - WinPE will NOT auto-launch TechInstall.cmd' }
            } elseif (-not (Test-Path -LiteralPath $startnetSrc)) {
                J @{ event='log'; disk=$DiskNumber; message="startnet-inject: WinPE-Startnet.cmd not found at '$startnetSrc' - WinPE will NOT auto-launch TechInstall.cmd" }
            } else {
                try { Set-ItemProperty -LiteralPath $espBootWim -Name IsReadOnly -Value $false -ErrorAction Stop } catch { }

                $_skipPeInject = $false
                # ISO mode (Architecture B) copies stock boot.wim from the mounted ISO per disk and
                # skips the ESP cache entirely, so a stale EspCache sentinel must NOT suppress
                # per-disk injection — that was the 5.0.18 regression (language-selection screen).
                if ([string]::IsNullOrEmpty($IsoDrive)) {
                    $_espSentinel  = Join-Path $EspCache 'sources\boot.wim.lw-injected'
                    if ((Test-Path -LiteralPath $_espSentinel) -and (Test-Path -LiteralPath $startnetSrc)) {
                        $_sentHash = (Get-Content -LiteralPath $_espSentinel -Raw -ErrorAction SilentlyContinue).Trim()
                        $_curHash  = (Get-FileHash -LiteralPath $startnetSrc -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
                        if ($_sentHash -and $_curHash -and $_sentHash -eq $_curHash) {
                            J @{ event='log'; disk=$DiskNumber; message='startnet-inject: boot.wim pre-injected via cache sentinel - skipping per-disk DISM injection' }
                            $_skipPeInject = $true
                        }
                    }
                } else {
                    J @{ event='log'; disk=$DiskNumber; message='startnet-inject: ISO mode - stock boot.wim requires per-disk DISM injection' }
                }

                if (-not $_skipPeInject) {
                    foreach ($peIdx in 1, 2) {
                        $peMountDir       = Join-Path $env:TEMP "LWPEMount_${DiskNumber}_${peIdx}"
                        $peIsMounted      = $false
                        $_peWinjBase      = if ($peIdx -eq 1) { 0 } else { 50 }
                        $_peWinjInitPct   = if ($peIdx -eq 1) { 5 } else { 52 }
                        $_peWinjCommitPct = if ($peIdx -eq 1) { 50 } else { 95 }
                        $_peWinjOcStep    = 0
                        try {
                            New-Item -ItemType Directory -Force -Path $peMountDir | Out-Null
                            JProgress 'winpe-inject' $_peWinjInitPct
                            J @{ event='log'; disk=$DiskNumber; message="startnet-inject: mounting boot.wim index $peIdx at $peMountDir ..." }

                            # Defensively discard any mount already registered against this
                            # boot.wim (this run's or a leftover from an earlier crashed build)
                            # before mounting - DISM permits only one read-write mount per WIM.
                            Clear-StaleWimMountLocal -WimPath $espBootWim | Out-Null

                            # Retry with backoff: mounting a different index of the same WIM
                            # right after another index was unmounted can transiently fail with
                            # 0xc1420127 ("already mounted for read/write access") if DISM's
                            # mount registry has not caught up yet.
                            $__mountAttempt = 0
                            $__mountMax     = 3
                            do {
                                $__mountAttempt++
                                $mOut = & dism.exe /Mount-Image /ImageFile:"$espBootWim" /Index:$peIdx /MountDir:"$peMountDir" 2>&1
                                if ($LASTEXITCODE -eq 0) { break }
                                if ($__mountAttempt -ge $__mountMax) {
                                    throw "DISM /Mount-Image (index $peIdx) failed (exit $LASTEXITCODE): $($mOut -join ' | ')"
                                }
                                J @{ event='log'; disk=$DiskNumber; message="startnet-inject: /Mount-Image (index $peIdx) attempt $__mountAttempt failed (exit $LASTEXITCODE) - clearing stale mounts and retrying in 2s ..." }
                                Clear-StaleWimMountLocal -WimPath $espBootWim | Out-Null
                                Start-Sleep -Seconds 2
                            } while ($__mountAttempt -lt $__mountMax)
                            $peIsMounted = $true

                            $sysCmdTarget = Join-Path $peMountDir 'Windows\System32\startnet.cmd'
                            Copy-Item -LiteralPath $startnetSrc -Destination $sysCmdTarget -Force
                            J @{ event='log'; disk=$DiskNumber; message="startnet-inject: startnet.cmd written (index $peIdx) ..." }

                            # Inject the UEFI pre-flight helper alongside startnet.cmd (mirrors
                            # Build-UsbStick.ps1 Invoke-TiPatchBootWim). startnet.cmd looks for it at
                            # X:\Windows\System32\Invoke-FbUefiPreflight.ps1; without this copy the
                            # pre-flight (Secure Boot / RAID) check is silently skipped at boot.
                            # Source from ContentRoot\Deploy (NOT $startnetSrc): the overlay cache's
                            # Deploy\ copy set does not include Invoke-FbUefiPreflight.ps1, but the
                            # bundled payload (ContentRoot) always does.
                            $pePreflightSrc = Join-Path $ContentRoot 'Deploy\Invoke-FbUefiPreflight.ps1'
                            if (Test-Path -LiteralPath $pePreflightSrc) {
                                Copy-Item -LiteralPath $pePreflightSrc -Destination (Join-Path $peMountDir 'Windows\System32\Invoke-FbUefiPreflight.ps1') -Force
                                J @{ event='log'; disk=$DiskNumber; message="startnet-inject: Invoke-FbUefiPreflight.ps1 written (index $peIdx) ..." }
                            } else {
                                J @{ event='log'; disk=$DiskNumber; message="startnet-inject: Invoke-FbUefiPreflight.ps1 not found at '$pePreflightSrc' (index $peIdx) - preflight will be skipped at boot" }
                            }

                            $peWinpeshlPath = Join-Path $peMountDir 'Windows\System32\winpeshl.ini'
                            Set-ItemProperty -LiteralPath $peWinpeshlPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                            [System.IO.File]::WriteAllText($peWinpeshlPath, "[LaunchApps]`r`ncmd.exe, /c X:\Windows\System32\startnet.cmd`r`n", [System.Text.Encoding]::ASCII)
                            J @{ event='log'; disk=$DiskNumber; message="startnet-inject: winpeshl.ini set to launch startnet.cmd (index $peIdx, setup.exe suppressed) ..." }

                            # WinPE PowerShell OCs: STRICT dependency order, base cab
                            # immediately followed by its en-us language cab. All 8 cabs
                            # are REQUIRED - PowerShell in WinPE cannot start without the
                            # matching _en-us language resources. Any missing cab or any
                            # /Add-Package failure is FATAL for this disk (re-thrown below
                            # so the disk is marked failed) rather than silently shipping a
                            # broken / PowerShell-less WinPE.
                            if (-not ($WpeOcStaging -and (Test-Path -LiteralPath $WpeOcStaging))) {
                                throw "FATAL: WinPE-OCs not found at '$WpeOcStaging' - cannot add PowerShell to WinPE (disk $DiskNumber). Stage the WinPE OC cabs in the per-architecture subfolder on the share."
                            }
                            $peOcGroups = @(
                                @{ base = 'WinPE-WMI.cab';        lang = 'WinPE-WMI_en-us.cab' },
                                @{ base = 'WinPE-NetFx.cab';      lang = 'WinPE-NetFx_en-us.cab' },
                                @{ base = 'WinPE-Scripting.cab';  lang = 'WinPE-Scripting_en-us.cab' },
                                @{ base = 'WinPE-PowerShell.cab'; lang = 'WinPE-PowerShell_en-us.cab' })
                            foreach ($peOc in $peOcGroups) {
                                foreach ($pkg in @($peOc.base, $peOc.lang)) {
                                    $cabFile = Join-Path $WpeOcStaging $pkg
                                    if (-not (Test-Path -LiteralPath $cabFile)) { $cabFile = Join-Path (Join-Path $WpeOcStaging 'en-us') $pkg }
                                    if (-not (Test-Path -LiteralPath $cabFile)) {
                                        throw "FATAL: required WinPE OC cab '$pkg' missing under '$WpeOcStaging' (disk $DiskNumber). OPERATOR ACTION: copy it into the arch subfolder '$WpeOcStaging' and re-run a Full Rebuild."
                                    }
                                    J @{ event='log'; disk=$DiskNumber; message="startnet-inject: adding $pkg to boot.wim index $peIdx (disk $DiskNumber) ..." }
                                    & dism.exe /Image:"$peMountDir" /Add-Package /PackagePath:"$cabFile" /Quiet 2>&1 | Out-Null
                                    if ($LASTEXITCODE -ne 0) {
                                        throw "FATAL: startnet-inject: $pkg /Add-Package failed (exit $LASTEXITCODE) on boot.wim index $peIdx (disk $DiskNumber)"
                                    }
                                }
                                $_peWinjOcStep += 10
                                JProgress 'winpe-inject' ($_peWinjBase + $_peWinjOcStep)
                            }

                            $peShellCheck = Join-Path $peMountDir 'Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
                            if (-not (Test-Path -LiteralPath $peShellCheck)) {
                                throw "FATAL: powershell.exe NOT present in boot.wim index $peIdx after adding WinPE OCs (disk $DiskNumber) - refusing to ship a PowerShell-less WinPE"
                            }
                            J @{ event='log'; disk=$DiskNumber; message="startnet-inject: PowerShell verified present in WinPE (index $peIdx, disk $DiskNumber)" }

                            J @{ event='log'; disk=$DiskNumber; message="startnet-inject: committing boot.wim index $peIdx (disk $DiskNumber) ..." }
                            $uOut = & dism.exe /Unmount-Image /MountDir:"$peMountDir" /Commit 2>&1
                            if ($LASTEXITCODE -ne 0) {
                                throw "DISM /Unmount-Image /Commit (index $peIdx) failed (exit $LASTEXITCODE): $($uOut -join ' | ')"
                            }
                            $peIsMounted = $false
                            # /Unmount-Image can report success before the WIMMount filter
                            # driver has actually released its lock on the file. Poll
                            # (read-only, up to ~5s) so the next index's /Mount-Image does not
                            # race the driver and fail with 0xc1420127.
                            $__unmountWaitTries = 0
                            while ($__unmountWaitTries -lt 10 -and (Test-WimMountedLocal -WimPath $espBootWim).Count -gt 0) {
                                Start-Sleep -Milliseconds 500
                                $__unmountWaitTries++
                            }
                            J @{ event='log'; disk=$DiskNumber; message="startnet-inject: boot.wim index $peIdx committed - WinPE will auto-launch TechInstall.cmd (disk $DiskNumber)" }
                            JProgress 'winpe-inject' $_peWinjCommitPct
                        } catch {
                            $__peMsg = $_.Exception.Message
                            if ($__peMsg -like 'FATAL:*' -or -not [string]::IsNullOrEmpty($IsoDrive)) {
                                # Mandatory dependency failure, or ISO mode where stock boot.wim was
                                # just placed on the ESP — any injection failure must abort this disk.
                                J @{ event='log'; disk=$DiskNumber; message="ERROR: startnet-inject FAILED (index $peIdx) - $__peMsg" }
                                if ($peIsMounted) {
                                    & dism.exe /Unmount-Image /MountDir:"$peMountDir" /Discard 2>&1 | Out-Null
                                    $peIsMounted = $false
                                }
                                Remove-Item -LiteralPath $peMountDir -Recurse -Force -ErrorAction SilentlyContinue
                                throw
                            }
                            J @{ event='log'; disk=$DiskNumber; message="WARNING: startnet-inject FAILED (index $peIdx) - $__peMsg" }
                            J @{ event='log'; disk=$DiskNumber; message='WARNING: WinPE may NOT auto-launch TechInstall.cmd; USB boots to PE command prompt' }
                        } finally {
                            if ($peIsMounted) {
                                J @{ event='log'; disk=$DiskNumber; message="startnet-inject: discarding uncommitted WIM mount (index $peIdx, cleanup) ..." }
                                & dism.exe /Unmount-Image /MountDir:"$peMountDir" /Discard 2>&1 | Out-Null
                            }
                            Remove-Item -LiteralPath $peMountDir -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                J @{ event='log'; disk=$DiskNumber; message='startnet-inject: complete' }
                JProgress 'winpe-inject' 100
            }
        }

        # -- Overlay copy (both full and overlay-only modes) -------------------
        # USB-bound overlay goes DIRECT to the stick from ContentRoot (or from a
        # pre-built OverlayCache when a non-ISO EspCache build still populated one).
        # No local temp stage of overlay files for ISO / PreferIso / OverlayOnly.
        if (-not $OverlayOnly) { JPhase 'overlay' }
        # In Single layout $espRoot and $dataRoot are the SAME volume - dedupe so the
        # overlay is not copied (and the layout marker not written) twice onto one volume.
        $overlayPartRoots = @($espRoot, $dataRoot) | Where-Object { $_ } | Select-Object -Unique

        $useOverlayCache = (-not [string]::IsNullOrWhiteSpace($OverlayCache)) -and
            (Test-Path -LiteralPath $OverlayCache) -and
            (@(Get-ChildItem -LiteralPath $OverlayCache -Force -ErrorAction SilentlyContinue).Count -gt 0)

        foreach ($partRoot in $overlayPartRoots) {
            # Quick Update / destage: wipe prior USB logs, keep a visible empty FirstBase-Logs.
            # Full rebuild is already blank after format; this still creates the folder.
            Reset-LwUsbLogFolder -VolRoot $partRoot -ClearContents:$OverlayOnly
            if ($OverlayOnly) {
                $null = Get-Item -LiteralPath (Join-Path $partRoot 'FirstBase') -Force -ErrorAction SilentlyContinue
            }
            if ($useOverlayCache) {
                foreach ($item in (Get-ChildItem -LiteralPath $OverlayCache -Force -ErrorAction SilentlyContinue)) {
                    $dst = Join-Path $partRoot $item.Name
                    if ($item.PSIsContainer) {
                        if (-not (Test-Path -LiteralPath $dst)) {
                            New-Item -ItemType Directory -Path $dst -Force | Out-Null
                        }
                        Copy-Item -Path (Join-Path $item.FullName '*') -Destination $dst -Recurse -Force
                    } else {
                        Copy-Item -LiteralPath $item.FullName -Destination $dst -Force
                    }
                }
                if (-not $NoPayload -and -not $QuickInstall) {
                    $loopSrc = Join-Path $OverlayCache 'FirstBase\WUPayload\Invoke-WindowsUpdateLoop.ps1'
                    if (-not (Test-Path -LiteralPath $loopSrc)) { $loopSrc = Join-Path $ContentRoot 'Invoke-WindowsUpdateLoop.ps1' }
                    Assert-LoopCopyLocal -Src $loopSrc -Dst (Join-Path $partRoot 'FirstBase\WUPayload\Invoke-WindowsUpdateLoop.ps1')
                }
            } else {
                # Direct ContentRoot → USB (deprecated local overlay temp stage).
                if (-not $NoPayload -and -not $QuickInstall) {
                    New-Item -ItemType Directory -Force -Path (Join-Path $partRoot 'FirstBase\Deploy'), (Join-Path $partRoot 'FirstBase\Policy'), (Join-Path $partRoot 'FirstBase\Scripts'), (Join-Path $partRoot 'FirstBase\WUPayload'), (Join-Path $partRoot 'FirstBase\WUPayload\Tools') | Out-Null
                    $overlayMap = @(
                        @{ Src = (Join-Path $ContentRoot 'Deploy\TechInstall.cmd');                       Dst = 'FirstBase\Deploy\TechInstall.cmd' },
                        @{ Src = (Join-Path $ContentRoot 'Deploy\disksetup.cmd');                         Dst = 'FirstBase\Deploy\disksetup.cmd' },
                        @{ Src = (Join-Path $ContentRoot 'Deploy\Invoke-FirstBaseRaidProbe.ps1');         Dst = 'FirstBase\Deploy\Invoke-FirstBaseRaidProbe.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'Deploy\WinPE-Startnet.cmd');                    Dst = 'FirstBase\Deploy\WinPE-Startnet.cmd' },
                        @{ Src = (Join-Path $ContentRoot 'Deploy\Show-DeployBanner.ps1');                 Dst = 'FirstBase\Deploy\Show-DeployBanner.ps1' },
            @{ Src = (Join-Path $ContentRoot 'Deploy\Invoke-FbDeployUi.ps1');                 Dst = 'FirstBase\Deploy\Invoke-FbDeployUi.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseBuildIdentity.ps1');                   Dst = 'FirstBase\Deploy\FirstBaseBuildIdentity.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'Scripts\Invoke-FirstBaseDismApply.ps1');        Dst = 'FirstBase\Scripts\Invoke-FirstBaseDismApply.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'Policy\autounattend.xml');                      Dst = 'FirstBase\Autounattend.xml' },
                        @{ Src = (Join-Path $ContentRoot 'Policy\autounattend.xml');                      Dst = 'FirstBase\Policy\Autounattend.xml' },
                        @{ Src = (Join-Path $ContentRoot 'SetupComplete.cmd');                            Dst = 'FirstBase\WUPayload\SetupComplete.cmd' },
                        @{ Src = (Join-Path $ContentRoot 'Invoke-WindowsUpdateLoop.ps1');                 Dst = 'FirstBase\WUPayload\Invoke-WindowsUpdateLoop.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'Tools\fb-dump.ps1');                             Dst = 'FirstBase\WUPayload\Tools\fb-dump.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'Tools\fb-im.cmd');                               Dst = 'fb-im.cmd' },
                        @{ Src = (Join-Path $ContentRoot 'Tools\fb-im.ps1');                               Dst = 'FirstBase\WUPayload\Tools\fb-im.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseDebugHotkeyWatcher.ps1');              Dst = 'FirstBase\WUPayload\FirstBaseDebugHotkeyWatcher.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseDeferredOobeSound.ps1');               Dst = 'FirstBase\WUPayload\FirstBaseDeferredOobeSound.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseHandoffSplash.ps1');                   Dst = 'FirstBase\WUPayload\FirstBaseHandoffSplash.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseOobeDeferredSoundBootstrap.ps1');      Dst = 'FirstBase\WUPayload\FirstBaseOobeDeferredSoundBootstrap.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseOobeOperatorFinalize.ps1');            Dst = 'FirstBase\WUPayload\FirstBaseOobeOperatorFinalize.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseOpenSettingsAndFinish.ps1');           Dst = 'FirstBase\WUPayload\FirstBaseOpenSettingsAndFinish.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseHardwareCheck.ps1');                   Dst = 'FirstBase\WUPayload\FirstBaseHardwareCheck.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBasePostSysprepOobeSoundArm.ps1');         Dst = 'FirstBase\WUPayload\FirstBasePostSysprepOobeSoundArm.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseShowSplash.ps1');                      Dst = 'FirstBase\WUPayload\FirstBaseShowSplash.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseSplashSingleInstance.ps1');            Dst = 'FirstBase\WUPayload\FirstBaseSplashSingleInstance.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseSplashWatcher.ps1');                   Dst = 'FirstBase\WUPayload\FirstBaseSplashWatcher.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseVersion.cmd');                         Dst = 'FirstBase\WUPayload\FirstBaseVersion.cmd' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseVersion.ps1');                         Dst = 'FirstBase\WUPayload\FirstBaseVersion.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseBuildIdentity.ps1');                   Dst = 'FirstBase\WUPayload\FirstBaseBuildIdentity.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBaseWuEngine.ps1');                        Dst = 'FirstBase\WUPayload\FirstBaseWuEngine.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'Show-UpdateProgress.ps1');                      Dst = 'FirstBase\WUPayload\Show-UpdateProgress.ps1' },
            @{ Src = (Join-Path $ContentRoot 'FirstBaseSplashTechMenu.ps1');                  Dst = 'FirstBase\WUPayload\FirstBaseSplashTechMenu.ps1' },
                        @{ Src = (Join-Path $ContentRoot 'Tools\seal_command.txt');                       Dst = 'FirstBase\WUPayload\Tools\seal_command.txt' },
                        @{ Src = (Join-Path $ContentRoot 'FirstBase.ico');                                Dst = 'FirstBase\FirstBase.ico' },
                        @{ Src = (Join-Path $ContentRoot 'Deploy\Fonts\cascadiamono.ttf');                 Dst = 'FirstBase\Deploy\Fonts\cascadiamono.ttf' }
                    )
                    foreach ($o in $overlayMap) {
                        if (Test-Path -LiteralPath $o.Src) {
                            $dstPath = Join-Path $partRoot $o.Dst
                            $dstParent = Split-Path -Parent $dstPath
                            if (-not (Test-Path -LiteralPath $dstParent)) {
                                New-Item -ItemType Directory -Force -Path $dstParent | Out-Null
                            }
                            Copy-Item -LiteralPath $o.Src -Destination $dstPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                    if (-not $NoPayload -and -not $QuickInstall) {
                        Assert-LoopCopyLocal -Src (Join-Path $ContentRoot 'Invoke-WindowsUpdateLoop.ps1') -Dst (Join-Path $partRoot 'FirstBase\WUPayload\Invoke-WindowsUpdateLoop.ps1')
                    }
                    $scriptsSrc = Join-Path $ContentRoot 'Scripts'
                    if (Test-Path -LiteralPath $scriptsSrc) {
                        $scriptsDst = Join-Path $partRoot 'FirstBase\Scripts'
                        New-Item -ItemType Directory -Path $scriptsDst -Force | Out-Null
                        Copy-Item -Path (Join-Path $scriptsSrc '*') -Destination $scriptsDst -Recurse -Force -ErrorAction SilentlyContinue
                    }
                } else {
                    # WIN-INSTALL / QUICK-INSTALL: same TechInstall architecture, minimal set.
                    New-Item -ItemType Directory -Force -Path (Join-Path $partRoot 'FirstBase\Policy'), (Join-Path $partRoot 'FirstBase\Deploy'), (Join-Path $partRoot 'FirstBase\WUPayload\Tools') | Out-Null
                    $autounattendInstallSrc = if ($QuickInstall) { Join-Path $ContentRoot 'Policy\autounattend-quickinstall.xml' } else { Join-Path $ContentRoot 'Policy\autounattend-install.xml' }
                    $autounattendSrc = if (Test-Path -LiteralPath $autounattendInstallSrc) { $autounattendInstallSrc } else { Join-Path $ContentRoot 'Policy\autounattend.xml' }
                    if (Test-Path -LiteralPath $autounattendSrc) {
                        Copy-Item -LiteralPath $autounattendSrc -Destination (Join-Path $partRoot 'FirstBase\Autounattend.xml') -Force
                        Copy-Item -LiteralPath $autounattendSrc -Destination (Join-Path $partRoot 'FirstBase\Policy\Autounattend.xml') -Force
                    }
                    $techInstallInstallSrc = if ($QuickInstall) { Join-Path $ContentRoot 'Deploy\TechInstall-QuickInstall.cmd' } else { Join-Path $ContentRoot 'Deploy\TechInstall-Install.cmd' }
                    if (Test-Path -LiteralPath $techInstallInstallSrc) {
                        Copy-Item -LiteralPath $techInstallInstallSrc -Destination (Join-Path $partRoot 'FirstBase\Deploy\TechInstall.cmd') -Force
                    }
                    $winpeStartnetSrc = Join-Path $ContentRoot 'Deploy\WinPE-Startnet.cmd'
                    if (Test-Path -LiteralPath $winpeStartnetSrc) {
                        Copy-Item -LiteralPath $winpeStartnetSrc -Destination (Join-Path $partRoot 'FirstBase\Deploy\WinPE-Startnet.cmd') -Force
                    }
                    $bannerSrc = Join-Path $ContentRoot 'Deploy\Show-DeployBanner.ps1'
                    if (Test-Path -LiteralPath $bannerSrc) {
                        Copy-Item -LiteralPath $bannerSrc -Destination (Join-Path $partRoot 'FirstBase\Deploy\Show-DeployBanner.ps1') -Force
                    }
                    $deployUiSrc = Join-Path $ContentRoot 'Deploy\Invoke-FbDeployUi.ps1'
                    if (Test-Path -LiteralPath $deployUiSrc) {
                        Copy-Item -LiteralPath $deployUiSrc -Destination (Join-Path $partRoot 'FirstBase\Deploy\Invoke-FbDeployUi.ps1') -Force
                    }
                    $identitySrc = Join-Path $ContentRoot 'FirstBaseBuildIdentity.ps1'
                    if (Test-Path -LiteralPath $identitySrc) {
                        Copy-Item -LiteralPath $identitySrc -Destination (Join-Path $partRoot 'FirstBase\Deploy\FirstBaseBuildIdentity.ps1') -Force
                    }
                    $disksetupSrc = Join-Path $ContentRoot 'Deploy\disksetup.cmd'
                    if (Test-Path -LiteralPath $disksetupSrc) {
                        Copy-Item -LiteralPath $disksetupSrc -Destination (Join-Path $partRoot 'FirstBase\Deploy\disksetup.cmd') -Force
                    }
                    $dismApplySrc = Join-Path $ContentRoot 'Scripts\Invoke-FirstBaseDismApply.ps1'
                    if (Test-Path -LiteralPath $dismApplySrc) {
                        New-Item -ItemType Directory -Force -Path (Join-Path $partRoot 'FirstBase\Scripts') | Out-Null
                        Copy-Item -LiteralPath $dismApplySrc -Destination (Join-Path $partRoot 'FirstBase\Scripts\Invoke-FirstBaseDismApply.ps1') -Force
                    }
                    # fb-im front-end: cmd launcher stays at volume ROOT; PS backend + fb-dump backend under FirstBase\WUPayload\Tools\.
                    $imCmdSrc = Join-Path $ContentRoot 'Tools\fb-im.cmd'
                    if (Test-Path -LiteralPath $imCmdSrc) {
                        Copy-Item -LiteralPath $imCmdSrc -Destination (Join-Path $partRoot 'fb-im.cmd') -Force
                    }
                    $imPs1Src = Join-Path $ContentRoot 'Tools\fb-im.ps1'
                    if (Test-Path -LiteralPath $imPs1Src) {
                        Copy-Item -LiteralPath $imPs1Src -Destination (Join-Path $partRoot 'FirstBase\WUPayload\Tools\fb-im.ps1') -Force
                    }
                    $dumpPs1Src = Join-Path $ContentRoot 'Tools\fb-dump.ps1'
                    if (Test-Path -LiteralPath $dumpPs1Src) {
                        Copy-Item -LiteralPath $dumpPs1Src -Destination (Join-Path $partRoot 'FirstBase\WUPayload\Tools\fb-dump.ps1') -Force
                    }
                    $icoSrc = Join-Path $ContentRoot 'FirstBase.ico'
                    if (Test-Path -LiteralPath $icoSrc) {
                        Copy-Item -LiteralPath $icoSrc -Destination (Join-Path $partRoot 'FirstBase\FirstBase.ico') -Force
                    }
                    Copy-LwPeBrailleFont -OverlayRoot $partRoot
                }
                J @{ event='log'; disk=$DiskNumber; message='overlay: copied deploy files directly from ContentRoot to USB (no local overlay temp stage)' }
            }
            $logDir = Join-Path $partRoot 'FirstBase-Logs'
            if (-not (Test-Path -LiteralPath $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            @("Layout=$Layout",'Builder=Invoke-LoneWolfBuild.ps1') |
                Set-Content -LiteralPath (Join-Path $logDir 'FirstBase-Layout.txt') -Encoding ascii -Force
            Write-LwUsbExplorerChrome -VolRoot $partRoot -IcoSrc (Join-Path $ContentRoot 'FirstBase.ico')
        }

        # -- Hide Windows install media at volume root; hide FirstBase; keep fb-im.cmd visible --
        if ($dataRoot) {
            try {
                foreach ($bootItem in @('boot', 'boot.disabled', 'bootmgr', 'bootmgr.efi', 'bootmgr.disabled', 'bootmgr.efi.disabled', 'setup.exe', 'setup.exe.disabled', 'autorun.inf', 'autorun.inf.disabled', 'sources', 'sources.disabled', 'efi', 'EFI', 'efi.disabled', 'EFI.disabled', 'support', 'Support', 'support.disabled', 'Support.disabled')) {
                    $bootPath = Join-Path $dataRoot $bootItem
                    if (Test-Path -LiteralPath $bootPath) {
                        & attrib.exe +H +S $bootPath /D /S 2>&1 | Out-Null
                    }
                }
                Write-LwUsbExplorerChrome -VolRoot $dataRoot -IcoSrc (Join-Path $ContentRoot 'FirstBase.ico')
                J @{ event='log'; disk=$DiskNumber; message='hid boot/media artifacts (+H +S); hid FirstBase (+H +S); staged autorun.inf icon; left fb-im.cmd visible' }
            } catch {
                J @{ event='log'; disk=$DiskNumber; message="WARNING: Could not set boot/media artifact attributes: $($_.Exception.Message)" }
            }
        }

        # -- Ensure bootmgfw.efi exists before BCD rebuild ---------------------
        if (-not $OverlayOnly -and $espRoot) {
            $p2Bootmgfw = Join-Path $espRoot 'efi\microsoft\boot\bootmgfw.efi'
            if (-not (Test-Path -LiteralPath $p2Bootmgfw)) {
                $p2Bootx64 = Join-Path $espRoot 'efi\boot\bootx64.efi'
                if (Test-Path -LiteralPath $p2Bootx64) {
                    New-Item -ItemType Directory -Force -Path (Split-Path $p2Bootmgfw -Parent) -ErrorAction SilentlyContinue | Out-Null
                    Copy-Item -LiteralPath $p2Bootx64 -Destination $p2Bootmgfw -Force
                    J @{ event='log'; disk=$DiskNumber; message='bcd-prep: synthesised efi\microsoft\boot\bootmgfw.efi from efi\boot\bootx64.efi' }
                } else {
                    throw "efi\microsoft\boot\bootmgfw.efi missing on ESP and efi\boot\bootx64.efi unavailable (USB will not boot)"
                }
            }
            $p2BootWim = Join-Path $espRoot 'sources\boot.wim'
            if (-not (Test-Path -LiteralPath $p2BootWim)) {
                throw "sources\boot.wim missing on ESP (USB will fail with missing winload.efi / 0xc0000098)"
            }
            $p2BootSdi = Join-Path $espRoot 'boot\boot.sdi'
            if (-not (Test-Path -LiteralPath $p2BootSdi)) {
                throw "boot\boot.sdi missing on ESP (ramdisk boot will fail)"
            }

            # -- Secure Boot invariant: signed loaders must be present + unmodified -----
            # Secure Boot validates the loader SIGNATURE, not the partition GPT type, so a
            # Single-layout FAT32 Basic-Data volume boots under Secure Boot as long as the
            # Microsoft-signed loaders copied verbatim from the ISO are present:
            #   \EFI\Boot\bootx64.efi          - removable-media fallback path (REQUIRED)
            #   \EFI\Microsoft\Boot\bootmgfw.efi - Windows Boot Manager (verified above)
            # These are copied byte-for-byte from the mounted ISO by the esp-copy phase and
            # are never re-generated or re-signed here. A missing bootx64.efi means firmware
            # cannot find a loader on removable media and the USB will not boot at all under
            # Secure Boot, so fail the build loudly rather than shipping unbootable media.
            $p2FallbackEfi = Join-Path $espRoot 'EFI\Boot\bootx64.efi'
            if (-not (Test-Path -LiteralPath $p2FallbackEfi)) {
                throw "SECURE BOOT: removable-media loader \EFI\Boot\bootx64.efi missing on volume $espRoot - USB will not boot under Secure Boot. Aborting (do NOT ship this media)."
            }
            $p2FallbackSize   = (Get-Item -LiteralPath $p2FallbackEfi).Length
            $p2BootmgfwSize   = (Get-Item -LiteralPath $p2Bootmgfw).Length
            J @{ event='log'; disk=$DiskNumber; message=("secure-boot: signed loaders verified present - \EFI\Boot\bootx64.efi ({0} bytes), \EFI\Microsoft\Boot\bootmgfw.efi ({1} bytes); copied verbatim from ISO (Secure Boot preserved)" -f $p2FallbackSize, $p2BootmgfwSize) }
        }

        # -- BCD: ship the ISO's own stock BCDs verbatim; NEVER rebuild or edit -----
        # HISTORY: 5.0.28 hand-authored a WinPE BCD from scratch (bcdedit /createstore
        # + /set calls); 5.0.29 tweaked the {bootmgr} device (locate -> boot); 5.0.30
        # copied the stock ISO BCD but still ran two 'bcdedit /store' tweaks (timeout 0
        # / displaybootmenu no) on it and kept a hand-authored fallback. ALL of that is
        # removed here.
        #
        # The proven reference builder (Windows_Installation\FirstBase Image Creation\
        # Builder\Build-UsbStick.ps1) NEVER touches the BCD: it robocopies the whole ISO
        # - including \efi\microsoft\boot\BCD (UEFI), \boot\BCD (BIOS) and \boot\boot.sdi
        # - and ships those stores byte-for-byte. The full-ISO copy above (no \boot
        # exclusion) now lands both stock BCDs + boot.sdi on the volume, so WinPE boots
        # exactly as stock removable install media does: {bootmgr} has NO device element
        # (firmware-provided load device), the loader is 'ramdisk=[boot]\sources\boot.wim,
        # {ramdiskoptions}', and [boot] resolves to the USB it was loaded from. That is
        # safe on a machine that already has Windows (no 'locate', no explicit partition)
        # and carries every element 25H2 winload requires. We only VERIFY the stock UEFI
        # store is present and fail loudly if not - we do NOT mutate it.
        if (-not $OverlayOnly -and $espRoot) {
            $uefiBcd = Join-Path $espRoot 'EFI\Microsoft\Boot\BCD'
            if (-not (Test-Path -LiteralPath $uefiBcd) -or ((Get-Item -LiteralPath $uefiBcd -ErrorAction SilentlyContinue).Length -le 0)) {
                throw "Stock UEFI BCD missing/empty at '$uefiBcd' after media copy - refusing to ship unbootable media. The ISO's \EFI\Microsoft\Boot\BCD must be copied verbatim (mirror Build-UsbStick.ps1); do NOT hand-author a store."
            }
            $biosBcd  = Join-Path $espRoot 'boot\BCD'
            $biosNote = if (Test-Path -LiteralPath $biosBcd) { 'BIOS \boot\BCD present' } else { 'BIOS \boot\BCD absent (UEFI-only boot unaffected)' }
            J @{ event='log'; disk=$DiskNumber; message=("bcd: shipping stock ISO BCD verbatim - NO bcdedit (mirrors Build-UsbStick.ps1); UEFI \EFI\Microsoft\Boot\BCD OK, {0}; ramdisk resolves via [boot]\sources\boot.wim + \boot\boot.sdi" -f $biosNote) }
        }

        # -- LoneWolf version stamp under FirstBase\ on data partition ---------
        if ($dataRoot) {
            try {
                $firstBaseDir = Join-Path $dataRoot 'FirstBase'
                if (-not (Test-Path -LiteralPath $firstBaseDir)) { New-Item -ItemType Directory -Force -Path $firstBaseDir | Out-Null }
                $stampImageDate = $ImageBuildDate
                if ($OverlayOnly) {
                    try {
                        $existingStampPath = Join-Path $dataRoot 'FirstBase\LW_VERSION.json'
                        if (Test-Path -LiteralPath $existingStampPath) {
                            $existingStamp = Get-Content -Raw -LiteralPath $existingStampPath | ConvertFrom-Json
                            if ($existingStamp.imageBuildDate) { $stampImageDate = [string]$existingStamp.imageBuildDate }
                            elseif ($existingStamp.wimBuildDate) { $stampImageDate = [string]$existingStamp.wimBuildDate }
                        }
                    } catch { }
                }
                $versionStamp = [ordered]@{
                    builtBy               = 'LoneWolfLauncher'
                    workflowType          = $WorkflowType
                    version               = $StagingVersion
                    scriptVersion         = $(if ($ScriptVersion) { $ScriptVersion } else { $StagingVersion })
                    payloadVersion        = $(if ($ScriptVersion) { $ScriptVersion } else { $StagingVersion })
                    builtAt               = (Get-Date -Format 'o')
                    diskNumber            = $DiskNumber
                    devBuild              = [bool]$DevBuild
                    launcherVersion       = $(if ($LauncherVersion) { $LauncherVersion } else { $null })
                    shareLauncherVersion  = $(if ($ShareLauncherVersion) { $ShareLauncherVersion } else { $null })
                    shareScriptVersion    = $(if ($ShareScriptVersion) { $ShareScriptVersion } else { $null })
                    imageBuildDate        = $(if ($stampImageDate) { $stampImageDate } else { $null })
                    wimBuildDate          = $(if ($stampImageDate) { $stampImageDate } else { $null })
                } | ConvertTo-Json -Compress
                $versionStamp | Out-File -FilePath (Join-Path $dataRoot 'FirstBase\LW_VERSION.json') -Encoding utf8 -Force
            } catch { }
        }

        J @{ event='done'; disk=$DiskNumber; success=$true }

    } catch {
        $msg = $_.Exception.Message
        J @{ event='error'; disk=$DiskNumber; message=$msg }
        J @{ event='done';  disk=$DiskNumber; success=$false; message=$msg }
        throw
    }
}

# --- Main execution -----------------------------------------------------------
try {
    # Shared WIM mount state (cleaned up in finally; init early so finally is always safe)
    $sharedWimWorkDir = ''
    $sharedWimMount   = ''

    # Emit init event so the UI knows exactly what the script received
    Emit @{
        event        = 'init'
        shareRoot    = $ShareRoot
        stagingRoot  = $StagingRoot
        contentRoot  = $ContentRoot
        workflowType = $WorkflowType
        diskNumbers  = @($requestedDisks)
        isoMode      = $false
        sequential   = [bool]$Sequential
    }

    # Self-heal: dismount any share ISO a prior cancelled/crashed run left mounted before
    # we mount our own. Covers both full builds and the -PreCacheOnly path (shared flow).
    Invoke-LwIsoSweep

    if ([string]::IsNullOrWhiteSpace($LocalProjectRoot)) {
        # Authenticate to network share
        $shareHost = 'WIN-HQ5JDEACV3S'
        if ($ShareRoot -match '^\\\\([^\\]+)\\') { $shareHost = $Matches[1] }
        Connect-Share -ShareHost $shareHost -User $ShareUser -Pass $SharePassword -ProbePath $ShareRoot

        if (-not (Test-Path -LiteralPath $ShareRoot)) {
            Emit @{ event='error'; disk=-1; message="Cannot reach share: $ShareRoot" }
            exit 1
        }
    } else {
        Emit @{ event='log'; disk=-1; message="Local build mode: using $LocalProjectRoot (share auth skipped)" }
        if (-not (Test-Path -LiteralPath $LocalProjectRoot)) {
            Emit @{ event='error'; disk=-1; message="Local build mode: LocalProjectRoot not found: $LocalProjectRoot" }
            exit 1
        }
    }

    # Payload/product version for LW_VERSION.json: bundled or -ScriptVersion. Never share VERSION.json.
    $stagingVersion = if ($ScriptVersion) { [string]$ScriptVersion } else { 'unknown' }
    try {
        $bundledVer = Join-Path $PSScriptRoot 'VERSION.json'
        if (($stagingVersion -eq 'unknown' -or [string]::IsNullOrWhiteSpace($stagingVersion)) -and (Test-Path -LiteralPath $bundledVer)) {
            $verJson = Get-Content -Raw -LiteralPath $bundledVer | ConvertFrom-Json
            if ($verJson.payloadVersion) { $stagingVersion = [string]$verJson.payloadVersion }
            elseif ($verJson.version) { $stagingVersion = [string]$verJson.version }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($stagingVersion)) { $stagingVersion = 'unknown' }

    # Primary layout: Staging\AMD64\AMD64.wim
    # $ArchRoot and $StagingWim already set at top of script.
    # Fallback: old layout Staging\Windows *($wfUpper).wim
    if (-not (Test-Path -LiteralPath $StagingWim)) {
        $oldWimFiles = @(Get-ChildItem -LiteralPath $StagingRoot -File -Filter "*.wim" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "Windows *($wfUpper).wim" } |
            Sort-Object LastWriteTime -Descending)
        if ($oldWimFiles.Count -gt 0) { $StagingWim = $oldWimFiles[0].FullName }
    }
    $StagingWindowsDir = $ArchRoot

    # -- ISO fallback: look in Staging\ISO\ first, then Staging\ root ---------
    $isoItem    = $null
    $useIsoMode = $false

    # ISO is the unconditional default source for every non-overlay build: always pull the
    # newest *(arch)*.iso from the share, ignoring any staged WIM. The -ForceIsoMode /
    # -PreferIso / -NoPayload flags no longer gate this (they only tune the log message).
    # The staged-WIM path below is kept dormant purely as a fallback for a missing ISO.
    if (-not $OverlayOnly) {
        $isoFiles = @()
        if (Test-Path -LiteralPath $IsoRoot) {
            $isoFiles = @(Get-ChildItem -Path $IsoRoot -Filter "*($wfUpper)*.iso" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
        }
        if ($isoFiles.Count -eq 0) {
            $isoFiles = @(Get-ChildItem -Path $StagingRoot -Filter "*($wfUpper)*.iso" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
        }
        if ($isoFiles.Count -gt 0) {
            $isoItem    = $isoFiles[0]
            $useIsoMode = $true
            $isoReason  = if ($ForceIsoMode) {
                'ForceIsoMode: skipping WIM, mounting ISO directly'
            } elseif ($PreferIso) {
                "LoneWolf: auto-selected newest ISO '$($isoItem.Name)' from share (ignoring staged WIM)"
            } elseif ($NoPayload) {
                'WIN-INSTALL: preferring ISO over staged WIM (Architecture B)'
            } elseif ($QuickInstall) {
                'QUICK-INSTALL: preferring ISO over staged WIM (Architecture B)'
            } else {
                "Auto-selected newest ISO '$($isoItem.Name)' from share (ISO is the default build source)"
            }
            Emit @{ event='iso-mode'; disk=0; isoFile=$isoItem.Name; message=$isoReason }
        } else {
            # ISO is the default source but none was found. Do NOT hard-fail: warn and fall
            # through to the dormant staged-WIM resolution below. If no WIM exists either,
            # that block emits the final hard error.
            $isoGlob = "*($wfUpper)*.iso"
            Emit @{ event='log'; disk=-1; message="WARNING: no matching $isoGlob found in $IsoRoot or $StagingRoot - falling back to a staged WIM if one is present" }
        }
    }

    if (-not $useIsoMode -and -not $OverlayOnly -and -not (Test-Path -LiteralPath $StagingWim)) {
        $isoFiles = @()
        if (Test-Path -LiteralPath $IsoRoot) {
            $isoFiles = @(Get-ChildItem -Path $IsoRoot -Filter "*($wfUpper)*.iso" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
        }
        # Fallback: old layout - ISOs in Staging\ root
        if ($isoFiles.Count -eq 0) {
            $isoFiles = @(Get-ChildItem -Path $StagingRoot -Filter "*($wfUpper)*.iso" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
        }
        if ($isoFiles.Count -gt 0) {
            $isoItem    = $isoFiles[0]
            $useIsoMode = $true
            Emit @{ event='iso-mode'; disk=0; isoFile=$isoItem.Name;
                    message='No pre-staged WIM found  -  mounting ISO directly' }
        } else {
            Emit @{ event='error'; disk=-1; message="No WIM at $StagingWim and no ISO in $IsoRoot or $StagingRoot - run Unpack-Staging.ps1 or drop an ISO into Staging\ISO\" }
            exit 1
        }
    }

    # -- Mount ISO once for the lifetime of this build ------------------------
    $isoDiskImage    = $null
    $isoDriveLetter  = ''
    if ($useIsoMode) {
        try {
            # Mount the ISO DIRECTLY from its UNC/share path - no local copy or cache.
            # Mount-DiskImage works fine against the share here because this runs
            # elevated AFTER Connect-Share (net use with ShareUser/SharePassword) has
            # authenticated the UNC path. Parallel per-disk workers robocopy the media
            # from this single mounted drive over SMB, which is expected and accepted.
            $isoSizeGb = [math]::Round($isoItem.Length / 1GB, 1)
            EmitLog -Disk 0 -Msg "iso-mount: mounting '$($isoItem.Name)' directly from share ($isoSizeGb GB) - no local copy..."
            $isoDiskImage = Mount-DiskImage -ImagePath $isoItem.FullName -PassThru -ErrorAction Stop
            # Record the mount so a cancel/crash sweep can dismount it if our finally never runs.
            Add-LwMountedIso -Path $isoItem.FullName
            # Retry: the volume may not be initialized immediately after mounting
            for ($retryIdx = 0; $retryIdx -lt 3 -and [string]::IsNullOrEmpty($isoDriveLetter); $retryIdx++) {
                if ($retryIdx -gt 0) { Start-Sleep -Seconds 1 }
                $isoVol = $isoDiskImage | Get-Volume -ErrorAction SilentlyContinue
                if ($isoVol -and $isoVol.DriveLetter) {
                    $isoDriveLetter = $isoVol.DriveLetter + ':'
                }
            }
            if ([string]::IsNullOrEmpty($isoDriveLetter)) {
                Emit @{ event='error'; disk=-1; message="Failed to get drive letter for mounted ISO '$($isoItem.Name)' after 3 attempts" }
                exit 1
            }
            EmitLog -Disk 0 -Msg "ISO mounted at $isoDriveLetter : $($isoItem.Name)"
        } catch {
            Emit @{ event='error'; disk=-1; message="Failed to mount ISO directly from share path '$($isoItem.FullName)': $($_.Exception.Message)" }
            exit 1
        }
    }

    # Measure ESP size for dynamic partition sizing
    $espCacheBytes = 0
    try {
        if ($useIsoMode) {
            $espCacheBytes = (Get-ChildItem -LiteralPath "$isoDriveLetter\" -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\sources\\install\.(wim|esd|swm)$' } |
                Measure-Object -Property Length -Sum).Sum
        } elseif ($StagingWindowsDir) {
            # Exclude install images AND the staged arch WIM (e.g. AMD64.wim) from ESP size estimate
            # Mirror Build-Cache logic: sources\ contributes only boot.wim + *.sdi to the ESP.
            $espCacheBytes = (Get-ChildItem -LiteralPath $StagingWindowsDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^install\.(wim|esd|swm)$' -and
                               $_.Name -notmatch '^(AMD64|ARM64)\.(wim|esd|swm)$' -and
                               ($_.FullName -notmatch '\\sources\\' -or $_.Name -ieq 'boot.wim' -or $_.Name -match '\.sdi$') } |
                Measure-Object -Property Length -Sum).Sum
        }
    } catch { $espCacheBytes = 0 }
    if (-not $espCacheBytes -or $espCacheBytes -le 0) { $espCacheBytes = 1GB }

    $espHeadroom = [math]::Max(384MB, [long]($espCacheBytes * 0.20))
    $espPartitionBytes = [long]([math]::Ceiling(($espCacheBytes + $espHeadroom) / 512MB) * 512MB)

    # Both WIN-INSTALL (-NoPayload) and full builds inject the same WinPE-Startnet.cmd into boot.wim.
    # Architecture B: startnet -> wpeinit -> finds Deploy\TechInstall.cmd on data partition ->
    #   TechInstall.cmd (= TechInstall-Install.cmd for WIN-INSTALL) -> disksetup.cmd + DISM apply + bcdboot + shutdown.
    # The autounattend.xml on the data partition is an offline unattend only (no DiskConfiguration/ImageInstall).
    $noPayloadStartnetTempPath = ''
    $startnetForInjection = Join-Path $ContentRoot 'Deploy\WinPE-Startnet.cmd'

    # Build cache (full build needs ESP template for non-ISO WIM path only).
    # ISO / PreferIso / OverlayOnly: USB-bound content goes DIRECT to the stick
    # (ISO→ESP, ISO→data, ContentRoot→overlay) — no LWCache / EspCache / overlay temp.
    # LocalProjectRoot mode uses the same path as network-share mode once $isoDriveLetter
    # / $StagingWim are resolved.
    if ($OverlayOnly) {
        # Overlay-only: worker copies deploy files straight from ContentRoot → existing USB.
        EmitLog -Disk 0 -Msg 'overlay-only: skipping CacheRoot — overlay copies directly from ContentRoot to USB'
        $CacheRoot = ''
        $userProvidedCache = $false
        $espCache = ''
        $overlayCache = ''
    } elseif (-not [string]::IsNullOrEmpty($isoDriveLetter)) {
        # Architecture B / PreferIso: no ESP cache — workers copy boot files from the mounted
        # ISO and inject WinPE per disk. Overlay maps ContentRoot → USB (no temp stage).
        EmitLog -Disk 0 -Msg 'ISO mode: skipping ESP/overlay cache — boot files + overlay copy directly to USB (no LWCache staging)'
        $CacheRoot = ''
        $userProvidedCache = $false
        $espCache = ''
        $overlayCache = ''
    } else {
        # Non-ISO staged-WIM / MEDIA-CREATOR: EspCache holds the injected boot.wim template
        # so each USB gets a fast copy instead of per-disk DISM inject. Allocate CacheRoot
        # now (deferred from script top so ISO builds never create LWCache_* litter).
        if (-not $userProvidedCache -or [string]::IsNullOrWhiteSpace($CacheRoot)) {
            $CacheRoot = Join-Path $env:TEMP ('LWCache_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $userProvidedCache = $false
        }
        $espCache     = Join-Path $CacheRoot 'esp'
        $overlayCache = Join-Path $CacheRoot 'overlay'

        # Freshness check: if boot.wim was written within the last 4 hours the ESP
        # cache (including the startnet-injected boot.wim) is still valid.  Skip the
        # expensive Build-Cache / Build-IsoCache + Invoke-StartnetInjection step.
        # This only activates when -CacheRoot points to a persistent folder; the
        # default GUID-based temp path is always fresh and always rebuilds.
        # Also require bootmgfw.efi — a cache that has boot.wim but missing bootmgfw
        # (common when staging ISO omitted it and a prior run skipped synthesis) must
        # not be treated as fresh; that produces USB boot 0xc0000098 / missing winload.efi.
        $espBootWim   = Join-Path $espCache 'sources\boot.wim'
        $espBootmgfw  = Join-Path $espCache 'efi\microsoft\boot\bootmgfw.efi'
        $cacheAge     = if (Test-Path -LiteralPath $espBootWim) {
            (Get-Date) - (Get-Item -LiteralPath $espBootWim).LastWriteTime
        } else { $null }
        $cacheIsFresh = $cacheAge -and $cacheAge.TotalHours -lt 4 -and (Test-Path -LiteralPath $espBootmgfw)

        if (-not $cacheIsFresh) {
            if ($useIsoMode) {
                Build-IsoCache -IsoDrive "$isoDriveLetter\"
            } else {
                Build-Cache -StagingWindowsDir $StagingWindowsDir -StagingWim $StagingWim
            }

            $startnetSrc  = $startnetForInjection   # Both modes: Deploy\WinPE-Startnet.cmd from ContentRoot
            $bootWimPath  = Join-Path $espCache 'sources\boot.wim'
            # WinPE-OCs is now arch-partitioned on the share: resolve <WpeOcRoot>\<ARCH>
            # (e.g. ...\WinPE-OCs\AMD64) with a legacy-flat fallback.
            $wpeOcStaging = Resolve-WpeOcArchRoot -BaseRoot $WpeOcSource -Arch $wfUpper
            EmitLog -Disk 0 -Msg "startnet inject: resolved WinPE-OCs source for $wfUpper -> '$wpeOcStaging'"
            $espSentinel  = Join-Path $espCache 'sources\boot.wim.lw-injected'

            # Skip the 8-15 minute DISM injection when boot.wim was pre-injected
            # by _inject-boot-wim.ps1 and the sentinel hash matches the current
            # startnet content (i.e. unchanged since the last cache build).
            $needsInjection = $true
            if ((Test-Path -LiteralPath $espSentinel) -and (Test-Path -LiteralPath $startnetSrc)) {
                $currentHash  = (Get-FileHash -LiteralPath $startnetSrc -Algorithm SHA256).Hash
                $sentinelHash = (Get-Content -LiteralPath $espSentinel -Raw).Trim()
                if ($currentHash -eq $sentinelHash) {
                    # Also verify the sentinel is not older than boot.wim - a sentinel that
                    # predates boot.wim means a new ISO refreshed boot.wim but left the stale
                    # sentinel behind, so injection was incorrectly skipped last build.
                    $bootWimAge  = (Get-Item -LiteralPath $bootWimPath).LastWriteTime
                    $sentinelAge = (Get-Item -LiteralPath $espSentinel).LastWriteTime
                    if ($sentinelAge -lt $bootWimAge) {
                        Write-Warning "startnet inject: sentinel predates boot.wim - re-injecting"
                    } else {
                        EmitLog -Disk 0 -Msg "startnet inject: boot.wim is pre-injected (sentinel matches) - skipping DISM injection"
                        $needsInjection = $false
                    }
                }
            }

            if ($needsInjection) {
                # Inject the custom WinPE startnet.cmd into boot.wim in the ESP cache so
                # that every USB written from this cache automatically launches TechInstall.cmd
                # when WinPE boots.
                Invoke-StartnetInjection -BootWimPath $bootWimPath -StartnetCmdPath $startnetSrc -WpeOcPath $wpeOcStaging
                # Write sentinel to the ESP cache only so future builds can skip injection.
                # Do NOT write back to staging - the staging boot.wim is always stock and a
                # stale sentinel there would cause injection to be incorrectly skipped after
                # a new ISO refreshes boot.wim but leaves the old sentinel in place.
                $injectedHash = (Get-FileHash -LiteralPath $startnetSrc -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
                if ($injectedHash) {
                    Set-Content -LiteralPath $espSentinel -Value $injectedHash -Encoding ascii -Force -ErrorAction SilentlyContinue
                }
            } else {
                # Emit a log event whose message contains "startnet inject" + "complete"
                # so the builder.js UI updates the WinPE-injection status bar to done.
                EmitLog -Disk 0 -Msg "startnet inject: boot.wim pre-injection complete"
            }
        } else {
            EmitLog -Disk 0 -Msg "esp-cache is fresh (age: $([math]::Round($cacheAge.TotalMinutes)) min) - skipping rebuild"
        }
        # Overlay for WIM-mode sticks is applied direct from ContentRoot in the
        # per-disk worker (no USB-bound overlay temp stage). EspCache remains for the
        # injected boot.wim template only.
        $overlayCache = ''
    }

    if ($PreCacheOnly) {
        Emit @{ event='done'; disk=0; success=$true; message='Pre-cache complete' }
        exit 0
    }

    # Validate disk numbers
    $validDisks = @(Get-Disk -ErrorAction SilentlyContinue)
    $validNums  = $validDisks | Select-Object -ExpandProperty Number
    $badNums    = $requestedDisks | Where-Object { $_ -notin $validNums }
    if ($badNums.Count -gt 0) {
        Emit @{ event='error'; disk=-1; message="Disk(s) not found: $($badNums -join ', ')" }
        exit 1
    }

    # -------------------------------------------------------------------------
    # Shared WIM mount (WIM mode only) — one read-only DISM mount for all disks
    # -------------------------------------------------------------------------
    # Concurrent DISM /Mount-Image from parallel Start-Jobs serializes or fails.
    # Mount once on the main thread; Phase 1 jobs robocopy from the shared path.
    if (-not $OverlayOnly -and -not $useIsoMode -and [string]::IsNullOrEmpty($isoDriveLetter) -and
        -not [string]::IsNullOrEmpty($StagingWim) -and (Test-Path -LiteralPath $StagingWim)) {
        try {
            $sharedWimWorkDir = Join-Path $env:TEMP ('LW-WimShared-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $sharedLocalWim   = Join-Path $sharedWimWorkDir 'staging.wim'
            $sharedWimMount   = Join-Path $sharedWimWorkDir 'mount'
            New-Item -ItemType Directory -Path $sharedWimWorkDir -Force | Out-Null
            New-Item -ItemType Directory -Path $sharedWimMount   -Force | Out-Null

            # Prefer mounting the staging WIM DIRECTLY from its share path (read-only) so we
            # skip the full multi-GB copy to %TEMP% before the shared mount. If the direct
            # mount throws, fall back to the proven copy-to-temp-then-mount. Either way the
            # mount dir stays under %TEMP% and the outer catch + finally cleanup is unchanged.
            $sharedDirectOk = $false
            try {
                EmitLog -Disk 0 -Msg "wim-shared: mounting staging WIM directly from share (read-only) -> $sharedWimMount"
                $sharedMountOut = & dism.exe /Mount-Image /ImageFile:"$StagingWim" /Index:1 /MountDir:"$sharedWimMount" /ReadOnly 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Shared DISM /Mount-Image (direct share) failed (exit $LASTEXITCODE): $($sharedMountOut -join '; ')"
                }
                $sharedDirectOk = $true
                EmitLog -Disk 0 -Msg 'wim-shared: direct share mount ready (no local copy) — Phase 1 will run parallel robocopy to each USB'
            } catch {
                EmitLog -Disk 0 -Msg "wim-shared: direct share mount failed ($($_.Exception.Message)); falling back to copy-to-temp then mount"
                & dism.exe /Unmount-Image /MountDir:"$sharedWimMount" /Discard 2>&1 | Out-Null
            }

            if (-not $sharedDirectOk) {
                EmitLog -Disk 0 -Msg "wim-shared: copying WIM to local temp for shared mount ($sharedLocalWim)..."
                $sharedCopy = & robocopy.exe (Split-Path $StagingWim) $sharedWimWorkDir (Split-Path $StagingWim -Leaf) /R:1 /W:2 /NP /NJH /NJS /J 2>&1
                if ($LASTEXITCODE -ge 8) {
                    throw "Shared WIM local copy failed (exit $LASTEXITCODE): $($sharedCopy -join '; ')"
                }
                $sharedLeaf = Split-Path $StagingWim -Leaf
                if ($sharedLeaf -ne 'staging.wim') {
                    Rename-Item -LiteralPath (Join-Path $sharedWimWorkDir $sharedLeaf) -NewName 'staging.wim' -Force
                }

                EmitLog -Disk 0 -Msg "wim-shared: mounting read-only -> $sharedWimMount (all Phase 1 jobs will robocopy from here)"
                $sharedMountOut = & dism.exe /Mount-Image /ImageFile:"$sharedLocalWim" /Index:1 /MountDir:"$sharedWimMount" /ReadOnly 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Shared DISM /Mount-Image failed (exit $LASTEXITCODE): $($sharedMountOut -join '; ')"
                }
                EmitLog -Disk 0 -Msg 'wim-shared: mount ready — Phase 1 will run parallel robocopy to each USB'
            }
        } catch {
            EmitLog -Disk 0 -Msg "WARNING: shared WIM mount failed ($($_.Exception.Message)); falling back to per-disk mounts (may serialize)"
            if (-not [string]::IsNullOrEmpty($sharedWimMount)) {
                & dism.exe /Unmount-Image /MountDir:"$sharedWimMount" /Discard 2>&1 | Out-Null
            }
            if (-not [string]::IsNullOrEmpty($sharedWimWorkDir) -and (Test-Path -LiteralPath $sharedWimWorkDir)) {
                Remove-Item -LiteralPath $sharedWimWorkDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            $sharedWimWorkDir = ''
            $sharedWimMount   = ''
        }
    }

    # -------------------------------------------------------------------------
    # Per-disk end-to-end jobs (true parallel across disks)
    # -------------------------------------------------------------------------
    # Each Start-Job runs wipe → ESP → DISM/data → WinPE inject (that USB's
    # boot.wim) → overlay → BCD → done. No global barrier between "Phase 1" and
    # "Phase 2": Disk A can inject WinPE while Disk B is still in DISM.
    # Shared staging WIM / ISO mounts stay on this thread until all jobs finish.
    $succeeded    = [System.Collections.Generic.List[int]]::new()
    $failed       = [System.Collections.Generic.List[int]]::new()
    $diskJobs     = @()
    # WinPE-OCs is arch-partitioned on the share: pass the resolved <WpeOcRoot>\<ARCH>
    # subfolder (legacy-flat fallback) into each per-disk job. The job runspace cannot
    # call script-scope functions, so resolution happens here on the main thread.
    $wpeOcStaging = Resolve-WpeOcArchRoot -BaseRoot $WpeOcSource -Arch $wfUpper

    # Resolve the pre-split fast-copy set ONCE (ISO mode + Single layout only). '' when no
    # valid, matching staged set exists -> each disk job falls back to the on-the-fly split
    # (control flow + output byte-identical to before this feature). Never fatal.
    $PreSplitSetDir = ''
    if ($useIsoMode -and $Layout -eq 'Single' -and -not $OverlayOnly -and $null -ne $isoItem) {
        $resolvedSet = Get-LWPreSplitSet -Iso $isoItem -PreSplitRoot $PreSplitRoot -Arch $wfUpper -VerifyHash:$VerifyPreSplitHash
        if ($resolvedSet) { $PreSplitSetDir = $resolvedSet }
    }

    $imageBuildDate = ''
    if ($isoItem) {
        try { $imageBuildDate = $isoItem.LastWriteTimeUtc.ToString('yyyy-MM-dd') } catch { }
    } elseif (-not $OverlayOnly -and (Test-Path -LiteralPath $StagingWim)) {
        try { $imageBuildDate = (Get-Item -LiteralPath $StagingWim).LastWriteTimeUtc.ToString('yyyy-MM-dd') } catch { }
    }

    foreach ($diskNum in $requestedDisks) {
        EmitStart -Disk $diskNum
        if ($Sequential) {
            EmitLog -Disk $diskNum -Msg 'sequential mode: draining this disk end-to-end before starting the next'
        }
        $diskJob = Start-Job -Name "LW-Disk${diskNum}" -ScriptBlock $workerDiskBlock `
            -ArgumentList @(
                $diskNum,
                $espCache,
                $StagingWim,
                $espPartitionBytes,
                ([bool]$OverlayOnly),
                $DataVolumeLabel,
                $isoDriveLetter,
                ([bool]$NoPayload),
                $sharedWimMount,
                $overlayCache,
                $startnetForInjection,
                $wpeOcStaging,
                $ContentRoot,
                $WorkflowType,
                $stagingVersion,
                $Layout,
                ([bool]$QuickInstall),
                $SplitLibPath,
                $PreSplitSetDir,
                ([bool]$DevBuild),
                $LauncherVersion,
                $ScriptVersion,
                $ShareLauncherVersion,
                $ShareScriptVersion,
                $imageBuildDate
            )

        if ($Sequential) {
            # Sequential mode: drain this disk fully before the next.
            do {
                $out = Receive-Job $diskJob -ErrorAction SilentlyContinue
                foreach ($line in @($out)) {
                    $line = [string]$line
                    if ($line.TrimStart().StartsWith('{')) { Write-Output $line }
                }
                if ($diskJob.State -eq 'Running') { Start-Sleep -Milliseconds 300 }
            } until ($diskJob.State -ne 'Running')
            $out = Receive-Job $diskJob -ErrorAction SilentlyContinue
            foreach ($line in @($out)) {
                $line = [string]$line
                if ($line.TrimStart().StartsWith('{')) { Write-Output $line }
            }
            if ($diskJob.State -eq 'Completed') {
                $succeeded.Add($diskNum)
            } else {
                $failed.Add($diskNum)
                foreach ($cj in @($diskJob.ChildJobs)) {
                    foreach ($err in @($cj.Error)) { EmitError -Disk $diskNum -Msg $err.ToString() }
                }
            }
            Remove-Job $diskJob -Force -ErrorAction SilentlyContinue
        } else {
            $diskJobs += [pscustomobject]@{ Disk = $diskNum; Job = $diskJob; Done = $false }
        }
    }

    # Poll parallel disk jobs and forward JSON events (no-op in sequential mode)
    $jobsRemaining = $diskJobs.Count
    while ($jobsRemaining -gt 0) {
        foreach ($j in $diskJobs) {
            if ($j.Done) { continue }
            $out = Receive-Job -Job $j.Job -Keep:$false -ErrorAction SilentlyContinue
            foreach ($line in @($out)) {
                $line = [string]$line
                if ($line.TrimStart().StartsWith('{')) { Write-Output $line }
            }
            if ($j.Job.State -notin @('Running','NotStarted')) {
                $tail = Receive-Job -Job $j.Job -ErrorAction SilentlyContinue
                foreach ($line in @($tail)) {
                    $line = [string]$line
                    if ($line.TrimStart().StartsWith('{')) { Write-Output $line }
                }
                if ($j.Job.State -eq 'Completed') {
                    $succeeded.Add($j.Disk)
                } else {
                    $failed.Add($j.Disk)
                    foreach ($cj in @($j.Job.ChildJobs)) {
                        foreach ($err in @($cj.Error)) { EmitError -Disk $j.Disk -Msg $err.ToString() }
                    }
                }
                Remove-Job -Job $j.Job -Force -ErrorAction SilentlyContinue
                $j.Done = $true
                $jobsRemaining--
            }
        }
        if ($jobsRemaining -gt 0) { Start-Sleep -Milliseconds 1800 }
    }

    EmitSummary -Succeeded @($succeeded) -Failed @($failed)

    if ($failed.Count -gt 0) { exit 1 }

} catch {
    Emit @{ event='error'; disk=-1; message=$_.Exception.Message }
    exit 1
} finally {
    # Dismount shared WIM mount (must happen after all Phase 1 jobs complete).
    if (-not [string]::IsNullOrEmpty($sharedWimMount)) {
        & dism.exe /Unmount-Image /MountDir:"$sharedWimMount" /Discard 2>&1 | Out-Null
    }
    if (-not [string]::IsNullOrEmpty($sharedWimWorkDir) -and (Test-Path -LiteralPath $sharedWimWorkDir -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $sharedWimWorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Kill the dismount race: the ISO is a single network-backed mount shared by all
    # parallel per-disk robocopy workers. The normal parallel poll loop above only
    # exits once every disk job has left Running, but if the try block exited early
    # (an error before the loop drained) a LW-Disk job could still be reading from the
    # mount. Dismounting then would yank the source mid-copy (the exit-11 "some files
    # could not be copied" symptom). Wait for any straggler disk jobs before dismount.
    $isoStragglers = @(Get-Job -Name 'LW-Disk*' -ErrorAction SilentlyContinue |
        Where-Object { $_.State -in @('Running','NotStarted') })
    if ($isoStragglers.Count -gt 0) {
        Wait-Job -Job $isoStragglers -ErrorAction SilentlyContinue | Out-Null
    }
    # Dismount ISO if we mounted it (only after all jobs complete, per the wait above).
    # Mount was against the ISO's UNC/share path directly (no local copy), so dismount
    # that same share path. No local temp/cache ISO exists to delete.
    if ($null -ne $isoDiskImage) {
        Dismount-DiskImage -ImagePath $isoItem.FullName -ErrorAction SilentlyContinue | Out-Null
        Remove-LwMountedIso -Path $isoItem.FullName
    }
    if (-not $userProvidedCache -and -not [string]::IsNullOrWhiteSpace($CacheRoot) -and
        (Test-Path -LiteralPath $CacheRoot -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $CacheRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    # $noPayloadStartnetTempPath is always empty (WIN-INSTALL now uses WinPE-Startnet.cmd directly; no temp file created).
    if (-not [string]::IsNullOrEmpty($noPayloadStartnetTempPath) -and
        (Test-Path -LiteralPath $noPayloadStartnetTempPath -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $noPayloadStartnetTempPath -Force -ErrorAction SilentlyContinue
    }
    # Best-effort orphan sweep (success, failure, and cancel-via-exit all reach finally;
    # hard-kill is covered by -DismountOnly + next build-start sweep).
    Invoke-LwTempOrphanSweep -Reason 'build-end' -IncludeCache
}
