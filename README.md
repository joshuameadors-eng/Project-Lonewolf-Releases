# Project LoneWolf — Releases

Official **binaries** for [Project LoneWolf Launcher](https://github.com/joshuameadors-eng/Project-Lonewolf) (FirstBase Deployment Suite).

**Source code is private.** This repository only hosts installers and payload updates.

<p align="center">
  <a href="https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/latest">
    <img src="https://img.shields.io/github/v/release/joshuameadors-eng/Project-Lonewolf-Releases?label=Download%20latest%20release&style=for-the-badge" alt="Download latest release">
  </a>
</p>

**[Download the latest release](https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/latest)**

## What you get

| Asset | Purpose |
| --- | --- |
| `LoneWolf-Launcher-Setup.exe` | Branded NSIS installer (desktop shortcut, Run as Administrator) |
| `LoneWolf-Launcher.exe` | Optional portable launcher |
| `FirstBase-payload.zip` | **Quick Update** — scripts and payload only (does **not** replace the launcher exe) |
| `latest.json` | Channel versions: `{ "launcherVersion", "payloadVersion" }` |

## Installer notes

- Windows x64. Run the setup **as Administrator** (the installer and app request elevation).
- The installer is **unsigned**. Windows SmartScreen may warn until the file builds reputation. That is expected; it is not a claim that antivirus is disabled or bypassed.
- USB imaging still needs the Windows ADK / WinPE components on the **build PC**. The installer does not silently install the ADK or Node.js.

## Updates

- **Quick Update** — pull `FirstBase-payload.zip` from this repo. Script/payload changes do **not** require a new launcher exe.
- **Launcher Update** — pull `LoneWolf-Launcher-Setup.exe` (or the portable exe) when the launcher itself changed.
