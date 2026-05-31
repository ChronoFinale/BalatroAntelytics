--- spec/open_pack_queue_spec.lua
---
--- Bug B — Empty `open_pack.offered` (queue + polling exploration tests)
---
--- Exploration tests for the pack-queue and polling defect documented in
--- `.kiro/specs/capture-pipeline-fixes/bugfix.md` Requirement 1.2 / 1.3
--- and detailed in `design.md` Bug B.
---
--- The unfixed `mod.calculate(open_booster)` handler in `main.lua`:
---   1. stores the pending node in a single slot
---      (`run_state.pending_open_pack_node`) — a second pack opened
---      back-to-back overwrites the first one and the first node is lost;
---   2. schedules a single, fixed-delay `Event` (`delay = 1.5`) that fires
---      once and reads `G.pack_cards.cards` whether or not the engine has
---      populated it yet — at slow gamespeeds the snapshot lands BEFORE
---      Balatro emplaces the pack contents, so `offered` is empty;
---   3. has no `flush_pending_pack_queue` helper, so a
---      `reset_game_globals(false)` between `open_booster` and the
---      deferred snapshot wipes the pending slot and the node is lost.
---
--- Counterexample on UNFIXED code (proves the bug exists):
---
---   Scenario 2 (back-to-back packs, single-slot overwrite):
---     two `open_booster` dispatches with distinct `pack_id`s ->
---     the second pack overwrites `pending_open_pack_node`, then the
---     deferred Event fires twice but only finds one pending node ->
---     exactly one `open_pack` Decision_Node is recorded (we expect
---     two — one per opened pack).
---
---     Observed on unfixed code: 1 `open_pack` node, carrying the
---     SECOND pack's `pack_id` and `offered`. The first pack is lost.
---
---   Scenario 3 (flush via reset_game_globals(false)):
---     one `open_booster` dispatch followed by `reset_game_globals(false)`
---     fired before the deferred Event has run -> on unfixed code
---     `reset_game_globals(false)` clears `pending_open_pack_node`, the
---     deferred Event finds nothing to send, and the node is lost.
---     Observed: 0 `open_pack` nodes (we expect 1, snapshotted at flush
---     time with whatever `snapshot_pack_contents` returns).
---
---   Scenario 4 (poll timeout):
---     one `open_booster` dispatch with `G.pack_cards.cards` left empty
---     for many ticks -> on unfixed code the single-shot Event fires on
---     its first tick, snapshots EMPTY, and is done. With the fix the
---     polling Event waits up to `MAX_POLL_FRAMES = 600` ticks before
---     giving up. On the unfixed code the test still records ONE node
---     so the count assertion passes, but the test ALSO asserts the
---     polling-Event semantics by ensuring a tick BEFORE the timeout
---     with empty pack_cards keeps the node pending — which the
---     single-shot unfixed Event violates.
---
--- Test mechanics: same harness pattern as `end_of_round_latch_spec.lua`.
--- We mock `love`, `SMODS`, `G`, and friends; load `main.lua`; and replace
--- `Capture.snapshot_pack_contents` with a controllable stub that returns
--- whatever `G.pack_cards.cards` looks like at call time (mirroring the
--- real shape).
---
--- _Validates: Requirements 2.2, 2.3_

package.path = package.path .. ";./lib/?.lua;./Antelytics/lib/?.lua"

-- ---------------------------------------------------------------------------
-- Pre-load FileWriter and Recorder so we can patch their factories before
-- main.lua instantiates them. main.lua resolves them via SMODS.load_file,
-- which we control below.
-- ---------------------------------------------------------------------------
local FileWriter = assert(loadfile("lib/file_writer.lua"))()
local Recorder   = assert(loadfile("lib/recorder.lua"))()

