# FirstBaseDebugHotkeyWatcher.ps1
# DEBUG: Hotkey watcher — Ctrl+Shift+End → force OOBE handoff bypass
# Key combo: VK_CONTROL (0x11) + VK_SHIFT (0x10) + VK_END (0x23) per WinUser.h.
# GetAsyncKeyState uses virtual-key codes (not scan codes); VK_END is correct for the
# navigation-cluster End key. Numpad routing uses the same VK when NumLock sends navigation.
# Writes: C:\ProgramData\FirstBase\.debug-force-oobe-handoff
#
# Launched by SetupComplete.cmd as FirstBase\DebugHotkeyWatcher (ONLOGON /IT)
# during the first image-apply specialize pass only (Bug U fence 1 gate).
# Deleted by Invoke-FbPreSysprepScrub STEP 2 and STEP 4 before sysprep.
#
# Behaviour:
#   - Polls GetAsyncKeyState every 250ms for Ctrl+Shift+End held simultaneously.
#   - Requires 3 consecutive positive polls (~750ms) to avoid accidental triggers.
#   - On confirmation: writes the flag file and logs the trigger, then exits.
#   - Also exits immediately if the flag already exists (another instance beat it).
#   - Single-shot: one press triggers one bypass; the process exits after writing.

$ErrorActionPreference = 'Continue'

# ---- paths ----
$flagFile   = 'C:\ProgramData\FirstBase\.debug-force-oobe-handoff'
$logDir     = 'C:\Windows\Setup\FirstBase\Logs'
$logFile    = Join-Path $logDir 'debug-hotkey-watcher.log'

# ---- log helper ----
function Write-WatcherLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] [DEBUG] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Add-Content -LiteralPath $logFile -Value $line -ErrorAction SilentlyContinue
    } catch {}
}

Add-Content -LiteralPath $logFile -Value ('[{0}] [DEBUG] [INFO] watcher entry PID={1} user={2}' -f (Get-Date -Format 'HH:mm:ss'), $PID, $env:USERNAME) -Encoding ASCII -ErrorAction SilentlyContinue
Write-WatcherLog "FirstBaseDebugHotkeyWatcher starting. Monitoring Ctrl+Shift+End (VK_CONTROL=0x11, VK_SHIFT=0x10, VK_END=0x23). Flag target: $flagFile" 'INFO'

# ---- early exit if flag already present ----
if (Test-Path -LiteralPath $flagFile) {
    Write-WatcherLog "Flag file already exists at '$flagFile'; exiting (another instance has already triggered the bypass)." 'WARN'
    exit 0
}
# ---- early exit if pipeline already complete ----
$pipelineMarker = 'C:\ProgramData\FirstBase\.pipeline-completed'
if (Test-Path -LiteralPath $pipelineMarker) {
    Write-WatcherLog "Pipeline already complete (.pipeline-completed found); exiting watcher (bypass not needed)." 'INFO'
    exit 0
}

# ---- P/Invoke GetAsyncKeyState from user32.dll ----
$csharp = @'
using System;
using System.Runtime.InteropServices;
public class FbHotkey {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
    public static bool IsDown(int vKey) { return (GetAsyncKeyState(vKey) & 0x8000) != 0; }
}
'@
try {
    Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
} catch {
    $errLine = ('[{0}] [DEBUG] [ERROR] FbHotkey Add-Type failed: {1}' -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message)
    Add-Content -LiteralPath $logFile -Value $errLine -Encoding ASCII -ErrorAction SilentlyContinue
    Write-WatcherLog ("Add-Type FbHotkey failed: {0}; hotkey monitoring unavailable. Exiting." -f $_.Exception.Message) 'WARN'
    exit 1
}

Write-WatcherLog "P/Invoke FbHotkey loaded. Polling every 250ms. Hold Ctrl+Shift+End for ~750ms to trigger bypass." 'INFO'

# ---- poll loop ----
$consecutiveHits = 0
$VK_CONTROL = 0x11
$VK_SHIFT   = 0x10
$VK_END     = 0x23
$requiredHits = 3

while ($true) {
    # Re-check flag each poll in case another process wrote it
    if (Test-Path -LiteralPath $flagFile) {
        Write-WatcherLog "Flag file detected during poll (written externally); exiting clean." 'WARN'
        exit 0
    }

    $allDown = $false
    try {
        $allDown = ([FbHotkey]::IsDown($VK_CONTROL) -and [FbHotkey]::IsDown($VK_SHIFT) -and [FbHotkey]::IsDown($VK_END))
    } catch {
        # GetAsyncKeyState failure is non-fatal; reset counter and continue
        $consecutiveHits = 0
        Start-Sleep -Milliseconds 250
        continue
    }

    if ($allDown) {
        $consecutiveHits++
        Write-WatcherLog ("[DEBUG] Ctrl+Shift+End detected (consecutive hit {0}/{1})" -f $consecutiveHits, $requiredHits) 'INFO'
        if ($consecutiveHits -ge $requiredHits) {
            # Confirmed — write the flag file and exit
            Write-WatcherLog "[DEBUG] 2249: Ctrl+Shift+End confirmed ($requiredHits consecutive polls). Writing debug bypass flag." 'WARN'
            try {
                if (-not (Test-Path -LiteralPath 'C:\ProgramData\FirstBase')) {
                    New-Item -ItemType Directory -Path 'C:\ProgramData\FirstBase' -Force -ErrorAction SilentlyContinue | Out-Null
                }
                $flagContent = ("debug-force-oobe-handoff triggered at {0} by Ctrl+Shift+End (FirstBaseDebugHotkeyWatcher.ps1 PID={1})" -f (Get-Date -Format 'o'), $PID)
                [System.IO.File]::WriteAllText($flagFile, $flagContent, [System.Text.Encoding]::UTF8)
                Write-WatcherLog ("[DEBUG] 2249: Flag written to '{0}'. Invoke-WindowsUpdateLoop.ps1 will detect this at the next iteration top and route to OOBE handoff. Exiting watcher." -f $flagFile) 'WARN'
            } catch {
                Write-WatcherLog ("[DEBUG] 2249: Flag write failed: {0}; bypass may not take effect." -f $_.Exception.Message) 'WARN'
            }
            exit 0
        }
    } else {
        if ($consecutiveHits -gt 0) {
            Write-WatcherLog ("[DEBUG] Ctrl+Shift+End released after {0} hit(s); resetting counter." -f $consecutiveHits) 'INFO'
        }
        $consecutiveHits = 0
    }

    Start-Sleep -Milliseconds 250
}
