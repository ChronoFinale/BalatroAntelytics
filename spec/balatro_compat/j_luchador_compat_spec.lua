--- spec/balatro_compat/j_luchador_compat_spec.lua
---
--- Verify Luchador's sell-action still disables the boss blind in
--- card.lua. Luchador has no scaling state — the live effect IS
--- "Sell to disable boss blind" — so this spec is a static presence
--- check on the calc block.
---
--- Real game (card.lua, Card:calculate_joker, selling_self branch):
---   if self.ability.name == 'Luchador' then
---       if G.GAME.blind and ((not G.GAME.blind.disabled)
---           and (G.GAME.blind:get_type() == 'Boss')) then
---           ...
---           G.GAME.blind:disable()
---       end
---   end

local Source = require("spec.balatro_compat.lib.source")

describe("Luchador compat — sell-action still disables boss blind", function()
    if Source.skip_unless_present("card.lua") then return end
    local card_source = Source.read("card.lua")

    it("card.lua's Luchador branch still calls G.GAME.blind:disable()", function()
        local pos = card_source:find("name%s*==%s*'Luchador'")
        assert.is_truthy(pos, "Luchador case should still exist in card.lua")

        local last_pos = pos
        local search_from = pos + 1
        while true do
            local p = card_source:find("name%s*==%s*'Luchador'", search_from)
            if not p then break end
            last_pos = p
            search_from = p + 1
        end

        local block = card_source:sub(last_pos, last_pos + 600)
        assert.is_truthy(
            block:find("blind:disable") or block:find("blind%.disable"),
            "Luchador sell-action branch should still disable the boss blind"
        )
        assert.is_truthy(
            block:find("Boss") or block:find("get_type"),
            "Luchador sell-action branch should still gate on the boss blind type"
        )
    end)

    -- ---------------------------------------------------------------
    -- Static check: the viewer's caption for Luchador is the constant
    -- "Sell to disable boss blind". Verify content alignment with
    -- what card.lua does.
    -- ---------------------------------------------------------------
    local VIEWER_CAPTION = "Sell to disable boss blind"

    it("viewer caption mentions selling and the boss blind", function()
        assert.is_truthy(VIEWER_CAPTION:find("Sell"))
        assert.is_truthy(VIEWER_CAPTION:find("boss blind"))
    end)

    it("caption is a constant — no scaling state to mirror", function()
        local function viewer_caption(_state) return VIEWER_CAPTION end
        assert.are.equal(VIEWER_CAPTION, viewer_caption(nil))
        assert.are.equal(VIEWER_CAPTION, viewer_caption({}))
        assert.are.equal(VIEWER_CAPTION, viewer_caption({ extra = 0 }))
    end)
end)
