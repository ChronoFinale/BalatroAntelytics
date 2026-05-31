--- spec/discard_effect_spec.lua
---
--- Bug D — Discard-Triggered Money Predictor — exploration & unit tests
---
--- Patterned after `spec/consumable_effect_spec.lua`.
---
--- This spec is the FAILING exploration test for Bug D in
--- `.kiro/specs/capture-pipeline-fixes/bugfix.md` Requirement 2.6 and
--- detailed in `design.md` Bug D. The bug is "no `lib/discard_effect.lua`
--- module exists, so the discard hook records no money prediction" — the
--- file therefore FAILS at require time on unfixed code, with an error
--- of the shape:
---
---     module 'lib.discard_effect' not found:
---       no field package.preload['lib.discard_effect']
---       no file './lib/discard_effect.lua'
---       ...
---
--- That require failure IS the success case for this exploration test —
--- it confirms the bug exists (no module). Once `lib/discard_effect.lua`
--- ships (Bug D implementation tasks 6–10), every scenario below passes.
---
--- API under test (per `design.md` Bug D):
---
---   DiscardEffect.predict_money_delta(discarded_descriptors, jokers, current_round)
---     -> { total = N, breakdown = { { joker = "...", amount = N }, ... } }
---     or  nil  when NONE of Mail-In Rebate, Faceless Joker, or Trading Card
---              is in `jokers`
---
--- Inputs:
---   discarded_descriptors — array of `Capture.describe_playing_card`-shaped
---     entries: `id` carries the rank string ("2".."10", "J", "Q", "K", "A"
---     — same convention used in golden fixtures), and `is_face` is the
---     boolean the discard hook stamps onto each descriptor.
---   jokers — array of joker objects with `ability.name` set to the
---     human-readable joker name ("Mail-In Rebate", "Faceless Joker",
---     "Trading Card", "Pareidolia", or anything else).
---   current_round — table with `mail_card.id` (string rank for Mail-In
---     Rebate's target) and `discards_used` (count of discards already
---     consumed this round, BEFORE this discard).
---
--- Semantics (from design.md):
---   - When at least one of the three discard-money jokers is in `jokers`,
---     return `{ total, breakdown }`. `breakdown` only lists jokers that
---     actually contributed (so a held-but-untriggered Faceless yields
---     `total = 0` and an empty breakdown — distinct from `nil`).
---   - When NONE of the three are in `jokers`, return `nil` regardless of
---     other inputs ("didn't predict" rather than "predicted zero").
---
--- _Validates: Requirements 2.6, 3.7_

local DiscardEffect = require("lib.discard_effect")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local FACE_RANKS = { J = true, Q = true, K = true }

--- Build a descriptor shaped like `Capture.describe_playing_card` plus the
--- `is_face` boolean the discard hook stamps. `is_face` defaults to true
--- when rank is J/Q/K, false otherwise; pass `opts.is_face` to override
--- (e.g. simulating Pareidolia at the descriptor level — though the
--- predictor handles Pareidolia from the jokers list itself).
local function make_descriptor(rank, opts)
    opts = opts or {}
    local is_face = opts.is_face
    if is_face == nil then is_face = FACE_RANKS[rank] == true end
    return {
        id      = rank,
        rank    = rank,
        suit    = opts.suit or "Spades",
        is_face = is_face,
    }
end

local function make_joker(name)
    return { ability = { name = name } }
end

local function find_breakdown(breakdown, joker_name)
    if type(breakdown) ~= "table" then return nil end
    for _, entry in ipairs(breakdown) do
        if entry.joker == joker_name then return entry end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Unit scenarios — one per row in the design.md Bug D test strategy
-- ---------------------------------------------------------------------------

