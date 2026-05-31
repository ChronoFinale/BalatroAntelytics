--- Scenario: play_then_discard
---
--- The simplest two-step flow: highlight three cards and play them as a
--- Three of a Kind, then highlight one card and discard it. Validates that
--- both wrappers produce nodes carrying the right action shape, the right
--- card detail, and the right hand-type label.

return function(world)
    local function card(id, rank, suit)
        return {
            base   = { id = id, value = rank, suit = suit },
            config = { center = { key = "c_base" } },
        }
    end

    -- 8-card hand: three 7s scattered among assorted others.
    world:set_hand({
        card("7",  "7",  "Spades"),
        card("Q",  "Q",  "Hearts"),
        card("7d", "7",  "Diamonds"),
        card("3",  "3",  "Clubs"),
        card("7c", "7",  "Clubs"),
        card("A",  "A",  "Spades"),
        card("K",  "K",  "Spades"),
        card("4",  "4",  "Hearts"),
    })

    -- Step 1: play the three 7s.
    world:highlight({ 1, 3, 5 })
    world:next_play_hand_type("Three of a Kind")
    world:play_hand()

    -- Step 2: discard a single card.
    world:set("hands_left", 3)
    world:highlight({ 4 })
    world:next_discard_hand_type("High Card")
    world:discard()
end
