#Requires -Version 3
<#
.SYNOPSIS
    fb-im.ps1 -- FirstBase technician tool (LoneWolf-themed WPF)
.DESCRIPTION
    Bench-friendly window for non-technical operators:

      Is it ready?     - auto status check; green READY / red NOT READY
      Restart updates  - clears stale locks and starts the update loop
      Collect logs     - runs fb-dump while the tech types issue notes

    Runs FROM THE STICK against the C: install. Elevation via fb-im.cmd (-STA).
.PARAMETER Action
    Menu (default WPF), Status, Updates, or Dump (opens WPF focused on that job).
.PARAMETER Force
    Accepted for compatibility; restart no longer prompts on the happy path.
#>
param(
    [ValidateSet('Menu', 'Status', 'Updates', 'Dump')]
    [string] $Action = 'Menu',

    [switch] $Force,

    # When set (splash dotsource), define functions only — do not open a window.
    [switch] $Library
)

Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'

$FbImVersion = '2.0.23'

function Initialize-FbImWpf {
    # Must run BEFORE Show-FbImWindow is invoked. Parameter binding resolves
    # [System.Windows.*] types before the function body (Add-Type) runs.
    # Standalone fb-im.cmd died with: Unable to find type [System.Windows.Controls.Panel].
    foreach ($asm in @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml')) {
        try { Add-Type -AssemblyName $asm -ErrorAction Stop } catch {}
    }
}
Initialize-FbImWpf

# =============================================================================
# PATHS -- must match Invoke-WindowsUpdateLoop.ps1 / FirstBaseOobeOperatorFinalize.ps1
# =============================================================================
$FbRoot           = 'C:\Windows\Setup\FirstBase'
$FbStateDir       = Join-Path $FbRoot 'State'
$FbLogDir         = Join-Path $FbRoot 'Logs'
$FbPd             = 'C:\ProgramData\FirstBase'
$FbScriptsDir     = 'C:\Windows\Setup\Scripts'

$SealedMarker     = Join-Path $FbPd '.firstbase-sealed'
$PipelineMarker   = Join-Path $FbPd '.pipeline-completed'
$GateFailMarker   = Join-Path $FbPd '.hardware-gate-fail-restart'
$ArmSuppressed    = Join-Path $FbPd '.firstbase-specialize-arm-suppressed'

$DoneFlag         = Join-Path $FbScriptsDir 'FirstBase-Updates-Done.flag'
$CompleteFlag     = Join-Path $FbScriptsDir 'FirstBase-Updates-Complete.flag'
$SetupCompleteCmd = Join-Path $FbScriptsDir 'SetupComplete.cmd'

$LoopScript       = Join-Path $FbRoot 'Invoke-WindowsUpdateLoop.ps1'
$EngineScript     = Join-Path $FbRoot 'FirstBaseWuEngine.ps1'
$LoopLauncher     = Join-Path $FbRoot 'FirstBaseLoopLauncher.cmd'
$StateFile        = Join-Path $FbRoot 'wu-state.json'
$StatusFile       = Join-Path $FbRoot 'wu-status.json'
$HeartbeatFile    = Join-Path $FbRoot 'wu-loop-heartbeat.txt'
$LockFile         = Join-Path $FbStateDir 'wu-loop.lock'

$LoopTaskName     = 'FirstBase\WindowsUpdateLoop'
$LogonTaskName    = 'FirstBase\WindowsUpdateLoopOnLogon'

$RunOnceKey       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$RunKey           = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$SetupStateKey    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'

# =============================================================================
# BUILD IDENTITY
# =============================================================================
function Get-FbImBuildIdentity {
    $id = [ordered]@{
        StickRev = ''; DeviceRev = ''; Product = ''; Dev = $false
        Launcher = ''; ShareLauncher = ''
    }
    $stickPayload = $null
    try { if ($PSScriptRoot) { $stickPayload = Split-Path -Path $PSScriptRoot -Parent } } catch {}

    foreach ($probe in @(
            @{ Dir = $stickPayload; Field = 'StickRev' },
            @{ Dir = $FbRoot;       Field = 'DeviceRev' }
        )) {
        if (-not $probe.Dir) { continue }
        $verFile = Join-Path $probe.Dir 'FirstBaseVersion.ps1'
        if (-not (Test-Path -LiteralPath $verFile)) { continue }
        try {
            $FirstBasePayloadRevision = $null; $FirstBaseProductVersion = $null
            . $verFile
            if ($FirstBasePayloadRevision) { $id[$probe.Field] = [string]$FirstBasePayloadRevision }
            if ($FirstBaseProductVersion -and -not $id.Product) { $id.Product = [string]$FirstBaseProductVersion }
        } catch {}
    }

    $identityPs1 = $null
    foreach ($cand in @($stickPayload, $FbRoot)) {
        if (-not $cand) { continue }
        $probePath = Join-Path $cand 'FirstBaseBuildIdentity.ps1'
        if (Test-Path -LiteralPath $probePath) { $identityPs1 = $probePath; break }
    }
    if ($identityPs1) {
        try {
            . $identityPs1
            $roots = @()
            if ($stickPayload) {
                $roots += $stickPayload
                $payloadParent = Split-Path -Path $stickPayload -Parent
                if ($payloadParent) { $roots += $payloadParent }
            }
            try {
                $qualifier = Split-Path -Path $PSScriptRoot -Qualifier
                if ($qualifier) { $roots += ($qualifier + '\') }
            } catch {}
            if ($FbRoot) { $roots += $FbRoot }
            $build = Get-FbBuildIdentity -PayloadRoot $roots
            if ($build) {
                $id.Dev           = [bool]$build.Dev
                $id.Launcher      = [string]$build.Launcher
                $id.ShareLauncher = [string]$build.ShareLauncher
            }
        } catch {}
    }

    # Fallback: LW_VERSION.json / .dev-build when identity helper is missing
    if (-not $id.Launcher -or -not $id.Dev) {
        $stampRoots = @()
        if ($stickPayload) {
            $stampRoots += $stickPayload
            $fbParent = Split-Path -Path $stickPayload -Parent
            if ($fbParent) { $stampRoots += $fbParent }
        }
        foreach ($root in $stampRoots) {
            if (-not $root) { continue }
            $lw = Join-Path $root 'LW_VERSION.json'
            if (-not (Test-Path -LiteralPath $lw)) { $lw = Join-Path (Split-Path $root -Parent) 'LW_VERSION.json' }
            if (Test-Path -LiteralPath $lw) {
                try {
                    $j = Get-Content -LiteralPath $lw -Raw -ErrorAction Stop | ConvertFrom-Json
                    if (-not $id.Launcher -and $j.launcherVersion) { $id.Launcher = [string]$j.launcherVersion }
                    if ($j.devBuild) { $id.Dev = $true }
                } catch {}
            }
            $devMarker = Join-Path $root '.dev-build'
            if (Test-Path -LiteralPath $devMarker) {
                $id.Dev = $true
                if (-not $id.Launcher) {
                    try {
                        foreach ($line in (Get-Content -LiteralPath $devMarker -ErrorAction Stop)) {
                            if ($line -match '^\s*launcherVersion\s*=\s*(.+)$') {
                                $id.Launcher = $Matches[1].Trim()
                                break
                            }
                        }
                    } catch {}
                }
            }
        }
    }

    return $id
}

$FbBuild = Get-FbImBuildIdentity

# =============================================================================
# STATE PROBES
# =============================================================================
function Test-FbAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-FbMarkerDetail {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $line = (Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop)
        if ($line) { return ([string]$line).Trim() }
    } catch {}
    try { return ('written ' + (Get-Item -LiteralPath $Path).LastWriteTime.ToString('s')) } catch {}
    return 'present'
}

function Get-FbLoopProcess {
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop
        foreach ($p in $procs) {
            if ($p.CommandLine -and $p.CommandLine -match 'Invoke-WindowsUpdateLoop\.ps1') { return $p }
        }
    } catch {}
    return $null
}

