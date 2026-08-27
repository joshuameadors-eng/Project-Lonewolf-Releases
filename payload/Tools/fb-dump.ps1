#Requires -Version 3
<#
.SYNOPSIS
    fb-dump.ps1 -- FirstBase diagnostic log collector (PowerShell backend)
    5.4.25: splash Hidden start; explicit -Dest is not blocked on C:;
    copies Setup\FirstBase\Logs (WU-*.log) with ASCII missing markers.
    5.4.26: NoPrompt never uses the console UI; robocopy does not redirect stdout
    (Hidden dump was exiting before extras / deadlocking).
.DESCRIPTION
    Full diagnostic collection: build identity, payload state, Panther, Sysprep,
    event logs, Task Scheduler, Defender, CBS/DISM, tasklist, installed programs,
    system info, and splash/preflight logs.
    Prompts for issue description; writes FirstBase-Issue.md.
    Invoked by the thin cmd launcher fb-dump.cmd which handles elevation. From
    5.1.53 that launcher is staged at the USB ROOT while this backbone stays in
    WUPayload\Tools\, so the launcher resolves this file by relative path. The
    destination logic below is unaffected: it locates the LoneWolf volume by
    label, independently of where either file sits.
.PARAMETER Dest
    Destination folder override.  Auto-generated from BIOS SN + time + mfr when omitted.
.PARAMETER IssueDescription
    Pre-filled issue text for FirstBase-Issue.md. When -NoPrompt is set, skips the
    interactive Read-Host and uses this value (empty => "No description provided").
.PARAMETER NoPrompt
    Skip the post-collection issue description prompt (for fb-im parallel notes UI).
#>
param(
    [string]$Dest = '',
    [string]$IssueDescription = '',
    [switch]$NoPrompt
)

Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'
$script:FbDumpUi = $false
try {
    if (-not $NoPrompt -and [Console]::WindowWidth -gt 0) { $script:FbDumpUi = $true }
} catch { $script:FbDumpUi = $false }
# Splash Collect logs starts this script Hidden with no console. Never
# call Console.SetCursorPosition unless FbDumpUi is true.

