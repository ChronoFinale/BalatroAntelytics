--- spec/end_of_round_latch_spec.lua
---
--- Bug A — `end_of_round` Latch Leak + preservation property tests
---
--- Two test suites live in this file:
---
---   1. Exploration tests for the `end_of_round` latch leak
---      (Requirement 1.1, design.md Bug A). The "leak scenario" test is
---      EXPECTED TO FAIL on unfixed code — its failure is what proves the
---      bug exists.
---
---   2. Preservation property tests for the other per-round latches
---      (`blind_defeated`, `starting_shop`, `ending_shop`,
---      `ending_booster`, `mp_end_of_pvp`, `skip_blind`). These are
---      EXPECTED TO PASS on unfixed code — the fix for Bug A must NOT
---      regress them. They cover Requirement 3.4: "the system SHALL
---      CONTINUE TO latch [those six contexts] so they emit at most
---      one Decision_Node per round; only the `end_of_round` latch is
---      being repaired."
---
--- Exploration test for the latch leak documented in
--- `.kiro/specs/capture-pipeline-fixes/bugfix.md` Requirement 1.1 and
--- detailed in `design.md` Bug A.
---
--- Counterexample on UNFIXED code (proves the bug exists):
---
---   Scenario 2: ten consecutive `mod.calculate({end_of_round = true})`
---   dispatches in a single (ante, blind_slot), followed by
---   `mod.reset_game_globals(false)`, followed by ten more dispatches in
---   the SAME (ante, blind_slot). Logically this is one round-end event,
---   so exactly ONE `end_of_round` Decision_Node should be recorded.
---
---   Unfixed observation: 2 `end_of_round` nodes (the per-blind latch
---   `emitted_this_round` is wiped by `reset_game_globals(false)`, so the
---   second batch's first dispatch re-emits). Counterexample documented
---   per the task list as "10 dispatches → 11 nodes after reset" — i.e.
---   any reset interleaved with dispatches re-opens the latch.
---
---   Once fixed (content-addressed `(ante, blind_slot)` latch that
---   survives `reset_game_globals(false)`), the second batch sees the
---   same key already latched and emits no further nodes → 1 node total.
---
--- Test mechanics: we mock `love`, `SMODS`, `G`, and the few globals the
--- mod's hook layer wraps, then load `main.lua` to populate
--- `SMODS.current_mod.calculate` and `SMODS.current_mod.reset_game_globals`.
--- A spy `FileWriter` captures every appended node so we can count
--- `end_of_round` emissions.
---
--- _Validates: Requirements 2.1, 3.1, 3.4_

package.path = package.path .. ";./lib/?.lua;./Antelytics/lib/?.lua"

-- ---------------------------------------------------------------------------
-- Pre-load FileWriter and Recorder so we can patch their factories before
-- main.lua instantiates them. main.lua resolves them via SMODS.load_file,
-- which we control below — when it asks for these two modules it gets the
-- patched table back.
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
-- Event manager stub. The mod schedules `Event(...)` for the deferred
-- pack-contents snapshot. Our tests never trigger that path, but the
-- constructors must exist when main.lua loads.
-- ---------------------------------------------------------------------------
_G.Event = function(opts) return opts end

local scheduled_events = {}
local function make_fake_E_MANAGER()
    return {
        -- Run scheduled events synchronously. The real engine drains the
        -- queue every frame, so for unit tests we just invoke the func
        -- inline. This lets us verify the deferred shop_entered capture
        -- emits exactly one node, the same way it does in-game once the
        -- next frame ticks.
        add_event = function(_, ev)
            scheduled_events[#scheduled_events + 1] = ev
            if ev and type(ev.func) == "function" then
                pcall(ev.func)
            end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Build a fake G that supports the field reads `mod.calculate` and
-- `Capture.build_game_state` perform. Capture wraps every read in pcall, so
-- even an incomplete G yields a valid Game_State; we only need the fields
-- relevant to setting_blind / end_of_round dispatches.
-- ---------------------------------------------------------------------------
local function build_fake_G()
    return {
        STATE        = 0,
        STATES       = {},
        E_MANAGER    = make_fake_E_MANAGER(),
        SETTINGS     = { GAMESPEED = 1 },
        CONTROLLER   = { locks = {} },
        FUNCS        = {
            play_cards_from_highlighted    = function() end,
            evaluate_play                  = function() end,
            discard_cards_from_highlighted = function() end,
            select_from_pack               = function() end,
            use_card                       = function() end,
        },
        GAME         = {
            round_resets  = {
                ante = 1,
                blind_choices = {},
                blind_tags = {},
                -- Populate blind_states so SkipBlindAction.build can find
                -- a Skipped slot. Without this, the new resolver returns
                -- nil and skip_blind_tag is silently dropped — masking
                -- the latch behaviour these tests verify.
                blind_states = { Small = "Skipped", Big = "Select", Boss = "Select" },
            },
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
    }
end

_G.G = build_fake_G()

-- ---------------------------------------------------------------------------
-- SMODS stub. Every loader call returns a chunk that returns the module.
-- For FileWriter and Recorder we hand back the patched tables we built
-- above so main.lua's instantiation flows through our spies.
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

local TEST_ROOT = temp_path("dt_test_eor")

local mod_table = {
    config = { player_id = "tester", enabled = true },
    path   = TEST_ROOT .. "/",
}

ensure_dir(TEST_ROOT .. "/log")

_G.SMODS = {
    current_mod = mod_table,
    load_file   = function(rel)
        local short = rel:gsub("^lib/", "")
        if short == "file_writer.lua" then return function() return FileWriter end end
        if short == "recorder.lua"    then return function() return Recorder    end end
        return assert(loadfile("lib/" .. short))
    end,
}

-- ---------------------------------------------------------------------------
-- Run main.lua once. After this, mod_table.calculate and
-- mod_table.reset_game_globals are populated and our_recorder + spy_writer
-- handles are live.
-- ---------------------------------------------------------------------------
assert(loadfile("main.lua"))()

assert(type(mod_table.calculate) == "function",
    "main.lua did not define mod.calculate")
assert(type(mod_table.reset_game_globals) == "function",
    "main.lua did not define mod.reset_game_globals")
assert(our_recorder, "Recorder factory was not invoked by main.lua")
assert(spy_writer, "FileWriter factory was not invoked by main.lua")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Count how many appended nodes carry the given action type.
local function count_nodes_of_type(action_type)
    local n = 0
    for _, node in ipairs(spy_writer.nodes) do
        if node.action and node.action.type == action_type then
            n = n + 1
        end
    end
    return n
end

--- Drive a `setting_blind` dispatch with the given ante + slot label so the
--- fix's `(ante, blind_slot)` content-addressed latch sees a fresh key.
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

--- Reset both run-level state (recorder run, run_state) and the spy
--- writer's node buffer back to a known-clean baseline. Each scenario
--- starts from a fresh round in (ante=1, slot="small").
local function fresh_round()
    if our_recorder:is_active() then
        our_recorder:end_run("interrupted", 1, nil)
    end
    spy_writer.nodes = {}
    our_recorder:start_run("TEST_RUN", "tester", "TESTSEED", 1700000000, "solo")
    -- run_start = true wipes all latches and per-blind state.
    mod_table.reset_game_globals(true)
    -- Establish ante=1, slot="small" so end_of_round dispatches have a
    -- stable key under the fixed implementation.
    dispatch_setting_blind(1, "small", "Small Blind")
    -- Drop the select_blind node so subsequent assertions count only the
    -- end_of_round emissions we triggered.
    spy_writer.nodes = {}
end

--- Dispatch the end_of_round calculate context N times. Mirrors what
--- SMODS does when it fans the context across joker / playing-card /
--- individual passes.
local function dispatch_end_of_round_n_times(n)
    for _ = 1, n do
        mod_table.calculate(mod_table, {
            end_of_round = true,
            beat_boss    = false,
            game_over    = false,
        })
    end
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("Bug A — end_of_round latch leak", function()

    before_each(function()
        fresh_round()
    end)

    it("ten consecutive dispatches without any reset → exactly one node", function()
        dispatch_end_of_round_n_times(10)
        assert.are.equal(1, count_nodes_of_type("end_of_round"),
            "expected one end_of_round node when no reset interleaves the dispatches")
    end)

    it("ten dispatches, reset_game_globals(false), ten more in SAME (ante, blind_slot) → exactly one node (LEAK SCENARIO)", function()
        -- This is the bug-condition test. On unfixed code the per-blind
        -- latch table `emitted_this_round` is wiped by
        -- reset_game_globals(false), so the second batch's first
        -- dispatch re-latches and re-emits — yielding TWO nodes for
        -- one logical round-end event.
        dispatch_end_of_round_n_times(10)
        mod_table.reset_game_globals(false)
        dispatch_end_of_round_n_times(10)

        assert.are.equal(1, count_nodes_of_type("end_of_round"),
            "the latch must survive reset_game_globals(false) within the same (ante, blind_slot)")
    end)

    it("ten dispatches, setting_blind advances (ante, blind_slot), ten more → exactly two nodes", function()
        dispatch_end_of_round_n_times(10)

        -- Real game flow: a new blind triggers reset_game_globals(false)
        -- and then setting_blind. The fix tracks (ante, blind_slot) so
        -- the new blind gets its own latch entry.
        mod_table.reset_game_globals(false)
        dispatch_setting_blind(1, "big", "Big Blind")
        spy_writer.nodes = {}  -- drop the select_blind node we just emitted

        dispatch_end_of_round_n_times(10)

        assert.are.equal(1, count_nodes_of_type("end_of_round"),
            "advancing to a new (ante, blind_slot) must let exactly one new end_of_round node fire")
    end)

    it("ten dispatches, reset_game_globals(true), one more dispatch → next dispatch records a new node", function()
        dispatch_end_of_round_n_times(10)
        local before = count_nodes_of_type("end_of_round")

        -- run_start = true wipes the entire latch table — start of a new run.
        mod_table.reset_game_globals(true)
        -- After run_start the recorder is no longer active, so we must
        -- start a fresh run and re-establish the blind context the same
        -- way the real game would.
        our_recorder:start_run("TEST_RUN_2", "tester", "TESTSEED", 1700000001, "solo")
        dispatch_setting_blind(1, "small", "Small Blind")
        spy_writer.nodes = {}

        dispatch_end_of_round_n_times(1)

        assert.are.equal(1, count_nodes_of_type("end_of_round"),
            "run_start=true must clear the latch so the next round can record again")
        -- Sanity: the prior batch already emitted at least one node before the reset.
        assert.is_true(before >= 1)
    end)
end)

-- ---------------------------------------------------------------------------
-- Preservation tests for the OTHER per-round latches (Requirement 3.4)
--
-- These six contexts (`blind_defeated`, `starting_shop`, `ending_shop`,
-- `ending_booster`, `mp_end_of_pvp`, `skip_blind`) each go through
-- `latch_once` against `run_state.emitted_this_round`. Bug A fixes only
-- the `end_of_round` latch by switching to a content-addressed table
-- that survives `reset_game_globals(false)`. The other six MUST keep
-- their existing behavior on UNFIXED code: at most one node per latch
-- key per round, regardless of how many calculate passes fire.
--
-- _Validates: Requirements 3.1, 3.4_
-- ---------------------------------------------------------------------------

--- Map from context-flag name → action.type the handler emits when the
--- latch fires. Used both by the unit tests below and the property test.
local PRESERVATION_LATCHES = {
    { context_flag = "blind_defeated",  action_type = "blind_beaten"     },
    { context_flag = "starting_shop",   action_type = "shop_entered"     },
    { context_flag = "ending_shop",     action_type = "ending_shop"      },
    -- ending_booster is NOT a per-round latch — it's a per-pack one-shot
    -- (armed on open_booster). Tested separately below so a shop with two
    -- packs emits two closes. See "ending_booster per-pack close".
    { context_flag = "mp_end_of_pvp",   action_type = "pvp_round_ended"  },
    { context_flag = "skip_blind",      action_type = "skip_blind_tag"   },
}

--- Dispatch a single calculate pass with the given context flag set.
local function dispatch_context(context_flag)
    mod_table.calculate(mod_table, { [context_flag] = true })
end

--- Dispatch one context flag N times in a row.
local function dispatch_context_n_times(context_flag, n)
    for _ = 1, n do
        dispatch_context(context_flag)
    end
end

describe("preservation: other per-round latches emit at most once per round", function()

    before_each(function()
        fresh_round()
    end)

    -- One unit test per latch — each documents the exact baseline the
    -- Bug A fix must not regress.
    for _, latch in ipairs(PRESERVATION_LATCHES) do
        it(latch.context_flag .. " latches once per round (10 dispatches → 1 " .. latch.action_type .. " node)", function()
            dispatch_context_n_times(latch.context_flag, 10)
            assert.are.equal(1, count_nodes_of_type(latch.action_type),
                latch.context_flag .. " must emit exactly one " .. latch.action_type
                .. " node per round on UNFIXED code")
        end)
    end

    -- Property test: any random interleaving of the six contexts within
    -- a single round (no resets between dispatches) must produce at
    -- most one node per unique action type. Mirrors the structure of
    -- play_discard_spec.lua's deterministic-LCG property tests so
    -- failures are reproducible without depending on math.random's
    -- global state.
    --
    -- _Property: P.1 preservation — each unique latch key emits ≤ 1
    -- node within a single round_
    it("property: any interleaving of the six contexts emits at most one node per type", function()
        local function make_rng(seed)
            local state = seed
            return function()
                state = (state * 1103515245 + 12345) % 2147483648
                return state
            end
        end

        for trial = 1, 50 do
            fresh_round()  -- isolate trials so a per-round latch in trial N
                           -- doesn't bleed into trial N+1
            local rng = make_rng(trial * 7919)
            local sequence_length = 30 + (rng() % 30)  -- 30..59 dispatches

            for _ = 1, sequence_length do
                local pick = (rng() % #PRESERVATION_LATCHES) + 1
                dispatch_context(PRESERVATION_LATCHES[pick].context_flag)
            end

            for _, latch in ipairs(PRESERVATION_LATCHES) do
                local count = count_nodes_of_type(latch.action_type)
                assert.is_true(count <= 1,
                    "trial " .. trial .. ": " .. latch.action_type
                    .. " emitted " .. count .. " nodes (expected ≤ 1)")
            end
        end
    end)
end)


-- ---------------------------------------------------------------------------
-- ending_booster: per-PACK close (one ending_pack per opened pack)
--
-- Regression for the boundary bug: ending_pack used a single per-round latch
-- ("ending_pack"), so opening two packs in one shop only emitted ONE close —
-- the second pack had no ending_pack and its window couldn't be bracketed.
-- Now it's a one-shot armed on each open_booster (run_state.pack_close_pending).
-- ---------------------------------------------------------------------------
describe("ending_booster per-pack close", function()
    before_each(function() fresh_round() end)

    it("emits one ending_pack per opened pack (two packs in a shop → two closes)", function()
        -- Pack 1: arm (as open_booster would) then close.
        mod_table.run_state.pack_close_pending = true
        dispatch_context("ending_booster")
        -- Multi-dispatch of the same close must NOT double-emit.
        dispatch_context("ending_booster")
        assert.are.equal(1, count_nodes_of_type("ending_pack"), "first pack → 1 close")

        -- Pack 2: re-arm (new open_booster) then close → a SECOND ending_pack.
        mod_table.run_state.pack_close_pending = true
        dispatch_context("ending_booster")
        assert.are.equal(2, count_nodes_of_type("ending_pack"), "second pack → 2 closes total")
    end)

    it("does NOT emit a close when no pack was opened (flag never armed)", function()
        mod_table.run_state.pack_close_pending = false
        dispatch_context_n_times("ending_booster", 5)
        assert.are.equal(0, count_nodes_of_type("ending_pack"))
    end)
end)


-- ---------------------------------------------------------------------------
-- tag_added.from_skip detection
--
-- `from_skip = true` marks the tag the player CHOSE by skipping (so the viewer
-- suppresses the redundant tag_added row above the skip_blind_tag row). The
-- chosen tag is added synchronously inside G.FUNCS.skip_blind, during which the
-- hooks.lua wrapper holds run_state.in_skip_blind = true. A Double Tag
-- duplicate is added on a later event-queue frame, after the flag clears, so it
-- stays unmarked. Vanilla tags outside a skip flow are unmarked too.
--
-- Regression: the old detection used "no blind flagged Skipped yet", which was
-- WRONG on the second consecutive skip (the first blind already reads
-- "Skipped") — the chosen tag was misclassified as a duplicate. The flag does
-- not depend on blind_states, so consecutive skips are handled correctly.
-- ---------------------------------------------------------------------------

local function dispatch_tag_added(opts)
    opts = opts or {}
    -- blind_states is deliberately set to prove from_skip no longer depends on
    -- it — only on run_state.in_skip_blind (set by the skip_blind wrapper).
    G.GAME.round_resets.blind_states = opts.blind_states or {
        Small = "Select", Big = "Select", Boss = "Select",
    }
    mod_table.run_state.in_skip_blind = opts.in_skip_blind == true
    mod_table.calculate(mod_table, {
        tag_added = {
            key  = opts.tag_key  or "tag_investment",
            name = opts.tag_name or "Investment Tag",
            ID   = opts.tag_ID   or 42,
            ante = opts.ante or 1,
        },
    })
end

local function find_node_of_type(action_type)
    for _, node in ipairs(spy_writer.nodes) do
        if node.action and node.action.type == action_type then return node end
    end
    return nil
end

describe("tag_added.from_skip detection", function()

    before_each(function()
        fresh_round()
        G.CONTROLLER.locks = {}
        mod_table.run_state.in_skip_blind = false
    end)

    it("chosen skip tag (in_skip_blind) stamps from_skip=true", function()
        dispatch_tag_added({ in_skip_blind = true })
        local node = find_node_of_type("tag_added")
        assert.is_not_nil(node, "tag_added node should have been recorded")
        assert.are.equal(true, node.action.from_skip,
            "the chosen skip tag should be marked from_skip=true")
    end)

    it("REGRESSION: 2nd consecutive skip's chosen tag is still marked, even with a prior blind already Skipped", function()
        -- Small already skipped earlier this round; player now skips Big and
        -- takes a tag. The old blind_states heuristic broke here.
        dispatch_tag_added({
            in_skip_blind = true,
            blind_states  = { Small = "Skipped", Big = "Select", Boss = "Select" },
        })
        local node = find_node_of_type("tag_added")
        assert.is_not_nil(node)
        assert.are.equal(true, node.action.from_skip,
            "chosen tag on the second consecutive skip must still be from_skip=true")
    end)

    it("Double Tag duplicate (added after skip_blind returns, flag cleared) does NOT stamp from_skip", function()
        dispatch_tag_added({
            in_skip_blind = false,
            blind_states  = { Small = "Skipped", Big = "Skipped", Boss = "Select" },
        })
        local node = find_node_of_type("tag_added")
        assert.is_not_nil(node)
        assert.is_nil(node.action.from_skip,
            "a tag added outside the synchronous skip window stays unmarked")
    end)

    it("non-skip tag (not in a skip) does NOT stamp from_skip", function()
        dispatch_tag_added({ in_skip_blind = false })
        local node = find_node_of_type("tag_added")
        assert.is_not_nil(node)
        assert.is_nil(node.action.from_skip,
            "tag added outside a skip flow should not be marked")
    end)
end)
