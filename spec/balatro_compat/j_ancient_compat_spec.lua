--- spec/balatro_compat/j_ancient_compat_spec.lua
---
--- Verify the Ancient Joker live-effect caption formula matches the
--- real game's on_scored branch, sourced from card.lua.
---
--- Real game (card.lua, Card:calculate_joker, individual on G.play):
---   if self.ability.name == 'Ancient Joker' and
---   context.other_card:is_suit(G.GAME.current_round.ancient_card.suit) then
---       return { x_mult = self.ability.extra, card = self }
---   end
---
--- Each round, Ancient Joker picks a random suit (G.GAME.current_round
--- .ancient_card.suit). When a card of that suit is played and scored,
--- the joker contributes self.ability.extra as Xmult.
---
--- The viewer's `j_ancient` handler surfaces the target suit so the
--- player can see "Target suit: Hearts ♥". The Xmult value lives in
--- the badge (read via badgeFor → joker.internal_state.x_mult).
---
--- Boundary: when the suit field is missing the viewer should surface
--- no caption (the static description already explains the joker).

local Source = require("spec.balatro_compat.lib.source")

describe("Ancient Joker compat — viewer caption matches card.lua on_scored", function()
    if Source.skip_unless_present("card.lua") then return end
    local card_source = Source.read("card.lua")

    it("card.lua's Ancient Joker branch still references ancient_card.suit and x_mult", function()
        -- The calc branch is the second occurrence (first is loc_vars setup).
        local last_pos = nil
        local pos = 1
        while true do
            local p = card_source:find("name%s*==%s*'Ancient Joker'", pos)
            if not p then break end
            last_pos = p
            pos = p + 1
        end
        assert.is_truthy(last_pos, "Ancient Joker case should still exist in card.lua")

        local block = card_source:sub(last_pos, last_pos + 400)
        assert.is_truthy(
            block:find("ancient_card"),
            "Ancient Joker calc block should still reference current_round.ancient_card"
        )
        assert.is_truthy(
            block:find("is_suit"),
            "Ancient Joker calc block should still match by suit"
        )
        assert.is_truthy(
            block:find("x_mult"),
            "Ancient Joker calc block should still emit x_mult"
        )
        assert.is_truthy(
            block:find("self%.ability%.extra"),
            "Ancient Joker calc block should still pay self.ability.extra as the Xmult"
        )
    end)

    -- ---------------------------------------------------------------
    -- Lua mirror of the game's per-scored-card check. The joker emits
    -- x_mult = extra once per matching-suit scored card.
    -- ---------------------------------------------------------------
    local function game_xmult_per_scored_card(scored_suits, target_suit, extra)
        if not target_suit then return {} end
        local out = {}
        for _, suit in ipairs(scored_suits) do
            if suit == target_suit then
                out[#out + 1] = extra
            end
        end
        return out
    end

    -- ---------------------------------------------------------------
    -- Lua mirror of the viewer's caption "Target suit: <Suit>". The
    -- handler reads `extra.suit` (or top-level `state.suit`) and
    -- formats with the suit glyph. Here we focus on the routing: the
    -- caption appears when a target suit is present, otherwise nil.
    -- ---------------------------------------------------------------
    local function viewer_caption_suit(state)
        if type(state) ~= "table" then return nil end
        local extra = state.extra
        if type(extra) == "table" and type(extra.suit) == "string" then return extra.suit end
        if type(state.suit) == "string" then return state.suit end
        return nil
    end

    local SUITS = { "Hearts", "Diamonds", "Spades", "Clubs" }

    for _, suit in ipairs(SUITS) do
        it("game pays x_mult per scored " .. suit .. " — viewer surfaces the same target", function()
            local scored = { "Hearts", suit, "Clubs", suit, "Diamonds" }
            local expected_matches = {}
            for _, s in ipairs(scored) do
                if s == suit then expected_matches[#expected_matches + 1] = 1.5 end
            end
            local game_says = game_xmult_per_scored_card(scored, suit, 1.5)
            assert.are.same(expected_matches, game_says)
            assert.are.equal(suit, viewer_caption_suit({ extra = { suit = suit } }))
        end)
    end

    it("game pays nothing when no scored card matches — viewer still surfaces the target", function()
        local scored = { "Hearts", "Hearts", "Hearts" }
        local game_says = game_xmult_per_scored_card(scored, "Clubs", 1.5)
        assert.are.equal(0, #game_says)
        assert.are.equal("Clubs", viewer_caption_suit({ extra = { suit = "Clubs" } }))
    end)

    it("boundary: suit field missing → viewer returns nil caption", function()
        assert.is_nil(viewer_caption_suit({ extra = {} }))
        assert.is_nil(viewer_caption_suit({}))
        assert.is_nil(viewer_caption_suit(nil))
    end)

    it("backward-compat: top-level state.suit also works as a target", function()
        assert.are.equal("Spades", viewer_caption_suit({ suit = "Spades" }))
    end)
end)
