--- gamemode_gate.lua
--- Decides whether the Antelytics should capture the current run.
---
--- For now we only support PvP Attrition (the competitive mode). Solo runs
--- and other multiplayer modes (Showdown, Survival) will land later when we
--- understand their flow. By gating here we avoid writing useless run files
--- for modes the viewer can't render properly.
---
--- Public API:
---   Gate.is_supported_run() -> boolean
---     true iff we should be capturing this run

local Gate = {}

local SUPPORTED_GAMEMODES = {
    gamemode_mp_attrition = true,
}

--- True iff:
---   - The Multiplayer mod is loaded
---   - We're currently in a lobby (MP.LOBBY.code is set)
---   - The lobby's gamemode is one we support
function Gate.is_supported_run()
    local MP = rawget(_G, "MP")
    if not MP or not MP.LOBBY then return false end
    if not MP.LOBBY.code or MP.LOBBY.code == "" then return false end
    local cfg = MP.LOBBY.config
    if not cfg or not cfg.gamemode then return false end
    return SUPPORTED_GAMEMODES[cfg.gamemode] == true
end

--- The active gamemode key (e.g. "gamemode_mp_attrition"), or nil.
function Gate.current_gamemode()
    local MP = rawget(_G, "MP")
    if not MP or not MP.LOBBY or not MP.LOBBY.config then return nil end
    return MP.LOBBY.config.gamemode
end

return Gate