function Wait-FbDumpExitPrompt {
    if ($NoPrompt) { return }
    try {
        Write-Host ''
        Write-Host "  $($script:DIM)Press any key to exit...$($script:RESET)"
    } catch {
        Write-Host ''
        Write-Host '  Press Enter to exit...'
    }
    try   { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    catch { try { Read-Host '  Press Enter to exit' | Out-Null } catch {} }
}

function Exit-FbDump {
    param([int]$Code = 0)
    if (-not $NoPrompt) {
        try { Read-Host '  Press Enter to exit' | Out-Null } catch {}
    }
    exit $Code
}

# =============================================================================
# VT100 / ANSI -- enable virtual terminal processing in the current console
# =============================================================================
try {
    if (-not ('FB.K32VT' -as [type])) {
        $vtsig = @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@
        Add-Type -MemberDefinition $vtsig -Name 'K32VT' -Namespace 'FB' -ErrorAction Stop | Out-Null
    }
    [uint32]$_vtm = 0
    $_vth = [FB.K32VT]::GetStdHandle(-11)
    [FB.K32VT]::GetConsoleMode($_vth, [ref]$_vtm) | Out-Null
    [FB.K32VT]::SetConsoleMode($_vth, $_vtm -bor 4) | Out-Null
} catch { }

# =============================================================================
# ANSI color / style sequences
# =============================================================================
$script:E      = [char]27
$script:RESET  = "$($script:E)[0m"
$script:WHITE  = "$($script:E)[1;97m"
$script:RED    = "$($script:E)[91m"
$script:GREEN  = "$($script:E)[92m"
$script:YELLOW = "$($script:E)[93m"
$script:CYAN   = "$($script:E)[96m"
$script:DIM    = "$($script:E)[2m"
$script:EL     = "$($script:E)[K"   # Erase Line: clears cursor to end-of-line

# =============================================================================
# Global UI state  (rows captured after header is drawn)
# =============================================================================
$script:TotalPhases    = 14
$script:ProgressBarRow = 0
$script:PhaseRow       = 0
$script:SubRow         = 0
$script:SpinChars      = [char[]]@('|', '/', '-', '\')

# =============================================================================
# HELPERS
# =============================================================================

function Build-Bar {
    <# Returns a $Width-char progress bar string, e.g. "=======>            " #>
    param([int]$Pct, [int]$Width = 20)
    $Pct  = [Math]::Max(0, [Math]::Min(100, $Pct))
    $fill = [int]([Math]::Round(($Pct / 100.0) * $Width))
    if ($Pct -ge 100) { return '=' * $Width }
    if ($fill -le 0)  { return ' ' * $Width }
    return ('=' * ($fill - 1)) + '>' + (' ' * ($Width - $fill))
}

function Update-ProgressBar {
    <#
    Overwrites the fixed progress-bar row then restores the cursor.
    Rendered form:  Progress  [=========>          ]  45%   (5 / 14 phases)
    #>
    param([int]$Current)
    if (-not $script:FbDumpUi) { return }
    $tot  = $script:TotalPhases
    $pct  = if ($tot -gt 0) { [int](($Current / $tot) * 100) } else { 0 }
    $bar  = Build-Bar -Pct $pct
    $pctLabel = if ($pct -ge 100) { "$($script:GREEN)Done$($script:RESET)" } else { "${pct}%" }
    $line = "  $($script:CYAN)Progress$($script:RESET)  " +
            "[$($script:GREEN)${bar}$($script:RESET)]" +
            "  ${pctLabel}   ($Current / $tot phases)"

    $st = [System.Console]::CursorTop
    $sl = [System.Console]::CursorLeft
    [System.Console]::SetCursorPosition(0, $script:ProgressBarRow)
    Write-Host "${line}$($script:EL)" -NoNewline
    [System.Console]::SetCursorPosition($sl, $st)
}

function Show-PhaseLabel {
    <#
    Overwrites the fixed phase-label row with a spinner/status indicator.
    Rendered form:  [3/14]  /  Copying Windows Panther logs...
    #>
    param(
        [int]    $Idx,
        [string] $Label,
        [string] $Spin  = '|',
        [switch] $Done,
        [switch] $Warn
    )
    if (-not $script:FbDumpUi) { return }
    $icon = if    ($Done) { "$($script:GREEN)OK$($script:RESET)" }
            elseif ($Warn) { "$($script:YELLOW)!!$($script:RESET)" }
            else           { "$($script:CYAN)${Spin}$($script:RESET) " }
    [System.Console]::SetCursorPosition(0, $script:PhaseRow)
    Write-Host "  [$Idx/$($script:TotalPhases)]  ${icon}  ${Label}$($script:EL)" -NoNewline
}

function Update-SubProgress {
    <#
    Overwrites the fixed sub-progress row.
    Rendered form:  [2] ProgramData  [======>             ]  38%  (14.2 MB / 37.8 MB)
    #>
    param(
        [int]    $Idx,
        [string] $Label,
        [int]    $Pct,
        [double] $DoneMB  = 0,
        [double] $TotalMB = 0
    )
    if (-not $script:FbDumpUi) { return }
    $bar   = Build-Bar -Pct $Pct
    $mbStr = if ($TotalMB -gt 0) {
        "  ($([Math]::Round($DoneMB, 1)) MB / $([Math]::Round($TotalMB, 1)) MB)"
    } else { '' }
    $line = "  [$Idx] $($script:DIM)${Label}$($script:RESET)  " +
            "[$($script:CYAN)${bar}$($script:RESET)]  ${Pct}%${mbStr}"
    [System.Console]::SetCursorPosition(0, $script:SubRow)
    Write-Host "${line}$($script:EL)" -NoNewline
}

function Clear-SubProgress {
    if (-not $script:FbDumpUi) { return }
    [System.Console]::SetCursorPosition(0, $script:SubRow)
    Write-Host $script:EL -NoNewline
}

function Start-PhaseSpin {
    <# Brief cosmetic pre-spin before synchronous work begins. #>
    param([int]$Idx, [string]$Label, [int]$Frames = 4)
    if (-not $script:FbDumpUi) { return }
    for ($i = 0; $i -lt $Frames; $i++) {
        Show-PhaseLabel -Idx $Idx -Label $Label -Spin ($script:SpinChars[$i % 4])
        Start-Sleep -Milliseconds 80
    }
}

function Invoke-RobocopyPhase {
    <#
    Runs robocopy for a directory copy and renders real-time file-count
    progress in the sub-progress row.  Robocopy exit codes 0-7 = success.

    Progress parsing: robocopy stdout lines containing the file-class markers
    ("New File", "Newer", "Older", "Changed", "Extra File") each indicate one
    file processed.  The pre-scan (Get-ChildItem) gives totalFiles/totalBytes
    so we can compute a percentage and an approximate MB-transferred figure.

    Robocopy args:  /E  (include subdirs)
                    /R:1 /W:1  (1 retry, 1-second wait -- fast fail)
                    /NJH /NJS  (suppress job header/summary -- reduces noise)
    #>
    param(
        [int]    $Idx,
        [string] $Label,
        [string] $Source,
        [string] $DestDir
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        Show-PhaseLabel -Idx $Idx -Label "$Label  (source absent)" -Done
        Update-ProgressBar -Current $Idx
        return
    }

    # Pre-scan: total file count + bytes for progress calculation
    $totalFiles = 0
    $totalBytes = 0.0
    try {
        $scan       = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue)
        $totalFiles = $scan.Count
        $totalBytes = [double](($scan | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum)
    } catch { }
    $totalMB = if ($totalBytes -gt 0) { $totalBytes / 1MB } else { 0 }

    $null = New-Item -ItemType Directory -Path $DestDir -Force -ErrorAction SilentlyContinue

    if (-not $script:FbDumpUi) {
        try {
            $rcExe = Join-Path $env:SystemRoot 'System32\robocopy.exe'
            if (-not (Test-Path -LiteralPath $rcExe)) { $rcExe = 'robocopy.exe' }
            $rcArgs = @($Source, $DestDir, '/E', '/R:1', '/W:1', '/NJH', '/NJS', '/NP', '/COPY:DAT')
            Start-Process -FilePath $rcExe -ArgumentList $rcArgs -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
        } catch {}
        return
    }

    Show-PhaseLabel -Idx $Idx -Label $Label -Spin '|'

    # Launch robocopy; read its stdout line-by-line in real time
    $psi                       = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'robocopy'
    $psi.Arguments              = "`"$Source`" `"$DestDir`" /E /R:1 /W:1 /NJH /NJS"
    $psi.RedirectStandardOutput = $true
    # Do not redirect stderr: an unread stderr pipe can fill and deadlock robocopy.
    $psi.RedirectStandardError  = $false
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch {
        Show-PhaseLabel -Idx $Idx -Label "$Label  (robocopy unavailable)" -Warn
        Update-ProgressBar -Current $Idx
        return
    }

    $spinIdx     = 0
    $copiedFiles = 0

    while (-not $proc.StandardOutput.EndOfStream) {
        $rcLine = $proc.StandardOutput.ReadLine()
        if ($null -eq $rcLine -or $rcLine.Trim() -eq '') { continue }

        # Each line that contains a file-class marker = one file processed
        if ($rcLine -match 'New File|Newer\s|Older\s|Changed\s|Extra File') { $copiedFiles++ }

        Show-PhaseLabel -Idx $Idx -Label $Label -Spin ($script:SpinChars[$spinIdx % 4])
        $spinIdx++

        $pct    = if ($totalFiles -gt 0) {
                      [Math]::Min(99, [int](($copiedFiles / $totalFiles) * 100))
                  } else { 0 }
        $doneMB = if ($totalMB -gt 0 -and $totalFiles -gt 0) {
                      ($copiedFiles / [Math]::Max(1, $totalFiles)) * $totalMB
                  } else { 0 }

        Update-SubProgress -Idx $Idx -Label $Label -Pct $pct -DoneMB $doneMB -TotalMB $totalMB
    }

    $proc.WaitForExit()
    $ec = $proc.ExitCode
    Clear-SubProgress

    if ($ec -le 7) { Show-PhaseLabel -Idx $Idx -Label $Label -Done }
    else           { Show-PhaseLabel -Idx $Idx -Label "$Label  (robocopy exit $ec)" -Warn }

    Update-ProgressBar -Current $Idx
}

function Write-FBHeader {
    <# Clears the console and draws the ASCII art branding (11 output lines). #>
    if (-not $script:FbDumpUi) { return }
    try { [System.Console]::Clear() } catch { return }
    Write-Host ''
    Write-Host '    ______  _              _   ____'
    Write-Host '   |  ____||_|           | | |  _ \'
    Write-Host '   | |__    _  _ __  ___ | |_| |_) | __ _  ___  ___'
    Write-Host "   |  __|  | || '__|/ __|| __|  _ < / _`` |/ __|/ _ \"
    Write-Host '   | |     | || |   \__ \| |_| |_) | (_| |\__ \  __/'
    Write-Host '   |_|     |_||_|   |___/ \__|____/ \__,_||___/\___|'
    Write-Host ''
    Write-Host "   $($script:RED)For Internal Use Only$($script:RESET)"
    Write-Host ''
}

# Volume labels that must never be written to
$script:BlockedLabels = @('FB_ESP', 'System Reserved', 'SYSTEM')

function Test-IsBlockedDrive {
    <#
    Returns $true if the drive is C:, has a blocked volume label (FB_ESP,
    System Reserved, SYSTEM), or is a FAT32 volume smaller than 2 GB
    (covers EFI System Partitions). Never throws.
    #>
    param([string]$Letter)
    if ($Letter -eq 'C') { return $true }
    if (-not (Test-Path -LiteralPath "${Letter}:\" -ErrorAction SilentlyContinue)) { return $true }
    try {
        $vol = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='${Letter}:'" -ErrorAction SilentlyContinue
        if ($vol) {
            $label = if ($vol.VolumeName) { $vol.VolumeName.Trim() } else { '' }
            foreach ($blocked in $script:BlockedLabels) {
                if ($label -eq $blocked) { return $true }
            }
            if ($vol.FileSystem -eq 'FAT32' -and [long]$vol.Size -lt 2147483648L) { return $true }
        }
    } catch {}
    return $false
}

# =============================================================================
# DESTINATION RESOLUTION
# =============================================================================
function Write-FbDumpAsciiNote {
    param([string]$Path, [string]$Text)
    if (-not $Path) { return }
    try {
        $body = [string]$Text
        if (-not $body.EndsWith("`r`n") -and -not $body.EndsWith("`n")) { $body = $body + "`r`n" }
        [System.IO.File]::WriteAllText($Path, $body, [System.Text.Encoding]::ASCII)
    } catch {}
}

function Copy-FbDumpOneTree {
    param(
        [string]$Source,
        [string]$DestDir,
        [string]$Label
    )
    $safeLabel = ($Label -replace '[^\w\-]', '-')
    if (-not $safeLabel) { $safeLabel = 'source' }
    $missingPath = Join-Path $FbDest ($safeLabel + '-MISSING.txt')
    if (-not $Source -or -not (Test-Path -LiteralPath $Source)) {
        Write-FbDumpAsciiNote -Path $missingPath -Text ('Source missing: ' + [string]$Source)
        return 0
    }
    $n = 0
    try { $null = New-Item -ItemType Directory -Path $DestDir -Force -ErrorAction SilentlyContinue } catch {}
    $files = @()
    try { $files = @(Get-ChildItem -LiteralPath $Source -Force -Recurse -File -ErrorAction SilentlyContinue) } catch { $files = @() }
    foreach ($f in $files) {
        try {
            $rel = $f.FullName.Substring($Source.Length).TrimStart('\')
            $target = Join-Path $DestDir $rel
            $parent = Split-Path -Parent $target
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue
            }
            Copy-Item -LiteralPath $f.FullName -Destination $target -Force -ErrorAction Stop
            $n++
        } catch {
            $skipPath = Join-Path $FbDest 'COPY-SKIP.txt'
            $msg = 'SKIP: ' + $f.FullName + ' :: ' + $_.Exception.Message
            try { Add-Content -LiteralPath $skipPath -Value $msg -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
        }
    }
    return $n
}

function Copy-FbDumpOnDeviceSources {
    # Always copy the live on-device log roots. Robocopy later may add more.
    # Hidden splash start has no console; Copy-Item still runs.
    $n = 0
    $n += Copy-FbDumpOneTree -Source 'C:\Windows\Setup\FirstBase\Logs' -DestDir (Join-Path $FbDest 'Logs') -Label 'Setup-FirstBase-Logs'
    $n += Copy-FbDumpOneTree -Source 'C:\Windows\Setup\FirstBase\State' -DestDir (Join-Path $FbDest 'State') -Label 'Setup-FirstBase-State'
    $n += Copy-FbDumpOneTree -Source 'C:\ProgramData\FirstBase' -DestDir (Join-Path $FbDest 'ProgramData-FirstBase') -Label 'ProgramData-FirstBase'
    $wuRoot = 'C:\Windows\Setup\FirstBase'
    $wuDest = Join-Path $FbDest 'Logs'
    try { $null = New-Item -ItemType Directory -Path $wuDest -Force -ErrorAction SilentlyContinue } catch {}
    $extra = @()
    try {
        $extra = @(Get-ChildItem -LiteralPath $wuRoot -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'WU-*.log' -or $_.Name -like '*.log' })
    } catch { $extra = @() }
    foreach ($f in $extra) {
        try {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $wuDest $f.Name) -Force -ErrorAction Stop
            $n++
        } catch {
            $skipPath = Join-Path $FbDest 'COPY-SKIP.txt'
            $msg = 'SKIP: ' + $f.FullName + ' :: ' + $_.Exception.Message
            try { Add-Content -LiteralPath $skipPath -Value $msg -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
        }
    }
    return $n
}

if ($Dest -and $Dest.Trim() -ne '') {
    $FbDest = $Dest.Trim().TrimEnd('\')
    $explicitDrive = (Split-Path -Qualifier $FbDest -ErrorAction SilentlyContinue).TrimEnd(':').ToUpper()
    if ($explicitDrive) {
        $blockEsp = $false
        try {
            $vol = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='${explicitDrive}:'" -ErrorAction SilentlyContinue
            if ($vol) {
                $label = if ($vol.VolumeName) { $vol.VolumeName.Trim() } else { '' }
                foreach ($blocked in $script:BlockedLabels) {
                    if ($label -eq $blocked) { $blockEsp = $true }
                }
                if ($explicitDrive -ne 'C' -and $vol.FileSystem -eq 'FAT32' -and [long]$vol.Size -lt 2147483648L) {
                    $blockEsp = $true
                }
            }
        } catch {}
        if ($blockEsp) {
            Write-Host ''
            Write-Host "  $($script:RED)[ERROR]$($script:RESET) Destination drive ${explicitDrive}: is blocked (FB_ESP or ESP partition)."
            Write-Host '         Pass a path on the LoneWolf USB volume or another writable folder.'
            Exit-FbDump -Code 1
        }
    }
} else {
    $hhmm = (Get-Date).ToString('HHmm')

    $sn = 'UNKNOWN-SN'
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        if ($bios.SerialNumber) {
            $s = $bios.SerialNumber.Trim()
            $s = $s -replace '[^\w\-]', '-' -replace '-{2,}', '-' -replace '^-+|-+$', ''
            if ($s) { $sn = $s }
        }
    } catch { }

    $mfr = 'UNKNOWN-MFR'
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.Manufacturer) {
            $m = $cs.Manufacturer.Trim()
            $m = $m -replace '^Dell.*',            'Dell'
            $m = $m -replace '^HP\b|^Hewlett-.*',  'HP'
            $m = $m -replace '^LENOVO.*|^Lenovo.*', 'Lenovo'
            $m = $m -replace '^Microsoft.*',        'Microsoft'
            $m = $m -replace '^Acer\b.*',           'Acer'
            $m = $m -replace '^ASUS\b.*',           'ASUS'
            $m = $m -replace '^Toshiba\b.*',        'Toshiba'
            $m = $m -replace '^Samsung\b.*',        'Samsung'
            $m = $m -replace '^Panasonic\b.*',      'Panasonic'
            $m = $m -replace '[^\w\-]', '-' -replace '-{2,}', '-' -replace '^-+|-+$', ''
            if ($m) { $mfr = $m }
        }
    } catch { }

    # Find the LoneWolf USB volume -- the only accepted destination. Both Single (FAT32)
    # and Split (NTFS) layouts now label the data volume "LoneWolf" (FAT32 reads it back
    # uppercase as "LONEWOLF"). -contains is case-insensitive; legacy labels kept for old sticks.
    $lwLabels = @('LoneWolf', 'LONEWOLF', 'Project LoneWolf')
    $destDrive = ''
    try {
        $allVols = Get-WmiObject Win32_LogicalDisk -ErrorAction SilentlyContinue
        $lwVol = $allVols | Where-Object { $_.VolumeName -and ($lwLabels -contains $_.VolumeName.Trim()) } | Select-Object -First 1
        if ($lwVol -and $lwVol.DeviceID) {
            $cand = $lwVol.DeviceID.TrimEnd(':').ToUpper()
            if (-not (Test-IsBlockedDrive $cand)) { $destDrive = $cand }
        }
    } catch {}

    if (-not $destDrive) {
        Write-FBHeader
        Write-Host ''
        Write-Host "  $($script:RED)[ERROR]$($script:RESET) Could not find a volume labeled 'LoneWolf'."
        Write-Host '         Ensure the FirstBase USB stick is connected and try again.'
        Write-Host '         To override: fb-dump.cmd H:\my-dump-folder'
        Write-Host ''
        Exit-FbDump -Code 1
    }

    $FbDest = Join-Path "${destDrive}:\FirstBase-Logs" "$sn-$hhmm-$mfr"
}

# =============================================================================
# INITIALIZE UI
# After Write-FBHeader (11 lines), cursor is at row 11.  We then write 3 more
# lines (dest, started, blank) before recording ProgressBarRow at row 14.
# Layout:
#   Row 14: Progress bar  (ProgressBarRow)
#   Row 15: blank spacer
#   Row 16: Phase label   (PhaseRow)
#   Row 17: Sub-progress  (SubRow)
# =============================================================================
Write-FBHeader
Write-Host "  Destination : $FbDest"
Write-Host "  Started     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ''

$script:ProgressBarRow = 0
$script:PhaseRow = 0
$script:SubRow = 0
if ($script:FbDumpUi) {
    try { $script:ProgressBarRow = [System.Console]::CursorTop } catch { $script:FbDumpUi = $false }
}
if ($script:FbDumpUi) { Write-Host '' }

if ($script:FbDumpUi) { Write-Host '' }

if ($script:FbDumpUi) {
    try { $script:PhaseRow = [System.Console]::CursorTop } catch {}
    Write-Host ''
    try { $script:SubRow = [System.Console]::CursorTop } catch {}
    Write-Host ''
}

Update-ProgressBar -Current 0

# Create destination folder
if (-not (Test-Path -LiteralPath $FbDest)) {
    $null = New-Item -ItemType Directory -Path $FbDest -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path -LiteralPath $FbDest)) {
    try {
        if ($script:FbDumpUi) { [System.Console]::SetCursorPosition(0, $script:SubRow + 2) }
    } catch {}
    Write-Host ''
    Write-Host "  $($script:RED)[ERROR]$($script:RESET) Cannot create destination: $FbDest"
    Write-Host '  Pass an explicit path:  fb-dump.cmd D:\fb-myrun'
    Exit-FbDump -Code 1
}

try { [void](Copy-FbDumpOnDeviceSources) } catch {}

# =============================================================================
# CAPTURE PHASES
# =============================================================================
$phase = 0

# ─── Phase 1: Build identity (00-BUILD-IDENTITY.txt) ─────────────────────────
$phase++
Start-PhaseSpin -Idx $phase -Label 'Build identity'
try {
    $bvPath = 'C:\Windows\Setup\FirstBase\State\build-version.txt'
    $lv = '<unknown>'; $ev = '<unknown>'
    if (Test-Path $bvPath) {
        foreach ($bl in (Get-Content $bvPath -ErrorAction SilentlyContinue)) {
            if ($bl -match '^LoopVersion:\s*(.+)$') { $lv = $Matches[1].Trim() }
            elseif ($bl -match '^EngineVer:\s*(.+)$') { $ev = $Matches[1].Trim() }
        }
    }
    $tag = '<unknown>'
    if ($lv -match '\d{4}\.\d{2}\.\d{2}\.([^-]+)') { $tag = $Matches[1] }
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'

    $payloadFiles = @(
        @{ N='Invoke-WindowsUpdateLoop.ps1';      P='C:\Windows\Setup\FirstBase\Invoke-WindowsUpdateLoop.ps1' }
        @{ N='FirstBaseWuEngine.ps1';             P='C:\Windows\Setup\FirstBase\FirstBaseWuEngine.ps1' }
        @{ N='SetupComplete.cmd';                 P='C:\Windows\Setup\Scripts\SetupComplete.cmd' }
        @{ N='FirstBaseSplashSingleInstance.ps1'; P='C:\Windows\Setup\FirstBase\FirstBaseSplashSingleInstance.ps1' }
        @{ N='FirstBaseSplashWatcher.ps1';        P='C:\Windows\Setup\FirstBase\FirstBaseSplashWatcher.ps1' }
    )

    $idLines = @(
        '========================================================'
        '====        FIRSTBASE BUILD IDENTITY                ===='
        '========================================================'
        ''
        "LoopVersion: $lv"
        "EngineVer:   $ev"
        ''
        "Build Tag: $tag"
        "Dump Captured: $ts"
        ''
        '========================================================'
        ''
        'Payload SHAs:'
    )
    foreach ($pf in $payloadFiles) {
        if (Test-Path -LiteralPath $pf.P) {
            try   { $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $pf.P -ErrorAction Stop).Hash
                    $idLines += ('  {0,-40}: {1}' -f $pf.N, $h) }
            catch { $idLines += ('  {0,-40}: <HASH-FAILED>' -f $pf.N) }
        } else  { $idLines += ('  {0,-40}: <MISSING>' -f $pf.N) }
    }
    $idLines += ''
    $idLines += '========================================================'
    [System.IO.File]::WriteAllLines(
        (Join-Path $FbDest '00-BUILD-IDENTITY.txt'),
        $idLines,
        [System.Text.Encoding]::UTF8
    )
    Show-PhaseLabel -Idx $phase -Label 'Build identity' -Done
} catch {
    Show-PhaseLabel -Idx $phase -Label 'Build identity' -Warn
}
Update-ProgressBar -Current $phase

