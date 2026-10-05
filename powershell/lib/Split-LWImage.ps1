<#
.SYNOPSIS
  Shared FAT32 install-image split helper for Project LoneWolf.

.DESCRIPTION
  Dot-sourced by BOTH the USB builder (Invoke-LoneWolfBuild.ps1, inside its
  per-disk Start-Job runspace) and the pre-split producer (Stage-PreSplitImage.ps1).
  Keeping the split body in exactly one place guarantees the on-the-fly build
  fallback and the pre-staged .swm set are byte-identical (same /FileSize, same
  /CheckIntegrity, same ESD-export path, same chunk naming).

  This file defines FUNCTIONS ONLY - no top-level executable code - so it is safe
  to dot-source directly (`. .\lib\Split-LWImage.ps1`) and inside a background job
  runspace (which cannot see script-scope functions of the parent).

  Exposed functions:
    Split-LWImageForFat32   - port of the builder's original Split-LWInstallImageForFat32
    Get-LWImageVersionId    - stable image-version identity derived from a source ISO
    Get-LWWindowsEdition    - Home | Pro (default Pro)
    Get-LWBareArch          - AMD64/ARM64 with workflow prefixes stripped
    Find-LWWindowsIso       - newest ISO for arch + SKU (flat ISO\ with home/pro in the name;
                              legacy ISO\Home, ISO\Pro, and untagged Pro files still read).
                              Optional FallbackIsoRoot is used only when the share IsoRoot
                              has no matching file (destage UUP ISO folder).
    Get-LWPreSplitScanDirs  - PreSplit\ (new) then legacy PreSplit\<ARCH>\<SKU>\
                              (Pro also: PreSplit\<ARCH>\)
    Get-LWPreSplitCandidateDirs / Write-LWPreSplitCurrentMarkers
#>

