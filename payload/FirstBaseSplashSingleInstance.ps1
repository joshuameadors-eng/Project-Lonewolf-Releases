<#
.SYNOPSIS
    FirstBase Windows Update splash single-instance wrapper.
    For Internal Use Only.

.DESCRIPTION
    2026.05.18.2213l Bug EE wrapper. Replaces the prior direct invocation
    of Show-UpdateProgress.ps1 from FirstBaseSplashLauncher.cmd. Provides
    a bulletproof single-instance gate by holding an exclusive
    FileShare::None lock on splash-launcher.lock for the entire lifetime
    of the WPF splash; any sibling launcher invocation (Layer 2 OnLogon
    task FirstBase\UpdateSplash + Layer 4 loop-spawned schtasks bridge
    FirstBase\UpdateSplashLayer4) lands on a sharing-violation IOException
    and exits clean instead of spawning a duplicate WPF window.

    The 2213k field run produced 2 WPF splash + 2 console fallback per
    boot because Layer 2 and Layer 4 both fired at startup without
    cross-process coordination. This wrapper makes that impossible by
    construction: one and only one wrapper invocation per boot holds
    the lock, every other invocation logs and exits 0.

    As of centralized versioning (``FirstBaseVersion.ps1``), Show-UpdateProgress.ps1
    is no longer byte-frozen; see RELEASE.txt / build-version.txt for the
    current payload SHA256. This wrapper does not modify it - it runs the
    script inline AFTER lock acquisition succeeds and disposes the lock on exit.

    Logs to splash-launcher-instances.log so a tech can see exactly
    which launcher PID won the race and which ones lost (and why).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$fbVerPs1 = Join-Path 'C:\Windows\Setup\FirstBase' 'FirstBaseVersion.ps1'
if (-not (Test-Path -LiteralPath $fbVerPs1)) {
    $fbVerPs1 = Join-Path $PSScriptRoot 'FirstBaseVersion.ps1'
}
if (Test-Path -LiteralPath $fbVerPs1) {
    . $fbVerPs1
} else {
    $FirstBaseProductVersion  = '1.0.0'
    $FirstBasePayloadRevision = 'unknown'
    $FirstBaseScriptVersion   = @{}
}
$fbWrapLeaf = 'FirstBaseSplashSingleInstance.ps1'
try {
    if ($MyInvocation.MyCommand.Path) { $fbWrapLeaf = Split-Path -Leaf $MyInvocation.MyCommand.Path }
} catch {}
$script:ThisScriptVersion = [string]$FirstBaseScriptVersion[$fbWrapLeaf]
if ([string]::IsNullOrWhiteSpace($script:ThisScriptVersion)) { $script:ThisScriptVersion = $FirstBaseProductVersion }

$FbStateDir   = 'C:\Windows\Setup\FirstBase\State'
$FbLogDir     = 'C:\Windows\Setup\FirstBase\Logs'
$FbRoot       = 'C:\Windows\Setup\FirstBase'
$LockPath     = Join-Path $FbStateDir 'splash-launcher.lock'
$LogPath      = Join-Path $FbLogDir 'splash-launcher-instances.log'
$SplashScript = Join-Path $FbRoot 'Show-UpdateProgress.ps1'

