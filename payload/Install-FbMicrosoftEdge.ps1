# Install Microsoft Edge from the USB payload (UUP ISOs often omit it).
# Run as -File from SetupComplete, or dot-source and call Install-FbMicrosoftEdge.
# No param() block — this file is also dot-sourced from the WU loop.
# For Internal Use Only.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Write-FbEdgeLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('[{0}] [{1}] {2}' -f (Get-Date -Format 'o'), $Level, $Message)
    $roots = @(
        'C:\Windows\Setup\FirstBase\Logs'
        'C:\ProgramData\FirstBase'
    )
    foreach ($dir in $roots) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Add-Content -LiteralPath (Join-Path $dir 'Install-FbMicrosoftEdge.log') -Value $line -Encoding ascii -ErrorAction SilentlyContinue
        } catch {}
    }
    $sc = 'C:\Windows\Setup\FirstBase\Logs\SetupComplete.log'
    try {
        if (Test-Path -LiteralPath $sc) {
            Add-Content -LiteralPath $sc -Value ('[edge] {0}' -f $line) -Encoding ascii -ErrorAction SilentlyContinue
        }
    } catch {}
    if (Get-Command -Name Write-FbLog -ErrorAction SilentlyContinue) {
        try { Write-FbLog ("Edge: {0}" -f $Message) $Level } catch {}
    }
    if (Get-Command -Name Write-FbManualSettingsFinishLog -ErrorAction SilentlyContinue) {
        try { Write-FbManualSettingsFinishLog ("Edge: {0}" -f $Message) $Level } catch {}
    }
}

function Test-FbMicrosoftEdgePresent {
    $hits = @(
        (Join-Path ${env:ProgramFiles} 'Microsoft\Edge\Application\msedge.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($p in $hits) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    foreach ($appKey in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )) {
        try {
            $item = Get-Item -LiteralPath $appKey -ErrorAction SilentlyContinue
            if ($item) {
                $def = [string]$item.GetValue('')
                if (-not [string]::IsNullOrWhiteSpace($def)) {
                    $def = $def.Trim('"')
                    if (Test-Path -LiteralPath $def) { return $def }
                }
            }
        } catch {}
    }
    return $null
}

function Get-FbEdgeNativeArch {
    $a = [string]$env:PROCESSOR_ARCHITECTURE
    if ($a -match 'ARM') { return 'ARM64' }
    return 'AMD64'
}

function Get-FbEdgeInstallerSearchRoots {
    $arch = Get-FbEdgeNativeArch
    $roots = New-Object System.Collections.Generic.List[string]
    $bases = @(
        'C:\Windows\Setup\FirstBase\Edge'
        'C:\Windows\Setup\FirstBase\WUPayload\Edge'
        'C:\ProgramData\FirstBase\Edge'
    )
    if ($PSScriptRoot) {
        $bases += (Join-Path $PSScriptRoot 'Edge')
    }
    foreach ($b in $bases) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        [void]$roots.Add((Join-Path $b $arch))
        [void]$roots.Add($b)
    }
    return @($roots)
}

function Find-FbEdgeOfflineInstaller {
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($root in @(Get-FbEdgeInstallerSearchRoots)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -match '\.(msi|exe)$' -and $_.Name -match 'edge' })) {
                [void]$files.Add($f.FullName)
            }
        } catch {}
    }
    $msi = @($files | Where-Object { $_ -match '\.msi$' })
    if ($msi.Count -gt 0) { return $msi[0] }
    if ($files.Count -gt 0) { return $files[0] }
    return $null
}

function Get-FbEdgeEnterpriseMsiUrl {
    param([string]$Arch)
    $want = if ($Arch -match 'ARM') { 'arm64' } else { 'x64' }
    try {
        $products = Invoke-RestMethod -Uri 'https://edgeupdates.microsoft.com/api/products?view=enterprise' -TimeoutSec 60
        $stable = @($products | Where-Object { [string]$_.Product -eq 'Stable' } | Select-Object -First 1)
        foreach ($product in $stable) {
            foreach ($rel in @($product.Releases)) {
                $plat = [string]$rel.Platform
                $a = [string]$rel.Architecture
                if ($plat -notmatch '(?i)Windows') { continue }
                if ($a -notmatch ("(?i)^{0}$" -f [regex]::Escape($want))) { continue }
                foreach ($art in @($rel.Artifacts)) {
                    $name = [string]$art.ArtifactName
                    $loc = [string]$art.Location
                    if ($name -match '(?i)msi' -and -not [string]::IsNullOrWhiteSpace($loc)) {
                        return $loc
                    }
                }
            }
        }
    } catch {
        Write-FbEdgeLog ("Edge updates API failed: {0}" -f $_.Exception.Message) 'WARN'
    }
    if ($want -eq 'x64') {
        return 'https://go.microsoft.com/fwlink/?linkid=2093437'
    }
    return $null
}

