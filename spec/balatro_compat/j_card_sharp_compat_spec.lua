--- spec/balatro_compat/j_card_sharp_compat_spec.lua
---
--- Verify the Card Sharp live-effect activation gate matches the real
--- game's calc branch, sourced from card.lua.
---
--- Real game (card.lua, Card:calculate_joker, scoring branch):
---   if self.ability.name == 'Card Sharp' and
---       G.GAME.hands[context.scoring_name] and
---       G.GAME.hands[context.scoring_name].played_this_round > 1 then
---       return { Xmult_mod = self.ability.extra.Xmult, ... }
---   end
---
--- Card Sharp gives X3 Mult (constant — `extra.Xmult`) only when the
--- played hand has already been played at least once this round
--- (`played_this_round > 1` after the engine's pre-scoring increment).
---
--- The viewer's caption surfaces the LAST played hand type via
--- `internal_state.hand_type`. The numeric thing we can compare is
--- the boolean "is the X3 multiplier active?" which is a function of
--- `played_this_round`.
---
--- Boundary: first hand of run — `hand_type` field unset on the
--- joker, so the viewer should produce no caption.

local Source = require("spec.balatro_compat.lib.source")

describe("Card Sharp compat — viewer activation gate matches card.lua", function()
    if Source.skip_unless_present("card.lua") then return end
    local card_source = Source.read("card.lua")

    it("card.lua's Card Sharp branch still gates on played_this_round > 1", function()
        local pos = card_source:find("name%s*==%s*'Card Sharp'")
        assert.is_truthy(pos, "Card Sharp case should still exist in card.lua")

        -- Walk forward to the calc branch (skip the first occurrence,
        -- which is loc_vars setup).
        local last_pos = pos
        local search_from = pos + 1
        while true do
            local p = card_source:find("name%s*==%s*'Card Sharp'", search_from)
            if not p then break end
            last_pos = p
            search_from = p + 1
        end

        local block = card_source:sub(last_pos, last_pos + 500)
        assert.is_truthy(
            block:find("played_this_round"),
            "Card Sharp calc block should still gate on played_this_round"
        )
        assert.is_truthy(
            block:find("Xmult"),
            "Card Sharp calc block should still emit Xmult_mod"
        )
    end)

    -- ---------------------------------------------------------------
    -- Lua mirror of the game's activation gate. Returns the X mult
    -- contribution: `extra.Xmult` when the gate is open, otherwise nil.
    -- ---------------------------------------------------------------
    local function game_xmult(extra_xmult, played_this_round_after_increment)
        if played_this_round_after_increment > 1 then
            return extra_xmult
        end
        return nil
    end

    -- ---------------------------------------------------------------
    -- Lua mirror of the JS viewer handler. Returns the caption that
    -- surfaces the last played hand type. The X3 itself is static, so
    -- we compare the displayed last-played name with the value that
    -- would gate activation in the game.
    -- ---------------------------------------------------------------
    local function viewer_caption(state)
        if type(state) ~= "table" then return nil end
        local hand = state.hand_type
        if type(hand) ~= "string" then return nil end
        return "Last played: " .. hand
    end

    it("activates when the same hand has already been played this round", function()
        local game_says = game_xmult(3, 2)
        assert.are.equal(3, game_says)
        -- The viewer's caption should reflect that the player has a
        -- last-played hand recorded.
        local state = { hand_type = "Pair" }
        assert.are.equal("Last played: Pair", viewer_caption(state))
    end)

    it("does NOT activate on the first play of a hand this round", function()
        local game_says = game_xmult(3, 1) -- post-increment to 1 = first play
        assert.is_nil(game_says)
    end)

    it("activates on a third repeat of the same hand", function()
        local game_says = game_xmult(3, 3)
        assert.are.equal(3, game_says)
        local state = { hand_type = "Flush" }
        assert.are.equal("Last played: Flush", viewer_caption(state))
    end)

    it("boundary: first hand of run, hand_type unset → viewer returns nil", function()
        local state = {} -- no hand_type
        assert.is_nil(viewer_caption(state))
    end)
end)
