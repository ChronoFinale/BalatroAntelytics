--- seed_privacy_spec.lua
--- The seed must not reach disk before the run is over.
---
--- Pins:
---   - flush_partial and end_run("interrupted") write seed = null and the
---     seed string appears nowhere in the written JSON
---   - end_run("win" | "loss") writes the seed
---   - run_id / filename is <timestamp>_<8 hex>, seed-free
---   - seed_tag is a salted digest: stable per install, different across
---     salts, never equal to the seed, and the salt persists in .seed_salt
---   - find_interrupted_run_for_seed matches on seed_tag, picks the most
---     recent interrupted file, ignores in_progress / finished files

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
        hash       = opts.hash,
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
        assert.is_string(record.seed_tag)
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
            assert.is_string(record.seed_tag)
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

describe("seed privacy — seed_tag and salt", function()
    it("creates .seed_salt on first use and reuses it", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        local tag1 = fw:seed_tag(SEED)
        assert.is_string(fs.files[".seed_salt"])
        assert.is_true(#fs.files[".seed_salt"] >= 16)

        local fw2 = make_writer(fs)   -- fresh writer, same install
        assert.are.equal(tag1, fw2:seed_tag(SEED))
    end)

    it("differs across salts and never equals the seed", function()
        local fs_a, fs_b = make_in_memory_fs(), make_in_memory_fs()
        local fw_a = make_writer(fs_a, { random = make_rng({ 0.1, 0.2, 0.3 }) })
        local fw_b = make_writer(fs_b, { random = make_rng({ 0.7, 0.8, 0.9 }) })
        local tag_a, tag_b = fw_a:seed_tag(SEED), fw_b:seed_tag(SEED)
        assert.are_not.equal(tag_a, tag_b)
        assert.are_not.equal(SEED, tag_a)
        assert.is_nil(tag_a:find(SEED, 1, true))
    end)

    it("differs between seeds on the same install", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        assert.are_not.equal(fw:seed_tag("AAAAAAAA"), fw:seed_tag("AAAAAAAB"))
    end)

    it("is nil for unknown / empty seeds and the record then carries seed_tag = null", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        assert.is_nil(fw:seed_tag(nil))
        assert.is_nil(fw:seed_tag(""))
        assert.is_nil(fw:seed_tag("unknown"))

        fw:start_run("R5", "alice", nil, 1000, "solo")
        fw:flush_partial()
        local record = Serializer.decode(fs.files["R5.json.gz"])
        assert.are.equal(Serializer.null, record.seed_tag)
    end)

    it("digest fallback is deterministic hex", function()
        local a = FileWriter.digest("salt:" .. SEED)
        local b = FileWriter.digest("salt:" .. SEED)
        assert.are.equal(a, b)
        assert.is_truthy(a:match("^%x+$"))
        assert.are_not.equal(a, FileWriter.digest("salt:" .. SEED .. "x"))
    end)
end)

describe("seed privacy — resume detection via seed_tag", function()
    local function write_run(fw, run_id, seed, ts, outcome)
        fw:start_run(run_id, "alice", seed, ts, "solo")
        if outcome == "in_progress" then
            fw:flush_partial()
            fw.run_id = nil  -- detach without finalising
        else
            fw:end_run(outcome, 2, nil)
        end
    end

    it("finds the most recent interrupted run with the same seed", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        write_run(fw, "1000_aaaaaaaa", SEED, 1000, "interrupted")
        write_run(fw, "2000_bbbbbbbb", SEED, 2000, "interrupted")
        write_run(fw, "3000_cccccccc", "OTHERSEED", 3000, "interrupted")

        assert.are.equal("2000_bbbbbbbb", fw:find_interrupted_run_for_seed(SEED))
        assert.are.equal("3000_cccccccc", fw:find_interrupted_run_for_seed("OTHERSEED"))
    end)

    it("ignores in_progress and finished files, and unrelated files in the log dir", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        write_run(fw, "1000_aaaaaaaa", SEED, 1000, "in_progress")
        write_run(fw, "2000_bbbbbbbb", SEED, 2000, "win")
        write_run(fw, "3000_cccccccc", SEED, 3000, "loss")
        fs.files["notes.txt"] = "not a run"
        fs.files[".json.gz"]  = "{}"

        assert.is_nil(fw:find_interrupted_run_for_seed(SEED))
    end)

    it("returns nil for an unknown seed", function()
        local fs = make_in_memory_fs()
        local fw = make_writer(fs)
        write_run(fw, "1000_aaaaaaaa", SEED, 1000, "interrupted")
        assert.is_nil(fw:find_interrupted_run_for_seed("unknown"))
        assert.is_nil(fw:find_interrupted_run_for_seed(nil))
        assert.is_nil(fw:find_interrupted_run_for_seed("NOPE1234"))
    end)

    it("matches across writer instances on the same install (salt persisted)", function()
        local fs = make_in_memory_fs()
        write_run(make_writer(fs), "1000_aaaaaaaa", SEED, 1000, "interrupted")
        local later = make_writer(fs)
        assert.are.equal("1000_aaaaaaaa", later:find_interrupted_run_for_seed(SEED))
    end)

    it("does not match a file written under a different salt", function()
        local fs = make_in_memory_fs()
        write_run(make_writer(fs), "1000_aaaaaaaa", SEED, 1000, "interrupted")
        fs.files[".seed_salt"] = nil   -- install lost its salt
        local fresh = make_writer(fs, { random = make_rng({ 0.42 }) })
        assert.is_nil(fresh:find_interrupted_run_for_seed(SEED))
    end)
end)
