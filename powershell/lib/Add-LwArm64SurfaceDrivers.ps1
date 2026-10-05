# ARM64 Snapdragon / Surface driver inject shared by the USB builder and
# Stage-PreSplitImage.ps1. One path: DISM /Add-Driver /Recurse of the Surface
# folder (including qcpep). Inbox USB services are left as the image shipped them.

function Resolve-LwArm64SurfaceDriverDir {
    param([string] $RepoRoot = '')

    foreach ($candidate in @(
        'C:\SurfaceDrivers\SurfaceUpdate',
        'C:\Repos\Windows_Installation\UUP\25h2\WinPE-Drivers\SurfaceLaptop7\SurfaceUpdate'
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    $msiName = 'SurfaceLaptop7_ARM_Win11_26100_26.053.36539.0.msi'
    $msi = ''
    $msiCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $msiCandidates += (Join-Path $RepoRoot "drivers\$msiName")
    }
    if ($PSScriptRoot) {
        $msiCandidates += (Join-Path $PSScriptRoot "..\..\..\drivers\$msiName")
    }
    foreach ($candidate in $msiCandidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $msi = [System.IO.Path]::GetFullPath($candidate)
            break
        }
    }
    if (-not $msi) { return '' }

    $extract = Join-Path $env:TEMP 'LwSurfaceLaptop7-26100-26.053.36539.0'
    $existingInf = @(Get-ChildItem -LiteralPath $extract -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($existingInf.Count -eq 0) {
        if (Test-Path -LiteralPath $extract) {
            Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Force -Path $extract | Out-Null
        $proc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
            -ArgumentList @('/a', $msi, '/qn', "TARGETDIR=$extract") -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
            throw "FATAL: could not extract Surface driver MSI '$msi' (msiexec exit $($proc.ExitCode))"
        }
        $existingInf = @(Get-ChildItem -LiteralPath $extract -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($existingInf.Count -eq 0) {
            throw "FATAL: Surface driver MSI extracted to '$extract' but no .inf files were found"
        }
    }

    $named = @(Get-ChildItem -LiteralPath $extract -Recurse -Directory -Filter 'SurfaceUpdate' -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($named.Count -gt 0) { return $named[0].FullName }
    return [System.IO.Path]::GetFullPath($extract)
}

# Snapdragon Windows Updates and Snapdragon Quick Install only.
# QUICK-INSTALL-AMD64 and AMD64 must not match.
function Test-LwSnapdragonWorkflow {
    param([string] $WorkflowType)
    $a = ([string]$WorkflowType).ToUpperInvariant()
    $a = [regex]::Replace($a, '^(QUICK-INSTALL-|WIN-INSTALL-|LONEWOLF-)', '')
    return ($a -eq 'ARM64')
}

function Test-LwImageIndexIsArm64 {
    param($Image)
    $arch = ''
    try { $arch = [string]$Image.Architecture } catch { }
    return ($arch -match 'ARM64' -or $arch -eq '12')
}

# Recurse-inject the Surface set into an already-mounted image.
# Includes qcpep. Does not change inbox USB service start types.
function Invoke-LwDismHeartbeat {
    param(
        [Parameter(Mandatory)][string[]] $ArgumentList,
        [scriptblock] $Progress,
        [scriptblock] $Log,
        [int] $Floor = 0,
        [int] $Ceiling = 99
    )
    $g = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path $env:TEMP "LW-Dism-$g.out"
    $errFile = Join-Path $env:TEMP "LW-Dism-$g.err"
    $proc = Start-Process -FilePath dism.exe -ArgumentList $ArgumentList -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $proc.Handle
    $started = Get-Date
    $lastEmit = -1
    $lastLine = ''
    try {
        while (-not $proc.HasExited) {
            Start-Sleep -Seconds 1
            $pct = $null
            $line = ''
            if (Test-Path -LiteralPath $outFile) {
                try {
                    $text = [System.IO.File]::ReadAllText($outFile)
                    $inst = [regex]::Matches($text, 'Installing\s+(\d+)\s+of\s+(\d+)')
                    if ($inst.Count -gt 0) {
                        $m = $inst[$inst.Count - 1]
                        $n = [int]$m.Groups[1].Value
                        $d = [math]::Max([int]$m.Groups[2].Value, 1)
                        $pct = [int](100 * $n / $d)
                        $line = "Injecting Snapdragon drivers $n of $d"
                    } else {
                        $pm = [regex]::Matches($text, '(?m)(\d{1,3}(?:\.\d+)?)\s*%')
                        if ($pm.Count -gt 0) {
                            $pct = [int][math]::Min(99, [double]$pm[$pm.Count - 1].Groups[1].Value)
                        }
                    }
                } catch { }
            }
            if ($null -eq $pct) {
                $elapsed = ((Get-Date) - $started).TotalSeconds
                $pct = [int][math]::Min(90, 8 + (82 * (1 - [math]::Exp(-$elapsed / 120))))
            }
            $mapped = $Floor + [int](($Ceiling - $Floor) * ([math]::Min(100, $pct) / 100.0))
            $mapped = [math]::Max($Floor, [math]::Min($Ceiling, $mapped))
            if ($mapped -ne $lastEmit -and $Progress) {
                & $Progress $mapped
                $lastEmit = $mapped
            }
            if ($line -and $line -ne $lastLine -and $Log) {
                & $Log $line
                $lastLine = $line
            }
        }
        $proc.WaitForExit()
        $exit = $proc.ExitCode
        $cap = ''
        if (Test-Path -LiteralPath $outFile) { $cap += [System.IO.File]::ReadAllText($outFile) }
        if (Test-Path -LiteralPath $errFile) { $cap += [System.IO.File]::ReadAllText($errFile) }
        $successText = $cap -match 'The operation completed successfully'
        if ($null -eq $exit) {
            if (-not $successText) { throw "DISM failed (no exit code): $cap" }
        } elseif ($exit -ne 0 -and $exit -ne 3010) {
            throw "DISM failed (exit $exit): $cap"
        }
        if ($Progress) { & $Progress $Ceiling }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Add-LwArm64WinPeUsbHost {
    param(
        [Parameter(Mandatory)][string] $MountDir,
        [Parameter(Mandatory)][string] $DriverRoot,
        [scriptblock] $Progress,
        [scriptblock] $Log
    )
    if ([string]::IsNullOrWhiteSpace($DriverRoot) -or -not (Test-Path -LiteralPath $DriverRoot -PathType Container)) {
        throw "FATAL: ARM64 Surface driver folder not found: '$DriverRoot'"
    }
    $inf = @(Get-ChildItem -LiteralPath $DriverRoot -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue)
    if ($inf.Count -eq 0) {
        throw "FATAL: ARM64 Surface driver folder has no .inf files: '$DriverRoot'"
    }
    if ($Log) { & $Log ("Injecting Snapdragon drivers ({0} packages) from $DriverRoot" -f $inf.Count) }
    Invoke-LwDismHeartbeat -ArgumentList @(
        '/Image:' + $MountDir,
        '/Add-Driver',
        '/Driver:' + $DriverRoot,
        '/Recurse',
        '/English'
    ) -Progress $Progress -Log $Log -Floor 5 -Ceiling 99
}

function Test-LwArm64SurfaceDriversStamped {
    param([string] $SetDir)
    if ([string]::IsNullOrWhiteSpace($SetDir)) { return $false }
    $manPath = Join-Path $SetDir 'presplit-manifest.json'
    if (-not (Test-Path -LiteralPath $manPath)) { return $false }
    try {
        $m = Get-Content -Raw -LiteralPath $manPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch { return $false }
    if ($m.PSObject.Properties['surfaceDrivers'] -and $m.surfaceDrivers) { return $true }
    if ($m.PSObject.Properties['install'] -and $m.install -and
        $m.install.PSObject.Properties['surfaceDrivers'] -and $m.install.surfaceDrivers) {
        return $true
    }
    return $false
}

function Get-LwBootWimInjectSentinel {
    param(
        [Parameter(Mandatory)][string] $StartnetPath,
        [string] $DriverDir = ''
    )
    $hash = (Get-FileHash -LiteralPath $StartnetPath -Algorithm SHA256).Hash
    if (-not [string]::IsNullOrWhiteSpace($DriverDir)) {
        return ($hash + '|surface')
    }
    return $hash
}

function Add-LwArm64DriversToWritableWim {
    param(
        [Parameter(Mandatory)][string] $WimPath,
        [Parameter(Mandatory)][string] $DriverRoot,
        [scriptblock] $Log,
        [scriptblock] $Progress
    )
    $write = {
        param([string] $Message)
        if ($Log) { & $Log $Message }
    }
    $tick = {
        param([int] $Pct)
        if ($Progress) { & $Progress $Pct }
    }
    try { Set-ItemProperty -LiteralPath $WimPath -Name IsReadOnly -Value $false -ErrorAction Stop } catch { }
    Import-Module Dism -ErrorAction SilentlyContinue
    $images = @(Get-WindowsImage -ImagePath $WimPath -ErrorAction Stop)
    if ($images.Count -eq 0) { throw "FATAL: no indexes in '$WimPath'" }
    foreach ($img in $images) {
        if (-not (Test-LwImageIndexIsArm64 $img)) {
            throw ("FATAL: refusing to inject Snapdragon drivers into '{0}' index {1} architecture {2}. Driver injection is Snapdragon only." -f $WimPath, $img.ImageIndex, $img.Architecture)
        }
    }
    $n = [math]::Max($images.Count, 1)
    $i = 0
    foreach ($img in $images) {
        $idx = [int]$img.ImageIndex
        $spanStart = [int](100 * $i / $n)
        $spanEnd = [int](100 * ($i + 1) / $n)
        $mountDir = Join-Path $env:TEMP ('LWArmDrv_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $mounted = $false
        try {
            New-Item -ItemType Directory -Force -Path $mountDir | Out-Null
            & $write "Snapdragon drivers: mounting '$WimPath' index $idx"
            & $tick $spanStart
            try {
                Invoke-LwDismHeartbeat -ArgumentList @(
                    '/Mount-Image',
                    '/ImageFile:' + $WimPath,
                    '/Index:' + $idx,
                    '/MountDir:' + $mountDir
                ) -Progress $tick -Log $write -Floor $spanStart -Ceiling ($spanStart + [int](($spanEnd - $spanStart) * 0.25))
            } catch {
                throw "FATAL: DISM /Mount-Image failed on '$WimPath' index ${idx}: $($_.Exception.Message)"
            }
            $mounted = $true
            & $write "Snapdragon drivers: /Add-Driver /Recurse index $idx from $DriverRoot"
            Add-LwArm64WinPeUsbHost -MountDir $mountDir -DriverRoot $DriverRoot -Log $write -Progress {
                param($p)
                $lo = $spanStart + [int](($spanEnd - $spanStart) * 0.25)
                $hi = $spanStart + [int](($spanEnd - $spanStart) * 0.9)
                & $tick ($lo + [int](($hi - $lo) * ($p / 100.0)))
            }
            try {
                Invoke-LwDismHeartbeat -ArgumentList @(
                    '/Unmount-Image',
                    '/MountDir:' + $mountDir,
                    '/Commit'
                ) -Progress $tick -Log $write -Floor ($spanStart + [int](($spanEnd - $spanStart) * 0.9)) -Ceiling $spanEnd
            } catch {
                throw "FATAL: DISM /Unmount-Image /Commit failed on '$WimPath' index ${idx}: $($_.Exception.Message)"
            }
            $mounted = $false
            Start-Sleep -Seconds 2
        } finally {
            if ($mounted) {
                & dism.exe /Unmount-Image /MountDir:"$mountDir" /Discard 2>&1 | Out-Null
            }
            Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $i++
    }
}

function New-LwArm64InjectedInstallSources {
    param(
        [Parameter(Mandatory)][string] $DriverRoot,
        [Parameter(Mandatory)][string] $DestDir,
        [string] $SourceWim = '',
        [string] $SourceEsd = '',
        [string] $SourceSwmDir = '',
        [switch] $SplitForFat32,
        [int] $FileSizeMb = 3800,
        [string] $SplitLibPath = '',
        [scriptblock] $Log,
        [scriptblock] $Progress
    )
    $write = {
        param([string] $Message)
        if ($Log) { & $Log $Message }
    }
    if (Test-Path -LiteralPath $DestDir) {
        Remove-Item -LiteralPath $DestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $work = Join-Path $env:TEMP ('LW-Arm64Wim-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $workWim = Join-Path $work 'install.wim'
        if (-not [string]::IsNullOrWhiteSpace($SourceWim) -and (Test-Path -LiteralPath $SourceWim)) {
            & $write "ARM64 install image: copying install.wim to a writable copy"
            Copy-Item -LiteralPath $SourceWim -Destination $workWim -Force
        } elseif (-not [string]::IsNullOrWhiteSpace($SourceEsd) -and (Test-Path -LiteralPath $SourceEsd)) {
            & $write "ARM64 install image: exporting install.esd to a writable WIM"
            $exported = Export-LwInstallIndexesToWim -SourceFile $SourceEsd -DestWim $workWim -Log $write
            if (-not $exported) { throw "FATAL: install.esd export produced no WIM: $SourceEsd" }
        } elseif (-not [string]::IsNullOrWhiteSpace($SourceSwmDir) -and (Test-Path -LiteralPath (Join-Path $SourceSwmDir 'install.swm'))) {
            & $write "ARM64 install image: exporting install.swm set to a writable WIM"
            $swmFile = Join-Path $SourceSwmDir 'install.swm'
            $swmPattern = Join-Path $SourceSwmDir 'install*.swm'
            $exported = Export-LwInstallIndexesToWim -SourceFile $swmFile -DestWim $workWim -SwmPattern $swmPattern -Log $write
            if (-not $exported) { throw "FATAL: install.swm export produced no WIM: $SourceSwmDir" }
        } else {
            throw 'FATAL: ARM64 install-image inject has no install.wim, install.esd, or install.swm source'
        }
        if (-not (Test-Path -LiteralPath $workWim)) {
            throw "FATAL: writable install image was not created at '$workWim'"
        }
        Add-LwArm64DriversToWritableWim -WimPath $workWim -DriverRoot $DriverRoot -Log $Log -Progress $Progress
        if ($SplitForFat32) {
            if (-not (Get-Command -Name Split-LWImageForFat32 -ErrorAction SilentlyContinue)) {
                if ([string]::IsNullOrWhiteSpace($SplitLibPath) -or -not (Test-Path -LiteralPath $SplitLibPath)) {
                    throw "FATAL: Split-LWImageForFat32 is not loaded and SplitLibPath is missing"
                }
                . $SplitLibPath
            }
            $srcDir = Join-Path $work 'sources'
            New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
            Move-Item -LiteralPath $workWim -Destination (Join-Path $srcDir 'install.wim') -Force
            Split-LWImageForFat32 -SourceSourcesDir $srcDir -DestSourcesDir $DestDir -FileSizeMb $FileSizeMb -Emit $Log
        } else {
            Copy-Item -LiteralPath $workWim -Destination (Join-Path $DestDir 'install.wim') -Force
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Export-LwInstallIndexesToWim {
    param(
        [Parameter(Mandatory)][string] $SourceFile,
        [Parameter(Mandatory)][string] $DestWim,
        [string] $SwmPattern = '',
        [scriptblock] $Log
    )
    Import-Module Dism -ErrorAction SilentlyContinue
    $images = @()
    try { $images = @(Get-WindowsImage -ImagePath $SourceFile -ErrorAction Stop) } catch { $images = @() }
    if ($images.Count -eq 0) {
        $images = @([pscustomobject]@{ ImageIndex = 1 })
    }
    foreach ($img in $images) {
        $idx = [int]$img.ImageIndex
        if ($Log) { & $Log "ARM64 install image: exporting index $idx from $SourceFile" }
        $dismArgs = @(
            '/Export-Image',
            "/SourceImageFile:$SourceFile",
            "/SourceIndex:$idx",
            "/DestinationImageFile:$DestWim",
            '/Compress:max',
            '/CheckIntegrity'
        )
        if (-not [string]::IsNullOrWhiteSpace($SwmPattern)) {
            $dismArgs += "/SWMFile:$SwmPattern"
        }
        $out = & dism.exe @dismArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "FATAL: DISM /Export-Image failed (exit $LASTEXITCODE) index ${idx}: $($out -join ' | ')"
        }
    }
    return (Test-Path -LiteralPath $DestWim)
}
