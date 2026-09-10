#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Reads ISO/WIM availability from the deployment share (ISO staging).
  Product and launcher versioning are not read from the share.

.DESCRIPTION
  Registers credentials for the share, then scans Staging for WIM and ISO files.
  Does not require VERSION.json on the share (that file is not hosted there).

  Also scans for pre-staged WIM and ISO files and reports build-mode availability:
    buildMode = "wim"   -  pre-staged WIM found (fastest, preferred)
    buildMode = "iso"   -  ISO found, no WIM (slower, no pre-staging needed)
    buildMode = "none"  -  neither found (not yet staged)

.OUTPUTS
  Single JSON object to stdout:
  {"version":"1.0.0","buildDate":"2026-06-18","workflowType":"AMD64",
   "wimLastModified":"2026-06-18T14:30:22Z","changelog":[...],
   "architectures":{"AMD64":{"wimBuildDate":"...","payloadHash":"","enabled":true},
                    "ARM64":{"wimBuildDate":"","payloadHash":"","enabled":false}},
   "wimAvailable":true,"isoAvailable":true,
   "isoFile":"25h2_updates_6.18(amd64).ISO","buildMode":"wim"}

  Share layout: Remote\Staging\ISO\ (and optional WIM / PreSplit). No launcher exe or VERSION.json.
#>

[CmdletBinding()]
param(
    [string]$ShareRoot        = '\\WIN-HQ5JDEACV3S\Images\FB Image Creation',
    [string]$ShareUser        = 'Reflect',
    [string]$SharePassword    = 'mer*HWE0upt*rqe@dud',
    [string]$WorkflowType     = 'AMD64',
    [string]$WindowsEdition   = 'Pro',  # Home | Pro. Presplit/ISO identity; not LoneWolf vs Quick Install.
    [string]$LocalProjectRoot = ''   # When non-empty: skip share auth and read from this local path instead
)

$ErrorActionPreference = 'SilentlyContinue'

# --- Share authentication -----------------------------------------------------
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

$wfUpper = $WorkflowType.ToUpper()
$winEdition = 'Pro'
if ($WindowsEdition -match '^(?i)home$') { $winEdition = 'Home' }

if ([string]::IsNullOrWhiteSpace($LocalProjectRoot)) {
    $shareHost = 'WIN-HQ5JDEACV3S'
    if ($ShareRoot -match '^\\\\([^\\]+)\\') { $shareHost = $Matches[1] }
    Connect-ShareCredentials -ShareHost $shareHost -User $ShareUser -Pass $SharePassword
}
$shareLayoutLib = Join-Path $PSScriptRoot 'lib\Resolve-LwShareLayout.ps1'
if (Test-Path -LiteralPath $shareLayoutLib) { . $shareLayoutLib }
$shareLayout = Resolve-LwShareLayout -ShareRoot $ShareRoot -LocalProjectRoot $LocalProjectRoot
$StagingRoot = $shareLayout.StagingRoot
$isoRoot     = $shareLayout.IsoRoot
$preSplitRootResolved = $shareLayout.PreSplitRoot
# WIM stays under Staging\<ARCH>\<ARCH>.wim (legacy Remote\Staging when that tree exists).
$wimPath     = Join-Path $StagingRoot "$wfUpper\$wfUpper.wim"

$output = [ordered]@{
    version         = 'unknown'
    buildDate       = ''
    workflowType    = $wfUpper
    windowsEdition  = $winEdition
    wimLastModified = ''
    changelog       = @()
    architectures   = $null
    wimAvailable    = $false
    isoAvailable    = $false
    isoFile         = $null
    buildMode       = 'none'
    # Pre-split (Option A) staging availability for the current arch's newest ISO.
    preSplitAvailable    = $false
    preSplitMatchesIso   = $false
    preSplitImageVersion = $null
    isoMissingReason     = $null
    shareLayout          = [string]$shareLayout.Layout
    isoRoot              = $isoRoot
    preSplitRoot         = $preSplitRootResolved
    wpeOcRoot            = [string]$shareLayout.WpeOcRoot
}

# Product/launcher versions come from bundled VERSION.json / GitHub latest.json.
$output.architectures = [ordered]@{
    AMD64 = [ordered]@{ wimBuildDate = ''; payloadHash = ''; enabled = $true }
    ARM64 = [ordered]@{ wimBuildDate = ''; payloadHash = ''; enabled = $true }
}
$verManifest = Join-Path $PSScriptRoot 'VERSION.json'
if (Test-Path -LiteralPath $verManifest) {
    try {
        $vj = Get-Content -Raw -LiteralPath $verManifest | ConvertFrom-Json
        foreach ($archName in @('AMD64', 'ARM64')) {
            $block = $null
            if ($vj.architectures -and $vj.architectures.$archName) { $block = $vj.architectures.$archName }
            if ($block -and $null -ne $block.enabled) {
                $output.architectures[$archName].enabled = [bool]$block.enabled
            }
        }
    } catch { }
}

# --- WIM availability + last-write-time fallback -----------------------------
try {
    # Primary: new layout Staging\AMD64\AMD64.wim
    # Fallback: old layout Staging\Windows *($wfUpper).wim
    $foundWim = $null
    if (Test-Path -LiteralPath $wimPath) {
        $foundWim = Get-Item -LiteralPath $wimPath -ErrorAction SilentlyContinue
    }
    if (-not $foundWim) {
        $oldPattern = "Windows *($wfUpper).wim"
        $foundWim = @(Get-ChildItem -LiteralPath $StagingRoot -File -Filter '*.wim' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $oldPattern } |
            Sort-Object LastWriteTime -Descending) | Select-Object -First 1
    }
    if ($foundWim) {
        $output.wimAvailable = $true
        $ts  = $foundWim.LastWriteTimeUtc
        $output.wimLastModified = $ts.ToString('o')
        $wimYmd = $ts.ToString('yyyy-MM-dd')
        if ($output.architectures.Contains($wfUpper)) {
            $output.architectures[$wfUpper].wimBuildDate = $wimYmd
        }
        $output.buildDate = $wimYmd
        if ($output.version -eq 'unknown') {
            $output.version = $ts.ToString('yyyyMMdd-HHmmss')
        }
    }
} catch { }

