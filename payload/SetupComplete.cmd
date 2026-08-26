@echo off
setlocal EnableDelayedExpansion

:: ============================================================================
:: FirstBase Windows Update Script - SetupComplete.cmd
:: For Internal Use Only
::
:: Reliability pivot:
::   Windows Update scan APIs are unreliable in the pre-OOBE "getting ready"
::   context on some hardware/firmware combinations. Instead of blocking OOBE
::   here, we hand off to Audit Mode where update services are fully
::   available, then return to OOBE via sysprep when updates complete.
::
:: Trigger model (2026-05-13 fix - trigger-resilience release):
::   This script is invoked by Windows Setup during the *specialize* pass
::   (via autounattend.xml RunSynchronousCommand). Reseal Mode=Audit then
::   reboots the box into Audit Mode and auto-logs in as the local
::   Administrator. We must arm a trigger that fires on THAT logon, not on
::   specialize-pass execution.
::
::   2026-05-13 1700 hardening - "no-interactive-prompts":
::     Field evidence: the test device showed a cmd window stuck at the
::     "Getting ready" pre-OOBE screen with prompt text "TaskName:" and
::     a blinking cursor. The user had to type a task name manually to
::     unblock OOBE. Empirically reproduced on the developer machine via
::     direct cmd-from-cmd invocations of the same APPLY_ROBUST_TASK_
::     SETTINGS pattern. The diagnosis had two compounding causes:
::
::     PART 1 (the visible "TaskName:" prompt):
::       Inside :APPLY_ROBUST_TASK_SETTINGS the inline PowerShell ran
::         Get-ScheduledTask -TaskPath $p -TaskName $l -ErrorAction Stop |
::             Set-ScheduledTask -Settings $s -ErrorAction Stop
::       When Get-ScheduledTask throws OR yields nothing (e.g. it was
::       called with an empty task name), Set-ScheduledTask is already
::       bound to an empty pipeline. Its -TaskName is declared Mandatory
::       so PowerShell PROMPTS to STDIN for "TaskName:". The cmd-side
::       ">> %FB_LOG% 2>&1" redirects stdout/stderr only - prompts go
::       through the host's input-collection API and remain visible on
::       the console. Reproduced on this developer machine: feeding the
::       prompt 'PROMPTED-VALUE' via stdin caused PS to immediately use
::       it as the -TaskName value (then the CIM query failed because
::       no such task exists). That is exactly what the field user
::       experienced - they typed a real task name and the script
::       continued.
::
::     PART 2 (why the empty task name happened):
::       SetupComplete.cmd was saved with LF-only line endings (it was
::       6748 LFs / 0 CRs on disk in the repo). cmd.exe REQUIRES CRLF
::       line endings to parse batch files correctly; with LF-only,
::       the parser exhibits a documented misbehaviour where execution
::       continues PAST 'exit /b 0' at the script's :DONE label and
::       falls through into the subroutine bodies below as if they
::       were inline main-flow code. That fall-through eventually
::       reaches :APPLY_ROBUST_TASK_SETTINGS - but without a 'call'
::       providing %~1, so FB_TN_FULL=''. The empty task name then
::       hits PART 1. (Empirically verified: rewriting SetupComplete
::       .cmd with CRLF endings made the script exit cleanly at :DONE.
::       With LF-only it kept executing every subroutine in source
::       order after the supposed exit.)
::
::     FIELD REGRESSION (rev 2285-arm-first): Device PF3THF6C-1159-Lenovo dropped
::       all WU loop LOG calls and skipped the WU loop ARM section entirely due to
::       the LF-only encoding described above. Fixed in rev 2286-crlf-fix by CRLF
::       conversion. Recurrence prevented by .gitattributes enforcing eol=crlf for
::       *.cmd files in the repo root.
::
::     The fix is layered:
::       FIX A. Convert SetupComplete.cmd to CRLF line endings (every
::              line terminator is now \r\n). Prevents the fall-through.
::       FIX B. Inside :APPLY_ROBUST_TASK_SETTINGS the PowerShell body
::              is rewritten to validate $tn (the cmd-side %~1) for
::              null/empty BEFORE doing anything and to use SEPARATE
::              Get-ScheduledTask + Set-ScheduledTask statements with
::              an explicit null-check in between. No pipeline binding
::              to a mandatory parameter exists anywhere in the new
::              body. Even if Part 1's compounding cause re-emerges
::              (e.g. a future code path passes an empty argument),
::              the code logs WARN and exits 0 instead of prompting.
::       FIX C. powershell.exe runs with -NonInteractive (in addition
::              to -NoProfile -ExecutionPolicy Bypass). Mandatory
::              prompts fail fast with a parameter-binding exception
::              under -NonInteractive instead of waiting for STDIN.
::       FIX D. Every cmd-side invocation that COULD prompt (schtasks,
::              reg, net user, powershell.exe in the APPLY subroutine)
::              has '<nul' appended to redirect STDIN to EOF.
::              Belt-and-braces guarantee against any future regression
::              that bypasses -NonInteractive.
::       FIX E. /TR argument complexity is eliminated by pointing /TR
::              at small launcher .cmd shims (%FB_ROOT%\FirstBaseLoop
::              Launcher.cmd and %FB_ROOT%\FirstBaseSplashLauncher.cmd)
::              dropped on disk BEFORE schtasks runs. No \"...\" quote
::              escapes inside /TR anywhere. The launcher pattern was
::              already proven by the Layer-3 kickstart launcher
::              (FirstBaseWuLoopRun.cmd) introduced earlier in this
::              release window.
::       FIX F. New self-test mode: if C:\Setup\FirstBase\State\
::              .setupcomplete-selftest.flag exists at script entry,
::              every schtasks /Create is routed to /Query and the
::              APPLY_ROBUST_TASK_SETTINGS subroutine dry-runs the
::              parsing without invoking Get-ScheduledTask at all.
::              Lets a tech run SetupComplete.cmd on a dev box and
::              verify no prompts fire without touching task scheduler.
::
::   FOUR-LAYER TRIGGER MODEL. Field evidence from
::   WU-20260512-122639.log on the test device proved that a single
::   trigger (RunOnce alone) is NOT sufficient: a failed shutdown.exe
::   sequence inside Invoke-FbReboot can begin a partial logoff that
::   CONSUMES the RunOnce entry without the box actually rebooting,
::   leaving the next manual restart with no trigger. The build prior
::   to 2026-05-13 also missed StartWhenAvailable=$true on the ONSTART
::   task, so a missed-schedule trigger silently skipped instead of
::   firing when the OS came back up. The fix arms FOUR independent
::   trigger layers so any single layer's failure cannot strand the
::   loop.
::
::   Layer 1 (RunOnce):   HKLM RunOnce '!FirstBaseWuLoop' (fires on first
::                        interactive logon = Audit Mode auto-Administrator).
::                        Leading '!' keeps the entry registered if the
::                        command exits non-zero so a transient failure
::                        does not silently disarm the autostart.
::                        REFRESHED unconditionally by Invoke-FbReboot's
::                        Set-RunOnceAutostart on every reboot attempt.
::   Layer 2 (RunOnceEx): HKLM RunOnceEx\0001\FirstBaseWuLoop. Survives
::                        certain logon-cycle edge cases that consume
::                        plain RunOnce. Refreshed by Set-RunOnceAutostart.
::   Layer 3 (Run):       HKLM Run\FirstBaseWuLoopRun pointing at
::                        FirstBaseWuLoopRun.cmd kickstart launcher.
::                        Persistent (re-fires on every interactive
::                        logon until the launcher self-deletes when
::                        the completion marker appears). Refreshed by
::                        Set-RunOnceAutostart.
::   Layer 4 (sched):     ONSTART task (no /IT) and ONLOGON task scoped
::                        to BUILTIN\Administrators so the Audit
::                        Administrator logon actually matches. BOTH
::                        tasks are post-creation re-stamped with
::                        StartWhenAvailable=$true / IgnoreNew /
::                        no time-limit / battery-permissive via
::                        Set-ScheduledTask. The StartWhenAvailable
::                        fix is the critical one - without it, an
::                        ONSTART trigger missed during early boot
::                        SILENTLY SKIPS instead of firing later.
::
::   Self-healing: Invoke-WindowsUpdateLoop.ps1 runs
::   Test-FbAndRepairTriggers at script startup AND in the post-
::   exhausted-shutdown branch of Invoke-FbReboot, so any layer
::   missing on a relaunch gets re-armed automatically.
::
:: Requires Policy\autounattend.xml to set Reseal Mode=Audit in oobeSystem.
:: ============================================================================

set "FB_ROOT=C:\Windows\Setup\FirstBase"
set "FB_LOGDIR=%FB_ROOT%\Logs"
set "FB_LOG=%FB_LOGDIR%\SetupComplete.log"
set "FB_LOOP_PS=%FB_ROOT%\Invoke-WindowsUpdateLoop.ps1"
set "FB_SPLASH_PS=%FB_ROOT%\Show-UpdateProgress.ps1"
:: 2026.05.18.2213l Bug EE: splash single-instance wrapper. The launcher
:: shim invokes this wrapper instead of Show-UpdateProgress.ps1 directly
:: so Layer 2 (OnLogon task FirstBase\UpdateSplash) and Layer 4 (loop-
:: spawned schtasks bridge FirstBase\UpdateSplashLayer4) firing in the
:: same boot can no longer race and spawn 2 WPF + 2 console fallbacks.
:: The wrapper holds an exclusive FileShare::None lock on
:: splash-launcher.lock for the entire lifetime of the WPF splash;
:: sibling launcher invocations get IOException and exit clean.
set "FB_SPLASH_WRAPPER_PS=%FB_ROOT%\FirstBaseSplashSingleInstance.ps1"
:: 2026.05.20.2213q Bug MM: SYSTEM-context Explorer-presence watcher.
:: Replaces the OnLogon trigger on FirstBase\UpdateSplash that lost a
:: race with explorer.exe startup on Dell hardware (dump 1142, 5/19/
:: 2026). The watcher runs as SYSTEM under FirstBase\SplashWatcher
:: (trigger ONSTART), polls every 1s for an interactive explorer.exe
:: (SessionId >= 1), waits 3s for desktop stabilization, then fires
:: schtasks /Run /TN FirstBase\UpdateSplash. Single-instance lock on
:: splash-watcher.lock; 20-minute hard timeout; idempotent.
set "FB_SPLASH_WATCHER_PS=%FB_ROOT%\FirstBaseSplashWatcher.ps1"
set "FB_COMPLETE_MARKER=C:\Windows\Setup\Scripts\FirstBase-Updates-Complete.flag"
:: 2026.05.20.2213t Bug U fence 1 marker relocation. The pre-2213t Fence 1
:: gated on either ImageState containing "OOBE" / "COMPLETE" or on the
:: presence of %FB_COMPLETE_MARKER%. Both gates failed in the field:
::   (a) ImageState=IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE is set by Windows
::       on BOTH the post-sysprep /oobe specialize pass AND the very first
::       image-apply specialize pass when the WIM was sealed with sysprep
::       /generalize /oobe. The 2213s substring check on "OOBE" therefore
::       fires on first-apply too and SKIPS arming the pipeline entirely
::       (dump g:\fb-dump-final-1351 / Logs\SetupComplete.log L8-L9).
::   (b) %FB_COMPLETE_MARKER% lives at C:\Windows\Setup\Scripts\ which does
::       not survive sysprep /generalize + the per-image cleanup block
::       above wipes related per-image state under %FB_ROOT%\ on every
::       InstallDate change (which sysprep /generalize triggers). So the
::       marker is unreliable as a "this image instance has completed its
::       pipeline once" signal across the sysprep boundary.
:: 2226 Bug U two-marker Fence 1 (replaces single .pipeline-completed write at STAGE 2):
::   (1) %FB_ARM_SUPPRESS_MARKER% = .firstbase-specialize-arm-suppressed — written in
::       Invoke-FbOobeHandoff STAGE 2 BEFORE scrub/sysprep (UTF-8 one line, timestamp/PID).
::       Signals "post-sysprep specialize must NOT re-arm Audit pipeline."
::   (2) %FB_PIPELINE_COMPLETED_MARKER% = .pipeline-completed — written from
::       FirstBaseOobeOperatorFinalize.ps1 after the operator closes Settings (2218 deferred path),
::       OR legacy images where STAGE 2 wrote .pipeline-completed pre-2226.
:: Fence 1 below skips arming if EITHER marker exists. ProgramData survives generalize and
:: stays outside %FB_ROOT% per-image cleanup.
set "FB_PROGRAMDATA_DIR=C:\ProgramData\FirstBase"
set "FB_SPLASH_OOBE_OVERLAY_MARKER=%FB_PROGRAMDATA_DIR%\FirstBase-Splash-Oobe-Overlay.mode"
set "FB_ARM_SUPPRESS_MARKER=%FB_PROGRAMDATA_DIR%\.firstbase-specialize-arm-suppressed"
set "FB_PIPELINE_COMPLETED_MARKER=%FB_PROGRAMDATA_DIR%\.pipeline-completed"
set "FB_SEALED_MARKER=%FB_PROGRAMDATA_DIR%\.firstbase-sealed"
set "FB_DEFERRED_SOUND_ARMED=%FB_PROGRAMDATA_DIR%\.deferred-oobe-sound-runonce-armed"
set "FB_DEFERRED_SOUND_PS=%FB_PROGRAMDATA_DIR%\FirstBaseDeferredOobeSound.ps1"
set "FB_DEFERRED_SOUND_ONLOGON_TASK=FirstBase\DeferredOobeSoundOnLogon"
set "FB_DEFERRED_SOUND_RUN_KEY=OpenWindowsSoundSettingsDeferredLogon"

set "FB_TASK=FirstBase\WindowsUpdateLoop"
set "FB_LOGON_TASK=FirstBase\WindowsUpdateLoopOnLogon"
set "FB_TASK_BOOT2=FirstBase\WindowsUpdateLoopBoot2"
set "FB_TASK_ANYLOGON=FirstBase\WindowsUpdateLoopAnyLogon"
set "FB_SPLASH_TASK=FirstBase\UpdateSplash"
:: 2026.05.20.2213q Bug MM: SYSTEM Explorer-presence watcher task.
:: ONSTART trigger, /RU SYSTEM, fires FirstBaseSplashWatcher.ps1 which
:: polls for interactive explorer.exe and then runs FirstBase\Update
:: Splash. Replaces the OnLogon trigger that was racing Explorer
:: startup on Dell hardware (dump 1142). FirstBase\UpdateSplash itself
:: keeps its definition but loses its trigger - it is now ONLY
:: runnable via schtasks /Run from the watcher (or from Layer 4
:: UpdateSplashLayer4 / Layer 5 fallback in the loop).
set "FB_SPLASH_WATCHER_TASK=FirstBase\SplashWatcher"
set "FB_SPLASH_WATCHER_BOOT2=FirstBase\SplashWatcherBoot2"
:: Splash stack summary (matches :SKIP_SPLASH* arming and Invoke-WindowsUpdateLoop.ps1 splash blocks).
:: Layer 1 (PRIMARY): FirstBase\SplashWatcher ONSTART (SYSTEM) runs FirstBaseSplashWatcher.ps1;
::   polls interactive explorer.exe, stabilization wait, then CreateProcessAsUser (explorer
::   token) -> FirstBaseSplashLauncher.cmd (2213x Bug PP); schtasks /Run FirstBase\UpdateSplash
::   is fallback only. UpdateSplash is created /IT (interactive principal) but SYSTEM /Run
::   alone still failed Session 0 on field dumps — token bridge is the reliable first paint.
:: Layer 2 (TASK): FirstBase\UpdateSplash — /TR FirstBaseSplashLauncher.cmd, triggerless ONCE
::   placeholder; exists for watcher /Run, Layer 4 UpdateSplashLayer4 schtasks bridge, or Layer 5
::   Invoke-FbSplashDirectSpawn in the loop (~6722+); not self-firing OnLogon.
:: Layer 3 (BACKUP): HKLM RunOnce !FirstBaseWuSplash (armed in splash section of this file).
:: Layer 4 (LOOP): Invoke-WindowsUpdateLoop.ps1 (~11947+): schtasks /Create ONCE /IT
::   FirstBase\UpdateSplashLayer4; Session-0 loop waits Explorer (2213y), token bridge or
::   conditional schtasks /Run; splash-fallback.log + WU log.
:: Layer 5 (DIAG): Invoke-FbSplashDirectSpawn (~6722+), splash-launch-direct.log; Session-0
::   refuses Start-Process without interactive Explorer (2213y).
:: Supersedes older comment blocks that described OnLogon UpdateSplash as primary; 2213q watcher
::   + triggerless UpdateSplash is current.

