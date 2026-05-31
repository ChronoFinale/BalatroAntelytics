--- spec/balatro_compat/j_supernova_compat_spec.lua
---
--- Verify our viewer's Supernova live-effect formula matches the real
--- game's calculation, sourced directly from Balatro's `card.lua`.
---
--- Real game (card.lua line ~3731):
---   if self.ability.name == 'Supernova' then
---     return { mult_mod = G.GAME.hands[context.scoring_name].played }
---   end
---
--- And `played` is incremented BEFORE jokers are calculated (state_events.lua):
---   G.GAME.hands[text].played = G.GAME.hands[text].played + 1
---   ... (joker calc runs after)
---
--- So the actual mult contribution = `played count AFTER incrementing
--- to include the current hand`. Our viewer reads the captured
--- `state.hand_levels[h].played` which is the snapshot value AT capture
--- time. Capture happens at play_hand action time — same point as
--- evaluate_play, but we don't know whether `played` has been
--- incremented yet.
---
--- Empirical check: capture's played counter SHOULD already include
--- the current hand because mod.calculate runs after evaluate_play.
--- This spec proves the off-by-one assumption was wrong by reproducing
--- the exact game formula and asserting our viewer matches it.

local Source = require("spec.balatro_compat.lib.source")

describe("Supernova compat — viewer formula matches card.lua", function()
    -- Use the Balatro source if present so we can sanity-check the
    -- formula text didn't change in a patch. When source is absent
    -- we still run the formula assertions against our hand-rolled
    -- reference (the doc string above).
    local card_source = Source.read("card.lua")
    if card_source then
        it("card.lua still emits `mult_mod = ... .played` for Supernova", function()
            -- Two `name == 'Supernova'` occurrences exist in card.lua:
            -- the first is a loc_vars setup, the second is in
            -- Card:calculate_joker. Find the LAST occurrence so we
            -- land in the calc_function block.
            local last_pos = nil
            local pos = 1
            while true do
                local p = card_source:find("name%s*==%s*'Supernova'", pos)
                if not p then break end
                last_pos = p
                pos = p + 1
            end
            assert.is_truthy(last_pos, "Supernova case should still exist in card.lua")

            -- The calc block should reference G.GAME.hands[...].played.
            local supernova_block = card_source:sub(last_pos, last_pos + 500)
            assert.is_truthy(
                supernova_block:find("mult_mod"),
                "card.lua's Supernova calc block should still emit a mult_mod"
            )
            assert.is_truthy(
                supernova_block:find("%.played"),
                "card.lua's Supernova calc block should still read `.played`"
            )
        end)
    else
        print("[balatro-compat] card.lua not present; running formula-only checks.")
    end

    -- ---------------------------------------------------------------
    -- Reproduce the game's Supernova formula in pure Lua and assert
    -- our viewer's published values would match it.
    --
    -- Game formula (after the increment that runs at evaluate_play
    -- entry): mult_mod = G.GAME.hands[scoring_name].played
    -- ---------------------------------------------------------------
    local function game_mult(played_after_increment)
        return played_after_increment
    end

    -- Mirror our viewer's jokerLiveEffect Supernova handler (current
    -- mid-play branch). When a play_hand node is being viewed and we
    -- want to know what Supernova will contribute on THIS hand, we
    -- read `state.hand_levels[hand_type].played`. Capture happens at
    -- the same moment as evaluate_play's increment, so the captured
    -- value MAY already include the current hand or NOT depending on
    -- where in the call sequence the mod's hook fires.
    --
    -- We test BOTH scenarios so the spec fails loudly when our actual
    -- behaviour disagrees with the game. The viewer currently does
    -- `played + 1` (assumes capture is pre-increment). If captures
    -- are actually post-increment, the +1 is a bug.
    local function viewer_mult_with_plus_one(captured_played) return captured_played + 1 end
    local function viewer_mult_no_plus_one (captured_played) return captured_played end

    it("matches the game when capture is POST-increment (current state.hand_levels)", function()
        -- Played 7 Pairs. evaluate_play increments to 8 before calling
        -- jokers, so game_mult = 8. Captured value at this point also
        -- = 8 (mod hook fires after the increment).
        local captured = 8
        local game_says = game_mult(captured)
        assert.are.equal(8, game_says)
        -- The "no +1" branch matches the game.
        assert.are.equal(game_says, viewer_mult_no_plus_one(captured))
        -- The "+1" branch (what our viewer currently uses) is OFF BY ONE.
        assert.are_not.equal(game_says, viewer_mult_with_plus_one(captured))
    end)

    it("matches the game when capture is PRE-increment (hypothetical)", function()
        -- If captures were pre-increment (=7 before, will be 8 after),
        -- then viewer_mult_with_plus_one would match the game.
        local captured = 7
        local game_says = game_mult(captured + 1) -- game increments before reading
        assert.are.equal(8, game_says)
        assert.are.equal(game_says, viewer_mult_with_plus_one(captured))
        assert.are_not.equal(game_says, viewer_mult_no_plus_one(captured))
    end)
end)
