@echo off
setlocal EnableDelayedExpansion

:: FirstBase - QUICK-INSTALL deploy script (payload-free clean-room minimal).
:: Copied and RENAMED to Deploy\TechInstall.cmd on the built USB by
:: Invoke-LoneWolfBuild.ps1 for the QUICK-INSTALL-AMD64 / QUICK-INSTALL-ARM64
:: profiles (-QuickInstall). It NEVER appears under its own filename on a stick.
:: Sequence: find media -> disksetup (partition) -> DISM apply -> offline unattend
:: -> bcdboot -> firmware handoff -> shutdown. No FirstBase payload, no
:: SetupComplete arming, no update loop, no seal/sysprep, no reaper.
:: Optional: set QUICKINSTALL_WIM_INDEX before launch (default 1).

title FirstBase Quick Install - For Internal Use Only

if not defined QUICKINSTALL_WIM_INDEX set "QUICKINSTALL_WIM_INDEX=1"
set "FB_QI_REV=2026-08-24.2"
set "FB_TOTAL_STEPS=6"
set "LOG=X:\FirstBase-QuickInstall.log"

:: -- Hand the screen to the PowerShell deploy UI (splash + steps in one surface) --
set "FB_WF_SUBTEXT=No Updates"
set "FB_UI_PLAN=WinPE ready - source media found;Preparing the target disk;Disk prepared - image source resolved;Applying the Windows image;Configuring boot + handoff;Done"
call :FB_UI_INIT

echo [%DATE% %TIME%] FirstBase Quick Install started > "%LOG%" 2>nul
echo [%DATE% %TIME%] revision %FB_QI_REV% >> "%LOG%" 2>nul

:: -- STEP 1: find install media BEFORE any disk operations ----------------
set /a FB_TRY=0
:QI_SRC_PRE
set /a FB_TRY+=1
call :FIND_SOURCE
if defined SRC goto :QI_SRC_PRE_OK
if !FB_TRY! LSS 15 (
    ping -n 3 127.0.0.1 >nul
    goto :QI_SRC_PRE
)
set "ERRMSG=No install media found ^(need sources\install.wim, .esd, or .swm^)."
goto :FAIL
:QI_SRC_PRE_OK

call :RESOLVE_PAYLOAD_ROOT
call :BIND_USB_LOG
call :RESOLVE_POWERSHELL
echo [%DATE% %TIME%] Source media: %SRC% payload root: !FB_PAYLOAD! >> "%LOG%"
if not defined FB_PS echo WARNING: powershell.exe not in this WinPE - DISM uses dism.exe ^(no progress UI^).
call :FB_UI_PROGRESS 1 "WinPE ready - source media found"

:: -- STEP 2: partition the target disk via disksetup.cmd ------------------
set "FB_DISKSETUP="
if exist "%~dp0disksetup.cmd" set "FB_DISKSETUP=%~dp0disksetup.cmd"
if not defined FB_DISKSETUP if exist "!FB_PAYLOAD!\Deploy\disksetup.cmd" set "FB_DISKSETUP=!FB_PAYLOAD!\Deploy\disksetup.cmd"
if not defined FB_DISKSETUP if exist "%SRC%\Deploy\disksetup.cmd" set "FB_DISKSETUP=%SRC%\Deploy\disksetup.cmd"
if not defined FB_DISKSETUP (
    set "ERRMSG=disksetup.cmd not found in Deploy folder."
    goto :FAIL
)
if exist "X:\disksetup.cmd" del /f /q "X:\disksetup.cmd" >nul 2>&1
copy /y "!FB_DISKSETUP!" "X:\disksetup.cmd" >nul 2>&1
set "FB_DISKSETUP_RUN=!FB_DISKSETUP!"
if exist "X:\disksetup.cmd" set "FB_DISKSETUP_RUN=X:\disksetup.cmd"

title FirstBase Quick Install - For Internal Use Only - Disk preparation
call :FB_UI_PROGRESS 2 "Preparing the target disk"
echo [%DATE% %TIME%] Running disksetup from !FB_DISKSETUP_RUN! >> "%LOG%"
set "INSTALLSRC=%SRC%"
call "!FB_DISKSETUP_RUN!"
set "DSERR=!ERRORLEVEL!"
set "INSTALLSRC="
echo [%DATE% %TIME%] disksetup exit=!DSERR! >> "%LOG%"
if not "!DSERR!"=="0" (
    set "ERRMSG=disksetup failed ^(exit !DSERR!^)."
    goto :FAIL
)

