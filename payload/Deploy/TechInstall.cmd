@echo off
setlocal EnableDelayedExpansion

:: This is the LIVE deploy script for the full "LoneWolf" build (WorkflowProfile
:: ProvisionMode=lonewolf, e.g. AMD64/ARM64 profiles), in BOTH WIM mode and ISO mode
:: (Invoke-LoneWolfBuild.ps1 Build-Cache / Build-IsoCache / Build-OverlayCache all copy
:: THIS file, unrenamed, to Deploy\TechInstall.cmd on the USB when NOT -NoPayload).
:: The sibling TechInstall-Install.cmd is a SEPARATE, ALSO-LIVE script used only for the
:: WIN-INSTALL / -NoPayload workflow (WorkflowProfile.TechInstallScript override) - it is
:: copied and RENAMED to Deploy\TechInstall.cmd on WIN-INSTALL builds only, so it never
:: appears under its own filename on a built USB. Neither file is dead code.

title FirstBase ? For Internal Use Only

:: Optional: set TECHINSTALL_WIM_INDEX before launch (default 1).
if not defined TECHINSTALL_WIM_INDEX set "TECHINSTALL_WIM_INDEX=1"
set "FB_TOTAL_STEPS=7"
set "FB_TECHINSTALL_REV=2026-08-24.2"

:: %TEMP% is not guaranteed to resolve to an existing directory in WinPE, so it can
:: never be the LAST-RESORT log location: a ">>" into a path that does not exist
:: prints "The system cannot find the path specified." straight to the console, and
:: a diskpart script file that cannot be written makes diskpart a no-op. X:\ is the
:: WinPE scratch volume and always exists, so FB_TMPD is the safe scratch root used
:: for every fallback log path and temp script file below.
set "FB_TMPD=X:"
if defined TEMP if exist "%TEMP%\." set "FB_TMPD=%TEMP%"

:: -- Hand the screen to the PowerShell deploy UI --------------------------
:: Invoke-FbDeployUi.ps1 owns the console: Init plays the splash reveal, then
:: paints splash branding + step plan + progress (no separate Show-DeployBanner
:: process, no title ribbon). Seeding the whole plan up front means the
:: operator can see what is still to come, not just the current step.
:: The labels below must stay in step order and match the FB_UI_PROGRESS calls.
set "FB_WF_SUBTEXT=Updates"
set "FB_UI_PLAN=WinPE initialized;Disk preparation;Source + image resolved;Applying Windows image;Staging post-install payload;Configuring boot + handoff;Finalizing + reboot"
call :FB_UI_INIT

:: -- STEP 1: Find source media BEFORE any disk operations ----------------
REM USB volumes can appear slightly after startnet finds TechInstall.cmd ? retry like WinPE-Startnet.cmd.
set /a FB_SRC_TRY=0
:FB_SRC_PRE_DISK
set /a FB_SRC_TRY+=1
call :FIND_SOURCE
if defined SRC goto :FB_SRC_PRE_DISK_OK
if !FB_SRC_TRY! LSS 15 (
    ping -n 3 127.0.0.1 >nul
    goto :FB_SRC_PRE_DISK
)
set "LOG=!FB_TMPD!\FirstBase-Deploy.log"
echo [%DATE% %TIME%] ERROR: No install media after !FB_SRC_TRY! attempts. >> "!LOG!" 2>nul
echo [%DATE% %TIME%]   Check %~d0\sources\ for install.wim / install.esd / install.swm >> "!LOG!" 2>nul
set "ERRMSG=Could not find sources\install.wim, install.esd, or install.swm before disksetup ^(see !LOG!^)."
goto :FAIL1
:FB_SRC_PRE_DISK_OK

:: Resolve the FirstBase payload root before anything reads WUPayload / Scripts /
:: Autounattend.xml / the USB log folder.
call :FB_RESOLVE_PAYLOAD_ROOT

:: Main log on USB so it survives reboots / WinPE crashes (RAM temp is useless).
:: APPEND mode - prior runs are kept so we can compare attempts after a forced reboot.
set "FB_SCRIPTVOL=%~d0"
if /i not "!FB_SCRIPTVOL:~-1!"==":" set "FB_SCRIPTVOL=!FB_SCRIPTVOL!:"
:: Keep deploy / DISM / trace logs in a visible FirstBase-Logs folder at the volume root.
call :FB_PICK_LOGDIR_SRC
REM USB logs live in <vol>\FirstBase-Logs (not inside hidden FirstBase, not loose at root).
REM Fall back to FB_TMPD if the volume is not writable yet. Do not use %TEMP% as last resort
REM (it may not exist this early).
if not exist "!FB_USB_LOGDIR_SRC!\." set "FB_USB_LOGDIR_SRC=!FB_TMPD!"
set "LOG=!FB_USB_LOGDIR_SRC!\FirstBase-Deploy.log"
set "FB_USB_VOL_SCRIPT=!FB_PAYLOAD_SELF:~0,2!"
if /i not "!FB_USB_VOL_SCRIPT:~-1!"==":" set "FB_USB_VOL_SCRIPT=!FB_USB_VOL_SCRIPT!:"
set "FB_USB_LOGDIR_SCRIPT=!FB_USB_VOL_SCRIPT!\FirstBase-Logs"
if exist "!FB_USB_VOL_SCRIPT!\." (
    if not exist "!FB_USB_LOGDIR_SCRIPT!\" mkdir "!FB_USB_LOGDIR_SCRIPT!" >nul 2>&1
    attrib -H -S "!FB_USB_LOGDIR_SCRIPT!" >nul 2>&1
)
if not exist "!FB_USB_LOGDIR_SCRIPT!\." set "FB_USB_LOGDIR_SCRIPT=!FB_TMPD!"
set "TRACE=!FB_USB_LOGDIR_SCRIPT!\FirstBase-Trace.log"
echo. >> "%LOG%" 2>nul
echo ===== %DATE% %TIME% NEW RUN ===== >> "%LOG%"
echo [%DATE% %TIME%] FirstBase deploy started >> "%LOG%"
echo [%DATE% %TIME%] TechInstall revision: %FB_TECHINSTALL_REV% >> "%LOG%"
echo [%DATE% %TIME%] PRE: Source=%SRC% >> "%LOG%"
echo [%DATE% %TIME%] SCRIPTVOL=!FB_SCRIPTVOL! PAYLOAD=!FB_PAYLOAD! >> "%LOG%"
echo.>> "%TRACE%" 2>nul
echo ===== %DATE% %TIME% NEW RUN ===== >> "%TRACE%" 2>nul
echo [%DATE% %TIME%] TechInstall revision: %FB_TECHINSTALL_REV% >> "%TRACE%" 2>nul
echo [%DATE% %TIME%] SCRIPTVOL=!FB_SCRIPTVOL! SRC=%SRC% >> "%TRACE%" 2>nul
call :RESOLVE_POWERSHELL
set "FB_DISKPART=%SystemRoot%\System32\diskpart.exe"
if not exist "!FB_DISKPART!" set "FB_DISKPART=%WINDIR%\System32\diskpart.exe"
if not exist "!FB_DISKPART!" if exist "X:\Windows\System32\diskpart.exe" set "FB_DISKPART=X:\Windows\System32\diskpart.exe"
if not exist "!FB_DISKPART!" set "FB_DISKPART=diskpart"

REM --------------------------------------------------------------------------
REM NOTE (rev %FB_TECHINSTALL_REV%): the previous "image already complete"
REM marker-file gate was removed. It wrote a completion marker onto the USB's
REM own media, so re-using the SAME stick to install Windows on a DIFFERENT
REM machine would see the marker from the prior job and refuse to wipe/image
REM at all -- silently turning a real install attempt into a no-op handoff.
REM Firmware boot-order handoff after bcdboot is what prevents the wipe-loop /
REM re-imaging-on-reboot problem. USB EFI loaders stay in place so the stick
REM remains bootable for the next machine. This extra media-side lock is not
REM needed and must not block legitimate reuse of the stick.
REM --------------------------------------------------------------------------

call :FB_UI_PROGRESS 1 "WinPE initialized"
call :FB_TRACE "STEP1 ready SRC=%SRC% FB_PS=%FB_PS%"
if not defined FB_PS echo WARNING: powershell.exe not in this WinPE ? disksetup install-media fallback limited; DISM uses dism.exe.

:: -- STEP 2: Copy disksetup.cmd to WinPE ramdisk (X:\) --------------------
:: disksetup.cmd lives alongside TechInstall.cmd in the Deploy\ folder on the
:: data partition (%~dp0). Fall back to %SRC%\ root for legacy sticks that
:: still carry it there.
set "FB_DISKSETUP_PATH="
set "FB_DISKSETUP_SRC="
if exist "%~dp0disksetup.cmd" (
    set "FB_DISKSETUP_SRC=%~dp0disksetup.cmd"
    echo [%DATE% %TIME%] Found disksetup.cmd at Deploy\ ^(%~dp0disksetup.cmd^) >> "%LOG%"
) else if exist "%SRC%\disksetup.cmd" (
    set "FB_DISKSETUP_SRC=%SRC%\disksetup.cmd"
    echo [%DATE% %TIME%] Found disksetup.cmd at legacy root path ^(%SRC%\disksetup.cmd^) >> "%LOG%"
)
if defined FB_DISKSETUP_SRC (
    if exist "X:\disksetup.cmd" del /f /q "X:\disksetup.cmd" >nul 2>&1
    copy /y "!FB_DISKSETUP_SRC!" "X:\disksetup.cmd" >nul 2>&1
    if exist "X:\disksetup.cmd" (
        set "FB_DISKSETUP_PATH=X:\disksetup.cmd"
        echo [%DATE% %TIME%] Copied disksetup.cmd to X:\ >> "%LOG%"
    ) else (
        set "FB_DISKSETUP_PATH=!FB_DISKSETUP_SRC!"
        echo [%DATE% %TIME%] WARNING: Copy to X:\disksetup.cmd failed. Using source path !FB_DISKSETUP_SRC! >> "%LOG%"
    )
) else (
    echo WARNING: disksetup.cmd not found on media. Skipping disk prep.
    echo [%DATE% %TIME%] WARNING: disksetup.cmd not found in Deploy\ or %SRC%\. >> "%LOG%"
)

