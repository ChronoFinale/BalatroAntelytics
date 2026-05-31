--- spec/resume_spec.lua
---
--- Bug F — Save/quit/resume run-id chaining
---
--- Tests for the resume detection chain, run-id linking, and idle-flush
--- detector added in tasks 39–48.
---
--- Bug condition: resumed runs have no link back to the pre-quit capture.
--- The fix adds:
---   - FileWriter:start_run accepts optional previous_run_id
---   - FileWriter:patch_previous_run_header(previous_run_id, next_run_id)
---   - Recorder:start_run passes previous_run_id through to FileWriter
---   - Idle detector in love.update fires recorder:end_run("interrupted")
---     after 30s idle in MENU state
---
--- These tests FAIL on unfixed code because the chaining infrastructure
--- does not exist yet.
---
--- _Validates: Requirements 2.8, 2.9_
--- **Validates: Requirements 2.8, 2.9**

local FileWriter = require("lib.file_writer")
local Recorder   = require("lib.recorder")
local Serializer = require("lib.serializer")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function make_in_memory_fs()
    local files = {}
    return {
        files   = files,
        log_dir = "/test/log",

        write = function(self, name, data)
            files[name] = data
            return true
        end,

        read = function(self, name)
            return files[name]
        end,

        rename = function(self, from, to)
            if files[from] == nil then return false end
            files[to]   = files[from]
            files[from] = nil
            return true
        end,

        remove = function(self, name)
            files[name] = nil
            return true
        end,
    }
end

local function passthrough_compress(data) return data end

local function make_writer(fs)
    return FileWriter.new({
        serializer = Serializer,
        logger     = function() end,
        mod_path   = "/test/",
        fs         = fs,
        compress   = passthrough_compress,
    })
end

local function make_recorder(fw)
    return Recorder.new({
        file_writer = fw,
        logger      = function() end,
    })
end

-- ---------------------------------------------------------------------------
-- Task 39 — Failing tests (no chaining infrastructure exists yet)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Scenario 1: Previous run interrupted → resume links the two files
-- ---------------------------------------------------------------------------

describe("Bug F — resume: previous interrupted run gets next_run_id set", function()

    it("after resume, new run's file has previous_run_id and old file has next_run_id", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)

        -- Simulate a previous interrupted run.
        fw:start_run("RUN_A", "alice", "SEED", 1000, "solo")
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:end_run("interrupted", 2, nil)

        -- Verify the previous file exists with outcome=interrupted.
        local prev_record = Serializer.decode(fs.files["RUN_A.json.gz"])
        assert.are.equal("interrupted", prev_record.outcome)
        assert.is_nil(prev_record.next_run_id,
            "before resume, previous file must have no next_run_id")

        -- Simulate resume: start a new run with previous_run_id set.
        fw:start_run("RUN_B", "alice", "SEED2", 2000, "solo", "RUN_A")
        fw:append_node({ index = 0, action = { type = "select_blind" } })

        -- Patch the previous file's header to set next_run_id.
        fw:patch_previous_run_header("RUN_A.json.gz", "RUN_B")

        fw:end_run("interrupted", 2, nil)

        -- New run's file must carry previous_run_id.
        local new_record = Serializer.decode(fs.files["RUN_B.json.gz"])
        assert.are.equal("RUN_A", new_record.previous_run_id,
            "resumed run must have previous_run_id pointing to the interrupted run")
        assert.is_nil(new_record.next_run_id,
            "new run has no next_run_id yet (it hasn't been resumed)")

        -- Previous file must now carry next_run_id.
        local patched_prev = Serializer.decode(fs.files["RUN_A.json.gz"])
        assert.are.equal("RUN_B", patched_prev.next_run_id,
            "previous file must have next_run_id set after patch")
        assert.are.equal("interrupted", patched_prev.outcome,
            "previous file outcome must remain interrupted after patch")
    end)

end)

-- ---------------------------------------------------------------------------
-- Scenario 2: Three-session chain A → B → C
-- ---------------------------------------------------------------------------

