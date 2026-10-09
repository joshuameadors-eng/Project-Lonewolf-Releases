#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Project LoneWolf Launcher - Pre-Split install.wim staging producer (Option A).

.DESCRIPTION
  One-shot producer for the "staged pre-split install.wim" feature. Mounts a
  source Windows ISO, splits sources\install.wim (or exports+splits install.esd)
  into an install*.swm set (< 4 GB each, DISM /Split-Image /CheckIntegrity via
  the SHARED helper lib\Split-LWImage.ps1). Images above 3800 MB keep
  /FileSize:3800. Images from 512 MiB through 3800 MB use a span just over
  half the image so DISM writes at least two SWM chunks. A one-file set for
  an image that large is not treated as finished, so the next Stage ISO
  re-stages that folder only. Result:

    Packaged: <share>\PreSplit\<imageVersion>\  (Drive Desktop or HQ UNC)
    Destage (npm start -DestageMedia):
      ISO from C:\Repos\Windows_Installation\UUP\25h2\ISO only (no share IsoRoot)
      Write C:\Repos\Windows_Installation\UUP\25h2\PreSplit\<imageVersion>\

    <PreSplit>\<imageVersion>\
        install.swm, install2.swm, ...
        presplit-manifest.json
        current                   (JSON marker inside the set)
    <PreSplit>\current.json  (map keyed AMD64-Home / ARM64-Pro / ...)

  imageVersion includes Windows version + Home/Pro + arch, e.g.
    25h2-home-9-9-amd64-<stamp>  /  25h2-pro-9-9-arm64-<stamp>

  Presplit identity is architecture + Windows version + Home/Pro. Full LoneWolf
  (updates) and Quick Install share the same set. Workflow type is not a lock.

  The builder (Invoke-LoneWolfBuild.ps1) fast-copies this set instead of running
  dism /Split-Image on every build. A missing/mismatched/corrupt set is NEVER
  fatal - the builder automatically falls back to the on-the-fly split.

  Progress is streamed as the SAME single-line JSON events the builder emits
  (event=phase|progress|log|done|error), so main.js' existing stdout parser and
  the renderer handle it with no new plumbing. Producer phases:
    stage-mount -> stage-split -> stage-copy -> stage-manifest -> stage-verify -> done

.PARAMETER WorkflowType
  Target architecture: AMD64 or ARM64. (Required.)

.PARAMETER ShareRoot
  UNC root of the deployment share. Ignored when -LocalProjectRoot is set.

.PARAMETER ShareUser / SharePassword
  Share credentials (used only when writing to the share, not in local mode).

.PARAMETER LocalProjectRoot
  Packaged/local-build only. When non-empty this is used as ProjectRoot
  (e.g. <appPath>\Remote): share auth is skipped and the set is written to
  the LOCAL Remote\Staging tree. Ignored when -DestageMedia is set.

.PARAMETER DestageMedia
  npm start only. Source ISO is only IsoRoot
  C:\Repos\Windows_Installation\UUP\25h2\ISO (*(amd64|arm64)*.iso + Home/Pro name).
  No share ISO. Write to PreSplitOutputRoot (default
  C:\Repos\Windows_Installation\UUP\25h2\PreSplit). UNC / share PreSplit writes
  are refused. Packaged production/Dev must not pass this.

.PARAMETER PreSplitOutputRoot
  Destage-only explicit PreSplit write directory. When set (or -DestageMedia),
  the producer never writes to share PreSplit.

.PARAMETER IsoFallbackRoot
  Unused on destage (local UUP ISO is the only source). Kept so older main.js
  argument lists do not bind-fail.

.PARAMETER IsoPath
  Explicit source ISO. Default: newest *(<ARCH>)*.iso by LastWriteTime in
  Staging\ISO\ (filename must include home or pro and *(<ARCH>)*; legacy ISO\<SKU>\ still read).

.PARAMETER WindowsEdition
  Home or Pro. Selects ISO by filename token (home/pro) and writes a PreSplit\<imageVersion>\ folder.

.PARAMETER Force
  Re-stage even if a valid set already exists for this image version. The new set
  is written to a temp sibling and atomically swapped in, so a failed re-stage
  never corrupts the existing known-good set.

.PARAMETER FileSizeMb
  Cap for DISM /Split-Image /FileSize (MB). Default 3800. Images at or under
  the cap use the shared span in lib\Split-LWImage.ps1 so this producer and
  the builder fallback stay interchangeable.