:: -- STEP 3: Disk layout snapshot ----------------------------------------
(
    echo list disk
    echo list volume
) > "!FB_TMPD!\fb_precheck.txt"
echo [%DATE% %TIME%] Pre-disksetup disk state: >> "%LOG%"
"!FB_DISKPART!" /s "!FB_TMPD!\fb_precheck.txt" >> "%LOG%" 2>&1

:: -- STEP 4: Partition internal disk -------------------------------------
title FirstBase ? For Internal Use Only ? Disk preparation
REM disksetup.cmd derives its log folder AND its operator-flag locations from
REM INSTALLSRC. Logs and FirstBase-WIPE-PENDING.txt write to <vol>\FirstBase-Logs
REM (visible). Operator flags stay at the volume root / payload root.
REM Pass the PAYLOAD root; disksetup still accepts operator flags at the volume root.
set "INSTALLSRC=%SRC%"
if defined FB_PAYLOAD set "INSTALLSRC=!FB_PAYLOAD!"
echo [%DATE% %TIME%] disksetup INSTALLSRC=!INSTALLSRC! ^(payload root^) >> "%LOG%"
call :FB_UI_PROGRESS 2 "Disk preparation"
call :FB_TRACE "STEP2 disksetup begin path=!FB_DISKSETUP_PATH!"
if defined FB_DISKSETUP_PATH (
    echo [%DATE% %TIME%] Running disksetup from !FB_DISKSETUP_PATH! >> "%LOG%"
    call "!FB_DISKSETUP_PATH!"
    set "DSERR=!ERRORLEVEL!"
    echo [%DATE% %TIME%] disksetup.cmd exit: !DSERR! >> "%LOG%"
) else (
    echo [%DATE% %TIME%] No disksetup.cmd found. Skipping. >> "%LOG%"
)
set "INSTALLSRC="
call :FB_TRACE "STEP2 disksetup exit DSERR=!DSERR!"
if defined DSERR if not "!DSERR!"=="0" (
    set "ERRMSG=disksetup blocked deployment ^(exit !DSERR!^)."
    goto :FAIL2
)

title FirstBase ? For Internal Use Only

:: -- STEP 5: Re-find source media AFTER disksetup -------------------------
set "SRC="
set /a FB_SRC_TRY=0
:FB_SRC_POST_DISK
set /a FB_SRC_TRY+=1
call :FIND_SOURCE
if defined SRC goto :FB_SRC_POST_DISK_OK
if !FB_SRC_TRY! LSS 15 (
    ping -n 3 127.0.0.1 >nul
    goto :FB_SRC_POST_DISK
)
set "ERRMSG=Lost USB/source after disksetup ^(!FB_SRC_TRY! tries^). Need sources\install.wim .esd or .swm. Check USB letter."
goto :FAIL1
:FB_SRC_POST_DISK_OK
:: Re-bind payload root + log folder to the post-disksetup resolved media letter (SRC may differ from pre-disksetup).
call :FB_RESOLVE_PAYLOAD_ROOT
call :FB_BIND_USB_LOG
call :FB_UI_PROGRESS 3 "Source + image resolved"
echo [%DATE% %TIME%] POST: Source=%SRC% >> "%LOG%" 2>nul
call :FB_TRACE "STEP3 source resolved SRC=%SRC%"
set "FB_LAYOUT=UNKNOWN"
set "FB_LAYOUT_FILE="
if exist "%SRC%\FirstBase-Logs\FirstBase-Layout.txt" set "FB_LAYOUT_FILE=%SRC%\FirstBase-Logs\FirstBase-Layout.txt"
if not defined FB_LAYOUT_FILE if exist "%SRC%\FirstBase-Layout.txt" set "FB_LAYOUT_FILE=%SRC%\FirstBase-Layout.txt"
if not defined FB_LAYOUT_FILE if exist "!FB_PAYLOAD!\FirstBase-Layout.txt" set "FB_LAYOUT_FILE=!FB_PAYLOAD!\FirstBase-Layout.txt"
if not defined FB_LAYOUT_FILE if exist "%SRC%\FirstBase-UsbLogs\FirstBase-Layout.txt" set "FB_LAYOUT_FILE=%SRC%\FirstBase-UsbLogs\FirstBase-Layout.txt"
if not defined FB_LAYOUT_FILE if exist "!FB_PAYLOAD!\FirstBase-UsbLogs\FirstBase-Layout.txt" set "FB_LAYOUT_FILE=!FB_PAYLOAD!\FirstBase-UsbLogs\FirstBase-Layout.txt"
if defined FB_LAYOUT_FILE (
    for /f "usebackq tokens=1,* delims==" %%a in ("!FB_LAYOUT_FILE!") do (
        if /I "%%~a"=="Layout" set "FB_LAYOUT=%%~b"
    )
)
if /I not "!FB_LAYOUT!"=="SPLIT" if /I not "!FB_LAYOUT!"=="SINGLE" set "FB_LAYOUT=UNKNOWN"
echo [%DATE% %TIME%] USB layout marker: !FB_LAYOUT! >> "%LOG%"

call :FIND_IMAGE_FILE
if not defined IMGFILE (
    set "ERRMSG=No install.wim, install.esd, or install.swm under %SRC%\sources\."
    goto :FAIL3
)
set "SWMFILE="
if /I "%IMGFILE:~-4%"==".swm" (
    set "SWMFILE=%SRC%\sources\install*.swm"
    echo [%DATE% %TIME%] SWM image set detected. SWMFile=!SWMFILE! >> "%LOG%"
)
echo [%DATE% %TIME%] IMGFILE=%IMGFILE% Index=%TECHINSTALL_WIM_INDEX% >> "%LOG%"

:: -- STEP 6: Target volume -----------------------------------------------
if not exist "W:\" (
    set "ERRMSG=W: partition not found after disksetup."
    goto :FAIL2
)
echo [%DATE% %TIME%] W: confirmed. >> "%LOG%"

:: -- Pre-DISM: wipe W:\ if stale content from a previous interrupted apply ----
if exist "W:\Windows" (
    echo [%DATE% %TIME%] Pre-DISM: W:\ has stale content - reformatting >> "%LOG%" 2>nul
    echo Y | format W: /FS:NTFS /Q >nul 2>&1
    echo [%DATE% %TIME%] Pre-DISM: W:\ quick-format complete >> "%LOG%" 2>nul
)

:: -- STEP 7: Apply Windows image (PowerShell UI + DISM) -------------------
title FirstBase ? For Internal Use Only ? Applying image
call :FB_UI_PROGRESS 4 "Applying Windows image"
echo [%DATE% %TIME%] Starting DISM apply >> "%LOG%"
call :FB_TRACE "STEP4 dism begin IMGFILE=%IMGFILE% INDEX=%TECHINSTALL_WIM_INDEX%"

REM Separate DISM log ? DISM truncates its target file, so MUST NOT be %LOG%.
set "DISMLOG=%FB_USB_LOGDIR_SRC%\FirstBase-DISM.log"
set "DISMWRAPLOG=%FB_USB_LOGDIR_SRC%\FirstBase-DISM-wrapper.log"
echo [%DATE% %TIME%] DISM /LogPath: %DISMLOG% >> "%LOG%"
echo [%DATE% %TIME%] DISM wrapper log: %DISMWRAPLOG% >> "%LOG%"
echo.>> "%DISMWRAPLOG%" 2>nul
echo ===== %DATE% %TIME% NEW RUN ===== >> "%DISMWRAPLOG%" 2>nul
echo [%DATE% %TIME%] IMGFILE=%IMGFILE% SWMFILE=%SWMFILE% INDEX=%TECHINSTALL_WIM_INDEX% APPLYDIR=W:\ >> "%DISMWRAPLOG%" 2>nul

set "PSAPPLY=!FB_PAYLOAD!\Scripts\Invoke-FirstBaseDismApply.ps1"
if not exist "!PSAPPLY!" if exist "!FB_PAYLOAD!\Deploy\Invoke-FirstBaseDismApply.ps1" set "PSAPPLY=!FB_PAYLOAD!\Deploy\Invoke-FirstBaseDismApply.ps1"
if not exist "!PSAPPLY!" if exist "%SRC%\Scripts\Invoke-FirstBaseDismApply.ps1"       set "PSAPPLY=%SRC%\Scripts\Invoke-FirstBaseDismApply.ps1"
if not exist "!PSAPPLY!" if exist "%SRC%\Deploy\Invoke-FirstBaseDismApply.ps1"        set "PSAPPLY=%SRC%\Deploy\Invoke-FirstBaseDismApply.ps1"
echo [%DATE% %TIME%] DISM helper script: !PSAPPLY! >> "%LOG%"
if exist "%PSAPPLY%" (
    if defined FB_PS (
        if defined SWMFILE (
            "%FB_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PSAPPLY%" -ImageFile "%IMGFILE%" -SwmFilePattern "%SWMFILE%" -Index %TECHINSTALL_WIM_INDEX% -ApplyDir W:\ -LogPath "%DISMLOG%" -WrapperLog "%DISMWRAPLOG%"
        ) else (
            "%FB_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PSAPPLY%" -ImageFile "%IMGFILE%" -Index %TECHINSTALL_WIM_INDEX% -ApplyDir W:\ -LogPath "%DISMLOG%" -WrapperLog "%DISMWRAPLOG%"
        )
        set "PSAPPLYEC=!ERRORLEVEL!"
        if not "!PSAPPLYEC!"=="0" (
            echo [%DATE% %TIME%] WARNING: DISM PowerShell helper failed ^(exit !PSAPPLYEC!^). Retrying with dism.exe. >> "%LOG%"
            echo [%DATE% %TIME%] WARNING: DISM PowerShell helper failed ^(exit !PSAPPLYEC!^). Retrying with dism.exe. >> "%DISMWRAPLOG%" 2>nul
            if defined SWMFILE (
                dism /Apply-Image /ImageFile:"%IMGFILE%" /SWMFile:"%SWMFILE%" /Index:%TECHINSTALL_WIM_INDEX% /ApplyDir:W:\ /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
            ) else (
                dism /Apply-Image /ImageFile:"%IMGFILE%" /Index:%TECHINSTALL_WIM_INDEX% /ApplyDir:W:\ /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
            )
        )
    ) else (
        echo WARNING: PowerShell missing in WinPE ? using dism.exe ^(no progress UI^)
        echo [%DATE% %TIME%] DISM: PS script skipped, using dism.exe >> "%LOG%"
        if defined SWMFILE (
            dism /Apply-Image /ImageFile:"%IMGFILE%" /SWMFile:"%SWMFILE%" /Index:%TECHINSTALL_WIM_INDEX% /ApplyDir:W:\ /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
        ) else (
            dism /Apply-Image /ImageFile:"%IMGFILE%" /Index:%TECHINSTALL_WIM_INDEX% /ApplyDir:W:\ /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
        )
    )
) else (
    echo WARNING: Invoke-FirstBaseDismApply.ps1 missing ? fallback dism.exe
    if defined SWMFILE (
        dism /Apply-Image /ImageFile:"%IMGFILE%" /SWMFile:"%SWMFILE%" /Index:%TECHINSTALL_WIM_INDEX% /ApplyDir:W:\ /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
    ) else (
        dism /Apply-Image /ImageFile:"%IMGFILE%" /Index:%TECHINSTALL_WIM_INDEX% /ApplyDir:W:\ /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
    )
)
set "DISMEC=%ERRORLEVEL%"
echo [%DATE% %TIME%] DISM invoke exit: !DISMEC! >> "%LOG%"
echo [%DATE% %TIME%] DISM invoke exit: !DISMEC! >> "%DISMWRAPLOG%" 2>nul
call :FB_TRACE "STEP4 dism exit DISMEC=!DISMEC!"

