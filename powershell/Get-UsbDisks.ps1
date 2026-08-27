<#
.SYNOPSIS
  Enumerates USB disks and outputs a JSON array to stdout.
  Used by Project LoneWolf Launcher (Electron IPC handler 'usb:detect').

  NOTE: Does NOT require RunAsAdministrator. Disk enumeration cmdlets (Get-Disk,
  Get-CimInstance, Get-PhysicalDisk) work without elevation. Only disk write
  operations require admin, which is handled separately.

.OUTPUTS
  JSON array on stdout:
  [{"number":1,"friendlyName":"SanDisk Ultra","sizeGB":28.9,"serial":"AA001","busType":"USB",
    "isLoneWolfDisk":true,"lwVersion":"1.0.0","lwWorkflowType":"AMD64"},...]
  Outputs [] if no USB disks found.
  No Write-Host, no interactive prompts. Write-Error only for errors (stderr).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# --- WMI-based USB disk number detection (belt-and-suspenders) --------------
function Get-DiskNumbersFromUsbWmi {
    $numbers = [System.Collections.Generic.HashSet[int]]::new()
    try {
        Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue | ForEach-Object {
            $pnp = $_.PNPDeviceID
            $ift = $_.InterfaceType
            $usbLike = $false
            if ($ift -eq 'USB')                              { $usbLike = $true }
            if ($pnp -like 'USBSTOR*')                       { $usbLike = $true }
            if ($pnp -like 'USB\\*')                         { $usbLike = $true }
            if ($ift -eq 'SCSI' -and $pnp -match 'USB')     { $usbLike = $true }
            if ($usbLike -and ($_.DeviceID -match 'PHYSICALDRIVE(\d+)$')) {
                [void]$numbers.Add([int]$Matches[1])
            }
        }
    } catch { }
    return @([int[]]@($numbers))
}

# --- Canonical USB disk list -------------------------------------------------
function Get-UsbDiskList {
    $seen = @{}
    $list = New-Object System.Collections.ArrayList

    function Add-DiskToList {
        param($Disk)
        if (-not $Disk) { return }
        $n = [int]$Disk.Number

        # Deduplicate
        if ($seen.ContainsKey($n)) { return }

        # Skip system disk
        $hasSys = $Disk.PSObject.Properties['IsSystem']
        if ($null -ne $hasSys -and $Disk.IsSystem -eq $true) { return }

        # Skip no-media / empty / unknown slots
        $size = 0
        try { $size = [long]$Disk.Size } catch { $size = 0 }
        if ($size -le 0) { return }

        $opStat = $null
        try { $opStat = [string]$Disk.OperationalStatus } catch { }
        if ($opStat -match 'No\s*Media') { return }
        if ($opStat -eq 'Unknown')       { return }

        $seen[$n] = $true
        [void]$list.Add($Disk)
    }

    # Method 1: Get-Disk BusType = USB
    foreach ($d in (Get-Disk -ErrorAction SilentlyContinue |
                    Where-Object { $_.BusType -eq 'USB' -and $_.OperationalStatus -ne 'Error' })) {
        Add-DiskToList $d
    }

    # Method 2: WMI cross-reference
    foreach ($num in (Get-DiskNumbersFromUsbWmi)) {
        $d = Get-Disk -Number $num -ErrorAction SilentlyContinue
        if ($d) { Add-DiskToList $d }
    }

    # Method 3: PhysicalDisk with BusType USB
    try {
        foreach ($p in (Get-PhysicalDisk -ErrorAction SilentlyContinue |
                        Where-Object { $_.BusType -eq 'USB' })) {
            $d = Get-Disk -UniqueId $p.UniqueId -ErrorAction SilentlyContinue
            if ($d) { Add-DiskToList $d }
        }
    } catch { }

    # Method 4: IsRemovable fallback
    foreach ($d in (Get-Disk -ErrorAction SilentlyContinue)) {
        $rem = $d.PSObject.Properties['IsRemovable']
        if ($null -ne $rem -and $d.IsRemovable -eq $true) {
            Add-DiskToList $d
        }
    }

    return @($list | Sort-Object Number)
}

# --- Serial enrichment via WMI -----------------------------------------------
function Get-WmiSerialByNumber {
    param([int]$Number)
    try {
        $wmi = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue |
               Where-Object { $_.DeviceID -match "PHYSICALDRIVE$Number$" } |
               Select-Object -First 1
        if ($wmi) { return ($wmi.SerialNumber -replace '\s+','').Trim() }
    } catch { }
    return $null
}