:: -- STEP 3: re-find media AFTER disksetup (letters shift) ----------------
set "SRC="
set /a FB_TRY=0
:QI_SRC_POST
set /a FB_TRY+=1
call :FIND_SOURCE
if defined SRC goto :QI_SRC_POST_OK
if !FB_TRY! LSS 15 (
    ping -n 3 127.0.0.1 >nul
    goto :QI_SRC_POST
)
set "ERRMSG=Lost install media after disksetup."
goto :FAIL
:QI_SRC_POST_OK
call :RESOLVE_PAYLOAD_ROOT
call :BIND_USB_LOG
echo [%DATE% %TIME%] Source media after disksetup: %SRC% >> "%LOG%"
title FirstBase Quick Install - For Internal Use Only
call :FB_UI_PROGRESS 3 "Disk prepared - image source resolved"

:: -- STEP 4: locate the Windows image ------------------------------------
call :FIND_IMAGE
if not defined IMGFILE (
    set "ERRMSG=No install.wim, install.esd, or install.swm under %SRC%\sources."
    goto :FAIL
)
set "SWMFILE="
if /I "!IMGFILE:~-4!"==".swm" set "SWMFILE=%SRC%\sources\install*.swm"
echo [%DATE% %TIME%] Image=!IMGFILE! Index=%QUICKINSTALL_WIM_INDEX% SWM=!SWMFILE! >> "%LOG%"

if not exist "W:\" (
    set "ERRMSG=W: ^(target OS volume^) not found after disksetup."
    goto :FAIL
)
if not exist "S:\" (
    set "ERRMSG=S: ^(target ESP^) not found after disksetup."
    goto :FAIL
)

:: -- STEP 5: apply the Windows image (PowerShell UI + DISM) --------------
title FirstBase Quick Install - For Internal Use Only - Applying image
call :FB_UI_PROGRESS 4 "Applying the Windows image"
echo [%DATE% %TIME%] Starting DISM apply >> "%LOG%"

REM Separate DISM log - DISM truncates its target file, so MUST NOT be %LOG%.
set "DISMLOG=%FB_USB_LOGDIR%\FirstBase-QuickInstall-DISM.log"
set "DISMWRAPLOG=%FB_USB_LOGDIR%\FirstBase-QuickInstall-DISM-wrapper.log"
echo [%DATE% %TIME%] DISM /LogPath: %DISMLOG% >> "%LOG%"
echo [%DATE% %TIME%] DISM wrapper log: %DISMWRAPLOG% >> "%LOG%"
echo.>> "%DISMWRAPLOG%" 2>nul
echo ===== %DATE% %TIME% NEW RUN ===== >> "%DISMWRAPLOG%" 2>nul
echo [%DATE% %TIME%] IMGFILE=%IMGFILE% SWMFILE=%SWMFILE% INDEX=%QUICKINSTALL_WIM_INDEX% APPLYDIR=W:\ >> "%DISMWRAPLOG%" 2>nul

