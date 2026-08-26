#Requires -Version 5.1
<#
.SYNOPSIS
  DISM /Apply-Image with same-line progress estimated from apply-drive disk usage
  (log-tail /LogPath polling is kept as a harmless secondary signal).

.NOTES
  WinPE-safe. DISM is launched via cmd.exe with stdout/stderr redirected to nul so
  it cannot scroll or overwrite the themed progress line. Progress is estimated from
  apply-drive disk usage (primary) plus /LogPath tail parsing (secondary). Same-line
  updates use SetCursorPosition on a pinned row; colors match Invoke-FbDeployUi
  (cyan active / dark gray idle / green complete). Progress ticks must not
  change console font, code page, buffer size, or Clear-Host.

  Without /Progress, DISM's /LogPath file carries ONLY Info-level lifecycle lines
  and rarely a percentage - live percent comes from disk usage. /Progress is
  intentionally omitted (pipe + Peek hang class fixed in 5.0.22). BeginOutputReadLine
  / OutputDataReceived is also avoided (threw in WinPE PS 5.1 in 5.0.15/5.0.16).
#>
param(
    [Parameter(Mandatory)] [string]$ImageFile,
    [Parameter()] [string]$SwmFilePattern,
    [Parameter(Mandatory)] [int]$Index,
    [Parameter(Mandatory)] [string]$ApplyDir,
    [Parameter()] [string]$LogPath,
    [Parameter()] [string]$WrapperLog
)

$ErrorActionPreference = 'Stop'
$FB_DismApplyRev = '2026-08-24.3'

# Encoding once at process start. Do NOT set console font, restore geometry,
# chcp, or Clear-Host on progress ticks (that resized the window every percent).
# Font is set once by Invoke-FbDeployUi before apply starts.
function Initialize-FbPeEncoding {
    if ($script:FbPeEncodingReady) { return }
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
    try { $script:OutputEncoding = [Console]::OutputEncoding } catch {}
    try { $OutputEncoding = [Console]::OutputEncoding } catch {}
    try { cmd.exe /c 'chcp 65001>nul' | Out-Null } catch {}
    $script:FbPeEncodingReady = $true
}
try { Initialize-FbPeEncoding } catch {}