# ─── Phase 2: Build version marker ───────────────────────────────────────────
$phase++
Start-PhaseSpin -Idx $phase -Label 'Build version marker'
try {
    $bvSrc = 'C:\Windows\Setup\FirstBase\State\build-version.txt'
    if (Test-Path $bvSrc) {
        Copy-Item -LiteralPath $bvSrc -Destination "$FbDest\build-version.txt" -Force
    } else {
        $fbFallback = @(
            '=== LIVE FALLBACK build-version.txt ==='
            "WrittenAt: $(Get-Date) [fb-dump fallback]"
            'LoopVersion: <not-written-by-loop>'
            'EngineVer:   <not-written-by-loop>'
            ''
            '=== Payload SHAs (fallback) ==='
        )
        $fbFallback += (
            Get-ChildItem 'C:\Windows\Setup\FirstBase' -File -Include '*.ps1','*.cmd' -EA SilentlyContinue |
            Get-FileHash -Algorithm SHA256 -EA SilentlyContinue |
            ForEach-Object { '{0}  {1}' -f $_.Hash, (Split-Path -Leaf $_.Path) }
        )
        [System.IO.File]::WriteAllLines("$FbDest\build-version.txt", $fbFallback, [System.Text.Encoding]::UTF8)
    }
    Show-PhaseLabel -Idx $phase -Label 'Build version marker' -Done
} catch {
    Show-PhaseLabel -Idx $phase -Label 'Build version marker' -Warn
}
Update-ProgressBar -Current $phase

