@echo off
setlocal EnableDelayedExpansion

:: This is the LIVE deploy script for the WIN-INSTALL / -NoPayload workflow only
:: (WorkflowProfile.TechInstallScript = "TechInstall-Install.cmd" for the WIN-INSTALL-AMD64
:: / WIN-INSTALL-ARM64 profiles). It is NOT dead code: Invoke-LoneWolfBuild.ps1 (all three
:: build-path functions: Build-Cache / Build-IsoCache / Build-OverlayCache) and BuildEngine.cs
:: both copy THIS file and RENAME it to Deploy\TechInstall.cmd on the USB whenever the build
:: is -NoPayload / WIN-INSTALL - it never appears under its own filename on a built USB. The
:: sibling TechInstall.cmd is the SEPARATE, ALSO-LIVE script used for the full "LoneWolf"
:: workflow (ProvisionMode=lonewolf) in both WIM mode and ISO mode.

title FirstBase - For Internal Use Only

:: WIN-INSTALL variant - WUPayload staging removed.
:: Partitions the disk, applies the image, configures boot, then shuts down.
:: No SetupComplete.cmd / Invoke-WindowsUpdateLoop.ps1 / schtasks involvement.
:: Optional: set TECHINSTALL_WIM_INDEX before launch (default 1).
if not defined TECHINSTALL_WIM_INDEX set "TECHINSTALL_WIM_INDEX=1"
set "FB_TOTAL_STEPS=6"
set "FB_TECHINSTALL_REV=2026-08-24.2"

:: -- Hand the screen to the PowerShell deploy UI --------------------------
set "FB_WF_SUBTEXT=Install"
set "FB_UI_PLAN=WinPE initialized;Disk preparation;Source + image resolved;Applying Windows image;Configuring boot + handoff;Finalizing + shutdown"
call :FB_UI_INIT

:: -- STEP 1: Find source media BEFORE any disk operations ----------------
REM USB volumes can appear slightly after startnet finds TechInstall.cmd ??? retry like WinPE-Startnet.cmd.
set /a FB_SRC_TRY=0
:FB_SRC_PRE_DISK
set /a FB_SRC_TRY+=1
call :FIND_SOURCE
if defined SRC goto :FB_SRC_PRE_DISK_OK
if !FB_SRC_TRY! LSS 15 (
    ping -n 3 127.0.0.1 >nul
    goto :FB_SRC_PRE_DISK
)
set "LOG=X:\FirstBase-Deploy.log"
echo [%DATE% %TIME%] ERROR: No install media after !FB_SRC_TRY! attempts. >> "%LOG%" 2>nul
echo [%DATE% %TIME%]   Check %~d0\sources\ for install.wim / install.esd / install.swm >> "%LOG%" 2>nul
set "ERRMSG=Could not find sources\install.wim, install.esd, or install.swm before disksetup ^(see X:\FirstBase-Deploy.log^)."
goto :FAIL1
:FB_SRC_PRE_DISK_OK

:: Resolve the FirstBase payload root before anything reads Scripts /
:: Autounattend.xml / the USB log folder.
call :FB_RESOLVE_PAYLOAD_ROOT

:: Main log on USB so it survives reboots / WinPE crashes (RAM temp is useless).
:: APPEND mode - prior runs are kept so we can compare attempts after a forced reboot.
set "FB_SCRIPTVOL=%~d0"
if /i not "!FB_SCRIPTVOL:~-1!"==":" set "FB_SCRIPTVOL=!FB_SCRIPTVOL!:"
:: Keep deploy / DISM / trace logs in a visible FirstBase-Logs folder at the volume root.
call :FB_PICK_LOGDIR_SRC
if not exist "!FB_USB_LOGDIR_SRC!\." set "FB_USB_LOGDIR_SRC=X:"
set "LOG=!FB_USB_LOGDIR_SRC!\FirstBase-Deploy.log"
set "FB_USB_VOL_SCRIPT=!FB_PAYLOAD_SELF:~0,2!"
if /i not "!FB_USB_VOL_SCRIPT:~-1!"==":" set "FB_USB_VOL_SCRIPT=!FB_USB_VOL_SCRIPT!:"
set "FB_USB_LOGDIR_SCRIPT=!FB_USB_VOL_SCRIPT!\FirstBase-Logs"
if exist "!FB_USB_VOL_SCRIPT!\." (
    if not exist "!FB_USB_LOGDIR_SCRIPT!\" mkdir "!FB_USB_LOGDIR_SCRIPT!" >nul 2>&1
    attrib -H -S "!FB_USB_LOGDIR_SCRIPT!" >nul 2>&1
)
if not exist "!FB_USB_LOGDIR_SCRIPT!\." set "FB_USB_LOGDIR_SCRIPT=X:"
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
if not defined FB_PS echo WARNING: powershell.exe not in this WinPE ??? disksetup install-media fallback limited; DISM uses dism.exe.

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
) > "%TEMP%\fb_precheck.txt"
echo [%DATE% %TIME%] Pre-disksetup disk state: >> "%LOG%"
"!FB_DISKPART!" /s "%TEMP%\fb_precheck.txt" >> "%LOG%" 2>&1

:: -- STEP 4: Partition internal disk -------------------------------------
title FirstBase ??? For Internal Use Only ??? Disk preparation
set "INSTALLSRC=%SRC%"
call :FB_UI_PROGRESS 2 "Disk preparation"
call :FB_TRACE "STEP2 disksetup begin path=!FB_DISKSETUP_PATH!"
REM [5.1.55] Discard any target-disk export left by an earlier run in this same WinPE session,
REM so STEP 6b can never validate S:/W: against a stale disk number.
if exist "%TEMP%\FirstBase-TargetDisk.txt" del /f /q "%TEMP%\FirstBase-TargetDisk.txt" >nul 2>&1
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

title FirstBase ??? For Internal Use Only

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
echo [%DATE% %TIME%] W: confirmed. >> "%LOG%" 2>nul

:: -- STEP 6b: [5.1.55] Prove S: and W: are the volumes disksetup just created -------------
:: Runs BEFORE the DISM apply so a wrong-volume target costs seconds, not a full image cycle.
call :FB_VERIFY_TARGET_VOLUMES
call :FB_TRACE "STEP6b verify status=!FB_VERIFY_STATUS! msg=!FB_VERIFY_MSG!"
if /I "!FB_VERIFY_STATUS!"=="FAIL" (
    set "ERRMSG=Target volume verification FAILED - !FB_VERIFY_MSG!"
    goto :FAIL6
)