# ---------------------------------------------------------------------------
# Split-LWImageForFat32
#   Place the install image on a FAT32 destination as install*.swm chunks.
#   Ported verbatim (behaviour-for-behaviour) from the builder's inline
#   Split-LWInstallImageForFat32. Threshold = 4GB-1. install.wim > max ->
#   dism /Split-Image (delete monolithic wim, assert install.swm, throw on
#   DISM failure); install.wim <= max -> copy as-is; install.esd > max ->
#   dism /Export-Image (index 1, /Compress:recovery /CheckIntegrity) to a temp
#   WIM then /Split-Image; install.esd <= max -> copy as-is. The monolithic
#   image is never left on the FAT32 volume.
#
#   $Emit, when supplied, receives each log line (a single string) so the caller
#   can wrap it into its own JSON event shape; otherwise lines go to Write-Output.
# ---------------------------------------------------------------------------
function Split-LWImageForFat32 {
    param(
        [Parameter(Mandatory)] [string] $SourceSourcesDir,
        [Parameter(Mandatory)] [string] $DestSourcesDir,
        [int] $FileSizeMb = 3800,
        [scriptblock] $Emit,
        [scriptblock] $Progress
    )

    # Local log shim: route to $Emit when provided, else Write-Output.
    $log = {
        param([string]$Message)
        if ($Emit) { & $Emit $Message } else { Write-Output $Message }
    }

    # Local progress shim: route an integer percentage to $Progress when supplied,
    # else silently no-op. Callers opt in by passing -Progress; without it the split
    # runs the original synchronous DISM call and stays byte-for-byte unchanged.
    $prog = {
        param([int]$p)
        if ($Progress) { & $Progress $p }
    }

    $fat32Max = [long](4GB - 1)
    New-Item -ItemType Directory -Force -Path $DestSourcesDir -ErrorAction SilentlyContinue | Out-Null
    $srcWim = Join-Path $SourceSourcesDir 'install.wim'
    $srcEsd = Join-Path $SourceSourcesDir 'install.esd'

    if (Test-Path -LiteralPath $srcWim) {
        $len = (Get-Item -LiteralPath $srcWim).Length
        if ($len -gt $fat32Max) {
            & $log ("wim-split: install.wim {0:N2} GB exceeds FAT32 4 GB file limit - splitting into install.swm (/FileSize:$FileSizeMb)" -f ($len / 1GB))
            Get-ChildItem -LiteralPath $DestSourcesDir -Filter 'install*.swm' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            $swm = Join-Path $DestSourcesDir 'install.swm'
            # /CheckIntegrity (5.1.55): validates the source WIM's resource hashes while
            # splitting AND writes an integrity table into every produced .swm, so the
            # deploy-side "dism /Apply-Image /CheckIntegrity" can actually detect a chunk
            # that rotted on the FAT32 stick. Without it a bit-damaged .swm applies a
            # right-size / wrong-content winload.efi that passes the pre-seal size gate
            # and only surfaces as 0xc000000f on the device's first boot.
            if ($Progress) {
                # Opt-in live progress: run DISM asynchronously so we can poll the
                # growing install*.swm bytes on the FAT32 volume against the source
                # WIM length. Same flags / same output as the synchronous branch.
                $g       = [guid]::NewGuid().ToString('N')
                $outFile = Join-Path $env:TEMP ("LW-Split-$g.out")
                $errFile = Join-Path $env:TEMP ("LW-Split-$g.err")
                try {
                    $proc = Start-Process dism.exe -ArgumentList @('/Split-Image', "/ImageFile:$srcWim", "/SWMFile:$swm", "/FileSize:$FileSizeMb", '/CheckIntegrity') -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
                    # Retain the process handle NOW. Without this reference .NET releases the
                    # handle when DISM exits and $proc.ExitCode comes back $null, which was
                    # misread as a failure ("failed (exit ):") even though DISM reported
                    # "The operation completed successfully." Reading .Handle keeps it alive.
                    $null = $proc.Handle
                    while (-not $proc.HasExited) {
                        Start-Sleep -Seconds 1
                        try {
                            $done = (Get-ChildItem -LiteralPath $DestSourcesDir -Filter 'install*.swm' -ErrorAction SilentlyContinue |
                                Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                            if (-not $done) { $done = 0 }
                            & $prog ([math]::Min(99, [int](100 * $done / [math]::Max($len, 1))))
                        } catch { }
                    }
                    $proc.WaitForExit()
                    $exit = $proc.ExitCode
                    if ($null -ne $exit -and $exit -ne 0) {
                        $cap = ''
                        if (Test-Path -LiteralPath $outFile) { $cap += (Get-Content -Raw -LiteralPath $outFile -ErrorAction SilentlyContinue) }
                        if (Test-Path -LiteralPath $errFile) { $cap += (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue) }
                        throw "DISM /Split-Image (install.wim) failed (exit $exit): $cap"
                    }
                } finally {
                    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
                }
                & $prog 100
            } else {
                $o = & dism.exe /Split-Image /ImageFile:"$srcWim" /SWMFile:"$swm" /FileSize:$FileSizeMb /CheckIntegrity 2>&1
                if ($LASTEXITCODE -ne 0) { throw "DISM /Split-Image (install.wim) failed (exit $LASTEXITCODE): $($o -join ' | ')" }
            }
            Remove-Item -LiteralPath (Join-Path $DestSourcesDir 'install.wim') -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $swm)) { throw "wim-split: install.swm was not produced on the FAT32 volume" }
            $chunks = @(Get-ChildItem -LiteralPath $DestSourcesDir -Filter 'install*.swm' -ErrorAction SilentlyContinue)
            & $log ("wim-split: produced {0} .swm chunk(s); monolithic install.wim omitted from FAT32 volume" -f $chunks.Count)
        } else {
            Copy-Item -LiteralPath $srcWim -Destination (Join-Path $DestSourcesDir 'install.wim') -Force
            & $log 'wim-split: install.wim <= 4 GB - copied as-is (no split needed)'
        }
    } elseif (Test-Path -LiteralPath $srcEsd) {
        $len = (Get-Item -LiteralPath $srcEsd).Length
        if ($len -gt $fat32Max) {
            & $log ("wim-split: install.esd {0:N2} GB exceeds FAT32 limit - exporting to WIM then splitting" -f ($len / 1GB))
            $work = Join-Path $env:TEMP ('LW-EsdSplit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $work | Out-Null
            try {
                $tmpWim = Join-Path $work 'install_export.wim'
                # /CheckIntegrity on the export as well (5.1.55): it seeds the intermediate
                # WIM with an integrity table, which is what /Split-Image /CheckIntegrity
                # below verifies and propagates into the .swm chunks.
                $o = & dism.exe /Export-Image /SourceImageFile:"$srcEsd" /SourceIndex:1 /DestinationImageFile:"$tmpWim" /Compress:recovery /CheckIntegrity 2>&1
                if ($LASTEXITCODE -ne 0) { throw "DISM /Export-Image (esd->wim) failed (exit $LASTEXITCODE): $($o -join ' | ')" }
                Get-ChildItem -LiteralPath $DestSourcesDir -Filter 'install*.swm' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                $swm = Join-Path $DestSourcesDir 'install.swm'
                if ($Progress) {
                    # Opt-in live progress: poll growing install*.swm bytes against the
                    # exported tmp WIM length. Same flags / same output as sync branch.
                    $denom   = (Get-Item -LiteralPath $tmpWim).Length
                    $g       = [guid]::NewGuid().ToString('N')
                    $outFile = Join-Path $env:TEMP ("LW-Split-$g.out")
                    $errFile = Join-Path $env:TEMP ("LW-Split-$g.err")
                    try {
                        $proc = Start-Process dism.exe -ArgumentList @('/Split-Image', "/ImageFile:$tmpWim", "/SWMFile:$swm", "/FileSize:$FileSizeMb", '/CheckIntegrity') -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
                        # Retain the handle so $proc.ExitCode is readable after exit (else $null
                        # -> false "failed (exit ):"). See the install.wim branch for detail.
                        $null = $proc.Handle
                        while (-not $proc.HasExited) {
                            Start-Sleep -Seconds 1
                            try {
                                $done = (Get-ChildItem -LiteralPath $DestSourcesDir -Filter 'install*.swm' -ErrorAction SilentlyContinue |
                                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                                if (-not $done) { $done = 0 }
                                & $prog ([math]::Min(99, [int](100 * $done / [math]::Max($denom, 1))))
                            } catch { }
                        }
                        $proc.WaitForExit()
                        $exit = $proc.ExitCode
                        if ($null -ne $exit -and $exit -ne 0) {
                            $cap = ''
                            if (Test-Path -LiteralPath $outFile) { $cap += (Get-Content -Raw -LiteralPath $outFile -ErrorAction SilentlyContinue) }
                            if (Test-Path -LiteralPath $errFile) { $cap += (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue) }
                            throw "DISM /Split-Image (esd) failed (exit $exit): $cap"
                        }
                    } finally {
                        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
                        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
                    }
                    & $prog 100
                } else {
                    $o = & dism.exe /Split-Image /ImageFile:"$tmpWim" /SWMFile:"$swm" /FileSize:$FileSizeMb /CheckIntegrity 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "DISM /Split-Image (esd) failed (exit $LASTEXITCODE): $($o -join ' | ')" }
                }
            } finally {
                Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath (Join-Path $DestSourcesDir 'install.esd') -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath (Join-Path $DestSourcesDir 'install.swm'))) { throw "wim-split: install.swm was not produced from install.esd" }
            $chunks = @(Get-ChildItem -LiteralPath $DestSourcesDir -Filter 'install*.swm' -ErrorAction SilentlyContinue)
            & $log ("wim-split: produced {0} .swm chunk(s) from install.esd; monolithic install.esd omitted from FAT32 volume" -f $chunks.Count)
        } else {
            Copy-Item -LiteralPath $srcEsd -Destination (Join-Path $DestSourcesDir 'install.esd') -Force
            & $log 'wim-split: install.esd <= 4 GB - copied as-is (no split needed)'
        }
    } else {
        throw "Single layout: no install.wim or install.esd found under '$SourceSourcesDir' to place on the FAT32 volume"
    }
}

