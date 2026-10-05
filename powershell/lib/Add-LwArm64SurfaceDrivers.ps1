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

# Recurse-inject the Surface set into an already-mounted image.
# Includes qcpep. Does not change inbox USB service start types.
function Add-LwArm64WinPeUsbHost {
    param(
        [Parameter(Mandatory)][string] $MountDir,
        [Parameter(Mandatory)][string] $DriverRoot
    )
    if ([string]::IsNullOrWhiteSpace($DriverRoot) -or -not (Test-Path -LiteralPath $DriverRoot -PathType Container)) {
        throw "FATAL: ARM64 Surface driver folder not found: '$DriverRoot'"
    }
    $inf = @(Get-ChildItem -LiteralPath $DriverRoot -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($inf.Count -eq 0) {
        throw "FATAL: ARM64 Surface driver folder has no .inf files: '$DriverRoot'"
    }
    $out = & dism.exe /Image:"$MountDir" /Add-Driver /Driver:"$DriverRoot" /Recurse 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "FATAL: DISM /Add-Driver /Recurse failed (exit $LASTEXITCODE) on '$MountDir': $($out -join ' | ')"
    }
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
        [scriptblock] $Log
    )
    $write = {
        param([string] $Message)
        if ($Log) { & $Log $Message }
    }
    try { Set-ItemProperty -LiteralPath $WimPath -Name IsReadOnly -Value $false -ErrorAction Stop } catch { }
    Import-Module Dism -ErrorAction SilentlyContinue
    $images = @(Get-WindowsImage -ImagePath $WimPath -ErrorAction Stop)
    if ($images.Count -eq 0) { throw "FATAL: no indexes in '$WimPath'" }
    foreach ($img in $images) {
        $idx = [int]$img.ImageIndex
        $mountDir = Join-Path $env:TEMP ('LWArmDrv_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $mounted = $false
        try {
            New-Item -ItemType Directory -Force -Path $mountDir | Out-Null
            & $write "ARM64 install image: mounting '$WimPath' index $idx"
            $mountOut = & dism.exe /Mount-Image /ImageFile:"$WimPath" /Index:$idx /MountDir:"$mountDir" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "FATAL: DISM /Mount-Image failed (exit $LASTEXITCODE) on '$WimPath' index ${idx}: $($mountOut -join ' | ')"
            }
            $mounted = $true
            & $write "ARM64 install image: /Add-Driver /Recurse index $idx from $DriverRoot"
            Add-LwArm64WinPeUsbHost -MountDir $mountDir -DriverRoot $DriverRoot
            $unmountOut = & dism.exe /Unmount-Image /MountDir:"$mountDir" /Commit 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "FATAL: DISM /Unmount-Image /Commit failed (exit $LASTEXITCODE) on '$WimPath' index ${idx}: $($unmountOut -join ' | ')"
            }
            $mounted = $false
            Start-Sleep -Seconds 2
        } finally {
            if ($mounted) {
                & dism.exe /Unmount-Image /MountDir:"$mountDir" /Discard 2>&1 | Out-Null
            }
            Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
        }
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
        [scriptblock] $Log
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
        Add-LwArm64DriversToWritableWim -WimPath $workWim -DriverRoot $DriverRoot -Log $Log
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