# 2026.05.19.2213p Bug LL: wrapper entry marker. The very first thing this
# wrapper does is stamp splash-wrapper-entry.log so we can prove (or
# disprove) that the PS1 was ever entered. On Dell Latitude 7450 (dump
# 1136) FirstBase\UpdateSplash reports Last Result=0 but produces no
# splash-launcher-instances.log entries, no splash-ui.log lines, and no
# splash PIDs anywhere. If splash-wrapper-entry.log ALSO does not appear
# on the next Dell dump, root cause is upstream of this wrapper (launcher
# .cmd or scheduled task firing into a degraded context that cannot host
# powershell.exe -File). If the entry log DOES appear but no
# splash-launcher-instances.log entry follows, the lock-acquisition path
# is the failure point. Diagnostic-only: write is wrapped in try{}, never
# throws, never blocks the lock-attempt below.
$EntryLogPath = Join-Path $FbLogDir 'splash-wrapper-entry.log'
try {
    if (-not (Test-Path -LiteralPath $FbLogDir)) {
        New-Item -ItemType Directory -Path $FbLogDir -Force | Out-Null
    }
    $entrySession = -1
    try { $entrySession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId } catch {}
    $entryUser = '<unknown>'
    try { $entryUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch {}
    $entryHost = '<unknown>'
    try { $entryHost = $Host.Name } catch {}
    $entryPwd  = '<unknown>'
    try { $entryPwd = (Get-Location).Path } catch {}
    $entryArgs = '<unknown>'
    try { if ($MyInvocation -and $MyInvocation.Line) { $entryArgs = [string]$MyInvocation.Line } } catch {}
    $entryLine = ('[{0}] [wrapper pid={1}] [session={2}] [user={3}] [host={4}] [pwd={5}] [invocation={6}] entered wrapper PS1' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fff'), $PID, $entrySession, $entryUser, $entryHost, $entryPwd, $entryArgs)
    Add-Content -LiteralPath $EntryLogPath -Value $entryLine -Encoding UTF8 -ErrorAction SilentlyContinue
} catch {}

function Write-FbSplashLog {
    param([string]$Level, [string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $FbLogDir)) {
            New-Item -ItemType Directory -Path $FbLogDir -Force | Out-Null
        }
        $line = ('[{0}] [{1}] [wrapper pid={2}] {3}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Level, $PID, $Message)
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

try {
    if (-not (Test-Path -LiteralPath $FbStateDir)) {
        New-Item -ItemType Directory -Path $FbStateDir -Force | Out-Null
    }
} catch {
    Write-FbSplashLog 'ERROR' ("State dir create threw: {0}" -f $_.Exception.Message)
}

Write-FbSplashLog 'INFO' ("FirstBase product={0} script={1} payload={2}" -f $FirstBaseProductVersion, $script:ThisScriptVersion, $FirstBasePayloadRevision)

# 2256/2295: Do not acquire splash lock after delivery started or operator seal (RunOnce / task can still invoke launcher).
$fbPdPipe = 'C:\ProgramData\FirstBase\.pipeline-completed'
$fbPdDeliveryStarted = 'C:\ProgramData\FirstBase\.oobe-sound-delivery-started'
$fbPdSeal = 'C:\ProgramData\FirstBase\.firstbase-sealed'
$fb2295LegacyDeliveryStarted = $false
if (Test-Path -LiteralPath $fbPdPipe) {
    try {
        $fb2295LegacyTxt = [string](Get-Content -LiteralPath $fbPdPipe -Raw -ErrorAction SilentlyContinue)
        $fb2295LegacyDeliveryStarted = ($fb2295LegacyTxt -match 'Pipeline started')
    } catch {}
}
if ((Test-Path -LiteralPath $fbPdPipe) -or (Test-Path -LiteralPath $fbPdDeliveryStarted) -or $fb2295LegacyDeliveryStarted -or (Test-Path -LiteralPath $fbPdSeal)) {
    Write-FbSplashLog 'INFO' '2295: delivery-started, pipeline completed, or device sealed; skipping splash wrapper.'
    exit 0
}

$lockStream = $null
try {
    # FileShare::None means: only the holder of this handle can open the
    # file for ANY access. Any sibling launcher PID hitting File.Open on
    # the same path gets IOException ("the process cannot access the file
    # because it is being used by another process.") regardless of
    # account identity (SYSTEM, Administrator, anyone). Same primitive
    # the loop's wu-loop.lock uses for cross-session single-instance.
    $lockStream = [System.IO.File]::Open(
        $LockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    # Stamp PID + start time into the lock file so a tech can `type
    # splash-launcher.lock` and see WHICH wrapper PID owns it. The lock
    # itself is the synchronization primitive; the file contents are
    # purely diagnostic.
    try {
        $stamp = ("pid={0}`nstarted={1}`nscript={2}`n" -f $PID, (Get-Date).ToString('o'), $SplashScript)
        $stampBytes = [System.Text.Encoding]::ASCII.GetBytes($stamp)
        $lockStream.SetLength(0)
        $lockStream.Write($stampBytes, 0, $stampBytes.Length)
        $lockStream.Flush()
    } catch {}
    Write-FbSplashLog 'INFO' ("acquired lock {0}; about to invoke {1}" -f $LockPath, $SplashScript)
} catch [System.IO.IOException] {
    # Duplicate instance: another holder has FileShare::None (HRESULT sharing violation).
    # Other IOExceptions (access denied, path too long, etc.): log ERROR and exit 1 so schtasks Last Result is non-zero.
    $ioEx = $_.Exception
    $hr = $ioEx.HResult
    $isSharingViolation =
        ($hr -eq -2147024864) -or
        ($hr -eq 0x80070020) -or
        (($ioEx.InnerException -is [System.ComponentModel.Win32Exception]) -and
            (32 -eq ([System.ComponentModel.Win32Exception]$ioEx.InnerException).NativeErrorCode))
    if ($isSharingViolation) {
        Write-FbSplashLog 'WARN' ("SKIPPED (sibling holds lock {0}): {1}" -f $LockPath, $ioEx.Message)
        exit 0
    }
    Write-FbSplashLog 'ERROR' ("lock open failed (IOException, not sharing violation) on {0}: {1} [HRESULT=0x{2:X8}]" -f $LockPath, $ioEx.Message, $hr)
    exit 1
} catch {
    Write-FbSplashLog 'ERROR' ("lock-attempt-threw (non-IO) on {0}: {1}; cannot acquire exclusive lock" -f $LockPath, $_.Exception.Message)
    exit 1
}

try {
    if (-not (Test-Path -LiteralPath $SplashScript)) {
        Write-FbSplashLog 'ERROR' ("Splash script missing at {0}; nothing to launch." -f $SplashScript)
        exit 1
    }
    # Run the WPF splash inline so the lock stays held for its lifetime.
    # Show-UpdateProgress.ps1's WPF ShowDialog blocks until the dashboard
    # window closes; we get the lock release for free when the script
    # returns and PowerShell tears down our process. Dot-source the
    # script so $PSScriptRoot inside it resolves to FbRoot (matches the
    # legacy direct -File invocation behavior closely enough; the splash
    # script does not depend on $MyInvocation.MyCommand.Path).
    Write-FbSplashLog 'INFO' ("invoking splash {0}" -f $SplashScript)
    & $SplashScript
    Write-FbSplashLog 'INFO' ("splash returned cleanly; releasing lock on exit.")
} catch {
    Write-FbSplashLog 'ERROR' ("splash invocation threw: {0}" -f $_.Exception.Message)
} finally {
    if ($null -ne $lockStream) {
        try { $lockStream.Close() } catch {}
        try { $lockStream.Dispose() } catch {}
    }
}

exit 0
