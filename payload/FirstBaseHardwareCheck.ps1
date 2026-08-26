# FirstBase hardware gate — Wi-Fi, camera, usable sound, and critical PnP.
# Called from Invoke-FbOobeHandoff STAGE 2 in the Administrator audit session.
# A check PASSES only when Windows can actually see the device/capability.
# Driver-present-but-error (yellow bang / ConfigManagerErrorCode != 0) is FAIL.
# Missing script or a thrown probe is FAIL — never skip-as-pass.
# PnP extra: present Net/MEDIA/Camera (and System problem 28) must not be Error.
#
# "Usable volume sliders" means active Core Audio endpoints exist for both
# render (output) and capture (input) so Settings and the volume flyout can
# bind. This does NOT UI-robot the sliders (fragile in Audit/OOBE).
# For Internal Use Only.

[CmdletBinding()]
param(
    [string]$ResultPath = '',
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$FbPd = 'C:\ProgramData\FirstBase'
$FbRoot = 'C:\Windows\Setup\FirstBase'
if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path $FbPd '.hardware-gate-result.json'
}

$fbVer = Join-Path $PSScriptRoot 'FirstBaseVersion.ps1'
if (-not (Test-Path -LiteralPath $fbVer)) { $fbVer = Join-Path $FbRoot 'FirstBaseVersion.ps1' }
if (Test-Path -LiteralPath $fbVer) { . $fbVer }
if (-not (Get-Variable -Name FirstBasePayloadRevision -ErrorAction SilentlyContinue)) {
    $FirstBaseProductVersion = '1.0.0'
    $FirstBasePayloadRevision = 'unknown'
    $FirstBaseScriptVersion = @{}
}
$script:ThisScriptVersion = [string]$FirstBaseScriptVersion['FirstBaseHardwareCheck.ps1']
if ([string]::IsNullOrWhiteSpace($script:ThisScriptVersion)) { $script:ThisScriptVersion = $FirstBaseProductVersion }

function Write-FbHardwareCheckLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('[{0}] [{1}] [hw-gate] {2}' -f (Get-Date -Format 'o'), $Level, $Message)
    foreach ($dir in @($FbPd, (Join-Path $FbRoot 'Logs'))) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Add-Content -LiteralPath (Join-Path $dir 'WU-hardware-gate.log') -Value $line -Encoding ascii -ErrorAction SilentlyContinue
        } catch {}
    }
}

function New-FbHardwareCheckItem {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )
    return [pscustomobject]@{
        Name   = $Name
        Passed = [bool]$Passed
        Detail = [string]$Detail
    }
}

function Get-FbActiveMmAudioEndpoints {
    param([ValidateSet('Render', 'Capture')][string]$Flow)
    $key = Join-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio' $Flow
    $hits = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $key)) { return @() }
    try {
        foreach ($dev in @(Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)) {
            if (-not $dev) { continue }
            $state = 0
            try { $state = [int](Get-ItemProperty -LiteralPath $dev.PSPath -Name DeviceState -ErrorAction SilentlyContinue).DeviceState } catch { $state = 0 }
            # DeviceState low nibble: 1=ACTIVE 2=DISABLED 4=NOTPRESENT 8=UNPLUGGED
            if (($state -band 0xF) -ne 1) { continue }
            $label = $dev.PSChildName
            try {
                $propKey = Join-Path $dev.PSPath 'Properties'
                if (Test-Path -LiteralPath $propKey) {
                    $p = Get-ItemProperty -LiteralPath $propKey -ErrorAction SilentlyContinue
                    foreach ($n in @('{a45c254e-df1c-4efd-8020-67d146a850e0},2', 'Name', 'FriendlyName')) {
                        if ($p -and $p.PSObject.Properties.Name -contains $n -and -not [string]::IsNullOrWhiteSpace([string]$p.$n)) {
                            $label = [string]$p.$n
                            break
                        }
                    }
                }
            } catch {}
            [void]$hits.Add($label)
        }
    } catch {}
    return @($hits)
}