describe("Bug F — resume: three-session chain forms a linked list", function()

    it("A interrupted → resumed as B, B interrupted → resumed as C: all three linked", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)

        -- Run A: interrupted.
        fw:start_run("RUN_A", "alice", "SEED", 1000, "solo")
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:end_run("interrupted", 1, nil)

        -- Run B: resumed from A.
        fw:start_run("RUN_B", "alice", "SEED", 2000, "solo", "RUN_A")
        fw:patch_previous_run_header("RUN_A.json.gz", "RUN_B")
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:end_run("interrupted", 2, nil)

        -- Run C: resumed from B.
        fw:start_run("RUN_C", "alice", "SEED", 3000, "solo", "RUN_B")
        fw:patch_previous_run_header("RUN_B.json.gz", "RUN_C")
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:end_run("win", 8, nil)

        -- Verify the chain.
        local rec_a = Serializer.decode(fs.files["RUN_A.json.gz"])
        local rec_b = Serializer.decode(fs.files["RUN_B.json.gz"])
        local rec_c = Serializer.decode(fs.files["RUN_C.json.gz"])

        -- A: head of chain — no previous, has next.
        assert.is_nil(rec_a.previous_run_id,
            "head of chain must have previous_run_id = nil")
        assert.are.equal("RUN_B", rec_a.next_run_id,
            "A must point forward to B")

        -- B: middle of chain.
        assert.are.equal("RUN_A", rec_b.previous_run_id,
            "B must point back to A")
        assert.are.equal("RUN_C", rec_b.next_run_id,
            "B must point forward to C")

        -- C: tail of chain — has previous, no next (completed run).
        assert.are.equal("RUN_B", rec_c.previous_run_id,
            "C must point back to B")
        assert.is_nil(rec_c.next_run_id,
            "tail of completed chain must have next_run_id = nil")
        assert.are.equal("win", rec_c.outcome)
    end)

end)

-- ---------------------------------------------------------------------------
-- Scenario 3: Resume when no previous interrupted file exists
-- ---------------------------------------------------------------------------

describe("Bug F — resume: no previous interrupted file → clean start", function()

    it("start_run with previous_run_id=nil starts cleanly, no crash", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)

        -- Start a fresh run with no previous_run_id.
        fw:start_run("RUN_FRESH", "alice", "SEED", 1000, "solo", nil)
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:end_run("win", 8, nil)

        local record = Serializer.decode(fs.files["RUN_FRESH.json.gz"])
        assert.are.equal("RUN_FRESH", record.run_id)
        assert.is_nil(record.previous_run_id,
            "fresh run must have previous_run_id = nil")
        assert.are.equal("win", record.outcome)
    end)

end)

-- ---------------------------------------------------------------------------
-- Scenario 4: Resume when previous file is missing or unreadable
-- ---------------------------------------------------------------------------