.PARAMETER DeepHash
  Also compute and record per-chunk sha256 in the manifest (expensive on multi-GB
  chunks). Default off: manifest sha256 fields are null and only size is recorded.

.PARAMETER AppResourcesPath
  Packaged-app resources path (parity with the builder / staging scripts).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File ".\Stage-PreSplitImage.ps1" -WorkflowType AMD64

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File ".\Stage-PreSplitImage.ps1" -WorkflowType AMD64 -LocalProjectRoot "C:\...\Remote" -Force -DeepHash
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('AMD64','ARM64')]
    [string] $WorkflowType,

    [ValidateSet('Home','Pro')]
    [string] $WindowsEdition = 'Pro',

    [string] $ShareRoot        = '\\WIN-HQ5JDEACV3S\Images\FB Image Creation',
    # KEEP IN SYNC: LONEWOLF_SHARE_USER / LONEWOLF_SHARE_PASSWORD env-first (see Invoke-LoneWolfBuild.ps1).
    [string] $ShareUser        = $(if (-not [string]::IsNullOrWhiteSpace($env:LONEWOLF_SHARE_USER)) { $env:LONEWOLF_SHARE_USER } else { 'Reflect' }),
    [string] $SharePassword    = $(if (-not [string]::IsNullOrWhiteSpace($env:LONEWOLF_SHARE_PASSWORD)) { $env:LONEWOLF_SHARE_PASSWORD } else { 'mer*HWE0upt*rqe@dud' }),
    [string] $LocalProjectRoot = '',
    [switch] $DestageMedia,
    [ValidateSet('local', 'share', 'googleDrive', '')]
    [string] $MediaSource = '',
    [string] $PreSplitOutputRoot = '',
    [string] $IsoFallbackRoot = '',
    [string] $IsoPath          = '',
    [switch] $Force,
    [int]    $FileSizeMb       = 3800,
    [switch] $DeepHash,
    [string] $AppResourcesPath = ''
)

$ErrorActionPreference = 'Stop'

# --- JSON event emitters (identical shape to Invoke-LoneWolfBuild.ps1) --------
# Producer top-level events use disk=0, matching the builder's top-level emitters.
function Emit         { param([hashtable]$Data) $Data | ConvertTo-Json -Compress -Depth 4 | Write-Output }
function EmitPhase    { param([string]$Phase) Emit @{ event='phase'; disk=0; phase=$Phase } }
function EmitProgress { param([string]$Phase, [int]$Pct) Emit @{ event='progress'; disk=0; phase=$Phase; pct=$Pct } }
function EmitLog      { param([string]$Msg) Emit @{ event='log'; disk=0; message=$Msg } }
function EmitError    { param([string]$Msg) Emit @{ event='error'; disk=0; message=$Msg } }
function EmitDone     { param([bool]$Success, [string]$Msg)
    $d = @{ event='done'; disk=0; success=$Success }
    if ($Msg) { $d['message'] = $Msg }
    Emit $d
}

# --- Share authentication (mirrors Get-StagingVersion.ps1) --------------------
function Connect-ShareCredentials {
    param([string]$ShareHost, [string]$User, [string]$Pass)
    try {
        $cmdkey = Join-Path $env:SystemRoot 'System32\cmdkey.exe'
        if (Test-Path -LiteralPath $cmdkey) {
            & $cmdkey /delete:$ShareHost 2>$null | Out-Null
            & $cmdkey /add:$ShareHost /user:$User /pass:$Pass 2>&1 | Out-Null
        }
    } catch { }
}

# --- Resolve paths (same contract as the builder) -----------------------------
$wfUpper = $WorkflowType.ToUpper()
$winEdition = if ($WindowsEdition -match '^(?i)home$') { 'Home' } else { 'Pro' }
$bareArch = if ($wfUpper -match 'ARM') { 'ARM64' } else { 'AMD64' }
$shareLayoutLib = Join-Path $PSScriptRoot 'lib\Resolve-LwShareLayout.ps1'
if (Test-Path -LiteralPath $shareLayoutLib) { . $shareLayoutLib }

