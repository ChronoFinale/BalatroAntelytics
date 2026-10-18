-- Antelytics config
return {
  -- Your player name, embedded in the run file metadata
  player_id = "anonymous",

  -- Toggle the mod on/off without uninstalling
  enabled   = true,

  -- Antelytics Live (streaming each decision to antelytics.gg as it happens)
  -- is NOT available in this release. The keys below are reserved for it and
  -- are ignored: main.lua forces live_enabled off at load, so editing this
  -- file cannot turn it on. Leave them as they are.
  live_enabled = false,
  live_url     = "https://www.antelytics.gg",
  live_token   = "",
  linked_user  = "",
}