# --- LoneWolf version detection from WINSETUP partition ---------------------
# Returns $null to signal "skip this disk entirely" (unreadable / < 1 MB with no partitions).
# Returns an ordered hashtable otherwise (isLoneWolfDisk, lwVersion, lwWorkflowType).
function Get-LoneWolfInfo {
    param([int]$DiskNum, [long]$DiskSize)

    $partitions = $null
    $partError  = $false
    try {
        $partitions = @(Get-Partition -DiskNumber $DiskNum -ErrorAction SilentlyContinue)
    } catch {
        $partError = $true
        $partitions = @()
    }

    # If partition read failed (or returned nothing) and disk is tiny, skip entirely
    if (($partError -or (-not $partitions) -or $partitions.Count -eq 0) -and $DiskSize -lt 1MB) {
        return $null
    }

    $lwInfo = [ordered]@{
        isLoneWolfDisk = $false
        lwVersion = $null
        lwWorkflowType = $null
        lwDevBuild = $false
        lwLauncherVersion = $null
        lwScriptVersion = $null
        lwShareLauncherVersion = $null
        lwShareScriptVersion = $null
        lwImageBuildDate = $null
        lwWimBuildDate = $null
    }

    # Find the largest non-System partition  -  most likely to be WINSETUP NTFS
    $part = $partitions |
        Where-Object { $_.Type -ne 'System' } |
        Sort-Object Size -Descending |
        Select-Object -First 1

    if (-not $part) { return $lwInfo }

    try {
        $vol = $part | Get-Volume -ErrorAction SilentlyContinue
        # Current label is 'LoneWolf' (FAT32 reads it back uppercase as 'LONEWOLF'); -eq is
        # case-insensitive so both match. Legacy 'Project LoneWolf' / 'WINSETUP' still detected.
        if ($vol -and ($vol.FileSystemLabel -eq 'LoneWolf' -or $vol.FileSystemLabel -eq 'Project LoneWolf' -or $vol.FileSystemLabel -eq 'WINSETUP') -and $vol.DriveLetter) {
            # The payload is nested under <vol>\FirstBase\; legacy sticks stamped
            # LW_VERSION.json at the volume root, so probe both in that order.
            $lwVersionFile = $null
            foreach ($candidate in @(
                "$($vol.DriveLetter):\FirstBase\LW_VERSION.json",
                "$($vol.DriveLetter):\LW_VERSION.json"
            )) {
                if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) {
                    $lwVersionFile = $candidate
                    break
                }
            }
            if ($lwVersionFile) {
                $lwJson = Get-Content -Raw -LiteralPath $lwVersionFile -ErrorAction SilentlyContinue |
                          ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($lwJson) {
                    $lwInfo.isLoneWolfDisk = $true
                    $lwInfo.lwVersion      = [string]$lwJson.version
                    $lwInfo.lwWorkflowType = [string]$lwJson.workflowType
                    try {
                        if ($lwJson.PSObject.Properties['devBuild'] -and $lwJson.devBuild) {
                            $lwInfo.lwDevBuild = $true
                        }
                    } catch {}
                    try {
                        if ($lwJson.PSObject.Properties['launcherVersion'] -and $lwJson.launcherVersion) {
                            $lwInfo.lwLauncherVersion = [string]$lwJson.launcherVersion
                        }
                    } catch {}
                    try {
                        if ($lwJson.PSObject.Properties['scriptVersion'] -and $lwJson.scriptVersion) {
                            $lwInfo.lwScriptVersion = [string]$lwJson.scriptVersion
                        } elseif ($lwJson.version) {
                            $lwInfo.lwScriptVersion = [string]$lwJson.version
                        }
                    } catch {}
                    try {
                        if ($lwJson.PSObject.Properties['shareLauncherVersion'] -and $lwJson.shareLauncherVersion) {
                            $lwInfo.lwShareLauncherVersion = [string]$lwJson.shareLauncherVersion
                        }
                    } catch {}
                    try {
                        if ($lwJson.PSObject.Properties['shareScriptVersion'] -and $lwJson.shareScriptVersion) {
                            $lwInfo.lwShareScriptVersion = [string]$lwJson.shareScriptVersion
                        }
                    } catch {}
                    try {
                        if ($lwJson.PSObject.Properties['imageBuildDate'] -and $lwJson.imageBuildDate) {
                            $lwInfo.lwImageBuildDate = [string]$lwJson.imageBuildDate
                        }
                    } catch {}
                    try {
                        if ($lwJson.PSObject.Properties['wimBuildDate'] -and $lwJson.wimBuildDate) {
                            $lwInfo.lwWimBuildDate = [string]$lwJson.wimBuildDate
                        } elseif ($lwInfo.lwImageBuildDate) {
                            $lwInfo.lwWimBuildDate = $lwInfo.lwImageBuildDate
                        }
                    } catch {}
                    # Infer Dev when stamped launcher/script is ahead of the share versions recorded at build time.
                    if (-not $lwInfo.lwDevBuild) {
                        try {
                            if ($lwInfo.lwLauncherVersion -and $lwInfo.lwShareLauncherVersion) {
                                $va = [version](($lwInfo.lwLauncherVersion -replace '[^0-9.]',''))
                                $vb = [version](($lwInfo.lwShareLauncherVersion -replace '[^0-9.]',''))
                                if ($va.CompareTo($vb) -gt 0) { $lwInfo.lwDevBuild = $true }
                            }
                        } catch {}
                        try {
                            if (-not $lwInfo.lwDevBuild -and $lwInfo.lwScriptVersion -and $lwInfo.lwShareScriptVersion) {
                                $va = [version](($lwInfo.lwScriptVersion -replace '[^0-9.]',''))
                                $vb = [version](($lwInfo.lwShareScriptVersion -replace '[^0-9.]',''))
                                if ($va.CompareTo($vb) -gt 0) { $lwInfo.lwDevBuild = $true }
                            }
                        } catch {}
                    }
                }
            }
        }
    } catch { }

    return $lwInfo
}