# ---------------------------------------------------------------------------
# Windows SKU (Home/Pro) + ISO lookup. Presplit identity is arch + Windows
# version (ISO name slug) + SKU. Not LoneWolf vs Quick Install.
# Write layout: Staging\ISO\ is a single blanket folder. Filenames carry
# edition + arch, e.g. 25h2_home_9.10(amd64).ISO / 25h2_pro_9.10(arm64).ISO.
# Read also accepts legacy ISO\Home, ISO\Pro, and untagged Pro files in ISO\
# or Staging\. Home never falls back to Pro (name must contain home vs pro).
# ---------------------------------------------------------------------------
function Get-LWWindowsEdition {
    param([string] $Edition)
    $e = ([string]$Edition).Trim()
    if ($e -match '^(?i)home$') { return 'Home' }
    return 'Pro'
}

function Get-LWBareArch {
    param([string] $Arch)
    $a = ([string]$Arch).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($a)) { return 'AMD64' }
    $a = [regex]::Replace($a, '^(QUICK-INSTALL-|WIN-INSTALL-|LONEWOLF-)', '')
    if ($a -match 'ARM') { return 'ARM64' }
    if ($a -match 'AMD' -or $a -match 'X64') { return 'AMD64' }
    return $a
}

function Get-LWIsoEditionFromName {
    param([string] $Name)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    if ($base -match '(?i)(^|[^a-z0-9])home([^a-z0-9]|$)') { return 'Home' }
    if ($base -match '(?i)(^|[^a-z0-9])pro([^a-z0-9]|$)') { return 'Pro' }
    return $null
}

