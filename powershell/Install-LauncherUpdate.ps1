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

# --- Copy new exe over old with retry -----------------------------------------
$attempt = 0
$copied  = $false
while ($attempt -lt 5 -and -not $copied) {
    try {
        Copy-Item -Path $SourceExe -Destination $TargetExe -Force -ErrorAction Stop
        $copied = $true
        Log "Copy succeeded on attempt $($attempt+1)"
    } catch {
        $attempt++
        Log "Copy attempt $attempt failed: $($_.Exception.Message)"
        if ($attempt -lt 5) { Start-Sleep -Seconds 1 }
    }
}

if (-not $copied) {
    Log "ERROR: All copy attempts failed - aborting relaunch"
    exit 1
}

# Verify the copy
$dstSize = (Get-Item -LiteralPath $TargetExe -ErrorAction SilentlyContinue).Length
Log "Target size after copy: $([math]::Round($dstSize/1MB,1)) MB"

# --- Unblock: remove Zone.Identifier ADS (Mark of the Web) -------------------
# Files copied from a network share are tagged with a security zone that causes
# Windows to block or warn on the embedded requireAdministrator manifest.
# Removing the stream restores normal UAC elevation behavior.
try {
    Unblock-File -LiteralPath $TargetExe -ErrorAction Stop
    Log "Unblocked: Zone.Identifier removed from $TargetExe"
} catch {
    # Unblock-File not available on all PS versions - remove the stream directly
    $zoneStream = "$TargetExe`:Zone.Identifier"
    if (Test-Path -LiteralPath $zoneStream) {
        Remove-Item -LiteralPath $zoneStream -Force -ErrorAction SilentlyContinue
        Log "Zone.Identifier stream removed manually"
    } else {
        Log "No Zone.Identifier stream found (already clean)"
    }
}

# Clean up temp source
Remove-Item -LiteralPath $SourceExe -Force -ErrorAction SilentlyContinue
Log "Temp source cleaned up"

# --- Relaunch as administrator ------------------------------------------------
Log "Relaunching: $TargetExe"
try {
    Start-Process -FilePath $TargetExe -Verb RunAs -ErrorAction Stop
    Log "Relaunch succeeded"
} catch {
    # Verb RunAs may fail in some contexts - fall back to plain launch
    Log "RunAs relaunch failed ($($_.Exception.Message)) - trying plain launch"
    try {
        Start-Process -FilePath $TargetExe
        Log "Plain relaunch succeeded"
    } catch {
        Log "ERROR: All relaunch attempts failed: $($_.Exception.Message)"
        exit 1
    }
}

Log "=== Installer complete ==="
exit 0
