# ARM64 driver inject shared by the USB builder. WinPE only.
# DISM /Add-Driver /Recurse of <ShareRoot>\WinPE-Drivers.
# HQ share root is \\WIN-HQ5JDEACV3S\Images\FB Image Creation.

function Resolve-LwArm64DriverDir {
    param([string] $ShareRoot = '')
    $base = $ShareRoot
    if ([string]::IsNullOrWhiteSpace($base)) {
        if (Get-Command -Name Get-LwHqShareRoot -ErrorAction SilentlyContinue) {
            $base = Get-LwHqShareRoot
        } else {
            $base = '\\WIN-HQ5JDEACV3S\Images\FB Image Creation'
        }
    }
    $root = Join-Path $base 'WinPE-Drivers'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return '' }
    $inf = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($inf.Count -eq 0) { return '' }
    return $root
}

# Snapdragon Windows Updates and Snapdragon Quick Install only.
# QUICK-INSTALL-AMD64 and AMD64 must not match.
function Test-LwSnapdragonWorkflow {
    param([string] $WorkflowType)
    $a = ([string]$WorkflowType).ToUpperInvariant()
    $a = [regex]::Replace($a, '^(QUICK-INSTALL-|WIN-INSTALL-|LONEWOLF-)', '')
    return ($a -eq 'ARM64')
}

function Get-LwImageArchitectureText {
    param($Image)
    if ($null -eq $Image) { return '' }
    if ($Image -is [string]) { return $Image.Trim() }
    $prop = $Image.PSObject.Properties['Architecture']
    if (-not $prop -or $null -eq $prop.Value) { return '' }
    return ([string]$prop.Value).Trim()
}

# Normalize DISM / WIM architecture tokens.
# ARM64 text, PROCESSOR_ARCHITECTURE_ARM64 (12), and IMAGE_FILE_MACHINE_ARM64 (0xAA64 / 43620) pass.
# AMD64, x64, and PROCESSOR_ARCHITECTURE_AMD64 (9) do not.
function Test-LwImageIndexIsArm64 {
    param($Image)
    $arch = Get-LwImageArchitectureText $Image
    if ([string]::IsNullOrWhiteSpace($arch)) { return $false }
    if ($arch -match '^(?i)0x([0-9A-Fa-f]+)$') {
        try { $arch = [string]([Convert]::ToUInt32($Matches[1], 16)) } catch { return $false }
    }
    if ($arch -match '^(?i)ARM64$') { return $true }
    if ($arch -eq '12') { return $true }
    if ($arch -eq '43620') { return $true }
    return $false
}

function Get-LwArm64ArchitectureLogValue {
    param([string] $Architecture)
    $arch = ([string]$Architecture).Trim()
    if ($arch -match '^(?i)ARM64$') { return 'ARM64' }
    return ('ARM64 ({0})' -f $arch)
}

# install.wim XML <ARCH> for one IMAGE INDEX. Blank when the resource is missing or compressed.
function Get-LwWimXmlArchitecture {
    param(
        [Parameter(Mandatory)][string] $WimPath,
        [Parameter(Mandatory)][int] $Index
    )
    $fs = [System.IO.File]::Open($WimPath, 'Open', 'Read', 'ReadWrite')
    try {
        $hdr = New-Object byte[] 208
        $n = $fs.Read($hdr, 0, $hdr.Length)
        if ($n -lt 96) { return '' }
        $magic = [System.Text.Encoding]::ASCII.GetString($hdr, 0, 5)
        if ($magic -ne 'MSWIM') { return '' }
        $xmlSizeFlags = [BitConverter]::ToUInt64($hdr, 72)
        $xmlOffset = [BitConverter]::ToInt64($hdr, 80)
        $flags = $xmlSizeFlags -shr 56
        $size = [int]($xmlSizeFlags -band 0x00FFFFFFFFFFFFFF)
        # 0x04 = compressed. Metadata (0x02) is still plain XML.
        if (($flags -band 0x04) -ne 0) { return '' }
        if ($xmlOffset -le 0 -or $size -le 0 -or $size -gt 20MB) { return '' }
        $fs.Position = $xmlOffset
        $buf = New-Object byte[] $size
        $got = 0
        while ($got -lt $buf.Length) {
            $r = $fs.Read($buf, $got, $buf.Length - $got)
            if ($r -le 0) { break }
            $got += $r
        }
        if ($got -lt 2) { return '' }
        $xmlText = $null
        if ($buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) {
            $xmlText = [System.Text.Encoding]::Unicode.GetString($buf, 0, $got)
        } elseif ($buf[0] -eq 0x3C) {
            $xmlText = [System.Text.Encoding]::UTF8.GetString($buf, 0, $got)
        } else {
            return ''
        }
        $image = [regex]::Match($xmlText, ('<IMAGE\s+INDEX\s*=\s*"' + $Index + '"[\s\S]*?</IMAGE>'))
        if (-not $image.Success) { return '' }
        $arch = [regex]::Match($image.Value, '<ARCH>\s*([^<]+?)\s*</ARCH>')
        if (-not $arch.Success) { return '' }
        return $arch.Groups[1].Value.Trim()
    } finally {
        $fs.Dispose()
    }
}