set "PSAPPLY=!FB_PAYLOAD!\Scripts\Invoke-FirstBaseDismApply.ps1"
if not exist "!PSAPPLY!" if exist "!FB_PAYLOAD!\Deploy\Invoke-FirstBaseDismApply.ps1" set "PSAPPLY=!FB_PAYLOAD!\Deploy\Invoke-FirstBaseDismApply.ps1"
if not exist "!PSAPPLY!" if exist "%SRC%\Scripts\Invoke-FirstBaseDismApply.ps1"       set "PSAPPLY=%SRC%\Scripts\Invoke-FirstBaseDismApply.ps1"
if not exist "!PSAPPLY!" if exist "%SRC%\Deploy\Invoke-FirstBaseDismApply.ps1"        set "PSAPPLY=%SRC%\Deploy\Invoke-FirstBaseDismApply.ps1"
echo [%DATE% %TIME%] DISM helper script: !PSAPPLY! >> "%LOG%"
if exist "%PSAPPLY%" (
    if defined FB_PS (
        if defined SWMFILE (
            "%FB_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PSAPPLY%" -ImageFile "%IMGFILE%" -SwmFilePattern "%SWMFILE%" -Index %QUICKINSTALL_WIM_INDEX% -ApplyDir W:\ -LogPath "%DISMLOG%" -WrapperLog "%DISMWRAPLOG%"
        ) else (
            "%FB_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PSAPPLY%" -ImageFile "%IMGFILE%" -Index %QUICKINSTALL_WIM_INDEX% -ApplyDir W:\ -LogPath "%DISMLOG%" -WrapperLog "%DISMWRAPLOG%"
        )
        set "PSAPPLYEC=!ERRORLEVEL!"
        if not "!PSAPPLYEC!"=="0" (
            echo [%DATE% %TIME%] WARNING: DISM PowerShell helper failed ^(exit !PSAPPLYEC!^). Retrying with dism.exe. >> "%LOG%"
            echo [%DATE% %TIME%] WARNING: DISM PowerShell helper failed ^(exit !PSAPPLYEC!^). Retrying with dism.exe. >> "%DISMWRAPLOG%" 2>nul
            if defined SWMFILE (
                dism /Apply-Image /ImageFile:"%IMGFILE%" /SWMFile:"%SWMFILE%" /Index:%QUICKINSTALL_WIM_INDEX% /ApplyDir:W:\ /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
            ) else (
                dism /Apply-Image /ImageFile:"%IMGFILE%" /Index:%QUICKINSTALL_WIM_INDEX% /ApplyDir:W:\ /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
            )
        )
    ) else (
        echo WARNING: PowerShell missing in WinPE - using dism.exe ^(no progress UI^)
        echo [%DATE% %TIME%] DISM: PS script skipped, using dism.exe >> "%LOG%"
        if defined SWMFILE (
            dism /Apply-Image /ImageFile:"%IMGFILE%" /SWMFile:"%SWMFILE%" /Index:%QUICKINSTALL_WIM_INDEX% /ApplyDir:W:\ /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
        ) else (
            dism /Apply-Image /ImageFile:"%IMGFILE%" /Index:%QUICKINSTALL_WIM_INDEX% /ApplyDir:W:\ /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
        )
    )
) else (
    echo WARNING: Invoke-FirstBaseDismApply.ps1 missing - fallback dism.exe
    if defined SWMFILE (
        dism /Apply-Image /ImageFile:"%IMGFILE%" /SWMFile:"%SWMFILE%" /Index:%QUICKINSTALL_WIM_INDEX% /ApplyDir:W:\ /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
    ) else (
        dism /Apply-Image /ImageFile:"%IMGFILE%" /Index:%QUICKINSTALL_WIM_INDEX% /ApplyDir:W:\ /LogPath:"%DISMLOG%" >> "%DISMWRAPLOG%" 2>&1
    )
)
set "DISMEC=%ERRORLEVEL%"
echo [%DATE% %TIME%] DISM exit=!DISMEC! >> "%LOG%"
echo [%DATE% %TIME%] DISM invoke exit: !DISMEC! >> "%DISMWRAPLOG%" 2>nul
if not "!DISMEC!"=="0" (
    set "ERRMSG=DISM apply failed ^(exit !DISMEC!^)."
    goto :FAIL
)
echo [%DATE% %TIME%] DISM apply succeeded. >> "%LOG%"
title FirstBase Quick Install - For Internal Use Only

:: -- STEP 6: offline unattend so the device boots to a clean OOBE ---------
:: Direct DISM apply (no setup.exe) means there is no Windows Setup
:: edition/disk menu to suppress; this offline unattend only tidies OOBE and
:: still shows the region / keyboard / account screens for the end user.
set "FB_UNATTEND="
if exist "!FB_PAYLOAD!\Autounattend.xml" set "FB_UNATTEND=!FB_PAYLOAD!\Autounattend.xml"
if not defined FB_UNATTEND if exist "!FB_PAYLOAD!\autounattend.xml" set "FB_UNATTEND=!FB_PAYLOAD!\autounattend.xml"
if not defined FB_UNATTEND if exist "%SRC%\Autounattend.xml"        set "FB_UNATTEND=%SRC%\Autounattend.xml"
if not defined FB_UNATTEND if exist "%SRC%\autounattend.xml"        set "FB_UNATTEND=%SRC%\autounattend.xml"
if defined FB_UNATTEND (
    if not exist "W:\Windows\Panther" mkdir "W:\Windows\Panther" >nul 2>&1
    copy /y "!FB_UNATTEND!" "W:\Windows\Panther\unattend.xml" >> "%LOG%" 2>&1
    echo [%DATE% %TIME%] Copied offline unattend to W:\Windows\Panther\unattend.xml >> "%LOG%"
) else (
    echo [%DATE% %TIME%] No autounattend.xml on media - stock Windows OOBE will run. >> "%LOG%"
)

