# Project LoneWolf Releases

Official **binaries and scripts** for Project LoneWolf / FirstBase. Application source stays private.

**No GitHub account is required** to download these files.

**[Latest release](https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/latest)**

## Downloads

| File | What it is |
| --- | --- |
| **`LoneWolf-Launcher-Setup.exe`** | Styled installer (one UAC). Installs **.NET 8 Desktop Runtime (x64)** if missing, then the launcher, desktop shortcut (Run as Administrator), and Start Menu shortcut. |
| **`LoneWolf-Launcher.exe`** | Portable / desktop exe |
| **`FirstBase-payload.zip`** | Scripts and payload only (Quick Update). Independent of the launcher exe version. |
| **`latest.json`** | Version manifest. Packaged apps use this as the **source of versioning** (`launcherVersion` vs `payloadVersion`). |

Installer sources (PowerShell bootstrapper + compile script) also live in this repository under `installer/` so they can be cloned or downloaded without an account.

## Install

1. Download `LoneWolf-Launcher-Setup.exe` from the latest release.
2. Run it. Accept **one** UAC prompt for the whole install (runtime + files + shortcuts). There is no second elevation for .NET.
3. If .NET 8 Desktop Runtime x64 is already installed, the UI skips the download.
4. Launch **Project LoneWolf Launcher** from the desktop shortcut.

The package is **unsigned**. **Windows SmartScreen may warn** until the file builds reputation. SmartScreen is not hidden or bypassed.

## Quick Update vs Launcher Update

These channels are separate. A script update does not require a new launcher exe.

- **Quick Update** → `FirstBase-payload.zip`
- **Launcher Update** → `LoneWolf-Launcher-Setup.exe` (or the portable exe)

`latest.json` on this repo is authoritative for installed/packaged updates.

## `latest.json` schema

```json
{
  "launcherVersion": "5.4.4",
  "payloadVersion": "5.4.2",
  "source": "github-public-release",
  "latestReleaseUrl": "https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/latest",
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
    "portable": "LoneWolf-Launcher.exe",
    "payload": "FirstBase-payload.zip",
    "manifest": "latest.json"
  }
}
```

## Requirements

- Windows 10/11 x64
- Administrator for install and USB imaging
- .NET 8 Desktop Runtime x64 (installer installs it from Microsoft if needed)

USB stick destage testing is done from the private source tree with `npm start` (local `src/`), not from these binaries.