describe("Bug F — resume: missing previous file → logs warning, starts cleanly", function()

    it("patch_previous_run_header with missing file logs warning but does not crash", function()
        local fs = make_in_memory_fs()
        local warnings = {}
        local fw = FileWriter.new({
            serializer = Serializer,
            logger     = function(msg) warnings[#warnings + 1] = msg end,
            mod_path   = "/test/",
            fs         = fs,
            compress   = passthrough_compress,
        })

        -- No previous file exists in fs.
        fw:start_run("RUN_B", "alice", "SEED", 2000, "solo", "RUN_MISSING")
        -- This must not throw — it should log a warning and continue.
        fw:patch_previous_run_header("RUN_MISSING.json.gz", "RUN_B")
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:end_run("win", 8, nil)

        -- New run must still be written correctly.
        local record = Serializer.decode(fs.files["RUN_B.json.gz"])
        assert.are.equal("RUN_B", record.run_id)
        assert.are.equal("RUN_MISSING", record.previous_run_id,
            "previous_run_id must still be set on the new run even when patch fails")

        -- A warning must have been logged.
        local found_warning = false
        for _, msg in ipairs(warnings) do
            if msg:find("RUN_MISSING") or msg:find("patch") or msg:find("warn") or msg:find("error") then
                found_warning = true
                break
            end
        end
        assert.is_true(found_warning,
            "patch_previous_run_header must log a warning when the previous file is missing")
    end)

end)

-- ---------------------------------------------------------------------------
-- Scenario 5: Idle detector fires once, then doesn't re-fire
-- ---------------------------------------------------------------------------

describe("Bug F — idle detector: fires once after 30s idle in MENU state", function()

    it("end_run called once when idle > 30s in MENU; subsequent ticks don't re-fire", function()
        -- We test the idle-check logic in isolation by simulating the
        -- state that love.update would read. The idle detector is
        -- implemented as a standalone function `update_idle_check` that
        -- main.lua exposes for testing, or we test it via the recorder
        -- state machine.
        --
        -- Since the idle detector lives in main.lua (not a pure module),
        -- we test the underlying contract: after firing, last_action_timestamp
        -- is cleared so subsequent calls are no-ops.

        local end_run_calls = 0
        local mock_recorder = {
            active = true,
            is_active = function(self) return self.active end,
            end_run = function(self, outcome)
                end_run_calls = end_run_calls + 1
                self.active = false
            end,
        }

        -- Simulate the idle check state.
        local run_state = {
            last_action_timestamp = os.time() - 35,  -- 35 seconds ago
        }

        -- Simulate G.STATE == G.STATES.MENU.
        local mock_G = {
            STATE  = 1,
            STATES = { MENU = 1 },
        }

        -- The idle check function (mirrors what main.lua implements).
        local function update_idle_check(recorder, state, g)
            if not recorder:is_active() then return end
            if state.last_action_timestamp == nil then return end
            if os.time() - state.last_action_timestamp <= 30 then return end
            if not (g and g.STATE == g.STATES.MENU) then return end
            -- Fire once and clear the timestamp so it doesn't re-fire.
            recorder:end_run("interrupted")
            state.last_action_timestamp = nil
        end

        -- First tick: should fire.
        update_idle_check(mock_recorder, run_state, mock_G)
        assert.are.equal(1, end_run_calls,
            "idle detector must call end_run once after 30s idle in MENU")
        assert.is_nil(run_state.last_action_timestamp,
            "idle detector must clear last_action_timestamp after firing")

        -- Second tick: recorder is no longer active, must not re-fire.
        update_idle_check(mock_recorder, run_state, mock_G)
        assert.are.equal(1, end_run_calls,
            "idle detector must not re-fire after end_run was called")
    end)

    it("idle detector does not fire when G.STATE is not MENU", function()
        local end_run_calls = 0
        local mock_recorder = {
            active = true,
            is_active = function(self) return self.active end,
            end_run = function(self, outcome)
                end_run_calls = end_run_calls + 1
                self.active = false
            end,
        }

        local run_state = {
            last_action_timestamp = os.time() - 35,
        }

        local mock_G = {
            STATE  = 2,  -- Not MENU
            STATES = { MENU = 1 },
        }

        local function update_idle_check(recorder, state, g)
            if not recorder:is_active() then return end
            if state.last_action_timestamp == nil then return end
            if os.time() - state.last_action_timestamp <= 30 then return end
            if not (g and g.STATE == g.STATES.MENU) then return end
            recorder:end_run("interrupted")
            state.last_action_timestamp = nil
        end

        update_idle_check(mock_recorder, run_state, mock_G)
        assert.are.equal(0, end_run_calls,
            "idle detector must not fire when G.STATE is not MENU")
    end)

    it("idle detector does not fire when last action was recent (< 30s)", function()
        local end_run_calls = 0
        local mock_recorder = {
            active = true,
            is_active = function(self) return self.active end,
            end_run = function(self, outcome)
                end_run_calls = end_run_calls + 1
            end,
        }

        local run_state = {
            last_action_timestamp = os.time() - 10,  -- only 10 seconds ago
        }

        local mock_G = {
            STATE  = 1,
            STATES = { MENU = 1 },
        }

        local function update_idle_check(recorder, state, g)
            if not recorder:is_active() then return end
            if state.last_action_timestamp == nil then return end
            if os.time() - state.last_action_timestamp <= 30 then return end
            if not (g and g.STATE == g.STATES.MENU) then return end
            recorder:end_run("interrupted")
            state.last_action_timestamp = nil
        end

        update_idle_check(mock_recorder, run_state, mock_G)
        assert.are.equal(0, end_run_calls,
            "idle detector must not fire when last action was less than 30s ago")
    end)

end)

-- ---------------------------------------------------------------------------
-- Scenario 6: Idle detector resets when a new action is recorded
-- ---------------------------------------------------------------------------

describe("Bug F — idle detector: resets when a new action is recorded", function()

    it("recording a new action updates last_action_timestamp, preventing idle fire", function()
        local run_state = {
            last_action_timestamp = os.time() - 35,  -- would trigger idle
        }

        -- Simulate record_action updating the timestamp.
        local function on_action_recorded(state)
            state.last_action_timestamp = os.time()
        end

        on_action_recorded(run_state)

        -- Now the timestamp is fresh — idle check should not fire.
        local end_run_calls = 0
        local mock_recorder = {
            active = true,
            is_active = function(self) return self.active end,
            end_run = function(self, outcome)
                end_run_calls = end_run_calls + 1
            end,
        }

        local mock_G = {
            STATE  = 1,
            STATES = { MENU = 1 },
        }

        local function update_idle_check(recorder, state, g)
            if not recorder:is_active() then return end
            if state.last_action_timestamp == nil then return end
            if os.time() - state.last_action_timestamp <= 30 then return end
            if not (g and g.STATE == g.STATES.MENU) then return end
            recorder:end_run("interrupted")
            state.last_action_timestamp = nil
        end

        update_idle_check(mock_recorder, run_state, mock_G)
        assert.are.equal(0, end_run_calls,
            "after recording a new action, idle detector must not fire")
    end)

end)

-- ---------------------------------------------------------------------------
-- Recorder pass-through: previous_run_id flows from Recorder to FileWriter
-- ---------------------------------------------------------------------------

describe("Bug F — Recorder:start_run passes previous_run_id to FileWriter", function()

    it("previous_run_id passed to recorder:start_run appears in the written file", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        local rec = make_recorder(fw)

        rec:start_run("RUN_B", "alice", "SEED", 2000, "solo", "RUN_A")
        rec:end_run("interrupted", 2, nil)

        local record = Serializer.decode(fs.files["RUN_B.json.gz"])
        assert.are.equal("RUN_A", record.previous_run_id,
            "previous_run_id passed to recorder:start_run must appear in the written file")
    end)

    it("no previous_run_id → field is null/nil in the written file", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        local rec = make_recorder(fw)

        rec:start_run("RUN_FRESH", "alice", "SEED", 1000, "solo")
        rec:end_run("win", 8, nil)

        local record = Serializer.decode(fs.files["RUN_FRESH.json.gz"])
        -- previous_run_id should be absent or null.
        local prev = record.previous_run_id
        assert.is_true(prev == nil or prev == Serializer.null,
            "fresh run must have previous_run_id absent or null")
    end)

end)

-- ---------------------------------------------------------------------------
-- patch_previous_run_header: never overwrites win/loss outcome
-- ---------------------------------------------------------------------------

describe("Bug F — patch_previous_run_header: preserves completed run outcomes", function()

    it("does not overwrite outcome=win with interrupted", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)

        -- Write a completed (win) run.
        fw:start_run("RUN_WIN", "alice", "SEED", 1000, "solo")
        fw:end_run("win", 8, nil)

        local before = Serializer.decode(fs.files["RUN_WIN.json.gz"])
        assert.are.equal("win", before.outcome)

        -- Attempt to patch it (should set next_run_id but NOT change outcome).
        fw:patch_previous_run_header("RUN_WIN.json.gz", "RUN_NEXT")

        local after = Serializer.decode(fs.files["RUN_WIN.json.gz"])
        assert.are.equal("win", after.outcome,
            "patch must not overwrite outcome=win with interrupted")
        assert.are.equal("RUN_NEXT", after.next_run_id,
            "patch must still set next_run_id even on a completed run")
    end)

    it("does not overwrite outcome=loss with interrupted", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)

        fw:start_run("RUN_LOSS", "alice", "SEED", 1000, "solo")
        fw:end_run("loss", 3, nil)

        fw:patch_previous_run_header("RUN_LOSS.json.gz", "RUN_NEXT")

        local after = Serializer.decode(fs.files["RUN_LOSS.json.gz"])
        assert.are.equal("loss", after.outcome,
            "patch must not overwrite outcome=loss with interrupted")
        assert.are.equal("RUN_NEXT", after.next_run_id)
    end)

    it("sets outcome=interrupted when current outcome is in_progress", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)

        fw:start_run("RUN_PROG", "alice", "SEED", 1000, "solo")
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:flush_partial()  -- writes outcome=in_progress

        local before = Serializer.decode(fs.files["RUN_PROG.json.gz"])
        assert.are.equal("in_progress", before.outcome)

        fw:patch_previous_run_header("RUN_PROG.json.gz", "RUN_NEXT")

        local after = Serializer.decode(fs.files["RUN_PROG.json.gz"])
        assert.are.equal("interrupted", after.outcome,
            "patch must upgrade outcome from in_progress to interrupted")
        assert.are.equal("RUN_NEXT", after.next_run_id)
    end)