:: -- Pre-DISM: wipe W:\ if stale content from a previous interrupted apply ----
if exist "W:\Windows" (
    echo [%DATE% %TIME%] Pre-DISM: W:\ has stale content - reformatting >> "%LOG%" 2>nul
    echo Y | format W: /FS:NTFS /Q >nul 2>&1
    echo [%DATE% %TIME%] Pre-DISM: W:\ quick-format complete >> "%LOG%" 2>nul
)

:: -- STEP 7: Apply Windows image (PowerShell UI + DISM) -------------------
title FirstBase ??? For Internal Use Only ??? Applying image
call :FB_UI_PROGRESS 4 "Applying Windows image"
echo [%DATE% %TIME%] Starting DISM apply >> "%LOG%"
call :FB_TRACE "STEP4 dism begin IMGFILE=%IMGFILE% INDEX=%TECHINSTALL_WIM_INDEX%"

REM Separate DISM log ??? DISM truncates its target file, so MUST NOT be %LOG%.
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
                dism /Apply-Image /ImageFile:"%IMGFILE%" /SWMFile:"%SWMFILE%" /Index:%TECHINSTALL_WIM_INDEX% /ApplyDir:W:\ /CheckIntegrity /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
            ) else (
                dism /Apply-Image /ImageFile:"%IMGFILE%" /Index:%TECHINSTALL_WIM_INDEX% /ApplyDir:W:\ /CheckIntegrity /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
            )
        )
    ) else (
        echo WARNING: PowerShell missing in WinPE ??? using dism.exe ^(no progress UI^)
        echo [%DATE% %TIME%] DISM: PS script skipped, using dism.exe >> "%LOG%"
        if defined SWMFILE (
            dism /Apply-Image /ImageFile:"%IMGFILE%" /SWMFile:"%SWMFILE%" /Index:%TECHINSTALL_WIM_INDEX% /ApplyDir:W:\ /CheckIntegrity /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
        ) else (
            dism /Apply-Image /ImageFile:"%IMGFILE%" /Index:%TECHINSTALL_WIM_INDEX% /ApplyDir:W:\ /CheckIntegrity /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
        )
    )
) else (
    echo WARNING: Invoke-FirstBaseDismApply.ps1 missing ??? fallback dism.exe
    if defined SWMFILE (
        dism /Apply-Image /ImageFile:"%IMGFILE%" /SWMFile:"%SWMFILE%" /Index:%TECHINSTALL_WIM_INDEX% /ApplyDir:W:\ /CheckIntegrity /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
    ) else (
        dism /Apply-Image /ImageFile:"%IMGFILE%" /Index:%TECHINSTALL_WIM_INDEX% /ApplyDir:W:\ /CheckIntegrity /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
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

title FirstBase ??? For Internal Use Only

:: -- STEP 9: Bootloader ---------------------------------------------------
title FirstBase - For Internal Use Only - Boot files
call :FB_UI_PROGRESS 5 "Configuring boot + handoff"
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
REM defense-in-depth only. USB EFI loaders are left in place. This
REM matches the proven Windows_Installation TechInstall.cmd - firmware handoff
REM is what actually stops the re-image loop on this hardware.
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
call :FB_UI_PROGRESS 6 "Finalizing + shutdown"
echo [%DATE% %TIME%] SUCCESS >> "%LOG%"
call :FB_TRACE "STEP7 success"

set "FB_STAY=0"
call :FB_FIND_FLAG FirstBase-StayInPE.txt
if defined FB_FLAG_PATH set "FB_STAY=1"
if "%FB_STAY%"=="1" (
    echo FirstBase-StayInPE.txt found - staying in WinPE ^(no wpeutil shutdown^).
    echo Full log: %LOG%
    echo [%DATE% %TIME%] SUCCESS - StayInPE override, no shutdown >> "%LOG%"
    exit /b 0
)

echo [%DATE% %TIME%] SUCCESS - preparing shutdown >> "%LOG%"

REM Copy WinPE bootstrap log to USB before shutdown -- MUST run here, before the
REM disk is taken offline below (offline disk makes %SRC% unwritable).
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
    echo [%DATE% %TIME%] WinPE bootstrap log copied to USB ^(FBLOG saved before shutdown^) >> "%LOG%"
)

REM Physical disk # that owns %SRC%. Needed for optional diskpart offline.
REM
REM [5.1.55] This used to parse a live diskpart pipe inline. That parse was written as
REM   for /f ... in ('"!FB_DISKPART!" /s "in.txt" ^| findstr ...')
REM and cmd mangles a for/f command string that STARTS with a double quote, so the command
REM never actually ran and MEDIADISK came back empty on every deploy - which silently
REM skipped the offline-disk step below. The
REM shared FB_DISK_OF_LETTER helper does the same job through a capture file, plus two
REM extra probes, and validates the result is digits.
set "VLE=%SRC:~0,1%"
echo [%DATE% %TIME%] Install media volume detail ^(disk number for offline^): >> "%LOG%"
call :FB_DISK_OF_LETTER !VLE!
set "MEDIADISK=!FB_DOL_DISK!"
set "MEDIADISK_SRC=!FB_DOL_SRC!"
if not defined MEDIADISK call :FB_MEDIADISK_PS_FALLBACK
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
    ) > "%TEMP%\fb_offline.txt"
    "!FB_DISKPART!" /s "%TEMP%\fb_offline.txt" >> "%LOG%" 2>&1
    set "FB_OFFLINE_EC=!ERRORLEVEL!"
    REM The install media disk is now OFFLINE - its %LOG% path (on the USB) no longer
    REM resolves, so any further ">> %LOG%" write would print "The system cannot find the
    REM path specified." to the WinPE console. Re-point LOG to X:\ (a RAM path that
    REM always resolves) BEFORE logging the offline result.
    set "LOG=X:\FirstBase-Deploy.log"
    echo [%DATE% %TIME%]   diskpart offline exit=!FB_OFFLINE_EC! >> "%LOG%" 2>nul
) else (
    echo [%DATE% %TIME%] WARNING: MEDIADISK unset - offline disk skipped; removing data volume letter fallback >> "%LOG%"
    (
        echo select volume !VLE!:
        echo remove letter=!VLE!
    ) > "%TEMP%\fb_eject.txt"
    "!FB_DISKPART!" /s "%TEMP%\fb_eject.txt" >> "%LOG%" 2>&1
)

