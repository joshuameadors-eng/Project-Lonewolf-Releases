#Requires -Version 5.1
<#
  Compile LoneWolf-Launcher-Setup.exe (Framework 4.8 WinForms host + embedded PS1).
  If electron-builder NSIS/portable exist in dist/, rename inner NSIS and append
  a zip overlay so the bootstrapper does not need a second download.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$OutputExe = '',
    [switch]$SkipOverlay
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }

$csc = Join-Path ${env:WINDIR} 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe not found: $csc (.NET Framework 4.8 targeting pack)" }

$dist = Join-Path $RepoRoot 'dist'
if (-not (Test-Path -LiteralPath $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }

$outExe = if ($OutputExe) { $OutputExe } else { Join-Path $dist 'LoneWolf-Launcher-Setup.exe' }
$outDir = Split-Path $outExe -Parent
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$nsisOut = Join-Path $dist 'LoneWolf-Launcher-Setup.exe'
$inner = Join-Path $dist 'LoneWolf-Launcher-Nsis.exe'
if (-not $OutputExe) {
    if ((Test-Path -LiteralPath $nsisOut) -and -not (Test-Path -LiteralPath $inner)) {
        if ((Get-Item -LiteralPath $nsisOut).Length -gt 2MB) {
            Move-Item -LiteralPath $nsisOut -Destination $inner -Force
            Write-Host "Moved electron-builder NSIS to $inner"
        }
    }
}

$icon = Join-Path $RepoRoot 'assets\icon.ico'
$hostCs = Join-Path $RepoRoot 'installer\LoneWolfSetupHost.cs'
$manifest = Join-Path $RepoRoot 'installer\app.manifest'
$ps1 = Join-Path $RepoRoot 'installer\Install-LoneWolfLauncher.ps1'

$sidebar = Join-Path $RepoRoot 'build\installerSidebar.bmp'
$rtJson = Join-Path $RepoRoot 'installer\dotnet-runtime.json'
$cscArgs = @(
    '/nologo', '/t:winexe', '/platform:x64',
    "/out:$outExe",
    "/win32manifest:$manifest",
    "/resource:$ps1,Install-LoneWolfLauncher.ps1",
    '/r:System.Windows.Forms.dll',
    '/r:System.Drawing.dll',
    '/r:System.IO.Compression.dll',
    '/r:System.IO.Compression.FileSystem.dll',
    $hostCs
)
if (Test-Path -LiteralPath $icon) { $cscArgs = @("/resource:$icon,icon.ico") + $cscArgs }
if (Test-Path -LiteralPath $sidebar) { $cscArgs = @("/resource:$sidebar,installerSidebar.bmp") + $cscArgs }
if (Test-Path -LiteralPath $rtJson) { $cscArgs = @("/resource:$rtJson,dotnet-runtime.json") + $cscArgs }
if (Test-Path -LiteralPath $icon) { $cscArgs = @("/win32icon:$icon") + $cscArgs }

& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc failed: $LASTEXITCODE" }

if (-not $SkipOverlay) {
    $portable = Join-Path $dist 'LoneWolf-Launcher.exe'
    $pack = @()
    if (Test-Path -LiteralPath $inner) { $pack += @{ Name = 'LoneWolf-Launcher-Nsis.exe'; Path = $inner } }
    if (Test-Path -LiteralPath $portable) { $pack += @{ Name = 'LoneWolf-Launcher.exe'; Path = $portable } }
    if ($pack.Count -gt 0) {
        $stage = Join-Path $env:TEMP ('lw-overlay-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        foreach ($f in $pack) {
            Copy-Item -LiteralPath $f.Path -Destination (Join-Path $stage $f.Name) -Force
        }
        $zip = Join-Path $env:TEMP ('lw-overlay-' + [guid]::NewGuid().ToString('n') + '.zip')
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
        $zipBytes = [System.IO.File]::ReadAllBytes($zip)
        $lenBytes = [BitConverter]::GetBytes([int64]$zipBytes.LongLength)
        $magic = [Text.Encoding]::ASCII.GetBytes('LWPAYLOAD1')
        $fs = [System.IO.File]::Open($outExe, 'Append', 'Write')
        try {
            $fs.Write($zipBytes, 0, $zipBytes.Length)
            $fs.Write($lenBytes, 0, $lenBytes.Length)
            $fs.Write($magic, 0, $magic.Length)
        } finally { $fs.Close() }
        Remove-Item -LiteralPath $zip, $stage -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Appended overlay ($($pack.Count) file(s)) to $outExe"
    } else {
        Write-Host 'No NSIS/portable in dist — Setup.exe will download LoneWolf-Launcher.exe from public Releases at install time.'
    }
}

Write-Host "Bootstrapper: $outExe ($((Get-Item $outExe).Length) bytes)"
