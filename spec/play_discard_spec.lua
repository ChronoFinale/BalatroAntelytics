--- spec/play_discard_spec.lua
--- Behavioural tests for the play_hand / discard hook layer.
---
--- Property: given any starting hand and any highlighted subset, the node
--- emitted by play_cards_from_highlighted (resp. discard_cards_from_highlighted)
--- always carries:
---   - action.type == "play_hand" / "discard"
---   - action.card_ids == ids of the highlighted cards (in order)
---   - action.cards    == one describe_playing_card entry per highlighted card,
---                        in the same order, with ids matching card_ids
---   - action.hand_type == evaluated hand name when SMODS.last_hand is set
---     (resp. action.discarded_hand_type for discard)
---   - state and index recorded by the recorder (one node per call)
---
--- Per-hand-type tests: for each of the 13 poker hand types we drive both
--- the play and discard paths and assert the action carries that exact
--- hand_type label.
---
--- The hooks talk to the global G table, so we install a fake G that owns
--- a hand, deck, jokers area, and a `highlighted` slot. The wrapped engine
--- functions are no-ops — we only care about what our wrapper records.

package.path = package.path .. ";./lib/?.lua;./Antelytics/lib/?.lua"

local Capture       = assert(loadfile("lib/capture.lua"))()
local Serializer    = assert(loadfile("lib/serializer.lua"))()
local Recorder      = assert(loadfile("lib/recorder.lua"))()
local hooks         = assert(loadfile("lib/hooks.lua"))()
local DiscardEffect = assert(loadfile("lib/discard_effect.lua"))()

-- ---------------------------------------------------------------------------
-- Fake Balatro globals
-- ---------------------------------------------------------------------------

--- Build a single card object that looks like a Balatro playing card.
local function make_card(id, rank, suit)
    return {
        base   = { id = id, value = rank, suit = suit },
        config = { center = { key = "c_base" } },
        edition = nil,
        seal = nil,
    }
end

