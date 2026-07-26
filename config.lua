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
  -- live_token is your personal STREAM KEY: sign in at antelytics.gg and
  -- generate one from your account page. It is shown once and stored only as
  -- a hash, so if you lose it, generate a new one (and revoke the old).
  --
  -- Treat it like a password: it can PUBLISH game state as you. It is NOT the
  -- link you paste into OBS — an overlay URL is a separate, read-only token,
  -- precisely so the thing that appears on stream can't be used to write.
  live_enabled = false,
  live_url     = "", -- e.g. "https://www.antelytics.gg"
  live_token   = "", -- your stream key from antelytics.gg (keep secret)
}
