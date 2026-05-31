--- spec/golden/lib/world.lua
--- Shared test harness for golden-file scenarios.
---
--- A scenario is a Lua module that returns a function:
---     function(world) ... end
---
--- The function receives a `world` table with helpers to build a fake G,
--- highlight cards, and drive the production hooks (play_hand, discard,
--- select_blind, etc.). Each scenario calls those helpers in sequence to
--- simulate a sliver of gameplay, then the runner serializes the resulting
--- nodes and compares them to a checked-in expected JSON file.
---
--- The point is: scenarios use the *real* production code paths
--- (hooks.lua, recorder.lua, capture.lua, serializer.lua), not mocks.
--- Only G itself is faked.

local World = {}

local Capture     = assert(loadfile("lib/capture.lua"))()
local Serializer  = assert(loadfile("lib/serializer.lua"))()
local Recorder    = assert(loadfile("lib/recorder.lua"))()
local hooks       = assert(loadfile("lib/hooks.lua"))()

-- ---------------------------------------------------------------------------
-- Card factory — produces vanilla-shaped Balatro card objects.
-- ---------------------------------------------------------------------------
local function make_card(opts)
    opts = opts or {}
    return {
        base = {
            id    = opts.id    or tostring(opts.rank_id or 1),
            value = opts.rank  or "A",
            suit  = opts.suit  or "Spades",
        },
        config = {
            center = { key = opts.center_key or "c_base" },
        },
        edition = opts.edition or nil,
        seal    = opts.seal    or nil,
        ability = opts.ability or nil,
    }
end