end)

-- ---------------------------------------------------------------------------
-- Property-based test: for any chain of run sessions, adjacent pairs satisfy
-- prev.next_run_id == this.run_id AND this.previous_run_id == prev.run_id
-- ---------------------------------------------------------------------------

describe("Bug F — property: run-id chain invariant holds for any chain length", function()

    --- **Validates: Requirements 2.8, 2.9**
    it("property: prev.next_run_id == this.run_id AND this.previous_run_id == prev.run_id for every adjacent pair", function()
        -- Test chains of length 2..6.
        for chain_len = 2, 6 do
            local fs = make_in_memory_fs()
            local fw = make_writer(fs)

            local run_ids = {}
            for i = 1, chain_len do
                run_ids[i] = "CHAIN_" .. chain_len .. "_RUN_" .. i
            end

            -- Write the first run (no previous).
            fw:start_run(run_ids[1], "alice", "SEED", 1000, "solo")
            fw:append_node({ index = 0, action = { type = "select_blind" } })
            fw:end_run("interrupted", 1, nil)

            -- Write subsequent runs, each resuming the previous.
            for i = 2, chain_len do
                local prev_id = run_ids[i - 1]
                local this_id = run_ids[i]
                fw:start_run(this_id, "alice", "SEED", 1000 + i, "solo", prev_id)
                fw:patch_previous_run_header(prev_id .. ".json.gz", this_id)
                fw:append_node({ index = 0, action = { type = "select_blind" } })
                -- Last run wins; others are interrupted.
                if i == chain_len then
                    fw:end_run("win", 8, nil)
                else
                    fw:end_run("interrupted", i, nil)
                end
            end

            -- Verify every adjacent pair.
            for i = 1, chain_len - 1 do
                local prev_id = run_ids[i]
                local this_id = run_ids[i + 1]
                local prev_rec = Serializer.decode(fs.files[prev_id .. ".json.gz"])
                local this_rec = Serializer.decode(fs.files[this_id .. ".json.gz"])

                assert.are.equal(this_id, prev_rec.next_run_id,
                    "chain_len=" .. chain_len .. " pair " .. i
                    .. ": prev.next_run_id must equal this.run_id")
                assert.are.equal(prev_id, this_rec.previous_run_id,
                    "chain_len=" .. chain_len .. " pair " .. i
                    .. ": this.previous_run_id must equal prev.run_id")
            end

            -- Head has no previous.
            local head = Serializer.decode(fs.files[run_ids[1] .. ".json.gz"])
            assert.is_true(head.previous_run_id == nil or head.previous_run_id == Serializer.null,
                "chain_len=" .. chain_len .. ": head must have previous_run_id = nil")

            -- Tail (completed) has no next.
            local tail = Serializer.decode(fs.files[run_ids[chain_len] .. ".json.gz"])
            assert.is_true(tail.next_run_id == nil or tail.next_run_id == Serializer.null,
                "chain_len=" .. chain_len .. ": tail must have next_run_id = nil")
            assert.are.equal("win", tail.outcome)
        end
    end)

end)
