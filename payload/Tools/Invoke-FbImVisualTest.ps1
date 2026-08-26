#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a mock LoneWolf USB tree and opens visual test windows for every
    operator-facing surface of the USB-root cleanup + fb-im WPF tool.
.DESCRIPTION
    Creates %TEMP%\LoneWolf-UsbVisualTest\<stamp>\ with the new layout:

      fb-im.cmd                         (visible)
      FirstBase\                        (hidden +H +S; includes FirstBase.ico)
      autorun.inf                       (root; icon=FirstBase\FirstBase.ico)
      sources\, EFI\, boot\, bootmgr... (hidden +H +S)

    Then launches separate consoles / WPF windows so each function can be exercised:

      [1] USB root listing (visible vs hidden)
      [2] WinPE banner - Updates + DEV
      [3] WinPE banner - No Updates + release
      [4] fb-im WPF status (clean host)
      [5] fb-im WPF status (simulated sealed)
      [6] fb-im WPF full window
      [7] fb-im WPF restart-updates focus
      [8] fb-im WPF collect-logs focus

    Use -NoLaunch to only build the mock tree and print its path.
#>
param(
    [switch] $NoLaunch,
    [string] $Root = ''
)

$ErrorActionPreference = 'Stop'
$PayloadRoot = Split-Path -Path $PSScriptRoot -Parent
if (-not $Root) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Root = Join-Path $env:TEMP ("LoneWolf-UsbVisualTest\{0}" -f $stamp)
}