:: -- STEP 7: bootloader + firmware handoff -------------------------------
title FirstBase Quick Install - For Internal Use Only - Boot files
call :FB_UI_PROGRESS 5 "Configuring boot + handoff"
echo [%DATE% %TIME%] Running bcdboot >> "%LOG%"
bcdboot W:\Windows /s S: /f UEFI >> "%LOG%" 2>&1
if !ERRORLEVEL! NEQ 0 (
    set "ERRMSG=bcdboot failed ^(exit !ERRORLEVEL!^)."
    goto :FAIL
)
echo [%DATE% %TIME%] bcdboot succeeded. >> "%LOG%"

:: Prefer the internal Windows Boot Manager on the next boot and permanently,
:: so firmware hands off to the freshly installed disk instead of re-running
:: the installer USB. Best-effort - failures are logged and non-fatal.
bcdedit /deletevalue {fwbootmgr} bootsequence >> "%LOG%" 2>&1
bcdedit /set {fwbootmgr} bootsequence {bootmgr} >> "%LOG%" 2>&1
bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst >> "%LOG%" 2>&1

:: Quiet the freshly written boot manager so it does not idle on a menu.
set "BCDSTORE="
if exist "S:\EFI\Microsoft\Boot\BCD" set "BCDSTORE=S:\EFI\Microsoft\Boot\BCD"
if not defined BCDSTORE if exist "S:\Boot\BCD" set "BCDSTORE=S:\Boot\BCD"
if defined BCDSTORE (
    bcdedit /store "!BCDSTORE!" /set {bootmgr} timeout 0 >> "%LOG%" 2>&1
    bcdedit /store "!BCDSTORE!" /set {bootmgr} displaybootmenu no >> "%LOG%" 2>&1
)

echo [%DATE% %TIME%] SUCCESS >> "%LOG%"
title FirstBase Quick Install - For Internal Use Only - Complete
call :FB_UI_PROGRESS 6 "Done"

call :FB_UI_RESOLVE
if defined FB_UI_SCRIPT (
    "!FB_UI_PS!" -NoProfile -ExecutionPolicy Bypass -File "!FB_UI_SCRIPT!" -Action Done -Text "Windows install complete. Remove the USB drive." -Reason "Press any key to shut down..." 2>nul
) else (
    echo.
    echo ============================================================
    echo   Windows install complete. Remove the USB drive.
    echo   Press any key to shut down...
    echo ============================================================
    echo.
)
pause >nul
wpeutil shutdown
exit /b 0

:: -- FIND_SOURCE : first volume carrying sources\install.* ----------------
:FIND_SOURCE
set "SRC="
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

:: -- FIND_IMAGE : resolve IMGFILE under %SRC%\sources ---------------------
:FIND_IMAGE
set "IMGFILE="
if exist "%SRC%\sources\install.wim" set "IMGFILE=%SRC%\sources\install.wim"
if not defined IMGFILE if exist "%SRC%\sources\install.esd" set "IMGFILE=%SRC%\sources\install.esd"
if not defined IMGFILE if exist "%SRC%\sources\install.swm" set "IMGFILE=%SRC%\sources\install.swm"
exit /b 0

