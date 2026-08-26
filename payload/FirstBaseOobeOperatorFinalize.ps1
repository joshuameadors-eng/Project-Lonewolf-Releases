# FirstBase 2226/2231: operator finalize after deferred OOBE Settings close.
# Writes Bug U .pipeline-completed + .firstbase-sealed, post-operator Winlogon scrub,
# disarms deferred delivery surfaces (RunOnce, Run, schtasks, activation RunOnce).
# Thin script — do not dot-source Invoke-WindowsUpdateLoop.ps1.
# For Internal Use Only.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ConfirmPreference      = 'None'

$FbRoot = 'C:\Windows\Setup\FirstBase'
$FbPd = 'C:\ProgramData\FirstBase'
$PipelineMarker = Join-Path $FbPd '.pipeline-completed'
$SealedMarker = Join-Path $FbPd '.firstbase-sealed'
$ArmSuppress = Join-Path $FbPd '.firstbase-specialize-arm-suppressed'
$SplashOverlay = Join-Path $FbPd 'FirstBase-Splash-Oobe-Overlay.mode'
$DeferredRunOnceArm = Join-Path $FbPd '.deferred-oobe-sound-runonce-armed'
$DeferredOnLogonTaskArm = Join-Path $FbPd '.deferred-oobe-sound-onlogon-task-armed'
$DeferredRunKeyArm = Join-Path $FbPd '.deferred-oobe-sound-run-key-armed'
$DeferredActiveSetupArm = Join-Path $FbPd '.deferred-oobe-sound-active-setup-armed'
$DeferredStartupArm = Join-Path $FbPd '.deferred-oobe-sound-startup-armed'
$DeferredUserInitArm = Join-Path $FbPd '.deferred-oobe-sound-userinit-armed'
$DeferredStartupCmd = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\FirstBaseOobeSoundAtLogon.vbs'
$DeferredBootstrapLock = Join-Path $FbPd '.deferred-oobe-sound-bootstrap.lock'
$OobeSoundUserRebootGate = Join-Path $FbPd '.oobe-sound-user-reboot-allowed'
$ActivationRunOnceArm = Join-Path $FbPd '.activation-settings-runonce-armed'
$DeferredOnLogonTask = 'FirstBase\DeferredOobeSoundOnLogon'
$RunOnceRk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$RunRk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$DeferredRunOnceName = 'OpenWindowsSoundSettingsDeferredOnce'
$DeferredRunKeyName = 'OpenWindowsSoundSettingsDeferredLogon'
$ActivationRunOnceName = 'OpenWindowsActivationSettingsOnce'
$WinlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$WinlogonAutologonValues = @(
    'AutoAdminLogon'
    'DefaultUserName'
    'DefaultPassword'
    'DefaultDomainName'
    'AutoLogonCount'
    'ForceAutoLogon'
    'AutoLogonSID'
    'SystemAutoLogon'
    'LastUsedUsername'
    'DisableLockWorkstation'
    'EnableFirstLogonAnimation'
)

function Get-FbOobeOperatorFinalizeScriptLeaf {
    try {
        if ($MyInvocation.MyCommand.Path) { return (Split-Path -Leaf $MyInvocation.MyCommand.Path) }
    } catch {}
    return 'FirstBaseOobeOperatorFinalize.ps1'
}

$fbVer = Join-Path $FbRoot 'FirstBaseVersion.ps1'
if (-not (Test-Path -LiteralPath $fbVer)) {
    $fbVer = Join-Path $PSScriptRoot 'FirstBaseVersion.ps1'
}
if (Test-Path -LiteralPath $fbVer) {
    . $fbVer
} else {
    $FirstBaseProductVersion = '1.0.0'
    $FirstBasePayloadRevision = 'unknown'
    $FirstBaseScriptVersion = @{}
}
$thisLeaf = Get-FbOobeOperatorFinalizeScriptLeaf
$thisVer = [string]$FirstBaseScriptVersion[$thisLeaf]
if ([string]::IsNullOrWhiteSpace($thisVer)) { $thisVer = $FirstBaseProductVersion }