# Quote a DISM option value for a single process argument string.
# Quotes wrap the value only: /ImageFile:"C:\path\install.wim"
# A trailing backslash is doubled so it does not escape the closing quote.
function Format-LwDismQuotedValue {
    param([string] $Value)
    if ($null -eq $Value) { $Value = '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }
        if ($ch -eq '"') {
            if ($backslashes -gt 0) { [void]$sb.Append(('\' * ($backslashes * 2))) }
            [void]$sb.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$sb.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$sb.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$sb.Append(('\' * ($backslashes * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Windows PowerShell @() binds the comma operator before +, so
# '/ImageFile:' + $Path is two elements (/ImageFile: and the path).
# Start-Process then joins them with a space and DISM exits 87.
# Rejoin that split, then pass one argument string. Quote the value only:
# /ImageFile:"C:\path\install.wim" — no space after the colon.
function ConvertTo-LwDismArgumentLine {
    param([Parameter(Mandatory)][string[]] $ArgumentList)
    $raw = @($ArgumentList)
    $parts = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $raw.Count; $i++) {
        $text = [string]$raw[$i]
        if ([string]::IsNullOrEmpty($text)) { continue }
        if ($text -match '^(/[^:="\s]+):$' -and ($i + 1) -lt $raw.Count) {
            $next = [string]$raw[$i + 1]
            if (-not [string]::IsNullOrEmpty($next) -and $next -notmatch '^/') {
                $text = $text + $next
                $i++
            }
        }
        if ($text -match '^(/[^:="\s]+):(.*)$') {
            $switchName = $Matches[1]
            $value = $Matches[2]
            $quote = ($value -match '[\s\\"]') -or ($value.Length -eq 0)
            if ($quote) {
                [void]$parts.Add(('{0}:{1}' -f $switchName, (Format-LwDismQuotedValue $value)))
            } else {
                [void]$parts.Add(('{0}:{1}' -f $switchName, $value))
            }
        } else {
            [void]$parts.Add($text)
        }
    }
    return ($parts -join ' ')
}

function Get-LwDismIndexArchitectureReport {
    param(
        [Parameter(Mandatory)][string] $WimPath,
        [Parameter(Mandatory)][int] $Index
    )
    $id = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path $env:TEMP "LW-WimInfo-$id.out"
    $errFile = Join-Path $env:TEMP "LW-WimInfo-$id.err"
    try {
        $argumentLine = ConvertTo-LwDismArgumentLine -ArgumentList @(
            '/Get-WimInfo',
            ('/WimFile:' + $WimPath),
            ('/Index:' + $Index),
            '/English'
        )
        $proc = Start-Process -FilePath dism.exe -ArgumentList $argumentLine -NoNewWindow -PassThru -Wait -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $cap = ''
        if (Test-Path -LiteralPath $outFile) { $cap += [System.IO.File]::ReadAllText($outFile) }
        if (Test-Path -LiteralPath $errFile) {
            $errText = [System.IO.File]::ReadAllText($errFile)
            if (-not [string]::IsNullOrWhiteSpace($errText)) {
                if ($cap -and -not $cap.EndsWith("`n")) { $cap += "`n" }
                $cap += $errText
            }
        }
        $arch = ''
        if ($cap -match '(?m)^\s*Architecture\s*:\s*(\S+)') { $arch = $Matches[1].Trim() }
        $exit = $null
        if ($proc) { $exit = $proc.ExitCode }
        return [pscustomobject]@{ Architecture = $arch; ExitCode = $exit; Output = $cap.Trim() }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# Index-specific architecture. The no-Index list object has no Architecture property.
# A failed query throws. An empty result is not treated as AMD64 and is not success.
function Resolve-LwImageIndexArchitecture {
    param(
        [Parameter(Mandatory)][string] $WimPath,
        [Parameter(Mandatory)][int] $Index
    )
    $detailError = $null
    $arch = ''
    try {
        $detail = Get-WindowsImage -ImagePath $WimPath -Index $Index -ErrorAction Stop
        $arch = Get-LwImageArchitectureText $detail
    } catch {
        $detailError = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($detailError)) { $detailError = $_.ToString() }
    }
    if (-not [string]::IsNullOrWhiteSpace($detailError)) {
        throw ("FATAL: could not read architecture for '{0}' index {1}: {2}" -f $WimPath, $Index, $detailError.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($arch)) { return $arch }

    $xmlError = $null
    try { $arch = Get-LwWimXmlArchitecture -WimPath $WimPath -Index $Index } catch { $xmlError = $_.Exception.Message }
    if (-not [string]::IsNullOrWhiteSpace($arch)) { return $arch.Trim() }

    $dism = $null
    $dismError = $null
    try { $dism = Get-LwDismIndexArchitectureReport -WimPath $WimPath -Index $Index } catch { $dismError = $_.Exception.Message }
    if ($dism -and -not [string]::IsNullOrWhiteSpace([string]$dism.Architecture)) {
        return ([string]$dism.Architecture).Trim()
    }

    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add('Get-WindowsImage -Index returned no Architecture value.')
    if ($xmlError) { [void]$parts.Add("WIM XML read failed: $xmlError") }
    if ($dismError) { [void]$parts.Add("DISM /Get-WimInfo failed: $dismError") }
    if ($dism) {
        $exitText = 'unknown'
        if ($null -ne $dism.ExitCode) { $exitText = [string]$dism.ExitCode }
        [void]$parts.Add("DISM /Get-WimInfo exit $exitText")
        if (-not [string]::IsNullOrWhiteSpace([string]$dism.Output)) {
            $out = [string]$dism.Output
            if ($out.Length -gt 2000) { $out = $out.Substring(0, 2000) }
            [void]$parts.Add($out)
        }
    }
    throw ("FATAL: could not read architecture for '{0}' index {1}: {2}" -f $WimPath, $Index, ($parts -join ' '))
}

# Recurse-inject the WinPE-Drivers tree into an already-mounted image.
# Does not change inbox USB service start types.
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
    # One string, not a string[]. Callers still pass $callerLog / $callerProgress.
    $argumentLine = ConvertTo-LwDismArgumentLine -ArgumentList $ArgumentList
    if ($Log) { & $Log $argumentLine }
    $proc = Start-Process -FilePath dism.exe -ArgumentList $argumentLine -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
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
                        $line = "Injecting ARM64 drivers $n of $d"
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

function Add-LwArm64DriversToMountedImage {
    param(
        [Parameter(Mandatory)][string] $MountDir,
        [Parameter(Mandatory)][string] $DriverRoot,
        [scriptblock] $Progress,
        [scriptblock] $Log
    )
    if ([string]::IsNullOrWhiteSpace($DriverRoot) -or -not (Test-Path -LiteralPath $DriverRoot -PathType Container)) {
        throw "FATAL: ARM64 driver folder not found: '$DriverRoot'"
    }
    $inf = @(Get-ChildItem -LiteralPath $DriverRoot -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue)
    if ($inf.Count -eq 0) {
        throw "FATAL: ARM64 driver folder has no .inf files: '$DriverRoot'"
    }
    if ($Log) { & $Log ("Injecting ARM64 drivers ({0} packages) from $DriverRoot" -f $inf.Count) }
    Invoke-LwDismHeartbeat -ArgumentList @(
        ('/Image:' + $MountDir),
        '/Add-Driver',
        ('/Driver:' + $DriverRoot),
        '/Recurse',
        '/English'
    ) -Progress $Progress -Log $Log -Floor 5 -Ceiling 99
}

function Test-LwManifestArm64DriverFlag {
    param($Manifest, [string] $Name)
    if (-not $Manifest) { return $false }
    if ($Manifest.PSObject.Properties[$Name] -and $Manifest.$Name) { return $true }
    if ($Manifest.PSObject.Properties['install'] -and $Manifest.install -and
        $Manifest.install.PSObject.Properties[$Name] -and $Manifest.install.$Name) {
        return $true
    }
    return $false
}

# Current blanket stamp. A Surface-only manifest does not count.
function Test-LwArm64DriversStamped {
    param([string] $SetDir)
    if ([string]::IsNullOrWhiteSpace($SetDir)) { return $false }
    $manPath = Join-Path $SetDir 'presplit-manifest.json'
    if (-not (Test-Path -LiteralPath $manPath)) { return $false }
    try {
        $m = Get-Content -Raw -LiteralPath $manPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch { return $false }
    return (Test-LwManifestArm64DriverFlag -Manifest $m -Name 'arm64Drivers')
}

# ARM64 driver sets must not be reused for Intel/AMD. Legacy surfaceDrivers still counts.
function Test-LwPreSplitHasArm64Drivers {
    param($Manifest)
    if (Test-LwManifestArm64DriverFlag -Manifest $Manifest -Name 'arm64Drivers') { return $true }
    return (Test-LwManifestArm64DriverFlag -Manifest $Manifest -Name 'surfaceDrivers')
}

function Get-LwBootWimInjectSentinel {
    param(
        [Parameter(Mandatory)][string] $StartnetPath,
        [string] $DriverDir = ''
    )
    $hash = (Get-FileHash -LiteralPath $StartnetPath -Algorithm SHA256).Hash
    if (-not [string]::IsNullOrWhiteSpace($DriverDir)) {
        return ($hash + '|arm64')
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
    # PowerShell resolves scriptblock variables dynamically. A wrapper that
    # reads $Log or $Progress re-enters itself when Invoke-LwDismHeartbeat or
    # Add-LwArm64DriversToMountedImage invokes it, because those functions use the same
    # parameter names. That call-depth overflow was reported as a DISM mount
    # failure. Keep the caller's callbacks and invoke them directly.
    $callerLog = $Log
    $callerProgress = $Progress
    try { Set-ItemProperty -LiteralPath $WimPath -Name IsReadOnly -Value $false -ErrorAction Stop } catch { }
    Import-Module Dism -ErrorAction SilentlyContinue
    try {
        $images = @(Get-WindowsImage -ImagePath $WimPath -ErrorAction Stop)
    } catch {
        $listError = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($listError)) { $listError = $_.ToString() }
        throw ("FATAL: could not read image indexes for '{0}': {1}" -f $WimPath, $listError.Trim())
    }
    if ($images.Count -eq 0) { throw "FATAL: no indexes in '$WimPath'" }
    foreach ($img in $images) {
        $idx = 0
        try { $idx = [int]$img.ImageIndex } catch {
            throw ("FATAL: could not read architecture for '{0}': image index is missing ({1})" -f $WimPath, $_.Exception.Message)
        }
        # List results omit Architecture. Read this index, then accept only ARM64.
        $arch = Resolve-LwImageIndexArchitecture -WimPath $WimPath -Index $idx
        if (-not (Test-LwImageIndexIsArm64 $arch)) {
            throw ("FATAL: refusing to inject ARM64 drivers into '{0}' index {1} architecture {2}. Driver injection is ARM64 only." -f $WimPath, $idx, $arch)
        }
        if ($callerLog) {
            & $callerLog ("ARM64 drivers: '{0}' index {1} architecture {2}; injecting" -f $WimPath, $idx, (Get-LwArm64ArchitectureLogValue $arch))
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
            if ($callerLog) { & $callerLog "ARM64 drivers: mounting '$WimPath' index $idx" }
            if ($callerProgress) { & $callerProgress $spanStart }
            try {
                Invoke-LwDismHeartbeat -ArgumentList @(
                    '/Mount-Image',
                    ('/ImageFile:' + $WimPath),
                    ('/Index:' + $idx),
                    ('/MountDir:' + $mountDir)
                ) -Progress $callerProgress -Log $callerLog -Floor $spanStart -Ceiling ($spanStart + [int](($spanEnd - $spanStart) * 0.25))
            } catch {
                $mountError = [string]$_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($mountError)) { $mountError = [string]$_ }
                if ($mountError -like 'DISM failed*') {
                    throw "FATAL: DISM /Mount-Image failed on '$WimPath' index ${idx}: $mountError"
                }
                throw
            }
            $mounted = $true
            if ($callerLog) { & $callerLog "ARM64 drivers: /Add-Driver /Recurse index $idx from $DriverRoot" }
            # Close over this index's span. The body must not read $Progress:
            # Add-LwArm64DriversToMountedImage and the heartbeat both use that name.
            $scaleProgress = {
                param($p)
                $lo = $spanStart + [int](($spanEnd - $spanStart) * 0.25)
                $hi = $spanStart + [int](($spanEnd - $spanStart) * 0.9)
                if ($callerProgress) {
                    & $callerProgress ($lo + [int](($hi - $lo) * ($p / 100.0)))
                }
            }.GetNewClosure()
            Add-LwArm64DriversToMountedImage -MountDir $mountDir -DriverRoot $DriverRoot -Log $callerLog -Progress $scaleProgress
            try {
                Invoke-LwDismHeartbeat -ArgumentList @(
                    '/Unmount-Image',
                    ('/MountDir:' + $mountDir),
                    '/Commit'
                ) -Progress $callerProgress -Log $callerLog -Floor ($spanStart + [int](($spanEnd - $spanStart) * 0.9)) -Ceiling $spanEnd
            } catch {
                $unmountError = [string]$_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($unmountError)) { $unmountError = [string]$_ }
                if ($unmountError -like 'DISM failed*') {
                    throw "FATAL: DISM /Unmount-Image /Commit failed on '$WimPath' index ${idx}: $unmountError"
                }
                throw
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
    # Same rule as Add-LwArm64DriversToWritableWim: do not wrap $Log in a
    # scriptblock. Export-LwInstallIndexesToWim takes $Log and would re-enter it.
    $callerLog = $Log
    if (Test-Path -LiteralPath $DestDir) {
        Remove-Item -LiteralPath $DestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $work = Join-Path $env:TEMP ('LW-Arm64Wim-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $workWim = Join-Path $work 'install.wim'
        if (-not [string]::IsNullOrWhiteSpace($SourceWim) -and (Test-Path -LiteralPath $SourceWim)) {
            if ($callerLog) { & $callerLog "ARM64 install image: copying install.wim to a writable copy" }
            Copy-Item -LiteralPath $SourceWim -Destination $workWim -Force
        } elseif (-not [string]::IsNullOrWhiteSpace($SourceEsd) -and (Test-Path -LiteralPath $SourceEsd)) {
            if ($callerLog) { & $callerLog "ARM64 install image: exporting install.esd to a writable WIM" }
            $exported = Export-LwInstallIndexesToWim -SourceFile $SourceEsd -DestWim $workWim -Log $callerLog
            if (-not $exported) { throw "FATAL: install.esd export produced no WIM: $SourceEsd" }
        } elseif (-not [string]::IsNullOrWhiteSpace($SourceSwmDir) -and (Test-Path -LiteralPath (Join-Path $SourceSwmDir 'install.swm'))) {
            if ($callerLog) { & $callerLog "ARM64 install image: exporting install.swm set to a writable WIM" }
            $swmFile = Join-Path $SourceSwmDir 'install.swm'
            $swmPattern = Join-Path $SourceSwmDir 'install*.swm'
            $exported = Export-LwInstallIndexesToWim -SourceFile $swmFile -DestWim $workWim -SwmPattern $swmPattern -Log $callerLog
            if (-not $exported) { throw "FATAL: install.swm export produced no WIM: $SourceSwmDir" }
        } else {
            throw 'FATAL: ARM64 install-image inject has no install.wim, install.esd, or install.swm source'
        }
        if (-not (Test-Path -LiteralPath $workWim)) {
            throw "FATAL: writable install image was not created at '$workWim'"
        }
        Add-LwArm64DriversToWritableWim -WimPath $workWim -DriverRoot $DriverRoot -Log $callerLog -Progress $Progress
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
