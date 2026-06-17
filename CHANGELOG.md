# Changelog

All notable changes to the Antelytics capture mod. The companion viewer at
[antelytics.gg](https://www.antelytics.gg) updates continuously and isn't tied
to these versions.

## v1.2.1-alpha

- **Shop joker stickers captured** — eternal / perishable / rental are now
  recorded on jokers offered in the shop (not just the ones you own), so a shop
  joker's Eternal badge shows in the viewer. (Existing runs captured before this
  won't have the data; new runs will.)

## v1.2.0-alpha

- **Joker stickers captured** — eternal / perishable (with its rounds-left
  countdown) / rental now record on every node, so the viewer shows the real
  sticker chips.
- **Fixed a false "lost a life"** at the first boss blind — the mod was emitting
  a bogus PvP round result on a regular blind. PvP round results now only fire
  on actual nemesis blinds.

## v1.1.0-alpha

- **Opponent's end-game build captured** at PvP match end — their final jokers,
  deck, vouchers, reroll count, and shop spending — by decoding the match-end
  network pull. Powers the viewer's "Nemesis" match report.
- INSANE_INT PvP score correctness fixes; `lobby_code` join key for two-sided
  merges; deferred MP finalize so the async opponent data lands before the run
  file is written.

## v1.0.0-alpha

- First public release: records every decision in a run (solo and PvP) to a
  single gzipped JSON, including per-hand PvP scoring, for review in the viewer.