--- Build a fake G table with a hand of the given cards, an empty deck,
--- discard pile, jokers, consumeables, and a sensible GAME state. The
--- returned table is the single source of truth — the production code
--- reads from G directly.
local function make_fake_G(hand_cards)
    return {
        GAME = {
            round_resets = { ante = 1 },
            blind        = { name = "Small Blind", chips = 100 },
            chips        = 0,
            dollars      = 4,
            current_round = { hands_left = 4, discards_left = 3 },
            pseudorandom = { seed = "TESTSEED" },
            vouchers     = {},
            hands        = {
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
            tags = {},
        },
        hand        = { cards = hand_cards, highlighted = {} },
        deck        = { cards = {} },
        discard     = { cards = {} },
        jokers      = { cards = {} },
        consumeables = { cards = {} },
        FUNCS       = {},
    }
end

-- ---------------------------------------------------------------------------
-- Test harness — installs hooks against a fresh G, runs them, captures nodes.
-- ---------------------------------------------------------------------------

--- An in-memory file_writer that records every appended node.
local function make_capturing_writer()
    return {
        nodes = {},
        start_run   = function(self, run_id) self.run_id = run_id; self.nodes = {} end,
        append_node = function(self, node)  self.nodes[#self.nodes + 1] = node end,
        end_run     = function(self) end,
    }
end

--- Build a fake `e` argument matching what the real engine passes to the
--- play / discard handlers (only ref_table is consulted, and only by
--- select_from_pack — for play/discard the wrappers ignore `e`).
local function make_e() return {} end

--- Stand up a fake game world plus the hooks, return a context table.
local function bootstrap(hand_cards)
    -- Reset the global G that the production code reads from.
    _G.G = make_fake_G(hand_cards)
    -- play_cards_from_highlighted / discard_cards_from_highlighted /
    -- evaluate_play come from G.FUNCS. The wrapper installs over the
    -- existing function, so we have to provide a no-op original.
    G.FUNCS.play_cards_from_highlighted    = function(e) end
    G.FUNCS.evaluate_play                  = function(e) end
    G.FUNCS.discard_cards_from_highlighted = function(e) end
    G.FUNCS.get_poker_hand_info            = nil  -- per-test override

    -- Stub Game so wrap_or_defer("Game", "start_run") doesn't fall through
    -- to deferred. We never call it in these tests.
    _G.Game = setmetatable({}, { __index = function() return function() end end })
    _G.Game.start_run = function() end

    _G.win_game                 = function() end
    _G.create_UIBox_game_over   = function() end

    -- SMODS namespace — production reads SMODS.last_hand.scoring_name in
    -- evaluate_play. We let each test populate it.
    _G.SMODS = _G.SMODS or {}
    _G.SMODS.last_hand = nil

    Capture.init({
        null_sentinel = Serializer.null,
        logger        = function() end,
    })

    local writer   = make_capturing_writer()
    local recorder = Recorder.new({ file_writer = writer, logger = function() end })
    recorder:start_run("RUN", "tester", "TESTSEED", 0)

    local state = { pending_play_node = nil }

    -- Reset the hook-registry guard so this fresh _G.G + register_all
    -- actually re-wraps. Production never resets — but tests do.
    hooks._reset_wrap_registry()

    hooks.register_all({
        capture        = Capture,
        serializer     = Serializer,
        logger         = { info = function() end, warning = function() end, error = function() end },
        config         = { player_id = "tester", enabled = true },
        recorder       = recorder,
        state          = state,
        mp             = { enabled = false },
        gate           = { current_gamemode = function() return "solo" end },
        discard_effect = DiscardEffect,
    })

    return {
        writer   = writer,
        recorder = recorder,
        state    = state,
    }
end

--- Highlight a subset of the hand by reference. The wrappers read
--- G.hand.highlighted directly.
local function highlight(hand_cards, indices)
    local h = {}
    for _, i in ipairs(indices) do h[#h + 1] = hand_cards[i] end
    G.hand.highlighted = h
    return h
end

-- ---------------------------------------------------------------------------
-- Property: every (hand, subset) pair lands a structurally-correct node.
-- ---------------------------------------------------------------------------

--- Build a deterministically pseudo-random hand of size n and choose a
--- random non-empty subset of indices to highlight. Driven by `seed` so
--- failures are reproducible.
local SUITS = { "Spades", "Hearts", "Diamonds", "Clubs" }
local RANKS = { "2","3","4","5","6","7","8","9","10","J","Q","K","A" }

local function rand_hand(rng, n)
    local hand = {}
    for i = 1, n do
        local rank = RANKS[(rng() % #RANKS) + 1]
        local suit = SUITS[(rng() % #SUITS) + 1]
        hand[i] = make_card("c_" .. tostring(i), rank, suit)
    end
    return hand
end

local function rand_subset(rng, n)
    local indices = {}
    for i = 1, n do
        if (rng() % 2) == 0 then indices[#indices + 1] = i end
    end
    if #indices == 0 then indices[1] = 1 end -- always pick at least one
    return indices
end

local function make_rng(seed)
    -- Simple LCG so we don't touch math.random's global state.
    local state = seed
    return function()
        state = (state * 1103515245 + 12345) % 2147483648
        return state
    end
end

describe("play_hand and discard hook invariants", function()

    it("invariant: action.card_ids and action.cards mirror G.hand.highlighted", function()
        for trial = 1, 50 do
            local rng = make_rng(trial * 7919)
            local hand_size = 3 + (rng() % 6)  -- 3..8 cards
            local hand = rand_hand(rng, hand_size)
            local indices = rand_subset(rng, hand_size)

            -- ---------------- play_hand ----------------
            -- Real-flow simulation: play_cards_from_highlighted only
            -- enqueues an event in the engine. evaluate_play runs later
            -- and is the moment SMODS.last_hand is fresh and the node
            -- gets sent. We have to drive both to mimic the engine.
            local ctx = bootstrap(hand)
            highlight(hand, indices)
            G.FUNCS.play_cards_from_highlighted(make_e())
            -- Now the engine's evaluate_play runs (asynchronously in
            -- real life). Set SMODS.last_hand the way Steamodded would,
            -- then trigger the wrapper.
            _G.SMODS.last_hand = { scoring_name = "Pair" }
            G.FUNCS.evaluate_play(make_e())

            assert.are.equal(1, #ctx.writer.nodes,
                "trial " .. trial .. ": expected exactly one play_hand node")
            local node = ctx.writer.nodes[1]
            assert.are.equal("play_hand", node.action.type)
            assert.are.equal(#indices, #node.action.card_ids,
                "trial " .. trial .. ": card_ids count mismatch")
            assert.are.equal(#indices, #node.action.cards,
                "trial " .. trial .. ": cards detail count mismatch")
            for k, i in ipairs(indices) do
                assert.are.equal("c_" .. tostring(i), node.action.card_ids[k])
                assert.are.equal("c_" .. tostring(i), node.action.cards[k].id)
                assert.are.equal(hand[i].base.value, node.action.cards[k].rank)
                assert.are.equal(hand[i].base.suit,  node.action.cards[k].suit)
            end
            assert.are.equal("Pair", node.action.hand_type)

            -- ---------------- discard ----------------
            ctx = bootstrap(hand)
            highlight(hand, indices)
            -- The wrapper calls G.FUNCS.get_poker_hand_info to label the
            -- discarded hand. Stub it to return a known label.
            G.FUNCS.get_poker_hand_info = function(_) return "High Card" end
            G.FUNCS.discard_cards_from_highlighted(make_e())

            assert.are.equal(1, #ctx.writer.nodes,
                "trial " .. trial .. ": expected exactly one discard node")
            node = ctx.writer.nodes[1]
            assert.are.equal("discard", node.action.type)
            assert.are.equal(#indices, #node.action.card_ids)
            assert.are.equal(#indices, #node.action.cards)
            for k, i in ipairs(indices) do
                assert.are.equal("c_" .. tostring(i), node.action.card_ids[k])
                assert.are.equal("c_" .. tostring(i), node.action.cards[k].id)
            end
            assert.are.equal("High Card", node.action.discarded_hand_type)
        end
    end)

    it("indices are sequential per run", function()
        local hand = { make_card("c_1", "A", "Spades"), make_card("c_2", "K", "Hearts") }
        local ctx = bootstrap(hand)
        highlight(hand, { 1 })
        G.FUNCS.play_cards_from_highlighted(make_e())
        _G.SMODS.last_hand = { scoring_name = "High Card" }
        G.FUNCS.evaluate_play(make_e())
        highlight(hand, { 2 })
        G.FUNCS.discard_cards_from_highlighted(make_e())

        assert.are.equal(0, ctx.writer.nodes[1].index)
        assert.are.equal(1, ctx.writer.nodes[2].index)
    end)

    it("regression: each play_hand records its OWN hand_type, not the previous one", function()
        -- This is the bug we hit in the wild: the original wrappers sent
        -- the play node before evaluate_play ran, so SMODS.last_hand
        -- still held the PREVIOUS hand's classification. Result was
        -- every play recorded the prior hand's type. Verified by playing
        -- a sequence of hands and checking the captured run file.
        local hand = {
            make_card("c_1", "A", "Spades"),
            make_card("c_2", "A", "Hearts"),
            make_card("c_3", "K", "Clubs"),
            make_card("c_4", "K", "Diamonds"),
        }
        local ctx = bootstrap(hand)

        -- Hand 1: play a "Flush" (whatever — engine label is mocked).
        highlight(hand, { 1, 2 })
        G.FUNCS.play_cards_from_highlighted(make_e())
        _G.SMODS.last_hand = { scoring_name = "Flush" }
        G.FUNCS.evaluate_play(make_e())

        -- Hand 2: play a "High Card". If the bug were still present,
        -- this node would record "Flush" because it would read stale
        -- SMODS.last_hand before evaluate_play updated it.
        highlight(hand, { 3 })
        G.FUNCS.play_cards_from_highlighted(make_e())
        _G.SMODS.last_hand = { scoring_name = "High Card" }
        G.FUNCS.evaluate_play(make_e())

        assert.are.equal(2, #ctx.writer.nodes)
        assert.are.equal("Flush",     ctx.writer.nodes[1].action.hand_type)
        assert.are.equal("High Card", ctx.writer.nodes[2].action.hand_type,
            "second play must record its own hand_type, not the previous play's")
    end)

    it("regression: very first play_hand of a run records its hand_type, not nil", function()
        -- Companion to the above. The bug manifested as nil on the
        -- first play (no previous SMODS.last_hand to leak), then the
        -- previous classification on every subsequent play.
        local hand = {
            make_card("c_1", "5", "Hearts"),
            make_card("c_2", "5", "Clubs"),
        }
        local ctx = bootstrap(hand)
        highlight(hand, { 1, 2 })
        G.FUNCS.play_cards_from_highlighted(make_e())
        _G.SMODS.last_hand = { scoring_name = "Pair" }
        G.FUNCS.evaluate_play(make_e())

        assert.are.equal(1, #ctx.writer.nodes)
        assert.are.equal("Pair", ctx.writer.nodes[1].action.hand_type,
            "first play of run must record its hand_type, not nil")
    end)
end)

-- ---------------------------------------------------------------------------
-- Per-hand-type tests: every poker hand label round-trips through both
-- the play_hand path (via SMODS.last_hand.scoring_name) and the discard
-- path (via G.FUNCS.get_poker_hand_info).
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

describe("hand-type labelling", function()
    for _, hand_type in ipairs(POKER_HAND_TYPES) do
        it("play_hand stamps action.hand_type = '" .. hand_type .. "'", function()
            local hand = {
                make_card("c_1", "A", "Spades"),
                make_card("c_2", "A", "Hearts"),
            }
            local ctx = bootstrap(hand)
            highlight(hand, { 1, 2 })
            G.FUNCS.play_cards_from_highlighted(make_e())
            -- evaluate_play runs (asynchronously in real Balatro). At
            -- that point Steamodded has populated SMODS.last_hand. We
            -- simulate that by setting it just before triggering the
            -- evaluate_play wrapper.
            _G.SMODS.last_hand = { scoring_name = hand_type }
            G.FUNCS.evaluate_play(make_e())

            assert.are.equal(1, #ctx.writer.nodes)
            assert.are.equal("play_hand", ctx.writer.nodes[1].action.type)
            assert.are.equal(hand_type, ctx.writer.nodes[1].action.hand_type)
        end)

        it("discard stamps action.discarded_hand_type = '" .. hand_type .. "'", function()
            local hand = {
                make_card("c_1", "A", "Spades"),
                make_card("c_2", "K", "Hearts"),
            }
            local ctx = bootstrap(hand)
            highlight(hand, { 1, 2 })
            G.FUNCS.get_poker_hand_info = function(_) return hand_type end
            G.FUNCS.discard_cards_from_highlighted(make_e())

            assert.are.equal(1, #ctx.writer.nodes)
            assert.are.equal("discard", ctx.writer.nodes[1].action.type)
            assert.are.equal(hand_type, ctx.writer.nodes[1].action.discarded_hand_type)
        end)
    end
end)

-- ---------------------------------------------------------------------------
-- Predictor money fields on the discard action.
--
-- The discard hook calls DiscardEffect.predict_money_delta and, when it
-- returns a structure, attaches `expected_money_delta` and
-- `money_breakdown` to the emitted action. When no relevant joker is
-- held the predictor returns nil and the hook leaves both fields off
-- the action entirely.
-- ---------------------------------------------------------------------------

local function make_joker(name)
    return { ability = { name = name } }
end

--- Locate the breakdown entry contributed by the named joker, or nil.
local function find_breakdown_entry(breakdown, joker_name)
    if type(breakdown) ~= "table" then return nil end
    for _, entry in ipairs(breakdown) do
        if entry.joker == joker_name then return entry end
    end
    return nil
end

describe("discard predictor fields on the action", function()

    it("Mail-In Rebate stamps expected_money_delta and money_breakdown", function()
        -- Discarding two 5s with mail rank "5" → Mail-In Rebate pays $10.
        -- A non-matching 7 sits alongside to confirm only matches count.
        --
        -- The predictor compares descriptor.id (which build_card_entry
        -- copies from card.base.id) to current_round.mail_card.id, so the
        -- test cards' base.id is the rank string for these scenarios.
        local hand = {
            make_card("5", "5", "Hearts"),
            make_card("5", "5", "Spades"),
            make_card("7", "7", "Diamonds"),
        }
        local ctx = bootstrap(hand)
        G.jokers.cards = { make_joker("Mail-In Rebate") }
        G.GAME.current_round.mail_card     = { id = "5" }
        G.GAME.current_round.discards_used = 0

        highlight(hand, { 1, 2, 3 })
        G.FUNCS.get_poker_hand_info = function(_) return "High Card" end
        G.FUNCS.discard_cards_from_highlighted(make_e())

        assert.are.equal(1, #ctx.writer.nodes)
        local action = ctx.writer.nodes[1].action
        assert.are.equal("discard", action.type)
        assert.are.equal(10, action.expected_money_delta)
        local entry = find_breakdown_entry(action.money_breakdown, "Mail-In Rebate")
        assert.is_not_nil(entry, "money_breakdown should list Mail-In Rebate")
        assert.are.equal(10, entry.amount)
    end)

    it("Faceless Joker stamps expected_money_delta = 5 on a 3-face discard", function()
        local hand = {
            make_card("J", "J", "Hearts"),
            make_card("Q", "Q", "Clubs"),
            make_card("K", "K", "Diamonds"),
        }
        local ctx = bootstrap(hand)
        G.jokers.cards = { make_joker("Faceless Joker") }
        G.GAME.current_round.mail_card     = { id = "2" }  -- doesn't matter
        G.GAME.current_round.discards_used = 0

        highlight(hand, { 1, 2, 3 })
        G.FUNCS.get_poker_hand_info = function(_) return "High Card" end
        G.FUNCS.discard_cards_from_highlighted(make_e())

        assert.are.equal(1, #ctx.writer.nodes)
        local action = ctx.writer.nodes[1].action
        assert.are.equal(5, action.expected_money_delta)
        local entry = find_breakdown_entry(action.money_breakdown, "Faceless Joker")
        assert.is_not_nil(entry, "money_breakdown should list Faceless Joker")
        assert.are.equal(5, entry.amount)
    end)

    it("Trading Card stamps expected_money_delta = 3 on the first single-card discard", function()
        local hand = {
            make_card("7", "7", "Diamonds"),
            make_card("9", "9", "Spades"),
        }
        local ctx = bootstrap(hand)
        G.jokers.cards = { make_joker("Trading Card") }
        G.GAME.current_round.mail_card     = { id = "2" }  -- doesn't matter
        G.GAME.current_round.discards_used = 0

        highlight(hand, { 1 })
        G.FUNCS.get_poker_hand_info = function(_) return "High Card" end
        G.FUNCS.discard_cards_from_highlighted(make_e())

        assert.are.equal(1, #ctx.writer.nodes)
        local action = ctx.writer.nodes[1].action
        assert.are.equal(3, action.expected_money_delta)
        local entry = find_breakdown_entry(action.money_breakdown, "Trading Card")
        assert.is_not_nil(entry, "money_breakdown should list Trading Card")
        assert.are.equal(3, entry.amount)
    end)

    it("control: no relevant joker means neither field is attached to the action", function()
        local hand = {
            make_card("5", "5", "Hearts"),
            make_card("J", "J", "Clubs"),
        }
        local ctx = bootstrap(hand)
        -- "Joker" is the base +4 Mult joker — not one of the three
        -- discard-money jokers the predictor cares about. The predictor
        -- returns nil and the hook leaves both fields absent.
        G.jokers.cards = { make_joker("Joker") }
        G.GAME.current_round.mail_card     = { id = "5" }
        G.GAME.current_round.discards_used = 0

        highlight(hand, { 1, 2 })
        G.FUNCS.get_poker_hand_info = function(_) return "High Card" end
        G.FUNCS.discard_cards_from_highlighted(make_e())

        assert.are.equal(1, #ctx.writer.nodes)
        local action = ctx.writer.nodes[1].action
        assert.are.equal("discard", action.type)
        assert.is_nil(action.expected_money_delta,
            "control discard must not carry expected_money_delta")
        assert.is_nil(action.money_breakdown,
            "control discard must not carry money_breakdown")
    end)
end)
