#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Project LoneWolf Launcher - Pre-Split install.wim staging producer (Option A).

.DESCRIPTION
  One-shot producer for the "staged pre-split install.wim" feature. Mounts a
  source Windows ISO, splits sources\install.wim (or exports+splits install.esd)
  into an install*.swm set (< 4 GB each, DISM /Split-Image /FileSize:3800
  /CheckIntegrity via the SHARED helper lib\Split-LWImage.ps1), and stages the
  result as a versioned set on the share (or the local dev tree):

    <Staging>\PreSplit\<ARCH>\<imageVersion>\
        install.swm, install2.swm, ...
        presplit-manifest.json
    <Staging>\PreSplit\<ARCH>\current   (JSON marker naming the active set)

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
  Dev mode. When non-empty this is used as ProjectRoot (e.g. <appPath>\Remote):
  share auth is skipped and the set is written to the LOCAL Remote\Staging tree
  ("staged for upload to the share").

.PARAMETER IsoPath
  Explicit source ISO. Default: newest *(<ARCH>)*.iso by LastWriteTime in
  Staging\ISO\ (fallback Staging\ root).

.PARAMETER Force
  Re-stage even if a valid set already exists for this image version. The new set
  is written to a temp sibling and atomically swapped in, so a failed re-stage
  never corrupts the existing known-good set.

.PARAMETER FileSizeMb
  DISM /Split-Image /FileSize (MB). Default 3800 - MUST match the builder's
  on-the-fly split or the sets are not interchangeable.

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

    [string] $ShareRoot        = '\\WIN-HQ5JDEACV3S\Images\FB Image Creation',
    [string] $ShareUser        = 'Reflect',
    [string] $SharePassword    = 'mer*HWE0upt*rqe@dud',
    [string] $LocalProjectRoot = '',
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
$isLocal = -not [string]::IsNullOrWhiteSpace($LocalProjectRoot)
if ($isLocal) {
    $ProjectRoot = $LocalProjectRoot
} else {
    $ProjectRoot = Join-Path $ShareRoot 'Remote'
}
$StagingRoot  = Join-Path $ProjectRoot 'Staging'
$IsoRoot      = Join-Path $StagingRoot 'ISO'
$PreSplitRoot = Join-Path $StagingRoot 'PreSplit'
$ArchPreSplit = Join-Path $PreSplitRoot $wfUpper

# Launcher version for the manifest's producedByLauncherVersion field.
$launcherVersion = 'unknown'
try {
    $vf = Join-Path $PSScriptRoot 'VERSION.json'
    if (Test-Path -LiteralPath $vf) {
        $vj = Get-Content -Raw -LiteralPath $vf | ConvertFrom-Json
        if ($vj.launcherVersion) { $launcherVersion = [string]$vj.launcherVersion }
    }
} catch { }

Emit @{ event='init'; stagingRoot=$StagingRoot; preSplitRoot=$PreSplitRoot; workflowType=$wfUpper; local=$isLocal }

# --- Share auth / reachability -----------------------------------------------
if ($isLocal) {
    EmitLog "local mode: staging pre-split set into the LOCAL Remote\Staging tree (for upload to the share); share auth skipped"
    if (-not (Test-Path -LiteralPath $LocalProjectRoot)) {
        EmitError "local mode: LocalProjectRoot not found: $LocalProjectRoot"; exit 1
    }
} else {
    $shareHost = 'WIN-HQ5JDEACV3S'
    if ($ShareRoot -match '^\\\\([^\\]+)\\') { $shareHost = $Matches[1] }
    Connect-ShareCredentials -ShareHost $shareHost -User $ShareUser -Pass $SharePassword
    if (-not (Test-Path -LiteralPath $ShareRoot)) {
        EmitError "cannot reach share: $ShareRoot"; exit 1
    }
}