# --- Main --------------------------------------------------------------------
try {
    $usbDisks = Get-UsbDiskList
    $result   = [System.Collections.ArrayList]::new()

    foreach ($disk in $usbDisks) {
        try {
            $diskNum  = [int]$disk.Number
            $diskSize = 0
            try { $diskSize = [long]$disk.Size } catch { }

            # Probe partitions  -  $null return means skip this disk
            $lwInfo = Get-LoneWolfInfo -DiskNum $diskNum -DiskSize $diskSize
            if ($null -eq $lwInfo) {
                Write-Error "Disk $diskNum skipped: unreadable or no media (size $diskSize bytes)" 2>&1 | Out-Null
                continue
            }

            $sizeGB = [math]::Round($disk.Size / 1GB, 2)
            $serial = $null
            try { $serial = [string]$disk.SerialNumber } catch { }
            if ([string]::IsNullOrWhiteSpace($serial)) {
                $serial = Get-WmiSerialByNumber -Number $diskNum
            }
            if ([string]::IsNullOrWhiteSpace($serial)) { $serial = '' }

            $entry = [ordered]@{
                number         = $diskNum
                friendlyName   = [string]($disk.FriendlyName -replace '"','').Trim()
                sizeGB         = $sizeGB
                serial         = $serial.Trim()
                busType        = [string]$disk.BusType
                isLoneWolfDisk = $lwInfo.isLoneWolfDisk
                lwVersion      = $lwInfo.lwVersion
                lwWorkflowType = $lwInfo.lwWorkflowType
                lwDevBuild     = [bool]$lwInfo.lwDevBuild
                lwLauncherVersion = $lwInfo.lwLauncherVersion
                lwScriptVersion = $lwInfo.lwScriptVersion
                lwShareLauncherVersion = $lwInfo.lwShareLauncherVersion
                lwShareScriptVersion = $lwInfo.lwShareScriptVersion
                lwImageBuildDate = $lwInfo.lwImageBuildDate
                lwWimBuildDate = $lwInfo.lwWimBuildDate
            }
            [void]$result.Add($entry)

        } catch {
            Write-Error "Disk $($disk.Number) enumeration error: $_"
            # Per-disk error  -  continue with remaining disks
        }
    }

    if ($result.Count -eq 0) {
        Write-Output '[]'
    } else {
        # Use -InputObject (not pipeline) so a single-item list stays a JSON array [...]
        # Pipeline unwraps the array and ConvertTo-Json emits a bare object {...} for one item.
        ConvertTo-Json -InputObject @($result) -Compress -Depth 2
    }

} catch {
    Write-Error "Get-UsbDisks failed: $_"
    Write-Output '[]'
}