local spy_writer
FileWriter.new = function(_deps)
    spy_writer = {
        nodes      = {},
        run_id     = nil,
        outcome    = nil,
        start_run  = function(self, run_id) self.run_id = run_id; self.nodes = {} end,
        append_node = function(self, node) self.nodes[#self.nodes + 1] = node end,
        end_run    = function(self, outcome) self.outcome = outcome end,
        recover_orphan_runs = function() return 0 end,
        save_path  = function() return "/tmp" end,
    }
    return spy_writer
end

local our_recorder
local original_recorder_new = Recorder.new
Recorder.new = function(deps)
    our_recorder = original_recorder_new(deps)
    return our_recorder
end

-- ---------------------------------------------------------------------------
-- love stubs — file_writer reads love.data / love.filesystem at load time
-- and main.lua reassigns love.update / love.quit.
-- ---------------------------------------------------------------------------
_G.love = {
    update     = nil,
    quit       = nil,
    data       = { compress = function(_, _, data) return data end },
    filesystem = {
        createDirectory = function() return true end,
        write           = function() return true end,
        read            = function() return nil end,
    },
    thread     = {
        newThread  = function() return { start = function() end } end,
        getChannel = function() return { push = function() end, pop = function() end } end,
    },
    timer      = { getTime = function() return 0 end },
}

-- ---------------------------------------------------------------------------
-- Game / global stubs hooks.lua tries to wrap.
-- ---------------------------------------------------------------------------
_G.Game                   = setmetatable({ start_run = function() end },
                                          { __index = function() return function() end end })
_G.win_game               = function() end
_G.create_UIBox_game_over = function() end

-- ---------------------------------------------------------------------------
-- Event manager stub. We give the test direct control over when scheduled
-- events fire via tick_events_once(). Each event is the table that Event(opts)
-- returned (we make Event(opts) return opts), with a `func` field. tick_events_once
-- calls each event's `func()` and removes it when the func returns true —
-- mirroring G.E_MANAGER's contract.
-- ---------------------------------------------------------------------------
_G.Event = function(opts) return opts end

local scheduled_events = {}

local function reset_event_queue()
    scheduled_events = {}
end

local function make_fake_E_MANAGER()
    return {
        add_event = function(_, ev) scheduled_events[#scheduled_events + 1] = ev end,
    }
end

--- Run every queued event's func once. Events whose func returns true are
--- removed from the queue. Events that return false stay queued for the
--- next tick — that's the polling-Event contract the Bug B fix relies on.
local function tick_events_once()
    local survivors = {}
    for _, ev in ipairs(scheduled_events) do
        local ok, done = pcall(function() return ev.func() end)
        if not (ok and done == true) then
            survivors[#survivors + 1] = ev
        end
    end
    scheduled_events = survivors
end

--- Run the queue to completion (until empty or hard cap hit). Used to
--- "advance time" past any single deferred snapshot. Hard cap exceeds
--- MAX_POLL_FRAMES = 600 so a polling Event hitting its safety net still
--- terminates inside this helper.
local function drain_events(max_iterations)
    max_iterations = max_iterations or 700
    for _ = 1, max_iterations do
        if #scheduled_events == 0 then return end
        tick_events_once()
    end
end

-- ---------------------------------------------------------------------------
-- Build a fake G that supports the field reads `mod.calculate` and
-- `Capture.build_game_state` perform.
-- ---------------------------------------------------------------------------
local function build_fake_G()
    return {
        STATE        = 0,
        STATES       = {},
        E_MANAGER    = make_fake_E_MANAGER(),
        SETTINGS     = { GAMESPEED = 1 },
        FUNCS        = {
            play_cards_from_highlighted    = function() end,
            evaluate_play                  = function() end,
            discard_cards_from_highlighted = function() end,
            select_from_pack               = function() end,
            use_card                       = function() end,
        },
        GAME         = {
            round_resets  = { ante = 1, blind_choices = {}, blind_tags = {} },
            blind         = {
                name   = "Small Blind",
                chips  = 100,
                config = { blind = { boss = false, key = "bl_small", name = "Small Blind" } },
            },
            blind_on_deck = "Small",
            chips         = 0,
            dollars       = 4,
            current_round = { hands_left = 4, discards_left = 3, dollars = 5 },
            pseudorandom  = { seed = "TESTSEED" },
            vouchers      = {},
            hands         = {},
            tags          = {},
        },
        hand          = { cards = {}, highlighted = {} },
        deck          = { cards = {} },
        discard       = { cards = {} },
        play          = { cards = {} },
        jokers        = { cards = {} },
        consumeables  = { cards = {} },
        shop_jokers   = { cards = {} },
        shop_vouchers = { cards = {} },
        shop_booster  = { cards = {} },
        shop_tarot    = { cards = {} },
        pack_cards    = { cards = {} },
    }
end

_G.G = build_fake_G()

-- ---------------------------------------------------------------------------
-- SMODS stub. main.lua resolves submodules via SMODS.load_file. For the
-- two factories we want to spy on we hand back the patched modules.
-- ---------------------------------------------------------------------------
-- Cross-platform temp dir + mkdir. The spec was originally Mac-only:
-- hardcoded /tmp paths and `mkdir -p` don't work in Windows cmd.exe.
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local function temp_path(name)
    if IS_WINDOWS then
        local base = (os.getenv("TEMP") or "C:/Temp"):gsub("\\", "/")
        return base .. "/" .. name
    end
    return "/tmp/" .. name
end
local function ensure_dir(path)
    if IS_WINDOWS then
        os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute("mkdir -p " .. path)
    end
end

local TEST_ROOT = temp_path("dt_test_pack")

local mod_table = {
    config = { player_id = "tester", enabled = true },
    path   = TEST_ROOT .. "/",
}

ensure_dir(TEST_ROOT .. "/log")

-- Cache loaded modules so we can patch them post-main-load and have
-- the patches visible to the same Capture instance main.lua holds.
local module_cache = {}
local function load_cached(short)
    if module_cache[short] == nil then
        module_cache[short] = assert(loadfile("lib/" .. short))()
    end
    return module_cache[short]
end

_G.SMODS = {
    current_mod = mod_table,
    load_file   = function(rel)
        local short = rel:gsub("^lib/", "")
        if short == "file_writer.lua" then return function() return FileWriter end end
        if short == "recorder.lua"    then return function() return Recorder    end end
        return function() return load_cached(short) end
    end,
}

-- ---------------------------------------------------------------------------
-- Run main.lua. After this, mod.calculate / mod.reset_game_globals exist
-- and our_recorder + spy_writer are populated.
-- ---------------------------------------------------------------------------
assert(loadfile("main.lua"))()

assert(type(mod_table.calculate) == "function",
    "main.lua did not define mod.calculate")
assert(type(mod_table.reset_game_globals) == "function",
    "main.lua did not define mod.reset_game_globals")
assert(our_recorder, "Recorder factory was not invoked by main.lua")
assert(spy_writer,   "FileWriter factory was not invoked by main.lua")

-- ---------------------------------------------------------------------------
-- Replace Capture.snapshot_pack_contents so the test can verify exactly
-- which cards the snapshot read at fire-time. We snapshot whatever
-- G.pack_cards.cards looks like by deep-copying the descriptors into a
-- new array — same shape the real Capture call returns.
--
-- Use the cached Capture instance main.lua loaded so our patch is the
-- one main.lua's deferred Event closure invokes.
-- ---------------------------------------------------------------------------
local Capture = module_cache["capture.lua"]
assert(Capture, "Capture module was not loaded by main.lua")
Capture.snapshot_pack_contents = function()
    local out = {}
    if G and G.pack_cards and G.pack_cards.cards then
        for _, c in ipairs(G.pack_cards.cards) do
            -- Cards in the test fixture are plain descriptor tables.
            -- Copy by value so the test asserts a stable snapshot.
            local copy = {}
            for k, v in pairs(c) do copy[k] = v end
            out[#out + 1] = copy
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function count_nodes_of_type(action_type)
    local n = 0
    for _, node in ipairs(spy_writer.nodes) do
        if node.action and node.action.type == action_type then
            n = n + 1
        end
    end
    return n
end

local function open_pack_nodes()
    local out = {}
    for _, node in ipairs(spy_writer.nodes) do
        if node.action and node.action.type == "open_pack" then
            out[#out + 1] = node
        end
    end
    return out
end

--- Drive a `setting_blind` dispatch so run_state.current_ante /
--- current_blind_slot are non-nil before we exercise pack opens.
local function dispatch_setting_blind(ante, slot_label, blind_name)
    G.GAME.round_resets.ante = ante
    G.GAME.blind_on_deck     = ({ small = "Small", big = "Big", boss = "Boss" })[slot_label]
    G.GAME.blind = {
        name   = blind_name,
        chips  = 100,
        config = { blind = { boss = (slot_label == "boss"), key = "bl_" .. slot_label, name = blind_name } },
    }
    mod_table.calculate(mod_table, {
        setting_blind = true,
        blind         = G.GAME.blind,
    })
end

--- Reset back to a clean per-test baseline.
local function fresh_round()
    if our_recorder:is_active() then
        our_recorder:end_run("interrupted", 1, nil)
    end
    spy_writer.nodes = {}
    reset_event_queue()
    G.pack_cards = { cards = {} }
    our_recorder:start_run("TEST_RUN_PACK", "tester", "TESTSEED", 1700000000, "solo")
    mod_table.reset_game_globals(true)
    dispatch_setting_blind(1, "small", "Small Blind")
    spy_writer.nodes = {}
end

--- Dispatch an open_booster context. The pack_id parameter lets each test
--- distinguish the first pack from the second when scenarios chain multiple
--- opens before any deferred snapshot fires.
local function dispatch_open_booster(pack_id, pack_name, pack_kind, pack_cost)
    mod_table.calculate(mod_table, {
        open_booster = true,
        booster      = {
            key    = pack_id,
            name   = pack_name or pack_id,
            kind   = pack_kind or "Buffoon",
            config = { extra = 2, choose = 1 },
        },
        card = { cost = pack_cost or 4 },
    })
end

--- Simulate Balatro's deferred pack-emplace by populating G.pack_cards.cards
--- with N stub descriptors tagged with the given marker so the test can
--- verify which pack's contents the snapshot saw.
local function populate_pack_cards(marker, n)
    local cards = {}
    for i = 1, n do
        cards[i] = { id = "j_test_" .. marker .. "_" .. tostring(i), name = marker .. " #" .. tostring(i) }
    end
    G.pack_cards.cards = cards
end

local function clear_pack_cards()
    G.pack_cards.cards = {}
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("Bug B — open_pack queue and polling", function()

    before_each(function()
        fresh_round()
    end)

    -- Scenario 1: one pack opened with G.pack_cards initially empty, then
    -- populated before the deferred snapshot. With the fix's polling Event,
    -- the snapshot waits until cards are populated. With the unfixed
    -- single-shot Event, scenario 1 either passes (if we populate before
    -- the only tick) or fails (if we tick once before populate). Per the
    -- task brief we structure it so it passes on both — populate first,
    -- THEN tick — to keep this scenario as the baseline-correct case.
    it("scenario 1: single pack populated before deferred fire records one node with populated offered", function()
        clear_pack_cards()
        dispatch_open_booster("p_buffoon_1")

        -- Engine emplaces pack contents BEFORE the deferred snapshot fires.
        populate_pack_cards("buffoon1", 2)
        drain_events()

        local nodes = open_pack_nodes()
        assert.are.equal(1, #nodes,
            "expected exactly one open_pack node for one open_booster dispatch")
        assert.are.equal("p_buffoon_1", nodes[1].action.pack_id)
        assert.is_table(nodes[1].action.offered)
        assert.are.equal(2, #nodes[1].action.offered,
            "snapshot must include both emplaced pack cards")
        assert.are.equal("buffoon1 #1", nodes[1].action.offered[1].name)
    end)

    -- Scenario 2 — THE BUG. Two packs back-to-back before either deferred
    -- snapshot fires. Single-slot pending_open_pack_node means the second
    -- open_booster overwrites the first. When the deferred Events run,
    -- the first finds pack #2 in the slot, snapshots and sends it; the
    -- second finds the slot empty (already cleared) and does nothing.
    -- Net: one node, with pack #2's id. Pack #1 is lost.
    --
    -- Counterexample (UNFIXED): 1 open_pack node with pack_id == "p_buffoon_2".
    -- Expected (FIXED)        : 2 open_pack nodes, one per opened pack,
    --                           each carrying its own pack_id and offered.
    it("scenario 2: two packs back-to-back -> both nodes emitted with their own offered (LEAK SCENARIO)", function()
        -- Open the first pack with cards staged for it.
        populate_pack_cards("buffoon1", 2)
        dispatch_open_booster("p_buffoon_1", "Buffoon Pack #1", "Buffoon", 4)

        -- Before the deferred snapshot fires, the player opens a second
        -- pack. Real-game equivalent: select_from_pack into another pack.
        populate_pack_cards("buffoon2", 3)
        dispatch_open_booster("p_buffoon_2", "Buffoon Pack #2", "Buffoon", 4)

        drain_events()

        local nodes = open_pack_nodes()
        assert.are.equal(2, #nodes,
            "single-slot pending_open_pack_node loses the first pack — expected two open_pack nodes")

        -- Order should be the order packs were opened.
        assert.are.equal("p_buffoon_1", nodes[1].action.pack_id,
            "first emitted node must carry the first pack's id")
        assert.are.equal("p_buffoon_2", nodes[2].action.pack_id,
            "second emitted node must carry the second pack's id")

        -- Each node's `offered` must be its own pack's contents — the bug
        -- also surfaces if both nodes share one pack's snapshot.
        assert.is_table(nodes[1].action.offered)
        assert.are.equal(2, #nodes[1].action.offered)
        assert.are.equal("buffoon1 #1", nodes[1].action.offered[1].name)

        assert.is_table(nodes[2].action.offered)
        assert.are.equal(3, #nodes[2].action.offered)
        assert.are.equal("buffoon2 #1", nodes[2].action.offered[1].name)
    end)

    -- Scenario 3 — flush via reset_game_globals(false). The player opens a
    -- pack, then a blind boundary fires reset_game_globals(false) before
    -- the deferred snapshot runs. The fix's flush_pending_pack_queue()
    -- snapshots whatever G.pack_cards.cards holds at flush time and
    -- sends the node. On unfixed code, reset_game_globals(false) clears
    -- pending_open_pack_node and the node is lost.
    it("scenario 3: reset_game_globals(false) before snapshot flushes pending node with at-flush offered", function()
        populate_pack_cards("buffoon_at_flush", 1)
        dispatch_open_booster("p_buffoon_flush")

        -- Blind boundary fires before the deferred Event has run.
        mod_table.reset_game_globals(false)

        -- Drain after the flush. The deferred Event should be a no-op
        -- because the queue was already flushed by reset_game_globals.
        drain_events()

        local nodes = open_pack_nodes()
        assert.are.equal(1, #nodes,
            "reset_game_globals(false) must flush the pending pack node, not drop it")
        assert.are.equal("p_buffoon_flush", nodes[1].action.pack_id)
        assert.is_table(nodes[1].action.offered)
        assert.are.equal(1, #nodes[1].action.offered,
            "flushed node must carry whatever snapshot_pack_contents returns at flush time")
        assert.are.equal("buffoon_at_flush #1", nodes[1].action.offered[1].name)
    end)

    -- Scenario 4 — poll timeout. Pack opens but G.pack_cards.cards is
    -- never populated. The fix polls up to MAX_POLL_FRAMES = 600 ticks,
    -- then snapshots empty rather than leaking the node forever.
    -- We verify two things:
    --   a) BEFORE the timeout, with empty pack_cards, the node should
    --      NOT yet be sent (polling Event keeps returning false).
    --   b) AFTER MAX_POLL_FRAMES ticks, the node IS sent with empty
    --      offered.
    -- On unfixed code, the single-shot Event sends on its first tick
    -- with empty offered — assertion (a) fails because the node is sent
    -- prematurely.
    it("scenario 4: poll timeout sends node with empty offered after MAX_POLL_FRAMES", function()
        clear_pack_cards()
        dispatch_open_booster("p_buffoon_timeout")

        -- (a) Tick a handful of frames with empty pack_cards. The polling
        -- Event must keep returning false — the node should not yet be
        -- in the writer.
        for _ = 1, 5 do tick_events_once() end
        assert.are.equal(0, count_nodes_of_type("open_pack"),
            "polling Event must wait for G.pack_cards.cards before snapshotting; "
            .. "the unfixed single-shot Event sends an empty node on its first tick")

        -- (b) Drain past MAX_POLL_FRAMES = 600. Safety-net snapshot fires.
        drain_events(700)

        local nodes = open_pack_nodes()
        assert.are.equal(1, #nodes,
            "poll timeout must still emit the node rather than losing it")
        assert.are.equal("p_buffoon_timeout", nodes[1].action.pack_id)
        assert.is_table(nodes[1].action.offered)
        assert.are.equal(0, #nodes[1].action.offered,
            "timeout snapshot reads whatever is there — empty in this scenario")
    end)

    -- Property test: pack-queue conservation under arbitrary scheduling.
    --
    -- For any interleaving of N `context.open_booster` dispatches with
    -- random frame ticks and populate/clear of `G.pack_cards.cards`,
    -- after we drain the event queue the count of `open_pack`
    -- Decision_Nodes recorded must equal N. The queue conserves nodes
    -- regardless of when (or whether) `G.pack_cards.cards` is populated
    -- — every enqueued slot has at least one terminal path (at-enqueue
    -- snapshot, in-poll snapshot once cards appear, or the
    -- MAX_POLL_FRAMES safety-net snapshot).
    --
    -- Mirrors the deterministic-LCG pattern from
    -- end_of_round_latch_spec.lua so failures are reproducible without
    -- depending on math.random's global state. We do NOT assert
    -- anything about the contents of `offered`: with random
    -- populate/clear interleaving, which pack's cards a given polling
    -- Event sees is timing-dependent and outside the scope of the
    -- conservation property.
    --
    -- _Property: P.2 preservation — pack queue conserves nodes_
    -- _Validates: Requirements 2.3_
    it("property: any interleaving of N opens and tick/populate/clear ops emits exactly N open_pack nodes", function()
        local function make_rng(seed)
            local state = seed
            return function()
                state = (state * 1103515245 + 12345) % 2147483648
                return state
            end
        end

        for trial = 1, 50 do
            fresh_round()  -- isolate trial state — pending_open_pack_queue
                           -- and spy_writer.nodes both reset
            local seed = trial * 7919
            local rng  = make_rng(seed)

            -- N opens to perform this trial: 1..6.
            local target_opens = (rng() % 6) + 1

            -- Plus 10..30 random noise operations interleaved with the
            -- opens. Noise ops are tick/populate/clear; their ordering
            -- relative to the opens is randomized below.
            local noise_ops    = 10 + (rng() % 21)
            local total_ops    = target_opens + noise_ops

            -- Build a sequence with the opens and the noise ops, then
            -- shuffle it via Fisher-Yates with the same LCG so the order
            -- is deterministic per seed.
            local sequence = {}
            for _ = 1, target_opens do sequence[#sequence + 1] = "open" end
            for _ = 1, noise_ops do
                local pick = rng() % 3
                if     pick == 0 then sequence[#sequence + 1] = "tick"
                elseif pick == 1 then sequence[#sequence + 1] = "populate"
                else                  sequence[#sequence + 1] = "clear"
                end
            end
            for i = #sequence, 2, -1 do
                local j = (rng() % i) + 1
                sequence[i], sequence[j] = sequence[j], sequence[i]
            end

            -- Execute the interleaved sequence.
            local opens_dispatched = 0
            for _, op in ipairs(sequence) do
                if op == "open" then
                    opens_dispatched = opens_dispatched + 1
                    dispatch_open_booster(
                        "p_buffoon_t" .. trial .. "_" .. opens_dispatched)
                elseif op == "tick" then
                    tick_events_once()
                elseif op == "populate" then
                    populate_pack_cards("t" .. trial, 1 + (rng() % 3))
                elseif op == "clear" then
                    clear_pack_cards()
                end
            end

            -- Drain to the terminal state. 700 iterations comfortably
            -- exceeds MAX_POLL_FRAMES = 600 so any pack stuck waiting on
            -- an empty G.pack_cards hits its safety-net snapshot.
            drain_events(700)

            local actual_count = count_nodes_of_type("open_pack")
            assert.are.equal(target_opens, actual_count,
                "trial " .. trial .. " (seed " .. seed .. "): "
                .. "dispatched " .. target_opens .. " open_booster events, "
                .. "recorded " .. actual_count .. " open_pack nodes "
                .. "(queue conservation requires count == N)")
        end
    end)
end)


-- ---------------------------------------------------------------------------
-- Pack-window tracking on ending_pack
--
-- Verifies the run_state.current_pack_kind + current_pack_selects fields
-- get drained onto the ending_pack action's payload. Replaces the
-- viewer's old derived.pack_group ETL deriver: the viewer reads
-- pack_kind + selects_in_pack directly off the ending_pack action.
-- ---------------------------------------------------------------------------
describe("Pack-window tracking on ending_pack", function()

    before_each(function()
        fresh_round()
    end)

    it("stamps pack_kind and selects_in_pack on ending_pack action", function()
        dispatch_open_booster("p_buffoon_1", "Mega Buffoon Pack", "Buffoon", 4)
        populate_pack_cards("buffoon1", 4)
        drain_events()

        -- Two select_from_pack picks. emit_select_from_pack's wrapper
        -- bumps state.current_pack_selects before recorder:send.
        G.FUNCS.select_from_pack({ config = { ref_table = { base = { id = "1" } } } })
        G.FUNCS.select_from_pack({ config = { ref_table = { base = { id = "2" } } } })

        mod_table.calculate(mod_table, { ending_booster = true })

        local ending = nil
        for _, node in ipairs(spy_writer.nodes) do
            if node.action and node.action.type == "ending_pack" then
                ending = node
                break
            end
        end

        assert.is_not_nil(ending, "ending_pack node should have been recorded")
        assert.are.equal("Buffoon", ending.action.pack_kind,
            "pack_kind should carry the open_pack's kind")
        assert.are.equal(2, ending.action.selects_in_pack,
            "selects_in_pack should count the picks made before close")
    end)

    it("stamps selects_in_pack = 0 on a skipped (no-pick) pack", function()
        dispatch_open_booster("p_arcana_1", "Arcana Pack", "Arcana", 4)
        populate_pack_cards("arcana1", 3)
        drain_events()

        -- No selects, player closes the pack.
        mod_table.calculate(mod_table, { ending_booster = true })

        local ending = nil
        for _, node in ipairs(spy_writer.nodes) do
            if node.action and node.action.type == "ending_pack" then
                ending = node
                break
            end
        end

        assert.is_not_nil(ending, "ending_pack node should have been recorded")
        assert.are.equal("Arcana", ending.action.pack_kind)
        assert.are.equal(0, ending.action.selects_in_pack)
    end)
end)
