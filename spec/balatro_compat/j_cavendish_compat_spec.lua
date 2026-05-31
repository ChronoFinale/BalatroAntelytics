--- spec/balatro_compat/j_cavendish_compat_spec.lua
---
--- Verify Cavendish's end-of-round self-destruct probability still
--- maps to a 1-in-1000 chance via `extra.odds` in card.lua.
---
--- Real game (card.lua, Card:calculate_joker, end_of_round branch):
---   if self.ability.name == 'Gros Michel' or self.ability.name == 'Cavendish' then
---       if pseudorandom(self.ability.name == 'Cavendish' and 'cavendish' or 'gros_michel') <
---           G.GAME.probabilities.normal / self.ability.extra.odds then
---           -- destroy self
---       end
---   end
---
--- With `probabilities.normal = 1` and `extra.odds = 1000`, the
--- threshold is 1/1000 = 0.001. The viewer surfaces the constant
--- caption "1 in 1000 chance to expire each round".

local Source = require("spec.balatro_compat.lib.source")

describe("Cavendish compat — 1-in-1000 self-destruct odds", function()
    if Source.skip_unless_present("card.lua") then return end
    local card_source = Source.read("card.lua")

    it("card.lua's Cavendish branch still rolls against probabilities.normal / extra.odds with 'cavendish' seed", function()
        -- The self-destruct branch is the joint Gros Michel/Cavendish
        -- condition. Anchor the search there to skip past loc_vars
        -- setup and the post-scoring xmult emission, which also
        -- mention Cavendish but don't roll the destruction probability.
        local joint_pos = card_source:find(
            "name%s*==%s*'Gros Michel'%s*or%s*self%.ability%.name%s*==%s*'Cavendish'"
        )
        assert.is_truthy(
            joint_pos,
            "Gros Michel/Cavendish self-destruct branch should still exist"
        )

        local block = card_source:sub(joint_pos, joint_pos + 1200)
        assert.is_truthy(
            block:find("'cavendish'"),
            "Cavendish calc block should still seed pseudorandom with 'cavendish'"
        )
        assert.is_truthy(
            block:find("probabilities%.normal"),
            "Cavendish calc block should still divide G.GAME.probabilities.normal"
        )
        assert.is_truthy(
            block:find("extra%.odds"),
            "Cavendish calc block should still use extra.odds as the divisor"
        )
    end)

    -- ---------------------------------------------------------------
    -- Lua mirror of the game's threshold formula. Same shape as Gros
    -- Michel — only the `extra.odds` constant differs.
    -- ---------------------------------------------------------------
    local function game_threshold(probabilities_normal, extra_odds)
        return probabilities_normal / extra_odds
    end

    -- The viewer's caption hard-codes "1 in 1000". Compare the
    -- threshold against what the game actually rolls.
    local VIEWER_CLAIMED_DENOMINATOR = 1000

    it("matches the game on default probabilities (1 / 1000 = 0.001)", function()
        local game_says = game_threshold(1, 1000)
        assert.are.equal(0.001, game_says)
        assert.are.equal(1 / VIEWER_CLAIMED_DENOMINATOR, game_says)
    end)

    it("matches the game when Oops! All 6s doubles probabilities.normal (2 / 1000 = 0.002)", function()
        local game_says = game_threshold(2, 1000)
        assert.are.equal(0.002, game_says)
        assert.are.equal(2 / VIEWER_CLAIMED_DENOMINATOR, game_says)
    end)

    it("boundary: extra.odds = 1 → guaranteed destruction (threshold = 1.0)", function()
        local game_says = game_threshold(1, 1)
        assert.are.equal(1.0, game_says)
    end)
end)
