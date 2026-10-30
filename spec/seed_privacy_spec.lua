--- seed_privacy_spec.lua
--- The seed must not reach disk before the run is over.
---
--- Pins:
---   - flush_partial and end_run("interrupted") write seed = null and the
---     seed string appears nowhere in the written JSON
---   - end_run("win" | "loss") writes the seed
---   - run_id / filename is <timestamp>_<8 hex>, seed-free
---   - no seed-derived field of any kind is written (no resume matching)

local FileWriter = require("lib.file_writer")
local Serializer = require("lib.serializer")

local function make_in_memory_fs()
    local files = {}
    return {
        files   = files,
        log_dir = "mem",
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
        end,
        list = function(self)
            local names = {}
            for name in pairs(files) do names[#names + 1] = name end
            table.sort(names)
            return names
        end,
    }
end

local function passthrough_compress(data) return data end

-- Deterministic RNG: cycles through a fixed sequence so ids are reproducible.
local function make_rng(values)
    local i = 0
    return function()
        i = i + 1
        return values[((i - 1) % #values) + 1]
    end
end

local function make_writer(fs, opts)
    opts = opts or {}
    return FileWriter.new({
        serializer = Serializer,
        logger     = function() end,
        mod_path   = "",
        fs         = fs,
        compress   = passthrough_compress,
        random     = opts.random,
    })
end

local SEED = "QX7PLM2A"

describe("seed privacy — in-progress and interrupted files", function()
    it("flush_partial writes seed = null and the seed string is absent from the JSON", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        fw:start_run("R1", "alice", SEED, 1000, "solo")
        fw:append_node({ index = 0, state = { ante = 1 }, action = { type = "play_hand" } })
        fw:flush_partial()

        local raw = fs.files["R1.json.gz"]
        assert.is_string(raw)
        assert.is_nil(raw:find(SEED, 1, true), "seed string must not appear in an in-progress file")

        local record = Serializer.decode(raw)
        assert.are.equal("in_progress", record.outcome)
        assert.are.equal(Serializer.null, record.seed)
    end)

    it("end_run('interrupted') writes seed = null", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        fw:start_run("R2", "alice", SEED, 1000, "solo")
        fw:end_run("interrupted", 3, nil)

        local raw = fs.files["R2.json.gz"]
        assert.is_nil(raw:find(SEED, 1, true), "seed string must not appear in an interrupted file")
        local record = Serializer.decode(raw)
        assert.are.equal("interrupted", record.outcome)
        assert.are.equal(Serializer.null, record.seed)
    end)

    it("end_run with a nil outcome withholds the seed", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        fw:start_run("R3", "alice", SEED, 1000, "solo")
        fw:end_run(nil, nil, nil)
        local record = Serializer.decode(fs.files["R3.json.gz"])
        assert.are.equal(Serializer.null, record.seed)
    end)

    it("writes no seed-derived field and nothing besides the run file", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        fw:start_run("R6", "alice", SEED, 1000, "solo")
        fw:flush_partial()

        local record = Serializer.decode(fs.files["R6.json.gz"])
        assert.is_nil(record.seed_tag)
        assert.is_nil(record.seed_hash)
        assert.is_nil(record.previous_run_id)
        assert.are.same({ "R6.json.gz" }, fs:list(),
            "no salt or side files next to the run file")
    end)
end)

describe("seed privacy — finished files", function()
    for _, outcome in ipairs({ "win", "loss" }) do
        it("end_run('" .. outcome .. "') writes the seed", function()
            local fs = make_in_memory_fs()
            local fw = make_writer(fs)
            fw:start_run("R4", "alice", SEED, 1000, "solo")
            fw:flush_partial()
            fw:end_run(outcome, 8, nil)

            local record = Serializer.decode(fs.files["R4.json.gz"])
            assert.are.equal(outcome, record.outcome)
            assert.are.equal(SEED, record.seed)
        end)
    end
end)

describe("seed privacy — run_id / filename", function()
    it("new_run_id is <timestamp>_<8 hex> and carries no seed", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs, { random = make_rng({ 0.0, 0.5, 0.99, 0.25 }) })
        local id = fw:new_run_id(1700000000)
        assert.are.equal("1700000000_08f408f4", id)
        assert.is_truthy(id:match("^%d+_%x%x%x%x%x%x%x%x$"))
    end)

    it("new_run_id defaults the timestamp to now", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        local before = os.time()
        local id = fw:new_run_id()
        local ts = tonumber(id:match("^(%d+)_"))
        assert.is_number(ts)
        assert.is_true(ts >= before and ts <= os.time())
    end)

    it("random_hex stays within the hex alphabet for edge RNG values", function()
        local hex = FileWriter.random_hex(6, make_rng({ 0.0, 0.9999999 }))
        assert.are.equal(6, #hex)
        assert.is_truthy(hex:match("^%x+$"))
    end)
end)

describe("seed privacy — no resume surface", function()
    it("FileWriter exposes no seed-matching or chain-patching API", function()
        assert.is_nil(FileWriter.find_interrupted_run_for_seed)
        assert.is_nil(FileWriter.patch_previous_run_header)
        assert.is_nil(FileWriter.seed_tag)
        assert.is_nil(FileWriter.get_salt)
    end)
end)
