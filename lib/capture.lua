--- capture.lua
--- Game state snapshot builder for the Balatro Antelytics.
---
--- Public API:
---   Capture.init(opts)                    -- inject dependencies (null_sentinel, logger)
---   Capture.set_logger(logger_fn)         -- inject/replace the logger function
---   Capture.build_game_state(action_type) -- build a Game_State snapshot
---
--- Reads from the global `G` table and constructs a complete Game_State
--- matching the JSON schema defined in the design document.
---
--- Every field access is wrapped in pcall. On failure the field is recorded
--- as the null sentinel and a warning is appended to the session log.
---
--- Dependencies are injected — this module does NOT use require().
---
--- Requirements: 2.1–2.10, 2.11

local Capture = {}

-- ---------------------------------------------------------------------------
-- Null sentinel — injected via Capture.init(). Represents JSON null in Lua
-- tables (since assigning nil removes the key). Defaults to a local sentinel
-- if init() is not called (for standalone testing).
-- ---------------------------------------------------------------------------
local NULL_SENTINEL = setmetatable({}, { __tostring = function() return "null" end })

-- ---------------------------------------------------------------------------
-- Logger function — injected via Capture.set_logger() or Capture.init().
-- Falls back to print if not configured.
-- ---------------------------------------------------------------------------
local log_warning = function(msg)
    if type(print) == "function" then
        print("[Capture WARNING] " .. tostring(msg))
    end
end

-- ---------------------------------------------------------------------------
-- get_current_blind_slot — injected via Capture.init(). Returns the
-- run-scoped current Blind_Slot (one of "small"/"big"/"boss"/"pvp") or nil
-- when unknown. Defaults to a no-op returning nil so captures fall back to
-- a null blind_slot when the host hasn't wired the accessor.
-- ---------------------------------------------------------------------------
local get_current_blind_slot = function() return nil end

-- ---------------------------------------------------------------------------
-- get_current_pack_kind — injected via Capture.init(). Returns the kind of the
-- booster pack currently open ("Arcana"/"Celestial"/"Spectral"/"Standard"/
-- "Buffoon") or nil when no pack is open. A pack is an OVERLAY, not a location:
-- you open it while standing in the shop or on the blind-select screen, and you
-- stay there. So this feeds state.pack (the overlay) while state.location keeps
-- the stable base context. Defaults to a no-op returning nil.
-- ---------------------------------------------------------------------------
local get_current_pack_kind = function() return nil end

-- ---------------------------------------------------------------------------
-- get_current_ante — injected via Capture.init(). Returns the logical
-- ante that the player is currently in (locked at the moment the player
-- pressed Play/Skip on a select_blind), so post-blind events like
-- `blind_beaten` and the subsequent shop don't get attributed to the
-- next ante just because Balatro's engine bumped `round_resets.ante`
-- under the hood. Returns nil when unknown so captures fall through to
-- the engine's value.
-- ---------------------------------------------------------------------------
local get_current_ante = function() return nil end

-- ---------------------------------------------------------------------------
-- multiplayer accessor — injected via Capture.init(). Provides PvP state
-- reads (opponent_id, opponent_name, player_score, opponent_score, ...)
-- behind an `enabled` flag. Defaults to a disabled no-op accessor so no
-- Multiplayer-namespaced globals are touched when the host hasn't wired it.
-- ---------------------------------------------------------------------------
local multiplayer = {
    enabled = false,
    is_pvp_blind   = function() return nil end,
    opponent_id    = function() return nil end,
    opponent_name  = function() return nil end,
    player_score   = function() return nil end,
    opponent_score = function() return nil end,
}

-- ---------------------------------------------------------------------------
-- Public: Dependency injection
-- ---------------------------------------------------------------------------

--- Initialize the Capture module with dependencies.
--- @param opts table  {
---   null_sentinel           = Serializer.null,
---   logger                  = logger_fn,
---   get_current_blind_slot  = function() -> "small"|"big"|"boss"|"pvp"|nil,
---   multiplayer             = Multiplayer accessor (see lib/multiplayer.lua),
--- }
function Capture.init(opts)
    opts = opts or {}
    if opts.null_sentinel ~= nil then
        NULL_SENTINEL = opts.null_sentinel
    end
    if type(opts.logger) == "function" then
        log_warning = opts.logger
    end
    if type(opts.get_current_blind_slot) == "function" then
        get_current_blind_slot = opts.get_current_blind_slot
    end
    if type(opts.get_current_pack_kind) == "function" then
        get_current_pack_kind = opts.get_current_pack_kind
    end
    if type(opts.get_current_ante) == "function" then
        get_current_ante = opts.get_current_ante
    end
    if type(opts.multiplayer) == "table" then
        multiplayer = opts.multiplayer
    end
end

--- Inject or replace the logger function.
--- @param logger_fn function  A function(msg) that logs warning messages.
function Capture.set_logger(logger_fn)
    if type(logger_fn) == "function" then
        log_warning = logger_fn
    end
end

-- ---------------------------------------------------------------------------
-- Shop action types that trigger shop inventory capture (Requirement 2.9)
--
-- shop_entered is included so the very first shop snapshot carries the full
-- inventory the player is choosing from. Without it the viewer has no idea
-- what was on offer until the player buys/rerolls something.
-- ---------------------------------------------------------------------------
local SHOP_ACTIONS = {
    shop_entered   = true,
    buy_joker      = true,
    buy_consumable = true,
    buy_voucher    = true,
    buy_pack       = true,
    reroll_shop    = true,
}

