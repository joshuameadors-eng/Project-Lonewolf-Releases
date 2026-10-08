#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Pre-process install media into an Image Ready package (destage producer).

.DESCRIPTION
  Builds a full bootable media package under PreSplit\<set>\:
    1. Pre-split install.wim into install*.swm and mirror the rest of the ISO tree
    2. Export startnet / WinPeUi-injected boot.wim into the same set\sources

  Target layout comes from -MediaSource:
    googleDrive - Drive Desktop / local UUP staging root
    share       - HQ share ISO\ + PreSplit\ (same package shape as Drive)

  USB Rebuild can copy the package without remounting the ISO.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('AMD64', 'ARM64')]
    [string] $WorkflowType,

    [ValidateSet('Home', 'Pro')]
    [string] $WindowsEdition = 'Pro',

    [string] $ShareRoot = '',
    [string] $IsoPath = '',
    [string] $AppResourcesPath = '',
    [ValidateSet('local', 'share', 'googleDrive', '')]
    [string] $MediaSource = 'googleDrive',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$stagePs = Join-Path $here 'Stage-PreSplitImage.ps1'
$buildPs = Join-Path $here 'Invoke-LoneWolfBuild.ps1'
$layoutLib = Join-Path $here 'lib\Resolve-LwShareLayout.ps1'
$splitLib = Join-Path $here 'lib\Split-LWImage.ps1'
if (Test-Path -LiteralPath $layoutLib) { . $layoutLib }
if (Test-Path -LiteralPath $splitLib) { . $splitLib }

function Emit-StageDrive {
    param([hashtable]$Data)
    [Console]::Out.WriteLine(($Data | ConvertTo-Json -Compress -Depth 4))
}

$ms = if ([string]::IsNullOrWhiteSpace($MediaSource)) { 'googleDrive' } else { $MediaSource }
if ($ms -eq 'local') { $ms = 'googleDrive' }

$stagingRoot = $ShareRoot
$usedLocalStagingRoot = $false
if ($ms -eq 'share') {
    if ([string]::IsNullOrWhiteSpace($stagingRoot) -and (Get-Command -Name Get-LwHqShareRoot -ErrorAction SilentlyContinue)) {
        $stagingRoot = Get-LwHqShareRoot
    }
    if ([string]::IsNullOrWhiteSpace($stagingRoot)) {
        Emit-StageDrive @{ event = 'error'; disk = -1; message = 'HQ share root not found for Image Ready share staging.' }
        exit 1
    }
} else {
    # Prefer an explicit ShareRoot that already looks like staging (local UUP or Drive
    # desktop). Only auto-detect Google Drive for Desktop when ShareRoot is empty.
    if (-not [string]::IsNullOrWhiteSpace($stagingRoot) -and (Get-Command -Name Test-LwLooksLikeStagingRoot -ErrorAction SilentlyContinue) -and
        (Test-LwLooksLikeStagingRoot -Path $stagingRoot)) {
        $usedLocalStagingRoot = $true
    } elseif ([string]::IsNullOrWhiteSpace($stagingRoot) -or -not (Test-Path -LiteralPath $stagingRoot)) {
        $stagingRoot = Resolve-LwGoogleDriveDesktopRoot
    }
    if ([string]::IsNullOrWhiteSpace($stagingRoot)) {
        Emit-StageDrive @{ event = 'error'; disk = -1; message = 'Staging root not found. Pass -ShareRoot (local UUP) or mount Google Drive / set LONEWOLF_DRIVE_ROOT.' }
        exit 1
    }
}

$destageLayout = Resolve-LwDestageMediaLayout -ShareRoot $stagingRoot -MediaSource $ms
if ([string]::IsNullOrWhiteSpace($destageLayout.PreSplitRoot) -or [string]::IsNullOrWhiteSpace($destageLayout.IsoRoot)) {
    Emit-StageDrive @{ event = 'error'; disk = -1; message = "Staging layout incomplete under '$stagingRoot' (need ISO\ and PreSplit\)." }
    exit 1
}