set "FB_RUNONCE_KEY=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
set "FB_RUNONCEEX_KEY=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnceEx\0001"
set "FB_RUN_KEY=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
set "FB_KICKSTART_LAUNCHER=%FB_ROOT%\FirstBaseWuLoopRun.cmd"
:: 2026-05-13.1700-no-interactive-prompts: schtasks /TR launcher shims.
:: The /TR argument used to be an inline 'powershell.exe -File ...' with
:: backslash-escaped quotes ("\"...\""), which is fragile across Windows
:: builds. We now point /TR at small .cmd shims that we drop on disk
:: BEFORE the schtasks call. This eliminates the entire /TR escape
:: surface (no quotes inside quotes, no \" escapes) and gives the
:: scheduled-task entry a deterministic, human-readable command line
:: that survives reg.exe export/import cleanly.
set "FB_LOOP_LAUNCHER=%FB_ROOT%\FirstBaseLoopLauncher.cmd"
set "FB_SPLASH_LAUNCHER=%FB_ROOT%\FirstBaseSplashLauncher.cmd"
:: 2213d: console fallback splash. cmd.exe console rendering has been
:: bulletproof since NT 3.5 - if the WPF splash dies silently (Defender,
:: hardware-specific WPF audit-mode issues, anything), the console gives
:: the tech something to look at. The launcher fires BOTH the WPF splash
:: AND this console window in parallel; the console opens /MIN so it
:: doesn't compete with the WPF window for visibility.
set "FB_CONSOLE_SPLASH=%FB_ROOT%\FirstBaseConsoleSplash.cmd"
:: 2026.05.13.2213i Bug W: extract the wu-status.json render into a
:: standalone PowerShell script invoked by the console splash batch
:: via -File (no -Command inline string). Field evidence on
:: G:\fb-dump-739\FirstBaseConsoleSplash.cmd line 29 showed the prior
:: 2213d inline -Command "..." invocation tokenized as a PowerShell
:: parser error visible on the user's console:
::   - The pattern was -split '\^|' (intent: -split '\|' to split the
::     '|'-separated message on literal pipe). The author used \^| in
::     the SOURCE so that cmd would consume the ^ and emit \| in the
::     generated file. Because the inline -Command string was wrapped
::     in double quotes during the SetupComplete.cmd echo step, cmd
::     PRESERVED the ^ literally instead of consuming it, and the
::     GENERATED file at line 29 contained '\^|' verbatim. In regex
::     that means "literal ^ OR (empty)" -- empty-string alternation
::     splits between every two characters, producing N+1 empty rows
::     and visible "There seems to be a token error on 'Updates'
::     foreach" output from PowerShell's parser when the generated
::     command line was interpreted as a script.
::   - In addition, the same line wrapped foreach ($u in @($j.updates
::     ^| Select-Object -First 12)) inside a cmd parenthesised
::     if exist (...) block. cmd's (...) parser handles ^-escapes and
::     nested ( ) in ways that are subtly different from top-level
::     parsing; when the cmd parser re-tokenized the body for each
::     LOOP iteration, the embedded parens and pipes drifted in
::     escape-accounting and PowerShell occasionally saw a malformed
::     command line.
:: Both classes of bug are eliminated by routing the JSON render
:: through a separate .ps1 file. SetupComplete.cmd writes the .ps1
:: verbatim from raw 'echo' lines (no PowerShell -Command at all in
:: the console splash batch). The console splash batch invokes it via
:: powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
:: -File "%FB_CONSOLE_RENDER%". The .ps1 is loaded as a script (not
:: as a command-line string) so all cmd-side escaping is bypassed.
set "FB_CONSOLE_RENDER=%FB_ROOT%\FirstBaseConsoleSplashRender.ps1"
:: 2026.05.18.2213l Bug EE: console-splash single-instance helper PS1.
:: Invoked by the generated FirstBaseConsoleSplash.cmd at the top of the
:: batch via powershell.exe -File. EXITS errorlevel 1 if a sibling
:: console-splash invocation already holds console-splash.lock with a
:: PID-stamp newer than 30s pointing at a still-running process;
:: errorlevel 0 otherwise (also writes our own stamp). Lives as a
:: separate .ps1 so the body is NOT cmd-parsed (no ^| escape hazards,
:: no -Command quote-escape complexity).
set "FB_CONSOLE_LOCK_PS1=%FB_ROOT%\FirstBaseConsoleSplashInstance.ps1"
:: 2026-05-13.1700: self-test flag-file. If this file exists at script
:: entry, every schtasks /Create call is routed to /Query (no side
:: effects) and the inline PowerShell in :APPLY_ROBUST_TASK_SETTINGS
:: short-circuits to a dry-run parse check. Lets a tech run
:: SetupComplete.cmd on a dev box and confirm no prompts fire. The
:: production code path is unchanged when the flag is absent.
set "FB_STATE_DIR_PROBE=C:\Setup\FirstBase\State"
set "FB_SELFTEST_FLAG=%FB_STATE_DIR_PROBE%\.setupcomplete-selftest.flag"
set "FB_SELFTEST_MODE=0"
if exist "%FB_SELFTEST_FLAG%" set "FB_SELFTEST_MODE=1"

if not exist "%FB_LOGDIR%" mkdir "%FB_LOGDIR%" >nul 2>&1
:: 2026.05.20.2213t Bug U fence 1: ensure ProgramData dir exists EARLY so
:: the Fence 1 marker check below can read from a guaranteed-present
:: directory. The marker write itself happens from the PowerShell loop,
:: NOT here; this directory exists either way so post-mortem inspection
:: of C:\ProgramData\FirstBase\ never sees "directory not found" noise.
if not exist "%FB_PROGRAMDATA_DIR%" mkdir "%FB_PROGRAMDATA_DIR%" >nul 2>&1
:: 2213x OOBE overlay marker MUST NOT be written on the post-sysprep specialize
:: pass (Bug U fence 1 -> :DONE). Writing it before the fence left the file
:: populated even when all arming was skipped, enabling Show-UpdateProgress
:: OOBE-overlay aggressors without a matching Audit pipeline context.

set "FIRSTBASE_PRODUCT_VER="
set "FIRSTBASE_PAYLOAD_REV="
if exist "%FB_ROOT%\FirstBaseVersion.cmd" (
    call "%FB_ROOT%\FirstBaseVersion.cmd"
) else if exist "%~dp0FirstBaseVersion.cmd" (
    call "%~dp0FirstBaseVersion.cmd"
) else if exist "%~dp0..\FirstBase\FirstBaseVersion.cmd" (
    call "%~dp0..\FirstBase\FirstBaseVersion.cmd"
)
if not defined FIRSTBASE_PRODUCT_VER set "FIRSTBASE_PRODUCT_VER=1.0.0"
if not defined FIRSTBASE_PAYLOAD_REV set "FIRSTBASE_PAYLOAD_REV=unknown"

call :LOG "============================================================"
call :LOG "FirstBase SetupComplete starting (Audit pipeline mode, RunOnce trigger)"
call :LOG "FirstBase product=%FIRSTBASE_PRODUCT_VER% payload=%FIRSTBASE_PAYLOAD_REV%"
call :LOG "Host=%COMPUTERNAME%  User=%USERNAME%  Session=%SESSIONNAME%"
if "%FB_SELFTEST_MODE%"=="1" (
    call :LOG "*** SELF-TEST MODE *** flag %FB_SELFTEST_FLAG% present - schtasks /Create routed to /Query, PowerShell helper dry-runs only. No production triggers will be armed."
)
call :LOG "============================================================"

:: ?? 2279-fence1-oobe-fix: arm-suppress pre-cleanup guard ??????????????????
:: sysprep /generalize resets InstallDate, so every post-sysprep OOBE boot
:: looks like a "fresh image" to the per-image cleanup below. If the marker
:: written by Invoke-FbOobeHandoff STAGE 2 is already present, skip the
:: per-image cleanup entirely and go straight to the Fence 1 body. This
:: eliminates the ordering dependency: Fence 1 can never miss the marker
:: because the cleanup (now or in future) ran first and deleted it.
:: Chosen over Approach B (exclusion list) because it requires fewer changes
:: and makes the intent explicit: on a post-sysprep OOBE boot, NO cleanup
:: is needed — we are jumping to :DONE via Fence 1 anyway.
if exist "%FB_ARM_SUPPRESS_MARKER%" (
    call :LOG "2279: fence 1 pre-cleanup guard: arm-suppress present at %FB_ARM_SUPPRESS_MARKER% — post-sysprep OOBE boot detected. Skipping per-image cleanup; jumping to Fence 1 body."
    goto :FENCE1_BODY
)

:: ?? Per-image state cleanup (2026.05.12.1700-real-install-evidence) ????
:: Field log WU-20260512-110026.log showed that a freshly-imaged device
:: started the loop with a stale wu-state.json / wu-status.json from a
:: prior test run still on the disk image. Without explicit per-image
:: cleanup, those carry-over files can:
::   - Pre-pre-populate UpdateRetry with retry counters from the prior
::     image's KB list, causing the loop to skip rescans on retry-pinned
::     KBs.
::   - Pre-populate wu-status.json with stale 'Pending restart' rows so
::     the startup bridge in Invoke-WindowsUpdateLoop.ps1 spuriously
::     synthesizes InstallsCompleted=true (pre-1700 behaviour) or
::     pollutes the dashboard (1700+).
::   - Carry over a RealInstallsTotal from the prior image so the new
::     Fix C / Fix E rails accept a latch that should not exist on the
::     fresh image.
::
:: We key the cleanup on Windows' InstallDate registry value (a
:: Unix-epoch timestamp Windows writes during specialize / first boot
:: of each unique image). The .image-id marker file under FB_ROOT\State
:: stores the last seen InstallDate; if it's missing or differs from
:: the current InstallDate, this is a fresh image and we delete the
:: stale state files. Otherwise we leave them alone (an in-cycle
:: reboot must NOT wipe state mid-pipeline).
set "FB_STATE_DIR=%FB_ROOT%\State"
set "FB_IMAGE_ID_FILE=%FB_STATE_DIR%\.image-id"
if not exist "%FB_STATE_DIR%" mkdir "%FB_STATE_DIR%" >nul 2>&1

set "FB_CURRENT_INSTALL_DATE="
for /f "tokens=3" %%V in ('reg query "HKLM\Software\Microsoft\Windows NT\CurrentVersion" /v InstallDate 2^>nul ^| findstr /R "InstallDate"') do (
    set "FB_CURRENT_INSTALL_DATE=%%V"
)
if not defined FB_CURRENT_INSTALL_DATE (
    call :LOG "Per-image cleanup: could not read InstallDate from registry; skipping cleanup (state preserved)."
    goto :SKIP_PER_IMAGE_CLEAN
)

set "FB_PRIOR_INSTALL_DATE="
if exist "%FB_IMAGE_ID_FILE%" (
    for /f "usebackq delims=" %%L in ("%FB_IMAGE_ID_FILE%") do set "FB_PRIOR_INSTALL_DATE=%%L"
)

if /i "%FB_PRIOR_INSTALL_DATE%"=="%FB_CURRENT_INSTALL_DATE%" (
    call :LOG "Per-image cleanup: InstallDate matches prior marker (%FB_CURRENT_INSTALL_DATE%); SAME image, preserving wu-state.json / wu-status.json."
    goto :SKIP_PER_IMAGE_CLEAN
)

:: 5.4.22: HKLM InstallDate is rewritten by specialize (0x0 -> real) AND again by
:: servicing / later SetupComplete re-entry. Dumps PF2X3W8J-0934, PF12VZ2W-0937,
:: 5CD930865J-0938 wiped wu-state mid-Audit and restarted all updates. Destage
:: copies USB overlay only; on-device state lives on C:. If the Audit pipeline
:: already has wu-state evidence, update .image-id only. True first specialize
:: still wipes when ProgramData is empty and wu-state has no live counters.
set "FB_PRESERVE_WU_STATE="
if exist "%FB_ROOT%\wu-loop-heartbeat.txt" set "FB_PRESERVE_WU_STATE=1"
if exist "%FB_ROOT%\wu-pipeline-started.utc" set "FB_PRESERVE_WU_STATE=1"
dir /b "%FB_ROOT%\Logs\WU-*.log" >nul 2>&1 && set "FB_PRESERVE_WU_STATE=1"
if exist "%FB_ROOT%\wu-state.json" (
    findstr /R /C:"\"RealInstallsTotal\":  [1-9][0-9]*" "%FB_ROOT%\wu-state.json" >nul 2>&1 && set "FB_PRESERVE_WU_STATE=1"
    findstr /R /C:"\"RebootIterations\":  [1-9][0-9]*" "%FB_ROOT%\wu-state.json" >nul 2>&1 && set "FB_PRESERVE_WU_STATE=1"
    findstr /R /C:"\"BootCount\":  [1-9][0-9]*" "%FB_ROOT%\wu-state.json" >nul 2>&1 && set "FB_PRESERVE_WU_STATE=1"
    findstr /R /C:"[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-" "%FB_ROOT%\wu-state.json" >nul 2>&1 && set "FB_PRESERVE_WU_STATE=1"
)
if defined FB_PRESERVE_WU_STATE (
    call :LOG "Per-image cleanup: InstallDate changed (was '%FB_PRIOR_INSTALL_DATE%', now '%FB_CURRENT_INSTALL_DATE%') but Audit WU state is live - NOT a fresh image. Preserving wu-state.json / success ledger / counters. Updating .image-id only."
    > "%FB_IMAGE_ID_FILE%" echo %FB_CURRENT_INSTALL_DATE%
    goto :SKIP_PER_IMAGE_CLEAN
)

call :LOG "Per-image cleanup: InstallDate changed (was '%FB_PRIOR_INSTALL_DATE%', now '%FB_CURRENT_INSTALL_DATE%') - FRESH image detected. Wiping stale state."
del /f /q "%FB_ROOT%\wu-state.json"          >nul 2>&1
del /f /q "%FB_ROOT%\wu-status.json"         >nul 2>&1
del /f /q "%FB_ROOT%\wu-loop-heartbeat.txt"  >nul 2>&1
del /f /q "%FB_ROOT%\wu-progress.json"       >nul 2>&1
del /f /q "%FB_ROOT%\NEVER-CASCADE.flag"     >nul 2>&1
:: FB_COMPLETE_MARKER lives outside State/ so was not caught by the above cleanup.
:: Stale flag baked into source WIM causes WU loop to skip all updates and sysprep immediately.
:: Field evidence: SD002RV2-1306-Lenovo, June 22 2026.
del /f /q "%FB_COMPLETE_MARKER%"             >nul 2>&1
:: Write the new image marker AFTER the cleanup so a power-failure
:: between marker write and cleanup re-triggers the cleanup on the
:: next boot rather than silently leaving stale state in place.
> "%FB_IMAGE_ID_FILE%" echo %FB_CURRENT_INSTALL_DATE%
call :LOG "Per-image cleanup: state files wiped + completion-flag and .image-id marker written (%FB_CURRENT_INSTALL_DATE%)."

:SKIP_PER_IMAGE_CLEAN

:: ?? 2026.05.20.2213t + 2026.05.27.2226 Bug U fence 1 (two-marker gate) ??????????
:: 2213s shipped a Fence 1 here that gated on either ImageState containing
:: "OOBE" / "COMPLETE" or on the presence of %FB_COMPLETE_MARKER%. Field
:: evidence on g:\fb-dump-final-1351 (Logs\SetupComplete.log L8-L9) proved
:: the ImageState gate is fundamentally broken:
::
::   Windows sets ImageState=IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE during
::   BOTH (a) the first image-apply specialize pass (when the WIM was
::   sealed with sysprep /generalize /oobe, which IS our pipeline's WIM)
::   AND (b) the post-sysprep /oobe specialize pass after the pipeline
::   completes. The 2213s substring check on "OOBE" fires on first-apply
::   too and SKIPS arming the pipeline entirely. Symptom: zero WU-*.log
::   files, empty \FirstBase scheduled-task folder, no FirstBase RunOnce
::   keys, no AutoLogonCount/ForceAutoLogon - pipeline never armed.
::
:: 2213t replaces the ImageState gate with a marker-only gate. 2226 splits markers:
::
::   %FB_ARM_SUPPRESS_MARKER% (.firstbase-specialize-arm-suppressed) - written in
::   Invoke-FbOobeHandoff STAGE 2 BEFORE scrub/sysprep - specialize re-arm skip only.
::   %FB_PIPELINE_COMPLETED_MARKER% (.pipeline-completed) - operator-done; written from
::   FirstBaseOobeOperatorFinalize.ps1 after deferred Settings closes (post-/fw boot).
::
::   Fence 1 skips arming if EITHER marker exists (legacy images may only have .pipeline-completed).
::   Markers live in C:\ProgramData\ which:
::     - Survives sysprep /generalize (per Microsoft Sysprep docs,
::       ProgramData is NOT in the generalize-wipe scope).
::     - Is OUTSIDE %FB_ROOT% (C:\Windows\Setup\FirstBase\) so the
::       per-image cleanup block above does NOT touch it.
::     - Has a different write site than %FB_COMPLETE_MARKER% (the old
::       %FB_COMPLETE_MARKER% under C:\Windows\Setup\Scripts\ stays in
::       use for its other roles: kickstart-launcher self-cleanup,
::       early-startup gate inside Invoke-WindowsUpdateLoop.ps1).
::
:: Why a marker-only gate is safe in 2213t when it wasn't in 2213s:
::   - 2213s spec said the marker alone could regress because per-image
::     cleanup wipes state on InstallDate change. The NEW 2213t marker
::     lives OUTSIDE the per-image-cleanup scope, so it cannot be wiped
::     by that path.
::   - Sysprep /generalize does change InstallDate (which triggers our
::     per-image cleanup of wu-state.json etc.), but it does NOT touch
::     C:\ProgramData\. So the post-sysprep boot's per-image cleanup
::     wipes %FB_ROOT%\wu-*.json (correct: stale per-image state) but
::     LEAVES ProgramData markers intact (arm-suppress until operator finalize removes it;
::     .pipeline-completed once written).
::
:: Companion Fence 2 in 2213s is UNCHANGED in 2213t: Invoke-FbPreSysprep
:: Scrub (Invoke-WindowsUpdateLoop.ps1) STEP 3b explicitly deletes the
:: Winlogon auto-login values + disables Administrator just before sysprep
:: launches. Either fence alone is sufficient; both together guarantee
:: Bug U cannot recur.
::
:: Edge case: if a tech re-images the SAME device with a fresh WIM via
:: WinPE (TechInstall.cmd / disksetup.cmd), disksetup.cmd does
:: `diskpart ... clean ... format quick fs=ntfs` on the Windows volume,
:: which wipes C:\ProgramData\FirstBase\ along with everything else. So
:: a true re-image starts with the marker absent and Fence 1 falls
:: through to arming as expected. The only scenario where this gate
:: would mis-skip is "same device, no WinPE re-image, manual sysprep
:: replay" - which is exactly what we WANT it to skip.
:FENCE1_BODY
if exist "%FB_ARM_SUPPRESS_MARKER%" (
    call :LOG "2245: Bug U fence 1: arm-suppress present, pipeline not yet complete. Post-sysprep specialize pass detected. Attempting to arm %FB_DEFERRED_SOUND_ONLOGON_TASK% ONLOGON task (Task Scheduler available in specialize pass)."
    if exist "%FB_PROGRAMDATA_DIR%\FirstBaseOobeDeferredSoundBootstrap.ps1" (
        if exist "%FB_DEFERRED_SOUND_ARMED%" (
            schtasks /Delete /TN "%FB_DEFERRED_SOUND_ONLOGON_TASK%" /F >nul 2>&1 <nul
            if "%FB_SELFTEST_MODE%"=="1" (
                call :LOG "SELF-TEST: skipped schtasks /Create %FB_DEFERRED_SOUND_ONLOGON_TASK% (2245 specialize arm)"
            ) else (
                schtasks /Create /TN "%FB_DEFERRED_SOUND_ONLOGON_TASK%" /TR "powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%FB_PROGRAMDATA_DIR%\FirstBaseOobeDeferredSoundBootstrap.ps1\"" /SC ONLOGON /IT /DELAY 0000:05 /F >> "%FB_LOG%" 2>&1 <nul
                if !ERRORLEVEL! EQU 0 (
                    call :LOG "2245: Created %FB_DEFERRED_SOUND_ONLOGON_TASK% (post-sysprep specialize arm; bootstrap; 5-second delay)."
                ) else (
                    call :LOG "2245: WARNING: %FB_DEFERRED_SOUND_ONLOGON_TASK% creation failed exit=!ERRORLEVEL!"
                )
            )
        ) else (
            call :LOG "2245: Skipping ONLOGON task arm: delivery arm marker absent (%FB_DEFERRED_SOUND_ARMED% not found)."
        )
    ) else (
        call :LOG "2245: Skipping ONLOGON task arm: bootstrap not in ProgramData (%FB_PROGRAMDATA_DIR%\FirstBaseOobeDeferredSoundBootstrap.ps1 absent)."
    )
    goto :DONE
)
if exist "%FB_PIPELINE_COMPLETED_MARKER%" (
    call :LOG "Bug U fence 1 (2226): pipeline completion marker present at %FB_PIPELINE_COMPLETED_MARKER% (operator finalize or legacy). Post-sysprep specialize pass detected. SKIPPING auto-login arming + RunOnce/RunOnceEx/Run arming + scheduled-task creation. OOBE must run untainted."
    goto :DONE
)
call :LOG "Bug U fence 1 (2226): no arm-suppress at %FB_ARM_SUPPRESS_MARKER% and no pipeline marker at %FB_PIPELINE_COMPLETED_MARKER%. First image-apply specialize pass. Proceeding with full arming."
:: 2285-arm-first: WU loop trigger registration MUST run before any slow
:: security-hardening operations (ADD_DEFENDER_EXCLUSION, DISABLE_DEFENDER,
:: SUPPRESS_MDM_ENROLLMENT). Field evidence on PF3THF6C-1003-Lenovo (payload
:: 2283-arm-verify) proved that MDM suppression takes 30-60 seconds and
:: Windows Setup's specialize-pass planned reboot fires before it completes.
:: In 2283, security hardening was placed BEFORE the ARM block; the reboot
:: killed the script before WU loop triggers were ever registered. ARM is
:: fast (~2-5s total); MDM suppress is slow. Register triggers first, harden
:: second -- if the reboot fires during hardening, triggers are already armed.
set "FB_ARM_STATUS=OK"

:: Overlay.mode is written in Invoke-FbOobeHandoff STAGE 2 (after CBS
:: settles), not here. Writing it at specialize made Audit splash treat
:: Dell CloudExperienceHost / WWAHost "Just a moment" as OOBE overlay
:: and fight it for the whole update loop (dump BWT3CB4-1420-DellInc).

:: ?? Audit Mode auto-login arming (must happen before Reseal reboot) ?????
:: Empirical: <AutoLogon>/<UserAccounts> in oobeSystem don't reliably take
:: effect when Reseal Mode=Audit short-circuits OOBE. We bypass the pass
:: system entirely and write the Winlogon registry values + enable the
:: local Administrator with a blank password directly into the live OS.
:: Blank password is acceptable because the device is offline/airgapped
:: during the Audit Mode window; the technician sets a real password
:: during the OOBE handoff after sysprep.
call :LOG "Arming Audit Mode auto-login (Administrator / blank password / AutoLogonCount=5)"
call :ARM_AUTOLOGIN
if errorlevel 1 (
    call :LOG "WARN: Auto-login arming returned errors; Audit Mode auto-logon may not fire."
) else (
    call :LOG "Auto-login registry values written and Administrator account enabled."
)

set "FB_PS="
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "FB_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined FB_PS (
    call :LOG "ERROR: powershell.exe not found."
    goto :DONE
)
call :LOG "PowerShell: %FB_PS%"

