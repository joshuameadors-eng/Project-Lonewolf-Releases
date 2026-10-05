# LoneWolf USB data-partition overlay profile.
# Full Updates (LoneWolf AMD64 and ARM64) share one file map and one Explorer chrome.
# Arch selects the identity (Snapdragon vs Intel/AMD, bootaa64 vs bootx64).
# Quick Install is a workflow stamp. A USB stick for that workflow uses the full
# rebuild payload (Deploy\TechInstall.cmd), the same file Snapdragon updates stages.
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
    # quick-install and updates share Deploy\TechInstall.cmd. The quick-install
    # payload script is not what a USB stick runs.
    $techSrc = switch ($kind) {
        'win-install' { 'Deploy\TechInstall-Install.cmd' }
        default       { 'Deploy\TechInstall.cmd' }
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
    # WIN-INSTALL keeps its own script. Updates and Quick Install USB both require
    # FirstBase\Deploy\TechInstall.cmd from the full rebuild payload.
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