function Test-FbHardwareSound {
    # Volume flyout / ms-settings:sound bind to ACTIVE Core Audio endpoints.
    # Require Audiosrv + at least one ACTIVE render and one ACTIVE capture.
    $reasons = New-Object System.Collections.Generic.List[string]
    $svc = $null
    try { $svc = Get-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue } catch {}
    if (-not $svc) {
        return New-FbHardwareCheckItem -Name 'sound' -Passed $false -Detail 'Windows Audio service (Audiosrv) is missing.'
    }
    if ($svc.Status -ne 'Running') {
        try { Start-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Milliseconds 800
        try { $svc = Get-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue } catch {}
    }
    if (-not $svc -or $svc.Status -ne 'Running') {
        return New-FbHardwareCheckItem -Name 'sound' -Passed $false -Detail ('Windows Audio service is {0}; volume sliders cannot bind.' -f $(if ($svc) { $svc.Status } else { 'missing' }))
    }

    $render = @(Get-FbActiveMmAudioEndpoints -Flow Render)
    $capture = @(Get-FbActiveMmAudioEndpoints -Flow Capture)
    if ($render.Count -eq 0) { [void]$reasons.Add('no ACTIVE render (output) endpoint') }
    if ($capture.Count -eq 0) { [void]$reasons.Add('no ACTIVE capture (microphone) endpoint') }

    # PnP corroboration: do not treat error-state MEDIA devices as a pass.
    # Get-PnpDevice -Class does not accept a comma list (FBTGJB4: "Argument types do not match").
    $pnpAudioOk = $false
    try {
        $pnp = @()
        foreach ($cls in @('MEDIA', 'AudioEndpoint')) {
            foreach ($dev in @(Get-FbPnpDevicesPresent -ClassName $cls)) {
                $problem = 0
                try {
                    if ($null -ne $dev.Problem -and [string]$dev.Problem -ne '') { $problem = [int]$dev.Problem }
                } catch { $problem = 0 }
                if ([string]$dev.Status -eq 'OK' -and $problem -eq 0) { $pnp += $dev }
            }
        }
        $pnpAudioOk = ($pnp.Count -gt 0)
    } catch {
        try {
            $pnp = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
                $_.ConfigManagerErrorCode -eq 0 -and
                ($_.PNPClass -eq 'MEDIA' -or $_.PNPClass -eq 'AudioEndpoint' -or $_.Name -match 'Audio|High Definition|Sound')
            })
            $pnpAudioOk = ($pnp.Count -gt 0)
        } catch {}
    }
    if (-not $pnpAudioOk -and ($render.Count -eq 0 -or $capture.Count -eq 0)) {
        [void]$reasons.Add('no working audio PnP device')
    }

    $passed = ($reasons.Count -eq 0)
    $detail = if ($passed) {
        ('Audiosrv running; ACTIVE render={0}; ACTIVE capture={1} (volume sliders can bind).' -f ($render -join ', '), ($capture -join ', '))
    } else {
        ('Sound not visible/usable: {0}.' -f ($reasons -join '; '))
    }
    return New-FbHardwareCheckItem -Name 'sound' -Passed $passed -Detail $detail
}

