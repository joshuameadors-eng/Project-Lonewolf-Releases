#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Project LoneWolf Launcher - ISO Unpack and WIM Capture

.DESCRIPTION
  Locates a Windows ISO in Remote\Staging\ISO\, mounts it, robocopy's the
  contents to a local temp folder (required because DISM cannot capture from
  a read-only virtual DVD drive), then runs DISM /capture-image to produce a
  WIM file at Remote\Staging\<arch>\<arch>.wim.

  The resulting WIM enables WIM mode in Invoke-LoneWolfBuild.ps1, which is
  significantly faster than mounting the ISO on every USB build.

  Run once after placing a new ISO in Remote\Staging\ISO\ on the share.

.PARAMETER ShareRoot
  UNC root of the deployment share.
  Default: \\WIN-HQ5JDEACV3S\Images\FB Image Creation

.PARAMETER WorkflowType
  Target architecture: AMD64 or ARM64. Default: AMD64

.PARAMETER LocalOnly
  Capture the WIM to -LocalOutputPath instead of writing directly to the share.
  Use this when the share blocks writes. Copy the output manually afterward.

.PARAMETER LocalOutputPath
  Destination folder when -LocalOnly is set. Default: C:\LWStaging

.PARAMETER SkipCapture
  Mount ISO and resolve paths, then exit without running DISM.
  Useful for validating connectivity.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File "...\Remote\Unpack-Staging.ps1" -WorkflowType AMD64 -LocalOnly

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File "...\Remote\Unpack-Staging.ps1" -WorkflowType AMD64
#>

[CmdletBinding()]
param(
    [string]$ShareRoot       = '\\WIN-HQ5JDEACV3S\Images\FB Image Creation',

    [ValidateSet('AMD64','ARM64')]
    [string]$WorkflowType    = 'AMD64',

    [switch]$LocalOnly,

    [string]$LocalOutputPath = 'C:\LWStaging',

    [switch]$SkipCapture
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$m)
    Write-Host ("[{0}] === {1} ===" -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Cyan }