$wfUpper = $WorkflowType.ToUpper()
$winEdition = if ($WindowsEdition -match '^(?i)home$') { 'Home' } else { 'Pro' }

$isoItem = $null
if (-not [string]::IsNullOrWhiteSpace($IsoPath)) {
    if (-not (Test-Path -LiteralPath $IsoPath)) {
        Emit-StageDrive @{ event = 'error'; disk = -1; message = "IsoPath not found: $IsoPath" }
        exit 1
    }
    $isoItem = Get-Item -LiteralPath $IsoPath
} elseif (Get-Command -Name Find-LWWindowsIso -ErrorAction SilentlyContinue) {
    $isoItem = Find-LWWindowsIso -StagingRoot $destageLayout.StagingRoot -IsoRoot $destageLayout.IsoRoot -Arch $wfUpper -Edition $winEdition
}
if (-not $isoItem) {
    Emit-StageDrive @{ event = 'error'; disk = -1; message = "No matching $winEdition ISO for $wfUpper under '$($destageLayout.IsoRoot)'" }
    exit 1
}

$imageVersion = Get-LWImageVersionId -Iso $isoItem -Edition $winEdition
$preSplitSetDir = Join-Path $destageLayout.PreSplitRoot $imageVersion

Emit-StageDrive @{
    event            = 'init'
    disk             = 0
    shareRoot        = $stagingRoot
    preSplitRoot     = $destageLayout.PreSplitRoot
    preSplitSetDir   = $preSplitSetDir
    workflowType     = $WorkflowType
    windowsEdition   = $WindowsEdition
    producer         = 'Stage-GoogleDriveMedia'
    mediaSource      = $ms
    localStagingRoot = $usedLocalStagingRoot
}

Emit-StageDrive @{ event = 'phase'; disk = 0; phase = 'stage-drive-presplit' }

$preArgs = @(
    '-WorkflowType', $WorkflowType,
    '-WindowsEdition', $WindowsEdition,
    '-ShareRoot', $stagingRoot,
    '-MediaSource', $ms
)
if ($AppResourcesPath) { $preArgs += '-AppResourcesPath', $AppResourcesPath }
if ($IsoPath) { $preArgs += '-IsoPath', $IsoPath }
if ($Force) { $preArgs += '-Force' }

& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stagePs @preArgs
if ($LASTEXITCODE -ne 0) {
    Emit-StageDrive @{ event = 'error'; disk = -1; message = "Pre-split staging failed (exit $LASTEXITCODE)" }
    exit $LASTEXITCODE
}

Emit-StageDrive @{ event = 'phase'; disk = 0; phase = 'stage-drive-bootwim' }

$bootArgs = @(
    '-WorkflowType', $WorkflowType,
    '-DiskNumbers', '0',
    '-WindowsEdition', $WindowsEdition,
    '-ShareRoot', $stagingRoot,
    '-MediaSource', $ms,
    '-ExportStagedBootWimSetDir', $preSplitSetDir,
    '-AppResourcesPath', $AppResourcesPath
)
if ($IsoPath) { $bootArgs += '-StagingIsoPath', $IsoPath }
else { $bootArgs += '-StagingIsoPath', $isoItem.FullName }

& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $buildPs @bootArgs
if ($LASTEXITCODE -ne 0) {
    Emit-StageDrive @{ event = 'error'; disk = -1; message = "boot.wim export failed (exit $LASTEXITCODE)" }
    exit $LASTEXITCODE
}

$doneWhere = if ($ms -eq 'share') {
    'HQ share PreSplit (Image Ready package)'
} elseif ($usedLocalStagingRoot) {
    'local PreSplit (Image Ready package)'
} else {
    'Drive PreSplit'
}
Emit-StageDrive @{ event = 'done'; disk = 0; success = $true; message = "Image Ready staging complete ($doneWhere set $imageVersion)" }
exit 0
