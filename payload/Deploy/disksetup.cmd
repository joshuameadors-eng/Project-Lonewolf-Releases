@echo off
setlocal EnableDelayedExpansion

REM %TEMP% is not guaranteed to resolve to an existing directory in WinPE. An
REM unresolvable path makes every ">" below print "The system cannot find the path
REM specified." on the console AND leaves diskpart without a script file. X:\ is the
REM WinPE scratch volume and always exists.
set "FB_TMPD=X:"
if defined TEMP if exist "%TEMP%\." set "FB_TMPD=%TEMP%"

set "dpScript=%FB_TMPD%\diskpart_script.txt"
set "dpResult=%FB_TMPD%\diskpart_result.txt"

REM TechInstall sets INSTALLSRC to the FirstBase PAYLOAD ROOT (<vol>\FirstBase on a
REM nested stick, the volume root on a legacy flat one) so logs land on USB and
REM survive a reboot / crash. FB_VOLROOT is that stick's volume root: operator flags
REM are hand-dropped there. USB logs and WIPE-PENDING write to <vol>\FirstBase-Logs
REM (visible, not hidden), not inside hidden FirstBase and not loose at the root.
set "log=%FB_TMPD%\disksetup.log"
set "FB_VOLROOT="
set "FB_USB_LOGDIR="
if defined INSTALLSRC set "FB_VOLROOT=%INSTALLSRC:~0,2%"
if defined FB_VOLROOT if exist "!FB_VOLROOT!\." (
  set "FB_USB_LOGDIR=!FB_VOLROOT!\FirstBase-Logs"
  if not exist "!FB_USB_LOGDIR!\" mkdir "!FB_USB_LOGDIR!" >nul 2>&1
  attrib -H -S "!FB_USB_LOGDIR!" >nul 2>&1
  if exist "!FB_USB_LOGDIR!\." set "log=!FB_USB_LOGDIR!\FirstBase-disksetup.log"
)
set "FB_DISKSETUP_REV=2026-08-24.2"

echo [%DATE% %TIME%] disksetup started > "%log%" 2>nul
echo [%DATE% %TIME%] disksetup revision=%FB_DISKSETUP_REV% >> "%log%" 2>nul
if defined INSTALLSRC echo [%DATE% %TIME%] INSTALLSRC=%INSTALLSRC% VOLROOT=%FB_VOLROOT% >> "%log%" 2>nul

call :FB_RESOLVE_PS
call :FB_RESOLVE_DISKPART

REM Diskpart invocations must use !FB_DISKPART! (delayed expansion). %FB_DISKPART% inside (...) blocks
REM can expand empty/wrong at parse time and yields '"X:\...\diskpart.exe"' is not recognized.

echo [%DATE% %TIME%] RAID/Secure Boot storage gate disabled by policy ^(no probe, no prompts^) >> "%log%"

:DO_DISKPART
echo [%DATE% %TIME%] Resolving target disk >> "%log%"

REM Hard policy: target = Disk 0. Optional override: empty file
REM   FirstBase-Disk-N.txt  ^(N = digits^) in the payload root OR on the USB volume
REM   root. The volume root is checked first so a payload-root file wins a tie.
set "DISKNUM=0"
if defined INSTALLSRC (
  for %%N in (0 1 2 3 4 5 6 7 8 9) do (
    if defined FB_VOLROOT if exist "!FB_VOLROOT!\FirstBase-Disk-%%N.txt" set "DISKNUM=%%N"
    if exist "%INSTALLSRC%\FirstBase-Disk-%%N.txt" set "DISKNUM=%%N"
  )
)
set "DISKNAME=fixed-target"
set "DISKBUS=fixed"
echo [%DATE% %TIME%] Target disk forced to !DISKNUM! ^(override: FirstBase-Disk-N.txt^) >> "%log%"