if not "!DISMEC!"=="0" (
    set "ERRMSG=DISM apply failed."
    goto :FAIL3
)
echo [%DATE% %TIME%] DISM apply succeeded. >> "%LOG%"

:: -- STEP 8: Offline unattend only (no SetupScripts / no post-install tools) -
set "FB_UNATTEND="
if exist "!FB_PAYLOAD!\Autounattend.xml" set "FB_UNATTEND=!FB_PAYLOAD!\Autounattend.xml"
if not defined FB_UNATTEND if exist "!FB_PAYLOAD!\autounattend.xml" set "FB_UNATTEND=!FB_PAYLOAD!\autounattend.xml"
if not defined FB_UNATTEND if exist "%SRC%\Autounattend.xml"        set "FB_UNATTEND=%SRC%\Autounattend.xml"
if not defined FB_UNATTEND if exist "%SRC%\autounattend.xml"        set "FB_UNATTEND=%SRC%\autounattend.xml"
if defined FB_UNATTEND (
    if not exist "W:\Windows\Panther" mkdir "W:\Windows\Panther" >nul 2>&1
    copy /y "!FB_UNATTEND!" "W:\Windows\Panther\unattend.xml" >> "%LOG%" 2>&1
    echo [%DATE% %TIME%] Copied !FB_UNATTEND! to Panther. >> "%LOG%"
) else (
    echo [%DATE% %TIME%] WARNING: No Autounattend.xml on media. >> "%LOG%"
)

