<#
.SYNOPSIS
  Detects Group Policy / MDM (Intune) restrictions that block removable USB
  storage access, so the launcher can clearly warn the user instead of silently
  failing to detect drives.
  Used by Project LoneWolf Launcher (Electron IPC handler 'system:checkUsbPolicy').

  NOTE: Does NOT require RunAsAdministrator. All checks are read-only registry
  lookups under HKLM policy keys, which are readable by standard users.

.OUTPUTS
  JSON object on stdout:
  {"blocked":true,"reasons":["Removable storage access is disabled by organization policy."]}
  {"blocked":false,"reasons":[]} when no restricting policy is found.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

$reasons = New-Object System.Collections.ArrayList

function Test-RegFlag {
    param([string]$Path, [string]$Name, [int]$MatchValue = 1)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $val = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($null -eq $val) { return $false }
    try { return ([int]$val -eq $MatchValue) } catch { return $false }
}

# 1. "All Removable Storage classes: Deny all access" (GPO / Intune Removable
#    Storage Access CSP maps to this same registry policy under the hood).
if (Test-RegFlag -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices' -Name 'Deny_All') {
    [void]$reasons.Add('Removable storage access is disabled by an organization policy (deny all access).')
}
if (Test-RegFlag -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices' -Name 'Deny_Write') {
    [void]$reasons.Add('Writing to removable storage is disabled by an organization policy.')
}
if (Test-RegFlag -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{53f56307-b6bf-11d0-94f2-00a0c91efb8b}' -Name 'Deny_All') {
    [void]$reasons.Add('Removable disk drive access is disabled by an organization policy.')
}

# 2. USB mass-storage driver disabled at the service level (Start=4 means Disabled)
if (Test-RegFlag -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -Name 'Start' -MatchValue 4) {
    [void]$reasons.Add('The USB mass storage driver is disabled on this device.')
}

# 3. Device installation restriction policies (deny removable devices / specific device IDs)
if (Test-RegFlag -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions' -Name 'DenyRemovableDevices') {
    [void]$reasons.Add('Installing removable devices is blocked by an organization policy.')
}
if (Test-RegFlag -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions' -Name 'DenyDeviceIDs') {
    [void]$reasons.Add('Certain device drivers are blocked by an organization policy, which may prevent USB drives from being recognized.')
}

$result = [ordered]@{
    blocked = ($reasons.Count -gt 0)
    reasons = @($reasons)
}

ConvertTo-Json -InputObject $result -Compress -Depth 2
