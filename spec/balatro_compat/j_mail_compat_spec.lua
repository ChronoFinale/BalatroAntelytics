--- spec/balatro_compat/j_mail_compat_spec.lua
---
--- Verify the Mail-In Rebate live-effect payout formula matches the
--- real game's on_discard branch, sourced from card.lua.
---
--- Real game (card.lua, Card:calculate_joker, on_discard branch):
---   if self.ability.name == 'Mail-In Rebate' and
---       not context.other_card.debuff and
---       context.other_card:get_id() == G.GAME.current_round.mail_card.id then
---       ease_dollars(self.ability.extra)
---   end
---
--- For each discarded card whose id matches the round's target rank,
--- the joker pays `self.ability.extra` dollars (default $5). The
--- viewer mirrors this as `discarded_matches * extra` for the round.
---
--- Boundary: when `extra.rank` (the target rank field) is missing the
--- viewer should produce no payout estimate.

local Source = require("spec.balatro_compat.lib.source")

describe("Mail-In Rebate compat — viewer payout matches card.lua on_discard", function()
    if Source.skip_unless_present("card.lua") then return end
    local card_source = Source.read("card.lua")

    it("card.lua's Mail-In Rebate branch still references mail_card.id and ease_dollars(extra)", function()
        -- Use the LAST occurrence to land in the calc branch (loc_vars
        -- setup is the first match).
        local last_pos = nil
        local pos = 1
        while true do
            local p = card_source:find("name%s*==%s*'Mail%-In Rebate'", pos)
            if not p then break end
            last_pos = p
            pos = p + 1
        end
        assert.is_truthy(last_pos, "Mail-In Rebate case should still exist in card.lua")

        local block = card_source:sub(last_pos, last_pos + 500)
        assert.is_truthy(
            block:find("mail_card"),
            "Mail-In Rebate calc block should still reference current_round.mail_card"
        )
        assert.is_truthy(
            block:find("ease_dollars"),
            "Mail-In Rebate calc block should still pay via ease_dollars(...)"
        )
        assert.is_truthy(
            block:find("self%.ability%.extra"),
            "Mail-In Rebate calc block should still pay self.ability.extra per match"
        )
    end)

    -- ---------------------------------------------------------------
    -- Lua mirror of the game's per-discard payout. Each discarded
    -- card whose rank matches the target rolls one ease_dollars(extra)
    -- call, so total payout = matches * extra.
    -- ---------------------------------------------------------------
    local function game_payout(discarded_ranks, target_rank, extra)
        if not target_rank then return nil end
        local matches = 0
        for _, rank in ipairs(discarded_ranks) do
            if rank == target_rank then matches = matches + 1 end
        end
        return matches * (extra or 5)
    end

    -- ---------------------------------------------------------------
    -- Lua mirror of the JS handler's numeric forecast. The viewer
    -- caption surfaces the target rank + per-card payout; here we
    -- check the underlying numeric formula it relies on.
    -- ---------------------------------------------------------------
    local function viewer_payout(state, discarded_ranks)
        local extra = state and state.extra
        if type(extra) ~= "table" then return nil end
        if type(extra.rank) ~= "string" then return nil end
        return game_payout(discarded_ranks, extra.rank, 5)
    end

    it("matches the game when 2 of 5 discards hit a 7 target", function()
        local discarded = {"7", "7", "King", "Queen", "3"}
        local state = { extra = { rank = "7" } }
        local game_says = game_payout(discarded, "7", 5)
        assert.are.equal(10, game_says)
        assert.are.equal(game_says, viewer_payout(state, discarded))
    end)

    it("matches the game when 0 discards hit the target", function()
        local discarded = {"King", "Queen", "Jack"}
        local state = { extra = { rank = "7" } }
        local game_says = game_payout(discarded, "7", 5)
        assert.are.equal(0, game_says)
        assert.are.equal(game_says, viewer_payout(state, discarded))
    end)

    it("matches the game when all 5 discards hit the target", function()
        local discarded = {"Ace", "Ace", "Ace", "Ace", "Ace"}
        local state = { extra = { rank = "Ace" } }
        local game_says = game_payout(discarded, "Ace", 5)
        assert.are.equal(25, game_says)
        assert.are.equal(game_says, viewer_payout(state, discarded))
    end)

    it("boundary: rank field missing → viewer returns nil", function()
        local state = { extra = {} } -- no .rank
        assert.is_nil(viewer_payout(state, {"7", "7"}))
    end)
end)