REM Wait for the technician to press a key before shutting down - no automatic
REM timer. Handoff, offline-disk, and log copy above have already
REM completed, so pausing here cannot block any finalization work.
call :FB_TRACE "STEP7 waiting for user keypress before shutdown"
call :FB_UI_RESOLVE
if defined FB_UI_SCRIPT (
    "!FB_UI_PS!" -NoProfile -ExecutionPolicy Bypass -File "!FB_UI_SCRIPT!" -Action Done -Text "Installation complete. Remove the USB drive." -Reason "Press any key to continue and shut down..." 2>nul
) else (
    echo.
    echo ============================================================
    echo   Installation complete. Remove the USB drive.
    echo   Press any key to continue and shut down...
    echo ============================================================
    echo.
)
pause >nul
call :FB_TRACE "STEP7 keypress received, shutting down"

wpeutil shutdown
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
REM [5.1.55] Census the firmware entries FIRST, unconditionally. Before 5.1.55 the
REM enumeration only ran when the symbolic bootsequence write failed, so on the common
REM success path the deploy log recorded nothing at all about what was in NVRAM.
call :FB_FW_ENUM_CANDIDATES
bcdedit /set {fwbootmgr} bootsequence {bootmgr} >> "%LOG%" 2>&1
if !ERRORLEVEL! EQU 0 (
    echo [%DATE% %TIME%] One-time bootsequence set to symbolic {bootmgr} >> "%LOG%"
    set "BS_OK=1"
) else (
    echo [%DATE% %TIME%] symbolic bootsequence failed exit=!ERRORLEVEL! - trying explicit firmware GUIDs >> "%LOG%"
    if defined FW_BS_LIST (
        echo [%DATE% %TIME%] Trying explicit GUIDs: !FW_BS_LIST! >> "%LOG%"
        bcdedit /set {fwbootmgr} bootsequence !FW_BS_LIST! >> "%LOG%" 2>&1
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
::
:: [5.1.55] The promotion target is now chosen deliberately instead of always being every
:: entry whose description says "Windows Boot Manager". bcdboot adds an NVRAM entry on every
:: imaging run and never removes stale ones, so a repeatedly-imaged device accumulates
:: entries pointing at partitions that disksetup's "clean" has since destroyed. Promoting
:: that whole set into the PERMANENT BootOrder is what lets the first cold boot select a dead
:: entry and fail with winload.efi / 0xc000000f, and is what the firmware reports back as
:: "multiple indistinguishable devices". Selection order, narrowest first:
::   1. entries whose device element IS the verified target ESP. Requires STEP 6b to have
::      returned PASS, so S: is known to be the ESP on the disk disksetup wiped and the ESP
::      bcdboot just wrote.
::   2. symbolic {bootmgr} when the one-time bootsequence write already succeeded - byte-for-
::      byte what this script did on the success path before 5.1.55.
::   3. the full match list - the pre-5.1.55 failure-path behaviour, kept so a firmware that
::      rejects symbolic writes still gets its Windows Boot Manager promoted.
:: This only ever NARROWS the promotion: if the target ESP cannot be identified, the exact
:: prior behaviour runs. No new kind of boot-order manipulation is introduced.
set "FW_PROMOTE={bootmgr}"
set "FW_PROMOTE_WHY=symbolic {bootmgr} - one-time bootsequence already took, no GUID list needed"
if defined FW_GUIDS if not "!BS_OK!"=="1" (
    set "FW_PROMOTE=!FW_GUIDS!"
    set "FW_PROMOTE_WHY=ALL !FW_MATCH_COUNT! Windows Boot Manager firmware entries - pre-5.1.55 fallback, target ESP not identified"
)
if defined FW_GUIDS_TARGET (
    set "FW_PROMOTE=!FW_GUIDS_TARGET!"
    set "FW_PROMOTE_WHY=target-ESP-only - entries whose device element is the verified ESP on the target disk"
)
echo [%DATE% %TIME%] [5.1.55] displayorder promotion target=!FW_PROMOTE! >> "%LOG%"
echo [%DATE% %TIME%] [5.1.55] displayorder promotion reason=!FW_PROMOTE_WHY! >> "%LOG%"
bcdedit /set {fwbootmgr} displayorder !FW_PROMOTE! /addfirst >> "%LOG%" 2>&1
if !ERRORLEVEL! EQU 0 (
    echo [%DATE% %TIME%] displayorder /addfirst exit=0 - WBM permanently promoted in BootOrder >> "%LOG%"
) else (
    echo [%DATE% %TIME%] WARNING: displayorder /addfirst failed exit=!ERRORLEVEL! - boot order may still prefer USB >> "%LOG%"
)
exit /b 0

:: -- FB_FW_ENUM_CANDIDATES  [5.1.55] ----------------------------------------
:: READ-ONLY firmware census. Dumps the complete bcdedit /enum FIRMWARE output to the deploy
:: log, then classifies every entry whose description is "Windows Boot Manager". Outputs:
::   FW_GUIDS        - every match. Same semantics as the pre-5.1.55 variable.
::   FW_GUIDS_TARGET - matches whose device element is the verified target ESP letter.
::   FW_BS_LIST      - the list the one-time bootsequence fallback should use.
::   FW_MATCH_COUNT  - how many entries matched.
::   FW_STALE_COUNT  - matches whose device does not resolve to a lettered volume here.
:FB_FW_ENUM_CANDIDATES
set "FW_GUIDS="
set "FW_GUIDS_TARGET="
set "FW_BS_LIST="
set /a FW_ENTRY_COUNT=0
set /a FW_MATCH_COUNT=0
set /a FW_STALE_COUNT=0
echo [%DATE% %TIME%] [5.1.55] ---- Firmware entry census ---- >> "%LOG%"
echo [%DATE% %TIME%] [5.1.55] complete bcdedit /enum FIRMWARE output follows >> "%LOG%"
bcdedit /enum FIRMWARE >> "%LOG%" 2>&1
echo [%DATE% %TIME%] [5.1.55] end of bcdedit /enum FIRMWARE output >> "%LOG%"
if "!FB_TARGET_VERIFIED!"=="1" (
    echo [%DATE% %TIME%] [5.1.55] target ESP letter used for device matching=!FB_TARGET_ESP_LTR!: >> "%LOG%"
) else (
    echo [%DATE% %TIME%] [5.1.55] target ESP NOT verified - device matching disabled, promotion cannot be narrowed >> "%LOG%"
)
for /f "tokens=2 delims={}" %%G in ('bcdedit /enum FIRMWARE 2^>nul ^| findstr /R /C:"^[ ]*identifier"') do (
    set "_G={%%G}"
    set /a FW_ENTRY_COUNT+=1
    if /I "!_G!"=="{fwbootmgr}" (
        echo [%DATE% %TIME%] [5.1.55]   !_G! skipped - firmware boot manager container, not a boot application >> "%LOG%"
    ) else (
        echo "!FW_GUIDS!" | findstr /I /C:"!_G!" >nul
        if errorlevel 1 call :FB_FW_CLASSIFY_ENTRY "!_G!"
    )
)
echo [%DATE% %TIME%] [5.1.55] firmware entries=!FW_ENTRY_COUNT! WindowsBootManager matches=!FW_MATCH_COUNT! non-resolving=!FW_STALE_COUNT! >> "%LOG%"
echo [%DATE% %TIME%] [5.1.55] all-match list=!FW_GUIDS! >> "%LOG%"
echo [%DATE% %TIME%] [5.1.55] target-ESP list=!FW_GUIDS_TARGET! >> "%LOG%"
if !FW_STALE_COUNT! GTR 0 (
    echo [%DATE% %TIME%] [5.1.55] NOTE: !FW_STALE_COUNT! Windows Boot Manager firmware entries do not point at any lettered volume in this WinPE. >> "%LOG%"
    echo [%DATE% %TIME%] [5.1.55] NOTE: that is the residue bcdboot leaves in NVRAM on every imaging run, and the likely source of the firmware >> "%LOG%"
    echo [%DATE% %TIME%] [5.1.55] NOTE: "multiple indistinguishable devices" error. FirstBase never deletes firmware entries automatically. >> "%LOG%"
    echo [%DATE% %TIME%] [5.1.55] NOTE: OPERATOR ACTION if a device keeps failing its first cold boot - confirm each GUID above against the enum >> "%LOG%"
    echo [%DATE% %TIME%] [5.1.55] NOTE: dump, then remove only the dead ones by hand with: bcdedit /delete {guid} /f >> "%LOG%"
)
set "FW_BS_LIST=!FW_GUIDS!"
if defined FW_GUIDS_TARGET set "FW_BS_LIST=!FW_GUIDS_TARGET!"
exit /b 0

:: -- FB_FW_CLASSIFY_ENTRY  {guid}  [5.1.55] ---------------------------------
:: READ-ONLY. Adds the entry to FW_GUIDS when its description is Windows Boot Manager, logs
:: its device / path / description elements verbatim so a dead partition reference is visible
:: in the deploy log, and adds it to FW_GUIDS_TARGET when its device element names the
:: verified target ESP letter. bcdedit renders a device as "partition=<letter>:" when the
:: volume is currently lettered and as "partition=\Device\HarddiskVolumeN" (or unknown) when
:: it is not, which is what both classifications key off.
:FB_FW_CLASSIFY_ENTRY
set "_FWG=%~1"
if not defined _FWG exit /b 0
bcdedit /enum "!_FWG!" 2>nul | findstr /I /C:"Windows Boot Manager" >nul
if errorlevel 1 exit /b 0
set /a FW_MATCH_COUNT+=1
if defined FW_GUIDS (
    set "FW_GUIDS=!FW_GUIDS! !_FWG!"
) else (
    set "FW_GUIDS=!_FWG!"
)
echo [%DATE% %TIME%] [5.1.55]   candidate !_FWG! elements: >> "%LOG%"
bcdedit /enum "!_FWG!" 2>nul | findstr /R /I /C:"^[ ]*device[ ]" /C:"^[ ]*path[ ]" /C:"^[ ]*description[ ]" >> "%LOG%"
bcdedit /enum "!_FWG!" 2>nul | findstr /R /I /C:"^[ ]*device[ ].*partition=[A-Za-z]:" >nul
if errorlevel 1 (
    set /a FW_STALE_COUNT+=1
    echo [%DATE% %TIME%] [5.1.55]   candidate !_FWG! verdict=NO-LETTERED-VOLUME - device does not resolve to a mounted volume here >> "%LOG%"
) else (
    echo [%DATE% %TIME%] [5.1.55]   candidate !_FWG! verdict=RESOLVES - device points at a currently lettered volume >> "%LOG%"
)
if not "!FB_TARGET_VERIFIED!"=="1" exit /b 0
if not defined FB_TARGET_ESP_LTR exit /b 0
bcdedit /enum "!_FWG!" 2>nul | findstr /R /I /C:"^[ ]*device[ ].*partition=!FB_TARGET_ESP_LTR!:" >nul
if errorlevel 1 exit /b 0
if defined FW_GUIDS_TARGET (
    set "FW_GUIDS_TARGET=!FW_GUIDS_TARGET! !_FWG!"
) else (
    set "FW_GUIDS_TARGET=!_FWG!"
)
echo [%DATE% %TIME%] [5.1.55]   candidate !_FWG! verdict=TARGET-ESP - device is partition=!FB_TARGET_ESP_LTR!: on the verified target disk >> "%LOG%"
exit /b 0

:: -- FB_VERIFY_TARGET_VOLUMES  [5.1.55] --------------------------------------
:: Proves that S: and W: really are the ESP + OS volumes disksetup just created on the target
:: disk, BEFORE anything is written to them. Without this, a pre-existing S:/W: assignment
:: (WinPE-Startnet.cmd can blanket-assign letters to every volume it finds, and diskpart's
:: "assign letter=S" fails SILENTLY when the letter is already taken) leaves "if exist S:\"
:: passing while pointing at a foreign volume - and "bcdboot W:\Windows /s S: /f UEFI" then
:: writes the boot files there, leaving the real new ESP empty. The device then cannot find
:: winload.efi on its first boot.
::
:: Sets FB_VERIFY_STATUS=PASS|FAIL|INDETERMINATE and FB_VERIFY_MSG. On PASS also sets
:: FB_TARGET_VERIFIED=1 and FB_TARGET_ESP_LTR=S, which is what unlocks the target-aware
:: firmware promotion in FB_FW_ENUM_CANDIDATES.
::
:: Only FAIL aborts. A check that cannot run in this WinPE is INDETERMINATE: it is logged
:: loudly and the deploy continues with the wide promotion, because refusing to deploy over a
:: missing diagnostic would be worse than the status quo. Every probe here is read-only -
:: diskpart is only ever asked to select / detail, never to write.
:FB_VERIFY_TARGET_VOLUMES
set "FB_VERIFY_STATUS=INDETERMINATE"
set "FB_VERIFY_MSG=no checks completed"
set "FB_TARGET_VERIFIED=0"
set "FB_TARGET_ESP_LTR="
set "FB_SDISK="
set "FB_WDISK="
set "FB_ESP_TYPE_RESULT=UNKNOWN"
echo [%DATE% %TIME%] [5.1.55] ---- Target volume verification ---- >> "%LOG%"
if not exist "S:\" (
    set "FB_VERIFY_STATUS=FAIL"
    set "FB_VERIFY_MSG=S: does not resolve after disksetup"
    goto :FB_VTV_DONE
)
if not exist "W:\" (
    set "FB_VERIFY_STATUS=FAIL"
    set "FB_VERIFY_MSG=W: does not resolve after disksetup"
    goto :FB_VTV_DONE
)

