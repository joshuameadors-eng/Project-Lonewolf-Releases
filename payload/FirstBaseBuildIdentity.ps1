<#
    FirstBaseBuildIdentity.ps1  (Project LoneWolf)

    Single source of truth for "is this a dev build?" and the version numbers
    that go beside that answer. Dot-sourced by every surface that shows a DEV
    marker: the WinPE banner and deploy screen, the on-device updates splash,
    the handoff splash, and the fb-im technician tool.

    WHY THIS FILE EXISTS
    The same question used to be answered four different ways. Three of them
    read the build stamp; the fourth also treated $FirstBaseBuildStatus from
    FirstBaseVersion.ps1 as a dev signal. That variable is a checked-in
    constant - it cannot know how a given stick was built - so every release
    build inherited whatever value happened to be committed and wrongly showed
    a DEV marker. Build status is a property of the BUILD, so it may only come
    from artifacts the builder stamps per build.

    THE TWO AUTHORITATIVE SIGNALS (in order)
      1. LW_VERSION.json  - written by both builders on every build. Carries
         devBuild plus the launcher/script versions and the share versions the
         dev comparison was made against.
      2. .dev-build       - a key=value marker the builders write ONLY when
         -DevBuild is set. Present at <root>\.dev-build on a device (staged by
         TechInstall) and <root>\WUPayload\.dev-build on a stick.

    RELEASE-SAFE BY DEFAULT: absent or unreadable signals mean release. A dev
    stick missing its pill is cosmetic; a release device claiming DEV is the
    bug this file exists to prevent.

    Must stay usable in the WinPE PowerShell 5.1 restricted runspace: no
    classes, no modules, no external calls, and it never throws.
#>

function Get-FbBuildIdentity {
    <#
        -PayloadRoot : one or more directories to probe, most authoritative
                       first. Callers pass whatever they know:
                         WinPE banner / deploy UI - parent of Deploy\, then the volume root
                         on-device splashes       - C:\Windows\Setup\FirstBase
                         fb-im                    - stick payload root, then the device root
    #>
    param([string[]] $PayloadRoot)

    $info = [ordered]@{
        Dev           = $false
        Launcher      = ''
        Script        = ''
        ShareLauncher = ''
        ShareScript   = ''
        Source        = ''   # which signal decided Dev; '' when none was found
    }

    $roots = @()
    foreach ($r in @($PayloadRoot)) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $roots += ([string]$r).TrimEnd('\')
    }
    if ($roots.Count -eq 0) { return $info }

    # --- Signal 1: LW_VERSION.json -------------------------------------------
    # First readable stamp wins for the version numbers, so the nearest root is
    # authoritative rather than whichever happens to be dev.
    foreach ($root in $roots) {
        $stamp = Join-Path $root 'LW_VERSION.json'
        if (-not (Test-Path -LiteralPath $stamp)) { continue }
        try {
            $j = Get-Content -LiteralPath $stamp -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch { continue }

        if ($j.devBuild) {
            $info.Dev = $true
            $info.Source = 'LW_VERSION.json'
        }
        if ($j.launcherVersion)      { $info.Launcher      = [string]$j.launcherVersion }
        elseif ($j.version)          { $info.Launcher      = [string]$j.version }
        if ($j.scriptVersion)        { $info.Script        = [string]$j.scriptVersion }
        elseif ($j.version)          { $info.Script        = [string]$j.version }
        if ($j.shareLauncherVersion) { $info.ShareLauncher = [string]$j.shareLauncherVersion }
        if ($j.shareScriptVersion)   { $info.ShareScript   = [string]$j.shareScriptVersion }
        break
    }

    # --- Signal 2: .dev-build marker -----------------------------------------
    # Only dev builds carry it, so its mere presence is the answer. Checked even
    # when a stamp was found, because a WIN-INSTALL stick can ship the marker
    # without a devBuild flag in the stamp.
    if (-not $info.Dev) {
        foreach ($root in $roots) {
            foreach ($rel in @('.dev-build', 'WUPayload\.dev-build')) {
                $marker = Join-Path $root $rel
                if (-not (Test-Path -LiteralPath $marker)) { continue }
                $info.Dev = $true
                $info.Source = $rel
                # The marker also carries versions, useful when no stamp was found.
                if (-not $info.Launcher) {
                    try {
                        foreach ($line in (Get-Content -LiteralPath $marker -ErrorAction Stop)) {
                            $kv = ([string]$line).Split('=', 2)
                            if ($kv.Count -ne 2) { continue }
                            switch ($kv[0].Trim()) {
                                'launcherVersion'      { if (-not $info.Launcher)      { $info.Launcher      = $kv[1].Trim() } }
                                'scriptVersion'        { if (-not $info.Script)        { $info.Script        = $kv[1].Trim() } }
                                'shareLauncherVersion' { if (-not $info.ShareLauncher) { $info.ShareLauncher = $kv[1].Trim() } }
                                'shareScriptVersion'   { if (-not $info.ShareScript)   { $info.ShareScript   = $kv[1].Trim() } }
                            }
                        }
                    } catch {}
                }
                break
            }
            if ($info.Dev) { break }
        }
    }

    return $info
}

function Get-FbBuildIdentityForScript {
    <#
        Convenience wrapper for the common case: resolve identity relative to a
        script's own location. -ScriptRoot is the caller's $PSScriptRoot.

        -Layout Deploy : the caller lives in <payload>\Deploy\, so the payload
                         root is its parent and the volume root its grandparent
                         (a legacy flat stick collapses those two).
        -Layout Payload: the caller lives in the payload root itself - the
                         device's C:\Windows\Setup\FirstBase, or WUPayload\ on a
                         stick.
    #>
    param(
        [string] $ScriptRoot,
        [ValidateSet('Deploy', 'Payload')]
        [string] $Layout = 'Payload'
    )

    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { return (Get-FbBuildIdentity -PayloadRoot @()) }

    $roots = @($ScriptRoot)
    try {
        $parent = Split-Path -Path $ScriptRoot -Parent
        if ($parent) {
            $roots += $parent
            if ($Layout -eq 'Deploy') {
                $grand = Split-Path -Path $parent -Parent
                if ($grand) { $roots += $grand }
            }
        }
    } catch {}

    if ($Layout -eq 'Deploy') {
        # Drop the script's own folder: Deploy\ never holds the stamp, and
        # probing it first would only waste a Test-Path per call.
        $roots = $roots | Select-Object -Skip 1
    }

    return (Get-FbBuildIdentity -PayloadRoot $roots)
}