function Write-WLog {
    param([string]$Msg)
    if (-not [string]::IsNullOrWhiteSpace($WrapperLog)) {
        try {
            $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Add-Content -LiteralPath $WrapperLog -Value ("[$ts] $Msg") -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {}
    }
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogPath = Join-Path $env:TEMP ("FirstBase-DISM-{0}.log" -f $stamp)
}
try {
    $logDir = Split-Path -Parent $LogPath
    if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
} catch {
    Write-Warning ("Could not create log directory for DISM log '{0}': {1}" -f $LogPath, $_.Exception.Message)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogPath = Join-Path $env:TEMP ("FirstBase-DISM-{0}.log" -f $stamp)
}

$dism = Join-Path $env:SystemRoot 'System32\dism.exe'
if (-not (Test-Path -LiteralPath $dism)) {
    $dism = 'dism.exe'
}

function Format-Duration([TimeSpan]$Ts) {
    $t = [long][math]::Floor($Ts.TotalSeconds)
    $h = [int][math]::Floor($t / 3600)
    $m = [int][math]::Floor(($t % 3600) / 60)
    $sec = [int]($t % 60)
    if ($h -gt 0) { return ('{0}:{1:D2}:{2:D2}' -f $h, $m, $sec) }
    return ('{0:D2}:{1:D2}' -f $m, $sec)
}

function Get-PercentBar {
    param([int]$Pct, [int]$Width = 28)
    $p = [math]::Max(0, [math]::Min(100, $Pct))
    $filled = [int][math]::Floor($Width * $p / 100.0)
    $empty  = $Width - $filled
    # Block glyphs via code points (ASCII-safe source; matches 5.4.8 DeployUi).
    $fullCh = [string][char]0x2588
    $emptyCh = [string][char]0x2591
    return [pscustomobject]@{
        Filled = ($fullCh * $filled)
        Empty  = ($emptyCh * $empty)
        Width  = $Width
        Pct    = $p
    }
}

function Read-LogTail {
    param([string]$Path, [int]$Tail = 40)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $fs = [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $sr   = [System.IO.StreamReader]::new($fs)
        $all  = $sr.ReadToEnd() -split "`r?`n"
        $sr.Dispose()
        $fs.Dispose()
        return $all | Select-Object -Last $Tail
    } catch {
        return @()
    }
}

function Update-PercentFromLine {
    param(
        [string]$Line,
        [regex]$PctRx,
        [ref]$LastPct
    )
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $m = $PctRx.Match($Line)
    if ($m.Success) {
        $v = [int][double]$m.Groups[1].Value
        if ($v -gt $LastPct.Value) { $LastPct.Value = $v }
    }
}

function Get-WimUncompressedBytes {
    # Returns the image's UNCOMPRESSED (applied-to-disk) size in bytes - the denominator
    # for the disk-usage-growth progress estimate. Must work for a SPLIT SWM set
    # (install.swm + install2.swm + ...), which is why the old single dism call failed:
    # it appended /SWMFile to /Get-ImageInfo, but /SWMFile is only valid for /Apply-Image
    # (and a few export verbs) - /Get-ImageInfo rejects it, so DISM printed an error and
    # NO "Size" line, leaving the denominator at 0 and the UI stuck on "(size unknown)".
    #
    # Three sources, most reliable first:
    #   1. Get-WindowsImage -ImagePath <first .swm> -Index N  ->  .ImageSize
    #      (DISM PS module auto-resolves the sibling .swm parts; may be absent in WinPE).
    #   2. dism /Get-ImageInfo /ImageFile:<first .swm> /Index:N  (NO /SWMFile). The
    #      part-1 XML carries the full uncompressed "Size : N bytes" for the image.
    #   3. Fallback: sum the on-disk bytes of every SWM part (or the single WIM/ESD).
    #      Compressed, so it under-counts the expanded size and the bar reaches ~99% a
    #      little early - but the operator still sees continuous same-line movement
    #      instead of a frozen "size unknown" spinner.
    param(
        [string]$Dism,
        [string]$ImageFile,
        [int]$Index,
        [string]$SwmPattern
    )

    # 1. Get-WindowsImage (DISM PowerShell module). Reports ImageSize for the whole SWM set.
    try {
        if (Get-Command Get-WindowsImage -ErrorAction SilentlyContinue) {
            $wi = Get-WindowsImage -ImagePath $ImageFile -Index $Index -ErrorAction Stop
            if ($wi -and [long]$wi.ImageSize -gt 0) {
                Write-WLog ("Size source: Get-WindowsImage.ImageSize = {0} bytes" -f [long]$wi.ImageSize)
                return [long]$wi.ImageSize
            }
        }
    } catch {
        Write-WLog ("Get-WindowsImage size lookup failed: {0}" -f $_.Exception.Message)
    }

    # 2. dism /Get-ImageInfo WITHOUT /SWMFile (short-lived, bounded output - no deadlock risk).
    try {
        $out = & $Dism '/Get-ImageInfo' "/ImageFile:$ImageFile" "/Index:$Index" '/English' 2>&1
        foreach ($ln in $out) {
            if ($ln -match 'Size\s*:\s*([\d,]+)\s*bytes') {
                $n = [long](($matches[1]) -replace ',', '')
                if ($n -gt 0) {
                    Write-WLog ("Size source: dism /Get-ImageInfo = {0} bytes" -f $n)
                    return $n
                }
            }
        }
    } catch {
        Write-WLog ("dism /Get-ImageInfo size lookup failed: {0}" -f $_.Exception.Message)
    }

    # 3. Sum on-disk sizes of the split parts (or the single image file).
    try {
        $parts = $null
        if (-not [string]::IsNullOrWhiteSpace($SwmPattern)) {
            $dir  = Split-Path -Parent $SwmPattern
            $leaf = Split-Path -Leaf   $SwmPattern
            if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Split-Path -Parent $ImageFile }
            $parts = Get-ChildItem -LiteralPath $dir -Filter $leaf -ErrorAction SilentlyContinue
        }
        if (-not $parts) {
            $parts = Get-Item -LiteralPath $ImageFile -ErrorAction SilentlyContinue
        }
        if ($parts) {
            $sum = [long](($parts | Measure-Object -Property Length -Sum).Sum)
            if ($sum -gt 0) {
                Write-WLog ("Size source: on-disk SWM/file byte sum = {0} bytes (compressed - progress reaches ~99% early)" -f $sum)
                return $sum
            }
        }
    } catch {
        Write-WLog ("On-disk byte-sum size lookup failed: {0}" -f $_.Exception.Message)
    }

    Write-WLog 'Size source: NONE - all three lookups returned 0; progress will show elapsed/spinner only.'
    return 0
}

function Get-DriveFreeBytes {
    param([string]$DriveLetter)
    try {
        return ([System.IO.DriveInfo]::new($DriveLetter)).AvailableFreeSpace
    } catch {
        return -1
    }
}

