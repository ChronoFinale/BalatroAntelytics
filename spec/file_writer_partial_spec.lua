--- spec/file_writer_partial_spec.lua
---
--- Bug E — Mid-run persistence: flush_partial + write_atomic
---
--- Exploration and correctness tests for the partial-flush and
--- atomic-write infrastructure added in tasks 30–37.
---
--- Bug condition: FileWriter only writes at end_run. A mid-run viewer
--- has no file to open. The fix adds:
---   - FileWriter:write_atomic(name, data) — writes to .tmp then renames
---   - FileWriter:flush_partial()          — writes outcome="in_progress"
---   - Wire flush_partial after blind_beaten / shop_entered / pvp_round_ended
---
--- These tests FAIL on unfixed code because flush_partial / write_atomic
--- do not exist yet.
---
--- _Validates: Requirements 2.7, 3.2, 3.3, 3.9_

local FileWriter = require("lib.file_writer")
local Serializer = require("lib.serializer")

-- ---------------------------------------------------------------------------
-- In-memory filesystem with rename + remove support (needed for write_atomic)
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

-- ---------------------------------------------------------------------------
-- write_atomic tests
-- ---------------------------------------------------------------------------

describe("FileWriter:write_atomic", function()

    it("writes to .tmp first then renames over the target when rename is available", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)

        local ok = fw:write_atomic("RUN1.json.gz", "PAYLOAD")

        assert.is_true(ok, "write_atomic must return true on success")
        -- Final file must exist with the payload.
        assert.are.equal("PAYLOAD", fs.files["RUN1.json.gz"])
        -- Temp file must have been cleaned up by the rename.
        assert.is_nil(fs.files["RUN1.json.gz.tmp"],
            "write_atomic must rename .tmp over the target, leaving no .tmp behind")
    end)

    it("falls back to direct write when rename is not available", function()
        local fs = make_in_memory_fs()
        -- Remove rename to simulate the fallback path.
        fs.rename = nil
        local fw = make_writer(fs)

        local ok = fw:write_atomic("RUN1.json.gz", "PAYLOAD_FALLBACK")

        assert.is_true(ok)
        assert.are.equal("PAYLOAD_FALLBACK", fs.files["RUN1.json.gz"])
    end)

end)

-- ---------------------------------------------------------------------------
-- flush_partial tests
-- ---------------------------------------------------------------------------

