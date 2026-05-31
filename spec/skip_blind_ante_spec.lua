--- skip_blind_ante_spec.lua
---
--- Regression: skipping a new ante's Small Blind must stamp the skip (and the
--- tag it grants) with the CURRENT ante, not the previous one.
---
--- run_state.current_ante (the "logical ante") is only refreshed when a blind
--- is *played* (context.setting_blind). A skipped blind is never played, so
--- before the fix the skip_blind_tag + its tag_added inherited the prior ante
--- and the skipped Small Blind showed up one ante too early in the viewer.
---
--- The engine bumps G.GAME.round_resets.ante the moment the previous boss is
--- beaten (verified in Balatro source), so it already reads the correct N+1 at
--- skip time. The skip_blind wrapper now copies it into current_ante before the
--- skip runs, so the tag_added (added inside the synchronous skip) sees N+1 too.

package.path = package.path .. ";./lib/?.lua;./Antelytics/lib/?.lua"

local Capture    = assert(loadfile("lib/capture.lua"))()
local Serializer = assert(loadfile("lib/serializer.lua"))()
local Recorder   = assert(loadfile("lib/recorder.lua"))()
local hooks      = assert(loadfile("lib/hooks.lua"))()

describe("skip_blind advances the logical ante to the engine value", function()
    local state, original_called

    before_each(function()
        original_called = false

        _G.G = {
            GAME  = { round_resets = { ante = 3 } },  -- engine already at N+1
            FUNCS = {
                skip_blind = function(_) original_called = true end,
            },
        }

        Capture.init({ null_sentinel = Serializer.null, logger = function() end })

        local recorder = Recorder.new({
            file_writer = {
                start_run = function() end,
                end_run   = function() end,
                write     = function() end,
            },
            logger = function() end,
        })
        recorder:start_run("RUN", "tester", "TESTSEED", 0)

        -- Logical ante is stale at 2 (the last *played* blind was ante 2).
        state = { current_ante = 2, in_skip_blind = false }

        hooks._reset_wrap_registry()
        hooks.register_all({
            capture    = Capture,
            serializer = Serializer,
            logger     = { info = function() end, warning = function() end, error = function() end },
            config     = { player_id = "tester", enabled = true },
            recorder   = recorder,
            state      = state,
            mp         = { enabled = false },
            gate       = { current_gamemode = function() return "solo" end },
        })
    end)

    after_each(function() _G.G = nil end)

    it("copies round_resets.ante into current_ante before the skip runs", function()
        assert.are.equal(2, state.current_ante)  -- stale going in
        G.FUNCS.skip_blind({})
        assert.is_true(original_called)          -- still ran the engine skip
        assert.are.equal(3, state.current_ante)  -- advanced to the engine ante
    end)

    it("does not clobber current_ante when the engine ante is unreadable", function()
        _G.G.GAME.round_resets = nil
        G.FUNCS.skip_blind({})
        assert.are.equal(2, state.current_ante)  -- left as-is, no crash
    end)
end)