:: -- STEP 8b: Stage FirstBase Windows Update payload onto W:\ -------------
:: Sources from the payload root's WUPayload\ (placed there by Builder\Build-UsbStick.ps1
:: from the sibling project "FirstBase Windows Update Script"). Lays down:
::   W:\Windows\Setup\Scripts\SetupComplete.cmd  (Microsoft auto-runs this)
::   W:\Windows\Setup\FirstBase\Invoke-WindowsUpdateLoop.ps1
::   W:\Windows\Setup\FirstBase\FirstBaseWuEngine.ps1   (native COM engine, REQUIRED)
::   W:\Windows\Setup\FirstBase\FirstBaseVersion.ps1 + FirstBaseVersion.cmd (product/payload semver manifest)
::   W:\Windows\Setup\FirstBase\Show-UpdateProgress.ps1
::   W:\Windows\Setup\FirstBase\Show-UpdatesCompleteMessage.ps1
::   W:\Windows\Setup\FirstBase\FirstBaseDeferredOobeSound.ps1 (2218 OOBE overlay)
::   W:\Windows\Setup\FirstBase\FirstBaseOobeOperatorFinalize.ps1 (2226 Fence 1 finalize)
::   W:\Windows\Setup\FirstBase\msu\                       (if shipped offline)
:: This WinPE staging phase lays down scripts that run in Audit Mode after
:: first boot, then return to OOBE once updates converge.
:: Runtime engine: native Windows Update Agent (Microsoft.Update.Session) only.
:: PSWindowsUpdate is no longer used at runtime.
:: Lab override: empty file FirstBase-SkipUpdates.txt on the USB root or in the
:: payload root (FirstBase\) skips this.
title FirstBase ? For Internal Use Only ? Staging Windows Update payload
call :FB_UI_PROGRESS 5 "Staging post-install payload"
call :FB_FIND_FLAG FirstBase-SkipUpdates.txt
if defined FB_FLAG_PATH (
    echo [%DATE% %TIME%] FirstBase-SkipUpdates.txt present ? skipping WU payload stage >> "%LOG%"
) else if not exist "!FB_PAYLOAD!\WUPayload\SetupComplete.cmd" (
    echo [%DATE% %TIME%] WARNING: !FB_PAYLOAD!\WUPayload\SetupComplete.cmd missing ? WU stage skipped >> "%LOG%"
    echo   WARNING: WUPayload missing on USB ? Windows Update phase will NOT run.
) else (
    echo [%DATE% %TIME%] Staging WU payload from !FB_PAYLOAD!\WUPayload\ >> "%LOG%"

    if not exist "W:\Windows\Setup\Scripts" mkdir "W:\Windows\Setup\Scripts" >> "%LOG%" 2>&1
    if not exist "W:\Windows\Setup\FirstBase" mkdir "W:\Windows\Setup\FirstBase" >> "%LOG%" 2>&1
    if not exist "W:\Windows\Setup\FirstBase\Logs" mkdir "W:\Windows\Setup\FirstBase\Logs" >> "%LOG%" 2>&1

    REM SetupComplete.cmd MUST live at the Microsoft-reserved path.
    copy /y "!FB_PAYLOAD!\WUPayload\SetupComplete.cmd" "W:\Windows\Setup\Scripts\SetupComplete.cmd" >> "%LOG%" 2>&1
    if !ERRORLEVEL! NEQ 0 (
        echo [%DATE% %TIME%] WARNING: copy SetupComplete.cmd failed exit=!ERRORLEVEL! >> "%LOG%"
    ) else (
        echo [%DATE% %TIME%]   staged W:\Windows\Setup\Scripts\SetupComplete.cmd >> "%LOG%"
    )

    REM Loop + native COM engine + UI scripts go under Setup\FirstBase\
    if exist "!FB_PAYLOAD!\WUPayload\Invoke-WindowsUpdateLoop.ps1" (
        copy /b /y "!FB_PAYLOAD!\WUPayload\Invoke-WindowsUpdateLoop.ps1" "W:\Windows\Setup\FirstBase\Invoke-WindowsUpdateLoop.ps1" >> "%LOG%" 2>&1
        set "FB_LOOP_SRC_SIZE=0"
        set "FB_LOOP_DST_SIZE=0"
        for %%A in ("!FB_PAYLOAD!\WUPayload\Invoke-WindowsUpdateLoop.ps1") do set "FB_LOOP_SRC_SIZE=%%~zA"
        for %%A in ("W:\Windows\Setup\FirstBase\Invoke-WindowsUpdateLoop.ps1") do set "FB_LOOP_DST_SIZE=%%~zA"
        echo [%DATE% %TIME%] loop script copy src=!FB_LOOP_SRC_SIZE! dst=!FB_LOOP_DST_SIZE! >> "%LOG%"
        if "!FB_LOOP_SRC_SIZE!"=="0" (
            echo [%DATE% %TIME%] ERROR: Invoke-WindowsUpdateLoop.ps1 source size is 0 >> "%LOG%"
            set "ERRMSG=FirstBase update loop script is missing or empty on the USB. Rebuild the stick from current src/payload."
            goto :FAIL1
        )
        if !FB_LOOP_SRC_SIZE! LSS 900000 (
            echo [%DATE% %TIME%] ERROR: Invoke-WindowsUpdateLoop.ps1 source is truncated (!FB_LOOP_SRC_SIZE! bytes, need ^>= 900000^) >> "%LOG%"
            set "ERRMSG=FirstBase update loop script on the USB is truncated. Rebuild from current src/payload (not a stale packaged launcher)."
            goto :FAIL1
        )
        if not "!FB_LOOP_SRC_SIZE!"=="!FB_LOOP_DST_SIZE!" (
            echo [%DATE% %TIME%] ERROR: Invoke-WindowsUpdateLoop.ps1 size mismatch after copy src=!FB_LOOP_SRC_SIZE! dst=!FB_LOOP_DST_SIZE! >> "%LOG%"
            set "ERRMSG=FirstBase update loop script was truncated while copying to the Windows volume. Retry the image."
            goto :FAIL1
        )
        findstr /C:FIRSTBASE-LOOP-EOF-OK "W:\Windows\Setup\FirstBase\Invoke-WindowsUpdateLoop.ps1" >nul
        if errorlevel 1 (
            echo [%DATE% %TIME%] WARNING: findstr missed FIRSTBASE-LOOP-EOF-OK after size-verified copy src=!FB_LOOP_SRC_SIZE! dst=!FB_LOOP_DST_SIZE! - continuing >> "%LOG%"
        )
    ) else (
        echo [%DATE% %TIME%] WARNING: Invoke-WindowsUpdateLoop.ps1 missing in WUPayload >> "%LOG%"
    )
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseWuEngine.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseWuEngine.ps1" "W:\Windows\Setup\FirstBase\FirstBaseWuEngine.ps1" >> "%LOG%" 2>&1
    ) else (
        echo [%DATE% %TIME%] ERROR: FirstBaseWuEngine.ps1 missing in WUPayload ? update loop cannot start >> "%LOG%"
    )
    if exist "!FB_PAYLOAD!\WUPayload\Show-UpdateProgress.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\Show-UpdateProgress.ps1" "W:\Windows\Setup\FirstBase\Show-UpdateProgress.ps1" >> "%LOG%" 2>&1
    ) else (
        echo [%DATE% %TIME%] NOTE: Show-UpdateProgress.ps1 missing in WUPayload ? splash UI disabled >> "%LOG%"
    )
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseSplashTechMenu.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseSplashTechMenu.ps1" "W:\Windows\Setup\FirstBase\FirstBaseSplashTechMenu.ps1" >> "%LOG%" 2>&1
    )
    if not exist "W:\Windows\Setup\FirstBase\Tools" mkdir "W:\Windows\Setup\FirstBase\Tools" >> "%LOG%" 2>&1
    if exist "!FB_PAYLOAD!\WUPayload\Tools\fb-im.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\Tools\fb-im.ps1" "W:\Windows\Setup\FirstBase\Tools\fb-im.ps1" >> "%LOG%" 2>&1
    )
    if exist "!FB_PAYLOAD!\WUPayload\Tools\fb-dump.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\Tools\fb-dump.ps1" "W:\Windows\Setup\FirstBase\Tools\fb-dump.ps1" >> "%LOG%" 2>&1
    )
    copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseHandoffSplash.ps1" "W:\Windows\Setup\FirstBase\FirstBaseHandoffSplash.ps1" >> "%LOG%" 2>&1
    REM 2237: Show-UpdatesCompleteMessage.ps1 staging removed (dead since 2213s popup removal ? no RunOnce registration, never invoked).
    REM FirstBaseVersion.* ? single source for product + payload + per-script semver (PowerShell + cmd).
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseVersion.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseVersion.ps1" "W:\Windows\Setup\FirstBase\FirstBaseVersion.ps1" >> "%LOG%" 2>&1
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBaseVersion.ps1 missing in WUPayload >> "%LOG%"
    )
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseVersion.cmd" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseVersion.cmd" "W:\Windows\Setup\FirstBase\FirstBaseVersion.cmd" >> "%LOG%" 2>&1
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBaseVersion.cmd missing in WUPayload >> "%LOG%"
    )
    REM FirstBaseBuildIdentity.ps1 - shared dev/release resolver used by the
    REM updates splash, the handoff splash and fb-im. Without it those surfaces
    REM default to RELEASE, so a dev device would silently lose its DEV pill.
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseBuildIdentity.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseBuildIdentity.ps1" "W:\Windows\Setup\FirstBase\FirstBaseBuildIdentity.ps1" >> "%LOG%" 2>&1
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBaseBuildIdentity.ps1 missing in WUPayload - device DEV marker will read release >> "%LOG%"
    )
    REM The two per-build dev signals themselves. Both are absent on a release
    REM build and that absence IS the release answer, so neither copy is
    REM unconditional and a missing file is not a warning.
    if exist "!FB_PAYLOAD!\LW_VERSION.json" (
        copy /y "!FB_PAYLOAD!\LW_VERSION.json" "W:\Windows\Setup\FirstBase\LW_VERSION.json" >> "%LOG%" 2>&1
        echo [%DATE% %TIME%] Staged LW_VERSION.json to device >> "%LOG%"
    )
    if exist "!FB_PAYLOAD!\WUPayload\.dev-build" (
        copy /y "!FB_PAYLOAD!\WUPayload\.dev-build" "W:\Windows\Setup\FirstBase\.dev-build" >> "%LOG%" 2>&1
        echo [%DATE% %TIME%] Staged .dev-build marker to device ^(dev build^) >> "%LOG%"
    ) else (
        echo [%DATE% %TIME%] No .dev-build marker on stick - device will report release >> "%LOG%"
    )

    REM 2026.05.19.2213m Bug EE-2: explicit copy of FirstBaseSplashSingleInstance.ps1.
    REM Dump 651 (5/19) showed build-version.txt reporting this file as MISSING on
    REM the live device even though Build-UsbStick.ps1 places it on the USB via
    REM "Payload\*" wildcard. Root cause: the WU payload staging block here uses an
    REM EXPLICIT hardcoded file list (not a wildcard), and 2213l added the wrapper
    REM file but did not add a copy line for it. Without this copy the WPF splash
    REM falls back to direct RunOnce launch (no dedupe) and splash-launcher-instances
    REM .log is never created. SHA evidence ships in build-version.txt every boot.
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseSplashSingleInstance.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseSplashSingleInstance.ps1" "W:\Windows\Setup\FirstBase\FirstBaseSplashSingleInstance.ps1" >> "%LOG%" 2>&1
        if !ERRORLEVEL! NEQ 0 (
            echo [%DATE% %TIME%] WARNING: copy FirstBaseSplashSingleInstance.ps1 failed exit=!ERRORLEVEL! >> "%LOG%"
        ) else (
            echo [%DATE% %TIME%]   staged W:\Windows\Setup\FirstBase\FirstBaseSplashSingleInstance.ps1 >> "%LOG%"
        )
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBaseSplashSingleInstance.ps1 missing in WUPayload - splash dedupe lock will not engage [Bug EE] >> "%LOG%"
    )

    REM 2026.05.20.2213q Bug MM: explicit copy of FirstBaseSplashWatcher.ps1.
    REM Same explicit-copy-list pattern as 2213m above. The watcher is the
    REM Layer 1.5 SYSTEM Explorer-presence poller that replaces the OnLogon
    REM trigger on FirstBase\UpdateSplash (which lost a race with explorer.exe
    REM startup on Dell hardware per dump 1142). SetupComplete.cmd creates a
    REM FirstBase\SplashWatcher scheduled task that powershell -File invokes
    REM this script; without the script on disk the watcher task is skipped
    REM and splash falls back to Layer 3/4 only - which on Dell means the
    REM splash appears ~10 minutes late instead of within 5 seconds of
    REM Explorer. SHA evidence ships in build-version.txt every boot.
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseSplashWatcher.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseSplashWatcher.ps1" "W:\Windows\Setup\FirstBase\FirstBaseSplashWatcher.ps1" >> "%LOG%" 2>&1
        if !ERRORLEVEL! NEQ 0 (
            echo [%DATE% %TIME%] WARNING: copy FirstBaseSplashWatcher.ps1 failed exit=!ERRORLEVEL! >> "%LOG%"
        ) else (
            echo [%DATE% %TIME%]   staged W:\Windows\Setup\FirstBase\FirstBaseSplashWatcher.ps1 >> "%LOG%"
        )
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBaseSplashWatcher.ps1 missing in WUPayload - splash will not fire until Layer 3/4 kicks in [Bug MM] >> "%LOG%"
    )

    REM 2254/2255: explicit copy of FirstBaseDebugHotkeyWatcher.ps1 (SetupComplete arms schtask only if file exists).
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseDebugHotkeyWatcher.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseDebugHotkeyWatcher.ps1" "W:\Windows\Setup\FirstBase\FirstBaseDebugHotkeyWatcher.ps1" >> "%LOG%" 2>&1
        if !ERRORLEVEL! NEQ 0 (
            echo [%DATE% %TIME%] WARNING: copy FirstBaseDebugHotkeyWatcher.ps1 failed exit=!ERRORLEVEL! >> "%LOG%"
        ) else (
            echo [%DATE% %TIME%]   staged W:\Windows\Setup\FirstBase\FirstBaseDebugHotkeyWatcher.ps1 >> "%LOG%"
        )
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBaseDebugHotkeyWatcher.ps1 missing in WUPayload - Ctrl+Shift+End debug bypass disabled [2254/2255] >> "%LOG%"
    )

    REM 2026.05.20.2218: OOBE-overlay deferred Sound (explicit copy ? same pattern as Bug MM / 2217).
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseDeferredOobeSound.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseDeferredOobeSound.ps1" "W:\Windows\Setup\FirstBase\FirstBaseDeferredOobeSound.ps1" >> "%LOG%" 2>&1
        if !ERRORLEVEL! NEQ 0 (
            echo [%DATE% %TIME%] WARNING: copy FirstBaseDeferredOobeSound.ps1 failed exit=!ERRORLEVEL! >> "%LOG%"
        ) else (
            echo [%DATE% %TIME%]   staged W:\Windows\Setup\FirstBase\FirstBaseDeferredOobeSound.ps1 >> "%LOG%"
        )
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBaseDeferredOobeSound.ps1 missing in WUPayload - OOBE-overlay deferred Sound disabled [2218] >> "%LOG%"
    )

    REM 2026.05.27.2226: operator finalize (writes .pipeline-completed after Settings close; same explicit-copy pattern as 2218).
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseOobeOperatorFinalize.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseOobeOperatorFinalize.ps1" "W:\Windows\Setup\FirstBase\FirstBaseOobeOperatorFinalize.ps1" >> "%LOG%" 2>&1
        if !ERRORLEVEL! NEQ 0 (
            echo [%DATE% %TIME%] WARNING: copy FirstBaseOobeOperatorFinalize.ps1 failed exit=!ERRORLEVEL! >> "%LOG%"
        ) else (
            echo [%DATE% %TIME%]   staged W:\Windows\Setup\FirstBase\FirstBaseOobeOperatorFinalize.ps1 >> "%LOG%"
        )
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBaseOobeOperatorFinalize.ps1 missing in WUPayload - OOBE Fence 1 finalize may fail [2226] >> "%LOG%"
    )

    REM 2026.05.28.2230: detached ONLOGON arm (fb-dump-final-617: missing on device caused inline-only arm killed by sysprep reboot).
    if exist "!FB_PAYLOAD!\WUPayload\FirstBasePostSysprepOobeSoundArm.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBasePostSysprepOobeSoundArm.ps1" "W:\Windows\Setup\FirstBase\FirstBasePostSysprepOobeSoundArm.ps1" >> "%LOG%" 2>&1
        if !ERRORLEVEL! NEQ 0 (
            echo [%DATE% %TIME%] WARNING: copy FirstBasePostSysprepOobeSoundArm.ps1 failed exit=!ERRORLEVEL! >> "%LOG%"
        ) else (
            echo [%DATE% %TIME%]   staged W:\Windows\Setup\FirstBase\FirstBasePostSysprepOobeSoundArm.ps1 >> "%LOG%"
        )
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBasePostSysprepOobeSoundArm.ps1 missing in WUPayload - ONLOGON detached arm disabled [2230] >> "%LOG%"
    )

    REM 2026.05.28.2234: OOBE Active Setup bootstrap.
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseOobeDeferredSoundBootstrap.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseOobeDeferredSoundBootstrap.ps1" "W:\Windows\Setup\FirstBase\FirstBaseOobeDeferredSoundBootstrap.ps1" >> "%LOG%" 2>&1
        if !ERRORLEVEL! NEQ 0 (
            echo [%DATE% %TIME%] WARNING: copy FirstBaseOobeDeferredSoundBootstrap.ps1 failed exit=!ERRORLEVEL! >> "%LOG%"
        ) else (
            echo [%DATE% %TIME%]   staged W:\Windows\Setup\FirstBase\FirstBaseOobeDeferredSoundBootstrap.ps1 >> "%LOG%"
        )
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBaseOobeDeferredSoundBootstrap.ps1 missing in WUPayload - Active Setup OOBE delivery disabled [2234] >> "%LOG%"
    )
    REM 2239: FirstBaseDetachedFirmwareReboot.ps1 removed ? logic inlined into Start-FbDetachedFirmwareRebootAfterSysprepValidation in Invoke-WindowsUpdateLoop.ps1 and written to ProgramData at arm time.

    REM 2026.05.28.2230: Shift+F10 operator triage scripts.
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseShowSplash.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseShowSplash.ps1" "W:\Windows\Setup\FirstBase\FirstBaseShowSplash.ps1" >> "%LOG%" 2>&1
        if !ERRORLEVEL! NEQ 0 (
            echo [%DATE% %TIME%] WARNING: copy FirstBaseShowSplash.ps1 failed exit=!ERRORLEVEL! >> "%LOG%"
        ) else (
            echo [%DATE% %TIME%]   staged W:\Windows\Setup\FirstBase\FirstBaseShowSplash.ps1 >> "%LOG%"
        )
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBaseShowSplash.ps1 missing in WUPayload - Shift+F10 splash disabled [2230] >> "%LOG%"
    )
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseOpenSettingsAndFinish.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseOpenSettingsAndFinish.ps1" "W:\Windows\Setup\FirstBase\FirstBaseOpenSettingsAndFinish.ps1" >> "%LOG%" 2>&1
        if !ERRORLEVEL! NEQ 0 (
            echo [%DATE% %TIME%] WARNING: copy FirstBaseOpenSettingsAndFinish.ps1 failed exit=!ERRORLEVEL! >> "%LOG%"
        ) else (
            echo [%DATE% %TIME%]   staged W:\Windows\Setup\FirstBase\FirstBaseOpenSettingsAndFinish.ps1 >> "%LOG%"
        )
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBaseOpenSettingsAndFinish.ps1 missing in WUPayload - manual Settings finish disabled [2230] >> "%LOG%"
    )
    if exist "!FB_PAYLOAD!\WUPayload\FirstBaseHardwareCheck.ps1" (
        copy /y "!FB_PAYLOAD!\WUPayload\FirstBaseHardwareCheck.ps1" "W:\Windows\Setup\FirstBase\FirstBaseHardwareCheck.ps1" >> "%LOG%" 2>&1
        if !ERRORLEVEL! NEQ 0 (
            echo [%DATE% %TIME%] WARNING: copy FirstBaseHardwareCheck.ps1 failed exit=!ERRORLEVEL! >> "%LOG%"
        ) else (
            echo [%DATE% %TIME%]   staged W:\Windows\Setup\FirstBase\FirstBaseHardwareCheck.ps1 >> "%LOG%"
        )
    ) else (
        echo [%DATE% %TIME%] WARNING: FirstBaseHardwareCheck.ps1 missing in WUPayload - hardware gate will FAIL closed (no skip-as-pass) >> "%LOG%"
    )
    REM 2026.07.21: Show-SplashNow.cmd removed from the payload - the operator splash is
    REM launched via FirstBaseShowSplash.ps1 directly, so no Tools\Show-SplashNow.cmd is
    REM staged (eliminates the missing-file WARNING [2230] and its path-not-found noise).

    REM PSWindowsUpdate is no longer used at runtime (native COM engine only).
    REM If a Modules\PSWindowsUpdate cache exists on USB, it is ignored here.
    if exist "!FB_PAYLOAD!\WUPayload\Modules\PSWindowsUpdate\" (
        echo [%DATE% %TIME%]   NOTE: PSWindowsUpdate cache present on USB but skipped (native COM engine in use) >> "%LOG%"
    )

    REM Optional offline .msu cache for fully offline deploys
    if exist "!FB_PAYLOAD!\WUPayload\msu\" (
        if not exist "W:\Windows\Setup\FirstBase\msu" mkdir "W:\Windows\Setup\FirstBase\msu" >> "%LOG%" 2>&1
        xcopy "!FB_PAYLOAD!\WUPayload\msu" "W:\Windows\Setup\FirstBase\msu\" /E /I /Y /H /R >> "%LOG%" 2>&1
        echo [%DATE% %TIME%]   staged offline .msu cache >> "%LOG%"
    )

    REM Lab override propagation: copy WU-side splash flag from USB to %FB_ROOT%
    REM so SetupComplete sees it on first boot.
    call :FB_FIND_FLAG FirstBase-NoSplash.flag
    if defined FB_FLAG_PATH (
        copy /y "!FB_FLAG_PATH!" "W:\Windows\Setup\FirstBase\FirstBase-NoSplash.flag" >> "%LOG%" 2>&1
        echo [%DATE% %TIME%]   propagated FirstBase-NoSplash.flag >> "%LOG%"
    )

    echo [%DATE% %TIME%] WU payload staging complete >> "%LOG%"
)
title FirstBase ? For Internal Use Only