if not exist "%FB_LOOP_PS%" (
    call :LOG "ERROR: Loop script missing: %FB_LOOP_PS%"
    goto :DONE
)

:: ?? Primary trigger: HKLM RunOnce ???????????????????????????????????????
:: Fires on first interactive logon. Audit Mode's auto-Administrator logon
:: is exactly that. The leading '!' in the value name keeps the entry
:: registered if the command exits non-zero (so a transient failure does
:: not silently disarm the autostart).
::
:: We use reg.exe (not PowerShell) here so we don't depend on the WMF
:: provider state during specialize. The bang-prefixed value name and
:: bang-prefixed value escapes within quoted command-line strings break
:: under EnableDelayedExpansion, so the RunOnce writes are done in a
:: nested DisableDelayedExpansion block.
call :LOG "Arming RunOnce primary trigger: %FB_RUNONCE_KEY%\^^!FirstBaseWuLoop"
call :ARM_RUNONCE_LOOP
set "FB_ARM_EC=!ERRORLEVEL!"
if !FB_ARM_EC! neq 0 (
    call :LOG "ERROR: [ARM] Failed to write RunOnce loop entry (errorlevel=!FB_ARM_EC!)."
    set "FB_ARM_STATUS=FAIL"
) else (
    call :LOG "OK: [ARM] RunOnce loop entry registered."
)

:: ?? Drop /TR launcher shims (2026-05-13.1700-no-interactive-prompts) ??
:: Eliminates the backslash-escaped-quote /TR pattern that historically
:: made schtasks parsing fragile across Windows builds. /TR now points
:: at a small .cmd shim with no quoting issues. We drop the shims BEFORE
:: the first schtasks /Create so each task creation sees a valid target.
call :LOG "Writing /TR launcher shims under %FB_ROOT%"
call :WRITE_LOOP_LAUNCHER
if errorlevel 1 (
    call :LOG "WARN: Failed to write loop launcher shim; ONSTART/ONLOGON tasks will skip."
    set "FB_LOOP_LAUNCHER_OK=0"
) else (
    call :LOG "Loop launcher shim written: %FB_LOOP_LAUNCHER%"
    set "FB_LOOP_LAUNCHER_OK=1"
)
call :WRITE_SPLASH_LAUNCHER
if errorlevel 1 (
    call :LOG "WARN: Failed to write splash launcher shim; splash ONLOGON task will skip."
    set "FB_SPLASH_LAUNCHER_OK=0"
) else (
    call :LOG "Splash launcher shim written: %FB_SPLASH_LAUNCHER%"
    set "FB_SPLASH_LAUNCHER_OK=1"
)
:: 2213d: drop the console fallback splash. Generated NOW so the
:: splash launcher (rewritten in 2213d to fire both WPF+console in
:: parallel) has a target to invoke. Independent of WPF success.
:: 2213i Bug W: write the render-helper PowerShell script BEFORE the
:: console splash batch so the batch's powershell -File target exists
:: when the splash first ticks; both files are idempotent.
call :WRITE_CONSOLE_RENDER_PS1
if errorlevel 1 (
    call :LOG "WARN: Failed to write console render helper script; console splash will render heartbeat only."
) else (
    call :LOG "Console render helper written: %FB_CONSOLE_RENDER%"
)
:: 2026.05.18.2213l Bug EE: console-splash single-instance helper. Must
:: be written BEFORE WRITE_CONSOLE_SPLASH so the generated batch's
:: powershell.exe -File target exists when the first sibling fires.
call :WRITE_CONSOLE_LOCK_PS1
if errorlevel 1 (
    call :LOG "WARN: Failed to write console lock helper script; console splash will skip dedupe (best-effort fallback)."
) else (
    call :LOG "Console lock helper written: %FB_CONSOLE_LOCK_PS1%"
)
call :WRITE_CONSOLE_SPLASH
if errorlevel 1 (
    call :LOG "WARN: Failed to write console fallback splash; WPF splash is the only visibility channel."
) else (
    call :LOG "Console fallback splash written: %FB_CONSOLE_SPLASH%"
)

:: ?? Backup trigger (ONSTART): SYSTEM, non-interactive, robust ???????????
:: 2026-05-13 trigger-resilience release: critical change is the post-
:: creation Set-ScheduledTask call below that flips StartWhenAvailable to
:: $true. Without that flag, an ONSTART trigger MISSED during early boot
:: (e.g. system was busy with WUA or in the early boot window when the
:: trigger fired) is silently skipped instead of being deferred to the
:: first available moment. Field evidence on the 2026-05-12 device showed
:: the box manually power-cycled and the loop never relaunched even
:: though the ONSTART task was registered - the trigger was missed and
:: skipped. /F forces overwrite if the task already exists. /RL HIGHEST
:: gives the task the elevated context it needs to call into Sysprep.
::
:: 2026-05-13.1700-no-interactive-prompts: /TR now points at the launcher
:: shim instead of an inline powershell.exe command line; every schtasks
:: call has "<nul" appended to redirect empty STDIN so even a future
:: prompt regression fails fast with EOF instead of hanging.
if "%FB_LOOP_LAUNCHER_OK%"=="0" goto :SKIP_ONSTART_TASK
:: 5.4.23: loop ONSTART DELAY 5s (was 30s) so WU starts while Windows
:: may still show Preparing your computer after a dirty reboot.
schtasks /Delete /TN "%FB_TASK%" /F >nul 2>&1 <nul
if "%FB_SELFTEST_MODE%"=="1" (
    schtasks /Query /TN "%FB_TASK%" >> "%FB_LOG%" 2>&1 <nul
    call :LOG "SELF-TEST: skipped schtasks /Create %FB_TASK% (would invoke /TR=%FB_LOOP_LAUNCHER%)"
) else (
    call :LOG "[ARM] CMD: schtasks /Create /TN %FB_TASK% /SC ONSTART /DELAY 0000:05 /RU SYSTEM /RL HIGHEST /F /TR %FB_LOOP_LAUNCHER%"
    schtasks /Create /TN "%FB_TASK%" /SC ONSTART /DELAY 0000:05 /RU SYSTEM /RL HIGHEST /F /TR "%FB_LOOP_LAUNCHER%" >> "%FB_LOG%" 2>&1 <nul
    set "FB_ARM_EC=!ERRORLEVEL!"
    if !FB_ARM_EC! neq 0 (
        call :LOG "WARN: [ARM] Failed to create %FB_TASK% (errorlevel=!FB_ARM_EC!) -- RunOnce/RunOnceEx/Run remain"
        set "FB_ARM_STATUS=FAIL"
    ) else (
        call :LOG "OK: [ARM] %FB_TASK% registered"
        call :LOG "Ensuring %FB_TASK% is enabled"
        schtasks /Change /TN "%FB_TASK%" /ENABLE >> "%FB_LOG%" 2>&1 <nul
        call :APPLY_ROBUST_TASK_SETTINGS "%FB_TASK%"
    )
)
:SKIP_ONSTART_TASK

:: ?? Backup trigger (ONLOGON): Administrators-scoped, robust ?????????????
:: Audit Mode auto-logs in as the local Administrator account (member of
:: BUILTIN\Administrators). Earlier builds set /RU SYSTEM here; SYSTEM has
:: no logon event so the trigger never fired. Scoping to Administrators
:: makes the trigger actually match the Audit auto-logon session.
:: /F forces overwrite. The post-create Set-ScheduledTask flips
:: StartWhenAvailable=$true (matching the ONSTART task) so a missed
:: logon trigger is deferred rather than silently dropped.
if "%FB_LOOP_LAUNCHER_OK%"=="0" goto :SKIP_ONLOGON_TASK
call :LOG "Arming Administrators ONLOGON backup task (/F overwrite, launcher shim)"
schtasks /Delete /TN "%FB_LOGON_TASK%" /F >nul 2>&1 <nul
if "%FB_SELFTEST_MODE%"=="1" (
    schtasks /Query /TN "%FB_LOGON_TASK%" >> "%FB_LOG%" 2>&1 <nul
    call :LOG "SELF-TEST: skipped schtasks /Create %FB_LOGON_TASK% (would invoke /TR=%FB_LOOP_LAUNCHER%)"
) else (
    call :LOG "[ARM] CMD: schtasks /Create /TN %FB_LOGON_TASK% /SC ONLOGON /RU BUILTIN\Administrators /RL HIGHEST /F /TR %FB_LOOP_LAUNCHER%"
    schtasks /Create /TN "%FB_LOGON_TASK%" /SC ONLOGON /RU "BUILTIN\Administrators" /RL HIGHEST /F /TR "%FB_LOOP_LAUNCHER%" >> "%FB_LOG%" 2>&1 <nul
    set "FB_ARM_EC=!ERRORLEVEL!"
    if !FB_ARM_EC! neq 0 (
        call :LOG "WARN: [ARM] Failed to create %FB_LOGON_TASK% (errorlevel=!FB_ARM_EC!) -- RunOnce/RunOnceEx/Run remain"
        set "FB_ARM_STATUS=FAIL"
    ) else (
        call :LOG "OK: [ARM] %FB_LOGON_TASK% registered"
        call :LOG "Ensuring %FB_LOGON_TASK% is enabled"
        schtasks /Change /TN "%FB_LOGON_TASK%" /ENABLE >> "%FB_LOG%" 2>&1 <nul
        call :APPLY_ROBUST_TASK_SETTINGS "%FB_LOGON_TASK%"
    )
)
:SKIP_ONLOGON_TASK

:: 5.4.14: sibling SYSTEM tasks that are NOT the in-flight loop TN.
:: Pre-reboot /Delete+/Create of WindowsUpdateLoop failed with E_FAIL
:: and left the next boot with no ONSTART loop (12:09 dumps).
if "%FB_LOOP_LAUNCHER_OK%"=="0" goto :SKIP_BOOT2_TASK
call :LOG "Arming SYSTEM ONSTART sibling %FB_TASK_BOOT2% (DELAY 20s, no /IT, launcher shim)"
if "%FB_SELFTEST_MODE%"=="1" (
    call :LOG "SELF-TEST: skipped schtasks /Create %FB_TASK_BOOT2%"
) else (
    call :LOG "[ARM] CMD: schtasks /Create /TN %FB_TASK_BOOT2% /SC ONSTART /DELAY 0000:20 /RU SYSTEM /RL HIGHEST /F /TR %FB_LOOP_LAUNCHER%"
    schtasks /Create /TN "%FB_TASK_BOOT2%" /SC ONSTART /DELAY 0000:20 /RU SYSTEM /RL HIGHEST /F /TR "%FB_LOOP_LAUNCHER%" >> "%FB_LOG%" 2>&1 <nul
    set "FB_ARM_EC=!ERRORLEVEL!"
    if !FB_ARM_EC! neq 0 (
        call :LOG "WARN: [ARM] Failed to create %FB_TASK_BOOT2% (errorlevel=!FB_ARM_EC!)"
    ) else (
        call :LOG "OK: [ARM] %FB_TASK_BOOT2% registered"
        schtasks /Change /TN "%FB_TASK_BOOT2%" /ENABLE >> "%FB_LOG%" 2>&1 <nul
        call :APPLY_ROBUST_TASK_SETTINGS "%FB_TASK_BOOT2%"
    )
)
:SKIP_BOOT2_TASK

if "%FB_LOOP_LAUNCHER_OK%"=="0" goto :SKIP_ANYLOGON_TASK
call :LOG "Arming SYSTEM ONLOGON sibling %FB_TASK_ANYLOGON% (DELAY 45s, no /IT, fires while CloudExperienceHost is up)"
if "%FB_SELFTEST_MODE%"=="1" (
    call :LOG "SELF-TEST: skipped schtasks /Create %FB_TASK_ANYLOGON%"
) else (
    call :LOG "[ARM] CMD: schtasks /Create /TN %FB_TASK_ANYLOGON% /SC ONLOGON /DELAY 0000:45 /RU SYSTEM /RL HIGHEST /F /TR %FB_LOOP_LAUNCHER%"
    schtasks /Create /TN "%FB_TASK_ANYLOGON%" /SC ONLOGON /DELAY 0000:45 /RU SYSTEM /RL HIGHEST /F /TR "%FB_LOOP_LAUNCHER%" >> "%FB_LOG%" 2>&1 <nul
    set "FB_ARM_EC=!ERRORLEVEL!"
    if !FB_ARM_EC! neq 0 (
        call :LOG "WARN: [ARM] Failed to create %FB_TASK_ANYLOGON% (errorlevel=!FB_ARM_EC!)"
    ) else (
        call :LOG "OK: [ARM] %FB_TASK_ANYLOGON% registered"
        schtasks /Change /TN "%FB_TASK_ANYLOGON%" /ENABLE >> "%FB_LOG%" 2>&1 <nul
        call :APPLY_ROBUST_TASK_SETTINGS "%FB_TASK_ANYLOGON%"
    )
)
:SKIP_ANYLOGON_TASK

:: ?? Layer 2: HKLM RunOnceEx\0001\FirstBaseWuLoop ????????????????????????
:: RunOnceEx is processed by the runonce service rather than the logon
:: shell directly, so it survives certain logon-cycle edge cases that
:: consume plain RunOnce. Same command line, different registry path.
call :LOG "Arming RunOnceEx backup trigger: %FB_RUNONCEEX_KEY%\FirstBaseWuLoop"
call :ARM_RUNONCEEX_LOOP
set "FB_ARM_EC=!ERRORLEVEL!"
if !FB_ARM_EC! neq 0 (
    call :LOG "WARN: [ARM] Failed to write RunOnceEx loop entry (errorlevel=!FB_ARM_EC!)."
    set "FB_ARM_STATUS=FAIL"
) else (
    call :LOG "OK: [ARM] RunOnceEx loop entry registered."
)

:: ?? Layer 3: HKLM Run\FirstBaseWuLoopRun + kickstart launcher ??????????
:: Persistent Run entry that re-fires on every interactive logon.
:: Points at FirstBaseWuLoopRun.cmd which checks for the completion
:: marker first - if present, the launcher self-deletes the Run entry
:: and exits, so once OOBE handoff lands the entry is gone. Until then,
:: every Audit-Mode logon retriggers the loop even if RunOnce / RunOnceEx
:: and the scheduled tasks have all somehow been disarmed.
call :LOG "Writing kickstart launcher: %FB_KICKSTART_LAUNCHER%"
call :WRITE_KICKSTART_LAUNCHER
if errorlevel 1 (
    call :LOG "WARN: Failed to write kickstart launcher; Run trigger may not fire."
) else (
    call :LOG "Kickstart launcher written."
)
call :LOG "Arming Run backup trigger: %FB_RUN_KEY%\FirstBaseWuLoopRun"
call :ARM_RUN_LOOP
set "FB_ARM_EC=!ERRORLEVEL!"
if !FB_ARM_EC! neq 0 (
    call :LOG "WARN: [ARM] Failed to write Run loop entry (errorlevel=!FB_ARM_EC!)."
    set "FB_ARM_STATUS=FAIL"
) else (
    call :LOG "OK: [ARM] Run loop entry registered."
)

:: ?? Splash UI: OnLogon task (direct launcher) + RunOnce backup ????????
if exist "%FB_ROOT%\FirstBase-NoSplash.flag" (
    call :LOG "FirstBase-NoSplash.flag present - splash trigger not armed"
    goto :SKIP_SPLASH
)
if not exist "%FB_SPLASH_PS%" (
    call :LOG "Show-UpdateProgress.ps1 missing - no splash trigger armed"
    goto :SKIP_SPLASH
)

:: ?? 2026.05.20.2213q splash trigger model (Bug MM, watcher restored) ??
:: PRIMARY (Layer 1.5): FirstBase\SplashWatcher SYSTEM ONSTART task ->
::                     FirstBaseSplashWatcher.ps1 polls for interactive
::                     explorer.exe (SessionId >= 1) every 1s, waits 3s
::                     for desktop stabilization, then fires schtasks
::                     /Run /TN FirstBase\UpdateSplash. Eliminates the
::                     Dell-specific OnLogon-vs-Explorer race observed
::                     in dump 1142 (5/19/2026) by deferring the splash
::                     /Run until AFTER Explorer is provably ready
::                     instead of firing 1s BEFORE it on OnLogon. This
::                     pattern was deliberately tried in 2213a/b/b1 and
::                     removed (per 2213c block above) because the
::                     SYSTEM watcher produced "fires with Last Result
::                     =0 but ZERO filesystem evidence" failures. The
::                     2213q version differs structurally from 2213b:
::                     (a) the watcher is a .ps1 invoked directly by
::                     scheduled task (not a .cmd shim around a .ps1),
::                     (b) it acquires a FileShare::None lock with a
::                     loud entry banner BEFORE any other work so a
::                     post-mortem can prove the script entered, (c)
::                     it logs every poll iteration to splash-watcher
::                     .log, (d) Defender is already pre-disabled in
::                     SetupComplete specialize pass (Bug DD onward)
::                     so the 2213a "Defender silently kills powershell
::                     before any side effect" failure mode does not
::                     apply. Lessons from 2213a/b are baked in.
:: Layer 2 (DEFINED):  FirstBase\UpdateSplash task is still defined
::                     pointing at FirstBaseSplashLauncher.cmd but has
::                     NO trigger - it is created with /SC ONCE /SD
::                     01/01/2099 /ST 00:00 so the task object exists
::                     for schtasks /Run /TN but never auto-fires. The
::                     watcher above is what /Runs it.
:: Layer 3 (BACKUP):   HKLM RunOnce !FirstBaseWuSplash unchanged.
::                     Doesn't fire reliably in audit mode but works
::                     if the device ever boots into a real interactive
::                     logon.
:: Layer 4 (FALLBACK): Loop self-launches splash via FirstBase\
::                     UpdateSplashLayer4 schtasks bridge if no splash
::                     evidence within 30s of loop startup. Implemented
::                     in Invoke-WindowsUpdateLoop.ps1, not here. This
::                     layer is the ONLY pre-2213q one with proven-on-
::                     device telemetry per F:\fb-dump-1255 evidence
::                     (splash-fallback.log line 1+2 createExit=0
::                     runExit=0 confirmed twice). Stays in place as
::                     belt-and-suspenders for the watcher failing.

