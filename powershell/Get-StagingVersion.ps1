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

if (-not [string]::IsNullOrWhiteSpace($LocalProjectRoot)) {
    # Local build mode: read from the bundled Remote\ folder, never touch the share.
    $StagingRoot = Join-Path $LocalProjectRoot 'Staging'
} else {
    $shareHost = 'WIN-HQ5JDEACV3S'
    if ($ShareRoot -match '^\\\\([^\\]+)\\') { $shareHost = $Matches[1] }
    Connect-ShareCredentials -ShareHost $shareHost -User $ShareUser -Pass $SharePassword
    $StagingRoot = Join-Path $ShareRoot 'Remote\Staging'
}
# New fixed-path layout: Staging\AMD64\AMD64.wim  and  Staging\ISO\
$wimPath     = Join-Path $StagingRoot "$wfUpper\$wfUpper.wim"
$isoRoot     = Join-Path $StagingRoot 'ISO'

$output = [ordered]@{
    version         = 'unknown'
    buildDate       = ''
    workflowType    = $wfUpper
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
}

# Product/launcher versions come from bundled VERSION.json / GitHub latest.json.
$output.architectures = [ordered]@{
    AMD64 = [ordered]@{ wimBuildDate = ''; payloadHash = ''; enabled = $true }
    ARM64 = [ordered]@{ wimBuildDate = ''; payloadHash = ''; enabled = $false }
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

# --- ISO availability: Staging\ISO\ (new) with fallback to Staging\ root ----
try {
    $isoPattern = "*($wfUpper).iso"
    $isoFiles   = @()
    # Primary: new Staging\ISO\ folder
    if (Test-Path -LiteralPath $isoRoot) {
        $isoFiles = @(Get-ChildItem -LiteralPath $isoRoot -File -Filter '*.iso' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $isoPattern } |
            Sort-Object LastWriteTime -Descending)
    }
    # Fallback: ISOs placed directly in Staging\ root (old layout)
    if ($isoFiles.Count -eq 0) {
        $isoFiles = @(Get-ChildItem -LiteralPath $StagingRoot -File -Filter '*.iso' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $isoPattern } |
            Sort-Object LastWriteTime -Descending)
    }
    if ($isoFiles.Count -gt 0) {
        $output.isoAvailable = $true
        $output.isoFile      = $isoFiles[0].Name
        $isoYmd = $isoFiles[0].LastWriteTimeUtc.ToString('yyyy-MM-dd')
        $output.isoLastWrite = $isoFiles[0].LastWriteTimeUtc.ToString('o')
        $output.buildDate = $isoYmd
        if ($output.architectures.Contains($wfUpper)) {
            $output.architectures[$wfUpper].wimBuildDate = $isoYmd
        }
    }
} catch { }

# --- Pre-split staging availability (Option A) ------------------------------
# Reports whether a pre-split install*.swm set exists for this arch, and whether it
# matches the newest ISO (i.e. the next build will take the fast-copy path). Uses the
# SAME shared validator (Test-LWPreSplitSet) + image-version identity (Get-LWImageVersionId)
# as the builder's Get-LWPreSplitSet so the UI and the build agree.
try {
    $splitLib = Join-Path $PSScriptRoot 'lib\Split-LWImage.ps1'
    if (Test-Path -LiteralPath $splitLib) {
        . $splitLib
        $preSplitRoot = Join-Path $StagingRoot 'PreSplit'
        $archDir      = Join-Path $preSplitRoot $wfUpper
        if (Test-Path -LiteralPath $archDir) {
            # Newest ISO for this arch (same selection pattern the builder uses).
            $psIso      = $null
            $psIsoFiles = @()
            if (Test-Path -LiteralPath $isoRoot) {
                $psIsoFiles = @(Get-ChildItem -LiteralPath $isoRoot -File -Filter '*.iso' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*($wfUpper)*.iso" } | Sort-Object LastWriteTime -Descending)
            }
            if ($psIsoFiles.Count -eq 0) {
                $psIsoFiles = @(Get-ChildItem -LiteralPath $StagingRoot -File -Filter '*.iso' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*($wfUpper)*.iso" } | Sort-Object LastWriteTime -Descending)
            }
            if ($psIsoFiles.Count -gt 0) { $psIso = $psIsoFiles[0] }
            $currentId = if ($psIso) { Get-LWImageVersionId -Iso $psIso } else { $null }

            # Candidate order: 'current' marker's set first, then newest subfolders.
            $cands  = New-Object System.Collections.Generic.List[string]
            $marker = Join-Path $archDir 'current'
            if (Test-Path -LiteralPath $marker) {
                try {
                    $mk = Get-Content -Raw -LiteralPath $marker | ConvertFrom-Json
                    if ($mk.imageVersion) {
                        $c = Join-Path $archDir ([string]$mk.imageVersion)
                        if (Test-Path -LiteralPath $c) { $cands.Add($c) }
                    }
                } catch { }
            }
            foreach ($d in @(Get-ChildItem -LiteralPath $archDir -Directory -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending)) {
                if ($d.Name -like '*.tmp-*') { continue }
                if (-not ($cands -contains $d.FullName)) { $cands.Add($d.FullName) }
            }

            foreach ($setDir in $cands) {
                $chk = Test-LWPreSplitSet -SetDir $setDir
                if (-not $chk.Valid) { continue }
                if (-not $output.preSplitAvailable) {
                    $output.preSplitAvailable    = $true
                    $output.preSplitImageVersion = [string]$chk.Manifest.imageVersion
                }
                if ($psIso) {
                    $src = $chk.Manifest.source
                    $match = ([string]$src.isoName -eq $psIso.Name) -and
                             ([long]$src.isoSizeBytes -eq [long]$psIso.Length) -and
                             ([string]$chk.Manifest.imageVersion -eq $currentId)
                    if ($match) {
                        $output.preSplitMatchesIso   = $true
                        $output.preSplitImageVersion = [string]$chk.Manifest.imageVersion
                        break
                    }
                }
            }
        }
    }
} catch { }

# --- Build mode (WIM preferred over ISO) ------------------------------------
$output.buildMode = if ($output.wimAvailable) { 'wim' } elseif ($output.isoAvailable) { 'iso' } else { 'none' }

# Remove null isoFile key if no ISO found (keeps JSON tidy)
if (-not $output.isoFile) { $output.Remove('isoFile') }

$output | ConvertTo-Json -Compress -Depth 5