:: -- STEP 9: Bootloader ---------------------------------------------------
title FirstBase - For Internal Use Only - Boot files
call :FB_UI_PROGRESS 6 "Configuring boot + handoff"
call :FB_TRACE "STEP6 bootcfg begin"
if not exist "S:\" (
    set "ERRMSG=S: EFI partition not found after DISM apply."
    goto :FAIL4
)

REM --------------------------------------------------------------------------
REM PROVEN local-builder boot handoff (rev %FB_TECHINSTALL_REV%).
REM
REM PRIMARY anti-loop mechanism: promote the internal-disk Windows Boot Manager
REM in firmware boot order ({fwbootmgr} bootsequence + permanent displayorder
REM /addfirst). Same-session diskpart offline of the install media is
REM defense-in-depth only. USB EFI loaders are left in place. This matches
REM the proven Windows_Installation TechInstall.cmd - firmware handoff is
REM what actually stops the re-image loop on this hardware.
REM
REM Pre-flight: clear any stale {fwbootmgr} bootsequence. On some firmwares
REM (HP commercial / certain Lenovos) a stale value makes bcdedit refuse every
REM operation with "multiple indistinguishable devices" / "Access is denied".
REM Clearing bootsequence first often unlocks the store. Failures are logged
REM and non-fatal - the real write is attempted afterward regardless.
REM --------------------------------------------------------------------------
echo [%DATE% %TIME%] Pre-bcdboot {fwbootmgr} state: >> "%LOG%"
bcdedit /enum {fwbootmgr} >> "%LOG%" 2>&1
echo [%DATE% %TIME%] Clearing stale bootsequence on {fwbootmgr} >> "%LOG%"
bcdedit /deletevalue {fwbootmgr} bootsequence >> "%LOG%" 2>&1
echo [%DATE% %TIME%]   bootsequence /deletevalue exit=!ERRORLEVEL! >> "%LOG%"

REM bcdboot writes ESP files onto the internal disk's own ESP (S:) AND registers
REM a Windows Boot Manager entry in {fwbootmgr}.
bcdboot W:\Windows /s S: /f UEFI >> "%LOG%" 2>&1
if !ERRORLEVEL! NEQ 0 (
    set "ERRMSG=BCDBOOT failed. Exit code: !ERRORLEVEL!"
    goto :FAIL5
)
echo [%DATE% %TIME%] BCDBOOT succeeded. >> "%LOG%"
call :FB_TRACE "STEP6 bcdboot succeeded"

REM PRIMARY handoff: force firmware to boot the freshly installed internal Windows.
call :FB_FORCE_NEXT_BOOT_INTERNAL
call :FB_TRACE "STEP6 force_boot_result !FORCE_BOOT_RESULT!"

if "!BS_OK!"=="0" (
    echo   WARNING: Could not set firmware bootsequence on this PC.
    echo   WARNING: relying on firmware fallback to internal disk.
    echo [%DATE% %TIME%] WARNING: bootsequence not set - firmware fallback is the handoff mechanism >> "%LOG%"
)

REM Quiet the new {bootmgr} on the freshly written ESP so it does not idle on a menu.
set "BCDSTORE="
if exist "S:\EFI\Microsoft\Boot\BCD" set "BCDSTORE=S:\EFI\Microsoft\Boot\BCD"
if not defined BCDSTORE if exist "S:\Boot\BCD" set "BCDSTORE=S:\Boot\BCD"
if defined BCDSTORE (
    bcdedit /store "!BCDSTORE!" /set {bootmgr} timeout 0 >> "%LOG%" 2>&1
    bcdedit /store "!BCDSTORE!" /set {bootmgr} displaybootmenu no >> "%LOG%" 2>&1
    bcdedit /store "!BCDSTORE!" /set {bootmgr} default {default} >> "%LOG%" 2>&1
    echo [%DATE% %TIME%] Quieted new bootmgr in !BCDSTORE! >> "%LOG%"
)

REM Snapshot final firmware state for post-mortem.
echo [%DATE% %TIME%] Final firmware boot order: >> "%LOG%"
bcdedit /enum {fwbootmgr} >> "%LOG%" 2>&1

title FirstBase - For Internal Use Only - Complete
call :FB_UI_PROGRESS 7 "Finalizing + reboot"
echo [%DATE% %TIME%] SUCCESS >> "%LOG%"
call :FB_TRACE "STEP7 success"