function Write-FbOperatorFinalizeMirror {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = ('[{0}] [{1}] [runId=oobe-operator-finalize] {2}' -f $ts, $Level, $Message)
    $logDir = Join-Path $FbRoot 'Logs'
    try {
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
    try {
        $mirror = Join-Path $logDir 'WU-oobe-operator-finalize-mirror.log'
        Add-Content -LiteralPath $mirror -Value $line -Encoding ascii -ErrorAction SilentlyContinue
    } catch {}
    # 2260: Also write to ProgramData — C:\Windows\Setup\FirstBase\Logs\ is not writable by defaultuser0 in OOBE
    # (dump fb-dump-final-924: no finalize mirror log; ProgramData log is writable from OOBE session).
    try {
        $pdMirror = Join-Path $FbPd 'WU-oobe-operator-finalize-mirror.log'
        Add-Content -LiteralPath $pdMirror -Value $line -Encoding ascii -ErrorAction SilentlyContinue
    } catch {}
    try {
        $latest = Get-ChildItem -LiteralPath $logDir -Filter 'WU-*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) {
            Add-Content -LiteralPath $latest.FullName -Value $line -Encoding ascii -ErrorAction SilentlyContinue
        }
    } catch {}
    try {
        $sc = Join-Path $logDir 'SetupComplete.log'
        if (Test-Path -LiteralPath $sc) {
            Add-Content -LiteralPath $sc -Value ("[2231-operator-finalize] {0}" -f $line) -Encoding ascii -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Clear-FbPostOperatorWinlogonAutologon {
    param([string]$Context = 'post-operator-seal')
    $removed = 0
    foreach ($valueName in $WinlogonAutologonValues) {
        try {
            $existing = Get-ItemProperty -LiteralPath $WinlogonKey -Name $valueName -ErrorAction SilentlyContinue
            if ($null -ne $existing) {
                Remove-ItemProperty -LiteralPath $WinlogonKey -Name $valueName -Force -ErrorAction Stop
                $removed++
                Write-FbOperatorFinalizeMirror ("2231: post-operator scrub removed Winlogon\{0} ({1})." -f $valueName, $Context) 'INFO'
            }
        } catch {
            Write-FbOperatorFinalizeMirror ("2231: post-operator scrub Winlogon\{0} WARN: {1}" -f $valueName, $_.Exception.Message) 'WARN'
        }
    }
    try {
        $p = Start-Process -FilePath 'net.exe' -ArgumentList @('user', 'Administrator', '/active:no') -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
        if ($p) {
            $exited = $p.WaitForExit(3000)
            if (-not $exited) {
                try { $p.Kill() } catch {}
                Write-FbOperatorFinalizeMirror '2250: net.exe Administrator disable timed out (3000ms); process killed; continuing.' 'WARN'
            }
        }
        Write-FbOperatorFinalizeMirror '2231: post-operator scrub net user Administrator /active:no issued.' 'INFO'
    } catch {
        Write-FbOperatorFinalizeMirror ("2231: post-operator Administrator disable WARN: {0}" -f $_.Exception.Message) 'WARN'
    }
    Write-FbOperatorFinalizeMirror ("2231: post-operator Winlogon scrub finished ({0} value(s) removed)." -f $removed) 'INFO'
    return $removed
}

function Remove-FbOperatorFinalizeRunOnceValue {
    param([string]$Name, [string]$Note = '')
    try {
        Remove-ItemProperty -LiteralPath $RunOnceRk -Name $Name -Force -ErrorAction SilentlyContinue
        if ($Note) {
            Write-FbOperatorFinalizeMirror ("2231: cleared HKLM RunOnce\{0} ({1})." -f $Name, $Note) 'INFO'
        }
    } catch {}
}

Write-FbOperatorFinalizeMirror ("2231: operator finalize starting (payload={0} script={1})" -f $FirstBasePayloadRevision, $thisVer) 'INFO'

# 2250: Operator context guard — informational only; delivery must complete regardless.
$fbFinalizeUser = $env:USERNAME
$fbIsOobeContext = ($fbFinalizeUser -eq 'defaultuser0') -or ($fbFinalizeUser -eq 'SYSTEM') -or ($fbFinalizeUser -eq 'Administrator') -or ([string]::IsNullOrWhiteSpace($fbFinalizeUser))
if (-not $fbIsOobeContext) {
    Write-FbOperatorFinalizeMirror ("2250: WARN finalize running for non-OOBE user [{0}]; delivery will still complete." -f $fbFinalizeUser) 'WARN'
}

# 2252: Immediate disarm — HKLM Run (must be first; session may terminate at any moment)
try {
    Remove-ItemProperty -LiteralPath $RunRk -Name $DeferredRunKeyName -Force -ErrorAction SilentlyContinue
    Write-FbOperatorFinalizeMirror ("2252: [IMMEDIATE] cleared HKLM Run {0}." -f $DeferredRunKeyName) 'INFO'
} catch {}

# 2252: Immediate disarm — Winlogon\Userinit restore (canonical Windows default includes trailing comma)
try {
    Set-ItemProperty -LiteralPath $WinlogonKey -Name Userinit -Value 'C:\Windows\system32\userinit.exe,' -ErrorAction Stop
    Write-FbOperatorFinalizeMirror '2252: [IMMEDIATE] Winlogon\Userinit restored to default.' 'INFO'
} catch {
    Write-FbOperatorFinalizeMirror ('2252: [IMMEDIATE] WARN Userinit restore failed: {0}' -f $_.Exception.Message) 'WARN'
}

# 2252: Immediate disarm — arm-suppress marker
try {
    if (Test-Path -LiteralPath $ArmSuppress) {
        Remove-Item -LiteralPath $ArmSuppress -Force -ErrorAction Stop
        Write-FbOperatorFinalizeMirror '2252: [IMMEDIATE] removed arm-suppress marker.' 'INFO'
    }
} catch {
    Write-FbOperatorFinalizeMirror ("2252: [IMMEDIATE] arm-suppress remove failed: {0}" -f $_.Exception.Message) 'WARN'
}

try {
    if (-not (Test-Path -LiteralPath $FbPd)) {
        New-Item -ItemType Directory -Path $FbPd -Force -ErrorAction Stop | Out-Null
    }
    $oneLine = ('Pipeline completed at {0} (FirstBaseOobeOperatorFinalize.ps1 PID {1})' -f (Get-Date -Format 'o'), $PID)
    Set-Content -LiteralPath $PipelineMarker -Value $oneLine -Encoding UTF8 -Force
    Write-FbOperatorFinalizeMirror ("2226: wrote .pipeline-completed at {0}" -f $PipelineMarker) 'INFO'
} catch {
    # 2260: Do NOT throw — DeferredOobeSound inline seal (2260) may have already written the marker.
    # Finalize continues to cleanup and shutdown regardless; throwing here would prevent shutdown from firing.
    Write-FbOperatorFinalizeMirror ("2226: WARN .pipeline-completed write failed (may have been written by inline seal): {0}; continuing." -f $_.Exception.Message) 'WARN'
}

try {
    $sealedLine = ('Sealed at {0} (PID {1}); device ready for pack/ship after shutdown.' -f (Get-Date -Format 'o'), $PID)
    Set-Content -LiteralPath $SealedMarker -Value $sealedLine -Encoding UTF8 -Force
    Write-FbOperatorFinalizeMirror ("2231: wrote .firstbase-sealed at {0}" -f $SealedMarker) 'INFO'
} catch {
    Write-FbOperatorFinalizeMirror ("2231: FAILED to write .firstbase-sealed: {0}" -f $_.Exception.Message) 'ERROR'
}

Remove-FbOperatorFinalizeRunOnceValue -Name $DeferredRunOnceName -Note 'deferred Sound'
Remove-FbOperatorFinalizeRunOnceValue -Name $ActivationRunOnceName -Note 'activation (warehouse power-on must not open Settings)'
# 2254: Layer-3 HKLM RunOnce splash backup survives OOBE-overlay scrub; remove before first real-user logon fires it.
Remove-FbOperatorFinalizeRunOnceValue -Name '!FirstBaseWuSplash' -Note '2254 Layer-3 splash backup (post-OOBE must not show update splash)'

# 2294: Startup launcher delete moved below (after $fb2258Deferred is initialized,
# near the 2258 scrub) so a failed removal falls back into the same deferred-delete
# batch instead of being a single-shot attempt with no recovery path.

# 2256: Complete ALL disarms before shutdown. Prior build issued shutdown /s here; the process was torn
# down before FirstBase-Splash-Oobe-Overlay.mode + schtasks removal ran, leaving stale overlay on disk.
# That made Show-UpdateProgress 2221-defer the close on the first real-user desktop (fb-dump-final-806).

try {
    $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Delete', '/TN', $DeferredOnLogonTask, '/F') -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
    if ($p) {
        $exited = $p.WaitForExit(3000)
        if (-not $exited) {
            try { $p.Kill() } catch {}
            Write-FbOperatorFinalizeMirror ("2250: schtasks /Delete {0} timed out (3000ms); process killed; continuing." -f $DeferredOnLogonTask) 'WARN'
        }
    }
    Write-FbOperatorFinalizeMirror ("2227: removed scheduled task {0} if present." -f $DeferredOnLogonTask) 'INFO'
} catch {
    Write-FbOperatorFinalizeMirror ("2227: optional remove {0} failed: {1}" -f $DeferredOnLogonTask, $_.Exception.Message) 'WARN'
}

# 2251: Remove remaining FirstBase scheduled tasks so no artifact survives into OOBE.
foreach ($fbTask in @('FirstBase\SplashWatcher', 'FirstBase\UpdateSplash', 'FirstBase\UpdateSplashLayer4', 'FirstBase\DebugHotkeyWatcher')) {
    try {
        $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Delete', '/TN', $fbTask, '/F') -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
        if ($p) {
            $exited = $p.WaitForExit(3000)
            if (-not $exited) {
                try { $p.Kill() } catch {}
                Write-FbOperatorFinalizeMirror ("2251: schtasks /Delete {0} timed out (3000ms); process killed; continuing." -f $fbTask) 'WARN'
            }
        }
        Write-FbOperatorFinalizeMirror ("2251: removed scheduled task {0} if present." -f $fbTask) 'INFO'
    } catch {
        Write-FbOperatorFinalizeMirror ("2251: optional remove {0} failed: {1}" -f $fbTask, $_.Exception.Message) 'WARN'
    }
}

# 2289: WU loop scheduled tasks and registry triggers must be removed here.
# Field evidence: WindowsUpdateLoop ONSTART task survived finalize, fired on reboot,
# re-staged ProgramData scripts via Ensure-FbDeferredOobeSoundProgramDataKit.
# These were omitted from finalize because pre-sysprep STEP 2 deletes them — but
# if sysprep's reboot kills the deferred-delete batch before it completes, they survive.
foreach ($fbTask in @('FirstBase\WindowsUpdateLoop', 'FirstBase\WindowsUpdateLoopOnLogon', 'FirstBase\WindowsUpdateLoopBoot2', 'FirstBase\WindowsUpdateLoopAnyLogon', 'FirstBase\SplashWatcher', 'FirstBase\SplashWatcherBoot2')) {
    try {
        $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Delete', '/TN', $fbTask, '/F') -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
        if ($p) {
            $exited = $p.WaitForExit(3000)
            if (-not $exited) {
                try { $p.Kill() } catch {}
                Write-FbOperatorFinalizeMirror ("2289: schtasks /Delete {0} timed out (3000ms); process killed; continuing." -f $fbTask) 'WARN'
            }
        }
        Write-FbOperatorFinalizeMirror ("2289: removed scheduled task {0} if present." -f $fbTask) 'INFO'
    } catch {
        Write-FbOperatorFinalizeMirror ("2289: optional remove {0} failed: {1}" -f $fbTask, $_.Exception.Message) 'WARN'
    }
}
Remove-FbOperatorFinalizeRunOnceValue -Name '!FirstBaseWuLoop' -Note '2289 WU loop HKLM RunOnce trigger'
try {
    Remove-ItemProperty -LiteralPath $RunRk -Name 'FirstBaseWuLoopRun' -Force -ErrorAction SilentlyContinue
    Write-FbOperatorFinalizeMirror '2289: cleared HKLM Run\FirstBaseWuLoopRun (WU loop Run trigger).' 'INFO'
} catch {}
try {
    $fb2289RunOnceExKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnceEx\0001'
    Remove-ItemProperty -LiteralPath $fb2289RunOnceExKey -Name 'FirstBaseWuLoop' -Force -ErrorAction SilentlyContinue
    Write-FbOperatorFinalizeMirror '2289: cleared HKLM RunOnceEx\0001\FirstBaseWuLoop if present.' 'INFO'
    if (Test-Path $fb2289RunOnceExKey) {
        $fb2289RunOnceExRemaining = Get-Item $fb2289RunOnceExKey | Get-ItemProperty | Select-Object -ExcludeProperty PS*
        if (($fb2289RunOnceExRemaining | Get-Member -MemberType NoteProperty).Count -eq 0) {
            Remove-Item $fb2289RunOnceExKey -Recurse -Force -ErrorAction SilentlyContinue
            Write-FbOperatorFinalizeMirror '2289: removed RunOnceEx\0001 subkey (empty after WU loop value removal).' 'INFO'
        }
    }
} catch {
    Write-FbOperatorFinalizeMirror ("2289: RunOnceEx\0001 cleanup WARN: {0}" -f $_.Exception.Message) 'WARN'
}

# 2251: Remove Active Setup component so it does not re-fire on the next real-user logon.
try {
    $asKey = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A7B8C9D0-E1F2-4A5B-9C01-2234DEFERREDSOUND}'
    if (Test-Path -LiteralPath $asKey) {
        Remove-Item -LiteralPath $asKey -Recurse -Force -Confirm:$false -ErrorAction Stop
        Write-FbOperatorFinalizeMirror '2251: removed Active Setup component {A7B8C9D0-E1F2-4A5B-9C01-2234DEFERREDSOUND} from HKLM.' 'INFO'
    }
} catch {
    Write-FbOperatorFinalizeMirror ('2251: optional Active Setup cleanup failed: {0}' -f $_.Exception.Message) 'WARN'
}

foreach ($markerPath in @($SplashOverlay, $DeferredRunOnceArm, $DeferredOnLogonTaskArm, $DeferredRunKeyArm, $DeferredActiveSetupArm, $DeferredStartupArm, $DeferredBootstrapLock, $OobeSoundUserRebootGate, $ActivationRunOnceArm, $DeferredUserInitArm)) {
    try {
        if (Test-Path -LiteralPath $markerPath) {
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
            Write-FbOperatorFinalizeMirror ("2231: removed ProgramData marker {0}" -f $markerPath) 'INFO'
        }
    } catch {
        Write-FbOperatorFinalizeMirror ("2231: optional ProgramData cleanup failed for {0}: {1}" -f $markerPath, $_.Exception.Message) 'WARN'
    }
}

Clear-FbPostOperatorWinlogonAutologon | Out-Null

# 2296-mdm-scrub: The privileged block teardown (MDM policy keys AutoEnrollMDM /
# UseAADCredentialType, DmEnrollmentSvc start-type, FirstBase-Block-Autopilot firewall
# rule, Defender exclusions, WU AU policy, recovery BCD) requires ELEVATION. This finalize
# runs in the LIMITED OOBE defaultuser0 token (see the Winlogon "Requested registry access
# is not allowed" WARNs above), so performing the removals inline SILENTLY FAILS while
# logging false success — confirmed on dump PF4VGG7V-1648, where AutoEnrollMDM=0 and
# DmEnrollmentSvc=Disabled survived PAST settings-close. Instead, trigger the pre-staged
# SYSTEM task FirstBase\MdmScrub (created pre-sysprep by Register-FbMdmScrubTaskPreSysprep;
# runs as SYSTEM / RL HIGHEST) and VERIFY its JSON result marker.
#
# This is intentionally the ONLY teardown site: the block STAYS APPLIED through sysprep and
# the entire OOBE sit period, and is removed ONLY here, when the operator closes Settings.
# Non-silent: a loud ERROR is logged (and thus captured by fb-dump) if the scrub does not
# confirm overall=PASS, so a residual device is diagnosable instead of silently shipping.
$mdmScrubTask   = 'FirstBase\MdmScrub'
$mdmScrubResult = Join-Path $FbPd '.mdm-scrub-result'
Write-FbOperatorFinalizeMirror '2296: triggering SYSTEM MdmScrub task (removes MDM keys, DmEnrollmentSvc, Autopilot firewall, Defender exclusions, WU AU policy, recovery BCD).' 'INFO'
try { if (Test-Path -LiteralPath $mdmScrubResult) { Remove-Item -LiteralPath $mdmScrubResult -Force -ErrorAction SilentlyContinue } } catch {}
$mdmScrubFired = $false
try {
    $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Run', '/TN', $mdmScrubTask) -WindowStyle Hidden -PassThru -ErrorAction Stop
    if ($p) {
        if (-not $p.WaitForExit(8000)) { try { $p.Kill() } catch {} }
        if ($p.HasExited -and $p.ExitCode -eq 0) { $mdmScrubFired = $true }
    }
    Write-FbOperatorFinalizeMirror ("2296: schtasks /Run {0} issued (fired={1})." -f $mdmScrubTask, $mdmScrubFired) 'INFO'
} catch {
    Write-FbOperatorFinalizeMirror ("2296: schtasks /Run {0} threw: {1}" -f $mdmScrubTask, $_.Exception.Message) 'WARN'
}
# Fallback trigger via the ScheduledTasks module (in case schtasks /Run was unavailable).
try { Start-ScheduledTask -TaskPath '\FirstBase\' -TaskName 'MdmScrub' -ErrorAction SilentlyContinue } catch {}
# Poll for the VERIFIED result marker written by the SYSTEM task (up to ~60s).
$mdmScrubVerified = $false
$mdmScrubOverall  = 'UNKNOWN'
for ($i = 0; $i -lt 30; $i++) {
    if (Test-Path -LiteralPath $mdmScrubResult) {
        try {
            $r = (Get-Content -LiteralPath $mdmScrubResult -Raw -ErrorAction Stop | ConvertFrom-Json)
            if ($r -and $r.overall) { $mdmScrubOverall = [string]$r.overall; $mdmScrubVerified = $true; break }
        } catch {}
    }
    Start-Sleep -Milliseconds 2000
}
if ($mdmScrubVerified -and $mdmScrubOverall -eq 'PASS') {
    Write-FbOperatorFinalizeMirror '2296: SYSTEM MdmScrub VERIFIED overall=PASS — MDM keys + DmEnrollmentSvc + Autopilot firewall confirmed removed at settings-close.' 'INFO'
} elseif ($mdmScrubVerified) {
    Write-FbOperatorFinalizeMirror ("2296: ERROR SYSTEM MdmScrub reported overall={0}; one or more PRIVILEGED blocks may PERSIST into the shipped image. Inspect C:\ProgramData\FirstBase\Logs\WU-mdm-scrub.log and .mdm-scrub-result." -f $mdmScrubOverall) 'ERROR'
} else {
    Write-FbOperatorFinalizeMirror '2296: ERROR SYSTEM MdmScrub did NOT report a result within 60s; the task trigger likely failed and the MDM / DmEnrollmentSvc / Autopilot-firewall blocks may PERSIST. Inspect scheduled task FirstBase\MdmScrub and C:\ProgramData\FirstBase\Logs\WU-mdm-scrub.log.' 'ERROR'
}

# NOTE (fb-dump-final-1101): Splash process kill is NOW BEFORE the script scrub (2261 fix).
# Prior 2260 build killed processes AFTER the scrub; splash scripts (FirstBaseSplashSingleInstance.ps1,
# FirstBaseSplashWatcher.ps1) were locked when the scrub ran, got deferred to a ping-delay batch, and
# survived because shutdown /t 0 fired before the ~8s batch delay completed. On the next boot those
# scripts were still on disk; SplashWatcher (OnStart task, still registered) fired them, and the real
# user saw the update splash screen instead of a clean desktop.
# Fix: kill all splash processes FIRST, sleep 1.5s to let the OS release file handles, THEN scrub.
# Splash files will be unlocked by the time Remove-Item runs; no deferral needed.
# 2252/2256: Kill splash-related PowerShell (Get-Process .CommandLine is unreliable on 5.1; Win32_Process only)
try {
    $pat = '(?i)Show-UpdateProgress|FirstBaseSplashSingleInstance|FirstBaseSplashWatcher|FirstBaseSplashLauncher|FirstBaseShowSplash'
    $pids = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and ($_.Name -match '^(powershell|pwsh)\.exe$') -and ($_.CommandLine -match $pat) } |
        Select-Object -ExpandProperty ProcessId -Unique)
    foreach ($spid in $pids) {
        if ($spid -eq $PID) { continue }
        try { Stop-Process -Id ([int]$spid) -Force -ErrorAction SilentlyContinue } catch {}
    }
    Write-FbOperatorFinalizeMirror ('2261: splash-related process kill attempted ({0} pid(s)) — BEFORE script scrub.' -f $pids.Count) 'INFO'
} catch {
    Write-FbOperatorFinalizeMirror ('2256: splash kill warn: {0}' -f $_.Exception.Message) 'WARN'
}
# NOTE (fb-dump-final-1101): Brief sleep after kill lets the OS release file handles on the splash .ps1
# files before Remove-Item tries to delete them. Without this, the handle release is asynchronous and a
# Remove-Item immediately after Stop-Process still hits a sharing violation on slow or busy systems.
Start-Sleep -Milliseconds 1500

# 2258: Post-seal script file scrub. Delete remaining .ps1 / .cmd / .bat files from both FirstBase
# directories so no scripts survive to the real user's desktop. Logs, log directories, and marker/flag
# files (*.flag, *.mode, wu-status/wu-state) are preserved.
# Self (FirstBaseOobeOperatorFinalize.ps1) is added to the deferred-delete list so it is removed
# after the process exits, using the same delayed-batch pattern as Invoke-FbPreSysprepScrub STEP 4a.
$fb2258ScrubDirs = @(
    'C:\Windows\Setup\FirstBase',
    (Join-Path $env:ProgramData 'FirstBase')
)
$fb2258SelfPath = $null
try {
    if ($MyInvocation.MyCommand.Path) { $fb2258SelfPath = $MyInvocation.MyCommand.Path }
} catch {}
$fb2258Deferred = [System.Collections.Generic.List[string]]::new()
$fb2258Deleted  = 0

# 2288: SetupComplete.cmd is not in the 2258 scrub roots — add explicit delete.
# Pre-sysprep STEP 4 should have removed it; this catches the deferred-batch-failure case.
$fb2288SetupCompleteCmd = 'C:\Windows\Setup\Scripts\SetupComplete.cmd'
if (Test-Path -LiteralPath $fb2288SetupCompleteCmd) {
    try {
        Remove-Item -LiteralPath $fb2288SetupCompleteCmd -Force -ErrorAction Stop
        Write-FbOperatorFinalizeMirror '2288: deleted SetupComplete.cmd from Setup\Scripts (survived pre-sysprep scrub).' 'INFO'
    } catch {
        [void]$fb2258Deferred.Add($fb2288SetupCompleteCmd)
        Write-FbOperatorFinalizeMirror ("2288: SetupComplete.cmd locked; added to deferred batch. {0}" -f $_.Exception.Message) 'WARN'
    }
}

# 2294: Startup .vbs delete now retries once (800ms) before falling back to the
# deferred-delete batch, matching the 2258 scrub's resilience. Field evidence
# showed the single-shot attempt losing a race (likely Defender real-time scan
# lock on the powershell-launching .vbs) and leaving the file permanently stranded
# with zero recovery path, since the Startup folder was never in scope of the
# 2258 scrub's own retry/deferred mechanism.
try {
    if (Test-Path -LiteralPath $DeferredStartupCmd) {
        Remove-Item -LiteralPath $DeferredStartupCmd -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $DeferredStartupCmd) {
            Start-Sleep -Milliseconds 800
            Remove-Item -LiteralPath $DeferredStartupCmd -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $DeferredStartupCmd) {
            Write-FbOperatorFinalizeMirror ("2294: Startup launcher still present after retry; adding to deferred batch: {0}" -f $DeferredStartupCmd) 'WARN'
            [void]$fb2258Deferred.Add($DeferredStartupCmd)
        } else {
            Write-FbOperatorFinalizeMirror ("2236: removed ProgramData All Users Startup launcher {0}." -f $DeferredStartupCmd) 'INFO'
        }
    }
} catch {
    Write-FbOperatorFinalizeMirror ("2294: Startup launcher remove threw; adding to deferred batch: {0}" -f $_.Exception.Message) 'WARN'
    [void]$fb2258Deferred.Add($DeferredStartupCmd)
}

