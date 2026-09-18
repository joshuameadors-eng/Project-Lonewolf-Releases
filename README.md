# Project LoneWolf Releases

Official **public files** for Project LoneWolf / FirstBase.

**[Installer (one URL)](https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/download/installer/LoneWolf-Launcher-Setup.exe)** — `LoneWolf-Launcher-Setup.exe` is the **only** file on the Releases page (stable tag `installer`, overwritten in place).

## Install
1. Download `LoneWolf-Launcher-Setup.exe` from the [single installer URL](https://github.com/joshuameadors-eng/Project-Lonewolf-Releases/releases/download/installer/LoneWolf-Launcher-Setup.exe).
2. Run it. Accept **one** UAC prompt for the whole first install (runtime + files + shortcuts). There is no second elevation for .NET.
3. If .NET 8 Desktop Runtime x64 is already installed, the UI skips the download.
4. Launch **Project LoneWolf Launcher** from the desktop shortcut.

**If Setup will not run:** Windows Security → App & browser control → Smart App Control. **Evaluation** can usually be turned **Off**. **On (enforcement)** often greys out Off and may need a PC reset; do not expect a one-click Off. Use **More info → Run anyway** / SmartScreen only if those dialogs still appear. Do **not** disable Windows Defender.

## Requirements
- Windows 10/11 x64
- Administrator for install and USB imaging
- .NET 8 Desktop Runtime x64 (installer installs it from Microsoft if needed)
