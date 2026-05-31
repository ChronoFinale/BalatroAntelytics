--- spec/balatro_compat/j_castle_compat_spec.lua
---
--- Verify the Castle live-effect chip count matches the real game's
--- on_discard accumulation branch and post-scoring chip emission,
--- sourced from card.lua.
---
--- Real game (card.lua, Card:calculate_joker):
---
---   on_discard branch:
---     if self.ability.name == 'Castle' and
---         not context.other_card.debuff and
---         context.other_card:is_suit(G.GAME.current_round.castle_card.suit) and
---         not context.blueprint then
---         self.ability.extra.chips =
---             self.ability.extra.chips + self.ability.extra.chip_mod
---     end
---
---   scoring branch (held-in-hand chips emit):
---     if self.ability.name == 'Castle' and (self.ability.extra.chips > 0) then
---         return { chip_mod = self.ability.extra.chips, ... }
---     end
---
--- The viewer surfaces `+{chips} Chips · target {suit}` from the
--- captured `extra.{chips, suit}`. The numeric formula it relies on
--- is just `extra.chips` — accumulated by the on_discard branch.
---
--- Boundary: suit just rolled, accumulated chips = 0.

local Source = require("spec.balatro_compat.lib.source")

describe("Castle compat — viewer chip read matches card.lua", function()
    if Source.skip_unless_present("card.lua") then return end
    local card_source = Source.read("card.lua")

    it("card.lua's Castle on_discard branch still accumulates extra.chips by extra.chip_mod for the target suit", function()
        -- Find the on_discard accumulation: the unique line where
        -- extra.chips is reassigned via + extra.chip_mod.
        local accum_pos = card_source:find(
            "self%.ability%.extra%.chips%s*=%s*self%.ability%.extra%.chips%s*%+%s*self%.ability%.extra%.chip_mod"
        )
        assert.is_truthy(
            accum_pos,
            "Castle on_discard branch should still accumulate extra.chips += extra.chip_mod"
        )

        -- The same vicinity should still gate on the suit match.
        local block = card_source:sub(math.max(1, accum_pos - 400), accum_pos + 200)
        assert.is_truthy(
            block:find("castle_card%.suit") or block:find("castle_card"),
            "Castle on_discard branch should still gate on current_round.castle_card.suit"
        )
        assert.is_truthy(
            block:find("Castle"),
            "Castle accumulation should still live in the Castle name branch"
        )
    end)

    -- ---------------------------------------------------------------
    -- Lua mirror of the game's accumulation. Each discard pass that
    -- targets the round's castle suit adds `chip_mod` to `extra.chips`.
    -- ---------------------------------------------------------------
    local function game_chips_after_discard(initial_chips, chip_mod, discarded_suits, target_suit)
        local chips = initial_chips
        for _, suit in ipairs(discarded_suits) do
            if suit == target_suit then
                chips = chips + chip_mod
            end
        end
        return chips
    end

    -- ---------------------------------------------------------------
    -- Lua mirror of the JS viewer handler. Returns the numeric chips
    -- value the live-effect caption surfaces, given the captured
    -- internal_state.
    -- ---------------------------------------------------------------
    local function viewer_chips(state)
        local extra = state and state.extra
        if type(extra) ~= "table" then return nil end
        if type(extra.chips) ~= "number" then return nil end
        return extra.chips
    end

    it("matches the game after 0 matching discards (boundary: chips = 0)", function()
        local chip_mod = 3
        local discarded = {"Hearts", "Diamonds", "Clubs"}
        local game_says = game_chips_after_discard(0, chip_mod, discarded, "Spades")
        assert.are.equal(0, game_says)

        local state = { extra = { chips = game_says, suit = "Spades", chip_mod = chip_mod } }
        assert.are.equal(game_says, viewer_chips(state))
    end)

    it("matches the game after 4 matching discards", function()
        local chip_mod = 3
        local discarded = {"Spades", "Spades", "Hearts", "Spades", "Spades"}
        local game_says = game_chips_after_discard(0, chip_mod, discarded, "Spades")
        assert.are.equal(12, game_says)

        local state = { extra = { chips = game_says, suit = "Spades", chip_mod = chip_mod } }
        assert.are.equal(game_says, viewer_chips(state))
    end)

    it("matches the game when accumulation continues from a non-zero base", function()
        local chip_mod = 3
        local discarded = {"Hearts", "Hearts", "Spades"} -- 2 hits
        local game_says = game_chips_after_discard(15, chip_mod, discarded, "Hearts")
        assert.are.equal(21, game_says)

        local state = { extra = { chips = game_says, suit = "Hearts", chip_mod = chip_mod } }
        assert.are.equal(game_says, viewer_chips(state))
    end)
end)
