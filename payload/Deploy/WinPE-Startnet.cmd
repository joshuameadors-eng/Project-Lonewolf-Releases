@echo off
setlocal EnableDelayedExpansion
title FirstBase - For Internal Use Only - WinPE

::  FirstBase - WinPE auto-deploy bootstrap
::  Injected into boot.wim at Windows\System32\startnet.cmd by LoneWolf.Provisioner.
::  Calls wpeinit, runs UEFI preflight, then finds FirstBase\Deploy\TechInstall.cmd on the data partition.
::  Intentionally QUIET: no banner or per-step console chatter (all status goes to %FBLOG%).
::  TechInstall.cmd renders its own progress; startnet only speaks on a fatal not-found.

set "FB_STARTNET_REV=2026-09-25.1"

if /I "%~1"=="--scan-test" (
    set "FBTECH="
    call :FB_SCAN_ROOT "%~2"
    if defined FBTECH (
        echo FOUND !FBTECH!
        exit /b 0
    )
    echo MISS
    exit /b 1
)
if /I "%~1"=="--launch-test" (
    set "FBTECH="
    set "FB_PERSIST_ROOT=%~2"
    set "FBLOG=%TEMP%\fb-launch-test.log"
    echo launch-test>"%TEMP%\fb-launch-test.log"
    call :FB_SCAN_ROOT "%~2"
    if not defined FBTECH (
        echo MISS
        exit /b 1
    )
    call :FB_PERSIST_FOR "!FBTECH!"
    call "!FBTECH!"
    echo LAUNCHED !FBTECH!
    exit /b 0
)

::  %TEMP% is not guaranteed to point at an existing directory this early - wpeinit has
::  not run yet. An unresolvable log path makes every ">" / ">>" below print "The system
::  cannot find the path specified." on the console, which is the chatter this script is
::  supposed to avoid. Validate it and fall back to X:\ (the WinPE RAM disk root, which
::  always exists). Every log write also carries 2>nul so a late failure stays silent.
set "FB_TMPD=X:"
if defined TEMP if exist "%TEMP%\." set "FB_TMPD=%TEMP%"
set "FBLOG=%FB_TMPD%\FirstBase-winpe.log"
echo [%DATE% %TIME%] WinPE-Startnet.cmd started rev=%FB_STARTNET_REV% > "%FBLOG%" 2>nul
echo [%DATE% %TIME%] SystemRoot=%SystemRoot% TEMP=%TEMP% FBLOG=%FBLOG% >> "%FBLOG%" 2>nul

echo [%DATE% %TIME%] Running wpeinit... >> "%FBLOG%" 2>nul
wpeinit >nul 2>&1
echo [%DATE% %TIME%] wpeinit exit: %ERRORLEVEL% >> "%FBLOG%" 2>nul

REM Optional debug pause
for %%P in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    set "_FB_PAUSE_FND=0"
    (for /f "delims=" %%Q in ('dir /b "%%P:\FirstBase-PAUSE.txt" 2^>nul') do set "_FB_PAUSE_FND=1") 2>nul
    if "!_FB_PAUSE_FND!"=="1" (
        echo [FirstBase-PAUSE] Debug shell. Remove FirstBase-PAUSE.txt when done.
        cmd.exe /k
    )
)

REM ========================================================
REM  UEFI preflight - Secure Boot + RAID detection (silent on the console;
REM  Invoke-FbUefiPreflight.ps1 logs to %FBLOG% and only prints if it must
REM  reboot to firmware to fix a real problem).
REM ========================================================
:PREFLIGHT_UEFI_CHECK
if /I "%FIRSTBASE_SKIP_PREFLIGHT%"=="1" (
    echo [%DATE% %TIME%] PREFLIGHT: bypassed (FIRSTBASE_SKIP_PREFLIGHT=1) >> "%FBLOG%" 2>nul
    goto :PREFLIGHT_DONE
)

set "FB_PFPS="
if exist "X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" set "FB_PFPS=X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined FB_PFPS (
    echo [%DATE% %TIME%] PREFLIGHT: powershell.exe not found - skipping >> "%FBLOG%" 2>nul
    goto :PREFLIGHT_DONE
)

set "FB_PFSCRIPT=X:\Windows\System32\Invoke-FbUefiPreflight.ps1"
if not exist "%FB_PFSCRIPT%" (
    echo [%DATE% %TIME%] PREFLIGHT: Invoke-FbUefiPreflight.ps1 not in boot.wim - skipping >> "%FBLOG%" 2>nul
    goto :PREFLIGHT_DONE
)

