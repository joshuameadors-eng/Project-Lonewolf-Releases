<#
.SYNOPSIS
  Replaces the running LoneWolf Launcher exe with a newer version and relaunches.

.DESCRIPTION
  Waits for the old Electron process to exit, copies the new exe over the old
  one (with retry), then launches the new version as administrator.
  Spawned by the Electron app in a hidden window just before app.quit().
  All steps are logged to %TEMP%\lonewolf-installer.log for diagnostics.

  Dev-mode safety: if $TargetExe resolves to an Electron or Node binary (not a
  packaged portable exe), the copy step is skipped and the script exits cleanly.
#>

param(
    [Parameter(Mandatory)] [string]$SourceExe,
    [Parameter(Mandatory)] [string]$TargetExe,
    [Parameter(Mandatory)] [int]$OldPid
)

$ErrorActionPreference = 'Continue'

# --- Log helper ---------------------------------------------------------------
# Use ProgramData (always writable from admin context) instead of $env:TEMP,
# which resolves to C:\Windows\TEMP in a hidden elevated detached PS process.
$LogDir  = 'C:\ProgramData\LoneWolf'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir 'installer.log'
function Log {
    param([string]$m)
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $m"
    Write-Host $line
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8 } catch {}
}
function Get-LwStableLauncherExe {
    return (Join-Path ${env:ProgramFiles} 'Project LoneWolf Launcher\LoneWolf-Launcher.exe')
}

function Test-LwUnstableLauncherPath {
    param([string]$Path)
    if (-not $Path) { return $true }
    $p = [string]$Path
    if ($p -match '(?i)\\Temp\\') { return $true }
    if ($p -match '(?i)\\Downloads\\') { return $true }
    if ($p -match '(?i)LoneWolf-Launcher-Setup\.exe$') { return $true }
    if ($p -match '(?i)\.(new|incoming)$') { return $true }
    return $false
}

$stableExe = Get-LwStableLauncherExe
if (Test-LwUnstableLauncherPath -Path $TargetExe) {
    Log "TargetExe was unstable ($TargetExe) - using Program Files path"
}
$TargetExe = $stableExe

Log "=== LoneWolf Installer started ==="
Log "SourceExe : $SourceExe"
Log "TargetExe : $TargetExe"
Log "OldPid    : $OldPid"

# --- Dev-mode safety guard ----------------------------------------------------
if ($TargetExe -match 'electron\.exe$' -or $TargetExe -match 'node\.exe$') {
    Log "Dev mode detected - skipping replacement"
    exit 0
}

# --- Validate source exists ---------------------------------------------------
if (-not (Test-Path -LiteralPath $SourceExe)) {
    Log "ERROR: Source exe not found: $SourceExe"
    exit 1
}
$srcSize = (Get-Item -LiteralPath $SourceExe).Length
Log "Source size: $([math]::Round($srcSize/1MB,1)) MB"

# --- Wait for old process to exit ---------------------------------------------
Log "Waiting for old process (PID $OldPid) to exit..."
$elapsed = 0
while ($elapsed -lt 30000) {
    $proc = Get-Process -Id $OldPid -ErrorAction SilentlyContinue
    if (-not $proc) { Log "Old process exited."; break }
    Start-Sleep -Milliseconds 200
    $elapsed += 200
}
if ($elapsed -ge 30000) {
    Log "WARNING: Timed out waiting for old process - attempting copy anyway"
}

Start-Sleep -Milliseconds 500   # extra settle time for file handles

# --- Copy new exe over old with retry (never delete or rename the live exe first)
$targetDir = Split-Path $TargetExe
if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}
$staged = "$TargetExe.incoming"
if ([string]$SourceExe -ne [string]$staged) {
    try {
        Copy-Item -LiteralPath $SourceExe -Destination $staged -Force -ErrorAction Stop
        Log "Staged incoming beside target: $staged"
    } catch {
        Log "ERROR: Could not stage incoming file: $($_.Exception.Message)"
        Log "Leaving the installed exe in place"
        if (Test-Path -LiteralPath $TargetExe) {
            $relaunchExe = $TargetExe
        } else {
            exit 1
        }
    }
}

$relaunchExe = $TargetExe
$attempt = 0
$copied  = $false
if (Test-Path -LiteralPath $staged) {
    while ($attempt -lt 5 -and -not $copied) {
        try {
            Copy-Item -LiteralPath $staged -Destination $TargetExe -Force -ErrorAction Stop
            $copied = $true
            Log "Copy succeeded on attempt $($attempt+1)"
        } catch {
            $attempt++
            Log "Copy attempt $attempt failed: $($_.Exception.Message)"
            if ($attempt -lt 5) { Start-Sleep -Seconds 1 }
        }
    }
}