# Shared ISO/SKU helpers (Find-LWWindowsIso, Get-LWImageVersionId, Test-LWPreSplitSet).
$splitLib = Join-Path $PSScriptRoot 'lib\Split-LWImage.ps1'
$splitLibLoaded = $false
if (Test-Path -LiteralPath $splitLib) {
    try { . $splitLib; $splitLibLoaded = $true } catch { }
}

# --- ISO availability: Staging\ISO\ (home/pro in filename); legacy ISO\<SKU>\ ----
try {
    $foundIso = $null
    if ($splitLibLoaded -and (Get-Command -Name Find-LWWindowsIso -ErrorAction SilentlyContinue)) {
        $foundIso = Find-LWWindowsIso -StagingRoot $StagingRoot -IsoRoot $isoRoot -Arch $wfUpper -Edition $winEdition
    }
    if ($foundIso) {
        $output.isoAvailable = $true
        $output.isoFile      = $foundIso.Name
        $isoYmd = $foundIso.LastWriteTimeUtc.ToString('yyyy-MM-dd')
        $output.isoLastWrite = $foundIso.LastWriteTimeUtc.ToString('o')
        $output.buildDate = $isoYmd
        if ($output.architectures.Contains($wfUpper)) {
            $output.architectures[$wfUpper].wimBuildDate = $isoYmd
        }
    } elseif ($winEdition -eq 'Home') {
        $output.isoMissingReason = "No Windows Home ISO for $wfUpper in $isoRoot. Place a *($wfUpper)*.iso with home in the name under ISO\ (do not use the Pro image)."
    }
} catch { }

# --- Pre-split staging availability ----------------------------------------
# Identity = arch + Windows version (ISO slug) + Home/Pro. LoneWolf and Quick
# Install share the same set. Uses Test-LWPreSplitSet + Get-LWImageVersionId.
try {
    if ($splitLibLoaded) {
        $preSplitRoot = $preSplitRootResolved
        if ([string]::IsNullOrWhiteSpace($preSplitRoot)) { $preSplitRoot = Join-Path $StagingRoot 'PreSplit' }
        $psIso = $null
        if ($output.isoFile) {
            foreach ($dir in @(Get-LWIsoSearchDirs -StagingRoot $StagingRoot -IsoRoot $isoRoot -Edition $winEdition)) {
                $p = Join-Path $dir $output.isoFile
                if (Test-Path -LiteralPath $p) { $psIso = Get-Item -LiteralPath $p; break }
            }
        }
        $currentId = if ($psIso) { Get-LWImageVersionId -Iso $psIso -Edition $winEdition } else { $null }
        $legacyId  = if ($psIso) { Get-LWImageVersionId -Iso $psIso } else { $null }

        $cands = @(Get-LWPreSplitCandidateDirs -PreSplitRoot $preSplitRoot -Arch $wfUpper -Edition $winEdition)

        foreach ($setDir in $cands) {
            $chk = Test-LWPreSplitSet -SetDir $setDir
            if (-not $chk.Valid) { continue }
            $manEd = $null
            try {
                if ($chk.Manifest.PSObject.Properties['windowsEdition'] -and $chk.Manifest.windowsEdition) {
                    $manEd = [string]$chk.Manifest.windowsEdition
                } elseif ($chk.Manifest.PSObject.Properties['edition'] -and $chk.Manifest.edition) {
                    $manEd = [string]$chk.Manifest.edition
                }
            } catch { }
            if ($manEd) {
                $manNorm = if ($manEd -match '^(?i)home$') { 'Home' } else { 'Pro' }
                if ($manNorm -ne $winEdition) { continue }
            } elseif ($winEdition -ne 'Pro') {
                continue
            }
            if (-not $output.preSplitAvailable) {
                $output.preSplitAvailable    = $true
                $output.preSplitImageVersion = [string]$chk.Manifest.imageVersion
            }
            if ($psIso) {
                $src = $chk.Manifest.source
                $idOk = ([string]$chk.Manifest.imageVersion -eq $currentId) -or
                        ($winEdition -eq 'Pro' -and [string]$chk.Manifest.imageVersion -eq $legacyId)
                $match = $idOk -and
                         ([string]$src.isoName -eq $psIso.Name) -and
                         ([long]$src.isoSizeBytes -eq [long]$psIso.Length)
                if ($match) {
                    $output.preSplitMatchesIso   = $true
                    $output.preSplitImageVersion = [string]$chk.Manifest.imageVersion
                    break
                }
            }
        }
    }
} catch { }

# --- Build mode (WIM preferred over ISO) ------------------------------------
# Home is ISO-only: a staged WIM is not SKU-aware, so never treat it as a Home source.
if ($winEdition -eq 'Home' -and -not $output.isoAvailable) {
    $output.buildMode = 'none'
} else {
    $output.buildMode = if ($output.wimAvailable) { 'wim' } elseif ($output.isoAvailable) { 'iso' } else { 'none' }
}

# Remove null isoFile key if no ISO found (keeps JSON tidy)
if (-not $output.isoFile) { $output.Remove('isoFile') }
if (-not $output.isoMissingReason) { $output.Remove('isoMissingReason') }

$output | ConvertTo-Json -Compress -Depth 5