echo [%DATE% %TIME%] PREFLIGHT: running UEFI pre-flight checks >> "%FBLOG%" 2>nul
"%FB_PFPS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%FB_PFSCRIPT%" -LogFile "%FBLOG%"
set "FB_PFEC=%ERRORLEVEL%"
if %FB_PFEC% EQU 1 (
    echo [%DATE% %TIME%] PREFLIGHT: reboot to UEFI in progress >> "%FBLOG%" 2>nul
    exit /b 1
)

:PREFLIGHT_DONE
echo [%DATE% %TIME%] PREFLIGHT: checks passed >> "%FBLOG%" 2>nul

REM ========================================================
REM  Locate FirstBase\Deploy\TechInstall.cmd.
REM  The file is on the USB (Windows shows it as D:\FirstBase\Deploy\TechInstall.cmd)
REM  but Snapdragon WinPE often never letters that volume, and FirstBase is
REM  Hidden+System. `if exist` plus one diskpart script that stops on the first
REM  missing volume index both miss it, so startnet prints "not found on any
REM  volume" and never copies a log onto the stick.
REM  dir /a-d sees hidden and system files. mountvol letters volumes that have
REM  no mount point. Each diskpart assign is its own script so one gap cannot
REM  skip the USB. The WinPE log is written to a visible FirstBase-Logs folder
REM  before TechInstall.cmd is called.
REM ========================================================
echo [%DATE% %TIME%] scan pass 1: probing drive letters A-Z >> "%FBLOG%" 2>nul
call :FB_SCAN
if defined FBTECH goto :FOUND_TECH

echo [%DATE% %TIME%] scan pass 1 empty - lettering volumes that WinPE left unmounted >> "%FBLOG%" 2>nul
set "FB_DISKPART="
if exist "X:\Windows\System32\diskpart.exe"        set "FB_DISKPART=X:\Windows\System32\diskpart.exe"
if not defined FB_DISKPART if exist "%SystemRoot%\System32\diskpart.exe" set "FB_DISKPART=%SystemRoot%\System32\diskpart.exe"
if not defined FB_DISKPART for /f "delims=" %%Q in ('where diskpart 2^>nul') do if not defined FB_DISKPART set "FB_DISKPART=%%~fQ"
if not defined FB_DISKPART set "FB_DISKPART=diskpart"
echo [%DATE% %TIME%] FB_DISKPART=!FB_DISKPART! >> "%FBLOG%" 2>nul
call :FB_LETTER_VOLUMES
call :FB_SCAN
if defined FBTECH goto :FOUND_TECH

set /a FB_TRY=0
:FIND_TECH
set /a FB_TRY+=1
echo [%DATE% %TIME%] scan attempt !FB_TRY! >> "%FBLOG%" 2>nul
ping -n 3 127.0.0.1 >nul
call :FB_RESCAN
call :FB_MOUNT_UNLETTERED
call :FB_SCAN
if defined FBTECH goto :FOUND_TECH
if !FB_TRY! LSS 8 goto :FIND_TECH

echo [%DATE% %TIME%] FATAL: TechInstall.cmd not found after lettering volumes. >> "%FBLOG%" 2>nul
echo.
echo  FATAL: FirstBase - TechInstall.cmd not found on any volume.
echo  See WinPE log: %FBLOG%
call :FB_PERSIST_ANY
echo  A debug shell follows so the volume table can be inspected (list volume via diskpart).
cmd.exe /k
exit /b 1

REM ---- Scan every letter. dir /a-d sees Hidden+System FirstBase\Deploy. ----
:FB_SCAN
set "FBTECH="
for %%D in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if not defined FBTECH call :FB_SCAN_ROOT "%%D:"
)
goto :eof

:FB_SCAN_ROOT
set "FB_ROOT=%~1"
if "!FB_ROOT:~-1!"=="\" set "FB_ROOT=!FB_ROOT:~0,-1!"
if not defined FBTECH call :FB_NOTE "!FB_ROOT!\FirstBase\Deploy\TechInstall.cmd"
if not defined FBTECH call :FB_NOTE "!FB_ROOT!\FirstBase\Deploy\TechInstall-Install.cmd"
if not defined FBTECH call :FB_NOTE "!FB_ROOT!\Deploy\TechInstall.cmd"
if not defined FBTECH call :FB_NOTE "!FB_ROOT!\Deploy\TechInstall-Install.cmd"
if not defined FBTECH call :FB_NOTE "!FB_ROOT!\TechInstall.cmd"
goto :eof

:FB_NOTE
if defined FBTECH goto :eof
dir /a-d /b "%~1" >nul 2>&1
if not errorlevel 1 set "FBTECH=%~1"
goto :eof

