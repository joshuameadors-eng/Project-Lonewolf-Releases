# FirstBase 2244: OOBE defaultuser0 first-logon bootstrap — launches deferred Sound handoff.
# 2244: stale bootstrap-lock detection — if the lock pid is dead (OOBE session was killed before
# pipeline completed), clear the stale lock and re-acquire so delivery fires on next logon.
# Previously the lock was permanent until finalize, causing Active Setup / Startup to silently
# exit 0 while HKLM Run bypassed the bootstrap entirely (root cause: Settings at user logon).
# Used as Active Setup StubPath, ProgramData Startup target, and HKLM Run target.
# 2270 (fb-dump-final-1106/1213): Two-part session-guard fix.
#   Root cause A: DeferredOobeSoundOnLogon ONLOGON task creation fails pre-sysprep with "No
#   mapping between account names and security IDs" (schtasks exit=1); only Winlogon\Userinit
#   fallback succeeds (2248), writing .deferred-oobe-sound-userinit-armed. Bootstrap's $armed
#   check did NOT include userinit-armed → exited "no deferred arm markers" for defaultuser0 OOBE
#   → DeferredOobeSound never fired. Fix: userinit-armed added to $armed.
#   Root cause B: HKLM RunOnce !FirstBaseWuSplash is NOT consumed by defaultuser0 autologon
#   (Sysprep auto-logon skips HKLM RunOnce processing) → persists until real-user logon → real
#   user sees splash. The prior real-user guard (2261) was only reachable AFTER the arm-marker
#   exit, so it never fired when userinit-armed was the only marker. Fix: a new early user-context
#   guard (2270) runs BEFORE the arm-marker exit — disarms everything for any real user before
#   Settings/splash/shutdown can reach the real user's desktop.
# For Internal Use Only.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$FbPd = 'C:\ProgramData\FirstBase'
$FbLogDir = 'C:\Windows\Setup\FirstBase\Logs'
$DeferredPs1 = Join-Path $FbPd 'FirstBaseDeferredOobeSound.ps1'
$ArmMarker = Join-Path $FbPd '.deferred-oobe-sound-runonce-armed'
$RunKeyMarker = Join-Path $FbPd '.deferred-oobe-sound-run-key-armed'
$ActiveSetupMarker = Join-Path $FbPd '.deferred-oobe-sound-active-setup-armed'
$StartupMarker = Join-Path $FbPd '.deferred-oobe-sound-startup-armed'
$UserinItMarker = Join-Path $FbPd '.deferred-oobe-sound-userinit-armed'
$PipelineDone = Join-Path $FbPd '.pipeline-completed'
$DeliveryStarted = Join-Path $FbPd '.oobe-sound-delivery-started'
$FlowDone = Join-Path $FbPd '.oobe-sound-after-updates-flow-completed'
$Sealed = Join-Path $FbPd '.firstbase-sealed'
$BootstrapLock = Join-Path $FbPd '.deferred-oobe-sound-bootstrap.lock'
$SessionLock = Join-Path $FbPd '.deferred-oobe-sound-session.lock'

function Write-FbOobeDeferredBootstrapLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('[{0}] [{1}] [bootstrap] {2}' -f (Get-Date -Format 'o'), $Level, $Message)
    foreach ($path in @(
            (Join-Path $FbPd 'WU-oobe-sound-bootstrap.log')
            (Join-Path $FbLogDir 'WU-oobe-sound-bootstrap.log')
        )) {
        try {
            $dir = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Add-Content -LiteralPath $path -Value $line -Encoding ascii -ErrorAction SilentlyContinue
        } catch {}
    }
}

function Test-FbLegacyPipelineDeliveryStartedMarker {
    try {
        if (-not (Test-Path -LiteralPath $PipelineDone)) { return $false }
        $txt = [string](Get-Content -LiteralPath $PipelineDone -Raw -ErrorAction SilentlyContinue)
        return ($txt -match 'Pipeline started')
    } catch {}
    return $false
}

function Test-FbPipelineCompletedMarkerContent {
    try {
        if (-not (Test-Path -LiteralPath $PipelineDone)) { return $false }
        $txt = [string](Get-Content -LiteralPath $PipelineDone -Raw -ErrorAction SilentlyContinue)
        return ($txt -match 'Pipeline completed')
    } catch {}
    return $false
}

