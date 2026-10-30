# Offline Windows cumulative (LCU) servicing for Image Ready.
# DISM cannot mount install*.swm. Reunite to install.wim, Add-WindowsPackage, then re-split.
# Windows 11 24H2+ catalog LCUs are combined SSU+LCU packages. A separate SSU is applied first when the catalog lists one.

function Get-LwReleaseFamilyLabel {
    param(
        [string] $Release = '',
        [string] $ImageVersion = ''
    )
    $src = (([string]$Release) + ' ' + ([string]$ImageVersion)).ToLowerInvariant()
    if ($src -match '26h2') { return '26H2' }
    if ($src -match '25h2') { return '25H2' }
    if ($src -match '24h2') { return '24H2' }
    if ($src -match '23h2') { return '23H2' }
    return '25H2'
}

function Get-LwCatalogArchToken {
    param([string] $Arch)
    if ([string]$Arch -match 'ARM') { return 'arm64' }
    return 'x64'
}

function Compare-LwOsBuild {
    # Negative when Left is older than Right. Empty left is older when right is set.
    param([string] $Left, [string] $Right)
    $l = [string]$Left
    $r = [string]$Right
    if ([string]::IsNullOrWhiteSpace($l) -and [string]::IsNullOrWhiteSpace($r)) { return 0 }
    if ([string]::IsNullOrWhiteSpace($l)) { return -1 }
    if ([string]::IsNullOrWhiteSpace($r)) { return 1 }
    $lp = @($l -split '\.' | ForEach-Object { 0 + $_ })
    $rp = @($r -split '\.' | ForEach-Object { 0 + $_ })
    $n = [Math]::Max($lp.Count, $rp.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $a = if ($i -lt $lp.Count) { [int]$lp[$i] } else { 0 }
        $b = if ($i -lt $rp.Count) { [int]$rp[$i] } else { 0 }
        if ($a -lt $b) { return -1 }
        if ($a -gt $b) { return 1 }
    }
    return 0
}

function Test-LwInstallLcuBehind {
    param(
        [string] $StickKb = '',
        [string] $StickBuild = '',
        [string] $CurrentKb = '',
        [string] $CurrentBuild = ''
    )
    $curKb = [string]$CurrentKb
    $curBuild = [string]$CurrentBuild
    if ([string]::IsNullOrWhiteSpace($curKb) -and [string]::IsNullOrWhiteSpace($curBuild)) { return $false }
    $stickKb = [string]$StickKb
    $stickBuild = [string]$StickBuild
    if ([string]::IsNullOrWhiteSpace($stickKb) -and [string]::IsNullOrWhiteSpace($stickBuild)) { return $true }
    if ((Compare-LwOsBuild -Left $stickBuild -Right $curBuild) -lt 0) { return $true }
    if (-not [string]::IsNullOrWhiteSpace($curKb) -and [string]::IsNullOrWhiteSpace($stickKb)) { return $true }
    if (-not [string]::IsNullOrWhiteSpace($curKb) -and -not [string]::IsNullOrWhiteSpace($stickKb) -and
        ($stickKb -ne $curKb) -and ((Compare-LwOsBuild -Left $stickBuild -Right $curBuild) -le 0)) {
        return $true
    }
    return $false
}

function Get-LwCatalogUpdates {
    param(
        [Parameter(Mandatory)][string] $Query
    )
    $uri = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($Query)
    $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -ErrorAction Stop
    $html = [string]$resp.Content
    $list = New-Object System.Collections.Generic.List[object]
    $rx = [regex]'id=[''"]([0-9a-fA-F-]{36})_link[''"][^>]*>\s*([^<]+)'
    foreach ($m in $rx.Matches($html)) {
        $title = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value).Trim()
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        [void]$list.Add([pscustomobject]@{
            UpdateId = $m.Groups[1].Value
            Title    = $title
        })
    }
    # Windows PowerShell 5.1 throws "Argument types do not match" on `return @($genericList)`.
    if ($list.Count -eq 0) { return @() }
    return $list.ToArray()
}

function Select-LwCatalogLcuPair {
    param(
        [Parameter(Mandatory)][string] $Release,
        [Parameter(Mandatory)][string] $Arch
    )
    $archToken = Get-LwCatalogArchToken -Arch $Arch
    $archPhrase = if ($archToken -eq 'arm64') { 'arm64-based' } else { 'x64-based' }
    $lcuQuery = "Cumulative Update for Windows 11 Version $Release for $archPhrase Systems"
    $ssuQuery = "Servicing Stack Update for Windows 11 Version $Release for $archPhrase Systems"
    $lcuHits = @(Get-LwCatalogUpdates -Query $lcuQuery | Where-Object {
        $_.Title -match [regex]::Escape($Release) -and
        $_.Title -match $archPhrase -and
        $_.Title -match 'Cumulative Update' -and
        $_.Title -notmatch 'Preview' -and
        $_.Title -notmatch 'Dynamic'
    })
    if (-not $lcuHits -or $lcuHits.Count -eq 0) {
        throw "Update Catalog returned no cumulative update for Windows 11 $Release $archPhrase. Full UUP rebuild remains the fallback."
    }
    $lcu = $lcuHits[0]
    foreach ($hit in $lcuHits) {
        $hb = ''
        $bb = ''
        if ($hit.Title -match '\((\d+\.\d+)\)') { $hb = $Matches[1] }
        if ($lcu.Title -match '\((\d+\.\d+)\)') { $bb = $Matches[1] }
        if ((Compare-LwOsBuild -Left $bb -Right $hb) -lt 0) { $lcu = $hit }
    }
    $ssu = $null
    try {
        $ssuHits = @(Get-LwCatalogUpdates -Query $ssuQuery | Where-Object {
            $_.Title -match 'Servicing Stack Update' -and
            $_.Title -match [regex]::Escape($Release) -and
            $_.Title -match $archPhrase -and
            $_.Title -notmatch 'Preview'
        })
        if ($ssuHits.Count -gt 0) { $ssu = $ssuHits[0] }
    } catch { }
    return [pscustomobject]@{ Lcu = $lcu; Ssu = $ssu }
}

