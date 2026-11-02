function Get-LwDriveHttpNodeRuntime {
    $node = $env:LONEWOLF_NODE
    if ([string]::IsNullOrWhiteSpace($node) -or -not (Test-Path -LiteralPath $node)) {
        $node = (Get-Command -Name node.exe -ErrorAction SilentlyContinue).Source
    }
    if ([string]::IsNullOrWhiteSpace($node)) {
        throw 'drive-http: Node runtime not found (set LONEWOLF_NODE or install Node.js)'
    }
    return $node
}

function Format-LwDriveHttpWinArg {
    # ProcessStartInfo quoting: a trailing \ before the closing " escapes the quote
    # (so --dest "E:\" swallows the rest of the command line). Double a final \.
    param([string] $Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value.EndsWith('\')) { $Value = $Value + '\' }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Format-LwDriveHttpNodeFailureText {
    # Prefer a short operator-facing line over a full Node stack dump.
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text.Trim()
    if ($t -match '(?im)Cannot find module\s+[''"]?([^''"\r\n]+)') {
        $mod = $Matches[1].Trim()
        return ("missing module '{0}' - Drive HTTP packaging is incomplete; reinstall or update the launcher" -f $mod)
    }
    if ($t -match '(?im)^Error:\s*(.+)$') {
        return ($Matches[1].Trim())
    }
    $first = ($t -split '[\r\n]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ($first -and $first.Length -gt 240) { return ($first.Substring(0, 237) + '...') }
    return [string]$first
}

function Test-LwDriveHttpScriptLayout {
    # Packaged installs need resources/scripts/*.js plus resources/launcher/*.js.
    param([Parameter(Mandatory)][string] $ScriptPath)
    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path -LiteralPath $ScriptPath)) {
        return "drive-http: script missing at '$ScriptPath'"
    }
    $scriptsDir = Split-Path -Parent $ScriptPath
    $loadHelper = Join-Path $scriptsDir 'drive-http-load-launcher.js'
    $launcherDir = Join-Path (Split-Path -Parent $scriptsDir) 'launcher'
    $srcLauncher = Join-Path (Split-Path -Parent $scriptsDir) 'src\launcher'
    $need = @('driveHttpMedia.js', 'devDriveStaging.js', 'windowsEdition.js')
    $ok = $true
    foreach ($leaf in $need) {
        $a = Join-Path $launcherDir $leaf
        $b = Join-Path $srcLauncher $leaf
        if (-not (Test-Path -LiteralPath $a) -and -not (Test-Path -LiteralPath $b)) { $ok = $false; break }
    }
    if (-not $ok) {
        return 'drive-http: launcher modules missing next to the Drive HTTP scripts (need resources/launcher or src/launcher). Reinstall or update the launcher.'
    }
    if (-not (Test-Path -LiteralPath $loadHelper)) {
        # Older installs without the helper still work if scripts use hard-coded ../src paths;
        # packaged layouts without the helper + without src/launcher already failed above.
        $pkgProbe = Join-Path $scriptsDir '..\src\launcher\driveHttpMedia.js'
        if (-not (Test-Path -LiteralPath $pkgProbe) -and -not (Test-Path -LiteralPath (Join-Path $launcherDir 'driveHttpMedia.js'))) {
            return 'drive-http: drive-http-load-launcher.js is missing from resources/scripts. Reinstall or update the launcher.'
        }
    }
    return ''
}

function Invoke-LwDriveHttpNodeScript {
    param(
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)][string[]] $ArgParts,
        [scriptblock] $OnJsonLine
    )
    $layoutErr = Test-LwDriveHttpScriptLayout -ScriptPath $ScriptPath
    if (-not [string]::IsNullOrWhiteSpace($layoutErr)) { throw $layoutErr }
    $node = Get-LwDriveHttpNodeRuntime
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node
    $psi.Arguments = (($ArgParts | ForEach-Object { $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    # Touching EnvironmentVariables keeps the inherited env and lets us force Electron-as-Node.
    if ($env:ELECTRON_RUN_AS_NODE) {
        $psi.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LONEWOLF_NODE)) {
        $psi.EnvironmentVariables['LONEWOLF_NODE'] = $env:LONEWOLF_NODE
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) { throw 'drive-http: failed to start Node process' }

    # Drain stderr async so a full stderr buffer cannot deadlock stdout ReadLine.
    $errTask = $proc.StandardError.ReadToEndAsync()

    $lastErrorMsg = ''
    while ($true) {
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { break }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trim = $line.TrimStart()
        if ($trim.StartsWith('{')) {
            try {
                $obj = $trim | ConvertFrom-Json -ErrorAction Stop
                if ($obj.event -eq 'error' -and $obj.message) {
                    $lastErrorMsg = [string]$obj.message
                }
            } catch { }
        }
        if ($OnJsonLine) { & $OnJsonLine $line }
    }
    $proc.WaitForExit()
    $errText = ''
    try { $errText = ([string]$errTask.Result).Trim() } catch { }

    if ($proc.ExitCode -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($lastErrorMsg)) {
            throw $lastErrorMsg
        }
        $short = Format-LwDriveHttpNodeFailureText $errText
        if (-not [string]::IsNullOrWhiteSpace($short)) {
            throw ("drive-http: Node script failed ({0})" -f $short)
        }
        throw ("drive-http: Node script failed (exit {0})" -f $proc.ExitCode)
    }
}

