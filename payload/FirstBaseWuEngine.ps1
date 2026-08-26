<#
.SYNOPSIS
    FirstBase native Windows Update Agent (COM) engine.
    For Internal Use Only.

.DESCRIPTION
    Pure native COM implementation backing Invoke-WindowsUpdateLoop.ps1.
    Uses the documented Microsoft.Update.Session / Microsoft.Update.Searcher /
    Microsoft.Update.Downloader / Microsoft.Update.Installer interfaces. No
    PSWindowsUpdate dependency.

    2026.05.13.0900-engine-sync-rewrite:
    The download + install path now runs INLINE in the foreground process
    (no Start-Job runspace boundary) and uses the SYNCHRONOUS Download() /
    Install() COM calls (no BeginDownload/BeginInstall + IsCompleted poll).
    See Invoke-FbWuApply's docstring for the full root-cause / fix story.

    Public functions:
      Invoke-FbWuScan            -> returns offered updates (filtered or full)
      Invoke-FbWuApply           -> downloads + installs targeted updates
      Test-FbWuRebootRequired    -> COM + registry reboot pending check
      Initialize-FbWuEnvironment -> registers Microsoft Update + clears WSUS pin
#>

Set-StrictMode -Version Latest

$script:FbWuMicrosoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'

# Version manifest (Payload\FirstBaseVersion.ps1); engine stamp uses per-script semver.
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
$fbThisLeaf = 'FirstBaseWuEngine.ps1'
try {
    if ($MyInvocation.MyCommand.Path) { $fbThisLeaf = Split-Path -Leaf $MyInvocation.MyCommand.Path }
} catch {}
$script:ThisScriptVersion = [string]$FirstBaseScriptVersion[$fbThisLeaf]
if ([string]::IsNullOrWhiteSpace($script:ThisScriptVersion)) { $script:ThisScriptVersion = $FirstBaseProductVersion }
# Stamped onto every INSTALL-DIAG-*.json and panic dump (same value as $script:ThisScriptVersion here).
$script:FbWuEngineVersion = $script:ThisScriptVersion

# ============================================================================
# 2026.05.18.2213l Bug FF: sticky residual mitigation (BOTH mechanisms).
# ============================================================================
# Symptom observed across boots 3-5 of the 2213k field run: KB5007651
# "Update for Windows Security platform" (UpdateId a32ca1d0-ddd4-486b-b708-
# d941db4f1101) returns ResultCode=2 (succeeded) on every install attempt,
# yet each post-install scan still reports it as applicable. The existing
# GivenUpUpdateIds mechanism (Bug Q convergence gate) only catches updates
# that FAIL; successful-but-still-offered never gets added. STAGE 1
# convergence refuses sysprep handoff indefinitely with postResidual=1,
# given-up=0. Boots 3, 4, 5 all hit ExitClass=budget-real and burn a reboot.
#
# Mechanism 1 (Generic - SOFT auto-GivenUp): after each successful install,
# track a per-UpdateId counter that increments on each subsequent scan
# where the same UpdateId is STILL applicable. When the counter crosses
# $script:FbSoftGivenUpThreshold, the UpdateId is promoted into
# GivenUpUpdateIds. The Bug Q convergence gate then filters it out and
# STAGE 1 sysprep handoff fires.
#
# Mechanism 2 (Surgical - Defender fast-path): known Defender platform
# GUIDs are listed in $script:FbDefenderPlatformGuids. After the first
# successful install of one of these in a boot, the per-boot tracker
# $script:FbDefenderInstalledThisBoot is marked so subsequent in-boot
# install attempts of the same UpdateId are SKIPPED entirely (per-boot
# dedupe). The same install path also PRE-SETS the SoftGivenUp counter
# to the threshold so the very next scan promotes the UpdateId straight
# into GivenUpSet without waiting for two full boot cycles to converge.
#
# Both counters live in $script:FbSoftGivenUpCounters and are mirrored by
# the loop into wu-state.json under SoftGivenUpCounters so they survive
# reboots. The loop owns the persistence; the engine owns only the
# threshold + Defender GUID constants and the per-boot tracker.
# ============================================================================
$script:FbSoftGivenUpThreshold = 2
$script:FbSoftGivenUpCounters  = @{}
# 5.4.18: one serialized Install() must not pin the splash for tens of
# minutes with no heartbeat. 600s (10 min) is the documented budget.
# On expiry: log title/KB, ResultCode=5, skip that update this boot.
# Do not stop TrustedInstaller. Do not fake 100%.
$script:FbWuPerUpdateInstallTimeoutSec = 600
$script:FbWuPerBucketDownloadTimeoutSec = 720
$script:FbInstallTimedOutThisBoot = @{}

# ============================================================================
# 2026.05.19.2213n Bug II: ScanStability convergence heuristic.
# ============================================================================
# User's literal convergence rule: "When all updates are completed and a
# scan lists the same update with no other updates, updates are complete."
#
# Operationalized: at the STAGE 1 OOBE handoff gate ONLY (boot-level gate
# scans, NOT the main-loop per-pass scan and NOT the STAGE 1 inline retry
# scan), fingerprint the set of "blocking" UpdateIds (scan rows whose
# UpdateId is NOT already in GivenUpSet AND NOT in ForceHiddenSet). If
# the same fingerprint repeats for $script:FbScanStabilityThreshold
# consecutive boot-level gate scans, bulk-promote every blocking
# UpdateId into GivenUpSet so the Bug Q residual gate clears and sysprep
# handoff fires.
#
# Closes the Scenario Z gap: a sticky update that failed install (so it
# is NOT in $script:FbSuccessLedgerSet) cannot be reached by the Bug FF
# Mechanism 1 SoftGivenUp path - that path requires a prior successful
# install. ScanStability is the orthogonal escape: a scan that just
# keeps offering the same set, regardless of why, eventually counts as
# converged-by-stability.
#
# Threshold = 2 is the literal interpretation of the user's rule (two
# consecutive matching scans = converged). STAGE 1 ONLY by design; the
# main-loop scan and the inline-retry scan run multiple times per boot
# and would over-promote. The STAGE 1 gate runs at most ONCE per boot
# and feeds directly into the sysprep decision, so it is the correct
# inflection point for a "give up because nothing is changing" gate.
# ============================================================================
$script:FbScanStabilityThreshold = 2
# Per-boot in-memory tracker for Mechanism 2. Reset to empty on each
# fresh engine module-load (which happens once per loop launch). NOT
# persisted: by design the skip is per-boot only; on the next boot a
# fresh install attempt is permitted so Defender platform updates can
# still be applied if the device genuinely needs them.
$script:FbDefenderInstalledThisBoot = @{}
# Known Defender platform UpdateIds. These updates return ResultCode=2
# on install but remain applicable on every subsequent scan (the WUA
# applicability metadata is intentionally sticky for security-platform
# packages). Add new GUIDs here if a field dump shows another Defender-
# class UpdateId triggering the same sticky-residual pattern.
$script:FbDefenderPlatformGuids = @(
    'a32ca1d0-ddd4-486b-b708-d941db4f1101',  # KB5007651 Windows Security platform (Bug FF triage 2213l)
    '3929eae1-c66b-4fae-ac30-e6add683fee2'   # KB4052623 Defender antimalware platform
)

# Diagnostic dump directory. Created on demand by Invoke-FbWuApply when it
# needs to write an INSTALL-DIAG-*.json. Must match the loop's $LogDir so
# the operator can read both side-by-side.
$script:FbWuLogDir = 'C:\Windows\Setup\FirstBase\Logs'

# 2026.05.13.2200-fullscope-multipass-progress: state directory used by the
# progress-poller sibling process (sentinel + JSON output). Directory is
# created on demand by Start-FbWuProgressPoller. Matches the loop-side
# $FbStateDir constant so the per-image cleanup in SetupComplete.cmd wipes
# the stale flag/marker files at re-image time.
$script:FbWuStateDir         = 'C:\Windows\Setup\FirstBase\State'
$script:FbWuProgressFile     = 'C:\Windows\Setup\FirstBase\wu-progress.json'
$script:FbWuPollerStopFlag   = 'C:\Windows\Setup\FirstBase\State\wu-progress-stop.flag'
$script:FbWuPollerLog        = 'C:\Windows\Setup\FirstBase\Logs\wu-progress-poller.log'