function Get-FbFirstBaseTasks {
    $names = @()
    try {
        $tasks = Get-ScheduledTask -TaskPath '\FirstBase\' -ErrorAction Stop
        foreach ($t in $tasks) { $names += ($t.TaskPath.TrimStart('\') + $t.TaskName) }
        return $names
    } catch {}
    try {
        $out = & schtasks.exe /Query /FO LIST 2>$null
        foreach ($line in $out) {
            if ($line -match '^TaskName:\s+\\(FirstBase\\.+)$') { $names += $Matches[1].Trim() }
        }
    } catch {}
    return $names
}

function Get-FbAutostartValues {
    $hits = @()
    foreach ($key in @($RunOnceKey, $RunKey)) {
        try {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                if ($p.Name -match '(?i)firstbase') { $hits += ((Split-Path $key -Leaf) + '\' + $p.Name) }
            }
        } catch {}
    }
    try {
        $out = & reg.exe query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnceEx' /s 2>$null
        foreach ($line in $out) {
            if ($line -match '(?i)\s(FirstBase\S*)\s+REG_') { $hits += ('RunOnceEx\' + $Matches[1]) }
        }
    } catch {}
    return $hits
}

function Get-FbExecutableResidue {
    $hits = @()
    if (-not (Test-Path -LiteralPath $FbRoot)) { return $hits }
    try {
        $files = Get-ChildItem -LiteralPath $FbRoot -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.FullName -like ($FbLogDir + '\*')) { continue }
            if (@('.ps1', '.cmd', '.bat', '.vbs', '.exe') -contains $f.Extension.ToLower()) {
                $hits += $f.FullName
            }
        }
    } catch {}
    return $hits
}

function Get-FbWuState {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try { return (Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Get-FbHeartbeatAge {
    if (-not (Test-Path -LiteralPath $HeartbeatFile)) { return $null }
    try { return ((Get-Date) - (Get-Item -LiteralPath $HeartbeatFile).LastWriteTime) } catch { return $null }
}

function Get-FbImageState {
    try { return [string](Get-ItemProperty -LiteralPath $SetupStateKey -ErrorAction Stop).ImageState } catch { return '' }
}

# =============================================================================
# STATUS / RESTART (structured)
# =============================================================================
function Test-FbImCbsRebootUnsafe {
    # True when a technician-issued shutdown /f would risk 0xc000000f
    # (CBS still replacing ntoskrnl / boot files, or WU still installing).
    $reasons = New-Object System.Collections.Generic.List[string]
    try {
        $sysInfo = New-Object -ComObject Microsoft.Update.SystemInfo
        if ($sysInfo.RebootRequired) { [void]$reasons.Add('Windows Update reports a reboot is owed') }
    } catch {}
    foreach ($p in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        )) {
        try { if (Test-Path -LiteralPath $p) { [void]$reasons.Add('CBS/WU reboot-pending key is present') } } catch {}
    }
    try {
        if (Test-Path -LiteralPath $StatusFile) {
            $obj = Get-Content -LiteralPath $StatusFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $phase = [string]$obj.phase
            $msg = [string]$obj.message
            if ($phase -match '(?i)rebooting') { [void]$reasons.Add('Update loop is in the reboot/CBS-commit phase') }
            if ($msg -match '(?i)cbs pre-reboot|servicing to finish|ntoskrnl|waiting for shutdown') {
                [void]$reasons.Add('Splash/loop reports boot-file commit or shutdown in progress')
            }
            foreach ($u in @($obj.updates)) {
                if (-not $u) { continue }
                $st = [string]$u.Status
                if ($st -match '(?i)download|install') {
                    [void]$reasons.Add('Updates are still downloading or installing')
                    break
                }
            }
        }
    } catch {}
    try {
        foreach ($p in @(Get-Process -Name 'TiWorker','poqexec','dismhost' -ErrorAction SilentlyContinue)) {
            if ($p) {
                [void]$reasons.Add(('Servicing worker {0} is still running' -f $p.Name))
                break
            }
        }
    } catch {}
    $unsafe = ($reasons.Count -gt 0)
    return [pscustomobject]@{
        Unsafe  = [bool]$unsafe
        Reasons = @($reasons | Select-Object -Unique)
        Detail  = if ($unsafe) { [string]::Join('; ', @($reasons | Select-Object -Unique)) } else { '' }
    }
}

function Get-FbImDeviceStatus {
    $sealed    = Test-Path -LiteralPath $SealedMarker
    $pipeline  = Test-Path -LiteralPath $PipelineMarker
    $gateFail  = Test-Path -LiteralPath $GateFailMarker
    $suppress  = Test-Path -LiteralPath $ArmSuppressed
    $complete  = Test-Path -LiteralPath $CompleteFlag
    $tasks     = @(Get-FbFirstBaseTasks)
    $autostart = @(Get-FbAutostartValues)
    $residue   = @(Get-FbExecutableResidue)
    $loopProc  = Get-FbLoopProcess
    $beat      = Get-FbHeartbeatAge
    $imgState  = Get-FbImageState
    $sysOk     = Test-Path -LiteralPath 'C:\Windows\System32\sysprep\Sysprep_succeeded.tag'
    $sysFail   = Test-Path -LiteralPath 'C:\Windows\System32\sysprep\Sysprep_failed.tag'
    $setupPresent = Test-Path -LiteralPath $SetupCompleteCmd
    $pdPresent    = Test-Path -LiteralPath $FbPd

    $reasons = New-Object System.Collections.Generic.List[string]
    $details = New-Object System.Collections.Generic.List[string]

    if (-not $sealed) {
        [void]$reasons.Add('Still needs sealing')
        [void]$details.Add('Seal: not finished')
    } else {
        [void]$details.Add('Seal: finished')
    }
    if ($pipeline) { [void]$details.Add('Pipeline: completed') }
    elseif ($sealed) {
        [void]$reasons.Add('Seal is incomplete')
        [void]$details.Add('Pipeline: missing completion mark')
    }
    if ($sysFail) {
        [void]$reasons.Add('Setup failed on this device')
        [void]$details.Add('Sysprep: failed')
    } elseif ($sysOk) {
        [void]$details.Add('Sysprep: succeeded')
    }
    if ($gateFail) {
        [void]$reasons.Add('Hardware check failed (Wi-Fi, camera, or usable input/output sound)')
        [void]$details.Add('Hardware gate: fail')
    }
    if ($loopProc) {
        [void]$details.Add('Updates: still running')
        if ($sealed) {
            [void]$reasons.Add('Updates are still running')
        }
    } elseif ($complete) {
        [void]$details.Add('Updates: finished')
    } else {
        [void]$details.Add('Updates: not finished')
        if (-not $sealed) {
            [void]$reasons.Add('Updates have not finished')
        }
    }
    if ($beat) {
        $mins = [int]$beat.TotalMinutes
        [void]$details.Add(('Updates heartbeat: {0} min ago' -f $mins))
    }
    if ($imgState) { [void]$details.Add(('Windows image state: {0}' -f $imgState)) }
    if ($tasks.Count -gt 0) {
        [void]$reasons.Add('Leftover scheduled tasks still registered')
        [void]$details.Add(('Tasks left: {0}' -f ($tasks -join ', ')))
    } else {
        [void]$details.Add('Scheduled tasks: clean')
    }
    if ($autostart.Count -gt 0) {
        [void]$reasons.Add('Leftover startup entries still registered')
        [void]$details.Add(('Autostart left: {0}' -f ($autostart -join ', ')))
    } else {
        [void]$details.Add('Autostart: clean')
    }
    if ($residue.Count -gt 0) {
        [void]$reasons.Add('Leftover FirstBase files still on the device')
        [void]$details.Add(('Runnable files left: {0}' -f $residue.Count))
    } else {
        [void]$details.Add('Runnable files: clean')
    }
    if ($setupPresent) {
        [void]$reasons.Add('Setup leftovers still present')
        [void]$details.Add('SetupComplete.cmd: still present')
    } else {
        [void]$details.Add('SetupComplete.cmd: clean')
    }
    if ($suppress -and -not $sealed) {
        [void]$reasons.Add('Finalize did not finish')
        [void]$details.Add('Arm suppression: still set')
    }
    if ($pdPresent -and $sealed) {
        [void]$details.Add('ProgramData markers: present (normal until pack)')
    }

    # Binary verdict: Ready only when sealed, no blockers, no residue-class issues.
    $ready = $sealed -and (-not $sysFail) -and (-not $gateFail) -and
        ($residue.Count -eq 0) -and ($tasks.Count -eq 0) -and ($autostart.Count -eq 0) -and
        (-not $setupPresent) -and ($pipeline) -and (-not $loopProc)

    if ($ready) {
        $reasons.Clear()
        [void]$reasons.Add('Sealed, scrubbed, and clean. Safe to pack.')
    } elseif ($reasons.Count -eq 0) {
        [void]$reasons.Add('Not ready to pack yet')
    }

    $cbsGate = $null
    try { $cbsGate = Test-FbImCbsRebootUnsafe } catch { $cbsGate = $null }
    $cbsUnsafe = $false
    if ($cbsGate -and [bool]$cbsGate.Unsafe) {
        $cbsUnsafe = $true
        [void]$details.Add(('CBS/reboot gate: {0}' -f $cbsGate.Detail))
        [void]$reasons.Add('Do not seal or force-reboot while Windows is committing boot files')
    }

    return [pscustomobject]@{
        Ready      = [bool]$ready
        Headline   = $(if ($ready) { 'READY TO PACK' } else { 'NOT READY' })
        Reasons    = @($reasons)
        Details    = @($details)
        Sealed     = [bool]$sealed
        Pipeline   = [bool]$pipeline
        CanRestart = (-not $sealed) -and (-not $pipeline)
        CanSeal    = (-not $cbsUnsafe)
        LoopRunning = [bool]$loopProc
        Admin      = [bool](Test-FbAdmin)
    }
}

function Invoke-FbImRestartUpdates {
    $result = [ordered]@{
        Ok      = $false
        Message = ''
        Detail  = ''
        Pid     = $null
    }

    if (-not (Test-FbAdmin)) {
        $result.Message = 'Administrator access is required'
        $result.Detail = 'Close this window and open fb-im.cmd from the USB stick.'
        return [pscustomobject]$result
    }

    if ((Test-Path -LiteralPath $SealedMarker) -or (Test-Path -LiteralPath $PipelineMarker)) {
        $result.Message = 'This device is already sealed'
        $result.Detail = 'Updates cannot be restarted here. Re-image the device if more updates are needed.'
        return [pscustomobject]$result
    }

    if (-not (Test-Path -LiteralPath $LoopScript)) {
        $result.Message = 'Update software is missing on this device'
        $result.Detail = 'Collect logs, then re-image the device.'
        return [pscustomobject]$result
    }
    if (-not (Test-Path -LiteralPath $EngineScript)) {
        $result.Message = 'Update engine is missing on this device'
        $result.Detail = 'Collect logs, then re-image the device.'
        return [pscustomobject]$result
    }

    $running = Get-FbLoopProcess
    if ($running) {
        $result.Ok = $true
        $result.Message = 'Updates are already running'
        $result.Detail = 'Leave the device on power. The progress screen should appear shortly.'
        $result.Pid = $running.ProcessId
        return [pscustomobject]$result
    }

    # Auto-clear stale lock - no prompt.
    if (Test-Path -LiteralPath $LockFile) {
        try { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue } catch {}
    }

    $started = $false
    $via = ''
    $tasks = @(Get-FbFirstBaseTasks)

    foreach ($task in @($LoopTaskName, $LogonTaskName)) {
        if ($started) { break }
        if ($tasks -notcontains $task) { continue }
        & schtasks.exe /Run /TN $task 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $started = $true; $via = 'scheduled task' }
    }

    if (-not $started -and (Test-Path -LiteralPath $LoopLauncher)) {
        try {
            Start-Process -FilePath $LoopLauncher -WindowStyle Hidden -ErrorAction Stop | Out-Null
            $started = $true; $via = 'launcher'
        } catch {}
    }

    if (-not $started) {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
        try {
            Start-Process -FilePath $psExe -WindowStyle Hidden -ErrorAction Stop -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-WindowStyle', 'Hidden', '-File', $LoopScript, '-FinalizeToOobe'
            ) | Out-Null
            $started = $true; $via = 'direct start'
        } catch {
            $result.Message = 'Could not start updates'
            $result.Detail = $_.Exception.Message
            return [pscustomobject]$result
        }
    }

    if (-not $started) {
        $result.Message = 'Could not start updates'
        $result.Detail = 'Collect logs for support.'
        return [pscustomobject]$result
    }

    $seen = $null
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 2
        $seen = Get-FbLoopProcess
        if ($seen) { break }
    }

    if ($seen) {
        $result.Ok = $true
        $result.Message = 'Updates started'
        $result.Detail = 'The progress screen should appear shortly. Leave the device on power.'
        $result.Pid = $seen.ProcessId
    } else {
        $result.Ok = $false
        $result.Message = 'Start was sent, but updates were not seen'
        $result.Detail = 'Wait a minute, or collect logs for support. ({0})' -f $via
    }
    return [pscustomobject]$result
}

function Find-FbDumpScript {
    $candidates = @()
    if ($PSScriptRoot) {
        $candidates += (Join-Path $PSScriptRoot 'fb-dump.ps1')
        $payloadDir = Split-Path -Path $PSScriptRoot -Parent
        if ($payloadDir) {
            $candidates += (Join-Path $payloadDir 'Tools\fb-dump.ps1')
            $stickRoot = Split-Path -Path $payloadDir -Parent
            if ($stickRoot) { $candidates += (Join-Path $stickRoot 'WUPayload\Tools\fb-dump.ps1') }
        }
        try {
            $qualifier = Split-Path -Path $PSScriptRoot -Qualifier
            if ($qualifier) {
                $volumeRoot = $qualifier + '\'
                $candidates += (Join-Path $volumeRoot 'FirstBase\WUPayload\Tools\fb-dump.ps1')
                $candidates += (Join-Path $volumeRoot 'WUPayload\Tools\fb-dump.ps1')
            }
        } catch {}
    }
    $candidates += (Join-Path $FbRoot 'Tools\fb-dump.ps1')
    $candidates += (Join-Path $FbRoot 'WUPayload\Tools\fb-dump.ps1')
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Get-FbImRemovableDumpRoot {
    try {
        $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue)
        foreach ($d in $disks) {
            $id = [string]$d.DeviceID
            if (-not $id) { continue }
            if ($id -match '^C') { continue }
            $root = $id.TrimEnd('\') + '\'
            if (Test-Path -LiteralPath $root) { return $id.TrimEnd('\') }
        }
    } catch {}
    try {
        if ($env:FB_USB_DRIVE) {
            $letter = ($env:FB_USB_DRIVE -replace ':$', '').ToUpper()
            if ($letter -and $letter -ne 'C' -and (Test-Path -LiteralPath ($letter + ':\'))) {
                return ($letter + ':')
            }
        }
    } catch {}
    return $null
}

function Get-FbImDumpNameLeaf {
    $sn = 'NOSN'
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        if ($bios.SerialNumber) { $sn = ($bios.SerialNumber -replace '[^\w\-]', '').Trim() }
        if ([string]::IsNullOrWhiteSpace($sn)) { $sn = 'NOSN' }
    } catch {}
    $hhmm = Get-Date -Format 'HHmm'
    $mfr = 'UNK'
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.Manufacturer) {
            $mfr = ($cs.Manufacturer -replace '[^\w]', '')
            if ($mfr.Length -gt 12) { $mfr = $mfr.Substring(0, 12) }
        }
    } catch {}
    return ('{0}-{1}-{2}' -f $sn, $hhmm, $mfr)
}

function Show-FbImDumpFolderPicker {
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { return $false }
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Choose a folder for support logs (USB stick or any writable folder).'
    $d.ShowNewFolderButton = $true
    if ($script:FbImManualDumpRoot -and (Test-Path -LiteralPath $script:FbImManualDumpRoot)) {
        $d.SelectedPath = $script:FbImManualDumpRoot
    }
    try {
        if ([System.Windows.Forms.DialogResult]::OK -eq $d.ShowDialog()) {
            $script:FbImManualDumpRoot = $d.SelectedPath
            return $true
        }
    } catch { return $false }
    return $false
}

function Get-FbImDumpDestFolder {
    # USB stick first; otherwise the folder the operator mapped. Never guess D:.
    $destRoot = Get-FbImRemovableDumpRoot
    if (-not $destRoot -and $script:FbImManualDumpRoot) {
        $destRoot = [string]$script:FbImManualDumpRoot
    }
    if (-not $destRoot) { return $null }
    $destRoot = $destRoot.TrimEnd('\')
    $logsRoot = Join-Path $destRoot 'FirstBase-Logs'
    try {
        if (-not (Test-Path -LiteralPath $logsRoot)) {
            New-Item -ItemType Directory -Path $logsRoot -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
    return (Join-Path $logsRoot (Get-FbImDumpNameLeaf))
}

function Write-FbImIssueMarkdown {
    param(
        [string]$DestFolder,
        [string]$IssueText
    )
    if (-not $DestFolder) { return }
    if ([string]::IsNullOrWhiteSpace($IssueText)) { $IssueText = 'No description provided' }
    $issOutPath = Join-Path $DestFolder 'FirstBase-Issue.md'
    try {
        if (-not (Test-Path -LiteralPath $DestFolder)) {
            New-Item -ItemType Directory -Path $DestFolder -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $dt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $cn = $env:COMPUTERNAME
        $files = @()
        try {
            $files = Get-ChildItem -Path $DestFolder -Recurse -File -EA SilentlyContinue |
                Where-Object { $_.Name -ne 'FirstBase-Issue.md' } |
                Sort-Object FullName |
                ForEach-Object { '- ' + $_.FullName.Substring($DestFolder.Length + 1).TrimStart('\') }
        } catch {}
        $mdLines = @(
            '# FirstBase Diagnostic Report'
            ''
            "**Date:** $dt"
            "**Machine:** $cn"
            ''
            '**Issue Description:**'
            $IssueText
            ''
            '## Logs Included'
        ) + @($files)
        [System.IO.File]::WriteAllLines($issOutPath, $mdLines, [System.Text.Encoding]::UTF8)
    } catch {}
}

function Set-FbImCustomerOobeArmed {
    $setupPs = 'HKLM:\SYSTEM\Setup'
    $wlPs = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $reg = Join-Path $env:WINDIR 'System32\reg.exe'
    if (-not (Test-Path -LiteralPath $reg)) { $reg = 'reg.exe' }
    try {
        if (-not (Test-Path -LiteralPath $setupPs)) { New-Item -Path $setupPs -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $setupPs -Name 'SetupType' -PropertyType DWord -Value 2 -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -LiteralPath $setupPs -Name 'CmdLine' -PropertyType String -Value 'oobe\windeploy.exe' -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -LiteralPath $setupPs -Name 'OOBEInProgress' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
    } catch {}
    try {
        Set-ItemProperty -LiteralPath $wlPs -Name 'AutoAdminLogon' -Value '1' -Type String -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -LiteralPath $wlPs -Name 'DefaultUserName' -Value 'defaultuser0' -Type String -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -LiteralPath $wlPs -Name 'DefaultPassword' -Value '' -Type String -Force -ErrorAction SilentlyContinue
        New-ItemProperty -LiteralPath $wlPs -Name 'AutoLogonCount' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
        Remove-ItemProperty -LiteralPath $wlPs -Name 'DefaultDomainName' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $wlPs -Name 'ForceAutoLogon' -Force -ErrorAction SilentlyContinue
    } catch {}
    foreach ($regArgs in @(
            @('add', 'HKLM\SYSTEM\Setup', '/v', 'SetupType', '/t', 'REG_DWORD', '/d', '2', '/f'),
            @('add', 'HKLM\SYSTEM\Setup', '/v', 'CmdLine', '/t', 'REG_SZ', '/d', 'oobe\windeploy.exe', '/f'),
            @('add', 'HKLM\SYSTEM\Setup', '/v', 'OOBEInProgress', '/t', 'REG_DWORD', '/d', '1', '/f'),
            @('add', 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon', '/v', 'AutoAdminLogon', '/t', 'REG_SZ', '/d', '1', '/f'),
            @('add', 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon', '/v', 'DefaultUserName', '/t', 'REG_SZ', '/d', 'defaultuser0', '/f'),
            @('add', 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon', '/v', 'DefaultPassword', '/t', 'REG_SZ', '/d', '', '/f'),
            @('add', 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon', '/v', 'AutoLogonCount', '/t', 'REG_DWORD', '/d', '1', '/f')
        )) {
        try { Start-Process -FilePath $reg -ArgumentList $regArgs -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
    $oobePs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\OOBE'
    foreach ($skipName in @('SkipMachineOOBE', 'SkipUserOOBE')) {
        try {
            if (Test-Path -LiteralPath $oobePs) {
                Set-ItemProperty -LiteralPath $oobePs -Name $skipName -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

function Invoke-FbImSealToOobe {
    param(
        [ValidateSet('Restart', 'Shutdown')]
        [string]$PowerAction
    )
    $result = [ordered]@{ Ok = $false; Message = ''; Detail = '' }

    if (-not (Test-FbAdmin)) {
        $result.Message = 'Administrator access is required'
        $result.Detail = 'Close this window and open fb-im.cmd from the USB stick.'
        return [pscustomobject]$result
    }

    $cbsGate = $null
    try { $cbsGate = Test-FbImCbsRebootUnsafe } catch { $cbsGate = $null }
    if ($cbsGate -and [bool]$cbsGate.Unsafe) {
        $result.Message = 'Seal blocked — Windows is still committing boot files'
        $result.Detail = ('A forced restart now can cause 0xc000000f / missing ntoskrnl. Wait for the update loop to reboot. {0}' -f $cbsGate.Detail)
        return [pscustomobject]$result
    }

    # Stop update loop if still running.
    try {
        $loop = Get-FbLoopProcess
        if ($loop) {
            Stop-Process -Id $loop.ProcessId -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
        }
    } catch {}
    if (Test-Path -LiteralPath $LockFile) {
        try { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue } catch {}
    }

    # Remove FirstBase scheduled tasks.
    $taskNames = @(Get-FbFirstBaseTasks)
    foreach ($tn in $taskNames) {
        try {
            $leaf = ($tn -replace '^FirstBase\\', '')
            Unregister-ScheduledTask -TaskName $leaf -TaskPath '\FirstBase\' -Confirm:$false -ErrorAction SilentlyContinue
        } catch {}
        try { & schtasks.exe /Delete /TN $tn /F 2>$null | Out-Null } catch {}
    }

    # Remove FirstBase autostart values.
    foreach ($key in @($RunOnceKey, $RunKey)) {
        try {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                if ($p.Name -match '(?i)firstbase') {
                    try { Remove-ItemProperty -LiteralPath $key -Name $p.Name -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
        } catch {}
    }

    # Remove SetupComplete and runnable residue under Setup\FirstBase (keep Logs).
    if (Test-Path -LiteralPath $SetupCompleteCmd) {
        try { Remove-Item -LiteralPath $SetupCompleteCmd -Force -ErrorAction SilentlyContinue } catch {}
    }
    foreach ($path in @(Get-FbExecutableResidue)) {
        try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch {}
    }
    # Also scrub ProgramData FirstBase scripts (keep markers/logs).
    try {
        if (Test-Path -LiteralPath $FbPd) {
            Get-ChildItem -LiteralPath $FbPd -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { @('.ps1', '.cmd', '.bat') -contains $_.Extension.ToLower() } |
                ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
                }
        }
    } catch {}

    # Seal markers.
    try {
        if (-not (Test-Path -LiteralPath $FbPd)) {
            New-Item -ItemType Directory -Path $FbPd -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $stamp = Get-Date -Format 'o'
        Set-Content -LiteralPath $PipelineMarker -Value ("Pipeline completed at {0} (fb-im seal)." -f $stamp) -Encoding UTF8 -Force
        Set-Content -LiteralPath $SealedMarker -Value ("Sealed at {0} (fb-im seal); device ready for OOBE after power cycle." -f $stamp) -Encoding UTF8 -Force
    } catch {}

    try {
        Start-Process -FilePath 'net.exe' -ArgumentList @('user', 'Administrator', '/active:no') -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
    } catch {}

    Set-FbImCustomerOobeArmed

    $shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    if (-not (Test-Path -LiteralPath $shutdown)) { $shutdown = 'shutdown.exe' }
    $flag = if ($PowerAction -eq 'Shutdown') { '/s' } else { '/r' }
    $comment = if ($PowerAction -eq 'Shutdown') {
        'FirstBase: sealed by technician; shutdown. OOBE on next power-on.'
    } else {
        'FirstBase: sealed by technician; restarting into OOBE.'
    }
    try {
        $p = Start-Process -FilePath $shutdown -ArgumentList @($flag, '/t', '12', '/f', '/c', $comment) -WindowStyle Hidden -PassThru -ErrorAction Stop
        if ($p) {
            $exited = $p.WaitForExit(8000)
            if ((-not $exited) -or ($p.ExitCode -eq 0)) {
                $result.Ok = $true
                $result.Message = if ($PowerAction -eq 'Shutdown') { 'Sealed. Shutting down.' } else { 'Sealed. Restarting.' }
                $result.Detail = 'Scrub and seal finished. Customer OOBE is armed.'
                return [pscustomobject]$result
            }
        }
    } catch {}

    try {
        if ($PowerAction -eq 'Shutdown') {
            Stop-Computer -Force -ErrorAction Stop
        } else {
            Restart-Computer -Force -ErrorAction Stop
        }
        $result.Ok = $true
        $result.Message = if ($PowerAction -eq 'Shutdown') { 'Sealed. Shutting down.' } else { 'Sealed. Restarting.' }
        $result.Detail = 'Scrub and seal finished. Customer OOBE is armed.'
        return [pscustomobject]$result
    } catch {
        $result.Message = 'Scrub and seal finished, but power action failed'
        $result.Detail = 'Restart or shut down this device manually.'
        return [pscustomobject]$result
    }
}

function Get-FbImLogoB64 {
    $candidates = @(
        (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'Show-UpdateProgress.ps1'),
        (Join-Path $FbRoot 'Show-UpdateProgress.ps1'),
        (Join-Path $PSScriptRoot '..\Show-UpdateProgress.ps1')
    )
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
            $m = [regex]::Match($raw, '\$script:FbSplashLogoB64\s*=\s*''([^'']+)''')
            if ($m.Success) { return $m.Groups[1].Value }
        } catch {}
    }
    return $null
}

# =============================================================================
# WPF SHELL
# =============================================================================
function Show-FbImWindow {
    param(
        [string]$FocusAction = 'Menu',
        [object]$EmbedHost = $null,
        [scriptblock]$OnEmbedClose = $null
    )

    # Caller (fb-im.cmd entry) may have set Stop; wiring uses null-safe clicks.
    # Do not inherit Stop or a missing FindName kills the host splash ShowDialog.
    $ErrorActionPreference = 'Continue'

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase -ErrorAction Stop
        Add-Type -AssemblyName System.Xaml -ErrorAction Stop
    } catch {
        Write-Host ''
        Write-Host '  Unable to open the technician window on this device.' -ForegroundColor Red
        Write-Host '  Windows presentation components are missing or blocked.' -ForegroundColor DarkGray
        Write-Host ''
        try { [void][Console]::ReadLine() } catch {}
        return
    }

    $logoB64 = Get-FbImLogoB64
    $logoXaml = '<Border Width="44" Height="44" Margin="0,0,10,0" VerticalAlignment="Center"/>'
    if ($logoB64) {
        $logoXaml = '<Ellipse Name="LogoEllipse" Width="44" Height="44" Margin="0,0,10,0" VerticalAlignment="Center"/>'
    }

    $devVisibility = if ($FbBuild.Dev) { 'Visible' } else { 'Collapsed' }
    $rawVer = ''
    if ($FbBuild.Launcher) { $rawVer = [string]$FbBuild.Launcher }
    $rawVer = ($rawVer -replace '[^0-9.]', '').Trim('.')
    if ([string]::IsNullOrWhiteSpace($rawVer)) { $rawVer = '5.3.15' }
    $subtitle = 'v' + $rawVer
    $embedBackVisibility = if ($EmbedHost) { 'Visible' } else { 'Collapsed' }
    $footerText = 'For Internal Use Only'

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Project LoneWolf - Technician Tools"
        Width="1100" Height="700" MinWidth="640" MinHeight="480"
        WindowStartupLocation="CenterScreen"
        WindowState="Maximized"
        Background="#FF02040A"
        FontFamily="Segoe UI"
        ResizeMode="CanResize">
  <Viewbox Name="FbImScaleBox" Stretch="Uniform" StretchDirection="Both"
           HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
  <Grid Name="FbImRoot" Width="1080" Height="640" Margin="16">
    <Grid.Resources>
    <Style TargetType="Button" x:Key="PrimaryBtn">
      <Setter Property="Background" Value="#FF0A1B33"/>
      <Setter Property="Foreground" Value="#FFE8F4FF"/>
      <Setter Property="BorderBrush" Value="#FF22D3EE"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#FF123154"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Opacity" Value="0.45"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="Button" x:Key="QuietBtn" BasedOn="{StaticResource PrimaryBtn}">
      <Setter Property="BorderBrush" Value="#FF123154"/>
      <Setter Property="Foreground" Value="#FFB0C4DE"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>
    </Grid.Resources>

    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <Button Name="BtnEmbedBack" DockPanel.Dock="Right" Content="Back to splash tools"
              Style="{StaticResource QuietBtn}" VerticalAlignment="Center" Margin="12,0,0,0"
              Visibility="$embedBackVisibility"/>
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
        $logoXaml
        <StackPanel VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="PROJECT LONEWOLF" FontSize="18" FontWeight="Bold" Foreground="#FFE8F4FF"/>
            <Border Margin="10,0,0,0" Padding="6,1" Background="#FF2A0A0A" BorderBrush="#FFEF5350"
                    BorderThickness="1" CornerRadius="4" VerticalAlignment="Center"
                    Visibility="$devVisibility">
              <TextBlock Text="DEV" Foreground="#FFEF5350" FontSize="10" FontWeight="Bold"/>
            </Border>
          </StackPanel>
          <TextBlock Text="Technician tools" FontSize="12" Foreground="#FF6B8CB0" Margin="0,1,0,0"/>
          <TextBlock Text="$subtitle" FontSize="10" Foreground="#FF4A6A88" Margin="0,2,0,0"/>
        </StackPanel>
      </StackPanel>
    </DockPanel>

    <!-- Main work area (status + actions) -->
    <Grid Name="MainWorkArea" Grid.Row="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

    <!-- Status hero -->
    <Border Grid.Row="0" Name="StatusHero" CornerRadius="8" Padding="14,10" Margin="0,0,0,10"
            Background="#FF071325" BorderBrush="#FF123154" BorderThickness="1">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Name="StatusLabel" Text="Checking device..." FontSize="11" Foreground="#FF6B8CB0"
                     FontWeight="SemiBold" Margin="0,0,0,4"/>
          <TextBlock Name="StatusHeadline" Text="..." FontSize="24" FontWeight="Bold" Foreground="#FFB0C4DE"/>
          <ItemsControl Name="StatusReasons" Margin="0,6,0,0">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <TextBlock Text="{Binding}" FontSize="13" Foreground="#FFB0C4DE" Margin="0,1,0,1" TextWrapping="Wrap"/>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
          <Expander Name="DetailsExpander" Header="Show details" Margin="0,8,0,0"
                    Foreground="#FF6B8CB0" FontSize="11">
            <ItemsControl Name="StatusDetails" Margin="0,8,0,0">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <TextBlock Text="{Binding}" FontSize="12" Foreground="#FF6B8CB0" Margin="0,1,0,1" FontFamily="Consolas" TextWrapping="Wrap"/>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </Expander>
        </StackPanel>
        <StackPanel Grid.Column="1" VerticalAlignment="Top" Margin="16,0,0,0">
          <Button Name="BtnRefresh" Content="Check again" Style="{StaticResource QuietBtn}" MinWidth="120"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Actions -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*" MinWidth="180"/>
        <ColumnDefinition Width="16"/>
        <ColumnDefinition Width="1.4*" MinWidth="240"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Name="ActionsPanel" CornerRadius="8" Padding="12" Background="#FF071325"
              BorderBrush="#FF123154" BorderThickness="1" Grid.ColumnSpan="3">
        <StackPanel>
          <TextBlock Text="Actions" FontSize="11" Foreground="#FF6B8CB0" FontWeight="SemiBold" Margin="0,0,0,8"/>
          <Button Name="BtnRestart" Content="Restart updates" Style="{StaticResource PrimaryBtn}"
                  HorizontalAlignment="Stretch" Margin="0,0,0,6"/>
          <TextBlock Name="RestartHint" Text="Clears stuck locks and starts updates again."
                     FontSize="11" Foreground="#FF6B8CB0" TextWrapping="Wrap" Margin="0,0,0,10"/>
          <Button Name="BtnCollect" Content="Collect logs" Style="{StaticResource PrimaryBtn}"
                  HorizontalAlignment="Stretch" Margin="0,0,0,6"/>
          <Button Name="BtnChooseDumpFolder" Content="Choose export folder" Style="{StaticResource QuietBtn}"
                  HorizontalAlignment="Stretch" Margin="0,0,0,6"/>
          <TextBlock Name="DumpDestHint" Text="Logs export to a USB stick, or to a folder you choose. Other tools work without a stick."
                     FontSize="11" Foreground="#FF6B8CB0" TextWrapping="Wrap" Margin="0,0,0,10"/>
          <Button Name="BtnSeal" Content="Seal device" Style="{StaticResource PrimaryBtn}"
                  HorizontalAlignment="Stretch" Margin="0,0,0,6"
                  BorderBrush="#FFEF5350"/>
          <TextBlock Text="Scrub and seal, then Restart or Shutdown. Both arm customer OOBE."
                     FontSize="11" Foreground="#FF6B8CB0" TextWrapping="Wrap"/>
          <TextBlock Name="ActionMessage" Text="" FontSize="12" TextWrapping="Wrap" Margin="0,10,0,0"
                     Foreground="#FF22D3EE"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="2" Name="NotesPanel" CornerRadius="10" Padding="18" Background="#FF071325"
              BorderBrush="#FF123154" BorderThickness="1" Visibility="Collapsed">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="What went wrong?" FontSize="14" FontWeight="SemiBold"
                     Foreground="#FFE8F4FF" Margin="0,0,0,8"/>
          <TextBox Grid.Row="1" Name="NotesBox" AcceptsReturn="True" TextWrapping="Wrap"
                   VerticalScrollBarVisibility="Auto" FontSize="14"
                   Background="#FF030609" Foreground="#FFE8F4FF" BorderBrush="#FF123154"
                   BorderThickness="1" Padding="10" CaretBrush="#FF22D3EE"/>
          <ProgressBar Grid.Row="2" Name="CollectProgress" Height="6" Margin="0,12,0,8"
                       IsIndeterminate="False" Minimum="0" Maximum="100" Value="0"
                       Background="#FF0A1B33" Foreground="#FF22D3EE" BorderThickness="0"
                       Visibility="Collapsed"/>
          <DockPanel Grid.Row="3">
            <Button Name="BtnSaveNotes" DockPanel.Dock="Right" Content="Save notes"
                    Style="{StaticResource QuietBtn}" Margin="12,0,0,0" Visibility="Collapsed"/>
            <Button Name="BtnOpenFolder" DockPanel.Dock="Right" Content="Open folder"
                    Style="{StaticResource QuietBtn}" Margin="12,0,0,0" Visibility="Collapsed"/>
            <TextBlock Name="CollectStatus" Text="Type what happened. Collection is running."
                       FontSize="12" Foreground="#FF6B8CB0" TextWrapping="Wrap" VerticalAlignment="Center"/>
          </DockPanel>
        </Grid>
      </Border>
    </Grid>
    </Grid>

    <!-- Seal page (same window; Restart / Shutdown) -->
    <Border Name="SealPage" Grid.Row="1" CornerRadius="8" Padding="28,20"
            Background="#FF071325" BorderBrush="#FF123154" BorderThickness="1"
            Visibility="Collapsed" VerticalAlignment="Center" HorizontalAlignment="Center"
            Width="520" MaxWidth="520">
      <StackPanel>
        <TextBlock Text="Seal device" FontSize="20" FontWeight="Bold" Foreground="#FFE8F4FF" HorizontalAlignment="Center"/>
        <TextBlock Text="Both options scrub FirstBase leftovers and seal the device for customer OOBE. Choose Restart or Shutdown:"
                   FontSize="13" Foreground="#FF6B8CB0" TextWrapping="Wrap" TextAlignment="Center"
                   HorizontalAlignment="Center" Margin="0,10,0,20"/>
        <Button Name="BtnSealRestart" Content="Restart" Style="{StaticResource PrimaryBtn}"
                HorizontalAlignment="Stretch" Margin="0,0,0,10" Padding="14,10" FontSize="15"/>
        <Button Name="BtnSealShutdown" Content="Shutdown" Style="{StaticResource PrimaryBtn}"
                HorizontalAlignment="Stretch" Margin="0,0,0,14" Padding="14,10" FontSize="15"/>
        <TextBlock Name="SealStatus" Text="" FontSize="12" Foreground="#FF22D3EE"
                   TextWrapping="Wrap" TextAlignment="Center" HorizontalAlignment="Center" MinHeight="18" Margin="0,0,0,12"/>
        <Button Name="BtnSealCancel" Content="Cancel" Style="{StaticResource QuietBtn}"
                HorizontalAlignment="Center" Padding="12,8"/>
      </StackPanel>
    </Border>

    <TextBlock Grid.Row="2" Margin="0,8,0,0" FontSize="10" Foreground="#FF4A6A88"
               Text="$footerText"/>

    <Grid Name="FbImBusyOverlay" Grid.Row="0" Grid.RowSpan="3" Visibility="Collapsed"
          Background="#CC02040A" Panel.ZIndex="100">
      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Width="360">
        <TextBlock Name="FbImBusyText" Text="Working..." FontSize="18" FontWeight="SemiBold"
                   Foreground="#FFE8F4FF" HorizontalAlignment="Center" TextAlignment="Center"
                   TextWrapping="Wrap" Margin="0,0,0,14"/>
        <ProgressBar IsIndeterminate="True" Width="280" Height="4" Background="#FF0A1B33"
                     Foreground="#FF22D3EE" BorderThickness="0" HorizontalAlignment="Center"/>
      </StackPanel>
    </Grid>
  </Grid>
  </Viewbox>
</Window>
"@

    $reader = $null
    $window = $null
    try {
        $reader = New-Object System.Xml.XmlNodeReader $xaml
        $window = [Windows.Markup.XamlReader]::Load($reader)
    } catch {
        Write-Host ''
        Write-Host '  fb-im window failed to load.' -ForegroundColor Red
        Write-Host ("  {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
        Write-Host ''
        try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 12 }
        throw
    }
    if (-not $window) {
        Write-Host '  fb-im window loaded empty.' -ForegroundColor Red
        try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 12 }
        throw 'XamlReader returned no window'
    }
    $uiRoot = $window.FindName('FbImRoot')
    if (-not $uiRoot) { $uiRoot = $window.Content }
    $scaleBox = $null
    try { $scaleBox = $window.FindName('FbImScaleBox') } catch {}

    $dispatcher = if ($EmbedHost) { $EmbedHost.Dispatcher } else { $window.Dispatcher }

    # Embedding loads a second Window via XamlReader. Default ShutdownMode is
    # OnLastWindowClose — closing that unused shell exits the splash with no error.
    if ($EmbedHost) {
        try {
            $app = [System.Windows.Application]::Current
            if ($app) {
                $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
            }
        } catch {}
    }

    if ($logoB64) {
        try {
            $bytes = [Convert]::FromBase64String($logoB64)
            $ms = New-Object System.IO.MemoryStream(,$bytes)
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.StreamSource = $ms
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit()
            $bmp.Freeze()
            $brush = New-Object System.Windows.Media.ImageBrush $bmp
            $brush.Stretch = [System.Windows.Media.Stretch]::UniformToFill
            $logoEl = $window.FindName('LogoEllipse')
            if (-not $logoEl -and $uiRoot) { $logoEl = $uiRoot.FindName('LogoEllipse') }
            if ($logoEl) { $logoEl.Fill = $brush }
        } catch {}
    }

    $find = {
        param([string]$Name)
        $el = $null
        try { $el = $window.FindName($Name) } catch {}
        if (-not $el -and $uiRoot) { try { $el = $uiRoot.FindName($Name) } catch {} }
        return $el
    }

    $statusHero     = & $find 'StatusHero'
    $statusLabel    = & $find 'StatusLabel'
    $statusHeadline = & $find 'StatusHeadline'
    $statusReasons  = & $find 'StatusReasons'
    $statusDetails  = & $find 'StatusDetails'
    $btnRefresh     = & $find 'BtnRefresh'
    $btnRestart     = & $find 'BtnRestart'
    $btnCollect     = & $find 'BtnCollect'
    $btnChooseDump  = & $find 'BtnChooseDumpFolder'
    $dumpDestHint   = & $find 'DumpDestHint'
    $btnSeal        = & $find 'BtnSeal'
    $btnSealRestart = & $find 'BtnSealRestart'
    $btnSealShutdown = & $find 'BtnSealShutdown'
    $btnSealCancel  = & $find 'BtnSealCancel'
    $btnOpenFolder  = & $find 'BtnOpenFolder'
    $btnSaveNotes   = & $find 'BtnSaveNotes'
    $btnEmbedBack   = & $find 'BtnEmbedBack'
    $actionMessage  = & $find 'ActionMessage'
    $restartHint    = & $find 'RestartHint'
    $actionsPanel   = & $find 'ActionsPanel'
    $notesPanel     = & $find 'NotesPanel'
    $notesBox       = & $find 'NotesBox'
    $collectProgress = & $find 'CollectProgress'
    $collectStatus  = & $find 'CollectStatus'
    $mainWorkArea   = & $find 'MainWorkArea'
    $sealPage       = & $find 'SealPage'
    $sealStatus     = & $find 'SealStatus'
    $busyOverlay    = & $find 'FbImBusyOverlay'
    $busyText       = & $find 'FbImBusyText'

    # Reparent after FindName so the Window namescope still resolves controls.
    if ($EmbedHost) {
        try {
            $window.Content = $null
            $EmbedHost.Children.Clear()
            $toHost = $scaleBox
            if (-not $toHost) { $toHost = $uiRoot }
            [void]$EmbedHost.Children.Add($toHost)
            # Close the unused Window shell. ShutdownMode is OnExplicitShutdown
            # so this must not tear down the splash ShowDialog.
            try { $window.Close() } catch {}
        } catch {
            throw ("Embed into splash failed: {0}" -f $_.Exception.Message)
        }
    }

    $script:FbImDumpDest = $null
    $script:FbImDumpProc = $null
    $script:FbImNotesIdleArmed = $false
    $script:FbImBusy = $false

    $showFbImBusy = {
        param([string]$Message = 'Working...')
        $script:FbImBusy = $true
        if ($busyText) { $busyText.Text = $Message }
        if ($busyOverlay) { $busyOverlay.Visibility = 'Visible' }
        try { $dispatcher.Invoke([Action]{}, 'Background') } catch {}
    }
    $hideFbImBusy = {
        if ($busyOverlay) { $busyOverlay.Visibility = 'Collapsed' }
        $script:FbImBusy = $false
        try { $dispatcher.Invoke([Action]{}, 'Background') } catch {}
    }

    $showSealPage = {
        if ($mainWorkArea) { $mainWorkArea.Visibility = 'Collapsed' }
        if ($sealPage) { $sealPage.Visibility = 'Visible' }
        if ($sealStatus) { $sealStatus.Text = '' }
    }

    $hideSealPage = {
        if ($sealPage) { $sealPage.Visibility = 'Collapsed' }
        if ($mainWorkArea) { $mainWorkArea.Visibility = 'Visible' }
        if ($sealStatus) { $sealStatus.Text = '' }
    }

    $runSealWithPower = {
        param([string]$PowerAction)
        if ($script:FbImBusy) { return }
        & $showFbImBusy ('Sealing device, then {0}...' -f $PowerAction.ToLower())
        if ($btnSealRestart) { $btnSealRestart.IsEnabled = $false }
        if ($btnSealShutdown) { $btnSealShutdown.IsEnabled = $false }
        if ($btnSealCancel) { $btnSealCancel.IsEnabled = $false }
        if ($sealStatus) {
            $sealStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
            $sealStatus.Text = ('Sealing device, then {0}...' -f $PowerAction.ToLower())
        }
        try {
            $r = Invoke-FbImSealToOobe -PowerAction $PowerAction
            if ($sealStatus) {
                if ($r.Ok) {
                    $sealStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
                } else {
                    $sealStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                }
                $sealStatus.Text = ($r.Message + "`n" + $r.Detail).Trim()
            }
            $actionMessage.Text = ($r.Message + "`n" + $r.Detail).Trim()
            if ($r.Ok) {
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
            } else {
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
            }
        } finally {
            & $hideFbImBusy
            if ($btnSealRestart) { $btnSealRestart.IsEnabled = $true }
            if ($btnSealShutdown) { $btnSealShutdown.IsEnabled = $true }
            if ($btnSealCancel) { $btnSealCancel.IsEnabled = $true }
            [void](& $runStatus)
        }
    }

    $showNotesPanel = {
        $notesPanel.Visibility = 'Visible'
        $actionsPanel.SetValue([System.Windows.Controls.Grid]::ColumnSpanProperty, 1)
        try { [void]$notesBox.Focus() } catch {}
    }

    $hideNotesPanel = {
        $notesPanel.Visibility = 'Collapsed'
        $actionsPanel.SetValue([System.Windows.Controls.Grid]::ColumnSpanProperty, 3)
        $collectProgress.Visibility = 'Collapsed'
        $btnOpenFolder.Visibility = 'Collapsed'
        $btnSaveNotes.Visibility = 'Collapsed'
        try { $notesBox.Text = '' } catch {}
    }

    $writeNotesLive = {
        if (-not $script:FbImDumpDest) { return }
        $text = [string]$notesBox.Text
        if ([string]::IsNullOrWhiteSpace($text)) { $text = 'No description provided' }
        Write-FbImIssueMarkdown -DestFolder $script:FbImDumpDest -IssueText $text
    }

    $restartNotesIdleTimer = {
        try { $notesHideTimer.Stop() } catch {}
        # Only auto-hide after dump finished (or notes were explicitly saved) and
        # the tech has been idle for 8s — never hide solely because collection ended.
        if (-not $script:FbImNotesIdleArmed) { return }
        try { $notesHideTimer.Start() } catch {}
    }

    $finishNotesKeepOpen = {
        param([string]$StatusText)
        & $writeNotesLive
        $btnSaveNotes.Visibility = 'Collapsed'
        if ($script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
            $collectStatus.Text = ('Logs saved to {0}' -f $script:FbImDumpDest)
            $collectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
            $btnOpenFolder.Visibility = 'Visible'
            $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
            if ([string]::IsNullOrWhiteSpace($StatusText)) {
                $actionMessage.Text = 'Log collection finished. Keep typing notes — they save live; panel hides after 8s idle.'
            } else {
                $actionMessage.Text = $StatusText
            }
        }
        $script:FbImNotesIdleArmed = $true
        & $restartNotesIdleTimer
    }

    $notesHideTimer = New-Object System.Windows.Threading.DispatcherTimer
    $notesHideTimer.Interval = [TimeSpan]::FromSeconds(8)
    $notesHideTimer.Add_Tick({
        $notesHideTimer.Stop()
        & $writeNotesLive
        & $hideNotesPanel
        $script:FbImNotesIdleArmed = $false
    })

    if ($notesBox) {
        $notesBox.Add_TextChanged({
            if ($notesPanel.Visibility -ne 'Visible') { return }
            if (-not $script:FbImDumpDest) { return }
            & $writeNotesLive
            if ($script:FbImNotesIdleArmed) { & $restartNotesIdleTimer }
        })
    }

    $applyStatus = {
        param($st)
        if (-not $st) { return }
        $statusHeadline.Text = $st.Headline
        if ($st.Ready) {
            $statusLabel.Text = 'Device status'
            $statusHeadline.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
            $statusHero.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF2E7D32')
            $statusHero.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF0A1F12')
        } else {
            $statusLabel.Text = 'Device status'
            $statusHeadline.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
            $statusHero.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFC62828')
            $statusHero.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF1A0A0A')
        }
        $statusReasons.ItemsSource = @($st.Reasons)
        $statusDetails.ItemsSource = @($st.Details)
        if ($st.CanRestart) {
            $btnRestart.IsEnabled = $true
            $restartHint.Text = 'Clears stuck locks and starts updates again.'
        } else {
            $btnRestart.IsEnabled = $false
            $restartHint.Text = 'Unavailable after sealing. Re-image if more updates are needed.'
        }
        $canSeal = $true
        try { if ($st.PSObject.Properties.Name -contains 'CanSeal') { $canSeal = [bool]$st.CanSeal } } catch {}
        if ($btnSeal) {
            $btnSeal.IsEnabled = [bool]$canSeal
        }
        if (-not $canSeal) {
            $actionMessage.Text = 'Seal/restart is blocked while Windows is committing boot files. Wait for the update loop to reboot.'
            $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFB74D')
        }
        if (-not $st.Admin) {
            $actionMessage.Text = 'Not running as Administrator - open fb-im.cmd from the USB stick.'
            $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFB74D')
        }
    }

    $runStatus = {
        & $showFbImBusy 'Checking device status...'
        $statusLabel.Text = 'Checking device...'
        $statusHeadline.Text = '...'
        $statusHeadline.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFB0C4DE')
        $statusReasons.ItemsSource = @('Please wait')
        try {
            $st = Get-FbImDeviceStatus
            & $applyStatus $st
            return $st
        } finally {
            & $hideFbImBusy
        }
    }

    # Every Click handler is try/caught so a missing command / unexpected throw
    # cannot bubble into the host splash ShowDialog and exit the whole preview.
    if ($btnRefresh) {
        $btnRefresh.Add_Click({
            try {
                if ($script:FbImBusy) { return }
                [void](& $runStatus)
            } catch {
                try {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Status check failed: {0}' -f $_.Exception.Message)
                } catch {}
            }
        })
    }

    if ($btnRestart) {
    $btnRestart.Add_Click({
        try {
            if ($script:FbImBusy) { return }
            & $showFbImBusy 'Starting updates...'
            $btnRestart.IsEnabled = $false
            $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
            $actionMessage.Text = 'Starting updates...'
            try {
                $r = Invoke-FbImRestartUpdates
                if ($r.Ok) {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
                } else {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                }
                $actionMessage.Text = ($r.Message + "`n" + $r.Detail).Trim()
            } finally {
                & $hideFbImBusy
                [void](& $runStatus)
            }
        } catch {
            try {
                & $hideFbImBusy
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = ('Restart updates failed: {0}' -f $_.Exception.Message)
            } catch {}
        }
    })
    }

    $dumpTimer = New-Object System.Windows.Threading.DispatcherTimer
    $dumpTimer.Interval = [TimeSpan]::FromMilliseconds(800)
    $dumpTimer.Add_Tick({
        try {
            if (-not $script:FbImDumpProc) { return }
            try {
                $script:FbImDumpProc.Refresh()
                if (-not $script:FbImDumpProc.HasExited) {
                    $collectStatus.Text = 'Gathering logs... You can keep typing notes.'
                    return
                }
            } catch { return }
            $dumpTimer.Stop()
            $exitCode = 0
            try { $exitCode = [int]$script:FbImDumpProc.ExitCode } catch {}
            $script:FbImDumpProc = $null
            $collectProgress.IsIndeterminate = $false
            $collectProgress.Value = 100
            & $hideFbImBusy
            $btnCollect.IsEnabled = $true
            $copiedCount = 0
            try {
                $copiedCount = @(Get-ChildItem -LiteralPath $script:FbImDumpDest -Recurse -File -Force -EA SilentlyContinue |
                    Where-Object { $_.Name -ne 'FirstBase-Issue.md' -and $_.Name -ne 'DUMP-SUMMARY.txt' }).Count
            } catch { $copiedCount = 0 }
            # Dump finished mid-edit is common — keep the notes panel open and only
            # auto-hide after 8s of inactivity. Live MD writes happen on keystrokes.
            if ($copiedCount -le 0) {
                $failMsg = 'Dump copied 0 files. Collection failed.'
                & $finishNotesKeepOpen $failMsg
                $collectStatus.Text = $failMsg
                $collectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                try {
                    if (Get-Command Set-FbSplashTechStatus -ErrorAction SilentlyContinue) {
                        Set-FbSplashTechStatus $failMsg '#FFEF5350'
                    }
                } catch {}
                if ($script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
                    $btnOpenFolder.Visibility = 'Visible'
                }
            } elseif ($exitCode -eq 0 -and $script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
                & $finishNotesKeepOpen 'Log collection finished. Keep typing notes — they save live; panel hides after 8s idle.'
            } else {
                & $finishNotesKeepOpen 'Log collection finished with problems. Notes still save live; panel hides after 8s idle.'
                $collectStatus.Text = 'Log collection finished with problems. Check the USB stick for a partial folder.'
                $collectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFB74D')
                if ($script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
                    $btnOpenFolder.Visibility = 'Visible'
                }
            }
        } catch {}
    })

    if ($btnChooseDump) {
        $btnChooseDump.Add_Click({
            try {
                if (Show-FbImDumpFolderPicker) {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
                    $actionMessage.Text = ('Export folder set to {0}' -f $script:FbImManualDumpRoot)
                    if ($dumpDestHint) {
                        $dumpDestHint.Text = ('Logs will export to: {0}' -f $script:FbImManualDumpRoot)
                    }
                }
            } catch {
                try {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Could not choose a folder: {0}' -f $_.Exception.Message)
                } catch {}
            }
        })
    }

    if ($btnCollect) {
    $btnCollect.Add_Click({
        try {
            if ($script:FbImBusy) { return }
            $dump = Find-FbDumpScript
            if (-not $dump) {
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = 'Log collector (fb-dump) was not found on this device.'
                return
            }
            $script:FbImDumpDest = Get-FbImDumpDestFolder
            if (-not $script:FbImDumpDest) {
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFB74D')
                $actionMessage.Text = 'Plug in a USB stick, or choose an export folder, then Collect logs again.'
                if (-not (Show-FbImDumpFolderPicker)) { return }
                $script:FbImDumpDest = Get-FbImDumpDestFolder
                if (-not $script:FbImDumpDest) { return }
            }
            try {
                if (-not (Test-Path -LiteralPath $script:FbImDumpDest)) {
                    New-Item -ItemType Directory -Path $script:FbImDumpDest -Force -ErrorAction Stop | Out-Null
                }
            } catch {
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = 'Could not create the log folder. Choose another export folder or insert a USB stick.'
                return
            }

            & $showNotesPanel

            # Keep the notes panel interactive during dump — busy flag only (no full-screen overlay).
            $script:FbImBusy = $true
            $script:FbImNotesIdleArmed = $false
            $btnCollect.IsEnabled = $false
            $btnOpenFolder.Visibility = 'Collapsed'
            $btnSaveNotes.Visibility = 'Collapsed'
            try { $notesHideTimer.Stop() } catch {}
            # Seed the MD immediately so keystrokes have a file to update while dump runs.
            & $writeNotesLive
            $collectProgress.Visibility = 'Visible'
            $collectProgress.IsIndeterminate = $true
            $collectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF6B8CB0')
            $collectStatus.Text = 'Gathering logs... You can keep typing notes.'
            $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
            $actionMessage.Text = 'Collecting logs in the background.'

            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
            $dumpArgs = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', $dump,
                '-Dest', $script:FbImDumpDest,
                '-NoPrompt'
            )
            try {
                $script:FbImDumpProc = Start-Process -FilePath $psExe -ArgumentList $dumpArgs -WindowStyle Hidden -PassThru -ErrorAction Stop
                $dumpTimer.Start()
                try { [void]$notesBox.Focus() } catch {}
            } catch {
                $script:FbImBusy = $false
                if ($busyOverlay) { $busyOverlay.Visibility = 'Collapsed' }
                $btnCollect.IsEnabled = $true
                $collectProgress.Visibility = 'Collapsed'
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = 'Could not start log collection.'
            }
        } catch {
            try {
                $script:FbImBusy = $false
                $btnCollect.IsEnabled = $true
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = ('Collect logs failed: {0}' -f $_.Exception.Message)
            } catch {}
        }
    })
    }

    if ($btnOpenFolder) {
    $btnOpenFolder.Add_Click({
        try {
            if ($script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList $script:FbImDumpDest | Out-Null
            }
        } catch {}
    })
    }

    if ($btnSaveNotes) {
    $btnSaveNotes.Add_Click({
        try {
            $text = [string]$notesBox.Text
            if ([string]::IsNullOrWhiteSpace($text)) {
                $confirm = [System.Windows.MessageBox]::Show(
                    $window,
                    "No notes were entered.`n`nSave with no description?",
                    'No notes entered',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Question
                )
                if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
            }
            $script:FbImNotesIdleArmed = $true
            & $finishNotesKeepOpen 'Notes saved. Keep typing if needed — panel hides after 8s idle.'
        } catch {
            try {
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = ('Save notes failed: {0}' -f $_.Exception.Message)
            } catch {}
        }
    })
    }

    if ($btnSeal) {
    $btnSeal.Add_Click({
        try {
            if ($script:FbImBusy) { return }
            & $showSealPage
        } catch {
            try {
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = ('Seal page failed: {0}' -f $_.Exception.Message)
            } catch {}
        }
    })
    }

    if ($btnSealRestart) {
        $btnSealRestart.Add_Click({
            try { & $runSealWithPower 'Restart' } catch {
                try {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Seal+restart failed: {0}' -f $_.Exception.Message)
                } catch {}
            }
        })
    }
    if ($btnSealShutdown) {
        $btnSealShutdown.Add_Click({
            try { & $runSealWithPower 'Shutdown' } catch {
                try {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Seal+shutdown failed: {0}' -f $_.Exception.Message)
                } catch {}
            }
        })
    }
    if ($btnSealCancel) {
        $btnSealCancel.Add_Click({
            try {
                if ($script:FbImBusy) { return }
                & $hideSealPage
            } catch {}
        })
    }

    if ($btnEmbedBack) {
        # Persist callback on $script: — locals vanish after Show-FbImWindow returns in embed mode,
        # and WPF Click handlers resolve variables at invoke time.
        $script:FbImOnEmbedClose = $OnEmbedClose
        $script:FbImHideBusy = $hideFbImBusy
        $btnEmbedBack.Add_Click({
            try {
                if ($script:FbImHideBusy) { & $script:FbImHideBusy }
                $script:FbImBusy = $false
                if ($script:FbImOnEmbedClose) {
                    & $script:FbImOnEmbedClose
                }
            } catch {
                try { Write-Host ("fb-im embed back failed: {0}" -f $_.Exception.Message) } catch {}
            }
        })
    } else {
        try { Write-Host 'fb-im: BtnEmbedBack not found — Back to splash tools will not work' } catch {}
    }

    $startUi = {
        [void](& $runStatus)
        if ($FocusAction -eq 'Updates' -and $btnRestart) {
            $btnRestart.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
        } elseif ($FocusAction -eq 'Dump' -and $btnCollect) {
            $btnCollect.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
        }
    }

    if ($EmbedHost) {
        & $startUi
        return
    }

    try { $window.Topmost = $true } catch {}
    $window.Add_ContentRendered({
        try { & $startUi } catch {
            try { Write-Host ("fb-im ContentRendered failed: {0}" -f $_.Exception.Message) } catch {}
        }
    })
    [void]$window.ShowDialog()
}

# =============================================================================
# ENTRY
# =============================================================================
if (-not $Library) {
    $focus = switch ($Action) {
        'Status'  { 'Status' }
        'Updates' { 'Updates' }
        'Dump'    { 'Dump' }
        default   { 'Menu' }
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        Initialize-FbImWpf
        Show-FbImWindow -FocusAction $focus
    } catch {
        Write-Host ''
        Write-Host '  fb-im failed to open.' -ForegroundColor Red
        Write-Host ("  {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Press Enter to close.' -ForegroundColor DarkGray
        try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 15 }
        $ErrorActionPreference = $prevEap
        exit 1
    }
    $ErrorActionPreference = $prevEap
}