-- ---------------------------------------------------------------------------
-- Map G.STATE numeric values to a human-readable location label. The
-- viewer reads `state.location` to know exactly where the player was at
-- the moment a node was captured — no inference needed.
-- ---------------------------------------------------------------------------
local STATE_NAME_TO_LOCATION = {
    SELECTING_HAND = "playing_blind",
    HAND_PLAYED    = "playing_blind",
    DRAW_TO_HAND   = "playing_blind",
    NEW_ROUND      = "playing_blind",
    ROUND_EVAL     = "round_eval",        -- between blind_beaten and shop
    SHOP           = "shop",
    BLIND_SELECT   = "blind_select",
    -- PLAY_TAROT and all *_PACK / SMODS_BOOSTER_OPENED states are deliberately
    -- NOT mapped. `location` is the STABLE BASE CONTEXT (the screen you're on):
    -- shop / blind_select / playing_blind / round_eval. Using a consumable
    -- (PLAY_TAROT) and opening a booster pack are OVERLAYS — you do them while
    -- standing in the shop or on the blind-select screen, and you stay there.
    -- So these states fall through to last_known_location (shop stays shop,
    -- blind-select stays blind-select). The "I'm in a pack" fact lives on the
    -- orthogonal `state.pack` overlay (from get_current_pack_kind), not here.
    -- Mapping packs/tarot to a location clobbered the base and mis-routed
    -- shop buys / tag-granted packs.
    GAME_OVER      = "game_over",
    MENU           = "menu",
    TUTORIAL       = "tutorial",
    SPLASH         = "splash",
    SANDBOX        = "sandbox",
    DEMO_CTA       = "demo_cta",
}

--- Reverse-lookup `G.STATE` (a number) to its key in `G.STATES`. Returns
--- nil when neither value matches — the location field falls back to
--- "unknown" in that case.
local function resolve_state_name()
    local current = G and G.STATE
    local states  = G and G.STATES
    if not (current and states) then return nil end
    for name, value in pairs(states) do
        if value == current then return name end
    end
    return nil
end

-- Last location that resolved cleanly. The engine flips G.STATE on queued
-- frames, so at the exact moment a pack opens/closes (and other transitions)
-- G.STATE can momentarily match no G.STATES key — without this we'd emit
-- "unknown" and the viewer would lose the player (e.g. a pack node bleeding
-- into the previous boss blind). We always know where we just were, so report
-- that instead of throwing it away.
local last_known_location = nil

--- Build the stable base-context label for the current G.STATE. Pack/consumable
--- overlays fall through to the last resolved base (see STATE_NAME_TO_LOCATION).
--- @return string  One of: "playing_blind", "round_eval", "shop",
---                 "blind_select", "game_over", "menu", "tutorial",
---                 "splash", "sandbox", "demo_cta", "unknown".
local function build_location()
    local name = resolve_state_name()
    if name and STATE_NAME_TO_LOCATION[name] then
        last_known_location = STATE_NAME_TO_LOCATION[name]
        return last_known_location
    end
    -- G.STATE didn't resolve (mid-transition). Fall back to the last place we
    -- knew we were; only emit "unknown" if we've never resolved one.
    return last_known_location or "unknown"
end

--- Clear the remembered location. Called at run start so a new run doesn't
--- inherit the previous run's last-known location (and so unit tests start
--- from a clean slate).
function Capture.reset_location()
    last_known_location = nil
end

-- ---------------------------------------------------------------------------
-- The 12 poker hand types Balatro actually tracks.
--
-- "Royal Flush" is NOT a hand type — Balatro source confirms this. In
-- functions/state_events.lua line 564, "Royal Flush" is set only as a
-- *display label* (`disp_text`) when a Straight Flush happens to be 10
-- through Ace. The scoring name (`text`) stays "Straight Flush", which
-- is what feeds hand levels and what SMODS.last_hand.scoring_name
-- carries. Do not include it in this list.
-- ---------------------------------------------------------------------------
local POKER_HAND_TYPES = {
    "High Card",
    "Pair",
    "Two Pair",
    "Three of a Kind",
    "Straight",
    "Flush",
    "Full House",
    "Four of a Kind",
    "Straight Flush",
    "Five of a Kind",
    "Flush House",
    "Flush Five",
}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Safe field access via pcall. Returns the value on success, or
--- NULL_SENTINEL on failure (with a warning logged).
--- @param accessor function  A zero-argument function that returns the value.
--- @param field_name string  Human-readable field name for logging.
--- @param action_type string The action type being captured (for log context).
--- @return any               The accessed value, or NULL_SENTINEL on error.
local function safe_access(accessor, field_name, action_type)
    local ok, result = pcall(accessor)
    if not ok then
        log_warning(
            "Field '" .. tostring(field_name) .. "' unavailable during action '" ..
            tostring(action_type) .. "': " .. tostring(result)
        )
        return NULL_SENTINEL
    end
    if result == nil then
        return NULL_SENTINEL
    end
    return result
end

--- Build a card entry table from a Balatro card object.
---
--- This is the canonical "describe a playing card" helper used to populate
--- state.hand / state.deck / state.discard_pile and the action.cards arrays
--- on play_hand / discard / select_from_pack.
---
--- Exposed both as a private upvalue (so the existing internal callers stay
--- inlined) and via Capture.describe_playing_card below.
---
--- @param card table  A card object from G.hand.cards, G.deck.cards, etc.
--- @return table      { id, rank, suit, enhancement, edition, seal }
local function build_card_entry(card)
    local id = "unknown"
    local rank = "?"
    local suit = "?"
    local enhancement = "none"
    local edition = "base"
    local seal = "none"

    -- Primary ID source: card.base.id
    if card.base and card.base.id then
        id = tostring(card.base.id)
    end

    -- Override with config.card.id if available (more specific)
    if card.config and card.config.card and card.config.card.id then
        id = tostring(card.config.card.id)
    end

    -- Rank from card.base.value
    if card.base and card.base.value then
        rank = tostring(card.base.value)
    end

    -- Suit from card.base.suit
    if card.base and card.base.suit then
        suit = tostring(card.base.suit)
    end

    -- Enhancement from card.config.center
    if card.config and card.config.center then
        local center = card.config.center
        if type(center) == "table" and center.key then
            local key = tostring(center.key)
            if key ~= "c_base" then
                enhancement = key:gsub("^m_", "")
            end
        elseif type(center) == "string" and center ~= "c_base" then
            enhancement = center:gsub("^m_", "")
        end
    end

    -- Edition
    if card.edition then
        if type(card.edition) == "table" then
            if card.edition.foil then
                edition = "foil"
            elseif card.edition.holo then
                edition = "holographic"
            elseif card.edition.polychrome then
                edition = "polychrome"
            end
        elseif type(card.edition) == "string" then
            edition = card.edition
        end
    end

    -- Seal
    if card.seal then
        seal = tostring(card.seal)
    end

    -- Permanent bonuses applied by jokers like Hiker (perma_bonus chips),
    -- Sock and Buskin retriggers, Steamodded perma_x_mult, etc. These are
    -- real per-card state the player can see in-game (the chip total on
    -- the card visibly grows). We capture only the non-default values so
    -- vanilla cards don't carry empty bonus tables.
    --
    -- Field list mirrors Steamodded's perma-bonus spec:
    -- https://github.com/Steamodded/smods/wiki/Perma-bonuses
    local PERMA_FIELDS = {
        "perma_bonus", "perma_mult", "perma_x_chips", "perma_x_mult",
        "perma_h_chips", "perma_h_mult", "perma_h_x_chips", "perma_h_x_mult",
        "perma_p_dollars", "perma_h_dollars",
        "perma_score", "perma_x_score", "perma_h_score", "perma_h_x_score",
        "perma_blind_size", "perma_x_blind_size",
        "perma_h_blind_size", "perma_h_x_blind_size",
        "perma_repetitions",
    }
    local perma = nil
    if card.ability then
        for _, key in ipairs(PERMA_FIELDS) do
            local v = card.ability[key]
            if type(v) == "number" and v ~= 0 then
                -- A value of 1 on the multiplicative perma_x_* fields is the
                -- identity (no effect) — skip those too.
                local is_multiplicative = key:find("perma_x_") or key:find("perma_h_x_")
                if not (is_multiplicative and v == 1) then
                    perma = perma or {}
                    perma[key] = v
                end
            end
        end
    end

    local entry = {
        id = id,
        rank = rank,
        suit = suit,
    }

    -- Modifiers — only emit when non-default. Most cards are vanilla
    -- (no enhancement, no edition, no seal), so omitting the keys for
    -- those saves ~40-50 bytes per card and ~25% of state.full_deck size
    -- on a typical run. Viewer treats absent keys as the documented
    -- defaults: enhancement="none", edition="base", seal="none".
    if enhancement ~= "none" then entry.enhancement = enhancement end
    if edition     ~= "base" then entry.edition     = edition     end
    if seal        ~= "none" then entry.seal        = seal        end

    -- Per-instance unique identity. Balatro assigns `card.sort_id` from a
    -- monotonically-increasing global at Card construction (see Card:init in
    -- game.lua) and never reassigns it. This is the only way to disambiguate
    -- cards that share a rank+suit (two 2♣ from a duplicated deck) or to
    -- track a single card as it moves between deck/hand/discard. The viewer
    -- and ETL match by `sort_id` whenever it's present, falling back to `id`
    -- (rank-only) for older runs that pre-date this field.
    if type(card.sort_id) == "number" then
        entry.sort_id = card.sort_id
    end

    if perma then entry.perma = perma end

    -- Card scoring values — chips, mult, x_mult, held-in-hand effects,
    -- and money-on-score. These let the viewer show the card's current
    -- contribution in tooltips (like joker badges). Only included when
    -- non-default so vanilla cards stay compact.
    if card.ability then
        local bonus = card.ability.bonus
        if type(bonus) == "number" and bonus > 0 then
            entry.chips = bonus
        end
        local mult = card.ability.mult
        if type(mult) == "number" and mult > 0 then
            entry.mult = mult
        end
        local x_mult = card.ability.x_mult
        if type(x_mult) == "number" and x_mult > 1 then
            entry.x_mult = x_mult
        end
        local h_mult = card.ability.h_mult
        if type(h_mult) == "number" and h_mult > 1 then
            entry.h_mult = h_mult
        end
        local p_dollars = card.ability.p_dollars
        if type(p_dollars) == "number" and p_dollars > 0 then
            entry.p_dollars = p_dollars
        end
    end

    return entry