set "FB_STAY=0"
call :FB_FIND_FLAG FirstBase-StayInPE.txt
if defined FB_FLAG_PATH set "FB_STAY=1"
if "%FB_STAY%"=="1" (
    echo FirstBase-StayInPE.txt found - staying in WinPE ^(no wpeutil reboot^).
    echo Full log: %LOG%
    echo [%DATE% %TIME%] SUCCESS - StayInPE override, no reboot >> "%LOG%"
    exit /b 0
)

echo [%DATE% %TIME%] SUCCESS - rebooting >> "%LOG%"

REM Copy WinPE bootstrap log to USB before reboot (wpeutil reboot is immediate;
REM control never returns to WinPE-Startnet.cmd so its log-copy block never runs).
REM Must run HERE -- before diskpart offline disk takes the USB offline.
if defined FBLOG if exist "%FBLOG%" (
    copy /y "%FBLOG%" "!FB_USB_LOGDIR_SRC!\FirstBase-winpe.log" >nul 2>&1
    if /I not "!FB_PAYLOAD_SELF:~0,2!"=="!FB_USB_VOL!" (
        set "FB_WINPE_ALT=!FB_PAYLOAD_SELF:~0,2!\FirstBase-Logs"
        if exist "!FB_PAYLOAD_SELF:~0,2!\." (
            if not exist "!FB_WINPE_ALT!\" mkdir "!FB_WINPE_ALT!" >nul 2>&1
            attrib -H -S "!FB_WINPE_ALT!" >nul 2>&1
            copy /y "%FBLOG%" "!FB_WINPE_ALT!\FirstBase-winpe.log" >nul 2>&1
        )
    )
    echo [%DATE% %TIME%] WinPE bootstrap log copied to USB ^(FBLOG saved before reboot^) >> "%LOG%"
)

REM Physical disk # that owns %SRC%. Needed for optional diskpart offline.
REM
REM This used to parse a LIVE diskpart pipe inline, with a for /f whose command
REM string was '"!FB_DISKPART!" /s "in.txt" piped through findstr'.
REM That command string STARTS with a double quote, which cmd mangles when it wraps
REM it for its "cmd /c" subshell - diskpart never ran, the loop body never executed,
REM the console got "The filename, directory name, or volume label syntax is
REM incorrect.", and MEDIADISK was left EMPTY. An empty MEDIADISK silently skipped
REM the offline-disk step below. usebackq does not
REM fix the quoting hazard. Run diskpart once into a CAPTURE FILE and parse the file
REM instead - the same capture-file pattern TechInstall-Install.cmd already uses.
set "VLE=%SRC:~0,1%"
set "MEDIADISK="
set "MEDIADISK_SRC=none"
echo [%DATE% %TIME%] Install media volume detail ^(disk number for offline^): >> "%LOG%"
call :FB_DISK_OF_LETTER !VLE!
set "MEDIADISK=!FB_DOL_DISK!"
set "MEDIADISK_SRC=!FB_DOL_SRC!"
if not defined MEDIADISK call :FB_MEDIADISK_PS_FALLBACK
REM The "if defined" guard is load-bearing: "set VAR=!VAR: =!" on an UNDEFINED
REM variable leaves the literal " =" behind, which then satisfies "if defined VAR"
REM with junk - that is how the log came to read "Disk  =" while the
REM self-wipe comparisons silently no-opped.
if defined MEDIADISK set "MEDIADISK=!MEDIADISK: =!"
if defined MEDIADISK (
    echo !MEDIADISK!| findstr /R "^[0-9][0-9]*$" >nul 2>&1
    if errorlevel 1 (
        set "MEDIADISK="
        set "MEDIADISK_SRC=none"
    )
)
echo [%DATE% %TIME%] MEDIADISK ^(install volume physical disk^)=!MEDIADISK! source=!MEDIADISK_SRC! >> "%LOG%"
echo [%DATE% %TIME%] USB boot loaders left in place ^(stick stays bootable after apply^) >> "%LOG%"
call :FB_TRACE "USB boot files left in place"

REM --------------------------------------------------------------------------
REM Optional: mark install-media disk offline ^(Windows stack, this WinPE session
REM only^). USB EFI loaders and sources\boot.wim stay on the stick.
REM --------------------------------------------------------------------------
echo [%DATE% %TIME%] Install media offline-disk ^(diskpart^): >> "%LOG%"
if defined MEDIADISK (
    echo [%DATE% %TIME%] Taking install media disk !MEDIADISK! offline >> "%LOG%"
    (
        echo select disk !MEDIADISK!
        echo offline disk
    ) > "!FB_TMPD!\fb_offline.txt"
    "!FB_DISKPART!" /s "!FB_TMPD!\fb_offline.txt" >> "!LOG!" 2>&1
    set "FB_OFFLINE_EC=!ERRORLEVEL!"
    rem The install media disk is now OFFLINE, so its USB-hosted LOG path no longer
    rem resolves and any further append would print "The system cannot find the path
    rem specified." to the WinPE console. Re-point LOG to the RAM scratch root BEFORE
    rem logging the offline result. The read below MUST be !LOG!, not %LOG% - cmd
    rem expands %LOG% at parse time for the whole block, so the re-point above would
    rem silently never take effect and the write would still target the dead USB path.
    set "LOG=!FB_TMPD!\FirstBase-Deploy.log"
    echo [%DATE% %TIME%]   diskpart offline exit=!FB_OFFLINE_EC! >> "!LOG!" 2>nul
) else (
    echo [%DATE% %TIME%] WARNING: MEDIADISK unset - offline disk skipped; removing data volume letter fallback >> "!LOG!" 2>nul
    (
        echo select volume !VLE!:
        echo remove letter=!VLE!
    ) > "!FB_TMPD!\fb_eject.txt"
    rem Dropping the data volume's drive letter kills the USB-hosted LOG path just as
    rem surely as taking the disk offline does, so re-point LOG the same way the if
    rem branch above does - BEFORE the diskpart output is appended.
    set "LOG=!FB_TMPD!\FirstBase-Deploy.log"
    "!FB_DISKPART!" /s "!FB_TMPD!\fb_eject.txt" >> "!LOG!" 2>&1
)

REM Wait for the technician to press a key before rebooting - no automatic
REM timer. Handoff, offline-disk, and log copy above have already
REM completed, so pausing here cannot block any finalization work.
call :FB_TRACE "STEP7 waiting for user keypress before reboot"
call :FB_UI_RESOLVE
if defined FB_UI_SCRIPT (
    "!FB_UI_PS!" -NoProfile -ExecutionPolicy Bypass -File "!FB_UI_SCRIPT!" -Action Done -Text "Image application complete. Remove the USB drive." -Reason "Press any key to continue and reboot..." 2>nul
) else (
    echo.
    echo ============================================================
    echo   Image application complete. Remove the USB drive.
    echo   Press any key to continue and reboot...
    echo ============================================================
    echo.
)
pause >nul
call :FB_TRACE "STEP7 keypress received, rebooting"

wpeutil reboot
exit /b 0

:: -- FB_UI_RESOLVE : locate the PowerShell deploy UI ------------------------
:: Sets FB_UI_SCRIPT when Invoke-FbDeployUi.ps1 is present next to this script.
:: Resolves its own powershell.exe because the UI starts before
:: RESOLVE_POWERSHELL has run. Leaving FB_UI_SCRIPT empty is the signal for
:: every UI subroutine below to fall back to plain echo, so a WinPE without
:: PowerShell still shows readable progress.
:FB_UI_RESOLVE
set "FB_UI_SCRIPT="
if not exist "%~dp0Invoke-FbDeployUi.ps1" exit /b 0
set "FB_UI_PS=X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "!FB_UI_PS!" set "FB_UI_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "!FB_UI_PS!" set "FB_UI_PS=powershell.exe"
set "FB_UI_SCRIPT=%~dp0Invoke-FbDeployUi.ps1"
exit /b 0

:: -- FB_UI_INIT : seed the step plan and paint the first screen -------------
:FB_UI_INIT
call :FB_UI_RESOLVE
if not defined FB_UI_SCRIPT exit /b 0
"!FB_UI_PS!" -NoProfile -ExecutionPolicy Bypass -File "!FB_UI_SCRIPT!" -Action Init -Workflow "!FB_WF_SUBTEXT!" -Steps "!FB_UI_PLAN!" 2>nul
start /b "" "!FB_UI_PS!" -NoProfile -ExecutionPolicy Bypass -File "!FB_UI_SCRIPT!" -Action SpinWatch
exit /b 0

:: -- FB_UI_PROGRESS  step  label ---------------------------------------------
:: Same call contract as the old echo-bar version, so every existing call site
:: is unchanged. Marks the step active (the UI marks earlier steps done).
:FB_UI_PROGRESS
set "_FB_STEP=%~1"
set "_FB_LABEL=%~2"
call :FB_UI_RESOLVE
if defined FB_UI_SCRIPT (
    "!FB_UI_PS!" -NoProfile -ExecutionPolicy Bypass -File "!FB_UI_SCRIPT!" -Action Step -Step !_FB_STEP! -Label "!_FB_LABEL!" 2>nul
    exit /b 0
)
set /a "_FB_FILL=(_FB_STEP*20)/FB_TOTAL_STEPS"
set /a "_FB_PCT=(_FB_STEP*100)/FB_TOTAL_STEPS"
set "_FB_BAR="
for /L %%i in (1,1,!_FB_FILL!) do set "_FB_BAR=!_FB_BAR!#"
set /a "_FB_EMPTY=20-_FB_FILL"
for /L %%i in (1,1,!_FB_EMPTY!) do set "_FB_BAR=!_FB_BAR!-"
echo [!_FB_BAR!] !_FB_PCT!%% !_FB_LABEL!
exit /b 0

:: -- FB_UI_DETAIL  text : update the detail line without changing the step --
:FB_UI_DETAIL
call :FB_UI_RESOLVE
if not defined FB_UI_SCRIPT exit /b 0
"!FB_UI_PS!" -NoProfile -ExecutionPolicy Bypass -File "!FB_UI_SCRIPT!" -Action Detail -Text "%~1" 2>nul
exit /b 0

