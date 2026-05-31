--- skip_blind_action.lua
--- Pure builder that turns the engine state right after a skip into a
--- complete skip_blind_tag action payload.
---
--- When the player skips a blind, Balatro mutates G in this order:
---   1. Adds the tag they took to G.GAME.tags (most recent = last element).
---   2. Sets G.GAME.round_resets.blind_states[<slot>] = "Skipped" for the
---      slot that was on deck at the moment of skip.
---   3. Advances G.GAME.blind_on_deck to the next slot.
---
--- All three changes happen synchronously before the SMODS calculate
--- context fires, so by the time we read G we can recover the full
--- "skipped what, took what, on deck now what" picture.
---
--- Public API:
---   build_skip_blind_action(G, Serializer) -> action table
---
--- Returns the JSON-serializable payload suitable for record_action.
--- Missing fields fall back to the Serializer.null sentinel so the
--- viewer can render a useful row even when only some data was readable.

local M = {}

-- Maps the engine's PascalCase slot name to our lowercase canonical slot.
local SLOT_MAP = { Small = "small", Big = "big", Boss = "boss" }

--- Read the slot the player just skipped by scanning blind_states for
--- entries marked "Skipped". Excludes any slots in `already_emitted` so
--- consecutive skips (Small then Big) each return the freshly-skipped
--- slot rather than the first match in hash-iteration order.
--- Only Small and Big are considered — Boss is never skippable.
--- @param game table              G.GAME table.
--- @param already_emitted table?  Set of canonical slots ("small", "big")
---                                 already emitted earlier this round.
--- @return slot string|nil, blind_key string|nil
local function read_skipped_slot_and_key(game, already_emitted)
    local round_resets = game and game.round_resets
    if not round_resets or not round_resets.blind_states then return nil, nil end

    already_emitted = already_emitted or {}

    for slot, state in pairs(round_resets.blind_states) do
        if state == "Skipped" and (slot == "Small" or slot == "Big") then
            local canonical_slot = SLOT_MAP[slot]
            if not already_emitted[canonical_slot] then
                local blind_key = round_resets.blind_choices and round_resets.blind_choices[slot]
                return canonical_slot, blind_key
            end
        end
    end
    return nil, nil
end

--- Resolve a blind_key to a human-readable name via G.P_BLINDS.
--- Falls back to the key itself if the lookup table is missing.
local function resolve_blind_name(G, blind_key)
    if not blind_key then return nil end
    if G and G.P_BLINDS and G.P_BLINDS[blind_key] then
        return G.P_BLINDS[blind_key].name or blind_key
    end
    return blind_key
end

--- Read the most recently added tag — the one the player just took.
local function read_most_recent_tag(game)
    if not (game and game.tags) or #game.tags == 0 then return nil, nil end
    local tag = game.tags[#game.tags]
    if not tag then return nil, nil end
    local id   = tag.key  and tostring(tag.key)  or nil
    local name = tag.name and tostring(tag.name) or nil
    return id, name
end

--- Read which blind is now on deck (i.e. the slot that will be played
--- next if the player doesn't also skip that one).
local function read_next_blind_slot(game)
    if not (game and game.blind_on_deck) then return nil end
    return SLOT_MAP[game.blind_on_deck]
end

--- Build the skip_blind_tag action payload from the live G global.
---
--- @param G table              The live Balatro G global (or a fake for tests).
--- @param Serializer table     The serializer module (for the null sentinel).
--- @param already_emitted table?  Set of canonical slots ("small", "big") for
---                                which a skip_blind_tag has already been
---                                emitted earlier this round. Lets a Big skip
---                                find Big-as-Skipped instead of returning
---                                Small (which is already Skipped from earlier).
--- @return table               Action payload ready for record_action.
function M.build(G, Serializer, already_emitted)
    local game = G and G.GAME
    local slot, blind_key = read_skipped_slot_and_key(game, already_emitted)
    local blind_name = resolve_blind_name(G, blind_key)
    local tag_id, tag_name = read_most_recent_tag(game)
    local next_slot = read_next_blind_slot(game)

    local NULL = Serializer and Serializer.null or nil
    local function or_null(v) return v ~= nil and v or NULL end

    return {
        type            = "skip_blind_tag",
        blind_slot      = or_null(slot),
        blind_key       = or_null(blind_key),
        blind_name      = or_null(blind_name),
        tag_id          = or_null(tag_id),
        tag_name        = or_null(tag_name),
        next_blind_slot = or_null(next_slot),
    }
end

return M
