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

$FbImVersion = '2.0.28'

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
$FbImFileDir = $PSScriptRoot
if (-not $FbImFileDir) {
    try { $FbImFileDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {}
}

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
    # USB destage first so splash does not keep using a stale C: copy.
    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue | ForEach-Object {
            $root = $_.DeviceID + '\'
            $candidates += (Join-Path $root 'FirstBase\WUPayload\Tools\fb-dump.ps1')
            $candidates += (Join-Path $root 'WUPayload\Tools\fb-dump.ps1')
            $candidates += (Join-Path $root 'Tools\fb-dump.ps1')
        }
    } catch {}
    $toolDir = $FbImFileDir
    if (-not $toolDir) { $toolDir = $PSScriptRoot }
    if ($toolDir) {
        $candidates += (Join-Path $toolDir 'fb-dump.ps1')
        $payloadDir = Split-Path -Path $toolDir -Parent
        if ($payloadDir) {
            $candidates += (Join-Path $payloadDir 'Tools\fb-dump.ps1')
            $stickRoot = Split-Path -Path $payloadDir -Parent
            if ($stickRoot) { $candidates += (Join-Path $stickRoot 'WUPayload\Tools\fb-dump.ps1') }
        }
        try {
            $qualifier = Split-Path -Path $toolDir -Qualifier
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
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Write-FbImAsciiNote {
    param([string]$Path, [string]$Text)
    if (-not $Path) { return }
    try {
        $body = [string]$Text
        if (-not $body.EndsWith("`r`n") -and -not $body.EndsWith("`n")) { $body = $body + "`r`n" }
        [System.IO.File]::WriteAllText($Path, $body, [System.Text.Encoding]::ASCII)
    } catch {}
}

function Copy-FbImOnDeviceLogs {
    param([string]$DestFolder)
    if (-not $DestFolder) { return 0 }
    try {
        if (-not (Test-Path -LiteralPath $DestFolder)) {
            New-Item -ItemType Directory -Path $DestFolder -Force -ErrorAction Stop | Out-Null
        }
    } catch { return 0 }

    $copied = 0
    $copyOne = {
        param([string]$Source, [string]$DestDir, [string]$Label)
        $safeLabel = ($Label -replace '[^\w\-]', '-')
        if (-not $safeLabel) { $safeLabel = 'source' }
        $missingPath = Join-Path $DestFolder ($safeLabel + '-MISSING.txt')
        if (-not $Source -or -not (Test-Path -LiteralPath $Source)) {
            Write-FbImAsciiNote -Path $missingPath -Text ('Source missing: ' + [string]$Source)
            return 0
        }
        $n = 0
        try { New-Item -ItemType Directory -Path $DestDir -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        $files = @()
        try { $files = @(Get-ChildItem -LiteralPath $Source -Force -Recurse -File -ErrorAction SilentlyContinue) } catch { $files = @() }
        foreach ($f in $files) {
            try {
                $rel = $f.FullName.Substring($Source.Length).TrimStart('\')
                $target = Join-Path $DestDir $rel
                $parent = Split-Path -Parent $target
                if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue | Out-Null
                }
                Copy-Item -LiteralPath $f.FullName -Destination $target -Force -ErrorAction Stop
                $n++
            } catch {
                $skipPath = Join-Path $DestFolder 'COPY-SKIP.txt'
                $msg = 'SKIP: ' + $f.FullName + ' :: ' + $_.Exception.Message
                try { Add-Content -LiteralPath $skipPath -Value $msg -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
            }
        }
        return $n
    }

    $copied += & $copyOne 'C:\Windows\Setup\FirstBase\Logs' (Join-Path $DestFolder 'Logs') 'Setup-FirstBase-Logs'
    $copied += & $copyOne 'C:\Windows\Setup\FirstBase\State' (Join-Path $DestFolder 'State') 'Setup-FirstBase-State'
    $copied += & $copyOne 'C:\ProgramData\FirstBase' (Join-Path $DestFolder 'ProgramData-FirstBase') 'ProgramData-FirstBase'
    $wuRoot = 'C:\Windows\Setup\FirstBase'
    $wuDest = Join-Path $DestFolder 'Logs'
    try { New-Item -ItemType Directory -Path $wuDest -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    $extra = @()
    try {
        $extra = @(Get-ChildItem -LiteralPath $wuRoot -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'WU-*.log' -or $_.Name -like '*.log' })
    } catch { $extra = @() }
    foreach ($f in $extra) {
        try {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $wuDest $f.Name) -Force -ErrorAction Stop
            $copied++
        } catch {
            $skipPath = Join-Path $DestFolder 'COPY-SKIP.txt'
            $msg = 'SKIP: ' + $f.FullName + ' :: ' + $_.Exception.Message
            try { Add-Content -LiteralPath $skipPath -Value $msg -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
        }
    }
    return $copied
}

function Copy-FbImDumpExtras {
    param([string]$DestFolder)
    if (-not $DestFolder) { return 0 }
    $n = Copy-FbImOnDeviceLogs -DestFolder $DestFolder
    $usbRoot = Join-Path $DestFolder 'UsbStickRoot'
    try { New-Item -ItemType Directory -Path $usbRoot -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue | ForEach-Object {
            $dl = ([string]$_.DeviceID).TrimEnd(':').ToUpper()
            if (-not $dl -or $dl -eq 'C') { return }
            foreach ($leaf in @(
                    'FirstBase-Deploy.log', 'FirstBase-Trace.log', 'FirstBase-DISM.log',
                    'FirstBase-DISM-wrapper.log', 'FirstBase-winpe.log', 'FirstBase-disksetup.log',
                    'fb-im-last-launch.log', 'FirstBase-Layout.txt', 'FirstBase-WIPE-PENDING.txt'
                )) {
                $src = $dl + ':\' + $leaf
                if (Test-Path -LiteralPath $src) {
                    try {
                        $dstName = [IO.Path]::GetFileNameWithoutExtension($leaf) + '-' + $dl + [IO.Path]::GetExtension($leaf)
                        Copy-Item -LiteralPath $src -Destination (Join-Path $usbRoot $dstName) -Force -ErrorAction Stop
                        $n++
                    } catch {}
                }
            }
        }
    } catch {}
    try {
        $tl = Join-Path $DestFolder 'tasklist.txt'
        (Get-Process | Select-Object Name, Id, CPU | Format-Table -AutoSize | Out-String) |
            Set-Content -LiteralPath $tl -Encoding ASCII -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $tl) { $n++ }
    } catch {}
    try {
        $si = Join-Path $DestFolder 'sysinfo.txt'
        $lines = @(
            ('Computer=' + $env:COMPUTERNAME)
            ('Captured=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            '=== Disk volumes ==='
        )
        try {
            $lines += @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
                ForEach-Object { '{0} {1} {2}' -f $_.DeviceID, $_.VolumeName, $_.FileSystem })
        } catch {}
        [System.IO.File]::WriteAllLines($si, $lines, [System.Text.Encoding]::ASCII)
        $n++
    } catch {}
    return $n
}

function Get-FbImDumpFileCount {
    param([string]$DestFolder)
    if (-not $DestFolder -or -not (Test-Path -LiteralPath $DestFolder)) { return 0 }
    try {
        return @(Get-ChildItem -LiteralPath $DestFolder -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -ne 'FirstBase-Issue.md' -and
                $_.Name -ne 'DUMP-SUMMARY.txt' -and
                $_.Name -ne 'fb-dump-host.txt'
            }).Count
    } catch { return 0 }
}

function Start-FbImDumpProcess {
    param([string]$DumpScript, [string]$DestFolder)
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
    $workDir = Split-Path -Parent $DumpScript
    if (-not $workDir) { $workDir = $env:SystemRoot }
    $esc = {
        param([string]$s)
        if ($null -eq $s) { return '' }
        return ([string]$s).Replace("'", "''")
    }
    $dumpQ = & $esc $DumpScript
    $destQ = & $esc $DestFolder
    # One -Command string so -Dest binds as a named parameter. Do not use -File:
    # Start-Process Hidden + -File often dropped -Dest on PS 5.1.
    $command = "& { & '$dumpQ' -Dest '$destQ' -NoPrompt }"
    $arg = '-NoProfile -ExecutionPolicy Bypass -NoLogo -NonInteractive -Command "' + $command + '"'
    $hostLog = Join-Path $DestFolder 'fb-dump-host.txt'
    $hostLines = @(
        ('ps=' + $psExe)
        ('file=' + $DumpScript)
        ('dest=' + $DestFolder)
        ('args=' + $arg)
        ('cwd=' + $workDir)
        ('started=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    )
    try { [System.IO.File]::WriteAllLines($hostLog, $hostLines, [System.Text.Encoding]::ASCII) } catch {}
    $p = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $psExe
        $psi.Arguments = $arg
        $psi.WorkingDirectory = $workDir
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
    } catch {
        $p = $null
    }
    if (-not $p) {
        try {
            $p = Start-Process -FilePath $psExe -ArgumentList $arg -WorkingDirectory $workDir -WindowStyle Hidden -PassThru -ErrorAction Stop
        } catch {
            $p = $null
        }
    }
    if (-not $p) {
        # Last resort: nested runspace so fb-dump's `exit` cannot kill splash ShowDialog.
        return Start-FbImDumpRunspace -DumpScript $DumpScript -DestFolder $DestFolder
    }
    return $p
}

function Start-FbImDumpRunspace {
    param([string]$DumpScript, [string]$DestFolder)
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript(@"
param(`$DumpScript, `$DestFolder)
`$ErrorActionPreference = 'Continue'
& `$DumpScript -Dest `$DestFolder -NoPrompt
"@).AddArgument($DumpScript).AddArgument($DestFolder)
    $handle = $ps.BeginInvoke()
    if (-not $handle) { throw 'Dump helper runspace did not start.' }
    return [pscustomobject]@{
        PSObject        = $true
        IsRunspace      = $true
        PowerShell      = $ps
        Handle          = $handle
        Runspace        = $rs
        HasExited       = $false
        ExitCode        = 0
        Refresh         = $null
    }
}

function Update-FbImDumpHandle {
    param($Handle)
    if (-not $Handle) { return $null }
    try {
        if ($Handle.PSObject.Properties.Name -contains 'IsRunspace' -and $Handle.IsRunspace) {
            $done = [bool]$Handle.Handle.IsCompleted
            $Handle.HasExited = $done
            if ($done) {
                try { $Handle.PowerShell.EndInvoke($Handle.Handle) | Out-Null } catch {}
                try { $Handle.ExitCode = 0 } catch {}
                try { $Handle.PowerShell.Dispose() } catch {}
                try { $Handle.Runspace.Close(); $Handle.Runspace.Dispose() } catch {}
            }
            return $Handle
        }
    } catch {}
    try { $Handle.Refresh() } catch {}
    return $Handle
}

function Invoke-FbImImmediateShutdown {
    $result = [ordered]@{
        Ok      = $false
        Message = ''
    }
    $shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    if (-not (Test-Path -LiteralPath $shutdown)) { $shutdown = 'shutdown.exe' }
    try {
        Start-Process -FilePath $shutdown -ArgumentList @('/s', '/f', '/t', '0') -WindowStyle Hidden -ErrorAction Stop | Out-Null
        $result.Ok = $true
        $result.Message = 'Shutting down.'
        return [pscustomobject]$result
    } catch {}
    try {
        Stop-Computer -Force -ErrorAction Stop
        $result.Ok = $true
        $result.Message = 'Shutting down.'
    } catch {
        $result.Message = $_.Exception.Message
    }
    return [pscustomobject]$result
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
    if ([string]::IsNullOrWhiteSpace($rawVer)) { $rawVer = '5.4.12' }
    $subtitle = 'v' + $rawVer
    $embedBackVisibility = if ($EmbedHost) { 'Visible' } else { 'Collapsed' }
    $script:FbImEmbedHosted = [bool]$EmbedHost
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
  <!-- ScrollViewer is the embed root. Nested Viewbox plus a fixed 640px canvas
       clipped notes off the splash DesignCanvas with no wheel target.
       Fill the host; scroll only if details overflow. -->
  <ScrollViewer Name="FbImScroller"
                VerticalScrollBarVisibility="Auto"
                HorizontalScrollBarVisibility="Disabled"
                CanContentScroll="False"
                PanningMode="VerticalOnly"
                HorizontalAlignment="Stretch"
                VerticalAlignment="Stretch"
                Background="#FF02040A"
                Focusable="True">
  <Grid Name="FbImRoot" Margin="14,10,14,10" MinWidth="560">
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

    <!-- Status | actions on one row; notes take leftover height (on-screen in splash). -->
    <Grid Name="MainWorkArea" Grid.Row="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*" MinHeight="132"/>
      </Grid.RowDefinitions>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="268"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

    <Border Grid.Row="0" Grid.Column="0" Name="StatusHero" CornerRadius="8" Padding="12,10"
            Margin="0,0,10,8" Background="#FF071325" BorderBrush="#FF123154" BorderThickness="1"
            VerticalAlignment="Stretch">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0" Margin="0,0,0,8">
          <Ellipse Name="StatusLamp" Width="16" Height="16" Fill="#FF6B8CB0"
                   Stroke="#FF8FB4D9" StrokeThickness="2"
                   DockPanel.Dock="Left" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <Button Name="BtnRefresh" DockPanel.Dock="Right" Content="Check"
                  Style="{StaticResource QuietBtn}" Padding="8,4" FontSize="11" MinWidth="64"/>
          <TextBlock Name="StatusLabel" Text="Device" FontSize="11" Foreground="#FF6B8CB0"
                     FontWeight="SemiBold" VerticalAlignment="Center"/>
        </DockPanel>
        <StackPanel Grid.Row="1">
          <Border Name="StatusSealChipBorder" Padding="8,2" CornerRadius="4" HorizontalAlignment="Left"
                  Background="#FF1A0A0A" BorderBrush="#FFC62828" BorderThickness="1" Margin="0,0,0,6">
            <TextBlock Name="StatusSealChip" Text="..." FontSize="10" FontWeight="Bold"
                       Foreground="#FFEF5350"/>
          </Border>
          <TextBlock Name="StatusHeadline" Text="..." FontSize="16" FontWeight="Bold"
                     Foreground="#FFB0C4DE" TextWrapping="Wrap"/>
          <TextBlock Name="StatusIdentity" Text="" FontSize="10" Foreground="#FF4A6A88" Margin="0,4,0,6"/>
          <ItemsControl Name="StatusReasons" MaxHeight="52">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <TextBlock Text="{Binding}" FontSize="11" Foreground="#FFB0C4DE" Margin="0,1,0,1" TextWrapping="Wrap"/>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
        </StackPanel>
        <Expander Grid.Row="2" Name="DetailsExpander" Header="Details" Margin="0,6,0,0"
                  Foreground="#FF6B8CB0" FontSize="11">
          <ItemsControl Name="StatusDetails" Margin="0,6,0,0">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <TextBlock Text="{Binding}" FontSize="11" Foreground="#FF6B8CB0" Margin="0,1,0,1"
                           FontFamily="Consolas" TextWrapping="Wrap"/>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
        </Expander>
      </Grid>
    </Border>

    <Border Grid.Row="0" Grid.Column="1" Name="ActionsPanel" CornerRadius="8" Padding="10,10"
            Margin="0,0,0,8" Background="#FF071325" BorderBrush="#FF123154" BorderThickness="1">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Actions" FontSize="11" Foreground="#FF6B8CB0"
                   FontWeight="SemiBold" Margin="0,0,0,6"/>
        <UniformGrid Grid.Row="1" Name="ActionsGrid" Rows="2" Columns="2" Margin="0,0,0,4">
          <StackPanel Margin="0,0,6,6">
            <Button Name="BtnRestart" Content="Restart updates" Style="{StaticResource PrimaryBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34"/>
            <TextBlock Name="RestartHint" Text="Clears stuck locks and starts updates again."
                       FontSize="10" Foreground="#FF6B8CB0" TextWrapping="Wrap" Margin="0,4,0,0"/>
          </StackPanel>
          <StackPanel Margin="6,0,0,6">
            <Button Name="BtnCollect" Content="Collect logs" Style="{StaticResource PrimaryBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34"/>
            <TextBlock Name="DumpDestHint" Text="Export to a USB stick, or a folder you choose."
                       FontSize="10" Foreground="#FF6B8CB0" TextWrapping="Wrap" Margin="0,4,0,0"/>
          </StackPanel>
          <StackPanel Margin="0,6,6,0">
            <Button Name="BtnChooseDumpFolder" Content="Choose export folder" Style="{StaticResource QuietBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34"/>
            <Button Name="BtnShutdown" Content="Shutdown" Style="{StaticResource PrimaryBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34" Margin="0,6,0,0"
                    BorderBrush="#FFEF5350" Visibility="Collapsed"/>
            <TextBlock Name="ShutdownHint" Text="Power off this device."
                       FontSize="10" Foreground="#FF6B8CB0" TextWrapping="Wrap" Margin="0,4,0,0"
                       Visibility="Collapsed"/>
          </StackPanel>
          <StackPanel Margin="6,6,0,0">
            <Button Name="BtnSeal" Content="Seal device" Style="{StaticResource PrimaryBtn}"
                    HorizontalAlignment="Stretch" MinHeight="34"
                    BorderBrush="#FFEF5350"/>
            <TextBlock Text="Scrub and seal, then Restart or Shutdown. Both arm customer OOBE."
                       FontSize="10" Foreground="#FF6B8CB0" TextWrapping="Wrap" Margin="0,4,0,0"/>
          </StackPanel>
        </UniformGrid>
        <TextBlock Grid.Row="2" Name="ActionMessage" Text="" FontSize="12" TextWrapping="Wrap" Margin="0,4,0,0"
                   Foreground="#FF22D3EE"/>
      </Grid>
    </Border>

    <Border Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Name="NotesPanel" CornerRadius="8"
            Padding="12,10" Background="#FF071325" BorderBrush="#FF22D3EE" BorderThickness="1"
            Visibility="Collapsed" MinHeight="132">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*" MinHeight="88"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Name="CollectBanner" Margin="0,0,0,8" Visibility="Collapsed">
          <TextBlock Text="Collecting logs" FontSize="13" FontWeight="SemiBold" Foreground="#FF22D3EE" Margin="0,0,0,6"/>
          <ProgressBar Name="CollectProgress" Height="8" Margin="0,0,0,6"
                       IsIndeterminate="False" Minimum="0" Maximum="100" Value="0"
                       Background="#FF0A1B33" Foreground="#FF22D3EE" BorderThickness="0"/>
          <TextBlock Name="CollectStatus" Text="Gathering logs... You can type notes below."
                     FontSize="12" Foreground="#FF6B8CB0" TextWrapping="Wrap"/>
        </StackPanel>
        <TextBlock Grid.Row="1" Text="What went wrong?" FontSize="13" FontWeight="SemiBold"
                   Foreground="#FFE8F4FF" Margin="0,0,0,6"/>
        <TextBox Grid.Row="2" Name="NotesBox" AcceptsReturn="True" TextWrapping="Wrap"
                 VerticalScrollBarVisibility="Auto" FontSize="14"
                 Background="#FF030609" Foreground="#FFE8F4FF" BorderBrush="#FF123154"
                 BorderThickness="1" Padding="8" CaretBrush="#FF22D3EE" MinHeight="88"/>
        <DockPanel Grid.Row="3" Margin="0,8,0,0">
          <Button Name="BtnSaveNotes" DockPanel.Dock="Right" Content="Save notes"
                  Style="{StaticResource QuietBtn}" Margin="12,0,0,0" Visibility="Collapsed"/>
          <Button Name="BtnOpenFolder" DockPanel.Dock="Right" Content="Open folder"
                  Style="{StaticResource QuietBtn}" Margin="12,0,0,0" Visibility="Collapsed"/>
          <TextBlock Text="Notes save into FirstBase-Issue.md while collection runs."
                     FontSize="11" Foreground="#FF6B8CB0" TextWrapping="Wrap" VerticalAlignment="Center"/>
        </DockPanel>
      </Grid>
    </Border>
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
          Background="#CC02040A" Panel.ZIndex="100" IsHitTestVisible="False">
      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Width="360">
        <TextBlock Name="FbImBusyText" Text="Working..." FontSize="18" FontWeight="SemiBold"
                   Foreground="#FFE8F4FF" HorizontalAlignment="Center" TextAlignment="Center"
                   TextWrapping="Wrap" Margin="0,0,0,14"/>
        <ProgressBar IsIndeterminate="True" Width="280" Height="4" Background="#FF0A1B33"
                     Foreground="#FF22D3EE" BorderThickness="0" HorizontalAlignment="Center"/>
      </StackPanel>
    </Grid>
  </Grid>
  </ScrollViewer>
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
    $scroller = $null
    try { $scroller = $window.FindName('FbImScroller') } catch {}
    $scaleBox = $scroller

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
    $statusLamp     = & $find 'StatusLamp'
    $statusLabel    = & $find 'StatusLabel'
    $statusHeadline = & $find 'StatusHeadline'
    $statusSealChip = & $find 'StatusSealChip'
    $statusSealChipBorder = & $find 'StatusSealChipBorder'
    $statusIdentity = & $find 'StatusIdentity'
    $statusReasons  = & $find 'StatusReasons'
    $statusDetails  = & $find 'StatusDetails'
    $btnRefresh     = & $find 'BtnRefresh'
    $btnRestart     = & $find 'BtnRestart'
    $btnCollect     = & $find 'BtnCollect'
    $btnChooseDump  = & $find 'BtnChooseDumpFolder'
    $dumpDestHint   = & $find 'DumpDestHint'
    $btnSeal        = & $find 'BtnSeal'
    $btnShutdown    = & $find 'BtnShutdown'
    $shutdownHint   = & $find 'ShutdownHint'
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
    $collectBanner  = & $find 'CollectBanner'
    $collectProgress = & $find 'CollectProgress'
    $collectStatus  = & $find 'CollectStatus'
    $mainWorkArea   = & $find 'MainWorkArea'
    $sealPage       = & $find 'SealPage'
    $sealStatus     = & $find 'SealStatus'
    $busyOverlay    = & $find 'FbImBusyOverlay'
    $busyText       = & $find 'FbImBusyText'

    # Click handlers resolve names at invoke time. Embed mode used to return from
    # Show-FbImWindow immediately, so these locals vanished and Collect logs
    # threw into an empty catch (no notes, no progress, no error). Keep a script
    # copy for Collect / dump-timer even if the stack frame is gone.
    $script:FbImUi = @{
        BtnCollect       = $btnCollect
        BtnOpenFolder    = $btnOpenFolder
        BtnSaveNotes     = $btnSaveNotes
        ActionMessage    = $actionMessage
        NotesPanel       = $notesPanel
        NotesBox         = $notesBox
        CollectBanner    = $collectBanner
        CollectProgress  = $collectProgress
        CollectStatus    = $collectStatus
        BusyOverlay      = $busyOverlay
        DumpDestHint     = $dumpDestHint
    }

    if ($statusIdentity) {
        $idBits = New-Object System.Collections.Generic.List[string]
        if ($subtitle) { [void]$idBits.Add([string]$subtitle) }
        if ($FbBuild.Dev) { [void]$idBits.Add('DEV') }
        $statusIdentity.Text = [string]::Join('  ', @($idBits))
    }

    $script:FbImFitRoot = {
        $sv = $script:FbImScroller
        $root = $script:FbImRootEl
        if (-not $sv -or -not $root) { return }
        try {
            $vh = [double]$sv.ViewportHeight
            if ($vh -lt 1) { $vh = [double]$sv.ActualHeight }
            $m = $root.Margin
            $need = $vh - [double]$m.Top - [double]$m.Bottom
            if ($need -gt 80) { $root.MinHeight = $need }
        } catch {}
    }
    $script:FbImScroller = $scroller
    $script:FbImRootEl = $uiRoot
    if ($scroller) {
        $scroller.Add_SizeChanged({
            try { if ($script:FbImFitRoot) { & $script:FbImFitRoot } } catch {}
        })
        $scroller.Add_Loaded({
            try { if ($script:FbImFitRoot) { & $script:FbImFitRoot } } catch {}
        })
        $scroller.Add_PreviewMouseWheel({
            $e = $null
            try { $e = $args[1] } catch {}
            if (-not $e) { return }
            try {
                $walk = $e.OriginalSource
                $tb = $null
                try { if ($script:FbImUi) { $tb = $script:FbImUi.NotesBox } } catch {}
                while ($walk) {
                    if ($tb -and [object]::ReferenceEquals($walk, $tb)) { return }
                    $parent = $null
                    try { $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($walk) } catch {}
                    if (-not $parent) { try { $parent = $walk.Parent } catch {} }
                    $walk = $parent
                }
                $scroller.ScrollToVerticalOffset($scroller.VerticalOffset - [double]$e.Delta)
                $e.Handled = $true
            } catch {}
        })
        try { if ($script:FbImFitRoot) { & $script:FbImFitRoot } } catch {}
    }

    # Reparent after FindName so the Window namescope still resolves controls.
    if ($EmbedHost) {
        try {
            $window.Content = $null
            $EmbedHost.Children.Clear()
            $toHost = $scroller
            if (-not $toHost) { $toHost = $uiRoot }
            [void]$EmbedHost.Children.Add($toHost)
            try { if ($script:FbImFitRoot) { & $script:FbImFitRoot } } catch {}
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
        if ($busyOverlay) {
            $busyOverlay.IsHitTestVisible = $true
            $busyOverlay.Visibility = 'Visible'
        }
        try { $dispatcher.Invoke([Action]{}, 'Background') } catch {}
    }
    $hideFbImBusy = {
        if ($busyOverlay) {
            $busyOverlay.Visibility = 'Collapsed'
            $busyOverlay.IsHitTestVisible = $false
        }
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
        $ui = $script:FbImUi
        if (-not $ui) { return }
        if ($ui.NotesPanel) { $ui.NotesPanel.Visibility = 'Visible' }
        if ($ui.CollectBanner) { $ui.CollectBanner.Visibility = 'Visible' }
        if ($ui.CollectProgress) { $ui.CollectProgress.Visibility = 'Visible' }
        try { if ($script:FbImFitRoot) { & $script:FbImFitRoot } } catch {}
        try { if ($ui.NotesBox) { [void]$ui.NotesBox.Focus() } } catch {}
        try { $dispatcher.Invoke([Action]{}, 'Background') } catch {}
    }

    $hideNotesPanel = {
        $ui = $script:FbImUi
        if (-not $ui) { return }
        if ($ui.NotesPanel) { $ui.NotesPanel.Visibility = 'Collapsed' }
        if ($ui.CollectBanner) { $ui.CollectBanner.Visibility = 'Collapsed' }
        if ($ui.CollectProgress) { $ui.CollectProgress.Visibility = 'Collapsed' }
        if ($ui.BtnOpenFolder) { $ui.BtnOpenFolder.Visibility = 'Collapsed' }
        if ($ui.BtnSaveNotes) { $ui.BtnSaveNotes.Visibility = 'Collapsed' }
        try { if ($ui.NotesBox) { $ui.NotesBox.Text = '' } } catch {}
    }

    $writeNotesLive = {
        $ui = $script:FbImUi
        if (-not $script:FbImDumpDest) { return }
        $text = ''
        try { if ($ui -and $ui.NotesBox) { $text = [string]$ui.NotesBox.Text } } catch {}
        if ([string]::IsNullOrWhiteSpace($text)) { $text = 'No description provided' }
        Write-FbImIssueMarkdown -DestFolder $script:FbImDumpDest -IssueText $text
    }

    $restartNotesIdleTimer = {
        $t = $script:FbImNotesHideTimer
        try { if ($t) { $t.Stop() } } catch {}
        # Only auto-hide after dump finished (or notes were explicitly saved) and
        # the tech has been idle for 8s - never hide solely because collection ended.
        if (-not $script:FbImNotesIdleArmed) { return }
        try { if ($t) { $t.Start() } } catch {}
    }
    $script:FbImRestartNotesIdleTimer = $restartNotesIdleTimer

    $finishNotesKeepOpen = {
        param([string]$StatusText)
        $ui = $script:FbImUi
        & $writeNotesLive
        if ($ui -and $ui.BtnSaveNotes) { $ui.BtnSaveNotes.Visibility = 'Collapsed' }
        if ($script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
            if ($ui -and $ui.CollectStatus) {
                $ui.CollectStatus.Text = ('Logs saved to {0}' -f $script:FbImDumpDest)
                $ui.CollectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
            }
            if ($ui -and $ui.CollectBanner) { $ui.CollectBanner.Visibility = 'Visible' }
            if ($ui -and $ui.BtnOpenFolder) { $ui.BtnOpenFolder.Visibility = 'Visible' }
            if ($ui -and $ui.ActionMessage) {
                $ui.ActionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF66BB6A')
                if ([string]::IsNullOrWhiteSpace($StatusText)) {
                    $ui.ActionMessage.Text = 'Log collection finished. Keep typing notes - they save live; panel hides after 8s idle.'
                } else {
                    $ui.ActionMessage.Text = $StatusText
                }
            }
        }
        $script:FbImNotesIdleArmed = $true
        if ($script:FbImRestartNotesIdleTimer) { & $script:FbImRestartNotesIdleTimer }
    }

    $script:FbImShowNotesPanel = $showNotesPanel
    $script:FbImWriteNotesLive = $writeNotesLive
    $script:FbImFinishNotesKeepOpen = $finishNotesKeepOpen
    $script:FbImHideBusy = $hideFbImBusy

    $notesHideTimer = New-Object System.Windows.Threading.DispatcherTimer
    $notesHideTimer.Interval = [TimeSpan]::FromSeconds(8)
    $script:FbImNotesHideTimer = $notesHideTimer
    $notesHideTimer.Add_Tick({
        try { $script:FbImNotesHideTimer.Stop() } catch {}
        if ($script:FbImWriteNotesLive) { & $script:FbImWriteNotesLive }
        $ui = $script:FbImUi
        if ($ui) {
            if ($ui.NotesPanel) { $ui.NotesPanel.Visibility = 'Collapsed' }
            if ($ui.CollectBanner) { $ui.CollectBanner.Visibility = 'Collapsed' }
            if ($ui.CollectProgress) { $ui.CollectProgress.Visibility = 'Collapsed' }
            if ($ui.BtnOpenFolder) { $ui.BtnOpenFolder.Visibility = 'Collapsed' }
            if ($ui.BtnSaveNotes) { $ui.BtnSaveNotes.Visibility = 'Collapsed' }
            try { if ($ui.NotesBox) { $ui.NotesBox.Text = '' } } catch {}
        }
        $script:FbImNotesIdleArmed = $false
    })

    if ($notesBox) {
        $notesBox.Add_TextChanged({
            $ui = $script:FbImUi
            if (-not $ui -or -not $ui.NotesPanel) { return }
            if ($ui.NotesPanel.Visibility -ne 'Visible') { return }
            if (-not $script:FbImDumpDest) { return }
            if ($script:FbImWriteNotesLive) { & $script:FbImWriteNotesLive }
            if ($script:FbImNotesIdleArmed -and $script:FbImRestartNotesIdleTimer) {
                & $script:FbImRestartNotesIdleTimer
            }
        })
    }

    $applyStatus = {
        param($st)
        if (-not $st) { return }
        $bc = [System.Windows.Media.BrushConverter]::new()
        $statusHeadline.Text = $st.Headline
        $lampBrush = '#FFEF5350'
        $headBrush = '#FFEF5350'
        $heroBg = '#FF1A0A0A'
        $heroBd = '#FFC62828'
        if ($st.Ready) {
            $lampBrush = '#FF66BB6A'
            $headBrush = '#FF66BB6A'
            $heroBg = '#FF0A1F12'
            $heroBd = '#FF2E7D32'
        } elseif ($st.Sealed) {
            $lampBrush = '#FFFFB74D'
            $headBrush = '#FFFFB74D'
            $heroBg = '#FF1A1408'
            $heroBd = '#FFF57C00'
        }
        $statusLabel.Text = 'Device'
        $statusHeadline.Foreground = $bc.ConvertFromString($headBrush)
        if ($statusHero) {
            $statusHero.BorderBrush = $bc.ConvertFromString($heroBd)
            $statusHero.Background = $bc.ConvertFromString($heroBg)
        }
        if ($statusLamp) {
            $statusLamp.Fill = $bc.ConvertFromString($lampBrush)
            $statusLamp.Stroke = $bc.ConvertFromString($heroBd)
        }
        if ($statusSealChip -and $statusSealChipBorder) {
            if ($st.Sealed) {
                $statusSealChip.Text = 'SEALED'
                $statusSealChip.Foreground = $bc.ConvertFromString('#FF66BB6A')
                $statusSealChipBorder.Background = $bc.ConvertFromString('#FF0A1F12')
                $statusSealChipBorder.BorderBrush = $bc.ConvertFromString('#FF2E7D32')
            } else {
                $statusSealChip.Text = 'NOT SEALED'
                $statusSealChip.Foreground = $bc.ConvertFromString('#FFEF5350')
                $statusSealChipBorder.Background = $bc.ConvertFromString('#FF1A0A0A')
                $statusSealChipBorder.BorderBrush = $bc.ConvertFromString('#FFC62828')
            }
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
        $showShutdown = $true
        try {
            if ($script:FbImEmbedHosted) {
                $showShutdown = [bool]$st.Sealed
            }
        } catch { $showShutdown = -not [bool]$script:FbImEmbedHosted }
        if ($btnShutdown) {
            $btnShutdown.Visibility = $(if ($showShutdown) { 'Visible' } else { 'Collapsed' })
        }
        if ($shutdownHint) {
            $shutdownHint.Visibility = $(if ($showShutdown) { 'Visible' } else { 'Collapsed' })
            if ($showShutdown -and $script:FbImEmbedHosted) {
                $shutdownHint.Text = 'Device is sealed. Power off when you are done.'
            } elseif ($showShutdown) {
                $shutdownHint.Text = 'Power off this device.'
            }
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
    $script:FbImDumpTimer = $dumpTimer
    $dumpTimer.Add_Tick({
        try {
            if (-not $script:FbImDumpProc) { return }
            $ui = $script:FbImUi
            $collectStatus = $null
            $collectProgress = $null
            $btnCollect = $null
            $btnOpenFolder = $null
            if ($ui) {
                $collectStatus = $ui.CollectStatus
                $collectProgress = $ui.CollectProgress
                $btnCollect = $ui.BtnCollect
                $btnOpenFolder = $ui.BtnOpenFolder
            }
            try {
                $script:FbImDumpProc = Update-FbImDumpHandle -Handle $script:FbImDumpProc
                if ($script:FbImDumpProc -and -not $script:FbImDumpProc.HasExited) {
                    if ($collectStatus) { $collectStatus.Text = 'Gathering logs... You can keep typing notes.' }
                    return
                }
            } catch { return }
            try { $script:FbImDumpTimer.Stop() } catch { try { $dumpTimer.Stop() } catch {} }
            $exitCode = 0
            try { $exitCode = [int]$script:FbImDumpProc.ExitCode } catch {}
            $script:FbImDumpProc = $null
            if ($collectProgress) {
                $collectProgress.IsIndeterminate = $false
                $collectProgress.Value = 100
            }
            if ($script:FbImHideBusy) { & $script:FbImHideBusy } else { $script:FbImBusy = $false }
            if ($btnCollect) { $btnCollect.IsEnabled = $true }
            $summaryPath = $null
            if ($script:FbImDumpDest) { $summaryPath = Join-Path $script:FbImDumpDest 'DUMP-SUMMARY.txt' }
            $copiedCount = 0
            try { $copiedCount = Get-FbImDumpFileCount -DestFolder $script:FbImDumpDest } catch { $copiedCount = 0 }
            if ($script:FbImDumpDest -and (-not $summaryPath -or -not (Test-Path -LiteralPath $summaryPath))) {
                try { $copiedCount = Copy-FbImDumpExtras -DestFolder $script:FbImDumpDest } catch {}
                try { $copiedCount = Get-FbImDumpFileCount -DestFolder $script:FbImDumpDest } catch { $copiedCount = 0 }
            } elseif ($copiedCount -le 0 -and $script:FbImDumpDest) {
                try { $copiedCount = Copy-FbImDumpExtras -DestFolder $script:FbImDumpDest } catch { $copiedCount = 0 }
                if ($copiedCount -le 0) {
                    try { $copiedCount = Get-FbImDumpFileCount -DestFolder $script:FbImDumpDest } catch { $copiedCount = 0 }
                }
            }
            # Dump finished mid-edit is common — keep the notes panel open and only
            # auto-hide after 8s of inactivity. Live MD writes happen on keystrokes.
            if ($copiedCount -le 0) {
                $failMsg = 'Dump copied 0 files. Collection failed.'
                if ($script:FbImFinishNotesKeepOpen) { & $script:FbImFinishNotesKeepOpen $failMsg }
                if ($collectStatus) {
                    $collectStatus.Text = $failMsg
                    $collectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                }
                try {
                    if (Get-Command Set-FbSplashTechStatus -ErrorAction SilentlyContinue) {
                        Set-FbSplashTechStatus $failMsg '#FFEF5350'
                    }
                } catch {}
                if ($script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
                    $btnOpenFolder.Visibility = 'Visible'
                }
            } elseif ($exitCode -eq 0 -and $script:FbImDumpDest -and (Test-Path -LiteralPath $script:FbImDumpDest)) {
                if ($script:FbImFinishNotesKeepOpen) {
                    & $script:FbImFinishNotesKeepOpen 'Log collection finished. Keep typing notes - they save live; panel hides after 8s idle.'
                }
            } else {
                if ($script:FbImFinishNotesKeepOpen) {
                    & $script:FbImFinishNotesKeepOpen 'Log collection finished with problems. Notes still save live; panel hides after 8s idle.'
                }
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
            $ui = $script:FbImUi
            $actionMessage = $null
            $btnCollectUi = $null
            $collectProgress = $null
            $collectStatus = $null
            $busyOverlay = $null
            $notesBox = $null
            if ($ui) {
                $actionMessage = $ui.ActionMessage
                $btnCollectUi = $ui.BtnCollect
                $collectProgress = $ui.CollectProgress
                $collectStatus = $ui.CollectStatus
                $busyOverlay = $ui.BusyOverlay
                $notesBox = $ui.NotesBox
            }
            $setMsg = {
                param($Text, $Color)
                if (-not $actionMessage) { return }
                try {
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
                    $actionMessage.Text = $Text
                } catch {}
            }
            # Immediate UI - never a silent no-op, even if dump dest is missing.
            if ($script:FbImShowNotesPanel) { & $script:FbImShowNotesPanel }
            if ($collectProgress) {
                $collectProgress.Visibility = 'Visible'
                $collectProgress.IsIndeterminate = $true
            }
            if ($collectStatus) {
                try {
                    $collectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF6B8CB0')
                    $collectStatus.Text = 'Collecting logs... You can type notes below.'
                } catch {}
            }
            & $setMsg 'Collecting logs. Type notes below.' '#FF22D3EE'

            if ($script:FbImBusy) {
                & $setMsg 'Wait - another action is still running.' '#FFFFB74D'
                return
            }

            $dump = Find-FbDumpScript
            if (-not $dump) {
                & $setMsg 'Log collector (fb-dump) was not found on this device.' '#FFEF5350'
                if ($collectStatus) { $collectStatus.Text = 'fb-dump was not found on this device.' }
                return
            }
            $script:FbImDumpDest = Get-FbImDumpDestFolder
            if (-not $script:FbImDumpDest) {
                & $setMsg 'Plug in a USB stick, or choose an export folder, then Collect logs again.' '#FFFFB74D'
                if (-not (Show-FbImDumpFolderPicker)) { return }
                $script:FbImDumpDest = Get-FbImDumpDestFolder
                if (-not $script:FbImDumpDest) { return }
                & $setMsg 'Collecting logs. Type notes below.' '#FF22D3EE'
            }
            try {
                if (-not (Test-Path -LiteralPath $script:FbImDumpDest)) {
                    New-Item -ItemType Directory -Path $script:FbImDumpDest -Force -ErrorAction Stop | Out-Null
                }
            } catch {
                & $setMsg 'Could not create the log folder. Choose another export folder or insert a USB stick.' '#FFEF5350'
                return
            }

            try { [void](Copy-FbImOnDeviceLogs -DestFolder $script:FbImDumpDest) } catch {}

            # Keep the notes panel interactive during dump - busy flag only (no full-screen overlay).
            $script:FbImBusy = $true
            $script:FbImNotesIdleArmed = $false
            if ($btnCollectUi) { $btnCollectUi.IsEnabled = $false }
            if ($ui -and $ui.BtnOpenFolder) { $ui.BtnOpenFolder.Visibility = 'Collapsed' }
            if ($ui -and $ui.BtnSaveNotes) { $ui.BtnSaveNotes.Visibility = 'Collapsed' }
            try { if ($script:FbImNotesHideTimer) { $script:FbImNotesHideTimer.Stop() } } catch {}
            if ($script:FbImWriteNotesLive) { & $script:FbImWriteNotesLive }
            if ($collectStatus) {
                $collectStatus.Text = 'Gathering logs... You can keep typing notes.'
            }

            try {
                $script:FbImDumpProc = Start-FbImDumpProcess -DumpScript $dump -DestFolder $script:FbImDumpDest
                if ($script:FbImDumpTimer) { $script:FbImDumpTimer.Start() }
                try { if ($notesBox) { [void]$notesBox.Focus() } } catch {}
            } catch {
                $script:FbImBusy = $false
                if ($busyOverlay) {
                    $busyOverlay.Visibility = 'Collapsed'
                    try { $busyOverlay.IsHitTestVisible = $false } catch {}
                }
                if ($btnCollectUi) { $btnCollectUi.IsEnabled = $true }
                $fallbackCount = 0
                try { $fallbackCount = Copy-FbImDumpExtras -DestFolder $script:FbImDumpDest } catch { $fallbackCount = 0 }
                if ($fallbackCount -le 0) {
                    try { $fallbackCount = Get-FbImDumpFileCount -DestFolder $script:FbImDumpDest } catch { $fallbackCount = 0 }
                }
                if ($fallbackCount -gt 0) {
                    & $setMsg 'Dump helper did not start; on-device logs were still copied to the export folder.' '#FFFFB74D'
                    if ($ui -and $ui.BtnOpenFolder) { $ui.BtnOpenFolder.Visibility = 'Visible' }
                    if ($script:FbImFinishNotesKeepOpen) {
                        & $script:FbImFinishNotesKeepOpen 'On-device logs were copied. Keep typing notes if needed.'
                    }
                } else {
                    & $setMsg ('Could not start log collection: {0}' -f $_.Exception.Message) '#FFEF5350'
                    if ($collectStatus) { $collectStatus.Text = 'Could not start log collection.' }
                }
            }
        } catch {
            try {
                $script:FbImBusy = $false
                $ui2 = $script:FbImUi
                if ($ui2 -and $ui2.BtnCollect) { $ui2.BtnCollect.IsEnabled = $true }
                if ($ui2 -and $ui2.ActionMessage) {
                    $ui2.ActionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $ui2.ActionMessage.Text = ('Collect logs failed: {0}' -f $_.Exception.Message)
                }
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
            & $script:FbImFinishNotesKeepOpen 'Notes saved. Keep typing if needed - panel hides after 8s idle.'
        } catch {
            try {
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                $actionMessage.Text = ('Save notes failed: {0}' -f $_.Exception.Message)
            } catch {}
        }
    })
    }

    if ($btnShutdown) {
        $btnShutdown.Add_Click({
            try {
                if ($script:FbImBusy) { return }
                if ($script:FbImEmbedHosted -and -not (Test-Path -LiteralPath $SealedMarker)) { return }
                & $showFbImBusy 'Please wait - shutting down...'
                $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22D3EE')
                $actionMessage.Text = 'Please wait - shutting down...'
                $r = Invoke-FbImImmediateShutdown
                if (-not $r.Ok) {
                    & $hideFbImBusy
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Shutdown did not start. {0}' -f $r.Message)
                }
            } catch {
                try {
                    & $hideFbImBusy
                    $actionMessage.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFEF5350')
                    $actionMessage.Text = ('Shutdown failed: {0}' -f $_.Exception.Message)
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
            } finally {
                try {
                    if ($script:FbImEmbedFrame) { $script:FbImEmbedFrame.Continue = $false }
                } catch {}
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
        try { & $startUi } catch {
            try { Write-Host ("fb-im embed start failed: {0}" -f $_.Exception.Message) } catch {}
        }
        # Nested dispatcher frame keeps this function on the stack so other Click
        # handlers (Restart, Seal, Check again) can still see their locals - the
        # same reason Collect used to be a silent no-op after an immediate return.
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $script:FbImEmbedFrame = $frame
        try {
            [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        } finally {
            $script:FbImEmbedFrame = $null
        }
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