call :LOG "Arming RunOnce splash trigger (Layer 3): %FB_RUNONCE_KEY%\^^!FirstBaseWuSplash"
call :ARM_RUNONCE_SPLASH
set "FB_ARM_EC=!ERRORLEVEL!"
if !FB_ARM_EC! neq 0 (
    call :LOG "WARN: [ARM] Failed to write RunOnce splash entry (errorlevel=!FB_ARM_EC!)."
) else (
    call :LOG "OK: [ARM] RunOnce splash entry registered."
)

:: Layer 2: FirstBase\UpdateSplash task -> launcher directly, NO TRIGGER.
:: 2026.05.20.2213q Bug MM: The OnLogon trigger that previously fired
:: this task is REMOVED. It was losing a race with explorer.exe startup
:: on Dell hardware (dump 1142, 5/19/2026): OnLogon fires ~1s BEFORE
:: explorer.exe becomes the interactive shell, so the launcher exited
:: 0 with no splash side effects. The task object is still created so
:: schtasks /Run /TN FirstBase\UpdateSplash works from the SplashWatcher
:: (and from Layer 4 UpdateSplashLayer4 / Layer 5 fallback), but it
:: never auto-fires on its own. /SC ONCE /SD 01/01/2099 /ST 00:00 is
:: the canonical "create-only, never-fires" pattern - schtasks /Create
:: requires a trigger so we give it one that effectively never expires
:: into reality.
:: 2026.05.20.2213w Bug OO: schtasks /Create MUST include /IT for this
:: task. Without /IT, a SYSTEM-initiated schtasks /Run (SplashWatcher)
:: runs in Session 0 (non-interactive); WPF + console launcher produce
:: no visible UI on the Audit desktop on first boot. Layer 4 already
:: used /IT; UpdateSplash now matches so the watcher PRIMARY path is
:: interactive-token correct on the first Audit boot after imaging.
if "%FB_SPLASH_LAUNCHER_OK%"=="0" goto :SKIP_SPLASH_TASK
set "FB_SPLASH_TASK_TR=%FB_SPLASH_LAUNCHER%"
call :LOG "Arming TRIGGERLESS splash task (Layer 2, /F overwrite, /IT interactive, /TR=%FB_SPLASH_TASK_TR%, /SC ONCE far-future placeholder - 2213q Bug MM + 2213w/2213x Bug OO /IT + 2213x Bug PP session bridge in watcher)"
schtasks /Delete /TN "%FB_SPLASH_TASK%" /F >nul 2>&1 <nul
if "%FB_SELFTEST_MODE%"=="1" (
    schtasks /Query /TN "%FB_SPLASH_TASK%" >> "%FB_LOG%" 2>&1 <nul
    call :LOG "SELF-TEST: skipped schtasks /Create %FB_SPLASH_TASK% (would invoke /TR=%FB_SPLASH_TASK_TR%)"
) else (
    call :LOG "[ARM] CMD: schtasks /Create /TN %FB_SPLASH_TASK% /SC ONCE /SD 01/01/2099 /ST 00:00 /RU BUILTIN\Administrators /RL HIGHEST /IT /F /TR %FB_SPLASH_TASK_TR%"
    schtasks /Create /TN "%FB_SPLASH_TASK%" /SC ONCE /SD 01/01/2099 /ST 00:00 /RU "BUILTIN\Administrators" /RL HIGHEST /IT /F /TR "%FB_SPLASH_TASK_TR%" >> "%FB_LOG%" 2>&1 <nul
    set "FB_ARM_EC=!ERRORLEVEL!"
    if !FB_ARM_EC! neq 0 (
        call :LOG "WARN: [ARM] Failed to create %FB_SPLASH_TASK% (errorlevel=!FB_ARM_EC!)"
    ) else (
        call :LOG "OK: [ARM] %FB_SPLASH_TASK% registered (triggerless / far-future /IT interactive; watcher fires via /Run)"
        call :LOG "Ensuring %FB_SPLASH_TASK% is enabled"
        schtasks /Change /TN "%FB_SPLASH_TASK%" /ENABLE >> "%FB_LOG%" 2>&1 <nul
        call :APPLY_ROBUST_TASK_SETTINGS "%FB_SPLASH_TASK%"
    )
)
:SKIP_SPLASH_TASK

:: 2026.05.20.2213q Bug MM: Layer 1.5 SYSTEM Explorer-presence watcher.
:: Creates FirstBase\SplashWatcher with trigger ONSTART, principal
:: SYSTEM, RunLevel HIGHEST, pointed at FirstBaseSplashWatcher.ps1.
:: The watcher polls for an interactive explorer.exe every 1s, waits
:: 3s for stabilization, then fires schtasks /Run /TN FirstBase\
:: UpdateSplash. Replaces the OnLogon trigger that was racing
:: Explorer startup on Dell hardware. The watcher script is dropped
:: under FB_ROOT by TechInstall.cmd Step 8b WU payload staging; if
:: missing here we skip creating the task and rely entirely on the
:: backup splash layers (Layer 3 RunOnce / Layer 4 UpdateSplashLayer4
:: / Layer 5 fallback). We invoke powershell.exe with -NoProfile
:: -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File
:: directly in /TR (no .cmd shim) because the watcher script itself
:: writes a loud entry log on EVERY invocation so a Dell post-mortem
:: can disambiguate "task fired but powershell died" from "task did
:: not fire" without needing the shim trace pattern.
if not exist "%FB_SPLASH_WATCHER_PS%" (
    call :LOG "WARN: SplashWatcher script missing at %FB_SPLASH_WATCHER_PS% - skipping SplashWatcher task creation. Backup layers (RunOnce + UpdateSplashLayer4) will be the only splash launch paths."
    goto :SKIP_SPLASH_WATCHER_TASK
)
call :LOG "Arming SYSTEM ONSTART SplashWatcher task (Layer 1.5, /F overwrite, /TR=powershell -File %FB_SPLASH_WATCHER_PS%) [2213q Bug MM]"
schtasks /Delete /TN "%FB_SPLASH_WATCHER_TASK%" /F >nul 2>&1 <nul
if "%FB_SELFTEST_MODE%"=="1" (
    schtasks /Query /TN "%FB_SPLASH_WATCHER_TASK%" >> "%FB_LOG%" 2>&1 <nul
    call :LOG "SELF-TEST: skipped schtasks /Create %FB_SPLASH_WATCHER_TASK% (would invoke /TR=powershell -File %FB_SPLASH_WATCHER_PS%)"
) else (
    call :LOG "[ARM] CMD: schtasks /Create /TN %FB_SPLASH_WATCHER_TASK% /SC ONSTART /DELAY 0000:05 /RU SYSTEM /RL HIGHEST /F /TR powershell -File %FB_SPLASH_WATCHER_PS%"
    schtasks /Create /TN "%FB_SPLASH_WATCHER_TASK%" /SC ONSTART /DELAY 0000:05 /RU SYSTEM /RL HIGHEST /F /TR "%FB_PS% -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%FB_SPLASH_WATCHER_PS%\"" >> "%FB_LOG%" 2>&1 <nul
    set "FB_ARM_EC=!ERRORLEVEL!"
    if !FB_ARM_EC! neq 0 (
        call :LOG "WARN: [ARM] Failed to create %FB_SPLASH_WATCHER_TASK% (errorlevel=!FB_ARM_EC!) - falling back to backup splash layers only"
    ) else (
        call :LOG "OK: [ARM] %FB_SPLASH_WATCHER_TASK% registered"
        call :LOG "Ensuring %FB_SPLASH_WATCHER_TASK% is enabled"
        schtasks /Change /TN "%FB_SPLASH_WATCHER_TASK%" /ENABLE >> "%FB_LOG%" 2>&1 <nul
        call :APPLY_ROBUST_TASK_SETTINGS "%FB_SPLASH_WATCHER_TASK%"
    )
)
:SKIP_SPLASH_WATCHER_TASK

if not exist "%FB_SPLASH_WATCHER_PS%" goto :SKIP_SPLASH_WATCHER_BOOT2
call :LOG "Arming SYSTEM ONSTART sibling %FB_SPLASH_WATCHER_BOOT2% (DELAY 20s)"
if "%FB_SELFTEST_MODE%"=="1" (
    call :LOG "SELF-TEST: skipped schtasks /Create %FB_SPLASH_WATCHER_BOOT2%"
) else (
    call :LOG "[ARM] CMD: schtasks /Create /TN %FB_SPLASH_WATCHER_BOOT2% /SC ONSTART /DELAY 0000:20 /RU SYSTEM /RL HIGHEST /F /TR powershell -File %FB_SPLASH_WATCHER_PS%"
    schtasks /Create /TN "%FB_SPLASH_WATCHER_BOOT2%" /SC ONSTART /DELAY 0000:20 /RU SYSTEM /RL HIGHEST /F /TR "%FB_PS% -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%FB_SPLASH_WATCHER_PS%\"" >> "%FB_LOG%" 2>&1 <nul
    set "FB_ARM_EC=!ERRORLEVEL!"
    if !FB_ARM_EC! neq 0 (
        call :LOG "WARN: [ARM] Failed to create %FB_SPLASH_WATCHER_BOOT2% (errorlevel=!FB_ARM_EC!)"
    ) else (
        call :LOG "OK: [ARM] %FB_SPLASH_WATCHER_BOOT2% registered"
        schtasks /Change /TN "%FB_SPLASH_WATCHER_BOOT2%" /ENABLE >> "%FB_LOG%" 2>&1 <nul
        call :APPLY_ROBUST_TASK_SETTINGS "%FB_SPLASH_WATCHER_BOOT2%"
    )
)
:SKIP_SPLASH_WATCHER_BOOT2

:SKIP_SPLASH

:: ?? [DEBUG] 2249: Hotkey watcher task — Ctrl+Shift+End forces OOBE handoff bypass ??
:: FirstBase\DebugHotkeyWatcher runs FirstBaseDebugHotkeyWatcher.ps1 on every
:: Audit Mode Administrator logon (ONLOGON /IT). The script polls GetAsyncKeyState
:: every 250ms for Ctrl+Shift+End held simultaneously for ~750ms (3 consecutive
:: polls). On confirmation it writes C:\ProgramData\FirstBase\.debug-force-oobe-handoff
:: and exits. Invoke-WindowsUpdateLoop.ps1 detects the flag at the top of each
:: main-loop iteration (Test-FbDebugForceOobeHandoff) and routes directly to
:: Invoke-FbOobeHandoff, bypassing the update scan/install pass entirely.
:: Invoke-FbPreSysprepScrub STEP 2 and STEP 4 delete the task and script before
:: sysprep so no artifact survives into OOBE.
:: Armed only in the first-pass section (Bug U fence 1 gate already passed above).
:: 2253: /RU "" (Interactive User logon type) is required. SetupComplete.cmd runs as
:: SYSTEM (session 0); without /RU "" the task inherits the SYSTEM principal and
:: also runs in session 0 where GetAsyncKeyState cannot detect user keypresses.
:: /RU "" creates an "Interactive User" logon type that executes in the user's
:: active session (session 1) so GetAsyncKeyState works correctly.
set "FB_DEBUG_HOTKEY_WATCHER_TASK=FirstBase\DebugHotkeyWatcher"
set "FB_DEBUG_HOTKEY_WATCHER_PS=%FB_ROOT%\FirstBaseDebugHotkeyWatcher.ps1"
if not exist "%FB_DEBUG_HOTKEY_WATCHER_PS%" (
    call :LOG "[DEBUG] 2249: WARN: DebugHotkeyWatcher script missing at %FB_DEBUG_HOTKEY_WATCHER_PS% - skipping task creation."
    goto :SKIP_DEBUG_HOTKEY_WATCHER_TASK
)
call :LOG "[DEBUG] 2249: Arming DebugHotkeyWatcher task (%FB_DEBUG_HOTKEY_WATCHER_TASK%) ONLOGON /IT /DELAY 0000:03"
schtasks /Delete /TN "%FB_DEBUG_HOTKEY_WATCHER_TASK%" /F >nul 2>&1 <nul
if "%FB_SELFTEST_MODE%"=="1" (
    schtasks /Query /TN "%FB_DEBUG_HOTKEY_WATCHER_TASK%" >> "%FB_LOG%" 2>&1 <nul
    call :LOG "SELF-TEST: skipped schtasks /Create %FB_DEBUG_HOTKEY_WATCHER_TASK% (would invoke /TR=powershell -File %FB_DEBUG_HOTKEY_WATCHER_PS%)"
) else (
    call :LOG "[ARM] [DEBUG] 2249 CMD: schtasks /Create /TN %FB_DEBUG_HOTKEY_WATCHER_TASK% /SC ONLOGON /IT /DELAY 0000:03 /RU (Interactive User) /F /TR powershell -File %FB_DEBUG_HOTKEY_WATCHER_PS%"
    schtasks /Create /TN "%FB_DEBUG_HOTKEY_WATCHER_TASK%" /TR "%FB_PS% -NonInteractive -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%FB_DEBUG_HOTKEY_WATCHER_PS%\"" /SC ONLOGON /IT /DELAY 0000:03 /RU "" /F >> "%FB_LOG%" 2>&1 <nul
    set "FB_ARM_EC=!ERRORLEVEL!"
    if !FB_ARM_EC! neq 0 (
        call :LOG "[DEBUG] 2249: WARN: [ARM] Failed to create %FB_DEBUG_HOTKEY_WATCHER_TASK% (errorlevel=!FB_ARM_EC!)"
    ) else (
        call :LOG "[DEBUG] 2249: OK: [ARM] %FB_DEBUG_HOTKEY_WATCHER_TASK% registered"
    )
)
:SKIP_DEBUG_HOTKEY_WATCHER_TASK

:: ?? 2026.05.19.2213p Bug LL: schtasks state dump (diagnostic-only) ?????
:: Capture the AT-CREATION-TIME definition (run-as user, run level, schedule,
:: action /TR, /IT flag, /F overwrite acknowledgement) of every FirstBase
:: scheduled task we just registered. Field evidence on Dell Latitude 7450
:: (dump 1136) showed FirstBase\UpdateSplash reporting Last Result=0 but
:: producing zero splash PIDs. We need an immutable record of how the task
:: was actually defined at the moment SetupComplete.cmd created it (versus
:: what the live system reports later, which may include post-creation
:: mutations by APPLY_ROBUST_TASK_SETTINGS or external tools). Append-only;
:: each SetupComplete invocation adds a fresh block with a timestamp banner.
:: Best-effort: if any individual schtasks /Query fails, the redirect
:: captures the error message and the next line continues.
call :LOG "Bug LL: dumping schtasks state for all FirstBase\* tasks to schtasks-firstbase-state.log"
set "FB_SCHTASKS_STATE_LOG=%FB_LOGDIR%\schtasks-firstbase-state.log"
(
    echo ============================================================
    echo === FirstBase schtasks state snapshot ^(post-create^) ===
    echo === Captured: %DATE% %TIME%
    echo === Host: %COMPUTERNAME%  User: %USERNAME%  Session: %SESSIONNAME%
    echo === SetupComplete.cmd / Bug LL diagnostic
    echo ============================================================
    echo.
    echo --- Task: %FB_TASK% ---
) >> "%FB_SCHTASKS_STATE_LOG%" 2>&1
schtasks /Query /TN "%FB_TASK%"        /V /FO LIST >> "%FB_SCHTASKS_STATE_LOG%" 2>&1 <nul
(
    echo.
    echo --- Task: %FB_LOGON_TASK% ---
) >> "%FB_SCHTASKS_STATE_LOG%" 2>&1
schtasks /Query /TN "%FB_LOGON_TASK%"  /V /FO LIST >> "%FB_SCHTASKS_STATE_LOG%" 2>&1 <nul
(
    echo.
    echo --- Task: %FB_TASK_BOOT2% ---
) >> "%FB_SCHTASKS_STATE_LOG%" 2>&1
schtasks /Query /TN "%FB_TASK_BOOT2%" /V /FO LIST >> "%FB_SCHTASKS_STATE_LOG%" 2>&1 <nul
(
    echo.
    echo --- Task: %FB_TASK_ANYLOGON% ---
) >> "%FB_SCHTASKS_STATE_LOG%" 2>&1
schtasks /Query /TN "%FB_TASK_ANYLOGON%" /V /FO LIST >> "%FB_SCHTASKS_STATE_LOG%" 2>&1 <nul
(
    echo.
    echo --- Task: %FB_SPLASH_TASK% ---
) >> "%FB_SCHTASKS_STATE_LOG%" 2>&1
schtasks /Query /TN "%FB_SPLASH_TASK%" /V /FO LIST >> "%FB_SCHTASKS_STATE_LOG%" 2>&1 <nul
(
    echo.
    echo --- Task: %FB_SPLASH_WATCHER_TASK% --- [2213q Bug MM]
) >> "%FB_SCHTASKS_STATE_LOG%" 2>&1
schtasks /Query /TN "%FB_SPLASH_WATCHER_TASK%" /V /FO LIST >> "%FB_SCHTASKS_STATE_LOG%" 2>&1 <nul
(
    echo.
    echo --- Task: %FB_SPLASH_WATCHER_BOOT2% ---
) >> "%FB_SCHTASKS_STATE_LOG%" 2>&1
schtasks /Query /TN "%FB_SPLASH_WATCHER_BOOT2%" /V /FO LIST >> "%FB_SCHTASKS_STATE_LOG%" 2>&1 <nul
(
    echo.
    echo --- Task: FirstBase\UpdateSplashLayer4 ---
    echo --- ^(NOTE: Layer 4 task is created by the loop, not by SetupComplete; expected absent here.^)
) >> "%FB_SCHTASKS_STATE_LOG%" 2>&1
schtasks /Query /TN "FirstBase\UpdateSplashLayer4" /V /FO LIST >> "%FB_SCHTASKS_STATE_LOG%" 2>&1 <nul
(
    echo.
    echo --- Task: %FB_DEBUG_HOTKEY_WATCHER_TASK% --- [DEBUG] 2249
) >> "%FB_SCHTASKS_STATE_LOG%" 2>&1
schtasks /Query /TN "%FB_DEBUG_HOTKEY_WATCHER_TASK%" /V /FO LIST >> "%FB_SCHTASKS_STATE_LOG%" 2>&1 <nul
(
    echo.
    echo === End of snapshot ===
    echo.
) >> "%FB_SCHTASKS_STATE_LOG%" 2>&1

:: NOTE: We deliberately do NOT call 'schtasks /Run' here. SetupComplete is
:: invoked from the specialize pass, BEFORE Reseal reboots the box into
:: Audit Mode. Launching the loop now would run in a stripped specialize
:: environment with no shell or networking, then get killed by the Audit
:: reboot (it produced a misleading "started successfully" log line in
:: prior builds). The RunOnce + ONLOGON triggers fire post-Audit-logon,
:: which is the only viable launch point.

:: ?? 2283-arm-verify Bug LL: post-creation verification pass ???????????????
:: Query each critical loop trigger to confirm it actually exists in the
:: scheduler / registry before declaring the arm succeeded.
:: FB_VERIFY_FAIL=1  -> at least one key loop trigger is absent; device
::                      will NOT run the update pipeline automatically.
:: FB_ARM_STATUS=FAIL -> at least one registration returned a nonzero exit
::                       code during arming (may be masked by schtasks output
::                       redirect; verification below is the authoritative check).
set "FB_VERIFY_FAIL=0"
call :LOG "[ARM-VERIFY] 2283: Verifying critical loop trigger registrations post-arm..."