function New-FbDir([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

Write-Host ''
Write-Host '  Building mock USB visual test environment...' -ForegroundColor Cyan
Write-Host ("  Root: {0}" -f $Root) -ForegroundColor DarkGray

# Wipe and recreate
if (Test-Path -LiteralPath $Root) {
    # Clear hidden attrs so Remove-Item can delete
    Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}
New-FbDir $Root

$fb = Join-Path $Root 'FirstBase'
New-FbDir $fb
New-FbDir (Join-Path $fb 'Deploy')
New-FbDir (Join-Path $fb 'WUPayload\Tools')
New-FbDir (Join-Path $fb 'Scripts')
New-FbDir (Join-Path $fb 'Policy')

# Windows media (will be hidden)
New-FbDir (Join-Path $Root 'sources')
New-FbDir (Join-Path $Root 'EFI\Boot')
New-FbDir (Join-Path $Root 'EFI\Microsoft\Boot')
New-FbDir (Join-Path $Root 'boot')
New-FbDir (Join-Path $Root 'support')
Set-Content -LiteralPath (Join-Path $Root 'sources\boot.wim') -Value 'mock-boot.wim' -Encoding ascii
Set-Content -LiteralPath (Join-Path $Root 'sources\install.wim') -Value 'mock-install.wim' -Encoding ascii
Set-Content -LiteralPath (Join-Path $Root 'bootmgr') -Value 'mock-bootmgr' -Encoding ascii
Set-Content -LiteralPath (Join-Path $Root 'bootmgr.efi') -Value 'mock-bootmgr.efi' -Encoding ascii
Set-Content -LiteralPath (Join-Path $Root 'setup.exe') -Value 'mock-setup' -Encoding ascii
[System.IO.File]::WriteAllText((Join-Path $Root 'autorun.inf'), "[autorun]`r`nicon=FirstBase\FirstBase.ico`r`n", [System.Text.Encoding]::ASCII)
Set-Content -LiteralPath (Join-Path $Root 'EFI\Boot\bootx64.efi') -Value 'mock-efi' -Encoding ascii
Set-Content -LiteralPath (Join-Path $Root 'boot\boot.sdi') -Value 'mock-sdi' -Encoding ascii

# Payload copies from live src
$copyMap = @(
    @{ Src = 'Deploy\Show-DeployBanner.ps1'; Dst = 'FirstBase\Deploy\Show-DeployBanner.ps1' },
    @{ Src = 'Deploy\TechInstall.cmd';     Dst = 'FirstBase\Deploy\TechInstall.cmd' },
    @{ Src = 'Deploy\WinPE-Startnet.cmd';   Dst = 'FirstBase\Deploy\WinPE-Startnet.cmd' },
    @{ Src = 'Tools\fb-im.cmd';             Dst = 'fb-im.cmd' },
    @{ Src = 'Tools\fb-im.ps1';             Dst = 'FirstBase\WUPayload\Tools\fb-im.ps1' },
    @{ Src = 'Tools\fb-dump.ps1';           Dst = 'FirstBase\WUPayload\Tools\fb-dump.ps1' },
    @{ Src = 'Show-UpdateProgress.ps1';     Dst = 'FirstBase\WUPayload\Show-UpdateProgress.ps1' },
    @{ Src = 'FirstBaseVersion.ps1';        Dst = 'FirstBase\WUPayload\FirstBaseVersion.ps1' },
    @{ Src = 'Policy\autounattend.xml';     Dst = 'FirstBase\Autounattend.xml' },
    @{ Src = 'FirstBase.ico';               Dst = 'FirstBase\FirstBase.ico' }
)
foreach ($m in $copyMap) {
    $src = Join-Path $PayloadRoot $m.Src
    $dst = Join-Path $Root $m.Dst
    New-FbDir (Split-Path $dst -Parent)
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $dst -Force
    } else {
        Write-Host ("  WARN missing src: {0}" -f $src) -ForegroundColor Yellow
    }
}

# Leftover root ico from older mock trees: clear attrs then delete (matches destage).
$rootIco = Join-Path $Root 'FirstBase.ico'
if (Test-Path -LiteralPath $rootIco) {
    & attrib.exe -H -S -R $rootIco 2>$null | Out-Null
    Remove-Item -LiteralPath $rootIco -Force -ErrorAction SilentlyContinue
}

# Dev stamp (DEV banner + stick identity)
$stamp = [ordered]@{
    builtBy              = 'LoneWolfLauncher'
    workflowType         = 'LoneWolf'
    version              = '5.3.1'
    scriptVersion        = '5.3.1'
    builtAt              = (Get-Date -Format 'o')
    diskNumber           = 0
    devBuild             = $true
    launcherVersion      = '5.3.1'
    shareLauncherVersion = '5.3.0'
    shareScriptVersion   = '5.3.0'
} | ConvertTo-Json -Compress
Set-Content -LiteralPath (Join-Path $fb 'LW_VERSION.json') -Value $stamp -Encoding utf8
$devMarker = "devBuild=1`r`nlauncherVersion=5.3.1`r`nscriptVersion=5.3.1`r`n"
[System.IO.File]::WriteAllText((Join-Path $fb 'WUPayload\.dev-build'), $devMarker)

# Release stamp sibling for banner release test
$releaseDir = Join-Path $Root '_release-stamp-parent\Deploy'
New-FbDir $releaseDir
Copy-Item (Join-Path $PayloadRoot 'Deploy\Show-DeployBanner.ps1') (Join-Path $releaseDir 'Show-DeployBanner.ps1') -Force
$relStamp = [ordered]@{
    builtBy = 'LoneWolfLauncher'; version = '5.3.0'; scriptVersion = '5.3.0'
    devBuild = $false; launcherVersion = '5.3.0'
    shareLauncherVersion = '5.3.0'; shareScriptVersion = '5.3.0'
} | ConvertTo-Json -Compress
Set-Content -LiteralPath (Join-Path $Root '_release-stamp-parent\LW_VERSION.json') -Value $relStamp -Encoding utf8

# Hide Windows media + FirstBase payload folder; keep fb-im.cmd visible
$hideNames = @(
    'boot', 'bootmgr', 'bootmgr.efi', 'setup.exe', 'autorun.inf',
    'sources', 'efi', 'EFI', 'support', 'Support', 'FirstBase'
)
foreach ($name in $hideNames) {
    $p = Join-Path $Root $name
    if (Test-Path -LiteralPath $p) {
        & attrib.exe +H +S $p /D 2>$null | Out-Null
    }
}
foreach ($keep in @('fb-im.cmd')) {
    $p = Join-Path $Root $keep
    if (Test-Path -LiteralPath $p) {
        & attrib.exe -H -S $p /D 2>$null | Out-Null
    }
}

# Harness helpers stay on disk but hidden so TEST 1 matches the real operator view
foreach ($helper in @('_list-root.ps1', '_status-sealed.ps1', '_release-stamp-parent')) {
    $p = Join-Path $Root $helper
    if (Test-Path -LiteralPath $p) {
        & attrib.exe +H +S $p /D 2>$null | Out-Null
    }
}

# Manifest for the harness
$manifest = @{
    root = $Root
    visible = @('fb-im.cmd')
    hidden = $hideNames
    createdAt = (Get-Date -Format 'o')
} | ConvertTo-Json -Depth 4
Set-Content -LiteralPath (Join-Path $Root 'FirstBase-Layout.txt') -Value $manifest -Encoding utf8

Write-Host '  Mock USB ready.' -ForegroundColor Green
Write-Host ''

# ---- Listing helper script written next to the tree ----
$listScript = Join-Path $Root '_list-root.ps1'
@'
param([string]$UsbRoot)
$ErrorActionPreference = "Continue"
Clear-Host
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "  USB ROOT  -  what Explorer shows vs what is hidden" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ("  {0}" -f $UsbRoot) -ForegroundColor DarkGray
Write-Host ""
Write-Host "  VISIBLE (no Hidden attribute):" -ForegroundColor Green
Get-ChildItem -LiteralPath $UsbRoot -Force | Where-Object {
    -not ($_.Attributes -band [IO.FileAttributes]::Hidden)
} | ForEach-Object {
    $kind = if ($_.PSIsContainer) { "<DIR>" } else { "     " }
    Write-Host ("    {0}  {1}" -f $kind, $_.Name) -ForegroundColor White
}
Write-Host ""
Write-Host "  HIDDEN (Hidden+System - Windows install media):" -ForegroundColor DarkGray
Get-ChildItem -LiteralPath $UsbRoot -Force | Where-Object {
    $_.Attributes -band [IO.FileAttributes]::Hidden
} | ForEach-Object {
    $kind = if ($_.PSIsContainer) { "<DIR>" } else { "     " }
    Write-Host ("    {0}  {1}" -f $kind, $_.Name) -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  FirstBase\ contents (payload):" -ForegroundColor Cyan
Get-ChildItem -LiteralPath (Join-Path $UsbRoot "FirstBase") -Force | ForEach-Object {
    $kind = if ($_.PSIsContainer) { "<DIR>" } else { "     " }
    Write-Host ("    {0}  {1}" -f $kind, $_.Name) -ForegroundColor Gray
}
Write-Host ""
Write-Host "  Expected visible root: fb-im.cmd only (FirstBase is hidden)" -ForegroundColor Yellow
Write-Host "  (ignore _list-root.ps1 / _release-stamp-parent / harness helpers)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Press Enter to close..." -ForegroundColor DarkGray
[void][Console]::ReadLine()
'@ | Set-Content -LiteralPath $listScript -Encoding UTF8

$sealedScript = Join-Path $Root '_status-sealed.ps1'
@'
param([string]$ImPs1)
$ErrorActionPreference = "Continue"
$pd = "C:\ProgramData\FirstBase"
if (-not (Test-Path $pd)) { New-Item -ItemType Directory -Path $pd -Force | Out-Null }
$sealed = Join-Path $pd ".firstbase-sealed"
$pipe = Join-Path $pd ".pipeline-completed"
$hadSealed = Test-Path $sealed
$hadPipe = Test-Path $pipe
try {
    Set-Content -LiteralPath $pipe -Value ("Pipeline completed at {0} (visual test)." -f (Get-Date -Format "o")) -Force
    Set-Content -LiteralPath $sealed -Value ("Sealed at {0} (visual test); device ready for pack/ship after shutdown." -f (Get-Date -Format "o")) -Force
    & $ImPs1 -Action Status
} finally {
    if (-not $hadSealed) { Remove-Item -LiteralPath $sealed -Force -ErrorAction SilentlyContinue }
    if (-not $hadPipe) { Remove-Item -LiteralPath $pipe -Force -ErrorAction SilentlyContinue }
}
'@ | Set-Content -LiteralPath $sealedScript -Encoding UTF8

if ($NoLaunch) {
    Write-Host ("  Mock path: {0}" -f $Root)
    return $Root
}

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$banner = Join-Path $Root 'FirstBase\Deploy\Show-DeployBanner.ps1'
$imPs1 = Join-Path $Root 'FirstBase\WUPayload\Tools\fb-im.ps1'
$releaseBanner = Join-Path $Root '_release-stamp-parent\Deploy\Show-DeployBanner.ps1'

function Start-FbTestWindow {
    param(
        [string] $Title,
        [string] $Command,
        [switch] $Sta
    )
    $scriptBody = @"
`$Host.UI.RawUI.WindowTitle = '$Title'
$Command
"@
    $tmp = Join-Path $env:TEMP ("fb-im-test-{0}.ps1" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    Set-Content -LiteralPath $tmp -Value $scriptBody -Encoding UTF8
    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.Add('-NoExit')
    $argList.Add('-NoProfile')
    if ($Sta) { $argList.Add('-STA') }
    $argList.Add('-ExecutionPolicy')
    $argList.Add('Bypass')
    $argList.Add('-File')
    $argList.Add($tmp)
    Start-Process -FilePath $ps -ArgumentList $argList.ToArray() -WorkingDirectory $Root | Out-Null
    Start-Sleep -Milliseconds 350
}

Write-Host '  Launching visual test windows...' -ForegroundColor Cyan

# 1. Root listing
Start-FbTestWindow 'TEST 1 - USB root visible vs hidden' (
    "& '$listScript' -UsbRoot '$Root'"
)

# 2. Banner DEV / Updates
Start-FbTestWindow 'TEST 2 - WinPE banner DEV + Updates' (
    "& '$banner' -Subtitle 'Updates'; Write-Host ''; Write-Host '  Press Enter to close...' -ForegroundColor DarkGray; [void][Console]::ReadLine()"
)

# 3. Banner release / No Updates
Start-FbTestWindow 'TEST 3 - WinPE banner release + No Updates' (
    "& '$releaseBanner' -Subtitle 'No Updates'; Write-Host ''; Write-Host '  Press Enter to close...' -ForegroundColor DarkGray; [void][Console]::ReadLine()"
)

# 4. fb-im WPF status (host as-is)
Start-FbTestWindow -Sta 'TEST 4 - fb-im WPF status (not sealed)' (
    "& '$imPs1' -Action Status"
)

# 5. fb-im WPF status sealed simulation
Start-FbTestWindow -Sta 'TEST 5 - fb-im WPF status (simulated sealed)' (
    "& '$sealedScript' -ImPs1 '$imPs1'"
)

# 6. Full WPF window
Start-FbTestWindow -Sta 'TEST 6 - fb-im WPF technician window' (
    "& '$imPs1' -Action Menu"
)

# 7. Restart-updates focus (auto-attempts restart on open)
Start-FbTestWindow -Sta 'TEST 7 - fb-im WPF restart updates' (
    "& '$imPs1' -Action Updates"
)

# 8. Collect-logs focus (notes box ready)
Start-FbTestWindow -Sta 'TEST 8 - fb-im WPF collect logs' (
    "& '$imPs1' -Action Dump"
)

Write-Host ''
Write-Host '  Eight test windows opened:' -ForegroundColor Green
Write-Host '    [1] USB root visible vs hidden'
Write-Host '    [2] WinPE banner  DEV + Updates'
Write-Host '    [3] WinPE banner  release + No Updates'
Write-Host '    [4] fb-im WPF status  (not sealed)'
Write-Host '    [5] fb-im WPF status  (simulated sealed / READY TO PACK)'
Write-Host '    [6] fb-im WPF technician window'
Write-Host '    [7] fb-im WPF restart updates  (focus + auto-start attempt)'
Write-Host '    [8] fb-im WPF collect logs  (notes box focused)'
Write-Host ''
Write-Host ("  Mock stick: {0}" -f $Root) -ForegroundColor DarkGray
Write-Host '  Explorer tip: open that folder with "Hidden items" OFF to see operator view.' -ForegroundColor Yellow
Write-Host ''

return $Root