function Test-FbDeferredOobeSoundSessionLockStale {
    param([string]$LockPath = $SessionLock)
    try {
        if (-not (Test-Path -LiteralPath $LockPath)) { return $false }
        $txt = [string](Get-Content -LiteralPath $LockPath -Raw -ErrorAction SilentlyContinue)
        if ([string]::IsNullOrWhiteSpace($txt)) { return $true }
        if ($txt -match 'pid=(\d+)') {
            $otherPid = 0
            if ([int]::TryParse($Matches[1], [ref]$otherPid) -and $otherPid -gt 0 -and $otherPid -ne $PID) {
                $alive = $false
                try { $alive = $null -ne (Get-Process -Id $otherPid -ErrorAction SilentlyContinue) } catch { $alive = $false }
                if (-not $alive) { return $true }
                $isTrueDeferred = $false
                try {
                    $liveCim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $otherPid" -ErrorAction SilentlyContinue
                    if ($liveCim -and ([string]$liveCim.CommandLine -match 'FirstBaseDeferredOobeSound\.ps1')) {
                        $isTrueDeferred = $true
                    }
                } catch {}
                return (-not $isTrueDeferred)
            }
        }
    } catch {}
    return $false
}

function Remove-FbDeferredOobeSoundSessionLockIfStale {
    param([string]$LockPath = $SessionLock)
    try {
        if (Test-FbDeferredOobeSoundSessionLockStale -LockPath $LockPath) {
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
            return $true
        }
    } catch {}
    return $false
}

$fbBootstrapSessionId = -1
try { $fbBootstrapSessionId = [int][System.Diagnostics.Process]::GetCurrentProcess().SessionId } catch {}
Write-FbOobeDeferredBootstrapLog ("2236: entry PID={0} user={1} session={2}" -f $PID, $env:USERNAME, $fbBootstrapSessionId) 'INFO'

