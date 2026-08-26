# FirstBase - OOBE overlay (2218 + 2226): one-shot after firmware reboot - open a Settings
# URI once (default ms-settings:sound), wait for the Settings host to exit, run
# FirstBaseOobeOperatorFinalize.ps1 SYNCHRONOUSLY (2259: blocking WaitForExit 120s so all cleanup
# and startup-item deletion complete before shutdown), then full shutdown via finalize.
# Armed via HKLM RunOnce from Invoke-SysprepToOobe success when FirstBase-Splash-Oobe-Overlay.mode was present.
#
# Wait semantics (Sound UI gone):
#   Primary: **SystemSettings.exe** - we proceed once it has been observed running
#   (Settings opened for the configured ms-settings URI) and is **no longer** running (user closed
#   Sound / Settings). **WindowsPackageManagerServer** (Winget/App Installer) is
#   intentionally NOT part of the completion gate; it can outlive Settings and would
#   deadlock shutdown if we waited for it. We only poll WPM for optional short
#   diagnostics (never blocks completion). If **only** WPM appears (no SystemSettings) for
#   120s, we proceed anyway (optional cap).
#
# URI launch: ``cmd.exe /c start "" "<ms-settings URI>"`` (default ``ms-settings:sound``; top-of-script ``$FbMsSettingsUri``).
# For Internal Use Only.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$FbRoot = 'C:\Windows\Setup\FirstBase'
$FbLogDir = Join-Path $FbRoot 'Logs'
$FbPdFirstBase = 'C:\ProgramData\FirstBase'

