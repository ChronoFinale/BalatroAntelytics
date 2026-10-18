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

## 2. Thunderstore (wired; first upload pending)

Thunderstore's Balatro community is the mod-manager channel (r2modman / Gale).
Everything is in the repo; what remains is the one-time account setup below.

**What ships.** `package-thunderstore.sh` / `.ps1` build
`dist/Antelytics-thunderstore.zip`, a **different layout** from the GitHub
zip: the zip root holds `manifest.json`, `README.md`, `CHANGELOG.md`,
`icon.png` and the mod files flat (`Antelytics.json`, `main.lua`,
`config.lua`, `lib/`, `LICENSE`) — no `Antelytics/` subfolder; managers create
the folder from the package name. `release.yml` builds it on every `v*` tag,
attaches it to the GitHub Release, and publishes it to Thunderstore when the
`THUNDERSTORE_TOKEN` secret exists (skipped otherwise).

**Metadata** lives in `thunderstore/`:

- `manifest.json` — committed with the real version so a manual upload works
  as-is; the build re-stamps `version_number` from `Antelytics.json` with the
  `~alpha` suffix stripped (Thunderstore wants plain semver).
  `spec/thunderstore_manifest_spec.lua` fails the suite if the two drift, if
  `name` leaves `[A-Za-z0-9_]`, if `description` exceeds 250 chars, or if the
  icon is not exactly 256×256. **Bump `version_number` with every release.**
- `icon.png` — 256×256. The current one is a generated placeholder
  (`thunderstore/make_icon.py`, viewer palette); replace it with real art any
  time, same size.
- Dependency pin: the **same Steamodded as Multiplayer**
  (`Steamodded-Steamodded-1.1620.0` as of Multiplayer 0.5.7) so a manager never
  drags Steamodded 26.x onto a Multiplayer player. Bump it when Multiplayer
  does.

**One-time setup (Chrono, browser only — Thunderstore has no API for it):**

1. Sign in at <https://thunderstore.io> (GitHub/Discord login), create a team
   named `Chrono` (or set the repo variable `THUNDERSTORE_NAMESPACE` to the
   name actually chosen).
2. Team settings → Service Accounts → create one and copy its token into the
   repo secret: `gh secret set THUNDERSTORE_TOKEN -R ChronoFinale/BalatroAntelytics`.
   Never commit it. Done 2026-10-18.

**Publishing.** Every `v*` tag publishes automatically. To publish without a
new tag (first upload, or a retry), run the workflow by hand:
`gh workflow run release.yml --ref main` — it rebuilds the zips and runs only
the Thunderstore step; the GitHub Release step is skipped off-tag. The first
publish creates the package page; categories can be edited on the site after.

Upload action used: `GreenTF/upload-thunderstore-package@v4.3` with `file:` set
(it then skips its own build and publishes our zip). `repo:` is passed
explicitly because the action's default repository is empty in v4.3.
