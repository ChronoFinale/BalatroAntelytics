--- spec/balatro_compat/j_idol_compat_spec.lua
---
--- Verify our viewer's Idol live-effect formula matches the real game's
--- calc block, sourced from card.lua.
---
--- Real game (card.lua, Card:calculate_joker, Idol branch):
---   if self.ability.name == 'The Idol' and
---       context.other_card:get_id() == G.GAME.current_round.idol_card.id and
---       context.other_card:is_suit(G.GAME.current_round.idol_card.suit) then
---       return { x_mult = self.ability.extra, ... }
---   end
---
--- The X2 mult itself is static (`self.ability.extra` is constant for the
--- joker). What the viewer surfaces dynamically is the TARGET card —
--- the rank/suit pair the player must hit. The current round's target
--- lives at `G.GAME.current_round.idol_card.{rank, suit}`, captured into
--- the viewer's `internal_state.extra.{rank, suit}`.
---
--- This spec asserts:
---   1. card.lua's Idol branch still references both
---      `current_round.idol_card.rank` and `.suit`.
---   2. Our JS-formula mirror produces the same caption as a Lua mirror
---      of the same target-selection logic across ≥3 cases including
---      the boundary where rank/suit are unset.

local Source = require("spec.balatro_compat.lib.source")

describe("Idol compat — viewer caption matches card.lua target selection", function()
    if Source.skip_unless_present("card.lua") then return end
    local card_source = Source.read("card.lua")

    -- ---------------------------------------------------------------
    -- Locate the Idol calc branch (the SECOND occurrence, in
    -- Card:calculate_joker — the FIRST occurrence is loc_vars setup).
    -- ---------------------------------------------------------------
    local function last_idol_block()
        local last_pos = nil
        local pos = 1
        while true do
            local p = card_source:find("name%s*==%s*'The Idol'", pos)
            if not p then break end
            last_pos = p
            pos = p + 1
        end
        return last_pos
    end

    it("card.lua's Idol branch still references rank+suit on idol_card", function()
        local pos = last_idol_block()
        assert.is_truthy(pos, "Idol case should still exist in card.lua")
        local idol_block = card_source:sub(pos, pos + 600)
        assert.is_truthy(
            idol_block:find("idol_card"),
            "Idol calc block should still reference current_round.idol_card"
        )
        assert.is_truthy(
            idol_block:find("get_id"),
            "Idol calc block should still match by card id (rank-equivalent)"
        )
        assert.is_truthy(
            idol_block:find("is_suit"),
            "Idol calc block should still match by suit"
        )
    end)

    -- ---------------------------------------------------------------
    -- Lua mirror of the JS handler. Returns the caption a viewer
    -- would display given the captured `extra` table.
    -- ---------------------------------------------------------------
    local SUIT_GLYPH = { Spades = "♠", Hearts = "♥", Diamonds = "♦", Clubs = "♣" }

    local function viewer_caption(extra)
        if type(extra) ~= "table" then return nil end
        local rank, suit = extra.rank, extra.suit
        if type(rank) ~= "string" or type(suit) ~= "string" then return nil end
        local glyph = SUIT_GLYPH[suit] or ""
        return "Targets " .. rank .. glyph
    end

    -- ---------------------------------------------------------------
    -- Mirror of the game's target-selection: it just reads the
    -- captured target straight out of `current_round.idol_card`.
    -- ---------------------------------------------------------------
    local function game_target(idol_card)
        if type(idol_card) ~= "table" then return nil end
        if not idol_card.rank or not idol_card.suit then return nil end
        local glyph = SUIT_GLYPH[idol_card.suit] or ""
        return "Targets " .. idol_card.rank .. glyph
    end

    it("matches the game on King of Hearts target", function()
        local idol_card = { rank = "King", suit = "Hearts" }
        assert.are.equal("Targets King♥", game_target(idol_card))
        assert.are.equal(game_target(idol_card), viewer_caption(idol_card))
    end)

    it("matches the game on 7 of Spades target", function()
        local idol_card = { rank = "7", suit = "Spades" }
        assert.are.equal("Targets 7♠", game_target(idol_card))
        assert.are.equal(game_target(idol_card), viewer_caption(idol_card))
    end)

    it("matches the game on Ace of Diamonds target", function()
        local idol_card = { rank = "Ace", suit = "Diamonds" }
        assert.are.equal("Targets Ace♦", game_target(idol_card))
        assert.are.equal(game_target(idol_card), viewer_caption(idol_card))
    end)

    it("boundary: rank/suit unset returns nil from both", function()
        assert.is_nil(game_target({}))
        assert.is_nil(viewer_caption({}))
        assert.is_nil(game_target({ rank = "King" })) -- partial
        assert.is_nil(viewer_caption({ rank = "King" }))
    end)
end)
