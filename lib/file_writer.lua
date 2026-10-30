--- file_writer.lua
--- Run writer.
---
--- Accumulates Decision_Nodes in memory during a run and writes a single
--- self-contained JSON file when the run ends. The file is gzipped for
--- size (typical ~98% reduction on JSON full of repeated field names).
---
--- We deliberately do NOT stream to disk on every action. Earlier
--- iterations of this module did per-action NDJSON appends for crash
--- recovery, but the only append primitive guaranteed available across
--- Balatro's filesystem APIs is full-file rewrite, which becomes
--- O(N²) over a run and stalls the game's event loop. Keep the
--- buffer in memory; flush once at end_run when the player is no
--- longer actively playing.
---
--- File location: <mod_path>/log/<run_id>.json.gz
--- On Mac: ~/Library/Application Support/Balatro/Mods/Antelytics/log/
---
--- Seed privacy: the seed is written to disk ONLY once the run is over
--- (outcome "win" or "loss"). In-progress and interrupted files carry
--- `seed: null`, the run_id / filename is `<timestamp>_<random hex>` and
--- contains no seed, and nodes carry no seed. Consequently there is no
--- save/quit/continue detection: continuing a saved game starts a new
--- run file, and the pre-quit file stays as it was (outcome
--- "interrupted", no seed).
---
--- Final file format (after gzip decompression):
---   {
---     "version":         "1.0",
---     "run_id":          string,
---     "player_id":       string,
---     "seed":            string | null   (null until the run is over),
---     "gamemode":        string,
---     "start_timestamp": number,
---     "end_timestamp":   number | null,
---     "outcome":         "win" | "loss" | "interrupted" | null,
---     "final_ante":      number | null,
---     "pvp_summary":     table | null,
---     "nodes":           [ Decision_Node, ... ]
---   }

local FileWriter = {}
FileWriter.__index = FileWriter

local FORMAT_VERSION = "1.0"
local FINAL_EXT      = ".json.gz"

-- Outcomes after which the run is over and the seed may be written.
local FINAL_OUTCOMES = { win = true, loss = true }

-- ---------------------------------------------------------------------------
-- Identifiers
-- ---------------------------------------------------------------------------

local HEX_DIGITS = "0123456789abcdef"

--- Default RNG. love.math.random has its own generator that Balatro never
--- reseeds; math.random is reseeded deterministically from the run seed by
--- Balatro's pseudorandom() helpers, so it is only a fallback.
local function default_random()
    if love and love.math and love.math.random then
        return love.math.random()
    end
    return math.random()
end

--- `n` random lowercase hex characters.
function FileWriter.random_hex(n, rng)
    rng = rng or default_random
    local out = {}
    for i = 1, n do
        local k = math.floor(rng() * 16) % 16 + 1
        out[i] = HEX_DIGITS:sub(k, k)
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Filesystem facade — wraps the host's filesystem so tests can swap in a
-- pure-Lua in-memory implementation. The default backend uses SMODS.NFS
-- when available (lets us write to the mod directory) and falls back to
-- love.filesystem (sandboxed save directory) otherwise.
-- ---------------------------------------------------------------------------

