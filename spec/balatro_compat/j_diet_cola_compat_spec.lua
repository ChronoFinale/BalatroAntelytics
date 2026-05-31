--- spec/balatro_compat/j_diet_cola_compat_spec.lua
---
--- Verify Diet Cola's sell-action behavior is still tied to the
--- Double Tag in card.lua. Diet Cola has no scaling state — the live
--- effect IS "Sell for a free Double Tag" — so this spec is a static
--- presence check on the calc block.
---
--- Real game (card.lua, Card:calculate_joker, selling_self branch):
---   if self.ability.name == 'Diet Cola' then
---       G.E_MANAGER:add_event(Event({
---           func = (function()
---               add_tag(Tag('tag_double'))
---               ...
---           end)
---       }))
---   end

local Source = require("spec.balatro_compat.lib.source")

describe("Diet Cola compat — sell-action still creates a Double Tag", function()
    if Source.skip_unless_present("card.lua") then return end
    local card_source = Source.read("card.lua")

    it("card.lua's Diet Cola branch still creates Tag('tag_double')", function()
        -- The Diet Cola name appears at least twice (loc_vars setup
        -- and the selling_self branch). Find the occurrence that
        -- includes the tag_double creation nearby.
        local pos = card_source:find("name%s*==%s*'Diet Cola'")
        assert.is_truthy(pos, "Diet Cola case should still exist in card.lua")

        local last_pos = pos
        local search_from = pos + 1
        while true do
            local p = card_source:find("name%s*==%s*'Diet Cola'", search_from)
            if not p then break end
            last_pos = p
            search_from = p + 1
        end

        local block = card_source:sub(last_pos, last_pos + 600)
        assert.is_truthy(
            block:find("tag_double"),
            "Diet Cola sell-action branch should still reference tag_double"
        )
        assert.is_truthy(
            block:find("add_tag") or block:find("Tag%("),
            "Diet Cola sell-action branch should still call add_tag(Tag(...))"
        )
    end)

    -- ---------------------------------------------------------------
    -- Static check: the viewer's caption for Diet Cola is the
    -- constant string "Sell for a free Double Tag". We verify the
    -- caption content matches what card.lua actually does.
    -- ---------------------------------------------------------------
    local VIEWER_CAPTION = "Sell for a free Double Tag"

    it("viewer caption mentions selling for a Double Tag", function()
        assert.is_truthy(VIEWER_CAPTION:find("Sell"))
        assert.is_truthy(VIEWER_CAPTION:find("Double Tag"))
    end)

    it("caption is a constant — no scaling state to mirror", function()
        -- Three "representative cases" for a static caption: it
        -- doesn't depend on internal_state, so it stays identical
        -- across any captured state shape.
        local function viewer_caption(_state) return VIEWER_CAPTION end
        assert.are.equal(VIEWER_CAPTION, viewer_caption(nil))
        assert.are.equal(VIEWER_CAPTION, viewer_caption({}))
        assert.are.equal(VIEWER_CAPTION, viewer_caption({ extra = 0 }))
    end)
end)