$resolvedMediaSource = if ($DestageMedia) { 'local' } elseif (-not [string]::IsNullOrWhiteSpace($MediaSource)) { $MediaSource } else { '' }
$useDestageLocalUup = $DestageMedia -or ($resolvedMediaSource -eq 'local') -or (
    -not [string]::IsNullOrWhiteSpace($PreSplitOutputRoot) -and
    $resolvedMediaSource -ne 'googleDrive' -and $resolvedMediaSource -ne 'share'
)
$useDestageMedia = $useDestageLocalUup -or ($resolvedMediaSource -eq 'googleDrive') -or ($resolvedMediaSource -eq 'share')
$isLocal = (-not $useDestageMedia) -and (-not [string]::IsNullOrWhiteSpace($LocalProjectRoot))

if ($useDestageLocalUup) {
    $null = Initialize-LwDestageUupDirs
    $uup = Get-LwDestageUupLayout
    $ProjectRoot  = $uup.Root
    $StagingRoot  = $uup.IsoRoot
    $IsoRoot      = $uup.IsoRoot
    $IsoFallbackRoot = ''
    $PreSplitRoot = if (-not [string]::IsNullOrWhiteSpace($PreSplitOutputRoot)) {
        $PreSplitOutputRoot
    } else {
        $uup.PreSplitRoot
    }
} elseif ($resolvedMediaSource -eq 'googleDrive' -or $resolvedMediaSource -eq 'share') {
    $destageLayout = Resolve-LwDestageMediaLayout -ShareRoot $ShareRoot -MediaSource $resolvedMediaSource
    $ProjectRoot = Join-Path $ShareRoot 'Remote'
    $StagingRoot = $destageLayout.StagingRoot
    $IsoRoot = $destageLayout.IsoRoot
    $IsoFallbackRoot = ''
    $PreSplitRoot = $destageLayout.PreSplitRoot
} else {
    $shareLayout = Resolve-LwShareLayout -ShareRoot $ShareRoot -LocalProjectRoot $LocalProjectRoot
    if ($isLocal) {
        $ProjectRoot = $LocalProjectRoot
    } else {
        $ProjectRoot = Join-Path $ShareRoot 'Remote'
    }
    $StagingRoot  = $shareLayout.StagingRoot
    $IsoRoot      = $shareLayout.IsoRoot
    $PreSplitRoot = $shareLayout.PreSplitRoot
}
$WriteRoot = $PreSplitRoot
if ($useDestageLocalUup) {
    if ([string]::IsNullOrWhiteSpace($WriteRoot)) {
        EmitError 'destage: PreSplit output root is empty'; exit 1
    }
    if ($WriteRoot -match '^\\\\') {
        EmitError "destage: refusing to write PreSplit to UNC share '$WriteRoot'. Output must be C:\Repos\Windows_Installation\UUP\25h2\PreSplit"; exit 1
    }
    try {
        $uupPre = [IO.Path]::GetFullPath((Get-LwDestageUupLayout).PreSplitRoot).TrimEnd('\')
        $writeFull = [IO.Path]::GetFullPath($WriteRoot).TrimEnd('\')
        if ($writeFull -ne $uupPre) {
            EmitError "destage: PreSplit output '$writeFull' is not the local UUP path '$uupPre'"; exit 1
        }
        $WriteRoot = $uupPre
        $PreSplitRoot = $uupPre
    } catch {
        EmitError "destage: invalid PreSplit output '$WriteRoot' ($($_.Exception.Message))"; exit 1
    }
}

# Launcher version for the manifest's producedByLauncherVersion field.
$launcherVersion = 'unknown'
try {
    $vf = Join-Path $PSScriptRoot 'VERSION.json'
    if (Test-Path -LiteralPath $vf) {
        $vj = Get-Content -Raw -LiteralPath $vf | ConvertFrom-Json
        if ($vj.launcherVersion) { $launcherVersion = [string]$vj.launcherVersion }
    }
} catch { }

Emit @{ event='init'; stagingRoot=$StagingRoot; preSplitRoot=$WriteRoot; isoRoot=$IsoRoot; isoFallbackRoot=$IsoFallbackRoot; workflowType=$wfUpper; windowsEdition=$winEdition; local=$isLocal; destageMedia=$useDestageMedia; writeRoot=$WriteRoot }

# --- Share auth / reachability -----------------------------------------------
if ($useDestageLocalUup) {
    EmitLog ('destage local: ISO from UUP {0}; PreSplit output {1}' -f $IsoRoot, $WriteRoot)
} elseif ($resolvedMediaSource -eq 'googleDrive') {
    EmitLog ("destage Drive: ISO from '$IsoRoot'; PreSplit to '$WriteRoot' (install*.swm chunks via Split-LWImage)")
} elseif ($resolvedMediaSource -eq 'share') {
    EmitLog ("destage share: ISO from '$IsoRoot'; PreSplit to '$WriteRoot'")
} elseif ($isLocal) {
    EmitLog "local mode: staging pre-split set into the LOCAL Remote\Staging tree (for upload to the share); share auth skipped"
    if (-not (Test-Path -LiteralPath $LocalProjectRoot)) {
        EmitError "local mode: LocalProjectRoot not found: $LocalProjectRoot"; exit 1
    }
} else {
    if ($ShareRoot -match '^(?i)https?://') {
        EmitError 'A Google Drive folder URL is not a Windows filesystem ShareRoot. Use local UUP or the HQ UNC share.'; exit 1
    }
    if ($ShareRoot -match '^\\\\') {
        $shareHost = 'WIN-HQ5JDEACV3S'
        if ($ShareRoot -match '^\\\\([^\\]+)\\') { $shareHost = $Matches[1] }
        Connect-ShareCredentials -ShareHost $shareHost -User $ShareUser -Pass $SharePassword
    }
    if (-not (Test-Path -LiteralPath $ShareRoot)) {
        EmitError "cannot reach share: $ShareRoot"; exit 1
    }
}

# --- Dot-source the SHARED split lib (same file the builder job uses) ---------
$SplitLibPath = Join-Path $PSScriptRoot 'lib\Split-LWImage.ps1'
if (-not (Test-Path -LiteralPath $SplitLibPath)) {
    EmitError "shared split lib not found: $SplitLibPath"; exit 1
}
. $SplitLibPath
$Arm64DriverLibPath = Join-Path $PSScriptRoot 'lib\Add-LwArm64Drivers.ps1'
if (Test-Path -LiteralPath $Arm64DriverLibPath) { . $Arm64DriverLibPath }

# --- Select source ISO --------------------------------------------------------
EmitPhase 'stage-mount'
$isoItem = $null
if (-not [string]::IsNullOrWhiteSpace($IsoPath)) {
    if (-not (Test-Path -LiteralPath $IsoPath)) { EmitError "IsoPath not found: $IsoPath"; exit 1 }
    $isoItem = Get-Item -LiteralPath $IsoPath
    if (-not (Test-LWIsoMatchesEdition -FullName $isoItem.FullName -Edition $winEdition)) {
        EmitError "IsoPath '$($isoItem.Name)' is not a $winEdition ISO (arch $wfUpper)"; exit 1
    }
} else {
    $isoFind = @{ StagingRoot = $StagingRoot; IsoRoot = $IsoRoot; Arch = $wfUpper; Edition = $winEdition }
    $isoItem = Find-LWWindowsIso @isoFind
    if (-not $isoItem) {
        $isoHint = $IsoRoot
        if ($winEdition -eq 'Home') {
            EmitError (Get-LWMissingHomeIsoMessage -Arch $wfUpper -IsoHomeDir $isoHint)
        } else {
            EmitError "no matching $winEdition *($wfUpper)*.iso found in $isoHint (name must include pro; legacy ISO\Pro still read)"
        }
        exit 1
    }
    if ($useDestageMedia) {
        EmitLog ('destage: using local UUP ISO {0}' -f $isoItem.FullName)
    }
}

# --- Compute image-version identity + target ----------------------------------
$imageVersion = Get-LWImageVersionId -Iso $isoItem -Edition $winEdition
$Target       = Join-Path $WriteRoot $imageVersion
$isoSizeGb    = [math]::Round($isoItem.Length / 1GB, 2)
EmitLog ('pre-split: iso={0} ({1} GB) edition={2} imageVersion={3}' -f $isoItem.FullName, $isoSizeGb, $winEdition, $imageVersion)
EmitLog ('pre-split: output root={0} target={1}' -f $WriteRoot, $Target)

# --- Skip vs write ------------------------------------------------------------
# Destage (npm start): skip/current is LOCAL UUP PreSplit only. Share PreSplit
# matching this ISO is ignored. Packaged still skips when share WriteRoot is valid.
$skipStaged = $false
if ($Force) {
    if ($useDestageMedia) {
        EmitLog ('destage split: -Force / Shift-click — re-staging into {0} (share PreSplit ignored)' -f $Target)
    } else {
        EmitLog ('force re-stage at {0}' -f $Target)
    }
} elseif ($useDestageLocalUup) {
    $uupPre = [IO.Path]::GetFullPath((Get-LwDestageUupLayout).PreSplitRoot).TrimEnd('\')
    $tgtFull = $null
    try { $tgtFull = [IO.Path]::GetFullPath($Target).TrimEnd('\') } catch { }
    $underUup = $tgtFull -and ($tgtFull -eq $uupPre -or $tgtFull.StartsWith($uupPre + '\', [StringComparison]::OrdinalIgnoreCase))
    if (-not $underUup -or $Target -match '^\\\\' -or $WriteRoot -match '^\\\\') {
        EmitError ('destage skip/current must use local UUP PreSplit only (got {0})' -f $Target)
        exit 1
    }
    $nameOk = $true
    if (Get-Command -Name Test-LWPreSplitFolderMatches -ErrorAction SilentlyContinue) {
        $nameOk = [bool](Test-LWPreSplitFolderMatches -FolderName $imageVersion -Arch $bareArch -Edition $winEdition -RequireArchInName)
    }
    if (-not $nameOk) {
        EmitLog ('destage split: set folder {0} is not a {1} {2} name - writing {3} (AMD64 current is not used for ARM64)' -f $imageVersion, $bareArch, $winEdition, $Target)
    } elseif (-not (Test-Path -LiteralPath $Target)) {
        EmitLog ('destage split: no local UUP {0} set at {1} (share PreSplit is ignored; other arches ignored) - writing SWMs/manifest/current' -f $bareArch, $Target)
    } else {
        $chk = Test-LWPreSplitSet -SetDir $Target
        $isoMatch = $false
        $manIso = ''
        if ($chk.Valid -and $chk.Manifest) {
            if ($chk.Manifest.PSObject.Properties['source'] -and $chk.Manifest.source) {
                $src = $chk.Manifest.source
                $manIso = [string]$src.isoName
                $isoMatch = ($manIso -eq $isoItem.Name) -and ([long]$src.isoSizeBytes -eq [long]$isoItem.Length)
            }
            if ($chk.Manifest.PSObject.Properties['arch'] -and $chk.Manifest.arch) {
                $manArch = [string]$chk.Manifest.arch
                if ($manArch -match 'ARM') { $manArch = 'ARM64' } elseif ($manArch -match 'AMD' -or $manArch -match 'X64') { $manArch = 'AMD64' }
                if ($manArch -ne $bareArch) {
                    EmitLog ('destage split: local set at {0} is arch {1}, not {2} - writing' -f $Target, $manArch, $bareArch)
                    $isoMatch = $false
                    $chk = [pscustomobject]@{ Valid = $false; Reason = 'arch mismatch' }
                }
            }
        }
        if ($chk.Valid -and $isoMatch) {
            if ($bareArch -eq 'ARM64' -and (Test-LwArm64DriversStamped -SetDir $Target)) {
                EmitLog ('destage split: ARM64 set at {0} has drivers in the install image - re-staging a stock image' -f $Target)
            } elseif ($resolvedMediaSource -eq 'googleDrive' -and (Get-Command -Name Test-LwPreSplitMediaPackage -ErrorAction SilentlyContinue) -and
                -not (Test-LwPreSplitMediaPackage -SetDir $Target)) {
                EmitLog ('destage split: Drive set at {0} is missing the ISO media tree - re-staging full package' -f $Target)
            } else {
                EmitLog ('destage skip: local UUP {0} already has a valid matching set at {1} (share PreSplit not used; other arches ignored). Shift-click / -Force to re-stage.' -f $bareArch, $Target)
                $skipStaged = $true
            }
        } elseif ($chk.Valid) {
            EmitLog ('destage split: local UUP set at {0} does not match this ISO (manifest {1} vs {2}) - writing' -f $Target, $manIso, $isoItem.Name)
        } else {
            EmitLog ('destage split: local UUP set at {0} is invalid ({1}) - writing' -f $Target, $chk.Reason)
        }
    }
} elseif ((Test-Path -LiteralPath $Target)) {
    $chk = Test-LWPreSplitSet -SetDir $Target
    if ($chk.Valid) {
        if ($bareArch -eq 'ARM64' -and (Test-LwArm64DriversStamped -SetDir $Target)) {
            EmitLog ('already-staged set at {0} has drivers in the install image - re-staging a stock image' -f $Target)
        } elseif ($resolvedMediaSource -eq 'googleDrive' -and (Get-Command -Name Test-LwPreSplitMediaPackage -ErrorAction SilentlyContinue) -and
            -not (Test-LwPreSplitMediaPackage -SetDir $Target)) {
            EmitLog ('already-staged set at {0} is missing the ISO media tree - re-staging full package' -f $Target)
        } else {
            EmitLog ('already-staged: a valid pre-split set for {0} exists at {1} - nothing to do (pass -Force to re-stage)' -f $isoItem.Name, $Target)
            $skipStaged = $true
        }
    } else {
        EmitLog ('existing set at {0} is invalid ({1}) - re-staging over it' -f $Target, $chk.Reason)
    }
} else {
    EmitLog ('split: no set at {0} - writing' -f $Target)
}

if ($skipStaged) {
    EmitDone $true 'already-staged'
    exit 0
}

# --- Produce the set ----------------------------------------------------------
$scratch   = ''
$tmpTarget = ''
$mounted   = $false
try {
    $isoSizeGb = [math]::Round($isoItem.Length / 1GB, 2)
    EmitLog "stage-mount: mounting '$($isoItem.Name)' ($isoSizeGb GB)..."
    EmitProgress 'stage-mount' 0
    $diskImage = Mount-DiskImage -ImagePath $isoItem.FullName -PassThru -ErrorAction Stop
    $mounted   = $true

    $driveLetter = ''
    for ($r = 0; $r -lt 5 -and [string]::IsNullOrEmpty($driveLetter); $r++) {
        if ($r -gt 0) { Start-Sleep -Seconds 1 }
        $vol = $diskImage | Get-Volume -ErrorAction SilentlyContinue
        if ($vol -and $vol.DriveLetter) { $driveLetter = $vol.DriveLetter + ':' }
    }
    if ([string]::IsNullOrEmpty($driveLetter)) { throw 'Failed to get drive letter for mounted ISO after 5 attempts.' }
    $isoDrive = "$driveLetter\"
    EmitLog "stage-mount: ISO mounted at $isoDrive"
    EmitProgress 'stage-mount' 100

    # Inspect the source install image for manifest metadata.
    $isoSources = Join-Path $isoDrive 'sources'
    $srcWimPath = Join-Path $isoSources 'install.wim'
    $srcEsdPath = Join-Path $isoSources 'install.esd'
    if (Test-Path -LiteralPath $srcWimPath) {
        $sourceKind = 'wim'; $installImg = $srcWimPath
    } elseif (Test-Path -LiteralPath $srcEsdPath) {
        $sourceKind = 'esd'; $installImg = $srcEsdPath
    } else {
        throw "no install.wim or install.esd found under '$isoSources' on the mounted ISO"
    }
    $originalSize = (Get-Item -LiteralPath $installImg).Length
    $indexCount   = 1
    try {
        $imgInfo = @(Get-WindowsImage -ImagePath $installImg -ErrorAction SilentlyContinue)
        if ($imgInfo.Count -gt 0) { $indexCount = $imgInfo.Count }
    } catch { }

    # -- Split into a local scratch folder (never split straight to the share) --
    $scratch        = Join-Path $env:TEMP ('LW-Stage-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $scratchSources = Join-Path $scratch 'sources'
    New-Item -ItemType Directory -Force -Path $scratchSources | Out-Null
    $splitSources = $isoSources
    EmitLog "stage-split: Windows install image stays stock (ARM64 drivers are injected into WinPE only)"
    EmitPhase 'stage-split'
    EmitProgress 'stage-split' 0
    Split-LWImageForFat32 -SourceSourcesDir $splitSources -DestSourcesDir $scratchSources -FileSizeMb $FileSizeMb -Emit { param($m) EmitLog $m } -Progress { param($p) EmitProgress 'stage-split' $p }
    EmitProgress 'stage-split' 100

    $chunkFiles = @(Get-ChildItem -LiteralPath $scratchSources -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^install(\d*)\.(swm|wim|esd)$' } |
        Sort-Object Name)
    if ($chunkFiles.Count -eq 0) {
        throw "stage-split produced no install image in $scratchSources"
    }
    $splitInputLen = [long]$originalSize
    $splitInputWim = Join-Path $splitSources 'install.wim'
    $splitInputEsd = Join-Path $splitSources 'install.esd'
    if (Test-Path -LiteralPath $splitInputWim) {
        $splitInputLen = (Get-Item -LiteralPath $splitInputWim).Length
    } elseif (Test-Path -LiteralPath $splitInputEsd) {
        $splitInputLen = (Get-Item -LiteralPath $splitInputEsd).Length
    }
    $splitPlan = Get-LWFat32SplitPlan -LengthBytes $splitInputLen -FileSizeMb $FileSizeMb
    $swmCount = @($chunkFiles | Where-Object { $_.Extension -eq '.swm' }).Count
    if ($splitPlan.Split -and $swmCount -lt 2) {
        throw ("stage-split: image is {0} bytes and /FileSize:{1} MB requires at least 2 install*.swm chunks, but {2} were produced. Stage not completed." -f $splitInputLen, $splitPlan.FileSizeMb, $swmCount)
    }

    # -- Copy the set to a temp sibling of the final target (atomic swap later) --
    EmitPhase 'stage-copy'
    EmitProgress 'stage-copy' 0
    if ($useDestageMedia -and ($WriteRoot -match '^\\\\')) {
        throw "destage: refusing UNC PreSplit write '$WriteRoot'"
    }
    New-Item -ItemType Directory -Force -Path $WriteRoot | Out-Null
    $tmpTarget = "$Target.tmp-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    New-Item -ItemType Directory -Force -Path $tmpTarget | Out-Null
    $chunkDest = $tmpTarget
    if ($resolvedMediaSource -eq 'googleDrive') {
        $chunkDest = Join-Path $tmpTarget 'sources'
        New-Item -ItemType Directory -Force -Path $chunkDest | Out-Null
        EmitLog "stage-copy: mirroring ISO boot tree into PreSplit package (excluding monolithic install image)..."
        $isoRootEntries = @(Get-ChildItem -LiteralPath $isoDrive -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ine 'sources' -and
                           -not (-not $_.PSIsContainer -and $_.Name -match '\.(wim|esd|swm)$') })
        $rootTotal = [math]::Max(1, $isoRootEntries.Count)
        $rootIdx = 0
        foreach ($isoEntry in $isoRootEntries) {
            $rootIdx++
            EmitProgress 'stage-copy' ([int](40 * $rootIdx / $rootTotal))
            if ($isoEntry.PSIsContainer) {
                Copy-Item -LiteralPath $isoEntry.FullName -Destination $tmpTarget -Recurse -Force -ErrorAction Stop
            } else {
                Copy-Item -LiteralPath $isoEntry.FullName -Destination $tmpTarget -Force -ErrorAction Stop
            }
        }
        & robocopy.exe $isoSources $chunkDest /E /XF 'install.wim' 'install.esd' /R:2 /W:5 /NP /NJH /NJS | Out-Null
        $rcIsoSrc = $LASTEXITCODE
        if ($rcIsoSrc -gt 7) { throw "robocopy failed (exit $rcIsoSrc) copying ISO sources (minus install image) to '$chunkDest'" }
        EmitProgress 'stage-copy' 50
    }
    $robPatterns = @('install*.swm', 'install.wim', 'install.esd')
    & robocopy.exe $scratchSources $chunkDest @robPatterns /R:2 /W:5 /NP /NJH /NJS | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -gt 7) { throw "robocopy failed (exit $rc) copying the .swm set to '$tmpTarget'" }
    EmitProgress 'stage-copy' 100

    # -- Manifest (schema 1, per docs §4.3) -------------------------------------
    EmitPhase 'stage-manifest'
    EmitProgress 'stage-manifest' 0
    $nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $isoTitleDate = ''
    if ($isoItem.Name -match '(\d{1,2}\.\d{1,2})') { $isoTitleDate = $Matches[1] }

    $chunkObjs = @()
    $ci = 0
    foreach ($cf in $chunkFiles) {
        $ci++
        $sha = $null
        if ($DeepHash) {
            EmitLog "stage-manifest: hashing $($cf.Name) (sha256)..."
            $sha = (Get-FileHash -LiteralPath $cf.FullName -Algorithm SHA256).Hash
        }
        $chunkObjs += [ordered]@{ name = $cf.Name; sizeBytes = [long]$cf.Length; sha256 = $sha }
        EmitProgress 'stage-manifest' ([int](100 * $ci / [math]::Max($chunkFiles.Count, 1)))
    }

    $manifest = [ordered]@{
        schema       = 1
        arch         = $wfUpper
        windowsEdition = $winEdition
        imageVersion = $imageVersion
        source       = [ordered]@{
            isoName         = $isoItem.Name
            isoSizeBytes    = [long]$isoItem.Length
            isoLastWriteUtc = $isoItem.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
            isoTitleDate    = $isoTitleDate
        }
        install      = [ordered]@{
            sourceKind           = $sourceKind
            sourceIndexCount     = $indexCount
            originalWimSizeBytes = [long]$originalSize
            splitFileSizeMb      = $(if ($splitPlan.Split) { [int]$splitPlan.FileSizeMb } else { [int]$FileSizeMb })
            chunks               = $chunkObjs
        }
        producedByLauncherVersion = $launcherVersion
        arm64Drivers              = $false
        mediaPackage              = $(if ($resolvedMediaSource -eq 'googleDrive') { $true } else { $false })
        createdUtc                = $nowUtc
        updatedUtc                = $nowUtc
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText((Join-Path $tmpTarget 'presplit-manifest.json'), $manifestJson,
        [System.Text.UTF8Encoding]::new($false))
    EmitProgress 'stage-manifest' 100

    # -- Verify, then atomically swap tmp -> Target -----------------------------
    EmitPhase 'stage-verify'
    EmitProgress 'stage-verify' 0
    $chk = Test-LWPreSplitSet -SetDir $tmpTarget -VerifyHash:$DeepHash
    if (-not $chk.Valid) { throw "post-copy validation failed: $($chk.Reason)" }
    EmitProgress 'stage-verify' 50

    if (Test-Path -LiteralPath $Target) {
        # Remove the stale live set (either -Force, or the earlier validity check failed).
        Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction Stop
    }
    Move-Item -LiteralPath $tmpTarget -Destination $Target -Force
    $tmpTarget = ''   # consumed - nothing left to clean up
    EmitProgress 'stage-verify' 90

    # -- Update current markers (root map + inside the set) ---------------------
    if (Get-Command -Name Write-LWPreSplitCurrentMarkers -ErrorAction SilentlyContinue) {
        Write-LWPreSplitCurrentMarkers -PreSplitRoot $WriteRoot -SetDir $Target -Arch $wfUpper -Edition $winEdition -ImageVersion $imageVersion -UpdatedUtc $nowUtc
    } else {
        $currentMarker = Join-Path $Target 'current'
        $curObj = [ordered]@{ imageVersion = $imageVersion; windowsEdition = $winEdition; arch = $wfUpper; updatedUtc = $nowUtc }
        [System.IO.File]::WriteAllText($currentMarker, ($curObj | ConvertTo-Json -Compress),
            [System.Text.UTF8Encoding]::new($false))
    }
    EmitProgress 'stage-verify' 100

    $chunkGb = [math]::Round($originalSize / 1GB, 2)
    $doneMsg = if ($swmCount -ge 2) {
        "staged $swmCount SWM chunk(s), $chunkGb GB, sourceKind=$sourceKind"
    } else {
        "staged 1 file ($($chunkFiles[0].Name), $chunkGb GB, under 512 MB), sourceKind=$sourceKind"
    }
    EmitLog "staged pre-split set at $Target ($doneMsg, imageVersion=$imageVersion)"
    if ($useDestageLocalUup) {
        EmitLog "destage: Rebuild from npm start reads this local UUP PreSplit set (packaged builds still use share PreSplit)"
    } elseif ($resolvedMediaSource -eq 'googleDrive') {
        EmitLog "destage Drive: PreSplit set includes install*.swm under sources\; boot.wim is exported into the same sources folder by Stage-GoogleDriveMedia"
    } elseif ($isLocal) {
        EmitLog "local mode: upload '$WriteRoot' to the share to make this set available to network builds"
    }
    EmitDone $true $doneMsg

} catch {
    EmitError $_.Exception.Message
    exit 1
} finally {
    if ($mounted) {
        EmitLog 'cleanup: dismounting ISO...'
        try { Dismount-DiskImage -ImagePath $isoItem.FullName -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($scratch) -and (Test-Path -LiteralPath $scratch)) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not [string]::IsNullOrWhiteSpace($tmpTarget) -and (Test-Path -LiteralPath $tmpTarget)) {
        Remove-Item -LiteralPath $tmpTarget -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Sweep any leftover .tmp-* siblings from prior interrupted runs.
    try {
        if (Test-Path -LiteralPath $WriteRoot) {
            Get-ChildItem -LiteralPath $WriteRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*.tmp-*' } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}
