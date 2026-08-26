#Requires -Version 3.0
<#
.SYNOPSIS
    FirstBase WinPE UEFI pre-flight check.

.DESCRIPTION
    Runs from WinPE-Startnet.cmd before any disk access.
    Checks two conditions and restarts to UEFI firmware settings if either is true:

      1. Secure Boot is disabled  - tech must enable it before imaging.
      2. RAID storage controller detected (Dell/Intel VMD/RST) - tech must
         switch to AHCI or NVMe mode before imaging to avoid wiping the USB.

    On detection: prints a console message, logs the finding, then sets the
    UEFI OsIndications NVRAM variable (bit 0) directly via
    SetFirmwareEnvironmentVariableW and issues "wpeutil reboot".  Falls back
    to shutdown.exe /r /fw if the NVRAM write fails, and to a plain reboot if
    that also fails.

    Exit 0 = all checks passed, caller may proceed.
    Exit 1 = issue detected; reboot to UEFI firmware has been initiated.

.PARAMETER LogFile
    Path for log output.  WinPE-Startnet.cmd passes %FBLOG%.
    Defaults to %FBLOG% env var, then X:\FirstBase-Preflight.log.
#>
param(
    [string]$LogFile = ''
)

Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'

# v1.0.4 - 2026-08-07.1: Write-PrefLog is log-only - the Write-Host it used to end with put every
#          status line on the console during the pre-banner phase, which is meant to be silent.
#          Invoke-FwReboot and the ACTION REQUIRED banners still print; they are user-facing.
# v1.0.3 - 2026-05-31: FbEfiRead.EnableEnvPrivilege() enables SeSystemEnvironmentPrivilege before GetFirmwareEnvironmentVariableW;
#          error 1314/5 treated as UEFI confirmed + SB assumed disabled (conservative).
# v1.0.2 - 2026-05-29: three-level SB detection (registry → NVRAM GetFirmwareEnvironmentVariableW → bcdedit UEFI-mode probe);
#          full paths for wpeutil.exe / shutdown.exe in Invoke-FwReboot.