if ((Test-Path -LiteralPath $PipelineDone) -and (Test-Path -LiteralPath $Sealed)) {
    Write-FbOobeDeferredBootstrapLog '2234: pipeline-completed + sealed present; fully sealed — exit 0.' 'INFO'
    exit 0
}
if (Test-Path -LiteralPath $Sealed) {
    Write-FbOobeDeferredBootstrapLog '2234: .firstbase-sealed present; exit 0.' 'INFO'
    exit 0
}
# 2295 (Phase 1 B+E+C): Smart recovery when sealed absent but delivery/finalize markers remain.
$fb2295DeliveryStarted = (Test-Path -LiteralPath $DeliveryStarted) -or (Test-FbLegacyPipelineDeliveryStartedMarker)
$fb2295FlowDone = Test-Path -LiteralPath $FlowDone
$fb2295PipelineCompleted = Test-FbPipelineCompletedMarkerContent
$fb2295RecoveryCandidate = $fb2295DeliveryStarted -or $fb2295PipelineCompleted -or $fb2295FlowDone -or (Test-Path -LiteralPath $PipelineDone)
if ($fb2295RecoveryCandidate) {
    Write-FbOobeDeferredBootstrapLog '2288-RECOVERY: delivery/finalize markers present, sealed absent — evaluating recovery branch.' 'WARN'

    if (Test-Path -LiteralPath $SessionLock) {
        if (Remove-FbDeferredOobeSoundSessionLockIfStale -LockPath $SessionLock) {
            Write-FbOobeDeferredBootstrapLog '2295-RECOVERY: stale session lock cleared; continuing recovery evaluation.' 'WARN'
        } else {
            Write-FbOobeDeferredBootstrapLog '2288-RECOVERY: session lock held by live DeferredOobeSound; exit 0.' 'WARN'
            exit 0
        }
    }

    $fb2295Armed = (Test-Path -LiteralPath $ArmMarker) -or (Test-Path -LiteralPath $RunKeyMarker) `
        -or (Test-Path -LiteralPath $ActiveSetupMarker) -or (Test-Path -LiteralPath $StartupMarker) `
        -or (Test-Path -LiteralPath $UserinItMarker)
    $fb2295InterruptedDelivery = (-not $fb2295FlowDone) -and $fb2295Armed -and $fb2295DeliveryStarted
    $fb2295InterruptedFinalize = $fb2295PipelineCompleted -or (-not $fb2295Armed) -or $fb2295FlowDone

    if ($fb2295InterruptedFinalize) {
        Write-FbOobeDeferredBootstrapLog '2295-RECOVERY: interrupted finalize — calling finalize.' 'WARN'
        $fbRecoveryFinalize = Join-Path $FbPd 'FirstBaseOobeOperatorFinalize.ps1'
        if (-not (Test-Path -LiteralPath $fbRecoveryFinalize)) {
            $fbRecoveryFinalize = 'C:\Windows\Setup\FirstBase\FirstBaseOobeOperatorFinalize.ps1'
        }
        if (Test-Path -LiteralPath $fbRecoveryFinalize) {
            Write-FbOobeDeferredBootstrapLog ("2288-RECOVERY: calling finalize at {0}" -f $fbRecoveryFinalize) 'WARN'
            try { & $fbRecoveryFinalize } catch {
                Write-FbOobeDeferredBootstrapLog ("2288-RECOVERY: finalize threw: {0}" -f $_.Exception.Message) 'ERROR'
            }
        } else {
            Write-FbOobeDeferredBootstrapLog '2288-RECOVERY: finalize absent; inline emergency scrub.' 'WARN'
            foreach ($fbRecDir in @('C:\Windows\Setup\FirstBase', (Join-Path $env:ProgramData 'FirstBase'))) {
                if (-not (Test-Path -LiteralPath $fbRecDir)) { continue }
                Get-ChildItem -LiteralPath $fbRecDir -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.PSIsContainer -and ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.cmd') } |
                    ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {} }
            }
            try { Set-Content -LiteralPath (Join-Path $FbPd '.firstbase-sealed') -Value "Recovery-sealed $(Get-Date -Format 'o')" -Encoding UTF8 -Force -ErrorAction SilentlyContinue } catch {}
            Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList @('/s','/t','12','/f') -WindowStyle Hidden -ErrorAction SilentlyContinue
        }
        exit 0
    }
    if ($fb2295InterruptedDelivery) {
        Write-FbOobeDeferredBootstrapLog '2295-RECOVERY: interrupted delivery — re-spawning DeferredOobeSound.' 'WARN'
        if (Test-FbLegacyPipelineDeliveryStartedMarker) {
            try { Remove-Item -LiteralPath $PipelineDone -Force -ErrorAction SilentlyContinue } catch {}
            Write-FbOobeDeferredBootstrapLog '2295-RECOVERY: removed legacy .pipeline-completed (Pipeline started).' 'WARN'
        }
        if (Test-Path -LiteralPath $DeliveryStarted) {
            try { Remove-Item -LiteralPath $DeliveryStarted -Force -ErrorAction SilentlyContinue } catch {}
            Write-FbOobeDeferredBootstrapLog '2295-RECOVERY: cleared .oobe-sound-delivery-started for fresh spawn.' 'WARN'
        }
        # Fall through to normal arm-marker check and DeferredOobeSound spawn.
    } elseif (Test-Path -LiteralPath $PipelineDone) {
        Write-FbOobeDeferredBootstrapLog '2295-RECOVERY: unrecognized .pipeline-completed content — calling finalize.' 'WARN'
        $fbRecoveryFinalize = Join-Path $FbPd 'FirstBaseOobeOperatorFinalize.ps1'
        if (-not (Test-Path -LiteralPath $fbRecoveryFinalize)) {
            $fbRecoveryFinalize = 'C:\Windows\Setup\FirstBase\FirstBaseOobeOperatorFinalize.ps1'
        }
        if (Test-Path -LiteralPath $fbRecoveryFinalize) {
            try { & $fbRecoveryFinalize } catch {
                Write-FbOobeDeferredBootstrapLog ("2288-RECOVERY: finalize threw: {0}" -f $_.Exception.Message) 'ERROR'
            }
        }
        exit 0
    }
}

