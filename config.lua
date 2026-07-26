-- Antelytics config
return {
  -- Your player name, embedded in the run file metadata
  player_id = "anonymous",

  -- Toggle the mod on/off without uninstalling
  enabled   = true,

  -- Live casting (Antelytics Live) — opt-in, off by default. When enabled
  -- and both live_url/live_token are set, each captured Decision_Node is
  -- POSTed to <live_url>/api/live/node as it happens. Fire-and-forget:
  -- never blocks or errors the run.
  --
  -- live_token is your personal STREAM KEY: get one WITHOUT hand-editing
  -- this file by opening the mod's Config tab in-game and clicking "Link
  -- account" — that starts a short device-pairing flow (a code + a browser
  -- approval page at antelytics.gg) and fills in live_token/linked_user for
  -- you on approval. It is NOT the link you paste into OBS — an overlay URL
  -- is a separate, read-only token, precisely so the thing that appears on
  -- stream can't be used to write.
  --
  -- SMODS stores mod config as plain (unencrypted) text on disk, so treat
  -- this file's contents as world-readable. The token is narrowly scoped
  -- (publish-only) and can be revoked any time from the Config tab's
  -- "Unlink" button (or by generating a new one on antelytics.gg).
  live_enabled = false,
  live_url     = "", -- e.g. "https://www.antelytics.gg"
  live_token   = "", -- your stream key — set via "Link account" in-game, not by hand
  linked_user  = "", -- display name of the linked antelytics.gg account, if any
}
