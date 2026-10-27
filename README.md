# enRAGE for RDR2 on SteamOS

A one-file, menu-driven script that installs and configures the
[enRAGE – Living World and Nemesis System](https://www.nexusmods.com/reddeadredemption2)
mod for **Red Dead Redemption 2 (Steam)** on **SteamOS** handhelds and PCs:
Steam Deck, ROG Ally / Xbox Ally, Legion Go, or any SteamOS install.

On Windows, installing enRAGE means copying a few files. On SteamOS it also needs
.NET Framework 4.8 inside the game's Proton prefix, a DLL override in Steam, and
workarounds for a couple of Proton issues. This script handles all of it and checks
each step.

> [!WARNING]
> **Vibe coded, lightly tested.** This script was written with heavy AI assistance
> ("vibe coded") and has only been tested on one device: an **Xbox ROG Ally X running SteamOS**.
> It should work on the Steam Deck, Legion Go and other SteamOS installs, but that hasn't been
> verified. Read the script before you run it, keep backups of your saves, and please open an
> issue with your device and the `status` output if something breaks (or works!).

> **Story Mode only.** Never launch Red Dead Online with Script Hook active.
> Run `disable` (menu option 3) first.

---

## What it does

| Step | Details |
|---|---|
| Finds the game | Reads every Steam library (internal storage, microSD, extra drives) and finds the Proton prefix, even when it's in a different library from the game |
| Backs up | Copies your Story Mode saves, plus any game files it would overwrite, to `~/RDR2-enRAGE-backups/<timestamp>/` |
| Installs the mod files | Extracts ScriptHookRDR2, ScriptHookRDR2DotNet V2 and enRAGE from `~/Downloads` and puts each file in the right place |
| Installs .NET 4.8 + VC++ 2019 | Uses the Protontricks flatpak and repairs the prefix's user profile first (otherwise the .NET installer fails quietly). It retries with known workarounds, verifies the install, and saves a log |
| Fixes the Windows version | Sets the prefix back to Windows 10. Winetricks can leave it on XP, which causes *"Windows XP and Windows Vista are no longer supported"* |
| Sets the launch option | Adds `WINEDLLOVERRIDES="dinput8=n,b" %command%` to RDR2's Steam launch options |

This script **doesn't download or redistribute any mod files.** You download them yourself from their official pages.

## Requirements

- SteamOS (Desktop Mode) with the **Steam** version of RDR2
- RDR2 launched **once** on this device (to the main menu), then closed
- About 3 GB free space for the .NET install
- These three downloads in `~/Downloads` (leave them zipped):
  1. **ScriptHookRDR2**: <https://www.dev-c.com/rdr2/scripthookrdr2/>. Get the latest version, because it has to support your game version.
  2. **ScriptHookRDR2DotNet V2**, version 2.2.0 or newer: <https://github.com/Halen84/ScriptHookRDR2DotNet-V2/releases>
  3. **enRAGE**: the main archive from Nexus Mods (the zip with the `scripts` folder, not the `.exe` installer)

## Quick start

```bash
# in Desktop Mode, open Konsole
cd ~/Downloads
curl -LO https://raw.githubusercontent.com/thisgitislegit/enrage-rdr2-steamos/main/enrage-setup.sh
bash enrage-setup.sh
```

Choose **1) Full install / repair**. The .NET step takes about 10–25 minutes, and installer
windows may flash up; don't close them. When it says **Done**, return to Game Mode, start RDR2
in Story Mode, and load a **test save** first.

**enRAGE menu:** double-tap **D-pad Right** (or press F11 on a keyboard).

## Menu options and commands

| Menu | Command | What it does |
|---|---|---|
| 1 | `install` | Full install, or repair a broken install |
| 2 | `status` | Checks the files, .NET, Windows version and launch option, and shows recent logs |
| 3 | `disable` | Moves the mod files aside (do this before playing Red Dead Online) |
| 4 | `enable` | Puts the mod files back |
| 5 | `uninstall` | Removes the mod files (moved to backups, not deleted) and the launch option |
| 6 | `reset` | Archives enRAGE's world data (nemeses, wars, history). Your normal saves aren't touched |
| 7 | `fixwin` | Fixes the *"Windows XP / Vista no longer supported"* error |
| 8 | `fixnet` | Reinstalls .NET Framework 4.8 |

```bash
bash enrage-setup.sh status        # run a command without the menu
bash enrage-setup.sh --help
```

### Optional environment variables

| Variable | Default | Purpose |
|---|---|---|
| `DL_DIR` | `~/Downloads` | Folder containing the three downloads |
| `GAME_DIR` | auto-detected | The `Red Dead Redemption 2` game folder |
| `PFX_DIR` | auto-detected | The game's Proton prefix: `…/steamapps/compatdata/1174180/pfx` |
| `BACKUP_ROOT` | `~/RDR2-enRAGE-backups` | Where backups and logs go |
| `FORCE_DEPS=1` | off | Reinstall .NET even if it's already detected |

Example: `DL_DIR=/run/media/deck/SD/mods bash enrage-setup.sh install`

## What it changes on your system

The script only changes these things, and backs up each one first:

- **Game folder:** adds `ScriptHookRDR2.dll`, `dinput8.dll`, `ScriptHookRDRDotNet.asi/.ini`,
  `ScriptHookRDRNetAPI.dll`, `scripts/NemesisMod.dll`, `scripts/Newtonsoft.Json.dll`, and a
  `.enrage-manifest` file listing what it installed.
- **Proton prefix** (`compatdata/1174180/pfx`): installs .NET 4.8 and VC++ 2019, adds the user
  profile registry entry, and sets the Windows version to Windows 10. If a .NET retry needs it,
  the script may also replace linked Windows files in the prefix with real copies.
- **Steam config** (`userdata/*/config/localconfig.vdf`): RDR2's launch options. Steam has to be
  closed for this edit, and the script offers to close it for you.
- **Flatpak:** installs Protontricks from Flathub if it's missing, and grants it access to your
  game and prefix folders.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Proton prefix not found" | Launch RDR2 from Steam on this device until the main menu appears, then quit. If it's still not found, the script lists every place it checked; you can point it at the prefix with `PFX_DIR=…` |
| "Windows XP and Windows Vista are no longer supported" | Menu **7** |
| Status shows ".NET Framework 4.8 not detected" | Menu **8**. If that fails too, set a different Proton version for RDR2 (Steam > Properties > Compatibility, e.g. GE-Proton or Proton 9.0), launch to the menu once, then run **8** again. Logs are in `~/RDR2-enRAGE-backups/<timestamp>/dotnet-install.log` |
| "Unsupported game version" in the game or in `ScriptHookRDR2.log` | Download the newest ScriptHookRDR2 and run **1** again |
| The game starts but enRAGE doesn't appear | Run **2**. Every line should show ✔. Make sure you're in Story Mode |

If you open a bug report, include the output of `bash enrage-setup.sh status` and any
`dotnet-install.log`.

## Credits

- **enRAGE** by nicklovin99
- **ScriptHookRDR2** by Alexander Blade
- **ScriptHookRDR2DotNet V2** by Halen84 and contributors (based on Saltyq's original)
- **Protontricks** by Matoking

Tested only on an Xbox ROG Ally X with SteamOS. Other devices are untested.
This project isn't affiliated with Rockstar Games, Take-Two, Valve, or the authors of the mods.
Use it at your own risk and keep backups of your saves.

## License

[MIT](LICENSE)