foreach ($fb2258Dir in $fb2258ScrubDirs) {
    if (-not (Test-Path -LiteralPath $fb2258Dir)) { continue }
    # 2272: Use Where-Object instead of -Include to correctly filter .ps1/.cmd.
    # In PowerShell 5.1, Get-ChildItem -LiteralPath <dir> -Include '*.ps1','*.cmd' -Recurse
    # returns ALL files in the tree (not just matching extensions) — confirmed by dump
    # fb-dump-final-1548: .log files appeared in "2258: deleted script" log lines, causing 120
    # non-script files to fill the deferred list and race the shutdown timer.
    $fb2258Files = @(Get-ChildItem -LiteralPath $fb2258Dir -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer -and ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.cmd' -or $_.Extension -ieq '.bat') })
    foreach ($fb2258File in $fb2258Files) {
        $fb2258Path = $fb2258File.FullName
        # Always defer self-deletion so this script can finish running.
        if ($fb2258SelfPath -and ($fb2258Path -ieq $fb2258SelfPath)) {
            [void]$fb2258Deferred.Add($fb2258Path)
            continue
        }
        try {
            Remove-Item -LiteralPath $fb2258Path -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $fb2258Path -ErrorAction SilentlyContinue) {
                [void]$fb2258Deferred.Add($fb2258Path)
                Write-FbOperatorFinalizeMirror ("2258: deferred delete (still present after SilentlyContinue) {0}" -f $fb2258Path) 'WARN'
            } else {
                $fb2258Deleted++
                Write-FbOperatorFinalizeMirror ("2258: deleted script {0}" -f $fb2258Path) 'INFO'
            }
        } catch {
            [void]$fb2258Deferred.Add($fb2258Path)
            Write-FbOperatorFinalizeMirror ("2258: deferred delete (exception) {0}: {1}" -f $fb2258Path, $_.Exception.Message) 'WARN'
        }
    }
}