# ─── Phase 3: Payload + state + logs ─────────────────────────────────────────
$phase++
Start-PhaseSpin -Idx $phase -Label 'Payload + state + logs'
try {
    $fbBase = 'C:\Windows\Setup\FirstBase'
    $fbLogs = Join-Path $fbBase 'Logs'
    $fbState = Join-Path $fbBase 'State'
    if (Test-Path -LiteralPath $fbBase) {
        if (Test-Path -LiteralPath $fbLogs) {
            & robocopy $fbLogs "$FbDest\Logs" /E /R:1 /W:1 /NP /NJH /NJS /COPY:DAT 2>$null | Out-Null
            Get-ChildItem -LiteralPath $fbLogs -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'WU-*.log' -or $_.Name -like 'splash-*.log' } |
                ForEach-Object {
                    $null = New-Item -ItemType Directory -Path "$FbDest\Logs" -Force -ErrorAction SilentlyContinue
                    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path "$FbDest\Logs" $_.Name) -Force -ErrorAction SilentlyContinue
                }
        }
        if (Test-Path -LiteralPath $fbState) {
            & robocopy $fbState "$FbDest\State" /E /R:1 /W:1 /NP /NJH /NJS /COPY:DAT 2>$null | Out-Null
        }
        Get-ChildItem -LiteralPath $fbBase -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.ps1', '.cmd') } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $FbDest -Force -ErrorAction SilentlyContinue }
        foreach ($xf in @('wu-state.json','wu-status.json','wu-loop-heartbeat.txt')) {
            foreach ($xp in @(
                (Join-Path $fbState $xf),
                (Join-Path $fbBase $xf),
                (Join-Path 'C:\ProgramData\FirstBase' $xf),
                (Join-Path 'C:\ProgramData\FirstBase\State' $xf)
            )) {
                if (Test-Path -LiteralPath $xp) {
                    Copy-Item -LiteralPath $xp -Destination $FbDest -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    Show-PhaseLabel -Idx $phase -Label 'Payload + state + logs' -Done
} catch {
    Show-PhaseLabel -Idx $phase -Label 'Payload + state + logs' -Warn
}
Update-ProgressBar -Current $phase

# ─── Phase 4: ProgramData + USB logs ─────────────────────────────────────────
$phase++

# USB stick logs first (quick -- any drive letter)
$null = New-Item -ItemType Directory -Path "$FbDest\UsbStickRoot" -Force -EA SilentlyContinue
    foreach ($dl in @('F','E','D','G','H','I','J')) {
    if (Test-IsBlockedDrive $dl) { continue }   # skip C:, ESP, and blocked labels
    $rootLogs = @(
        "${dl}:\FirstBase-Deploy.log"
        "${dl}:\FirstBase-Trace.log"
        "${dl}:\FirstBase-DISM.log"
        "${dl}:\FirstBase-DISM-wrapper.log"
        "${dl}:\FirstBase-winpe.log"
        "${dl}:\FirstBase-disksetup.log"
        "${dl}:\FirstBase-QuickInstall.log"
        "${dl}:\FirstBase-QuickInstall-DISM.log"
        "${dl}:\FirstBase-QuickInstall-DISM-wrapper.log"
        "${dl}:\fb-im-last-launch.log"
    )
    foreach ($rl in $rootLogs) {
        if (Test-Path $rl) {
            Copy-Item $rl -Destination ("$FbDest\UsbStickRoot\{0}" -f [IO.Path]::GetFileName($rl).Replace('.log', "-${dl}.log")) -Force -EA SilentlyContinue
        }
    }
    $uldrVisible = "${dl}:\FirstBase-Logs"
    $uldr = "${dl}:\FirstBase-UsbLogs"
    $uldrNested = "${dl}:\FirstBase\FirstBase-UsbLogs"
    foreach ($ud in @($uldrVisible, $uldr, $uldrNested)) {
        if (Test-Path -LiteralPath $ud) {
            $leaf = Split-Path $ud -Leaf
            $usbDst = "$FbDest\UsbStickRoot\$leaf-${dl}"
            $null = New-Item -ItemType Directory -Path $usbDst -Force -EA SilentlyContinue
            & robocopy $ud $usbDst /E /R:1 /W:1 /NP /NJH /NJS /COPY:DAT /XD $FbDest 2>$null | Out-Null
        }
    }
}

# ProgramData -- potentially large, use Invoke-RobocopyPhase for live progress
$pdSrc = 'C:\ProgramData\FirstBase'
if (Test-Path $pdSrc) {
    Invoke-RobocopyPhase -Idx $phase -Label 'ProgramData + USB logs' -Source $pdSrc -DestDir "$FbDest\ProgramData-FirstBase"
} else {
    Start-PhaseSpin -Idx $phase -Label 'ProgramData + USB logs'
    'C:\ProgramData\FirstBase absent at dump time.' | Out-File "$FbDest\ProgramData-FirstBase-MISSING.txt" -Encoding UTF8
    Show-PhaseLabel -Idx $phase -Label 'ProgramData + USB logs' -Done
    Update-ProgressBar -Current $phase
}

# ─── Phase 5: Windows Panther (large -- Invoke-RobocopyPhase) ─────────────────
$phase++
Invoke-RobocopyPhase -Idx $phase -Label 'Windows Panther' `
    -Source 'C:\Windows\Panther' -DestDir "$FbDest\Panther"

# ─── Phase 6: Sysprep Panther ─────────────────────────────────────────────────
$phase++
Invoke-RobocopyPhase -Idx $phase -Label 'Sysprep Panther' `
    -Source 'C:\Windows\System32\Sysprep\Panther' -DestDir "$FbDest\SysprepPanther"

# ─── Phase 7: Task Scheduler events ──────────────────────────────────────────
$phase++
Start-PhaseSpin -Idx $phase -Label 'Task Scheduler events'
try {
    & wevtutil epl 'Microsoft-Windows-TaskScheduler/Operational' `
        "$FbDest\TaskScheduler-Operational.evtx" /ow:true 2>$null
    & wevtutil qe 'Microsoft-Windows-TaskScheduler/Operational' /f:text /c:500 /rd:true 2>$null |
        Out-File "$FbDest\TaskScheduler-Operational-text.txt" -Encoding UTF8 -EA SilentlyContinue
    Show-PhaseLabel -Idx $phase -Label 'Task Scheduler events' -Done
} catch {
    Show-PhaseLabel -Idx $phase -Label 'Task Scheduler events' -Warn
}
Update-ProgressBar -Current $phase

# ─── Phase 8: Defender events ────────────────────────────────────────────────
$phase++
Start-PhaseSpin -Idx $phase -Label 'Defender events'
try {
    & wevtutil epl 'Microsoft-Windows-Windows Defender/Operational' `
        "$FbDest\Defender-Operational.evtx" /ow:true 2>$null
    & wevtutil qe 'Microsoft-Windows-Windows Defender/Operational' /f:text /c:200 /rd:true 2>$null |
        Out-File "$FbDest\Defender-Operational-text.txt" -Encoding UTF8 -EA SilentlyContinue
    Show-PhaseLabel -Idx $phase -Label 'Defender events' -Done
} catch {
    Show-PhaseLabel -Idx $phase -Label 'Defender events' -Warn
}
Update-ProgressBar -Current $phase

# ─── Phase 9: Application + System events ────────────────────────────────────
$phase++
Start-PhaseSpin -Idx $phase -Label 'Application + System events'
try {
    & wevtutil qe Application /f:text /c:200 /rd:true 2>$null |
        Out-File "$FbDest\Application-text.txt" -Encoding UTF8 -EA SilentlyContinue
    & wevtutil qe System /f:text /c:200 /rd:true 2>$null |
        Out-File "$FbDest\System-text.txt" -Encoding UTF8 -EA SilentlyContinue
    Show-PhaseLabel -Idx $phase -Label 'Application + System events' -Done
} catch {
    Show-PhaseLabel -Idx $phase -Label 'Application + System events' -Warn
}
Update-ProgressBar -Current $phase

# ─── Phase 10: Tasklist + registry + installed programs + sysinfo ────────────
$phase++
Start-PhaseSpin -Idx $phase -Label 'Tasklist + registry'
try {
    & {
        '=== Process list ==='
        Get-CimInstance Win32_Process -EA SilentlyContinue |
            Where-Object { $_.Name -match 'powershell|sysprep|cmd|explorer|setup' } |
            Select-Object ProcessId, SessionId, CreationDate, CommandLine |
            Format-List | Out-String -Width 240
        ''
        '=== Scheduled tasks ==='
        & schtasks /Query /TN 'FirstBase\WindowsUpdateLoop'        /V /FO LIST 2>$null
        & schtasks /Query /TN 'FirstBase\WindowsUpdateLoopOnLogon' /V /FO LIST 2>$null
        & schtasks /Query /TN 'FirstBase\WindowsUpdateLoopBoot2'   /V /FO LIST 2>$null
        & schtasks /Query /TN 'FirstBase\WindowsUpdateLoopAnyLogon' /V /FO LIST 2>$null
        & schtasks /Query /TN 'FirstBase\UpdateSplash'             /V /FO LIST 2>$null
        & schtasks /Query /TN 'FirstBase\SplashWatcher'            /V /FO LIST 2>$null
        & schtasks /Query /TN 'FirstBase\SplashWatcherBoot2'       /V /FO LIST 2>$null
        & schtasks /Query /TN 'FirstBase\UpdateSplashLayer4'       /V /FO LIST 2>$null
        ''
        '=== HKLM RunOnce ==='
        & reg query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 2>$null
        '=== HKLM RunOnceEx ==='
        & reg query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnceEx' /s 2>$null
        '=== HKLM Run ==='
        & reg query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 2>$null
        '=== HKLM Winlogon ==='
        & reg query 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 2>$null
        '=== CBS RebootPending ==='
        & reg query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' 2>$null
        '=== Session Manager PendingFileRenameOperations ==='
        & reg query 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager' /v PendingFileRenameOperations 2>$null
        '=== ImageState ==='
        & reg query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' 2>$null
    } | Out-File "$FbDest\tasklist.txt" -Encoding UTF8 -EA SilentlyContinue
    Show-PhaseLabel -Idx $phase -Label 'Tasklist + registry' -Done
} catch {
    Show-PhaseLabel -Idx $phase -Label 'Tasklist + registry' -Warn
}
Update-ProgressBar -Current $phase

# Installed programs list (separate file, same phase slot)
try {
    & {
        '=== Installed programs (HKLM Uninstall) ==='
        Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -EA SilentlyContinue |
            Where-Object DisplayName |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
            Sort-Object DisplayName |
            Format-Table -AutoSize | Out-String -Width 200
        ''
        '=== Installed programs (HKLM WOW6432) ==='
        Get-ItemProperty 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -EA SilentlyContinue |
            Where-Object DisplayName |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
            Sort-Object DisplayName |
            Format-Table -AutoSize | Out-String -Width 200
    } | Out-File "$FbDest\installed-programs.txt" -Encoding UTF8 -EA SilentlyContinue
} catch { }

# Live system info (separate file, same phase slot)
try {
    & {
        '=== IP configuration ==='
        & ipconfig /all 2>$null
        ''
        '=== System information ==='
        & systeminfo 2>$null
        ''
        '=== Disk volumes ==='
        Get-Volume -EA SilentlyContinue | Format-Table -AutoSize | Out-String -Width 200
        ''
        '=== Environment ==='
        Get-ChildItem Env: | Sort-Object Name | Format-Table -AutoSize | Out-String -Width 200
    } | Out-File "$FbDest\sysinfo.txt" -Encoding UTF8 -EA SilentlyContinue
} catch { }

# ─── Phase 11: Payload SHA256 ─────────────────────────────────────────────────
$phase++
Start-PhaseSpin -Idx $phase -Label 'Payload SHA256'
try {
    & {
        '=== SHA256 on-disk payload ==='
        Get-ChildItem 'C:\Windows\Setup\FirstBase' -Filter '*.ps1' -File -EA SilentlyContinue |
            Get-FileHash -Algorithm SHA256 -EA SilentlyContinue | Format-List
        Get-ChildItem 'C:\Windows\Setup\FirstBase' -Filter '*.cmd' -File -EA SilentlyContinue |
            Get-FileHash -Algorithm SHA256 -EA SilentlyContinue | Format-List
        '=== Version banners ==='
        $iwulPath = 'C:\Windows\Setup\FirstBase\Invoke-WindowsUpdateLoop.ps1'
        if (Test-Path $iwulPath) {
            Get-Content $iwulPath -EA SilentlyContinue |
                Select-String '\$ScriptVersion\s*=' | Select-Object -First 1
        }
        $wuePath = 'C:\Windows\Setup\FirstBase\FirstBaseWuEngine.ps1'
        if (Test-Path $wuePath) {
            Get-Content $wuePath -EA SilentlyContinue |
                Select-String 'FbWuEngineVersion\s*=' | Select-Object -First 1
        }
    } | Out-File "$FbDest\disk-sha256.txt" -Encoding UTF8 -EA SilentlyContinue
    Show-PhaseLabel -Idx $phase -Label 'Payload SHA256' -Done
} catch {
    Show-PhaseLabel -Idx $phase -Label 'Payload SHA256' -Warn
}
Update-ProgressBar -Current $phase

# ─── Phase 12: CBS / DISM / SFC logs ─────────────────────────────────────────
$phase++
Start-PhaseSpin -Idx $phase -Label 'CBS / DISM / SFC logs'
try {
    $null = New-Item -ItemType Directory -Path "$FbDest\WindowsLogs" -Force -EA SilentlyContinue
    if (Test-Path 'C:\Windows\Logs\CBS\CBS.log') {
        Get-Content 'C:\Windows\Logs\CBS\CBS.log' -Tail 5000 -EA SilentlyContinue |
            Out-File "$FbDest\WindowsLogs\CBS-tail.log" -Encoding UTF8 -EA SilentlyContinue
    }
    if (Test-Path 'C:\Windows\Logs\DISM\dism.log') {
        Get-Content 'C:\Windows\Logs\DISM\dism.log' -Tail 5000 -EA SilentlyContinue |
            Out-File "$FbDest\WindowsLogs\dism-tail.log" -Encoding UTF8 -EA SilentlyContinue
    }
    Get-ChildItem 'C:\Windows\Logs\CBS\' -Filter 'CbsPersist_*.log' -EA SilentlyContinue |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination "$FbDest\WindowsLogs" -Force -EA SilentlyContinue }
    Show-PhaseLabel -Idx $phase -Label 'CBS / DISM / SFC logs' -Done
} catch {
    Show-PhaseLabel -Idx $phase -Label 'CBS / DISM / SFC logs' -Warn
}
Update-ProgressBar -Current $phase

# ─── Phase 13: Sysprep status ─────────────────────────────────────────────────
$phase++
Start-PhaseSpin -Idx $phase -Label 'Sysprep status'
try {
    & {
        '=== Sysprep image state ==='
        & reg query 'HKLM\SYSTEM\Setup\Status\SysprepStatus' /v GeneralizationState 2>$null
        & reg query 'HKLM\SYSTEM\Setup\Status\SysprepStatus' /v CleanupState 2>$null
        if (Test-Path 'C:\Windows\System32\sysprep\Sysprep_succeeded.tag') { 'Sysprep_succeeded.tag PRESENT' }
        if (Test-Path 'C:\Windows\System32\sysprep\Sysprep_failed.tag')    { 'Sysprep_failed.tag PRESENT' }
        & reg query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' /v ImageState 2>$null
        '=== InstallDate ==='
        & reg query 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' /v InstallDate 2>$null
        '=== System info ==='
        [pscustomobject]@{
            ComputerName   = $env:COMPUTERNAME
            LastBootUpTime = (Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue).LastBootUpTime
            OSVersion      = [Environment]::OSVersion.Version
        } | Format-List
    } | Out-File "$FbDest\sysprep-status.txt" -Encoding UTF8 -EA SilentlyContinue
    Show-PhaseLabel -Idx $phase -Label 'Sysprep status' -Done
} catch {
    Show-PhaseLabel -Idx $phase -Label 'Sysprep status' -Warn
}
Update-ProgressBar -Current $phase

# ─── Phase 14: Splash + preflight logs ───────────────────────────────────────
$phase++
Start-PhaseSpin -Idx $phase -Label 'Splash + preflight logs'
try {
    $null = New-Item -ItemType Directory -Path "$FbDest\Logs" -Force -EA SilentlyContinue
    $null = New-Item -ItemType Directory -Path "$FbDest\ProgramData-FirstBase" -Force -EA SilentlyContinue

    foreach ($sf in @(
        'splash-ui.log','splash-watcher.log','debug-hotkey-watcher.log','SetupComplete.log',
        'WU-oobe-sound-handoff-mirror.log','WU-oobe-sound-bootstrap.log','pre-oobe-scrub.log'
    )) {
        $sp = "C:\Windows\Setup\FirstBase\Logs\$sf"
        if (Test-Path -LiteralPath $sp) { Copy-Item -LiteralPath $sp -Destination "$FbDest\Logs\$sf" -Force -EA SilentlyContinue }
    }

    foreach ($sf in @(
        'splash-ui.log','WU-oobe-sound-handoff-mirror.log','WU-oobe-sound-bootstrap.log',
        'WU-oobe-sound-onlogon-arm.log','WU-oobe-operator-finalize-mirror.log'
    )) {
        $sp = "C:\ProgramData\FirstBase\$sf"
        if (Test-Path $sp) { Copy-Item -LiteralPath $sp -Destination "$FbDest\ProgramData-FirstBase\$sf" -Force -EA SilentlyContinue }
    }

    if (Test-Path 'X:\FirstBase-Preflight.log') {
        Copy-Item 'X:\FirstBase-Preflight.log' -Destination "$FbDest\FirstBase-Preflight.log" -Force -EA SilentlyContinue
    }

    Show-PhaseLabel -Idx $phase -Label 'Splash + preflight logs' -Done
} catch {
    Show-PhaseLabel -Idx $phase -Label 'Splash + preflight logs' -Warn
}
Update-ProgressBar -Current $phase

# =============================================================================
# ISSUE DESCRIPTION PROMPT
# =============================================================================
try {
    if ($script:FbDumpUi) { [System.Console]::SetCursorPosition(0, $script:SubRow + 2) }
} catch {}
Write-Host ''
Write-Host "  $($script:GREEN)All $($script:TotalPhases) phases complete.$($script:RESET)"
Write-Host ''
Write-Host "  $($script:DIM)============================================================$($script:RESET)"
Write-Host ''
$issueDesc = ''
if ($NoPrompt) {
    $issueDesc = [string]$IssueDescription
    if ([string]::IsNullOrWhiteSpace($issueDesc)) { $issueDesc = 'No description provided' }
    Write-Host "  $($script:DIM)Issue notes supplied by caller (no prompt).$($script:RESET)"
} else {
    $issueDesc = Read-Host '  Describe the issue (press Enter when done)'
}
Write-Host ''

# =============================================================================
# WRITE FirstBase-Issue.md
# =============================================================================
$issOutPath = Join-Path $FbDest 'FirstBase-Issue.md'
$dumpFiles = @()
try {
    $dumpFiles = @(Get-ChildItem -LiteralPath $FbDest -Recurse -File -Force -EA SilentlyContinue)
} catch { $dumpFiles = @() }
if ($NoPrompt -and (Test-Path -LiteralPath $issOutPath)) {
    Write-Host '  Kept existing FirstBase-Issue.md (notes from fb-im).'
} else {
    try {
        $dt    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $cn    = $env:COMPUTERNAME
        $files = $dumpFiles |
                 Sort-Object FullName |
                 ForEach-Object { '- ' + $_.FullName.Substring($FbDest.Length + 1).TrimStart('\') }
        $mdLines = @(
            '# FirstBase Diagnostic Report'
            ''
            "**Date:** $dt"
            "**Machine:** $cn"
            ''
            '**Issue Description:**'
            $issueDesc
            ''
            '## Logs Included'
        )
        $mdLines += $files
        [System.IO.File]::WriteAllLines($issOutPath, $mdLines, [System.Text.Encoding]::UTF8)
        Write-Host '  Saved: FirstBase-Issue.md'
    } catch {
        @(
            '# FirstBase Diagnostic Report'
            ''
            "**Date:** $(Get-Date)"
            "**Machine:** $env:COMPUTERNAME"
            ''
            '**Issue Description:**'
            $issueDesc
            ''
            '## Logs Included'
            '(file list unavailable)'
        ) | Out-File $issOutPath -Encoding UTF8 -EA SilentlyContinue
    }
}

$payloadFiles = @($dumpFiles | Where-Object { $_.Name -ne 'FirstBase-Issue.md' -and $_.Name -ne 'DUMP-SUMMARY.txt' })
$payloadCount = $payloadFiles.Count
$summaryLines = @(
    "Dest=$FbDest"
    "FileCount=$payloadCount"
    "Captured=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "HasConsole=$($script:FbDumpUi)"
)
try { [System.IO.File]::WriteAllLines((Join-Path $FbDest 'DUMP-SUMMARY.txt'), $summaryLines, [System.Text.Encoding]::UTF8) } catch {}

# =============================================================================
# SUMMARY SCREEN
# =============================================================================
Write-FBHeader
Write-Host ''
if ($payloadCount -le 0) {
    Write-Host "  $($script:RED)Dump copied 0 files. Collection failed.$($script:RESET)"
} else {
    Write-Host "  $($script:GREEN)Dump complete.$($script:RESET)"
}
Write-Host ''
Write-Host "  Folder   : $FbDest"
Write-Host "  Files    : $payloadCount"
Write-Host "  Issue MD : $FbDest\FirstBase-Issue.md"
Write-Host "  Finished : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ''
Write-Host '  Largest files (top 10):'
Write-Host ''
try {
    $top10 = $payloadFiles |
             Sort-Object Length -Descending |
             Select-Object -First 10 `
                 @{ N='Size(KB)'; E={ [int]($_.Length / 1KB) } },
                 @{ N='File';     E={ $_.FullName.Substring($FbDest.Length + 1) } }
    ($top10 | Format-Table -AutoSize | Out-String -Width 120).TrimEnd() | Write-Host
} catch { }
Write-Host ''
Write-Host "  $($script:DIM)============================================================$($script:RESET)"
Write-Host ''
Wait-FbDumpExitPrompt
if ($payloadCount -le 0) { exit 1 }
exit 0