function Initialize-FbWuEnvironment {
    [CmdletBinding()]
    param()

    try {
        $auPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        if (Test-Path $auPolicy) {
            $useWsus = (Get-ItemProperty -Path $auPolicy -Name UseWUServer -ErrorAction SilentlyContinue).UseWUServer
            if ($useWsus -eq 1) {
                Set-ItemProperty -Path $auPolicy -Name UseWUServer -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}

    try {
        $svcMgr = New-Object -ComObject Microsoft.Update.ServiceManager
        $null = $svcMgr.AddService2($script:FbWuMicrosoftUpdateServiceId, 7, '')
    } catch {}
}

function Invoke-FbWuScan {
    <#
    .SYNOPSIS
        Runs ONE unfiltered online WUA scan and classifies results post-scan.

    .DESCRIPTION
        On modern Windows builds, scoping a WUA scan with `Type='Software'`
        or category-name whitelists drops most cumulative/security packages
        (they publish as Type=0/utNotSet and ship under volatile category
        names like "Windows 11", "Microsoft Server Operating System", etc.).
        We instead always run `IsInstalled=0 and IsHidden=0`, then bucket
        every offered update into Critical / Driver / Cumulative / Optional
        in PowerShell with a tolerant classifier.

        Legacy parameters (CategoryFilters / ExcludeCategories / TypeFilter)
        are accepted but IGNORED; the loop now decides install order via
        the per-record `Bucket` field.
    #>
    [CmdletBinding()]
    param(
        [string[]]$CategoryFilters = @(),
        [string[]]$ExcludeCategories = @(),
        [ValidateSet('Any','Software','Driver')]
        [string]$TypeFilter = 'Any',
        [int]$TimeoutSeconds = 1800
    )

    $job = Start-Job -ScriptBlock {
        param($muServiceId)
        $ErrorActionPreference = 'Stop'

        $svcManager = New-Object -ComObject Microsoft.Update.ServiceManager
        try { $null = $svcManager.AddService2($muServiceId, 7, '') } catch {}

        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searcher.Online = $true
        try {
            $searcher.ServerSelection = 3
            $searcher.ServiceID = $muServiceId
        } catch {
            $searcher.ServerSelection = 2
        }

        $result = $searcher.Search("IsInstalled=0 and IsHidden=0")

        $criticalCategoryHints = @('Security Updates','Critical Updates','Definition Updates')
        $cumulativeKeywordHints = @('Cumulative','Rollup','Servicing Stack','Latest Cumulative','LCU','SSU')

        $updates = @()
        for ($i = 0; $i -lt $result.Updates.Count; $i++) {
            $u = $result.Updates.Item($i)

            $catNames = @()
            for ($c = 0; $c -lt $u.Categories.Count; $c++) {
                $catNames += [string]$u.Categories.Item($c).Name
            }

            $kbList = @()
            for ($k = 0; $k -lt $u.KBArticleIDs.Count; $k++) {
                $kbList += ('KB' + [string]$u.KBArticleIDs.Item($k))
            }

            $rawType = 0
            try { $rawType = [int]$u.Type } catch { $rawType = 0 }
            $typeStr = switch ($rawType) {
                1 { 'Software' }
                2 { 'Driver'   }
                default { 'Software' }
            }

            $msrc = ''
            try { $msrc = [string]$u.MsrcSeverity } catch {}
            $isMandatory = $false
            try { $isMandatory = [bool]$u.IsMandatory } catch {}

            $title = [string]$u.Title
            $catBlob = (($catNames -join '|') + '|' + $title)

            $bucket = 'Optional'
            if ($rawType -eq 2) {
                $bucket = 'Driver'
            } elseif ($catNames | Where-Object { $_ -match 'Driver' }) {
                $bucket = 'Driver'
            } elseif ($isMandatory -or ($msrc -and ($msrc -match 'Critical|Important'))) {
                $bucket = 'Critical'
            } elseif ($catNames | Where-Object { $criticalCategoryHints -contains $_ }) {
                $bucket = 'Critical'
            } else {
                foreach ($hint in $cumulativeKeywordHints) {
                    if ($catBlob -match [regex]::Escape($hint)) { $bucket = 'Cumulative'; break }
                }
            }

            $updates += [pscustomobject]@{
                Title        = $title
                UpdateId     = [string]$u.Identity.UpdateID
                RevisionNum  = [int]$u.Identity.RevisionNumber
                KB           = if ($kbList.Count -gt 0) { [string]$kbList[0] } else { '' }
                KBArticleIDs = @($kbList)
                Categories   = @($catNames)
                Type         = $typeStr
                TypeRaw      = $rawType
                MsrcSeverity = $msrc
                IsMandatory  = $isMandatory
                EulaAccepted = [bool]$u.EulaAccepted
                IsDownloaded = [bool]$u.IsDownloaded
                Bucket       = $bucket
                Identity     = [pscustomobject]@{ UpdateID = [string]$u.Identity.UpdateID }
            }
        }

        return $updates
    } -ArgumentList $script:FbWuMicrosoftUpdateServiceId

    if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
        throw "Native COM scan timed out after $TimeoutSeconds seconds."
    }

    try {
        return @(Receive-Job -Job $job -ErrorAction Stop)
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

function Write-FbWuInstallDiag {
    <#
    .SYNOPSIS
        Atomically write an INSTALL-DIAG-<timestamp>.json under the engine's
        log directory capturing the full state of one Invoke-FbWuApply run.

    .DESCRIPTION
        Called from inside Invoke-FbWuApply at every "interesting" point:
        - on rescan miss (Found < Targeted)
        - on every COM exception during Download() or Install()
        - on a per-update result with ResultCode in {-1, 0, 1} after
          synchronous Install() returned (the MINUS_ONE_BUG sentinel rail;
          MUST NEVER fire on a healthy device)

        The dump is best-effort. A failure to write it must not surface
        upstream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Stage,
        [Parameter(Mandatory)] [string]$BucketHint,
        [Parameter(Mandatory)] [object]$Payload
    )

    try {
        if (-not (Test-Path -LiteralPath $script:FbWuLogDir)) {
            New-Item -ItemType Directory -Path $script:FbWuLogDir -Force | Out-Null
        }
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
        $name = ("INSTALL-DIAG-{0}-{1}-{2}.json" -f $Stage, $BucketHint, $stamp)
        $name = $name -replace '[\\/:\*\?"<>\|]','_'
        $path = Join-Path $script:FbWuLogDir $name
        $envelope = [pscustomobject]@{
            EngineVersion = $script:FbWuEngineVersion
            Timestamp     = (Get-Date).ToString('o')
            Stage         = $Stage
            BucketHint    = $BucketHint
            Payload       = $Payload
        }
        $envelope | ConvertTo-Json -Depth 8 -Compress | Set-Content -Path $path -Encoding UTF8 -Force
    } catch {}
}

function Get-FbWuComExceptionInfo {
    <#
    .SYNOPSIS
        Project a PowerShell ErrorRecord into a serializable record for
        INSTALL-DIAG dumps. Captures HResult, message, source, type, and
        InnerException chain (up to depth 4) so the operator can read the
        real WUA error code without spelunking the source.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ErrorRecord)

    $info = [ordered]@{
        Type           = ''
        Message        = ''
        HResultDecimal = 0
        HResultHex     = '0x00000000'
        Source         = ''
        StackTrace     = ''
        InnerChain     = @()
    }
    try {
        $ex = $ErrorRecord
        if ($ex.Exception) { $ex = $ex.Exception }
        if ($ex) {
            try { $info.Type = $ex.GetType().FullName } catch {}
            try { $info.Message = [string]$ex.Message } catch {}
            try {
                $hr = [int]$ex.HResult
                $info.HResultDecimal = $hr
                $info.HResultHex = ('0x{0:X8}' -f ($hr -band 0xFFFFFFFF))
            } catch {}
            try { $info.Source = [string]$ex.Source } catch {}
            try { $info.StackTrace = [string]$ex.StackTrace } catch {}
            $inner = $null
            try { $inner = $ex.InnerException } catch {}
            $depth = 0
            while ($inner -and $depth -lt 4) {
                $rec = [ordered]@{
                    Type           = ''
                    Message        = ''
                    HResultDecimal = 0
                    HResultHex     = '0x00000000'
                }
                try { $rec.Type = $inner.GetType().FullName } catch {}
                try { $rec.Message = [string]$inner.Message } catch {}
                try {
                    $hr2 = [int]$inner.HResult
                    $rec.HResultDecimal = $hr2
                    $rec.HResultHex = ('0x{0:X8}' -f ($hr2 -band 0xFFFFFFFF))
                } catch {}
                $info.InnerChain += [pscustomobject]$rec
                try { $inner = $inner.InnerException } catch { $inner = $null }
                $depth++
            }
        }
    } catch {}
    return [pscustomobject]$info
}

function Start-FbWuProgressPoller {
    <#
    .SYNOPSIS
        Spawn a sibling powershell.exe process that polls BITS + TrustedInstaller
        / TiWorker progress and writes wu-progress.json every ~1.5s.
    .DESCRIPTION
        2026.05.13.2200-fullscope-multipass-progress.

        Why a sibling process and not a Start-Job runspace?
          - The 2026.05.13.0900-engine-sync-rewrite story documents in
            painful detail why the Start-Job runspace boundary breaks COM
            marshaling for Microsoft.Update.* objects (MTA/STA mismatch,
            COM proxy invalidation at runspace tear-down). We do NOT want
            to put any COM object near a Start-Job here.
          - Start-ThreadJob is not shipped with Windows PowerShell 5.1 in
            the FirstBase Audit Mode environment; we cannot rely on it.
          - A sibling powershell.exe child process runs under its own
            STA, has its own BITS COM proxies, and is fully isolated from
            this engine's WUA COM session. The sibling writes to a flat
            JSON file; this engine never reads back from the sibling.
          - The sibling exits when it sees the sentinel file we drop via
            Stop-FbWuProgressPoller after Download() / Install() returns.

        What does the sibling actually poll?
          - PHASE 'Downloading': enumerates BITS jobs via
            Get-BitsTransfer -AllUsers and sums BytesTransferred /
            BytesTotal across jobs. WUA uses BITS for download in audit
            mode without WSUS, so this gives real-time bytes/percent.
            Filter is best-effort (display name OR owner SYSTEM) to match
            both the WU foreground service jobs and any background CDN
            re-broker jobs.
          - PHASE 'Installing': enumerates the TrustedInstaller / TiWorker
            / msiexec processes via Get-Process and reports CPU time +
            working-set memory deltas. Cannot give real percentage, but
            at least proves the box is doing work. Also samples the
            SoftwareDistribution\DataStore.edb size delta and
            SoftwareDistribution\Download dir size delta as a secondary
            "still working" signal so the dashboard can see install
            activity even when CPU is idle (CBS waiting on disk).
          - HEARTBEAT: write every 1.5 seconds regardless. The dashboard
            polls wu-progress.json on a 1s timer; an absent / stale write
            would cause the percentage column to look frozen even though
            the install is alive.

        Output JSON shape (one record per write, atomic via .tmp + Move-Item):
          {
            "timestamp":       "<ISO 8601>",
            "phase":           "Downloading" | "Installing",
            "bucket":          "<caller-supplied bucket name>",
            "bytesDone":       <int64>,
            "bytesTotal":      <int64>,
            "percent":         <int 0..100>,
            "totalBytesDone":  <int64>,
            "totalBytesTotal": <int64>,
            "totalPercent":    <int 0..100>,
            "currentTitle":    "<bucket: phase> heartbeat",
            "currentUpdateId": "",
            "tiActive":        $true | $false,
            "tiCpuSeconds":    <double>,
            "tiWorkingSetMB":  <double>,
            "datastoreMB":     <double>,
            "downloadCacheMB": <double>,
            "pollerPid":       <int>,
            "pollIteration":   <int>
          }

        Returns the System.Diagnostics.Process for the sibling. Caller is
        responsible for calling Stop-FbWuProgressPoller (touches sentinel,
        waits for exit). Best-effort: returns $null on any setup failure.

        BITS fallback: if Get-BitsTransfer is unavailable in this PowerShell
        edition (extremely rare on Windows 10/11 audit), the sibling logs
        a one-line WARN to its own log file and falls back to TI / DataStore
        delta only. The dashboard still sees a live heartbeat.

    .PARAMETER Phase
        'Downloading' or 'Installing' - dictates which signal the sibling
        prioritizes for the percent calculation.
    .PARAMETER Bucket
        Bucket label for log / status output (e.g. 'Critical', 'Driver').
    .PARAMETER TotalCount
        Number of updates being processed in this phase. Stamped onto
        wu-progress.json so the dashboard can render "downloading 3 of 7"
        from the engine's pre-call write even when BITS hasn't started yet.
    .PARAMETER FirstTitle
        Title of the first targeted update, used as the "currentTitle"
        seed before BITS reports anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Downloading','Installing')] [string]$Phase,
        [string]$Bucket = 'unknown',
        [int]$TotalCount = 0,
        [string]$FirstTitle = '',
        [string]$FirstUpdateId = ''
    )

    # 2026.05.13.2212-splash-watcher-and-poller-telemetry Fix 2.1:
    # entry-point telemetry. Build 2200-2211 silently produced no
    # wu-progress-poller.log on the test device despite the engine
    # entering Invoke-FbWuApply. Without an entry-point log line we
    # could not distinguish "function never called" from "function
    # called but Start-Process silently failed". This block ALWAYS
    # writes one line to the poller log and (if available) one line
    # to the loop log, BEFORE any sentinel logic, so the next field
    # log conclusively distinguishes those two failure modes.
    try {
        # Best-effort log directory creation for the very first call
        # (the bigger Test-Path/New-Item block below repeats this; we
        # can't rely on it because we want the telemetry write to land
        # even if that block throws).
        if (-not (Test-Path -LiteralPath $script:FbWuLogDir)) {
            try { New-Item -ItemType Directory -Path $script:FbWuLogDir -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
        $tsLine = '[{0}] [start] Start-FbWuProgressPoller called from PID {1} for Phase={2} Bucket={3} TotalCount={4} FirstTitle="{5}" FirstUpdateId={6} EngineVersion={7}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $PID, $Phase, $Bucket, $TotalCount, $FirstTitle, $FirstUpdateId, $script:FbWuEngineVersion
        if ($script:FbWuPollerLog) {
            try { Add-Content -Path $script:FbWuPollerLog -Value $tsLine -ErrorAction SilentlyContinue } catch {}
        }
        if (Get-Command -Name Write-FbLog -ErrorAction SilentlyContinue) {
            try { Write-FbLog $tsLine 'INFO' } catch {}
        }
    } catch {
        # Last-resort emergency log: a fixed path that bypasses
        # $script: variable lookups in case strict-mode + uninitialised
        # variable triggered the outer catch. If even THIS write
        # silently fails the box has bigger problems than the poller.
        try { Add-Content -Path 'C:\Windows\Setup\FirstBase\Logs\poller-emergency.log' -Value ('[{0}] [start-emergency] Start-FbWuProgressPoller telemetry block threw: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $_.Exception.Message) -ErrorAction SilentlyContinue } catch {}
    }

    try {
        if (-not (Test-Path -LiteralPath $script:FbWuStateDir)) {
            New-Item -ItemType Directory -Path $script:FbWuStateDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        if (-not (Test-Path -LiteralPath $script:FbWuLogDir)) {
            New-Item -ItemType Directory -Path $script:FbWuLogDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}

    try {
        if (Test-Path -LiteralPath $script:FbWuPollerStopFlag) {
            Remove-Item -LiteralPath $script:FbWuPollerStopFlag -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    $progressFileLit  = $script:FbWuProgressFile
    $stopFlagLit      = $script:FbWuPollerStopFlag
    $pollerLogLit     = $script:FbWuPollerLog
    $phaseLit         = $Phase
    $bucketLit        = $Bucket
    $totalCountLit    = [int]$TotalCount
    $firstTitleLit    = $FirstTitle
    $firstUpdateIdLit = $FirstUpdateId

    $sb = {
        param(
            [string]$ProgressFile,
            [string]$StopFlag,
            [string]$PollerLog,
            [string]$PhaseArg,
            [string]$BucketArg,
            [int]$TotalCountArg,
            [string]$FirstTitleArg,
            [string]$FirstUpdateIdArg
        )

        # 2026.05.13.2212-splash-watcher-and-poller-telemetry Fix 2.4:
        # GUARANTEED first-action heartbeat. If the sibling powershell.
        # exe child process spawned at all, this line MUST appear in
        # wu-progress-poller.log. Use a plain Add-Content (no $writeLog
        # scriptblock yet, no formatter dependencies) so a syntax error
        # later in the file or a parameter-binding failure on the inner
        # scriptblocks cannot suppress this line. ALSO writes a copy
        # to the emergency log so even a corrupt PollerLog path or a
        # locked file lands the heartbeat somewhere.
        try {
            $hbLine = "[heartbeat] Poller PID $PID starting at $(Get-Date -Format o) PhaseArg=$PhaseArg BucketArg=$BucketArg TotalCountArg=$TotalCountArg"
            Add-Content -Path $PollerLog -Value $hbLine -ErrorAction SilentlyContinue
        } catch {}
        try {
            Add-Content -Path 'C:\Windows\Setup\FirstBase\Logs\poller-emergency.log' -Value ("[poller-heartbeat] PID $PID PhaseArg=$PhaseArg BucketArg=$BucketArg TS=$(Get-Date -Format o)") -ErrorAction SilentlyContinue
        } catch {}

        $ErrorActionPreference = 'Continue'
        $ProgressPreference    = 'SilentlyContinue'

        $writeLog = {
            param([string]$Level, [string]$Msg)
            try {
                $line = ('[{0}] [{1}] [poller pid={2}] {3}' -f (Get-Date -Format 'HH:mm:ss.fff'), $Level, $PID, $Msg)
                Add-Content -Path $PollerLog -Value $line -ErrorAction SilentlyContinue
            } catch {}
        }

        # 2026.05.18.2213l Bug GG: retry-with-jitter on IOException. The
        # progress poller and the loop both touch wu-progress.json on
        # overlapping cadences; before 2213l the bare WriteAllText+Move
        # path silently swallowed sharing violations via the outer
        # try{}catch{}. Now we retry up to 5 times with 50-200ms jitter
        # before giving up. Logs (best-effort) to wu-progress-poller.log
        # on final-attempt failure so the operator has evidence.
        $writeProgress = {
            param([hashtable]$Data)
            try {
                $tmp = $ProgressFile + '.tmp'
                $json = ($Data | ConvertTo-Json -Compress -Depth 4)
                $maxAttempts = 5
                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    try {
                        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
                        Move-Item -LiteralPath $tmp -Destination $ProgressFile -Force -ErrorAction Stop
                        break
                    } catch [System.IO.IOException] {
                        if ($attempt -eq $maxAttempts) {
                            try { & $writeLog 'WARN' ("writeProgress IOException on attempt {0}/{1}: {2}; giving up this tick (Bug GG)." -f $attempt, $maxAttempts, $_.Exception.Message) } catch {}
                            throw
                        }
                        Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 200)
                    }
                }
            } catch {}
        }

        & $writeLog 'INFO' ("Poller starting: Phase={0} Bucket={1} TotalCount={2} FirstTitle='{3}'" -f $PhaseArg, $BucketArg, $TotalCountArg, $FirstTitleArg)

        $bitsAvailable = $null -ne (Get-Command -Name 'Get-BitsTransfer' -ErrorAction SilentlyContinue)
        if (-not $bitsAvailable) {
            & $writeLog 'WARN' 'Get-BitsTransfer not available; BITS-based progress disabled. Falling back to TI/DataStore heartbeat only.'
        }

        $sdRoot      = Join-Path $env:SystemRoot 'SoftwareDistribution'
        $sdDataStore = Join-Path $sdRoot 'DataStore\DataStore.edb'
        $sdDownload  = Join-Path $sdRoot 'Download'

        $iter = 0
        $totalBytesDoneSeen  = [int64]0
        $totalBytesTotalSeen = [int64]0
        while (-not (Test-Path -LiteralPath $StopFlag)) {
            $iter++

            $bytesDone  = [int64]0
            $bytesTotal = [int64]0
            $bitsJobCount = 0
            if ($bitsAvailable) {
                try {
                    $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue)
                    foreach ($j in $jobs) {
                        if (-not $j) { continue }
                        $isWuLike = $false
                        try {
                            $own = [string]$j.OwnerAccount
                            if ($own -and ($own -match 'SYSTEM' -or $own -match 'NETWORK SERVICE' -or $own -match 'LOCAL SERVICE')) {
                                $isWuLike = $true
                            }
                        } catch {}
                        try {
                            $dn = [string]$j.DisplayName
                            if ($dn -and ($dn -match '(?i)WU\s*Client|Windows\s*Update|MoUpdate|Microsoft\s*Update')) {
                                $isWuLike = $true
                            }
                        } catch {}
                        if (-not $isWuLike) { continue }
                        $bitsJobCount++
                        try { $bytesDone  += [int64]$j.BytesTransferred } catch {}
                        try { $bytesTotal += [int64]$j.BytesTotal } catch {}
                    }
                } catch {
                    if ($iter -le 3) {
                        & $writeLog 'WARN' ("Get-BitsTransfer threw at iter={0}: {1}" -f $iter, $_.Exception.Message)
                    }
                }
            }

            if ($bytesDone -gt $totalBytesDoneSeen)   { $totalBytesDoneSeen  = $bytesDone }
            if ($bytesTotal -gt $totalBytesTotalSeen) { $totalBytesTotalSeen = $bytesTotal }

            $tiActive       = $false
            $tiCpuSeconds   = 0.0
            $tiWorkingSetMB = 0.0
            try {
                $tiProcs = @(Get-Process -Name 'TrustedInstaller','TiWorker','msiexec','wuauclt' -ErrorAction SilentlyContinue)
                foreach ($p in $tiProcs) {
                    if (-not $p) { continue }
                    $tiActive = $true
                    try { $tiCpuSeconds   += [double]$p.CPU } catch {}
                    try { $tiWorkingSetMB += ([double]$p.WorkingSet64 / 1MB) } catch {}
                }
            } catch {}

            $datastoreMB     = 0.0
            $downloadCacheMB = 0.0
            try {
                if (Test-Path -LiteralPath $sdDataStore) {
                    $datastoreMB = ([double](Get-Item -LiteralPath $sdDataStore -ErrorAction SilentlyContinue).Length / 1MB)
                }
            } catch {}
            try {
                if (Test-Path -LiteralPath $sdDownload) {
                    $sum = 0.0
                    Get-ChildItem -LiteralPath $sdDownload -Recurse -File -ErrorAction SilentlyContinue |
                        ForEach-Object { try { $sum += ([double]$_.Length / 1MB) } catch {} }
                    $downloadCacheMB = $sum
                }
            } catch {}

            $percent = 0
            if ($PhaseArg -eq 'Downloading' -and $bytesTotal -gt 0) {
                try { $percent = [int][math]::Floor((($bytesDone * 100.0) / $bytesTotal)) } catch {}
                if ($percent -lt 0)   { $percent = 0 }
                if ($percent -gt 100) { $percent = 100 }
            } elseif ($PhaseArg -eq 'Installing') {
                $percent = 0
            }

            $totalPercent = $percent
            if ($PhaseArg -eq 'Downloading' -and $totalBytesTotalSeen -gt 0) {
                try { $totalPercent = [int][math]::Floor((($totalBytesDoneSeen * 100.0) / $totalBytesTotalSeen)) } catch {}
                if ($totalPercent -lt 0)   { $totalPercent = 0 }
                if ($totalPercent -gt 100) { $totalPercent = 100 }
            }

            $heartbeatTitle = if ([string]::IsNullOrWhiteSpace($FirstTitleArg)) {
                ("{0}: {1}" -f $BucketArg, $PhaseArg)
            } else {
                $FirstTitleArg
            }

            $rec = @{
                timestamp       = (Get-Date).ToString('s')
                phase           = $PhaseArg
                bucket          = $BucketArg
                currentIndex    = 0
                totalCount      = $TotalCountArg
                currentTitle    = $heartbeatTitle
                currentUpdateId = $FirstUpdateIdArg
                bytesDone       = [int64]$bytesDone
                bytesTotal      = [int64]$bytesTotal
                percent         = [int]$percent
                totalBytesDone  = [int64]$totalBytesDoneSeen
                totalBytesTotal = [int64]$totalBytesTotalSeen
                totalPercent    = [int]$totalPercent
                bitsJobCount    = [int]$bitsJobCount
                tiActive        = [bool]$tiActive
                tiCpuSeconds    = [double]$tiCpuSeconds
                tiWorkingSetMB  = [double]$tiWorkingSetMB
                datastoreMB     = [double]$datastoreMB
                downloadCacheMB = [double]$downloadCacheMB
                pollerPid       = [int]$PID
                pollIteration   = [int]$iter
            }
            & $writeProgress $rec

            if ($iter -eq 1 -or ($iter % 20) -eq 0) {
                & $writeLog 'INFO' ("iter={0} bitsJobs={1} bytes={2}/{3} pct={4}% ti={5} tiCpu={6:N1}s dsMB={7:N0} dlMB={8:N0}" -f $iter, $bitsJobCount, $bytesDone, $bytesTotal, $percent, $tiActive, $tiCpuSeconds, $datastoreMB, $downloadCacheMB)
            }

            Start-Sleep -Milliseconds 1500
        }

        & $writeLog 'INFO' ("Poller stop sentinel observed at iter={0}; exiting." -f $iter)
    }

    $sbScript = $sb.ToString()
    $cmdLine = '$sb = [scriptblock]::Create(@'
    $cmdLine += "'`n"
    $cmdLine += $sbScript
    $cmdLine += "`n'@"
    $cmdLine += '); & $sb '
    $cmdLine += "-ProgressFile '"     + ($progressFileLit -replace "'","''") + "' "
    $cmdLine += "-StopFlag '"         + ($stopFlagLit     -replace "'","''") + "' "
    $cmdLine += "-PollerLog '"        + ($pollerLogLit    -replace "'","''") + "' "
    $cmdLine += "-PhaseArg '"         + ($phaseLit        -replace "'","''") + "' "
    $cmdLine += "-BucketArg '"        + ($bucketLit       -replace "'","''") + "' "
    $cmdLine += "-TotalCountArg "     + [string]$totalCountLit + ' '
    $cmdLine += "-FirstTitleArg '"    + ($firstTitleLit    -replace "'","''") + "' "
    $cmdLine += "-FirstUpdateIdArg '" + ($firstUpdateIdLit -replace "'","''") + "'"

    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

    # 2026.05.13.2212-splash-watcher-and-poller-telemetry Fix 2.3:
    # harden the Start-Process call. Build 2200-2211 used
    # -ErrorAction Stop on Start-Process which threw correctly on
    # spawn failure, but did NOT verify the sibling actually
    # survived its first instruction. The new logic captures the
    # PID, sleeps 500ms, and probes HasExited. If the sibling died
    # immediately we log ExitCode + a clear ERROR; if it's running
    # we log the PID for cross-correlation with the sibling's own
    # heartbeat line.
    try {
        $proc = Start-Process -FilePath $psExe -ArgumentList @(
            '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
            '-Command', $cmdLine
        ) -WindowStyle Hidden -PassThru -ErrorAction Stop
        try { Start-Sleep -Milliseconds 500 } catch {}
        try {
            if ($proc.HasExited) {
                $exitCode = $null
                try { $exitCode = $proc.ExitCode } catch {}
                $earlyExitLine = ('[{0}] [start-error] Poller process PID {1} exited immediately with ExitCode={2}; sibling will NOT produce a heartbeat. Phase={3} Bucket={4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $proc.Id, $exitCode, $Phase, $Bucket)
                try { Add-Content -Path $script:FbWuPollerLog -Value $earlyExitLine -ErrorAction SilentlyContinue } catch {}
                if (Get-Command -Name Write-FbLog -ErrorAction SilentlyContinue) {
                    try { Write-FbLog ("Progress poller died immediately - PID={0} ExitCode={1} Phase={2} Bucket={3}" -f $proc.Id, $exitCode, $Phase, $Bucket) 'ERROR' } catch {}
                }
            } else {
                $okLine = ('[{0}] [start-ok] Poller process PID {1} running. Phase={2} Bucket={3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $proc.Id, $Phase, $Bucket)
                try { Add-Content -Path $script:FbWuPollerLog -Value $okLine -ErrorAction SilentlyContinue } catch {}
                if (Get-Command -Name Write-FbLog -ErrorAction SilentlyContinue) {
                    try { Write-FbLog ("Progress poller running - PID={0} Phase={1} Bucket={2}" -f $proc.Id, $Phase, $Bucket) 'INFO' } catch {}
                }
                $script:FbWuPollerPid = $proc.Id
            }
        } catch {
            # HasExited probe itself threw - log but don't fail. The
            # caller still gets a valid Process object back; Stop-
            # FbWuProgressPoller will deal with whatever state it ends
            # up in.
            try { Add-Content -Path $script:FbWuPollerLog -Value ('[{0}] [start-warn] HasExited probe on PID {1} threw: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $proc.Id, $_.Exception.Message) -ErrorAction SilentlyContinue } catch {}
        }
        return $proc
    } catch {
        try {
            Add-Content -Path $script:FbWuPollerLog -Value (
                '[{0}] [start-throw] Start-FbWuProgressPoller could not spawn sibling: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $_.Exception.Message
            ) -ErrorAction SilentlyContinue
        } catch {}
        if (Get-Command -Name Write-FbLog -ErrorAction SilentlyContinue) {
            try { Write-FbLog ("Start-Process for poller THREW: {0}" -f $_.Exception.Message) 'ERROR' } catch {}
        }
        return $null
    }
}

function Stop-FbWuProgressPoller {
    <#
    .SYNOPSIS
        Touch the sentinel flag and wait for the sibling poller to exit.
    .DESCRIPTION
        2026.05.13.2200-fullscope-multipass-progress. Best-effort: guarantees
        the poller process is gone within ~5 seconds (one full poll cycle
        is 1.5s; we give it 3 cycles plus margin), then force-kills if it
        somehow refuses to exit. Never throws.
    #>
    [CmdletBinding()]
    param(
        [System.Diagnostics.Process]$Process = $null
    )

    # 2026.05.13.2212-splash-watcher-and-poller-telemetry Fix 2.1
    # mate: entry-point telemetry on the Stop side too, so a field
    # log shows the matched [start]/[stop] pair (or its absence).
    try {
        $procDesc = if ($Process) { ('PID={0} HasExited={1}' -f $Process.Id, $Process.HasExited) } else { '<null>' }
        $tsLine = '[{0}] [stop] Stop-FbWuProgressPoller called from PID {1}; child process: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $PID, $procDesc
        if ($script:FbWuPollerLog) {
            try { Add-Content -Path $script:FbWuPollerLog -Value $tsLine -ErrorAction SilentlyContinue } catch {}
        }
        if (Get-Command -Name Write-FbLog -ErrorAction SilentlyContinue) {
            try { Write-FbLog $tsLine 'INFO' } catch {}
        }
    } catch {
        try { Add-Content -Path 'C:\Windows\Setup\FirstBase\Logs\poller-emergency.log' -Value ('[{0}] [stop-emergency] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $_.Exception.Message) -ErrorAction SilentlyContinue } catch {}
    }

    try {
        if (-not (Test-Path -LiteralPath $script:FbWuStateDir)) {
            New-Item -ItemType Directory -Path $script:FbWuStateDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Set-Content -Path $script:FbWuPollerStopFlag -Value 'stop' -Encoding ASCII -Force -ErrorAction SilentlyContinue
    } catch {}

    if ($Process) {
        try {
            $waited = $Process.WaitForExit(5000)
            if (-not $waited) {
                try { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue } catch {}
            }
        } catch {
            try { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
    }

    try {
        if (Test-Path -LiteralPath $script:FbWuPollerStopFlag) {
            Remove-Item -LiteralPath $script:FbWuPollerStopFlag -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Invoke-FbWuInstallOneUpdateWithTimeout {
    <#
    .SYNOPSIS
        Run IUpdateInstaller.Install for one UpdateId with a wall-clock timeout.
    .DESCRIPTION
        Install() is a blocking COM call, so it runs on an STA runspace.
        WaitOne enforces FbWuPerUpdateInstallTimeoutSec (default 600).
        Timeout: Stop() the runspace, return ResultCode=5 / 0x80070102.
        Does not stop TrustedInstaller. Does not report percent=100.
    #>
    param(
        [Parameter(Mandatory)] [string]$UpdateId,
        [string]$Title = '',
        [int]$TimeoutSec = 600
    )
    $logTitle = $Title
    if ([string]::IsNullOrWhiteSpace($logTitle)) { $logTitle = $UpdateId }
    $timeoutMs = [Math]::Max(1000, [int]($TimeoutSec * 1000))
    $rs = $null
    $ps = $null
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::STA
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param([string]$Uid)
            $ErrorActionPreference = 'Stop'
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $searcher.Online = $false
            $sr = $searcher.Search(("UpdateID='{0}'" -f $Uid))
            if ($sr.Updates.Count -lt 1) {
                $searcher.Online = $true
                $sr = $searcher.Search(("UpdateID='{0}'" -f $Uid))
            }
            if ($sr.Updates.Count -lt 1) {
                return @{ Rc = 4; Hr = 0x80240007; Reboot = $false; Err = 'not-found' }
            }
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            [void]$coll.Add($sr.Updates.Item(0))
            $inst = $session.CreateUpdateInstaller()
            $inst.Updates = $coll
            $ir = $inst.Install()
            $rc = [int]$ir.ResultCode
            $reboot = [bool]$ir.RebootRequired
            $hr = 0
            try {
                $ur = $ir.GetUpdateResult(0)
                $rc = [int]$ur.ResultCode
                $hr = [int]$ur.HResult
            } catch {}
            return @{ Rc = $rc; Hr = $hr; Reboot = $reboot; Err = '' }
        }).AddArgument($UpdateId)
        $async = $ps.BeginInvoke()
        $finished = $async.AsyncWaitHandle.WaitOne($timeoutMs)
        if (-not $finished) {
            try { $ps.Stop() } catch {}
            try { Write-FbLog ("Per-update Install TIMED OUT after {0}s: '{1}' ({2}). Soft-skip this boot. TrustedInstaller not stopped." -f $TimeoutSec, $logTitle, $UpdateId) 'WARN' } catch {}
            if ($null -eq $script:FbInstallTimedOutThisBoot) { $script:FbInstallTimedOutThisBoot = @{} }
            $script:FbInstallTimedOutThisBoot[$UpdateId] = $true
            return [pscustomobject]@{ TimedOut = $true; ResultCode = 5; HResult = [int]0x80070102; RebootRequired = $false }
        }
        $out = $ps.EndInvoke($async)
        $map = $null
        foreach ($item in @($out)) {
            if ($item -is [hashtable]) { $map = $item; break }
            try {
                if ($item.Keys -contains 'Rc') { $map = $item; break }
            } catch {}
        }
        if ($null -eq $map) {
            return [pscustomobject]@{ TimedOut = $false; ResultCode = 4; HResult = 0; RebootRequired = $false }
        }
        return [pscustomobject]@{
            TimedOut       = $false
            ResultCode     = [int]$map.Rc
            HResult        = [int]$map.Hr
            RebootRequired = [bool]$map.Reboot
        }
    } catch {
        try { Write-FbLog ("Per-update Install helper threw for '{0}': {1}" -f $logTitle, $_.Exception.Message) 'WARN' } catch {}
        return [pscustomobject]@{ TimedOut = $false; ResultCode = 4; HResult = 0; RebootRequired = $false }
    } finally {
        try { if ($ps) { $ps.Dispose() } } catch {}
        try { if ($rs) { $rs.Dispose() } } catch {}
    }
}

function Invoke-FbWuDownloadBucketWithTimeout {
    param(
        [Parameter(Mandatory)] [string[]]$UpdateIds,
        [string]$FirstTitle = '',
        [int]$TimeoutSec = 720
    )
    $logTitle = $FirstTitle
    if ([string]::IsNullOrWhiteSpace($logTitle)) { $logTitle = 'bucket' }
    $timeoutMs = [Math]::Max(1000, [int]($TimeoutSec * 1000))
    $rs = $null
    $ps = $null
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::STA
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param([string[]]$Uids)
            $ErrorActionPreference = 'Stop'
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($uid in @($Uids)) {
                if ([string]::IsNullOrWhiteSpace($uid)) { continue }
                $searcher.Online = $false
                $sr = $searcher.Search(("UpdateID='{0}'" -f $uid))
                if ($sr.Updates.Count -lt 1) {
                    $searcher.Online = $true
                    $sr = $searcher.Search(("UpdateID='{0}'" -f $uid))
                }
                if ($sr.Updates.Count -ge 1) { [void]$coll.Add($sr.Updates.Item(0)) }
            }
            if ($coll.Count -lt 1) {
                return @{ Rc = 4; Hr = 0x80240007; Err = 'not-found' }
            }
            $dl = $session.CreateUpdateDownloader()
            $dl.Updates = $coll
            $dr = $dl.Download()
            return @{ Rc = [int]$dr.ResultCode; Hr = 0; Err = '' }
        }).AddArgument(@($UpdateIds))
        $async = $ps.BeginInvoke()
        $finished = $async.AsyncWaitHandle.WaitOne($timeoutMs)
        if (-not $finished) {
            try { $ps.Stop() } catch {}
            try { Write-FbLog ("Per-bucket Download TIMED OUT after {0}s: first='{1}' count={2}. Soft-skip undownloaded this boot; continue to Install for anything already staged. TrustedInstaller not stopped." -f $TimeoutSec, $logTitle, @($UpdateIds).Count) 'WARN' } catch {}
            return [pscustomobject]@{ TimedOut = $true; ResultCode = 5; HResult = [int]0x80070102 }
        }
        $out = $ps.EndInvoke($async)
        $map = $null
        foreach ($item in @($out)) {
            if ($item -is [hashtable]) { $map = $item; break }
            try {
                if ($item.Keys -contains 'Rc') { $map = $item; break }
            } catch {}
        }
        if ($null -eq $map) {
            return [pscustomobject]@{ TimedOut = $false; ResultCode = 4; HResult = 0 }
        }
        return [pscustomobject]@{
            TimedOut   = $false
            ResultCode = [int]$map.Rc
            HResult    = [int]$map.Hr
        }
    } catch {
        try { Write-FbLog ("Per-bucket Download helper threw for '{0}': {1}" -f $logTitle, $_.Exception.Message) 'WARN' } catch {}
        return [pscustomobject]@{ TimedOut = $false; ResultCode = 4; HResult = 0 }
    } finally {
        try { if ($ps) { $ps.Dispose() } } catch {}
        try { if ($rs) { $rs.Dispose() } } catch {}
    }
}

function Invoke-FbWuApply {
    <#
    .SYNOPSIS
        Download + install targeted updates via the native WUA COM API.

    .DESCRIPTION
        2026.05.13.0900-engine-sync-rewrite REWRITE.

        ROOT CAUSE OF THE PRIOR REGRESSION
        ----------------------------------
        Field log WU-20260512-122639.log on the test device showed every
        update in EVERY bucket returning ResultCode=-1, HResult=0x00000000
        ~28-35 seconds after the bucket apply started, with NO
        STUCK-DIAG-RESULTCODE-MINUS-ONE-*.json marker files written by the
        engine's MINUS_ONE_BUG sentinel rail. The HResult of 0x00000000
        (instead of the engine-synthesized 0x8024000B) proved that the
        engine was NEVER reaching the MINUS_ONE_BUG synthesis branch and
        was returning UpdateResults=@() (empty array). The loop's
        per-update lookup then fell through to its "no result entry"
        synthesis path:
            $code = if ($resultEntry) { [int]$resultEntry.ResultCode } else { -1 }
            $hr   = if ($resultEntry) { [int]$resultEntry.HResult }   else { 0 }
        ...which exactly matches the (-1, 0) signature observed in the field.

        The empty UpdateResults array was being produced by the prior
        engine's Start-Job runspace boundary in one of three ways:

          (a) The Start-Job runspace runs in MTA, but Microsoft.Update.
              Session is happiest in STA. A COM exception during the
              re-scan inside the job (line 394 in 1830 build) was silently
              caught, producing $foundCount=0 and the early-return at
              "if ($foundCount -eq 0) { ... UpdateResults=@() }".
          (b) The re-scan in the runspace returned a different set of
              UpdateIDs than the parent's Invoke-FbWuScan call, so
              "$ids -contains $uid" was false for every row, again
              producing $foundCount=0 and the empty-array early-return.
          (c) Even if BeginDownload/BeginInstall worked, the Start-Job
              runspace tear-down at job completion sometimes invalidated
              the COM proxies before EndInstall could read the per-update
              results, producing GetUpdateResult() throws that were
              swallowed and rendered as empty UpdateResults.

        All three paths share one root cause: the Start-Job runspace
        boundary breaks COM marshaling for Microsoft.Update.* objects.

        THE FIX
        -------
        1. NO MORE Start-Job. The entire Invoke-FbWuApply body runs
           INLINE in the caller's foreground process. The COM session,
           searcher, downloader, installer, and result objects all live
           in one apartment for the lifetime of the call. No marshaling
           boundary, no runspace tear-down race.

        2. NO MORE BeginDownload/BeginInstall + IsCompleted polling.
           We use the SYNCHRONOUS IUpdateDownloader.Download() and
           IUpdateInstaller.Install() methods. They block until the
           operation completes and return real IDownloadResult /
           IInstallationResult objects directly. There is no async
           race, no IsCompleted toggling, no EndDownload/EndInstall
           timing window.

        3. Progress reporting is best-effort. Without async
           IsCompleted polling we cannot pump per-update bytes/percent
           updates into wu-progress.json during the call. The dashboard
           still shows the bucket-level "Downloading N updates..." /
           "Installing N updates..." status because:
             a) Invoke-FbBucketApply stamps "Downloading" status on
                every row before calling us (line ~4318 in the loop).
             b) Invoke-FbBucketApply stamps "Installing" status on
                every row after Download() returns (line ~4530).
             c) The wu-progress.json sidecar gets a single "phase
                start" record before each call so the dashboard's
                top-level message reflects "Downloading bucket
                Critical (4 updates)" instead of going stale.

        4. INSTALL-DIAG capture. Every COM exception during the call
           is captured into INSTALL-DIAG-<stage>-<bucket>-<timestamp>.
           json under FB_ROOT\Logs with full HResult / message /
           source / stack / inner-exception chain. The dump also
           includes the targeted UpdateIDs, the rescan-found UpdateIDs,
           and any IDownloadResult / IInstallationResult per-update
           fields successfully read before the exception.

        5. The MINUS_ONE_BUG sentinel rail is RETAINED as a true
           safety net only. With the sync path it MUST NEVER fire
           on a healthy device because Install() does not return
           until the per-update state machine has terminated. If
           it ever fires the rail will write a
           STUCK-DIAG-RESULTCODE-MINUS-ONE-*.json AND an
           INSTALL-DIAG-*.json so the operator can correlate.

        6. Per-phase hard timeouts are GONE. The synchronous calls
           are blocking and have no native timeout knob. We rely on
           the OUTER watchdog ($TimeoutSeconds, default 7200s) plus
           the loop's existing watchdog scheduled task to recover
           from a truly hung WUA. In practice WUA's own Connection-
           Manager timeouts (~30 minutes per BITS slot) plus
           Trusted Installer's per-package CBS timeouts bound the
           call to well under our outer watchdog. The 1700/1830
           builds' 30min-download / 45min-install per-phase windows
           were never load-bearing - they were a band-aid on the
           async polling race, not a real timeout for WUA itself.

    .PARAMETER UpdateIds
        UpdateIDs (GUID strings) to apply. Filtered against the WUA
        offered list (IsInstalled=0 and IsHidden=0).
    .PARAMETER TimeoutSeconds
        OUTER timeout for the entire apply. Honored by the caller
        (Invoke-FbBucketApply wraps us in its own try/catch and the
        loop's watchdog scheduled task is the ultimate safety net).
        We do NOT enforce this timeout internally because the
        synchronous COM calls cannot be aborted from the calling
        thread; the parameter is preserved for back-compat.
    .PARAMETER DownloadTimeoutSec
        Accepted for back-compat but no longer load-bearing. With the
        sync rewrite there are no per-phase async windows to enforce.
    .PARAMETER InstallTimeoutSec
        Accepted for back-compat but no longer load-bearing. With the
        sync rewrite there are no per-phase async windows to enforce.
    .PARAMETER ProgressCallback
        Optional scriptblock; invoked once with a synthetic progress
        record at the start of each phase (Downloading / Installing)
        so the loop's per-row UI helper can stamp the bucket-level
        status. Per-update bytes/percent progress is NOT available
        during the sync calls; the loop's per-row UI updates remain
        accurate (Downloading -> Installing -> Completed/Retrying)
        because they are stamped by the caller around our call,
        not by us.

    .OUTPUTS
        PSCustomObject with the public shape:
            DownloadResultCode (int)
            InstallResultCode  (int)
            RebootRequired     (bool)
            Targeted           (int)  - UpdateIds.Count
            Found              (int)  - rows actually located in the WUA scan
            Installed          (int)  - count of per-update ResultCodes in {2,3}
            UpdateResults      (PSCustomObject[]) - per-update Title/UpdateId/
                                                    ResultCode/HResult
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$UpdateIds,
        [int]$TimeoutSeconds = 7200,
        [int]$DownloadTimeoutSec = 1800,
        [int]$InstallTimeoutSec  = 2700,
        [scriptblock]$ProgressCallback = $null
    )

    # Operation result codes (WUA OperationResultCode enum).
    $RC_NotStarted   = 0
    $RC_InProgress   = 1
    $RC_Succeeded    = 2
    $RC_SucceededWE  = 3
    $RC_Failed       = 4
    $RC_Aborted      = 5

    # Sentinel HResults used when synthesizing per-update rows.
    $HR_DownloadAborted = 0x8024000C  # WU_E_NOOP repurposed as "download phase aborted"
    $HR_MinusOneMarker  = 0x8024000B  # WU_E_CALL_CANCELLED repurposed as "MINUS_ONE_BUG marker"

    if (-not $UpdateIds -or $UpdateIds.Count -eq 0) {
        return [pscustomobject]@{
            DownloadResultCode = 0
            InstallResultCode  = 0
            RebootRequired     = $false
            Targeted           = 0
            Found              = 0
            Installed          = 0
            UpdateResults      = @()
        }
    }

    $progressFile = 'C:\Windows\Setup\FirstBase\wu-progress.json'

    # Inline helper: atomically write the wu-progress.json sidecar so the
    # dashboard's poll cannot see a partial JSON document. We write a single
    # phase-start record before each blocking call; per-update progress is
    # not available during sync Download()/Install().
    #
    # 2026.05.18.2213l Bug GG: retry-with-jitter on IOException. The loop
    # side reads wu-progress.json on a 1s timer; the engine writes it on
    # phase transitions. Without retry, a same-tick race silently dropped
    # the write (the outer try{}catch{} swallowed it). 5 attempts with
    # 50-200ms jitter covers the worst-case poller-vs-engine contention.
    $writeProgress = {
        param([hashtable]$data)
        try {
            $tmp = $progressFile + '.tmp'
            $json = ($data | ConvertTo-Json -Compress -Depth 4)
            $maxAttempts = 5
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                try {
                    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
                    Move-Item -LiteralPath $tmp -Destination $progressFile -Force -ErrorAction Stop
                    break
                } catch [System.IO.IOException] {
                    if ($attempt -eq $maxAttempts) { throw }
                    Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 200)
                }
            }
        } catch {}
    }

    # Pre-clean any stale progress file from a previous apply so the caller's
    # first poll cannot read leftover data from a prior run.
    try {
        if (Test-Path -LiteralPath $progressFile) {
            Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    # Wire the wu-progress.json + ProgressCallback fan-out into one
    # call that we can fire at every "interesting" transition point.
    # Bucket name is not visible to the engine - we use the Targeted
    # count as the only differentiator the dashboard needs.
    $emitPhaseStart = {
        param([string]$phase, [int]$idx, [int]$total, [string]$title, [string]$uid)
        try {
            $rec = @{
                timestamp       = (Get-Date).ToString('s')
                phase           = $phase
                currentIndex    = $idx
                totalCount      = $total
                currentTitle    = $title
                currentUpdateId = $uid
                bytesDone       = 0
                bytesTotal      = 0
                percent         = 0
                totalBytesDone  = 0
                totalBytesTotal = 0
                totalPercent    = 0
            }
            & $writeProgress $rec
            if ($ProgressCallback) {
                try {
                    $msg = New-Object psobject -Property $rec
                    & $ProgressCallback $msg
                } catch {}
            }
        } catch {}
    }

    # ------------------------------------------------------------------
    # Bucket hint for INSTALL-DIAG filenames. We don't know the bucket
    # name at engine level; the loop passes the title pattern in via
    # the first targeted UID's KB. For the dump filename we just use
    # "bucket" + the targeted count; the body of the dump carries the
    # full UpdateID list so the operator can match it to the bucket.
    # ------------------------------------------------------------------
    $bucketHint = ('targeted{0}' -f $UpdateIds.Count)

    # ==================================================================
    # PHASE 0: WUA session bootstrap (inline; no Start-Job)
    # ==================================================================
    $session = $null
    $searcher = $null
    try {
        $svcManager = New-Object -ComObject Microsoft.Update.ServiceManager
        try { $null = $svcManager.AddService2($script:FbWuMicrosoftUpdateServiceId, 7, '') } catch {}

        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searcher.Online = $true
        try {
            $searcher.ServerSelection = 3
            $searcher.ServiceID = $script:FbWuMicrosoftUpdateServiceId
        } catch {
            $searcher.ServerSelection = 2
        }
    } catch {
        $diag = [pscustomobject]@{
            TargetedIds = @($UpdateIds)
            Phase       = 'session-bootstrap'
            Exception   = (Get-FbWuComExceptionInfo -ErrorRecord $_)
        }
        Write-FbWuInstallDiag -Stage 'bootstrap-fail' -BucketHint $bucketHint -Payload $diag
        $perUpdate = @()
        foreach ($id in $UpdateIds) {
            $perUpdate += [pscustomobject]@{
                Title      = $id
                UpdateId   = $id
                ResultCode = $RC_Failed
                HResult    = $diag.Exception.HResultDecimal
            }
        }
        try { Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue } catch {}
        return [pscustomobject]@{
            DownloadResultCode = $RC_Failed
            InstallResultCode  = $RC_Failed
            RebootRequired     = $false
            Targeted           = $UpdateIds.Count
            Found              = 0
            Installed          = 0
            UpdateResults      = $perUpdate
        }
    }

    # ==================================================================
    # PHASE 1: Inline rescan + UpdateColl assembly
    # ==================================================================
    $target = $null
    $rescanFoundIds = @()
    $rescanTotalCount = 0
    try {
        $result = $searcher.Search("IsInstalled=0 and IsHidden=0")
        $rescanTotalCount = [int]$result.Updates.Count
        $target = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $result.Updates.Count; $i++) {
            $u = $result.Updates.Item($i)
            $uid = [string]$u.Identity.UpdateID
            $rescanFoundIds += $uid
            if ($UpdateIds -contains $uid) {
                try { if (-not $u.EulaAccepted) { $null = $u.AcceptEula() } } catch {}
                [void]$target.Add($u)
            }
        }
    } catch {
        $diag = [pscustomobject]@{
            TargetedIds      = @($UpdateIds)
            Phase            = 'rescan'
            RescanFoundIds   = @($rescanFoundIds)
            RescanTotalCount = $rescanTotalCount
            Exception        = (Get-FbWuComExceptionInfo -ErrorRecord $_)
        }
        Write-FbWuInstallDiag -Stage 'rescan-fail' -BucketHint $bucketHint -Payload $diag
        $perUpdate = @()
        foreach ($id in $UpdateIds) {
            $perUpdate += [pscustomobject]@{
                Title      = $id
                UpdateId   = $id
                ResultCode = $RC_Failed
                HResult    = $diag.Exception.HResultDecimal
            }
        }
        try { Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue } catch {}
        return [pscustomobject]@{
            DownloadResultCode = $RC_Failed
            InstallResultCode  = $RC_Failed
            RebootRequired     = $false
            Targeted           = $UpdateIds.Count
            Found              = 0
            Installed          = 0
            UpdateResults      = $perUpdate
        }
    }

    $foundCount = [int]$target.Count

    # Build a deterministic per-target snapshot so the synthesized-failure
    # paths can still emit a per-update row with the right Title / UpdateID
    # even when no real IInstallationResult is available.
    $targetSnap = @()
    for ($i = 0; $i -lt $target.Count; $i++) {
        $tu = $target.Item($i)
        $targetSnap += [pscustomobject]@{
            Title    = [string]$tu.Title
            UpdateId = [string]$tu.Identity.UpdateID
        }
    }

    # Compute missing IDs once and capture diag if the rescan dropped any
    # targeted UpdateIDs. Even when a partial install proceeds for the
    # found subset, the missing rows must still appear in UpdateResults
    # below so the loop's perResults[$uid] lookup never falls through to
    # its "no entry" synthesis path - that path is exactly what produced
    # the WU-20260512-122639.log silent-bypass (-1, 0) signature.
    $missingIds = @()
    foreach ($id in $UpdateIds) {
        if ($rescanFoundIds -notcontains $id) { $missingIds += $id }
    }
    if ($foundCount -lt $UpdateIds.Count) {
        $diag = [pscustomobject]@{
            TargetedIds       = @($UpdateIds)
            FoundIds          = @($targetSnap | ForEach-Object { $_.UpdateId })
            MissingIds        = @($missingIds)
            RescanFoundIds    = @($rescanFoundIds)
            RescanTotalCount  = $rescanTotalCount
            Phase             = 'rescan-partial-miss'
        }
        Write-FbWuInstallDiag -Stage 'rescan-miss' -BucketHint $bucketHint -Payload $diag
    }

    if ($foundCount -eq 0) {
        # Nothing to install. Emit one per-update row per targeted UID so
        # the loop's perResults lookup never falls into the "no entry"
        # synthesis path (which is what produced the original ResultCode=-1
        # / HResult=0 silent-bypass signature in the field).
        $perUpdate = @()
        foreach ($id in $UpdateIds) {
            $title = $id
            $perUpdate += [pscustomobject]@{
                Title      = $title
                UpdateId   = $id
                ResultCode = $RC_Failed
                HResult    = $HR_DownloadAborted  # WU_E_NOOP - "no work was performed"
            }
        }
        try { Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue } catch {}
        return [pscustomobject]@{
            DownloadResultCode = $RC_Failed
            InstallResultCode  = $RC_Failed
            RebootRequired     = $false
            Targeted           = $UpdateIds.Count
            Found              = 0
            Installed          = 0
            UpdateResults      = $perUpdate
        }
    }

    # ==================================================================
    # PHASE 2: SYNCHRONOUS download (inline; no async, no Start-Job)
    # ==================================================================
    $downloader = $null
    $downloadResult = $null
    $dRC = $RC_Failed
    $dException = $null
    $dExceptionInfo = $null
    $dlPoller = $null
    $downloadTimedOutContinue = $false
    try {
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $target

        if ($targetSnap.Count -gt 0) {
            & $emitPhaseStart 'Downloading' 0 $targetSnap.Count $targetSnap[0].Title $targetSnap[0].UpdateId
        }

        # 2026.05.13.2200-fullscope-multipass-progress: spin up sibling
        # powershell.exe poller that watches BITS + TI / TiWorker so the
        # dashboard sees real-time bytes/% during the synchronous
        # Download() call. The sibling writes to wu-progress.json on a
        # 1.5s cadence; the loop side merges it onto wu-status.json so
        # the WPF UI stays alive instead of frozen at 0% for the full
        # duration of this blocking call.
        $dlPollerBucket = $bucketHint
        if ([string]::IsNullOrWhiteSpace($dlPollerBucket)) { $dlPollerBucket = 'Updates' }
        $dlPollerTitle = ''
        $dlPollerUid   = ''
        if ($targetSnap.Count -gt 0) {
            $dlPollerTitle = [string]$targetSnap[0].Title
            $dlPollerUid   = [string]$targetSnap[0].UpdateId
        }
        # 2026.05.13.2212-splash-watcher-and-poller-telemetry Fix 2.2:
        # call-site telemetry. Even if Start-FbWuProgressPoller's
        # entry-point log write somehow failed, the loop transcript
        # below proves whether the call was made and how it returned.
        try { Write-FbLog ("Spawning progress poller for Phase=Downloading Bucket={0} updateCount={1}" -f $dlPollerBucket, $targetSnap.Count) 'INFO' } catch {}
        $dlTimeoutSec = 720
        try { $dlTimeoutSec = [int]$script:FbWuPerBucketDownloadTimeoutSec } catch { $dlTimeoutSec = 720 }
        try { Write-FbLog ("Per-bucket Download timeout is {0}s. A hung BITS/WUA Download() will be abandoned; Install may still apply staged packages. TrustedInstaller is not stopped." -f $dlTimeoutSec) 'INFO' } catch {}
        $dlPollerStarted = $false
        try {
            $dlPoller = Start-FbWuProgressPoller -Phase 'Downloading' -Bucket $dlPollerBucket `
                -TotalCount $targetSnap.Count -FirstTitle $dlPollerTitle -FirstUpdateId $dlPollerUid
            if ($dlPoller) {
                $dlPollerStarted = $true
                try { Write-FbLog ("Progress poller spawn returned successfully for Phase=Downloading Bucket={0} (PID={1})" -f $dlPollerBucket, $dlPoller.Id) 'INFO' } catch {}
            } else {
                try { Write-FbLog ("Progress poller spawn returned `$null for Phase=Downloading Bucket={0}; check wu-progress-poller.log for [start-throw] / [start-error]" -f $dlPollerBucket) 'WARN' } catch {}
            }
        } catch {
            $dlPoller = $null
            try { Write-FbLog ("Progress poller spawn THREW for Phase=Downloading Bucket={0}: {1}" -f $dlPollerBucket, $_.Exception.Message) 'ERROR' } catch {}
        }

        # IUpdateDownloader.Download() is SYNCHRONOUS and has no native
        # timeout. 5.4.21 wraps it with WaitOne (default 720s) so a
        # wedged BITS slot cannot pin the splash forever. On timeout we
        # proceed to Install() for packages already staged.
        $dlIds = @($targetSnap | ForEach-Object { [string]$_.UpdateId })
        $timedDl = Invoke-FbWuDownloadBucketWithTimeout -UpdateIds $dlIds -FirstTitle $dlPollerTitle -TimeoutSec $dlTimeoutSec
        if ($timedDl -and [bool]$timedDl.TimedOut) {
            $downloadTimedOutContinue = $true
            $dRC = $RC_SucceededWE
            $downloadResult = $null
        } else {
            $dRC = [int]$timedDl.ResultCode
        }
    } catch {
        $dException = $_.Exception.Message
        $dExceptionInfo = Get-FbWuComExceptionInfo -ErrorRecord $_
        $dRC = $RC_Failed
    } finally {
        try { Stop-FbWuProgressPoller -Process $dlPoller } catch {}
    }

    # If the download phase produced no usable result, capture diag and
    # return a per-update synthesized failure for every targeted row.
    if ((-not $downloadTimedOutContinue) -and ($dException -or $dRC -notin @($RC_Succeeded, $RC_SucceededWE))) {
        $diag = [pscustomobject]@{
            TargetedIds      = @($UpdateIds)
            FoundIds         = @($targetSnap | ForEach-Object { $_.UpdateId })
            DownloadResultRC = $dRC
            DownloadException = $dExceptionInfo
            Phase            = 'download'
        }
        Write-FbWuInstallDiag -Stage 'download-fail' -BucketHint $bucketHint -Payload $diag

        $perUpdate = @()
        for ($j = 0; $j -lt $targetSnap.Count; $j++) {
            $rowTitle = $targetSnap[$j].Title
            $rowUid   = $targetSnap[$j].UpdateId
            # Prefer the per-update IDownloadResult.GetUpdateResult($j)
            # HResult if Download() returned a result object - it gives
            # the actual per-update download error code (e.g. 0x80244019
            # WU_E_PT_HTTP_STATUS_NOT_FOUND for a missing CAB). Fall back
            # to the synthesized download-aborted code when no result is
            # available.
            $rowHR = $HR_DownloadAborted
            if ($downloadResult) {
                try {
                    $uDr = $downloadResult.GetUpdateResult($j)
                    $hr  = [int]$uDr.HResult
                    if ($hr -ne 0) { $rowHR = $hr }
                } catch {}
            } elseif ($dExceptionInfo -and $dExceptionInfo.HResultDecimal -ne 0) {
                $rowHR = $dExceptionInfo.HResultDecimal
            }
            $perUpdate += [pscustomobject]@{
                Title      = $rowTitle
                UpdateId   = $rowUid
                ResultCode = $RC_Failed
                HResult    = $rowHR
            }
        }
        try { Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue } catch {}
        return [pscustomobject]@{
            DownloadResultCode = $dRC
            InstallResultCode  = $RC_Failed
            RebootRequired     = $false
            Targeted           = $UpdateIds.Count
            Found              = $foundCount
            Installed          = 0
            UpdateResults      = $perUpdate
        }
    }

    # ==================================================================
    # PHASE 3: SYNCHRONOUS install (PER-UPDATE, serialized)
    # ==================================================================
    # 2026.05.13.2213h-real-convergence-and-ti-serialization Bug M:
    # The pre-2213h engine called IUpdateInstaller.Install() ONCE with
    # the full UpdateColl (all targeted rows as one batch). Field
    # evidence from F:\fb-dump-final-1347 proved this collides with
    # Trusted Installer's single-instance lock:
    #   INSTALL-DIAG-apply-partial-targeted36-20260515-115356-345.json
    #     -> 36 driver updates batched, 35 returned ResultCode=4 +
    #        HResult=0x80240016 (WU_E_INSTALL_NOT_ALLOWED = "another
    #        install in progress"), only INDEX 17 actually succeeded.
    #   INSTALL-DIAG-apply-partial-targeted2-20260515-115036-267.json
    #     -> 2 Critical updates batched, BOTH returned 0x80240016 on
    #        first attempt. The 2-Critical retry at 11:50:58 succeeded
    #        for both - proving the failure mode is purely temporal
    #        collision, not a real install error.
    # The COM API path is: IUpdateInstaller.Install() submits every
    # targeted update to Trusted Installer in rapid succession. TI
    # holds a single-instance global lock per Microsoft.Update.Installer
    # COM object; the first row in the batch acquires it, the rest get
    # 0x80240016 returned almost immediately, then the FIRST row
    # finishes its CBS workflow and Install() returns - leaving 35
    # rows reported as "failed" that NEVER actually had their installer
    # run. The 36-driver batch + the 2-Critical batch + the WU log
    # serializing the bucket-end "34/36 retrying" message before the
    # WorkQueue is silently dropped are the same root cause.
    #
    # The 2213h fix: SERIALIZE THE INSTALL. Each row is submitted as
    # its own IUpdateInstaller.Install() call with a fresh single-row
    # UpdateColl. The download remains batched (Phase 2) because BITS
    # has no analogous single-instance constraint. Per-update retry
    # is added (3 attempts: 2s, 8s, 30s backoff) so a transient TI
    # mid-finalize race from a prior package doesn't surface as a
    # spurious 0x80240016 failure. The cumulative wall-clock cost is
    # accepted explicitly by the user (per task spec: "OK with the
    # slowest option if it has the highest success rate").
    #
    # Result projection is per-row directly (one row, one
    # IInstallationResult). The pre-2213h GetUpdateResult($j) loop is
    # replaced by appending each per-call result; the resulting
    # $perUpdate array shape and semantics are unchanged so callers
    # (Invoke-FbBucketApply, Update-FbWuWorkQueueFromBucketResults)
    # see the same contract.

    $perUpdate = @()
    $minusOneRows = @()
    $rawResultsForDiag = @()
    $installedCount = 0
    # Aggregate signals returned to the caller as DownloadResultCode /
    # InstallResultCode / RebootRequired. We aggregate across all
    # per-row Install() calls: $iRC reports orcSucceeded only if EVERY
    # row's RC is in {2,3}; if any row failed it reports orcFailed.
    $iRC = $RC_NotStarted
    $iRebootR = $false
    $iException = $null
    $iExceptionInfo = $null
    $perRowSucceededAll = $true
    $perRowAnyReal = $false

    # WU_E_INSTALL_NOT_ALLOWED ("another install is in progress").
    # 0x80240016 (decimal -2145124330). This is the SPECIFIC error we
    # retry with backoff because it's the documented signal that TI is
    # busy with another install at the moment of submission.
    $HR_InstallNotAllowed = -2145124330  # 0x80240016
    $maxAttempts = 3
    # Backoff seconds between attempts. Total worst-case wait per row
    # is 2+8+30 = 40s, which is bounded and survivable even for 36
    # drivers (36*40 = 24min worst case, all retries failing).
    $attemptBackoffSec = @(0, 2, 8, 30)

    $instPollerBucket = $bucketHint
    if ([string]::IsNullOrWhiteSpace($instPollerBucket)) { $instPollerBucket = 'Updates' }

    # 2026.05.13.2213h: install-phase poller spawned ONCE for the whole
    # serialized walk (not once per row). It heartbeats from
    # TrustedInstaller/TiWorker CPU + working set so the dashboard
    # stays alive across the (potentially long) per-row sequence.
    $instPoller = $null
    $instPollerTitle = if ($targetSnap.Count -gt 0) { [string]$targetSnap[0].Title } else { '' }
    $instPollerUid   = if ($targetSnap.Count -gt 0) { [string]$targetSnap[0].UpdateId } else { '' }
    try { Write-FbLog ("Spawning progress poller for Phase=Installing Bucket={0} updateCount={1} (serialized per-update)" -f $instPollerBucket, $targetSnap.Count) 'INFO' } catch {}
    $perUpdateTimeoutSec = 600
    try { $perUpdateTimeoutSec = [int]$script:FbWuPerUpdateInstallTimeoutSec } catch { $perUpdateTimeoutSec = 600 }
    try { Write-FbLog ("Per-update Install timeout is {0}s. A hung OEM driver will be soft-skipped this boot; TrustedInstaller is not stopped." -f $perUpdateTimeoutSec) 'INFO' } catch {}
    try {
        $instPoller = Start-FbWuProgressPoller -Phase 'Installing' -Bucket $instPollerBucket `
            -TotalCount $targetSnap.Count -FirstTitle $instPollerTitle -FirstUpdateId $instPollerUid
        if ($instPoller) {
            try { Write-FbLog ("Progress poller spawn returned successfully for Phase=Installing Bucket={0} (PID={1})" -f $instPollerBucket, $instPoller.Id) 'INFO' } catch {}
        } else {
            try { Write-FbLog ("Progress poller spawn returned `$null for Phase=Installing Bucket={0}; check wu-progress-poller.log for [start-throw] / [start-error]" -f $instPollerBucket) 'WARN' } catch {}
        }
    } catch {
        $instPoller = $null
        try { Write-FbLog ("Progress poller spawn THREW for Phase=Installing Bucket={0}: {1}" -f $instPollerBucket, $_.Exception.Message) 'ERROR' } catch {}
    }

    try {
        for ($j = 0; $j -lt $target.Count; $j++) {
            $rowTitle = $targetSnap[$j].Title
            $rowUid   = $targetSnap[$j].UpdateId
            $rowRC    = $RC_Failed
            $rowHR    = 0
            $rowReboot = $false
            $rowExn   = $null
            $rowExnInfo = $null
            $rowAttemptsLogged = @()
            $rowTimedOut = $false

            $rowAlreadyLedgered = $false
            try {
                if ($null -ne $script:FbSuccessLedgerSet -and $script:FbSuccessLedgerSet.Contains($rowUid)) {
                    $rowAlreadyLedgered = $true
                }
            } catch {}
            if ($rowAlreadyLedgered) {
                try { Write-FbLog ("[engine-serialize] '{0}' already in success ledger; skip install this boot." -f $rowTitle) 'INFO' } catch {}
                $perUpdate += [pscustomobject]@{
                    Title      = $rowTitle
                    UpdateId   = $rowUid
                    ResultCode = $RC_Succeeded
                    HResult    = 0
                }
                $installedCount++
                $perRowAnyReal = $true
                continue
            }

            if ($script:FbInstallTimedOutThisBoot -and $script:FbInstallTimedOutThisBoot.ContainsKey($rowUid)) {
                try { Write-FbLog ("[engine-serialize] '{0}' already timed out this boot; skipping." -f $rowTitle) 'WARN' } catch {}
                $perUpdate += [pscustomobject]@{
                    Title      = $rowTitle
                    UpdateId   = $rowUid
                    ResultCode = $RC_Aborted
                    HResult    = [int]0x80070102
                }
                $perRowSucceededAll = $false
                continue
            }

            # Stamp a phase-start record so the dashboard knows which
            # row of N we are working on. The sibling poller continues
            # heartbeating from TI's CPU/WS but the wu-progress.json
            # currentTitle/currentUpdateId now reflect THIS row.
            & $emitPhaseStart 'Installing' $j $targetSnap.Count $rowTitle $rowUid

            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                if ($attempt -gt 1) {
                    $sleepSec = $attemptBackoffSec[$attempt - 1]
                    try { Write-FbLog ("[engine-serialize] '{0}' attempt {1}/{2}: backing off {3}s before retry (last HResult=0x{4:X8})" -f $rowTitle, $attempt, $maxAttempts, $sleepSec, ($rowHR -band 0xFFFFFFFF)) 'INFO' } catch {}
                    Start-Sleep -Seconds $sleepSec
                }

                # Build a single-row UpdateColl for this attempt.
                $singleColl = $null
                $singleInstaller = $null
                $singleResult = $null
                try {
                    $timed = Invoke-FbWuInstallOneUpdateWithTimeout -UpdateId $rowUid -Title $rowTitle -TimeoutSec $perUpdateTimeoutSec
                    if ($timed -and [bool]$timed.TimedOut) {
                        $rowTimedOut = $true
                        $rowRC = $RC_Aborted
                        $rowHR = [int]$timed.HResult
                        $rowReboot = [bool]$timed.RebootRequired
                    } else {
                        $rowRC = [int]$timed.ResultCode
                        $rowReboot = [bool]$timed.RebootRequired
                        $rowHR = [int]$timed.HResult
                    }
                } catch {
                    $rowExn = $_.Exception.Message
                    $rowExnInfo = Get-FbWuComExceptionInfo -ErrorRecord $_
                    $rowRC = $RC_Failed
                    if ($rowExnInfo -and $rowExnInfo.HResultDecimal -ne 0) {
                        $rowHR = [int]$rowExnInfo.HResultDecimal
                    }
                }

                $rowAttemptsLogged += [pscustomobject]@{
                    Attempt    = $attempt
                    ResultCode = $rowRC
                    HResult    = $rowHR
                    HResultHex = ('0x{0:X8}' -f ($rowHR -band 0xFFFFFFFF))
                    Exception  = if ($rowExnInfo) { $rowExnInfo.Message } else { $null }
                }

                # Decide whether to retry. We retry ONLY on the
                # specific WU_E_INSTALL_NOT_ALLOWED HResult and ONLY
                # when more attempts remain. Anything else (success or
                # a different failure) terminates the row.
                if ($rowRC -eq $RC_Succeeded -or $rowRC -eq $RC_SucceededWE) {
                    break  # success: stop retrying
                }
                if ($rowHR -ne $HR_InstallNotAllowed) {
                    break  # different failure: TI lock retry won't help
                }
                if ($attempt -ge $maxAttempts) {
                    try { Write-FbLog ("[engine-serialize] '{0}' EXHAUSTED {1} attempts on HResult=0x80240016; surfacing as orcFailed" -f $rowTitle, $maxAttempts) 'WARN' } catch {}
                    break
                }
                try { Write-FbLog ("[engine-serialize] '{0}' attempt {1}/{2} got HResult=0x80240016 (TI lock contention); will retry after backoff" -f $rowTitle, $attempt, $maxAttempts) 'WARN' } catch {}
            }

            # Aggregate signals.
            if ($rowReboot) { $iRebootR = $true }
            if ($rowExn -and -not $iException) {
                $iException = $rowExn
                $iExceptionInfo = $rowExnInfo
            }

            # Project this row's terminal state into the result array.
            if ($rowRC -eq $RC_Succeeded -or $rowRC -eq $RC_SucceededWE) {
                $perUpdate += [pscustomobject]@{
                    Title      = $rowTitle
                    UpdateId   = $rowUid
                    ResultCode = $rowRC
                    HResult    = $rowHR
                }
                $installedCount++
                $perRowAnyReal = $true
            } elseif ($rowRC -eq $RC_NotStarted -or $rowRC -eq $RC_InProgress -or $rowRC -eq -1) {
                # MINUS_ONE safety net retained from pre-2213h engine.
                # With per-row sync Install() this should be even MORE
                # unreachable than before; if we hit it, mark loud.
                $perUpdate += [pscustomobject]@{
                    Title      = $rowTitle
                    UpdateId   = $rowUid
                    ResultCode = $RC_Failed
                    HResult    = $HR_MinusOneMarker
                }
                $minusOneRows += [pscustomobject]@{
                    Title         = $rowTitle
                    UpdateId      = $rowUid
                    RawResultCode = $rowRC
                    RawHResult    = $rowHR
                }
                $perRowSucceededAll = $false
            } else {
                # Real orcFailed/orcAborted. Surface the real HResult so
                # the loop's BenignHResultMap and per-key retry budget
                # classify correctly.
                $perUpdate += [pscustomobject]@{
                    Title      = $rowTitle
                    UpdateId   = $rowUid
                    ResultCode = $rowRC
                    HResult    = $rowHR
                }
                $perRowSucceededAll = $false
                $perRowAnyReal = $true
            }

            $rawResultsForDiag += [pscustomobject]@{
                Index       = $j
                UpdateId    = $rowUid
                ResultCode  = $rowRC
                HResult     = $rowHR
                HResultHex  = ('0x{0:X8}' -f ($rowHR -band 0xFFFFFFFF))
                Attempts    = $rowAttemptsLogged
                Reboot      = $rowReboot
            }

            if ($rowTimedOut) {
                $osPendingAfterTimeout = $false
                try { $osPendingAfterTimeout = [bool](Test-FbWuRebootRequired) } catch { $osPendingAfterTimeout = [bool]$rowReboot }
                $timeoutAlreadyDone = $false
                try {
                    if ($null -ne $script:FbSuccessLedgerSet -and $script:FbSuccessLedgerSet.Contains($rowUid)) { $timeoutAlreadyDone = $true }
                } catch {}
                if ($timeoutAlreadyDone) {
                    try { Write-FbLog ("[engine-serialize] '{0}' timed out but is already in the success ledger; continue, do not reboot the bucket." -f $rowTitle) 'WARN' } catch {}
                } elseif ($osPendingAfterTimeout) {
                    try { Write-FbLog ("[engine-serialize] '{0}' timed out and OS pending reboot is true; stopping remaining serialized installs this boot." -f $rowTitle) 'WARN' } catch {}
                    $iRebootR = $true
                    break
                }
            }
        }
    } finally {
        try { Stop-FbWuProgressPoller -Process $instPoller } catch {}
    }

    # Aggregate installer ResultCode: orcSucceeded only when every row
    # finished orcSucceeded(2) or orcSucceededWithErrors(3). Anything
    # else degrades to orcFailed for the bucket-level signal. The
    # per-row results array is the source of truth either way.
    if ($targetSnap.Count -eq 0) {
        $iRC = $RC_Failed
    } elseif ($perRowSucceededAll -and $installedCount -eq $targetSnap.Count) {
        $iRC = $RC_Succeeded
    } else {
        $iRC = $RC_Failed
    }

    # Remove the sidecar so the caller's last poll after we return does
    # not show stale data on the next bucket.
    try { Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue } catch {}

    # ==================================================================
    # PHASE 4: (moved above; per-update results are built inline)
    # ==================================================================
    # In the pre-2213h engine PHASE 4 walked the single
    # IInstallationResult's per-index slots via GetUpdateResult($j) to
    # build $perUpdate. In 2213h the per-update results are built
    # inside PHASE 3 (each row owns its own IInstallationResult), so
    # this section is intentionally empty - $perUpdate is already
    # populated above. We DO NOT add a synthesized
    # IInstallationResult-shaped object for back-compat because no
    # caller reads it (the loop reads only $applyResult.UpdateResults).
    $installationResult = $null  # kept for back-compat shape only

    # Synthesize a row for every targeted UpdateID the rescan failed to
    # find. Without this, the loop's perResults[$uid] lookup falls into
    # the "no entry" synthesis path (code=-1, hr=0) for every missing
    # UID - which is exactly the WU-20260512-122639.log signature that
    # this rewrite is designed to eliminate. We use HResult=0x8024000C
    # (WU_E_NOOP) so the loop's downstream classifier treats it as an
    # unknown HResult that bumps the retry counter; after $MaxUpdateRetry
    # iterations the row is given up via the existing retry-ceiling path.
    if ($missingIds.Count -gt 0) {
        foreach ($missId in $missingIds) {
            $perUpdate += [pscustomobject]@{
                Title      = $missId
                UpdateId   = $missId
                ResultCode = $RC_Failed
                HResult    = $HR_DownloadAborted  # WU_E_NOOP (0x8024000C)
            }
        }
    }

    # ==================================================================
    # PHASE 5: Diagnostic dumps
    # ==================================================================
    # Always write the "first install attempt diagnostic" required by
    # the spec: full call trace, exception info, raw per-update results.
    # This file is the operator's primary debugging surface for any
    # failed bucket and lets us correlate field reports against a single
    # source-of-truth artifact.
    try {
        $diag = [pscustomobject]@{
            TargetedIds        = @($UpdateIds)
            FoundIds           = @($targetSnap | ForEach-Object { $_.UpdateId })
            FoundCount         = $foundCount
            DownloadResultRC   = $dRC
            DownloadException  = $dExceptionInfo
            InstallResultRC    = $iRC
            InstallRebootR     = $iRebootR
            InstallException   = $iExceptionInfo
            RawPerUpdate       = $rawResultsForDiag
            ProjectedPerUpdate = $perUpdate
            InstalledCount     = $installedCount
            MinusOneRows       = $minusOneRows
        }
        $diagStage = if ($installedCount -eq $foundCount -and $minusOneRows.Count -eq 0) {
            'apply-ok'
        } elseif ($minusOneRows.Count -gt 0) {
            'apply-minus-one'
        } elseif ($iException) {
            'apply-install-exn'
        } else {
            'apply-partial'
        }
        Write-FbWuInstallDiag -Stage $diagStage -BucketHint $bucketHint -Payload $diag
    } catch {}

    # The legacy STUCK-DIAG marker is still written if the safety net
    # tripped, so the loop's existing PanicDump scan continues to work.
    if ($minusOneRows.Count -gt 0) {
        try {
            if (-not (Test-Path -LiteralPath $script:FbWuLogDir)) {
                New-Item -ItemType Directory -Path $script:FbWuLogDir -Force | Out-Null
            }
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $bugFile = Join-Path $script:FbWuLogDir ("STUCK-DIAG-RESULTCODE-MINUS-ONE-{0}.json" -f $stamp)
            $bugPayload = [pscustomobject]@{
                EngineVersion      = $script:FbWuEngineVersion
                Timestamp          = (Get-Date).ToString('o')
                InstallResultCode  = $iRC
                InstallRebootR     = $iRebootR
                InstallException   = $iExceptionInfo
                Targeted           = $UpdateIds.Count
                Found              = $foundCount
                Rows               = $minusOneRows
            }
            $bugPayload | ConvertTo-Json -Depth 6 | Set-Content -Path $bugFile -Encoding UTF8 -Force
        } catch {}
    }

    return [pscustomobject]@{
        DownloadResultCode = $dRC
        InstallResultCode  = $iRC
        RebootRequired     = $iRebootR
        Targeted           = $UpdateIds.Count
        Found              = $foundCount
        Installed          = $installedCount
        UpdateResults      = $perUpdate
    }
}

function Test-FbWuRebootRequired {
    <#
    .SYNOPSIS
        Return $true when the OS reports a reboot is owed.
    .DESCRIPTION
        Probes the canonical Microsoft-documented signals:

          1. COM Microsoft.Update.SystemInfo.RebootRequired
          2. HKLM\...\Component Based Servicing\RebootPending - registry KEY
          3. HKLM\...\WindowsUpdate\Auto Update\RebootRequired - registry KEY
          4. HKLM\...\Session Manager\PendingFileRenameOperations - registry
             VALUE on the Session Manager KEY (multi-string, non-empty)

        2026.05.12.1100-latch-on-pending: probe #4 was previously written
        as Test-Path on the value path, which always returns $false on the
        HKLM provider (Test-Path only resolves KEYS, not values). On
        devices where the only reboot signal is PFRO (very common for
        servicing-stack-deferred file replacements), the old probe
        silently missed the signal and Invoke-FbReboot routed to the
        pre-install reboot branch even though installs had clearly run.
        The new probe uses Get-ItemProperty against the Session Manager
        key and treats a non-empty multi-string PFRO value as a true
        blocker, matching the convention used by Get-FbPendingRestart-
        Blockers in the loop script.
    #>
    [CmdletBinding()]
    param()

    try {
        $sysInfo = New-Object -ComObject Microsoft.Update.SystemInfo
        if ($sysInfo.RebootRequired) { return $true }
    } catch {}

    $keyPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($p in $keyPaths) {
        try { if (Test-Path $p) { return $true } } catch {}
    }

    # Session Manager\PendingFileRenameOperations is a VALUE on a KEY,
    # not a key. Test-Path on the value path always returns $false on
    # the registry provider. Probe the value directly and treat a
    # non-empty multi-string as a reboot blocker (same rule as
    # Get-FbPendingRestartBlockers in Invoke-WindowsUpdateLoop.ps1).
    try {
        $smKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        if (Test-Path $smKey) {
            $pfro = (Get-ItemProperty -Path $smKey -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
            if ($pfro -and (@($pfro) | Where-Object { $_ }).Count -gt 0) {
                return $true
            }
        }
    } catch {}

    return $false
}