function Test-FbHardwareCamera {
    $ok = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($dev in @(Get-PnpDevice -Class Camera -ErrorAction SilentlyContinue)) {
            if (-not $dev) { continue }
            $problem = 0
            try { $problem = [int]$dev.Problem } catch { $problem = 0 }
            if ($dev.Status -eq 'OK' -and $problem -eq 0) {
                [void]$ok.Add([string]$dev.FriendlyName)
            }
        }
    } catch {}
    if ($ok.Count -eq 0) {
        try {
            foreach ($dev in @(Get-PnpDevice -Class Image -ErrorAction SilentlyContinue)) {
                if (-not $dev) { continue }
                $name = [string]$dev.FriendlyName
                if ($name -notmatch '(?i)camera|webcam|integrated cam') { continue }
                if ($name -match '(?i)scanner|printer') { continue }
                $problem = 0
                try { $problem = [int]$dev.Problem } catch { $problem = 0 }
                if ($dev.Status -eq 'OK' -and $problem -eq 0) {
                    [void]$ok.Add($name)
                }
            }
        } catch {}
    }
    if ($ok.Count -eq 0) {
        try {
            foreach ($ent in @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue)) {
                if (-not $ent) { continue }
                $cls = [string]$ent.PNPClass
                $nm = [string]$ent.Name
                $isCam = ($cls -eq 'Camera') -or ($cls -eq 'Image' -and $nm -match '(?i)camera|webcam')
                if (-not $isCam) { continue }
                if ([int]$ent.ConfigManagerErrorCode -eq 0 -and $ent.Status -eq 'OK') {
                    [void]$ok.Add($nm)
                }
            }
        } catch {}
    }
    $passed = ($ok.Count -gt 0)
    $detail = if ($passed) {
        ('Internal camera visible to Windows: {0}.' -f ($ok -join ', '))
    } else {
        'No working camera PnP device (Status=OK, ConfigManagerErrorCode=0). Driver-present-with-error is not a pass.'
    }
    return New-FbHardwareCheckItem -Name 'camera' -Passed $passed -Detail $detail
}

function Test-FbHardwareWifi {
    $reasons = New-Object System.Collections.Generic.List[string]
    try {
        $svc = Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            try { Start-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue } catch {}
            Start-Sleep -Milliseconds 800
            try { $svc = Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue } catch {}
        }
        if (-not $svc -or $svc.Status -ne 'Running') {
            [void]$reasons.Add(('WLAN AutoConfig is {0}' -f $(if ($svc) { [string]$svc.Status } else { 'missing' })))
        }
    } catch {
        [void]$reasons.Add(('WLAN AutoConfig probe threw: {0}' -f $_.Exception.Message))
    }

    $adapters = @()
    try {
        $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
            $ifType = 0
            try { $ifType = [int]$_.InterfaceType } catch { $ifType = 0 }
            $medium = ''
            try { $medium = [string]$_.NdisPhysicalMedium } catch { $medium = '' }
            ($ifType -eq 71) -or
            ($medium -match 'Native802_11|802.11') -or
            ($_.InterfaceDescription -match '(?i)wi-?fi|wireless|802\.11|wlan') -or
            ($_.Name -match '(?i)wi-?fi|wireless|wlan')
        })
    } catch {}

    if ($adapters.Count -eq 0) {
        [void]$reasons.Add('no Wi-Fi adapter visible to Windows')
    } else {
        $up = @($adapters | Where-Object { $_.Status -eq 'Up' -or $_.AdminStatus -eq 'Up' })
        $disabled = @($adapters | Where-Object { $_.Status -eq 'Disabled' -or $_.AdminStatus -eq 'Down' })
        if ($up.Count -eq 0) {
            [void]$reasons.Add(('Wi-Fi adapter present but not up (status={0})' -f (($adapters | ForEach-Object { '{0}:{1}' -f $_.Name, $_.Status }) -join ', ')))
        }
        if ($disabled.Count -eq $adapters.Count) {
            [void]$reasons.Add('all Wi-Fi adapters are disabled')
        }
    }

    $scanOut = ''
    $scanOk = $false
    $visibleCount = -1
    try {
        $scanOut = [string](& netsh.exe wlan show networks 2>&1 | Out-String)
        if ($scanOut -match '(?i)there is no wireless interface') {
            [void]$reasons.Add('netsh: no wireless interface')
        } elseif ($scanOut -match '(?i)interface is powered down|radio is off|powered off') {
            [void]$reasons.Add('Wi-Fi radio is off / powered down')
        } elseif ($scanOut -match '(?i)not running|WLAN AutoConfig') {
            [void]$reasons.Add('netsh cannot scan (WLAN service)')
        } elseif ($scanOut -match '(?i)The following command was not found|is not recognized') {
            [void]$reasons.Add('netsh wlan show networks is unavailable')
        } else {
            $scanOk = $true
            if ($scanOut -match '(?i)There are (\d+) networks currently visible') {
                $visibleCount = [int]$Matches[1]
            } elseif ($scanOut -match '(?i)SSID\s+\d+\s*:') {
                $visibleCount = @([regex]::Matches($scanOut, '(?i)SSID\s+\d+\s*:')).Count
            } else {
                $visibleCount = 0
            }
        }
    } catch {
        [void]$reasons.Add(('Wi-Fi scan threw: {0}' -f $_.Exception.Message))
    }

    # Scan capability is enough — 0 visible SSIDs still passes (warehouse with no AP).
    # Connected-to-a-specific-SSID is NOT required.
    $passed = ($reasons.Count -eq 0) -and $scanOk
    $detail = if ($passed) {
        ('Adapter up; radio on; scan completed (visible networks={0}; SSID association not required).' -f $visibleCount)
    } else {
        ('Wi-Fi not usable: {0}.' -f ($reasons -join '; '))
    }
    if ($passed -and $visibleCount -eq 0) {
        $detail += ' Scan returned zero SSIDs; interface can scan so this is still a pass.'
    }
    return New-FbHardwareCheckItem -Name 'wifi' -Passed $passed -Detail $detail
}

