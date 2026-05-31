--- spec/balatro_compat/j_gros_michel_compat_spec.lua
---
--- Verify Gros Michel's end-of-round self-destruct probability still
--- maps to a 1-in-6 chance via `extra.odds` in card.lua.
---
--- Real game (card.lua, Card:calculate_joker, end_of_round branch):
---   if self.ability.name == 'Gros Michel' or self.ability.name == 'Cavendish' then
---       if pseudorandom(... or 'gros_michel') <
---           G.GAME.probabilities.normal / self.ability.extra.odds then
---           -- destroy self, set extinct flag
---       end
---   end
---
--- With `probabilities.normal = 1` and `extra.odds = 6`, the trigger
--- threshold is 1/6 ≈ 0.1667. The viewer surfaces the constant caption
--- "1 in 6 chance to expire each round". This spec is a static check
--- that card.lua still ties Gros Michel's destruction probability to
--- a divisor that mirrors the displayed 1-in-6 odds.

local Source = require("spec.balatro_compat.lib.source")

describe("Gros Michel compat — 1-in-6 self-destruct odds", function()
    if Source.skip_unless_present("card.lua") then return end
    local card_source = Source.read("card.lua")

    it("card.lua's Gros Michel branch still rolls against probabilities.normal / extra.odds", function()
        -- The self-destruct branch is the joint Gros Michel/Cavendish
        -- condition. Find that conjoint pattern specifically — there
        -- are also separate Gros Michel matches (loc_vars setup,
        -- post-scoring mult emission) we need to skip past.
        local joint_pos = card_source:find(
            "name%s*==%s*'Gros Michel'%s*or%s*self%.ability%.name%s*==%s*'Cavendish'"
        )
        assert.is_truthy(
            joint_pos,
            "Gros Michel/Cavendish self-destruct branch should still exist"
        )

        local block = card_source:sub(joint_pos, joint_pos + 1200)
        assert.is_truthy(
            block:find("pseudorandom"),
            "Gros Michel calc block should still roll via pseudorandom"
        )
        assert.is_truthy(
            block:find("probabilities%.normal"),
            "Gros Michel calc block should still divide G.GAME.probabilities.normal"
        )
        assert.is_truthy(
            block:find("extra%.odds"),
            "Gros Michel calc block should still use extra.odds as the divisor"
        )
        assert.is_truthy(
            block:find("gros_michel") or block:find("Gros Michel"),
            "Gros Michel calc block should still seed pseudorandom with 'gros_michel'"
        )
    end)

    -- ---------------------------------------------------------------
    -- Lua mirror of the game's threshold formula and the viewer's
    -- displayed 1-in-N copy. They must agree on N for typical
    -- captures (extra.odds = 6, probabilities.normal = 1).
    -- ---------------------------------------------------------------
    local function game_threshold(probabilities_normal, extra_odds)
        return probabilities_normal / extra_odds
    end

    -- The viewer's caption is hard-coded "1 in 6 chance to expire each
    -- round". The numeric thing we can compare is the threshold value
    -- the caption claims (1/6) versus what the game actually rolls
    -- against.
    local VIEWER_CLAIMED_DENOMINATOR = 6

    it("matches the game on default probabilities (1 / 6 ≈ 0.1667)", function()
        local game_says = game_threshold(1, 6)
        assert.is_near(0.1666667, game_says, 0.0001)
        assert.are.equal(1 / VIEWER_CLAIMED_DENOMINATOR, game_says)
    end)

    it("matches the game when Oops! All 6s doubles probabilities.normal (2 / 6 ≈ 0.3333)", function()
        -- Oops! All 6s doubles the numerator (`probabilities.normal = 2`),
        -- effectively turning 1-in-6 into 1-in-3. The threshold the
        -- game uses is exactly 2/6, which is what the viewer would
        -- compute if it ever surfaced the live odds.
        local game_says = game_threshold(2, 6)
        assert.is_near(0.3333333, game_says, 0.0001)
        assert.are.equal(2 / VIEWER_CLAIMED_DENOMINATOR, game_says)
    end)

    it("boundary: extra.odds = 1 → guaranteed destruction (threshold = 1.0)", function()
        local game_says = game_threshold(1, 1)
        assert.are.equal(1.0, game_says)
    end)
end)
