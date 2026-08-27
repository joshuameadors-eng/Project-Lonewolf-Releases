<#
.SYNOPSIS
  Checks public GitHub Releases for a newer LoneWolf Launcher exe.
  Used by Project LoneWolf Launcher for self-update detection.

.DESCRIPTION
  Reads latest.json from the public Project-Lonewolf-Releases source tree
  (raw.githubusercontent.com, unauthenticated). Launcher Update uses the
  portable exe in that tree. Setup is first-install only (stable tag installer).
  Does not use the ISO staging share for versioning or exe.

.OUTPUTS
  JSON: updateAvailable, currentVersion, latestVersion, exeName, exePath (HTTPS URL).
#>

param(
    [string]$CurrentVersion,
    [string]$LatestJsonUrl = 'https://raw.githubusercontent.com/joshuameadors-eng/Project-Lonewolf-Releases/main/latest.json'
)

$ErrorActionPreference = 'SilentlyContinue'

function Compare-SemVer {
    param([string]$a, [string]$b)
    try {
        $va = [version]($a -replace '[^0-9.]', '')
        $vb = [version]($b -replace '[^0-9.]', '')
        return $va.CompareTo($vb)
    } catch {
        return 0
    }
}

$output = [ordered]@{
    updateAvailable = $false
    devBuild        = $false
    launcherAhead   = $false
    scriptAhead     = $false
    currentVersion  = $CurrentVersion
    latestVersion   = $CurrentVersion
    shareScriptVersion = $null
    payloadVersion  = $null
    exeName         = 'LoneWolf-Launcher.exe'
    exePath         = $null
    setupUrl        = $null
    source          = 'github-public-release'
    channel         = $null
}

try {
    $headers = @{ 'User-Agent' = 'LoneWolf-Launcher-UpdateCheck' }
    $vj = Invoke-RestMethod -Uri $LatestJsonUrl -Headers $headers -Method Get
    if ($vj -is [string]) {
        $vj = ($vj.TrimStart([char]0xFEFF).Trim() | ConvertFrom-Json)
    }
    $latestVersion = if ($vj.launcherVersion) { [string]$vj.launcherVersion } else { $CurrentVersion }
    $payload = if ($vj.payloadVersion) { [string]$vj.payloadVersion } else { $null }
    $exeName = 'LoneWolf-Launcher.exe'
    $exeUrl = $null
    $setupUrl = $null
    if ($vj.urls -and $vj.urls.portable) { $exeUrl = [string]$vj.urls.portable }
    else {
        $exeUrl = 'https://raw.githubusercontent.com/joshuameadors-eng/Project-Lonewolf-Releases/main/bin/LoneWolf-Launcher.exe'
    }
    if ($vj.urls -and $vj.urls.setup) { $setupUrl = [string]$vj.urls.setup }
    else {
        $setupUrl = 'https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/download/installer/LoneWolf-Launcher-Setup.exe'
    }

    $output.latestVersion = $latestVersion
    $output.exeName = $exeName
    $output.setupUrl = $setupUrl
    $output.payloadVersion = $payload
    $output.shareScriptVersion = $payload
    $output.channel = if ($vj.channel) { [string]$vj.channel } else { 'release' }

    if ($latestVersion -and $CurrentVersion) {
        $cmp = Compare-SemVer $latestVersion $CurrentVersion
        if ($cmp -gt 0) {
            $output.updateAvailable = $true
            $output.exePath = $exeUrl
        } elseif ($cmp -lt 0) {
            $output.launcherAhead = $true
        }
    }
} catch {
    $output.error = $_.Exception.Message
}

$output | ConvertTo-Json -Compress -Depth 3