function Get-FbPnpDevicesPresent {
    param([string]$ClassName)
    $hits = New-Object System.Collections.Generic.List[object]
    # One class string per call. Do not wrap List[object] of CIM devices in @() —
    # Windows PowerShell 5.1 throws ArgumentException "Argument types do not match"
    # (FBTGJB4: sound/camera/wifi PASS, pnp=FAIL with working hardware).
    try {
        foreach ($dev in @(Get-PnpDevice -Class $ClassName -ErrorAction SilentlyContinue)) {
            if (-not $dev) { continue }
            $present = $true
            try {
                if ($null -ne $dev.PSObject.Properties['Present']) { $present = [bool]$dev.Present }
            } catch { $present = $true }
            if ($present) { [void]$hits.Add($dev) }
        }
    } catch {}
    return $hits.ToArray()
}

function Test-FbHardwareCriticalPnp {
    # Extra fail if present Net / MEDIA / Camera (and System with no-driver)
    # show Error after WUA claimed driver installs. Inbox adapters can look
    # OK while OEM packages never committed (YouTube-on-pass with missing OEM).
    $bad = New-Object System.Collections.Generic.List[string]
    $failProblems = @(10, 19, 28, 31, 39, 43)
    $skipNet = '(?i)WAN Miniport|Kernel Debug|Wi-?Fi Direct|Virtual Adapter|Teredo|Microsoft Hosted Network|Bluetooth Device \(Personal Area Network\)|TAP-|Hyper-V|Npcap|Loopback'
    foreach ($tuple in @(
        @{ Class = 'Net'; Mode = 'net' }
        @{ Class = 'MEDIA'; Mode = 'media' }
        @{ Class = 'AudioEndpoint'; Mode = 'media' }
        @{ Class = 'Camera'; Mode = 'camera' }
        @{ Class = 'Image'; Mode = 'image' }
        @{ Class = 'System'; Mode = 'system' }
    )) {
        foreach ($dev in @(Get-FbPnpDevicesPresent -ClassName $tuple.Class)) {
            if (-not $dev) { continue }
            $name = ''
            $st = ''
            $problem = 0
            try {
                $name = [string]$dev.FriendlyName
                if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$dev.InstanceId }
                $st = [string]$dev.Status
                if ($null -ne $dev.Problem -and [string]$dev.Problem -ne '') {
                    $problem = [int]$dev.Problem
                }
            } catch {
                continue
            }
            if ($problem -eq 22) { continue }
            if ($tuple.Mode -eq 'net' -and $name -match $skipNet) { continue }
            if ($tuple.Mode -eq 'image' -and $name -notmatch '(?i)camera|webcam|integrated cam') { continue }
            if ($tuple.Mode -eq 'image' -and $name -match '(?i)scanner|printer') { continue }
            if ($tuple.Mode -eq 'system') {
                if ($problem -eq 28) {
                    [void]$bad.Add(('System/{0} problem=28 (no driver)' -f $name))
                }
                continue
            }
            $isBadStatus = ($st -eq 'Error' -or $st -eq 'Unknown' -or $st -eq 'Degraded')
            $isBadProblem = ($failProblems -contains $problem)
            if ($isBadStatus -or $isBadProblem) {
                [void]$bad.Add(('{0}/{1} Status={2} Problem={3}' -f $tuple.Class, $name, $st, $problem))
            }
        }
    }
    $unique = @($bad | Select-Object -Unique)
    if ($unique.Count -gt 8) {
        $unique = @($unique[0..7] + (('...and {0} more' -f ($bad.Count - 8))))
    }
    $passed = ($bad.Count -eq 0)
    $detail = if ($passed) {
        'No Error/Unknown present Net, MEDIA, or Camera devices; no System devices with problem 28 (no driver).'
    } else {
        ('PnP driver errors: {0}' -f ($unique -join '; '))
    }
    return New-FbHardwareCheckItem -Name 'pnp' -Passed $passed -Detail $detail
}

