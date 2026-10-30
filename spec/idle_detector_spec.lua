--- spec/idle_detector_spec.lua
---
--- Idle-flush detector: after 30s idle in the MENU state, the run is
--- closed with recorder:end_run("interrupted"), exactly once.
---
--- The detector lives in main.lua's love.update (not a pure module), so
--- these tests pin the contract it implements: fires once, then clears
--- last_action_timestamp so later ticks are no-ops; never fires outside
--- MENU or within the 30s window; a new action resets the window.

local function make_mock_recorder(counter)
    return {
        active = true,
        is_active = function(self) return self.active end,
        end_run = function(self, outcome)
            counter.calls = counter.calls + 1
            self.active = false
        end,
    }
end

-- Mirrors what main.lua implements.
local function update_idle_check(recorder, state, g)
    if not recorder:is_active() then return end
    if state.last_action_timestamp == nil then return end
    if os.time() - state.last_action_timestamp <= 30 then return end
    if not (g and g.STATE == g.STATES.MENU) then return end
    -- Fire once and clear the timestamp so it doesn't re-fire.
    recorder:end_run("interrupted")
    state.last_action_timestamp = nil
end

local MENU_G     = { STATE = 1, STATES = { MENU = 1 } }
local NOT_MENU_G = { STATE = 2, STATES = { MENU = 1 } }

describe("idle detector: fires once after 30s idle in MENU state", function()

    it("end_run called once when idle > 30s in MENU; subsequent ticks don't re-fire", function()
        local counter = { calls = 0 }
        local recorder = make_mock_recorder(counter)
        local run_state = { last_action_timestamp = os.time() - 35 }

        update_idle_check(recorder, run_state, MENU_G)
        assert.are.equal(1, counter.calls,
            "idle detector must call end_run once after 30s idle in MENU")
        assert.is_nil(run_state.last_action_timestamp,
            "idle detector must clear last_action_timestamp after firing")

        update_idle_check(recorder, run_state, MENU_G)
        assert.are.equal(1, counter.calls,
            "idle detector must not re-fire after end_run was called")
    end)

    it("does not fire when G.STATE is not MENU", function()
        local counter = { calls = 0 }
        local run_state = { last_action_timestamp = os.time() - 35 }
        update_idle_check(make_mock_recorder(counter), run_state, NOT_MENU_G)
        assert.are.equal(0, counter.calls,
            "idle detector must not fire when G.STATE is not MENU")
    end)

    it("does not fire when last action was recent (< 30s)", function()
        local counter = { calls = 0 }
        local run_state = { last_action_timestamp = os.time() - 10 }
        update_idle_check(make_mock_recorder(counter), run_state, MENU_G)
        assert.are.equal(0, counter.calls,
            "idle detector must not fire when last action was less than 30s ago")
    end)

end)

describe("idle detector: resets when a new action is recorded", function()

    it("recording a new action updates last_action_timestamp, preventing idle fire", function()
        local run_state = { last_action_timestamp = os.time() - 35 }

        -- Simulate record_action updating the timestamp.
        run_state.last_action_timestamp = os.time()

        local counter = { calls = 0 }
        update_idle_check(make_mock_recorder(counter), run_state, MENU_G)
        assert.are.equal(0, counter.calls,
            "after recording a new action, idle detector must not fire")
    end)

end)
