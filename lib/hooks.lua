--- hooks.lua
--- Monkey-patched hooks for events without SMODS calculate contexts.
---
--- Public API:
---   hooks.register_all(deps)
---   hooks.retry_deferred_hooks(logger)
---
--- deps must contain:
---   capture     -- Capture module
---   recorder    -- Recorder instance (single send path)
---   logger      -- Logger module
---   config      -- { player_id }
---   state       -- run-scoped state table
---   mp          -- Multiplayer accessor
---   gate        -- Gate module (deciding whether to record)
---
--- All hook bodies are wrapped in pcall so no error reaches the game.

local hooks = {}

-- ---------------------------------------------------------------------------
-- Function wrapping helper
-- ---------------------------------------------------------------------------
-- Track wrapped functions by container+key so a double-install (e.g. on a
-- mid-run mod hot-reload) doesn't stack two wrappers on the same target.
local wrapped_keys = {}

--- Reset the wrapped-function registry. Used by tests to bootstrap a
--- fresh G + hooks.register_all() between cases without inheriting the
--- prior test's wrap state. Production code never calls this — the
--- registry is intentionally process-lifetime to prevent double-wraps
--- on mid-run hot-reload.
local function reset_wrap_registry()
    wrapped_keys = {}
end

local function wrap_function(scope, key, wrapper)
    local container
    if scope == "G.FUNCS" then
        if not G or not G.FUNCS then return false end
        container = G.FUNCS
    elseif scope == "G.E_MANAGER" then
        if not G or not G.E_MANAGER then return false end
        container = G.E_MANAGER
    elseif scope == "Game"   then container = _G.Game
    elseif scope == "Card"   then container = _G.Card
    elseif scope == "global" then container = _G
    else return false
    end

    if not container then return false end
    if type(container[key]) ~= "function" then return false end

    -- Idempotency guard. Stacking wrappers means the snapshot work runs
    -- N times per call and pcall errors get swallowed N times, which can
    -- manifest as gameplay-affecting slowdowns or stuck states.
    local registry_key = scope .. "." .. key
    if wrapped_keys[registry_key] then return true end

    local original = container[key]
    container[key] = function(...) return wrapper(original, ...) end
    wrapped_keys[registry_key] = true
    return true
end

local deferred_hooks = {}

