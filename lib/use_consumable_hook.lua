--- use_consumable_hook.lua
--- Synchronous post-effect snapshot for Card:use_consumeable.
---
--- Wraps Balatro's `Card:use_consumeable` so the capture pipeline can
--- read the post-effect state of every targeted/destroyed card while
--- still on the same call stack as the engine's effect resolution. This
--- avoids the boss-blind-breaking deferred-event approach a previous
--- attempt used.
---
--- The wrapper:
---   1. Snapshots player-selected target refs and every owned card ref
---      BEFORE the original method runs.
---   2. Calls the original method (errors propagate to the engine — see
---      Requirement 2.8).
---   3. Runs the post-effect snapshot inside `pcall` so capture errors
---      can never kill the game (Requirement 3.2).
---   4. Returns the original method's return value unmodified
---      (Requirement 3.4).
---
--- Public API:
---   UseConsumableHook.install(deps)  -> boolean
---
--- deps table contract:
---   capture           Capture module — provides describe_playing_card
---                     and is_card_destroyed.
---   logger            Logger module — used for warning output.
---   pending_node_ref  function() -> Action_Node|nil. Returns the
---                     in-flight `use_consumable` Action_Node whose
---                     action table should receive the post-effect
---                     fields. Returns nil if no node is in flight.

local UseConsumableHook = {}

