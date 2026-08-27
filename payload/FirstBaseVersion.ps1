# FirstBase version manifest - dot-source from each payload .ps1 at startup.



#



# KEEP IN SYNC: Payload\FirstBaseVersion.cmd defines the same product + payload



# revision for cmd.exe (SetupComplete.cmd). When you bump versions here, update



# the .cmd mirror (FIRSTBASE_* variables) in the same commit.



#



# Semantics:



#   $FirstBaseProductVersion  - user-facing overall release (splash no longer shows a Version label; manifest kept for logs/engine).



#   $FirstBasePayloadRevision - universal payload / build id for all components on this drop.



#   $FirstBaseScriptVersion   - per-file semantic versions (Major.Minor.Patch). All entries



#                               start at 1.0.0 for this centralized scheme; bump only the



#                               script(s) whose behavior changed on a given release.







$FirstBaseProductVersion  = '3.0.1'

$FirstBaseBuildStatus     = 'release'

$FirstBasePayloadRevision = '3001-release-3.0.1'







$FirstBaseScriptVersion = @{

    'Build-UsbStick.ps1'               = '1.1.0'

    'Invoke-WindowsUpdateLoop.ps1'       = '1.0.26'

    'SetupComplete.cmd'                = '1.0.6'



    'FirstBaseWuEngine.ps1'            = '1.0.6'



    'Show-UpdateProgress.ps1'          = '3.0.13'



    'FirstBaseSplashSingleInstance.ps1' = '1.0.1'



    'FirstBaseSplashWatcher.ps1'       = '1.0.1'

    'FirstBaseDebugHotkeyWatcher.ps1'  = '1.0.0'



    'FirstBaseDeferredOobeSound.ps1'   = '1.0.6'



    'FirstBaseOobeOperatorFinalize.ps1' = '1.0.10'
    'FirstBaseOobeDeferredSoundBootstrap.ps1' = '1.0.5'



    'FirstBasePostSysprepOobeSoundArm.ps1' = '1.0.0'



    'FirstBaseShowSplash.ps1'          = '1.0.0'

    'FirstBaseHandoffSplash.ps1'        = '1.0.4'

    'FirstBaseOpenSettingsAndFinish.ps1' = '1.1.6'

    'FirstBaseHardwareCheck.ps1'        = '1.0.2'



}