:FB_LETTER_VOLUMES
call :FB_RESCAN
call :FB_MOUNT_UNLETTERED
set "FB_DPSCRIPT=%FB_TMPD%\fb-assign-one.txt"
for %%V in (0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25) do (
    >"%FB_DPSCRIPT%" echo select volume %%V
    >>"%FB_DPSCRIPT%" echo assign
    "!FB_DISKPART!" /s "%FB_DPSCRIPT%" >nul 2>&1
)
del "%FB_DPSCRIPT%" >nul 2>&1
echo [%DATE% %TIME%] Volume table after letter assignment: >> "%FBLOG%" 2>nul
(echo list volume) > "%FB_DPSCRIPT%" 2>nul
"!FB_DISKPART!" /s "%FB_DPSCRIPT%" >> "%FBLOG%" 2>&1
del "%FB_DPSCRIPT%" >nul 2>&1
goto :eof

:FB_RESCAN
set "FB_DPSCRIPT=%FB_TMPD%\fb-rescan.txt"
(
    echo automount enable
    echo rescan
) > "%FB_DPSCRIPT%" 2>nul
"!FB_DISKPART!" /s "%FB_DPSCRIPT%" >> "%FBLOG%" 2>&1
del "%FB_DPSCRIPT%" >nul 2>&1
goto :eof

REM mountvol lines are indented. A volume with no mount point is invisible to A-Z.
:FB_MOUNT_UNLETTERED
set "FB_MV=%FB_TMPD%\fb-mountvol.txt"
mountvol > "%FB_MV%" 2>nul
set "FB_GUID="
for /f "usebackq delims=" %%L in ("%FB_MV%") do (
    set "FB_LINE=%%L"
    set "FB_TRIM=!FB_LINE!"
    for /f "tokens=* delims= " %%T in ("!FB_LINE!") do set "FB_TRIM=%%T"
    if "!FB_TRIM:~0,11!"=="\\?\Volume{" (
        set "FB_GUID=!FB_TRIM!"
    ) else if defined FB_GUID (
        echo !FB_TRIM! | findstr /i /c:"NO MOUNT POINTS" >nul
        if not errorlevel 1 call :FB_MOUNT_ONE "!FB_GUID!"
        set "FB_GUID="
    )
)
del "%FB_MV%" >nul 2>&1
goto :eof

:FB_MOUNT_ONE
set "FB_FREE="
for %%L in (D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if not defined FB_FREE (
        dir %%L:\ >nul 2>&1
        if errorlevel 1 set "FB_FREE=%%L:"
    )
)
if not defined FB_FREE goto :eof
mountvol !FB_FREE! %~1 >nul 2>&1
echo [%DATE% %TIME%] mountvol !FB_FREE! %~1 >> "%FBLOG%" 2>nul
goto :eof

:FB_PERSIST_FOR
set "FB_HIT=%~1"
if defined FB_PERSIST_ROOT (
    set "FB_LOGVOL=!FB_PERSIST_ROOT!"
) else (
    for %%P in ("!FB_HIT!") do set "FB_LOGVOL=%%~dP"
)
if "!FB_LOGVOL:~-1!"=="\" set "FB_LOGVOL=!FB_LOGVOL:~0,-1!"
call :FB_WRITE_LOG "!FB_LOGVOL!"
goto :eof

:FB_PERSIST_ANY
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    dir /a-d /b "%%D:\FirstBase\Deploy\TechInstall.cmd" >nul 2>&1
    if not errorlevel 1 (
        call :FB_WRITE_LOG "%%D:"
        goto :eof
    )
    dir /a /b "%%D:\sources" >nul 2>&1
    if not errorlevel 1 (
        call :FB_WRITE_LOG "%%D:"
        goto :eof
    )
)
goto :eof

:FB_WRITE_LOG
set "FB_LOGDIR=%~1\FirstBase-Logs"
if not exist "!FB_LOGDIR!\" mkdir "!FB_LOGDIR!" >nul 2>&1
attrib -H -S "!FB_LOGDIR!" >nul 2>&1
copy /y "%FBLOG%" "!FB_LOGDIR!\FirstBase-winpe.log" >nul 2>&1
echo [%DATE% %TIME%] persisted !FB_LOGDIR!\FirstBase-winpe.log >> "%FBLOG%" 2>nul
goto :eof

:FOUND_TECH
echo [%DATE% %TIME%] Found deploy entry point: !FBTECH! >> "%FBLOG%" 2>nul
call :FB_PERSIST_FOR "!FBTECH!"
echo [%DATE% %TIME%] Launching: !FBTECH! >> "%FBLOG%" 2>nul
call "!FBTECH!"
echo [%DATE% %TIME%] TechInstall.cmd returned: !ERRORLEVEL! >> "%FBLOG%" 2>nul
exit /b !ERRORLEVEL!