schtasks /Query /TN "%FB_TASK%" >nul 2>&1 <nul
if errorlevel 1 (
    call :LOG "ERROR: [ARM-VERIFY] %FB_TASK% task NOT found after arm"
    set "FB_VERIFY_FAIL=1"
) else (
    call :LOG "OK: [ARM-VERIFY] %FB_TASK% task present"
)

schtasks /Query /TN "%FB_LOGON_TASK%" >nul 2>&1 <nul
if errorlevel 1 (
    call :LOG "ERROR: [ARM-VERIFY] %FB_LOGON_TASK% task NOT found after arm"
    set "FB_VERIFY_FAIL=1"
) else (
    call :LOG "OK: [ARM-VERIFY] %FB_LOGON_TASK% task present"
)

:: RunOnce value name is !FirstBaseWuLoop (bang prefix). Use a
:: DisableDelayedExpansion block so the literal ! survives the reg query.
setlocal DisableDelayedExpansion
reg query "%FB_RUNONCE_KEY%" /v "!FirstBaseWuLoop" >nul 2>&1 <nul
if errorlevel 1 (endlocal & set "FB_RUNONCE_VERIFY_EC=1") else (endlocal & set "FB_RUNONCE_VERIFY_EC=0")
if "!FB_RUNONCE_VERIFY_EC!"=="1" (
    call :LOG "ERROR: [ARM-VERIFY] !FirstBaseWuLoop RunOnce key NOT found after arm"
    set "FB_VERIFY_FAIL=1"
) else (
    call :LOG "OK: [ARM-VERIFY] !FirstBaseWuLoop RunOnce key present"
)

if "!FB_VERIFY_FAIL!"=="1" (
    call :LOG "ERROR: [ARM] 2283-arm-verify: One or more critical loop trigger registrations failed or are absent. FB_ARM_STATUS=!FB_ARM_STATUS!. Device will NOT run the update pipeline automatically. Inspect schtasks-firstbase-state.log and SetupComplete.log. Re-image may be required."
) else (
    call :LOG "OK: [ARM] 2283-arm-verify: All critical loop trigger layers verified present (FB_ARM_STATUS=!FB_ARM_STATUS!). Pipeline will run on next logon/startup."
)
call :LOG "Trigger summary: RunOnce=^^!FirstBaseWuLoop + RunOnceEx=FirstBaseWuLoop + Run=FirstBaseWuLoopRun + %FB_TASK% ONSTART/SYSTEM + %FB_LOGON_TASK% ONLOGON/Admins. Splash: %FB_SPLASH_WATCHER_TASK% SYSTEM ONSTART (watcher); %FB_SPLASH_TASK% TRIGGERLESS; HKLM RunOnce ^^!FirstBaseWuSplash; loop UpdateSplashLayer4 bridge. [DEBUG] 2249: %FB_DEBUG_HOTKEY_WATCHER_TASK% ONLOGON/IT. System will reboot to Audit Mode."

:: ?? 2295-hardening-reorder + PS-free MDM block ???????????????????????????????
:: Pre-reboot hardening runs in this order so the MOST IMPORTANT step (MDM
:: enrollment suppression) can never be lost:
::   1) SUPPRESS_MDM_ENROLLMENT  - PS-FREE (sc.exe + reg.exe). No child
::      powershell exists for Defender's fileless-attack heuristic to terminate,
::      so it always completes. Runs FIRST, before any bypass-policy PS.
::   2) DISABLE_DEFENDER         - turn real-time monitoring OFF before any
::      bypass-policy PowerShell runs below.
::   3) ADD_DEFENDER_EXCLUSION   - now safe (real-time already off).
::   4) BLOCK_AUTOPILOT_ENDPOINTS
::   5) SUPPRESS_RECOVERY_SCREEN
:: Every PS-based step (2,3,4) is launched through :RUN_PS_ISOLATED, which runs
:: powershell in a SEPARATE process tree via start /wait so that if Defender
:: terminates the child the kill cannot propagate up and abort SetupComplete.cmd.
:: Each hardening subroutine returns 0 unconditionally and the main flow falls
:: through on any WARN, so execution ALWAYS reaches :DONE / exit /b 0.
:: Root cause this fixes (dump PF4VGG7V-1423-Lenovo): the 2280 revision placed
:: ADD_DEFENDER_EXCLUSION FIRST, running a bypass-policy PS while Defender real-
:: time was still ON; Defender terminated the process tree (SetupComplete exited
:: 0xff) BEFORE the MDM block ever ran, so Intune/Autopilot enrolled the device
:: mid-pipeline and it landed at the Administrator password screen.
::
:: TEMPORARY: everything below is undone at the OOBE handoff by
:: FirstBaseOobeOperatorFinalize.ps1 (2277 MDM restore, 2280 exclusion + firewall
:: removal, 2284 recovery-screen restore). Do NOT permanently disable MDM.

:: 1) MDM enrollment suppression - PS-FREE (sc + reg), runs FIRST.
call :LOG "Suppressing MDM enrollment (DmEnrollmentSvc + registry policy, PS-free sc/reg, pre-audit-reboot, prevents Autopilot/Intune policy interference with pipeline)"
call :SUPPRESS_MDM_ENROLLMENT
if errorlevel 1 (
    call :LOG "WARN: MDM enrollment suppression returned non-zero; enrollment may still fire in Audit Mode."
) else (
    call :LOG "MDM enrollment suppression completed."
)

:: 2) Disable Defender real-time monitoring BEFORE any bypass-policy PowerShell.
:: (2213d) Field evidence proved the splash powershell launched by Layer 2 OnLogon
:: / Layer 4 bridge silently terminates before the loop's own Set-FbDefenderRealtime
:: can fire, because Defender's real-time scanner classifies powershell.exe
:: -ExecutionPolicy Bypass as a fileless-attack signature. Disabling HERE means the
:: exclusion/autopilot PS below (and the later splash PS) start with real-time
:: already off. Loop-side restore call sites stay intact - Defender is fully
:: restored at OOBE handoff / escape valve / Tier 7 panic / every exit.
call :LOG "Disabling Defender real-time monitoring (pre-audit-reboot, fixes splash powershell silent kill)"
call :DISABLE_DEFENDER
if errorlevel 1 (
    call :LOG "WARN: Defender pre-disable returned non-zero; splash powershell may still be killed by real-time scan. Loop-side disable will retry."
) else (
    call :LOG "Defender pre-disable completed."
)

:: 3) Add Defender path exclusions (real-time already off; Add-MpPreference is also
:: not blocked by Tamper Protection). Removed by FirstBaseOobeOperatorFinalize.ps1
:: (2280) before seal.
call :LOG "Adding Defender path exclusions for FirstBase directories (2280, pre-audit-reboot, prevents AMSI quarantine of payload scripts on Tamper Protection devices)"
call :ADD_DEFENDER_EXCLUSION
if errorlevel 1 (
    call :LOG "WARN: ADD_DEFENDER_EXCLUSION returned non-zero; Defender may still scan and quarantine FirstBase scripts on Tamper Protection devices."
) else (
    call :LOG "Defender path exclusions added for FirstBase directories."
)

:: 4) Block Autopilot enrollment endpoints via Windows Firewall OUTBOUND rules.
:: The WCOOBE / oobeldr.exe / msoobe.exe stack bypasses DmEnrollmentSvc suppression
:: and the AutoEnrollMDM keys entirely. login.microsoftonline.com and
:: portal.manage.microsoft.com are intentionally omitted (WU may use AAD auth
:: endpoints). Rule is removed by FirstBaseOobeOperatorFinalize.ps1 (2280).
call :LOG "Blocking Autopilot enrollment endpoints via Windows Firewall outbound rules (2280, pre-audit-reboot, prevents WCOOBE/oobeldr enrollment bypass of DmEnrollmentSvc suppression)"
call :BLOCK_AUTOPILOT_ENDPOINTS
if errorlevel 1 (
    call :LOG "WARN: BLOCK_AUTOPILOT_ENDPOINTS returned non-zero; Autopilot enrollment may still occur during the pipeline window."
) else (
    call :LOG "Autopilot enrollment endpoint firewall block rules added."
)

:: 5) Recovery-screen suppression (still before the audit reboot).
call :SUPPRESS_RECOVERY_SCREEN
if errorlevel 1 call :LOG "WARN: Recovery screen suppression returned non-zero; pipeline reboots may show recovery screen"

:DONE
call :LOG "SetupComplete exiting"
endlocal
exit /b 0

:: ?? Subroutines ?????????????????????????????????????????????????????????
:: Both RunOnce arming routines run with delayed expansion DISABLED so the
:: literal '!' characters in value names and command strings survive intact.

:ARM_RUNONCE_LOOP
setlocal DisableDelayedExpansion
reg add "%FB_RUNONCE_KEY%" /v "!FirstBaseWuLoop" /t REG_SZ /d "\"%FB_PS%\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%FB_LOOP_PS%\" -FinalizeToOobe" /f >> "%FB_LOG%" 2>&1 <nul
:: 2283-arm-verify: capture ERRORLEVEL before endlocal (parse-time %% expansion
:: captures the value NOW, before endlocal resets it, so exit /b sees the real code)
endlocal & exit /b %ERRORLEVEL%

:ARM_RUNONCE_SPLASH
:: 2026-05-13.2030-splash-interactive: drop -NonInteractive from
:: the splash command line. Show-UpdateProgress.ps1 is a WPF GUI
:: that requires an interactive PowerShell host - $window.ShowDialog()
:: silently fails under -NonInteractive ($ErrorActionPreference =
:: 'Continue' swallows the dispatcher exception). The loop process
:: keeps -NonInteractive (no UI), but the splash MUST be interactive
:: so the dashboard window can render.
:: -WindowStyle Hidden is safe here: it only hides the powershell.exe
:: host console; the WPF window is still rendered as a top-level
:: window.
:: 2026.05.13.2213c-onlogon-primary-and-defender-disable: the WPF
:: window is now WindowStyle=SingleBorderWindow, WindowState=
:: Maximized, Topmost=False with an F12 hotkey to toggle Topmost,
:: so it is fullscreen-windowed (not borderless+topmost) and the
:: tech can Alt+Tab / minimize / pin without using Ctrl+Alt+Del.
setlocal DisableDelayedExpansion
reg add "%FB_RUNONCE_KEY%" /v "!FirstBaseWuSplash" /t REG_SZ /d "\"%FB_PS%\" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%FB_SPLASH_PS%\"" /f >> "%FB_LOG%" 2>&1 <nul
endlocal & exit /b %ERRORLEVEL%

:ARM_RUNONCEEX_LOOP
:: RunOnceEx Layer 2 backup. Each subkey under RunOnceEx is a logical
:: group; values inside it are command lines. We use a single group
:: "0001" with one value "FirstBaseWuLoop" and the same command line as
:: the RunOnce primary. No '!' prefix here - RunOnceEx values do not
:: have the keep-on-nonzero-exit semantics RunOnce does.
setlocal DisableDelayedExpansion
reg add "%FB_RUNONCEEX_KEY%" /v "FirstBaseWuLoop" /t REG_SZ /d "\"%FB_PS%\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%FB_LOOP_PS%\" -FinalizeToOobe" /f >> "%FB_LOG%" 2>&1 <nul
endlocal & exit /b %ERRORLEVEL%

:ARM_RUN_LOOP
:: Run Layer 3 backup. Persistent Run entry; fires on every interactive
:: logon. Command line is cmd.exe /c <kickstart launcher> so the
:: launcher's completion-marker self-cleanup logic runs first. The
:: launcher self-deletes the Run entry once C:\Windows\Setup\Scripts\
:: FirstBase-Updates-Complete.flag is on disk.
setlocal DisableDelayedExpansion
reg add "%FB_RUN_KEY%" /v "FirstBaseWuLoopRun" /t REG_SZ /d "\"%SystemRoot%\System32\cmd.exe\" /c \"%FB_KICKSTART_LAUNCHER%\"" /f >> "%FB_LOG%" 2>&1 <nul
endlocal & exit /b %ERRORLEVEL%

:WRITE_KICKSTART_LAUNCHER
:: Drop %FB_KICKSTART_LAUNCHER% on disk. The launcher batch is what
:: HKLM\Run\FirstBaseWuLoopRun fires on every interactive logon. It:
::   1. Checks for C:\Windows\Setup\Scripts\FirstBase-Updates-Complete.flag.
::      If present, self-deletes the Run-key entry and exits. This stops
::      the entry from re-firing post-OOBE-handoff.
::   2. Otherwise launches the same powershell.exe command line as
::      RunOnce / RunOnceEx / scheduled tasks, via 'start ""' so the
::      launcher does not block on the loop.
:: We DisableDelayedExpansion around the heredoc-equivalent so any
:: literal '!' or '%' characters survive intact.
setlocal DisableDelayedExpansion
> "%FB_KICKSTART_LAUNCHER%" echo @echo off
>> "%FB_KICKSTART_LAUNCHER%" echo :: FirstBase Windows Update kickstart launcher
>> "%FB_KICKSTART_LAUNCHER%" echo :: Auto-generated by SetupComplete.cmd / WRITE_KICKSTART_LAUNCHER.
>> "%FB_KICKSTART_LAUNCHER%" echo :: Fired by HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\FirstBaseWuLoopRun
>> "%FB_KICKSTART_LAUNCHER%" echo :: on every interactive logon. Self-deletes when the completion marker
>> "%FB_KICKSTART_LAUNCHER%" echo :: is present so the entry does not re-fire after OOBE handoff.
>> "%FB_KICKSTART_LAUNCHER%" echo setlocal EnableExtensions
>> "%FB_KICKSTART_LAUNCHER%" echo.
>> "%FB_KICKSTART_LAUNCHER%" echo set "FB_COMPLETE_MARKER=%FB_COMPLETE_MARKER%"
>> "%FB_KICKSTART_LAUNCHER%" echo if exist "%%FB_COMPLETE_MARKER%%" ^(
>> "%FB_KICKSTART_LAUNCHER%" echo     reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "FirstBaseWuLoopRun" /f ^>nul 2^>^&1
>> "%FB_KICKSTART_LAUNCHER%" echo     endlocal
>> "%FB_KICKSTART_LAUNCHER%" echo     exit /b 0
>> "%FB_KICKSTART_LAUNCHER%" echo ^)
>> "%FB_KICKSTART_LAUNCHER%" echo.
>> "%FB_KICKSTART_LAUNCHER%" echo start "" "%FB_PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%FB_LOOP_PS%" -FinalizeToOobe
>> "%FB_KICKSTART_LAUNCHER%" echo endlocal
>> "%FB_KICKSTART_LAUNCHER%" echo exit /b 0
endlocal & exit /b

:APPLY_ROBUST_TASK_SETTINGS
:: Post-create Set-ScheduledTask to flip StartWhenAvailable=$true,
:: MultipleInstances=IgnoreNew, ExecutionTimeLimit=0 (no limit), and
:: the battery-permissive flags. schtasks.exe /Create cannot set
:: StartWhenAvailable directly; we have to round-trip through the
:: PowerShell ScheduledTasks module. Without StartWhenAvailable the
:: ONSTART task silently skips a missed trigger - the exact failure
:: mode observed on 2026-05-12.
::
:: %~1 is the task name in 'Folder\Leaf' form (e.g.
:: 'FirstBase\WindowsUpdateLoop'). The PowerShell helper splits it
:: into -TaskPath '\Folder\' and -TaskName 'Leaf'.
::
:: 2026-05-13.1700-no-interactive-prompts:
::   Previous implementation:
::     Get-ScheduledTask ... -ErrorAction Stop | Set-ScheduledTask ...
::   That construct prompts the cmd console with "TaskName:" when
::   Get-ScheduledTask throws (e.g. because the task is not yet visible
::   to the CIM provider) because Set-ScheduledTask is bound to the
::   pipeline with a mandatory -TaskName that has no value. Empirically
::   reproduced on this developer machine.
::
::   New implementation:
::     1. powershell.exe runs with -NoProfile -NonInteractive
::        -ExecutionPolicy Bypass. -NonInteractive makes mandatory
::        prompts FAIL FAST with a parameter-binding exception rather
::        than waiting for STDIN.
::     2. The cmd-side invocation appends "<nul" so STDIN is EOF.
::        Belt-and-braces against any future regression that bypasses
::        -NonInteractive.
::     3. The inline -Command body wraps EVERYTHING in a single
::        try/catch and uses an EXPLICIT null/empty guard on $leaf and
::        on the Get-ScheduledTask result before calling
::        Set-ScheduledTask. Get and Set are SEPARATE statements with
::        a variable in between - no pipeline binding to a mandatory
::        parameter is involved.
::     4. The body never references any cmd metacharacter that would
::        survive cmd's "..." quoting (no '&', no '|' outside the
::        single-quoted PowerShell strings, no '<', no '>').
::     5. -split on '\\' is replaced with String.LastIndexOf('\') +
::        Substring(); no regex, no array indexing, no chance of
::        producing a null leaf from a string the cmd parser already
::        validated.
::     6. In SELF-TEST mode the PS body only parses + logs;
::        Get-ScheduledTask is never invoked. Lets a tech run
::        SetupComplete.cmd on a dev box without touching task scheduler.
setlocal DisableDelayedExpansion
set "FB_TN_FULL=%~1"
set "FB_APPLY_MODE=apply"
if "%FB_SELFTEST_MODE%"=="1" set "FB_APPLY_MODE=dryrun"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try { $tn = '%FB_TN_FULL%'; $mode = '%FB_APPLY_MODE%'; if ([string]::IsNullOrEmpty($tn)) { Write-Output 'WARN: empty task name passed to APPLY_ROBUST_TASK_SETTINGS; nothing to do'; exit 0 }; $idx = $tn.LastIndexOf([char]92); if ($idx -lt 0) { $path = [char]92; $leaf = $tn } else { $path = [char]92 + $tn.Substring(0, $idx) + [char]92; $leaf = $tn.Substring($idx + 1) }; if ([string]::IsNullOrEmpty($leaf)) { Write-Output ('WARN: empty leaf parsed from ' + $tn + '; skipping'); exit 0 }; if ($mode -eq 'dryrun') { Write-Output ('DRYRUN: would Set-ScheduledTask TaskPath=' + $path + ' TaskName=' + $leaf + ' StartWhenAvailable=true MultipleInstances=IgnoreNew ExecutionTimeLimit=0 battery-permissive'); exit 0 }; $task = Get-ScheduledTask -TaskPath $path -TaskName $leaf -ErrorAction SilentlyContinue; if ($null -eq $task) { Write-Output ('WARN: task not found by Get-ScheduledTask (TaskPath=' + $path + ' TaskName=' + $leaf + '); schtasks-only settings remain in effect'); exit 0 }; $s = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 0) -MultipleInstances IgnoreNew; Set-ScheduledTask -TaskPath $path -TaskName $leaf -Settings $s -ErrorAction Stop | Out-Null; Write-Output ('OK: ' + $tn + ' StartWhenAvailable=true MultipleInstances=IgnoreNew ExecutionTimeLimit=0 battery-permissive') } catch { Write-Output ('WARN: ' + '%FB_TN_FULL%' + ' Set-ScheduledTask threw: ' + $_.Exception.Message) }" <nul >> "%FB_LOG%" 2>&1
endlocal & exit /b 0