# 2272: Retry pass — after a brief yield, re-attempt any deferred file whose transient lock may
# have cleared. Self-path must remain deferred (process must exit before it can be deleted).
# Reduces the final deferred count so the batch script has fewer files to handle.
if ($fb2258Deferred.Count -gt 0) {
    Start-Sleep -Milliseconds 800
    $fb2258StillDeferred = [System.Collections.Generic.List[string]]::new()
    foreach ($fb2258RetryPath in @($fb2258Deferred)) {
        if ($fb2258SelfPath -and ($fb2258RetryPath -ieq $fb2258SelfPath)) {
            [void]$fb2258StillDeferred.Add($fb2258RetryPath)
            continue
        }
        if (-not (Test-Path -LiteralPath $fb2258RetryPath -ErrorAction SilentlyContinue)) { continue }
        try {
            Remove-Item -LiteralPath $fb2258RetryPath -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $fb2258RetryPath -ErrorAction SilentlyContinue) {
                [void]$fb2258StillDeferred.Add($fb2258RetryPath)
                Write-FbOperatorFinalizeMirror ("2272: retry-pass still deferred {0}" -f $fb2258RetryPath) 'WARN'
            } else {
                $fb2258Deleted++
                Write-FbOperatorFinalizeMirror ("2272: retry-pass deleted {0}" -f $fb2258RetryPath) 'INFO'
            }
        } catch {
            [void]$fb2258StillDeferred.Add($fb2258RetryPath)
            Write-FbOperatorFinalizeMirror ("2272: retry-pass exception {0}: {1}" -f $fb2258RetryPath, $_.Exception.Message) 'WARN'
        }
    }
    $fb2258Deferred = $fb2258StillDeferred
}