REM Safety: if Disk !DISKNUM! is the install media, refuse to wipe ^(prevents bricked USB/WinPE crash^).
if defined INSTALLSRC (
  set "VL=%INSTALLSRC:~0,1%"
  set "MEDIADISK="
  set "MEDIADISK_SRC=none"
  rem Diskpart-only resolution (detail volume + disk walk). Do NOT call the
  rem Get-Partition PS fallback here - it hangs WinPE before wipe on this hardware
  rem even with a runspace timeout, and an unresolved MEDIADISK is non-fatal.
  call :FB_DISK_OF_LETTER !VL!
  set "MEDIADISK=!FB_DOL_DISK!"
  set "MEDIADISK_SRC=!FB_DOL_SRC!"
  rem The "if defined" guard is load-bearing: "set VAR=!VAR: =!" on an UNDEFINED
  rem variable leaves the literal " =" behind, which then satisfies "if defined VAR"
  rem with junk and makes the comparison below compare " =" against the target disk.
  if defined MEDIADISK set "MEDIADISK=!MEDIADISK: =!"
  if defined MEDIADISK (
    echo !MEDIADISK!| findstr /R "^[0-9][0-9]*$" >nul 2>&1
    if errorlevel 1 (
      set "MEDIADISK="
      set "MEDIADISK_SRC=none"
    )
  )
  echo [%DATE% %TIME%] MEDIADISK ^(install media physical disk^)=!MEDIADISK! source=!MEDIADISK_SRC! >> "%log%"
  if defined MEDIADISK (
    echo [%DATE% %TIME%] Install media is on Disk !MEDIADISK! >> "%log%"
    if "!MEDIADISK!"=="!DISKNUM!" (
      echo.
      echo  ERROR: Disk !DISKNUM! is the boot USB ^(install media^).
      echo  Refusing to clean the installer drive.
      echo  Move the OS disk to position 0 in BIOS, OR drop FirstBase-Disk-N.txt on USB
      echo  with N = the internal disk number you want to wipe.
      echo  Log: %log%
      echo [%DATE% %TIME%] ABORT: target Disk !DISKNUM! == install media >> "%log%"
      ping -n 31 127.0.0.1 >nul
      exit /b 1
    )
  ) else (
    echo [%DATE% %TIME%] WARNING: Could not resolve install-media disk number ^(continuing^) >> "%log%"
  )
)

echo [%DATE% %TIME%] Target disk !DISKNUM! !DISKNAME! BusType=!DISKBUS! >> "%log%"

REM The WIPE-PENDING marker is read back by the TechInstall side as the target-disk
REM source, so it must land where that side looks. Write it into FirstBase-Logs.
if defined FB_USB_LOGDIR if exist "!FB_USB_LOGDIR!\." (
  (
    echo FirstBase pending WIPE
    echo DiskNumber=!DISKNUM!
    echo FriendlyName=!DISKNAME!
    echo BusType=!DISKBUS!
    echo Log=!log!
    echo Time=%DATE% %TIME%
  )>"!FB_USB_LOGDIR!\FirstBase-WIPE-PENDING.txt"
)

set "FB_SKIPCD=0"
if defined INSTALLSRC if exist "%INSTALLSRC%\FirstBase-SkipCountdown.txt" set "FB_SKIPCD=1"
if defined FB_VOLROOT if exist "%FB_VOLROOT%\FirstBase-SkipCountdown.txt" set "FB_SKIPCD=1"
if "!FB_SKIPCD!"=="0" (
  echo [%DATE% %TIME%] Pre-wipe countdown 45s >> "%log%"
  ping -n 46 127.0.0.1 >nul
)

echo [%DATE% %TIME%] Starting diskpart script >> "%log%"

(
  echo select disk !DISKNUM!
  echo clean
  echo convert gpt
  echo create partition efi size=100
  echo format quick fs=fat32 label=System
  echo assign letter=S
  echo create partition msr size=16
  echo create partition primary
  echo format quick fs=ntfs label=Windows
  echo assign letter=W
)>"%dpScript%"

"!FB_DISKPART!" /s "!dpScript!" >> "!log!" 2>&1
if errorlevel 1 (
  echo ERROR: Diskpart failed. See %log%
  ping -n 11 127.0.0.1 >nul
  exit /b 1
)

if not exist "W:\" (
  >"%dpScript%" (
    echo list volume
    echo select volume Windows
    echo assign letter=W
    echo select volume System
    echo assign letter=S
  )
  "!FB_DISKPART!" /s "!dpScript!" >> "!log!" 2>&1
)

if not exist "W:\" (
  echo ERROR: W: not found. See %log%
  ping -n 11 127.0.0.1 >nul
  exit /b 1
)
if not exist "S:\" (
  echo ERROR: S: not found. See %log%
  ping -n 11 127.0.0.1 >nul
  exit /b 1
)

echo [%DATE% %TIME%] success >> "%log%"
exit /b 0