describe("FileWriter:flush_partial", function()

    it("writes outcome=in_progress with all buffered nodes after first flush", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        fw:start_run("RUN1", "alice", "SEED", 1000, "solo")
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:append_node({ index = 1, action = { type = "play_hand" } })
        fw:append_node({ index = 2, action = { type = "blind_beaten" } })

        fw:flush_partial()

        assert.is_string(fs.files["RUN1.json.gz"],
            "flush_partial must write a file to disk")
        local record = Serializer.decode(fs.files["RUN1.json.gz"])
        assert.are.equal("in_progress", record.outcome,
            "flush_partial must set outcome = 'in_progress'")
        assert.are.equal(3, #record.nodes,
            "flush_partial must include all buffered nodes")
        assert.are.equal("RUN1", record.run_id)
    end)

    it("second flush after more nodes includes all nodes (monotonic append-only)", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        fw:start_run("RUN1", "alice", "SEED", 1000, "solo")
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:append_node({ index = 1, action = { type = "play_hand" } })
        fw:append_node({ index = 2, action = { type = "blind_beaten" } })
        fw:flush_partial()

        fw:append_node({ index = 3, action = { type = "shop_entered" } })
        fw:append_node({ index = 4, action = { type = "buy_joker" } })
        fw:flush_partial()

        local record = Serializer.decode(fs.files["RUN1.json.gz"])
        assert.are.equal("in_progress", record.outcome)
        assert.are.equal(5, #record.nodes,
            "second flush must include all 5 nodes (3 from first flush + 2 new)")
    end)

    it("end_run after flush_partial overwrites with final outcome and all nodes", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        fw:start_run("RUN1", "alice", "SEED", 1000, "solo")
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:append_node({ index = 1, action = { type = "blind_beaten" } })
        fw:flush_partial()

        fw:append_node({ index = 2, action = { type = "shop_entered" } })
        fw:end_run("win", 8, nil)

        local record = Serializer.decode(fs.files["RUN1.json.gz"])
        assert.are.equal("win", record.outcome,
            "end_run must overwrite the partial file with the final outcome")
        assert.are.equal(3, #record.nodes,
            "end_run must include all nodes from both before and after the flush")
        assert.are.equal(8, record.final_ante)
    end)

    it("flush_partial does not clear run_id or nodes — run continues", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        fw:start_run("RUN1", "alice", "SEED", 1000, "solo")
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:flush_partial()

        -- Run must still be active after flush.
        assert.is_not_nil(fw.run_id,
            "flush_partial must not clear run_id — the run is still in progress")
        assert.are.equal(1, #fw.nodes,
            "flush_partial must not clear the in-memory buffer")

        -- Appending after flush must work.
        fw:append_node({ index = 1, action = { type = "play_hand" } })
        assert.are.equal(2, #fw.nodes)
    end)

    it("flush_partial callable many times without leaking handles or temp files", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        fw:start_run("RUN1", "alice", "SEED", 1000, "solo")
        fw:append_node({ index = 0, action = { type = "select_blind" } })

        for _ = 1, 10 do
            fw:flush_partial()
        end

        -- No .tmp files should remain.
        for name, _ in pairs(fs.files) do
            assert.is_falsy(name:find("%.tmp$"),
                "no .tmp files should remain after repeated flush_partial calls")
        end

        local record = Serializer.decode(fs.files["RUN1.json.gz"])
        assert.are.equal("in_progress", record.outcome)
        assert.are.equal(1, #record.nodes)
    end)

    it("flush_partial is a no-op when no run is active", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        -- No start_run called.
        fw:flush_partial()  -- must not error
        local file_count = 0
        for _ in pairs(fs.files) do file_count = file_count + 1 end
        assert.are.equal(0, file_count,
            "flush_partial outside a run must not write any files")
    end)

end)

-- ---------------------------------------------------------------------------
-- Property-based test: monotonic append-only invariant
--
-- For any sequence of (append_node × N, flush_partial)*, the on-disk
-- file decodes successfully and nodes is a prefix of every later
-- flush's nodes.
-- ---------------------------------------------------------------------------

describe("flush_partial monotonic append-only property", function()

    it("property: each flush's nodes is a prefix of the next flush's nodes", function()
        local function make_rng(seed)
            local state = seed
            return function()
                state = (state * 1103515245 + 12345) % 2147483648
                return state
            end
        end

        for trial = 1, 30 do
            local fs = make_in_memory_fs()
            local fw = make_writer(fs)
            fw:start_run("RUN_PROP_" .. trial, "alice", "SEED", 1000, "solo")

            local rng = make_rng(trial * 9973)
            local total_nodes = 5 + (rng() % 20)  -- 5..24 nodes
            local flush_count = 2 + (rng() % 4)   -- 2..5 flushes

            -- Distribute nodes across flushes.
            local nodes_per_flush = {}
            local remaining = total_nodes
            for i = 1, flush_count do
                if i == flush_count then
                    nodes_per_flush[i] = remaining
                else
                    local n = 1 + (rng() % math.max(1, math.floor(remaining / (flush_count - i + 1))))
                    nodes_per_flush[i] = math.min(n, remaining)
                    remaining = remaining - nodes_per_flush[i]
                end
            end

            local cumulative = 0
            local prev_nodes_count = 0
            for flush_i, n in ipairs(nodes_per_flush) do
                for j = 1, n do
                    fw:append_node({ index = cumulative, action = { type = "play_hand" } })
                    cumulative = cumulative + 1
                end
                fw:flush_partial()

                local record = Serializer.decode(fs.files["RUN_PROP_" .. trial .. ".json.gz"])
                assert.is_table(record, "trial " .. trial .. " flush " .. flush_i .. ": file must decode")
                assert.are.equal("in_progress", record.outcome)
                assert.is_true(#record.nodes >= prev_nodes_count,
                    "trial " .. trial .. " flush " .. flush_i
                    .. ": node count must be monotonically non-decreasing")
                assert.are.equal(cumulative, #record.nodes,
                    "trial " .. trial .. " flush " .. flush_i
                    .. ": node count must equal total appended so far")
                prev_nodes_count = #record.nodes
            end
        end
    end)

end)