# 2270 (fb-dump-final-1106/1213): Early user-context safety guard — runs before ANY arm-marker check.
# Guards against the case where bootstrap fires for a real user even when no (or wrong) arm markers
# are present. Specifically: when the ONLOGON task fails and only userinit-armed was written, the
# prior arm check exited "no markers" before reaching the 2261 guard — this guard fills that gap.
# Condition: real user (not defaultuser0 / SYSTEM / Administrator) AND device not yet sealed.
# (sealed is already absent here — checked above; .pipeline-completed is also absent if we reach this.)
#
# 2271 (fb-dump-final-1423): Empty-username bypass fix. When fired via Winlogon\Userinit at early
# logon, $env:USERNAME may not yet be populated (user environment not loaded). The prior guard
# treated IsNullOrWhiteSpace($env:USERNAME) as "OOBE session" — meaning any real-user Userinit
# firing with an uninitialized environment bypassed the guard. Fix: resolve via WindowsIdentity
# when $env:USERNAME is empty. If still empty after resolution, treat as real user (fail-safe blocks
# delivery rather than risking it firing on a real user's desktop).
$fb2270ResolvedUser = $env:USERNAME
if ([string]::IsNullOrWhiteSpace($fb2270ResolvedUser)) {
    try { $fb2270ResolvedUser = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -split '\\')[-1] } catch {}
}
$fb2270IsOobeSession = ($fb2270ResolvedUser -eq 'defaultuser0') -or ($fb2270ResolvedUser -eq 'SYSTEM') -or ($fb2270ResolvedUser -eq 'Administrator')
if (-not $fb2270IsOobeSession) {
    Write-FbOobeDeferredBootstrapLog ('2270: ABORT — bootstrap fired for real user [{0}] (resolved from [{1}]) before seal (.firstbase-sealed absent). Comprehensive emergency disarm (2270 early guard, pre-arm-check).' -f $fb2270ResolvedUser, $env:USERNAME) 'WARN'
    try {
        if (-not (Test-Path -LiteralPath $FbPd)) { New-Item -ItemType Directory -Path $FbPd -Force -ErrorAction SilentlyContinue | Out-Null }
        if (-not (Test-Path -LiteralPath $PipelineDone)) {
            Set-Content -LiteralPath $PipelineDone -Value ('Emergency-sealed at {0} (bootstrap PID {1} user [{2}]; 2270 early-guard pre-arm-check)' -f (Get-Date -Format 'o'), $PID, $env:USERNAME) -Encoding UTF8 -Force -ErrorAction SilentlyContinue
            Write-FbOobeDeferredBootstrapLog '2270: wrote .pipeline-completed (early guard — suppresses SplashWatcher/SplashSingleInstance on all subsequent logons).' 'WARN'
        }
        Set-Content -LiteralPath $Sealed -Value ('Emergency-sealed at {0} (bootstrap PID {1} user [{2}]; 2270 early-guard)' -f (Get-Date -Format 'o'), $PID, $env:USERNAME) -Encoding UTF8 -Force -ErrorAction SilentlyContinue
        Write-FbOobeDeferredBootstrapLog '2270: wrote .firstbase-sealed (early guard).' 'WARN'
    } catch {}
    try { Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'OpenWindowsSoundSettingsDeferredLogon' -Force -ErrorAction SilentlyContinue } catch {}
    try {
        $fb2270RoRk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        Remove-ItemProperty -LiteralPath $fb2270RoRk -Name 'OpenWindowsSoundSettingsDeferredOnce' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $fb2270RoRk -Name '!FirstBaseWuSplash' -Force -ErrorAction SilentlyContinue
        Write-FbOobeDeferredBootstrapLog '2270: removed HKLM Run + RunOnce delivery keys (early guard).' 'WARN'
    } catch {}
    try {
        $fb2270WlKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $fb2270Ui = (Get-ItemProperty -Path $fb2270WlKey -Name Userinit -ErrorAction SilentlyContinue).Userinit
        if ($fb2270Ui -match 'FirstBase') {
            Set-ItemProperty -Path $fb2270WlKey -Name Userinit -Value 'C:\Windows\system32\userinit.exe,' -ErrorAction SilentlyContinue
            Write-FbOobeDeferredBootstrapLog '2270: restored Winlogon\Userinit (early guard).' 'WARN'
        }
    } catch {}
    try {
        $fb2270StartupCmd = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\FirstBaseOobeSoundAtLogon.vbs'
        if (Test-Path -LiteralPath $fb2270StartupCmd) { Remove-Item -LiteralPath $fb2270StartupCmd -Force -ErrorAction SilentlyContinue }
    } catch {}
    foreach ($fb2270Tn in @('FirstBase\DeferredOobeSoundOnLogon', 'FirstBase\SplashWatcher', 'FirstBase\SplashWatcherBoot2', 'FirstBase\UpdateSplash', 'FirstBase\UpdateSplashLayer4', 'FirstBase\DebugHotkeyWatcher', 'FirstBase\WindowsUpdateLoop', 'FirstBase\WindowsUpdateLoopOnLogon', 'FirstBase\WindowsUpdateLoopBoot2', 'FirstBase\WindowsUpdateLoopAnyLogon')) {
        try { $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Delete', '/TN', $fb2270Tn, '/F') -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue; if ($p) { $null = $p.WaitForExit(3000) } } catch {}
    }
    Write-FbOobeDeferredBootstrapLog '2270: deleted delivery scheduled tasks (early guard).' 'WARN'
    foreach ($fb2270Mk in @(
            (Join-Path $FbPd '.firstbase-specialize-arm-suppressed'),
            (Join-Path $FbPd '.deferred-oobe-sound-runonce-armed'),
            (Join-Path $FbPd '.deferred-oobe-sound-onlogon-task-armed'),
            (Join-Path $FbPd '.deferred-oobe-sound-run-key-armed'),
            (Join-Path $FbPd '.deferred-oobe-sound-active-setup-armed'),
            (Join-Path $FbPd '.deferred-oobe-sound-startup-armed'),
            (Join-Path $FbPd '.deferred-oobe-sound-userinit-armed'),
            (Join-Path $FbPd '.deferred-oobe-sound-bootstrap.lock'))) {
        try { if (Test-Path -LiteralPath $fb2270Mk) { Remove-Item -LiteralPath $fb2270Mk -Force -ErrorAction SilentlyContinue } } catch {}
    }
    Write-FbOobeDeferredBootstrapLog '2270: removed delivery arm markers (early guard).' 'WARN'
    foreach ($fb2270ScrubDir in @('C:\Windows\Setup\FirstBase', (Join-Path $env:ProgramData 'FirstBase'))) {
        if (-not (Test-Path -LiteralPath $fb2270ScrubDir)) { continue }
        # 2272: Use Where-Object to filter .ps1/.cmd — Get-ChildItem -Include broken in PS 5.1 with -LiteralPath -Recurse.
        foreach ($fb2270Script in @(Get-ChildItem -LiteralPath $fb2270ScrubDir -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.cmd') })) {
            try { Remove-Item -LiteralPath $fb2270Script.FullName -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    Write-FbOobeDeferredBootstrapLog '2270: deleted FirstBase script files (early guard). Nothing can reach the real user desktop.' 'WARN'
    exit 0
}

if (-not (Test-Path -LiteralPath $DeferredPs1)) {
    Write-FbOobeDeferredBootstrapLog ("2234: missing {0}; exit 1." -f $DeferredPs1) 'ERROR'
    exit 1
}
# 2270: UserinItMarker (.deferred-oobe-sound-userinit-armed) added to arm check.
# fb-dump-final-1106 root cause: ONLOGON task creation failed pre-sysprep (exit=1; "No mapping
# between account names and security IDs") → only userinit fallback fired (build 2248) and wrote
# .deferred-oobe-sound-userinit-armed.  The $armed check below did NOT include userinit-armed, so
# for defaultuser0 in OOBE all four prior tests were FALSE → "no deferred arm markers; exit 0"
# and DeferredOobeSound never launched.  Fix: include $UserinItMarker.
$armed = (Test-Path -LiteralPath $ArmMarker) -or (Test-Path -LiteralPath $RunKeyMarker) `
    -or (Test-Path -LiteralPath $ActiveSetupMarker) -or (Test-Path -LiteralPath $StartupMarker) `
    -or (Test-Path -LiteralPath $UserinItMarker)
if (-not $armed) {
    Write-FbOobeDeferredBootstrapLog '2270/2236: no deferred arm markers (runonce/run-key/active-setup/startup/userinit); exit 0.' 'INFO'
    exit 0
}

# 2250: Real-user abort guard
# If this delivery fires for a non-OOBE user and the pipeline is not yet complete,
# emergency-disarm all delivery surfaces and write .pipeline-completed so splash is suppressed on all
# subsequent logons. The pipeline must only complete during OOBE defaultuser0.
#
# NOTE (fb-dump-final-1101): The prior 2250 emergency disarm ONLY removed HKLM Run and optionally
# restored Userinit. It did NOT write .pipeline-completed, did NOT delete scheduled tasks, and did NOT
# remove the All Users Startup cmd. On the SAME logon where bootstrap fired via HKLM Run, the RunOnce
# !FirstBaseWuSplash (if present) could still fire, AND the already-running FirstBase\SplashWatcher
# task (OnStart, no pipeline marker yet) would wait for interactive Explorer and then fire the splash.
# The real user saw the update splash screen because .pipeline-completed was absent.
# Fix (2261): emergency disarm is now COMPREHENSIVE — writes .pipeline-completed + .firstbase-sealed
# immediately (so SplashWatcher and SplashSingleInstance suppress themselves on this and all future
# logons), removes all RunOnce and Run delivery keys, deletes all delivery-related scheduled tasks,
# removes the Startup cmd, removes arm markers, and deletes splash script files directly.
$isOobeUser = ($env:USERNAME -eq 'defaultuser0') -or ($env:USERNAME -eq 'SYSTEM') -or ($env:USERNAME -eq 'Administrator') -or ($fb2270ResolvedUser -eq 'defaultuser0') -or ($fb2270ResolvedUser -eq 'SYSTEM') -or ($fb2270ResolvedUser -eq 'Administrator')
if (-not $isOobeUser -and -not (Test-Path -LiteralPath $PipelineDone)) {
    Write-FbOobeDeferredBootstrapLog ('2250: ABORT - bootstrap fired for real user [{0}] before pipeline complete. Comprehensive emergency disarm (2261).' -f $env:USERNAME) 'WARN'

    # NOTE (fb-dump-final-1101): Write .pipeline-completed FIRST — this is the single most important
    # action. Both FirstBaseSplashWatcher.ps1 and FirstBaseSplashSingleInstance.ps1 check this marker
    # at startup and exit immediately if present, which breaks the splash-on-real-user-login chain
    # regardless of which other cleanup steps succeed or fail below.
    try {
        if (-not (Test-Path -LiteralPath $FbPd)) {
            New-Item -ItemType Directory -Path $FbPd -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $fb2261EmergPipeline = Join-Path $FbPd '.pipeline-completed'
        Set-Content -LiteralPath $fb2261EmergPipeline -Value ('Emergency-sealed at {0} (bootstrap PID {1} user [{2}]; pipeline incomplete but real user logged in before OOBE finalize ran)' -f (Get-Date -Format 'o'), $PID, $env:USERNAME) -Encoding UTF8 -Force
        Write-FbOobeDeferredBootstrapLog '2261: emergency disarm: wrote .pipeline-completed (splash suppression on all subsequent logons).' 'WARN'
    } catch {
        Write-FbOobeDeferredBootstrapLog ("2261: emergency disarm: .pipeline-completed write FAILED: {0}." -f $_.Exception.Message) 'ERROR'
    }
    try {
        $fb2261EmergSealed = Join-Path $FbPd '.firstbase-sealed'
        Set-Content -LiteralPath $fb2261EmergSealed -Value ('Emergency-sealed at {0} (bootstrap PID {1} user [{2}])' -f (Get-Date -Format 'o'), $PID, $env:USERNAME) -Encoding UTF8 -Force
        Write-FbOobeDeferredBootstrapLog '2261: emergency disarm: wrote .firstbase-sealed.' 'WARN'
    } catch {}

    # Remove all HKLM Run and RunOnce delivery keys
    try { Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'OpenWindowsSoundSettingsDeferredLogon' -Force -ErrorAction SilentlyContinue } catch {}
    try {
        $fb2261RoRk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        Remove-ItemProperty -LiteralPath $fb2261RoRk -Name 'OpenWindowsSoundSettingsDeferredOnce' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $fb2261RoRk -Name '!FirstBaseWuSplash' -Force -ErrorAction SilentlyContinue
        Write-FbOobeDeferredBootstrapLog '2261: emergency disarm: removed HKLM Run + RunOnce delivery keys.' 'WARN'
    } catch {}

    # Remove Userinit injection to stop future logon firings
    try {
        $wlKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $cur = (Get-ItemProperty -Path $wlKey -Name Userinit -ErrorAction SilentlyContinue).Userinit
        if ($cur -match 'FirstBase') {
            $restored = 'C:\Windows\system32\userinit.exe,'
            Set-ItemProperty -Path $wlKey -Name Userinit -Value $restored -ErrorAction SilentlyContinue
            Write-FbOobeDeferredBootstrapLog '2250: Emergency Userinit restore done.' 'WARN'
        }
    } catch {}

    # Remove All Users Startup cmd (fires on every logon; would re-trigger bootstrap)
    try {
        $fb2261StartupCmd = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\FirstBaseOobeSoundAtLogon.vbs'
        if (Test-Path -LiteralPath $fb2261StartupCmd) {
            Remove-Item -LiteralPath $fb2261StartupCmd -Force -ErrorAction SilentlyContinue
            Write-FbOobeDeferredBootstrapLog '2261: emergency disarm: removed All Users Startup FirstBaseOobeSoundAtLogon.vbs.' 'WARN'
        }
    } catch {}

    # Delete all delivery-related scheduled tasks so they cannot fire on subsequent logons/startups
    foreach ($fb2261Tn in @(
            'FirstBase\DeferredOobeSoundOnLogon',
            'FirstBase\SplashWatcher',
            'FirstBase\SplashWatcherBoot2',
            'FirstBase\UpdateSplash',
            'FirstBase\UpdateSplashLayer4',
            'FirstBase\DebugHotkeyWatcher',
            'FirstBase\WindowsUpdateLoop',
            'FirstBase\WindowsUpdateLoopOnLogon',
            'FirstBase\WindowsUpdateLoopBoot2',
            'FirstBase\WindowsUpdateLoopAnyLogon')) {
        try {
            $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Delete', '/TN', $fb2261Tn, '/F') -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
            if ($p) { $null = $p.WaitForExit(3000) }
        } catch {}
    }
    Write-FbOobeDeferredBootstrapLog '2261: emergency disarm: deleted delivery/splash scheduled tasks.' 'WARN'

    # Remove delivery arm markers
    foreach ($fb2261Mk in @(
            (Join-Path $FbPd '.firstbase-specialize-arm-suppressed'),
            (Join-Path $FbPd '.deferred-oobe-sound-runonce-armed'),
            (Join-Path $FbPd '.deferred-oobe-sound-onlogon-task-armed'),
            (Join-Path $FbPd '.deferred-oobe-sound-run-key-armed'),
            (Join-Path $FbPd '.deferred-oobe-sound-active-setup-armed'),
            (Join-Path $FbPd '.deferred-oobe-sound-startup-armed'),
            (Join-Path $FbPd '.deferred-oobe-sound-userinit-armed'),
            (Join-Path $FbPd '.deferred-oobe-sound-bootstrap.lock'))) {
        try {
            if (Test-Path -LiteralPath $fb2261Mk) { Remove-Item -LiteralPath $fb2261Mk -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
    Write-FbOobeDeferredBootstrapLog '2261: emergency disarm: removed delivery arm markers.' 'WARN'

    # NOTE (fb-dump-final-1134): Use *.ps1/*.cmd glob instead of a named list. The 2261 named list
    # had 9 entries, but Invoke-FbPreSysprepScrub (splashKeepLeaves) preserves 12 files in the OOBE
    # overlay; the 4 files missing from the old list were FirstBaseConsoleSplash.cmd,
    # FirstBaseConsoleSplashInstance.ps1, FirstBaseConsoleSplashRender.ps1, and
    # FirstBaseSplashLauncher.cmd. All 4 survived to the real-user desktop when the emergency disarm
    # path was taken. Glob approach matches what FirstBaseOobeOperatorFinalize.ps1 already does and
    # is self-maintaining: future additions to splashKeepLeaves are deleted automatically.
    foreach ($fb2262ScrubDir in @('C:\Windows\Setup\FirstBase', (Join-Path $env:ProgramData 'FirstBase'))) {
        if (-not (Test-Path -LiteralPath $fb2262ScrubDir)) { continue }
        # 2272: Use Where-Object to filter .ps1/.cmd — Get-ChildItem -Include broken in PS 5.1 with -LiteralPath -Recurse.
        $fb2262ScriptFiles = @(Get-ChildItem -LiteralPath $fb2262ScrubDir -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -and ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.cmd') })
        foreach ($fb2262ScriptFile in $fb2262ScriptFiles) {
            try {
                Remove-Item -LiteralPath $fb2262ScriptFile.FullName -Force -ErrorAction SilentlyContinue
                Write-FbOobeDeferredBootstrapLog ("2262: emergency disarm: deleted {0}." -f $fb2262ScriptFile.FullName) 'WARN'
            } catch {
                Write-FbOobeDeferredBootstrapLog ("2262: emergency disarm: delete failed {0}: {1}" -f $fb2262ScriptFile.FullName, $_.Exception.Message) 'WARN'
            }
        }
    }

    exit 0
}

# 2244: stale-lock detection — if the lock file exists but the pid inside is dead (e.g. the
# OOBE defaultuser0 session was killed before pipeline completed), clear the stale lock and
# re-acquire so delivery fires on the next logon (real user or next OOBE retry).
function Test-FbBootstrapLockStale {
    try {
        $txt = [string](Get-Content -LiteralPath $BootstrapLock -Raw -ErrorAction SilentlyContinue)
        if ([string]::IsNullOrWhiteSpace($txt)) { return $true }
        if ($txt -match 'pid=(\d+)') {
            $lockPid = 0
            if ([int]::TryParse($Matches[1], [ref]$lockPid) -and $lockPid -gt 0 -and $lockPid -ne $PID) {
                $alive = $false
                try { $alive = $null -ne (Get-Process -Id $lockPid -ErrorAction SilentlyContinue) } catch {}
                return (-not $alive)
            }
        }
    } catch {}
    return $false
}

$fbLockAcquired = $false
for ($fbLockAttempt = 0; $fbLockAttempt -lt 2; $fbLockAttempt++) {
    try {
        $fs = [System.IO.File]::Open($BootstrapLock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $sw = New-Object System.IO.StreamWriter($fs)
        $sw.WriteLine(('pid={0} utc={1}' -f $PID, ([DateTimeOffset]::UtcNow.ToString('o'))))
        $sw.Flush()
        $sw.Dispose()
        $fs.Dispose()
        $fbLockAcquired = $true
        break
    } catch {
        if ($fbLockAttempt -eq 0 -and (Test-FbBootstrapLockStale)) {
            Remove-Item -LiteralPath $BootstrapLock -Force -ErrorAction SilentlyContinue
            Write-FbOobeDeferredBootstrapLog '2244: stale bootstrap lock (dead pid) cleared; retrying lock acquire.' 'WARN'
            continue
        }
        Write-FbOobeDeferredBootstrapLog '2234: bootstrap lock held by live process; exit 0 (idempotent).' 'INFO'
        exit 0
    }
}
if (-not $fbLockAcquired) {
    Write-FbOobeDeferredBootstrapLog '2244: bootstrap lock acquire failed after stale check; exit 0.' 'INFO'
    exit 0
}

Write-FbOobeDeferredBootstrapLog ("2234: spawning {0}" -f $DeferredPs1) 'INFO'
try {
    # 2258: -WindowStyle Hidden — Settings opens as a fullscreen modern app (separate process);
    # the PowerShell host window does not need to be visible and causes a visible flash on OOBE logon.
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $DeferredPs1
    ) -WindowStyle Hidden -ErrorAction Stop
    Write-FbOobeDeferredBootstrapLog '2234: spawn OK.' 'INFO'
    exit 0
} catch {
    Write-FbOobeDeferredBootstrapLog ("2234: spawn failed: {0}" -f $_.Exception.Message) 'ERROR'
    exit 1
}
