# Publishing Antelytics

Two channels:

1. **GitHub Releases** — the download of record. Automated: push a `v*` tag.
2. **Thunderstore** (`thunderstore.io/c/balatro`) — what the mod managers read
   now (r2modman, Gale, Thunderstore Mod Manager). Steamodded, Balatro
   Multiplayer and JokerDisplay all publish there. Not set up yet; see §2.

**Balatro Mod Manager is gone as a channel.** Its `skyline69/balatro-mod-index`
repo was archived on 2026-09-29 ("This index is no longer maintained") and the
BMM README now points users to r2modman / imm. Antelytics was never listed in
it. The `bmm/` folder is kept for reference only.

---

## 1. GitHub Releases (primary, automated)

```sh
# 1. bump "version" in Antelytics.json (e.g. 1.2.3~alpha), add a CHANGELOG entry, commit
# 2. tag + push the tag
git tag v1.2.3-alpha
git push origin v1.2.3-alpha
# 3. watch it
gh run list --workflow release.yml --limit 1
gh run watch
```

`.github/workflows/release.yml` runs `package.sh` and attaches
**`dist/Antelytics.zip`** to a GitHub Release with auto-generated notes. Tests
are enforced separately by `ci.yml` on every push, so release.yml needs no Lua
toolchain.

The zip has a single top-level `Antelytics/` folder (so extracting into
`Mods/` yields `Mods/Antelytics/main.lua`) and is reachable at the stable URL

```
https://github.com/ChronoFinale/BalatroAntelytics/releases/latest/download/Antelytics.zip
```

**Manual fallback** (if CI hiccups): `./package.ps1` (Windows) or
`./package.sh` (mac/Linux) → upload `dist/Antelytics.zip` to a Release by hand.

### Steamodded dependency

`Antelytics.json` declares `Steamodded (>=1.0.0~BETA-1221a)`. Leave it. Verified
against Steamodded 26.1002.0's comparator (`src/preflight/sharedUtil.lua`):
versions compare major-first, so `26.x` satisfies `>=1.0.0~...` and so does
every `1.0.0~BETA-*` build. Balatro Multiplayer 0.4.x declares the identical
string and its Thunderstore package pins Steamodded `1.1620.0`, so players on
either Steamodded line load Antelytics unchanged.

---

## 2. Thunderstore (to do)

Package format (verified against Thunderstore's docs and JokerDisplay's
published zip, 2026-10-18):

- The zip root holds `manifest.json`, `README.md`, `icon.png` (**exactly
  256×256 PNG**) and the mod files themselves — `Antelytics.json`, `main.lua`,
  `config.lua`, `lib/`, `LICENSE`. **No `Antelytics/` subfolder**: this is a
  different zip from the GitHub one. Mod managers create the folder from the
  package name. Optional `CHANGELOG.md` at the root is shown on the page.
- `manifest.json`:

  ```json
  {
    "name": "Antelytics",
    "version_number": "1.2.3",
    "website_url": "https://github.com/ChronoFinale/BalatroAntelytics",
    "description": "Records every decision in a Balatro run (solo or Multiplayer PvP) to one file for review at antelytics.gg.",
    "dependencies": ["Steamodded-Steamodded-1.1620.0"]
  }
  ```

  `name`: `a-z A-Z 0-9 _` only. `version_number`: plain semver, so strip
  `~alpha`. `description`: ≤ 250 chars. Pin the **same Steamodded as
  Multiplayer** (`1.1620.0` as of Multiplayer 0.5.7) so a manager never drags
  Steamodded 26.x onto a Multiplayer player; bump it when Multiplayer does.

**Still needed before the first upload:** a 256×256 `icon.png` (none in the
repo), a Thunderstore account + team (`Chrono`), and a `package-thunderstore.sh`
that stages the flat layout. First upload is manual at
`thunderstore.io/c/balatro/create/`; later ones can use the
`GreenTF/upload-thunderstore-package` action with a team API key.
