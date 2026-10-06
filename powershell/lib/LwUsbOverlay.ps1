# LoneWolf USB data-partition overlay profile.
# Full Snapdragon Windows Updates (ARM64, not Quick Install) stages the Windows
# Update payload. Snapdragon Quick Install, Windows (amd64), and Quick Install
# Intel/AMD do not. Arch selects the identity (Snapdragon vs Intel/AMD,
# bootaa64 vs bootx64).
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

# Full Snapdragon Windows Updates only (ARM64, not Quick Install, not WIN-INSTALL).
# Windows (amd64) is the Intel/AMD card: workflow AMD64. It does not match.
function Test-LwStageWindowsUpdatePayload {
    param(
        [string]$WorkflowType = '',
        [bool]$QuickInstall = $false,
        [bool]$NoPayload = $false
    )
    if ($QuickInstall -or $NoPayload) { return $false }
    $raw = ([string]$WorkflowType).ToUpperInvariant()
    if ($raw -match '^(QUICK-INSTALL-|WIN-INSTALL-)') { return $false }
    if (Get-Command -Name Test-LwSnapdragonWorkflow -ErrorAction SilentlyContinue) {
        return [bool](Test-LwSnapdragonWorkflow -WorkflowType $WorkflowType)
    }
    $bare = [regex]::Replace($raw, '^(QUICK-INSTALL-|WIN-INSTALL-|LONEWOLF-)', '')
    return ($bare -eq 'ARM64')
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
