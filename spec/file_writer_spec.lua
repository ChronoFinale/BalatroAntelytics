--- Tests for FileWriter — in-memory run buffer + gzip on end_run.
---
--- We keep the buffer in memory during a run and write a single
--- compressed file at end_run. Earlier streaming experiments caused
--- O(N²) writes on the game thread, so the simpler design is the one
--- the production mod ships with.

local FileWriter = require("lib.file_writer")
local Serializer = require("lib.serializer")

--- Build an in-memory filesystem with the same shape as the production
--- FileWriter facade. Lets us assert exactly what was written without
--- touching the real disk.
local function make_in_memory_fs()
    local files = {}
    return {
        files   = files,
        log_dir = "/test/log",

        write = function(self, name, data)
            files[name] = data
            return true
        end,
    }
end

--- A no-op compress fn so tests assert against plaintext JSON. The real
--- love.data gzip path is exercised in integration / smoke tests, not
--- here.
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

describe("FileWriter — in-memory buffer + gzipped final write", function()

    describe("start_run", function()
        it("clears any accumulated nodes from a previous run", function()
            local fs = make_in_memory_fs()
            local fw = make_writer(fs)
            fw:start_run("RUN1", "alice", "SEED", 1000, "solo")
            fw:append_node({ index = 0, action = { type = "play_hand" } })
            fw:start_run("RUN2", "bob", "S2", 2000, "pvp")
            fw:end_run("loss", 3, nil)

            local record = Serializer.decode(fs.files["RUN2.json.gz"])
            assert.are.equal("RUN2", record.run_id)
            assert.are.equal(0, #record.nodes)
        end)
    end)

    describe("append_node", function()
        it("buffers nodes in memory without writing to disk", function()
            local fs = make_in_memory_fs()
            local fw = make_writer(fs)
            fw:start_run("RUN1", "alice", "SEED", 1000, "solo")
            fw:append_node({ index = 0, action = { type = "select_blind" } })
            fw:append_node({ index = 1, action = { type = "play_hand" } })

            -- No file should exist yet — buffered only.
            assert.is_nil(fs.files["RUN1.json.gz"])
        end)

        it("silently no-ops when called outside a run", function()
            local fs = make_in_memory_fs()
            local fw = make_writer(fs)
            fw:append_node({ index = 0, action = { type = "play_hand" } })
            assert.is_nil(fs.files["RUN1.json.gz"])
        end)
    end)

    describe("end_run", function()
        it("writes a single .json.gz file with all buffered nodes", function()
            local fs = make_in_memory_fs()
            local fw = make_writer(fs)
            fw:start_run("RUN1", "alice", "SEED", 1000, "solo")
            fw:append_node({ index = 0, action = { type = "select_blind" } })
            fw:append_node({ index = 1, action = { type = "play_hand" } })
            fw:end_run("win", 8, nil)

            assert.is_string(fs.files["RUN1.json.gz"])
            local record = Serializer.decode(fs.files["RUN1.json.gz"])
            assert.are.equal("RUN1", record.run_id)
            assert.are.equal("alice", record.player_id)
            assert.are.equal("win", record.outcome)
            assert.are.equal(8, record.final_ante)
            assert.are.equal(2, #record.nodes)
            assert.are.equal(0, record.nodes[1].index)
            assert.are.equal(1, record.nodes[2].index)
        end)

        it("preserves run-level metadata in the final record", function()
            local fs = make_in_memory_fs()
            local fw = make_writer(fs)
            fw:start_run("RUN2", "bob", "OTHERSEED", 5000, "pvp")
            fw:append_node({ index = 0, action = { type = "play_hand" } })
            fw:end_run("loss", 3, { opponent_id = "x" })

            local record = Serializer.decode(fs.files["RUN2.json.gz"])
            assert.are.equal("RUN2", record.run_id)
            assert.are.equal("OTHERSEED", record.seed)
            assert.are.equal("pvp", record.gamemode)
            assert.are.equal(5000, record.start_timestamp)
            assert.is_table(record.pvp_summary)
            assert.are.equal("x", record.pvp_summary.opponent_id)
        end)

        it("writes an empty-nodes file when end_run fires with nothing buffered", function()
            local fs = make_in_memory_fs()
            local fw = make_writer(fs)
            fw:start_run("RUN3", "carl", "S", 7000, "solo")
            fw:end_run("interrupted", nil, nil)

            assert.is_string(fs.files["RUN3.json.gz"])
            local record = Serializer.decode(fs.files["RUN3.json.gz"])
            assert.are.equal("RUN3", record.run_id)
            assert.are.equal(0, #record.nodes)
            assert.are.equal("interrupted", record.outcome)
        end)

        it("clears state so post-end append_node calls are no-ops", function()
            local fs = make_in_memory_fs()
            local fw = make_writer(fs)
            fw:start_run("RUN1", "alice", "SEED", 1000, "solo")
            fw:end_run("win", 8, nil)
            fw:append_node({ index = 99, action = { type = "play_hand" } })

            local record = Serializer.decode(fs.files["RUN1.json.gz"])
            assert.are.equal(0, #record.nodes)
        end)
    end)

    describe("compression", function()
        it("calls the injected compressor on the final JSON", function()
            local fs = make_in_memory_fs()
            local compress_calls = 0
            local fw = FileWriter.new({
                serializer = Serializer,
                logger     = function() end,
                mod_path   = "/test/",
                fs         = fs,
                compress   = function(data)
                    compress_calls = compress_calls + 1
                    return "COMPRESSED:" .. data
                end,
            })

            fw:start_run("R1", "alice", "S", 1000, "solo")
            fw:append_node({ index = 0, action = { type = "play_hand" } })
            fw:end_run("win", 8, nil)

            assert.are.equal(1, compress_calls)
            assert.is_string(fs.files["R1.json.gz"])
            assert.is_truthy(fs.files["R1.json.gz"]:find("^COMPRESSED:"))
        end)
    end)

    describe("recover_orphan_runs", function()
        it("returns 0 — no orphan recovery in the in-memory model", function()
            local fs = make_in_memory_fs()
            local fw = make_writer(fs)
            assert.are.equal(0, fw:recover_orphan_runs())
        end)
    end)
end)

-- ---------------------------------------------------------------------------
-- Task 37 — flush_partial + end_run round-trip (Bug E)
-- ---------------------------------------------------------------------------

describe("FileWriter — flush_partial + end_run round-trip (Bug E)", function()

    local function make_fs_with_rename()
        local files = {}
        return {
            files   = files,
            log_dir = "/test/log",
            write   = function(self, name, data) files[name] = data; return true end,
            read    = function(self, name) return files[name] end,
            rename  = function(self, from, to)
                if files[from] == nil then return false end
                files[to] = files[from]; files[from] = nil; return true
            end,
            remove  = function(self, name) files[name] = nil; return true end,
        }
    end

    local function make_writer_with_rename()
        return FileWriter.new({
            serializer = Serializer,
            logger     = function() end,
            mod_path   = "/test/",
            fs         = make_fs_with_rename(),
            compress   = passthrough_compress,
        })
    end

    it("flush_partial then end_run: final file has correct outcome and all nodes", function()
        local fw = make_writer_with_rename()
        fw:start_run("RUN_RT", "alice", "SEED", 1000, "solo")
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:append_node({ index = 1, action = { type = "blind_beaten" } })
        fw:flush_partial()

        -- Partial file exists with in_progress.
        local partial = Serializer.decode(fw.fs.files["RUN_RT.json.gz"])
        assert.are.equal("in_progress", partial.outcome)
        assert.are.equal(2, #partial.nodes)

        -- More nodes, then end_run.
        fw:append_node({ index = 2, action = { type = "shop_entered" } })
        fw:end_run("win", 8, nil)

        local final = Serializer.decode(fw.fs.files["RUN_RT.json.gz"])
        assert.are.equal("win", final.outcome,
            "end_run must overwrite partial with final outcome")
        assert.are.equal(3, #final.nodes,
            "final file must include all nodes from before and after the flush")
        assert.are.equal(8, final.final_ante)
    end)

    it("partial file decodes cleanly via the serializer", function()
        local fw = make_writer_with_rename()
        fw:start_run("RUN_DECODE", "bob", "S2", 2000, "solo")
        fw:append_node({ index = 0, action = { type = "play_hand", hand_type = "Pair" } })
        fw:flush_partial()

        local record = Serializer.decode(fw.fs.files["RUN_DECODE.json.gz"])
        assert.is_table(record)
        assert.are.equal("in_progress", record.outcome)
        assert.are.equal("Pair", record.nodes[1].action.hand_type)
    end)

    it("outcome=interrupted path on love.quit still works (Req 3.9)", function()
        local fw = make_writer_with_rename()
        fw:start_run("RUN_QUIT", "carl", "S3", 3000, "solo")
        fw:append_node({ index = 0, action = { type = "select_blind" } })
        fw:flush_partial()
        fw:append_node({ index = 1, action = { type = "play_hand" } })
        fw:end_run("interrupted", 2, nil)

        local record = Serializer.decode(fw.fs.files["RUN_QUIT.json.gz"])
        assert.are.equal("interrupted", record.outcome,
            "love.quit path must still produce outcome=interrupted")
        assert.are.equal(2, #record.nodes)
    end)

end)