if (-not $copied) {
    Log "ERROR: Replace failed - leaving the old exe in place (never deleted first)"
    if (-not (Test-Path -LiteralPath $TargetExe)) {
        Log "ERROR: Target exe is missing; cannot relaunch"
        exit 1
    }
}

# Verify the copy
$dstSize = (Get-Item -LiteralPath $TargetExe -ErrorAction SilentlyContinue).Length
Log "Target size after copy: $([math]::Round($dstSize/1MB,1)) MB"

# --- Unblock: remove Zone.Identifier ADS (Mark of the Web) -------------------
if ($copied) {
    try {
        Unblock-File -LiteralPath $TargetExe -ErrorAction Stop
        Log "Unblocked: Zone.Identifier removed from $TargetExe"
    } catch {
        $zoneStream = "$TargetExe`:Zone.Identifier"
        if (Test-Path -LiteralPath $zoneStream) {
            Remove-Item -LiteralPath $zoneStream -Force -ErrorAction SilentlyContinue
            Log "Zone.Identifier stream removed manually"
        } else {
            Log "No Zone.Identifier stream found (already clean)"
        }
    }
} else {
    Log "Skipping unblock because replace did not succeed"
}

# Clean up staging only after a successful replace. Never delete the live exe.
if ($copied) {
    foreach ($p in @($SourceExe, $staged)) {
        if (-not $p) { continue }
        $sameAsTarget = $false
        try {
            if ((Test-Path -LiteralPath $p) -and (Test-Path -LiteralPath $TargetExe)) {
                $sameAsTarget = ((Resolve-Path -LiteralPath $p).Path -eq (Resolve-Path -LiteralPath $TargetExe).Path)
            }
        } catch { $sameAsTarget = $false }
        if ($sameAsTarget) { continue }
        if ((Test-LwUnstableLauncherPath -Path $p) -or ($p -like '*.incoming') -or ($p -like '*.new')) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            Log "Removed staging file: $p"
        }
    }
} else {
    Log "Kept staging and target because replace failed"
}

# Desktop / Start Menu shortcuts: create if missing, never delete.
function Ensure-LwUpdateShortcut {
    param([string]$LnkPath, [string]$Target)
    if (-not $Target -or -not (Test-Path -LiteralPath $Target)) { return }
    if (Test-LwUnstableLauncherPath -Path $Target) { return }
    if (Test-Path -LiteralPath $LnkPath) {
        try {
            $w0 = New-Object -ComObject WScript.Shell
            $cur = [string]($w0.CreateShortcut($LnkPath).TargetPath)
            if ($cur -eq $Target) {
                Log "Shortcut already present: $LnkPath"
                return
            }
            if (-not (Test-LwUnstableLauncherPath -Path $cur)) {
                Log "Shortcut already present: $LnkPath"
                return
            }
            Log "Retargeting unstable shortcut (no delete): $LnkPath"
        } catch {
            Log "Shortcut already present: $LnkPath"
            return
        }
    }
    $dir = Split-Path $LnkPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    try {
        $w = New-Object -ComObject WScript.Shell
        $s = $w.CreateShortcut($LnkPath)
        $s.TargetPath = $Target
        $s.WorkingDirectory = Split-Path $Target
        $s.WindowStyle = 1
        $s.Description = 'Project LoneWolf Launcher'
        $s.Save()
        if (Test-Path -LiteralPath $LnkPath) {
            $bytes = [System.IO.File]::ReadAllBytes($LnkPath)
            if ($bytes.Length -gt 0x15) {
                $bytes[0x15] = $bytes[0x15] -bor 0x20
                [System.IO.File]::WriteAllBytes($LnkPath, $bytes)
            }
        }
        Log "Created missing shortcut: $LnkPath"
    } catch {
        Log "WARN: could not create shortcut $LnkPath : $($_.Exception.Message)"
    }
}
$desk = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Project LoneWolf Launcher.lnk'
$sm = Join-Path ([Environment]::GetFolderPath('CommonStartMenu')) 'Programs\Project LoneWolf Launcher.lnk'
Ensure-LwUpdateShortcut -LnkPath $desk -Target $TargetExe
Ensure-LwUpdateShortcut -LnkPath $sm -Target $TargetExe

# --- Relaunch as administrator ------------------------------------------------
Log "Relaunching: $relaunchExe"
try {
    Start-Process -FilePath $relaunchExe -Verb RunAs -ErrorAction Stop
    Log "Relaunch succeeded"
} catch {
    # Verb RunAs may fail in some contexts - fall back to plain launch
    Log "RunAs relaunch failed ($($_.Exception.Message)) - trying plain launch"
    try {
        Start-Process -FilePath $relaunchExe
        Log "Plain relaunch succeeded"
    } catch {
        Log "ERROR: All relaunch attempts failed: $($_.Exception.Message)"
        exit 1
    }
}

Log "=== Installer complete ==="
exit 0
