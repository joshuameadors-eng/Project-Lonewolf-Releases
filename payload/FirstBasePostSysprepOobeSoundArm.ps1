# FirstBase 2244: detached survivor — completes ONLOGON schtasks arm after sysprep validation.
# Parent Invoke-WindowsUpdateLoop.ps1 must NOT block on schtasks /Create -Wait (fb-dump-final-859).
# Script kit staging, HKLM Run + RunOnce + markers are handled by the parent before spawn;
# this worker is the only process that may use schtasks /Create -Wait for DeferredOobeSoundOnLogon.
# 2244: HKLM Run fallback now targets FirstBaseOobeDeferredSoundBootstrap.ps1 (not deferred sound
# directly) so all delivery paths share the stale-lock-aware bootstrap.
# For Internal Use Only.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$FbLogDir = 'C:\Windows\Setup\FirstBase\Logs'
$PdDir = 'C:\ProgramData\FirstBase'
$MirrorLogPd = Join-Path $PdDir 'WU-oobe-sound-onlogon-arm.log'
$MirrorLog = Join-Path $FbLogDir 'WU-oobe-sound-onlogon-arm.log'
$Tn = 'FirstBase\DeferredOobeSoundOnLogon'
$PdPs1 = Join-Path $PdDir 'FirstBaseDeferredOobeSound.ps1'
$PdBootstrap = Join-Path $PdDir 'FirstBaseOobeDeferredSoundBootstrap.ps1'
$OnLogonMarker = Join-Path $PdDir '.deferred-oobe-sound-onlogon-task-armed'
$PipelineCompleted = Join-Path $PdDir '.pipeline-completed'

function Write-FbPostSysprepOobeSoundArmLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('[{0}] [{1}] {2}' -f (Get-Date -Format 'o'), $Level, $Message)
    foreach ($path in @($MirrorLogPd, $MirrorLog)) {
        try {
            $dir = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Add-Content -LiteralPath $path -Value $line -Encoding ascii -ErrorAction SilentlyContinue
        } catch {}
    }
    try {
        $latest = Get-ChildItem -LiteralPath $FbLogDir -Filter 'WU-*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) {
            Add-Content -LiteralPath $latest.FullName -Value ("[2231-onlogon-arm] {0}" -f $line) -Encoding ascii -ErrorAction SilentlyContinue
        }
    } catch {}
}

Write-FbPostSysprepOobeSoundArmLog ("2231: detached ONLOGON arm worker entry (PID {0})." -f $PID) 'INFO'

if (Test-Path -LiteralPath $PipelineCompleted) {
    Write-FbPostSysprepOobeSoundArmLog '2231: .pipeline-completed present; skipping ONLOGON arm (already sealed).' 'INFO'
    exit 0
}

if (-not (Test-Path -LiteralPath $PdDir)) {
    try { New-Item -ItemType Directory -Path $PdDir -Force | Out-Null } catch {}
}

if (-not (Test-Path -LiteralPath $PdPs1)) {
    Write-FbPostSysprepOobeSoundArmLog ("2231: ABORT - missing deferred Sound script at {0}." -f $PdPs1) 'ERROR'
    exit 1
}

if (Test-Path -LiteralPath $OnLogonMarker) {
    Write-FbPostSysprepOobeSoundArmLog '2231: onlogon marker already present; exiting 0 (idempotent).' 'INFO'
    exit 0
}

$tr = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PdPs1)  # 2258: Hidden to suppress OOBE logon window flash
try {
    $null = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Delete', '/TN', $Tn, '/F') -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
} catch {}

