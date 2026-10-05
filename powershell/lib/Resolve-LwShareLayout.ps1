<#
.SYNOPSIS
  Resolve ISO / PreSplit / WinPE-OCs roots for the deployment share.

.DESCRIPTION
  Functions only - safe to dot-source.   Prefers share-root folders:

    <ShareRoot>\ISO
    <ShareRoot>\PreSplit
    <ShareRoot>\WinPE-OCs          (arch cabs live in AMD64\ and ARM64\)
    <ShareRoot>\Edge

  HQ default ShareRoot is \\WIN-HQ5JDEACV3S\Images\FB Image Creation, so WinPE OCs are:

    \\WIN-HQ5JDEACV3S\Images\FB Image Creation\WinPE-OCs\AMD64
    \\WIN-HQ5JDEACV3S\Images\FB Image Creation\WinPE-OCs\ARM64

  Falls back to the legacy tree for ISO / PreSplit / Edge only:

    <ShareRoot>\Remote\Staging\ISO
    <ShareRoot>\Remote\Staging\PreSplit
    <ShareRoot>\Remote\Staging\Edge

  Legacy Remote\Staging\WinPE-OCs is no longer used on HQ (folder removed).

  LocalProjectRoot (dev / Local Build Mode) still uses <LocalProjectRoot>\Staging\...

  Destage (npm start, -DestageMedia) does NOT use LocalProjectRoot for ISO/PreSplit:
    ISO  = C:\Repos\Windows_Installation\UUP\25h2\ISO only (no share IsoRoot)
    PreSplit write/read = C:\Repos\Windows_Installation\UUP\25h2\PreSplit (flat set folders)
    WinPE-OCs prefer HQ Images\FB Image Creation\WinPE-OCs when reachable.
  Packaged production/Dev keep this share-root / legacy-staging resolver unchanged.

  A Google Drive folder URL is never a filesystem ShareRoot.
#>

function Get-LwHqShareRoot {
    return '\\WIN-HQ5JDEACV3S\Images\FB Image Creation'
}

function Get-LwHqWpeOcRoot {
    return (Join-Path (Get-LwHqShareRoot) 'WinPE-OCs')
}

function Test-LwShareDir {
    param([string]$Path)
    return (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path))
}

function Test-LwShareRootIsFilesystem {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '^(?i)https?://') { return $false }
    return $true
}

