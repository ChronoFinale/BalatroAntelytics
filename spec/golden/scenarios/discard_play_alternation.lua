--- Scenario: discard_play_alternation
---
--- Reproduces the navigation pattern that exposed the duplicate-card-id
--- key bug: a hand with multiple 7s and 4s where the player alternates
--- discard / play / discard / play. The captured nodes feed the viewer
--- regression tests that assert the rendered hand stays the right size
--- across rerenders.

return function(world)
    local function card(id, rank, suit)
        return {
            base   = { id = id, value = rank, suit = suit },
            config = { center = { key = "c_base" } },
        }
    end

    -- 8-card hand with deliberate id duplication: two 7s, two 4s, two 3s.
    -- These all share the same Balatro `card.base.id` because base.id is
    -- the rank's nominal id, not a per-card UUID.
    world:set_hand({
        card("7", "7", "Spades"),
        card("7", "7", "Hearts"),
        card("Q", "Q", "Diamonds"),
        card("4", "4", "Spades"),
        card("4", "4", "Hearts"),
        card("3", "3", "Spades"),
        card("3", "3", "Hearts"),
        card("A", "A", "Clubs"),
    })

    world:highlight({ 1, 2 })
    world:next_discard_hand_type("Pair")
    world:discard()

    world:set("discards_left", 2)
    world:highlight({ 4, 5 })
    world:next_play_hand_type("Pair")
    world:play_hand()

    world:set("hands_left", 3)
    world:highlight({ 6, 7 })
    world:next_discard_hand_type("Pair")
    world:discard()

    world:set("discards_left", 1)
    world:highlight({ 8 })
    world:next_play_hand_type("High Card")
    world:play_hand()
end