local function wrap_or_defer(scope, key, wrapper)
    local ok = wrap_function(scope, key, wrapper)
    if not ok then
        deferred_hooks[#deferred_hooks + 1] = { scope = scope, key = key, wrapper = wrapper }
    end
    return ok
end

function hooks.retry_deferred_hooks(logger)
    if #deferred_hooks == 0 then return true end
    local still_pending = {}
    for _, entry in ipairs(deferred_hooks) do
        local installed = false
        if entry.install then
            local ok, result = pcall(entry.install)
            installed = ok and result == true
        else
            installed = wrap_function(entry.scope, entry.key, entry.wrapper)
        end
        if not installed then
            still_pending[#still_pending + 1] = entry
        elseif logger and logger.info then
            local name = entry.key or "custom"
            logger.info("Deferred hook installed: " .. name)
        end
    end
    deferred_hooks = still_pending
    return #still_pending == 0
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------
local function generate_run_id(seed, timestamp)
    -- The run_id becomes the log FILENAME (<run_id>.json.gz). Multiplayer seeds
    -- can contain characters that are illegal in filenames — notably a leading
    -- '*' in MP Attrition (seed "*I5DHZ93B") — which made the write silently
    -- fail on Windows and produced NO file. Strip filesystem-reserved chars
    -- (< > : " / \ | ? * and control chars) for the id; the untouched seed is
    -- still recorded separately in the run's `seed` field.
    local safe = tostring(seed or "unknown"):gsub('[<>:"/\\|?*%c]', '_')
    return safe .. "_" .. tostring(timestamp or os.time())
end

local function get_highlighted_card_ids()
    local ids = {}
    if G and G.hand and G.hand.highlighted then
        for _, card in ipairs(G.hand.highlighted) do
            local id = "unknown"
            if card.base and card.base.id then
                id = tostring(card.base.id)
            elseif card.config and card.config.card and card.config.card.id then
                id = tostring(card.config.card.id)
            end
            ids[#ids + 1] = id
        end
    end
    return ids
end

local function get_highlighted_card_details(deps)
    if not (G and G.hand and G.hand.highlighted) then return {} end
    if not (deps and deps.capture and deps.capture.describe_playing_cards) then
        return {}
    end
    return deps.capture.describe_playing_cards(G.hand.highlighted)
end

local function log_error(logger, where, err)
    local fn = (logger and (logger.error or logger.warning or logger.info)) or function() end
    fn("Hook error in " .. where .. ": " .. tostring(err))
end

-- ---------------------------------------------------------------------------
-- Build PvP summary from the Multiplayer accessor (called at run end).
-- ---------------------------------------------------------------------------
local function build_pvp_summary(mp)
    if not (mp and mp.enabled) then return nil end
    local ok, summary = pcall(function()
        return {
            opponent_shop_spending   = mp.opponent_shop_spending(),
            opponent_sells           = mp.opponent_sells(),
            player_reroll_count      = mp.player_reroll_count(),
            player_reroll_cost_total = mp.player_reroll_cost_total(),
            -- Usually nil here: the opponent's end-game jokers arrive a few
            -- frames after match end (async pull). The deferred finalize in
            -- main.lua waits for them; this is the fallback for paths that
            -- finalize synchronously (solo/interrupted), where it stays nil.
            opponent_end_game_jokers = mp.opponent_end_game_jokers(),
            lobby_config             = mp.lobby_config(),
        }
    end)
    if ok then return summary end
    return nil
end

-- ---------------------------------------------------------------------------
-- Public: register_all
-- ---------------------------------------------------------------------------
function hooks.register_all(deps)
    local capture  = deps.capture
    local logger   = deps.logger
    local config   = deps.config
    local recorder = deps.recorder
    local state    = deps.state
    local gate     = deps.gate
    local mp       = deps.mp

    -- Emit an explicit terminal node when an MP MATCH ends. Solo runs already
    -- get a terminal node (the failing end_of_round carries game_over=true), but
    -- an MP match ends server-side — win_game / create_UIBox_game_over fire via
    -- network messages with NO end_of_round — so the run otherwise just stops on
    -- a play_hand with no result node. Gated on being in an MP lobby
    -- (MP.LOBBY.code) so solo runs (no lobby) are untouched. Records the final
    -- scores/lives via build_game_state and the authoritative outcome.
    -- Emit the terminal MP node and report whether this was an MP match (i.e.
    -- we're in a lobby). Callers use the return to decide between deferring the
    -- finalize (MP — wait for the async opponent end-game pull) and finalizing
    -- synchronously (solo).
    local function record_mp_match_end(outcome)
        local MP = rawget(_G, "MP")
        local ok, code = pcall(function() return MP and MP.LOBBY and MP.LOBBY.code end)
        if not (ok and code ~= nil) then return false end
        pcall(function()
            recorder:send({
                index  = recorder:next_index(),
                state  = capture.build_game_state("game_over"),
                action = { type = "game_over", outcome = outcome },
            })
        end)
        return true
    end

    -- Defer an MP run's finalize so the update loop can wait for the opponent's
    -- end-game jokers (async pull) before writing the file. Solo runs finalize
    -- immediately. See main.lua's pending_mp_end handling.
    local function finalize_or_defer(outcome, final_ante)
        local is_mp = record_mp_match_end(outcome)
        if is_mp then
            state.pending_mp_end = { outcome = outcome, final_ante = final_ante, frames = 0 }
        else
            recorder:end_run(outcome, final_ante, build_pvp_summary(mp))
        end
    end

    -- -----------------------------------------------------------------------
    -- Game:start_run — generate runId, begin recording every run
    -- The gate is intentionally permissive: we record everything and let the
    -- viewer / file consumer decide what to do with non-PvP runs. The only
    -- thing that distinguishes a PvP run is the presence of pvp_summary in
    -- the run file, which we populate at end_run when the Multiplayer mod
    -- has data to share.
    -- -----------------------------------------------------------------------
    wrap_or_defer("Game", "start_run", function(original, self, ...)
        local result = original(self, ...)

        local ok, err = pcall(function()
            local timestamp = os.time()
            local seed = "unknown"
            if G and G.GAME and G.GAME.pseudorandom and G.GAME.pseudorandom.seed
                and tostring(G.GAME.pseudorandom.seed) ~= "" then
                seed = tostring(G.GAME.pseudorandom.seed)
            elseif G and G.GAME and G.GAME.seeded then
                seed = tostring(G.GAME.seeded)
            end

            -- Resume detection: if the game loaded mid-run (ante > 1, or
            -- ante == 1 but past the first blind), this is a continue rather
            -- than a fresh start. Look for an interrupted file with the same
            -- seed and reuse its run_id so capture appends to the same
            -- logical run. Falls back to a fresh run_id when no match found.
            local ante = 1
            pcall(function()
                ante = G.GAME.round_resets.ante or 1
            end)
            local is_resume = ante > 1

            local run_id
            if is_resume and deps.file_writer then
                local previous_id = deps.file_writer:find_interrupted_run_for_seed(seed)
                if previous_id then
                    run_id = previous_id
                    if logger.info then
                        logger.info("Run resumed: " .. run_id
                            .. " (seed=" .. seed .. ", ante=" .. tostring(ante) .. ")")
                    end
                end
            end

            if not run_id then
                run_id = generate_run_id(seed, timestamp)
            end

            local gamemode_label = "solo"
            if gate and gate.current_gamemode() then
                gamemode_label = gate.current_gamemode()
            end

            -- Read deck back and stake for the run header.
            local deck_back = nil
            pcall(function()
                deck_back = G.GAME.selected_back.effect.center.key
            end)

            local stake_level = nil
            pcall(function()
                stake_level = G.GAME.stake
            end)

            recorder:start_run(
                run_id,
                (config.player_id ~= "" and config.player_id) or "anonymous",
                seed,
                timestamp,
                gamemode_label,
                nil,  -- previous_run_id (handled separately for resumes)
                deck_back,
                stake_level
            )

            if logger.info then
                logger.info("Run started: " .. run_id .. " (seed=" .. seed .. ", gamemode=" .. gamemode_label .. ")")
            end
        end)

        if not ok then log_error(logger, "Game:start_run", err) end
        return result
    end)

    -- -----------------------------------------------------------------------
    -- G.FUNCS.play_cards_from_highlighted — play_hand
    --
    -- IMPORTANT: in the real engine, this function does NOT call
    -- evaluate_play synchronously. It enqueues an event on G.E_MANAGER
    -- whose callback eventually calls evaluate_play. So when our
    -- wrapper returns, evaluate_play has not run yet and SMODS.last_hand
    -- still holds the PREVIOUS hand's classification.
    --
    -- Therefore we only build and stash the node here. Sending it is
    -- the responsibility of the evaluate_play wrapper below, which is
    -- guaranteed to run after SMODS.last_hand has been refreshed for
    -- this hand.
    -- -----------------------------------------------------------------------
    wrap_or_defer("G.FUNCS", "play_cards_from_highlighted", function(original, e)
        local ok, err = pcall(function()
            if not recorder:is_active() then return end

            local game_state = capture.build_game_state("play_hand")
            local node = {
                index = recorder:next_index(),
                state = game_state,
                action = {
                    type      = "play_hand",
                    card_ids  = get_highlighted_card_ids(),
                    cards     = get_highlighted_card_details(deps),
                    hand_type = nil,  -- filled in by evaluate_play wrapper
                },
            }
            state.pending_play_node = node
            -- Mark active BEFORE original(e) runs the scoring loop, so
            -- effect contexts during scoring (Glass break → remove_playing_cards,
            -- Midas → setting_ability) route onto this node.
            state.active_effect_node = node
        end)
        if not ok then log_error(logger, "play_cards_from_highlighted", err) end

        return original(e)
    end)

    -- -----------------------------------------------------------------------
    -- G.FUNCS.evaluate_play — stamp hand_type AND send the pending node.
    --
    -- Steamodded's lovely patch sets SMODS.last_hand at the start of
    -- the original evaluate_play. By the time the original returns,
    -- SMODS.last_hand.scoring_name is the fresh classification of the
    -- hand we just played, so this is the correct moment to stamp and
    -- send.
    -- -----------------------------------------------------------------------
    wrap_or_defer("G.FUNCS", "evaluate_play", function(original, e)
        local result = original(e)
        pcall(function()
            if state.pending_play_node then
                local hand_type = nil
                if SMODS and SMODS.last_hand and SMODS.last_hand.scoring_name then
                    hand_type = SMODS.last_hand.scoring_name
                elseif G and G.GAME and G.GAME.last_hand_played then
                    hand_type = G.GAME.last_hand_played
                end
                if hand_type then
                    state.pending_play_node.action.hand_type = hand_type
                end

                recorder:send(state.pending_play_node)
                state.pending_play_node = nil
            end
        end)
        return result
    end)

    -- -----------------------------------------------------------------------
    -- G.FUNCS.discard_cards_from_highlighted — discard
    --
    -- Engine signature: G.FUNCS.discard_cards_from_highlighted(e, hook).
    -- The Hook boss blind calls this with `hook = true` to auto-discard
    -- two random cards from hand at the start of each round. The `hook`
    -- arg gates engine logic (it skips deducting a discard from the
    -- player's count, since The Hook is "free"). DROPPING THE SECOND
    -- ARG ON FORWARD HUNG THE BLIND — without `hook=true`, the engine's
    -- discard accounting got confused and the round never resolved.
    -- We capture as a regular `discard` action either way, since the
    -- player visually sees cards leave their hand; the `e, hook`
    -- forwarding to the original is what matters.
    -- -----------------------------------------------------------------------
    wrap_or_defer("G.FUNCS", "discard_cards_from_highlighted", function(original, e, hook)
        local ok, err = pcall(function()
            if not recorder:is_active() then return end

            local discarded_hand_type = nil
            if G and G.FUNCS and G.FUNCS.get_poker_hand_info and G.hand and G.hand.highlighted then
                local ok_eval, hand_name = pcall(function()
                    return G.FUNCS.get_poker_hand_info(G.hand.highlighted)
                end)
                if ok_eval and type(hand_name) == "string" and hand_name ~= "" then
                    discarded_hand_type = hand_name
                end
            end

            local discarded_descriptors = get_highlighted_card_details(deps)

            local action = {
                type                = "discard",
                card_ids            = get_highlighted_card_ids(),
                cards               = discarded_descriptors,
                discarded_hand_type = discarded_hand_type,
            }

            -- Mark Hook-auto discards so the viewer can render them
            -- differently from player-initiated discards.
            if hook then
                action.auto_source = "the_hook"
            end

            -- Predict the money delta from Mail-In Rebate / Faceless Joker /
            -- Trading Card. discard_effect.predict_money_delta inspects the
            -- highlighted cards + current jokers + round state and computes
            -- the dollar delta deterministically. The viewer reads
            -- action.expected_money_delta + action.money_breakdown for the
            -- sidebar "+$N (Mail-In Rebate)" label.
            if deps.discard_effect and deps.discard_effect.predict_money_delta then
                local ok_predict, prediction = pcall(function()
                    local jokers        = G and G.jokers and G.jokers.cards or {}
                    local current_round = G and G.GAME and G.GAME.current_round or {}
                    return deps.discard_effect.predict_money_delta(
                        discarded_descriptors, jokers, current_round
                    )
                end)
                if ok_predict and type(prediction) == "table" then
                    action.expected_money_delta = prediction.total
                    action.money_breakdown      = prediction.breakdown
                end
            end

            local node = {
                index  = recorder:next_index(),
                state  = capture.build_game_state("discard"),
                action = action,
            }
            -- Active before original() runs the discard, so Purple-seal
            -- tarot generation (card_added) and any destroys route here.
            state.active_effect_node = node
            recorder:send(node)
        end)
        if not ok then log_error(logger, "discard_cards_from_highlighted", err) end

        return original(e, hook)
    end)

    -- -----------------------------------------------------------------------
    -- G.FUNCS.select_from_pack — picks from STANDARD_PACK only.
    --
    -- Important: in vanilla Balatro, picks from non-Standard booster packs
    -- (Buffoon, Arcana, Celestial, Spectral, Mega variants) are NOT
    -- routed through select_from_pack. They go through G.FUNCS.use_card
    -- while G.STATE is one of the *_PACK states. The use_card hook below
    -- catches those picks and emits the same select_from_pack node.
    -- -----------------------------------------------------------------------
    local PACK_STATES = {
        ["TAROT_PACK"]           = true,
        ["SPECTRAL_PACK"]        = true,
        ["STANDARD_PACK"]        = true,
        ["BUFFOON_PACK"]         = true,
        ["PLANET_PACK"]          = true,
        -- SMODS routes ALL packs through its own state (booster.toml:80). The
        -- live DIAG log showed `state=SMODS_BOOSTER_OPENED match=false` — the
        -- pick was firing here, we just didn't recognize the state. This is
        -- THE reason Buffoon/joker picks weren't captured.
        ["SMODS_BOOSTER_OPENED"] = true,
    }

    --- Build and emit a select_from_pack Decision_Node from the card the
    --- player just picked. Shared by both the select_from_pack and
    --- use_card hooks below.
    local function emit_select_from_pack(picked_card)
        if not recorder:is_active() then return end

        local pack_id = "p_unknown"
        local selected_card_id = nil
        local selected_description = nil

        if G and G.GAME and G.GAME.current_round and G.GAME.current_round.used_packs then
            local packs = G.GAME.current_round.used_packs
            if #packs > 0 then pack_id = tostring(packs[#packs]) end
        end

        if picked_card then
            -- For playing cards, use base.id (the card's identity).
            -- For jokers/consumables, use config.center.key.
            local is_playing = picked_card.base
                and picked_card.base.value and picked_card.base.suit
            if is_playing then
                if picked_card.base.id then
                    selected_card_id = tostring(picked_card.base.id)
                end
            elseif picked_card.config and picked_card.config.center and picked_card.config.center.key then
                selected_card_id = tostring(picked_card.config.center.key)
            elseif picked_card.base and picked_card.base.id then
                selected_card_id = tostring(picked_card.base.id)
            end
            -- Describe a PLAYING card by rank/suit; only jokers/consumables go
            -- through describe_card. Standard-pack picks were being described as
            -- the enhancement center ("Default Base") instead of "7 of Spades".
            if is_playing and capture.describe_playing_card then
                selected_description = capture.describe_playing_card(picked_card)
            elseif capture.describe_card then
                selected_description = capture.describe_card(picked_card)
            end
        end

        local offered = {}
        if capture.snapshot_pack_offered then
            offered = capture.snapshot_pack_offered(picked_card)
        end

        -- Increment the pack-window pick counter so ending_pack can
        -- stamp the final selects_in_pack onto its action payload.
        state.current_pack_selects = (state.current_pack_selects or 0) + 1

        recorder:send({
            index = recorder:next_index(),
            state = capture.build_game_state("select_from_pack"),
            action = {
                type                 = "select_from_pack",
                pack_id              = pack_id,
                selected_card_id     = selected_card_id,
                selected_description = selected_description,
                offered              = offered,
            },
        })
    end

    wrap_or_defer("G.FUNCS", "select_from_pack", function(original, e)
        local ok, err = pcall(function()
            local picked_card = e and e.config and e.config.ref_table or nil
            emit_select_from_pack(picked_card)
        end)
        if not ok then log_error(logger, "select_from_pack", err) end
        return original(e)
    end)

    -- -----------------------------------------------------------------------
    -- G.FUNCS.use_card — pack picks for Buffoon / Arcana / Celestial / etc.
    --
    -- use_card is also called for normal consumable use, so we only emit
    -- the pack-pick node when the engine is currently inside a *_PACK
    -- state. The buying_card / using_consumeable contexts handle the
    -- non-pack cases via mod.calculate.
    -- -----------------------------------------------------------------------
    --- Reverse-lookup `G.STATE` (a numeric value) to its key name in
    --- `G.STATES`, e.g. returns "BUFFOON_PACK" for the buffoon pack state.
    --- Returns nil if the value isn't found.
    local function current_state_name()
        local current = G and G.STATE
        local states  = G and G.STATES
        if not (current and states) then return nil end
        for name, value in pairs(states) do
            if value == current then return name end
        end
        return nil
    end

    wrap_or_defer("G.FUNCS", "use_card", function(original, e, mute, nosave)
        -- Snapshot the wallet BEFORE the action pays. Vouchers (redeem) and
        -- packs charge inside the original before the buying_card context
        -- fires, so without this their buy node would record post-pay money
        -- (inconsistent with jokers/consumables, which record pre-pay). The
        -- buy handler in main.lua uses this snapshot so EVERY buy node has a
        -- consistent pre-purchase wallet → the viewer's money diff is correct.
        pcall(function()
            if G and G.GAME then state.money_before_purchase = G.GAME.dollars end
        end)
        local ok, err = pcall(function()
            local state_name = current_state_name()
            -- DIAGNOSTIC (task #36): Buffoon/Arcana pack picks aren't
            -- emitting select_from_pack in captured runs (selects_in_pack
            -- stays 0). By source this hook SHOULD fire here. Log the live
            -- state + picked card whenever a booster pack is open so a real
            -- pick reveals why the PACK_STATES gate misses. Remove once fixed.
            if G and G.booster_pack and logger and logger.info then
                local card_set = "nil"
                pcall(function()
                    local c = e and e.config and e.config.ref_table
                    if c and c.ability then card_set = tostring(c.ability.set) end
                end)
                logger.info("DIAG use_card: state=" .. tostring(state_name)
                    .. " match=" .. tostring(state_name ~= nil and PACK_STATES[state_name] ~= nil)
                    .. " card.set=" .. card_set
                    .. " recorder_active=" .. tostring(recorder and recorder:is_active()))
            end
            if not (state_name and PACK_STATES[state_name]) then return end
            local picked_card = e and e.config and e.config.ref_table or nil
            -- Every pick (joker OR consumable) from any pack kind: this hook is
            -- the single funnel (SMODS keeps the pick on G.FUNCS.use_card while
            -- G.STATE is the pack state). Now that SMODS_BOOSTER_OPENED is in
            -- PACK_STATES, jokers register here too.
            emit_select_from_pack(picked_card)
        end)
        if not ok then log_error(logger, "use_card", err) end
        return original(e, mute, nosave)
    end)

    -- Pre-purchase money snapshot for shop buys (jokers, consumables,
    -- playing cards). buy_from_shop fires buying_card before deducting the
    -- cost, so these are already pre-pay, but we snapshot here too so the
    -- buy handler can use one consistent source regardless of buy path.
    wrap_or_defer("G.FUNCS", "buy_from_shop", function(original, e)
        pcall(function()
            if G and G.GAME then state.money_before_purchase = G.GAME.dollars end
        end)
        return original(e)
    end)

    -- -----------------------------------------------------------------------
    -- G.FUNCS.skip_blind — mark the synchronous skip window.
    --
    -- The tag the player CHOSE by skipping is added synchronously inside this
    -- call (add_tag, button_callbacks.lua:2757) BEFORE the slot flips to
    -- "Skipped". A Double Tag duplicate is added on a LATER event-queue frame
    -- (tag.lua:327, deferred via Tag:yep), after this call has returned. So
    -- `state.in_skip_blind` is true only while the chosen tag is being added —
    -- the tag_added handler in main.lua reads it to set `from_skip`. This is a
    -- deterministic sync/async boundary, replacing the old "any blind skipped
    -- yet" heuristic that mis-fired on the second consecutive skip.
    -- -----------------------------------------------------------------------
    wrap_or_defer("G.FUNCS", "skip_blind", function(original, e)
        state.in_skip_blind = true
        -- Advance the logical ante to the engine value the moment the player
        -- acts on the new ante's blind-select. round_resets.ante is already the
        -- correct N+1 here -- it was bumped when the previous boss was beaten and
        -- is NOT touched by skip_blind (verified in engine) -- but
        -- run_state.current_ante is only refreshed when a blind is *played*
        -- (context.setting_blind), never on a skip. Without this, the
        -- skip_blind_tag and its tag_added (both emitted inside this synchronous
        -- window) inherit the PREVIOUS ante, so a skipped Small Blind shows up
        -- one ante too early. Set it before original(e) so the tag_added handler
        -- -- which runs as the tag is added inside the skip -- sees N+1 too.
        if G and G.GAME and G.GAME.round_resets
            and type(G.GAME.round_resets.ante) == "number" then
            state.current_ante = G.GAME.round_resets.ante
        end
        local ok, ret = pcall(original, e)
        state.in_skip_blind = nil
        if not ok then log_error(logger, "skip_blind", ret) end
        return ret
    end)

    -- -----------------------------------------------------------------------
    -- win_game (global) — outcome "win"
    -- -----------------------------------------------------------------------
    wrap_or_defer("global", "win_game", function(original, ...)
        local ok, err = pcall(function()
            if not recorder:is_active() then return end
            local final_ante = 8
            if G and G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante then
                final_ante = G.GAME.round_resets.ante
            end
            finalize_or_defer("win", final_ante)
            if logger.info then logger.info("Run ended: win (ante " .. tostring(final_ante) .. ")") end
        end)
        if not ok then log_error(logger, "win_game", err) end
        return original(...)
    end)

    -- -----------------------------------------------------------------------
    -- create_UIBox_game_over (global) — outcome "loss"
    -- -----------------------------------------------------------------------
    wrap_or_defer("global", "create_UIBox_game_over", function(original, ...)
        pcall(function()
            if not recorder:is_active() then return end
            local final_ante = 1
            pcall(function()
                final_ante = G.GAME.round_resets.ante or 1
            end)
            finalize_or_defer("loss", final_ante)
            if logger.info then logger.info("Run ended: loss (ante " .. tostring(final_ante) .. ")") end
        end)
        return original(...)
    end)

    -- -----------------------------------------------------------------------
    -- MP.ACTIONS.play_hand — your PvP hand scored (deferred — MP loads later)
    -- -----------------------------------------------------------------------
    if mp and mp.enabled then
        deferred_hooks[#deferred_hooks + 1] = {
            install = function()
                local MP = rawget(_G, "MP")
                if not MP or not MP.ACTIONS or type(MP.ACTIONS.play_hand) ~= "function" then
                    return false
                end
                local original = MP.ACTIONS.play_hand
                MP.ACTIONS.play_hand = function(score, hands_left)
                    pcall(function()
                        if not recorder:is_active() then return end
                        local ok, is_pvp = pcall(function()
                            return MP.is_pvp_blind and MP.is_pvp_blind()
                        end)
                        if not (ok and is_pvp) then return end

                        local game_state = capture.build_game_state("pvp_hand_scored")
                        recorder:send({
                            index = recorder:next_index(),
                            state = game_state,
                            action = {
                                type          = "pvp_hand_scored",
                                player        = "self",
                                hand_score    = score,
                                hands_left    = hands_left,
                                running_total = game_state.pvp and game_state.pvp.player_running_score,
                            },
                        })
                    end)
                    return original(score, hands_left)
                end
                return true
            end,
        }
    end

    -- -----------------------------------------------------------------------
    -- Tag:apply_to_run — capture tag triggers (Investment Tag pays out,
    -- Charm Tag spawns an Arcana pack, Speed Tag pays per skip, etc.).
    --
    -- We hook the method at the prototype level so every tag instance
    -- routes through our wrapper. We only emit when the tag actually
    -- triggered this call, since apply_to_run also runs as a no-op
    -- "are you ready?" probe across multiple context types per event.
    -- -----------------------------------------------------------------------
    deferred_hooks[#deferred_hooks + 1] = {
        install = function()
            if not (rawget(_G, "Tag") and type(Tag.apply_to_run) == "function") then
                return false
            end
            local original = Tag.apply_to_run
            Tag.apply_to_run = function(self, _context)
                local was_triggered_before = self.triggered and true or false
                local result = original(self, _context)
                pcall(function()
                    if not recorder:is_active() then return end
                    -- Only record when this call flipped the tag from
                    -- not-triggered to triggered. Tags get poked across
                    -- many context types per event, but only the call
                    -- that actually applies the effect sets `triggered`.
                    if was_triggered_before then return end
                    if not self.triggered then return end

                    local trigger_context = _context and _context.type or "unknown"
                    recorder:send({
                        index = recorder:next_index(),
                        state = capture.build_game_state("tag_triggered"),
                        action = {
                            type            = "tag_triggered",
                            tag_id          = self.key  and tostring(self.key)  or "tag_unknown",
                            tag_name        = self.name and tostring(self.name) or "Unknown Tag",
                            trigger_context = trigger_context,
                        },
                    })
                end)
                return result
            end
            return true
        end,
    }

    -- -----------------------------------------------------------------------
    -- Card:use_consumeable — synchronous post-effect snapshot.
    --
    -- The actual wrapper lives in `lib/use_consumable_hook.lua`. We defer
    -- the install attempt because the `Card` prototype is built during
    -- Balatro's bootstrap, so a cold mod load may run before it exists.
    -- Same retry pattern as the Tag.apply_to_run entry above.
    -- -----------------------------------------------------------------------
    if deps.use_consumable_hook then
        deferred_hooks[#deferred_hooks + 1] = {
            install = function()
                return deps.use_consumable_hook.install({
                    capture          = capture,
                    logger           = logger,
                    pending_node_ref = deps.pending_node_ref,
                }) == true
            end,
        }
    end

    -- -----------------------------------------------------------------------
    -- G.FUNCS.continue — resume detection (primary signal for Bug F)
    --
    -- G.FUNCS.continue may not exist at cold mod load (it's created by
    -- Balatro's UI setup). We register via wrap_or_defer so the retry
    -- loop in love.update installs it once the function appears.
    --
    -- The wrapper runs the original first (so the game's continue logic
    -- always executes), then calls deps.on_resume_detected if that
    -- callback is present in deps. The callback is responsible for
    -- scanning the log directory and starting the resumed run.
    --
    -- Open Question 6: G.FUNCS.continue existence must be verified
    -- against the installed Balatro build during live testing. The
    -- fallback in mod.reset_game_globals is load-bearing if this hook
    -- is absent.
    -- -----------------------------------------------------------------------
    wrap_or_defer("G.FUNCS", "continue", function(original, ...)
        local result = original(...)
        pcall(function()
            if deps.on_resume_detected then
                deps.on_resume_detected()
            end
        end)
        return result
    end)

    -- -----------------------------------------------------------------------
    -- Diagnostic: log which hooks were successfully registered
    -- -----------------------------------------------------------------------
    local diag = {}
    local function check(scope, key)
        local container
        if scope == "G.FUNCS" then container = G and G.FUNCS
        elseif scope == "Game"   then container = _G.Game
        elseif scope == "global" then container = _G
        end
        local status = (container and type(container[key]) == "function") and "OK" or "MISSING"
        diag[#diag + 1] = scope .. "." .. key .. "=" .. status
    end
    check("Game", "start_run")
    check("global", "win_game")
    check("global", "create_UIBox_game_over")
    check("G.FUNCS", "play_cards_from_highlighted")
    check("G.FUNCS", "evaluate_play")
    check("G.FUNCS", "discard_cards_from_highlighted")
    check("G.FUNCS", "select_from_pack")
    check("G.FUNCS", "use_card")
    if logger.info then
        logger.info("Hook registration: " .. table.concat(diag, ", "))
    end
end

-- Test-only: expose registry reset so spec bootstraps can re-wrap a
-- freshly-built G between cases. Production code never calls this.
hooks._reset_wrap_registry = reset_wrap_registry

return hooks