describe("DiscardEffect.predict_money_delta — unit scenarios", function()

    local default_round
    before_each(function()
        default_round = {
            mail_card     = { id = "5" },
            discards_used = 0,
        }
    end)

    it("returns nil when no relevant joker is held", function()
        local discarded = { make_descriptor("5"), make_descriptor("J") }
        local jokers = {
            make_joker("Joker"),
            make_joker("Greedy Joker"),
        }
        assert.is_nil(
            DiscardEffect.predict_money_delta(discarded, jokers, default_round)
        )
    end)

    it("Mail-In Rebate pays $5 per matching mail rank in the discard", function()
        -- mail rank "5", discarded [5H, 5C, 7D] -> two matches -> $10.
        local discarded = {
            make_descriptor("5", { suit = "Hearts" }),
            make_descriptor("5", { suit = "Clubs" }),
            make_descriptor("7", { suit = "Diamonds" }),
        }
        local jokers = { make_joker("Mail-In Rebate") }

        local result = DiscardEffect.predict_money_delta(
            discarded, jokers, default_round
        )

        assert.is_table(result)
        assert.are.equal(10, result.total)
        local entry = find_breakdown(result.breakdown, "Mail-In Rebate")
        assert.is_not_nil(entry)
        assert.are.equal(10, entry.amount)
    end)

    it("Faceless Joker pays $5 when 3 face cards are discarded together", function()
        local discarded = {
            make_descriptor("J", { suit = "Hearts" }),
            make_descriptor("Q", { suit = "Clubs" }),
            make_descriptor("K", { suit = "Diamonds" }),
        }
        local jokers = { make_joker("Faceless Joker") }

        local result = DiscardEffect.predict_money_delta(
            discarded, jokers, default_round
        )

        assert.is_table(result)
        assert.are.equal(5, result.total)
        local entry = find_breakdown(result.breakdown, "Faceless Joker")
        assert.is_not_nil(entry)
        assert.are.equal(5, entry.amount)
    end)

    it("Faceless Joker does NOT contribute with only 2 face cards", function()
        local discarded = {
            make_descriptor("J", { suit = "Hearts" }),
            make_descriptor("Q", { suit = "Clubs" }),
        }
        local jokers = { make_joker("Faceless Joker") }

        local result = DiscardEffect.predict_money_delta(
            discarded, jokers, default_round
        )

        -- Faceless IS one of the three relevant jokers, so the predictor
        -- returns the structure (not nil) — but Faceless didn't trigger,
        -- so total = 0 and breakdown does not list Faceless.
        assert.is_table(result)
        assert.are.equal(0, result.total)
        assert.is_nil(find_breakdown(result.breakdown, "Faceless Joker"))
    end)

    it("Pareidolia turns every discarded card into a face for Faceless", function()
        -- 3 non-face cards + Pareidolia in jokers => Faceless triggers $5.
        local discarded = {
            make_descriptor("2", { suit = "Hearts" }),
            make_descriptor("3", { suit = "Clubs" }),
            make_descriptor("4", { suit = "Diamonds" }),
        }
        local jokers = {
            make_joker("Faceless Joker"),
            make_joker("Pareidolia"),
        }

        local result = DiscardEffect.predict_money_delta(
            discarded, jokers, default_round
        )

        assert.is_table(result)
        assert.are.equal(5, result.total)
        local entry = find_breakdown(result.breakdown, "Faceless Joker")
        assert.is_not_nil(entry)
        assert.are.equal(5, entry.amount)
    end)

    it("Trading Card pays $3 on the first single-card discard of the round", function()
        local discarded = { make_descriptor("7", { suit = "Diamonds" }) }
        local jokers = { make_joker("Trading Card") }
        local round = { mail_card = { id = "5" }, discards_used = 0 }

        local result = DiscardEffect.predict_money_delta(discarded, jokers, round)

        assert.is_table(result)
        assert.are.equal(3, result.total)
        local entry = find_breakdown(result.breakdown, "Trading Card")
        assert.is_not_nil(entry)
        assert.are.equal(3, entry.amount)
    end)

    it("Trading Card does NOT contribute on the second discard of the round", function()
        local discarded = { make_descriptor("7", { suit = "Diamonds" }) }
        local jokers = { make_joker("Trading Card") }
        local round = { mail_card = { id = "5" }, discards_used = 1 }

        local result = DiscardEffect.predict_money_delta(discarded, jokers, round)

        -- Trading Card is one of the three relevant jokers, so the predictor
        -- returns the structure (not nil) but it did not trigger.
        assert.is_table(result)
        assert.are.equal(0, result.total)
        assert.is_nil(find_breakdown(result.breakdown, "Trading Card"))
    end)

    it("Mail-In Rebate + Faceless Joker stack on 3 mail-rank face cards", function()
        -- Mail rank "J", discarded three Jacks (all face, all match mail).
        -- Mail-In Rebate: $5 * 3 matches = $15.
        -- Faceless Joker: $5 (3 face cards).
        -- Total: $20.
        local round = { mail_card = { id = "J" }, discards_used = 0 }
        local discarded = {
            make_descriptor("J", { suit = "Hearts" }),
            make_descriptor("J", { suit = "Clubs" }),
            make_descriptor("J", { suit = "Diamonds" }),
        }
        local jokers = {
            make_joker("Mail-In Rebate"),
            make_joker("Faceless Joker"),
        }

        local result = DiscardEffect.predict_money_delta(discarded, jokers, round)

        assert.is_table(result)
        assert.are.equal(20, result.total)
        local mail = find_breakdown(result.breakdown, "Mail-In Rebate")
        local faceless = find_breakdown(result.breakdown, "Faceless Joker")
        assert.is_not_nil(mail,
            "breakdown should list Mail-In Rebate when triggered")
        assert.is_not_nil(faceless,
            "breakdown should list Faceless Joker when triggered")
        assert.are.equal(15, mail.amount)
        assert.are.equal(5,  faceless.amount)
    end)
end)