function Get-LwCatalogDownloadUrls {
    param([Parameter(Mandatory)][string] $UpdateId)
    $body = @{ updateIDs = '[{"size":0,"updateID":"' + $UpdateId + '","uidInfo":"' + $UpdateId + '"}]' }
    $resp = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
        -Method POST -Body $body -UseBasicParsing -ErrorAction Stop
    $text = [string]$resp.Content
    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($text, 'https://[^"''\s>]+\.(?:msu|cab)')) {
        $u = $m.Value
        if (-not $urls.Contains($u)) { [void]$urls.Add($u) }
    }
    if ($urls.Count -eq 0) {
        throw "Update Catalog did not return a download URL for $UpdateId"
    }
    return $urls.ToArray()
}

function Save-LwUrlToFile {
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $Dest,
        [string] $Label,
        [scriptblock] $Log
    )
    $partial = "$Dest.partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.AllowAutoRedirect = $true
    $req.Timeout = 7200000
    $req.ReadWriteTimeout = 7200000
    $res = $null
    $in = $null
    $out = $null
    try {
        $res = $req.GetResponse()
        $total = [int64]$res.ContentLength
        if ($total -lt 0) { $total = 0 }
        $in = $res.GetResponseStream()
        $out = [System.IO.File]::Create($partial)
        $buf = New-Object byte[] 1048576
        $read = [int64]0
        $lastPct = -5
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $read += $n
            if (-not $Log) { continue }
            if ($total -gt 0) {
                $pct = [int](($read * 100) / $total)
                if ($pct -ge ($lastPct + 5)) {
                    $lastPct = $pct
                    & $Log ("Downloading {0} {1}% ({2} / {3} MB)" -f $Label, $pct, [int]($read / 1MB), [int]($total / 1MB))
                }
            } elseif (($read / 1MB) -ge ($lastPct + 100)) {
                $lastPct = [int]($read / 1MB)
                & $Log ("Downloading {0} ({1} MB)" -f $Label, $lastPct)
            }
        }
        $out.Dispose(); $out = $null
        $in.Dispose(); $in = $null
        $res.Close(); $res = $null
        if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
        Move-Item -LiteralPath $partial -Destination $Dest -Force
    } catch {
        if ($out) { $out.Dispose() }
        if ($in) { $in.Dispose() }
        if ($res) { $res.Close() }
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Save-LwCatalogPackage {
    param(
        [Parameter(Mandatory)][string] $UpdateId,
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][string] $DestDir,
        [scriptblock] $Log
    )
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $kb = 'KB'
    if ($Title -match '(KB\d+)') { $kb = $Matches[1] }
    $urls = @(Get-LwCatalogDownloadUrls -UpdateId $UpdateId)
    $saved = @()
    $i = 0
    foreach ($url in $urls) {
        $i++
        $leaf = [IO.Path]::GetFileName(([uri]$url).AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = "$kb-$i.msu" }
        $fileKb = $kb
        if ($leaf -match '(KB\d+)') { $fileKb = $Matches[1].ToUpperInvariant() }
        $dest = Join-Path $DestDir $leaf
        if (-not (Test-Path -LiteralPath $dest) -or ((Get-Item -LiteralPath $dest).Length -lt 1MB)) {
            if ($Log) {
                if ($fileKb -ne $kb) { & $Log ("Pulling checkpoint $fileKb for $kb") }
                else { & $Log ("Pulling $kb") }
            }
            Save-LwUrlToFile -Url $url -Dest $dest -Label $fileKb -Log $Log
        } elseif ($Log) {
            & $Log ("Using cached $fileKb")
        }
        $saved += $dest
    }
    return [pscustomobject]@{ Kb = $kb; Files = @($saved); Title = $Title }
}