function Get-FbEdgeDownloadDir {
    $dir = 'C:\Windows\Setup\FirstBase\Edge'
    $arch = Get-FbEdgeNativeArch
    $dir = Join-Path $dir $arch
    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        $dir = Join-Path $env:TEMP ('FirstBaseEdge-' + $arch)
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
    return $dir
}

function Save-FbEdgeEnterpriseMsi {
    $arch = Get-FbEdgeNativeArch
    $url = Get-FbEdgeEnterpriseMsiUrl -Arch $arch
    if ([string]::IsNullOrWhiteSpace($url)) {
        Write-FbEdgeLog ("No Edge MSI URL for {0}. Stage MicrosoftEdgeEnterprise{1}.msi under Edge\{0}\ on the share." -f $arch, $(if ($arch -eq 'ARM64') { 'ARM64' } else { 'X64' })) 'ERROR'
        return $null
    }
    $dir = Get-FbEdgeDownloadDir
    $leaf = if ($arch -eq 'ARM64') { 'MicrosoftEdgeEnterpriseARM64.msi' } else { 'MicrosoftEdgeEnterpriseX64.msi' }
    $out = Join-Path $dir $leaf
    Write-FbEdgeLog ("Downloading Edge Enterprise MSI ({0}) from {1}" -f $arch, $url) 'INFO'
    try {
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 180
    } catch {
        Write-FbEdgeLog ("Edge MSI download failed: {0}" -f $_.Exception.Message) 'ERROR'
        return $null
    }
    if (-not (Test-Path -LiteralPath $out)) { return $null }
    $len = 0
    try { $len = [int64](Get-Item -LiteralPath $out).Length } catch {}
    if ($len -lt 1000000) {
        Write-FbEdgeLog ("Downloaded Edge installer is too small ({0} bytes); ignoring." -f $len) 'ERROR'
        try { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue } catch {}
        return $null
    }
    Write-FbEdgeLog ("Downloaded Edge MSI ({0} bytes) -> {1}" -f $len, $out) 'INFO'
    return $out
}

function Invoke-FbEdgeInstallerFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $ext = [IO.Path]::GetExtension($Path)
    Write-FbEdgeLog ("Running Edge installer {0}" -f $Path) 'INFO'
    try {
        if ($ext -ieq '.msi') {
            $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList @('/i', $Path, '/qn', '/norestart', 'ALLUSERS=1', 'DONOTCREATEDESKTOPSHORTCUT=1') -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            Write-FbEdgeLog ("msiexec exit={0}" -f $p.ExitCode) 'INFO'
            return ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010)
        }
        $p = Start-Process -FilePath $Path -ArgumentList @('/silent', '/install') -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        Write-FbEdgeLog ("Edge setup.exe exit={0}" -f $p.ExitCode) 'INFO'
        return ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010)
    } catch {
        Write-FbEdgeLog ("Edge installer threw: {0}" -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Install-FbMicrosoftEdge {
    param(
        [switch]$AllowDownload = $true,
        [switch]$Force
    )
    $existing = Test-FbMicrosoftEdgePresent
    if ($existing -and -not $Force) {
        Write-FbEdgeLog ("Edge already present: {0}" -f $existing) 'INFO'
        return [pscustomobject]@{ Present = $true; Path = $existing; Installed = $false; Source = 'already-present' }
    }

    $installer = Find-FbEdgeOfflineInstaller
    $source = 'payload'
    if (-not $installer -and $AllowDownload) {
        $installer = Save-FbEdgeEnterpriseMsi
        $source = 'download'
    }
    if (-not $installer) {
        Write-FbEdgeLog 'No Edge offline installer on the image and download was unavailable. YouTube PASS needs Edge. Stage Edge\AMD64 or Edge\ARM64 on the share (MicrosoftEdgeEnterpriseX64.msi / MicrosoftEdgeEnterpriseARM64.msi).' 'ERROR'
        $existing = Test-FbMicrosoftEdgePresent
        return [pscustomobject]@{ Present = [bool]$existing; Path = $existing; Installed = $false; Source = 'missing' }
    }

    $ok = Invoke-FbEdgeInstallerFile -Path $installer
    $path = Test-FbMicrosoftEdgePresent
    if ($path) {
        Write-FbEdgeLog ("Edge ready after {0} install: {1}" -f $source, $path) 'INFO'
        return [pscustomobject]@{ Present = $true; Path = $path; Installed = $true; Source = $source }
    }
    Write-FbEdgeLog ("Edge installer ran (ok={0}) but msedge.exe was not found." -f $ok) 'ERROR'
    return [pscustomobject]@{ Present = $false; Path = $null; Installed = $false; Source = $source }
}

if ($MyInvocation.InvocationName -ne '.') {
    $allow = $true
    $force = $false
    foreach ($a in @($args)) {
        $s = [string]$a
        if ($s -match '(?i)^-AllowDownload:?False$') { $allow = $false }
        if ($s -match '(?i)^-Force$') { $force = $true }
    }
    $result = Install-FbMicrosoftEdge -AllowDownload:$allow -Force:$force
    if ($result -and $result.Present) { exit 0 }
    exit 1
}
