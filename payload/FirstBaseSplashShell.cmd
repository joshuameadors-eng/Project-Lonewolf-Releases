@echo off
setlocal EnableExtensions
set "FB_ROOT=C:\Windows\Setup\FirstBase"
set "FB_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%FB_ROOT%\FirstBaseHandoffSplash.ps1" (
  start "" "%FB_PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%FB_ROOT%\FirstBaseHandoffSplash.ps1" -Phase preparing-handoff
)
if exist "%FB_ROOT%\FirstBaseSplashSingleInstance.ps1" (
  start "" "%FB_PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%FB_ROOT%\FirstBaseSplashSingleInstance.ps1"
)
start "" "%SystemRoot%\explorer.exe"
:fb_shell_wait
timeout /t 30 /nobreak >nul
tasklist /FI "IMAGENAME eq explorer.exe" | find /I "explorer.exe" >nul
if errorlevel 1 start "" "%SystemRoot%\explorer.exe"
goto fb_shell_wait
