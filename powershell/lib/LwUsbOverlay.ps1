# LoneWolf USB data-partition overlay profile.
# Full Windows Updates (Intel/AMD and Snapdragon, not Quick Install) stages the
# Windows Update payload. Both Quick Install workflows do not. Arch selects the
# identity (Snapdragon vs Intel/AMD, bootaa64 vs bootx64).
# Quick Install boots Deploy\TechInstall-QuickInstall.cmd renamed to
# FirstBase\Deploy\TechInstall.cmd. Full updates boot Deploy\TechInstall.cmd.
# WIN-INSTALL still stages TechInstall-Install.cmd under that same dest name.
# Do not special-case Snapdragon updates away from the ARM64 profile.

function Get-LwUsbOverlayProfile {
    param(
        [string]$WorkflowType = '',
        [bool]$QuickInstall = $false,
        [bool]$NoPayload = $false
    )
    $arch = if ([string]$WorkflowType -match 'ARM') { 'ARM64' } else { 'AMD64' }
    $kind = if ($QuickInstall) { 'quick-install' } elseif ($NoPayload) { 'win-install' } else { 'updates' }
    # Quick Install is renamed onto Deploy\TechInstall.cmd so WinPE startnet
    # still finds one entry point. It does not carry the update-loop payload.
    $techSrc = switch ($kind) {
        'win-install'   { 'Deploy\TechInstall-Install.cmd' }
        'quick-install' { 'Deploy\TechInstall-QuickInstall.cmd' }
        default         { 'Deploy\TechInstall.cmd' }
    }
    # Same hidden set the full AMD64 and ARM64 builders already apply.
    # Boot/media at the volume root is Hidden+System. FirstBase is Hidden+System.
    # fb-im.cmd stays visible. The volume icon is FirstBase\FirstBase.ico.
    $hidden = @(
        'boot', 'boot.disabled',
        'bootmgr', 'bootmgr.efi', 'bootmgr.disabled', 'bootmgr.efi.disabled',
        'setup.exe', 'setup.exe.disabled',
        'autorun.inf', 'autorun.inf.disabled',
        'sources', 'sources.disabled',
        'efi', 'EFI', 'efi.disabled', 'EFI.disabled',
        'support', 'Support', 'support.disabled', 'Support.disabled'
    )
    [pscustomobject]@{
        Kind               = $kind
        Arch               = $arch
        ArchLabel          = $(if ($arch -eq 'ARM64') { 'Snapdragon' } else { 'Intel/AMD' })
        EfiRemovable       = $(if ($arch -eq 'ARM64') { 'bootaa64.efi' } else { 'bootx64.efi' })
        VolumeLabel        = 'LoneWolf'
        TechInstallSource  = $techSrc
        TechInstallDest    = 'FirstBase\Deploy\TechInstall.cmd'
        IconSource         = 'FirstBase.ico'
        IconDest           = 'FirstBase\FirstBase.ico'
        AutorunIcon        = 'FirstBase\FirstBase.ico'
        HiddenRootItems    = $hidden
        HideFirstBase      = $true
        VisibleRootItems   = @('fb-im.cmd')
    }
}

function Move-LwUsbMediaRootArtifacts {
    param([Parameter(Mandatory)][string] $VolRoot)
    if ([string]::IsNullOrWhiteSpace($VolRoot)) { return }
    $vol = $VolRoot.TrimEnd('\') + '\'
    $fbDir = Join-Path $vol 'FirstBase'
    if (-not (Test-Path -LiteralPath $fbDir)) {
        New-Item -ItemType Directory -Path $fbDir -Force | Out-Null
    }
    foreach ($leaf in @('current', 'current.json', 'presplit-manifest.json')) {
        $src = Join-Path $vol $leaf
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $fbDir $leaf
        if (Test-Path -LiteralPath $dst) {
            & attrib.exe -H -S -R $dst 2>&1 | Out-Null
            Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
        }
        & attrib.exe -H -S -R $src 2>&1 | Out-Null
        Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
    }
}

# Quick Install lands at stock OOBE. Full updates keep the audit unattend
# (specialize SetupComplete, oobeSystem Reseal Audit, auditUser strip).
function Get-LwUsbOverlayUnattendSource {
    param(
        [bool]$QuickInstall = $false
    )
    if ($QuickInstall) { return 'Policy\autounattend-quickinstall.xml' }
    return 'Policy\autounattend.xml'
}

function Assert-LwQuickInstallUnattend {
    param([Parameter(Mandatory)][string]$PartRoot)
    $path = Join-Path $PartRoot 'FirstBase\Autounattend.xml'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "FATAL: Quick Install unattend missing at '$path'."
    }
    $body = [System.IO.File]::ReadAllText($path)
    if ($body -match '<Mode>\s*Audit\s*</Mode>' -or $body -match '<RunSynchronous[\s>]') {
        throw "FATAL: Quick Install unattend at '$path' still reseals to Audit or runs SetupComplete."
    }
}