$taskOk = $false
try {
    $exitCode = -1
    foreach ($createArgs in @(
            @('/Create', '/TN', $Tn, '/SC', 'ONLOGON', '/RL', 'HIGHEST', '/F', '/TR', $tr)
            @('/Create', '/TN', $Tn, '/SC', 'ONLOGON', '/RL', 'HIGHEST', '/IT', '/F', '/TR', $tr)
        )) {
        $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList $createArgs -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
        $exitCode = if ($null -ne $p) { [int]$p.ExitCode } else { -1 }
        if ($exitCode -eq 0) {
            try {
                $q = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Query', '/TN', $Tn, '/FO', 'LIST') -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
                if ($null -ne $q -and $q.ExitCode -eq 0) { $taskOk = $true; break }
            } catch {}
            Write-FbPostSysprepOobeSoundArmLog ("2234: schtasks /Create {0} exit 0 but /Query missing; retrying." -f $Tn) 'WARN'
        } else {
            Write-FbPostSysprepOobeSoundArmLog ("2234: schtasks /Create {0} returned exit {1}." -f $Tn, $exitCode) 'WARN'
        }
    }
} catch {
    Write-FbPostSysprepOobeSoundArmLog ("2231: schtasks /Create threw: {0}" -f $_.Exception.Message) 'ERROR'
}

if ($taskOk) {
    try {
        $existing = Get-ScheduledTask -TaskPath '\FirstBase\' -TaskName 'DeferredOobeSoundOnLogon' -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            $settings = New-ScheduledTaskSettingsSet `
                -StartWhenAvailable `
                -DontStopIfGoingOnBatteries `
                -AllowStartIfOnBatteries `
                -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
                -MultipleInstances IgnoreNew
            Set-ScheduledTask -TaskPath '\FirstBase\' -TaskName 'DeferredOobeSoundOnLogon' -Settings $settings -ErrorAction Stop | Out-Null
            Write-FbPostSysprepOobeSoundArmLog '2231: StartWhenAvailable settings applied to DeferredOobeSoundOnLogon.' 'INFO'
        }
    } catch {
        Write-FbPostSysprepOobeSoundArmLog ("2231: Set-ScheduledTask settings WARN (schtasks-only remains): {0}" -f $_.Exception.Message) 'WARN'
    }
    try {
        Set-Content -LiteralPath $OnLogonMarker -Value ("Armed at {0} (detached arm PID {1}) TR={2}" -f (Get-Date -Format 'o'), $PID, $tr) -Encoding UTF8 -Force
        Write-FbPostSysprepOobeSoundArmLog ("2231: registered {0} (ONLOGON /IT); marker written." -f $Tn) 'INFO'
        exit 0
    } catch {
        Write-FbPostSysprepOobeSoundArmLog ("2231: task created but marker write failed: {0}" -f $_.Exception.Message) 'WARN'
    }
}

# schtasks failed — HKLM Run fallback (2244: points to bootstrap for stale-lock-aware delivery;
# removed by FirstBaseOobeOperatorFinalize.ps1).
$runName = 'OpenWindowsSoundSettingsDeferredLogon'
$runRk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
# 2244: prefer bootstrap as HKLM Run target so all delivery paths share stale-lock detection.
$runTr = if (Test-Path -LiteralPath $PdBootstrap) {
    ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PdBootstrap)  # 2258: Hidden
} else {
    $tr
}
try {
    if (-not (Test-Path -LiteralPath $runRk)) {
        New-Item -Path $runRk -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $runRk -Name $runName -Value $runTr -Type String -Force
    $runKeyMarker = Join-Path $PdDir '.deferred-oobe-sound-run-key-armed'
    Set-Content -LiteralPath $runKeyMarker -Value ("Armed at {0} (detached PID {1})" -f (Get-Date -Format 'o'), $PID) -Encoding UTF8 -Force
    Write-FbPostSysprepOobeSoundArmLog ("2244: HKLM Run\{0} -> bootstrap fallback armed (schtasks ONLOGON failed; TR={1})." -f $runName, $runTr) 'WARN'
    exit 0
} catch {
    Write-FbPostSysprepOobeSoundArmLog ("2244: HKLM Run fallback failed: {0}" -f $_.Exception.Message) 'ERROR'
    exit 1
}