function Get-DiskUsagePct {
    # Cheap per-second progress signal: how much free space has disappeared from the
    # apply drive since the apply started, relative to the WIM's uncompressed size.
    # [System.IO.DriveInfo] is a single O(1) filesystem-metadata syscall (no directory
    # recursion), so polling it every second adds negligible overhead and needs no
    # process I/O redirection at all.
    param(
        [string]$DriveLetter,
        [long]$InitialFreeBytes,
        [long]$TotalBytes
    )
    if ($TotalBytes -le 0 -or $InitialFreeBytes -lt 0) { return -1 }
    $curFree = Get-DriveFreeBytes -DriveLetter $DriveLetter
    if ($curFree -lt 0) { return -1 }
    $used = $InitialFreeBytes - $curFree
    if ($used -lt 0) { $used = 0 }
    $pct = [int](($used / $TotalBytes) * 100)
    if ($pct -gt 99) { $pct = 99 }
    if ($pct -lt 0)  { $pct = 0 }
    return $pct
}

$argLine = [System.Collections.Generic.List[string]]::new()
$argLine.Add('/Apply-Image')
$argLine.Add("/ImageFile:`"$ImageFile`"")
if (-not [string]::IsNullOrWhiteSpace($SwmFilePattern)) {
    $argLine.Add("/SWMFile:`"$SwmFilePattern`"")
}
$argLine.Add("/Index:$Index")
$argLine.Add("/ApplyDir:$ApplyDir")
$argLine.Add("/LogPath:`"$LogPath`"")
# NOTE: /Progress intentionally omitted. Its continuous stdout chatter is what filled the
# redirected pipe buffer and triggered the StreamReader.Peek() hang fixed in 5.0.22 (see
# CHANGELOG). Progress is instead estimated from apply-drive disk usage below, with
# log-tail parsing kept only as a harmless secondary signal.

Write-WLog ("DismApply rev={0}" -f $FB_DismApplyRev)
Write-WLog ("ImageFile={0}  Index={1}  ApplyDir={2}" -f $ImageFile, $Index, $ApplyDir)
Write-WLog ("DISM log: {0}" -f $LogPath)
Write-WLog ("DISM cmd: {0} {1}" -f $dism, ($argLine -join ' '))

# Pre-scan the WIM's uncompressed size and the apply drive's starting free space so
# the loop below can turn disk-usage growth into a live percentage. Either can come
# back empty/unavailable (e.g. Get-ImageInfo fails, or DriveInfo throws) - the display
# degrades gracefully to a bar without percent in that case (see Get-DiskUsagePct).
$applyDriveLetter = $ApplyDir.Substring(0, 1) + ':'
$totalApplyBytes  = Get-WimUncompressedBytes -Dism $dism -ImageFile $ImageFile -Index $Index -SwmPattern $SwmFilePattern
$initialFreeBytes = Get-DriveFreeBytes -DriveLetter $applyDriveLetter
Write-WLog ("Uncompressed image size estimate: {0} bytes" -f $totalApplyBytes)
Write-WLog ("Apply drive {0} initial free space: {1} bytes" -f $applyDriveLetter, $initialFreeBytes)
$hasDiskPct = ($totalApplyBytes -gt 0 -and $initialFreeBytes -ge 0)

# Keep DISM off the operator console without WinPE-unsafe OutputDataReceived
# handlers (those threw in 5.0.15/5.0.16). cmd /c redirect-to-nul inherits no
# console chatter; progress comes from disk usage + /LogPath only.
$dismArgs = ($argLine -join ' ')
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = (Join-Path $env:SystemRoot 'System32\cmd.exe')
if (-not (Test-Path -LiteralPath $psi.FileName)) { $psi.FileName = 'cmd.exe' }
$psi.Arguments              = '/c ""{0}" {1} >nul 2>&1"' -f $dism, $dismArgs
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true
$psi.RedirectStandardOutput = $false
$psi.RedirectStandardError  = $false

$p = [System.Diagnostics.Process]::Start($psi)
if (-not $p) {
    Write-WLog 'Failed to start DISM via cmd.exe'
    Write-Host '   X  Could not start DISM.' -ForegroundColor Red
    exit 1
}
$sw      = [System.Diagnostics.Stopwatch]::StartNew()
$lastPct = 0
$pctRx   = [regex]'(\d+\.?\d*)(?:\s*%|\s+percent)'
$script:FbDismProgressRow = $null
$script:FbDismSpin = @('|', '/', '-', '\')

function Get-FbUiPlanEndRow {
    # Pin the apply bar under the deploy step list. CursorTop is unsafe: the
    # background SpinWatch parks on the active-step glyph (step 4) and would
    # make this bar overwrite the plan.
    foreach ($sf in @('X:\FirstBase-DeployUi.json', (Join-Path $env:TEMP 'FirstBase-DeployUi.json'))) {
        if ([string]::IsNullOrWhiteSpace($sf)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $sf)) { continue }
            $st = Get-Content -LiteralPath $sf -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $r = 0
            try { $r = [int]$st.PlanEndRow } catch { continue }
            if ($r -ge 2) { return $r }
        } catch {}
    }
    return $null
}

function Write-ProgressLine {
    param([int]$Pct, [bool]$HasPct, [switch]$Done)
    # Themed to Invoke-FbDeployUi: cyan active accents, dark gray idle fill, white %.
    # In-place only: never Clear-Host, SetCurrentConsoleFontEx, chcp, or mode con.
    $showPct = if ($Done) { 100 } elseif ($HasPct) { [math]::Max(0, [math]::Min(99, $Pct)) } else { 0 }
    $parts = Get-PercentBar -Pct $showPct -Width 28
    $spin = $script:FbDismSpin[[int]($sw.Elapsed.Seconds % 4)]
    if ($Done) { $spin = '*' }

    try {
        if ($null -eq $script:FbDismProgressRow) {
            $pinned = Get-FbUiPlanEndRow
            if ($null -ne $pinned) { $script:FbDismProgressRow = $pinned }
            else { $script:FbDismProgressRow = [System.Console]::CursorTop }
        }
        [System.Console]::SetCursorPosition(0, [int]$script:FbDismProgressRow)
    } catch {}

    $labelColor = if ($Done) { 'DarkGreen' } else { 'Cyan' }
    $pctColor   = if ($Done) { 'Green' } else { 'White' }
    $fillColor  = if ($Done) { 'DarkGreen' } else { 'Cyan' }

    # Indent aligns under the DeployUi step list (spinner column).
    Write-Host '   ' -NoNewline
    Write-Host $spin -ForegroundColor $labelColor -NoNewline
    Write-Host '  Applying image  ' -ForegroundColor $labelColor -NoNewline
    Write-Host ('[' ) -ForegroundColor DarkCyan -NoNewline
    if ($parts.Filled.Length -gt 0) {
        Write-Host $parts.Filled -ForegroundColor $fillColor -NoNewline
    }
    if ($parts.Empty.Length -gt 0) {
        Write-Host $parts.Empty -ForegroundColor DarkGray -NoNewline
    }
    Write-Host ']' -ForegroundColor DarkCyan -NoNewline
    if ($HasPct -or $Done) {
        Write-Host ('  {0,3}%' -f $showPct) -ForegroundColor $pctColor -NoNewline
    }
    # Pad rest of line so prior longer frames do not leave ghosts.
    Write-Host (' ' * 8) -NoNewline
}

try {
    while ($true) {
        $p.Refresh()
        $isRunning = -not $p.HasExited

        foreach ($ln in (Read-LogTail -Path $LogPath -Tail 40)) {
            Update-PercentFromLine -Line $ln -PctRx $pctRx -LastPct ([ref]$lastPct)
        }
        if ($hasDiskPct) {
            $diskPct = Get-DiskUsagePct -DriveLetter $applyDriveLetter -InitialFreeBytes $initialFreeBytes -TotalBytes $totalApplyBytes
            if ($diskPct -gt $lastPct) { $lastPct = $diskPct }
        }

        Write-ProgressLine -Pct $lastPct -HasPct $hasDiskPct

        if (-not $isRunning) { break }
        Start-Sleep -Milliseconds 1000
    }

    foreach ($ln in (Read-LogTail -Path $LogPath -Tail 40)) {
        Update-PercentFromLine -Line $ln -PctRx $pctRx -LastPct ([ref]$lastPct)
    }
} catch {
    Write-WLog ("Progress loop error: {0}" -f $_.Exception.Message)
}

try { $p.WaitForExit() } catch {}
$code = $null
try {
    $p.Refresh()
    $code = $p.ExitCode
} catch {
    Write-Warning ("Could not read DISM exit code: {0}" -f $_.Exception.Message)
}
if ($null -eq $code) { $code = -1 }

$totalElapsed = Format-Duration $sw.Elapsed
Write-WLog ("DISM exit code: {0}  elapsed: {1}" -f $code, $totalElapsed)

if ($code -eq 0) {
    Write-ProgressLine -Pct 100 -HasPct:$true -Done
    Write-Host ''
} else {
    Write-Host ''
    Write-Host ('   X  Applying image failed (exit {0})' -f $code) -ForegroundColor Red
    Write-Host ''
    Write-Host '   ---- DISM log (last 30 lines) ----' -ForegroundColor Yellow
    foreach ($ln in (Read-LogTail -Path $LogPath -Tail 30)) {
        Write-Host ('   {0}' -f $ln)
    }
    Write-Host ''
    Write-Host '   Press any key to continue...' -ForegroundColor Yellow -NoNewline
    try { $null = [System.Console]::ReadKey($true) } catch {}
    Write-Host ''
}

exit [int]$code