-- ---------------------------------------------------------------------------
-- Forward declarations so helpers can reference each other regardless of
-- definition order.
-- ---------------------------------------------------------------------------
local capture_pre_effect_snapshot
local record_post_effect_state
local describe_post_effect_targets
local describe_destroyed_cards
local has_any_entry

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Snapshot every player-selected target ref and every owned card ref
--- before the engine resolves the consumable's effect. We store the raw
--- Card refs (not descriptors) because:
---   * `target_refs` are re-described post-effect to read the engine's
---     mutations.
---   * `pre_full_deck` is diffed against the post-effect Card_Areas to
---     find cards the consumable removed.
---
--- Wrapped in pcall so a transient missing G area (or a mod-level G
--- replacement) cannot kill the wrapper.
---
--- @param consumable_card table  The consumable Card being used (unused
---                               here but kept for symmetry with the
---                               post-effect helper signature).
--- @param deps table  Dependency table (unused here — included for future
---                    extension).
--- @return table  { target_refs = {...}, pre_full_deck = {...} }
function capture_pre_effect_snapshot(consumable_card, deps)
    local snapshot = {
        target_refs   = {},
        pre_full_deck = {},
    }
    pcall(function()
        if G and G.hand and G.hand.highlighted then
            local highlighted = G.hand.highlighted
            for i = 1, #highlighted do
                snapshot.target_refs[#snapshot.target_refs + 1] = highlighted[i]
            end
        end
        local AREA_NAMES = { "deck", "hand", "discard" }
        for _, area_name in ipairs(AREA_NAMES) do
            local area = G and G[area_name]
            if area and area.cards then
                for i = 1, #area.cards do
                    snapshot.pre_full_deck[#snapshot.pre_full_deck + 1] = area.cards[i]
                end
            end
        end
    end)
    return snapshot
end

--- Re-describe each player-selected target ref by identity so the
--- captured descriptor reflects the engine's post-effect mutations
--- (Strength's rank bump, Death's left-becomes-right, suit conversions,
--- enhancement applications, ...).
---
--- A target ref that no longer lives in any Card_Area was destroyed by
--- the effect (Death's right card, Hanged Man's targets); we leave that
--- index unassigned so the array remains sparse — the JSON serializer
--- encodes the gap as `null` and the viewer treats absence as "no after
--- card for this slot".
---
--- @param target_refs table  Array of player-selected Card refs.
--- @param capture table      Capture module.
--- @return table             Sparse array of Card_Descriptors.
function describe_post_effect_targets(target_refs, capture)
    local target_cards_after = {}
    for i = 1, #target_refs do
        local ref = target_refs[i]
        if not capture.is_card_destroyed(ref) then
            target_cards_after[i] = capture.describe_playing_card(ref)
        end
        -- Destroyed targets stay sparse: index i intentionally unassigned.
    end
    return target_cards_after
end

--- Walk the pre-effect ref list and emit a descriptor for every ref
--- that's no longer present in any Card_Area after the original method
--- returned. This catches every consumable-driven removal: Hanged Man's
--- selected destroys, Immolate's 5 random destroys, Familiar/Grim/
--- Incantation's "destroy 1 random card", and so on.
---
--- The descriptor reflects the card's last-known state (the engine
--- typically nulls fields during destruction, so `id`/`rank`/`suit` may
--- already be missing — `Capture.describe_playing_card` falls back to
--- placeholder values for any field it can't read).
---
--- @param pre_full_deck table  Array of pre-effect Card refs.
--- @param capture table        Capture module.
--- @return table               Array of Card_Descriptors (no holes).
function describe_destroyed_cards(pre_full_deck, capture)
    local destroyed_cards = {}
    for i = 1, #pre_full_deck do
        local ref = pre_full_deck[i]
        if capture.is_card_destroyed(ref) then
            destroyed_cards[#destroyed_cards + 1] = capture.describe_playing_card(ref)
        end
    end
    return destroyed_cards
end

--- True when the table has at least one assigned entry. Lua's `#`
--- operator returns an undefined value on tables with holes, so we
--- can't rely on `#target_cards_after > 0` when index 1 is sparse
--- (Death-style transformations leave index 1 unassigned when the left
--- card was the destroyed one, etc.).
---
--- @param t table
--- @return boolean
function has_any_entry(t)
    for _ in pairs(t) do
        return true
    end
    return false
end

--- Read post-effect descriptors and attach them to the in-flight
--- `use_consumable` Action_Node. No-op when there is no in-flight node
--- (e.g. recording is off, or the SMODS pre-effect handler didn't
--- stash one for us). Empty result lists are NOT attached — the schema
--- requires the keys to be absent rather than empty arrays
--- (Requirements 2.6 and 2.7).
---
--- @param consumable_card table  The consumable Card (unused here;
---                               accepted for symmetry).
--- @param pre_snapshot table     The output of capture_pre_effect_snapshot.
--- @param deps table             Dependency table.
function record_post_effect_state(consumable_card, pre_snapshot, deps)
    local node = deps.pending_node_ref()
    if not (node and node.action) then return end

    local target_cards_after = describe_post_effect_targets(
        pre_snapshot.target_refs, deps.capture
    )
    local destroyed_cards = describe_destroyed_cards(
        pre_snapshot.pre_full_deck, deps.capture
    )

    if has_any_entry(target_cards_after) then
        node.action.target_cards_after = target_cards_after
    end
    if #destroyed_cards > 0 then
        node.action.destroyed_cards = destroyed_cards
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Install the `Card:use_consumeable` wrapper.
---
--- Returns `false` if the `Card` class isn't loaded yet (Balatro builds
--- it during early bootstrap, so a cold-start mod load may run before
--- the prototype exists). The caller's deferred-hook retry loop should
--- call install() again on subsequent ticks until it returns `true`.
---
--- @param deps table  See module header for required keys.
--- @return boolean    true on success, false to defer.
function UseConsumableHook.install(deps)
    if not (rawget(_G, "Card") and type(Card.use_consumeable) == "function") then
        return false
    end

    -- Idempotency guard. The deferred-hook retry loop calls install() on
    -- every tick until it returns true. If install runs more than once
    -- (e.g. mid-run mod hot-reload), we'd wrap the already-wrapped
    -- function and snapshot work would double per call.
    if rawget(UseConsumableHook, "_installed") then
        return true
    end

    local original = Card.use_consumeable
    Card.use_consumeable = function(self, ...)
        local pre_snapshot = capture_pre_effect_snapshot(self, deps)
        -- Errors from the original method must propagate to the engine
        -- unmodified (Requirement 2.8). Only the post-effect snapshot
        -- is wrapped in pcall (Requirement 3.2).
        local result = original(self, ...)
        pcall(function()
            record_post_effect_state(self, pre_snapshot, deps)
        end)
        return result
    end
    UseConsumableHook._installed = true
    return true
end

return UseConsumableHook