REM Check 1: neither target letter may be the install media or this script's own volume.
REM FIND_SOURCE scans C: through Z:, so a stale volume holding sources\install.* could put
REM SRC on S: or W: - and bcdboot would then write the boot files onto the USB stick.
set "FB_SRCLTR=%SRC:~0,1%"
set "FB_SCRIPTLTR=%FB_SCRIPTVOL:~0,1%"
echo [%DATE% %TIME%] [5.1.55] letters: target ESP=S: target OS=W: media=!FB_SRCLTR!: script=!FB_SCRIPTLTR!: >> "%LOG%"
if /I "!FB_SRCLTR!"=="S" (
    set "FB_VERIFY_STATUS=FAIL"
    set "FB_VERIFY_MSG=install media resolved to S: which is the target ESP letter"
    goto :FB_VTV_DONE
)
if /I "!FB_SRCLTR!"=="W" (
    set "FB_VERIFY_STATUS=FAIL"
    set "FB_VERIFY_MSG=install media resolved to W: which is the target OS letter"
    goto :FB_VTV_DONE
)
if /I "!FB_SCRIPTLTR!"=="S" (
    set "FB_VERIFY_STATUS=FAIL"
    set "FB_VERIFY_MSG=this script is running from S: which is the target ESP letter"
    goto :FB_VTV_DONE
)
if /I "!FB_SCRIPTLTR!"=="W" (
    set "FB_VERIFY_STATUS=FAIL"
    set "FB_VERIFY_MSG=this script is running from W: which is the target OS letter"
    goto :FB_VTV_DONE
)

