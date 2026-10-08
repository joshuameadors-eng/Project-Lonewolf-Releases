@echo off
setlocal EnableDelayedExpansion
:: Prefer boot.wim copy at X:\FirstBase\WinPeUi (already started by startnet).
:: Fall back to USB Deploy\WinPeUi\<ARCH>\ when the WIM inject is missing.
:: Do NOT use tasklist/wmic - they can hang WinPE and block startnet forever.
:: Optional %1 = Deploy folder (defaults to this script's directory).

set "FB_UI_DEPLOY=%~1"
if not defined FB_UI_DEPLOY set "FB_UI_DEPLOY=%~dp0"
if "!FB_UI_DEPLOY:~-1!"=="\" set "FB_UI_DEPLOY=!FB_UI_DEPLOY:~0,-1!"

for %%P in ("!FB_UI_DEPLOY!") do set "FB_UI_LOGDIR=%%~dP\FirstBase-Logs"
if not exist "!FB_UI_LOGDIR!\" mkdir "!FB_UI_LOGDIR!" >nul 2>&1
attrib -H -S "!FB_UI_LOGDIR!" >nul 2>&1
set "FB_UI_LOG=!FB_UI_LOGDIR!\WinPeUi-early.log"

call :LOG "begin deploy=!FB_UI_DEPLOY! arch_env=%PROCESSOR_ARCHITECTURE%"

set "FB_UI_FLAG=X:\FirstBase-WinPeUi.started"
if not exist "X:\" set "FB_UI_FLAG=!FB_UI_LOGDIR!\FirstBase-WinPeUi.started"
if exist "!FB_UI_FLAG!" (
    call :LOG "skip start - flag present !FB_UI_FLAG! (boot.wim or prior launch)"
    exit /b 0
)

set "FB_UI_STATE=X:\FirstBase-DeployUi.json"
if not exist "X:\" set "FB_UI_STATE=!FB_UI_LOGDIR!\FirstBase-DeployUi.json"

set "FB_UI_DIR="
set "FB_UI_EXE="
if exist "X:\FirstBase\WinPeUi\LoneWolf.WinPeUi.exe" (
    set "FB_UI_DIR=X:\FirstBase\WinPeUi"
    set "FB_UI_EXE=X:\FirstBase\WinPeUi\LoneWolf.WinPeUi.exe"
    call :LOG "using boot.wim copy !FB_UI_EXE!"
) else (
    set "FB_UI_ARCH=AMD64"
    if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "FB_UI_ARCH=ARM64"
    set "FB_UI_DIR=!FB_UI_DEPLOY!\WinPeUi\!FB_UI_ARCH!"
    set "FB_UI_EXE=!FB_UI_DIR!\LoneWolf.WinPeUi.exe"
    call :LOG "using USB copy !FB_UI_EXE!"
)

if not exist "!FB_UI_EXE!" (
    call :LOG "FAIL exe missing: !FB_UI_EXE!"
    exit /b 0
)

> "!FB_UI_STATE!" echo {"Workflow":"","Dev":false,"PayloadVersion":"","ImageBuildDate":"","PhaseLabel":"Windows installation","OverallPercent":0,"WpfHost":true,"Steps":[],"Current":0,"Detail":"Starting...","Status":"running","Message":"","Spin":0,"SplashDone":false}
if errorlevel 1 (
    call :LOG "WARN stub JSON write failed path=!FB_UI_STATE!"
) else (
    call :LOG "stub JSON written !FB_UI_STATE!"
)

call :LOG "starting /D !FB_UI_DIR!"
start "LoneWolfWinPeUi" /D "!FB_UI_DIR!" "LoneWolf.WinPeUi.exe" --state-file "!FB_UI_STATE!"
echo started> "!FB_UI_FLAG!" 2>nul
call :LOG "start issued flag=!FB_UI_FLAG!"
exit /b 0

:LOG
echo [%DATE% %TIME%] %~1>> "!FB_UI_LOG!" 2>nul
if defined FBLOG echo [%DATE% %TIME%] WinPeUi-early: %~1>> "%FBLOG%" 2>nul
goto :eof