:: -- RESOLVE_PAYLOAD_ROOT : locate the FirstBase payload root -------------
:: The stick nests the payload under <vol>\FirstBase\ (this script runs from
:: <vol>\FirstBase\Deploy\) while sources\ stays at the VOLUME ROOT, so %SRC%
:: keeps pointing at the root and FB_PAYLOAD owns Autounattend.xml and Scripts\.
:: USB logs write to <vol>\FirstBase-Logs (visible). A legacy flat stick resolves FB_PAYLOAD to the
:: volume root, so one code path serves both layouts.
:RESOLVE_PAYLOAD_ROOT
for %%I in ("%~dp0..") do set "FB_PAYLOAD_SELF=%%~fI"
if "!FB_PAYLOAD_SELF:~-1!"=="\" set "FB_PAYLOAD_SELF=!FB_PAYLOAD_SELF:~0,-1!"
set "FB_PAYLOAD="
if exist "!FB_PAYLOAD_SELF!\Autounattend.xml" set "FB_PAYLOAD=!FB_PAYLOAD_SELF!"
if not defined FB_PAYLOAD if exist "!FB_PAYLOAD_SELF!\autounattend.xml" set "FB_PAYLOAD=!FB_PAYLOAD_SELF!"
if not defined FB_PAYLOAD if defined SRC if exist "%SRC%\FirstBase\Autounattend.xml" set "FB_PAYLOAD=%SRC%\FirstBase"
if not defined FB_PAYLOAD if defined SRC if exist "%SRC%\Autounattend.xml"           set "FB_PAYLOAD=%SRC%"
REM Quick Install ships no payload folder, so fall back to the parent of this
REM Deploy folder - correct in both layouts by construction.
if not defined FB_PAYLOAD set "FB_PAYLOAD=!FB_PAYLOAD_SELF!"
exit /b 0

:: -- BIND_USB_LOG : keep the deploy log on the USB when possible ----------
:BIND_USB_LOG
set "FB_USB_VOL="
if defined SRC set "FB_USB_VOL=%SRC:~0,2%"
if not defined FB_USB_VOL if defined FB_PAYLOAD set "FB_USB_VOL=!FB_PAYLOAD:~0,2!"
if not defined FB_USB_VOL set "FB_USB_VOL=%~d0"
if /i not "!FB_USB_VOL:~-1!"==":" set "FB_USB_VOL=!FB_USB_VOL!:"
set "FB_USB_LOGDIR=!FB_USB_VOL!\FirstBase-Logs"
if exist "!FB_USB_VOL!\." (
    if not exist "!FB_USB_LOGDIR!\" mkdir "!FB_USB_LOGDIR!" >nul 2>&1
    attrib -H -S "!FB_USB_LOGDIR!" >nul 2>&1
)
if exist "!FB_USB_LOGDIR!\." (
    set "LOG=!FB_USB_LOGDIR!\FirstBase-QuickInstall.log"
) else (
    set "FB_USB_LOGDIR=X:"
    set "LOG=X:\FirstBase-QuickInstall.log"
)
exit /b 0

:: -- RESOLVE_POWERSHELL : locate the WinPE powershell.exe (FB_PS) ---------
:RESOLVE_POWERSHELL
set "FB_PS="
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "FB_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined FB_PS if exist "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" set "FB_PS=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined FB_PS for /f "delims=" %%P in ('where powershell.exe 2^>nul') do if not defined FB_PS set "FB_PS=%%~fP"
if not defined FB_PS for /f "delims=" %%P in ('dir /s /b "%SystemRoot%\powershell.exe" 2^>nul') do if not defined FB_PS set "FB_PS=%%~fP"
echo [%DATE% %TIME%] RESOLVE_POWERSHELL: FB_PS=%FB_PS% >> "%LOG%"
if not defined FB_PS echo [%DATE% %TIME%] RESOLVE_POWERSHELL: SystemRoot=%SystemRoot% WINDIR=%WINDIR% >> "%LOG%"
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

:: -- FAILURES ------------------------------------------------------------
:FAIL
echo [%DATE% %TIME%] FAILED: !ERRMSG! >> "%LOG%" 2>nul
title FirstBase Quick Install - FAILED
call :FB_UI_RESOLVE
if defined FB_UI_SCRIPT (
    "!FB_UI_PS!" -NoProfile -ExecutionPolicy Bypass -File "!FB_UI_SCRIPT!" -Action Fail -Reason "!ERRMSG!" -Text "Log: %LOG%" -LogFile "%LOG%" 2>nul
) else (
    echo.
    echo ================================================================
    echo   FirstBase Quick Install - FAILED
    echo   Reason : !ERRMSG!
    echo   Log    : %LOG%
    echo ================================================================
    echo.
)
echo   Press any key to continue...
pause >nul
exit /b 1

:: -- FB_SHOW_BANNER : legacy no-op -------------------------------------------
:: Splash branding is painted by Invoke-FbDeployUi.ps1 Init (same shell).
:: Kept so any stray call :FB_SHOW_BANNER does not fail.
:FB_SHOW_BANNER
goto :eof