local function build_default_fs(mod_path)
    local nfs = rawget(_G, "SMODS") and rawget(_G, "SMODS").NFS
    local has_nfs = nfs and mod_path and mod_path ~= ""
    local log_dir = has_nfs and (mod_path .. "log") or "Antelytics"

    if has_nfs then
        pcall(function() nfs.createDirectory(log_dir) end)
    else
        pcall(function() love.filesystem.createDirectory("Antelytics") end)
    end

    return {
        log_dir = log_dir,

        --- Write a binary string to a file (used for the gzipped final).
        write = function(self, name, data)
            if has_nfs then
                local path = log_dir .. "/" .. name
                return nfs.write(path, data)
            else
                local path = "Antelytics/" .. name
                return love.filesystem.write(path, data)
            end
        end,

        --- Read a file's contents. Returns nil when the file doesn't exist.
        read = function(self, name)
            if has_nfs and nfs.read then
                local path = log_dir .. "/" .. name
                local ok, data = pcall(function() return nfs.read(path) end)
                return ok and data or nil
            else
                local path = "Antelytics/" .. name
                local ok, data = pcall(function()
                    return love.filesystem.read(path)
                end)
                return ok and data or nil
            end
        end,

        --- Rename a file. Returns true on success, false when unavailable.
        rename = function(self, from, to)
            if has_nfs and nfs.rename then
                local ok = pcall(function()
                    -- Per design.md Open Question 8: verify SMODS.NFS.rename
                    -- exists in 1.0.0~BETA-1503a during live testing.
                    nfs.rename(log_dir .. "/" .. from, log_dir .. "/" .. to)
                end)
                return ok
            end
            -- love.filesystem 11 has no rename; write_atomic falls back
            -- to direct write when this returns false.
            return false
        end,

        --- Best-effort delete. Failures are silently ignored.
        remove = function(self, name)
            if has_nfs and nfs.remove then
                pcall(function() nfs.remove(log_dir .. "/" .. name) end)
            else
                pcall(function()
                    love.filesystem.remove("Antelytics/" .. name)
                end)
            end
            return true
        end,

        --- List all filenames in the log directory. Returns an array of
        --- filename strings (no directory prefix), or empty table on error.
        list = function(self)
            local names = {}
            if has_nfs and nfs.getDirectoryItems then
                local ok, items = pcall(function()
                    return nfs.getDirectoryItems(log_dir)
                end)
                if ok and items then
                    for _, name in ipairs(items) do
                        names[#names + 1] = name
                    end
                end
            else
                local ok, items = pcall(function()
                    return love.filesystem.getDirectoryItems("Antelytics")
                end)
                if ok and items then
                    for _, name in ipairs(items) do
                        names[#names + 1] = name
                    end
                end
            end
            return names
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Compression facade — defaults to love.data.compress (LÖVE 11 native gzip,
-- ~5ms for a 1.5MB run, ~98% size reduction on JSON). Pure-Lua test
-- environments can inject a no-op or a custom compressor.
-- ---------------------------------------------------------------------------
local function default_compress(data)
    if love and love.data and love.data.compress then
        local compressed = love.data.compress("string", "gzip", data)
        if type(compressed) == "string" then return compressed end
        if type(compressed) == "userdata" and compressed.getString then
            return compressed:getString()
        end
    end
    -- Fallback: store uncompressed. The viewer detects gzip vs plain by
    -- magic bytes, so a non-gzipped file still loads correctly.
    return data
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

--- Create a new FileWriter instance.
--- @param deps table {
---   serializer  = JSON encoder (encode, null),
---   logger      = function(msg),
---   mod_path    = string  (path to mod directory; "" disables NFS),
---   fs          = optional filesystem facade for testing,
---   compress    = optional compression function (string -> string),
---   random      = optional RNG (function -> number in [0, 1)),
--- }
function FileWriter.new(deps)
    deps = deps or {}
    local self = setmetatable({
        serializer = deps.serializer,
        logger     = deps.logger or function() end,
        mod_path   = deps.mod_path or "",
        fs         = deps.fs or build_default_fs(deps.mod_path or ""),
        compress   = deps.compress or default_compress,
        random     = deps.random or default_random,

        -- Per-run state, reset on each start_run
        run_id          = nil,
        player_id       = nil,
        seed            = nil,
        gamemode        = nil,
        start_timestamp = nil,
        nodes           = {},
    }, FileWriter)
    return self
end

--- A fresh run_id: `<timestamp>_<8 random hex>`. Becomes the filename.
--- Deliberately seed-free (see "Seed privacy" above); the timestamp prefix
--- keeps a directory listing in chronological order.
function FileWriter:new_run_id(timestamp)
    return tostring(timestamp or os.time()) .. "_" .. FileWriter.random_hex(8, self.random)
end

--- Build the record written by end_run and flush_partial. The seed is
--- included only when `outcome` means the run is over.
function FileWriter:build_record(outcome, final_ante, pvp_summary)
    local null = self.serializer.null
    local is_final = FINAL_OUTCOMES[outcome] == true
    local record = {
        version         = FORMAT_VERSION,
        run_id          = self.run_id,
        player_id       = self.player_id,
        seed            = is_final and self.seed or null,
        gamemode        = self.gamemode or "solo",
        deck_back       = self.deck_back or null,
        stake           = self.stake or null,
        start_timestamp = self.start_timestamp,
        end_timestamp   = os.time(),
        outcome         = outcome or null,
        final_ante      = final_ante or null,
        pvp_summary     = pvp_summary or null,
        nodes           = self.nodes,
    }
    return record
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Begin a new run. Clears any accumulated nodes from a previous run.
function FileWriter:start_run(run_id, player_id, seed, start_timestamp, gamemode, deck_back, stake)
    self.run_id          = run_id
    self.player_id       = player_id or "anonymous"
    self.seed            = seed or "unknown"
    self.gamemode        = gamemode or "solo"
    self.start_timestamp = start_timestamp or os.time()
    self.nodes           = {}
    self.deck_back       = deck_back or nil
    self.stake           = stake or nil
    self.logger("FileWriter: started run " .. tostring(run_id))
end

--- Append a Decision_Node to the in-memory buffer. No disk I/O.
--- @param node table { index, state, action }
function FileWriter:append_node(node)
    if not self.run_id then return end
    self.nodes[#self.nodes + 1] = node
end

--- Finish the run: build the final record, gzip it, write
--- `<run_id>.json.gz`. Single disk write per run.
--- @param outcome string "win" | "loss" | "interrupted"
--- @param final_ante number | nil
--- @param pvp_summary table | nil
function FileWriter:end_run(outcome, final_ante, pvp_summary)
    if not self.run_id then return end
    local run_id = self.run_id

    local ok, err = pcall(function()
        local record = self:build_record(outcome, final_ante, pvp_summary)

        local json = self.serializer.encode(record)
        local compressed = self.compress(json)
        local ok_write = self:write_atomic(run_id .. FINAL_EXT, compressed)

        self.logger(string.format(
            "FileWriter: %s %s (%d nodes, %d -> %d bytes)",
            ok_write and "wrote" or "FAILED writing",
            run_id .. FINAL_EXT, #self.nodes, #json, #compressed
        ))
    end)

    if not ok then
        self.logger("FileWriter: end_run error: " .. tostring(err))
    end

    -- Reset state so a follow-up append_node is a no-op.
    self.run_id = nil
    self.nodes = {}
end

--- Write data atomically: write to <name>.tmp then rename over <name>.
--- Falls back to a direct write when the fs facade has no rename method.
--- Returns true on success, false on failure.
--- @param name string  filename (without directory prefix)
--- @param data string  binary payload
function FileWriter:write_atomic(name, data)
    local wrote = false
    local ok, err = pcall(function()
        local tmp = name .. ".tmp"
        local w_tmp = self.fs:write(tmp, data)
        -- Real fs (NativeFS / love.filesystem) returns `false` on failure; a
        -- test mock may return nil. Treat only an explicit `false` as failure
        -- so mocks (and the happy path) still register as written.
        if w_tmp ~= false and self.fs.rename and self.fs:rename(tmp, name) then
            -- Rename succeeded — .tmp is gone, target is in place.
            wrote = true
            return
        end
        -- No rename available (love.filesystem 11) or rename failed.
        -- Write directly to the target and clean up any stale .tmp.
        local w_direct = self.fs:write(name, data)
        wrote = (w_direct ~= false)
        if self.fs.remove then
            pcall(function() self.fs:remove(tmp) end)
        end
    end)
    if not ok then
        self.logger("FileWriter: write_atomic error for " .. name .. ": " .. tostring(err))
        return false
    end
    if not wrote then
        -- The fs returned no success but didn't throw — the classic silent
        -- failure (invalid filename or permissions). Log it loudly so this
        -- isn't a black hole again.
        self.logger("FileWriter: write FAILED for " .. name
            .. " (filesystem returned no success — invalid filename or permissions?)")
        return false
    end
    return true
end

--- Write the in-memory buffer to disk with outcome = "in_progress".
--- Called at natural pause points (blind_beaten, shop_entered,
--- pvp_round_ended) so the viewer can open a live run file.
---
--- The file uses the same name as end_run (<run_id>.json.gz) so the
--- final end_run write atomically overwrites the partial without
--- leaving stale files behind.
---
--- Does NOT clear run_id or nodes — the run is still in progress.
--- Wrapped in pcall internally; failures are logged but never crash.
function FileWriter:flush_partial()
    if not self.run_id then return end
    local run_id = self.run_id

    local ok, err = pcall(function()
        local record = self:build_record("in_progress", nil, nil)

        local json = self.serializer.encode(record)
        local compressed = self.compress(json)
        self:write_atomic(run_id .. FINAL_EXT, compressed)

        self.logger(string.format(
            "FileWriter: flush_partial %s (%d nodes)",
            run_id .. FINAL_EXT, #self.nodes
        ))
    end)

    if not ok then
        self.logger("FileWriter: flush_partial error: " .. tostring(err))
    end
end

--- No-op stub kept for API compatibility with the previous NDJSON-based
--- recovery flow. With the in-memory model there are no orphan files to
--- recover from a crash — interrupted runs simply lose their data.
--- We keep the method so callers don't break; future work could
--- reintroduce streaming on a guarded path.
function FileWriter:recover_orphan_runs()
    return 0
end

--- Returns the directory where run files are saved.
function FileWriter:save_path()
    return self.fs.log_dir
end

return FileWriter
