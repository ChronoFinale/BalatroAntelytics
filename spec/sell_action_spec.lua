--- spec/sell_action_spec.lua
--- Unit tests for lib/sell_action.lua — the helper that turns a sold
--- card into either a `sell_joker` or `sell_consumable` action payload.
---
--- Background: the previous capture path emitted only `sell_joker` for
--- every sale, which misattributed sold consumables to the Joker_Strip
--- in the viewer (Requirement 24). This spec pins the new shape.

local SellAction = assert(loadfile("lib/sell_action.lua"))()

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

--- Build a fake card whose `ability.set` and identity fields can be set
--- per test. Mirrors the minimum surface the real Balatro card object
--- exposes through `Capture.describe_card` (id, name, set, edition,
--- sell_value).
local function fake_card(opts)
    opts = opts or {}
    local center = {
        key  = opts.id   or "c_unknown",
        name = opts.name or "Unknown Card",
    }
    local card = {
        config    = { center = center },
        ability   = { name = opts.name or "Unknown Card" },
        sell_cost = opts.sell_value or 3,
    }
    if opts.set ~= nil then card.ability.set = opts.set end
    if opts.no_ability then card.ability = nil end
    if opts.edition then card.edition = opts.edition end
    return card
end

--- A stub Capture module that mirrors the real Capture.describe_card's
--- public contract (id, name, set, edition, sell_value, ...). We don't
--- pull in lib/capture.lua here because it requires a `G` global to be
--- mocked — and SellAction only needs `describe_card`.
local Capture = {}
function Capture.describe_card(card)
    local description = {
        id          = "unknown",
        name        = "Unknown",
        set         = "unknown",
        edition     = "base",
        sell_value  = 0,
    }
    if type(card) ~= "table" then return description end

    local center = card.config and card.config.center or nil
    if center and center.key  then description.id   = tostring(center.key)  end
    if center and center.name then description.name = tostring(center.name) end
    if card.ability and card.ability.name then
        description.name = tostring(card.ability.name)
    end
    if card.ability and card.ability.set then
        description.set = tostring(card.ability.set)
    end
    if card.sell_cost then description.sell_value = card.sell_cost end
    if card.edition then
        if type(card.edition) == "table" then
            if     card.edition.foil       then description.edition = "foil"
            elseif card.edition.holo       then description.edition = "holographic"
            elseif card.edition.polychrome then description.edition = "polychrome"
            elseif card.edition.negative   then description.edition = "negative"
            end
        elseif type(card.edition) == "string" then
            description.edition = card.edition
        end
    end
    return description
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("SellAction.build", function()

    -- ----------------------------------------------------------------------
    -- Joker branch — the existing shape must remain unchanged so the
    -- viewer's Joker_Strip stamp logic keeps working.
    -- ----------------------------------------------------------------------
    it("emits sell_joker for a Joker card with the correct fields", function()
        local card = fake_card{
            id   = "j_blueprint",
            name = "Blueprint",
            set  = "Joker",
            sell_value = 5,
            edition = { polychrome = true },
        }

        local action = SellAction.build(card, Capture)

        assert.are.equal("sell_joker",  action.type)
        assert.are.equal("j_blueprint", action.joker_id)
        assert.are.equal("Blueprint",   action.joker_name)
        assert.are.equal("polychrome",  action.edition)
        assert.are.equal(5,             action.sell_value)
        assert.is_table(action.description)

        -- A Joker sale must NOT carry consumable_* fields — the viewer
        -- stamps the consumable row from those fields, so a stray one
        -- here would double-stamp.
        assert.is_nil(action.consumable_id)
        assert.is_nil(action.consumable_name)
        assert.is_nil(action.consumable_set)
    end)

    -- ----------------------------------------------------------------------
    -- Consumable branch — Tarot, Planet, Spectral, Consumeables all get
    -- the same `sell_consumable` shape with consumable_set carrying the
    -- specific kind.
    -- ----------------------------------------------------------------------
    it("emits sell_consumable for a Tarot card", function()
        local card = fake_card{
            id   = "c_hermit",
            name = "The Hermit",
            set  = "Tarot",
            sell_value = 1,
        }

        local action = SellAction.build(card, Capture)

        assert.are.equal("sell_consumable", action.type)
        assert.are.equal("c_hermit",        action.consumable_id)
        assert.are.equal("The Hermit",      action.consumable_name)
        assert.are.equal("Tarot",           action.consumable_set)
        assert.are.equal(1,                 action.sell_value)
        assert.is_table(action.description)

        -- A consumable sale must NOT carry joker_* fields.
        assert.is_nil(action.joker_id)
        assert.is_nil(action.joker_name)
    end)

    it("emits sell_consumable for a Planet card", function()
        local card = fake_card{
            id   = "c_jupiter",
            name = "Jupiter",
            set  = "Planet",
            sell_value = 1,
        }

        local action = SellAction.build(card, Capture)

        assert.are.equal("sell_consumable", action.type)
        assert.are.equal("c_jupiter",       action.consumable_id)
        assert.are.equal("Planet",          action.consumable_set)
    end)

    it("emits sell_consumable for a Spectral card", function()
        local card = fake_card{
            id   = "c_aura",
            name = "Aura",
            set  = "Spectral",
            sell_value = 2,
        }

        local action = SellAction.build(card, Capture)

        assert.are.equal("sell_consumable", action.type)
        assert.are.equal("c_aura",          action.consumable_id)
        assert.are.equal("Spectral",        action.consumable_set)
    end)

    it("emits sell_consumable for a card tagged with the umbrella Consumeables set", function()
        -- "Consumeables" is the in-game spelling Balatro uses for the
        -- generic consumable area. Negative consumables created by
        -- Perkeo show up under this set rather than the specific Tarot
        -- / Planet / Spectral type.
        local card = fake_card{
            id   = "c_negative_thing",
            name = "Negative Consumable",
            set  = "Consumeables",
            sell_value = 4,
        }

        local action = SellAction.build(card, Capture)

        assert.are.equal("sell_consumable", action.type)
        assert.are.equal("Consumeables",    action.consumable_set)
    end)

    -- ----------------------------------------------------------------------
    -- Fallback branches — anything we don't recognize stays a sell_joker
    -- so existing replays remain renderable. Voucher is the canonical
    -- "weird sell" case (vouchers can't actually be sold today, but a
    -- modded card might surface here).
    -- ----------------------------------------------------------------------
    it("falls back to sell_joker for an unrecognized set (Voucher)", function()
        local card = fake_card{
            id   = "v_overstock",
            name = "Overstock",
            set  = "Voucher",
            sell_value = 0,
        }

        local action = SellAction.build(card, Capture)

        assert.are.equal("sell_joker", action.type)
        assert.are.equal("v_overstock", action.joker_id)
        assert.are.equal("Overstock",   action.joker_name)
        assert.is_nil(action.consumable_id)
    end)

    it("falls back to sell_joker when the card has no ability.set at all", function()
        local card = fake_card{ id = "j_unknown", name = "Mystery", no_ability = true }

        local action = SellAction.build(card, Capture)

        assert.are.equal("sell_joker", action.type)
        assert.are.equal("j_unknown",  action.joker_id)
        assert.is_nil(action.consumable_id)
    end)
end)