:WRITE_LOOP_LAUNCHER
:: Drop the loop launcher shim (%FB_LOOP_LAUNCHER%). schtasks /TR
:: targets this file instead of an inline powershell.exe command, so
:: the /TR argument is a plain unquoted path with no backslash-escape
:: complexity. The shim launches the same powershell.exe command line
:: as RunOnce / RunOnceEx / the kickstart launcher.
::
:: We DisableDelayedExpansion around the heredoc-equivalent so any
:: literal '!' or '%' in the body survives intact. The shim itself
:: also enables delayed expansion only for its own state, not for
:: the substitutions done at write-time here.
setlocal DisableDelayedExpansion
> "%FB_LOOP_LAUNCHER%" echo @echo off
>> "%FB_LOOP_LAUNCHER%" echo :: FirstBase Windows Update loop launcher (schtasks /TR target)
>> "%FB_LOOP_LAUNCHER%" echo :: Auto-generated by SetupComplete.cmd / WRITE_LOOP_LAUNCHER.
>> "%FB_LOOP_LAUNCHER%" echo :: 2026-05-13.1700-no-interactive-prompts: eliminates the inline
>> "%FB_LOOP_LAUNCHER%" echo :: powershell.exe command line in /TR (and its backslash-quote
>> "%FB_LOOP_LAUNCHER%" echo :: escape complexity) by routing the task through a fixed-path .cmd.
>> "%FB_LOOP_LAUNCHER%" echo setlocal EnableExtensions
>> "%FB_LOOP_LAUNCHER%" echo "%FB_PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%FB_LOOP_PS%" -FinalizeToOobe
>> "%FB_LOOP_LAUNCHER%" echo endlocal
>> "%FB_LOOP_LAUNCHER%" echo exit /b %%ERRORLEVEL%%
if not exist "%FB_LOOP_LAUNCHER%" (
    endlocal & exit /b 1
)
endlocal & exit /b 0

:WRITE_SPLASH_LAUNCHER
:: Drop the splash launcher shim (%FB_SPLASH_LAUNCHER%). schtasks /TR
:: targets this file instead of an inline powershell.exe command. The
:: shim launches Show-UpdateProgress.ps1.
::
:: 2214i: splash launcher no longer spawns FirstBaseConsoleSplash.cmd
:: (console fallback). Field runs showed an extra cmd.exe console
:: competing with OOBE / splash focus; WPF + FirstBaseSplashSingleInstance
:: remain the only auto-launched splash path. Console batch + PS1
:: helpers are still written for optional manual use.
::
:: 2026.05.18.2213l Bug EE: route the WPF splash invocation through
:: FirstBaseSplashSingleInstance.ps1 instead of calling Show-Update
:: Progress.ps1 directly. The wrapper holds a FileShare::None lock
:: on splash-launcher.lock so Layer 2 (OnLogon task) and Layer 4
:: (loop-spawned schtasks bridge) cannot both spawn duplicate WPF
:: windows when they fire within the same boot. Show-UpdateProgress
:: .ps1 itself is FROZEN (SHA pinned) and is invoked unchanged INSIDE
:: the wrapper after the lock is acquired.
::
:: 2026.05.19.2213p Bug LL: diagnostic trace instrumentation. The
:: generated launcher .cmd writes marker lines to splash-launcher-trace.log
:: (entry / setlocal-ok / wrapper-ps1 / exit). On Dell Latitude
:: 7450 (dump 1136) FirstBase\UpdateSplash reports Last Result=0
:: (cmd.exe says it ran the launcher to completion) but produces no
:: splash-launcher-instances.log entries, no splash-ui.log, and no
:: splash PIDs anywhere. The trace log will distinguish:
::   (a) launcher .cmd never executed     -> NO trace lines at all
::   (b) launcher .cmd entered but died   -> SOME trace lines, abrupt cut-off
::   (c) launcher .cmd ran to completion  -> ALL trace lines, exit code recorded
:: Each trace line includes %%DATE%% %%TIME%% (timestamp at launcher run
:: time, NOT at echo-generation time -- the %% doubles in the source so
:: the GENERATED batch contains literal %DATE% / %TIME% which expand at
:: runtime), %%RANDOM%% (per-invocation salt so concurrent launcher PIDs
:: are distinguishable), and the standard environment-probe variables
:: (%%USERNAME%%, %%USERDOMAIN%%, %%SESSIONNAME%%, %%PROCESSOR_ARCHITECTURE%%).
:: Failures of the trace append (e.g. log dir missing) are silently
:: swallowed by `2^>nul` so the trace itself is best-effort and never
:: breaks the actual launcher logic.
setlocal DisableDelayedExpansion
:: Pre-compute the trace log path literal so every echo line stays clean.
set "FB_SPLASH_TRACE_LOG=C:\Windows\Setup\FirstBase\Logs\splash-launcher-trace.log"
> "%FB_SPLASH_LAUNCHER%" echo @echo off
>> "%FB_SPLASH_LAUNCHER%" echo :: FirstBase Windows Update splash launcher (schtasks /TR target)
>> "%FB_SPLASH_LAUNCHER%" echo :: Auto-generated by SetupComplete.cmd / WRITE_SPLASH_LAUNCHER.
>> "%FB_SPLASH_LAUNCHER%" echo :: 2026-05-13.1700-no-interactive-prompts: eliminates the inline
>> "%FB_SPLASH_LAUNCHER%" echo :: powershell.exe command line in /TR (and its backslash-quote
>> "%FB_SPLASH_LAUNCHER%" echo :: escape complexity) by routing the task through a fixed-path .cmd.
>> "%FB_SPLASH_LAUNCHER%" echo :: 2026-05-13.2030-splash-interactive: NO -NonInteractive
>> "%FB_SPLASH_LAUNCHER%" echo :: flag - Show-UpdateProgress.ps1 is WPF and needs an
>> "%FB_SPLASH_LAUNCHER%" echo :: interactive host or ShowDialog silently fails.
>> "%FB_SPLASH_LAUNCHER%" echo :: 2214i: launches WPF splash only ^(no console fallback start^).
>> "%FB_SPLASH_LAUNCHER%" echo :: FirstBaseConsoleSplash.cmd is not auto-started from this shim.
>> "%FB_SPLASH_LAUNCHER%" echo :: 2026.05.18.2213l Bug EE: route WPF splash through
>> "%FB_SPLASH_LAUNCHER%" echo :: FirstBaseSplashSingleInstance.ps1 wrapper for dedupe lock.
>> "%FB_SPLASH_LAUNCHER%" echo :: 2026.05.19.2213p Bug LL: trace every major step to splash-launcher-trace.log.
>> "%FB_SPLASH_LAUNCHER%" echo set "FB_LT=%FB_SPLASH_TRACE_LOG%"
>> "%FB_SPLASH_LAUNCHER%" echo set "FB_LSALT=%%RANDOM%%"
>> "%FB_SPLASH_LAUNCHER%" echo ^>^> "%%FB_LT%%" echo [%%DATE%% %%TIME%%] [salt=%%FB_LSALT%%] [arch=%%PROCESSOR_ARCHITECTURE%%] [user=%%USERDOMAIN%%\%%USERNAME%%] [session=%%SESSIONNAME%%] [cd=%%CD%%] launcher entered
>> "%FB_SPLASH_LAUNCHER%" echo setlocal EnableExtensions
>> "%FB_SPLASH_LAUNCHER%" echo ^>^> "%%FB_LT%%" echo [%%DATE%% %%TIME%%] [salt=%%FB_LSALT%%] launcher: setlocal EnableExtensions OK; console fallback launch disabled ^(2214i^); about to spawn wrapper PS1
>> "%FB_SPLASH_LAUNCHER%" echo ^>^> "%%FB_LT%%" echo [%%DATE%% %%TIME%%] [salt=%%FB_LSALT%%] launcher: invoking "%FB_PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%FB_SPLASH_WRAPPER_PS%"
>> "%FB_SPLASH_LAUNCHER%" echo "%FB_PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%FB_SPLASH_WRAPPER_PS%"
>> "%FB_SPLASH_LAUNCHER%" echo set "FB_LRC=%%ERRORLEVEL%%"
>> "%FB_SPLASH_LAUNCHER%" echo ^>^> "%%FB_LT%%" echo [%%DATE%% %%TIME%%] [salt=%%FB_LSALT%%] launcher: wrapper PS1 returned errorlevel=%%FB_LRC%%; about to endlocal+exit
>> "%FB_SPLASH_LAUNCHER%" echo endlocal
>> "%FB_SPLASH_LAUNCHER%" echo exit /b %%FB_LRC%%
if not exist "%FB_SPLASH_LAUNCHER%" (
    endlocal & exit /b 1
)
endlocal & exit /b 0

:WRITE_CONSOLE_SPLASH
:: 2213d: drop the console fallback splash batch (%FB_CONSOLE_SPLASH%).
:: 2026.05.19.2213m Bug EE-3: the cmd-side :LOOP refresh body has moved
:: into the PowerShell helper (%FB_CONSOLE_LOCK_PS1%) so the lock holder
:: and the renderer are the SAME process; the FileShare::None handle stays
:: alive for the full splash lifetime. This cmd file is now a thin
:: launcher that invokes the helper synchronously and exits when the
:: helper exits.
::
:: Pre-2213m the cmd batch ran its own LOOP (cls + render + timeout 2) and
:: only consulted PowerShell as a one-shot helper for the lock stamp.
:: Dump 651 showed two ACQUIRE lines 4 seconds apart - the stamp scheme
:: did NOT actually prevent a sibling launcher invocation from claiming
:: the lock. The 2213m design uses [System.IO.File]::Open with
:: FileShare::None inside the helper, which IS bulletproof, but it
:: requires the helper process to stay alive for the splash lifetime.
:: Moving the refresh body into PowerShell achieves that.
::
:: Notable cmd metacharacter escapes used below when echoing this body:
::   %%   -> literal %
::   ^>   -> literal >
::   ^<   -> literal <
::   ^&   -> literal &
::   ^|   -> literal |
::   ^(   ^)  -> literal parens
setlocal DisableDelayedExpansion
> "%FB_CONSOLE_SPLASH%" echo @echo off
>> "%FB_CONSOLE_SPLASH%" echo :: FirstBase console fallback splash ^(thin launcher^).
>> "%FB_CONSOLE_SPLASH%" echo :: Auto-generated by SetupComplete.cmd / WRITE_CONSOLE_SPLASH ^(2213m Bug EE-3^).
>> "%FB_CONSOLE_SPLASH%" echo :: All rendering + lock-hold logic lives in FirstBaseConsoleSplashInstance.ps1.
>> "%FB_CONSOLE_SPLASH%" echo :: This batch just invokes that helper and exits when it returns. Sibling
>> "%FB_CONSOLE_SPLASH%" echo :: invocations land on a FileShare::None IOException inside the helper and
>> "%FB_CONSOLE_SPLASH%" echo :: exit cleanly without spawning a duplicate console window.
>> "%FB_CONSOLE_SPLASH%" echo setlocal EnableExtensions
>> "%FB_CONSOLE_SPLASH%" echo chcp 65001 ^>nul 2^>^&1
>> "%FB_CONSOLE_SPLASH%" echo color 0F
>> "%FB_CONSOLE_SPLASH%" echo mode con: cols=120 lines=35
>> "%FB_CONSOLE_SPLASH%" echo title FirstBase Updates ^(Console Fallback^)
>> "%FB_CONSOLE_SPLASH%" echo powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%FB_CONSOLE_LOCK_PS1%"
>> "%FB_CONSOLE_SPLASH%" echo set "FB_CONSOLE_EXIT=%%ERRORLEVEL%%"
>> "%FB_CONSOLE_SPLASH%" echo endlocal ^& exit /b %%FB_CONSOLE_EXIT%%
if not exist "%FB_CONSOLE_SPLASH%" (
    endlocal & exit /b 1
)
endlocal & exit /b 0

:WRITE_CONSOLE_RENDER_PS1
:: 2026.05.13.2213i Bug W: standalone PowerShell render helper for the
:: console fallback splash. Loaded via powershell.exe -File from
:: FirstBaseConsoleSplash.cmd so there is NO cmd-side parsing of the
:: PowerShell body and NO -Command string to escape. Reads
:: %FB_STATUS% (wu-status.json), pretty-prints phase / message /
:: updates. Failure is non-fatal (caller continues the LOOP).
::
:: Why -File and not -Command. The prior 2213d implementation embedded
:: this entire body as the -Command argument to powershell.exe and
:: emitted it from a single 'echo' line inside an 'if exist (...)'
:: block. Two interacting bugs in that path:
::   (1) The intended regex '\|' was written '\^|' in source so cmd
::       would consume the ^ during echo; because the surrounding
::       -Command string was double-quoted, cmd preserved the ^ and
::       the GENERATED batch contained '\^|' literally. In regex
::       that's "literal ^ OR empty" - alternation on empty string
::       splits between every pair of characters, breaking message
::       rendering and producing PowerShell parser noise visible on
::       the console as "There seems to be a token error on
::       'Updates' foreach".
::   (2) cmd's parenthesised (...) block parser handles ^-escapes and
::       embedded parens differently than top-level parsing; the
::       inline -Command body had its own (...) for foreach groups
::       and its own ^| pipe escapes, which drifted across LOOP
::       re-executions and occasionally fed PowerShell a malformed
::       command line.
:: A standalone .ps1 file invoked via -File is loaded as a script;
:: every character in the file goes to PowerShell verbatim. No cmd
:: escape accounting, no parenthesised-block parsing interaction.
::
:: Notable cmd metacharacter escapes used when echoing this body:
::   %%   -> literal %
::   ^|   -> literal | (pipe)
::   ^>   -> literal > (redirect)
::   ^<   -> literal < (redirect)
::   ^&   -> literal & (separator)
::   ^(   -> literal ( (group)
::   ^)   -> literal ) (group)
::   ^^   -> literal ^ (escape)
:: All -Command flags and quoting are GONE from the generated file.
:: We use ASCII-only single quotes and double quotes (no smart
:: quotes) to keep cmd's parser happy.
setlocal DisableDelayedExpansion
> "%FB_CONSOLE_RENDER%" echo # FirstBase console fallback splash render helper.
>> "%FB_CONSOLE_RENDER%" echo # Auto-generated by SetupComplete.cmd / WRITE_CONSOLE_RENDER_PS1 (2213i Bug W).
>> "%FB_CONSOLE_RENDER%" echo # Reads %%FB_STATUS%% (wu-status.json) and pretty-prints phase / message / updates.
>> "%FB_CONSOLE_RENDER%" echo $ErrorActionPreference = 'Continue'
>> "%FB_CONSOLE_RENDER%" echo try {
>> "%FB_CONSOLE_RENDER%" echo     $j = Get-Content -LiteralPath $env:FB_STATUS -Raw -ErrorAction Stop ^| ConvertFrom-Json -ErrorAction Stop
>> "%FB_CONSOLE_RENDER%" echo     Write-Host ^('Phase:    ' + [string]$j.phase^)
>> "%FB_CONSOLE_RENDER%" echo     Write-Host ^('Updated:  ' + [string]$j.updatedAt^)
>> "%FB_CONSOLE_RENDER%" echo     Write-Host ''
>> "%FB_CONSOLE_RENDER%" echo     Write-Host 'Message:'
>> "%FB_CONSOLE_RENDER%" echo     foreach ^($m in ^([string]$j.message -split '\^|'^)^) {
>> "%FB_CONSOLE_RENDER%" echo         Write-Host ^('  ' + $m.Trim^(^)^)
>> "%FB_CONSOLE_RENDER%" echo     }
>> "%FB_CONSOLE_RENDER%" echo     if ^($j.updates^) {
>> "%FB_CONSOLE_RENDER%" echo         Write-Host ''
>> "%FB_CONSOLE_RENDER%" echo         Write-Host 'Updates:'
>> "%FB_CONSOLE_RENDER%" echo         foreach ^($u in @^($j.updates ^| Select-Object -First 12^)^) {
>> "%FB_CONSOLE_RENDER%" echo             $t = [string]$u.Title
>> "%FB_CONSOLE_RENDER%" echo             if ^(-not $t^) { $t = [string]$u.Id }
>> "%FB_CONSOLE_RENDER%" echo             if ^($t.Length -gt 80^) { $t = $t.Substring^(0,77^) + '...' }
>> "%FB_CONSOLE_RENDER%" echo             Write-Host ^('  [' + [string]$u.Status + '] ' + $t^)
>> "%FB_CONSOLE_RENDER%" echo         }
>> "%FB_CONSOLE_RENDER%" echo     }
>> "%FB_CONSOLE_RENDER%" echo } catch {
>> "%FB_CONSOLE_RENDER%" echo     Write-Host ^('Could not read status: ' + $_.Exception.Message^)
>> "%FB_CONSOLE_RENDER%" echo }
if not exist "%FB_CONSOLE_RENDER%" (
    endlocal & exit /b 1
)
endlocal & exit /b 0

