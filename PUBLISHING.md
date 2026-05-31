# Publishing Antelytics

Two channels:

1. **GitHub Releases** — the source of the download. Ready now.
2. **Balatro Mod Manager (BMM)** — the desktop installer most players use. You
   get listed by a PR to its
   [`balatro-mod-index`](https://github.com/skyline69/balatro-mod-index) repo,
   whose `downloadURL` points at the GitHub Release.

(Thunderstore is intentionally not used — BMM has its own index and doesn't read
from Thunderstore, and Thunderstore's only Steamodded listing is too old for the
beta this mod needs.)

---

## 1. GitHub Releases (primary, ready)

This is what BMM downloads from.

```sh
# bump the version in Antelytics.json first if needed, then:
git tag v0.1.0-alpha
git push origin v0.1.0-alpha
```

`.github/workflows/release.yml` runs the tests, builds the zip (`package.sh`),
and attaches **`BalatroAntelytics.zip`** to a GitHub Release with auto notes.

The asset is then reachable at a stable "latest" URL — the link BMM uses:

```
https://github.com/ChronoFinale/BalatroAntelytics/releases/latest/download/BalatroAntelytics.zip
```

**Manual fallback** (if CI Lua setup hiccups): `./package.ps1` (Windows) or
`./package.sh` (mac/Linux) → upload `dist/BalatroAntelytics.zip` to a Release.

---

## 2. Balatro Mod Manager (BMM)

BMM installs from the `skyline69/balatro-mod-index` repo. The submission files
are prepared in [`bmm/`](bmm/) — `meta.json` + `description.md`.

**Steps**
1. Cut a GitHub Release first (above) so the `downloadURL` resolves.
2. Fork `skyline69/balatro-mod-index`, add a folder `mods/Chrono@Antelytics/`
   containing `meta.json`, `description.md`, and optionally `thumbnail.jpg`
   (1920×1080 max, JPEG). Copy them from `bmm/`.
   - Or use the helper: https://bmi-helper.dasguney.com/
3. Open a PR to its `main` branch. A GitHub Action validates it, then a
   maintainer reviews.

**Before submitting, double-check:**
- The **release must exist first** — the validator fetches `downloadURL` and
  requires a real file (HTTP 2xx, not a `/blob/`,`/tree/`, or page URL). Our
  `…/releases/latest/download/BalatroAntelytics.zip` only resolves once a
  Release is published.
- `categories` is set to `["Technical", "Quality of Life"]`. Allowed values
  (verified against the index's check-mod.yml): Content, Joker, Quality of Life,
  Technical, Miscellaneous, Resource Packs, API.
- `version` matches the released tag (strip `~alpha` → `0.1.0`).
- `"requires-steamodded": true` is enough — no Steamodded version pin needed.

Updates are automatic: `meta.json` sets `"automatic-version-check": true` and
the `downloadURL` is the `/latest/` link, so the index's Version Update Bot
bumps our `version` whenever you publish a new GitHub Release — no follow-up PR
needed. (Only fixed-tag download URLs need `fixed-release-tag-updates`; ours
doesn't.)

Note: the index schema has no "requires-multiplayer" field — Balatro Multiplayer
is optional and is documented in `description.md` instead. We only set
`requires-steamodded: true`.