function Write-Sub  { param([string]$m)
    Write-Host ("  [{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Write-OK   { param([string]$m)
    Write-Host ("  [{0}] OK: {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Green }
function Write-Warn { param([string]$m)
    Write-Host ("  [{0}] WARN: {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Yellow }
function Write-Fail { param([string]$m)
    Write-Host ("  [{0}] ERROR: {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$wfUpper     = $WorkflowType.ToUpper()
$StagingRoot = Join-Path $ShareRoot 'Remote\Staging'
$IsoRoot     = Join-Path $StagingRoot 'ISO'
$ArchRoot    = Join-Path $StagingRoot $wfUpper        # Staging\AMD64\
$wimName     = "$wfUpper.wim"                         # AMD64.wim
$wimTarget   = if ($LocalOnly) {
    New-Item -ItemType Directory -Force -Path $LocalOutputPath | Out-Null
    Join-Path $LocalOutputPath $wimName
} else {
    Join-Path $ArchRoot $wimName                      # Staging\AMD64\AMD64.wim
}

Write-Step 'Project LoneWolf - Unpack Staging'
Write-Sub "Share root    : $ShareRoot"
Write-Sub "Staging root  : $StagingRoot"
Write-Sub "ISO folder    : $IsoRoot"
Write-Sub "Arch folder   : $ArchRoot"
Write-Sub "Workflow      : $wfUpper"
if ($LocalOnly) {
    Write-Warn '-LocalOnly mode: WIM will be saved locally. Copy it to the share manually afterward.'
    Write-Sub "Local output  : $wimTarget"
    Write-Sub "Copy target   : $ArchRoot\$wimName"
} else {
    Write-Sub "WIM output    : $wimTarget"
}

# ---------------------------------------------------------------------------
# Step 1: Validate share and ISO folder are reachable
# ---------------------------------------------------------------------------
Write-Step 'Validating share connectivity'

if (-not (Test-Path -LiteralPath $IsoRoot)) {
    throw "ISO folder not found: $IsoRoot  -  create Staging\ISO\ on the share and place the ISO there."
}
Write-OK "ISO folder reachable: $IsoRoot"

# ---------------------------------------------------------------------------
# Step 2: Find ISO
# ---------------------------------------------------------------------------
Write-Step "Locating $wfUpper ISO in $IsoRoot"

$isoFiles = @(Get-ChildItem -LiteralPath $IsoRoot -File -Filter '*.iso' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*($wfUpper).iso" } |
    Sort-Object LastWriteTime -Descending)

if ($isoFiles.Count -eq 0) {
    throw "No ISO matching *($wfUpper).iso found in $IsoRoot"
}

$isoFile = $isoFiles[0]
Write-OK "Found ISO: $($isoFile.Name)  ($([math]::Round($isoFile.Length/1GB,2)) GB)"

# ---------------------------------------------------------------------------
# Step 3: Ensure arch output folder exists (on share or local)
# ---------------------------------------------------------------------------
if (-not $LocalOnly) {
    if (-not (Test-Path -LiteralPath $ArchRoot)) {
        Write-Sub "Creating arch folder: $ArchRoot"
        New-Item -ItemType Directory -Force -Path $ArchRoot | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Step 4: Mount ISO, robocopy to local temp, DISM capture
# ---------------------------------------------------------------------------
$diskImage  = $null
$isoMounted = $false

try {
    Write-Step 'Mounting ISO'
    $diskImage  = Mount-DiskImage -ImagePath $isoFile.FullName -PassThru -ErrorAction Stop
    $isoMounted = $true

    $driveLetter = ''
    for ($retry = 0; $retry -lt 5 -and [string]::IsNullOrEmpty($driveLetter); $retry++) {
        if ($retry -gt 0) { Start-Sleep -Seconds 1 }
        $vol = $diskImage | Get-Volume -ErrorAction SilentlyContinue
        if ($vol -and $vol.DriveLetter) { $driveLetter = $vol.DriveLetter + ':\' }
    }
    if ([string]::IsNullOrEmpty($driveLetter)) {
        throw 'Failed to get drive letter for mounted ISO after 5 attempts.'
    }
    Write-OK "ISO mounted at $driveLetter"

    if ($SkipCapture) {
        Write-Warn '(-SkipCapture specified - skipping DISM capture)'
    } else {
        # -- Step 4a: robocopy ISO to local temp (DISM cannot capture read-only DVD) --
        $stagingTemp = Join-Path $env:TEMP ("LWUnpack-$wfUpper-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        $captureTemp = Join-Path $env:TEMP ("LWCapture-$wfUpper-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.wim')

        Write-Step 'Copying ISO contents to local temp folder'
        Write-Sub "  $driveLetter -> $stagingTemp"
        Write-Sub "  (Required: DISM cannot capture from a read-only virtual drive)"
        New-Item -ItemType Directory -Force -Path $stagingTemp | Out-Null

        & robocopy.exe $driveLetter $stagingTemp /E /R:1 /W:1 /NP /NJH /NJS
        $rcExit = $LASTEXITCODE
        if ($rcExit -gt 7) {
            Remove-Item -LiteralPath $stagingTemp -Recurse -Force -ErrorAction SilentlyContinue
            throw "robocopy failed copying ISO to local temp (exit $rcExit)"
        }
        Write-OK "ISO contents staged locally at $stagingTemp"

        # -- Step 4b: DISM capture from local temp --
        Write-Step 'Capturing WIM with DISM (from local temp)'
        Write-Sub "Source  : $stagingTemp"
        Write-Sub "WIM     : $captureTemp"
        Write-Sub "This may take 20-60 minutes depending on ISO size."

        $imageName    = "Windows Setup ($wfUpper)"
        $captureStart = Get-Date

        & dism.exe /capture-image "/imagefile:$captureTemp" "/capturedir:$stagingTemp" "/name:$imageName" /compress:fast /verify

        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $stagingTemp -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $captureTemp -Force -ErrorAction SilentlyContinue
            throw "DISM /capture-image failed with exit code $LASTEXITCODE"
        }

        $elapsed = [math]::Round(((Get-Date) - $captureStart).TotalMinutes, 1)
        $sizeMb  = [math]::Round((Get-Item -LiteralPath $captureTemp).Length / 1MB, 0)
        Write-OK "WIM captured in $elapsed minutes ($sizeMb MB)"

        # -- Step 4c: Copy extracted ISO files into $ArchRoot for ESP pre-caching --
        # The build script (Invoke-LoneWolfBuild.ps1) reads $ArchRoot to build the ESP
        # partition on each USB. It needs the ISO boot files (boot/, efi/, bootmgr*, etc.)
        # but NOT install.wim/esd/swm (those are in the WIM we just captured).
        Write-Step 'Copying ISO boot files to arch folder (for ESP pre-caching)'
        Write-Sub "  $stagingTemp -> $ArchRoot"

        if ($LocalOnly) {
            $extractDst = $LocalOutputPath
        } else {
            $extractDst = $ArchRoot
            if (-not (Test-Path -LiteralPath $ArchRoot)) {
                New-Item -ItemType Directory -Force -Path $ArchRoot | Out-Null
            }
        }

        # Copy everything except the large install images (those are in the WIM) and
        # boot.wim (which is pre-injected by _inject-boot-wim.ps1 and must not be
        # overwritten with the stock ISO copy, which would break the sentinel age-check
        # and cause injection to be silently skipped on subsequent builds).
        & robocopy.exe $stagingTemp $extractDst /E /XF 'install.wim' 'install.esd' 'install.swm' 'boot.wim' /R:1 /W:1 /NP /NJH /NJS
        $rcExit2 = $LASTEXITCODE
        Remove-Item -LiteralPath $stagingTemp -Recurse -Force -ErrorAction SilentlyContinue
        if ($rcExit2 -gt 7) {
            throw "robocopy failed copying ISO boot files to arch folder (exit $rcExit2)"
        }
        Write-OK "ISO boot files extracted to $extractDst"

        # -- Step 4d: Move WIM to final destination --
        Write-Step 'Moving WIM to destination'
        Write-Sub "  -> $wimTarget"

        $dstDir = Split-Path $wimTarget -Parent
        if (-not (Test-Path -LiteralPath $dstDir)) {
            New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        }
        if (Test-Path -LiteralPath $wimTarget) {
            cmd /c "attrib -r `"$wimTarget`"" 2>$null | Out-Null
            Remove-Item -LiteralPath $wimTarget -Force -ErrorAction SilentlyContinue
        }

        Move-Item -LiteralPath $captureTemp -Destination $wimTarget -Force
        Write-OK "WIM saved: $wimTarget"

        # -- Step 4d: Update VERSION.json (skip in LocalOnly mode) --
        if ($LocalOnly) {
            Write-Warn 'Skipping VERSION.json update (LocalOnly mode). Update manually after copying WIM to share.'
        } else {
            Write-Step 'Updating VERSION.json'
            $versionFile = Join-Path $StagingRoot 'VERSION.json'
            try {
                if (Test-Path -LiteralPath $versionFile) {
                    $vj    = Get-Content -Raw -LiteralPath $versionFile | ConvertFrom-Json
                    $today = Get-Date -Format 'yyyy-MM-dd'
                    if ($vj.PSObject.Properties['buildDate'])    { $vj.buildDate = $today }
                    if ($vj.PSObject.Properties['architectures'] -and
                        $vj.architectures.PSObject.Properties[$wfUpper]) {
                        $vj.architectures.$wfUpper.wimBuildDate = $today
                    }
                    $json = $vj | ConvertTo-Json -Depth 10
                    [System.IO.File]::WriteAllText($versionFile, $json,
                        [System.Text.UTF8Encoding]::new($false))
                    Write-OK "VERSION.json updated (buildDate=$today)"
                } else {
                    Write-Warn "VERSION.json not found at $versionFile - skipping."
                }
            } catch {
                Write-Warn "VERSION.json update failed: $($_.Exception.Message) - continuing."
            }
        }
    }

} catch {
    Write-Fail $_.Exception.Message
    throw
} finally {
    if ($isoMounted -and $null -ne $diskImage) {
        Write-Sub 'Dismounting ISO...'
        try { Dismount-DiskImage -ImagePath $isoFile.FullName | Out-Null } catch { }
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Step 'Done'

if ($LocalOnly) {
    Write-Host ''
    Write-Host '  *** MANUAL TRANSFER REQUIRED ***' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Copy this file to the share:' -ForegroundColor Cyan
    Write-Host "    FROM : $wimTarget" -ForegroundColor White
    Write-Host "    TO   : $ArchRoot\$wimName" -ForegroundColor White
    Write-Host ''
    Write-Host '  Then update VERSION.json on the share if desired.' -ForegroundColor Cyan
    Write-Host ''
} else {
    Write-OK "Staging complete. LoneWolf builds will now use WIM mode."
    Write-Sub "WIM : $wimTarget"
}