# ---------------------------------------------------------------------------
# Resolve log path
# ---------------------------------------------------------------------------
if ([string]::IsNullOrEmpty($LogFile)) {
    $LogFile = if ($env:FBLOG) { $env:FBLOG } else { 'X:\FirstBase-Preflight.log' }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-PrefLog {
    param([string]$Message)
    $stamp = (Get-Date -ErrorAction SilentlyContinue).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "[$stamp] PREFLIGHT: $Message"
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

# ---------------------------------------------------------------------------
# WHY direct NVRAM instead of "shutdown.exe /r /fw":
#   shutdown.exe /r /fw works by setting the UEFI OsIndications variable and
#   then calling the Windows BCD (Boot Configuration Data) service / shutdown
#   manager to schedule the reboot.  Those services are not present in WinPE,
#   so the command fails silently or exits non-zero.  The correct WinPE
#   approach is to set the OsIndications NVRAM variable directly via the
#   Win32 API (SetFirmwareEnvironmentVariableW) — which works as long as the
#   process holds SeSystemEnvironmentPrivilege — then call "wpeutil reboot"
#   to actually restart the machine.
# ---------------------------------------------------------------------------
function Set-UefiBootToFirmwareUI {
    <#
    .SYNOPSIS
        Sets OsIndications bit 0 in UEFI NVRAM so the firmware enters setup on next reboot.
        Works in WinPE where shutdown.exe /r /fw is not supported.
    #>
    $EFI_GLOBAL_GUID = '{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}'
    $OS_INDICATIONS_BOOT_TO_FW_UI = [uint64]1

    # Inline C# for the three Win32 calls we need.
    $typeSrc = @'
using System;
using System.Runtime.InteropServices;

public static class FbEfiBoot {
    // Privilege constants
    private const uint SE_PRIVILEGE_ENABLED = 0x00000002;
    private const uint TOKEN_ADJUST_PRIVILEGES = 0x00000020;
    private const uint TOKEN_QUERY             = 0x00000008;

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES {
        public uint PrivilegeCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 1)]
        public LUID_AND_ATTRIBUTES[] Privileges;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr hProcess, uint dwAccess, out IntPtr hToken);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(
        IntPtr hToken, bool disableAll, ref TOKEN_PRIVILEGES newState,
        uint bufLen, IntPtr prevState, IntPtr returnLen);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint GetFirmwareEnvironmentVariableW(
        string lpName, string lpGuid, IntPtr pBuffer, uint nSize);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SetFirmwareEnvironmentVariableW(
        string lpName, string lpGuid, IntPtr pBuffer, uint nSize);

    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();

    public static string EnableEnvPrivilege() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(),
                TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
            return "OpenProcessToken failed: " + Marshal.GetLastWin32Error();

        LUID luid;
        if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid))
            return "LookupPrivilegeValue failed: " + Marshal.GetLastWin32Error();

        var tp = new TOKEN_PRIVILEGES {
            PrivilegeCount = 1,
            Privileges = new LUID_AND_ATTRIBUTES[] {
                new LUID_AND_ATTRIBUTES { Luid = luid, Attributes = SE_PRIVILEGE_ENABLED }
            }
        };
        AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        int err = Marshal.GetLastWin32Error();
        return err == 0 ? "OK" : "AdjustTokenPrivileges error: " + err;
    }

    public static string SetBootToFirmwareUI(string varName, string guid) {
        // Read current value (may not exist yet — that is fine, treat as 0)
        ulong current = 0;
        IntPtr buf = Marshal.AllocHGlobal(8);
        try {
            uint read = GetFirmwareEnvironmentVariableW(varName, guid, buf, 8);
            if (read == 8) current = (ulong)Marshal.ReadInt64(buf);
        } finally { Marshal.FreeHGlobal(buf); }

        ulong newVal = current | 1UL; // bit 0 = EFI_OS_INDICATIONS_BOOT_TO_FW_UI
        IntPtr buf2 = Marshal.AllocHGlobal(8);
        try {
            Marshal.WriteInt64(buf2, (long)newVal);
            bool ok = SetFirmwareEnvironmentVariableW(varName, guid, buf2, 8);
            return ok ? "OK" : ("SetFirmwareEnvironmentVariableW failed: " + Marshal.GetLastWin32Error());
        } finally { Marshal.FreeHGlobal(buf2); }
    }
}
'@

    try {
        if (-not ([System.Management.Automation.PSTypeName]'FbEfiBoot').Type) {
            Add-Type -TypeDefinition $typeSrc -Language CSharp -ErrorAction Stop
        }
    } catch {
        return "Add-Type failed: $($_.Exception.Message)"
    }

    $privResult = [FbEfiBoot]::EnableEnvPrivilege()
    if ($privResult -ne 'OK') {
        return "Privilege enable failed: $privResult"
    }

    return [FbEfiBoot]::SetBootToFirmwareUI('OsIndications', $EFI_GLOBAL_GUID)
}