:: -- FB_FORCE_NEXT_BOOT_INTERNAL --------------------------------------------
:: Sets BS_OK=1 when firmware bootsequence is set for next restart.
:: Logs FORCE_BOOT_RESULT=SUCCESS|FAILED for deterministic post-mortem, then
:: permanently promotes the Windows Boot Manager to the top of the UEFI
:: displayorder so BootOrder itself prefers the internal disk over the USB.
:FB_FORCE_NEXT_BOOT_INTERNAL
set "BS_OK=0"
set "FORCE_BOOT_RESULT=FAILED"
bcdedit /set {fwbootmgr} bootsequence {bootmgr} >> "%LOG%" 2>&1
if !ERRORLEVEL! EQU 0 (
    echo [%DATE% %TIME%] One-time bootsequence set to symbolic {bootmgr} >> "%LOG%"
    set "BS_OK=1"
) else (
    echo [%DATE% %TIME%] symbolic bootsequence failed exit=!ERRORLEVEL! - trying explicit firmware GUIDs >> "%LOG%"
    echo [%DATE% %TIME%] Enumerating firmware entries for Windows Boot Manager GUIDs >> "%LOG%"
    bcdedit /enum FIRMWARE >> "%LOG%" 2>&1

    set "FW_GUIDS="
    for /f "tokens=2 delims={}" %%G in ('bcdedit /enum FIRMWARE 2^>nul ^| findstr /R /C:"^[ ]*identifier"') do (
        set "_G={%%G}"
        echo "!FW_GUIDS!" | findstr /I /C:"!_G!" >nul
        if errorlevel 1 (
            bcdedit /enum "!_G!" 2>nul | findstr /I /C:"Windows Boot Manager" >nul
            if not errorlevel 1 (
                if defined FW_GUIDS (
                    set "FW_GUIDS=!FW_GUIDS! !_G!"
                ) else (
                    set "FW_GUIDS=!_G!"
                )
            )
        )
    )

    if defined FW_GUIDS (
        echo [%DATE% %TIME%] Trying explicit GUIDs: !FW_GUIDS! >> "%LOG%"
        bcdedit /set {fwbootmgr} bootsequence !FW_GUIDS! >> "%LOG%" 2>&1
        if !ERRORLEVEL! EQU 0 (
            echo [%DATE% %TIME%] One-time bootsequence set to explicit GUID list >> "%LOG%"
            set "BS_OK=1"
        ) else (
            echo [%DATE% %TIME%] explicit-GUID bootsequence ALSO failed exit=!ERRORLEVEL! >> "%LOG%"
        )
    ) else (
        echo [%DATE% %TIME%] No Windows Boot Manager GUIDs found in firmware enum >> "%LOG%"
    )
)
if "!BS_OK!"=="1" set "FORCE_BOOT_RESULT=SUCCESS"
echo [%DATE% %TIME%] FORCE_BOOT_RESULT=!FORCE_BOOT_RESULT! >> "%LOG%"
:: Permanently promote Windows Boot Manager to top of UEFI displayorder.
:: bootsequence is one-time only - if it evaporates or fails, the raw BootOrder
:: (displayorder) determines what boots. Without this, USB can sit above the
:: internal disk in BootOrder forever, causing a boot loop on the next power cycle.
if defined FW_GUIDS (
    bcdedit /set {fwbootmgr} displayorder !FW_GUIDS! /addfirst >> "%LOG%" 2>&1
    if !ERRORLEVEL! EQU 0 (
        echo [%DATE% %TIME%] displayorder /addfirst exit=0 - WBM permanently promoted in BootOrder >> "%LOG%"
    ) else (
        echo [%DATE% %TIME%] WARNING: displayorder /addfirst failed exit=!ERRORLEVEL! - boot order may still prefer USB >> "%LOG%"
    )
) else (
    echo [%DATE% %TIME%] WARNING: FW_GUIDS empty - skipping displayorder promotion (bootsequence-only path) >> "%LOG%"
)
if not defined FW_GUIDS (
    bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst >> "%LOG%" 2>&1
    if !ERRORLEVEL! EQU 0 (
        echo [%DATE% %TIME%] displayorder {bootmgr} /addfirst exit=0 >> "%LOG%"
    ) else (
        echo [%DATE% %TIME%] displayorder {bootmgr} /addfirst failed exit=!ERRORLEVEL! (non-fatal) >> "%LOG%"
    )
)
exit /b 0

:: -- FB_TRACE  write a line to the USB trace log (no-op if TRACE unset) -----
:FB_TRACE
if not defined TRACE exit /b 0
echo [%DATE% %TIME%] %~1 >> "%TRACE%" 2>nul
exit /b 0

:: -- FB_DP_RUN  scriptfile  outfile -----------------------------------------
:: Runs diskpart ONCE against a script file, captures its output to a file the
:: parsers read, and copies that output into the deploy log. Parsing a capture
:: file rather than a live pipe is deliberate: a for /f whose command string
:: starts with a double quote is mangled by cmd and never runs. Mirrors the
:: proven implementation in TechInstall-Install.cmd.
:FB_DP_RUN
set "_DPS=%~1"
set "_DPO=%~2"
if not defined _DPS exit /b 0
if not defined _DPO exit /b 0
"!FB_DISKPART!" /s "!_DPS!" > "!_DPO!" 2>&1
type "!_DPO!" >> "%LOG%" 2>nul
exit /b 0

:: -- FB_DISK_OF_LETTER  letter -----------------------------------------------
:FB_DISK_OF_LETTER
set "FB_DOL_DISK="
set "FB_DOL_SRC=none"
set "_DOLL=%~1"
if not defined _DOLL exit /b 0
(
    echo select volume !_DOLL!:
    echo detail volume
) > "!FB_TMPD!\fb_dol_in.txt"
call :FB_DP_RUN "!FB_TMPD!\fb_dol_in.txt" "!FB_TMPD!\fb_dol_out.txt"
call :FB_DOL_PARSE "!FB_TMPD!\fb_dol_out.txt"
if defined FB_DOL_DISK set "FB_DOL_SRC=detail-volume-colon"
if not defined FB_DOL_DISK (
    (
        echo select volume=!_DOLL!
        echo detail volume
    ) > "!FB_TMPD!\fb_dol_in.txt"
    call :FB_DP_RUN "!FB_TMPD!\fb_dol_in.txt" "!FB_TMPD!\fb_dol_out.txt"
    call :FB_DOL_PARSE "!FB_TMPD!\fb_dol_out.txt"
    if defined FB_DOL_DISK set "FB_DOL_SRC=detail-volume-equals"
)
if not defined FB_DOL_DISK (
    call :FB_DOL_WALK "!_DOLL!"
    if defined FB_DOL_DISK set "FB_DOL_SRC=detail-disk-walk"
)
if defined FB_DOL_DISK set "FB_DOL_DISK=!FB_DOL_DISK: =!"
if defined FB_DOL_DISK (
    echo !FB_DOL_DISK!| findstr /R "^[0-9][0-9]*$" >nul 2>&1
    if errorlevel 1 (
        set "FB_DOL_DISK="
        set "FB_DOL_SRC=none"
    )
)
exit /b 0

:: -- FB_DOL_PARSE  capturefile -----------------------------------------------
:FB_DOL_PARSE
set "_DPO=%~1"
if not defined _DPO exit /b 0
if not exist "!_DPO!" exit /b 0
del /f /q "!FB_TMPD!\fb_dol_diskline.txt" >nul 2>&1
findstr /C:"* Disk" "!_DPO!" > "!FB_TMPD!\fb_dol_diskline.txt" 2>nul
if exist "!FB_TMPD!\fb_dol_diskline.txt" (
    for /f "usebackq tokens=3" %%N in ("!FB_TMPD!\fb_dol_diskline.txt") do (
        set "FB_DOL_DISK=%%N"
        goto :FB_DOL_PARSE_DONE
    )
)
:FB_DOL_PARSE_DONE
exit /b 0

:: -- FB_DOL_WALK  letter -----------------------------------------------------
:FB_DOL_WALK
set "_DWL=%~1"
if not defined _DWL exit /b 0
for %%N in (0 1 2 3 4 5 6 7) do (
    (
        echo select disk %%N
        echo detail disk
    ) > "!FB_TMPD!\fb_dw_in.txt"
    call :FB_DP_RUN "!FB_TMPD!\fb_dw_in.txt" "!FB_TMPD!\fb_dw_out.txt"
    findstr /C:"The disk you specified is not valid" "!FB_TMPD!\fb_dw_out.txt" >nul 2>&1
    if errorlevel 1 (
        del /f /q "!FB_TMPD!\fb_dw_volline.txt" >nul 2>&1
        findstr /R /C:"Volume [0-9]" "!FB_TMPD!\fb_dw_out.txt" > "!FB_TMPD!\fb_dw_volline.txt" 2>nul
        if exist "!FB_TMPD!\fb_dw_volline.txt" (
            for /f "usebackq tokens=3" %%L in ("!FB_TMPD!\fb_dw_volline.txt") do (
                if /I "%%L"=="!_DWL!" (
                    set "FB_DOL_DISK=%%N"
                    goto :FB_DOL_WALK_DONE
                )
            )
        )
    )
)
:FB_DOL_WALK_DONE
exit /b 0

:: -- FB_MEDIADISK_PARSE  (legacy alias - use FB_DOL_PARSE) -------------------
:FB_MEDIADISK_PARSE
call :FB_DOL_PARSE "!FB_TMPD!\fb_offline_detail_out.txt"
set "MEDIADISK=!FB_DOL_DISK!"
exit /b 0

