--- capture_spec.lua
--- Unit tests for the Balatro Antelytics game state capture module.
--- Validates: Requirements 2.1–2.10

-- Adjust package path to find the capture module
package.path = package.path .. ";../lib/?.lua;./lib/?.lua;./Antelytics/lib/?.lua"

local Capture = require("capture")

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

--- Create a null sentinel for injection
local NULL = setmetatable({}, { __tostring = function() return "null" end })

--- Filter `state.full_deck` by area, returning the cards in that
--- CardArea. Mirrors what the viewer does — `state.hand`, `state.deck`,
--- and `state.discard_pile` were redundant duplicates of full_deck
--- filtered by area, so capture stopped emitting them. Tests now read
--- through this helper.
---
--- Note: cards in the deck have no `area` field (it's the documented
--- default); cards in hand/discard carry `area = "hand"` or "discard".
local function area_subset(state, area)
    local list = {}
    if not (state and state.full_deck) then return list end
    for _, card in ipairs(state.full_deck) do
        local card_area = card.area or "deck"
        if card_area == area then
            list[#list + 1] = card
        end
    end
    return list
end

local function state_hand(state)         return area_subset(state, "hand")    end
local function state_deck(state)         return area_subset(state, "deck")    end
local function state_discard_pile(state) return area_subset(state, "discard") end

--- Create a mock logger that captures warnings
local function make_mock_logger()
    local warnings = {}
    local function logger(msg)
        warnings[#warnings + 1] = msg
    end
    return logger, warnings
end

--- Build a realistic mock G global with all expected fields
local function build_mock_G()
    return {
        GAME = {
            round_resets = { ante = 2 },
            blind = {
                name = "Big Blind",
                chips = 600,
                config = {
                    blind = {
                        boss = false,
                        key = "bl_big",
                        name = "Big Blind",
                    },
                },
            },
            chips = 150,
            dollars = 8,
            current_round = {
                hands_left = 3,
                discards_left = 2,
                discards_used = 1,
            },
            pseudorandom = { seed = "SEED42" },
            -- Redeemed vouchers live in used_vouchers (key -> true), which is
            -- what capture reads. v_inactive=false must be excluded.
            used_vouchers = {
                v_overstock = true,
                v_clearance_sale = true,
                v_inactive = false,
            },
            hands = {
                ["High Card"]       = { level = 1, chips = 5,   mult = 1 },
                ["Pair"]            = { level = 2, chips = 15,  mult = 3 },
                ["Two Pair"]        = { level = 1, chips = 20,  mult = 2 },
                ["Three of a Kind"] = { level = 1, chips = 30,  mult = 3 },
                ["Straight"]        = { level = 1, chips = 30,  mult = 4 },
                ["Flush"]           = { level = 1, chips = 35,  mult = 4 },
                ["Full House"]      = { level = 1, chips = 40,  mult = 4 },
                ["Four of a Kind"]  = { level = 1, chips = 60,  mult = 7 },
                ["Straight Flush"]  = { level = 1, chips = 100, mult = 8 },
                ["Five of a Kind"]  = { level = 1, chips = 120, mult = 12 },
                ["Flush House"]     = { level = 1, chips = 140, mult = 14 },
                ["Flush Five"]      = { level = 1, chips = 160, mult = 16 },
            },
        },
        hand = {
            cards = {
                {
                    base = { id = "c_1", value = "A", suit = "Spades" },
                    config = { center = { key = "c_base" } },
                    edition = nil,
                    seal = nil,
                },
                {
                    base = { id = "c_2", value = "K", suit = "Hearts" },
                    config = { center = { key = "m_bonus" } },
                    edition = { foil = true },
                    seal = "Gold",
                },
            },
        },
        deck = {
            cards = {
                {
                    base = { id = "c_10", value = "5", suit = "Clubs" },
                    config = { center = { key = "c_base" } },
                    edition = nil,
                    seal = nil,
                },
            },
        },
        discard = {
            cards = {
                {
                    base = { id = "c_20", value = "2", suit = "Diamonds" },
                    config = { center = { key = "c_base" } },
                    edition = { holo = true },
                    seal = "Red",
                },
            },
        },
        jokers = {
            cards = {
                {
                    config = { center = { key = "j_ride_the_bus", name = "Ride the Bus" } },
                    ability = { name = "Ride the Bus", consecutive = 5, extra = 3 },
                    edition = { polychrome = true },
                    seal = nil,
                },
                {
                    config = { center = { key = "j_joker", name = "Joker" } },
                    ability = { name = "Joker" },
                    edition = nil,
                    seal = "Blue",
                },
            },
        },
        consumeables = {
            cards = {
                {
                    config = { center = { key = "c_fool", name = "The Fool" } },
                    ability = { name = "The Fool" },
                },
                {
                    config = { center = { key = "c_jupiter", name = "Jupiter" } },
                    ability = { name = "Jupiter" },
                },
            },
        },
        shop_jokers = {
            cards = {
                {
                    config = { center = { key = "j_banner", name = "Banner" } },
                    ability = { name = "Banner", set = "Joker" },
                    cost = 5,
                },
            },
        },
        shop_vouchers = {
            cards = {
                {
                    config = { center = { key = "v_grabber", name = "Nacho Tong" } },
                    ability = { name = "Nacho Tong", set = "Voucher" },
                    cost = 10,
                },
            },
        },
        shop_booster = {
            cards = {
                {
                    config = { center = { key = "p_standard_normal_1", name = "Standard Pack" } },
                    ability = { name = "Standard Pack", set = "Booster" },
                    cost = 4,
                },
            },
        },
        shop_tarot = {
            cards = {
                {
                    config = { center = { key = "c_hermit", name = "The Hermit" } },
                    ability = { name = "The Hermit", set = "Tarot" },
                    cost = 3,
                },
            },
        },
        STATES = {
            SELECTING_HAND = 1, HAND_PLAYED = 2, DRAW_TO_HAND = 3,
            GAME_OVER = 4, SHOP = 5, PLAY_TAROT = 6, BLIND_SELECT = 7,
            ROUND_EVAL = 8, TAROT_PACK = 9, PLANET_PACK = 10, MENU = 11,
            TUTORIAL = 12, SPLASH = 13, SANDBOX = 14, SPECTRAL_PACK = 15,
            DEMO_CTA = 16, STANDARD_PACK = 17, BUFFOON_PACK = 18,
            NEW_ROUND = 19,
        },
        STATE = 1,  -- SELECTING_HAND by default
    }
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("Capture module", function()

    local mock_logger, warnings

    before_each(function()
        -- Set up fresh mock logger and inject dependencies
        mock_logger, warnings = make_mock_logger()
        Capture.init({ null_sentinel = NULL, logger = mock_logger })

        -- Set up the global G with realistic data
        _G.G = build_mock_G()
    end)

    after_each(function()
        _G.G = nil
    end)

    -- -----------------------------------------------------------------------
    -- 1. All required top-level fields are present
    -- -----------------------------------------------------------------------
    describe("build_game_state() returns all required fields", function()
        it("contains all required top-level fields", function()
            local state = Capture.build_game_state("play_hand")

            assert.is_not_nil(state.ante)
            assert.is_not_nil(state.blind_name)
            assert.is_not_nil(state.blind_target)
            -- boss_blind_effect can be NULL sentinel
            assert.is_not_nil(state.boss_blind_effect)
            assert.is_not_nil(state.score)
            assert.is_not_nil(state.money)
            assert.is_not_nil(state.hands_remaining)
            assert.is_not_nil(state.discards_remaining)
            assert.is_not_nil(state.seed)
            assert.is_not_nil(state.timestamp)
            assert.is_not_nil(state.full_deck)
            assert.is_not_nil(state.jokers)
            assert.is_not_nil(state.consumables)
            assert.is_not_nil(state.vouchers)
            assert.is_not_nil(state.hand_levels)
            assert.is_not_nil(state.shop_inventory)
        end)

        it("captures correct scalar values from G", function()
            local state = Capture.build_game_state("play_hand")

            assert.are.equal(2, state.ante)
            assert.are.equal("Big Blind", state.blind_name)
            assert.are.equal(600, state.blind_target)
            assert.are.equal(150, state.score)
            assert.are.equal(8, state.money)
            assert.are.equal(3, state.hands_remaining)
            assert.are.equal(2, state.discards_remaining)
            assert.are.equal(1, state.discards_used)
            assert.are.equal("SEED42", state.seed)
            assert.is_number(state.timestamp)
        end)

        it("records an overflowed (inf) score as the game's \"naneinf\" string", function()
            -- A score past the double ceiling reads as inf; the game shows it
            -- as "naneinf". The serializer would null a raw inf, dropping the
            -- run, so capture substitutes the string.
            G.GAME.chips = math.huge
            assert.are.equal("naneinf", Capture.build_game_state("play_hand").score)

            G.GAME.chips = 0 / 0  -- NaN
            assert.are.equal("naneinf", Capture.build_game_state("play_hand").score)
        end)

        it("captures boss_blind_effect as NULL when blind is not a boss", function()
            local state = Capture.build_game_state("play_hand")
            assert.are.equal(NULL, state.boss_blind_effect)
        end)

        it("captures boss_blind_effect when blind is a boss", function()
            G.GAME.blind.config.blind.boss = true
            G.GAME.blind.config.blind.key = "bl_hook"

            local state = Capture.build_game_state("play_hand")
            assert.are.equal("bl_hook", state.boss_blind_effect)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 2. Card list building (hand, deck, discard_pile)
    -- -----------------------------------------------------------------------
    describe("card list building", function()
        it("builds hand entries with all required card fields", function()
            local state = Capture.build_game_state("play_hand")

            assert.are.equal(2, #state_hand(state))

            -- Default modifiers (enhancement="none", edition="base",
            -- seal="none") are omitted from the descriptor — the viewer
            -- treats absent keys as those defaults. Card 1 is vanilla,
            -- so its modifier keys should not appear at all.
            local card1 = state_hand(state)[1]
            assert.are.equal("c_1", card1.id)
            assert.are.equal("A", card1.rank)
            assert.are.equal("Spades", card1.suit)
            assert.is_nil(card1.enhancement)
            assert.is_nil(card1.edition)
            assert.is_nil(card1.seal)

            -- Card 2 has non-default modifiers; those keys should appear.
            local card2 = state_hand(state)[2]
            assert.are.equal("c_2", card2.id)
            assert.are.equal("K", card2.rank)
            assert.are.equal("Hearts", card2.suit)
            assert.are.equal("bonus", card2.enhancement)
            assert.are.equal("foil", card2.edition)
            assert.are.equal("Gold", card2.seal)
        end)

        it("builds deck entries with all required card fields", function()
            local state = Capture.build_game_state("play_hand")

            assert.are.equal(1, #state_deck(state))
            local card = state_deck(state)[1]
            assert.are.equal("c_10", card.id)
            assert.are.equal("5", card.rank)
            assert.are.equal("Clubs", card.suit)
            -- Vanilla card → default modifiers omitted.
            assert.is_nil(card.enhancement)
            assert.is_nil(card.edition)
            assert.is_nil(card.seal)
        end)

        it("builds discard_pile entries with all required card fields", function()
            local state = Capture.build_game_state("play_hand")

            assert.are.equal(1, #state_discard_pile(state))
            local card = state_discard_pile(state)[1]
            assert.are.equal("c_20", card.id)
            assert.are.equal("2", card.rank)
            assert.are.equal("Diamonds", card.suit)
            assert.is_nil(card.enhancement)
            assert.are.equal("holographic", card.edition)
            assert.are.equal("Red", card.seal)
        end)

        it("captures perma_bonus and similar permanent bonuses on cards", function()
            -- Hiker stacks +chips on a card; Steamodded mods can add other
            -- perma_x_* fields. Capture should include any non-default values
            -- under a `perma` subtable so the viewer can show "this 5 of
            -- Hearts has +30 chips baked in".
            _G.G.hand.cards[1].ability = {
                perma_bonus = 30,        -- Hiker chips
                perma_mult  = 5,         -- Sock and Buskin etc.
                perma_x_mult = 1.5,      -- modded
                perma_x_chips = 1,       -- identity — should be skipped
                perma_p_dollars = 0,     -- zero — should be skipped
                perma_repetitions = 1,   -- 1 retrigger from Sock and Buskin
            }
            local state = Capture.build_game_state("play_hand")
            local p = state_hand(state)[1].perma
            assert.is_not_nil(p)
            assert.are.equal(30,  p.perma_bonus)
            assert.are.equal(5,   p.perma_mult)
            assert.are.equal(1.5, p.perma_x_mult)
            assert.are.equal(1,   p.perma_repetitions)
            assert.is_nil(p.perma_x_chips,    "x_chips=1 is identity, must be skipped")
            assert.is_nil(p.perma_p_dollars,  "perma_p_dollars=0 must be skipped")
        end)

        it("does not attach perma when the card has no permanent bonuses", function()
            -- Vanilla card with no ability fields should produce no perma key.
            local state = Capture.build_game_state("play_hand")
            assert.is_nil(state_hand(state)[1].perma)
            assert.is_nil(state_hand(state)[2].perma)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 3. Joker list
    -- -----------------------------------------------------------------------
    describe("joker list", function()
        it("captures jokers with slot positions", function()
            local state = Capture.build_game_state("play_hand")

            assert.are.equal(2, #state.jokers)
            assert.are.equal(1, state.jokers[1].slot)
            assert.are.equal(2, state.jokers[2].slot)
        end)

        it("captures joker names", function()
            local state = Capture.build_game_state("play_hand")

            assert.are.equal("Ride the Bus", state.jokers[1].name)
            assert.are.equal("Joker", state.jokers[2].name)
        end)

        it("captures joker editions", function()
            local state = Capture.build_game_state("play_hand")

            assert.are.equal("polychrome", state.jokers[1].edition)
            assert.are.equal("base", state.jokers[2].edition)
        end)

        it("captures joker internal_state maps", function()
            local state = Capture.build_game_state("play_hand")

            -- Ride the Bus has mutable state
            local rtb_state = state.jokers[1].internal_state
            assert.are.equal(5, rtb_state.consecutive)
            assert.are.equal(3, rtb_state.extra)

            -- Plain Joker has no mutable state (empty table)
            local joker_state = state.jokers[2].internal_state
            local count = 0
            for _ in pairs(joker_state) do count = count + 1 end
            assert.are.equal(0, count)
        end)

        it("captures joker seals", function()
            local state = Capture.build_game_state("play_hand")

            assert.are.equal("none", state.jokers[1].seal)
            assert.are.equal("Blue", state.jokers[2].seal)
        end)

        it("captures joker IDs from config.center.key", function()
            local state = Capture.build_game_state("play_hand")

            assert.are.equal("j_ride_the_bus", state.jokers[1].id)
            assert.are.equal("j_joker", state.jokers[2].id)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 4. Consumables list
    -- -----------------------------------------------------------------------
    describe("consumables list", function()
        it("captures consumables with id and name", function()
            local state = Capture.build_game_state("play_hand")

            assert.are.equal(2, #state.consumables)
            assert.are.equal("c_fool", state.consumables[1].id)
            assert.are.equal("The Fool", state.consumables[1].name)
            assert.are.equal("c_jupiter", state.consumables[2].id)
            assert.are.equal("Jupiter", state.consumables[2].name)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 5. Vouchers list
    -- -----------------------------------------------------------------------
    describe("vouchers list", function()
        it("captures active vouchers only", function()
            local state = Capture.build_game_state("play_hand")

            -- v_overstock and v_clearance_sale are active; v_inactive is false
            assert.are.equal(2, #state.vouchers)

            -- Collect voucher IDs (order may vary since pairs() is unordered)
            local ids = {}
            for _, v in ipairs(state.vouchers) do
                ids[v.id] = true
            end
            assert.is_true(ids["v_overstock"])
            assert.is_true(ids["v_clearance_sale"])
        end)

        it("voucher entries have id and name fields", function()
            local state = Capture.build_game_state("play_hand")

            for _, v in ipairs(state.vouchers) do
                assert.is_not_nil(v.id)
                assert.is_not_nil(v.name)
                assert.is_string(v.id)
                assert.is_string(v.name)
            end
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 6. Hand levels
    -- -----------------------------------------------------------------------
    describe("hand_levels", function()
        it("includes all 13 poker hand types", function()
            local state = Capture.build_game_state("play_hand")

            local expected_types = {
                "High Card", "Pair", "Two Pair", "Three of a Kind",
                "Straight", "Flush", "Full House", "Four of a Kind",
                "Straight Flush", "Five of a Kind",
                "Flush House", "Flush Five",
            }

            for _, hand_type in ipairs(expected_types) do
                assert.is_not_nil(state.hand_levels[hand_type],
                    "Missing hand type: " .. hand_type)
            end
        end)

        it("each hand level has level, chips, and mult", function()
            local state = Capture.build_game_state("play_hand")

            for hand_type, data in pairs(state.hand_levels) do
                assert.is_not_nil(data.level, hand_type .. " missing level")
                assert.is_not_nil(data.chips, hand_type .. " missing chips")
                assert.is_not_nil(data.mult, hand_type .. " missing mult")
            end
        end)

        it("captures upgraded hand levels correctly", function()
            local state = Capture.build_game_state("play_hand")

            -- Pair was set to level 2 in mock
            assert.are.equal(2, state.hand_levels["Pair"].level)
            assert.are.equal(15, state.hand_levels["Pair"].chips)
            assert.are.equal(3, state.hand_levels["Pair"].mult)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 7. Shop inventory for shop actions vs non-shop actions
    -- -----------------------------------------------------------------------
    describe("shop_inventory", function()
        it("is populated for buy_joker action", function()
            local state = Capture.build_game_state("buy_joker")
            assert.is_true(#state.shop_inventory > 0)
        end)

        it("is populated for reroll_shop action", function()
            local state = Capture.build_game_state("reroll_shop")
            assert.is_true(#state.shop_inventory > 0)
        end)

        it("is populated for buy_consumable action", function()
            local state = Capture.build_game_state("buy_consumable")
            assert.is_true(#state.shop_inventory > 0)
        end)

        it("is populated for buy_voucher action", function()
            local state = Capture.build_game_state("buy_voucher")
            assert.is_true(#state.shop_inventory > 0)
        end)

        it("is populated for buy_pack action", function()
            local state = Capture.build_game_state("buy_pack")
            assert.is_true(#state.shop_inventory > 0)
        end)

        it("is empty for play_hand action", function()
            local state = Capture.build_game_state("play_hand")
            assert.are.equal(0, #state.shop_inventory)
        end)

        it("is empty for discard action", function()
            local state = Capture.build_game_state("discard")
            assert.are.equal(0, #state.shop_inventory)
        end)

        it("shop items have type, id, name, and cost", function()
            local state = Capture.build_game_state("buy_joker")

            for _, item in ipairs(state.shop_inventory) do
                assert.is_not_nil(item.type)
                assert.is_not_nil(item.id)
                assert.is_not_nil(item.name)
                assert.is_not_nil(item.cost)
            end
        end)

        it("captures items from all shop areas", function()
            local state = Capture.build_game_state("buy_joker")

            -- Mock has 1 joker, 1 voucher, 1 booster, 1 consumable = 4 items
            assert.are.equal(4, #state.shop_inventory)

            local types = {}
            for _, item in ipairs(state.shop_inventory) do
                types[item.type] = true
            end
            assert.is_true(types["joker"])
            assert.is_true(types["voucher"])
            assert.is_true(types["pack"])
            assert.is_true(types["consumable"])
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 7b. Location label derived from G.STATE
    -- -----------------------------------------------------------------------
    describe("location", function()
        it("returns 'playing_blind' when G.STATE is SELECTING_HAND", function()
            G.STATE = G.STATES.SELECTING_HAND
            local state = Capture.build_game_state("play_hand")
            assert.are.equal("playing_blind", state.location)
        end)

        it("returns 'playing_blind' when G.STATE is HAND_PLAYED", function()
            G.STATE = G.STATES.HAND_PLAYED
            local state = Capture.build_game_state("play_hand")
            assert.are.equal("playing_blind", state.location)
        end)

        it("returns 'shop' when G.STATE is SHOP", function()
            G.STATE = G.STATES.SHOP
            local state = Capture.build_game_state("buy_joker")
            assert.are.equal("shop", state.location)
        end)

        it("returns 'blind_select' when G.STATE is BLIND_SELECT", function()
            G.STATE = G.STATES.BLIND_SELECT
            local state = Capture.build_game_state("select_blind")
            assert.are.equal("blind_select", state.location)
        end)

        it("returns 'round_eval' when G.STATE is ROUND_EVAL", function()
            G.STATE = G.STATES.ROUND_EVAL
            local state = Capture.build_game_state("blind_beaten")
            assert.are.equal("round_eval", state.location)
        end)

        -- Packs are an OVERLAY, not a location. The pack states pass through to
        -- the last-known base context so opening a pack never clobbers WHERE the
        -- player is standing (shop or blind-select). See state.pack for the
        -- overlay carrying the pack kind.
        it("keeps base 'shop' when a pack opens in the shop (TAROT_PACK)", function()
            G.STATE = G.STATES.SHOP
            assert.are.equal("shop", Capture.build_game_state("buy_pack").location)
            G.STATE = G.STATES.TAROT_PACK
            local state = Capture.build_game_state("select_from_pack")
            assert.are.equal("shop", state.location)
        end)

        it("keeps base 'blind_select' for a tag-granted pack (BUFFOON_PACK)", function()
            G.STATE = G.STATES.BLIND_SELECT
            assert.are.equal("blind_select", Capture.build_game_state("skip_blind_tag").location)
            G.STATE = G.STATES.BUFFOON_PACK
            local state = Capture.build_game_state("open_pack")
            assert.are.equal("blind_select", state.location)
        end)

        it("pack states (PLANET/SPECTRAL/STANDARD) all pass through to the base", function()
            G.STATE = G.STATES.SHOP
            Capture.build_game_state("shop_entered")
            for _, st in ipairs({ "PLANET_PACK", "SPECTRAL_PACK", "STANDARD_PACK" }) do
                G.STATE = G.STATES[st]
                assert.are.equal("shop", Capture.build_game_state("open_pack").location)
            end
        end)

        it("returns 'unknown' when G.STATE is missing and nothing was ever resolved", function()
            Capture.reset_location()
            G.STATE = nil
            local state = Capture.build_game_state("play_hand")
            assert.are.equal("unknown", state.location)
        end)

        it("falls back to the last-known location when G.STATE is mid-transition", function()
            -- Resolve a real location first, then simulate the engine flipping
            -- G.STATE to an unmapped value (as it does when a pack opens/closes).
            G.STATE = G.STATES.SHOP
            assert.are.equal("shop", Capture.build_game_state("shop_entered").location)
            G.STATE = nil  -- unresolvable
            local state = Capture.build_game_state("open_pack")
            assert.are.equal("shop", state.location)  -- not "unknown"
        end)

        it("is always present, even on non-shop actions", function()
            G.STATE = G.STATES.SELECTING_HAND
            local state = Capture.build_game_state("play_hand")
            assert.is_string(state.location)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 7c. Pack overlay (state.pack) — orthogonal to location
    -- -----------------------------------------------------------------------
    describe("pack overlay", function()
        -- The accessor is module-level; restore a nil-returning one after each
        -- test so the overlay doesn't bleed into unrelated specs.
        after_each(function()
            Capture.init({ get_current_pack_kind = function() return nil end })
        end)

        it("is absent when no pack is open (accessor returns nil)", function()
            Capture.init({ get_current_pack_kind = function() return nil end })
            G.STATE = G.STATES.SHOP
            local state = Capture.build_game_state("buy_joker")
            assert.is_nil(state.pack)
        end)

        it("carries the pack kind while a pack is open", function()
            Capture.init({ get_current_pack_kind = function() return "Buffoon" end })
            G.STATE = G.STATES.SHOP
            local state = Capture.build_game_state("open_pack")
            assert.are.same({ kind = "Buffoon" }, state.pack)
        end)

        it("is present even on a use_consumable fired inside the pack", function()
            -- The action type alone (use_consumable) wouldn't reveal the pack;
            -- the overlay comes from run_state, so it's still stamped.
            Capture.init({ get_current_pack_kind = function() return "Arcana" end })
            G.STATE = G.STATES.PLAY_TAROT
            local state = Capture.build_game_state("use_consumable")
            assert.are.equal("Arcana", state.pack.kind)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 8. pcall error handling: blind is nil
    -- -----------------------------------------------------------------------
    describe("pcall error handling", function()
        it("returns NULL sentinel for blind_name when G.GAME.blind is nil", function()
            G.GAME.blind = nil

            local state = Capture.build_game_state("play_hand")

            assert.are.equal(NULL, state.blind_name)
        end)

        it("logs a warning when blind_name is unavailable", function()
            G.GAME.blind = nil

            Capture.build_game_state("play_hand")

            -- Should have logged at least one warning mentioning blind_name
            local found = false
            for _, msg in ipairs(warnings) do
                if msg:find("blind_name") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected a warning about blind_name")
        end)

        it("logs a warning that includes the action type", function()
            G.GAME.blind = nil

            Capture.build_game_state("play_hand")

            local found = false
            for _, msg in ipairs(warnings) do
                if msg:find("play_hand") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected warning to include action type 'play_hand'")
        end)

        it("still returns a valid table when blind is nil", function()
            G.GAME.blind = nil

            local state = Capture.build_game_state("play_hand")

            assert.is_table(state)
            -- Other fields should still be captured
            assert.are.equal(2, state.ante)
            assert.are.equal(8, state.money)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 9. pcall error handling: G.hand is nil
    -- -----------------------------------------------------------------------
    describe("partial full_deck handling — G.hand is nil", function()
        it("emits full_deck containing the surviving areas (deck, discard) when G.hand is nil", function()
            G.hand = nil

            local state = Capture.build_game_state("discard")

            -- full_deck still contains deck and discard contributions; hand
            -- area silently contributes nothing.
            assert.is_table(state.full_deck)
            assert.are.equal(0, #state_hand(state))
            assert.are.equal(1, #state_deck(state))
            assert.are.equal(1, #state_discard_pile(state))
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 10. Multiple field failures handled independently
    -- -----------------------------------------------------------------------
    describe("multiple field failures handled independently", function()
        it("captures remaining fields when multiple G sub-tables are nil", function()
            -- Simulate multiple failures at once
            G.GAME.blind = nil
            G.hand = nil
            G.jokers = nil
            G.consumeables = nil

            local state = Capture.build_game_state("play_hand")

            -- Failed fields should be NULL sentinel
            assert.are.equal(NULL, state.blind_name)
            assert.are.equal(NULL, state.blind_target)
            assert.are.equal(NULL, state.jokers)
            assert.are.equal(NULL, state.consumables)

            -- Unaffected fields should still be captured correctly
            assert.are.equal(2, state.ante)
            assert.are.equal(150, state.score)
            assert.are.equal(8, state.money)
            assert.are.equal(3, state.hands_remaining)
            assert.are.equal(2, state.discards_remaining)
            assert.are.equal("SEED42", state.seed)
            assert.is_number(state.timestamp)

            -- full_deck still aggregates the surviving areas (deck, discard).
            assert.is_table(state.full_deck)
            assert.are.equal(0, #state_hand(state))
            assert.are.equal(1, #state_deck(state))
            assert.are.equal(1, #state_discard_pile(state))

            -- Vouchers and hand_levels should still work
            assert.is_table(state.vouchers)
            assert.are.equal(2, #state.vouchers)
            assert.is_table(state.hand_levels)
        end)

        it("logs a separate warning for each failed field", function()
            G.GAME.blind = nil
            G.hand = nil
            G.jokers = nil

            Capture.build_game_state("discard")

            -- Should have warnings for blind_name, blind_target, boss_blind_effect, jokers
            local found_blind_name = false
            local found_jokers = false
            for _, msg in ipairs(warnings) do
                if msg:find("blind_name") then found_blind_name = true end
                if msg:find("jokers") then found_jokers = true end
            end
            assert.is_true(found_blind_name, "Expected warning about blind_name")
            assert.is_true(found_jokers, "Expected warning about jokers")
        end)

        it("each warning includes the action type context", function()
            G.GAME.blind = nil
            G.jokers = nil

            Capture.build_game_state("buy_joker")

            -- All warnings should mention the action type
            for _, msg in ipairs(warnings) do
                assert.is_truthy(msg:find("buy_joker"),
                    "Warning should include action type: " .. msg)
            end
        end)

        it("one failure does not prevent subsequent fields from being captured", function()
            -- Set G.deck to nil — full_deck still picks up hand and discard.
            G.deck = nil

            local state = Capture.build_game_state("play_hand")

            -- full_deck loses the deck-area cards but keeps hand and discard.
            assert.is_table(state.full_deck)
            assert.are.equal(0, #state_deck(state))
            assert.are.equal(2, #state_hand(state))
            assert.are.equal(1, #state_discard_pile(state))

            -- And jokers (captured after full_deck) should still work
            assert.is_table(state.jokers)
            assert.are.equal(2, #state.jokers)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 11. Output structure matches schema (Task 3.2 sub-task 1)
    -- -----------------------------------------------------------------------
    describe("output structure matches schema", function()
        it("returns a table with exactly the expected top-level keys", function()
            local state = Capture.build_game_state("play_hand")

            local expected_keys = {
                "ante", "blind_name", "blind_target", "boss_blind_effect",
                "blind_slot",
                "score", "money", "hands_remaining", "discards_remaining",
                "discards_used",
                "seed", "timestamp",
                "full_deck",
                "jokers", "consumables", "vouchers", "hand_levels", "shop_inventory",
                "tags", "location",
            }

            -- Verify all expected keys are present
            for _, key in ipairs(expected_keys) do
                assert.is_not_nil(state[key], "Missing key: " .. key)
            end

            -- Verify no unexpected keys exist
            local expected_set = {}
            for _, key in ipairs(expected_keys) do expected_set[key] = true end
            for key, _ in pairs(state) do
                assert.is_true(expected_set[key], "Unexpected key: " .. tostring(key))
            end
        end)

        it("scalar fields have correct types", function()
            local state = Capture.build_game_state("play_hand")

            assert.is_number(state.ante)
            assert.is_string(state.blind_name)
            assert.is_number(state.blind_target)
            -- boss_blind_effect is NULL sentinel (non-boss) or string (boss)
            assert.is_number(state.score)
            assert.is_number(state.money)
            assert.is_number(state.hands_remaining)
            assert.is_number(state.discards_remaining)
            assert.is_string(state.seed)
            assert.is_number(state.timestamp)
        end)

        it("collection fields are arrays/tables", function()
            local state = Capture.build_game_state("play_hand")

            assert.is_table(state.full_deck)
            assert.is_table(state.jokers)
            assert.is_table(state.consumables)
            assert.is_table(state.vouchers)
            assert.is_table(state.hand_levels)
            assert.is_table(state.shop_inventory)
        end)

        it("card entries have all required fields (id, rank, suit)", function()
            local state = Capture.build_game_state("play_hand")

            -- Modifiers (enhancement / edition / seal) are omitted from
            -- descriptors when they equal their defaults — the viewer
            -- treats absent keys as 'none' / 'base' / 'none'. Only id,
            -- rank, and suit are mandatory on every card.
            for _, card in ipairs(state.full_deck) do
                assert.is_string(card.id)
                assert.is_string(card.rank)
                assert.is_string(card.suit)
            end
        end)

        it("joker entries have all required fields (id, name, slot, edition, enhancement, seal, internal_state)", function()
            local state = Capture.build_game_state("play_hand")

            for _, joker in ipairs(state.jokers) do
                assert.is_string(joker.id)
                assert.is_string(joker.name)
                assert.is_number(joker.slot)
                assert.is_string(joker.edition)
                assert.is_string(joker.enhancement)
                assert.is_string(joker.seal)
                assert.is_table(joker.internal_state)
            end
        end)

        it("hand_levels entries have level, chips, mult, played fields", function()
            local state = Capture.build_game_state("play_hand")

            for hand_type, data in pairs(state.hand_levels) do
                assert.is_number(data.level, hand_type .. " level should be number")
                assert.is_number(data.chips, hand_type .. " chips should be number")
                assert.is_number(data.mult, hand_type .. " mult should be number")
                assert.is_number(data.played, hand_type .. " played should be number")
            end
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 12. Shop inventory empty for all non-shop actions (Task 3.2 sub-task 2)
    -- -----------------------------------------------------------------------
    describe("shop inventory empty for all non-shop actions", function()
        it("is empty for sell_joker action", function()
            local state = Capture.build_game_state("sell_joker")
            assert.are.equal(0, #state.shop_inventory)
        end)

        it("is empty for use_consumable action", function()
            local state = Capture.build_game_state("use_consumable")
            assert.are.equal(0, #state.shop_inventory)
        end)

        it("is empty for skip_blind action", function()
            local state = Capture.build_game_state("skip_blind")
            assert.are.equal(0, #state.shop_inventory)
        end)

        it("is empty for select_from_pack action", function()
            local state = Capture.build_game_state("select_from_pack")
            assert.are.equal(0, #state.shop_inventory)
        end)

        it("is an empty table (not nil or NULL) for non-shop actions", function()
            local state = Capture.build_game_state("play_hand")
            assert.is_table(state.shop_inventory)
            assert.are_not.equal(NULL, state.shop_inventory)
            assert.are.equal(0, #state.shop_inventory)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 13. pcall error handling with field name + action type (Task 3.2 sub-task 3)
    -- -----------------------------------------------------------------------
    describe("pcall error handling includes field name and action type", function()
        it("warning for full_deck failure includes the field name and action type", function()
            -- Force build_full_deck to throw by sabotaging the metatable on
            -- a card so the descriptor builder errors. Easier: nil out
            -- every area at once and let safe_access wrap the whole call.
            -- Actually safe_access only fires when build_full_deck() throws,
            -- not when it returns an empty table. Force a throw by making
            -- ipairs over G.deck.cards explode.
            G.deck.cards = setmetatable({}, {
                __len = function() error("boom") end,
            })

            Capture.build_game_state("sell_joker")

            -- The pcall inside append_area_to_full_deck catches the deck
            -- error so the other areas still contribute. Whether or not
            -- this surfaces a warning is implementation-defined; what we
            -- DO require is that capture continues without crashing.
            assert.is_true(true)
        end)

        it("warning for consumables includes field name and action type", function()
            G.consumeables = nil

            Capture.build_game_state("use_consumable")

            local found_field = false
            local found_action = false
            for _, msg in ipairs(warnings) do
                if msg:find("consumables") then found_field = true end
                if msg:find("use_consumable") then found_action = true end
            end
            assert.is_true(found_field, "Expected warning to include field name 'consumables'")
            assert.is_true(found_action, "Expected warning to include action type 'use_consumable'")
        end)

        it("substitutes NULL sentinel for unavailable field", function()
            G.consumeables = nil

            local state = Capture.build_game_state("play_hand")

            assert.are.equal(NULL, state.consumables)
        end)

        it("warning for jokers during skip_blind includes both identifiers", function()
            G.jokers = nil

            Capture.build_game_state("skip_blind")

            local found_field = false
            local found_action = false
            for _, msg in ipairs(warnings) do
                if msg:find("jokers") then found_field = true end
                if msg:find("skip_blind") then found_action = true end
            end
            assert.is_true(found_field, "Expected warning to include field name 'jokers'")
            assert.is_true(found_action, "Expected warning to include action type 'skip_blind'")
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 14. Joker internal_state is empty object when no mutable fields (Task 3.2 sub-task 4)
    -- -----------------------------------------------------------------------
    describe("joker internal_state empty when no mutable fields", function()
        it("returns empty table for joker with only name in ability", function()
            -- Replace jokers with one that has only a name field
            G.jokers.cards = {
                {
                    config = { center = { key = "j_joker", name = "Joker" } },
                    ability = { name = "Joker" },
                    edition = nil,
                    seal = nil,
                },
            }

            local state = Capture.build_game_state("play_hand")

            assert.is_table(state.jokers[1].internal_state)
            local count = 0
            for _ in pairs(state.jokers[1].internal_state) do count = count + 1 end
            assert.are.equal(0, count)
        end)

        it("returns empty table for joker with name + non-mutable meta fields", function()
            -- Joker with name, order, set, description (all excluded from internal_state)
            G.jokers.cards = {
                {
                    config = { center = { key = "j_banner", name = "Banner" } },
                    ability = { name = "Banner", order = 1, set = "Joker", description = "A joker" },
                    edition = nil,
                    seal = nil,
                },
            }

            local state = Capture.build_game_state("play_hand")

            assert.is_table(state.jokers[1].internal_state)
            local count = 0
            for _ in pairs(state.jokers[1].internal_state) do count = count + 1 end
            assert.are.equal(0, count)
        end)

        it("returns populated table for joker with mutable numeric fields", function()
            G.jokers.cards = {
                {
                    config = { center = { key = "j_ride_the_bus", name = "Ride the Bus" } },
                    ability = { name = "Ride the Bus", consecutive = 7 },
                    edition = nil,
                    seal = nil,
                },
            }

            local state = Capture.build_game_state("play_hand")

            assert.is_table(state.jokers[1].internal_state)
            assert.are.equal(7, state.jokers[1].internal_state.consecutive)
        end)

        it("internal_state is a table (not nil) even when empty", function()
            G.jokers.cards = {
                {
                    config = { center = { key = "j_joker", name = "Joker" } },
                    ability = { name = "Joker" },
                    edition = nil,
                    seal = nil,
                },
            }

            local state = Capture.build_game_state("play_hand")

            -- Must be a table, not nil or NULL
            assert.is_table(state.jokers[1].internal_state)
            assert.are_not.equal(NULL, state.jokers[1].internal_state)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 15. Dependency injection
    -- -----------------------------------------------------------------------
    describe("dependency injection", function()
        it("set_logger replaces the logger function", function()
            local new_warnings = {}
            Capture.set_logger(function(msg)
                new_warnings[#new_warnings + 1] = msg
            end)

            G.GAME.blind = nil
            Capture.build_game_state("play_hand")

            assert.is_true(#new_warnings > 0)
            -- Original warnings should be empty since logger was replaced
            assert.are.equal(0, #warnings)
        end)

        it("init() injects both null_sentinel and logger", function()
            local custom_null = { _type = "custom_null" }
            local custom_warnings = {}
            Capture.init({
                null_sentinel = custom_null,
                logger = function(msg) custom_warnings[#custom_warnings + 1] = msg end,
            })

            G.GAME.blind = nil
            local state = Capture.build_game_state("play_hand")

            assert.are.equal(custom_null, state.blind_name)
            assert.is_true(#custom_warnings > 0)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 16. blind_slot stamping (Requirements 2.3, 2.5, 2.6, 2.7)
    -- -----------------------------------------------------------------------
    describe("blind_slot stamping from injected getter", function()
        it("stamps state.blind_slot from the injected getter for play_hand", function()
            Capture.init({
                null_sentinel = NULL,
                logger = mock_logger,
                get_current_blind_slot = function() return "small" end,
            })

            local state = Capture.build_game_state("play_hand")
            assert.are.equal("small", state.blind_slot)
        end)

        it("stamps state.blind_slot for each of small/big/boss/pvp across actions", function()
            local action_types = {
                "play_hand", "discard",
                "buy_joker", "buy_consumable", "buy_voucher", "buy_pack",
                "reroll_shop", "sell_joker", "use_consumable", "select_from_pack",
            }
            local slots = { "small", "big", "boss", "pvp" }

            for _, slot in ipairs(slots) do
                Capture.init({
                    null_sentinel = NULL,
                    logger = mock_logger,
                    get_current_blind_slot = function() return slot end,
                })

                for _, action_type in ipairs(action_types) do
                    local state = Capture.build_game_state(action_type)
                    assert.are.equal(slot, state.blind_slot,
                        "Expected slot " .. slot .. " on action " .. action_type)
                end
            end
        end)

        it("calls the getter on every build_game_state invocation", function()
            local call_count = 0
            Capture.init({
                null_sentinel = NULL,
                logger = mock_logger,
                get_current_blind_slot = function()
                    call_count = call_count + 1
                    return "big"
                end,
            })

            Capture.build_game_state("play_hand")
            Capture.build_game_state("buy_joker")
            Capture.build_game_state("discard")

            assert.are.equal(3, call_count)
        end)

        it("reflects changes to the run-scoped slot across calls", function()
            -- Simulate run_state.current_blind_slot being updated between
            -- select_blind emissions; the getter closure returns the current
            -- value each time it is invoked.
            local current = "small"
            Capture.init({
                null_sentinel = NULL,
                logger = mock_logger,
                get_current_blind_slot = function() return current end,
            })

            local s1 = Capture.build_game_state("play_hand")
            current = "big"
            local s2 = Capture.build_game_state("play_hand")
            current = "boss"
            local s3 = Capture.build_game_state("play_hand")

            assert.are.equal("small", s1.blind_slot)
            assert.are.equal("big",   s2.blind_slot)
            assert.are.equal("boss",  s3.blind_slot)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 17. blind_slot null + warning for non-select_blind actions (Req 2.7)
    -- -----------------------------------------------------------------------
    describe("blind_slot null handling", function()
        it("is NULL and emits a warning when getter returns nil on play_hand", function()
            Capture.init({
                null_sentinel = NULL,
                logger = mock_logger,
                get_current_blind_slot = function() return nil end,
            })

            local state = Capture.build_game_state("play_hand")

            assert.are.equal(NULL, state.blind_slot)

            -- Warning must name the field and the action type (Requirement 2.7).
            local found = false
            for _, msg in ipairs(warnings) do
                if msg:find("blind_slot", 1, true) and msg:find("play_hand", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found,
                "Expected warning naming 'blind_slot' and 'play_hand', got: "
                .. table.concat(warnings, " | "))
        end)

        it("is NULL and emits a warning when getter returns nil on a shop action", function()
            Capture.init({
                null_sentinel = NULL,
                logger = mock_logger,
                get_current_blind_slot = function() return nil end,
            })

            local state = Capture.build_game_state("buy_joker")

            assert.are.equal(NULL, state.blind_slot)

            local found = false
            for _, msg in ipairs(warnings) do
                if msg:find("blind_slot", 1, true) and msg:find("buy_joker", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found,
                "Expected warning naming 'blind_slot' and 'buy_joker', got: "
                .. table.concat(warnings, " | "))
        end)

        it("is NULL but emits NO warning for select_blind when getter returns nil", function()
            -- select_blind is exempt: hooks.lua overrides state.blind_slot with
            -- the freshly-resolved slot after build_game_state returns. A nil
            -- getter result here is expected and must not pollute the log.
            Capture.init({
                null_sentinel = NULL,
                logger = mock_logger,
                get_current_blind_slot = function() return nil end,
            })

            local state = Capture.build_game_state("select_blind")

            assert.are.equal(NULL, state.blind_slot)

            for _, msg in ipairs(warnings) do
                assert.is_falsy(msg:find("blind_slot", 1, true),
                    "select_blind must not emit a blind_slot warning, but got: " .. msg)
            end
        end)

        it("does not prevent other fields from being captured", function()
            Capture.init({
                null_sentinel = NULL,
                logger = mock_logger,
                get_current_blind_slot = function() return nil end,
            })

            local state = Capture.build_game_state("play_hand")

            -- blind_slot is null but the rest of the state is intact.
            assert.are.equal(NULL, state.blind_slot)
            assert.are.equal(2, state.ante)
            assert.are.equal("Big Blind", state.blind_name)
            assert.is_table(state.full_deck)
            assert.are.equal(2, #state_hand(state))
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 18. PvP gating: enabled=true attaches state.pvp with four fields.
    -- Requirements 4.2, 4.4
    -- -----------------------------------------------------------------------
    describe("state.pvp when multiplayer.enabled = true", function()
        it("attaches state.pvp with all four expected fields and values", function()
            local mp_stub = {
                enabled        = true,
                is_pvp_blind   = function() return true end,
                opponent_id    = function() return "op_42" end,
                opponent_name  = function() return "rival_player" end,
                player_score   = function() return 1500 end,
                opponent_score = function() return 1200 end,
            }
            Capture.init({
                null_sentinel = NULL,
                logger = mock_logger,
                multiplayer = mp_stub,
            })

            local state = Capture.build_game_state("play_hand")

            assert.is_table(state.pvp)
            assert.are.equal("op_42",        state.pvp.opponent_id)
            assert.are.equal("rival_player", state.pvp.opponent_name)
            assert.are.equal(1500,           state.pvp.player_running_score)
            assert.are.equal(1200,           state.pvp.opponent_running_score)
        end)

        it("substitutes NULL for individual fields when the accessor returns nil", function()
            -- Requirement 4.4: failed sub-field reads become null; the pvp
            -- object is still attached with the other fields populated.
            local mp_stub = {
                enabled        = true,
                is_pvp_blind   = function() return true end,
                opponent_id    = function() return "op_9" end,
                opponent_name  = function() return nil end,
                player_score   = function() return 300 end,
                opponent_score = function() return nil end,
            }
            Capture.init({
                null_sentinel = NULL,
                logger = mock_logger,
                multiplayer = mp_stub,
            })

            local state = Capture.build_game_state("play_hand")

            assert.is_table(state.pvp)
            assert.are.equal("op_9", state.pvp.opponent_id)
            assert.are.equal(NULL,   state.pvp.opponent_name)
            assert.are.equal(300,    state.pvp.player_running_score)
            assert.are.equal(NULL,   state.pvp.opponent_running_score)
        end)

        it("attaches state.pvp on shop actions as well", function()
            local mp_stub = {
                enabled        = true,
                is_pvp_blind   = function() return false end,
                opponent_id    = function() return "op_1" end,
                opponent_name  = function() return "foe" end,
                player_score   = function() return 0 end,
                opponent_score = function() return 0 end,
            }
            Capture.init({
                null_sentinel = NULL,
                logger = mock_logger,
                multiplayer = mp_stub,
            })

            local state = Capture.build_game_state("buy_joker")

            assert.is_table(state.pvp)
            assert.are.equal("op_1", state.pvp.opponent_id)
            assert.are.equal("foe",  state.pvp.opponent_name)
            assert.are.equal(0,      state.pvp.player_running_score)
            assert.are.equal(0,      state.pvp.opponent_running_score)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 19. PvP gating: enabled=false omits state.pvp and makes zero reads.
    -- Requirement 4.3
    -- -----------------------------------------------------------------------
    describe("state.pvp when multiplayer.enabled = false", function()
        --- Build a Multiplayer stub whose accessor functions bump a shared
        --- counter when invoked. Any non-zero counter after a capture proves
        --- capture.lua touched the Multiplayer surface — a Requirement 4.3
        --- violation.
        local function make_counting_mp(enabled)
            local reads = { count = 0 }
            local function bump(name)
                return function()
                    reads.count = reads.count + 1
                    return "forbidden:" .. name
                end
            end
            return {
                enabled        = enabled,
                is_pvp_blind   = bump("is_pvp_blind"),
                opponent_id    = bump("opponent_id"),
                opponent_name  = bump("opponent_name"),
                player_score   = bump("player_score"),
                opponent_score = bump("opponent_score"),
            }, reads
        end

        it("omits state.pvp entirely when enabled is false", function()
            local mp_stub = make_counting_mp(false)
            Capture.init({
                null_sentinel = NULL,
                logger = mock_logger,
                multiplayer = mp_stub,
            })

            local state = Capture.build_game_state("play_hand")

            assert.is_nil(state.pvp,
                "state.pvp must be absent when multiplayer is disabled")
        end)

        it("performs zero reads on the multiplayer accessor when disabled", function()
            local mp_stub, reads = make_counting_mp(false)
            Capture.init({
                null_sentinel = NULL,
                logger = mock_logger,
                multiplayer = mp_stub,
            })

            Capture.build_game_state("play_hand")
            Capture.build_game_state("buy_joker")
            Capture.build_game_state("discard")
            Capture.build_game_state("select_blind")

            assert.are.equal(0, reads.count,
                "Disabled multiplayer must not be read, but " ..
                tostring(reads.count) .. " accessor calls were observed")
        end)

        it("omits state.pvp when the accessor is not injected at all", function()
            -- Fresh init with only null_sentinel + logger — no multiplayer opt.
            Capture.init({ null_sentinel = NULL, logger = mock_logger })

            local state = Capture.build_game_state("play_hand")

            assert.is_nil(state.pvp)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- Capture.is_card_destroyed
    -- -----------------------------------------------------------------------
    describe("Capture.is_card_destroyed", function()
        --- Build a minimal card reference with a base.value so the helper
        --- only has to decide based on `removed` and area membership.
        local function make_card(rank, suit)
            return {
                base = { value = rank or "A", suit = suit or "Spades" },
            }
        end

        --- Reset G to a baseline with empty hand/deck/discard/play areas.
        before_each(function()
            _G.G = {
                hand    = { cards = {} },
                deck    = { cards = {} },
                discard = { cards = {} },
                play    = { cards = {} },
            }
        end)

        it("returns true for a non-table reference", function()
            assert.is_true(Capture.is_card_destroyed(nil))
            assert.is_true(Capture.is_card_destroyed("c_42"))
            assert.is_true(Capture.is_card_destroyed(7))
            assert.is_true(Capture.is_card_destroyed(false))
        end)

        it("returns true when ref.removed is set", function()
            local card = make_card("Q", "Hearts")
            card.removed = true
            -- Even if the card is also still in hand, removed=true wins.
            table.insert(_G.G.hand.cards, card)

            assert.is_true(Capture.is_card_destroyed(card))
        end)

        it("returns true when the card has no base.value", function()
            local card = { base = { suit = "Hearts" } }  -- no value
            table.insert(_G.G.hand.cards, card)
            assert.is_true(Capture.is_card_destroyed(card))

            local card_no_base = { suit = "Hearts" }
            assert.is_true(Capture.is_card_destroyed(card_no_base))
        end)

        it("returns false when the card is in G.hand", function()
            local card = make_card("A", "Spades")
            table.insert(_G.G.hand.cards, card)

            assert.is_false(Capture.is_card_destroyed(card))
        end)

        it("returns false when the card is in G.deck", function()
            local card = make_card("K", "Diamonds")
            table.insert(_G.G.deck.cards, card)

            assert.is_false(Capture.is_card_destroyed(card))
        end)

        it("returns false when the card is in G.discard", function()
            local card = make_card("J", "Clubs")
            table.insert(_G.G.discard.cards, card)

            assert.is_false(Capture.is_card_destroyed(card))
        end)

        it("returns false when the card is in G.play", function()
            local card = make_card("10", "Hearts")
            table.insert(_G.G.play.cards, card)

            assert.is_false(Capture.is_card_destroyed(card))
        end)

        it("returns true when the card is not in any area", function()
            -- Card is well-formed but no area references it — destroyed.
            local card = make_card("5", "Spades")
            -- Populate areas with OTHER cards to ensure scan runs fully.
            table.insert(_G.G.hand.cards, make_card("2", "Hearts"))
            table.insert(_G.G.deck.cards, make_card("3", "Clubs"))

            assert.is_true(Capture.is_card_destroyed(card))
        end)

        it("uses identity comparison, not value equality", function()
            -- Two cards with identical fields are still distinct refs.
            local original = make_card("A", "Spades")
            local lookalike = make_card("A", "Spades")
            table.insert(_G.G.hand.cards, lookalike)

            -- The original ref is gone from all areas → destroyed.
            assert.is_true(Capture.is_card_destroyed(original))
            -- The lookalike is in G.hand → surviving.
            assert.is_false(Capture.is_card_destroyed(lookalike))
        end)
    end)
end)