function Invoke-FwReboot {
    param([string]$Reason)

    Write-Host ''
    Write-Host '================================================================'
    Write-Host "  FirstBase Pre-flight: ACTION REQUIRED"
    Write-Host ''
    Write-Host "  $Reason"
    Write-Host ''
    Write-Host '  Fix the setting in UEFI/BIOS firmware:'
    Write-Host '    - Enable Secure Boot (if prompted for Secure Boot)'
    Write-Host '    - Set storage controller to AHCI or NVMe (if prompted for RAID)'
    Write-Host '  Then Save & Exit firmware and re-boot from the FirstBase USB.'
    Write-Host ''
    Write-Host '  Restarting to UEFI firmware settings in 5 seconds...'
    Write-Host '================================================================'
    Write-Host ''

    Write-PrefLog "Reboot to UEFI initiated: $Reason"

    Write-PrefLog 'Setting UEFI OsIndications bit 0 (boot to firmware UI) via SetFirmwareEnvironmentVariableW...'
    $nvramResult = Set-UefiBootToFirmwareUI
    Write-PrefLog "OsIndications set result: $nvramResult"

    if ($nvramResult -eq 'OK') {
        Write-PrefLog 'NVRAM write succeeded. Issuing wpeutil reboot...'
        Start-Process -FilePath 'X:\Windows\System32\wpeutil.exe' -ArgumentList 'reboot' -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10
    } else {
        # NVRAM write failed — try shutdown /r /fw as a fallback (works on some UEFI firmware in WinPE)
        Write-PrefLog 'NVRAM write failed; trying shutdown.exe /r /fw as fallback...'
        $p = $null
        try {
            $p = Start-Process -FilePath 'X:\Windows\System32\shutdown.exe' `
                               -ArgumentList '/r', '/fw', '/t', '5' `
                               -Wait -PassThru -ErrorAction Stop
        } catch {
            Write-PrefLog ("shutdown.exe /fw threw: $($_.Exception.Message)")
        }

        if ($null -eq $p -or $p.ExitCode -ne 0) {
            Write-Host ''
            Write-Host 'WARNING: Both UEFI reboot methods failed.'
            Write-Host 'Issuing a plain reboot. Enter UEFI setup manually (Del / F2 / F10 / F12).'
            Write-Host ''
            Write-PrefLog 'WARNING: All /fw methods failed; plain reboot via wpeutil'
            Start-Sleep -Seconds 5
            Start-Process -FilePath 'X:\Windows\System32\wpeutil.exe' -ArgumentList 'reboot' -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 10
        }
    }

    exit 1
}

# ---------------------------------------------------------------------------
# Check 1: Secure Boot
#
# Detection levels (first success wins):
#   L1: Registry HKLM\...\SecureBoot\State\UEFISecureBootEnabled
#       Written by the kernel at boot — present/=1 when SB on; absent when SB off on many OEMs.
#   L2: GetFirmwareEnvironmentVariableW('SecureBoot', EFI_GLOBAL_GUID)
#       Reads the UEFI NVRAM variable directly. 0x01=on, 0x00=off.
#       Returns 0 + Win32Error=1 (ERROR_INVALID_FUNCTION) on legacy BIOS.
#       Requires Add-Type (csc.exe in WinPE .NET runtime).
#   L3: bcdedit /enum {current} → winload.efi present → UEFI mode confirmed
#       If UEFI mode but SB unreadable → conservatively assume SB disabled.
#       If winload.efi absent → legacy BIOS → skip (SB not applicable).
#
# Confirm-SecureBootUEFI intentionally skipped: requires WinPE-SecureStartup OC.
# ---------------------------------------------------------------------------
Write-PrefLog 'Checking Secure Boot status...'
$sbOff    = $false
$sbChecked = $false

