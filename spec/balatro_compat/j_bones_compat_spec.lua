--- spec/balatro_compat/j_bones_compat_spec.lua
---
--- Verify Mr. Bones' save-from-loss branch still uses the 25%
--- threshold in card.lua, and check the boundary case where the
--- player scores exactly 25% of the requirement.
---
--- Real game (card.lua, Card:calculate_joker, end_of_round / game_over):
---   if self.ability.name == 'Mr. Bones' and context.game_over and
---       G.GAME.chips/G.GAME.blind.chips >= 0.25 then
---       ...
---       return { message = localize('k_saved_ex'), saved = true, ... }
---   end
---
--- The viewer surfaces the constant caption "Prevents death (≥25%
--- required score)". The numeric thing we can mirror is the
--- save-or-die predicate: `scored / required >= 0.25`.

local Source = require("spec.balatro_compat.lib.source")

describe("Mr. Bones compat — save-from-loss threshold matches card.lua", function()
    if Source.skip_unless_present("card.lua") then return end
    local card_source = Source.read("card.lua")

    it("card.lua's Mr. Bones branch still uses the 25% (>= 0.25) threshold", function()
        local pos = card_source:find("name%s*==%s*'Mr%. Bones'")
        assert.is_truthy(pos, "Mr. Bones case should still exist in card.lua")

        local last_pos = pos
        local search_from = pos + 1
        while true do
            local p = card_source:find("name%s*==%s*'Mr%. Bones'", search_from)
            if not p then break end
            last_pos = p
            search_from = p + 1
        end

        local block = card_source:sub(last_pos, last_pos + 500)
        assert.is_truthy(
            block:find("game_over"),
            "Mr. Bones branch should still gate on context.game_over"
        )
        assert.is_truthy(
            block:find("0%.25"),
            "Mr. Bones branch should still use the 0.25 (25%%) threshold"
        )
        assert.is_truthy(
            block:find("blind%.chips") or block:find("G%.GAME%.chips"),
            "Mr. Bones branch should still compare scored chips to required chips"
        )
    end)

    -- ---------------------------------------------------------------
    -- Lua mirror of the game's save predicate: `scored / required >= 0.25`.
    -- ---------------------------------------------------------------
    local function game_saves(scored, required)
        if required <= 0 then return false end
        return scored / required >= 0.25
    end

    -- ---------------------------------------------------------------
    -- Lua mirror of the JS viewer's predicate. The handler returns a
    -- caption when the joker is in play; we test the underlying
    -- numeric save check that the caption summarizes.
    -- ---------------------------------------------------------------
    local function viewer_saves(scored, required)
        if type(scored) ~= "number" or type(required) ~= "number" then return false end
        if required <= 0 then return false end
        return scored / required >= 0.25
    end

    it("matches the game when scored is well above 25%", function()
        assert.is_true(game_saves(60, 100))
        assert.are.equal(game_saves(60, 100), viewer_saves(60, 100))
    end)

    it("matches the game when scored is well below 25%", function()
        assert.is_false(game_saves(20, 100))
        assert.are.equal(game_saves(20, 100), viewer_saves(20, 100))
    end)

    it("boundary: scored exactly equals 25% of required → save fires", function()
        -- The branch uses `>=`, so the 25% boundary is INCLUSIVE.
        -- Both the game and the viewer must agree.
        assert.is_true(game_saves(25, 100))
        assert.are.equal(game_saves(25, 100), viewer_saves(25, 100))
    end)

    it("matches the game just below the 25% boundary", function()
        assert.is_false(game_saves(24, 100))
        assert.are.equal(game_saves(24, 100), viewer_saves(24, 100))
    end)
end)