REM Check 2: the disk number disksetup actually wiped.
call :FB_READ_TARGET_DISK
echo [%DATE% %TIME%] [5.1.55] disksetup target disk=!FB_TARGET_DISK! source=!FB_TARGET_DISK_SRC! >> "%LOG%"

REM Check 3: which physical disk hosts S: and W:.
call :FB_DISK_OF_LETTER S
set "FB_SDISK=!FB_DOL_DISK!"
set "FB_SDISK_SRC=!FB_DOL_SRC!"
call :FB_DISK_OF_LETTER W
set "FB_WDISK=!FB_DOL_DISK!"
set "FB_WDISK_SRC=!FB_DOL_SRC!"
echo [%DATE% %TIME%] [5.1.55] S: disk=!FB_SDISK! source=!FB_SDISK_SRC! >> "%LOG%"
echo [%DATE% %TIME%] [5.1.55] W: disk=!FB_WDISK! source=!FB_WDISK_SRC! >> "%LOG%"
if defined FB_SDISK if defined FB_WDISK if not "!FB_SDISK!"=="!FB_WDISK!" (
    set "FB_VERIFY_STATUS=FAIL"
    set "FB_VERIFY_MSG=S: is on disk !FB_SDISK! but W: is on disk !FB_WDISK! - not the same physical disk"
    goto :FB_VTV_DONE
)
if defined FB_TARGET_DISK if defined FB_SDISK if not "!FB_SDISK!"=="!FB_TARGET_DISK!" (
    set "FB_VERIFY_STATUS=FAIL"
    set "FB_VERIFY_MSG=S: is on disk !FB_SDISK! but disksetup targeted disk !FB_TARGET_DISK!"
    goto :FB_VTV_DONE
)
if defined FB_TARGET_DISK if defined FB_WDISK if not "!FB_WDISK!"=="!FB_TARGET_DISK!" (
    set "FB_VERIFY_STATUS=FAIL"
    set "FB_VERIFY_MSG=W: is on disk !FB_WDISK! but disksetup targeted disk !FB_TARGET_DISK!"
    goto :FB_VTV_DONE
)

REM Check 4: S: must carry the EFI System Partition GPT type. disksetup always gives the
REM target its own dedicated ESP + MSR + OS partitions, so this expectation is the same for a
REM SPLIT and a SINGLE stick - FB_LAYOUT describes the USB, never the internal disk.
call :FB_CHECK_ESP_TYPE S
echo [%DATE% %TIME%] [5.1.55] S: GPT type=!FB_ESP_TYPE_GUID! verdict=!FB_ESP_TYPE_RESULT! >> "%LOG%"
if /I "!FB_ESP_TYPE_RESULT!"=="OTHER" (
    set "FB_VERIFY_STATUS=FAIL"
    set "FB_VERIFY_MSG=S: GPT type is !FB_ESP_TYPE_GUID! not the ESP type c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
    goto :FB_VTV_DONE
)

set "FB_VERIFY_STATUS=PASS"
set "FB_VERIFY_MSG=S: and W: are both on disk !FB_SDISK! and S: carries the ESP GPT type"
if not defined FB_SDISK set "FB_VERIFY_STATUS=INDETERMINATE"
if not defined FB_WDISK set "FB_VERIFY_STATUS=INDETERMINATE"
if not defined FB_TARGET_DISK set "FB_VERIFY_STATUS=INDETERMINATE"
if /I not "!FB_ESP_TYPE_RESULT!"=="ESP" set "FB_VERIFY_STATUS=INDETERMINATE"
if /I "!FB_VERIFY_STATUS!"=="INDETERMINATE" set "FB_VERIFY_MSG=at least one probe could not run in this WinPE - see the lines above for which"

