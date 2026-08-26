# FirstBase Dell-class storage RAID probe (WinPE / full Windows).
# Exit: 0 = treat as non-RAID (AHCI/NVMe path), 7 = inconclusive/soft (UNKNOWN policy), 9 = hardware RAID signal.
param(
    [Parameter(Mandatory = $true)]
    [string] $LogPath
)

$ErrorActionPreference = 'Stop'

function Add-FbDisksetupLog {
    param([string] $Message)
    $line = ('[{0}] {1}' -f (Get-Date), $Message)
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8 -ErrorAction Stop
    }
    catch {
        # Best-effort; exit codes still drive policy.
    }
}

try {
    $pnpAll = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)
}
catch {
    Add-FbDisksetupLog 'RAID_SIGNAL_SOURCE=PNP_QUERY_FAILED'
    exit 7
}

# Storage-facing PnP rows only (reduces random "RAID" hits on unrelated classes).
$pnpStor = @($pnpAll | Where-Object { $_.PNPClass -in @('SCSIAdapter', 'HDC') })

# Strong: vendor RAID / HBA / spaces — excludes plain "Intel Rapid Storage" (AHCI too) and bare "RST"/"VMD" tokens.
$rxStrong = '(?i)(MegaRAID|PERC\s|Dell\s+PERC|H330|H730|H740|H745|H755|HBA\d{3}|Smart\s+Array|AMD[\s\-]RAID|LSI[^\n]{0,40}(MegaRaid|RAID)|Broadcom[^\n]{0,40}RAID|Adaptec[^\n]{0,40}RAID|\bSATA\s+RAID\b|\bNVMe\s+RAID\b|Intel(\(R\))?\s+Rapid\s+Storage[^\n]{0,100}\bRAID\b|RSTe?[^\n]{0,40}\bRAID\b|\bRAID\s+Mode\b)'

# Intel VMD / volume manager — often reports BusType RAID for pass-through NVMe (not a firmware RAID array).
$rxVmdSoft = '(?i)(Volume\s+Management\s+Device|Intel[^\n]{0,60}\bVMD\b|\bVMD\s+Controller\b)'

$strongHits = @($pnpStor | Where-Object { $_.Name -match $rxStrong })
$vmdHits    = @($pnpStor | Where-Object { $_.Name -match $rxVmdSoft })

try {
    $disks = @(Get-Disk -ErrorAction Stop)
}
catch {
    Add-FbDisksetupLog 'RAID_SIGNAL_SOURCE=GETDISK_FAILED'
    exit 7
}

$busRaid = @($disks | Where-Object { $_.BusType -eq 'RAID' })

# 1) Obvious hardware / explicit RAID-mode strings on storage class.
if ($strongHits.Count -gt 0) {
    $n = $strongHits[0].Name
    if ($n.Length -gt 160) { $n = $n.Substring(0, 157) + '...' }
    Add-FbDisksetupLog ('RAID_SIGNAL_SOURCE=PNP_STRONG NAME={0}' -f $n)
    exit 9
}

# 2) BusType RAID: downgrade when only Intel VMD-style controller (common Dell non-RAID BIOS path).
if ($busRaid.Count -gt 0) {
    Add-FbDisksetupLog ('RAID_SIGNAL_SOURCE=GETDISK_BUSTYPE_RAID COUNT={0}' -f $busRaid.Count)
    if ($vmdHits.Count -gt 0 -and $strongHits.Count -eq 0) {
        Add-FbDisksetupLog 'RAID_DELL_SOFT=INTEL_VMD_BUSTYPE_RAID RAID_POLICY=UNKNOWN'
        exit 7
    }
    Add-FbDisksetupLog 'RAID_DELL_SOFT=BUS_RAID_NO_STRONG_PNP RAID_POLICY=UNKNOWN'
    exit 7
}

# 3) No strong PnP and no RAID bus — treat as non-RAID for gate purposes.
Add-FbDisksetupLog 'RAID_SIGNAL_SOURCE=NONE'
exit 0
