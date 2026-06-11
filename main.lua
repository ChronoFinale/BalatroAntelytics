--- main.lua
--- Mod entry point for the Balatro Antelytics.
---
--- Captures one JSON file per PvP Attrition run. No server, no network calls.
--- The file lands at <mod_path>/log/<seed>_<timestamp>.json and can be loaded
--- in the viewer for post-game analysis.
---
--- Architecture:
---   - Recorder         single source of truth for sending nodes
---   - FileWriter       owns the in-memory buffer and JSON file output
---   - Capture          builds Game_State snapshots from the global G table
---   - hooks            monkey-patches for the events without SMODS contexts
---                      (start_run, win_game, create_UIBox_game_over,
---                      play_cards_from_highlighted, evaluate_play,
---                      discard_cards_from_highlighted, select_from_pack)
---   - mod.calculate    SMODS contexts for shop, blinds, consumables, packs
---   - love.update      polls for opponent hand plays during PvP blinds
---   - Gate             decides whether to record (PvP Attrition only for now)
---
--- Single-mode design: file output only. The HTTP path was removed because it
--- introduced two parallel send paths that drifted out of sync. Upload to a
--- backend is a separate concern and will live in a separate tool.

local mod = SMODS.current_mod
local config = mod.config or {}
local player_id = config.player_id or "anonymous"
local enabled   = config.enabled
if enabled == nil then enabled = true end

-- ---------------------------------------------------------------------------
-- Load submodules
-- ---------------------------------------------------------------------------
local Logger      = assert(SMODS.load_file("lib/logger.lua"))()
local Serializer  = assert(SMODS.load_file("lib/serializer.lua"))()
local Capture     = assert(SMODS.load_file("lib/capture.lua"))()
local hooks       = assert(SMODS.load_file("lib/hooks.lua"))()
local Multiplayer = assert(SMODS.load_file("lib/multiplayer.lua"))()
local FileWriter  = assert(SMODS.load_file("lib/file_writer.lua"))()
local Recorder    = assert(SMODS.load_file("lib/recorder.lua"))()
local Gate        = assert(SMODS.load_file("lib/gamemode_gate.lua"))()
local SkipBlindAction = assert(SMODS.load_file("lib/skip_blind_action.lua"))()
local SellAction      = assert(SMODS.load_file("lib/sell_action.lua"))()
local ConsumableEffect = assert(SMODS.load_file("lib/consumable_effect.lua"))()
local DiscardEffect    = assert(SMODS.load_file("lib/discard_effect.lua"))()
local UseConsumableHook = assert(SMODS.load_file("lib/use_consumable_hook.lua"))()

Logger.init(mod.path)
Logger.info("Antelytics initializing")

-- ---------------------------------------------------------------------------
-- Multiplayer accessor (PvP state)
-- ---------------------------------------------------------------------------
local mp_ok, mp = pcall(Multiplayer.new, { logger = Logger.warning })
if not mp_ok or not mp then
    mp = { enabled = false }
    Logger.warning("Multiplayer module failed to initialize; running in solo-only mode")
else
    Logger.info("Multiplayer detection: enabled=" .. tostring(mp.enabled))
end

-- ---------------------------------------------------------------------------
-- Per-run state
-- ---------------------------------------------------------------------------
local run_state = {
    current_blind_slot      = nil,
    current_ante            = nil,
    slot_captured           = {},
    pending_play_node       = nil,
    pending_discard_node    = nil,
    pending_consumable_node = nil,
    pending_open_pack_queue = {},
    pending_open_pack_seq   = 0,
    -- Pack-window running counter. Set on open_pack, incremented on each
    -- select_from_pack, drained onto the ending_pack action's payload so
    -- the viewer doesn't need to walk nodes to know how many cards were
    -- picked from the closing pack.
    current_pack_kind       = nil,
    current_pack_selects    = 0,
    pack_close_pending      = false, -- armed on open_booster, cleared on the pack's ending_booster (one close per pack, NOT per round)
    last_opponent_hands     = nil,
    last_action_timestamp   = nil,  -- updated by record_action; drives idle-flush
    emitted_this_round      = {},
    emitted_skip_slots      = {},   -- set of canonical slots ("small","big") with a skip_blind_tag emitted this ante
    skip_slots_ante         = nil,  -- the ante emitted_skip_slots is valid for; reset the set when the ante changes
    end_of_round_latched    = {},
    -- The action node whose effect we're currently accumulating. Set when
    -- ANY action node is created; swapped (not cleared) on the next action.
    -- Effect-bearing SMODS contexts (remove_playing_cards / playing_card_added
    -- / setting_ability / change_rank / change_suit) fire DURING and AFTER an
    -- action resolves (some deferred a frame), so the node must persist past
    -- the synchronous action handler — hence a dedicated ref, not the
    -- read-and-cleared pending_*_node. See SMODS_API_REFERENCE.md.
    active_effect_node      = nil,

    -- True only while G.FUNCS.skip_blind runs synchronously (set by the
    -- hooks.lua wrapper). The tag the player CHOSE by skipping is added during
    -- this window; a Double Tag duplicate is added later (async), so this flag
    -- deterministically separates the two. See the tag_added handler below.
    in_skip_blind           = false,
}

-- Exposed on the mod object so the hooks wrapper and busted specs can reach the
-- same run_state instance the calculate dispatch reads.
mod.run_state = run_state

Capture.init({
    null_sentinel = Serializer.null,
    logger        = function(msg) Logger.warning(msg) end,
    get_current_blind_slot = function() return run_state.current_blind_slot end,
    get_current_pack_kind  = function() return run_state.current_pack_kind end,
    get_current_ante       = function() return run_state.current_ante end,
    multiplayer = mp,
})

Serializer._log_error = function(msg) Logger.error(msg) end

-- ---------------------------------------------------------------------------
-- Recorder + FileWriter — single send path
-- ---------------------------------------------------------------------------
local file_writer = FileWriter.new({
    serializer = Serializer,
    logger     = function(msg) Logger.info(msg) end,
    mod_path   = mod.path,
})

local recorder = Recorder.new({
    file_writer = file_writer,
    logger      = function(msg) Logger.warning(msg) end,
})

-- Recover any runs that were interrupted by a previous crash. Each
-- orphan `.ndjson` file gets converted to a finalised `.json.gz` with
-- outcome = "interrupted" so the player can still review what was
-- captured before the crash.
do
    local ok, recovered = pcall(function()
        return file_writer:recover_orphan_runs()
    end)
    if ok and type(recovered) == "number" and recovered > 0 then
        Logger.info("Recovered " .. recovered .. " interrupted run(s) from previous session")
    end
end

