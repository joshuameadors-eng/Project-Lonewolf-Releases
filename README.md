# Project LoneWolf Releases

Official **installer files** for Project LoneWolf / FirstBase. Application source stays private.

**[Installer (one URL)](https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/download/installer/LoneWolf-Launcher-Setup.exe)** — `LoneWolf-Launcher-Setup.exe` is the **only** file on the Releases page (stable tag `installer`, overwritten in place).

## Install

1. Download `LoneWolf-Launcher-Setup.exe` from the [single installer URL](https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/download/installer/LoneWolf-Launcher-Setup.exe).
2. Run it. Accept **one** UAC prompt for the whole first install (runtime + files + shortcuts). There is no second elevation for .NET.
3. If .NET 8 Desktop Runtime x64 is already installed, the UI skips the download.
4. Launch **Project LoneWolf Launcher** from the desktop shortcut.

The package is **unsigned**. Install and update download unsigned PE from GitHub (`bin/LoneWolf-Launcher.exe` and this Setup). **Smart App Control** can block them as untrusted.

**If Setup will not run:** Windows Security → App & browser control → Smart App Control. **Evaluation** can usually be turned **Off**. **On (enforcement)** often greys out Off and may need a PC reset; do not expect a one-click Off. Use **More info → Run anyway** / SmartScreen only if those dialogs still appear. Do **not** disable Windows Defender.

## Quick Update vs Launcher Update

These channels are separate. A script update does not require a new launcher exe.

- **Quick Update** → `FirstBase-payload.zip` from the **source tree** (URL in `latest.json`). Never touches the desktop shortcut or Setup.
- **Launcher Update** → portable `bin/LoneWolf-Launcher.exe` from the **source tree**. Replaces the exe at the same path; creates the shortcut only if it is missing. Does **not** re-run Setup.

`latest.json` in this repo is authoritative for installed/packaged updates.

## `latest.json` schema

```json
{
  "launcherVersion": "5.4.7",
  "payloadVersion": "5.4.2",
  "channel": "release",
  "source": "github-public-source",
  "latestReleaseUrl": "https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/latest",
  "manifestUrl": "https://raw.githubusercontent.com/joshuameadors-eng/Project-Lonewolf-Releases/main/latest.json",
  "dotnet": {
    "id": "windowsdesktop",
    "major": 8,
    "arch": "x64",
    "displayName": ".NET 8 Desktop Runtime",
    "installerUrl": "https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe"
  },
  "assets": {
    "setup": "LoneWolf-Launcher-Setup.exe",
    "installer": "LoneWolf-Launcher-Setup.exe",
    "portable": "bin/LoneWolf-Launcher.exe",
    "payload": "FirstBase-payload.zip",
    "manifest": "latest.json"
  },
  "urls": {
    "setup": "https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/download/installer/LoneWolf-Launcher-Setup.exe",
    "portable": "https://raw.githubusercontent.com/joshuameadors-eng/Project-Lonewolf-Releases/main/bin/LoneWolf-Launcher.exe",
    "payload": "https://raw.githubusercontent.com/joshuameadors-eng/Project-Lonewolf-Releases/main/FirstBase-payload.zip",
    "manifest": "https://raw.githubusercontent.com/joshuameadors-eng/Project-Lonewolf-Releases/main/latest.json"
  }
}
```

## Requirements

- Windows 10/11 x64
- Administrator for install and USB imaging
- .NET 8 Desktop Runtime x64 (installer installs it from Microsoft if needed)
