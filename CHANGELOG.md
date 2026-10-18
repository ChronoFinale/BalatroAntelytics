# Changelog

All notable changes to the Antelytics capture mod. The companion viewer at
[antelytics.gg](https://www.antelytics.gg) updates continuously and isn't tied
to these versions.

## v1.2.3-alpha

- **Joker stickers now really captured** -- eternal / perishable (with its
  rounds-left countdown) / rental. v1.2.0 and v1.2.1 announced this, but the
  keys never existed in capture: 0 of 3,613 real shop items carried one. They
  are now recorded on owned jokers, shop offers and pack contents alike, so the
  viewer's sticker chips light up. (Existing runs won't have them; new runs
  will.)
- **RNG pool depths captured** (`state.pools`) -- how far each pseudorandom
  chain has advanced, the groundwork for hidden-info readouts such as tarot
  queue position. Stays in your local run file only.
- **Installer fix** -- `install.ps1` removes a copy Balatro Mod Manager may have
  parked under `Mods/_disabled`. Steamodded was loading that copy in place of
  the real one, which made the in-game Antelytics toggle flip every parked mod
  (Multiplayer included).
- **Antelytics Live ships dark** -- the live-casting code is in this build but
  cannot be enabled; its config keys are reserved and ignored for now.

## v1.2.2-alpha

- **Negative edition captured** — a Negative joker was being recorded as a plain
  base joker, so the viewer showed no edition badge and you couldn't tell it was
  Negative. (Existing runs won't have it; new runs will.)

  Negative jokers come from **Riff-Raff**, the **Negative Tag**, **Ectoplasm**,
  challenge starting jokers, or the flat **0.3%** edition roll on any newly
  created joker — shop slot, Buffoon Pack, Judgement, The Soul, Wraith, and the
  Top-up / Rare / Uncommon Tags.

  The edition branch was added to the playing-card path too, but that is
  defensive rather than a fix: vanilla cannot produce a Negative playing card
  (Aura, Standard Packs and Illusion all exclude Negative from their rolls).

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