:WRITE_CONSOLE_LOCK_PS1
:: 2026.05.18.2213l Bug EE: standalone PowerShell helper for console-splash
:: single-instance dedupe.
:: 2026.05.19.2213m Bug EE-3: replaced 30-second stamp scheme with a true
:: FileShare::None hold pattern identical to FirstBaseSplashSingleInstance
:: .ps1 (the WPF splash wrapper).
::
:: Why the 2213l stamp scheme regressed (dump 651 console-splash-instances
:: .log):
::   [2026-05-19T06:25:44] [ACQUIRE] [pid=7260] stamped console-splash.lock
::   [2026-05-19T06:25:48] [ACQUIRE] [pid=10076] stamped console-splash.lock
:: Two ACQUIRE 4 seconds apart - meaning the 30-second freshness window did
:: not gate the second invocation. Root cause: the prior helper was a
:: one-shot stamp + exit. The cmd-side :LOOP body in FirstBaseConsoleSplash
:: .cmd kept the cmd PID alive but did NOT keep the lock-stamp fresh
:: because the helper had already exited. By the time pid=10076 fired,
:: pid=7260's stamp may have been within the window OR Get-Process may
:: have returned a slightly different process snapshot, OR the stamp file
:: write+read race fell on the wrong side. None of those are bulletproof.
::
:: 2213m design: this PS1 helper IS the console splash. It opens
:: console-splash.lock via [System.IO.File]::Open(..., FileShare::None)
:: and HOLDS the file handle for the entire lifetime of the splash. The
:: handle is the synchronization primitive: any sibling PS invocation
:: hitting File.Open on the same path gets IOException ("the process
:: cannot access the file because it is being used by another process")
:: regardless of account identity or stamp staleness. The PS1 then runs
:: the 2-second refresh loop (the work the cmd batch :LOOP used to do)
:: while the handle is held; when the loop exits (done-marker / complete
:: marker / Ctrl+C) the finally{} block releases the handle and the next
:: launcher invocation can claim it.
::
:: FirstBaseConsoleSplash.cmd is reduced to a thin wrapper that invokes
:: this PS1 with -File and exits when it returns. cmd no longer drives
:: the render loop, so the synchronization domain is now 100% inside
:: PowerShell's runtime - the same primitive that already works for the
:: WPF splash wrapper.
::
:: Sibling launcher behavior: IOException from File.Open -> log SKIP,
:: exit 0 (mirrors FirstBaseSplashSingleInstance.ps1 line 86-88).
:: Operator can `type console-splash-instances.log` and see exactly which
:: PID won the race.
::
:: Notable cmd metacharacter escapes used when echoing this body:
::   %%   -> literal %
::   ^|   -> literal | (pipe)
::   ^>   -> literal > (redirect)
::   ^<   -> literal < (redirect)
::   ^&   -> literal & (separator)
::   ^(   -> literal ( (group)
::   ^)   -> literal ) (group)
::   ^^   -> literal ^ (escape)
setlocal DisableDelayedExpansion
> "%FB_CONSOLE_LOCK_PS1%" echo # FirstBase console fallback splash single-instance helper + splash body.
>> "%FB_CONSOLE_LOCK_PS1%" echo # Auto-generated by SetupComplete.cmd / WRITE_CONSOLE_LOCK_PS1 (payload rev from FirstBaseVersion.cmd; console HWND_TOPMOST on GetConsoleWindow).
>> "%FB_CONSOLE_LOCK_PS1%" echo # Holds console-splash.lock via FileShare::None for the entire splash
>> "%FB_CONSOLE_LOCK_PS1%" echo # lifetime. Sibling invocations hit IOException on File.Open and exit 0.
>> "%FB_CONSOLE_LOCK_PS1%" echo $ErrorActionPreference = 'Continue'
>> "%FB_CONSOLE_LOCK_PS1%" echo $lockPath = 'C:\Windows\Setup\FirstBase\State\console-splash.lock'
>> "%FB_CONSOLE_LOCK_PS1%" echo $logPath  = 'C:\Windows\Setup\FirstBase\Logs\console-splash-instances.log'
>> "%FB_CONSOLE_LOCK_PS1%" echo $stateDir = 'C:\Windows\Setup\FirstBase\State'
>> "%FB_CONSOLE_LOCK_PS1%" echo $logDir   = 'C:\Windows\Setup\FirstBase\Logs'
>> "%FB_CONSOLE_LOCK_PS1%" echo $statusPath = 'C:\Windows\Setup\FirstBase\wu-status.json'
>> "%FB_CONSOLE_LOCK_PS1%" echo $heartbeatPath = 'C:\Windows\Setup\FirstBase\wu-loop-heartbeat.txt'
>> "%FB_CONSOLE_LOCK_PS1%" echo $doneMarkerPath = 'C:\Windows\Setup\Scripts\FirstBase-Updates-Done.flag'
>> "%FB_CONSOLE_LOCK_PS1%" echo $completeMarkerPath = 'C:\Windows\Setup\Scripts\FirstBase-Updates-Complete.flag'
>> "%FB_CONSOLE_LOCK_PS1%" echo $renderPath = 'C:\Windows\Setup\FirstBase\FirstBaseConsoleSplashRender.ps1'
>> "%FB_CONSOLE_LOCK_PS1%" echo try { if ^(-not ^(Test-Path -LiteralPath $stateDir^)^) { New-Item -ItemType Directory -Path $stateDir -Force ^| Out-Null } } catch {}
>> "%FB_CONSOLE_LOCK_PS1%" echo try { if ^(-not ^(Test-Path -LiteralPath $logDir^)^)   { New-Item -ItemType Directory -Path $logDir   -Force ^| Out-Null } } catch {}
>> "%FB_CONSOLE_LOCK_PS1%" echo function Write-FbConsoleLockLog ^([string]$Level, [string]$Msg^) {
>> "%FB_CONSOLE_LOCK_PS1%" echo     try {
>> "%FB_CONSOLE_LOCK_PS1%" echo         $line = ^('[' + ^(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'^) + '] [' + $Level + '] [pid=' + $PID + '] ' + $Msg^)
>> "%FB_CONSOLE_LOCK_PS1%" echo         Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
>> "%FB_CONSOLE_LOCK_PS1%" echo     } catch {}
>> "%FB_CONSOLE_LOCK_PS1%" echo }
>> "%FB_CONSOLE_LOCK_PS1%" echo $lockStream = $null
>> "%FB_CONSOLE_LOCK_PS1%" echo try {
>> "%FB_CONSOLE_LOCK_PS1%" echo     $lockStream = [System.IO.File]::Open^(
>> "%FB_CONSOLE_LOCK_PS1%" echo         $lockPath,
>> "%FB_CONSOLE_LOCK_PS1%" echo         [System.IO.FileMode]::OpenOrCreate,
>> "%FB_CONSOLE_LOCK_PS1%" echo         [System.IO.FileAccess]::Write,
>> "%FB_CONSOLE_LOCK_PS1%" echo         [System.IO.FileShare]::None
>> "%FB_CONSOLE_LOCK_PS1%" echo     ^)
>> "%FB_CONSOLE_LOCK_PS1%" echo     try {
>> "%FB_CONSOLE_LOCK_PS1%" echo         $stamp = ^('pid=' + $PID + "`n" + 'acquired=' + ^(Get-Date -Format 'o'^) + "`n" + 'payloadRev=%FIRSTBASE_PAYLOAD_REV%' + "`n" + 'mode=FileShare::None hold' + "`n"^)
>> "%FB_CONSOLE_LOCK_PS1%" echo         $stampBytes = [System.Text.Encoding]::ASCII.GetBytes^($stamp^)
>> "%FB_CONSOLE_LOCK_PS1%" echo         $lockStream.SetLength^(0^)
>> "%FB_CONSOLE_LOCK_PS1%" echo         $lockStream.Write^($stampBytes, 0, $stampBytes.Length^)
>> "%FB_CONSOLE_LOCK_PS1%" echo         $lockStream.Flush^(^)
>> "%FB_CONSOLE_LOCK_PS1%" echo     } catch {}
>> "%FB_CONSOLE_LOCK_PS1%" echo     Write-FbConsoleLockLog 'ACQUIRE' ^('acquired FileShare::None lock on ' + $lockPath + '; running console splash inline.'^)
>> "%FB_CONSOLE_LOCK_PS1%" echo } catch [System.IO.IOException] {
>> "%FB_CONSOLE_LOCK_PS1%" echo     Write-FbConsoleLockLog 'SKIP' ^('sibling holds lock ' + $lockPath + ': ' + $_.Exception.Message + '; exiting clean.'^)
>> "%FB_CONSOLE_LOCK_PS1%" echo     exit 0
>> "%FB_CONSOLE_LOCK_PS1%" echo } catch {
>> "%FB_CONSOLE_LOCK_PS1%" echo     Write-FbConsoleLockLog 'ERROR' ^('lock-attempt-threw ^(non-IO^): ' + $_.Exception.Message + '; bailing out without console splash to avoid duplicate ^(Bug EE-3^).'^)
>> "%FB_CONSOLE_LOCK_PS1%" echo     exit 0
>> "%FB_CONSOLE_LOCK_PS1%" echo }
>> "%FB_CONSOLE_LOCK_PS1%" echo try {
>> "%FB_CONSOLE_LOCK_PS1%" echo     try { $Host.UI.RawUI.WindowTitle = 'FirstBase Updates ^(Console Fallback^)' } catch {}
>> "%FB_CONSOLE_LOCK_PS1%" echo     $fbConTopLogWritten = $false
>> "%FB_CONSOLE_LOCK_PS1%" echo     try { Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class FbCon2214nZ{[DllImport("kernel32.dll")]public static extern IntPtr GetConsoleWindow();[DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr hWnd,IntPtr hWndInsertAfter,int X,int Y,int cx,int cy,uint uFlags);public static readonly IntPtr HWND_TOPMOST=new IntPtr(-1);public const uint SWP_FL=0x0043;}' -ErrorAction Stop } catch {}
>> "%FB_CONSOLE_LOCK_PS1%" echo     while ^($true^) {
>> "%FB_CONSOLE_LOCK_PS1%" echo         try { Clear-Host } catch {}
>> "%FB_CONSOLE_LOCK_PS1%" echo         try { $hCon=[FbCon2214nZ]::GetConsoleWindow(); if ($hCon -ne [IntPtr]::Zero) { [void][FbCon2214nZ]::SetWindowPos($hCon,[FbCon2214nZ]::HWND_TOPMOST,0,0,0,0,[FbCon2214nZ]::SWP_FL); if (-not $fbConTopLogWritten) { $fbConTopLogWritten=$true; try { Add-Content -LiteralPath 'C:\Windows\Setup\FirstBase\Logs\splash-ui.log' -Encoding UTF8 -Value ('['+(Get-Date -Format 'o')+'] [INFO] [PID '+$PID+'] [ConsoleFallback] payload=%FIRSTBASE_PAYLOAD_REV% console-fallback HWND_TOPMOST GetConsoleWindow') } catch {} } } } catch {}
>> "%FB_CONSOLE_LOCK_PS1%" echo         Write-Host '============================================================'
>> "%FB_CONSOLE_LOCK_PS1%" echo         Write-Host '                 FIRSTBASE WINDOWS UPDATES'
>> "%FB_CONSOLE_LOCK_PS1%" echo         Write-Host '                  ^(Console Fallback Mode^)'
>> "%FB_CONSOLE_LOCK_PS1%" echo         Write-Host '============================================================'
>> "%FB_CONSOLE_LOCK_PS1%" echo         Write-Host ''
>> "%FB_CONSOLE_LOCK_PS1%" echo         Write-Host ^('Time: ' + ^(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'^)^)
>> "%FB_CONSOLE_LOCK_PS1%" echo         Write-Host ''
>> "%FB_CONSOLE_LOCK_PS1%" echo         if ^(Test-Path -LiteralPath $statusPath^) {
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-Host '--- Current Status ---'
>> "%FB_CONSOLE_LOCK_PS1%" echo             try {
>> "%FB_CONSOLE_LOCK_PS1%" echo                 if ^(Test-Path -LiteralPath $renderPath^) {
>> "%FB_CONSOLE_LOCK_PS1%" echo                     $env:FB_STATUS = $statusPath
>> "%FB_CONSOLE_LOCK_PS1%" echo                     ^& $renderPath
>> "%FB_CONSOLE_LOCK_PS1%" echo                 } else {
>> "%FB_CONSOLE_LOCK_PS1%" echo                     $j = Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop ^| ConvertFrom-Json -ErrorAction Stop
>> "%FB_CONSOLE_LOCK_PS1%" echo                     Write-Host ^('Phase:    ' + [string]$j.phase^)
>> "%FB_CONSOLE_LOCK_PS1%" echo                     Write-Host ^('Updated:  ' + [string]$j.updatedAt^)
>> "%FB_CONSOLE_LOCK_PS1%" echo                 }
>> "%FB_CONSOLE_LOCK_PS1%" echo             } catch {
>> "%FB_CONSOLE_LOCK_PS1%" echo                 Write-Host ^('Could not read status: ' + $_.Exception.Message^)
>> "%FB_CONSOLE_LOCK_PS1%" echo             }
>> "%FB_CONSOLE_LOCK_PS1%" echo         } else {
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-Host 'Status file not yet present...'
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-Host ''
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-Host 'The update loop may still be initializing.'
>> "%FB_CONSOLE_LOCK_PS1%" echo         }
>> "%FB_CONSOLE_LOCK_PS1%" echo         Write-Host ''
>> "%FB_CONSOLE_LOCK_PS1%" echo         if ^(Test-Path -LiteralPath $heartbeatPath^) {
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-Host '--- Loop Heartbeat ---'
>> "%FB_CONSOLE_LOCK_PS1%" echo             try { Get-Content -LiteralPath $heartbeatPath -Raw -ErrorAction Stop ^| Write-Host } catch { Write-Host ^('heartbeat read failed: ' + $_.Exception.Message^) }
>> "%FB_CONSOLE_LOCK_PS1%" echo         } else {
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-Host 'No heartbeat yet.'
>> "%FB_CONSOLE_LOCK_PS1%" echo         }
>> "%FB_CONSOLE_LOCK_PS1%" echo         Write-Host ''
>> "%FB_CONSOLE_LOCK_PS1%" echo         Write-Host '------------------------------------------------------------'
>> "%FB_CONSOLE_LOCK_PS1%" echo         Write-Host '  Press Ctrl+C to exit. Auto-refreshes every 2 seconds.'
>> "%FB_CONSOLE_LOCK_PS1%" echo         Write-Host '------------------------------------------------------------'
>> "%FB_CONSOLE_LOCK_PS1%" echo         if ^(Test-Path -LiteralPath $doneMarkerPath^) {
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-Host ''
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-Host '*** UPDATES DONE - Loop signalled done; exiting in 30s ***'
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-Host ''
>> "%FB_CONSOLE_LOCK_PS1%" echo             Start-Sleep -Seconds 30
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-FbConsoleLockLog 'DONE' 'updates-done marker observed; releasing lock and exiting.'
>> "%FB_CONSOLE_LOCK_PS1%" echo             break
>> "%FB_CONSOLE_LOCK_PS1%" echo         }
>> "%FB_CONSOLE_LOCK_PS1%" echo         if ^(Test-Path -LiteralPath $completeMarkerPath^) {
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-Host ''
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-Host '*** UPDATES COMPLETE - Loop has finished ***'
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-Host ''
>> "%FB_CONSOLE_LOCK_PS1%" echo             Start-Sleep -Seconds 30
>> "%FB_CONSOLE_LOCK_PS1%" echo             Write-FbConsoleLockLog 'COMPLETE' 'updates-complete marker observed; releasing lock and exiting.'
>> "%FB_CONSOLE_LOCK_PS1%" echo             break
>> "%FB_CONSOLE_LOCK_PS1%" echo         }
>> "%FB_CONSOLE_LOCK_PS1%" echo         Start-Sleep -Seconds 2
>> "%FB_CONSOLE_LOCK_PS1%" echo     }
>> "%FB_CONSOLE_LOCK_PS1%" echo } catch {
>> "%FB_CONSOLE_LOCK_PS1%" echo     try { Write-FbConsoleLockLog 'ERROR' ^('render-loop threw: ' + $_.Exception.Message + '; releasing lock and exiting.'^) } catch {}
>> "%FB_CONSOLE_LOCK_PS1%" echo } finally {
>> "%FB_CONSOLE_LOCK_PS1%" echo     if ^($null -ne $lockStream^) {
>> "%FB_CONSOLE_LOCK_PS1%" echo         try { $lockStream.Close^(^) } catch {}
>> "%FB_CONSOLE_LOCK_PS1%" echo         try { $lockStream.Dispose^(^) } catch {}
>> "%FB_CONSOLE_LOCK_PS1%" echo     }
>> "%FB_CONSOLE_LOCK_PS1%" echo }
>> "%FB_CONSOLE_LOCK_PS1%" echo exit 0
if not exist "%FB_CONSOLE_LOCK_PS1%" (
    endlocal & exit /b 1
)
endlocal & exit /b 0

:: 2026.05.13.2213c-onlogon-primary-and-defender-disable:
:: :WRITE_SPLASH_WATCHER subroutine REMOVED. The watcher batch
:: FirstBaseSplashWatcher.cmd is no longer generated or referenced
:: anywhere. Field evidence on 2211/2212/2213a/2213b/2213b1 proved
:: the watcher invocations fire (Last Result=0 in scheduled-task
:: history) but produce ZERO filesystem evidence - the 2213b1 marker
:: design that was supposed to make this impossible did not help.
:: Splash now triggers via FirstBaseSplashLauncher.cmd directly from
:: the OnLogon task and Layer 4 loop self-launch.
::
:: :ARM_SPLASH_WATCHER_TASK subroutine REMOVED. The
:: FirstBase\UpdateSplashInteractive SYSTEM ONSTART task is no longer
:: created. Any stale task on a re-imaged device gets overwritten /
:: deleted naturally because no code creates or references it; if a
:: tech wants to clean up the stale entry, schtasks /Delete /TN
:: "FirstBase\UpdateSplashInteractive" /F is a manual one-liner.

:DISABLE_DEFENDER
:: 2213d: disable Microsoft Defender real-time monitoring HERE, in
:: specialize pass, BEFORE the Reseal-to-audit reboot. Forensic post-
:: mortem on F:\fb-dump-final-1430 (and F:\fb-dump-final-0635) proved
:: that Defender's real-time scanner classifies the splash launcher's
:: powershell.exe (-NoProfile -ExecutionPolicy Bypass -WindowStyle
:: Hidden) as a textbook fileless-attack signature and terminates /
:: stalls / scans-to-death the process before the loop's own
:: Set-FbDefenderRealtime call (Invoke-WindowsUpdateLoop.ps1 ~L9817)
:: can fire. ALL 5 prior builds (2211 -> 2212 -> 2213a -> 2213b1 ->
:: 2213c) failed with the same fingerprint: OnLogon splash + Layer 4
:: bridge fired with Last Result=0, but no powershell.exe in tasklist,
:: and zero splash-ui.log evidence. The window was 12-44 seconds long;
:: long enough for Defender to scan, killer the process, and let
:: Show-UpdateProgress.ps1 silently exit (its $ErrorActionPreference =
:: 'Continue' swallows the dispatcher throw, so the launcher reports
:: exit 0 and the failure is INVISIBLE).
::
:: We run via powershell.exe -NoProfile -NonInteractive -ExecutionPolicy
:: Bypass so the same flags pattern as APPLY_ROBUST_TASK_SETTINGS is
:: used (no mandatory prompts can fire). STDIN is redirected to <nul.
:: The body writes the defender-state.flag the loop's startup recovery
:: code already reads (see Invoke-WindowsUpdateLoop.ps1 ~L8415-8438)
:: so the system-of-record is consistent across SetupComplete and the
:: loop. The flag body matches the format Set-FbDefenderRealtime
:: writes: "<state>|<iso>|<reason>|<pid>" so the loop's recovery
:: parser interprets either author identically.
::
:: NEVER blocks. If Set-MpPreference throws (rare; Defender service
:: not yet up in specialize pass on some hardware), we log WARN and
:: continue. The 7 loop-side restore call sites still apply Defender
:: restore at OOBE handoff / escape valve / Tier 7 panic / every exit,
:: so a failed pre-disable just means the splash is still vulnerable
:: for one boot cycle, not that the device ships Defender-off.
setlocal DisableDelayedExpansion
set "FB_DEFENDER_PS_BODY=try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop; $stateDir = 'C:\Windows\Setup\FirstBase\State'; if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction SilentlyContinue | Out-Null }; $iso = (Get-Date).ToString('o'); $body = 'disabled|' + $iso + '|setup-complete-pre-audit-reboot|' + $PID; Set-Content -LiteralPath (Join-Path $stateDir 'defender-state.flag') -Value $body -Encoding ASCII -Force -ErrorAction Stop; Write-Output 'OK: Defender real-time monitoring DISABLED; defender-state.flag written' } catch { Write-Output ('WARN: pre-audit Defender disable threw: ' + $_.Exception.Message) }"
:: 2295-fail-isolation: this is the FIRST bypass-policy PS to run and it executes
:: while Defender real-time is still ON (it is the step turning it off), so it is
:: the most likely to be terminated by Defender. Run it in a SEPARATE process tree
:: via a one-shot launcher .cmd + start /wait so a child tree-kill cannot abort
:: SetupComplete.cmd. The PS body (unchanged, proven) is baked into the launcher
:: with -Command; internal | and () are protected by the surrounding quotes and the
:: redirection operators are ^-escaped so they land literally in the launcher.
set "FB_DEFENDER_LAUNCHER=%TEMP%\fb-defender-disable.run.cmd"
> "%FB_DEFENDER_LAUNCHER%" echo @echo off
>> "%FB_DEFENDER_LAUNCHER%" echo "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "%FB_DEFENDER_PS_BODY%" ^<nul ^>^> "%FB_LOG%" 2^>^&1
start "FBHarden" /min /wait "%ComSpec%" /c "%FB_DEFENDER_LAUNCHER%"
del /f /q "%FB_DEFENDER_LAUNCHER%" 2>nul
endlocal & exit /b 0

:SUPPRESS_MDM_ENROLLMENT
:: 2277-mdm-block / 2295-ps-free: Stop + disable DmEnrollmentSvc and write the MDM
:: auto-enroll suppression policy keys using ONLY native sc.exe + reg.exe. NO child
:: powershell is launched, so Defender's fileless-attack heuristic has nothing to
:: terminate and this step can NEVER abort the script. This replaces the 2278
:: -File powershell variant, which was the step that let a Defender real-time tree-
:: kill orphan the whole pre-reboot flow (dump PF4VGG7V-1423-Lenovo: SetupComplete
:: exited 0xff before the MDM block ran). Runs FIRST in the pre-reboot sequence and
:: NEVER blocks (all sc/reg output redirected to the log; always returns 0).
::
:: TEMPORARY / KEEP IN SYNC: the service name, registry path and value names below
:: MUST match the teardown in FirstBaseOobeOperatorFinalize.ps1 (2277), which
:: Remove-ItemProperty's AutoEnrollMDM + UseAADCredentialType and restores
:: DmEnrollmentSvc to StartupType=Automatic + Start at the OOBE handoff. Do NOT
:: rename these without updating that teardown, or the device will ship unable to
:: enroll.
setlocal DisableDelayedExpansion
set "FB_MDM_KEY=HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM"
:: Stop then disable the enrollment service (native; no PowerShell). sc.exe returns
:: non-zero when the service is already stopped/absent - non-fatal, all output is
:: redirected to the log. NOTE: the space after "start=" is REQUIRED by sc syntax.
sc stop DmEnrollmentSvc >> "%FB_LOG%" 2>&1
sc config DmEnrollmentSvc start= disabled >> "%FB_LOG%" 2>&1
:: Write the block policy values (native reg.exe; reg auto-creates the key path).
reg add "%FB_MDM_KEY%" /v AutoEnrollMDM        /t REG_DWORD /d 0 /f >> "%FB_LOG%" 2>&1
reg add "%FB_MDM_KEY%" /v UseAADCredentialType /t REG_DWORD /d 0 /f >> "%FB_LOG%" 2>&1
call :LOG "MDM suppression applied PS-free (sc: DmEnrollmentSvc stop + start=disabled; reg: AutoEnrollMDM=0 UseAADCredentialType=0)"
endlocal & exit /b 0

:ADD_DEFENDER_EXCLUSION
:: 2280-defender-autopilot-block: Add Defender path exclusions for the two FirstBase
:: directories BEFORE any PowerShell from those directories runs.
:: Add-MpPreference -ExclusionPath is NOT blocked by Tamper Protection (unlike
:: Set-MpPreference -DisableRealtimeMonitoring). This prevents the false-positive
:: AMSI quarantine (Trojan:Win32/AmsiTamper.A!ams) that blocked payload scripts on
:: devices with Tamper Protection enabled. Exclusions are removed by
:: FirstBaseOobeOperatorFinalize.ps1 (2280) before seal.
setlocal DisableDelayedExpansion
set "FB_DEFEXCL_TMPSCRIPT=%TEMP%\fb-defexcl-add.ps1"
(
echo $svc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
echo $waited = 0
echo while ($svc -and $svc.Status -ne 'Running' -and $waited -lt 30) {
echo     Start-Sleep -Seconds 2
echo     $waited += 2
echo     $svc.Refresh(^)
echo }
echo if ($svc -and $svc.Status -ne 'Running') {
echo     Write-Output "WARN: WinDefend not Running after ${waited}s — skipping Add-MpPreference (not critical)"
echo } else {
echo     try {
echo         Add-MpPreference -ExclusionPath 'C:\Windows\Setup\FirstBase' -ErrorAction Stop
echo         Add-MpPreference -ExclusionPath 'C:\ProgramData\FirstBase' -ErrorAction Stop
echo         Add-MpPreference -ExclusionPath 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup' -ErrorAction Stop
echo         Write-Output 'OK: Defender exclusions added for FirstBase directories'
echo     } catch {
echo         Write-Output ('WARN: Add-MpPreference threw: ' + $_.Exception.Message^)
echo     }
echo }
) > "%FB_DEFEXCL_TMPSCRIPT%"
:: 2295-fail-isolation: run the temp .ps1 in a detached process tree so a Defender
:: termination of the child cannot abort SetupComplete.cmd. Always returns 0.
call :RUN_PS_ISOLATED "%FB_DEFEXCL_TMPSCRIPT%"
del /f /q "%FB_DEFEXCL_TMPSCRIPT%" 2>nul
endlocal & exit /b 0

:BLOCK_AUTOPILOT_ENDPOINTS
:: 2280-defender-autopilot-block: Add Windows Firewall outbound block rules for
:: Autopilot-specific enrollment endpoints. The WCOOBE / oobeldr.exe / msoobe.exe
:: enrollment stack bypasses DmEnrollmentSvc suppression and AutoEnrollMDM registry
:: keys entirely. Resolves hostnames to IPs first for rule reliability; falls back
:: to hostname string if DNS resolution fails. login.microsoftonline.com and
:: portal.manage.microsoft.com are intentionally omitted to avoid breaking Windows
:: Update AAD authentication. Rule is removed by FirstBaseOobeOperatorFinalize.ps1
:: (2280) before seal.
setlocal DisableDelayedExpansion
set "FB_APBLOCK_TMPSCRIPT=%TEMP%\fb-autopilot-block.ps1"
(
echo $endpoints = @(
echo     'ztd.dds.microsoft.com',
echo     'cs.dds.microsoft.com',
echo     'enterpriseregistration.windows.net',
echo     'enterpriseenrollment.manage.microsoft.com',
echo     'enrollment.manage.microsoft.com',
echo     'dm.microsoft.com',
echo     'wcoobe.microsoft.com'
echo ^)
echo $addresses = [System.Collections.Generic.List[string]]::new(^)
echo foreach ($h in $endpoints) {
echo     $job = Start-Job -ScriptBlock { param($host) [System.Net.Dns]::GetHostAddresses($host) ^| ForEach-Object { $_.IPAddressToString } } -ArgumentList $h
echo     $completed = Wait-Job -Job $job -Timeout 5
echo     if ($completed) {
echo         $ips = Receive-Job -Job $job -ErrorAction SilentlyContinue
echo         if ($ips) { $ips ^| ForEach-Object { [void]$addresses.Add($_) }; Write-Output "Resolved $h -> $($ips -join ', ')" }
echo         else { [void]$addresses.Add($h); Write-Output "No IPs for $h — using hostname" }
echo     } else {
echo         Stop-Job -Job $job
echo         [void]$addresses.Add($h)  # fall back to hostname
echo         Write-Output "WARN: DNS timeout for $h after 5s — using hostname in rule"
echo     }
echo     Remove-Job -Job $job -Force
echo }
echo if ($addresses.Count -gt 0) {
echo     $ruleName = 'FirstBase-Block-Autopilot'
echo     Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
echo     New-NetFirewallRule -DisplayName $ruleName -Direction Outbound -Action Block `
echo         -RemoteAddress ($addresses ^| Select-Object -Unique) `
echo         -Protocol Any -Enabled True -Profile Any -ErrorAction Stop ^| Out-Null
echo     Write-Output "OK: Autopilot outbound block rule created ($($addresses.Count) addresses)"
echo } else {
echo     Write-Output 'WARN: No addresses resolved — Autopilot block rule NOT created'
echo }
) > "%FB_APBLOCK_TMPSCRIPT%"
:: 2295-fail-isolation: run the temp .ps1 in a detached process tree so a Defender
:: termination of the child cannot abort SetupComplete.cmd. Always returns 0.
call :RUN_PS_ISOLATED "%FB_APBLOCK_TMPSCRIPT%"
del /f /q "%FB_APBLOCK_TMPSCRIPT%" 2>nul
endlocal & exit /b 0

:RUN_PS_ISOLATED
:: 2295-fail-isolation: run a temp .ps1 in a SEPARATE process tree so that if
:: Defender's real-time/AMSI engine terminates the child powershell (its fileless-
:: attack heuristic fires on -ExecutionPolicy Bypass), the kill CANNOT propagate up
:: and abort SetupComplete.cmd. A one-shot launcher .cmd carries the powershell
:: invocation + log redirection so the "start" command line needs NO nested quotes;
:: start /wait returns control to us when the launcher exits OR is killed, so the
:: caller ALWAYS continues to :DONE. This subroutine ALWAYS returns 0.
::   %~1 = full path to the .ps1 to execute with -File.
setlocal DisableDelayedExpansion
set "FB_ISO_PS1=%~1"
set "FB_ISO_LAUNCHER=%FB_ISO_PS1%.run.cmd"
if not defined FB_PS set "FB_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
:: Build the launcher. The redirection to the log is ^-escaped so it is written
:: literally into the launcher (and executed there), not applied to this echo.
> "%FB_ISO_LAUNCHER%" echo @echo off
>> "%FB_ISO_LAUNCHER%" echo "%FB_PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%FB_ISO_PS1%" ^<nul ^>^> "%FB_LOG%" 2^>^&1
:: Launch in a detached process tree; /min keeps any transient console hidden.
start "FBHarden" /min /wait "%ComSpec%" /c "%FB_ISO_LAUNCHER%"
del /f /q "%FB_ISO_LAUNCHER%" 2>nul
endlocal & exit /b 0

:SUPPRESS_RECOVERY_SCREEN
:: 2284-recovery-screen: Suppress "Why did my PC restart?" and automatic WinRE
:: boot during the FirstBase update pipeline. Pipeline reboots (watchdog, forced
:: restart) trigger the recovery screen if Windows sees an unexpected shutdown.
:: Reversed in FirstBaseOobeOperatorFinalize.ps1 before seal.
setlocal DisableDelayedExpansion
call :LOG "Suppressing recovery screen (bootstatuspolicy + recoveryenabled, pre-pipeline)"
bcdedit /set {current} bootstatuspolicy ignoreallfailures >> "%FB_LOG%" 2>&1 <nul
set "FB_BSUP_EC1=%ERRORLEVEL%"
bcdedit /set {current} recoveryenabled no >> "%FB_LOG%" 2>&1 <nul
set "FB_BSUP_EC2=%ERRORLEVEL%"
if %FB_BSUP_EC1% neq 0 ( call :LOG "WARN: bcdedit bootstatuspolicy failed (ec=%FB_BSUP_EC1%^)" )
if %FB_BSUP_EC2% neq 0 ( call :LOG "WARN: bcdedit recoveryenabled failed (ec=%FB_BSUP_EC2%^)" )
if %FB_BSUP_EC1% equ 0 if %FB_BSUP_EC2% equ 0 call :LOG "OK: Recovery screen suppressed for pipeline window"
endlocal & exit /b 0

:ARM_DEFERRED_OOBE_SOUND_IF_PENDING
:: 2232 (fb-dump-final-859): Fence 1 skips the Audit pipeline on post-sysprep specialize,
:: but HKLM RunOnce often does NOT run during defaultuser0 OOBE logon. When deferred Sound
:: is armed and the device is not yet sealed, (re)create FirstBase\DeferredOobeSoundOnLogon
:: and optionally HKLM Run fallback so FirstBaseDeferredOobeSound.ps1 runs on first interactive logon.
if not exist "%FB_DEFERRED_SOUND_ARMED%" goto :ARM_DEFERRED_EOF
if exist "%FB_PIPELINE_COMPLETED_MARKER%" goto :ARM_DEFERRED_EOF
if exist "%FB_SEALED_MARKER%" goto :ARM_DEFERRED_EOF
if not exist "%FB_DEFERRED_SOUND_PS%" (
    call :LOG "2231: deferred Sound armed but script missing at %FB_DEFERRED_SOUND_PS%; cannot arm ONLOGON on specialize pass."
    goto :ARM_DEFERRED_EOF
)
call :LOG "2231: post-sysprep specialize — arming %FB_DEFERRED_SOUND_ONLOGON_TASK% (Settings delivery only; audit arming skipped)."
schtasks /Delete /TN "%FB_DEFERRED_SOUND_ONLOGON_TASK%" /F >nul 2>&1 <nul
if "%FB_SELFTEST_MODE%"=="1" (
    call :LOG "SELF-TEST: skipped schtasks /Create %FB_DEFERRED_SOUND_ONLOGON_TASK%"
    goto :ARM_DEFERRED_EOF
)
schtasks /Create /TN "%FB_DEFERRED_SOUND_ONLOGON_TASK%" /SC ONLOGON /RL HIGHEST /IT /F /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%FB_DEFERRED_SOUND_PS%\"" >> "%FB_LOG%" 2>&1 <nul
if errorlevel 1 (
    call :LOG "2233: WARN schtasks /Create %FB_DEFERRED_SOUND_ONLOGON_TASK% failed on specialize pass."
) else (
    call :LOG "2233: created %FB_DEFERRED_SOUND_ONLOGON_TASK% on post-sysprep specialize pass."
    call :APPLY_ROBUST_TASK_SETTINGS "%FB_DEFERRED_SOUND_ONLOGON_TASK%"
)
:: 2233/2234: always arm HKLM Run belt — RunOnce alone is unreliable on defaultuser0 OOBE logon.
set "FB_DEFERRED_BOOTSTRAP_PS=%FB_PROGRAMDATA_DIR%\FirstBaseOobeDeferredSoundBootstrap.ps1"
set "FB_DEFERRED_BOOTSTRAP_SETUP=%FB_ROOT%\FirstBaseOobeDeferredSoundBootstrap.ps1"
if not exist "%FB_DEFERRED_BOOTSTRAP_PS%" if exist "%FB_DEFERRED_BOOTSTRAP_SETUP%" (
    copy /y "%FB_DEFERRED_BOOTSTRAP_SETUP%" "%FB_DEFERRED_BOOTSTRAP_PS%" >> "%FB_LOG%" 2>&1 <nul
    call :LOG "2237: staged FirstBaseOobeDeferredSoundBootstrap.ps1 from Setup to ProgramData (specialize ARM_DEFERRED)."
)
if not exist "%FB_DEFERRED_SOUND_PS%" if exist "%FB_ROOT%\FirstBaseDeferredOobeSound.ps1" (
    copy /y "%FB_ROOT%\FirstBaseDeferredOobeSound.ps1" "%FB_DEFERRED_SOUND_PS%" >> "%FB_LOG%" 2>&1 <nul
    call :LOG "2237: staged FirstBaseDeferredOobeSound.ps1 from Setup to ProgramData (specialize ARM_DEFERRED)."
)
if exist "%FB_DEFERRED_BOOTSTRAP_PS%" (
    set "FB_DEFERRED_SOUND_TR=powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%FB_DEFERRED_BOOTSTRAP_PS%\""
) else (
    set "FB_DEFERRED_SOUND_TR=powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%FB_DEFERRED_SOUND_PS%\""
)
reg add "%FB_RUN_KEY%" /v "%FB_DEFERRED_SOUND_RUN_KEY%" /t REG_SZ /d "%FB_DEFERRED_SOUND_TR%" /f >> "%FB_LOG%" 2>&1 <nul
if errorlevel 1 (
    call :LOG "2234: WARN reg add HKLM Run %FB_DEFERRED_SOUND_RUN_KEY% failed on specialize pass."
) else (
    call :LOG "2234: HKLM Run %FB_DEFERRED_SOUND_RUN_KEY% armed on specialize pass (belt with ONLOGON)."
)
:: 2234: Active Setup — once per user at first logon (OOBE defaultuser0); fb-dump-final-1121.
reg add "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A7B8C9D0-E1F2-4A5B-9C01-2234DEFERREDSOUND}" /ve /d "FirstBase OOBE deferred Sound handoff" /f >> "%FB_LOG%" 2>&1 <nul
reg add "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A7B8C9D0-E1F2-4A5B-9C01-2234DEFERREDSOUND}" /v StubPath /t REG_SZ /d "%FB_DEFERRED_SOUND_TR%" /f >> "%FB_LOG%" 2>&1 <nul
reg add "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A7B8C9D0-E1F2-4A5B-9C01-2234DEFERREDSOUND}" /v Version /t REG_SZ /d "1,0" /f >> "%FB_LOG%" 2>&1 <nul
call :LOG "2234: Active Setup Installed Components armed for deferred Sound (specialize Fence 1 path)."
:: 2236: All Users Startup — runs at user logon when Run/RunOnce/Active Setup do not fire on OOBE defaultuser0.
if not exist "%FB_DEFERRED_BOOTSTRAP_PS%" goto :ARM_DEFERRED_EOF
set "FB_DEFERRED_STARTUP_DIR=%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup"
set "FB_DEFERRED_STARTUP_VBS=%FB_DEFERRED_STARTUP_DIR%\FirstBaseOobeSoundAtLogon.vbs"
if not exist "%FB_DEFERRED_STARTUP_DIR%" mkdir "%FB_DEFERRED_STARTUP_DIR%" 2>nul
> "%FB_DEFERRED_STARTUP_VBS%" echo Set oShell = CreateObject("WScript.Shell")
>> "%FB_DEFERRED_STARTUP_VBS%" echo oShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%FB_DEFERRED_BOOTSTRAP_PS%""", 0, False
call :LOG "2293: ProgramData All Users Startup (VBS) armed at %FB_DEFERRED_STARTUP_VBS% (specialize Fence 1 path)."
:ARM_DEFERRED_EOF
exit /b 0

:ARM_AUTOLOGIN
:: Enable local Administrator with a BLANK password. Audit Mode auto-login
:: works reliably with a blank Administrator password and is acceptable
:: because the device is offline/airgapped during this window. The password
:: gets set during OOBE post-sysprep when the technician hands the box off
:: to the end user.
net user Administrator "" /active:yes >> "%FB_LOG%" 2>&1 <nul
set "AUTOLOGIN_EC=!ERRORLEVEL!"
if not "!AUTOLOGIN_EC!"=="0" (
    echo [%DATE% %TIME%]   WARN: net user Administrator failed exit=!AUTOLOGIN_EC! >> "%FB_LOG%"
)

set "WL_KEY=HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
reg add "%WL_KEY%" /v "AutoAdminLogon"     /t REG_SZ    /d "1"             /f >> "%FB_LOG%" 2>&1 <nul
reg add "%WL_KEY%" /v "DefaultUserName"    /t REG_SZ    /d "Administrator" /f >> "%FB_LOG%" 2>&1 <nul
reg add "%WL_KEY%" /v "DefaultPassword"    /t REG_SZ    /d ""              /f >> "%FB_LOG%" 2>&1 <nul
reg add "%WL_KEY%" /v "DefaultDomainName"  /t REG_SZ    /d "."             /f >> "%FB_LOG%" 2>&1 <nul
reg add "%WL_KEY%" /v "AutoLogonCount"     /t REG_DWORD /d 5               /f >> "%FB_LOG%" 2>&1 <nul
reg add "%WL_KEY%" /v "ForceAutoLogon"     /t REG_SZ    /d "1"             /f >> "%FB_LOG%" 2>&1 <nul
echo [%DATE% %TIME%]   AutoAdminLogon=1, AutoLogonCount=5, ForceAutoLogon=1 >> "%FB_LOG%"
exit /b 0

:LOG
echo [%DATE% %TIME%] %~1>> "%FB_LOG%"
echo [%TIME%] %~1
exit /b 0