function Test-LwLooksLikeStagingRoot {
    param([string]$Path)
    if (-not (Test-LwShareRootIsFilesystem $Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    foreach ($n in @('ISO', 'PreSplit', 'WinPE-OCs', 'Edge')) {
        if (Test-Path -LiteralPath (Join-Path $Path $n)) { return $true }
    }
    return $false
}

function Resolve-LwGoogleDriveDesktopRoot {
    param(
        [string]$EnvRoot = $env:LONEWOLF_DRIVE_ROOT,
        [string]$HomeDir = $env:USERPROFILE
    )
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($EnvRoot) -and (Test-LwShareRootIsFilesystem $EnvRoot)) {
        $candidates.Add($EnvRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($HomeDir)) {
        $candidates.Add((Join-Path $HomeDir 'Google Drive'))
        $candidates.Add((Join-Path $HomeDir 'My Drive'))
        $candidates.Add((Join-Path $HomeDir 'Google Drive\My Drive'))
    }
    $candidates.Add('G:\My Drive')
    $candidates.Add('G:\')

    foreach ($c in $candidates) {
        if (Test-LwLooksLikeStagingRoot $c) { return $c }
        if (-not (Test-Path -LiteralPath $c -PathType Container)) { continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $c -Directory -ErrorAction SilentlyContinue)) {
            if (Test-LwLooksLikeStagingRoot $child.FullName) { return $child.FullName }
            foreach ($grand in @(Get-ChildItem -LiteralPath $child.FullName -Directory -ErrorAction SilentlyContinue)) {
                if (Test-LwLooksLikeStagingRoot $grand.FullName) { return $grand.FullName }
            }
        }
    }
    return $null
}

function Resolve-LwDevShareRoot {
    param([string]$ShareRoot = '')
    if (Test-LwLooksLikeStagingRoot $ShareRoot) {
        return [pscustomobject]@{ Kind = 'explicit'; ShareRoot = $ShareRoot }
    }
    if ($ShareRoot -match '^(?i)https?://') {
        return [pscustomobject]@{
            Kind       = 'rejected-url'
            ShareRoot  = $null
            Reason     = 'A Google Drive folder URL is not a Windows filesystem ShareRoot. Use Google Drive for Desktop or the HQ UNC share.'
        }
    }
    $drive = Resolve-LwGoogleDriveDesktopRoot
    if ($drive) {
        return [pscustomobject]@{ Kind = 'drive-desktop'; ShareRoot = $drive }
    }
    return [pscustomobject]@{
        Kind      = 'hq-unc'
        ShareRoot = (Get-LwHqShareRoot)
    }
}

function Resolve-LwWpeOcRoot {
    <#
    .SYNOPSIS
      Pick WinPE-OCs root (parent of AMD64\ / ARM64\). Prefer share-root, then HQ, never require legacy Staging.
    #>
    param(
        [string]$ShareRoot = '',
        [string]$LocalOcRoot = ''
    )
    if (Test-LwShareDir $LocalOcRoot) { return $LocalOcRoot }
    if (-not [string]::IsNullOrWhiteSpace($ShareRoot)) {
        $rootOc = Join-Path $ShareRoot 'WinPE-OCs'
        if (Test-LwShareDir $rootOc) { return $rootOc }
    }
    $hqOc = Get-LwHqWpeOcRoot
    if (Test-LwShareDir $hqOc) { return $hqOc }
    if (-not [string]::IsNullOrWhiteSpace($ShareRoot)) {
        return (Join-Path $ShareRoot 'WinPE-OCs')
    }
    return $hqOc
}

function Resolve-LwShareLayout {
    param(
        [string]$ShareRoot = '',
        [string]$LocalProjectRoot = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($LocalProjectRoot)) {
        $staging = Join-Path $LocalProjectRoot 'Staging'
        return [pscustomobject]@{
            Layout       = 'local'
            StagingRoot  = $staging
            IsoRoot      = Join-Path $staging 'ISO'
            PreSplitRoot = Join-Path $staging 'PreSplit'
            WpeOcRoot    = Join-Path $staging 'WinPE-OCs'
            EdgeRoot     = Join-Path $staging 'Edge'
        }
    }

    if ($ShareRoot -match '^(?i)https?://') {
        return [pscustomobject]@{
            Layout       = 'rejected-url'
            StagingRoot  = ''
            IsoRoot      = ''
            PreSplitRoot = ''
            WpeOcRoot    = ''
            EdgeRoot     = ''
        }
    }

    $legacyStaging = Join-Path $ShareRoot 'Remote\Staging'
    $rootIso = Join-Path $ShareRoot 'ISO'
    $rootPre = Join-Path $ShareRoot 'PreSplit'
    $rootOc  = Join-Path $ShareRoot 'WinPE-OCs'
    $rootEdge = Join-Path $ShareRoot 'Edge'
    $legacyIso = Join-Path $legacyStaging 'ISO'
    $legacyPre = Join-Path $legacyStaging 'PreSplit'
    $legacyEdge = Join-Path $legacyStaging 'Edge'
    $useRoot = (Test-LwShareDir $rootIso) -or (Test-LwShareDir $rootPre) -or (Test-LwShareDir $rootOc) -or (Test-LwShareDir $rootEdge)
    $wpeOcRoot = Resolve-LwWpeOcRoot -ShareRoot $ShareRoot

    if ($useRoot) {
        return [pscustomobject]@{
            Layout       = 'share-root'
            StagingRoot  = $(if (Test-LwShareDir $legacyStaging) { $legacyStaging } else { $ShareRoot })
            IsoRoot      = $(if (Test-LwShareDir $rootIso) { $rootIso } else { $legacyIso })
            PreSplitRoot = $(if (Test-LwShareDir $rootPre) { $rootPre } else { $legacyPre })
            WpeOcRoot    = $wpeOcRoot
            EdgeRoot     = $(if (Test-LwShareDir $rootEdge) { $rootEdge } else { (Join-Path $legacyStaging 'Edge') })
        }
    }

    return [pscustomobject]@{
        Layout       = 'legacy-staging'
        StagingRoot  = $legacyStaging
        IsoRoot      = $legacyIso
        PreSplitRoot = $legacyPre
        WpeOcRoot    = $wpeOcRoot
        EdgeRoot     = $legacyEdge
    }
}

function Get-LwDestageUupRoot {
    return 'C:\Repos\Windows_Installation\UUP\25h2'
}

function Get-LwDestageUupLayout {
    $root = Get-LwDestageUupRoot
    return [pscustomobject]@{
        Root         = $root
        IsoRoot      = Join-Path $root 'ISO'
        PreSplitRoot = Join-Path $root 'PreSplit'
    }
}

# Destage (npm start) media: ISO and PreSplit are local UUP only (no share ISO).
# WinPE-OCs come from Images\FB Image Creation\WinPE-OCs\{AMD64|ARM64} (HQ preferred).
function Resolve-LwDestageMediaLayout {
    param([string]$ShareRoot = '')
    $uup = Get-LwDestageUupLayout
    $share = Resolve-LwShareLayout -ShareRoot $ShareRoot
    $wpeOcRoot = Resolve-LwWpeOcRoot -ShareRoot $ShareRoot -LocalOcRoot $share.WpeOcRoot
    return [pscustomobject]@{
        Layout          = 'destage-uup'
        StagingRoot     = $share.StagingRoot
        IsoRoot         = $uup.IsoRoot
        IsoFallbackRoot = ''
        PreSplitRoot    = $uup.PreSplitRoot
        WpeOcRoot       = $wpeOcRoot
        UupRoot         = $uup.Root
        ShareLayout     = [string]$share.Layout
    }
}

function Initialize-LwDestageUupDirs {
    $uup = Get-LwDestageUupLayout
    foreach ($p in @($uup.Root, $uup.IsoRoot, $uup.PreSplitRoot)) {
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType Directory -Force -Path $p | Out-Null
        }
    }
    return $uup
}