:FB_RESOLVE_PS
if defined FB_PS if exist "!FB_PS!" exit /b 0
set "FB_PS="
REM WinPE: SystemRoot may be set before powershell is populated; X:\ is the usual RAMDISK.
if not defined FB_PS if exist "X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" set "FB_PS=X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined FB_PS if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "FB_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined FB_PS if exist "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" set "FB_PS=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined FB_PS for /f "delims=" %%P in ('where powershell.exe 2^>nul') do if not defined FB_PS set "FB_PS=%%~fP"
if not defined FB_PS for /f "delims=" %%P in ('dir /s /b "%SystemRoot%\powershell.exe" 2^>nul') do if not defined FB_PS set "FB_PS=%%~fP"
if defined FB_PS echo [%DATE% %TIME%] FB_PS=!FB_PS! >> "%log%"
if not defined FB_PS echo [%DATE% %TIME%] FB_PS not found - Get-Partition media-disk fallback unavailable >> "%log%"
if not defined FB_PS echo [%DATE% %TIME%] SystemRoot=%SystemRoot% WINDIR=%WINDIR% >> "%log%"
exit /b 0

:FB_RESOLVE_DISKPART
set "FB_DISKPART="
if exist "%SystemRoot%\System32\diskpart.exe" set "FB_DISKPART=%SystemRoot%\System32\diskpart.exe"
if not defined FB_DISKPART if exist "%WINDIR%\System32\diskpart.exe" set "FB_DISKPART=%WINDIR%\System32\diskpart.exe"
if not defined FB_DISKPART if exist "X:\Windows\System32\diskpart.exe" set "FB_DISKPART=X:\Windows\System32\diskpart.exe"
if not defined FB_DISKPART for /f "delims=" %%Q in ('where diskpart 2^>nul') do if not defined FB_DISKPART set "FB_DISKPART=%%~fQ"
if not defined FB_DISKPART set "FB_DISKPART=diskpart"
echo [%DATE% %TIME%] FB_DISKPART=!FB_DISKPART! >> "%log%"
exit /b 0

:: -- FB_DP_RUN  scriptfile  outfile ------------------------------------------
:: Runs diskpart ONCE against a script file, captures its output to a file the
:: parsers read, and copies that output into the deploy log. Everything downstream
:: parses the CAPTURE FILE because a for /f whose command string starts with a
:: double quote is mangled by cmd and never runs. Mirrors TechInstall-Install.cmd.
:FB_DP_RUN
set "_DPS=%~1"
set "_DPO=%~2"
if not defined _DPS exit /b 0
if not defined _DPO exit /b 0
"!FB_DISKPART!" /s "!_DPS!" > "!_DPO!" 2>&1
type "!_DPO!" >> "%log%" 2>nul
exit /b 0

:: -- FB_DISK_OF_LETTER  letter -----------------------------------------------
:: FB_DOL_DISK = physical disk hosting that drive letter (digits only).
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

:: -- FB_DOL_PARSE  capturefile  ---------------------------------------------
:: "* Disk N" from detail volume. Token 3 is the disk number. Avoid "if not
:: defined" inside for/( ) - cmd parses the whole block once and never assigns.
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
:: Walk disks 0-7; token 3 on "Volume #  Ltr ..." rows is the drive letter.
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

:: -- FB_MEDIADISK_PS_FALLBACK  (unused in disksetup - hangs WinPE pre-wipe) ----
:: Output goes to a file rather than a backquoted for/f, because that form also
:: starts with a double quote and hits the same cmd mangling (usebackq does not
:: help). Get-Partition additionally needs WinPE-StorageWMI, so this often answers
:: nothing - hence the runspace WaitOne timeout so control ALWAYS returns.
:FB_MEDIADISK_PS_FALLBACK
if not defined FB_PS exit /b 0
if not defined VL exit /b 0
echo [%DATE% %TIME%] media-disk fallback: bounded Get-Partition for !VL!: >> "%log%"
"!FB_PS!" -NoProfile -ExecutionPolicy Bypass -Command "$dl='!VL!'; $rs=[PowerShell]::Create(); [void]$rs.AddScript('param($d) try { $p = Get-Partition -DriveLetter $d -ErrorAction Stop; if ($null -ne $p) { [int]$p.DiskNumber } } catch {}').AddArgument($dl); $ah=$rs.BeginInvoke(); if ($ah.AsyncWaitHandle.WaitOne(6000)) { $rs.EndInvoke($ah) } else { try { $rs.Stop() } catch {} }; $rs.Dispose()" > "%FB_TMPD%\fb_psdisk_out.txt" 2>nul
for /f "usebackq tokens=1" %%a in ("%FB_TMPD%\fb_psdisk_out.txt") do (
  if not defined MEDIADISK set "MEDIADISK=%%a"
)
if defined MEDIADISK set "MEDIADISK_SRC=get-partition"
exit /b 0
