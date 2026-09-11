@echo off
:: ============================================================================
:: fb-im.cmd -- FirstBase technician tool
::
:: Usage:
::   fb-im.cmd                -> LoneWolf WPF technician window
::   fb-im.cmd -Action Status -> same window (status check on open)
::
:: This launcher is the only technician entry point staged at the USB ROOT, so
:: a tech sees it as soon as they open the stick (D:\fb-im.cmd). fb-dump.cmd is
:: DEPRECATED and is no longer staged at the root: use Collect logs in the WPF
:: window instead.
::
:: The PowerShell backbone stays in the payload at
:: FirstBase\WUPayload\Tools\fb-im.ps1 and is resolved by relative path.
::
:: Other-PC Access denied: cmd "start" / Start-Process -Verb RunAs from a USB
:: working directory (D:\) fails on many devices. Copy the .ps1 to local disk,
:: leave the USB cwd, then elevate the local copy (-ExecutionPolicy Bypass).
::
:: Window: device ready check, restart updates, pass hardware check,
:: collect logs, Restart, Shutdown, and seal (sysprep /oobe).
:: ============================================================================
setlocal EnableExtensions EnableDelayedExpansion

:: -------- PS resolution (WinPE-safe) ----------------------------------------
set "FB_PS="
if exist "X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" set "FB_PS=X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined FB_PS if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "FB_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined FB_PS if exist "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" set "FB_PS=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined FB_PS for /f "tokens=* delims= " %%P in ('where powershell.exe 2^>nul') do (
    if not defined FB_PS if exist "%%~fP" set "FB_PS=%%~fP"
)

if not defined FB_PS (
    echo.
    echo  [ERROR] powershell.exe not found.
    echo          Install Windows PowerShell 5.1 and try again.
    echo.
    pause
    exit /b 1
)

:: -------- Locate the PS backbone ---------------------------------------------
:: The nested stick layout (payload under FirstBase\) is tried first, then the
:: legacy flat layout, then a built stick opened from Tools\, then a hand-copied
:: pair in one folder. %~dp0 is the launcher's own folder in every case.
:: `if exist` sees Hidden+System FirstBase; Explorer does not have to.
set "FB_IM_PS1="
if exist "%~dp0FirstBase\WUPayload\Tools\fb-im.ps1" set "FB_IM_PS1=%~dp0FirstBase\WUPayload\Tools\fb-im.ps1"
if not defined FB_IM_PS1 if exist "%~dp0WUPayload\Tools\fb-im.ps1" set "FB_IM_PS1=%~dp0WUPayload\Tools\fb-im.ps1"
if not defined FB_IM_PS1 if exist "%~dp0Tools\fb-im.ps1" set "FB_IM_PS1=%~dp0Tools\fb-im.ps1"
if not defined FB_IM_PS1 if exist "%~dp0fb-im.ps1" set "FB_IM_PS1=%~dp0fb-im.ps1"

if not defined FB_IM_PS1 (
    echo.
    echo  [ERROR] fb-im.ps1 not found.
    echo          Looked in FirstBase\WUPayload\Tools\, WUPayload\Tools\, Tools\
    echo          and alongside this file, relative to %~dp0
    echo.
    pause
    exit /b 1
)

:: -------- Launch log (no console noise) --------------------------------------
set "FB_USB_DRIVE=%~d0"
if not exist "%FB_USB_DRIVE%\FirstBase-Logs\" mkdir "%FB_USB_DRIVE%\FirstBase-Logs" >nul 2>&1
attrib -H -S "%FB_USB_DRIVE%\FirstBase-Logs" >nul 2>&1
set "FB_IM_LOG=%FB_USB_DRIVE%\FirstBase-Logs\fb-im-last-launch.log"
> "%FB_IM_LOG%" echo %DATE% %TIME% fb-im.cmd start
>>"%FB_IM_LOG%" echo self=%~f0
>>"%FB_IM_LOG%" echo cwd=%CD%
>>"%FB_IM_LOG%" echo ps=%FB_PS%
>>"%FB_IM_LOG%" echo ps1=%FB_IM_PS1%
set "FB_IM_ARGS=%*"
>>"%FB_IM_LOG%" echo args=%FB_IM_ARGS%

:: Stick Tools dir for identity / fb-dump after the TEMP copy. Strip trailing
:: backslash so -UsbToolsDir "D:\...\Tools" is not eaten by cmd quoting.
for %%I in ("%FB_IM_PS1%") do set "FB_IM_USB_TOOLS=%%~dpI"
if defined FB_IM_USB_TOOLS if "%FB_IM_USB_TOOLS:~-1%"=="\" set "FB_IM_USB_TOOLS=%FB_IM_USB_TOOLS:~0,-1%"
>>"%FB_IM_LOG%" echo usbTools=%FB_IM_USB_TOOLS%

:: Local host folder. RunAs + USB cwd is Access denied on other PCs.
if defined LOCALAPPDATA (
    set "FB_IM_HOST=%LOCALAPPDATA%\FirstBase\fb-im"
) else (
    set "FB_IM_HOST=%TEMP%\FirstBase-fb-im"
)
if not defined FB_IM_HOST set "FB_IM_HOST=%SystemRoot%\Temp\FirstBase-fb-im"
if not exist "%FB_IM_HOST%\" mkdir "%FB_IM_HOST%" >nul 2>&1
if not exist "%FB_IM_HOST%\" (
    echo.
    echo  [ERROR] Could not create local host folder:
    echo          %FB_IM_HOST%
    echo.
    pause
    exit /b 1
)

attrib -R "%FB_IM_PS1%" >nul 2>&1
copy /Y "%FB_IM_PS1%" "%FB_IM_HOST%\fb-im.ps1" >nul
if not exist "%FB_IM_HOST%\fb-im.ps1" (
    echo.
    echo  [ERROR] Could not copy fb-im.ps1 off the USB stick.
    echo          From: %FB_IM_PS1%
    echo          To:   %FB_IM_HOST%\fb-im.ps1
    echo.
    pause
    exit /b 1
)
>>"%FB_IM_LOG%" echo host=%FB_IM_HOST%

:: Leave the USB working directory BEFORE start / UAC. start /D is local.
:: Relative -File fb-im.ps1 avoids start.exe quote-eating on paths with spaces.
pushd "%FB_IM_HOST%"
if errorlevel 1 (
    echo.
    echo  [ERROR] Cannot use local host folder:
    echo          %FB_IM_HOST%
    echo.
    pause
    exit /b 1
)

start "" /D "%FB_IM_HOST%" "%FB_PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File fb-im.ps1 -LaunchHost -UsbToolsDir "%FB_IM_USB_TOOLS%"
set "FB_START_EC=%ERRORLEVEL%"
>>"%FB_IM_LOG%" echo launched=local-host startEc=%FB_START_EC%
if not "%FB_START_EC%"=="0" (
    echo.
    echo  [ERROR] Could not start fb-im (code %FB_START_EC%).
    echo          Log: %FB_IM_LOG%
    echo.
    pause
    popd
    exit /b %FB_START_EC%
)
popd
exit /b 0