function Test-LWIsoMatchesEdition {
    param(
        [Parameter(Mandatory)] [string] $FullName,
        [string] $Edition
    )
    $want = Get-LWWindowsEdition $Edition
    $fromName = Get-LWIsoEditionFromName $FullName
    if ($fromName) { return ($fromName -eq $want) }
    $parent = ''
    try { $parent = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($FullName)) } catch { }
    if ($parent -match '^(?i)home$') { return ($want -eq 'Home') }
    if ($parent -match '^(?i)pro$') { return ($want -eq 'Pro') }
    # Untagged file in a non-SKU folder (flat ISO\ or Staging\): Pro-only legacy.
    return ($want -eq 'Pro')
}

function Get-LWIsoSearchDirs {
    param(
        [Parameter(Mandatory)] [string] $StagingRoot,
        [Parameter(Mandatory)] [string] $IsoRoot,
        [string] $Edition
    )
    $ed = Get-LWWindowsEdition $Edition
    $dirs = New-Object System.Collections.Generic.List[string]
    $dirs.Add($IsoRoot)
    $dirs.Add((Join-Path $IsoRoot $ed))
    $dirs.Add($StagingRoot)
    return @($dirs)
}

function Find-LWWindowsIso {
    param(
        [Parameter(Mandatory)] [string] $StagingRoot,
        [Parameter(Mandatory)] [string] $IsoRoot,
        [Parameter(Mandatory)] [string] $Arch,
        [string] $Edition,
        [string] $FallbackIsoRoot = ''
    )
    $ed = Get-LWWindowsEdition $Edition
    $arch = Get-LWBareArch $Arch
    $seen = @{}
    $hits = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($dir in @(Get-LWIsoSearchDirs -StagingRoot $StagingRoot -IsoRoot $IsoRoot -Edition $ed)) {
        if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) { continue }
        $files = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.iso' -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like "*($arch)*.iso" -and
                (Test-LWIsoMatchesEdition -FullName $_.FullName -Edition $ed)
            })
        foreach ($f in $files) {
            if (-not $seen.ContainsKey($f.FullName)) {
                $seen[$f.FullName] = $true
                [void]$hits.Add($f)
            }
        }
    }
    if ($hits.Count -gt 0) {
        return ($hits | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    }
    # Destage: share miss only — do not merge fallback into the primary newest-wins set.
    if ([string]::IsNullOrWhiteSpace($FallbackIsoRoot)) { return $null }
    $fb = $FallbackIsoRoot.Trim()
    $same = $false
    try {
        $isoFull = [IO.Path]::GetFullPath($IsoRoot).TrimEnd('\')
        $fbFull = [IO.Path]::GetFullPath($fb).TrimEnd('\')
        $same = ($isoFull -eq $fbFull)
    } catch { }
    if ($same) { return $null }
    return Find-LWWindowsIso -StagingRoot $fb -IsoRoot $fb -Arch $arch -Edition $ed
}

function Get-LWMissingHomeIsoMessage {
    param([string] $Arch, [string] $IsoHomeDir)
    $a = Get-LWBareArch $Arch
    $dir = $IsoHomeDir
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = 'Staging\ISO' }
    return "No Windows Home ISO for $a in $dir. Place a *($a)*.iso with home in the name under ISO\ (do not use the Pro image)."
}

function Get-LWPreSplitCurrentKey {
    param([string] $Arch, [string] $Edition)
    return ("{0}-{1}" -f (Get-LWBareArch $Arch), (Get-LWWindowsEdition $Edition))
}

function Test-LWPreSplitFolderMatches {
    param(
        [Parameter(Mandatory)] [string] $FolderName,
        [Parameter(Mandatory)] [string] $Arch,
        [string] $Edition,
        [switch] $RequireArchInName
    )
    $ed = Get-LWWindowsEdition $Edition
    $arch = Get-LWBareArch $Arch
    $fromEd = Get-LWIsoEditionFromName $FolderName
    if ($fromEd -and $fromEd -ne $ed) { return $false }
    $n = $FolderName.ToLowerInvariant()
    $hasAmd = [bool]($n -match '(?i)(^|[^a-z0-9])(amd64|x64)([^a-z0-9]|$)')
    $hasArm = [bool]($n -match '(?i)(^|[^a-z0-9])arm64([^a-z0-9]|$)')
    if ($arch -eq 'ARM64' -and $hasAmd -and -not $hasArm) { return $false }
    if ($arch -eq 'AMD64' -and $hasArm -and -not $hasAmd) { return $false }
    if ($RequireArchInName) {
        if ($arch -eq 'ARM64') { return $hasArm }
        if ($arch -eq 'AMD64') { return $hasAmd }
    }
    return $true
}

function Get-LWPreSplitScanDirs {
    param(
        [Parameter(Mandatory)] [string] $PreSplitRoot,
        [Parameter(Mandatory)] [string] $Arch,
        [string] $Edition
    )
    $ed = Get-LWWindowsEdition $Edition
    $arch = Get-LWBareArch $Arch
    $dirs = New-Object System.Collections.Generic.List[string]
    $dirs.Add($PreSplitRoot)
    $dirs.Add((Join-Path (Join-Path $PreSplitRoot $arch) $ed))
    if ($ed -eq 'Pro') {
        $dirs.Add((Join-Path $PreSplitRoot $arch))
    }
    return @($dirs)
}

function Get-LWPreSplitCandidateDirs {
    param(
        [Parameter(Mandatory)] [string] $PreSplitRoot,
        [Parameter(Mandatory)] [string] $Arch,
        [string] $Edition
    )
    $ed = Get-LWWindowsEdition $Edition
    $arch = Get-LWBareArch $Arch
    $key = Get-LWPreSplitCurrentKey -Arch $arch -Edition $ed
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    $rootFull = $null
    try { $rootFull = [IO.Path]::GetFullPath($PreSplitRoot).TrimEnd('\') } catch { }

    foreach ($scanDir in @(Get-LWPreSplitScanDirs -PreSplitRoot $PreSplitRoot -Arch $arch -Edition $ed)) {
        if ([string]::IsNullOrWhiteSpace($scanDir) -or -not (Test-Path -LiteralPath $scanDir)) { continue }
        $scanFull = $scanDir
        try { $scanFull = [IO.Path]::GetFullPath($scanDir).TrimEnd('\') } catch { }
        $isRoot = ($rootFull -and ($scanFull -eq $rootFull))

        $pending = New-Object System.Collections.Generic.List[string]
        foreach ($markerName in @('current.json', 'current')) {
            $marker = Join-Path $scanDir $markerName
            if (-not (Test-Path -LiteralPath $marker)) { continue }
            try {
                $mk = Get-Content -Raw -LiteralPath $marker -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $propNames = @($mk.PSObject.Properties.Name)
                $isKeyedMap = $false
                foreach ($pn in $propNames) {
                    if ($pn -match '^(?i)(AMD64|ARM64)-(Home|Pro)$') { $isKeyedMap = $true; break }
                }
                $entry = $null
                if ($isKeyedMap) {
                    # Only the matching arch+SKU key. Never treat the whole map (or an
                    # AMD64-* entry) as current for ARM64.
                    if ($propNames -contains $key) { $entry = $mk.$key }
                } elseif ($propNames -contains 'imageVersion') {
                    $mkEd = $null
                    $mkArch = $null
                    if ($mk.PSObject.Properties['windowsEdition'] -and $mk.windowsEdition) {
                        $mkEd = Get-LWWindowsEdition ([string]$mk.windowsEdition)
                    }
                    if ($mk.PSObject.Properties['arch'] -and $mk.arch) {
                        $mkArch = Get-LWBareArch ([string]$mk.arch)
                    }
                    if ($isRoot) {
                        # A single root current without arch is global and would make
                        # ARM64 Stage ISO / Rebuild follow the AMD64 set.
                        if ($mkArch -and $mkArch -eq $arch -and ((-not $mkEd) -or ($mkEd -eq $ed))) {
                            $entry = $mk
                        }
                    } else {
                        $edOk = (-not $mkEd) -or ($mkEd -eq $ed)
                        $archOk = (-not $mkArch) -or ($mkArch -eq $arch)
                        if ($edOk -and $archOk) { $entry = $mk }
                    }
                }
                $iv = $null
                if ($entry -is [string]) { $iv = $entry }
                elseif ($entry -and $entry.PSObject.Properties['imageVersion']) { $iv = [string]$entry.imageVersion }
                if ($iv -and (Test-LWPreSplitFolderMatches -FolderName $iv -Arch $arch -Edition $ed -RequireArchInName:$isRoot)) {
                    [void]$pending.Add((Join-Path $scanDir $iv))
                }
            } catch { }
        }

        foreach ($d in @(Get-ChildItem -LiteralPath $scanDir -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)) {
            if ($d.Name -like '*.tmp-*') { continue }
            if ($d.Name -match '^(?i)(AMD64|ARM64|Home|Pro)$') { continue }
            if (-not (Test-LWPreSplitFolderMatches -FolderName $d.Name -Arch $arch -Edition $ed -RequireArchInName:$isRoot)) { continue }
            [void]$pending.Add($d.FullName)
        }

        foreach ($p in $pending) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $full = $p
            try { $full = [IO.Path]::GetFullPath($p) } catch { }
            if (-not $seen.ContainsKey($full) -and (Test-Path -LiteralPath $p)) {
                $seen[$full] = $true
                [void]$out.Add($p)
            }
        }
    }
    return @($out)
}

function Write-LWPreSplitCurrentMarkers {
    param(
        [Parameter(Mandatory)] [string] $PreSplitRoot,
        [string] $SetDir,
        [Parameter(Mandatory)] [string] $Arch,
        [string] $Edition,
        [Parameter(Mandatory)] [string] $ImageVersion,
        [string] $UpdatedUtc
    )
    $ed = Get-LWWindowsEdition $Edition
    $arch = Get-LWBareArch $Arch
    if ([string]::IsNullOrWhiteSpace($UpdatedUtc)) {
        $UpdatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    $payload = [ordered]@{
        imageVersion   = $ImageVersion
        windowsEdition = $ed
        arch           = $arch
        updatedUtc     = $UpdatedUtc
    }
    if (-not [string]::IsNullOrWhiteSpace($SetDir) -and (Test-Path -LiteralPath $SetDir)) {
        [System.IO.File]::WriteAllText((Join-Path $SetDir 'current'), ($payload | ConvertTo-Json -Compress),
            [System.Text.UTF8Encoding]::new($false))
    }
    $key = Get-LWPreSplitCurrentKey -Arch $arch -Edition $ed
    $rootPath = Join-Path $PreSplitRoot 'current.json'
    $map = [ordered]@{}
    if (Test-Path -LiteralPath $rootPath) {
        try {
            $existing = Get-Content -Raw -LiteralPath $rootPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in $existing.PSObject.Properties) {
                $map[$p.Name] = $p.Value
            }
        } catch { }
    }
    $map[$key] = $payload
    if (-not (Test-Path -LiteralPath $PreSplitRoot)) {
        New-Item -ItemType Directory -Force -Path $PreSplitRoot | Out-Null
    }
    [System.IO.File]::WriteAllText($rootPath, ($map | ConvertTo-Json -Depth 6),
        [System.Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------
# Get-LWImageVersionId
#   Stable image-version identity for a source ISO, computed IDENTICALLY by the
#   producer (manifest imageVersion + folder name) and the builder detection.
#     slug  = ISO base filename w/o extension, lowercased, each run of
#             [^a-z0-9]+ collapsed to '-', trimmed of leading/trailing '-'
#     sku   = home | pro (appended when not already in the slug)
#     stamp = ISO LastWriteTimeUtc as 'yyyyMMddTHHmmssZ'
#     id    = "<slug>-<sku>-<stamp>"
# ---------------------------------------------------------------------------
function Get-LWImageVersionId {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo] $Iso,
        [string] $Edition = ''
    )
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Iso.Name)
    $slug = $base.ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[^a-z0-9]+', '-')
    $slug = $slug.Trim('-')
    if (-not [string]::IsNullOrWhiteSpace($Edition)) {
        $ed = (Get-LWWindowsEdition $Edition).ToLowerInvariant()
        if ($slug -notmatch [regex]::Escape($ed)) { $slug = "$slug-$ed" }
    }
    $stamp = $Iso.LastWriteTimeUtc.ToString("yyyyMMdd'T'HHmmss'Z'")
    return "$slug-$stamp"
}

# ---------------------------------------------------------------------------
# Test-LWPreSplitSet
#   Integrity validator for a staged pre-split set folder. Used by the producer
#   ("already-staged" check + post-copy verify), the builder (Get-LWPreSplitSet),
#   and Get-StagingVersion.ps1 so the same rules apply everywhere. Never throws -
#   returns a result object with Valid/Reason/Manifest.
#     - manifest parses
#     - every chunk.name exists with the EXACT chunk.sizeBytes (mandatory)
#     - sha256 checked only when -VerifyHash AND the manifest carries a hash
#   NOTE: this validates the SET only. Matching the set against a specific ISO
#   (name/size/last-write) is the caller's responsibility.
# ---------------------------------------------------------------------------
function Test-LWPreSplitSet {
    param(
        [Parameter(Mandatory)] [string] $SetDir,
        [switch] $VerifyHash
    )
    $result = [pscustomobject]@{ Valid = $false; Reason = ''; Manifest = $null }
    try {
        if ([string]::IsNullOrWhiteSpace($SetDir) -or -not (Test-Path -LiteralPath $SetDir)) {
            $result.Reason = "set folder not found: $SetDir"; return $result
        }
        $manifestPath = Join-Path $SetDir 'presplit-manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            $result.Reason = "presplit-manifest.json missing in $SetDir"; return $result
        }
        try {
            $m = Get-Content -Raw -LiteralPath $manifestPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $result.Reason = "presplit-manifest.json unreadable/unparseable: $($_.Exception.Message)"; return $result
        }
        $result.Manifest = $m
        $chunks = @()
        if ($m.PSObject.Properties['install'] -and $m.install -and $m.install.PSObject.Properties['chunks']) {
            $chunks = @($m.install.chunks)
        }
        if ($chunks.Count -eq 0) { $result.Reason = 'manifest lists no chunks'; return $result }
        foreach ($c in $chunks) {
            $name = [string]$c.name
            if ([string]::IsNullOrWhiteSpace($name)) { $result.Reason = 'manifest chunk with empty name'; return $result }
            $chunkPath = Join-Path $SetDir $name
            if (-not (Test-Path -LiteralPath $chunkPath)) { $result.Reason = "chunk missing: $name"; return $result }
            $actual   = (Get-Item -LiteralPath $chunkPath).Length
            $expected = [long]$c.sizeBytes
            if ($actual -ne $expected) {
                $result.Reason = "chunk size mismatch for '$name' (manifest $expected, on-disk $actual)"; return $result
            }
            if ($VerifyHash -and $c.PSObject.Properties['sha256'] -and $c.sha256) {
                $h = (Get-FileHash -LiteralPath $chunkPath -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($h -ne ([string]$c.sha256)) { $result.Reason = "chunk sha256 mismatch for '$name'"; return $result }
            }
        }
        $result.Valid  = $true
        $result.Reason = 'ok'
        return $result
    } catch {
        $result.Reason = "validation error: $($_.Exception.Message)"
        return $result
    }
}