# --- L1: Registry ---
try {
    $sbReg = Get-ItemProperty `
        -Path  'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' `
        -Name  'UEFISecureBootEnabled' `
        -ErrorAction Stop
    $sbVal = [int]$sbReg.UEFISecureBootEnabled
    if ($sbVal -eq 0) {
        $sbOff = $true
        Write-PrefLog 'FAIL: Secure Boot is DISABLED (registry UEFISecureBootEnabled=0)'
    } else {
        Write-PrefLog ('OK: Secure Boot enabled (registry UEFISecureBootEnabled={0})' -f $sbVal)
    }
    $sbChecked = $true
} catch {
    Write-PrefLog ('L1 registry absent ({0}); trying NVRAM read...' -f $_.Exception.Message)
}

# --- L2: Direct UEFI NVRAM variable read ---
if (-not $sbChecked) {
    try {
        if (-not ([System.Management.Automation.PSTypeName]'FbEfiRead').Type) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FbEfiRead {
    private const uint TOKEN_ADJUST_PRIVILEGES = 0x00000020;
    private const uint TOKEN_QUERY             = 0x00000008;
    private const uint SE_PRIVILEGE_ENABLED    = 0x00000002;

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES {
        public uint PrivilegeCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 1)]
        public LUID_AND_ATTRIBUTES[] Privileges;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr hProcess, uint dwAccess, out IntPtr hToken);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(
        IntPtr hToken, bool disableAll, ref TOKEN_PRIVILEGES newState,
        uint bufLen, IntPtr prevState, IntPtr returnLen);

    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint GetFirmwareEnvironmentVariableW(
        string lpName, string lpGuid, IntPtr pBuffer, uint nSize);

    public static string EnableEnvPrivilege() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(),
                TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
            return "OpenProcessToken failed: " + Marshal.GetLastWin32Error();
        LUID luid;
        if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid))
            return "LookupPrivilegeValue failed: " + Marshal.GetLastWin32Error();
        var tp = new TOKEN_PRIVILEGES {
            PrivilegeCount = 1,
            Privileges = new LUID_AND_ATTRIBUTES[] {
                new LUID_AND_ATTRIBUTES { Luid = luid, Attributes = SE_PRIVILEGE_ENABLED }
            }
        };
        AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        int err = Marshal.GetLastWin32Error();
        return err == 0 ? "OK" : "AdjustTokenPrivileges error: " + err;
    }
}
'@ -Language CSharp -ErrorAction Stop
        }
        $privRes = [FbEfiRead]::EnableEnvPrivilege()
        Write-PrefLog ('L2 NVRAM: EnableEnvPrivilege result: {0}' -f $privRes)
        $nvBuf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        try {
            $nvRead = [FbEfiRead]::GetFirmwareEnvironmentVariableW(
                'SecureBoot',
                '{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}',
                $nvBuf, 4)
            $nvErr = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($nvRead -gt 0) {
                $nvVal = [System.Runtime.InteropServices.Marshal]::ReadByte($nvBuf)
                if ($nvVal -eq 0) {
                    $sbOff = $true
                    Write-PrefLog 'FAIL: Secure Boot is DISABLED (NVRAM SecureBoot variable = 0x00)'
                } else {
                    Write-PrefLog ('OK: Secure Boot enabled (NVRAM SecureBoot variable = 0x{0:X2})' -f $nvVal)
                }
                $sbChecked = $true
            } elseif ($nvErr -eq 1) {
                # ERROR_INVALID_FUNCTION = legacy BIOS (firmware ignores UEFI variable API entirely)
                Write-PrefLog 'L2 NVRAM: ERROR_INVALID_FUNCTION = legacy BIOS; Secure Boot not applicable'
                $sbChecked = $true
            } elseif ($nvErr -eq 1314 -or $nvErr -eq 5) {
                # 1314 = ERROR_PRIVILEGE_NOT_HELD, 5 = ERROR_ACCESS_DENIED
                # These are UEFI-only errors (BIOS returns 1, not 1314/5).
                # Privilege enable should have succeeded; reaching here means a policy/token issue.
                # Treat as UEFI mode with unreadable SB state -> assume disabled (conservative).
                $sbOff = $true
                Write-PrefLog ('FAIL: UEFI mode confirmed (Win32Error={0} = privilege/access; not BIOS error=1) but SecureBoot variable unreadable - ASSUMING Secure Boot DISABLED (conservative)' -f $nvErr)
                $sbChecked = $true
            } else {
                Write-PrefLog ('L2 NVRAM: read returned 0, Win32Error={0} (variable absent or access denied)' -f $nvErr)
            }
        } finally {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($nvBuf)
        }
    } catch {
        Write-PrefLog ('L2 Add-Type/NVRAM unavailable: {0}' -f $_.Exception.Message)
    }
}

# --- L3: bcdedit UEFI-mode probe → conservative assume-disabled ---
if (-not $sbChecked) {
    Write-PrefLog 'L3: all SB read methods failed; checking UEFI mode via bcdedit...'
    try {
        $bcdLines = & 'X:\Windows\System32\bcdedit.exe' /enum '{current}' 2>&1
        $isUefi   = ($bcdLines | Where-Object { $_ -match 'winload\.efi' }) -ne $null
        if ($isUefi) {
            $sbOff = $true
            Write-PrefLog 'FAIL: UEFI mode confirmed (winload.efi) but SB state unreadable - ASSUMING Secure Boot DISABLED (conservative)'
            Write-Host ''
            Write-Host '  NOTE: Secure Boot status could not be read directly.'
            Write-Host '  UEFI mode detected. Conservatively assuming SB is disabled.'
            Write-Host '  To bypass: set FIRSTBASE_SKIP_PREFLIGHT=1 at a debug shell.'
            Write-Host ''
        } else {
            Write-PrefLog 'L3 bcdedit: winload.efi absent - legacy BIOS or non-UEFI boot; Secure Boot check skipped'
        }
    } catch {
        Write-PrefLog ('L3 bcdedit failed: {0}; Secure Boot check inconclusive' -f $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Check 2: RAID storage controller via SCSI controller name
# ---------------------------------------------------------------------------
Write-PrefLog 'Checking for RAID storage controller (Win32_SCSIController)...'
$raidFound  = $false
$raidDetail = ''
try {
    $ctrl = Get-WmiObject Win32_SCSIController -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'RAID|RST|VMD|VROC|Intel Rapid' }
    if ($ctrl) {
        $raidFound  = $true
        $raidDetail = ($ctrl | Select-Object -First 1 -ExpandProperty Name)
        Write-PrefLog ('FAIL: RAID controller detected: {0}' -f $raidDetail)
    }
} catch {
    Write-PrefLog ('Win32_SCSIController query error: {0}' -f $_.Exception.Message)
}

# ---------------------------------------------------------------------------
# Check 3: RAID disk model (belt-and-suspenders for Intel RAID metadata)
# ---------------------------------------------------------------------------
if (-not $raidFound) {
    Write-PrefLog 'Checking for RAID disk model (Win32_DiskDrive)...'
    try {
        $raidDisk = Get-WmiObject Win32_DiskDrive -ErrorAction SilentlyContinue |
                        Where-Object { $_.Model -match 'RAID|Virtual' }
        if ($raidDisk) {
            $raidFound  = $true
            $raidDetail = ($raidDisk | Select-Object -First 1 -ExpandProperty Model)
            Write-PrefLog ('FAIL: RAID disk model detected: {0}' -f $raidDetail)
        }
    } catch {
        Write-PrefLog ('Win32_DiskDrive query error: {0}' -f $_.Exception.Message)
    }
}

if (-not $raidFound) {
    Write-PrefLog 'OK: No RAID controller or RAID disk model detected'
}

# ---------------------------------------------------------------------------
# Act on findings
# ---------------------------------------------------------------------------
if ($sbOff -and $raidFound) {
    Invoke-FwReboot ('Secure Boot is DISABLED and RAID storage is active ({0}).  ' +
                     'Enable Secure Boot and switch storage to AHCI/NVMe mode.' -f $raidDetail)
} elseif ($sbOff) {
    Invoke-FwReboot 'Secure Boot is DISABLED.  Enable Secure Boot in UEFI before imaging.'
} elseif ($raidFound) {
    Invoke-FwReboot ('RAID storage controller is active ({0}).  ' +
                     'Switch to AHCI or NVMe mode in UEFI before imaging.' -f $raidDetail)
}

Write-PrefLog 'All pre-flight checks passed.'
exit 0
