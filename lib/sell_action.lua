--- sell_action.lua
--- Pure builder that turns a sold card into a JSON-ready action payload.
---
--- Background: the previous capture path emitted only `sell_joker` for
--- every `context.selling_card` event, which misattributed sold
--- consumables (Tarot, Planet, Spectral, Consumeables) to the
--- Joker_Strip in the viewer. This module inspects the sold card's
--- `ability.set` and emits either a `sell_joker` payload (for Jokers
--- and unrecognized sets, preserving backward compatibility) or a
--- `sell_consumable` payload (for the four consumable sets).
---
--- Public API:
---   SellAction.build(card, Capture) -> action table
---
--- The Capture module is injected so the spec can pass the real
--- module (or a stub) without depending on global state.
---
--- Requirements: 24.1, 24.2, 24.3, 24.4

local M = {}

--- The four ability.set values that mean "this card is a consumable".
--- "Consumeables" is the in-game spelling — Balatro stores Negative
--- consumables (created by Perkeo) under that umbrella set, while
--- vanilla consumables are tagged with their specific type.
local CONSUMABLE_SETS = {
    Tarot        = true,
    Planet       = true,
    Spectral     = true,
    Consumeables = true,
}

--- True when the card's ability.set marks it as a consumable.
--- @param set string|nil  The value of card.ability.set, or nil.
--- @return boolean
local function is_consumable_set(set)
    return set ~= nil and CONSUMABLE_SETS[set] == true
end

--- Read card.ability.set safely, returning nil when the card is missing
--- or malformed rather than throwing.
local function read_ability_set(card)
    if type(card) ~= "table" then return nil end
    if type(card.ability) ~= "table" then return nil end
    return card.ability.set
end

--- Build the sell-action payload for a sold card.
---
--- @param card table     The Balatro card object that was sold.
--- @param Capture table  The Capture module (must expose describe_card).
--- @return table         Action payload ready for record_action.
function M.build(card, Capture)
    local description = Capture.describe_card(card)
    local ability_set = read_ability_set(card)

    if is_consumable_set(ability_set) then
        return {
            type            = "sell_consumable",
            consumable_id   = description.id,
            consumable_name = description.name,
            consumable_set  = description.set,
            sell_value      = description.sell_value,
            description     = description,
        }
    end

    -- Joker (explicit) and unrecognized sets fall back to sell_joker so
    -- replays captured before this split, and any future set we haven't
    -- categorized yet, remain renderable by the viewer.
    return {
        type        = "sell_joker",
        joker_id    = description.id,
        joker_name  = description.name,
        edition     = description.edition,
        sell_value  = description.sell_value,
        description = description,
    }
end

return M