end

--- Build an ordered list of card entries from a card area.
--- @param cards table  Array of card objects.
--- @return table       Array of card entry tables.
local function build_card_list(cards)
    local list = {}
    for i = 1, #cards do
        list[i] = build_card_entry(cards[i])
    end
    return list
end

--- Append every card in `area.cards` to `full_deck`, tagged with the area
--- label. Silently no-ops when `area` or `area.cards` is nil so a partial
--- snapshot is still emitted when one of deck/hand/discard is unavailable.
---
--- The area label is omitted when it equals "deck" — most cards live in
--- the deck most of the time, and the viewer reads absent `area` as
--- "deck" to keep the descriptor compact.
---
--- Wrapped in pcall so that an area which throws on read (vs being nil)
--- still leaves the other areas' contributions intact in `full_deck`.
---
--- @param full_deck table  Array being assembled by build_full_deck.
--- @param area_label string  One of "deck", "hand", "discard".
--- @param area table|nil  A Balatro CardArea (G.deck, G.hand, G.discard) or nil.
local function append_area_to_full_deck(full_deck, area_label, area)
    pcall(function()
        if not (area and area.cards) then return end
        for i = 1, #area.cards do
            local descriptor = build_card_entry(area.cards[i])
            if area_label ~= "deck" then descriptor.area = area_label end
            full_deck[#full_deck + 1] = descriptor
        end
    end)
end

--- Snapshot every card the player owns across deck, hand, and discard.
---
--- Each entry is a Card_Descriptor (the same shape build_card_entry returns)
--- with an extra `area` field set to "deck", "hand", or "discard". Order
--- within each area follows the engine's internal G.deck/G.hand/G.discard
--- order, and the three areas are concatenated in deck → hand → discard
--- order so the snapshot reads like a single ordered list grouped by area.
---
--- An area whose cards table is missing or unreadable contributes nothing;
--- the other areas still appear, so a partial failure produces a partial
--- snapshot rather than an empty one.
---
--- @return table  Array of Card_Descriptors with `area` tags.
local function build_full_deck()
    local full_deck = {}
    append_area_to_full_deck(full_deck, "deck", G and G.deck)
    append_area_to_full_deck(full_deck, "hand", G and G.hand)
    append_area_to_full_deck(full_deck, "discard", G and G.discard)
    return full_deck
end

--- Build the joker list with slot positions and internal state.
-- Jokers whose effect targets a card chosen per-ROUND, stored in
-- G.GAME.current_round.<card> rather than the joker's ability. Maps the
-- engine's source field → the internal_state key the viewer reads. Engine:
-- card.lua (Mail-In 880, The Idol 840, Ancient Joker 891, Castle 894).
local ROUND_TARGET_JOKERS = {
    j_mail    = { card = "mail_card",    fields = { rank = "mail_rank" } },
    j_idol    = { card = "idol_card",    fields = { rank = "idol_rank", suit = "idol_suit" } },
    j_ancient = { card = "ancient_card", fields = { suit = "ancient_suit" } },
    j_castle  = { card = "castle_card",  fields = { suit = "castle_suit" } },
}

--- @param joker_cards table  Array of joker card objects from G.jokers.cards.
--- @return table             Array of joker entry tables.
local function build_joker_list(joker_cards)
    local list = {}
    for i = 1, #joker_cards do
        local joker = joker_cards[i]
        local entry = {
            id = "j_unknown",
            name = "Unknown",
            slot = i,
            edition = "base",
            enhancement = "none",
            seal = "none",
            internal_state = {},
        }

        -- ID from config.center.key
        if joker.config and joker.config.center and joker.config.center.key then
            entry.id = tostring(joker.config.center.key)
        end

        -- Per-instance unique identity. The engine assigns every Card (jokers
        -- included) a unique `sort_id` at creation (card.lua:24). `id` is the
        -- center key (duplicates share it, e.g. two Brainstorms) and `slot`
        -- renumbers on reorder, so neither identifies an instance. sort_id does
        -- — the viewer diffs by it to tell a genuinely NEW joker from one that
        -- merely moved. Mirrors what the playing-card builder already records.
        if type(joker.sort_id) == "number" then
            entry.sort_id = joker.sort_id
        end

        -- Name from ability.name (primary) or config.center.name (fallback)
        if joker.ability and joker.ability.name then
            entry.name = tostring(joker.ability.name)
        elseif joker.config and joker.config.center and joker.config.center.name then
            entry.name = tostring(joker.config.center.name)
        end

        -- Edition
        if joker.edition then
            if type(joker.edition) == "table" then
                if joker.edition.foil then
                    entry.edition = "foil"
                elseif joker.edition.holo then
                    entry.edition = "holographic"
                elseif joker.edition.polychrome then
                    entry.edition = "polychrome"
                end
            elseif type(joker.edition) == "string" then
                entry.edition = joker.edition
            end
        end

        -- Enhancement (jokers don't typically have enhancements, but record if present)
        if joker.config and joker.config.center and joker.config.center.key then
            local key = tostring(joker.config.center.key)
            if key:match("^m_") then
                entry.enhancement = key:gsub("^m_", "")
            end
        end

        -- Seal
        if joker.seal then
            entry.seal = tostring(joker.seal)
        end

        -- Internal state: capture only the mutable ability fields that carry
        -- meaningful information about this joker's current state.
        --
        -- We skip:
        --   1. Meta/identity fields (name, order, set, description, type)
        --   2. Numeric fields whose value is 0 (additive default — no change)
        --   3. Numeric fields whose value is 1 AND whose key is a known
        --      multiplicative field (x_mult, x_chips, h_x_mult, h_x_chips,
        --      perma_x_mult, perma_x_chips, perma_h_x_mult, perma_h_x_chips)
        --      — 1 is the multiplicative identity, meaning "no effect"
        --   4. Boolean false (default)
        --   5. Empty strings (default)
        --
        -- This keeps things like Ride the Bus's `consecutive` counter or
        -- Lucky Cat's `Xmult` accumulator while dropping the 25+ zero/one
        -- fields every joker carries by default.
        local MULTIPLICATIVE_DEFAULTS = {
            x_mult = true, x_chips = true,
            h_x_mult = true, h_x_chips = true,
            perma_x_mult = true, perma_x_chips = true,
            perma_h_x_mult = true, perma_h_x_chips = true,
        }
        local META_FIELDS = {
            name = true, order = true, set = true,
            description = true, type = true,
        }
        if joker.ability then
            local state = {}
            for k, v in pairs(joker.ability) do
                if not META_FIELDS[k] then
                    if type(v) == "number" then
                        -- Skip 0 (additive default) and 1 on multiplicative fields
                        if v ~= 0 and not (v == 1 and MULTIPLICATIVE_DEFAULTS[k]) then
                            state[k] = v
                        end
                    elseif type(v) == "boolean" and v ~= false then
                        state[k] = v
                    elseif type(v) == "string" and v ~= "" then
                        state[k] = v
                    elseif type(v) == "table" then
                        -- Nested ability tables (e.g. The Idol's `extra` carrying
                        -- {suit, rank}, Castle's `extra` carrying scaling chips +
                        -- current suit, Mail-In Rebate's rank tracker, etc.).
                        -- We capture a shallow copy of primitive children so the
                        -- viewer can show the joker's current target / scaled
                        -- value without us hard-coding a separate field per joker.
                        local sub = {}
                        for sk, sv in pairs(v) do
                            local svt = type(sv)
                            if svt == "number" or svt == "string" or svt == "boolean" then
                                sub[sk] = sv
                            end
                        end
                        if next(sub) ~= nil then state[k] = sub end
                    end
                end
            end
            entry.internal_state = next(state) and state or {}
        end

        -- Several jokers' targets live in ROUND state
        -- (G.GAME.current_round.*_card), NOT the joker's ability — so the
        -- per-joker walk above can't see them. Stamp the current target into
        -- internal_state so the viewer can show what each is "on" this round.
        -- Engine refs (card.lua): Mail-In 880, The Idol 840, Ancient 891,
        -- Castle 894. Targets reroll each round (common_events.lua).
        local round_target = ROUND_TARGET_JOKERS[entry.id]
        if round_target then
            pcall(function()
                local card = G and G.GAME and G.GAME.current_round
                    and G.GAME.current_round[round_target.card]
                if not card then return end
                entry.internal_state = entry.internal_state or {}
                for src_key, dest_key in pairs(round_target.fields) do
                    if card[src_key] ~= nil then
                        entry.internal_state[dest_key] = tostring(card[src_key])
                    end
                end
            end)
        end

        list[i] = entry
    end
    return list
end

--- Build the consumables list.
--- @param consumable_cards table  Array of consumable card objects.
--- @return table                  Array of { id, name, edition } tables.
local function build_consumables_list(consumable_cards)
    local list = {}
    for i = 1, #consumable_cards do
        local card = consumable_cards[i]
        local id = "co_unknown"
        local name = "Unknown"
        local edition = "base"

        if card.config and card.config.center and card.config.center.key then
            id = tostring(card.config.center.key)
        end
        if card.ability and card.ability.name then
            name = tostring(card.ability.name)
        elseif card.config and card.config.center and card.config.center.name then
            name = tostring(card.config.center.name)
        end

        -- Edition is mostly relevant for Negative consumables (Perkeo
        -- creates these). Capturing all editions defensively keeps the
        -- viewer's overlay logic uniform across joker / consumable / card.
        if card.edition then
            if type(card.edition) == "table" then
                if     card.edition.foil       then edition = "foil"
                elseif card.edition.holo       then edition = "holographic"
                elseif card.edition.polychrome then edition = "polychrome"
                elseif card.edition.negative   then edition = "negative"
                end
            elseif type(card.edition) == "string" then
                edition = card.edition
            end
        end

        list[i] = { id = id, name = name, edition = edition }
    end
    return list
end

--- Resolve a voucher key (e.g. "v_planet_tycoon") to its display name.
--- Prefers the real center name from G.P_CENTERS; falls back to a readable
--- de-prefixed form so tests (and any missing center) still get something.
local function resolve_voucher_name(key)
    local ok, name = pcall(function()
        local center = G and G.P_CENTERS and G.P_CENTERS[key]
        return center and center.name
    end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return tostring(key):gsub("^v_", ""):gsub("_", " ")
end

--- Build the vouchers list from G.GAME.used_vouchers.
--- That table's keys are voucher IDs and values are truthy when the voucher
--- has been redeemed. If the table is nil (no vouchers yet), returns an empty
--- array.
--- @param vouchers_table table|nil  The G.GAME.used_vouchers table.
--- @return table                    Array of { id, name } tables, sorted by id.
local function build_vouchers_list(vouchers_table)
    local list = {}
    if type(vouchers_table) ~= "table" then
        return list
    end
    for k, v in pairs(vouchers_table) do
        if v then
            list[#list + 1] = {
                id   = tostring(k),
                name = resolve_voucher_name(k),
            }
        end
    end
    -- Stable order (pairs() is unordered) so identical voucher sets serialize
    -- identically across nodes.
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

--- Build the hand_levels map for all 13 poker hand types.
--- @param hands_table table  The G.GAME.hands table.
--- @return table             Map from hand type name to { level, chips, mult, played }.
local function build_hand_levels(hands_table)
    local levels = {}
    for _, hand_type in ipairs(POKER_HAND_TYPES) do
        local hand_data = hands_table[hand_type]
        if hand_data then
            levels[hand_type] = {
                level  = hand_data.level or 1,
                chips  = hand_data.chips or 0,
                mult   = hand_data.mult or 0,
                -- `played` is the run-long counter Balatro maintains for
                -- each hand type. Supernova reads it at score-time to
                -- compute its +Mult contribution (literally `+played`).
                -- Surfacing it lets the viewer reconstruct what jokers
                -- like Supernova will actually contribute on a hand.
                played = hand_data.played or 0,
            }
        else
            -- Default values if hand type data is missing
            levels[hand_type] = {
                level  = 1,
                chips  = 0,
                mult   = 0,
                played = 0,
            }
        end
    end
    return levels
end

--- Build the shop inventory list.
--- Reads from G.shop_jokers, G.shop_vouchers, G.shop_booster, G.shop_tarot.
---
--- The item type is derived from `card.ability.set` (Joker, Tarot, Planet,
--- Spectral, Voucher, Booster), NOT from which physical CardArea the card
--- sits in — modern Balatro stuffs jokers AND consumables into
--- G.shop_jokers, so checking the area would mislabel a consumable as a
--- joker (and vice-versa for any future shop reshuffles).
--- @return table  Array of { type, id, name, cost } tables, or empty array.
local function build_shop_inventory()
    local inventory = {}

    --- Map an ability set string to our canonical inventory `type`.
    local function inventory_type_for(card)
        local set = card.ability and card.ability.set or nil
        if set == "Joker" then return "joker" end
        if set == "Voucher" then return "voucher" end
        if set == "Booster" then return "pack" end
        if set == "Tarot" or set == "Planet" or set == "Spectral" or set == "Consumeables" then
            return "consumable"
        end
        -- Fall back to the area name as a last resort.
        return "unknown"
    end

    -- Helper to add items from a shop area
    local function add_shop_items(area)
        if not area or not area.cards then return end
        for _, card in ipairs(area.cards) do
            local item = {
                type = inventory_type_for(card),
                id   = "unknown",
                name = "Unknown",
                cost = 0,
            }
            if card.config and card.config.center and card.config.center.key then
                item.id = tostring(card.config.center.key)
            end
            if card.ability and card.ability.name then
                item.name = tostring(card.ability.name)
            elseif card.config and card.config.center and card.config.center.name then
                item.name = tostring(card.config.center.name)
            end
            if card.cost then
                item.cost = card.cost
            end

            -- Tag-decoration markers. Rare/Uncommon/Foil/Holo/Poly/Negative/
            -- Coupon tags set `card.ability.couponed = true` synchronously
            -- during shop population, even though the actual `card:set_cost()`
            -- call that drops cost to 0 fires inside an async `yep` callback.
            -- Surfacing the flag here lets the viewer render "Free" or the
            -- right edition badge regardless of whether the async cost
            -- update happened before our snapshot.
            if card.ability and card.ability.couponed then
                item.couponed = true
            end

            -- Edition: read from card.edition first (synchronous), then
            -- temp_edition (set during the yep callback before the real
            -- edition is applied). Either signals the foil/holo/poly/neg
            -- decoration is incoming.
            local edition_name = nil
            if card.edition then
                if card.edition.foil       then edition_name = "foil"
                elseif card.edition.holo   then edition_name = "holographic"
                elseif card.edition.polychrome then edition_name = "polychrome"
                elseif card.edition.negative   then edition_name = "negative"
                end
            end
            if edition_name then
                item.edition = edition_name
            end

            inventory[#inventory + 1] = item
        end
    end

    local ok1, shop_jokers   = pcall(function() return G.shop_jokers end)
    if ok1 and shop_jokers   then add_shop_items(shop_jokers)   end

    local ok2, shop_vouchers = pcall(function() return G.shop_vouchers end)
    if ok2 and shop_vouchers then add_shop_items(shop_vouchers) end

    local ok3, shop_booster  = pcall(function() return G.shop_booster end)
    if ok3 and shop_booster  then add_shop_items(shop_booster)  end

    -- G.shop_tarot is legacy — kept for older Balatro versions where
    -- consumables had their own row. inventory_type_for() reads ability.set
    -- so the type label stays correct regardless.
    local ok4, shop_tarot    = pcall(function() return G.shop_tarot end)
    if ok4 and shop_tarot    then add_shop_items(shop_tarot)    end

    return inventory
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Build a complete Game_State snapshot from the global G table.
---
--- @param action_type string  The action type being captured. Used to determine
---                            whether shop inventory should be included.
--- @return table              A Game_State table matching the JSON schema.
function Capture.build_game_state(action_type)
    action_type = action_type or ""

    local state = {}

    -- Top-level scalar fields (Requirement 2.1)
    --
    -- Prefer the run-scoped logical ante stamped by select_blind, falling
    -- back to the engine's `G.GAME.round_resets.ante`. The engine bumps
    -- the value at the END of an ante (right before `blind_beaten` /
    -- `starting_shop` fire on a boss blind), which would otherwise
    -- attribute the boss-defeat and the post-boss shop to the NEXT ante.
    -- For `select_blind` itself we always read the engine value because
    -- that's the moment the logical ante is being set.
    if action_type == "select_blind" then
        state.ante = safe_access(
            function() return G.GAME.round_resets.ante end,
            "ante", action_type
        )
    else
        local logical_ante = nil
        local ok, value = pcall(get_current_ante)
        if ok then logical_ante = value end
        if type(logical_ante) == "number" then
            state.ante = logical_ante
        else
            state.ante = safe_access(
                function() return G.GAME.round_resets.ante end,
                "ante", action_type
            )
        end
    end

    state.blind_name = safe_access(
        function() return G.GAME.blind.name end,
        "blind_name", action_type
    )

    state.blind_target = safe_access(
        function() return G.GAME.blind.chips end,
        "blind_target", action_type
    )

    state.boss_blind_effect = safe_access(
        function()
            local blind = G.GAME.blind
            if blind and blind.config and blind.config.blind then
                local blind_cfg = blind.config.blind
                if blind_cfg.boss then
                    return blind_cfg.key or blind_cfg.name
                end
            end
            return nil  -- becomes NULL_SENTINEL via safe_access
        end,
        "boss_blind_effect", action_type
    )

    -- blind_slot (Requirements 2.3, 2.5, 2.6, 2.7)
    -- Read the run-scoped current slot via the injected getter. For
    -- select_blind captures, hooks.lua overwrites this field after
    -- build_game_state returns with the freshly-resolved slot, so a nil
    -- result here is expected and must NOT emit a warning. For all other
    -- action types (round actions, shop actions), nil means the slot has
    -- not yet been stamped by a prior select_blind and we record null plus
    -- a warning per Requirement 2.7.
    local slot_ok, slot_value = pcall(get_current_blind_slot)
    if not slot_ok then
        log_warning(
            "Field 'blind_slot' unavailable during action '" ..
            tostring(action_type) .. "': " .. tostring(slot_value)
        )
        state.blind_slot = NULL_SENTINEL
    elseif slot_value == nil then
        if action_type ~= "select_blind" then
            log_warning(
                "Field 'blind_slot' unavailable during action '" ..
                tostring(action_type) .. "': current_blind_slot is nil"
            )
        end
        state.blind_slot = NULL_SENTINEL
    else
        state.blind_slot = slot_value
    end

    state.score = safe_access(
        function()
            local c = G.GAME.chips
            -- A score that overflowed a double to inf/NaN renders in-game as
            -- "naneinf" (number_format(inf), misc_functions.lua:956). JSON has
            -- no inf literal and the serializer nulls non-finite numbers, which
            -- would drop a maxed-out run -- store the string the game shows.
            if type(c) == "number" and (c ~= c or c == math.huge or c == -math.huge) then
                return "naneinf"
            end
            return c
        end,
        "score", action_type
    )

    state.money = safe_access(
        function() return G.GAME.dollars end,
        "money", action_type
    )

    state.hands_remaining = safe_access(
        function() return G.GAME.current_round.hands_left end,
        "hands_remaining", action_type
    )

    state.discards_remaining = safe_access(
        function() return G.GAME.current_round.discards_left end,
        "discards_remaining", action_type
    )

    -- Number of discards the player has consumed this round. Counter to
    -- `discards_remaining` for "did the player use a discard yet?" queries
    -- (Delayed Gratification, Trading Card prediction). Resets to 0 on
    -- `setting_blind` per the engine.
    state.discards_used = safe_access(
        function() return G.GAME.current_round.discards_used end,
        "discards_used", action_type
    )

    state.seed = safe_access(
        function() return G.GAME.pseudorandom.seed end,
        "seed", action_type
    )

    state.timestamp = safe_access(
        function() return os.time() end,
        "timestamp", action_type
    )

    -- Full deck snapshot — every card the player owns across deck/hand/
    -- discard, tagged with its CardArea. Single source of truth for card
    -- listings: the viewer (and these tests) derive per-area subsets
    -- (hand / deck / discard_pile) by filtering on `area`. Replaces the
    -- three separate `state.hand` / `state.deck` / `state.discard_pile`
    -- arrays we used to emit — they were exact duplicates of full_deck
    -- filtered by area, costing ~38% of the raw run JSON for nothing.
    state.full_deck = safe_access(
        function() return build_full_deck() end,
        "full_deck", action_type
    )

    -- Jokers with slot positions and internal state (Requirement 2.5)
    state.jokers = safe_access(
        function() return build_joker_list(G.jokers.cards) end,
        "jokers", action_type
    )

    -- Consumables (Requirement 2.6)
    state.consumables = safe_access(
        function() return build_consumables_list(G.consumeables.cards) end,
        "consumables", action_type
    )

    -- Vouchers (Requirement 2.7). Redeemed vouchers live in
    -- G.GAME.used_vouchers (key -> true), NOT G.GAME.vouchers (which is the
    -- shop's voucher slot, usually empty/absent) — that's why state.vouchers
    -- always came back empty.
    state.vouchers = safe_access(
        function() return build_vouchers_list(G.GAME.used_vouchers) end,
        "vouchers", action_type
    )

    -- Hand levels for all 13 poker hand types (Requirement 2.8)
    state.hand_levels = safe_access(
        function() return build_hand_levels(G.GAME.hands) end,
        "hand_levels", action_type
    )

    -- Location label, computed early so shop-inventory capture can key off it.
    -- (Assigned to state.location below.)
    local location = safe_access(
        function() return build_location() end,
        "location", action_type
    )

    -- Shop inventory (Requirement 2.9). Capture whenever the player is standing
    -- in the shop — not only on buy/reroll actions. A booster pack is an OVERLAY
    -- over the shop (location stays "shop"), and the shop's CardAreas persist
    -- behind it (engine only slides G.shop off-screen — game.lua:3342), so
    -- open_pack / select_from_pack nodes, and mid-shop sells/uses, all carry the
    -- shop's offerings. That's the decision context the viewer wants: "what
    -- jokers were in the shop when I opened this pack". Gating on location also
    -- subsumes the SHOP_ACTIONS whitelist; the latter is kept as a belt-and-
    -- suspenders for the brief frames where location may not yet read "shop".
    if SHOP_ACTIONS[action_type] or location == "shop" then
        state.shop_inventory = safe_access(
            function() return build_shop_inventory() end,
            "shop_inventory", action_type
        )
    else
        state.shop_inventory = {}
    end

    -- Active tags. Snapshotted on every node so the viewer always knows
    -- what tags the player is carrying; cheap to read and worth always
    -- including for context.
    state.tags = safe_access(
        function() return Capture.snapshot_active_tags() end,
        "tags", action_type
    )

    -- Location label. Always present, derived from G.STATE (computed above so
    -- shop-inventory capture can key off it). The viewer uses this to know
    -- exactly where the player was — selling a joker on the blind-select screen
    -- is NOT the same as selling one in the shop, and the viewer should be able
    -- to tell without guessing.
    state.location = location

    -- Pack overlay. Orthogonal to location: while a booster pack is open the
    -- player is still standing in the shop or on the blind-select screen
    -- (state.location), with the pack layered on top. Set only when a pack is
    -- actually open so non-pack nodes stay clean (absent === not in a pack).
    -- Sourced from run_state.current_pack_kind via the injected accessor, so it
    -- is present for EVERY node in the pack window — including a use_consumable
    -- fired inside the pack, whose action type alone wouldn't reveal the pack.
    local pack_ok, pack_kind = pcall(get_current_pack_kind)
    if pack_ok and type(pack_kind) == "string" then
        state.pack = { kind = pack_kind }
    end

    -- PvP state (Requirements 4.2, 4.3, 4.4)
    -- Attach state.pvp ONLY when the injected Multiplayer accessor reports
    -- enabled. When disabled, do not set the field at all and do not touch
    -- any Multiplayer-namespaced global (Requirement 4.3).
    if multiplayer and multiplayer.enabled then
        state.pvp = {
            opponent_id = safe_access(
                function() return multiplayer.opponent_id() end,
                "pvp.opponent_id", action_type
            ),
            opponent_name = safe_access(
                function() return multiplayer.opponent_name() end,
                "pvp.opponent_name", action_type
            ),
            player_running_score = safe_access(
                function() return multiplayer.player_score() end,
                "pvp.player_running_score", action_type
            ),
            opponent_running_score = safe_access(
                function() return multiplayer.opponent_score() end,
                "pvp.opponent_running_score", action_type
            ),
            player_lives = safe_access(
                function() return multiplayer.player_lives() end,
                "pvp.player_lives", action_type
            ),
            opponent_lives = safe_access(
                function() return multiplayer.opponent_lives() end,
                "pvp.opponent_lives", action_type
            ),
            opponent_hand_score = safe_access(
                function() return multiplayer.opponent_hand_score() end,
                "pvp.opponent_hand_score", action_type
            ),
            opponent_hands_left = safe_access(
                function() return multiplayer.opponent_hands_left() end,
                "pvp.opponent_hands_left", action_type
            ),
            pvp_start_round = safe_access(
                function() return multiplayer.pvp_start_round() end,
                "pvp.pvp_start_round", action_type
            ),
        }
    end

    return state
end

--- Describe a single shop / consumable / pack card. Used by mod.calculate
--- to attach rich detail to buy_joker / buy_consumable / buy_voucher /
--- buy_pack / sell_joker / use_consumable actions, so the viewer doesn't
--- have to maintain its own ID -> name table.
---
--- The returned shape is intentionally a superset that covers every center
--- type the shop can present. Callers are free to ignore fields irrelevant
--- to their action.
---
--- @param card table  Any Balatro card with a `config.center`.
--- @return table {
---   id, name, set, rarity, cost, sell_value,
---   edition, enhancement, seal,
---   pack_kind, pack_size, pack_choose
--- }
function Capture.describe_card(card)
    local description = {
        id          = "unknown",
        name        = "Unknown",
        set         = "unknown",
        rarity      = nil,
        cost        = 0,
        sell_value  = 0,
        edition     = "base",
        enhancement = "none",
        seal        = "none",
        pack_kind   = nil,
        pack_size   = nil,
        pack_choose = nil,
    }

    if type(card) ~= "table" then return description end

    local ok, _ = pcall(function()
        local center = card.config and card.config.center or nil

        if center and center.key then description.id = tostring(center.key) end

        -- Resolve display name. Prefer:
        --   1. card.ability.name when it isn't just the center key (e.g.
        --      vanilla Ouija stamps "Ouija"; SMODS-modded consumables
        --      sometimes leave it as the namespaced key like
        --      "c_mp_ouija_standard").
        --   2. center.name (the registered display name from SMODS or
        --      vanilla center definitions).
        --   3. Look up the localized name from G.localization.descriptions
        --      so a modded consumable's "name = 'Ouija'" entry surfaces.
        --   4. Fall back to the id.
        local function looks_like_key(s)
            -- center keys conventionally start with a type prefix
            -- (c_, j_, v_, m_) followed by lowercase identifiers.
            return type(s) == "string" and s:match("^[a-z]_[%w_]+$") ~= nil
        end

        local name_from_ability = card.ability and card.ability.name
        local name_from_center  = center and center.name
        local set_for_lookup    = card.ability and card.ability.set or center and center.set

        if name_from_ability and not looks_like_key(name_from_ability) then
            description.name = tostring(name_from_ability)
        elseif name_from_center and not looks_like_key(name_from_center) then
            description.name = tostring(name_from_center)
        elseif center and center.key and set_for_lookup
            and G and G.localization and G.localization.descriptions
            and G.localization.descriptions[set_for_lookup]
            and G.localization.descriptions[set_for_lookup][center.key]
            and G.localization.descriptions[set_for_lookup][center.key].name
        then
            description.name = tostring(G.localization.descriptions[set_for_lookup][center.key].name)
        elseif name_from_ability then
            description.name = tostring(name_from_ability)
        elseif name_from_center then
            description.name = tostring(name_from_center)
        end

        if card.ability and card.ability.set then
            description.set = tostring(card.ability.set)
        elseif center and center.set then
            description.set = tostring(center.set)
        end

        -- Joker rarity: number 1-4 in vanilla, string for modded rarities.
        if center and center.rarity ~= nil then
            description.rarity = center.rarity
        end

        if card.cost       then description.cost       = card.cost       end
        if card.sell_cost  then description.sell_value = card.sell_cost  end

        -- Booster packs carry their own size/choose/kind on the center.
        if center and center.config then
            description.pack_size   = center.config.extra
            description.pack_choose = center.config.choose
        end
        if center and center.kind then description.pack_kind = tostring(center.kind) end

        if card.edition then
            if type(card.edition) == "table" then
                if     card.edition.foil       then description.edition = "foil"
                elseif card.edition.holo       then description.edition = "holographic"
                elseif card.edition.polychrome then description.edition = "polychrome"
                elseif card.edition.negative   then description.edition = "negative"
                end
            elseif type(card.edition) == "string" then
                description.edition = card.edition
            end
        end

        if center and center.key then
            local key = tostring(center.key)
            if key:match("^m_") and key ~= "c_base" then
                description.enhancement = key:gsub("^m_", "")
            end
        end

        if card.seal then description.seal = tostring(card.seal) end
    end)

    if not ok then
        log_warning("describe_card failed; emitting partial description")
    end

    return description
end

--- True when the card looks like a playing card (rank/suit) rather than a
--- center (joker / consumable / voucher / booster). Used by the pack
--- snapshots so Standard packs end up with describe_playing_card entries
--- (rank/suit/enhancement/edition/seal) rather than the center-shaped
--- describe_card payload, which would lose rank and suit.
local function looks_like_playing_card(card)
    if type(card) ~= "table" then return false end
    if not card.base then return false end
    return card.base.value ~= nil or card.base.suit ~= nil
end

--- Snapshot the cards currently offered inside an open booster pack. Used
--- by the open_pack action so the viewer always shows what was on offer
--- the moment the pack opened, even before any selection happens.
---
--- The shape mirrors describe_card / describe_playing_card depending on
--- the kind of card the pack holds, so the viewer can render it with the
--- same component used for shop / hand cards.
---
--- @return table  Array of describe entries (empty when no pack is open).
function Capture.snapshot_pack_contents()
    local contents = {}
    local ok, _ = pcall(function()
        if G and G.pack_cards and G.pack_cards.cards then
            for _, card in ipairs(G.pack_cards.cards) do
                if looks_like_playing_card(card) then
                    contents[#contents + 1] = Capture.describe_playing_card(card)
                else
                    contents[#contents + 1] = Capture.describe_card(card)
                end
            end
        end
    end)
    if not ok then
        log_warning("snapshot_pack_contents failed; emitting empty list")
    end
    return contents
end

--- Snapshot the player's current hand. Public wrapper around the same
--- Snapshot every card the player owns across deck/hand/discard, in
--- the same shape as `state.full_deck`. Used by the open_pack polling
--- Event to refresh the snapshot once Arcana / Spectral packs have
--- emplaced their cards into G.hand (the engine draws cards INTO
--- G.hand.cards on a delayed Event when those packs open, so the
--- at-enqueue full_deck caught the pre-draw hand area as empty).
---
--- @return table  Array of Card_Descriptors with area tags (empty when G is unavailable).
function Capture.snapshot_full_deck()
    return build_full_deck()
end

--- builder used to populate state.hand, used by the open_pack polling
--- Event to refresh the hand once an Arcana / Spectral pack has emplaced
--- its cards (the engine draws cards INTO G.hand.cards on a delayed
--- Event when those packs open, so the at-enqueue snapshot may have
--- caught the pre-draw hand).
---
--- @return table  Array of card entry tables (empty when no hand is available).
function Capture.snapshot_hand()
    local hand = {}
    local ok, _ = pcall(function()
        if G and G.hand and G.hand.cards then
            for i = 1, #G.hand.cards do
                local entry = build_card_entry(G.hand.cards[i])
                if entry then hand[#hand + 1] = entry end
            end
        end
    end)
    if not ok then
        log_warning("snapshot_hand failed; emitting empty list")
    end
    return hand
end

--- Snapshot the full shop inventory. Public wrapper around the existing
--- private builder so mod.calculate / hooks.lua can attach the snapshot to
--- specific actions (e.g. shop_entered) without re-running build_game_state.
---
--- @return table  Array of { type, id, name, cost } entries.
function Capture.snapshot_shop_inventory()
    local snapshot = {}
    local ok, result = pcall(build_shop_inventory)
    if ok and type(result) == "table" then
        snapshot = result
    else
        log_warning("snapshot_shop_inventory failed; emitting empty list")
    end
    return snapshot
end

--- Describe a playing card. Public wrapper around the same builder used to
--- populate state.hand / state.deck / state.discard_pile, so action payloads
--- can record the rank / suit / enhancement / edition / seal of every card
--- the player interacted with — not just its id.
---
--- @param card table  A playing card object.
--- @return table      { id, rank, suit, enhancement, edition, seal }
function Capture.describe_playing_card(card)
    if type(card) ~= "table" then
        return { id = "unknown", rank = "?", suit = "?",
                 enhancement = "none", edition = "base", seal = "none" }
    end
    local ok, entry = pcall(build_card_entry, card)
    if ok and type(entry) == "table" then return entry end
    log_warning("describe_playing_card failed; emitting placeholder entry")
    return { id = "unknown", rank = "?", suit = "?",
             enhancement = "none", edition = "base", seal = "none" }
end

--- Describe a list of playing cards. Convenience wrapper used by hooks.lua
--- when emitting play_hand / discard / select_from_pack so each action
--- payload carries the full card detail of every interacted card.
---
--- @param cards table  Array of playing card objects.
--- @return table       Array of describe_playing_card entries.
function Capture.describe_playing_cards(cards)
    local list = {}
    if type(cards) ~= "table" then return list end
    for i = 1, #cards do
        list[i] = Capture.describe_playing_card(cards[i])
    end
    return list
end

--- Snapshot the cards currently offered inside an open booster pack along
--- with which one(s) the player picked. Used by select_from_pack so the
--- viewer can show the full offering and highlight the chosen card —
--- making it possible to ask "what did the player pass on?".
---
--- The `picked_card` argument should be the actual Balatro card object the
--- player clicked on. Each offered entry's `picked` flag is true when its id
--- matches the picked card; otherwise false.
---
--- @param picked_card table|nil  The card the player selected (may be nil).
--- @return table  Array of describe_card entries, each with `picked = bool`.
function Capture.snapshot_pack_offered(picked_card)
    local offered = {}
    local picked_id = nil
    if picked_card then
        -- For playing cards, use base.id (the card's identity).
        -- For jokers/consumables, use config.center.key.
        if looks_like_playing_card(picked_card) then
            if picked_card.base and picked_card.base.id then
                picked_id = tostring(picked_card.base.id)
            end
        elseif picked_card.config and picked_card.config.center
            and picked_card.config.center.key then
            picked_id = tostring(picked_card.config.center.key)
        end
    end

    local ok, _ = pcall(function()
        if G and G.pack_cards and G.pack_cards.cards then
            for _, card in ipairs(G.pack_cards.cards) do
                local entry = looks_like_playing_card(card)
                    and Capture.describe_playing_card(card)
                    or  Capture.describe_card(card)
                entry.picked = (picked_id ~= nil and entry.id == picked_id) or false
                offered[#offered + 1] = entry
            end
        end
    end)
    if not ok then
        log_warning("snapshot_pack_offered failed; emitting empty list")
    end
    return offered
end

--- Snapshot the player's currently-active tags. Reads `G.GAME.tags` (the
--- list of tag instances the player owns) and returns one entry per tag.
---
--- @return table  Array of { id, name, ante } entries.
function Capture.snapshot_active_tags()
    local tags = {}
    local ok, _ = pcall(function()
        if not (G and G.GAME and G.GAME.tags) then return end
        for _, tag in ipairs(G.GAME.tags) do
            local entry = { id = "tag_unknown", name = "Unknown", ante = nil }
            if tag.key then  entry.id   = tostring(tag.key)  end
            if tag.name then entry.name = tostring(tag.name) end
            if tag.ante then entry.ante = tag.ante           end
            tags[#tags + 1] = entry
        end
    end)
    if not ok then
        log_warning("snapshot_active_tags failed; emitting empty list")
    end
    return tags
end

--- Decide whether a captured card reference has been destroyed.
---
--- A card is considered destroyed when any of the following are true:
---   1. The reference is not a table (defensive: nil, string, number, …).
---   2. The card carries `removed = true` (Balatro marks destroyed cards
---      this way during deferred remove Events).
---   3. The card has lost its `base.value` (rank cleared during destruction).
---   4. The card is no longer present (by reference identity) in any of the
---      live card areas: `G.hand`, `G.deck`, `G.discard`, `G.play`.
---
--- The G-access scan is guarded with `pcall` so a transient missing area
--- can never crash a deferred callback. If the scan throws, we conservatively
--- report "not destroyed" — the post-effect descriptor will still be useful
--- to the viewer and we avoid spurious `destroyed_cards` entries.
---
--- @param ref any  The captured card reference (the table from G.hand.cards/etc.).
--- @return boolean True if the card has been destroyed, false otherwise.
function Capture.is_card_destroyed(ref)
    if type(ref) ~= "table" then return true end
    if ref.removed then return true end
    if not (ref.base and ref.base.value) then return true end

    -- Scan live card areas for an identity match. We bail out as soon as we
    -- find the ref so the worst case is one full pass through the hand/deck.
    local in_area = false
    local ok = pcall(function()
        for _, area in ipairs({ G.hand, G.deck, G.discard, G.play }) do
            if area and area.cards then
                for _, c in ipairs(area.cards) do
                    if c == ref then
                        in_area = true
                        return
                    end
                end
            end
        end
    end)
    if not ok then
        -- If G is unavailable, conservatively say not destroyed.
        return false
    end
    return not in_area
end

return Capture