function Invoke-FbHardwareGate {
    Write-FbHardwareCheckLog ("start payload={0} script={1}" -f $FirstBasePayloadRevision, $script:ThisScriptVersion)
    $items = @()
    try { $items += Test-FbHardwareSound } catch {
        $items += New-FbHardwareCheckItem -Name 'sound' -Passed $false -Detail ('Sound probe threw: {0}' -f $_.Exception.Message)
    }
    try { $items += Test-FbHardwareCamera } catch {
        $items += New-FbHardwareCheckItem -Name 'camera' -Passed $false -Detail ('Camera probe threw: {0}' -f $_.Exception.Message)
    }
    try { $items += Test-FbHardwareWifi } catch {
        $items += New-FbHardwareCheckItem -Name 'wifi' -Passed $false -Detail ('Wi-Fi probe threw: {0}' -f $_.Exception.Message)
    }
    try { $items += Test-FbHardwareCriticalPnp } catch {
        $items += New-FbHardwareCheckItem -Name 'pnp' -Passed $false -Detail ('PnP probe threw: {0}' -f $_.Exception.Message)
    }

    $failed = @($items | Where-Object { -not $_.Passed })
    $passed = ($failed.Count -eq 0 -and $items.Count -eq 4)
    $summary = ($items | ForEach-Object { '{0}={1}' -f $_.Name, $(if ($_.Passed) { 'PASS' } else { 'FAIL' }) }) -join '; '
    Write-FbHardwareCheckLog ("result passed={0} {1}" -f $passed, $summary) $(if ($passed) { 'INFO' } else { 'WARN' })
    foreach ($it in $items) {
        Write-FbHardwareCheckLog ('  {0}: {1}' -f $it.Name, $it.Detail) $(if ($it.Passed) { 'INFO' } else { 'WARN' })
    }

    return [pscustomobject]@{
        Passed    = [bool]$passed
        At        = (Get-Date -Format 'o')
        Payload   = [string]$FirstBasePayloadRevision
        Script    = [string]$script:ThisScriptVersion
        Summary   = [string]$summary
        Checks    = @($items)
        Failed    = @($failed | ForEach-Object { $_.Name })
    }
}

$result = $null
try {
    $result = Invoke-FbHardwareGate
} catch {
    Write-FbHardwareCheckLog ("Invoke-FbHardwareGate threw: {0}" -f $_.Exception.Message) 'ERROR'
    $result = [pscustomobject]@{
        Passed  = $false
        At      = (Get-Date -Format 'o')
        Summary = 'probe-threw'
        Error   = [string]$_.Exception.Message
        Checks  = @()
        Failed  = @('sound', 'camera', 'wifi', 'pnp')
    }
}

try {
    $dir = Split-Path -Parent $ResultPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    ($result | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $ResultPath -Encoding UTF8 -Force
} catch {
    Write-FbHardwareCheckLog ("result JSON write failed: {0}" -f $_.Exception.Message) 'WARN'
}

if (-not $Quiet) {
    try { $result | ConvertTo-Json -Depth 6 | Write-Output } catch { Write-Output ($result | Out-String) }
}

if ($result -and $result.Passed) { exit 0 } else { exit 1 }
