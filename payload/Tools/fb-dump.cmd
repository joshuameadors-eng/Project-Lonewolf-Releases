@echo off
:: ============================================================================
:: fb-dump.cmd -- FirstBase diagnostic log collector
::
:: DEPRECATED. This launcher is no longer staged at the USB root. Run fb-im.cmd
:: from the root of the stick and choose menu option [3] Collect logs, which
:: hands off to the same fb-dump.ps1 backbone. The file is kept here so a
:: hand-copied root launcher on an existing stick still works.
::
:: Usage:
::   fb-dump.cmd               -> D:\{SN}-{HHmm}-{MFR}
::   fb-dump.cmd D:\foo        -> D:\foo
::   fb-dump.cmd F:\fb-XYZ     -> F:\fb-XYZ
::
:: 5.1.53: this launcher is staged at the USB ROOT so the operator sees it as
:: soon as they open the stick. The PowerShell backbone stays in the payload at
:: WUPayload\Tools\fb-dump.ps1, so the launcher resolves it by relative path
:: rather than assuming it sits alongside. Output behaviour is unchanged.
::
:: Captures: build identity, payload state, Panther, Sysprep, event logs,
:: Task Scheduler, Defender, CBS/DISM, tasklist, registry keys.
:: After capture: prompts for issue description, writes FirstBase-Issue.md.
:: ============================================================================
setlocal EnableExtensions EnableDelayedExpansion

:: -------- Self-elevation (check net session; re-launch with runas if not admin)
::
:: 5.1.53 FIX: the powershell path in the block below is read with DELAYED
:: expansion. It was "%_FB_ELEV_PS%", which cmd expands when it parses the whole
:: enclosing block - before the for loop has assigned it - so it was always
:: empty and elevation died with '""' is not recognized. Start-Process also
:: rejects an empty -ArgumentList, which is the double-click case, so the
:: argument clause is built as a string and omitted entirely when there are no
:: arguments. The block is kept flat to avoid a third level of parentheses.
::
:: 5.1.54 FIX: these notes live ABOVE the block rather than inside it. `::` is a
:: degenerate label, and cmd cannot parse a label inside a parenthesized block:
:: the seven `::` lines that sat inside this block in 5.1.53 made it emit three
:: "The system cannot find the drive specified." lines to stderr on every
:: non-elevated run - the first thing an operator saw after double-clicking the
:: launcher. The X: probe below is NOT the source; `if exist` on a missing drive
:: is silent. Only `rem` is safe inside parentheses, and nothing in this file
:: now uses `::` inside a block.
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
:: 5.1.53: this launcher lives at the USB root while the backbone stays in the
:: payload, so the root-relative paths are tried first: the nested layout
:: (payload under FirstBase\) then the legacy flat one. The last two candidates
:: keep an already-built stick (both files in Tools\) and a hand-copied pair in
:: one folder working, since %~dp0 is the launcher's own folder in every case.
set "FB_DUMP_PS1="
if exist "%~dp0FirstBase\WUPayload\Tools\fb-dump.ps1" set "FB_DUMP_PS1=%~dp0FirstBase\WUPayload\Tools\fb-dump.ps1"
if not defined FB_DUMP_PS1 if exist "%~dp0WUPayload\Tools\fb-dump.ps1" set "FB_DUMP_PS1=%~dp0WUPayload\Tools\fb-dump.ps1"
if not defined FB_DUMP_PS1 if exist "%~dp0Tools\fb-dump.ps1" set "FB_DUMP_PS1=%~dp0Tools\fb-dump.ps1"
if not defined FB_DUMP_PS1 if exist "%~dp0fb-dump.ps1" set "FB_DUMP_PS1=%~dp0fb-dump.ps1"

if not defined FB_DUMP_PS1 (
    echo.
    echo  [ERROR] fb-dump.ps1 not found.
    echo          Looked in FirstBase\WUPayload\Tools\, WUPayload\Tools\, Tools\
    echo          and alongside this file, relative to %~dp0
    echo.
    pause
    exit /b 1
)

:: -------- Launch PS backend --------------------------------------------------
:: Stamp our own drive letter so the PS script can default the output folder
:: to this USB stick rather than guessing from WMI or $PSScriptRoot. %~d0 is the
:: launcher's own drive, so this is identical from the root or from Tools\.
set "FB_USB_DRIVE=%~d0"
"%FB_PS%" -NoProfile -ExecutionPolicy Bypass -File "%FB_DUMP_PS1%" %*
exit /b %errorlevel%
