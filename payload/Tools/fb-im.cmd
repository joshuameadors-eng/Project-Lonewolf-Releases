@echo off
:: ============================================================================
:: fb-im.cmd -- FirstBase technician tool
::
:: Usage:
::   fb-im.cmd                -> LoneWolf WPF technician window
::   fb-im.cmd -Action Status -> same window (status check on open)
::
:: This launcher is the only technician entry point staged at the USB ROOT, so
:: a tech sees it as soon as they open the stick. fb-dump.cmd is DEPRECATED and
:: is no longer staged at the root: use Collect logs in the WPF window instead.
::
:: The PowerShell backbone stays in the payload at
:: FirstBase\WUPayload\Tools\fb-im.ps1 and is resolved by relative path.
::
:: Window: device ready check, restart updates (clears locks), collect logs
:: with issue notes typed while dump runs.
:: ============================================================================
setlocal EnableExtensions EnableDelayedExpansion

:: -------- Self-elevation (check net session; re-launch with runas if not admin)
::
:: Structured exactly like fb-dump.cmd: the powershell path is read with DELAYED
:: expansion because cmd expands the whole parenthesized block at parse time,
:: before the for loop has assigned it. Start-Process also rejects an empty
:: -ArgumentList, so the argument clause is built as a string and omitted when
:: there are no arguments (the double-click case). Only `rem` is safe inside a
:: parenthesized block - a `::` label there emits "The system cannot find the
:: drive specified." on every run - so all notes stay above the block.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo  Requesting administrator privileges...
    set "_FB_SELF=%~f0"
    set "_FB_ARGS=%*"
    for %%P in (
        "X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
        "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    ) do if exist %%P if not defined _FB_ELEV_PS set "_FB_ELEV_PS=%%~P"
    set "_FB_ELEV_ARGS="
    if defined _FB_ARGS set "_FB_ELEV_ARGS= -ArgumentList '!_FB_ARGS!'"
    if defined _FB_ELEV_PS "!_FB_ELEV_PS!" -NoProfile -Command "Start-Process -FilePath '!_FB_SELF!'!_FB_ELEV_ARGS! -Verb RunAs"
    if not defined _FB_ELEV_PS echo  [ERROR] Cannot elevate: powershell.exe not found. Run this script as Administrator.
    exit /b 0
)

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

:: -------- Launch PS backend --------------------------------------------------
:: Same stamp fb-dump.cmd sets: the tools hand off to each other and fb-dump
:: defaults its output folder to this stick.
:: -STA is required for the WPF technician window.
:: Keep a launch log so a flash-and-exit is diagnosable (errors were invisible
:: when powershell -File died immediately under SilentlyContinue).
set "FB_USB_DRIVE=%~d0"
if not exist "%FB_USB_DRIVE%\FirstBase-Logs\" mkdir "%FB_USB_DRIVE%\FirstBase-Logs" >nul 2>&1
attrib -H -S "%FB_USB_DRIVE%\FirstBase-Logs" >nul 2>&1
set "FB_IM_LOG=%FB_USB_DRIVE%\FirstBase-Logs\fb-im-last-launch.log"
> "%FB_IM_LOG%" echo %DATE% %TIME% fb-im.cmd start
>>"%FB_IM_LOG%" echo self=%~f0
>>"%FB_IM_LOG%" echo ps=%FB_PS%
>>"%FB_IM_LOG%" echo ps1=%FB_IM_PS1%
echo  Launching technician tools...
echo  %FB_IM_PS1%
"%FB_PS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%FB_IM_PS1%" %*
set "FB_EC=%ERRORLEVEL%"
>>"%FB_IM_LOG%" echo exit=%FB_EC%
if not "%FB_EC%"=="0" (
    echo.
    echo  [ERROR] fb-im exited with code %FB_EC%
    echo          Log: %FB_IM_LOG%
    echo.
    pause
)
exit /b %FB_EC%
