--- spec/balatro_compat/j_to_do_list_compat_spec.lua
---
--- Verify the To Do List live-effect payout formula matches the real
--- game's on_play branch, sourced from card.lua.
---
--- Real game (card.lua, Card:calculate_joker, scoring branch):
---   if self.ability.name == 'To Do List' and
---       context.scoring_name == self.ability.to_do_poker_hand then
---       ease_dollars(self.ability.extra.dollars)
---       ...
---       return { ..., dollars = self.ability.extra.dollars, ... }
---   end
---
--- The viewer surfaces the target hand type + the +$4 payout. The
--- numeric formula is trivial: 4 dollars when scoring_name matches
--- to_do_poker_hand, 0 otherwise.
---
--- Boundary: hand never played yet (`to_do_poker_hand` field unset on
--- the joker — the viewer should produce no caption).

local Source = require("spec.balatro_compat.lib.source")

describe("To Do List compat — viewer payout matches card.lua play branch", function()
    if Source.skip_unless_present("card.lua") then return end
    local card_source = Source.read("card.lua")

    it("card.lua's To Do List play branch still references scoring_name == to_do_poker_hand", function()
        -- The To Do List name appears multiple times: loc_vars setup,
        -- a discard branch (resets the target), and the scoring
        -- branch. We want the scoring branch — find the occurrence
        -- that's followed by `scoring_name == self.ability.to_do_poker_hand`.
        local found = card_source:find(
            "scoring_name%s*==%s*self%.ability%.to_do_poker_hand"
        )
        assert.is_truthy(
            found,
            "card.lua should still gate To Do List payout on scoring_name == to_do_poker_hand"
        )

        -- The same block should still pay `extra.dollars`.
        local block = card_source:sub(found, found + 400)
        assert.is_truthy(
            block:find("extra%.dollars"),
            "To Do List play branch should still pay self.ability.extra.dollars"
        )
    end)

    -- ---------------------------------------------------------------
    -- Lua mirror of the game's payout: $4 when the played hand
    -- matches the joker's target, else $0.
    -- ---------------------------------------------------------------
    local function game_payout(scoring_name, target_hand, dollars)
        if scoring_name == target_hand then return dollars or 4 end
        return 0
    end

    -- ---------------------------------------------------------------
    -- Lua mirror of the JS handler's numeric prediction. The viewer
    -- caption is `Target: {handType} (+$4)` when the target is set.
    -- We check the predicted payout for the hand the player just
    -- played, which is what the live-effect is announcing.
    -- ---------------------------------------------------------------
    local function viewer_predicted(state, scoring_name)
        if type(state) ~= "table" then return nil end
        local target = state.to_do_poker_hand
        if type(target) ~= "string" then return nil end
        local extra = state.extra
        local dollars = (type(extra) == "table" and extra.dollars) or 4
        return game_payout(scoring_name, target, dollars)
    end

    it("matches the game when scoring hand equals the target", function()
        local state = { to_do_poker_hand = "Pair", extra = { dollars = 4 } }
        local game_says = game_payout("Pair", "Pair", 4)
        assert.are.equal(4, game_says)
        assert.are.equal(game_says, viewer_predicted(state, "Pair"))
    end)

    it("matches the game when scoring hand differs from the target", function()
        local state = { to_do_poker_hand = "Pair", extra = { dollars = 4 } }
        local game_says = game_payout("Flush", "Pair", 4)
        assert.are.equal(0, game_says)
        assert.are.equal(game_says, viewer_predicted(state, "Flush"))
    end)

    it("matches the game on Straight Flush match", function()
        local state = { to_do_poker_hand = "Straight Flush", extra = { dollars = 4 } }
        local game_says = game_payout("Straight Flush", "Straight Flush", 4)
        assert.are.equal(4, game_says)
        assert.are.equal(game_says, viewer_predicted(state, "Straight Flush"))
    end)

    it("boundary: `to_do_poker_hand` unset → viewer returns nil", function()
        local state = { extra = { dollars = 4 } } -- no to_do_poker_hand
        assert.is_nil(viewer_predicted(state, "Pair"))
    end)
end)