:: -- FB_MEDIADISK_PS_FALLBACK  bounded Get-Partition probe -------------------
:: Output goes to a file rather than a backquoted for /f, because that form also
:: starts with a double quote and hits the same cmd mangling; usebackq does not
:: help. The runspace WaitOne timeout keeps a hung Get-Partition from stopping
:: the script before the offline work below.
:FB_MEDIADISK_PS_FALLBACK
if not defined FB_PS exit /b 0
if not defined VLE exit /b 0
echo [%DATE% %TIME%] media-disk fallback: bounded Get-Partition for !VLE!: >> "%LOG%"
"!FB_PS!" -NoProfile -ExecutionPolicy Bypass -Command "$dl='!VLE!'; $rs=[PowerShell]::Create(); [void]$rs.AddScript('param($d) try { $p = Get-Partition -DriveLetter $d -ErrorAction Stop; if ($null -ne $p) { [int]$p.DiskNumber } } catch {}').AddArgument($dl); $ah=$rs.BeginInvoke(); if ($ah.AsyncWaitHandle.WaitOne(6000)) { $rs.EndInvoke($ah) } else { try { $rs.Stop() } catch {} }; $rs.Dispose()" > "!FB_TMPD!\fb_psdisk_out.txt" 2>nul
for /f "usebackq tokens=1" %%a in ("!FB_TMPD!\fb_psdisk_out.txt") do (
    if not defined MEDIADISK set "MEDIADISK=%%a"
)
if defined MEDIADISK set "MEDIADISK_SRC=get-partition"
exit /b 0

:: -- FB_RESOLVE_PAYLOAD_ROOT  locate the FirstBase payload root ------------------
:: The stick is laid out with the payload nested under <vol>\FirstBase\ (this script
:: runs from <vol>\FirstBase\Deploy\), while sources\ stays at the VOLUME ROOT so
:: FIND_SOURCE / FIND_IMAGE_FILE keep using %SRC% ^(= %~d0 or a scanned letter^).
:: FB_PAYLOAD is the folder that owns WUPayload\, Scripts\, Autounattend.xml
:: and LW_VERSION.json. USB logs write to the volume root. On a legacy flat stick it resolves to the
:: volume root, so both layouts work from one code path.
:: FB_PAYLOAD_SELF is always the payload root on the SCRIPT's own volume - used where
:: the script volume and the install-media volume can differ (Split layout).
:FB_RESOLVE_PAYLOAD_ROOT
for %%I in ("%~dp0..") do set "FB_PAYLOAD_SELF=%%~fI"
REM Legacy flat sticks resolve to "D:\" - drop the trailing separator so the value
REM concatenates the same way %SRC% does.
if "!FB_PAYLOAD_SELF:~-1!"=="\" set "FB_PAYLOAD_SELF=!FB_PAYLOAD_SELF:~0,-1!"
set "FB_PAYLOAD="
if exist "!FB_PAYLOAD_SELF!\WUPayload\SetupComplete.cmd" set "FB_PAYLOAD=!FB_PAYLOAD_SELF!"
if not defined FB_PAYLOAD if defined SRC if exist "%SRC%\FirstBase\WUPayload\SetupComplete.cmd" set "FB_PAYLOAD=%SRC%\FirstBase"
if not defined FB_PAYLOAD if defined SRC if exist "%SRC%\WUPayload\SetupComplete.cmd"           set "FB_PAYLOAD=%SRC%"
REM No WUPayload anywhere (WIN-INSTALL / -NoPayload builds): the parent of this
REM Deploy folder is the payload root by construction, in both layouts.
if not defined FB_PAYLOAD set "FB_PAYLOAD=!FB_PAYLOAD_SELF!"
exit /b 0

:: -- FB_PICK_LOGDIR_SRC  choose the USB log folder for the media volume ----------
:FB_PICK_LOGDIR_SRC
set "FB_USB_VOL="
if defined SRC set "FB_USB_VOL=%SRC:~0,2%"
if not defined FB_USB_VOL if defined FB_PAYLOAD set "FB_USB_VOL=!FB_PAYLOAD:~0,2!"
if not defined FB_USB_VOL set "FB_USB_VOL=%~d0"
if /i not "!FB_USB_VOL:~-1!"==":" set "FB_USB_VOL=!FB_USB_VOL!:"
set "FB_USB_LOGDIR_SRC=!FB_USB_VOL!\FirstBase-Logs"
if exist "!FB_USB_VOL!\." (
    if not exist "!FB_USB_LOGDIR_SRC!\" mkdir "!FB_USB_LOGDIR_SRC!" >nul 2>&1
    attrib -H -S "!FB_USB_LOGDIR_SRC!" >nul 2>&1
)
exit /b 0

:: -- FB_FIND_FLAG  filename  ->  FB_FLAG_PATH (empty when absent) ----------------
:: Lab-override flags are hand-dropped by a technician, so accept them at the volume
:: root as well as in the payload root.
:FB_FIND_FLAG
set "FB_FLAG_PATH="
if defined SRC if exist "%SRC%\%~1" set "FB_FLAG_PATH=%SRC%\%~1"
if not defined FB_FLAG_PATH if defined FB_PAYLOAD if exist "!FB_PAYLOAD!\%~1" set "FB_FLAG_PATH=!FB_PAYLOAD!\%~1"
exit /b 0

:: -- FB_BIND_USB_LOG  commit LOG paths only when the USB log folder exists --------
:FB_BIND_USB_LOG
if not defined SRC exit /b 0
call :FB_PICK_LOGDIR_SRC
if exist "!FB_USB_LOGDIR_SRC!\." (
    set "LOG=!FB_USB_LOGDIR_SRC!\FirstBase-Deploy.log"
) else (
    rem USB log dir unavailable on the post-disksetup letter - keep logs on the
    rem validated scratch root so DISM log paths and ">> %LOG%" writes always
    rem resolve to a real directory even when %TEMP% itself does not.
    set "FB_USB_LOGDIR_SRC=!FB_TMPD!"
    set "LOG=!FB_TMPD!\FirstBase-Deploy.log"
)
exit /b 0

:: -- RESOLVE_POWERSHELL / FIND_SOURCE ---------------------------------------
:RESOLVE_POWERSHELL
set "FB_PS="
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "FB_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined FB_PS if exist "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" set "FB_PS=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined FB_PS for /f "delims=" %%P in ('where powershell.exe 2^>nul') do if not defined FB_PS set "FB_PS=%%~fP"
if not defined FB_PS for /f "delims=" %%P in ('dir /s /b "%SystemRoot%\powershell.exe" 2^>nul') do if not defined FB_PS set "FB_PS=%%~fP"
echo [%DATE% %TIME%] RESOLVE_POWERSHELL: FB_PS=%FB_PS% >> "%LOG%"
if not defined FB_PS echo [%DATE% %TIME%] RESOLVE_POWERSHELL: SystemRoot=%SystemRoot% WINDIR=%WINDIR% >> "%LOG%"
exit /b 0

:FIND_SOURCE
set "SRC="
REM Prefer the volume that hosts this script ^(D:\TechInstall.cmd ? try D:\sources\ first^).
REM Scanning C: first can miss split-USB timing or pick the wrong disk if another volume shadows install.* .
set "FBBOOT=%~d0"
if defined FBBOOT if /i not "!FBBOOT:~0,2!"=="\\" (
    if exist "!FBBOOT!\sources\install.wim" (
        set "SRC=!FBBOOT!"
        goto :FIND_SOURCE_DONE
    )
    if exist "!FBBOOT!\sources\install.esd" (
        set "SRC=!FBBOOT!"
        goto :FIND_SOURCE_DONE
    )
    if exist "!FBBOOT!\sources\install.swm" (
        set "SRC=!FBBOOT!"
        goto :FIND_SOURCE_DONE
    )
)
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\sources\install.wim" (
        set "SRC=%%D:"
        goto :FIND_SOURCE_DONE
    )
    if exist "%%D:\sources\install.esd" (
        set "SRC=%%D:"
        goto :FIND_SOURCE_DONE
    )
    if exist "%%D:\sources\install.swm" (
        set "SRC=%%D:"
        goto :FIND_SOURCE_DONE
    )
)
:FIND_SOURCE_DONE
exit /b 0

:: -- FIND_IMAGE_FILE -------------------------------------------------------
:FIND_IMAGE_FILE
set "IMGFILE="
if exist "%SRC%\sources\install.wim" set "IMGFILE=%SRC%\sources\install.wim"
if not defined IMGFILE if exist "%SRC%\sources\install.esd" set "IMGFILE=%SRC%\sources\install.esd"
if not defined IMGFILE if exist "%SRC%\sources\install.swm" set "IMGFILE=%SRC%\sources\install.swm"
exit /b 0

:: -- FAILURES --------------------------------------------------------------
:FAIL1
set "RET=1"
goto :FAIL
:FAIL2
set "RET=2"
goto :FAIL
:FAIL3
set "RET=3"
goto :FAIL
:FAIL4
set "RET=4"
goto :FAIL
:FAIL5
set "RET=5"
goto :FAIL

:FAIL
call :FB_TRACE "FAIL exit=!RET! !ERRMSG!"
title FirstBase ? For Internal Use Only ? FAILED
call :FB_UI_RESOLVE
if defined FB_UI_SCRIPT (
    "!FB_UI_PS!" -NoProfile -ExecutionPolicy Bypass -File "!FB_UI_SCRIPT!" -Action Fail -Reason "!ERRMSG!" -Text "Exit code !RET!   Log: %LOG%" -LogFile "%LOG%" 2>nul
) else (
    echo.
    echo ================================================================
    echo   FirstBase ? Deployment failed
    echo ================================================================
    echo   Reason    : !ERRMSG!
    echo   Exit Code : !RET!
    echo   Log       : %LOG%
    echo.
    echo  ---- Last 10 log lines: ----
    if defined FB_PS (
        "%FB_PS%" -NoProfile -ExecutionPolicy Bypass -Command "if (Test-Path '%LOG%') { Get-Content '%LOG%' -Tail 10 }"
    ) else (
        echo ^(PowerShell not available ? open the log on the USB drive.^)
    )
    echo.
)
  echo  Waiting 60 seconds...
  ping -n 61 127.0.0.1 >nul
echo [%DATE% %TIME%] FAILED exit=!RET! !ERRMSG! >> "%LOG%"
exit /b !RET!

:: -- FB_SHOW_BANNER : legacy no-op -------------------------------------------
:: Splash branding now lives inside Invoke-FbDeployUi.ps1 (Init reveal + header
:: on every paint). Kept so any stray call :FB_SHOW_BANNER does not fail.
:FB_SHOW_BANNER
if not defined FB_WF_SUBTEXT set "FB_WF_SUBTEXT=Install"
goto :eof
