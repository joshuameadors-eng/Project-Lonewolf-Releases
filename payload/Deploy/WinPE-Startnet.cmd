@echo off
setlocal EnableDelayedExpansion
title FirstBase - For Internal Use Only - WinPE

::  FirstBase - WinPE auto-deploy bootstrap
::  Injected into boot.wim at Windows\System32\startnet.cmd by LoneWolf.Provisioner.
::  Calls wpeinit, runs UEFI preflight, then finds FirstBase\Deploy\TechInstall.cmd on the data partition.
::  Intentionally QUIET: no banner or per-step console chatter (all status goes to %FBLOG%).
::  TechInstall.cmd renders its own progress; startnet only speaks on a fatal not-found.

set "FB_STARTNET_REV=2026-08-24.2"

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
REM  Locate FirstBase\Deploy\TechInstall.cmd (legacy: Deploy\ or the volume root).
REM  FAST PATH (mirrors Build-UsbStick.ps1): WinPE auto-letters the boot USB, so on the
REM  default Single (FAT32 Basic-Data) layout the entry point is already reachable - scan
REM  first WITHOUT touching diskpart. Only if that first pass fails (e.g. a Split ESP+NTFS
REM  layout where WinPE does not letter the NTFS data partition) do we fall back to a
REM  diskpart rescan + blanket letter-assignment and retry. This avoids the diskpart dance
REM  on the common layout the reference builder is proven against.
REM ========================================================
echo [%DATE% %TIME%] scan pass 1 (no diskpart): probing drive letters A-Z >> "%FBLOG%" 2>nul
call :FB_SCAN
if defined FBTECH goto :FOUND_TECH

echo [%DATE% %TIME%] scan pass 1 empty - running diskpart letter assignment (Split-layout assist) >> "%FBLOG%" 2>nul

set "FB_DISKPART="
if exist "X:\Windows\System32\diskpart.exe"        set "FB_DISKPART=X:\Windows\System32\diskpart.exe"
if not defined FB_DISKPART if exist "%SystemRoot%\System32\diskpart.exe" set "FB_DISKPART=%SystemRoot%\System32\diskpart.exe"
if not defined FB_DISKPART for /f "delims=" %%Q in ('where diskpart 2^>nul') do if not defined FB_DISKPART set "FB_DISKPART=%%~fQ"
if not defined FB_DISKPART set "FB_DISKPART=diskpart"
echo [%DATE% %TIME%] FB_DISKPART=!FB_DISKPART! >> "%FBLOG%" 2>nul

set "FB_DPSCRIPT=%FB_TMPD%\fb-assign-letters.txt"
(
    echo automount enable
    echo rescan
    for %%V in (0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25) do (
        echo select volume %%V
        echo assign
    )
) > "%FB_DPSCRIPT%" 2>nul
echo [%DATE% %TIME%] Assigning drive letters to all volumes... >> "%FBLOG%" 2>nul
"!FB_DISKPART!" /s "%FB_DPSCRIPT%" >> "%FBLOG%" 2>&1
del "%FB_DPSCRIPT%" >nul 2>&1

echo [%DATE% %TIME%] Volume table after letter assignment: >> "%FBLOG%" 2>nul
(echo list volume) > "%FB_DPSCRIPT%" 2>nul
"!FB_DISKPART!" /s "%FB_DPSCRIPT%" >> "%FBLOG%" 2>&1
del "%FB_DPSCRIPT%" >nul 2>&1

set /a FB_TRY=0
:FIND_TECH
set /a FB_TRY+=1
echo [%DATE% %TIME%] scan attempt !FB_TRY! (post-diskpart) >> "%FBLOG%" 2>nul
call :FB_SCAN
if defined FBTECH goto :FOUND_TECH
if !FB_TRY! LSS 15 (
    ping -n 3 127.0.0.1 >nul
    (echo rescan) > "%FB_DPSCRIPT%" 2>nul
    "!FB_DISKPART!" /s "%FB_DPSCRIPT%" >nul 2>&1
    del "%FB_DPSCRIPT%" >nul 2>&1
    goto :FIND_TECH
)

echo [%DATE% %TIME%] FATAL: TechInstall.cmd not found after !FB_TRY! attempts. >> "%FBLOG%" 2>nul
echo.
echo  FATAL: FirstBase - TechInstall.cmd not found on any volume.
echo  See WinPE log: %FBLOG%
call :FB_PERSIST_LOG
echo  A debug shell follows so the volume table can be inspected (list volume via diskpart).
cmd.exe /k
exit /b 1

REM ---- Scan helper: sets FBTECH to the first deploy entry point found on A-Z ----
REM Nested layout (current builder) keeps the payload under <vol>\FirstBase\, so
REM FirstBase\Deploy\ is probed first; the flat <vol>\Deploy\ and <vol>\ paths stay
REM for legacy sticks. Preference is per-drive-letter, not per-path-shape.
:FB_SCAN
set "FBTECH="
for %%D in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if not defined FBTECH if exist "%%D:\FirstBase\Deploy\TechInstall.cmd"         set "FBTECH=%%D:\FirstBase\Deploy\TechInstall.cmd"
    if not defined FBTECH if exist "%%D:\FirstBase\Deploy\TechInstall-Install.cmd" set "FBTECH=%%D:\FirstBase\Deploy\TechInstall-Install.cmd"
    if not defined FBTECH if exist "%%D:\Deploy\TechInstall.cmd"                   set "FBTECH=%%D:\Deploy\TechInstall.cmd"
    if not defined FBTECH if exist "%%D:\Deploy\TechInstall-Install.cmd"           set "FBTECH=%%D:\Deploy\TechInstall-Install.cmd"
    if not defined FBTECH if exist "%%D:\TechInstall.cmd"                          set "FBTECH=%%D:\TechInstall.cmd"
)
goto :eof

REM ---- Copy the WinPE bootstrap log onto the data partition (survives reboot) ----
:FB_PERSIST_LOG
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\FirstBase\Deploy\" (
        if not exist "%%D:\FirstBase-Logs\" mkdir "%%D:\FirstBase-Logs" >nul 2>&1
        attrib -H -S "%%D:\FirstBase-Logs" >nul 2>&1
        copy /y "%FBLOG%" "%%D:\FirstBase-Logs\FirstBase-winpe.log" >nul 2>&1
        goto :eof
    )
    if exist "%%D:\Deploy\" (
        if not exist "%%D:\FirstBase-Logs\" mkdir "%%D:\FirstBase-Logs" >nul 2>&1
        attrib -H -S "%%D:\FirstBase-Logs" >nul 2>&1
        copy /y "%FBLOG%" "%%D:\FirstBase-Logs\FirstBase-winpe.log" >nul 2>&1
        goto :eof
    )
)
goto :eof

:FOUND_TECH
echo [%DATE% %TIME%] Found deploy entry point: !FBTECH! >> "%FBLOG%" 2>nul
call :FB_PERSIST_LOG
echo [%DATE% %TIME%] Launching: !FBTECH! >> "%FBLOG%" 2>nul
call "!FBTECH!"
echo [%DATE% %TIME%] TechInstall.cmd returned: !ERRORLEVEL! >> "%FBLOG%" 2>nul
exit /b !ERRORLEVEL!