function Export-LwSwmSetToInstallWim {
    param(
        [Parameter(Mandatory)][string] $SwmPath,
        [Parameter(Mandatory)][string] $DestWim,
        [string] $SwmPattern = '',
        [scriptblock] $Log
    )
    if ([string]::IsNullOrWhiteSpace($SwmPattern)) {
        $SwmPattern = Join-Path (Split-Path -Parent $SwmPath) 'install*.swm'
    }
    Import-Module Dism -ErrorAction SilentlyContinue
    $images = @()
    try { $images = @(Get-WindowsImage -ImagePath $SwmPath -ErrorAction Stop) } catch { $images = @() }
    if ($images.Count -eq 0) { $images = @([pscustomobject]@{ ImageIndex = 1 }) }
    if (Test-Path -LiteralPath $DestWim) { Remove-Item -LiteralPath $DestWim -Force }
    foreach ($img in $images) {
        $idx = [int]$img.ImageIndex
        if ($Log) { & $Log ("Exporting install.swm index $idx") }
        $dismArgs = @(
            '/Export-Image',
            (Format-LwDismArg 'SourceImageFile' $SwmPath),
            "/SourceIndex:$idx",
            (Format-LwDismArg 'DestinationImageFile' $DestWim),
            '/Compress:max'
        )
        if (-not [string]::IsNullOrWhiteSpace($SwmPattern)) { $dismArgs += (Format-LwDismArg 'SWMFile' $SwmPattern) }
        & dism.exe @dismArgs 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "DISM /Export-Image failed (exit $LASTEXITCODE) for index $idx" }
    }
    if (-not (Test-Path -LiteralPath $DestWim)) { throw "Export did not produce $DestWim" }
    return $DestWim
}

function Get-LwPackageLabel {
    param([string] $Name)
    if ($Name -match '(KB\d+)') { return $Matches[1].ToUpperInvariant() }
    if ($Name -match '^(SSU-[^.]+)') { return $Matches[1] }
    return $Name
}

function Format-LwDismArg {
    # DISM splits unquoted values on spaces. Paths under "Project Keyes" must be
    # /Name:"C:\path with spaces" so Add-Package / Mount-Image see one path.
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Value)
    return ('/{0}:"{1}"' -f $Name.TrimStart('/'), $Value)
}

function Save-LwLcuFailLogs {
    param([string[]] $Paths)
    $dest = 'C:\LW-Lcu\last-fail'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    foreach ($p in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($p) -or -not (Test-Path -LiteralPath $p)) { continue }
        Copy-Item -LiteralPath $p -Destination (Join-Path $dest ([IO.Path]::GetFileName($p))) -Force -ErrorAction SilentlyContinue
    }
}

function Dismount-LwReadOnlyDir {
    param([string] $MountDir)
    if ([string]::IsNullOrWhiteSpace($MountDir) -or -not (Test-Path -LiteralPath $MountDir)) { return }
    & dism.exe /Unmount-Image (Format-LwDismArg 'MountDir' $MountDir) /Discard 2>&1 | Out-Null
    Remove-Item -LiteralPath $MountDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-Lw7ZipExe {
    foreach ($c in @('C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe')) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return ''
}

function Open-LwUpdatePackage {
    # Catalog .msu files are WIM wrappers (MSWIM). Add-Package rejects the
    # inner .wim and the .mumx.esd. Extract SSU + Windows*.wim + Windows*.psf
    # with 7-Zip, expand the wim to update.mum, and keep the .psf beside it
    # (PSFX needs that file or Add-Package fails 0x800f0991).
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $WorkRoot,
        [switch] $Required,
        [scriptblock] $Log
    )
    $leaf = [IO.Path]::GetFileName($SourcePath)
    $label = Get-LwPackageLabel -Name $leaf
    if ($leaf -notmatch '\.msu$') {
        return [pscustomobject]@{
            MountDir = ''
            Packages = @([pscustomobject]@{ Path = $SourcePath; Label = $label; Required = [bool]$Required })
        }
    }
    $seven = Get-Lw7ZipExe
    if (-not $seven) { throw '7-Zip (7z.exe) is required to open cumulative update packages' }
    $pkgRoot = Join-Path $WorkRoot ($label + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $extract = Join-Path $pkgRoot 'msu'
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    if ($Log) { & $Log ("Opening $label") }
    foreach ($pattern in @('SSU-*.cab', 'Windows*.psf', 'Windows*.wim')) {
        & $seven e -y "-o$extract" $SourcePath $pattern 2>&1 | Out-Null
        if ($LASTEXITCODE -gt 1) {
            throw "7-Zip could not extract $pattern from $label (exit $LASTEXITCODE)"
        }
    }
    $files = @(Get-ChildItem -LiteralPath $extract -File -ErrorAction SilentlyContinue)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        if ($f.Name -match '^SSU-.*\.cab$') {
            [void]$list.Add([pscustomobject]@{ Path = $f.FullName; Label = (Get-LwPackageLabel -Name $f.Name); Required = $false })
        }
    }
    $inner = @($files | Where-Object { $_.Name -match '^Windows.+\.wim$' } | Sort-Object Length) | Select-Object -First 1
    $psf = @($files | Where-Object { $_.Name -match '(?i)\.psf$' }) | Select-Object -First 1
    $payloadPath = ''
    if ($inner) {
        $payloadDir = Join-Path $pkgRoot 'payload'
        New-Item -ItemType Directory -Force -Path $payloadDir | Out-Null
        if ($Log) { & $Log ("Preparing $label package") }
        & dism.exe /Apply-Image (Format-LwDismArg 'ImageFile' $inner.FullName) /Index:1 (Format-LwDismArg 'ApplyDir' $payloadDir) 2>&1 | Out-Null
        $mum = Join-Path $payloadDir 'update.mum'
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $mum)) {
            throw "DISM could not expand $label (exit $LASTEXITCODE)"
        }
        if (-not $psf) {
            throw "Cumulative update $label is missing its .psf payload store"
        }
        $psfDest = Join-Path $payloadDir $psf.Name
        if ($Log) { & $Log ("Staging $($psf.Name) for PSFX ($([math]::Round($psf.Length / 1MB)) MB)") }
        Move-Item -LiteralPath $psf.FullName -Destination $psfDest -Force
        $staged = Get-Item -LiteralPath $psfDest -ErrorAction Stop
        if ($staged.Length -lt 1MB) {
            throw "Staged .psf for $label is too small ($($staged.Length) bytes)"
        }
        $payloadPath = $payloadDir
    }
    else {
        $cab = $files | Where-Object { $_.Name -match '^Windows.+\.cab$' -and $_.Name -notmatch 'DesktopDeployment' } | Select-Object -First 1
        if ($cab) { $payloadPath = $cab.FullName }
    }
    if (-not $payloadPath) {
        throw "No cumulative payload inside $label"
    }
    [void]$list.Add([pscustomobject]@{
        Path     = $payloadPath
        Label    = $label
        Required = [bool]$Required
    })
    return [pscustomobject]@{ MountDir = ''; Packages = $list.ToArray() }
}

