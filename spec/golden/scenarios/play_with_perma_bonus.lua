--- Scenario: play_with_perma_bonus
---
--- Validates that perma_* fields on cards (Hiker chips, Sock and Buskin
--- retriggers, Steamodded perma_x_mult, etc.) are captured under
--- `card.perma` in state.hand and in action.cards when the card is played.

return function(world)
    local function card(id, rank, suit, ability)
        return {
            base    = { id = id, value = rank, suit = suit },
            config  = { center = { key = "c_base" } },
            ability = ability,
        }
    end

    world:set_hand({
        -- Card 1: A 5 of Hearts that has been hit by Hiker twice (+10) and
        -- has a perma retrigger from Sock and Buskin.
        card("5", "5", "Hearts", {
            perma_bonus       = 10,
            perma_repetitions = 1,
            -- multiplicative defaults that should be filtered out:
            perma_x_chips = 1,
            perma_x_mult  = 1,
            -- zero default that should be filtered out:
            perma_p_dollars = 0,
        }),
        -- Card 2: vanilla
        card("A", "A", "Spades"),
    })

    world:highlight({ 1, 2 })
    world:next_play_hand_type("High Card")
    world:play_hand()
end