:FB_VTV_DONE
if /I "!FB_VERIFY_STATUS!"=="PASS" (
    set "FB_TARGET_VERIFIED=1"
    set "FB_TARGET_ESP_LTR=S"
    echo [%DATE% %TIME%] [5.1.55] TARGET VERIFY=PASS - !FB_VERIFY_MSG! >> "%LOG%"
)
if /I "!FB_VERIFY_STATUS!"=="INDETERMINATE" (
    echo [%DATE% %TIME%] [5.1.55] TARGET VERIFY=INDETERMINATE - !FB_VERIFY_MSG! >> "%LOG%"
    echo [%DATE% %TIME%] [5.1.55] TARGET VERIFY=INDETERMINATE - continuing, and the firmware promotion stays wide because the ESP is unproven >> "%LOG%"
    echo   WARNING: could not fully verify S: / W: against the target disk - see the deploy log.
)
if /I "!FB_VERIFY_STATUS!"=="FAIL" (
    echo [%DATE% %TIME%] [5.1.55] TARGET VERIFY=FAIL - !FB_VERIFY_MSG! >> "%LOG%"
    echo [%DATE% %TIME%] [5.1.55] TARGET VERIFY=FAIL - aborting before DISM and bcdboot; writing boot files to the wrong volume is far worse than a failed deploy >> "%LOG%"
)
exit /b 0

:: -- FB_READ_TARGET_DISK  [5.1.55] -------------------------------------------
:: FB_TARGET_DISK = the disk number disksetup wiped, FB_TARGET_DISK_SRC = where it came from.
:: disksetup.cmd runs under its own setlocal, so it exports the number to a file rather than
:: relying on the environment.
:FB_READ_TARGET_DISK
set "FB_TARGET_DISK="
set "FB_TARGET_DISK_SRC=none"
if exist "%TEMP%\FirstBase-TargetDisk.txt" (
    for /f "usebackq tokens=1" %%a in ("%TEMP%\FirstBase-TargetDisk.txt") do (
        if not defined FB_TARGET_DISK set "FB_TARGET_DISK=%%a"
    )
    if defined FB_TARGET_DISK set "FB_TARGET_DISK_SRC=disksetup-export"
)
if not defined FB_TARGET_DISK if exist "%SRC%\FirstBase-Logs\FirstBase-WIPE-PENDING.txt" (
    for /f "usebackq tokens=1,* delims==" %%a in ("%SRC%\FirstBase-Logs\FirstBase-WIPE-PENDING.txt") do (
        if /I "%%~a"=="DiskNumber" if not defined FB_TARGET_DISK set "FB_TARGET_DISK=%%~b"
    )
    if defined FB_TARGET_DISK set "FB_TARGET_DISK_SRC=wipe-pending-marker"
)
if not defined FB_TARGET_DISK if exist "%SRC%\FirstBase-WIPE-PENDING.txt" (
    for /f "usebackq tokens=1,* delims==" %%a in ("%SRC%\FirstBase-WIPE-PENDING.txt") do (
        if /I "%%~a"=="DiskNumber" if not defined FB_TARGET_DISK set "FB_TARGET_DISK=%%~b"
    )
    if defined FB_TARGET_DISK set "FB_TARGET_DISK_SRC=wipe-pending-marker"
)
if not defined FB_TARGET_DISK if exist "%SRC%\FirstBase-UsbLogs\FirstBase-WIPE-PENDING.txt" (
    for /f "usebackq tokens=1,* delims==" %%a in ("%SRC%\FirstBase-UsbLogs\FirstBase-WIPE-PENDING.txt") do (
        if /I "%%~a"=="DiskNumber" if not defined FB_TARGET_DISK set "FB_TARGET_DISK=%%~b"
    )
    if defined FB_TARGET_DISK set "FB_TARGET_DISK_SRC=wipe-pending-marker"
)
if not defined FB_TARGET_DISK (
    REM Last resort: re-derive disksetup's own policy - Disk 0 unless an operator override
    REM file on the USB root names a different disk.
    set "FB_TARGET_DISK=0"
    set "FB_TARGET_DISK_SRC=policy-default-with-override-scan"
    for %%N in (0 1 2 3 4 5 6 7 8 9) do (
        if exist "%SRC%\FirstBase-Disk-%%N.txt" set "FB_TARGET_DISK=%%N"
    )
)
if defined FB_TARGET_DISK set "FB_TARGET_DISK=!FB_TARGET_DISK: =!"
if defined FB_TARGET_DISK (
    echo !FB_TARGET_DISK!| findstr /R "^[0-9][0-9]*$" >nul 2>&1
    if errorlevel 1 (
        set "FB_TARGET_DISK="
        set "FB_TARGET_DISK_SRC=none"
    )
)
exit /b 0

:: -- FB_DISK_OF_LETTER  letter  [5.1.55] -------------------------------------
:: FB_DOL_DISK = physical disk hosting that drive letter (digits only, empty when
:: unresolved), FB_DOL_SRC = which probe answered. READ-ONLY diskpart.
:FB_DISK_OF_LETTER
set "FB_DOL_DISK="
set "FB_DOL_SRC=none"
set "_DOLL=%~1"
if not defined _DOLL exit /b 0
(
    echo select volume !_DOLL!:
    echo detail volume
) > "%TEMP%\fb_dol_in.txt"
call :FB_DP_RUN "%TEMP%\fb_dol_in.txt" "%TEMP%\fb_dol_out.txt"
call :FB_DOL_PARSE "%TEMP%\fb_dol_out.txt"
if defined FB_DOL_DISK set "FB_DOL_SRC=detail-volume-colon"
if not defined FB_DOL_DISK (
    REM diskpart documents SELECT VOLUME={n|d}; the trailing colon above is not part of that
    REM syntax and is rejected by some builds, which prints no Disk row at all.
    (
        echo select volume=!_DOLL!
        echo detail volume
    ) > "%TEMP%\fb_dol_in.txt"
    call :FB_DP_RUN "%TEMP%\fb_dol_in.txt" "%TEMP%\fb_dol_out.txt"
    call :FB_DOL_PARSE
    if defined FB_DOL_DISK set "FB_DOL_SRC=detail-volume-equals"
)
if not defined FB_DOL_DISK (
    call :FB_DOL_WALK "!_DOLL!"
    if defined FB_DOL_DISK set "FB_DOL_SRC=detail-disk-walk"
)
REM See the note in FB_MEDIADISK_PS_FALLBACK: the "if defined" guard is required, because
REM "set VAR=!VAR: =!" on an undefined variable leaves the literal " =" behind.
if defined FB_DOL_DISK set "FB_DOL_DISK=!FB_DOL_DISK: =!"
if defined FB_DOL_DISK (
    echo !FB_DOL_DISK!| findstr /R "^[0-9][0-9]*$" >nul 2>&1
    if errorlevel 1 (
        set "FB_DOL_DISK="
        set "FB_DOL_SRC=none"
    )
)
exit /b 0