# 2288: Post-scrub verification — confirm no .ps1/.cmd remain in ProgramData\FirstBase
$fb2288PdRoot = Join-Path $env:ProgramData 'FirstBase'
if (Test-Path -LiteralPath $fb2288PdRoot) {
    $fb2288Residuals = @(Get-ChildItem -LiteralPath $fb2288PdRoot -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer -and ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.cmd' -or $_.Extension -ieq '.bat') })
    if ($fb2288Residuals.Count -gt 0) {
        Write-FbOperatorFinalizeMirror ("2288: ProgramData verify: {0} script(s) still present after 2258 scrub; adding to deferred list." -f $fb2288Residuals.Count) 'WARN'
        foreach ($fb2288Res in $fb2288Residuals) {
            Write-FbOperatorFinalizeMirror ("  RESIDUAL: {0}" -f $fb2288Res.FullName) 'WARN'
            [void]$fb2258Deferred.Add($fb2288Res.FullName)
        }
    } else {
        Write-FbOperatorFinalizeMirror '2288: ProgramData verify: clean — no .ps1/.cmd residuals found.' 'INFO'
    }
}

# Spawn delayed-delete batch for self and any remaining locked files.
# NOTE (fb-dump-final-1101): With the splash process kill reordered above, splash scripts should no longer
# appear here as locked. This batch now handles only self-deletion and any file locked by non-splash processes.
# NOTE (2272): With the Where-Object filter fix, the deferred list should contain only
# self-deletion (1 file) plus any file still locked after the retry pass. ping -n 6 (~5s delay)
# gives this process time to exit before the batch deletes self.
if ($fb2258Deferred.Count -gt 0) {
    try {
        $fb2258Bat = Join-Path $env:TEMP 'FbFinalizeScriptScrub.cmd'
        $fb2258Lines = [System.Collections.Generic.List[string]]::new()
        $fb2258Lines.Add('@echo off')
        $fb2258Lines.Add('ping 127.0.0.1 -n 6 >nul')
        foreach ($fb2258Dp in $fb2258Deferred) {
            $fb2258Lines.Add(('del /f /q "{0}" >nul 2>&1' -f $fb2258Dp))
        }
        $fb2258Lines.Add('(goto) 2>nul & del "%~f0"')
        [System.IO.File]::WriteAllLines($fb2258Bat, $fb2258Lines, [System.Text.Encoding]::ASCII)
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $fb2258Bat) -WindowStyle Hidden -ErrorAction SilentlyContinue
        Write-FbOperatorFinalizeMirror ('2258: SCRIPT-SCRUB-DEFERRED: deleted={0} deferred={1}; batch spawned.' -f $fb2258Deleted, $fb2258Deferred.Count) 'INFO'
    } catch {
        Write-FbOperatorFinalizeMirror ('2258: deferred scrub batch spawn failed: {0}' -f $_.Exception.Message) 'WARN'
    }
} else {
    Write-FbOperatorFinalizeMirror ('2258: SCRIPT-SCRUB-COMPLETE: deleted={0} deferred=0.' -f $fb2258Deleted) 'INFO'
}

