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

function Invoke-LwDriveHttpNodeScript {
    param(
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)][string[]] $ArgParts,
        [scriptblock] $OnJsonLine
    )
    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path -LiteralPath $ScriptPath)) {
        throw "drive-http: script missing at '$ScriptPath'"
    }
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
        if (-not [string]::IsNullOrWhiteSpace($errText)) {
            throw ("drive-http: Node script failed ({0})" -f $errText)
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
        [Parameter(Mandatory)][string] $FolderId,
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
        throw 'drive-http-support: support download script not found (set LONEWOLF_DRIVE_HTTP_SUPPORT_SCRIPT)'
    }
    New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null
    $nameCsv = ($Names -join ',')
    $argParts = @(
        (Format-LwDriveHttpWinArg $script),
        '--folder-id', (Format-LwDriveHttpWinArg $FolderId),
        '--dest', (Format-LwDriveHttpWinArg ($DestRoot.TrimEnd('\'))),
        '--names', (Format-LwDriveHttpWinArg $nameCsv),
        '--disk', '0'
    )
    Invoke-LwDriveHttpNodeScript -ScriptPath $script -ArgParts $argParts -OnJsonLine $OnJsonLine
}
