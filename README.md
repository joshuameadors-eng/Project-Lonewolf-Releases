# Project LoneWolf Releases

Official **public files** for Project LoneWolf / FirstBase. Application source stays private.

**No GitHub account is required.** Use [raw.githubusercontent.com](https://raw.githubusercontent.com/joshuameadors-eng/Project-Lonewolf-Releases/main/latest.json) or the GitHub Contents API for `latest.json`, payload, and the portable exe.

**[Latest installer](https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/latest)** — `LoneWolf-Launcher-Setup.exe` is the **only** file on the Releases page.

## Where files live

| File | Location |
| --- | --- |
| **`LoneWolf-Launcher-Setup.exe`** | **Releases only.** Styled installer (one UAC). Installs **.NET 8 Desktop Runtime (x64)** if missing, then the launcher, desktop shortcut (Run as Administrator), and Start Menu shortcut. |
| **`bin/LoneWolf-Launcher.exe`** | **Git tree** (portable / desktop exe). Not a release asset. |
| **`payload/`** and **`powershell/`** | **Git tree** (scripts). Independent of the launcher exe version. |
| **`FirstBase-payload.zip`** | **Git tree** (zip of those folders for Quick Update). Not a release asset. |
| **`latest.json`** | **Git tree.** Packaged apps use this as the **source of versioning** (`launcherVersion` vs `payloadVersion`). |

Installer sources (PowerShell bootstrapper + compile script) also live in this repository under `installer/` so they can be cloned or downloaded without an account.

## Install

1. Download `LoneWolf-Launcher-Setup.exe` from the [latest release](https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/latest).
2. Run it. Accept **one** UAC prompt for the whole install (runtime + files + shortcuts). There is no second elevation for .NET.
3. If .NET 8 Desktop Runtime x64 is already installed, the UI skips the download.
4. Launch **Project LoneWolf Launcher** from the desktop shortcut.

The package is **unsigned**. **Windows SmartScreen may warn** until the file builds reputation. SmartScreen is not hidden or bypassed.

## Quick Update vs Launcher Update

These channels are separate. A script update does not require a new launcher exe.

- **Quick Update** → `FirstBase-payload.zip` from the **source tree** (URL in `latest.json`)
- **Launcher Update** → `LoneWolf-Launcher-Setup.exe` from **Releases** (the only asset)

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
    "setup": "https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/latest/download/LoneWolf-Launcher-Setup.exe",
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

USB stick destage testing is done from the private source tree with `npm start` (local `src/`), not from these binaries.