:: -- FB_MEDIADISK_PS_FALLBACK  [5.1.55] ---------------------------------------
:: Last-resort media-disk probe. Bounded on purpose: on this hardware a plain Get-Partition
:: call has hung indefinitely right after bcdboot, which used to stop the script before
:: offline-disk ever ran, so the call lives in an in-process runspace with a
:: 6-second AsyncWaitHandle timeout and control ALWAYS returns.
::
:: Get-Partition also needs the Storage module, which needs the WinPE-StorageWMI optional
:: component - not one of the four cabs this WinPE ships - so this usually answers nothing.
:: Its output goes to a file rather than being read from a backquoted for/f command, because
:: that form starts with a double quote and cmd mangles it (see FB_DP_RUN).
:FB_MEDIADISK_PS_FALLBACK
if not defined FB_PS exit /b 0
if not defined VLE exit /b 0
echo [%DATE% %TIME%] [5.1.55] media-disk fallback: bounded Get-Partition for !VLE!: >> "%LOG%"
"%FB_PS%" -NoProfile -ExecutionPolicy Bypass -Command "$dl='!VLE!'; $rs=[PowerShell]::Create(); [void]$rs.AddScript('param($d) try { $p = Get-Partition -DriveLetter $d -ErrorAction Stop; if ($null -ne $p) { [int]$p.DiskNumber } } catch {}').AddArgument($dl); $ah=$rs.BeginInvoke(); if ($ah.AsyncWaitHandle.WaitOne(6000)) { $rs.EndInvoke($ah) } else { try { $rs.Stop() } catch {} }; $rs.Dispose()" > "%TEMP%\fb_psdisk_out.txt" 2>nul
for /f "usebackq tokens=1" %%a in ("%TEMP%\fb_psdisk_out.txt") do (
    if not defined MEDIADISK set "MEDIADISK=%%a"
)
REM [5.1.55] The "if defined" guard is load-bearing. "set VAR=!VAR: =!" on an UNDEFINED
REM variable does not yield an empty string - cmd leaves the literal " =" behind, which then
REM satisfies "if defined VAR" with junk. That is precisely how the deploy log came to read
REM "Install media is on Disk  =" while the self-wipe comparisons silently no-opped.
if defined MEDIADISK set "MEDIADISK=!MEDIADISK: =!"
if defined MEDIADISK (
    echo !MEDIADISK!| findstr /R "^[0-9][0-9]*$" >nul 2>&1
    if errorlevel 1 set "MEDIADISK="
)
if defined MEDIADISK set "MEDIADISK_SRC=get-partition"
exit /b 0

:: -- FB_DP_RUN  scriptfile  outfile  [5.1.55] ---------------------------------
:: Runs diskpart ONCE against a script file, captures its output to a file that the parsers
:: read, and copies that output into the deploy log.
::
:: Everything downstream parses the CAPTURE FILE rather than a live pipe on purpose. A
:: for /f whose command string STARTS with a double quote - as in
::   for /f ... in ('"!FB_DISKPART!" /s "in.txt" ^| findstr ...')
:: - is mangled by cmd when it wraps the string for its "cmd /c" subshell, so the command
:: never runs and the loop body never executes. Every historical inline diskpart parse in
:: this pipeline was written that way, which is why the deploy log has always reported an
:: empty install-media disk number. Reading a plain file has no quoting hazard at all, and
:: it also halves the number of diskpart invocations.
:FB_DP_RUN
set "_DPS=%~1"
set "_DPO=%~2"
if not defined _DPS exit /b 0
if not defined _DPO exit /b 0
"!FB_DISKPART!" /s "!_DPS!" > "!_DPO!" 2>&1
type "!_DPO!" >> "%LOG%" 2>nul
exit /b 0

:: -- FB_DOL_PARSE  [5.1.55]  parse "* Disk N" from detail volume ------------
:FB_DOL_PARSE
set "_DPO=%~1"
if not defined _DPO set "_DPO=%TEMP%\fb_dol_out.txt"
if not exist "!_DPO!" exit /b 0
del /f /q "%TEMP%\fb_dol_diskline.txt" >nul 2>&1
findstr /C:"* Disk" "!_DPO!" > "%TEMP%\fb_dol_diskline.txt" 2>nul
if exist "%TEMP%\fb_dol_diskline.txt" (
    for /f "usebackq tokens=3" %%N in ("%TEMP%\fb_dol_diskline.txt") do (
        set "FB_DOL_DISK=%%N"
        goto :FB_DOL_PARSE_DONE
    )
)
:FB_DOL_PARSE_DONE
exit /b 0

