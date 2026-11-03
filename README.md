# Antelytics

> A Balatro run recorder. Made by **Chrono**.

Antelytics records every decision you make during a run — blinds, hands, discards,
shop buys, packs, PvP scoring — and writes it to a single compressed file. Open
that file in the **[Antelytics viewer](https://www.antelytics.gg)** to step back
through the whole run, ante by ante. Built with **Balatro Multiplayer** in mind
(it captures PvP scores and lives), but it works on solo runs too.

---

## Install

**Requirements**
- [Steamodded](https://github.com/Steamodded/smods) `1.0.0-BETA-1221a` or newer
- (optional) [Balatro Multiplayer](https://github.com/Balatro-Multiplayer/BalatroMultiplayer) — needed only for PvP capture

### Option A — mod manager (r2modman / Thunderstore Mod Manager)

Install **[Antelytics from Thunderstore](https://thunderstore.io/c/balatro/p/Chrono/Antelytics/)**
inside the manager. It pulls in Steamodded and lovely for you. Launch Balatro
with the manager's **Start modded** button — the manager runs the game against
its own profile folder, so nothing is copied into your real Balatro folder.
Mod managers currently exist for **Windows and Linux only** — on macOS use
Option B.

### Option B — manual

1. Download the latest **`Antelytics.zip`** from the
   [Releases page](https://github.com/ChronoFinale/BalatroAntelytics/releases).
2. Extract it. You'll get an `Antelytics` folder containing `main.lua` and
   `Antelytics.json`.
3. Drop that folder into your Balatro **Mods** directory:

   | OS | Mods folder |
   |---|---|
   | **Windows** | `%APPDATA%\Balatro\Mods\` |
   | **macOS** | `~/Library/Application Support/Balatro/Mods/` |
   | **Linux** | `~/.steam/steam/steamapps/compatdata/.../Balatro/Mods/` |

   The result should be `…/Mods/Antelytics/main.lua`.
4. Launch Balatro. If it loaded, Antelytics shows up in the in-game Mods list.

### Where the files end up

Antelytics writes its run files to an `Antelytics/log` folder in Balatro's
**save directory** — the same place the game keeps its own saves and
settings, one level up from `Mods/`. It is the same folder for a manual
install and an r2modman profile, so nothing needs configuring:

| OS | Run files |
|---|---|
| **Windows** | `%APPDATA%\Balatro\Antelytics\log\` |
| **macOS** | `~/Library/Application Support/Balatro/Antelytics/log/` |
| **Linux (Proton)** | `…/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Antelytics/log/` |

The run files deliberately live outside `Mods/`: Steamodded scans every mod
folder for metadata on boot, and a folder full of run files slowed that scan
and filled the log with warnings. (Versions before 1.3.1 wrote to
`Mods/Antelytics/log/`; files already there stay put and still open in the
viewer.)

---

## How to use it

1. **Play a run.** Antelytics records it automatically — nothing to turn on.
2. When you want to review it, find your run file in Balatro's save
   directory (see *Where the files end up* above):

   | OS | Log folder |
   |---|---|
   | **Windows** | `%APPDATA%\Balatro\Antelytics\log\` |
   | **macOS** | `~/Library/Application Support/Balatro/Antelytics/log/` |

   Files are named `<timestamp>_<random>.json.gz`. The run's seed is written
   into the file only once the run is over, so an in-progress file never
   reveals it.
3. Open **[www.antelytics.gg](https://www.antelytics.gg)** and load that file (the **↑ Load
   run** button, or drag-and-drop). Step through your run ante by ante.

Each run file updates at every blind boundary, so you can even open an
in-progress run.

### Coaching / sharing notes
In the viewer you can add a comment on any step, then **↓ Notes** to download the
run bundled with your comments as one file. Hand it to a coach (or teammate) —
they open it, reply on the steps, download again, and send it back. Annotated
steps are marked on the timeline so they're easy to find.

---

## What it captures

- Blind select (play / skip-with-tag), play hand & discard (with hand type)
- Buy / sell / use consumable, reroll, pack open & pick
- End-of-round cash-out, blind defeated, shop contents
- **PvP** (with Balatro Multiplayer): your & the opponent's scores and lives each
  step, who won each PvP blind, and the match result

Every step also snapshots money, score, jokers, consumables, deck, hand levels,
vouchers and tags — everything needed to reconstruct the run state.

---

## Feedback & bugs

Open an issue: **[New issue →](https://github.com/ChronoFinale/BalatroAntelytics/issues/new/choose)**
(there's a form for both the mod and the website).

---

## Building from source (developers)

```sh
git clone https://github.com/ChronoFinale/BalatroAntelytics
cd BalatroAntelytics

# Run the tests (needs https://lunarmodules.github.io/busted/)
busted spec/

# Install into your Mods folder (COPY, never symlink — Balatro holds files
# open at runtime; a symlink into a working tree can corrupt a mid-game capture)
pwsh ./install.ps1        # Windows
./install.sh              # macOS / Linux

# Build a release zip (writes dist/BalatroAntelytics.zip)
pwsh ./package.ps1        # Windows
./package.sh              # macOS / Linux
```

Releases are cut by pushing a `v*` tag — see `.github/workflows/release.yml`.

## License

GPL-3.0
