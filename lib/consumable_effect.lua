--- consumable_effect.lua
--- Predicts the money delta that a consumable's effect will apply to the
--- player's wallet, computed at the moment the consumable is used.
---
--- The capture pipeline snapshots `state.money` BEFORE Balatro's deferred
--- ease_dollars events fire, so the viewer can't tell from state alone how
--- much money a tarot/spectral added or removed. This module reads the
--- consumable's ability config and the current game state to predict the
--- delta deterministically.
---
--- Returns nil for consumables that don't change money or whose effect is
--- non-deterministic (e.g. Lucky Cat, random spectrals like Familiar).
---
--- Public API:
---   ConsumableEffect.predict_money_delta(card)  -- returns number|nil

local ConsumableEffect = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Sum of sell values across G.jokers.cards, used for Temperance.
local function total_joker_sell_value()
    local total = 0
    if not (G and G.jokers and G.jokers.cards) then return total end
    for _, joker in ipairs(G.jokers.cards) do
        if type(joker.sell_cost) == "number" then
            total = total + joker.sell_cost
        end
    end
    return total
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Predict the wallet change the player should see after this consumable's
--- effect resolves. Reads `card.ability` and `G.GAME.dollars`/`G.jokers` —
--- never mutates state.
---
--- @param card table  A consumable Card (Tarot, Planet, Spectral) being used.
--- @return number|nil The predicted signed dollar delta, or nil when the
---                    consumable doesn't change money or the change is
---                    not predictable from current state.
function ConsumableEffect.predict_money_delta(card)
    if type(card) ~= "table" or not card.ability then return nil end

    local name = card.ability.name
    local extra = card.ability.extra
    local dollars = (G and G.GAME and G.GAME.dollars) or 0

    if name == "The Hermit" then
        -- Doubles your money, capped at +max ($20 in vanilla).
        -- Source: Card:use_consumeable in card.lua
        --   ease_dollars(math.max(0, math.min(G.GAME.dollars, self.ability.extra)), true)
        local cap = type(extra) == "number" and extra or 20
        return math.max(0, math.min(dollars, cap))
    end

    if name == "Temperance" then
        -- Gives sum of joker sell values, capped at $50 in vanilla.
        -- Source: Card:use_consumeable
        --   ease_dollars(self.ability.money, true)
        -- where self.ability.money was set in :set_ability based on jokers.
        if type(card.ability.money) == "number" then
            return card.ability.money
        end
        local cap = type(extra) == "number" and extra or 50
        return math.min(total_joker_sell_value(), cap)
    end

    if name == "Wraith" then
        -- Sets money to $0 — delta = -current dollars.
        return -dollars
    end

    if name == "Immolate" then
        -- +$20 (and destroys 5 random cards, but that's not a money effect).
        if type(extra) == "table" and type(extra.dollars) == "number" then
            return extra.dollars
        end
        return 20
    end

    -- The Fool, Wheel of Fortune, High Priestess, Emperor, Strength,
    -- Hanged Man, Death, Devil, Tower, suit-changing tarots,
    -- Familiar/Grim/Incantation, Aura, Sigil, Ouija, Ectoplasm, Ankh,
    -- Hex, Trance, Medium, Cryptid, The Soul, Black Hole — none of
    -- these change the wallet directly. Planets are always free.
    return nil
end

return ConsumableEffect