# --- Select source ISO --------------------------------------------------------
EmitPhase 'stage-mount'
$isoItem = $null
if (-not [string]::IsNullOrWhiteSpace($IsoPath)) {
    if (-not (Test-Path -LiteralPath $IsoPath)) { EmitError "IsoPath not found: $IsoPath"; exit 1 }
    $isoItem = Get-Item -LiteralPath $IsoPath
} else {
    $isoFiles = @()
    if (Test-Path -LiteralPath $IsoRoot) {
        $isoFiles = @(Get-ChildItem -Path $IsoRoot -Filter "*($wfUpper)*.iso" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    }
    if ($isoFiles.Count -eq 0) {
        $isoFiles = @(Get-ChildItem -Path $StagingRoot -Filter "*($wfUpper)*.iso" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    }
    if ($isoFiles.Count -eq 0) {
        EmitError "no matching *($wfUpper)*.iso found in $IsoRoot or $StagingRoot"; exit 1
    }
    $isoItem = $isoFiles[0]
}

# --- Dot-source the SHARED split lib (same file the builder job uses) ---------
$SplitLibPath = Join-Path $PSScriptRoot 'lib\Split-LWImage.ps1'
if (-not (Test-Path -LiteralPath $SplitLibPath)) {
    EmitError "shared split lib not found: $SplitLibPath"; exit 1
}
. $SplitLibPath

# --- Compute image-version identity + target ----------------------------------
$imageVersion = Get-LWImageVersionId -Iso $isoItem
$Target       = Join-Path $ArchPreSplit $imageVersion
EmitLog "pre-split: iso='$($isoItem.Name)' imageVersion='$imageVersion' target='$Target'"

# --- Idempotent no-op when a valid set already exists (unless -Force) ---------
if ((Test-Path -LiteralPath $Target) -and -not $Force) {
    $chk = Test-LWPreSplitSet -SetDir $Target
    if ($chk.Valid) {
        EmitLog "already-staged: a valid pre-split set for '$($isoItem.Name)' exists at $Target - nothing to do (pass -Force to re-stage)"
        EmitDone $true 'already-staged'
        exit 0
    }
    EmitLog "existing set at $Target is invalid ($($chk.Reason)) - re-staging over it"
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
    EmitPhase 'stage-split'
    EmitProgress 'stage-split' 0
    $scratch        = Join-Path $env:TEMP ('LW-Stage-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $scratchSources = Join-Path $scratch 'sources'
    New-Item -ItemType Directory -Force -Path $scratchSources | Out-Null
    Split-LWImageForFat32 -SourceSourcesDir $isoSources -DestSourcesDir $scratchSources -FileSizeMb $FileSizeMb -Emit { param($m) EmitLog $m } -Progress { param($p) EmitProgress 'stage-split' $p }
    EmitProgress 'stage-split' 100

    # Chunk set: install*.swm normally; install.wim/.esd when the image was <= 4 GB.
    $chunkFiles = @(Get-ChildItem -LiteralPath $scratchSources -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^install(\d*)\.(swm|wim|esd)$' } |
        Sort-Object Name)
    if ($chunkFiles.Count -eq 0) {
        throw "stage-split produced no install*.swm (or install image) chunks in $scratchSources"
    }

    # -- Copy the set to a temp sibling of the final target (atomic swap later) --
    EmitPhase 'stage-copy'
    EmitProgress 'stage-copy' 0
    New-Item -ItemType Directory -Force -Path $ArchPreSplit | Out-Null
    $tmpTarget = "$Target.tmp-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    New-Item -ItemType Directory -Force -Path $tmpTarget | Out-Null
    $robPatterns = @('install*.swm', 'install.wim', 'install.esd')
    & robocopy.exe $scratchSources $tmpTarget @robPatterns /R:2 /W:5 /NP /NJH /NJS | Out-Null
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
            splitFileSizeMb      = $FileSizeMb
            chunks               = $chunkObjs
        }
        producedByLauncherVersion = $launcherVersion
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

    # -- Update the 'current' marker --------------------------------------------
    $currentMarker = Join-Path $ArchPreSplit 'current'
    $curObj = [ordered]@{ imageVersion = $imageVersion; updatedUtc = $nowUtc }
    [System.IO.File]::WriteAllText($currentMarker, ($curObj | ConvertTo-Json -Compress),
        [System.Text.UTF8Encoding]::new($false))
    EmitProgress 'stage-verify' 100

    EmitLog "staged pre-split set at $Target ($($chunkFiles.Count) chunk(s), sourceKind=$sourceKind, imageVersion=$imageVersion)"
    if ($isLocal) {
        EmitLog "local mode: upload '$ArchPreSplit' to the share to make this set available to network builds"
    }
    EmitDone $true 'staged'

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
        if (Test-Path -LiteralPath $ArchPreSplit) {
            Get-ChildItem -LiteralPath $ArchPreSplit -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*.tmp-*' } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}