-- ---------------------------------------------------------------------------
-- Property-based test
--
-- For ANY joker set NOT containing Mail-In Rebate, Faceless Joker, or
-- Trading Card, the predictor returns nil regardless of the discarded
-- descriptors or current_round shape. This is the contract that lets the
-- discard hook decide whether to attach `expected_money_delta` at all.
-- ---------------------------------------------------------------------------

describe("DiscardEffect.predict_money_delta — property: nil for non-relevant jokers", function()

    -- Pool of jokers KNOWN not to be one of the three discard-money jokers.
    -- Pareidolia is included on purpose: by itself it must NOT make the
    -- predictor produce a structure — it only modifies Faceless's face
    -- check when Faceless is also held.
    local SAFE_JOKER_NAMES = {
        "Joker", "Greedy Joker", "Lusty Joker", "Wrathful Joker",
        "Gluttonous Joker", "Jolly Joker", "Pareidolia", "Mime",
        "Burglar", "Photograph", "Hack", "Misprint", "Banner",
        "Fibonacci", "Steel Joker", "Scary Face", "Ride the Bus",
        "Even Steven", "Odd Todd", "Splash", "Showman",
    }
    local RANKS = { "2","3","4","5","6","7","8","9","10","J","Q","K","A" }

    --- Deterministic LCG so failures replay identically.
    local function lcg(seed)
        local state = seed
        return function()
            state = (state * 1103515245 + 12345) % 2147483648
            return state
        end
    end

    it("for any random non-relevant joker set, predictor returns nil", function()
        for trial = 1, 200 do
            local rng = lcg(trial * 9973)

            -- Random discarded list, 1..5 cards, random ranks.
            local count = 1 + (rng() % 5)
            local discarded = {}
            for _ = 1, count do
                local rank = RANKS[(rng() % #RANKS) + 1]
                discarded[#discarded + 1] = make_descriptor(rank)
            end

            -- Random joker set, 0..6 jokers, all from the safe pool.
            local jokers = {}
            local joker_count = rng() % 7
            for _ = 1, joker_count do
                local name = SAFE_JOKER_NAMES[(rng() % #SAFE_JOKER_NAMES) + 1]
                jokers[#jokers + 1] = make_joker(name)
            end

            local round = {
                mail_card     = { id = RANKS[(rng() % #RANKS) + 1] },
                discards_used = rng() % 3,
            }

            local result = DiscardEffect.predict_money_delta(
                discarded, jokers, round
            )

            assert.is_nil(
                result,
                "trial " .. trial ..
                " expected nil prediction with safe-only jokers, got non-nil"
            )
        end
    end)
end)