function Close-LwDismSession {
    # Get-WindowsImage keeps a DISM API session in this process. That session
    # blocks unloading the offline registry on unmount.
    Remove-Module Dism -Force -ErrorAction SilentlyContinue
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

function Get-LwDismLogDetail {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $lines = @(Get-Content -LiteralPath $Path -Tail 120 -ErrorAction SilentlyContinue)
    $err = @($lines | Where-Object { $_ -match ', Error ' } | Select-Object -Last 3)
    if ($err.Count -eq 0) {
        $err = @($lines | Where-Object { $_ -match 'Failed to unload offline registry' } | Select-Object -Last 1)
    }
    return ($err -join ' ')
}

function Invoke-LwDismUnmount {
    param(
        [Parameter(Mandatory)][string] $MountDir,
        [switch] $Commit
    )
    $flag = if ($Commit) { '/Commit' } else { '/Discard' }
    $log = 'C:\LW-Lcu\unmount.log'
    $code = 1
    for ($try = 1; $try -le 4; $try++) {
        Close-LwDismSession
        & dism.exe /Unmount-Image (Format-LwDismArg 'MountDir' $MountDir) $flag (Format-LwDismArg 'LogPath' $log) 2>&1 | Out-Null
        $code = $LASTEXITCODE
        if ($code -eq 0) { return }
        $detail = Get-LwDismLogDetail -Path $log
        $retry = ($detail -match 'unload offline registry|0x80070005|0xc1420117') -or ($try -lt 4)
        if (-not $retry) { break }
        Start-Sleep -Seconds (5 * $try)
    }
    $detail = Get-LwDismLogDetail -Path $log
    $u = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$code), 0)
    $hex = '0x{0:X8}' -f $u
    $suffix = if ($detail) { " $detail" } else { '' }
    throw "DISM /Unmount-Image $flag failed ($hex).$suffix"
}