# 2256 / 5.0.38: Single shutdown decision after full disarm (no prior /s that could terminate this
# script mid-cleanup). 5.0.38 (Option B): the /r /fw "reboot to UEFI firmware" path is REMOVED.
# Rationale (analysis §5 secondary root cause for "exited to Windows login"): on Secure-Boot-disabled
# hardware the prior code issued shutdown /r /fw, i.e. a REBOOT — a sealed, Administrator-disabled,
# OOBE-state device that reboots comes straight back up at the customer OOBE/login instead of powering
# off for pack/ship. The end state MUST be a power-OFF. This script is also no longer part of the main
# flow (the SYSTEM WU loop now finalizes + scrubs + seals in the Administrator session and issues
# sysprep /oobe /shutdown itself); this shutdown remains only for the bootstrap recovery path, and it
# now unconditionally powers the device OFF.
$fbShutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
Write-FbOperatorFinalizeMirror '5.0.38: issuing shutdown /s /t 12 /f (post-disarm; device sealed; power OFF for pack/ship; NO /r /fw reboot path). 12s window for deferred-delete batch; /f prevents OOBE shell from blocking.' 'INFO'
Start-Process -FilePath $fbShutdown -ArgumentList @('/s', '/t', '12', '/f') -WindowStyle Hidden -ErrorAction SilentlyContinue
Write-FbOperatorFinalizeMirror '2231: operator finalize finished (5.0.38: power-off shutdown last after overlay/tasks/markers/kill).' 'INFO'