local function make_joker(opts)
    opts = opts or {}
    return {
        config = {
            center = {
                key  = opts.id   or "j_joker",
                name = opts.name or "Joker",
            },
        },
        ability = opts.ability or { name = opts.name or "Joker" },
        edition = opts.edition or nil,
        seal    = opts.seal    or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Fake G builder — minimum viable shape for the production code.
-- ---------------------------------------------------------------------------
local function build_fake_G(spec)
    spec = spec or {}
    return {
        GAME = {
            round_resets = { ante = spec.ante or 1 },
            blind = spec.blind or {
                name   = "Small Blind",
                chips  = 100,
                config = { blind = { boss = false, key = "bl_small" } },
            },
            chips        = spec.chips        or 0,
            dollars      = spec.dollars      or 4,
            current_round = spec.current_round or { hands_left = 4, discards_left = 3 },
            pseudorandom = { seed = spec.seed or "TESTSEED" },
            vouchers     = spec.vouchers or {},
            hands        = spec.hands or {
                ["High Card"]       = { level = 1, chips =   5, mult =  1 },
                ["Pair"]            = { level = 1, chips =  10, mult =  2 },
                ["Two Pair"]        = { level = 1, chips =  20, mult =  2 },
                ["Three of a Kind"] = { level = 1, chips =  30, mult =  3 },
                ["Straight"]        = { level = 1, chips =  30, mult =  4 },
                ["Flush"]           = { level = 1, chips =  35, mult =  4 },
                ["Full House"]      = { level = 1, chips =  40, mult =  4 },
                ["Four of a Kind"]  = { level = 1, chips =  60, mult =  7 },
                ["Straight Flush"]  = { level = 1, chips = 100, mult =  8 },
                ["Five of a Kind"]  = { level = 1, chips = 120, mult = 12 },
                ["Flush House"]     = { level = 1, chips = 140, mult = 14 },
                ["Flush Five"]      = { level = 1, chips = 160, mult = 16 },
            },
            tags = spec.tags or {},
            blind_on_deck = spec.blind_on_deck or "Small",
        },
        hand        = { cards = spec.hand or {}, highlighted = {} },
        deck        = { cards = spec.deck or {} },
        discard     = { cards = spec.discard or {} },
        jokers      = { cards = spec.jokers or {} },
        consumeables = { cards = spec.consumables or {} },
        FUNCS       = {
            -- Production wrapping requires these to exist before
            -- hooks.register_all runs. The wrappers replace them with
            -- versions that call back into ours after recording.
            play_cards_from_highlighted    = function() end,
            evaluate_play                  = function() end,
            discard_cards_from_highlighted = function() end,
            select_blind                   = function() end,
            skip_blind                     = function() end,
        },
        shop_jokers   = { cards = {} },
        shop_vouchers = { cards = {} },
        shop_booster  = { cards = {} },
    }
end

-- ---------------------------------------------------------------------------
-- World: the object scenarios receive and drive.
-- ---------------------------------------------------------------------------

--- Build and install everything a scenario needs.
function World.new(spec)
    -- Capture every node the recorder appends, in order.
    local captured_nodes = {}
    local fake_writer = {
        start_run   = function(self, run_id) self.run_id = run_id end,
        append_node = function(_, node) captured_nodes[#captured_nodes + 1] = node end,
        end_run     = function(self, outcome, final_ante)
            self.outcome = outcome
            self.final_ante = final_ante
        end,
    }

    -- Reset the global G that production code reads from.
    _G.G    = build_fake_G(spec)
    _G.SMODS = _G.SMODS or {}
    _G.SMODS.last_hand = nil
    _G.Game = setmetatable({}, { __index = function() return function() end end })
    _G.Game.start_run = function() end
    _G.win_game = function() end
    _G.create_UIBox_game_over = function() end

    Capture.init({
        null_sentinel = Serializer.null,
        logger        = function() end,
    })

    local recorder = Recorder.new({
        file_writer = fake_writer,
        logger      = function() end,
    })
    recorder:start_run(spec.run_id or "GOLDEN_RUN", "tester",
                       spec.seed   or "TESTSEED",  spec.timestamp or 0,
                       spec.gamemode or "solo")

    local state = { pending_play_node = nil }

    -- Reset the hook-registry guard so this fresh _G.G + register_all
    -- actually re-wraps. Production never resets — but tests do.
    hooks._reset_wrap_registry()

    hooks.register_all({
        capture    = Capture,
        serializer = Serializer,
        logger     = { info = function() end, warning = function() end, error = function() end },
        config     = { player_id = "tester", enabled = true },
        recorder   = recorder,
        state      = state,
        mp         = { enabled = false },
        gate       = { current_gamemode = function() return "solo" end },
    })

    return setmetatable({
        _writer   = fake_writer,
        _recorder = recorder,
        _state    = state,
        _nodes    = captured_nodes,
    }, { __index = World })
end

-- ---------------------------------------------------------------------------
-- World methods (called by scenarios)
-- ---------------------------------------------------------------------------

--- Replace the hand contents.
function World:set_hand(cards) G.hand.cards = cards end

--- Highlight the given indices in the current hand.
function World:highlight(indices)
    local h = {}
    for _, i in ipairs(indices) do h[#h + 1] = G.hand.cards[i] end
    G.hand.highlighted = h
end

--- Set the hand_type that will be reported by SMODS.last_hand when play_hand
--- evaluates. Use this to simulate Balatro classifying the played hand.
function World:next_play_hand_type(hand_type)
    _G.SMODS.last_hand = { scoring_name = hand_type }
end

--- Set the hand_type returned by G.FUNCS.get_poker_hand_info on the next
--- discard (used by the discard wrapper to label the discarded cards).
function World:next_discard_hand_type(hand_type)
    G.FUNCS.get_poker_hand_info = function(_) return hand_type end
end

--- Drive a play_hand action through the production wrappers in the
--- same order Balatro itself runs them: first
--- play_cards_from_highlighted (which only stashes the pending node),
--- then evaluate_play (which is the moment SMODS.last_hand is fresh
--- and the node actually gets sent).
---
--- This mirrors the real engine's async flow: in the live game, the
--- play wrapper enqueues an event, and a few frames later the engine
--- calls evaluate_play out of the event manager. We just call them
--- back-to-back here because tests don't care about timing.
function World:play_hand()
    G.FUNCS.play_cards_from_highlighted({})
    G.FUNCS.evaluate_play({})
end

--- Drive a discard action through the production wrapper.
function World:discard()
    G.FUNCS.discard_cards_from_highlighted({})
end

--- Set the dollar/chip/etc state directly. Useful between actions to
--- simulate the engine updating state.
function World:set(field, value)
    if field == "money"             then G.GAME.dollars = value
    elseif field == "chips"         then G.GAME.chips   = value
    elseif field == "hands_left"    then G.GAME.current_round.hands_left = value
    elseif field == "discards_left" then G.GAME.current_round.discards_left = value
    elseif field == "ante"          then G.GAME.round_resets.ante = value
    elseif field == "blind"         then G.GAME.blind = value
    end
end

--- Return the captured node list. JSON-serializable.
function World:nodes() return self._nodes end

--- Return a normalized version: indices reset to 0..N-1, timestamps
--- replaced with 0, jokers/consumables/etc untouched. Snapshots stay
--- stable across runs.
function World:normalized_nodes()
    local out = {}
    for i, node in ipairs(self._nodes) do
        out[i] = World._normalize(node, i - 1)
    end
    return out
end

function World._normalize(node, expected_index)
    -- Deep-copy and strip noisy/non-deterministic fields.
    local function clone(v, depth)
        if type(v) ~= "table" then return v end
        if depth > 32 then return "<too deep>" end
        local c = {}
        for k, val in pairs(v) do c[k] = clone(val, depth + 1) end
        return c
    end
    local copy = clone(node, 0)
    copy.index = expected_index
    if copy.state then
        copy.state.timestamp = 0
        -- shop_inventory is empty for non-shop actions; leave it as-is for
        -- shop ones so changes are visible.
    end
    return copy
end

return World