function Add-LwOfflinePackagesToWim {
    param(
        [Parameter(Mandatory)][string] $WimPath,
        [Parameter(Mandatory)][string[]] $PackagePaths,
        [string] $Edition = '',
        [string] $ScratchDir = '',
        [scriptblock] $Log
    )
    Close-LwDismSession
    $info = & dism.exe /Get-WimInfo (Format-LwDismArg 'WimFile' $WimPath) /English 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "DISM /Get-WimInfo failed for $WimPath" }
    $want = ''
    if ($Edition -match '^(?i)home$') { $want = 'home' }
    elseif ($Edition -match '^(?i)pro$') { $want = 'pro' }
    $indexes = @()
    foreach ($part in @([regex]::Split($info, '(?=Index\s*:)'))) {
        if ($part -notmatch 'Index\s*:\s*(\d+)') { continue }
        $imageIndex = [int]$Matches[1]
        $imageName = ''
        if ($part -match 'Name\s*:\s*(.+)') { $imageName = $Matches[1].Trim() }
        if ($want -and $imageName -notmatch $want) { continue }
        $indexes += $imageIndex
    }
    if ($indexes.Count -eq 0) { throw "No $Edition image index in $WimPath" }
    # Mount + package expand stay under C:\LW-Lcu (no spaces). Under %TEMP%
    # (C:\Users\...), DISM fails 0x80070003 restoring Users\All Users.
    $mount = Join-Path 'C:\LW-Lcu' ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $mount | Out-Null
    $mountLog = 'C:\LW-Lcu\mount.log'
    $msuRoot = Join-Path 'C:\LW-Lcu' ('pkg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $msuRoot | Out-Null
    $dismScratch = if (-not [string]::IsNullOrWhiteSpace($ScratchDir)) { $ScratchDir } else { Join-Path 'C:\LW-Lcu' 'scratch' }
    New-Item -ItemType Directory -Force -Path $dismScratch | Out-Null
    $msuMounts = New-Object System.Collections.Generic.List[string]
    $applied = $false
    $keepFailLogs = $false
    try {
        $payloads = New-Object System.Collections.Generic.List[object]
        $lastSource = if ($PackagePaths.Count -gt 0) { [string]$PackagePaths[-1] } else { '' }
        foreach ($src in $PackagePaths) {
            if (-not (Test-Path -LiteralPath $src)) { throw "Package missing: $src" }
            $opened = Open-LwUpdatePackage -SourcePath $src -WorkRoot $msuRoot -Required:($src -eq $lastSource) -Log $Log
            if (-not [string]::IsNullOrWhiteSpace([string]$opened.MountDir)) { [void]$msuMounts.Add([string]$opened.MountDir) }
            foreach ($item in @($opened.Packages)) { [void]$payloads.Add($item) }
        }
        foreach ($idx in $indexes) {
            if ($Log) { & $Log ("Mounting install.wim index $idx") }
            $mountArgs = @(
                '/Mount-Image',
                (Format-LwDismArg 'ImageFile' $WimPath),
                "/Index:$idx",
                (Format-LwDismArg 'MountDir' $mount),
                (Format-LwDismArg 'LogPath' $mountLog),
                (Format-LwDismArg 'ScratchDir' $dismScratch)
            )
            & dism.exe @mountArgs 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $keepFailLogs = $true
                Save-LwLcuFailLogs -Paths @($mountLog)
                $detail = Get-LwDismLogDetail -Path $mountLog
                $u = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$LASTEXITCODE), 0)
                $hex = '0x{0:X8}' -f $u
                $suffix = if ($detail) { " $detail" } else { '' }
                throw "DISM /Mount-Image failed ($hex) index $idx.$suffix"
            }
            try {
                New-Item -ItemType Directory -Force -Path (Join-Path $mount 'Windows\Temp') | Out-Null
                foreach ($pkg in $payloads) {
                    $pkgPath = [string]$pkg.Path
                    $fileLabel = [string]$pkg.Label
                    # PSFX packages need the folder that holds update.mum + the .psf.
                    if ((Test-Path -LiteralPath $pkgPath -PathType Container)) {
                        $mum = Join-Path $pkgPath 'update.mum'
                        $psfHit = @(Get-ChildItem -LiteralPath $pkgPath -Filter '*.psf' -File -ErrorAction SilentlyContinue)
                        if ((Test-Path -LiteralPath $mum) -and $psfHit.Count -eq 0) {
                            throw "PSFX package folder for $fileLabel has update.mum but no .psf"
                        }
                    }
                    if ($Log) { & $Log ("Applying $fileLabel to install.wim index $idx") }
                    $addLog = Join-Path $msuRoot ("add-" + $fileLabel + "-$idx.log")
                    & dism.exe (Format-LwDismArg 'Image' $mount) /Add-Package (Format-LwDismArg 'PackagePath' $pkgPath) (Format-LwDismArg 'LogPath' $addLog) 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        $detail = Get-LwDismLogDetail -Path $addLog
                        $u = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$LASTEXITCODE), 0)
                        $hex = '0x{0:X8}' -f $u
                        $notApplicable = ($hex -eq '0x800F081E') -or ($detail -match '0x800f081e|not applicable')
                        if ($notApplicable -and -not $pkg.Required) {
                            if ($Log) { & $Log ("$fileLabel is not applicable to this image") }
                            continue
                        }
                        $keepFailLogs = $true
                        Save-LwLcuFailLogs -Paths @($addLog, $mountLog)
                        if ($notApplicable) { throw "$fileLabel is not applicable to this install image." }
                        $suffix = if ($detail) { " $detail" } else { '' }
                        throw "DISM /Add-Package failed ($hex) for $fileLabel.$suffix"
                    }
                    $applied = $true
                }
                Invoke-LwDismUnmount -MountDir $mount -Commit
            } catch {
                $keepFailLogs = $true
                Save-LwLcuFailLogs -Paths @(Get-ChildItem -LiteralPath $msuRoot -Filter 'add-*.log' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName})
                Save-LwLcuFailLogs -Paths @($mountLog, 'C:\LW-Lcu\unmount.log')
                try { Invoke-LwDismUnmount -MountDir $mount } catch {}
                throw
            }
        }
    } finally {
        foreach ($dir in $msuMounts) { Dismount-LwReadOnlyDir -MountDir $dir }
        Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
        if (-not $keepFailLogs -and -not [string]::IsNullOrWhiteSpace($msuRoot) -and (Test-Path -LiteralPath $msuRoot)) {
            Remove-Item -LiteralPath $msuRoot -Recurse -Force -ErrorAction SilentlyContinue
        } elseif ($keepFailLogs -and (Test-Path -LiteralPath $msuRoot)) {
            Save-LwLcuFailLogs -Paths @(Get-ChildItem -LiteralPath $msuRoot -Filter 'add-*.log' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            Remove-Item -LiteralPath $msuRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $applied) { throw 'No Windows package was applied to the install image.' }
}

function Get-LwWimOsBuild {
    param([Parameter(Mandatory)][string] $WimPath)
    $info = & dism.exe /Get-WimInfo (Format-LwDismArg 'WimFile' $WimPath) /English 2>&1 | Out-String
    $best = ''
    foreach ($hit in @([regex]::Matches($info, 'Version\s*:\s*\d+\.\d\.(\d+\.\d+)'))) {
        $tail = [string]$hit.Groups[1].Value
        if ((Compare-LwOsBuild -Left $best -Right $tail) -lt 0) { $best = $tail }
    }
    return $best
}

function Clear-LwLcuMounts {
    Import-Module Dism -ErrorAction SilentlyContinue
    foreach ($img in @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)) {
        $mountPath = [string]$img.Path
        if ($mountPath -like 'C:\LW-Lcu\*') {
            & dism.exe /Unmount-Image (Format-LwDismArg 'MountDir' $mountPath) /Discard 2>&1 | Out-Null
        }
    }
    if (Test-Path -LiteralPath 'C:\LW-Lcu') {
        Get-ChildItem -LiteralPath 'C:\LW-Lcu' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'last-fail' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Publish-LwServicedInstallToSet {
    # Replace install*.swm in the existing Image Ready set. The rest of the package stays.
    param(
        [Parameter(Mandatory)][string] $SetDir,
        [Parameter(Mandatory)][string] $WimPath,
        [Parameter(Mandatory)][string] $ScratchDir,
        [scriptblock] $Log
    )
    $splitLib = Join-Path $PSScriptRoot 'Split-LWImage.ps1'
    if (-not (Get-Command -Name Split-LWImageForFat32 -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $splitLib)) {
        . $splitLib
    }
    if (-not (Get-Command -Name Split-LWImageForFat32 -ErrorAction SilentlyContinue)) {
        throw "Missing Split-LWImageForFat32 ($splitLib)"
    }
    $outDir = Join-Path $ScratchDir 'swm-out'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $sourceDir = Split-Path -Parent $WimPath
    if ([IO.Path]::GetFileName($WimPath) -ine 'install.wim') {
        $sourceDir = Join-Path $ScratchDir 'wim-src'
        New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null
        Copy-Item -LiteralPath $WimPath -Destination (Join-Path $sourceDir 'install.wim') -Force
    }
    if ($Log) { & $Log 'Splitting the serviced install image over the existing Image Ready set' }
    # Bind $Log now. Split-LWImageForFat32 defines $log, and PowerShell variable
    # names are not case-sensitive, so a late lookup recurses until call depth overflows.
    $emitSplitLine = {
        param($m)
        if ($Log) { & $Log $m }
    }.GetNewClosure()
    Split-LWImageForFat32 -SourceSourcesDir $sourceDir -DestSourcesDir $outDir -Emit $emitSplitLine
    $chunkDir = if (Get-Command -Name Get-LWPreSplitChunkDir -ErrorAction SilentlyContinue) {
        Get-LWPreSplitChunkDir -SetDir $SetDir
    } else {
        Join-Path $SetDir 'sources'
    }
    if (-not (Test-Path -LiteralPath $chunkDir)) {
        throw "Image Ready install folder missing: $chunkDir"
    }
    $newFiles = @(Get-ChildItem -LiteralPath $outDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(?i)install(\d+)?\.(swm|wim|esd)$' } |
        Sort-Object Name)
    if ($newFiles.Count -eq 0) { throw "Split produced no install image in $outDir" }
    foreach ($f in $newFiles) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $chunkDir $f.Name) -Force
    }
    $keep = @($newFiles | ForEach-Object { $_.Name })
    Get-ChildItem -LiteralPath $chunkDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(?i)install(\d+)?\.(swm|wim|esd)$' -and ($keep -notcontains $_.Name) } |
        Remove-Item -Force -ErrorAction Stop
    $manPath = Join-Path $SetDir 'presplit-manifest.json'
    if (-not (Test-Path -LiteralPath $manPath)) { throw "presplit-manifest.json missing in $SetDir" }
    $man = Get-Content -Raw -LiteralPath $manPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $chunks = @()
    foreach ($f in $newFiles) {
        $onDisk = Get-Item -LiteralPath (Join-Path $chunkDir $f.Name)
        $chunks += [pscustomobject]@{ name = $onDisk.Name; sizeBytes = [long]$onDisk.Length; sha256 = $null }
    }
    if (-not $man.PSObject.Properties['install'] -or -not $man.install) {
        $man | Add-Member -NotePropertyName install -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $man.install | Add-Member -NotePropertyName chunks -NotePropertyValue $chunks -Force
    $man.install | Add-Member -NotePropertyName originalWimSizeBytes -NotePropertyValue ([long](Get-Item -LiteralPath $WimPath).Length) -Force
    $man.install | Add-Member -NotePropertyName sourceKind -NotePropertyValue 'wim' -Force
    $man | Add-Member -NotePropertyName updatedUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($manPath, ($man | ConvertTo-Json -Depth 8), $utf8)
    if (Get-Command -Name Test-LWPreSplitSet -ErrorAction SilentlyContinue) {
        $chk = Test-LWPreSplitSet -SetDir $SetDir
        if (-not $chk.Valid) { throw "Image Ready set invalid after install refresh: $($chk.Reason)" }
    }
    Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($Log) { & $Log ("Replaced $($newFiles.Count) install file(s) in $chunkDir") }
}

function Update-LwPreSplitLcuStamp {
    param(
        [Parameter(Mandatory)][string] $PreSplitRoot,
        [Parameter(Mandatory)][string] $SetDir,
        [Parameter(Mandatory)][string] $Arch,
        [string] $Edition = 'Pro',
        [Parameter(Mandatory)][string] $InstallLcuKb,
        [string] $OsBuild = ''
    )
    $splitLib = Join-Path $PSScriptRoot 'Split-LWImage.ps1'
    if (-not (Get-Command -Name Write-LWPreSplitCurrentMarkers -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $splitLib)) {
        . $splitLib
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $manPath = Join-Path $SetDir 'presplit-manifest.json'
    if (Test-Path -LiteralPath $manPath) {
        $man = Get-Content -Raw -LiteralPath $manPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $man | Add-Member -NotePropertyName installLcuKb -NotePropertyValue $InstallLcuKb -Force
        if (-not [string]::IsNullOrWhiteSpace($OsBuild)) {
            $man | Add-Member -NotePropertyName osBuild -NotePropertyValue $OsBuild -Force
        }
        [System.IO.File]::WriteAllText($manPath, ($man | ConvertTo-Json -Depth 8), $utf8)
    }
    $imageVersion = ''
    try { $imageVersion = [string](Split-Path -Leaf $SetDir) } catch { }
    if (Get-Command -Name Write-LWPreSplitCurrentMarkers -ErrorAction SilentlyContinue) {
        Write-LWPreSplitCurrentMarkers -PreSplitRoot $PreSplitRoot -SetDir $SetDir -Arch $Arch -Edition $Edition `
            -ImageVersion $imageVersion -InstallLcuKb $InstallLcuKb -OsBuild $OsBuild
    }
}

function Invoke-LwOfflineLcuInject {
    <#
      Servicing entry. Prefers -SourceWim. Otherwise reunites SetDir\sources\install.swm.
      Writes a serviced install.wim into -MediaDir\sources (media tree copied from the set, SWMs removed).
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('AMD64', 'ARM64')][string] $Arch,
        [ValidateSet('Home', 'Pro')][string] $Edition = 'Pro',
        [string] $Release = '',
        [string] $ImageVersion = '',
        [string] $SourceWim = '',
        [string] $SetDir = '',
        [string] $CacheRoot = '',
        [string] $ScratchRoot = '',
        [string] $MediaDir = '',
        [scriptblock] $Log
    )
    $rel = Get-LwReleaseFamilyLabel -Release $Release -ImageVersion $ImageVersion
    if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
        $CacheRoot = Join-Path $env:TEMP ("LW-LcuCache\" + $rel + '\' + $Arch)
    }
    if ([string]::IsNullOrWhiteSpace($ScratchRoot)) {
        $ScratchRoot = Join-Path $env:TEMP ('LW-LcuScratch-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    }
    New-Item -ItemType Directory -Force -Path $CacheRoot, $ScratchRoot | Out-Null
    $workWim = Join-Path $ScratchRoot 'install.wim'
    if (-not [string]::IsNullOrWhiteSpace($SourceWim) -and (Test-Path -LiteralPath $SourceWim)) {
        if ($Log) { & $Log "Copying install.wim for offline servicing" }
        Copy-Item -LiteralPath $SourceWim -Destination $workWim -Force
    } else {
        $swm = ''
        if (-not [string]::IsNullOrWhiteSpace($SetDir)) {
            $swm = Join-Path $SetDir 'sources\install.swm'
            if (-not (Test-Path -LiteralPath $swm)) { $swm = Join-Path $SetDir 'install.swm' }
        }
        if ([string]::IsNullOrWhiteSpace($swm) -or -not (Test-Path -LiteralPath $swm)) {
            throw "No install.wim or install.swm to service (SetDir '$SetDir')."
        }
        if ($Log) { & $Log "Reuniting install*.swm to a writable WIM" }
        Export-LwSwmSetToInstallWim -SwmPath $swm -DestWim $workWim -Log $Log | Out-Null
    }

    if ($Log) { & $Log ("Resolving latest cumulative update for Windows 11 $rel $Arch") }
    $pair = Select-LwCatalogLcuPair -Release $rel -Arch $Arch
    $pickedKb = 'cumulative update'
    if ($pair.Lcu.Title -match '(KB\d+)') { $pickedKb = $Matches[1] }
    $pickedBuild = ''
    if ($pair.Lcu.Title -match '\((\d+\.\d+)\)') { $pickedBuild = $Matches[1] }
    $pickedBuildBit = if ($pickedBuild) { " (OS build $pickedBuild)" } else { '' }
    if ($Log) { & $Log ("Selected $pickedKb$pickedBuildBit") }
    $packages = New-Object System.Collections.Generic.List[string]
    $ssuKb = ''
    if ($pair.Ssu) {
        $ssuSaved = Save-LwCatalogPackage -UpdateId $pair.Ssu.UpdateId -Title $pair.Ssu.Title -DestDir (Join-Path $CacheRoot 'SSU') -Log $Log
        $ssuKb = [string]$ssuSaved.Kb
        foreach ($f in @($ssuSaved.Files)) { [void]$packages.Add($f) }
    } elseif ($Log) {
        & $Log 'No separate servicing stack update on the catalog; applying the cumulative package (combined SSU+LCU on Windows 11 24H2+).'
    }
    $lcuSaved = Save-LwCatalogPackage -UpdateId $pair.Lcu.UpdateId -Title $pair.Lcu.Title -DestDir (Join-Path $CacheRoot 'LCU') -Log $Log
    $lcuKb = [string]$lcuSaved.Kb
    $imageBuild = Get-LwWimOsBuild -WimPath $workWim
    # KB5043080 is the 24H2 checkpoint (26100.2033). 25H2/26H2 images are already past it.
    # Opening that MSU next to KB5127648 makes DISM fail on ModelCompDB.xml (0x80070228).
    $skipCheckpoint = ($rel -match '^(?i)(25H2|26H2)$') -or ((Compare-LwOsBuild -Left '26100.2033' -Right $imageBuild) -lt 0)
    foreach ($f in @($lcuSaved.Files)) {
        $name = [IO.Path]::GetFileName([string]$f)
        if ($name -match [regex]::Escape($lcuKb)) { continue }
        if ($skipCheckpoint) {
            if ($Log) { & $Log ("Skipping checkpoint $(Get-LwPackageLabel -Name $name). Image is already $imageBuild.") }
            continue
        }
        [void]$packages.Add([string]$f)
    }
    foreach ($f in @($lcuSaved.Files)) {
        $name = [IO.Path]::GetFileName([string]$f)
        if ($name -match [regex]::Escape($lcuKb)) { [void]$packages.Add([string]$f) }
    }
    if ($packages.Count -eq 0) {
        foreach ($f in @($lcuSaved.Files)) {
            $name = [IO.Path]::GetFileName([string]$f)
            if ($skipCheckpoint -and $name -notmatch [regex]::Escape($lcuKb)) { continue }
            [void]$packages.Add([string]$f)
        }
    }
    if ($Log) { & $Log ("Applying $lcuKb to the install image") }
    Add-LwOfflinePackagesToWim -WimPath $workWim -PackagePaths $packages.ToArray() -Edition $Edition -ScratchDir (Join-Path $ScratchRoot 'dism') -Log $Log
    $osBuild = Get-LwWimOsBuild -WimPath $workWim

    $publishedSet = ''
    if (-not [string]::IsNullOrWhiteSpace($SetDir) -and (Test-Path -LiteralPath $SetDir)) {
        Publish-LwServicedInstallToSet -SetDir $SetDir -WimPath $workWim -ScratchDir $ScratchRoot -Log $Log
        $publishedSet = $SetDir
        if (Test-Path -LiteralPath $workWim) { Remove-Item -LiteralPath $workWim -Force -ErrorAction SilentlyContinue }
    } else {
        if ([string]::IsNullOrWhiteSpace($MediaDir)) {
            $MediaDir = Join-Path $ScratchRoot 'media'
        }
        if (Test-Path -LiteralPath $MediaDir) {
            Remove-Item -LiteralPath $MediaDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Force -Path $MediaDir | Out-Null
        $sources = Join-Path $MediaDir 'sources'
        New-Item -ItemType Directory -Force -Path $sources | Out-Null
        $installWim = Join-Path $sources 'install.wim'
        Move-Item -LiteralPath $workWim -Destination $installWim -Force
        $publishedSet = $MediaDir
    }

    return [pscustomobject]@{
        MediaDir     = $publishedSet
        InstallLcuKb = [string]$lcuSaved.Kb
        SsuKb        = $ssuKb
        OsBuild      = [string]$osBuild
        Release      = $rel
        WimPath      = $(if ($publishedSet -eq $SetDir) { '' } else { (Join-Path $publishedSet 'sources\install.wim') })
    }
}

function Copy-LwInstallSwmSetToVolume {
    # Replace sources\install*.swm on an existing stick. Does not partition or touch boot.wim.
    param(
        [Parameter(Mandatory)][string] $SetDir,
        [Parameter(Mandatory)][string] $VolumeRoot,
        [scriptblock] $Log
    )
    $src = Join-Path $SetDir 'sources'
    if (-not (Test-Path -LiteralPath (Join-Path $src 'install.swm'))) {
        $src = $SetDir
    }
    $swm = Join-Path $src 'install.swm'
    if (-not (Test-Path -LiteralPath $swm)) { throw "install.swm missing under $SetDir" }
    $destSources = Join-Path $VolumeRoot.TrimEnd('\') 'sources'
    if (-not (Test-Path -LiteralPath $destSources)) { throw "Stick sources folder missing: $destSources" }
    Get-ChildItem -LiteralPath $destSources -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(?i)install(\d+)?\.(swm|wim|esd)$' } |
        Remove-Item -Force -ErrorAction Stop
    if ($Log) { & $Log ("Refreshing install image from $src") }
    & robocopy.exe $src $destSources 'install*.swm' /R:2 /W:2 /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "robocopy failed (exit $LASTEXITCODE) copying install*.swm" }
    if (-not (Test-Path -LiteralPath (Join-Path $destSources 'install.swm'))) {
        throw 'install.swm was not copied to the stick'
    }
    $man = Join-Path $SetDir 'presplit-manifest.json'
    if (Test-Path -LiteralPath $man) {
        Copy-Item -LiteralPath $man -Destination (Join-Path $destSources 'presplit-manifest.json') -Force
    }
}
