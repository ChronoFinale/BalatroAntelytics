--- spec/balatro_compat/j_delayed_grat_compat_spec.lua
---
--- Verify the Delayed Gratification end-of-round payout matches the
--- real game's calc branch, sourced from card.lua.
---
--- Real game (card.lua, calc_dollar_bonus / end_of_round payout branch):
---   if self.ability.name == 'Delayed Gratification' and
---       G.GAME.current_round.discards_used == 0 and
---       G.GAME.current_round.discards_left > 0 then
---       return G.GAME.current_round.discards_left * self.ability.extra
---   end
---
--- Payout fires only when zero discards have been used this round and
--- there's at least one discard remaining. The dollar amount is
--- `discards_left * extra` (default $2 per discard).
---
--- Boundary: one discard used → payout = $0.

local Source = require("spec.balatro_compat.lib.source")

describe("Delayed Gratification compat — viewer payout matches card.lua", function()
    if Source.skip_unless_present("card.lua") then return end
    local card_source = Source.read("card.lua")

    it("card.lua's Delayed Gratification branch still pays discards_left * extra", function()
        local pos = card_source:find("name%s*==%s*'Delayed Gratification'")
        assert.is_truthy(pos, "Delayed Gratification case should still exist in card.lua")

        -- Walk to the LAST occurrence (the calc branch, after loc_vars).
        local last_pos = pos
        local search_from = pos + 1
        while true do
            local p = card_source:find("name%s*==%s*'Delayed Gratification'", search_from)
            if not p then break end
            last_pos = p
            search_from = p + 1
        end

        local block = card_source:sub(last_pos, last_pos + 500)
        assert.is_truthy(
            block:find("discards_used"),
            "Delayed Gratification branch should still gate on discards_used"
        )
        assert.is_truthy(
            block:find("discards_left"),
            "Delayed Gratification branch should still pay discards_left * extra"
        )
        assert.is_truthy(
            block:find("self%.ability%.extra"),
            "Delayed Gratification branch should still multiply by extra"
        )
    end)

    -- ---------------------------------------------------------------
    -- Lua mirror of the game's payout.
    -- ---------------------------------------------------------------
    local function game_payout(discards_used, discards_left, extra)
        if discards_used == 0 and discards_left > 0 then
            return discards_left * extra
        end
        return 0
    end

    -- ---------------------------------------------------------------
    -- Lua mirror of the JS viewer handler's numeric prediction.
    --
    -- The viewer's caption is `+$N if no discards used` when the
    -- player hasn't burned a discard yet this round, and `+$0 this
    -- round (used a discard)` when one has been used. We compare the
    -- predicted dollar amount against the game's payout.
    -- ---------------------------------------------------------------
    local function viewer_predicted(state, context)
        local extra = (state and state.extra) or 2
        local discards_left = context and context.discards_remaining
        local used_any = context and context.any_discard_this_round
        if used_any then return 0 end
        if type(discards_left) ~= "number" or discards_left <= 0 then return nil end
        return discards_left * extra
    end

    it("matches the game when no discards used and 3 discards left", function()
        local game_says = game_payout(0, 3, 2)
        assert.are.equal(6, game_says)

        local state = { extra = 2 }
        local context = { discards_remaining = 3, any_discard_this_round = false }
        assert.are.equal(game_says, viewer_predicted(state, context))
    end)

    it("matches the game when no discards used and 1 discard left", function()
        local game_says = game_payout(0, 1, 2)
        assert.are.equal(2, game_says)

        local state = { extra = 2 }
        local context = { discards_remaining = 1, any_discard_this_round = false }
        assert.are.equal(game_says, viewer_predicted(state, context))
    end)

    it("matches the game on a non-default extra value", function()
        local game_says = game_payout(0, 4, 3)
        assert.are.equal(12, game_says)

        local state = { extra = 3 }
        local context = { discards_remaining = 4, any_discard_this_round = false }
        assert.are.equal(game_says, viewer_predicted(state, context))
    end)

    it("boundary: one discard used → payout = 0 (matches game)", function()
        local game_says = game_payout(1, 2, 2)
        assert.are.equal(0, game_says)

        local state = { extra = 2 }
        local context = { discards_remaining = 2, any_discard_this_round = true }
        assert.are.equal(game_says, viewer_predicted(state, context))
    end)
end)