-- ---------------------------------------------------------------------------
-- flush_pending_pack_queue
--
-- Best-effort drain of `run_state.pending_open_pack_queue`. For each
-- still-pending `open_pack` node we either preserve the at-enqueue
-- `offered` snapshot (back-to-back opens — re-snapshotting now would
-- read whichever pack `G.pack_cards.cards` currently holds, which is
-- almost always the LAST opened pack) or, if the at-enqueue snapshot
-- was empty (gamespeed race), re-snapshot one last time before sending.
--
-- A flushed node carrying empty `offered` is still better than losing
-- the node entirely — the viewer can recover the pack contents from
-- subsequent `select_from_pack` / `buy_joker` / `ending_pack.remaining`
-- nodes if needed.
--
-- Wired into:
--   1. `mod.reset_game_globals(false)` — clean up before the next blind
--   2. `context.ending_booster` — clean up when the player closes the pack
--   3. `love.quit` — clean up on shutdown
--
-- See Bug B in design.md.
-- ---------------------------------------------------------------------------
local function flush_pending_pack_queue()
    if not recorder:is_active() then return end
    for pending_id, node in pairs(run_state.pending_open_pack_queue) do
        pcall(function()
            -- Only re-snapshot if the at-enqueue snapshot was empty.
            -- Preserving the at-enqueue snapshot is what keeps per-pack
            -- contents correct when two opens fire back-to-back.
            if not (node.action.offered and #node.action.offered > 0) then
                node.action.offered = Capture.snapshot_pack_contents()
            end
            -- Refresh the full-deck snapshot for Arcana / Spectral packs.
            -- The engine draws cards INTO G.hand.cards on a delayed Event
            -- when those packs open, so the at-enqueue full_deck caught
            -- the pre-draw hand area as empty. Re-running build_full_deck
            -- now that the engine has emplaced everything gives the
            -- viewer the right hand to render alongside the pack.
            local refreshed_full_deck = Capture.snapshot_full_deck()
            if refreshed_full_deck and #refreshed_full_deck > 0 then
                node.state.full_deck = refreshed_full_deck
            end
            recorder:send(node)
        end)
        run_state.pending_open_pack_queue[pending_id] = nil
    end
end

-- ---------------------------------------------------------------------------
-- reset_game_globals — fires at the start of every blind, not just every run
-- ---------------------------------------------------------------------------
function mod.reset_game_globals(run_start)
    if run_start then
        run_state.current_blind_slot      = nil
        run_state.current_ante            = nil
        run_state.slot_captured           = {}
        run_state.pending_play_node       = nil
        run_state.pending_discard_node    = nil
        run_state.pending_consumable_node = nil
        run_state.pending_open_pack_queue = {}
        run_state.pending_open_pack_seq   = 0
        run_state.current_pack_kind       = nil
        run_state.current_pack_selects    = 0
        run_state.pack_close_pending      = false
        run_state.last_opponent_hands     = nil
        run_state.pending_mp_end          = nil
        run_state.last_action_timestamp   = nil
        run_state.emitted_this_round      = {}
        run_state.emitted_skip_slots      = {}
        run_state.skip_slots_ante         = nil
        run_state.end_of_round_latched    = {}
        pcall(function() Capture.reset_location() end)
    else
        -- Drain any open_pack nodes whose polling Event hasn't yet had
        -- a chance to snapshot — see Bug B. Must run BEFORE we mutate
        -- any other run_state, since flush_pending_pack_queue calls
        -- recorder:send and recorder:is_active reads run_state we'd
        -- otherwise have just wiped.
        flush_pending_pack_queue()
        -- New blind in an active run. Clear round-scoped state but try to
        -- recover the slot/ante so mid-run mod loads still capture correctly.
        --
        -- We deliberately do NOT touch `pending_open_pack_queue` /
        -- `pending_open_pack_seq` here — `flush_pending_pack_queue` (added
        -- in task 18) is responsible for emitting any still-pending pack
        -- nodes before the next blind starts. Wiping them here would
        -- silently drop packs whose populate Event hasn't fired yet, which
        -- is exactly the Bug B failure mode.
        run_state.pending_play_node      = nil
        run_state.pending_discard_node   = nil
        run_state.pending_consumable_node = nil
        run_state.emitted_this_round     = {}
        if recorder:is_active() and run_state.current_blind_slot == nil then
            local ok, slot = pcall(function()
                local on_deck = G and G.GAME and G.GAME.blind_on_deck
                local map = { Small = "small", Big = "big", Boss = "boss" }
                return map[on_deck]
            end)
            if ok and slot then run_state.current_blind_slot = slot end
            local ok2, ante = pcall(function()
                return G and G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante
            end)
            if ok2 and type(ante) == "number" then run_state.current_ante = ante end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Card:use_consumeable wrapper — synchronous post-effect snapshot
--
-- The wrapper reads `target_cards_after` and `destroyed_cards` from the
-- engine's mutated card state RIGHT AFTER `Card:use_consumeable` returns,
-- on the same call stack. This sidesteps the boss-blind-breaking
-- deferred-event approach a previous attempt used.
--
-- The handoff with the SMODS `context.using_consumeable` path works in
-- three steps:
--   1. The pre-effect SMODS handler builds the node, calls
--      `recorder:send(node)`, and stashes the node ref into
--      `run_state.pending_consumable_node`.
--   2. The engine resolves the consumable's effect via the original
--      `Card:use_consumeable`.
--   3. The wrapper calls `pending_node_ref()`, reads-and-clears the
--      stashed node, and mutates `node.action` in place to add the
--      post-effect fields. FileWriter holds the node by reference, so
--      the mutation is visible at end_run.
--
-- Single-slot pending is sufficient: vanilla Balatro resolves
-- consumables serially, and the read-and-clear contract guarantees
-- each consumable use writes its post-effect fields exactly once.
--
-- Actual installation is performed by the deferred-hook retry loop in
-- `hooks.lua`. Card may not be loaded at mod cold-start, so we register
-- the install attempt alongside the other deferred wrappers and let the
-- retry loop install it on the first tick the prototype is available.
-- ---------------------------------------------------------------------------
local function pending_node_ref()
    local node = run_state.pending_consumable_node
    run_state.pending_consumable_node = nil
    return node
end

-- ---------------------------------------------------------------------------
-- Hooks (monkey-patches for things without SMODS contexts)
-- ---------------------------------------------------------------------------
-- Build the run-level PvP summary written at end_run. Mirrors hooks.lua's
-- build_pvp_summary; defined here too so the deferred MP finalize and the
-- love.quit path (both in this file) can build it. opponent_end_game_jokers is
-- nil until the async match-end pull lands — the deferred finalize waits for it.
local function build_mp_summary()
    if not (mp and mp.enabled) then return nil end
    local ok, summary = pcall(function()
        return {
            opponent_shop_spending   = mp.opponent_shop_spending(),
            opponent_sells           = mp.opponent_sells(),
            player_reroll_count      = mp.player_reroll_count(),
            player_reroll_cost_total = mp.player_reroll_cost_total(),
            opponent_end_game_jokers = mp.opponent_end_game_jokers(),
            opponent_nemesis_deck    = mp.opponent_nemesis_deck(),
            lobby_config             = mp.lobby_config(),
        }
    end)
    if ok then return summary end
    return nil
end

local deps = {
    capture             = Capture,
    serializer          = Serializer,
    logger              = Logger,
    config              = { player_id = player_id, enabled = enabled },
    recorder            = recorder,
    file_writer         = file_writer,
    state               = run_state,
    mp                  = mp,
    gate                = Gate,
    discard_effect      = DiscardEffect,
    use_consumable_hook = UseConsumableHook,
    pending_node_ref    = pending_node_ref,
}

hooks.register_all(deps)
Logger.info("All hooks registered")

-- ---------------------------------------------------------------------------
-- mod.calculate — SMODS context capture for shop / blind / consumable events
-- ---------------------------------------------------------------------------
local SLOT_MAP = { Small = "small", Big = "big", Boss = "boss" }

-- Safety net for the open_pack polling Event (Bug B). If the engine
-- never emplaces `G.pack_cards.cards` for some reason, the polling
-- closure would otherwise loop forever and leak the pending node. After
-- this many ticks we snapshot whatever is in `G.pack_cards.cards`
-- (possibly empty), send the node, and clear the queue slot. ~10 seconds
-- of wall-clock at gamespeed 1; longer at slower gamespeeds since
-- `G.E_MANAGER` ticks at a gamespeed-aware rate.
local MAX_POLL_FRAMES = 600

-- Consumables whose effect mutates targeted playing cards' rank, suit,
-- enhancement, edition, or seal — or destroys them. Used by the
-- `using_consumeable` handler (Bug C) as the gate for whether to attach
-- `target_cards_after` and `destroyed_cards` to the action payload.
-- Keys match the `name` returned by `Capture.describe_card`
-- (i.e. `card.ability.name`). For non-transforming consumables (Planet
-- cards, Hermit, Temperance, etc.) both fields are omitted from the JSON.
-- See `design.md` Bug C.
local TRANSFORMING_TAROTS = {
    -- Enhancement-applying tarots (target → Enhanced)
    ["The Magician"]    = true,
    ["The Empress"]     = true,
    ["The Hierophant"]  = true,
    ["The Lovers"]      = true,
    ["The Chariot"]     = true,
    ["Justice"]         = true,
    ["The Devil"]       = true,
    ["The Tower"]       = true,
    -- Rank/suit-modifying tarots
    ["Strength"]    = true,
    ["Death"]       = true,
    ["The Star"]    = true,
    ["The Moon"]    = true,
    ["The Sun"]     = true,
    ["The World"]   = true,
    -- Destroying tarot
    ["The Hanged Man"]  = true,
    -- Targeting spectrals (player selects 1 card)
    ["Talisman"]    = true,
    ["Aura"]        = true,
    ["Deja Vu"]     = true,
    ["Trance"]      = true,
    ["Medium"]      = true,
    ["Cryptid"]     = true,
    -- Random-destroy spectrals (no target_cards, but destroyed_cards
    -- is meaningful — they remove cards from hand)
    ["Familiar"]    = true,
    ["Grim"]        = true,
    ["Incantation"] = true,
    ["Immolate"]    = true,
}

local function resolve_blind_slot()
    if not (G and G.GAME) then return nil end

    -- Multiplayer's nemesis blind (the PvP boss) is injected at the BOSS slot
    -- and visually impersonates a normal blind, so on_deck reads "Boss". Catch
    -- the real PvP blind by its key / pvp flag and report it as "pvp" so the
    -- viewer shows the dual PvP score line instead of treating it as a boss.
    -- (MP.is_pvp_boss(): blind.config.blind.key == "bl_mp_nemesis" or blind.pvp.)
    local active = G.GAME.blind
    if active then
        local bkey = active.config and active.config.blind and active.config.blind.key
        if bkey == "bl_mp_nemesis" or active.pvp then return "pvp" end
    end

    -- `blind_on_deck` is set by the engine before `setting_blind` fires and
    -- is the most reliable source at blind-setup time. Use it first.
    -- `G.GAME.blind` may still point to the *previous* blind's object at the
    -- moment `setting_blind` fires (e.g. after a boss blind, `blind.boss` is
    -- still true while `blind_on_deck` has already advanced to "Small").
    local on_deck = G.GAME.blind_on_deck
    if on_deck then
        local mapped = SLOT_MAP[on_deck]
        if mapped then return mapped end
        -- Multiplayer PvP blind uses a different on_deck value.
        local lower = on_deck:lower()
        if lower:find("nemesis") or lower:find("pvp") then return "pvp" end
    end

    -- Fallback: read from the live blind object (reliable mid-blind, e.g.
    -- for contexts that fire after the blind is fully set up).
    local blind = G.GAME.blind
    if blind then
        if blind.boss then return "boss" end
        local name = blind.name or ""
        if name:find("[Ss]mall")   then return "small" end
        if name:find("[Bb]ig")     then return "big"   end
        if name:find("[Nn]emesis") or name:find("[Pp]vp") then return "pvp" end
    end

    return nil
end

local function highlighted_card_ids()
    local ids = {}
    if G and G.hand and G.hand.highlighted then
        for _, target in ipairs(G.hand.highlighted) do
            local id = target.base and target.base.id and tostring(target.base.id) or "unknown"
            ids[#ids + 1] = id
        end
    end
    return ids
end

--- Snapshot the cards the player has highlighted in their hand,
--- returning the full describe_playing_card descriptor for each one
--- (rank, suit, enhancement, edition, seal, perma) rather than just the
--- rank-only base.id.
---
--- We need the full descriptor for tarot/spectral targets because
--- base.id is rank-only — a 5 of Hearts and 5 of Spades both report
--- base.id = 5, so the viewer can't tell them apart from the id alone.
--- The descriptor carries suit + enhancements + edition + seal so we
--- can render the exact card the player picked.
local function highlighted_card_descriptors()
    if not (G and G.hand and G.hand.highlighted) then return {} end
    if not (Capture and Capture.describe_playing_cards) then return {} end
    return Capture.describe_playing_cards(G.hand.highlighted)
end

--- Mark a node as the active effect target. Every newly-created action node
--- calls this; effect-bearing contexts append to whatever is active. Held by
--- reference, so appends after the node is sent still land in the JSON
--- (FileWriter holds nodes by reference).
local function set_active_effect_node(node)
    run_state.active_effect_node = node
end

--- Remove the first entry of `list` whose id matches `id` (in place). Used to
--- reflect a just-sold card in the snapshot: the state photo at selling_card
--- time still includes the card (removal animates a frame later), but we KNOW
--- it's gone, so the sell node's own state shows it gone. Removes one instance.
local function remove_first_by_id(list, id)
    if type(list) ~= "table" or not id then return end
    for i = 1, #list do
        if list[i] and list[i].id == id then table.remove(list, i); return end
    end
end

--- True if `list` already contains an entry with this id.
local function list_has_id(list, id)
    if type(list) ~= "table" then return false end
    for i = 1, #list do if list[i] and list[i].id == id then return true end end
    return false
end

--- Reflect a just-bought consumable/joker in the snapshot. The buying_card
--- context fires BEFORE the card is added to the inventory, so the buy node's
--- own state didn't include the thing you just bought. We know what was bought
--- from the action, so add it (skip if the engine already added it). Mirrors
--- the sell-removal so a buy moment shows the item in your inventory.
local function add_bought_to_state(game_state, action)
    if action.type == "buy_consumable" and action.consumable_id then
        game_state.consumables = game_state.consumables or {}
        if not list_has_id(game_state.consumables, action.consumable_id) then
            game_state.consumables[#game_state.consumables + 1] = {
                id      = action.consumable_id,
                name    = action.consumable_name,
                edition = (action.description and action.description.edition) or "base",
            }
        end
    elseif action.type == "buy_joker" and action.joker_id then
        game_state.jokers = game_state.jokers or {}
        if not list_has_id(game_state.jokers, action.joker_id) then
            game_state.jokers[#game_state.jokers + 1] = {
                id             = action.joker_id,
                name           = action.joker_name,
                slot           = #game_state.jokers,
                edition        = action.edition or "base",
                enhancement    = "none",
                seal           = "none",
                internal_state = {},
            }
        end
    end
end

--- Build a Decision_Node and send it through the recorder.
local function record_action(action_type, action)
    if not recorder:is_active() then return end
    local ok, err = pcall(function()
        local game_state = Capture.build_game_state(action_type)
        -- Settle the snapshot for sells: drop the sold card so the node's own
        -- state reflects the result ("sold Hex" → Hex gone), not the pre-removal
        -- snapshot. We know exactly what was sold from the action itself.
        if action.type == "sell_joker" then
            remove_first_by_id(game_state.jokers, action.joker_id)
        elseif action.type == "sell_consumable" then
            remove_first_by_id(game_state.consumables, action.consumable_id)
        end
        local idx = recorder:next_index()
        local node = { index = idx, state = game_state, action = action }
        set_active_effect_node(node)
        recorder:send(node)
        run_state.last_action_timestamp = os.time()
    end)
    if not ok then
        Logger.error("record_action error (" .. action_type .. "): " .. tostring(err))
    end
end

--- True the first time we're called with `latch_key` since the last
--- blind boundary, false on every subsequent call. Used to dedupe
--- once-per-round contexts that SMODS dispatches multiple times
--- (blind_defeated, end_of_round, starting_shop, etc.).
local function latch_once(latch_key)
    if run_state.emitted_this_round[latch_key] then return false end
    run_state.emitted_this_round[latch_key] = true
    return true
end

--- Content-addressed latch for `end_of_round` dispatches, keyed by
--- (ante, blind_slot). Returns true the first time the key is seen
--- and false afterward.
---
--- We can't reuse `latch_once` here because Steamodded can dispatch
--- `end_of_round` calculate passes AFTER `reset_game_globals(false)`
--- has already wiped `emitted_this_round` for the next blind — see
--- Bug A in design.md. The tuple key plus a separate table that
--- survives `reset_game_globals(false)` keeps the latch stable across
--- that timing window.
local function latch_end_of_round(ante, slot)
    local key = tostring(ante) .. ":" .. tostring(slot)
    if run_state.end_of_round_latched[key] then return false end
    run_state.end_of_round_latched[key] = true
    return true
end

--- Append a pending open_pack node to the FIFO queue and return its
--- monotonic `pending_id`. The id is captured by the deferred Event
--- closure scheduled in the `open_booster` handler so each event reads
--- and clears its own slot, regardless of how many packs are opened
--- back-to-back. See Bug B in design.md.
local function enqueue_pending_pack_node(node)
    run_state.pending_open_pack_seq = run_state.pending_open_pack_seq + 1
    local pending_id = run_state.pending_open_pack_seq
    run_state.pending_open_pack_queue[pending_id] = node
    return pending_id
end

local function buy_action_for(card)
    local ability_set = card.ability and card.ability.set or ""
    local cost        = card.cost or 0
    local description = Capture.describe_card(card)

    if ability_set == "Joker" then
        return {
            type        = "buy_joker",
            joker_id    = description.id,
            joker_name  = description.name,
            rarity      = description.rarity,
            edition     = description.edition,
            cost        = cost,
            description = description,
        }
    elseif ability_set == "Consumeables" or ability_set == "Tarot"
        or ability_set == "Planet"      or ability_set == "Spectral" then
        return {
            type            = "buy_consumable",
            consumable_id   = description.id,
            consumable_name = description.name,
            consumable_set  = description.set,
            cost            = cost,
            description     = description,
        }
    elseif ability_set == "Voucher" then
        return {
            type         = "buy_voucher",
            voucher_id   = description.id,
            voucher_name = description.name,
            cost         = cost,
            description  = description,
        }
    elseif ability_set == "Booster" then
        return {
            type        = "buy_pack",
            pack_id     = description.id,
            pack_name   = description.name,
            pack_kind   = description.pack_kind,
            pack_size   = description.pack_size,
            pack_choose = description.pack_choose,
            cost        = cost,
            description = description,
        }
    end

    -- Unknown set — fall through as joker so we never silently drop a buy
    return {
        type        = "buy_joker",
        joker_id    = description.id,
        joker_name  = description.name,
        cost        = cost,
        description = description,
    }
end

--- Build the action payload for a sold card. Delegates to SellAction so
--- the consumable-vs-joker classification (Requirement 24) lives in a
--- single, unit-testable module instead of being inlined here.
local function sell_action_for(card)
    return SellAction.build(card, Capture)
end


function mod.calculate(self, context, ret)
    -- ── Effects are NOT observed here anymore ───────────────────────────
    -- We used to route SMODS effect contexts (remove_playing_cards,
    -- playing_card_added, card_added, setting_ability, change_rank/suit) onto
    -- the "active" action node to build action.effect.{destroyed,generated,
    -- transformed}. That was fragile: the engine resolves effects on later
    -- event-queue frames, so the "active node" was often stale and effects got
    -- misattributed (a pack-picked joker pinned on the previous consumable,
    -- etc.). It was also unread — the viewer derives effects two reliable ways:
    --   • generated cards / pack picks  → ETL state-diff of consecutive
    --     full-state snapshots (etl/packPicks.js, MV_Shop next-node diff)
    --   • destroyed / transformed cards → action.destroyed_cards /
    --     target_cards_after, written synchronously by the use_consumeable
    --     wrapper (lib/use_consumable_hook.lua), which sees settled state.
    -- So capture's job is just complete per-step snapshots; the diffing lives
    -- in the ETL. (See GAME_MODEL notes on state-diff over async observers.)

    -- Buying a card from the shop.
    --
    -- Record the PRE-purchase wallet consistently. The buying_card context
    -- fires before the charge for jokers/consumables but after it for
    -- vouchers/packs, so reading G.GAME.dollars here would be inconsistent.
    -- The buy-entry hooks (buy_from_shop / use_card) stash the pre-purchase
    -- wallet in run_state.money_before_purchase; we use it so every buy node
    -- carries the wallet as it was BEFORE paying. The viewer then shows the
    -- cost on the correct row (next node's money − this node's money).
    if context.buying_card and context.card then
        local action = buy_action_for(context.card)
        if recorder:is_active() then
            local ok, err = pcall(function()
                local game_state = Capture.build_game_state(action.type)
                if run_state.money_before_purchase ~= nil then
                    game_state.money = run_state.money_before_purchase
                end
                add_bought_to_state(game_state, action)
                local node = {
                    index = recorder:next_index(),
                    state = game_state,
                    action = action,
                }
                set_active_effect_node(node)
                recorder:send(node)
                run_state.last_action_timestamp = os.time()
            end)
            if not ok then
                Logger.error("record_action error (" .. action.type .. "): " .. tostring(err))
            end
        end
    end

    -- Selling a card. Splits into sell_joker / sell_consumable based on
    -- the sold card's ability.set so the viewer can stamp the correct
    -- row (Joker_Strip vs Consumable_Row). See Requirement 24.
    if context.selling_card and context.card then
        local action = sell_action_for(context.card)
        record_action(action.type, action)
    end

    -- Using a consumable.
    --
    -- The pre-effect node is built and sent here synchronously, then
    -- the `Card:use_consumeable` wrapper (installed at startup) reads
    -- the post-effect card state on the same call stack and mutates
    -- this node's `action` in place to add `target_cards_after` and
    -- `destroyed_cards`. FileWriter holds nodes by reference, so those
    -- post-send mutations land in the final JSON.
    --
    -- The wrapper handles random-destroy spectrals (Familiar, Grim,
    -- Incantation, Immolate) uniformly via its own pre-effect full-deck
    -- snapshot, so we don't need to capture hand/deck refs here.
    if context.using_consumeable and context.consumeable then
        local description     = Capture.describe_card(context.consumeable)
        local consumable_set  = description.set or ""
        local consumable_name = description.name or ""
        local targets         = {}
        local target_cards    = {}
        local target_refs     = {}
        -- Planets never target playing cards. Tarot/Spectral often do.
        if consumable_set ~= "Planet" then
            targets      = highlighted_card_ids()
            target_cards = highlighted_card_descriptors()
            -- `target_refs` holds the raw card object references in the
            -- same order as `target_cards`. Never serialized — retained
            -- alongside `target_cards` and `target_card_ids` so future
            -- handlers can re-describe the same cards by identity.
            if G and G.hand and G.hand.highlighted then
                for _, card in ipairs(G.hand.highlighted) do
                    target_refs[#target_refs + 1] = card
                end
            end
        end

        -- Predict the money delta for tarots/spectrals that affect the
        -- wallet. Lets the viewer show "Used Hermit  +$14" without having
        -- to read the next node's state.money (which is unreliable when
        -- multiple ease_dollars events are pending).
        local expected_delta = ConsumableEffect.predict_money_delta(context.consumeable)

        -- Build the node and send it synchronously. We keep a reference
        -- in `run_state.pending_consumable_node` so the
        -- `Card:use_consumeable` wrapper can mutate the action payload
        -- in place — FileWriter holds the node by reference, so
        -- post-effect fields appended after send are still visible at
        -- end_run. Single-slot pending is sufficient because vanilla
        -- Balatro resolves consumables serially.
        if recorder:is_active() then
            local ok, err = pcall(function()
                local game_state = Capture.build_game_state("use_consumable")
                local node = {
                    index = recorder:next_index(),
                    state = game_state,
                    action = {
                        type                  = "use_consumable",
                        consumable_id         = description.id,
                        consumable_name       = consumable_name,
                        consumable_set        = consumable_set,
                        target_card_ids       = targets,
                        target_cards          = target_cards,
                        expected_money_delta  = expected_delta,
                        description           = description,
                    },
                }

                -- The consumable's effects (seal/enhancement/rank/suit change,
                -- destroys, generated jokers) fire as SMODS contexts during
                -- and AFTER use_consumeable resolves — some a frame later. The
                -- effect observers route those to whatever is active, so mark
                -- this node active BEFORE sending. It persists (by reference)
                -- until the next action, so deferred effects still land here.
                set_active_effect_node(node)
                recorder:send(node)

                -- Stash the just-sent node so the Card:use_consumeable
                -- wrapper (installed at startup) can attach
                -- `target_cards_after` and `destroyed_cards` once the
                -- engine resolves the effect. Single-slot is sufficient
                -- because vanilla Balatro resolves consumables serially;
                -- the wrapper reads-and-clears via `pending_node_ref()`.
                run_state.pending_consumable_node = node

                -- No deferred Events — they can interfere with boss blind
                -- mechanics (The Hook, etc.) and prevent game-over from
                -- showing. The Card:use_consumeable wrapper runs on the
                -- same call stack as the engine's effect resolution and
                -- mutates `node.action` in place to add post-effect fields.
            end)
            if not ok then
                Logger.error("record_action error (use_consumable): " .. tostring(err))
            end
        end
    end

    -- Blind started — reliable replacement for G.FUNCS.select_blind, which
    -- the Multiplayer mod bypasses by calling select_blind_ref directly.
    if context.setting_blind then
        local slot = resolve_blind_slot()
        local ante = G and G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante
        local latch_key = tostring(ante) .. "_" .. tostring(slot)
        if slot and ante and not run_state.slot_captured[latch_key] then
            run_state.slot_captured[latch_key]  = true
            run_state.current_blind_slot        = slot
            run_state.current_ante              = ante

            -- NOTE: the skip-slots latch is reset on ante change inside the
            -- context.skip_blind handler, NOT here. Resetting on "small blind
            -- set" was wrong: a player who SKIPS small (and big) never sets
            -- those blinds, so the reset never fired and the ante-1 latch
            -- blocked ante-2's skips entirely.

            local ok, err = pcall(function()
                if not recorder:is_active() then return end
                local game_state = Capture.build_game_state("select_blind")
                game_state.blind_slot   = slot
                local blind_name = G.GAME.blind and G.GAME.blind.name or slot
                game_state.blind_name   = blind_name
                game_state.blind_target = G.GAME.blind and G.GAME.blind.chips or 0

                local action = {
                    type             = "select_blind",
                    blind_slot       = slot,
                    blind_name       = blind_name,
                    chip_requirement = game_state.blind_target,
                    choice           = "play",
                    offered_tag      = Serializer.null,
                    boss_debuff      = Serializer.null,
                }

                local idx = recorder:next_index()
                recorder:send({
                    index = idx,
                    state = game_state,
                    action = action,
                })
            end)
            if not ok then Logger.error("setting_blind error: " .. tostring(err)) end
        end
    end

    -- Blind defeated.
    --
    -- We attach `cash_out_dollars = G.GAME.current_round.dollars` because
    -- Balatro has already computed the cash-out amount by this point
    -- (round_eval populated it). The viewer no longer needs to diff
    -- state.money between this node and the next shop_entered node.
    --
    -- SMODS dispatches `blind_defeated` through every calculate_card_areas
    -- pass, so a single defeat fires mod.calculate multiple times. Latch
    -- so we only emit one node per round.
    if context.blind_defeated then
        if latch_once("blind_beaten") then
            local blind = G and G.GAME and G.GAME.blind or nil
            local cash_out = nil
            local ok_co, value = pcall(function()
                return G and G.GAME and G.GAME.current_round
                    and G.GAME.current_round.dollars
            end)
            if ok_co and type(value) == "number" then cash_out = value end

            local action = {
                type             = "blind_beaten",
                blind_name       = blind and blind.name or nil,
                chips_scored     = G and G.GAME and G.GAME.chips or 0,
                chips_required   = blind and blind.chips or 0,
                cash_out_dollars = cash_out,
            }

            record_action("blind_beaten", action)
            -- Bug E: flush in-progress artifact after blind_beaten so the
            -- viewer can open a live run file at every blind boundary.
            pcall(function() file_writer:flush_partial() end)
        end
    end

    -- Shop opened.
    --
    -- IMPORTANT timing note: tags that decorate shop jokers
    -- (Rare → free Rare joker, Foil/Holo/Poly/Negative → free
    -- editioned joker, Coupon → everything free) fire their effects
    -- inside async `yep` callbacks queued on G.E_MANAGER. By the time
    -- `context.starting_shop` reaches us, those callbacks have NOT yet
    -- run, so reading `card.cost` here would still see the pre-tag
    -- cost.
    --
    -- We defer the snapshot one event-loop tick by enqueueing our own
    -- `Event` after the tag callbacks. The trigger 'after' with delay 0
    -- runs on the very next G.E_MANAGER cycle — late enough to see the
    -- updated `cost`, `edition`, and `couponed` fields, early enough
    -- that no player input can mutate the shop yet.
    -- Shop opened.
    --
    -- Tags that decorate shop jokers (Rare → free Rare joker,
    -- Foil/Holo/Poly/Negative → free editioned joker, Coupon →
    -- everything free) fire their cost-modifying effects inside async
    -- `yep` callbacks queued on G.E_MANAGER. The first time we see
    -- `context.starting_shop`, those callbacks have not yet run, so
    -- `card.cost` still reads the pre-tag value.
    --
    -- We took the simple immediate capture here (deferring the snapshot
    -- via G.E_MANAGER:add_event proved unstable across mod boundaries
    -- — multiplayer's own queue work was hanging the engine on the
    -- post-PvP shop). The viewer detects "couponed" jokers from
    -- `card.ability.couponed` separately, which IS already set
    -- synchronously during shop population.
    if context.starting_shop and latch_once("shop_entered") then
        -- Clear the blind context. The player has finished the prior blind
        -- and entered the shop; subsequent sell/buy/use_consumable/reroll
        -- nodes (and this shop_entered itself) should report blind_slot=null.
        -- The next `setting_blind` re-stamps current_blind_slot for the
        -- upcoming round.
        run_state.current_blind_slot = nil
        record_action("shop_entered", {
            type      = "shop_entered",
            inventory = Capture.snapshot_shop_inventory(),
        })
        pcall(function() file_writer:flush_partial() end)
    end

    -- Reroll shop.
    if context.reroll_shop then
        record_action("reroll_shop", { type = "reroll_shop", cost = context.cost or 0 })
    end

    -- Skip blind tag.
    --
    -- Two challenges here:
    --
    -- 1. SMODS dispatches `skip_blind` through every calculate_card_areas
    --    pass, so a single skip fires mod.calculate multiple times. We
    --    need to dedupe per skip event.
    --
    -- 2. After a Small skip, both Small AND Big are eligible to skip in
    --    the same round. When the player skips Big, `blind_states` now
    --    has BOTH "Small=Skipped" and "Big=Skipped". The slot resolver
    --    iterates pairs() and returns the first match in hash-iteration
    --    order, which can return Small (already-emitted) instead of Big
    --    (newly-skipped) and silently drop the Big skip event.
    --
    -- Solution: track which slots we've already emitted in run_state,
    -- pass that set to SkipBlindAction.build so it skips already-emitted
    -- slots and finds the freshly-skipped one.
    if context.skip_blind then
        run_state.emitted_skip_slots = run_state.emitted_skip_slots or {}
        -- Reset the per-ante skip-slot latch when the ante changes. The latch
        -- exists only to disambiguate Small-vs-Big within ONE ante's
        -- blind-select (SMODS dispatches skip_blind multiple times); across
        -- antes the slots repeat, so a stale latch would silently drop the new
        -- ante's skips. Keyed on ante, not on "small blind set", because a
        -- skipped blind is never set.
        local cur_ante = G and G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante
        if cur_ante ~= run_state.skip_slots_ante then
            run_state.emitted_skip_slots = {}
            run_state.skip_slots_ante    = cur_ante
        end
        local skip_action = SkipBlindAction.build(
            G, Serializer, run_state.emitted_skip_slots
        )
        local skip_slot = skip_action.blind_slot
        if skip_slot and skip_slot ~= Serializer.null then
            -- Mark this slot as emitted before recording so a re-entrant
            -- dispatch can't double-emit. The set is cleared on
            -- reset_game_globals(false) along with emitted_this_round.
            if not run_state.emitted_skip_slots[skip_slot] then
                run_state.emitted_skip_slots[skip_slot] = true
                record_action("skip_blind_tag", skip_action)
            end
        end
    end

    -- Booster pack opened.
    --
    -- The pack cost is on `context.card.cost` (the booster Card's cost)
    -- — verified against Balatro's `Card:open` source. We record the
    -- cost directly on the open_pack action, so we don't need a separate
    -- `buy_from_shop` hook for packs and the viewer always sees the
    -- right deduction on this node.
    --
    -- Timing caveat: in vanilla Balatro, Card:open enqueues the pack
    -- contents into G.pack_cards via an Event with a ~1.3s delay (gated
    -- by G.SETTINGS.GAMESPEED). The `open_booster` context can fire
    -- *before* that event runs, so reading G.pack_cards.cards right now
    -- may return an empty table. We:
    --   1. Build the open_pack node now with metadata + cost.
    --   2. Snapshot `offered` eagerly — typically the engine has already
    --      emplaced the cards, so this captures the right pack's
    --      contents synchronously (matters for back-to-back opens).
    --   3. Schedule a polling Event (delay = 0.0, blockable = false)
    --      that waits until G.pack_cards.cards is populated before
    --      sending the node. Auto-scales with gamespeed because
    --      G.E_MANAGER ticks at a gamespeed-aware rate.
    if context.open_booster then
        local pack_id, pack_name = "p_unknown", "Unknown Pack"
        local pack_kind, pack_size, pack_choose = nil, nil, nil
        local pack_cost = 0
        if context.booster then
            local b = context.booster
            if b.key  then pack_id   = tostring(b.key)  end
            if b.name then pack_name = tostring(b.name) end
            if b.kind then pack_kind = tostring(b.kind) end
            if b.config then
                pack_size   = b.config.extra
                pack_choose = b.config.choose
            end
            -- Vanilla packs hand us the localized name ("Jumbo Standard Pack"),
            -- but some modded packs (e.g. the MP Giga Standard) leave `name` as
            -- the raw center key — their display name lives in localization.
            -- Resolve it from descriptions.Other so we never record a key.
            if type(pack_name) == "string" and pack_name:match("^p_[%w_]+$") then
                local descs = G and G.localization and G.localization.descriptions
                local other = descs and descs.Other
                local loc   = other and other[pack_id]
                if loc and loc.name then pack_name = tostring(loc.name) end
            end
        end
        if context.card and type(context.card.cost) == "number" then
            pack_cost = context.card.cost
        end

        if recorder:is_active() then
            -- Reset the per-pack running counter. ending_pack reads
            -- run_state.current_pack_kind + current_pack_selects to stamp
            -- the window summary on its action; we set the kind here so a
            -- pack with zero picks (e.g. skipped Buffoon) still surfaces
            -- the right kind on close.
            run_state.current_pack_kind    = pack_kind
            run_state.current_pack_selects = 0
            -- Arm the close for THIS pack. ending_booster (SMODS) can fire
            -- multiple times per close, so we need a one-shot — but it must be
            -- re-armed per pack, NOT a per-round latch. The old
            -- latch_once("ending_pack") let only the FIRST pack of a shop emit
            -- a close, so a 2nd pack (e.g. Standard then Celestial) had no
            -- ending_pack and its window couldn't be bracketed.
            run_state.pack_close_pending = true

            -- Snapshot pack contents at open_booster time. If the engine
            -- has already emplaced the cards (the typical case once the
            -- pack-emplace Event has run), this captures the right pack's
            -- contents synchronously — which matters when two opens fire
            -- back-to-back, since each pack's deferred snapshot would
            -- otherwise read whichever state G.pack_cards is in by the
            -- time the Event fires (= the LAST opened pack's contents).
            -- If the contents aren't emplaced yet (gamespeed race), the
            -- snapshot is empty and the deferred Event below re-snapshots.
            local initial_offered = Capture.snapshot_pack_contents()
            -- A bought pack pays for itself BEFORE open_booster fires, so
            -- build_game_state would read POST-pay money — inconsistent with
            -- buy nodes, and it makes the PRECEDING action's forward money-diff
            -- swallow the pack's cost (a Pluto used right before opening an
            -- Arcana pack showed -$5, which was actually the pack price). Use
            -- the pre-pay wallet stashed at buy time, same as buy nodes. Free
            -- tag-granted packs have no buy (cost 0) and their current money is
            -- already correct, so only override for paid packs.
            local open_state = Capture.build_game_state("open_pack")
            if pack_cost and pack_cost > 0 and run_state.money_before_purchase ~= nil then
                open_state.money = run_state.money_before_purchase
            end
            local pending_node = {
                index = recorder:next_index(),
                state = open_state,
                action = {
                    type        = "open_pack",
                    pack_id     = pack_id,
                    pack_name   = pack_name,
                    pack_kind   = pack_kind,
                    pack_size   = pack_size,
                    pack_choose = pack_choose,
                    cost        = pack_cost,
                    offered     = initial_offered,
                },
            }
            -- Enqueue the pending node and capture its monotonic id so the
            -- deferred Event closure can read/clear its own slot. Replaces
            -- the old single-slot `pending_open_pack_node` which dropped
            -- the first pack whenever a second was opened back-to-back.
            local pending_id = enqueue_pending_pack_node(pending_node)

            -- Polling Event keyed by `pending_id`. The previous fixed
            -- `delay = 1.5` Event didn't scale with `G.SETTINGS.GAMESPEED`:
            -- at slow gamespeeds the engine's pack-emplace Event (delay
            -- = 1.3s × √GAMESPEED) fires AFTER our snapshot, so the
            -- snapshot reads an empty `G.pack_cards.cards` and `offered`
            -- ends up empty. By scheduling a `delay = 0.0` Event that
            -- returns `false` until pack contents are visible, we wait
            -- the right amount of time at any gamespeed — `G.E_MANAGER`
            -- ticks events at a gamespeed-aware rate.
            --
            -- The closure captures `pending_id` plus a local
            -- `frames_polled` counter so the safety-net timeout (added
            -- in task 17 as MAX_POLL_FRAMES) can bail out if the engine
            -- never emplaces cards.
            local frames_polled = 0
            G.E_MANAGER:add_event(Event({
                trigger   = "after",
                delay     = 0.0,
                blocking  = false,
                blockable = false,
                func = function()
                    local should_keep_polling = false
                    pcall(function()
                        local node = run_state.pending_open_pack_queue[pending_id]
                        -- Already flushed by another path
                        -- (reset_game_globals(false), ending_booster,
                        -- love.quit, etc.). Nothing to do.
                        if node == nil then return end

                        frames_polled = frames_polled + 1

                        -- Safety net: if we've polled this many ticks
                        -- without `G.pack_cards.cards` ever populating,
                        -- give up and send the node with whatever is
                        -- there (possibly empty). Prevents a stuck
                        -- pending node from leaking forever if the
                        -- engine's pack-emplace Event never fires.
                        if frames_polled >= MAX_POLL_FRAMES then
                            node.action.offered = Capture.snapshot_pack_contents()
                            local timeout_full_deck = Capture.snapshot_full_deck()
                            if timeout_full_deck and #timeout_full_deck > 0 then
                                node.state.full_deck = timeout_full_deck
                            end
                            recorder:send(node)
                            run_state.pending_open_pack_queue[pending_id] = nil
                            return
                        end

                        -- Typical case: the at-enqueue snapshot already
                        -- captured the pack contents because the engine
                        -- emplaced `pack_cards` before `open_booster`
                        -- fired. Send the node as-is. Crucially, this
                        -- preserves per-pack contents when two opens
                        -- fire back-to-back — without this branch each
                        -- polling Event would re-snapshot from the
                        -- *current* `G.pack_cards.cards` and both nodes
                        -- would carry the LAST opened pack's contents.
                        if node.action.offered and #node.action.offered > 0 then
                            -- Arcana / Spectral packs also draw cards
                            -- into G.hand.cards when they open. The
                            -- at-enqueue full_deck snapshot may have
                            -- caught an empty hand area (the engine
                            -- gates the draw on a delayed Event), so
                            -- refresh once everything is emplaced.
                            local refreshed_full_deck = Capture.snapshot_full_deck()
                            if refreshed_full_deck and #refreshed_full_deck > 0 then
                                node.state.full_deck = refreshed_full_deck
                            end
                            recorder:send(node)
                            run_state.pending_open_pack_queue[pending_id] = nil
                            return
                        end

                        -- Race case: the at-enqueue snapshot was empty
                        -- (engine hadn't emplaced cards yet). Wait until
                        -- `G.pack_cards.cards` becomes non-empty, then
                        -- snapshot. Auto-scales with gamespeed.
                        local cards_ready = G
                            and G.pack_cards
                            and G.pack_cards.cards
                            and #G.pack_cards.cards > 0
                        if cards_ready then
                            node.action.offered = Capture.snapshot_pack_contents()
                            -- Arcana / Spectral packs draw cards INTO
                            -- G.hand.cards when they open (the player
                            -- picks from hand to apply tarots / spectrals).
                            -- That draw is gated on the same Event the
                            -- pack-emplace is gated on, so the at-enqueue
                            -- full_deck caught an empty hand area.
                            -- Re-snapshot now so the viewer can render
                            -- the cards the player will be picking from.
                            local refreshed_full_deck = Capture.snapshot_full_deck()
                            if refreshed_full_deck and #refreshed_full_deck > 0 then
                                node.state.full_deck = refreshed_full_deck
                            end
                            recorder:send(node)
                            run_state.pending_open_pack_queue[pending_id] = nil
                            return
                        end

                        -- Still no cards. Keep polling — returning
                        -- `false` from the Event func tells G.E_MANAGER
                        -- to tick this event again on the next frame.
                        should_keep_polling = true
                    end)
                    return not should_keep_polling
                end,
            }))
        end
    end

    -- Player left the shop. We don't snapshot remaining inventory here:
    -- shop_entered already captured the full starting inventory and every
    -- buy/reroll/use/sell since produces an action that mutates it, so
    -- the viewer can derive "what was on offer when the player walked
    -- away" by replaying. The bare action marks the phase boundary.
    if context.ending_shop and latch_once("ending_shop") then
        record_action("ending_shop", { type = "ending_shop" })
    end

    -- Player closed a booster pack. Same reasoning as ending_shop —
    -- open_pack carried the offered list, select_from_pack records the
    -- pick, the unpicked cards are just (offered \ picked).
    --
    -- Drain any still-pending open_pack node first so its node lands
    -- BEFORE the ending_pack node (preserves the natural pack ordering
    -- in the captured node sequence). See Bug B in design.md.
    -- Per-pack one-shot (re-armed on each open_booster). NOT a per-round latch:
    -- a shop can open several packs, and each must emit its own close.
    if context.ending_booster and run_state.pack_close_pending then
        run_state.pack_close_pending = false
        flush_pending_pack_queue()
        -- Stamp the pack-window summary. Replaces the viewer's old
        -- `derived.pack_group` ETL deriver: now the viewer reads kind
        -- and selects directly off the ending_pack action.
        record_action("ending_pack", {
            type             = "ending_pack",
            pack_kind        = run_state.current_pack_kind,
            selects_in_pack  = run_state.current_pack_selects or 0,
        })
        run_state.current_pack_kind    = nil
        run_state.current_pack_selects = 0
    end

    -- PvP round ended (multiplayer-only). Fires when both players have
    -- finished a Boss/PvP blind. The state we capture here carries the
    -- final scores, lives changes, and who won via state.pvp.
    if context.mp_end_of_pvp and latch_once("pvp_round_ended") then
        local pvp_state = Capture.build_game_state("pvp_round_ended")
        local won_round = false
        if mp and mp.enabled and pvp_state.pvp then
            -- Scores can be plain numbers OR decoded INSANE_INT strings
            -- ("4.07e12"), so parse with tonumber before comparing — the old
            -- `type == "number"` guard left won_round false for big scores.
            -- Compare against opponent_hand_score (enemy.score = THIS blind),
            -- not the all-time-max running score.
            local me  = tonumber(pvp_state.pvp.player_running_score)
            local opp = tonumber(pvp_state.pvp.opponent_hand_score)
                or tonumber(pvp_state.pvp.opponent_running_score)
            if me and opp then
                won_round = me > opp
            end
        end
        record_action("pvp_round_ended", {
            type      = "pvp_round_ended",
            won_round = won_round,
        })
        -- Bug E Open Question 5 resolution: PvP runs flush at the same
        -- per-blind granularity as solo runs. Without this, a PvP run
        -- loses every PvP blind's worth of nodes on a mid-blind crash.
        pcall(function() file_writer:flush_partial() end)
    end

    -- Tag added to the player's tag stack. Fires for skip-blind picks,
    -- Double Tag spawns, Diet Cola sales, Anaglyph deck post-boss, and
    -- any other source of tag acquisition. Lets the viewer show the
    -- complete provenance of every tag the player ends up holding.
    --
    -- We capture every add — even when redundant with skip_blind_tag —
    -- because the viewer can collapse adjacent events but cannot
    -- recover lost ones.
    --
    -- Per-tag latch (not per-type) because multiple tags can legitimately
    -- be added in one round (e.g. Double Tag fires and creates another).
    -- We dedupe by tag_id + tag's internal numeric ID so the same tag
    -- instance can't double-record.
    if context.tag_added then
        local tag = context.tag_added
        local tag_uid = tostring(tag.key or "tag_unknown") .. ":" .. tostring(tag.ID or "")
        if latch_once("tag_added:" .. tag_uid) then
            -- Detect "primary skip tag" so the viewer can suppress the
            -- redundant tag_added row above the corresponding skip_blind_tag
            -- row. Engine order (button_callbacks.lua:2740-2782, G.FUNCS.skip_blind):
            --   1. G.CONTROLLER.locks.skip_blind = true   (line 2742)
            --   2. add_tag(primary)                        (line 2757) ← context.tag_added fires HERE, SYNC
            --   3. blind_states[skipped] = 'Skipped'       (line 2760)
            --   4. queued event fires context.skip_blind later (line 2769)
            -- The tag the player CHOSE is added synchronously at step 2, while
            -- our hooks.lua skip_blind wrapper holds run_state.in_skip_blind.
            -- A Double Tag DUPLICATE is added on a later event-queue frame
            -- (tag.lua:327, deferred via Tag:yep), after skip_blind returns and
            -- the flag is cleared. This sync/async boundary is deterministic.
            --
            -- (The old heuristic — "no blind flagged 'Skipped' yet" — was wrong
            -- on the second consecutive skip: the first blind already reads
            -- "Skipped", so the chosen tag was misclassified as a duplicate and
            -- leaked through as a stray "Got <tag>" row. See bug: double-skip.)
            local from_skip = run_state.in_skip_blind == true
            record_action("tag_added", {
                type      = "tag_added",
                tag_id    = tag.key  and tostring(tag.key)  or "tag_unknown",
                tag_name  = tag.name and tostring(tag.name) or "Unknown Tag",
                ante      = tag.ante,
                from_skip = from_skip or nil,
            })
        end
    end

    -- End of round — we already capture blind_beaten via context.blind_defeated,
    -- but end_of_round adds the `game_over` flag (true when this round's
    -- failure is going to end the run) and `beat_boss`. Useful for the
    -- viewer to mark a final loss explicitly instead of inferring from
    -- the absence of a follow-up shop_entered.
    --
    -- Same multi-dispatch pattern as blind_defeated, but with a
    -- content-addressed latch keyed by (ante, blind_slot). Steamodded
    -- can dispatch end_of_round AFTER reset_game_globals(false) wipes
    -- emitted_this_round, so a per-round latch is not enough — see
    -- Bug A in design.md.
    if context.end_of_round then
        if latch_end_of_round(run_state.current_ante, run_state.current_blind_slot) then
            -- Engine truth (balatro-engine, state_events.lua:87-122):
            --   * context.beat_boss does NOT exist in vanilla — it's mod-
            --     injected and unreliable (came through TRUE on a loss). Dropped.
            --   * context.game_over is real: it means "did NOT meet the chip
            --     requirement", already accounting for a Mr. Bones save. Keep it
            --     as the run-ending flag.
            --   * "cleared this blind by score" is authoritative from game state:
            --     G.GAME.chips >= G.GAME.blind.chips. Record it separately
            --     (false on a Mr. Bones save even though the run continues).
            local won_blind, is_boss = false, false
            pcall(function()
                local g = G and G.GAME
                if g then
                    won_blind = (g.chips or 0) >= (g.blind and g.blind.chips or 0)
                    if g.blind and g.blind.get_type then
                        is_boss = g.blind:get_type() == "Boss"
                    end
                end
            end)
            record_action("end_of_round", {
                type      = "end_of_round",
                won_blind = won_blind,
                is_boss   = is_boss,
                game_over = context.game_over and true or false,
            })
        end
    end

end

-- ---------------------------------------------------------------------------
-- love.update — flush logger, retry deferred hooks, poll opponent scoring
-- ---------------------------------------------------------------------------
local original_love_update = love.update

love.update = function(dt)
    if original_love_update then original_love_update(dt) end

    hooks.retry_deferred_hooks(Logger)

    -- Idle-flush detector (Bug F): if the player returned to the main
    -- menu without triggering love.quit (e.g. via the in-game menu),
    -- the in-memory buffer would be lost. After 30s idle in MENU state
    -- we flush as "interrupted" so the run is preserved.
    if recorder:is_active() and run_state.last_action_timestamp then
        local ok_state, in_menu = pcall(function()
            return G and G.STATE and G.STATES and G.STATE == G.STATES.MENU
        end)
        if ok_state and in_menu then
            local idle_seconds = os.time() - run_state.last_action_timestamp
            if idle_seconds > 30 then
                pcall(function()
                    local final_ante = nil
                    local ok2, v = pcall(function()
                        return G and G.GAME and G.GAME.round_resets
                            and G.GAME.round_resets.ante
                    end)
                    if ok2 and type(v) == "number" then final_ante = v end
                    recorder:end_run("interrupted", final_ante, nil)
                    Logger.info("Antelytics: idle-flush triggered (30s in MENU)")
                end)
                run_state.last_action_timestamp = nil
            end
        end
    end

    -- Deferred MP finalize: win_game / create_UIBox_game_over set
    -- run_state.pending_mp_end (instead of finalizing) so we can wait a few
    -- frames for the asynchronous end-of-match pull — the opponent's final
    -- jokers (MP.end_game_jokers_payload) arrive over the network after our end
    -- screen opens. Finalize as soon as they land, or after a ~3s timeout so a
    -- missing pull (client dismissed the screen too fast, opponent disconnected)
    -- can never hang the run. The frame budget is generous; the payload normally
    -- arrives within a handful of frames.
    if recorder:is_active() and run_state.pending_mp_end then
        local p = run_state.pending_mp_end
        p.frames = (p.frames or 0) + 1
        local jokers = mp and mp.enabled and mp.opponent_end_game_jokers() or nil
        local deck   = mp and mp.enabled and mp.opponent_nemesis_deck() or nil
        -- Finalize once BOTH the opponent's jokers and deck have landed (they
        -- arrive a few frames apart), or after the timeout so a slow/missing
        -- pull can't hang the run.
        if (jokers ~= nil and deck ~= nil) or p.frames > 180 then
            local summary = build_mp_summary() or {}
            -- Prefer the freshly-read values; build_mp_summary may have read them
            -- a frame earlier as nil.
            if jokers ~= nil then summary.opponent_end_game_jokers = jokers end
            if deck   ~= nil then summary.opponent_nemesis_deck    = deck end
            pcall(function() recorder:end_run(p.outcome, p.final_ante, summary) end)
            run_state.pending_mp_end = nil
            Logger.info("Antelytics: finalized MP run (" .. tostring(p.outcome)
                .. ", opp jokers: " .. (jokers and tostring(#jokers) or "—")
                .. ", opp deck: " .. (deck and tostring(#deck) or "—") .. ")")
        end
    end

    -- Opponent PvP scoring detection: watch for MP.GAME.enemy.hands decreasing.
    if recorder:is_active() and mp and mp.enabled then
        local ok, enemy = pcall(function()
            local MP = rawget(_G, "MP")
            return MP and MP.GAME and MP.GAME.enemy
        end)
        if ok and enemy then
            local current_hands = type(enemy.hands) == "number" and enemy.hands or nil
            if current_hands ~= nil then
                if run_state.last_opponent_hands == nil then
                    run_state.last_opponent_hands = current_hands
                elseif current_hands < run_state.last_opponent_hands then
                    -- Opponent played a hand
                    pcall(function()
                        -- enemy.score is an INSANE_INT table
                        -- {coeffiocient,exponent,e_count} (no `.value` field —
                        -- the old check left running_total nil on every node)
                        -- and it EASES toward the new total. Go through the
                        -- accessor, which resolves the ease target and decodes
                        -- the triple, so each per-hand total is the settled
                        -- value, not a mid-animation frame.
                        local opp_score = mp.opponent_score()

                        local idx = recorder:next_index()
                        recorder:send({
                            index = idx,
                            state = Capture.build_game_state("opponent_hand_scored"),
                            action = {
                                type          = "opponent_hand_scored",
                                player        = "opponent",
                                hands_left    = current_hands,
                                running_total = opp_score,
                            },
                        })
                    end)
                    run_state.last_opponent_hands = current_hands
                elseif current_hands > run_state.last_opponent_hands then
                    -- Hands reset for a new blind
                    run_state.last_opponent_hands = current_hands
                end
            end
        end
    end

    Logger.flush()
end

-- ---------------------------------------------------------------------------
-- love.quit
-- ---------------------------------------------------------------------------
local original_love_quit = love.quit

love.quit = function()
    Logger.info("Antelytics shutting down")
    -- Drain any still-pending open_pack nodes before we finalise the
    -- run — otherwise their polling Events would be silently dropped
    -- when the engine tears down. See Bug B in design.md.
    pcall(flush_pending_pack_queue)
    -- If a run is still in progress (player closed the game cleanly
    -- mid-run), flush the in-memory buffer to disk as an interrupted
    -- run. This only fires on a clean love.quit — if the OS kills
    -- the process or the game crashes, the in-memory buffer is lost.
    if recorder:is_active() then
        local final_ante = nil
        local ok, value = pcall(function()
            return G and G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante
        end)
        if ok and type(value) == "number" then final_ante = value end
        if run_state.pending_mp_end then
            -- A match ended and we were still waiting for the opponent's
            -- end-game pull when the player quit. Finalize with the REAL
            -- outcome (win/loss), not "interrupted", and whatever build data
            -- has arrived by now.
            local p = run_state.pending_mp_end
            pcall(function()
                recorder:end_run(p.outcome, p.final_ante or final_ante, build_mp_summary())
            end)
            run_state.pending_mp_end = nil
            Logger.info("Antelytics: finalised deferred MP run on quit (" .. tostring(p.outcome) .. ")")
        else
            pcall(function()
                recorder:end_run("interrupted", final_ante, build_mp_summary())
            end)
            Logger.info("Antelytics: finalised interrupted run on quit")
        end
    end
    Logger.flush()
    if original_love_quit then return original_love_quit() end
end

Logger.info("Antelytics initialized successfully")
Logger.flush()
