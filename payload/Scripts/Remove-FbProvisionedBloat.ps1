#Requires -Version 5.1
<#
.SYNOPSIS
  Offline DISM strip of provisioned AppX bloat, then inject Default Start layout.

.NOTES
  WinPE-safe. Runs against an applied image root (e.g. W:\):
    1) dism /Remove-ProvisionedAppxPackage for Xbox / Solitaire / WhatsApp / LinkedIn
    2) Inject Users\Default\...\Shell\LayoutModification.json and clear stale Start bins
  Best-effort: individual failures are logged and do not fail the deploy.
#>
param(
    [Parameter(Mandatory)]
    [string]$ImagePath,

    [Parameter()]
    [string]$LogPath,

    [Parameter()]
    [string]$LayoutJsonPath
)

$ErrorActionPreference = 'Continue'
$FB_BloatRev = '1.1.0'

function Write-FbBloatLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = ('[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg)
    try { Write-Host $line } catch {}
    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }
    try {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

function Remove-FbProvisionedAppxMatches {
    param(
        [string]$Img,
        [string]$Dism
    )

    # Match PackageName from /Get-ProvisionedAppxPackages (Name_Version_Arch__PublisherId).
    $matchPatterns = @(
        '^Microsoft\.GamingApp_'
        '^Microsoft\.Xbox'
        '^Microsoft\.MicrosoftSolitaireCollection_'
        '^5319275A\.WhatsAppDesktop_'
        '(?i)WhatsApp'
        '^7EE7776C\.LinkedInforWindows_'
        '(?i)LinkedIn'
    )

    $getOut = @()
    try {
        $getOut = & $Dism ('/Image:{0}' -f $Img) '/Get-ProvisionedAppxPackages' '/English' 2>&1
    } catch {
        Write-FbBloatLog ("Get-ProvisionedAppxPackages threw: {0}" -f $_.Exception.Message) 'WARN'
        return
    }

    $getText = ($getOut | ForEach-Object { "$_" }) -join "`n"
    $packageNames = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($getText, '(?im)^\s*PackageName\s*:\s*(.+?)\s*$')) {
        $name = $m.Groups[1].Value.Trim()
        if ($name) { [void]$packageNames.Add($name) }
    }

    if ($packageNames.Count -eq 0) {
        Write-FbBloatLog 'No provisioned AppX packages listed (or DISM output unparsed); nothing to strip.' 'WARN'
        return
    }

    $targets = @(
        $packageNames |
            Where-Object {
                $pkg = $_
                foreach ($pat in $matchPatterns) {
                    if ($pkg -match $pat) { return $true }
                }
                return $false
            } |
            Sort-Object -Unique
    )

    if ($targets.Count -eq 0) {
        Write-FbBloatLog ('No matching provisioned AppX among {0} package(s).' -f $packageNames.Count)
        return
    }

    Write-FbBloatLog ('Removing {0} provisioned AppX package(s).' -f $targets.Count)
    $removed = 0
    $failed = 0
    foreach ($pkg in $targets) {
        Write-FbBloatLog ("Removing {0}" -f $pkg)
        $rmOut = @()
        $code = -1
        try {
            $rmOut = & $Dism ('/Image:{0}' -f $Img) '/Remove-ProvisionedAppxPackage' ("/PackageName:{0}" -f $pkg) '/English' 2>&1
            $code = [int]$LASTEXITCODE
        } catch {
            Write-FbBloatLog ("Remove threw for {0}: {1}" -f $pkg, $_.Exception.Message) 'WARN'
            $failed++
            continue
        }
        if ($code -eq 0) {
            $removed++
            Write-FbBloatLog ("Removed OK: {0}" -f $pkg)
        } else {
            $failed++
            $tail = (($rmOut | ForEach-Object { "$_" } | Select-Object -Last 3) -join ' | ')
            Write-FbBloatLog ("Remove failed exit={0} pkg={1} detail={2}" -f $code, $pkg, $tail) 'WARN'
        }
    }

    Write-FbBloatLog ("Offline AppX strip done removed={0} failed={1}" -f $removed, $failed)
}

function Set-FbDefaultStartLayout {
    param(
        [string]$Img,
        [string]$SourceJson
    )

    $shellDir = Join-Path $Img 'Users\Default\AppData\Local\Microsoft\Windows\Shell'
    try {
        if (-not (Test-Path -LiteralPath $shellDir)) {
            New-Item -ItemType Directory -Path $shellDir -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-FbBloatLog ("Could not create Default Shell folder: {0}" -f $_.Exception.Message) 'WARN'
        return
    }

    # Stale pin DBs / prior layouts can keep Xbox/Solitaire/etc. tiles for new users.
    foreach ($stale in @(
            'start.bin'
            'start2.bin'
            'LayoutModification.xml'
        )) {
        $p = Join-Path $shellDir $stale
        if (Test-Path -LiteralPath $p) {
            try {
                Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                Write-FbBloatLog ("Cleared stale Default Start file: {0}" -f $stale)
            } catch {
                Write-FbBloatLog ("Could not clear {0}: {1}" -f $stale, $_.Exception.Message) 'WARN'
            }
        }
    }

    $destJson = Join-Path $shellDir 'LayoutModification.json'
    $jsonText = $null
    if ($SourceJson -and (Test-Path -LiteralPath $SourceJson)) {
        try {
            $jsonText = [System.IO.File]::ReadAllText($SourceJson)
            Write-FbBloatLog ("Using layout source: {0}" -f $SourceJson)
        } catch {
            Write-FbBloatLog ("Could not read layout source: {0}" -f $_.Exception.Message) 'WARN'
        }
    }
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        $jsonText = @'
{
  "primaryOEMPins": [],
  "secondaryOEMPins": [],
  "firstRunOEMPins": []
}
'@
        Write-FbBloatLog 'Using embedded empty OEM Start layout.'
    }

    try {
        # UTF-8 without BOM — Start layout parser is picky about encoding.
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($destJson, $jsonText.Trim() + "`r`n", $utf8)
        Write-FbBloatLog ("Injected Default LayoutModification.json -> {0}" -f $destJson)
    } catch {
        Write-FbBloatLog ("Layout inject failed: {0}" -f $_.Exception.Message) 'WARN'
    }
}

$img = $ImagePath.TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($img)) {
    Write-FbBloatLog 'ImagePath is empty.' 'ERROR'
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $img 'Windows'))) {
    Write-FbBloatLog ("ImagePath does not look like a Windows image root: {0}" -f $img) 'ERROR'
    exit 1
}

$dism = Join-Path $env:SystemRoot 'System32\dism.exe'
if (-not (Test-Path -LiteralPath $dism)) { $dism = 'dism.exe' }

if ([string]::IsNullOrWhiteSpace($LayoutJsonPath)) {
    $LayoutJsonPath = Join-Path $PSScriptRoot 'LayoutModification.json'
}

Write-FbBloatLog ("Remove-FbProvisionedBloat rev={0} image={1}" -f $FB_BloatRev, $img)
Remove-FbProvisionedAppxMatches -Img $img -Dism $dism
Set-FbDefaultStartLayout -Img $img -SourceJson $LayoutJsonPath
Write-FbBloatLog 'Offline AppX strip + Default Start layout inject finished.'
exit 0
