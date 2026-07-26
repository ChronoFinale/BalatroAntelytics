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
  live_enabled = false,
  live_url     = "", -- e.g. "https://www.antelytics.gg"
  live_token   = "", -- opaque session token (>= 32 chars)
}
