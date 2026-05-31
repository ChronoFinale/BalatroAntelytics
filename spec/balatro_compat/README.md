# Balatro Compat Tests

Local-only spec/harness that loads pieces of Balatro's actual `card.lua`
and runs them against a minimal `G` mock so we can verify our viewer
formulas (live joker effects, hand evaluation, score math) match the
real game's behavior — not just our own assumptions.

## Why local-only

These tests load source files extracted from the user's local Balatro
install. We don't redistribute Balatro's code, so the harness expects
the files to live under `~/.cache/balatro-source/` (configurable via
`BALATRO_SOURCE_DIR` env var). When the source isn't available the
specs are skipped automatically — CI never runs them.

## Setup

Run once on your machine:

```sh
mkdir -p ~/.cache/balatro-source
unzip -p "/Users/mj/Library/Application Support/Steam/steamapps/common/Balatro/Balatro.app/Contents/Resources/Balatro.love" card.lua > ~/.cache/balatro-source/card.lua
unzip -p "/Users/mj/Library/Application Support/Steam/steamapps/common/Balatro/Balatro.app/Contents/Resources/Balatro.love" game.lua > ~/.cache/balatro-source/game.lua
unzip -p "/Users/mj/Library/Application Support/Steam/steamapps/common/Balatro/Balatro.app/Contents/Resources/Balatro.love" functions/state_events.lua > ~/.cache/balatro-source/state_events.lua
```

Then run the specs:

```sh
busted spec/balatro_compat/
```

If the source isn't installed the specs print a skip notice and exit
clean. They never fail on missing source — that's by design so the
main `spec/` suite stays green for anyone running the repo.

## What we test

- `j_supernova_compat_spec.lua` — feeds a synthetic `G.GAME.hands`
  through Balatro's actual Supernova `calc_function` (sliced out of
  `card.lua`) and asserts our viewer's `jokerLiveEffect` produces the
  same number.

Add new specs as you need to verify formulas. The harness in
`spec/balatro_compat/lib/source.lua` handles missing-source skips
and provides a `slice_function(name, source)` helper for pulling
specific functions out of `card.lua`.