# Full Windows Updates for Intel/AMD (AMD64) and Snapdragon (ARM64).
# Quick Install and WIN-INSTALL do not stage the update loop.
function Test-LwStageWindowsUpdatePayload {
    param(
        [string]$WorkflowType = '',
        [bool]$QuickInstall = $false,
        [bool]$NoPayload = $false
    )
    if ($QuickInstall -or $NoPayload) { return $false }
    $raw = ([string]$WorkflowType).ToUpperInvariant()
    if ($raw -match '^(QUICK-INSTALL-|WIN-INSTALL-)') { return $false }
    $bare = [regex]::Replace($raw, '^(QUICK-INSTALL-|WIN-INSTALL-|LONEWOLF-)', '')
    return ($bare -eq 'ARM64' -or $bare -eq 'AMD64')
}

# WinPE-Startnet.cmd is injected into boot.wim. Full Snapdragon Updates also
# stages a copy under FirstBase\Deploy. Quick Install must not drop that copy
# (or a leftover from a prior Updates destage) into Deploy.
function Test-LwQuickInstallSkipDeployOverlayDest {
    param([string]$Destination)
    $dst = ([string]$Destination).Replace('/', '\')
    return ($dst -eq 'FirstBase\Deploy\WinPE-Startnet.cmd')
}

function Remove-LwQuickInstallStartnetFromDeploy {
    param([Parameter(Mandatory)][string]$PartRoot)
    $path = Join-Path $PartRoot 'FirstBase\Deploy\WinPE-Startnet.cmd'
    if (-not (Test-Path -LiteralPath $path)) { return }
    & attrib.exe -R -H -S $path 2>&1 | Out-Null
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

# Update-loop scripts, Edge, and SetupComplete. The fb-im tool front-end stays.
function Test-LwUpdatePayloadOverlayDest {
    param([string]$Destination)
    $dst = ([string]$Destination).Replace('/', '\')
    if ($dst -notlike 'FirstBase\WUPayload\*') { return $false }
    if ($dst -eq 'FirstBase\WUPayload\Tools\fb-im.ps1') { return $false }
    if ($dst -eq 'FirstBase\WUPayload\Tools\fb-dump.ps1') { return $false }
    return $true
}

function Remove-LwStagedWindowsUpdatePayload {
    param([Parameter(Mandatory)][string]$PartRoot)
    $wu = Join-Path $PartRoot 'FirstBase\WUPayload'
    if (-not (Test-Path -LiteralPath $wu)) { return }
    & attrib.exe -R -H -S $wu /D /S 2>&1 | Out-Null
    Get-ChildItem -LiteralPath $wu -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSIsContainer -and $_.Name -eq 'Tools') {
            Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -ne 'fb-im.ps1' -and $_.Name -ne 'fb-dump.ps1') {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        } else {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Copy-LwOverlayPayloadFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    $parent = Split-Path -Parent $Destination
    if ($parent) {
        if (Test-Path -LiteralPath $parent) {
            # A prior destage marks FirstBase Hidden+System. Copy-Item -Force
            # cannot replace a Hidden+System file and SilentlyContinue used to
            # drop that failure, so TechInstall.cmd never landed.
            & attrib.exe -R -H -S $parent /D 2>&1 | Out-Null
        } else {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
    }
    if (Test-Path -LiteralPath $Destination) {
        & attrib.exe -R -H -S $Destination 2>&1 | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return (Test-Path -LiteralPath $Destination)
}

function Assert-LwUpdatesOverlayTechInstall {
    param(
        [Parameter(Mandatory)][string]$PartRoot,
        [string]$WorkflowType = '',
        [bool]$QuickInstall = $false,
        [bool]$NoPayload = $false
    )
    $profile = Get-LwUsbOverlayProfile -WorkflowType $WorkflowType -QuickInstall $QuickInstall -NoPayload $NoPayload
    # WIN-INSTALL keeps its own script. Updates and Quick Install both land a
    # FirstBase\Deploy\TechInstall.cmd (quick-install is the renamed install script).
    if ($profile.Kind -eq 'win-install') { return }
    $dest = Join-Path $PartRoot $profile.TechInstallDest
    if (-not (Test-Path -LiteralPath $dest)) {
        throw ("FATAL: TechInstall.cmd missing after {0} {1} overlay at '{2}'. Stage {3}." -f $profile.Arch, $profile.Kind, $dest, $profile.TechInstallSource)
    }
}

function Unlock-LwUsbOverlayForCopy {
    param([Parameter(Mandatory)][string]$PartRoot)
    if ([string]::IsNullOrWhiteSpace($PartRoot)) { return }
    $fb = Join-Path $PartRoot 'FirstBase'
    if (Test-Path -LiteralPath $fb) {
        & attrib.exe -R -H -S $fb /D /S 2>&1 | Out-Null
    }
}

function Copy-LwEdgeOfflineInstaller {
    <#
    .SYNOPSIS
        Copy / download Microsoft Edge Enterprise MSI/EXE onto the USB WUPayload.
    .NOTES
        Used by Full Rebuild overlay cache and by Quick Update (-OverlayOnly) disk jobs
        (this lib is dotted into Start-Job). Search order: share EdgeRoot, ContentRoot\Edge,
        then enterprise download. Does not delete tools\ or ContentRoot sources.
    #>
    param(
        [Parameter(Mandatory)][string]$WuPayloadRoot,
        [string]$Arch = '',
        [string]$ContentRoot = '',
        [string]$EdgeShareRoot = ''
    )
    if ([string]::IsNullOrWhiteSpace($Arch)) { $Arch = 'AMD64' }
    if ($Arch -match 'ARM') { $Arch = 'ARM64' } else { $Arch = 'AMD64' }

    $wu = $WuPayloadRoot
    try {
        if (-not (Test-Path -LiteralPath $wu)) {
            New-Item -ItemType Directory -Path $wu -Force | Out-Null
        }
    } catch {}

    $ps1Src = ''
    if ($ContentRoot) { $ps1Src = Join-Path $ContentRoot 'Install-FbMicrosoftEdge.ps1' }
    if ($ps1Src -and (Test-Path -LiteralPath $ps1Src)) {
        Copy-Item -LiteralPath $ps1Src -Destination (Join-Path $wu 'Install-FbMicrosoftEdge.ps1') -Force -ErrorAction SilentlyContinue
    }

    $dstDir = Join-Path $wu ("Edge\{0}" -f $Arch)
    try { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null } catch {}

    $wantName = if ($Arch -eq 'ARM64') { 'MicrosoftEdgeEnterpriseARM64.msi' } else { 'MicrosoftEdgeEnterpriseX64.msi' }
    $copied = $null
    $searchRoots = New-Object System.Collections.Generic.List[string]
    if ($EdgeShareRoot) {
        [void]$searchRoots.Add((Join-Path $EdgeShareRoot $Arch))
        [void]$searchRoots.Add($EdgeShareRoot)
    }
    if ($ContentRoot) {
        [void]$searchRoots.Add((Join-Path $ContentRoot ("Edge\{0}" -f $Arch)))
        [void]$searchRoots.Add((Join-Path $ContentRoot 'Edge'))
    }

    foreach ($root in $searchRoots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $exact = Join-Path $root $wantName
        if (Test-Path -LiteralPath $exact) {
            Copy-Item -LiteralPath $exact -Destination (Join-Path $dstDir $wantName) -Force -ErrorAction SilentlyContinue
            $copied = Join-Path $dstDir $wantName
            break
        }
        $hit = @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '\.(msi|exe)$' -and $_.Name -match 'edge' } |
            Select-Object -First 1)
        if ($hit) {
            Copy-Item -LiteralPath $hit[0].FullName -Destination (Join-Path $dstDir $hit[0].Name) -Force -ErrorAction SilentlyContinue
            $copied = Join-Path $dstDir $hit[0].Name
            break
        }
    }

    if (-not $copied) {
        $url = $null
        try {
            $wantArch = if ($Arch -eq 'ARM64') { 'arm64' } else { 'x64' }
            $products = Invoke-RestMethod -Uri 'https://edgeupdates.microsoft.com/api/products?view=enterprise' -TimeoutSec 45
            $stable = @($products | Where-Object { [string]$_.Product -eq 'Stable' } | Select-Object -First 1)
            foreach ($product in $stable) {
                foreach ($rel in @($product.Releases)) {
                    if ([string]$rel.Platform -notmatch '(?i)Windows') { continue }
                    if ([string]$rel.Architecture -notmatch ("(?i)^{0}$" -f [regex]::Escape($wantArch))) { continue }
                    foreach ($art in @($rel.Artifacts)) {
                        if ([string]$art.ArtifactName -match '(?i)msi' -and [string]$art.Location) {
                            $url = [string]$art.Location
                            break
                        }
                    }
                    if ($url) { break }
                }
            }
        } catch {}
        if (-not $url -and $Arch -ne 'ARM64') {
            $url = 'https://go.microsoft.com/fwlink/?linkid=2093437'
        }
        if ($url) {
            $out = Join-Path $dstDir $wantName
            try {
                Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 180
                $len = 0
                try { $len = [int64](Get-Item -LiteralPath $out).Length } catch {}
                if ($len -ge 1000000) { $copied = $out }
                else { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
            } catch {}
        }
    }

    if ($copied) {
        if (Get-Command -Name EmitLog -ErrorAction SilentlyContinue) {
            EmitLog -Disk 0 -Msg ("edge: staged {0} installer {1}" -f $Arch, $copied)
        }
        return $copied
    }
    if (Get-Command -Name EmitLog -ErrorAction SilentlyContinue) {
        EmitLog -Disk 0 -Msg ("edge: no MSI for {0}. Drop {1} in Edge\{0}\ on the share (or payload Edge\{0}\). Destage/download failed." -f $Arch, $wantName)
    }
    return $null
}