function Invoke-LwDriveHttpMediaToVolume {
    param(
        [Parameter(Mandatory)][int] $DiskNumber,
        [Parameter(Mandatory)][string] $DestRoot,
        [Parameter(Mandatory)][string] $FolderId,
        [Parameter(Mandatory)][string] $Arch,
        [string] $Edition = 'Pro',
        [scriptblock] $OnJsonLine
    )
    if ([string]::IsNullOrWhiteSpace($DestRoot)) { throw 'drive-http: DestRoot is empty' }
    $script = $env:LONEWOLF_DRIVE_HTTP_SCRIPT
    if ([string]::IsNullOrWhiteSpace($script) -or -not (Test-Path -LiteralPath $script)) {
        throw 'drive-http: LONEWOLF_DRIVE_HTTP_SCRIPT is not set or script is missing'
    }
    # No trailing slash: "E:\" breaks ProcessStartInfo argument quoting.
    $dest = $DestRoot.TrimEnd('\')
    $ed = if ($Edition -match '^(?i)home$') { 'Home' } else { 'Pro' }
    $argParts = @(
        (Format-LwDriveHttpWinArg $script),
        '--folder-id', (Format-LwDriveHttpWinArg $FolderId),
        '--dest', (Format-LwDriveHttpWinArg $dest),
        '--arch', (Format-LwDriveHttpWinArg $Arch),
        '--edition', (Format-LwDriveHttpWinArg $ed),
        '--disk', ('{0}' -f $DiskNumber)
    )
    $warm = $env:LONEWOLF_DRIVE_WARM_MANIFEST
    if (-not [string]::IsNullOrWhiteSpace($warm) -and (Test-Path -LiteralPath $warm)) {
        $argParts += @('--warm-manifest', (Format-LwDriveHttpWinArg $warm))
    }
    Invoke-LwDriveHttpNodeScript -ScriptPath $script -ArgParts $argParts -OnJsonLine $OnJsonLine
}

function Invoke-LwDriveHttpSupportFolders {
    param(
        [Parameter(Mandatory)][string] $DestRoot,
        [string] $FolderId = '1xxCL3FrNjKOPCOB_zWUC2NJLKCfKry8d',
        [string] $OcsFolderId = '1Nmit70WgD0nov4mQs-XWdTRRkHCrRjbP',
        [string] $DriversFolderId = '1ovDOCBkqKf7k5esZ_dm2o4aOkc_VA6Dg',
        [string[]] $Names = @('WinPE-OCs', 'WinPE-Drivers'),
        [scriptblock] $OnJsonLine
    )
    if ([string]::IsNullOrWhiteSpace($DestRoot)) { throw 'drive-http-support: DestRoot is empty' }
    $script = $env:LONEWOLF_DRIVE_HTTP_SUPPORT_SCRIPT
    if ([string]::IsNullOrWhiteSpace($script) -or -not (Test-Path -LiteralPath $script)) {
        $pkgScript = $env:LONEWOLF_DRIVE_HTTP_SCRIPT
        if (-not [string]::IsNullOrWhiteSpace($pkgScript)) {
            $candidate = Join-Path (Split-Path -Parent $pkgScript) 'drive-http-support-to-dir.js'
            if (Test-Path -LiteralPath $candidate) { $script = $candidate }
        }
    }
    if ([string]::IsNullOrWhiteSpace($script) -or -not (Test-Path -LiteralPath $script)) {
        # Destage checkout: scripts\ next to src\powershell\lib → ../../scripts
        $hereLib = $PSScriptRoot
        if (-not [string]::IsNullOrWhiteSpace($hereLib)) {
            $candidate = Join-Path (Split-Path -Parent (Split-Path -Parent $hereLib)) 'scripts\drive-http-support-to-dir.js'
            if (Test-Path -LiteralPath $candidate) { $script = $candidate }
        }
    }
    if ([string]::IsNullOrWhiteSpace($script) -or -not (Test-Path -LiteralPath $script)) {
        throw 'drive-http-support: support download script not found (set LONEWOLF_DRIVE_HTTP_SUPPORT_SCRIPT)'
    }
    New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null
    $nameCsv = ($Names -join ',')
    $fid = if (-not [string]::IsNullOrWhiteSpace($FolderId)) { $FolderId } else { '1xxCL3FrNjKOPCOB_zWUC2NJLKCfKry8d' }
    $argParts = @(
        (Format-LwDriveHttpWinArg $script),
        '--folder-id', (Format-LwDriveHttpWinArg $fid),
        '--dest', (Format-LwDriveHttpWinArg ($DestRoot.TrimEnd('\'))),
        '--names', (Format-LwDriveHttpWinArg $nameCsv),
        '--disk', '0'
    )
    if (-not [string]::IsNullOrWhiteSpace($OcsFolderId)) {
        $argParts += @('--ocs-folder-id', (Format-LwDriveHttpWinArg $OcsFolderId))
    }
    if (-not [string]::IsNullOrWhiteSpace($DriversFolderId)) {
        $argParts += @('--drivers-folder-id', (Format-LwDriveHttpWinArg $DriversFolderId))
    }
    Invoke-LwDriveHttpNodeScript -ScriptPath $script -ArgParts $argParts -OnJsonLine $OnJsonLine
}

function Ensure-LwDriveHttpWpeOcRoot {
    <#
    .SYNOPSIS
      When HQ WinPE-OCs is missing, download the public Drive WinPE-OCs folder into DestRoot\WinPE-OCs.
    #>
    param(
        [Parameter(Mandatory)][string] $DestRoot,
        [string] $Arch = 'AMD64',
        [scriptblock] $Log
    )
    if ([string]::IsNullOrWhiteSpace($DestRoot)) { return '' }
    $ocRoot = Join-Path $DestRoot.TrimEnd('\') 'WinPE-OCs'
    $archKey = if ($Arch -match '(?i)ARM64') { 'ARM64' } else { 'AMD64' }
    if ((Get-Command -Name Test-LwWpeOcRootHasArch -ErrorAction SilentlyContinue) -and
        (Test-LwWpeOcRootHasArch $ocRoot)) {
        return $ocRoot
    }
    if (Test-Path -LiteralPath (Join-Path $ocRoot $archKey)) { return $ocRoot }
    if (-not (Get-Command -Name Invoke-LwDriveHttpSupportFolders -ErrorAction SilentlyContinue)) {
        return ''
    }
    if ($Log) { & $Log "drive-http-support: fetching WinPE-OCs from Google Drive into $ocRoot" }
    try {
        Invoke-LwDriveHttpSupportFolders -DestRoot $DestRoot -Names @('WinPE-OCs') -OnJsonLine {
            param($line)
            if (-not $Log -or [string]::IsNullOrWhiteSpace($line)) { return }
            try {
                $ev = $line | ConvertFrom-Json -ErrorAction Stop
                if ($ev.message) { & $Log ([string]$ev.message) }
            } catch {
                & $Log ([string]$line)
            }
        }
    } catch {
        if ($Log) { & $Log ("drive-http-support: WinPE-OCs download skipped ($($_.Exception.Message))") }
        return ''
    }
    if ((Get-Command -Name Test-LwWpeOcRootHasArch -ErrorAction SilentlyContinue) -and
        (Test-LwWpeOcRootHasArch $ocRoot)) {
        return $ocRoot
    }
    if (Test-Path -LiteralPath (Join-Path $ocRoot $archKey)) { return $ocRoot }
    return ''
}

function Test-LwWinPeDriversRootHasPackages {
    param([string] $Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    $inf = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    return ($inf.Count -gt 0)
}

function Ensure-LwDriveHttpWinPeDriversRoot {
    <#
    .SYNOPSIS
      When HQ and local ShareRoot lack WinPE-Drivers packages, download the public Drive WinPE-Drivers folder into DestRoot\WinPE-Drivers.
    #>
    param(
        [Parameter(Mandatory)][string] $DestRoot,
        [scriptblock] $Log
    )
    if ([string]::IsNullOrWhiteSpace($DestRoot)) { return '' }
    $driverRoot = Join-Path $DestRoot.TrimEnd('\') 'WinPE-Drivers'
    if (Test-LwWinPeDriversRootHasPackages -Root $driverRoot) { return $driverRoot }
    if (-not (Get-Command -Name Invoke-LwDriveHttpSupportFolders -ErrorAction SilentlyContinue)) {
        return ''
    }
    if ($Log) { & $Log 'drive-http-support: fetching WinPE-Drivers from Google Drive...' }
    try {
        Invoke-LwDriveHttpSupportFolders -DestRoot $DestRoot -Names @('WinPE-Drivers') -OnJsonLine {
            param($line)
            if (-not $Log -or [string]::IsNullOrWhiteSpace($line)) { return }
            try {
                $ev = $line | ConvertFrom-Json -ErrorAction Stop
                if ($ev.message) { & $Log ([string]$ev.message) }
            } catch {
                & $Log ([string]$line)
            }
        }
    } catch {
        if ($Log) { & $Log ("drive-http-support: WinPE-Drivers download skipped ($($_.Exception.Message))") }
        return ''
    }
    if (Test-LwWinPeDriversRootHasPackages -Root $driverRoot) { return $driverRoot }
    return ''
}

function Invoke-LwDriveHttpWinPeUiZip {
    # Download WinPeUi-<ARCH>.zip from Warehouse - Imaging > WinPEUI (Drive staging child).
    param(
        [Parameter(Mandatory)][string] $DestPath,
        [Parameter(Mandatory)][string] $FileName,
        [string] $FolderId = '',
        [string] $ChildFolderName = 'WinPEUI',
        [scriptblock] $OnJsonLine
    )
    if ([string]::IsNullOrWhiteSpace($DestPath)) { throw 'drive-http-winpeui: DestPath is empty' }
    if ([string]::IsNullOrWhiteSpace($FileName)) { throw 'drive-http-winpeui: FileName is empty' }
    $script = $env:LONEWOLF_DRIVE_HTTP_WINPEUI_SCRIPT
    if ([string]::IsNullOrWhiteSpace($script) -or -not (Test-Path -LiteralPath $script)) {
        $pkgScript = $env:LONEWOLF_DRIVE_HTTP_SCRIPT
        if (-not [string]::IsNullOrWhiteSpace($pkgScript)) {
            $candidate = Join-Path (Split-Path -Parent $pkgScript) 'drive-http-winpeui-zip.js'
            if (Test-Path -LiteralPath $candidate) { $script = $candidate }
        }
    }
    if ([string]::IsNullOrWhiteSpace($script) -or -not (Test-Path -LiteralPath $script)) {
        throw 'drive-http-winpeui: download script not found (set LONEWOLF_DRIVE_HTTP_WINPEUI_SCRIPT)'
    }
    $parent = Split-Path -Parent $DestPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $fid = if (-not [string]::IsNullOrWhiteSpace($FolderId)) { $FolderId } else { '1xxCL3FrNjKOPCOB_zWUC2NJLKCfKry8d' }
    $child = if (-not [string]::IsNullOrWhiteSpace($ChildFolderName)) { $ChildFolderName } else { 'WinPEUI' }
    $argParts = @(
        (Format-LwDriveHttpWinArg $script),
        '--folder-id', (Format-LwDriveHttpWinArg $fid),
        '--child-folder', (Format-LwDriveHttpWinArg $child),
        '--dest', (Format-LwDriveHttpWinArg ($DestPath.TrimEnd('\'))),
        '--file-name', (Format-LwDriveHttpWinArg $FileName),
        '--disk', '0'
    )
    Invoke-LwDriveHttpNodeScript -ScriptPath $script -ArgParts $argParts -OnJsonLine $OnJsonLine
}
