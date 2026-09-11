<#
.SYNOPSIS
  Replaces the running LoneWolf Launcher exe with a newer version and relaunches.

.DESCRIPTION
  Waits for the old Electron process to exit, copies the new exe over the old
  one (with retry), then starts the new exe with a plain Start-Process.
  Do not use a hidden RunAs verb: that UAC wait never returns from a
  windowsHide parent, so the launcher never restarts. This script is already
  elevated when spawned from the packaged admin launcher, so the new process
  inherits that token. If elevation is missing, the exe manifest shows a
  visible UAC. Spawned by Electron just before app.quit().
  Logs to C:\ProgramData\LoneWolf\installer.log.

  Dev-mode safety: if $TargetExe resolves to an Electron or Node binary (not a
  packaged portable exe), the copy step is skipped and the script exits cleanly.
#>

param(
    [Parameter(Mandatory)] [string]$SourceExe,
    [Parameter(Mandatory)] [string]$TargetExe,
    [Parameter(Mandatory)] [int]$OldPid,
    [string]$UnpackDir = ''
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
function Get-LwInstallIdentity {
    $candidates = @(
        (Join-Path $PSScriptRoot 'install-identity.json'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'updater\install-identity.json'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\updater\install-identity.json')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            try { return Get-Content -Raw -LiteralPath $c | ConvertFrom-Json } catch { }
        }
    }
    return [pscustomobject]@{
        channel         = 'release'
        productName     = 'Project LoneWolf Launcher'
        exeName         = 'LoneWolf-Launcher.exe'
        installDirName  = 'Project LoneWolf Launcher'
        shortcutStem    = 'Project LoneWolf Launcher'
        setupName       = 'LoneWolf-Launcher-Setup.exe'
    }
}

function Get-LwIdentityFromPath {
    param([string]$Path)
    $p = [string]$Path
    if ($p -match '(?i)Launcher-Dev\.exe$' -or $p -match '(?i)Launcher Dev\\' -or $p -match '(?i)Setup-Dev\.exe$') {
        return [pscustomobject]@{
            channel         = 'dev'
            productName     = 'Project LoneWolf Launcher Dev'
            exeName         = 'LoneWolf-Launcher-Dev.exe'
            installDirName  = 'Project LoneWolf Launcher Dev'
            shortcutStem    = 'Project LoneWolf Launcher Dev'
            setupName       = 'LoneWolf-Launcher-Setup-Dev.exe'
        }
    }
    return $null
}

function Get-LwStableLauncherExe {
    param([string]$HintPath = '')
    $fromHint = Get-LwIdentityFromPath -Path $HintPath
    $id = if ($fromHint) { $fromHint } else { Get-LwInstallIdentity }
    if ($HintPath) {
        $p = [string]$HintPath
        $expected = Join-Path ${env:ProgramFiles} (Join-Path $id.installDirName $id.exeName)
        if ($p -ieq $expected) { return $p }
        if ($p -match [regex]::Escape($id.installDirName) -and $p -match [regex]::Escape($id.exeName) -and $p -notmatch '(?i)\\Temp\\') {
            return $p
        }
    }
    return (Join-Path ${env:ProgramFiles} (Join-Path $id.installDirName $id.exeName))
}

function Test-LwUnstableLauncherPath {
    param([string]$Path)
    if (-not $Path) { return $true }
    $p = [string]$Path
    if ($p -match '(?i)\\Temp\\') { return $true }
    if ($p -match '(?i)\\Downloads\\') { return $true }
    if ($p -match '(?i)LoneWolf-Launcher-Setup(-Dev)?\.exe$') { return $true }
    if ($p -match '(?i)\.(new|incoming)$') { return $true }
    return $false
}

function Test-LwTempUnpackDir {
    param([string]$Path)
    if (-not $Path) { return $false }
    $full = [string]$Path
    $temp = [IO.Path]::GetTempPath().TrimEnd('\')
    if ($full.Length -lt ($temp.Length + 2)) { return $false }
    if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -eq $false) { return $false }
    $leaf = Split-Path $full -Leaf
    if (-not $leaf) { return $false }
    if ($leaf -match '(?i)^(lw-public-src|lw-setup|lw-nsis|lonewolf)') { return $false }
    return $true
}

function Remove-LwPortableUnpackDir {
    param([string]$Dir, [string]$Reason)
    if (-not (Test-LwTempUnpackDir -Path $Dir)) { return }
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    $attempt = 0
    while ($attempt -lt 6) {
        try {
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction Stop
            Log "Removed portable unpack dir ($Reason): $Dir"
            return
        } catch {
            $attempt++
            Start-Sleep -Milliseconds 400
        }
    }
    Log "WARN: could not remove unpack dir $Dir"
}

function Remove-LwStalePortableUnpacks {
    param([string]$HintDir, [string]$ExeName)
    if ($HintDir) { Remove-LwPortableUnpackDir -Dir $HintDir -Reason 'this-run' }
    $temp = [IO.Path]::GetTempPath()
    Get-ChildItem -LiteralPath $temp -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $dir = $_.FullName
        if (-not (Test-LwTempUnpackDir -Path $dir)) { return }
        $rootExe = if ($ExeName) { Join-Path $dir $ExeName } else { $null }
        $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
        $empty = ($items.Count -eq 0)
        $sfxLeftover = $_.Name -match '^3J[A-Za-z0-9]{8,}$'
        $hasHintExe = ($rootExe -and (Test-Path -LiteralPath $rootExe))
        if (($empty -and $sfxLeftover) -or $hasHintExe) {
            Remove-LwPortableUnpackDir -Dir $dir -Reason $(if ($empty) { 'empty leftover' } else { 'stale inner exe' })
        }
    }
}