:: -- FB_DOL_WALK  letter  [5.1.55] -------------------------------------------
:: Walks disks 0-7 and matches the Ltr column of "detail disk". Independent of the
:: "select volume" syntax entirely, so it answers even when both forms above are rejected.
:FB_DOL_WALK
set "_DWL=%~1"
if not defined _DWL exit /b 0
for %%N in (0 1 2 3 4 5 6 7) do (
        (
            echo select disk %%N
            echo detail disk
        ) > "%TEMP%\fb_dw_in.txt"
        call :FB_DP_RUN "%TEMP%\fb_dw_in.txt" "%TEMP%\fb_dw_out.txt"
        findstr /C:"The disk you specified is not valid" "%TEMP%\fb_dw_out.txt" >nul 2>&1
        if errorlevel 1 (
            del /f /q "%TEMP%\fb_dw_volline.txt" >nul 2>&1
            findstr /R /C:"Volume [0-9]" "%TEMP%\fb_dw_out.txt" > "%TEMP%\fb_dw_volline.txt" 2>nul
            if exist "%TEMP%\fb_dw_volline.txt" (
                for /f "usebackq tokens=3" %%L in ("%TEMP%\fb_dw_volline.txt") do (
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

:: -- FB_CHECK_ESP_TYPE  letter  [5.1.55] -------------------------------------
:: FB_ESP_TYPE_RESULT = ESP | OTHER | UNKNOWN, FB_ESP_TYPE_GUID = the raw Type value.
:: UNKNOWN means diskpart printed nothing GUID-shaped, and is deliberately NOT a failure -
:: an unexpected diskpart output format must never block an otherwise good deploy. Only a
:: value that IS GUID-shaped and is NOT the ESP type counts as a real mismatch.
:FB_CHECK_ESP_TYPE
set "FB_ESP_TYPE_RESULT=UNKNOWN"
set "FB_ESP_TYPE_GUID="
set "_ETL=%~1"
if not defined _ETL exit /b 0
(
    echo select volume !_ETL!:
    echo detail partition
) > "%TEMP%\fb_esptype_in.txt"
echo [%DATE% %TIME%] [5.1.55] detail partition for !_ETL!: follows >> "%LOG%"
call :FB_DP_RUN "%TEMP%\fb_esptype_in.txt" "%TEMP%\fb_esptype_out.txt"
call :FB_ESP_TYPE_PARSE
if not defined FB_ESP_TYPE_GUID (
    (
        echo select volume=!_ETL!
        echo detail partition
    ) > "%TEMP%\fb_esptype_in.txt"
    call :FB_DP_RUN "%TEMP%\fb_esptype_in.txt" "%TEMP%\fb_esptype_out.txt"
    call :FB_ESP_TYPE_PARSE
)
if not defined FB_ESP_TYPE_GUID exit /b 0
if defined FB_ESP_TYPE_GUID set "FB_ESP_TYPE_GUID=!FB_ESP_TYPE_GUID: =!"
if not defined FB_ESP_TYPE_GUID exit /b 0
set "_ETSHAPE=0"
if "!FB_ESP_TYPE_GUID:~8,1!"=="-" if "!FB_ESP_TYPE_GUID:~13,1!"=="-" set "_ETSHAPE=1"
if "!_ETSHAPE!"=="0" exit /b 0
if /I "!FB_ESP_TYPE_GUID!"=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" (
    set "FB_ESP_TYPE_RESULT=ESP"
) else (
    set "FB_ESP_TYPE_RESULT=OTHER"
)
exit /b 0

:: -- FB_ESP_TYPE_PARSE  [5.1.55]  pull the "Type : <guid>" line ---------------
:FB_ESP_TYPE_PARSE
for /f "tokens=1,* delims=:" %%a in ('findstr /R /I /C:"^[ ]*Type[ ]*:" "%TEMP%\fb_esptype_out.txt" 2^>nul') do (
    if not defined FB_ESP_TYPE_GUID set "FB_ESP_TYPE_GUID=%%b"
)
exit /b 0

:: -- FB_TRACE  write a line to the USB trace log (no-op if TRACE unset) -----
:FB_TRACE
if not defined TRACE exit /b 0
echo [%DATE% %TIME%] %~1 >> "%TRACE%" 2>nul
exit /b 0

:: -- FB_RESOLVE_PAYLOAD_ROOT  locate the FirstBase payload root ------------------
:: The stick is laid out with the payload nested under <vol>\FirstBase\ (this script
:: runs from <vol>\FirstBase\Deploy\), while sources\ stays at the VOLUME ROOT so
:: FIND_SOURCE / FIND_IMAGE_FILE keep using %SRC% ^(= %~d0 or a scanned letter^).
:: FB_PAYLOAD is the folder that owns Scripts\ and Autounattend.xml. USB logs write to the volume root.
:: WIN-INSTALL ships no WUPayload\, so this anchors on Autounattend.xml the way
:: TechInstall-QuickInstall.cmd does, with the parent of this Deploy folder as the final
:: fallback - correct in both layouts by construction, so one code path serves the nested
:: and the legacy flat stick.
:: FB_PAYLOAD_SELF is always the payload root on the SCRIPT's own volume - used where
:: the script volume and the install-media volume can differ (Split layout).
:FB_RESOLVE_PAYLOAD_ROOT
for %%I in ("%~dp0..") do set "FB_PAYLOAD_SELF=%%~fI"
REM Legacy flat sticks resolve to "D:\" - drop the trailing separator so the value
REM concatenates the same way %SRC% does.
if "!FB_PAYLOAD_SELF:~-1!"=="\" set "FB_PAYLOAD_SELF=!FB_PAYLOAD_SELF:~0,-1!"
set "FB_PAYLOAD="
if exist "!FB_PAYLOAD_SELF!\Autounattend.xml" set "FB_PAYLOAD=!FB_PAYLOAD_SELF!"
if not defined FB_PAYLOAD if exist "!FB_PAYLOAD_SELF!\autounattend.xml" set "FB_PAYLOAD=!FB_PAYLOAD_SELF!"
if not defined FB_PAYLOAD if defined SRC if exist "%SRC%\FirstBase\Autounattend.xml" set "FB_PAYLOAD=%SRC%\FirstBase"
if not defined FB_PAYLOAD if defined SRC if exist "%SRC%\Autounattend.xml"           set "FB_PAYLOAD=%SRC%"
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
    REM USB log dir unavailable on the post-disksetup letter - keep logs in X:\
    REM so DISM log paths and ">> %LOG%" writes always resolve to a real directory.
    set "FB_USB_LOGDIR_SRC=X:"
    set "LOG=X:\FirstBase-Deploy.log"
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
REM Prefer the volume that hosts this script ^(D:\TechInstall.cmd ??? try D:\sources\ first^).
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
:: [5.1.55] Exit 6 = the post-disksetup target-volume verification rejected S: or W:.
:FAIL6
set "RET=6"
goto :FAIL

:FAIL
call :FB_TRACE "FAIL exit=!RET! !ERRMSG!"
title FirstBase ??? For Internal Use Only ??? FAILED
call :FB_UI_RESOLVE
if defined FB_UI_SCRIPT (
    "!FB_UI_PS!" -NoProfile -ExecutionPolicy Bypass -File "!FB_UI_SCRIPT!" -Action Fail -Reason "!ERRMSG!" -Text "Exit code !RET!   Log: %LOG%" -LogFile "%LOG%" 2>nul
) else (
    echo.
    echo ================================================================
    echo   FirstBase ??? Deployment failed
    echo ================================================================
    echo   Reason    : !ERRMSG!
    echo   Exit Code : !RET!
    echo   Log       : %LOG%
    echo.
    echo  ---- Last 10 log lines: ----
    if defined FB_PS (
        "%FB_PS%" -NoProfile -ExecutionPolicy Bypass -Command "if (Test-Path '%LOG%') { Get-Content '%LOG%' -Tail 10 }"
    ) else (
        echo ^(PowerShell not available ??? open the log on the USB drive.^)
    )
    echo.
)
echo  Waiting 60 seconds...
timeout /t 60 >nul
echo [%DATE% %TIME%] FAILED exit=!RET! !ERRMSG! >> "%LOG%" 2>nul
exit /b !RET!
