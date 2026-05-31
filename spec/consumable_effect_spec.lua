--- Tests for lib/consumable_effect.lua.

local ConsumableEffect = require("lib.consumable_effect")

describe("ConsumableEffect.predict_money_delta", function()
    before_each(function()
        _G.G = { GAME = { dollars = 10 }, jokers = { cards = {} } }
    end)

    after_each(function()
        _G.G = nil
    end)

    it("returns nil for non-table input", function()
        assert.is_nil(ConsumableEffect.predict_money_delta(nil))
        assert.is_nil(ConsumableEffect.predict_money_delta(42))
    end)

    it("returns nil for cards without ability", function()
        assert.is_nil(ConsumableEffect.predict_money_delta({}))
    end)

    it("Hermit doubles dollars capped at extra (default 20)", function()
        _G.G.GAME.dollars = 8
        local card = { ability = { name = "The Hermit", extra = 20 } }
        assert.are.equal(8, ConsumableEffect.predict_money_delta(card))
    end)

    it("Hermit caps at extra when wallet exceeds it", function()
        _G.G.GAME.dollars = 50
        local card = { ability = { name = "The Hermit", extra = 20 } }
        assert.are.equal(20, ConsumableEffect.predict_money_delta(card))
    end)

    it("Hermit returns 0 when wallet is 0", function()
        _G.G.GAME.dollars = 0
        local card = { ability = { name = "The Hermit", extra = 20 } }
        assert.are.equal(0, ConsumableEffect.predict_money_delta(card))
    end)

    it("Temperance uses ability.money when set", function()
        local card = { ability = { name = "Temperance", money = 17 } }
        assert.are.equal(17, ConsumableEffect.predict_money_delta(card))
    end)

    it("Temperance falls back to summing joker sell values", function()
        _G.G.jokers.cards = {
            { sell_cost = 3 }, { sell_cost = 5 }, { sell_cost = 2 },
        }
        local card = { ability = { name = "Temperance", extra = 50 } }
        assert.are.equal(10, ConsumableEffect.predict_money_delta(card))
    end)

    it("Temperance caps at $50 in vanilla", function()
        _G.G.jokers.cards = {}
        for i = 1, 30 do
            _G.G.jokers.cards[i] = { sell_cost = 5 }
        end
        local card = { ability = { name = "Temperance", extra = 50 } }
        assert.are.equal(50, ConsumableEffect.predict_money_delta(card))
    end)

    it("Wraith returns negative current dollars", function()
        _G.G.GAME.dollars = 24
        local card = { ability = { name = "Wraith" } }
        assert.are.equal(-24, ConsumableEffect.predict_money_delta(card))
    end)

    it("Immolate returns +20 by default", function()
        local card = { ability = { name = "Immolate" } }
        assert.are.equal(20, ConsumableEffect.predict_money_delta(card))
    end)

    it("Immolate honors extra.dollars when present", function()
        local card = { ability = { name = "Immolate", extra = { dollars = 25 } } }
        assert.are.equal(25, ConsumableEffect.predict_money_delta(card))
    end)

    it("returns nil for tarots without money effect", function()
        local card = { ability = { name = "The Fool" } }
        assert.is_nil(ConsumableEffect.predict_money_delta(card))
    end)

    it("returns nil for planets", function()
        local card = { ability = { name = "Pluto" } }
        assert.is_nil(ConsumableEffect.predict_money_delta(card))
    end)

    it("returns nil for non-money spectrals", function()
        local card = { ability = { name = "Aura" } }
        assert.is_nil(ConsumableEffect.predict_money_delta(card))
    end)
end)