# 2271 (fb-dump-final-1423): User-context guard at DeferredOobeSound entry — defense-in-depth
# against the case where the bootstrap's 2270 guard is bypassed.
# Root cause confirmed from dump: Winlogon\Userinit fires the bootstrap BEFORE $env:USERNAME is
# populated (early logon, user environment not yet loaded). The bootstrap's 2270 guard includes
# [string]::IsNullOrWhiteSpace($env:USERNAME) as a "OOBE session" pass-through, which fires for
# the uninitialized env → bootstrap treats it as a safe session → falls through arm-marker check →
# arm markers present → stale bootstrap lock cleared → DeferredOobeSound spawned for real user.
# By the time DeferredOobeSound runs (seconds after spawn), $env:USERNAME IS populated ("Test").
# Evidence: .pipeline-completed in dump has timestamp 14:09:36 (PID 1976 = Test's session 2
# DeferredOobeSound), not the expected 12:34 OOBE timestamp. Bootstrap log has NO Test entry
# (log write failed silently at early Userinit time before user profile was accessible).
# Fix: check the actual username HERE, in DeferredOobeSound itself, BEFORE ANY I/O (including
# the 2295 .oobe-sound-delivery-started early write). If not an OOBE/system user, perform full disarm
# and exit 0 — Settings is NEVER opened, no shutdown issued.
$fb2271DosUser = $env:USERNAME
$fb2271DosIsOobeSession = ($fb2271DosUser -eq 'defaultuser0') -or ($fb2271DosUser -eq 'SYSTEM') -or ($fb2271DosUser -eq 'Administrator') -or ([string]::IsNullOrWhiteSpace($fb2271DosUser))
if (-not $fb2271DosIsOobeSession) {
    $fb2271DosTs = Get-Date -Format 'o'
    $fb2271DosLine = ('[{0}] [WARN] [runId=deferred-oobe-sound] 2271: ABORT — DeferredOobeSound fired for real user [{1}] PID={2}; user-context guard. Sealing and disarming all delivery surfaces. No Settings will open.' -f $fb2271DosTs, $fb2271DosUser, $PID)
    foreach ($fb2271DosMirrorPath in @(
            (Join-Path $FbPdFirstBase 'WU-oobe-sound-handoff-mirror.log'),
            (Join-Path $FbLogDir     'WU-oobe-sound-handoff-mirror.log'))) {
        try {
            $fb2271DosMirrorDir = Split-Path -Parent $fb2271DosMirrorPath
            if (-not (Test-Path -LiteralPath $fb2271DosMirrorDir)) {
                New-Item -ItemType Directory -Path $fb2271DosMirrorDir -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Add-Content -LiteralPath $fb2271DosMirrorPath -Value $fb2271DosLine -Encoding ascii -ErrorAction SilentlyContinue
        } catch {}
    }
    try {
        if (-not (Test-Path -LiteralPath $FbPdFirstBase)) {
            New-Item -ItemType Directory -Path $FbPdFirstBase -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $FbPdFirstBase '.pipeline-completed') -Value ('Emergency-sealed at {0} (DeferredOobeSound PID {1} user [{2}]; 2271 user-context guard)' -f $fb2271DosTs, $PID, $fb2271DosUser) -Encoding UTF8 -Force -ErrorAction SilentlyContinue
        Set-Content -LiteralPath (Join-Path $FbPdFirstBase '.firstbase-sealed')   -Value ('Emergency-sealed at {0} (DeferredOobeSound PID {1} user [{2}]; 2271 user-context guard)' -f $fb2271DosTs, $PID, $fb2271DosUser) -Encoding UTF8 -Force -ErrorAction SilentlyContinue
    } catch {}
    try { Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'    -Name 'OpenWindowsSoundSettingsDeferredLogon' -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'OpenWindowsSoundSettingsDeferredOnce'    -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name '!FirstBaseWuSplash'                      -Force -ErrorAction SilentlyContinue } catch {}
    try {
        $fb2271DosWlKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $fb2271DosUi = (Get-ItemProperty -Path $fb2271DosWlKey -Name Userinit -ErrorAction SilentlyContinue).Userinit
        if ($fb2271DosUi -match 'FirstBase') {
            Set-ItemProperty -Path $fb2271DosWlKey -Name Userinit -Value 'C:\Windows\system32\userinit.exe,' -ErrorAction SilentlyContinue
        }
    } catch {}
    try {
        $fb2271DosStartupCmd = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\FirstBaseOobeSoundAtLogon.vbs'
        if (Test-Path -LiteralPath $fb2271DosStartupCmd) { Remove-Item -LiteralPath $fb2271DosStartupCmd -Force -ErrorAction SilentlyContinue }
    } catch {}
    foreach ($fb2271DosTn in @('FirstBase\DeferredOobeSoundOnLogon', 'FirstBase\SplashWatcher', 'FirstBase\UpdateSplash', 'FirstBase\UpdateSplashLayer4', 'FirstBase\DebugHotkeyWatcher')) {
        try { $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Delete', '/TN', $fb2271DosTn, '/F') -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue; if ($p) { $null = $p.WaitForExit(3000) } } catch {}
    }
    foreach ($fb2271DosMkName in @('.firstbase-specialize-arm-suppressed', '.deferred-oobe-sound-runonce-armed', '.deferred-oobe-sound-onlogon-task-armed', '.deferred-oobe-sound-run-key-armed', '.deferred-oobe-sound-active-setup-armed', '.deferred-oobe-sound-startup-armed', '.deferred-oobe-sound-userinit-armed', '.deferred-oobe-sound-bootstrap.lock')) {
        try { $fp = Join-Path $FbPdFirstBase $fb2271DosMkName; if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue } } catch {}
    }
    foreach ($fb2271DosScrubDir in @('C:\Windows\Setup\FirstBase', $FbPdFirstBase)) {
        if (-not (Test-Path -LiteralPath $fb2271DosScrubDir)) { continue }
        # 2272: Use Where-Object to filter .ps1/.cmd — Get-ChildItem -Include broken in PS 5.1 with -LiteralPath -Recurse.
        foreach ($fb2271DosScriptFile in @(Get-ChildItem -LiteralPath $fb2271DosScrubDir -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.cmd') })) {
            try { Remove-Item -LiteralPath $fb2271DosScriptFile.FullName -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    exit 0
}

# 2295 (Phase 1 E): Write .oobe-sound-delivery-started at the ABSOLUTE FIRST I/O — before
# session lock, version load, entry log, or any other action. Semantics:
#   .oobe-sound-delivery-started = "delivery entered; suppress re-fire" (written HERE)
#   .pipeline-completed           = "operator-done / inline seal complete" (written after Settings close)
#   .firstbase-sealed             = "inline seal ran to completion; device ready to ship"
# Root cause (2269): writing .pipeline-completed here caused 2288 recovery to call finalize while
# Settings was still open — bootstrap treated "Pipeline started" as finalize-ready.
try {
    foreach ($fb2295EarlyDsDir in @($FbPdFirstBase, $FbLogDir)) {
        try {
            if (-not (Test-Path -LiteralPath $fb2295EarlyDsDir)) {
                New-Item -ItemType Directory -Path $fb2295EarlyDsDir -Force -ErrorAction SilentlyContinue | Out-Null
            }
            $fb2295EarlyDsPath = Join-Path $fb2295EarlyDsDir '.oobe-sound-delivery-started'
            Set-Content -LiteralPath $fb2295EarlyDsPath -Value ('Delivery started at {0} (FirstBaseDeferredOobeSound.ps1 PID {1}; re-fire guard; .pipeline-completed written after Settings close)' -f (Get-Date -Format 'o'), $PID) -Encoding UTF8 -Force -ErrorAction SilentlyContinue
        } catch {}
    }
} catch {}

# 2226: default ms-settings URI for OOBE operator handoff (edit this line to test other pages).
[string]$FbDeferredMsSettingsUri = 'ms-settings:sound'
$FlowDonePath = Join-Path $FbPdFirstBase '.oobe-sound-after-updates-flow-completed'
$SessionLockPath = Join-Path $FbPdFirstBase '.deferred-oobe-sound-session.lock'
$RunOnceRk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$RunOnceName = 'OpenWindowsSoundSettingsDeferredOnce'
$FinalizePs1 = (Join-Path $FbRoot 'FirstBaseOobeOperatorFinalize.ps1')
$FinalizePs1Pd = (Join-Path $FbPdFirstBase 'FirstBaseOobeOperatorFinalize.ps1')
$DeferredArmMarker = Join-Path $FbPdFirstBase '.deferred-oobe-sound-runonce-armed'
$DeferredOnLogonArmMarker = Join-Path $FbPdFirstBase '.deferred-oobe-sound-onlogon-task-armed'
$MaxProcWaitSec = 3600
$PollMs = 2000
$ExplorerWaitSec = 300
$SettingsLaunchRetries = 5
$SettingsLaunchRetryDelaySec = 5

function Get-FbDeferredOobeSoundScriptLeaf {
    try {
        if ($MyInvocation.MyCommand.Path) { return (Split-Path -Leaf $MyInvocation.MyCommand.Path) }
    } catch {}
    return 'FirstBaseDeferredOobeSound.ps1'
}

$fbVerPs1 = Join-Path $FbRoot 'FirstBaseVersion.ps1'
if (-not (Test-Path -LiteralPath $fbVerPs1)) {
    $fbVerPs1 = Join-Path $PSScriptRoot 'FirstBaseVersion.ps1'
}
if (Test-Path -LiteralPath $fbVerPs1) {
    . $fbVerPs1
} else {
    $FirstBaseProductVersion  = '1.0.0'
    $FirstBasePayloadRevision = 'unknown'
    $FirstBaseScriptVersion   = @{}
}
$thisLeaf = Get-FbDeferredOobeSoundScriptLeaf
$script:ThisScriptVersion = [string]$FirstBaseScriptVersion[$thisLeaf]
if ([string]::IsNullOrWhiteSpace($script:ThisScriptVersion)) { $script:ThisScriptVersion = $FirstBaseProductVersion }

function Write-FbDeferredOobeSoundWuMirrorLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = ('[{0}] [{1}] [runId=deferred-oobe-sound] {2}' -f $ts, $Level, $Message)
    try {
        if (-not (Test-Path -LiteralPath $FbLogDir)) {
            New-Item -ItemType Directory -Path $FbLogDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
    # 2223: Always append mirror first so a failing WU-*.log probe cannot swallow all diagnostics (fb-dump-final-1419 had no mirror).
    try {
        $mirror = Join-Path $FbLogDir 'WU-oobe-sound-handoff-mirror.log'
        Add-Content -LiteralPath $mirror -Value $line -Encoding ascii -ErrorAction SilentlyContinue
    } catch {}
    # 2260: Also write to ProgramData — C:\Windows\Setup\FirstBase\Logs\ is not writable by defaultuser0 in OOBE
    # (dump fb-dump-final-924: no handoff mirror log despite session lock being created; ProgramData writable).
    try {
        $pdMirror = Join-Path $FbPdFirstBase 'WU-oobe-sound-handoff-mirror.log'
        Add-Content -LiteralPath $pdMirror -Value $line -Encoding ascii -ErrorAction SilentlyContinue
    } catch {}
    try {
        $latest = Get-ChildItem -LiteralPath $FbLogDir -Filter 'WU-*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) {
            Add-Content -LiteralPath $latest.FullName -Value $line -Encoding ascii -ErrorAction SilentlyContinue
        }
    } catch {}
    try {
        $scLog = Join-Path $FbLogDir 'SetupComplete.log'
        if (Test-Path -LiteralPath $scLog) {
            Add-Content -LiteralPath $scLog -Value ("[2218-deferred-sound] {0}" -f $line) -Encoding ascii -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Test-FbDeferredOobeSoundAlreadyRunning {
    try {
        $mine = $PID
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue
        foreach ($p in @($procs)) {
            if (-not $p) { continue }
            try {
                if ([int]$p.ProcessId -eq $mine) { continue }
                $cl = [string]$p.CommandLine
                if ($cl -like '*FirstBaseDeferredOobeSound.ps1*') { return $true }
            } catch {}
        }
    } catch {}
    return $false
}

function Remove-FbDeferredOobeSoundRunOnceValue {
    try {
        Remove-ItemProperty -LiteralPath $RunOnceRk -Name $RunOnceName -Force -ErrorAction SilentlyContinue
        Write-FbDeferredOobeSoundWuMirrorLog "2218: removed HKLM RunOnce\$RunOnceName (defensive cleanup)." 'INFO'
    } catch {}
}

function Wait-FbDeferredOobeSoundInteractiveShell {
    $deadline = (Get-Date).AddSeconds($ExplorerWaitSec)
    do {
        try {
            $ex = Get-Process -Name 'explorer' -ErrorAction SilentlyContinue |
                Where-Object { $_.SessionId -ge 1 }
            if (@($ex).Count -gt 0) {
                Write-FbDeferredOobeSoundWuMirrorLog ("2227: interactive explorer.exe present (session>=1, count={0})." -f @($ex).Count) 'INFO'
                return $true
            }
        } catch {}
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    Write-FbDeferredOobeSoundWuMirrorLog ("2227: explorer wait TIMEOUT ({0}s); proceeding anyway." -f $ExplorerWaitSec) 'WARN'
    return $false
}

function Test-FbDeferredOobeSoundDeliveryArmed {
    try {
        if (Test-Path -LiteralPath $DeferredArmMarker) { return $true }
        if (Test-Path -LiteralPath $DeferredOnLogonArmMarker) { return $true }
        $runKeyMarker = Join-Path $FbPdFirstBase '.deferred-oobe-sound-run-key-armed'
        if (Test-Path -LiteralPath $runKeyMarker) { return $true }
        $activeSetupMarker = Join-Path $FbPdFirstBase '.deferred-oobe-sound-active-setup-armed'
        if (Test-Path -LiteralPath $activeSetupMarker) { return $true }
        $startupMarker = Join-Path $FbPdFirstBase '.deferred-oobe-sound-startup-armed'
        if (Test-Path -LiteralPath $startupMarker) { return $true }
        # 2270: userinit-armed added — see FirstBaseOobeDeferredSoundBootstrap.ps1 2270 comment.
        $userInitMarker = Join-Path $FbPdFirstBase '.deferred-oobe-sound-userinit-armed'
        if (Test-Path -LiteralPath $userInitMarker) { return $true }
    } catch {}
    return $false
}

function Get-FbDeferredOobeSoundFinalizeScriptPath {
    if (Test-Path -LiteralPath $FinalizePs1Pd) { return $FinalizePs1Pd }
    if (Test-Path -LiteralPath $FinalizePs1) { return $FinalizePs1 }
    return $FinalizePs1
}

function Start-FbDeferredOobeSoundSettingsUri {
    param([int]$Attempt = 1)
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    if (-not (Test-Path -LiteralPath $cmdExe)) { $cmdExe = 'cmd.exe' }
    $explorerExe = Join-Path $env:SystemRoot 'explorer.exe'
  # 2231: alternate launch paths — OOBE defaultuser0 often ignores HKLM RunOnce but responds to shell URI.
    if ($Attempt -eq 1) {
        Write-FbDeferredOobeSoundWuMirrorLog ("2231: launching '{0}' via cmd.exe /c start attempt={1}/{2}" -f $FbDeferredMsSettingsUri, $Attempt, $SettingsLaunchRetries) 'INFO'
        try {
            Start-Process -FilePath $cmdExe -ArgumentList @('/c', 'start', '""', $FbDeferredMsSettingsUri) -WindowStyle Normal -ErrorAction Stop
            return $true
        } catch {
            Write-FbDeferredOobeSoundWuMirrorLog ("2231: cmd.exe start attempt {0} threw: {1}" -f $Attempt, $_.Exception.Message) 'WARN'
        }
    } elseif ($Attempt -eq 2 -and (Test-Path -LiteralPath $explorerExe)) {
        Write-FbDeferredOobeSoundWuMirrorLog ("2231: launching '{0}' via explorer.exe attempt={1}/{2}" -f $FbDeferredMsSettingsUri, $Attempt, $SettingsLaunchRetries) 'INFO'
        try {
            Start-Process -FilePath $explorerExe -ArgumentList $FbDeferredMsSettingsUri -WindowStyle Normal -ErrorAction Stop
            return $true
        } catch {
            Write-FbDeferredOobeSoundWuMirrorLog ("2231: explorer.exe URI attempt {0} threw: {1}" -f $Attempt, $_.Exception.Message) 'WARN'
        }
    } else {
        Write-FbDeferredOobeSoundWuMirrorLog ("2231: launching '{0}' via Start-Process ms-settings attempt={1}/{2}" -f $FbDeferredMsSettingsUri, $Attempt, $SettingsLaunchRetries) 'INFO'
        try {
            Start-Process -FilePath $FbDeferredMsSettingsUri -WindowStyle Normal -ErrorAction Stop
            return $true
        } catch {
            Write-FbDeferredOobeSoundWuMirrorLog ("2231: Start-Process URI attempt {0} threw: {1}" -f $Attempt, $_.Exception.Message) 'WARN'
        }
    }
    return $false
}

function Write-FbDeferredOobeSoundRunOncePeersDiag {
    try {
        $rk = $RunOnceRk
        $p = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
        $names = @()
        if ($p) {
            foreach ($prop in $p.PSObject.Properties) {
                if ($prop.Name -notmatch '^PS' -and $prop.Name -like 'OpenWindows*') {
                    $names += [string]$prop.Name
                }
            }
        }
        $sorted = ($names | Sort-Object -Unique)
        $joined = if ($sorted.Count -gt 0) { ($sorted -join ', ') } else { '(none)' }
        Write-FbDeferredOobeSoundWuMirrorLog ("2218: 2224 RunOnce OpenWindows* names visible now: {0}" -f $joined) 'INFO'
    } catch {}
}

$fbDeferredEntrySessionId = -1
try { $fbDeferredEntrySessionId = [int][System.Diagnostics.Process]::GetCurrentProcess().SessionId } catch {}
$fbDeferredRunKeyMarkerPath = Join-Path $FbPdFirstBase '.deferred-oobe-sound-run-key-armed'
Write-FbDeferredOobeSoundWuMirrorLog ("2235: entry (payload={0} script={1} path={2} user={3} session={4} deliveryArmed={5} runonceMarker={6} onLogonMarker={7} runKeyMarker={8})" -f $FirstBasePayloadRevision, $script:ThisScriptVersion, $MyInvocation.MyCommand.Path, $env:USERNAME, $fbDeferredEntrySessionId, (Test-FbDeferredOobeSoundDeliveryArmed), (Test-Path -LiteralPath $DeferredArmMarker), (Test-Path -LiteralPath $DeferredOnLogonArmMarker), (Test-Path -LiteralPath $fbDeferredRunKeyMarkerPath)) 'INFO'

if (Test-Path -LiteralPath $FlowDonePath) {
    Write-FbDeferredOobeSoundWuMirrorLog '2218: flow already completed (.oobe-sound-after-updates-flow-completed); exiting 0.' 'INFO'
    Remove-FbDeferredOobeSoundRunOnceValue
    exit 0
}

if (-not (Test-FbDeferredOobeSoundDeliveryArmed)) {
    Write-FbDeferredOobeSoundWuMirrorLog '2229: deferred delivery markers absent (runonce-armed and onlogon-task-armed); exiting 0 (stale trigger or already finalized).' 'INFO'
    Remove-FbDeferredOobeSoundRunOnceValue
    exit 0
}

if (Test-FbDeferredOobeSoundAlreadyRunning) {
    $roDup = $null
    try { $roDup = (Get-ItemProperty -LiteralPath $RunOnceRk -Name $RunOnceName -ErrorAction SilentlyContinue).$RunOnceName } catch {}
    $roNote = if ($null -ne $roDup -and -not [string]::IsNullOrWhiteSpace([string]$roDup)) {
        ' RunOnce OpenWindowsSoundSettingsDeferredOnce is still present (another instance may consume it on next logon).'
    } else {
        ' RunOnce OpenWindowsSoundSettingsDeferredOnce absent (likely already consumed or never armed).'
    }
    Write-FbDeferredOobeSoundWuMirrorLog ("2218: another FirstBaseDeferredOobeSound.ps1 instance is already running; exiting 0.{0}" -f $roNote) 'INFO'
    exit 0
}

function Remove-FbDeferredOobeSoundSessionLockIfStale {
    try {
        if (-not (Test-Path -LiteralPath $SessionLockPath)) { return $false }
        $txt = [string](Get-Content -LiteralPath $SessionLockPath -Raw -ErrorAction SilentlyContinue)
        if ([string]::IsNullOrWhiteSpace($txt)) {
            Remove-Item -LiteralPath $SessionLockPath -Force -ErrorAction SilentlyContinue
            return $true
        }
        if ($txt -match 'pid=(\d+)') {
            $otherPid = 0
            if ([int]::TryParse($Matches[1], [ref]$otherPid) -and $otherPid -gt 0 -and $otherPid -ne $PID) {
                $alive = $false
                try { $alive = $null -ne (Get-Process -Id $otherPid -ErrorAction SilentlyContinue) } catch { $alive = $false }
                if (-not $alive) {
                    Remove-Item -LiteralPath $SessionLockPath -Force -ErrorAction SilentlyContinue
                    return $true
                }
                # NOTE (fb-dump-final-1134): PID reuse guard. Windows reuses PIDs; after ~1h the original
                # DeferredOobeSound PID may belong to a completely unrelated process. Get-Process reports it
                # as "alive", causing a false-negative stale check that leaves the lock in place and blocks
                # real-user delivery. Verify via Win32_Process.CommandLine that the live process is
                # actually FirstBaseDeferredOobeSound.ps1. If the CommandLine does not match, the PID was
                # reused and the lock must be cleared.
                $isTrueDeferred = $false
                try {
                    $liveCim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $otherPid" -ErrorAction SilentlyContinue
                    if ($liveCim -and ([string]$liveCim.CommandLine -match 'FirstBaseDeferredOobeSound\.ps1')) {
                        $isTrueDeferred = $true
                    }
                } catch {}
                if (-not $isTrueDeferred) {
                    Remove-Item -LiteralPath $SessionLockPath -Force -ErrorAction SilentlyContinue
                    return $true
                }
            }
        }
    } catch {}
    return $false
}

try {
    if (-not (Test-Path -LiteralPath $FbPdFirstBase)) {
        New-Item -ItemType Directory -Path $FbPdFirstBase -Force -ErrorAction Stop | Out-Null
    }
    $lockOk = $false
    for ($lockAttempt = 0; $lockAttempt -lt 2; $lockAttempt++) {
        try {
            $fs = [System.IO.File]::Open($SessionLockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $sw = New-Object System.IO.StreamWriter($fs)
            $sw.WriteLine(('pid={0} utc={1}' -f $PID, ([DateTimeOffset]::UtcNow.ToString('o'))))
            $sw.Flush()
            $fs.Flush()
            $sw.Dispose()
            $fs.Dispose()
            $lockOk = $true
            break
        } catch {
            if ($lockAttempt -eq 0 -and (Remove-FbDeferredOobeSoundSessionLockIfStale)) { continue }
            throw
        }
    }
    if (-not $lockOk) { throw (New-Object System.InvalidOperationException('session lock')) }
} catch {
    Write-FbDeferredOobeSoundWuMirrorLog '2218: session lock already held or lock create failed; exiting 0.' 'INFO'
    exit 0
}

try {
    Write-FbDeferredOobeSoundRunOncePeersDiag
    Write-FbDeferredOobeSoundWuMirrorLog ("2218: deferred Sound handoff starting (payload={0} script={1})" -f $FirstBasePayloadRevision, $script:ThisScriptVersion) 'INFO'
    Wait-FbDeferredOobeSoundInteractiveShell | Out-Null

    try {
        Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'OpenWindowsSoundSettingsOnce' -Force -ErrorAction SilentlyContinue
    } catch {}
    try {
        $m2216 = Join-Path $FbPdFirstBase '.sound-settings-runonce-armed'
        if (Test-Path -LiteralPath $m2216) { Remove-Item -LiteralPath $m2216 -Force -ErrorAction SilentlyContinue }
    } catch {}

    $launchOk = $false
    for ($li = 1; $li -le $SettingsLaunchRetries; $li++) {
        if (Start-FbDeferredOobeSoundSettingsUri -Attempt $li) {
            $launchOk = $true
            Start-Sleep -Seconds 2
            try {
                $ssProbe = @(Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue)
                if ($ssProbe.Count -gt 0) { break }
            } catch {}
        }
        if ($li -lt $SettingsLaunchRetries) {
            Start-Sleep -Seconds $SettingsLaunchRetryDelaySec
        }
    }
    if (-not $launchOk) {
        Write-FbDeferredOobeSoundWuMirrorLog ("2229: all {0} settings URI launch attempts failed; continuing to process wait." -f $SettingsLaunchRetries) 'WARN'
    }

    Write-FbDeferredOobeSoundWuMirrorLog '2218: Settings process wait start (primary: SystemSettings only; WPM optional 120s cap if no SystemSettings).' 'INFO'
    $procDeadline = (Get-Date).AddSeconds($MaxProcWaitSec)
    $seenSystemSettings = $false
    $wpmOptionalDeadline = [DateTime]::MinValue
    do {
        $sysAlive = @()
        try {
            $sysAlive = @(Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue)
        } catch {}
        if ($sysAlive.Count -gt 0) { $seenSystemSettings = $true }

        if (-not $seenSystemSettings) {
            try {
                $wpmAlive = @(Get-Process -Name 'WindowsPackageManagerServer' -ErrorAction SilentlyContinue)
                if ($wpmAlive.Count -gt 0 -and $sysAlive.Count -eq 0) {
                    if ($wpmOptionalDeadline -eq [DateTime]::MinValue) {
                        $wpmOptionalDeadline = (Get-Date).AddSeconds(120)
                    }
                } else {
                    $wpmOptionalDeadline = [DateTime]::MinValue
                }
            } catch {}
        }

        if ($seenSystemSettings -and $sysAlive.Count -eq 0) {
            try {
                $wpmLeft = @(Get-Process -Name 'WindowsPackageManagerServer' -ErrorAction SilentlyContinue)
                if ($wpmLeft.Count -gt 0) {
                    Write-FbDeferredOobeSoundWuMirrorLog '2218: SystemSettings exited; WindowsPackageManagerServer still running (ignored for proceed gate).' 'INFO'
                }
            } catch {}
            break
        }
        if (-not $seenSystemSettings -and $wpmOptionalDeadline -ne [DateTime]::MinValue -and (Get-Date) -gt $wpmOptionalDeadline) {
            Write-FbDeferredOobeSoundWuMirrorLog '2218: optional WPM-only cap (120s): SystemSettings never observed; proceeding to shutdown.' 'WARN'
            break
        }
        if (-not $seenSystemSettings -and ((Get-Date) -gt $procDeadline)) {
            Write-FbDeferredOobeSoundWuMirrorLog '2218: SystemSettings wait TIMEOUT (never observed); proceeding to shutdown.' 'WARN'
            break
        }
        if ($seenSystemSettings -and ((Get-Date) -gt $procDeadline)) {
            Write-FbDeferredOobeSoundWuMirrorLog '2218: SystemSettings wait TIMEOUT (still alive); proceeding to shutdown anyway.' 'WARN'
            break
        }
        Start-Sleep -Milliseconds $PollMs
    } while ($true)
    Write-FbDeferredOobeSoundWuMirrorLog '2218: SystemSettings wait end.' 'INFO'

    # 2260: Inline critical seal — all critical markers, startup-item disarms, and the early shutdown are
    # executed directly in DeferredOobeSound's process before spawning finalize as a subprocess.
    # Root cause (dump fb-dump-final-924): OOBE defaultuser0 session terminated (~2 min after DeferredOobeSound
    # started) when operator created account before/during finalize execution; finalize was killed mid-execution
    # leaving .pipeline-completed unwritten, all startup items armed, and splash RunOnce active.
    # Fix: do the entire critical seal here (< 0.5s), issue shutdown /s /t 30 /f immediately so the machine
    # shuts down even if finalize is killed; finalize overrides to /t 0 on success.
    #
    # NOTE (2295): .pipeline-completed is written here at inline seal (operator Settings closed).
    # Delivery re-fire guard uses .oobe-sound-delivery-started (written at script entry).
    # FirstBaseSplashWatcher.ps1 and FirstBaseSplashSingleInstance.ps1 check delivery-started and
    # pipeline-completed at startup and exit immediately if present.
    # Splash process kill is also added INSIDE the inline seal (before shutdown /t 30) so finalize's later
    # file scrub finds the splash .ps1 files UNLOCKED, eliminating deferred-delete races with shutdown.
    try {
        if (-not (Test-Path -LiteralPath $FbPdFirstBase)) {
            New-Item -ItemType Directory -Path $FbPdFirstBase -Force -ErrorAction SilentlyContinue | Out-Null
        }
        # 2295: .pipeline-completed = operator-done; written at inline seal after Settings close.
        $fb2260PipelineMarker = Join-Path $FbPdFirstBase '.pipeline-completed'
        Set-Content -LiteralPath $fb2260PipelineMarker -Value ('Pipeline completed at {0} (FirstBaseDeferredOobeSound.ps1 PID {1})' -f (Get-Date -Format 'o'), $PID) -Encoding UTF8 -Force
    } catch {}
    Write-FbDeferredOobeSoundWuMirrorLog '2261: starting inline critical seal (.pipeline-completed written first).' 'INFO'
    try {
        Write-FbDeferredOobeSoundWuMirrorLog '2260: wrote .pipeline-completed (inline).' 'INFO'
    } catch {}
    try {
        $fb2260SealedMarker = Join-Path $FbPdFirstBase '.firstbase-sealed'
        Set-Content -LiteralPath $fb2260SealedMarker -Value ('Sealed at {0} (DeferredOobeSound PID {1}); device ready for pack/ship.' -f (Get-Date -Format 'o'), $PID) -Encoding UTF8 -Force
        Write-FbDeferredOobeSoundWuMirrorLog '2260: wrote .firstbase-sealed (inline).' 'INFO'
    } catch {
        Write-FbDeferredOobeSoundWuMirrorLog ("2260: WARN .firstbase-sealed write failed (inline): {0}." -f $_.Exception.Message) 'WARN'
    }
    try {
        Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'OpenWindowsSoundSettingsDeferredLogon' -Force -ErrorAction SilentlyContinue
        Write-FbDeferredOobeSoundWuMirrorLog '2260: removed HKLM Run OpenWindowsSoundSettingsDeferredLogon (inline).' 'INFO'
    } catch {}
    try {
        $fb2260RoRk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        Remove-ItemProperty -LiteralPath $fb2260RoRk -Name 'OpenWindowsSoundSettingsDeferredOnce' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $fb2260RoRk -Name '!FirstBaseWuSplash' -Force -ErrorAction SilentlyContinue
        Write-FbDeferredOobeSoundWuMirrorLog '2260: removed HKLM RunOnce Settings + Splash values (inline).' 'INFO'
    } catch {}
    try {
        Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'Userinit' -Value 'C:\Windows\system32\userinit.exe,' -ErrorAction Stop
        Write-FbDeferredOobeSoundWuMirrorLog '2260: restored Winlogon\Userinit (inline).' 'INFO'
    } catch {
        Write-FbDeferredOobeSoundWuMirrorLog ("2260: WARN Userinit restore failed (inline): {0}." -f $_.Exception.Message) 'WARN'
    }
    try {
        $fb2260StartupCmd = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\FirstBaseOobeSoundAtLogon.vbs'
        if (Test-Path -LiteralPath $fb2260StartupCmd) {
            Remove-Item -LiteralPath $fb2260StartupCmd -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $fb2260StartupCmd) {
                Start-Sleep -Milliseconds 800
                Remove-Item -LiteralPath $fb2260StartupCmd -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $fb2260StartupCmd) {
                # 2294: still locked after retry; finalize (called synchronously right after
                # this seal) has its own retry + deferred-delete fallback for this same path.
                Write-FbDeferredOobeSoundWuMirrorLog '2294: Startup vbs still locked after retry; deferring to finalize.' 'WARN'
            } else {
                Write-FbDeferredOobeSoundWuMirrorLog '2260: removed All Users Startup FirstBaseOobeSoundAtLogon.vbs (inline).' 'INFO'
            }
        }
    } catch {
        Write-FbDeferredOobeSoundWuMirrorLog ("2260: WARN Startup cmd remove failed (inline): {0}." -f $_.Exception.Message) 'WARN'
    }
    foreach ($fb2260Marker in @(
        (Join-Path $FbPdFirstBase '.firstbase-specialize-arm-suppressed'),
        (Join-Path $FbPdFirstBase '.deferred-oobe-sound-runonce-armed'),
        (Join-Path $FbPdFirstBase '.deferred-oobe-sound-onlogon-task-armed'),
        (Join-Path $FbPdFirstBase '.deferred-oobe-sound-run-key-armed'),
        (Join-Path $FbPdFirstBase '.deferred-oobe-sound-active-setup-armed'),
        (Join-Path $FbPdFirstBase '.deferred-oobe-sound-startup-armed'),
        (Join-Path $FbPdFirstBase '.deferred-oobe-sound-userinit-armed'))) {
        try {
            if (Test-Path -LiteralPath $fb2260Marker) { Remove-Item -LiteralPath $fb2260Marker -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
    Write-FbDeferredOobeSoundWuMirrorLog '2260: removed delivery arm markers (inline).' 'INFO'
    # NOTE (fb-dump-final-1101): Kill splash-related processes inside the inline seal so that by the time
    # finalize's script scrub runs, FirstBaseSplashSingleInstance.ps1 and FirstBaseSplashWatcher.ps1 are
    # UNLOCKED on disk. The prior 2260 build killed them only inside finalize AFTER the file scrub had
    # already tried to delete them; locked files got deferred to a ping-delay batch that shutdown /t 30
    # killed before it could run, leaving the scripts on disk and armed for real-user login.
    try {
        $fb2261SplashPat = '(?i)Show-UpdateProgress|FirstBaseSplashSingleInstance|FirstBaseSplashWatcher|FirstBaseSplashLauncher|FirstBaseShowSplash'
        $fb2261SplashPids = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and ($_.Name -match '^(powershell|pwsh)\.exe$') -and ($_.CommandLine -match $fb2261SplashPat) } |
            Select-Object -ExpandProperty ProcessId -Unique)
        foreach ($fb2261Spid in $fb2261SplashPids) {
            if ($fb2261Spid -eq $PID) { continue }
            try { Stop-Process -Id ([int]$fb2261Spid) -Force -ErrorAction SilentlyContinue } catch {}
        }
        Write-FbDeferredOobeSoundWuMirrorLog ("2261: killed {0} splash process(es) inline so finalize scrub finds files unlocked." -f $fb2261SplashPids.Count) 'INFO'
    } catch {
        Write-FbDeferredOobeSoundWuMirrorLog ("2261: WARN splash process kill (inline) threw: {0}." -f $_.Exception.Message) 'WARN'
    }
    # Issue shutdown /s /t 30 /f immediately — seals the device after Settings close.
    # Finalize (spawned below) overrides this to /t 0 on success.
    Write-FbDeferredOobeSoundWuMirrorLog '2260: inline seal complete; issuing shutdown /s /t 30 /f (finalize may override to /t 8 /f on success).' 'INFO'
    $fb2260Shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    Start-Process -FilePath $fb2260Shutdown -ArgumentList @('/s', '/t', '30', '/f', '/c', 'FirstBase: pipeline sealed after Settings close.') -WindowStyle Hidden -ErrorAction SilentlyContinue

    # 2259: Write DeferredSound's own completion marker and remove RunOnce BEFORE calling finalize
    # (quick operations; must complete even if finalize is delayed or fails).
    try {
        Set-Content -LiteralPath $FlowDonePath -Value ("completedUtc={0} pid={1}" -f ([DateTimeOffset]::UtcNow.ToString('o')), $PID) -Encoding UTF8 -Force
    } catch {}

    Remove-FbDeferredOobeSoundRunOnceValue

    $finalizePath = Get-FbDeferredOobeSoundFinalizeScriptPath
    if (Test-Path -LiteralPath $finalizePath) {
        # 2259: Call finalize SYNCHRONOUSLY (blocking, WaitForExit 120s) so all cleanup and startup-item
        # deletion run to completion BEFORE any shutdown is issued. The previous detached + /t 10 approach
        # killed finalize mid-execution — PowerShell startup overhead (~3s) left only ~7s of runtime,
        # confirmed by dump: no finalize mirror log, no .pipeline-completed, all arm markers still present.
        # Finalize issues its own shutdown /s /t 0 on success; fallback below covers crashes/timeouts.
        try {
            $fbFinalizeArgList = @('-NonInteractive', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $finalizePath)
            $fbFinalizeProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $fbFinalizeArgList -WindowStyle Hidden -PassThru -ErrorAction Stop
            Write-FbDeferredOobeSoundWuMirrorLog ("2259: FirstBaseOobeOperatorFinalize.ps1 launched synchronously (PID {0}) from '{1}'; waiting up to 120s." -f $fbFinalizeProc.Id, $finalizePath) 'INFO'
            $fbFinalizeExited = $fbFinalizeProc.WaitForExit(120000)
            if ($fbFinalizeExited) {
                Write-FbDeferredOobeSoundWuMirrorLog ("2259: FirstBaseOobeOperatorFinalize.ps1 completed (exit {0}); shutdown delegated to finalize." -f $fbFinalizeProc.ExitCode) 'INFO'
            } else {
                Write-FbDeferredOobeSoundWuMirrorLog '2259: FirstBaseOobeOperatorFinalize.ps1 did not exit within 120s; issuing fallback shutdown /s /t 0 /f.' 'WARN'
                $fbShutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
                Start-Process -FilePath $fbShutdown -ArgumentList @('/s', '/t', '0', '/f', '/c', 'FirstBase: finalize 120s timeout; fallback shutdown.') -WindowStyle Hidden -ErrorAction SilentlyContinue
            }
        } catch {
            Write-FbDeferredOobeSoundWuMirrorLog ("2259: ERROR launching FirstBaseOobeOperatorFinalize.ps1 synchronously: {0}; issuing fallback shutdown." -f $_.Exception.Message) 'ERROR'
            $fbShutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
            Start-Process -FilePath $fbShutdown -ArgumentList @('/s', '/t', '0', '/f', '/c', 'FirstBase: finalize launch failed; fallback shutdown.') -WindowStyle Hidden -ErrorAction SilentlyContinue
        }
    } else {
        Write-FbDeferredOobeSoundWuMirrorLog ("2259: FirstBaseOobeOperatorFinalize.ps1 missing (Setup='{0}' ProgramData='{1}') - cannot write .pipeline-completed; issuing fallback shutdown." -f $FinalizePs1, $FinalizePs1Pd) 'ERROR'
        $fbShutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
        Start-Process -FilePath $fbShutdown -ArgumentList @('/s', '/t', '0', '/f', '/c', 'FirstBase: finalize missing; fallback shutdown.') -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
} finally {
    try { Remove-Item -LiteralPath $SessionLockPath -Force -ErrorAction SilentlyContinue } catch {}
}

exit 0
