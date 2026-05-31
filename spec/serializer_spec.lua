--- serializer_spec.lua
--- Unit tests for the Balatro Antelytics JSON serializer.
--- Validates: Requirements 3.3, 3.4

-- Adjust package path to find the serializer module
package.path = package.path .. ";../lib/?.lua;./lib/?.lua;./Antelytics/lib/?.lua"

local Serializer = require("serializer")

-- Helper: deep equality check for tables
local function deep_equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    -- Check same number of keys
    local a_count, b_count = 0, 0
    for _ in pairs(a) do a_count = a_count + 1 end
    for _ in pairs(b) do b_count = b_count + 1 end
    if a_count ~= b_count then return false end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    return true
end

describe("Serializer", function()

    -- -----------------------------------------------------------------------
    -- 1. Primitive types
    -- -----------------------------------------------------------------------
    describe("primitive types", function()
        it("encodes nil as null", function()
            assert.are.equal("null", Serializer.encode(nil))
        end)

        it("encodes Serializer.null sentinel as null", function()
            assert.are.equal("null", Serializer.encode(Serializer.null))
        end)

        it("encodes true", function()
            assert.are.equal("true", Serializer.encode(true))
        end)

        it("encodes false", function()
            assert.are.equal("false", Serializer.encode(false))
        end)

        it("encodes integers without decimal point", function()
            assert.are.equal("42", Serializer.encode(42))
            assert.are.equal("0", Serializer.encode(0))
            assert.are.equal("-7", Serializer.encode(-7))
        end)

        it("encodes large integers without 32-bit overflow", function()
            -- Regression: %d truncated to int32 under LuaJIT, wrapping a
            -- 23.7-billion PvP score to -2,042,506,920. Must round-trip.
            assert.are.equal("23727296856", Serializer.encode(23727296856))
            assert.are.equal("2215102804", Serializer.encode(2215102804))
            assert.are.equal("-23727296856", Serializer.encode(-23727296856))
            assert.are.equal(23727296856, Serializer.decode(Serializer.encode(23727296856)))
        end)

        it("round-trips scores across Balatro's full double range", function()
            -- Vanilla scores are finite doubles with no cap; the top end is the
            -- IEEE max (~1.8e308, the "naneinf" boundary). Every value must
            -- survive encode->decode exactly (lossless relative to the double
            -- the game itself stores). Above 2^53 exact-integer-ness is lost,
            -- but the round-trip still reproduces the identical double.
            local extremes = {
                1e15, 1e16, 1e18, 1e100, 1e300,
                1.7976931348623157e308, -1.7976931348623157e308,
            }
            for _, v in ipairs(extremes) do
                assert.are.equal(v, Serializer.decode(Serializer.encode(v)),
                    "round-trip failed for " .. tostring(v))
            end
        end)

        it("encodes non-finite scores as null", function()
            -- inf/NaN never arise from a legitimate vanilla score (engine has
            -- no cap and never constructs them); null is the safe sentinel.
            assert.are.equal("null", Serializer.encode(math.huge))
            assert.are.equal("null", Serializer.encode(-math.huge))
            assert.are.equal("null", Serializer.encode(0/0))
        end)

        it("encodes floats with decimal precision", function()
            local encoded = Serializer.encode(3.14159)
            local decoded = tonumber(encoded)
            assert.is_not_nil(decoded)
            assert.is_near(3.14159, decoded, 1e-10)
        end)

        it("encodes simple strings", function()
            assert.are.equal('"hello"', Serializer.encode("hello"))
            assert.are.equal('""', Serializer.encode(""))
        end)

        it("encodes NaN as null", function()
            assert.are.equal("null", Serializer.encode(0/0))
        end)

        it("encodes infinity as null", function()
            assert.are.equal("null", Serializer.encode(math.huge))
            assert.are.equal("null", Serializer.encode(-math.huge))
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 2. String escaping
    -- -----------------------------------------------------------------------
    describe("string escaping", function()
        it("escapes double quotes", function()
            local result = Serializer.encode('say "hello"')
            assert.are.equal('"say \\"hello\\""', result)
        end)

        it("escapes backslashes", function()
            local result = Serializer.encode("back\\slash")
            assert.are.equal('"back\\\\slash"', result)
        end)

        it("escapes newlines", function()
            local result = Serializer.encode("line1\nline2")
            assert.are.equal('"line1\\nline2"', result)
        end)

        it("escapes tabs", function()
            local result = Serializer.encode("col1\tcol2")
            assert.are.equal('"col1\\tcol2"', result)
        end)

        it("escapes carriage returns", function()
            local result = Serializer.encode("cr\rhere")
            assert.are.equal('"cr\\rhere"', result)
        end)

        it("escapes control characters as \\uXXXX", function()
            -- ASCII 0x01 (SOH)
            local result = Serializer.encode("\x01")
            assert.are.equal('"\\u0001"', result)
        end)

        it("round-trips strings with special characters", function()
            local original = 'quotes"and\\backslash\nnewline\ttab'
            local encoded = Serializer.encode(original)
            local decoded = Serializer.decode(encoded)
            assert.are.equal(original, decoded)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 3. Arrays
    -- -----------------------------------------------------------------------
    describe("arrays", function()
        it("encodes empty table as empty array", function()
            assert.are.equal("[]", Serializer.encode({}))
        end)

        it("encodes single-element array", function()
            assert.are.equal("[1]", Serializer.encode({1}))
        end)

        it("encodes multi-element array", function()
            assert.are.equal("[1,2,3]", Serializer.encode({1, 2, 3}))
        end)

        it("encodes nested arrays", function()
            local result = Serializer.encode({{1, 2}, {3, 4}})
            assert.are.equal("[[1,2],[3,4]]", result)
        end)

        it("encodes mixed-type arrays", function()
            local result = Serializer.encode({1, "two", true, Serializer.null})
            assert.are.equal('[1,"two",true,null]', result)
        end)

        it("round-trips arrays", function()
            local original = {10, 20, 30}
            local decoded = Serializer.decode(Serializer.encode(original))
            assert.is_true(deep_equal(original, decoded))
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 4. Objects
    -- -----------------------------------------------------------------------
    describe("objects", function()
        it("encodes simple object", function()
            local result = Serializer.decode(Serializer.encode({name = "test"}))
            assert.are.equal("test", result.name)
        end)

        it("encodes nested objects", function()
            local original = {outer = {inner = "value"}}
            local decoded = Serializer.decode(Serializer.encode(original))
            assert.are.equal("value", decoded.outer.inner)
        end)

        it("encodes objects with mixed value types", function()
            local original = {
                str = "hello",
                num = 42,
                bool = true,
                arr = {1, 2, 3}
            }
            local decoded = Serializer.decode(Serializer.encode(original))
            assert.are.equal("hello", decoded.str)
            assert.are.equal(42, decoded.num)
            assert.are.equal(true, decoded.bool)
            assert.is_true(deep_equal({1, 2, 3}, decoded.arr))
        end)

        it("sorts object keys deterministically", function()
            local encoded = Serializer.encode({z = 1, a = 2, m = 3})
            -- Keys should be sorted alphabetically
            assert.are.equal('{"a":2,"m":3,"z":1}', encoded)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 5. Card data round-trip
    -- -----------------------------------------------------------------------
    describe("card data", function()
        it("round-trips a playing card", function()
            local card = {
                id = "c_1",
                rank = "A",
                suit = "Spades",
                enhancement = "none",
                edition = "base",
                seal = "none"
            }
            local decoded = Serializer.decode(Serializer.encode(card))
            assert.are.equal("c_1", decoded.id)
            assert.are.equal("A", decoded.rank)
            assert.are.equal("Spades", decoded.suit)
            assert.are.equal("none", decoded.enhancement)
            assert.are.equal("base", decoded.edition)
            assert.are.equal("none", decoded.seal)
        end)

        it("round-trips a hand of cards", function()
            local hand = {
                { id = "c_1", rank = "A", suit = "Spades", enhancement = "none", edition = "base", seal = "none" },
                { id = "c_2", rank = "K", suit = "Hearts", enhancement = "bonus", edition = "foil", seal = "gold" },
                { id = "c_3", rank = "10", suit = "Diamonds", enhancement = "wild", edition = "holographic", seal = "red" },
            }
            local decoded = Serializer.decode(Serializer.encode(hand))
            assert.are.equal(3, #decoded)
            assert.are.equal("c_1", decoded[1].id)
            assert.are.equal("K", decoded[2].rank)
            assert.are.equal("holographic", decoded[3].edition)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 6. Joker with internal state
    -- -----------------------------------------------------------------------
    describe("joker with internal state", function()
        it("round-trips a joker with mutable internal state", function()
            local joker = {
                id = "j_1",
                name = "Ride the Bus",
                slot = 1,
                internal_state = { consecutive = 5 }
            }
            local decoded = Serializer.decode(Serializer.encode(joker))
            assert.are.equal("j_1", decoded.id)
            assert.are.equal("Ride the Bus", decoded.name)
            assert.are.equal(1, decoded.slot)
            assert.are.equal(5, decoded.internal_state.consecutive)
        end)

        it("round-trips a joker with empty internal state", function()
            local joker = {
                id = "j_2",
                name = "Joker",
                slot = 2,
                edition = "base",
                enhancement = "none",
                seal = "none",
                internal_state = {}
            }
            local decoded = Serializer.decode(Serializer.encode(joker))
            assert.are.equal("j_2", decoded.id)
            assert.are.equal("Joker", decoded.name)
            -- Empty internal_state should decode as empty table
            local count = 0
            for _ in pairs(decoded.internal_state) do count = count + 1 end
            assert.are.equal(0, count)
        end)

        it("round-trips a joker with complex internal state", function()
            local joker = {
                id = "j_3",
                name = "Egg",
                slot = 3,
                internal_state = { sell_value = 12, rounds_held = 8 }
            }
            local decoded = Serializer.decode(Serializer.encode(joker))
            assert.are.equal(12, decoded.internal_state.sell_value)
            assert.are.equal(8, decoded.internal_state.rounds_held)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 7. Null fields in objects (Serializer.null sentinel)
    -- -----------------------------------------------------------------------
    describe("null fields", function()
        it("preserves null fields using Serializer.null sentinel", function()
            local obj = {
                boss_blind_effect = Serializer.null,
                name = "Small Blind"
            }
            local encoded = Serializer.encode(obj)
            -- Should contain null for boss_blind_effect
            assert.truthy(encoded:find('"boss_blind_effect":null'))

            local decoded = Serializer.decode(encoded)
            assert.are.equal(Serializer.null, decoded.boss_blind_effect)
            assert.are.equal("Small Blind", decoded.name)
        end)

        it("preserves null in arrays", function()
            local arr = {1, Serializer.null, 3}
            local encoded = Serializer.encode(arr)
            assert.are.equal("[1,null,3]", encoded)

            local decoded = Serializer.decode(encoded)
            assert.are.equal(1, decoded[1])
            assert.are.equal(Serializer.null, decoded[2])
            assert.are.equal(3, decoded[3])
        end)

        it("distinguishes null from missing keys", function()
            local obj = { present = Serializer.null }
            local encoded = Serializer.encode(obj)
            local decoded = Serializer.decode(encoded)
            -- present key exists with null value
            assert.are.equal(Serializer.null, decoded.present)
            -- absent key is truly nil
            assert.is_nil(decoded.absent)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 8. Circular reference detection
    -- -----------------------------------------------------------------------
    describe("circular reference detection", function()
        it("produces null for circular references and logs error", function()
            local logged_errors = {}
            Serializer._log_error = function(msg)
                logged_errors[#logged_errors + 1] = msg
            end

            local t = { name = "root" }
            t.self = t  -- circular reference

            local encoded = Serializer.encode(t)
            -- The circular reference should be substituted with null
            local decoded = Serializer.decode(encoded)
            assert.are.equal("root", decoded.name)
            assert.are.equal(Serializer.null, decoded.self)

            -- An error should have been logged
            assert.is_true(#logged_errors > 0)
            assert.truthy(logged_errors[1]:find("Circular reference"))
        end)

        it("handles indirect circular references", function()
            local logged_errors = {}
            Serializer._log_error = function(msg)
                logged_errors[#logged_errors + 1] = msg
            end

            local a = { name = "a" }
            local b = { name = "b", ref = a }
            a.ref = b  -- indirect cycle: a -> b -> a

            local encoded = Serializer.encode(a)
            local decoded = Serializer.decode(encoded)
            assert.are.equal("a", decoded.name)
            assert.are.equal("b", decoded.ref.name)
            -- The back-reference should be null
            assert.are.equal(Serializer.null, decoded.ref.ref)

            assert.is_true(#logged_errors > 0)
        end)

        it("allows the same table in sibling positions (not circular)", function()
            local logged_errors = {}
            Serializer._log_error = function(msg)
                logged_errors[#logged_errors + 1] = msg
            end

            local shared = { value = 99 }
            local parent = { a = shared, b = shared }

            local encoded = Serializer.encode(parent)
            local decoded = Serializer.decode(encoded)
            assert.are.equal(99, decoded.a.value)
            assert.are.equal(99, decoded.b.value)

            -- No circular reference error should be logged
            assert.are.equal(0, #logged_errors)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 9. Full Decision_Node structure round-trip
    -- -----------------------------------------------------------------------
    describe("Decision_Node round-trip", function()
        it("round-trips a complete Decision_Node", function()
            local node = {
                index = 0,
                state = {
                    ante = 1,
                    blind_name = "Small Blind",
                    blind_target = 300,
                    boss_blind_effect = Serializer.null,
                    score = 0,
                    money = 4,
                    hands_remaining = 4,
                    discards_remaining = 3,
                    seed = "ABC123",
                    timestamp = 1700000000,
                    hand = {
                        { id = "c_1", rank = "A", suit = "Spades", enhancement = "none", edition = "base", seal = "none" },
                        { id = "c_2", rank = "K", suit = "Hearts", enhancement = "none", edition = "base", seal = "none" },
                    },
                    deck = {
                        { id = "c_10", rank = "5", suit = "Clubs", enhancement = "none", edition = "base", seal = "none" },
                    },
                    discard_pile = {},
                    jokers = {
                        { id = "j_1", name = "Ride the Bus", slot = 1, edition = "base", enhancement = "none", seal = "none", internal_state = { consecutive = 5 } },
                    },
                    consumables = {
                        { id = "co_1", name = "The Fool" },
                    },
                    vouchers = {
                        { id = "v_1", name = "Overstock" },
                    },
                    hand_levels = {
                        ["High Card"]       = { level = 1, chips = 5,   mult = 1 },
                        ["Pair"]            = { level = 1, chips = 10,  mult = 2 },
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
                    shop_inventory = {},
                },
                action = {
                    type = "play_hand",
                    card_ids = { "c_1", "c_2" },
                },
            }

            local encoded = Serializer.encode(node)
            local decoded = Serializer.decode(encoded)

            -- Top-level fields
            assert.are.equal(0, decoded.index)
            assert.are.equal("play_hand", decoded.action.type)
            assert.is_true(deep_equal({"c_1", "c_2"}, decoded.action.card_ids))

            -- State fields
            local state = decoded.state
            assert.are.equal(1, state.ante)
            assert.are.equal("Small Blind", state.blind_name)
            assert.are.equal(300, state.blind_target)
            assert.are.equal(Serializer.null, state.boss_blind_effect)
            assert.are.equal(0, state.score)
            assert.are.equal(4, state.money)
            assert.are.equal(4, state.hands_remaining)
            assert.are.equal(3, state.discards_remaining)
            assert.are.equal("ABC123", state.seed)
            assert.are.equal(1700000000, state.timestamp)

            -- Hand
            assert.are.equal(2, #state.hand)
            assert.are.equal("c_1", state.hand[1].id)
            assert.are.equal("A", state.hand[1].rank)

            -- Jokers with internal state
            assert.are.equal(1, #state.jokers)
            assert.are.equal("Ride the Bus", state.jokers[1].name)
            assert.are.equal(5, state.jokers[1].internal_state.consecutive)

            -- Hand levels
            assert.are.equal(1, state.hand_levels["High Card"].level)
            assert.are.equal(16, state.hand_levels["Flush Five"].mult)

            -- Consumables and vouchers
            assert.are.equal("The Fool", state.consumables[1].name)
            assert.are.equal("Overstock", state.vouchers[1].name)
        end)

        it("round-trips a Decision_Node with shop action", function()
            local node = {
                index = 5,
                state = {
                    ante = 2,
                    blind_name = "Shop",
                    blind_target = 0,
                    boss_blind_effect = Serializer.null,
                    score = 450,
                    money = 12,
                    hands_remaining = 0,
                    discards_remaining = 0,
                    seed = "XYZ789",
                    timestamp = 1700001000,
                    hand = {},
                    deck = {},
                    discard_pile = {},
                    jokers = {},
                    consumables = {},
                    vouchers = {},
                    hand_levels = {},
                    shop_inventory = {
                        { type = "joker", id = "j_joker", name = "Joker", cost = 4 },
                        { type = "consumable", id = "co_fool", name = "The Fool", cost = 3 },
                    },
                },
                action = {
                    type = "buy_joker",
                    joker_id = "j_joker",
                },
            }

            local encoded = Serializer.encode(node)
            local decoded = Serializer.decode(encoded)

            assert.are.equal(5, decoded.index)
            assert.are.equal("buy_joker", decoded.action.type)
            assert.are.equal("j_joker", decoded.action.joker_id)
            assert.are.equal(2, #decoded.state.shop_inventory)
            assert.are.equal("joker", decoded.state.shop_inventory[1].type)
            assert.are.equal(4, decoded.state.shop_inventory[1].cost)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- 10. Special characters in strings
    -- -----------------------------------------------------------------------
    describe("special characters", function()
        it("round-trips emoji characters", function()
            local original = "Hello 🎰🃏"
            local decoded = Serializer.decode(Serializer.encode(original))
            assert.are.equal(original, decoded)
        end)

        it("round-trips unicode characters", function()
            local original = "café résumé naïve"
            local decoded = Serializer.decode(Serializer.encode(original))
            assert.are.equal(original, decoded)
        end)

        it("round-trips strings with null bytes via \\u0000 encoding", function()
            local original = "before\x00after"
            local encoded = Serializer.encode(original)
            -- Should contain \u0000 escape
            assert.truthy(encoded:find("\\u0000"))
            local decoded = Serializer.decode(encoded)
            assert.are.equal(original, decoded)
        end)

        it("round-trips all ASCII control characters", function()
            -- Test a selection of control chars
            for i = 1, 31 do
                local original = "x" .. string.char(i) .. "y"
                local decoded = Serializer.decode(Serializer.encode(original))
                assert.are.equal(original, decoded,
                    "Failed round-trip for control char " .. i)
            end
        end)

        it("handles strings with mixed special characters", function()
            local original = 'tab:\there\nnewline "quoted" back\\slash'
            local decoded = Serializer.decode(Serializer.encode(original))
            assert.are.equal(original, decoded)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- Decoder edge cases
    -- -----------------------------------------------------------------------
    describe("decoder", function()
        it("rejects non-string input", function()
            assert.has_error(function() Serializer.decode(123) end)
            assert.has_error(function() Serializer.decode(nil) end)
            assert.has_error(function() Serializer.decode({}) end)
        end)

        it("rejects trailing garbage", function()
            assert.has_error(function() Serializer.decode("123 abc") end)
        end)

        it("decodes whitespace-padded JSON", function()
            local decoded = Serializer.decode('  { "a" : 1 }  ')
            assert.are.equal(1, decoded.a)
        end)
    end)
end)