$stableExe = Get-LwStableLauncherExe -HintPath $TargetExe
if (Test-LwUnstableLauncherPath -Path $TargetExe) {
    Log "TargetExe was unstable ($TargetExe) - using Program Files path $stableExe"
    $TargetExe = $stableExe
}

Log "=== LoneWolf Installer started ==="
Log "SourceExe : $SourceExe"
Log "TargetExe : $TargetExe"
Log "OldPid    : $OldPid"
Log "UnpackDir : $UnpackDir"

$script:lwIdentity = Get-LwIdentityFromPath -Path $TargetExe
if (-not $script:lwIdentity) { $script:lwIdentity = Get-LwInstallIdentity }
$script:lwShortcutStem = [string]$script:lwIdentity.shortcutStem
$script:lwProductName = [string]$script:lwIdentity.productName
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

Start-Sleep -Milliseconds 1500   # SFX unpack dir is deleted on inner-exe exit; wait before we touch it
$exeLeaf = [IO.Path]::GetFileName($TargetExe)
Remove-LwStalePortableUnpacks -HintDir $UnpackDir -ExeName $exeLeaf

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
        $s.Description = $script:lwProductName
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
$desk = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) "$($script:lwShortcutStem).lnk"
$sm = Join-Path ([Environment]::GetFolderPath('CommonStartMenu')) "Programs\$($script:lwShortcutStem).lnk"
Ensure-LwUpdateShortcut -LnkPath $desk -Target $TargetExe
Ensure-LwUpdateShortcut -LnkPath $sm -Target $TargetExe

# 7z SFX reuses a leftover empty %TEMP%\3J* folder and then exits 1 without
# launching Electron. Sweep again right before start.
Remove-LwStalePortableUnpacks -HintDir $UnpackDir -ExeName $exeLeaf

# --- Relaunch (no hidden RunAs / UAC wait) ------------------------------------
# Use cmd start with an empty title. Start-Process on the 7z SFX from a
# minimized hidden host can return success while the unpacker exits 1
# because a leftover empty %TEMP%\3J* dir blocked re-extract.
Log "Relaunching (cmd start): $relaunchExe"
$workDir = Split-Path $relaunchExe
$cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
try {
    Start-Process -FilePath $cmd -ArgumentList @('/c', 'start', '', "`"$relaunchExe`"") -WorkingDirectory $workDir -ErrorAction Stop
    Log "Relaunch started"
} catch {
    Log "cmd start failed ($($_.Exception.Message)) - trying Start-Process"
    try {
        Start-Process -FilePath $relaunchExe -WorkingDirectory $workDir -ErrorAction Stop
        Log "Start-Process relaunch started"
    } catch {
        Log "ERROR: All relaunch attempts failed: $($_.Exception.Message)"
        exit 1
    }
}

Log "=== Installer complete ==="
exit 0
