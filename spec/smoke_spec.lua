--- spec/smoke_spec.lua
--- End-to-end smoke test for the file-based capture pipeline.
---
--- Builds a fake game scenario and asserts that every action type that
--- should be captured ends up in the recorder's node buffer. This catches
--- the class of regressions where a code-path change silently drops nodes
--- (e.g. the bug where send_node only wrote to HTTP, not the file writer).
---
--- This test does NOT load the full plugin (no Steamodded, no LÖVE). It
--- wires together the modules directly and feeds them controlled inputs.

local Recorder    = assert(loadfile("lib/recorder.lua"))()
local Serializer  = assert(loadfile("lib/serializer.lua"))()
local FileWriter  = assert(loadfile("lib/file_writer.lua"))()

-- Mock file_writer that captures appended nodes in memory instead of
-- writing to disk. Lets us assert what would have been written.
local function make_capturing_file_writer()
    return {
        nodes  = {},
        run_id = nil,
        start_run = function(self, run_id)
            self.run_id = run_id
            self.nodes = {}
        end,
        append_node = function(self, node)
            self.nodes[#self.nodes + 1] = node
        end,
        end_run = function(self, outcome, final_ante, pvp_summary)
            self.outcome = outcome
            self.final_ante = final_ante
            self.pvp_summary = pvp_summary
        end,
    }
end

describe("end-to-end capture pipeline", function()

    it("records every action type that flows through the recorder", function()
        local fw = make_capturing_file_writer()
        local recorder = Recorder.new({ file_writer = fw, logger = function() end })

        recorder:start_run("TEST_123", "tester", "TEST", 1700000000)

        -- Simulate every action type the plugin can emit. The exact state
        -- shape doesn't matter here — we just want to prove each call
        -- lands a node in the file writer.
        local action_types = {
            "select_blind",
            "play_hand",
            "discard",
            "blind_beaten",
            "shop_entered",
            "buy_joker",
            "buy_consumable",
            "buy_voucher",
            "buy_pack",
            "sell_joker",
            "use_consumable",
            "reroll_shop",
            "open_pack",
            "select_from_pack",
            "ending_pack",
            "ending_shop",
            "skip_blind_tag",
            "pvp_hand_scored",
            "opponent_hand_scored",
        }

        for _, t in ipairs(action_types) do
            recorder:send({
                index = recorder:next_index(),
                state = { ante = 1, money = 4 },
                action = { type = t },
            })
        end

        recorder:end_run("loss", 2, nil)

        assert.are.equal(#action_types, #fw.nodes)
        for i, t in ipairs(action_types) do
            assert.are.equal(t, fw.nodes[i].action.type,
                "missing or out-of-order: " .. t)
            assert.are.equal(i - 1, fw.nodes[i].index,
                "wrong index for " .. t)
        end
        assert.are.equal("loss", fw.outcome)
        assert.are.equal(2, fw.final_ante)
    end)

    it("drops sends silently when not active", function()
        local fw = make_capturing_file_writer()
        local recorder = Recorder.new({ file_writer = fw, logger = function() end })

        -- No start_run called — recorder is inactive
        recorder:send({
            index = 0,
            state = {},
            action = { type = "play_hand" },
        })

        assert.are.equal(0, #fw.nodes)
    end)

    it("end_run is a no-op when not active", function()
        local fw = make_capturing_file_writer()
        local recorder = Recorder.new({ file_writer = fw, logger = function() end })

        recorder:end_run("win", 8, nil)
        assert.is_nil(fw.outcome)
    end)

    it("indices are sequential and zero-based", function()
        local fw = make_capturing_file_writer()
        local recorder = Recorder.new({ file_writer = fw, logger = function() end })
        recorder:start_run("RUN", "p", "S", 0)

        for i = 1, 5 do
            recorder:send({
                index = recorder:next_index(),
                state = {},
                action = { type = "play_hand" },
            })
        end

        for i = 1, 5 do
            assert.are.equal(i - 1, fw.nodes[i].index)
        end
    end)

    it("seq resets on a new run", function()
        local fw = make_capturing_file_writer()
        local recorder = Recorder.new({ file_writer = fw, logger = function() end })

        recorder:start_run("RUN_1", "p", "S", 0)
        recorder:send({ index = recorder:next_index(), state = {}, action = { type = "play_hand" } })
        recorder:end_run("loss", 1, nil)

        recorder:start_run("RUN_2", "p", "S", 0)
        recorder:send({ index = recorder:next_index(), state = {}, action = { type = "play_hand" } })

        -- After the second start_run the seq should be back to 0
        assert.are.equal(0, fw.nodes[1].index)
    end)
end)

describe("Recorder + FileWriter integration", function()
    it("FileWriter receives append_node + start_run + end_run in order", function()
        local calls = {}
        local fake_fw = {
            start_run = function(_, run_id) calls[#calls + 1] = "start:" .. run_id end,
            append_node = function(_, node) calls[#calls + 1] = "append:" .. node.action.type end,
            end_run = function(_, outcome) calls[#calls + 1] = "end:" .. outcome end,
        }

        local recorder = Recorder.new({ file_writer = fake_fw, logger = function() end })
        recorder:start_run("RUN", "p", "S", 0)
        recorder:send({ index = 0, state = {}, action = { type = "play_hand" } })
        recorder:send({ index = 1, state = {}, action = { type = "blind_beaten" } })
        recorder:end_run("win", 8, nil)

        assert.are.same({
            "start:RUN",
            "append:play_hand",
            "append:blind_beaten",
            "end:win",
        }, calls)
    end)
end)
