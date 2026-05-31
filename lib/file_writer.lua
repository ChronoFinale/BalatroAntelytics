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
--- Final file format (after gzip decompression):
---   {
---     "version":         "1.0",
---     "run_id":          string,
---     "player_id":       string,
---     "seed":            string,
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
--- }
function FileWriter.new(deps)
    deps = deps or {}
    local self = setmetatable({
        serializer = deps.serializer,
        logger     = deps.logger or function() end,
        mod_path   = deps.mod_path or "",
        fs         = deps.fs or build_default_fs(deps.mod_path or ""),
        compress   = deps.compress or default_compress,

        -- Per-run state, reset on each start_run
        run_id          = nil,
        player_id       = nil,
        seed            = nil,
        gamemode        = nil,
        start_timestamp = nil,
        nodes           = {},
        previous_run_id = nil,
    }, FileWriter)
    return self
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Begin a new run. Clears any accumulated nodes from a previous run.
--- @param previous_run_id string | nil  run_id of the interrupted run this
---   resumes, or nil for a fresh run. Stored on self and included in every
---   record written by end_run and flush_partial as a top-level
---   `previous_run_id` field (JSON null when absent).
function FileWriter:start_run(run_id, player_id, seed, start_timestamp, gamemode, previous_run_id, deck_back, stake)
    self.run_id          = run_id
    self.player_id       = player_id or "anonymous"
    self.seed            = seed or "unknown"
    self.gamemode        = gamemode or "solo"
    self.start_timestamp = start_timestamp or os.time()
    self.nodes           = {}
    self.previous_run_id = previous_run_id or nil
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
        local record = {
            version         = FORMAT_VERSION,
            run_id          = run_id,
            player_id       = self.player_id,
            seed            = self.seed,
            gamemode        = self.gamemode or "solo",
            deck_back       = self.deck_back or self.serializer.null,
            stake           = self.stake or self.serializer.null,
            start_timestamp = self.start_timestamp,
            end_timestamp   = os.time(),
            outcome         = outcome or self.serializer.null,
            final_ante      = final_ante or self.serializer.null,
            pvp_summary     = pvp_summary or self.serializer.null,
            nodes           = self.nodes,
        }
        -- Include chain-link fields only when they carry a value.
        -- Using Lua nil omits the key from JSON entirely (cleaner than
        -- encoding as JSON null for fields that are absent on most runs).
        if self.previous_run_id then
            record.previous_run_id = self.previous_run_id
        end
        -- next_run_id is always absent at write time; it is patched in
        -- later by patch_previous_run_header when a resume is detected.

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
        local record = {
            version         = FORMAT_VERSION,
            run_id          = run_id,
            player_id       = self.player_id,
            seed            = self.seed,
            gamemode        = self.gamemode or "solo",
            start_timestamp = self.start_timestamp,
            end_timestamp   = os.time(),
            outcome         = "in_progress",
            final_ante      = self.serializer.null,
            pvp_summary     = self.serializer.null,
            nodes           = self.nodes,
        }
        if self.previous_run_id then
            record.previous_run_id = self.previous_run_id
        end

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

--- Patch the header of a previous run file to set next_run_id and
--- (when appropriate) upgrade outcome to "interrupted".
---
--- Reads the previous file via fs:read, decodes JSON, updates the
--- header fields, re-encodes, and writes back atomically. Wrapped in
--- pcall — failure to find or read the previous file logs a warning
--- but never aborts the resume.
---
--- Rules:
---   - next_run_id is always set to the provided value.
---   - outcome is set to "interrupted" only when currently null or
---     "in_progress". Completed runs ("win" / "loss") keep their
---     final outcome.
---
--- @param previous_file_name string  filename of the previous run
---   (e.g. "RUN_A.json.gz")
--- @param next_run_id string  run_id of the resumed run
function FileWriter:patch_previous_run_header(previous_file_name, next_run_id)
    local ok, err = pcall(function()
        -- Read the previous file.
        local data = self.fs:read(previous_file_name)
        if not data then
            self.logger("FileWriter: patch_previous_run_header warning: "
                .. "file not found: " .. tostring(previous_file_name))
            return
        end

        -- Detect gzip by magic bytes 0x1f 0x8b. In the test environment
        -- with passthrough_compress the data is plain JSON, so we try
        -- Serializer.decode directly first. If the data starts with the
        -- gzip magic bytes we would need to decompress first — but since
        -- we can't call love.data.decompress in tests, we rely on the
        -- test fs always storing plain JSON (passthrough_compress).
        -- In production the compress function is love.data.compress, so
        -- the stored data IS gzipped; however patch_previous_run_header
        -- is only called at resume time (not the hot path), and the
        -- production fs stores the raw compressed bytes. We detect gzip
        -- and decompress when love.data is available.
        local json_str
        local is_gzip = #data >= 2
            and data:byte(1) == 0x1f
            and data:byte(2) == 0x8b
        if is_gzip then
            if love and love.data and love.data.decompress then
                local ok_d, decompressed = pcall(function()
                    local result = love.data.decompress("string", "gzip", data)
                    if type(result) == "string" then return result end
                    if type(result) == "userdata" and result.getString then
                        return result:getString()
                    end
                    return nil
                end)
                if ok_d and decompressed then
                    json_str = decompressed
                else
                    self.logger("FileWriter: patch_previous_run_header warning: "
                        .. "failed to decompress " .. tostring(previous_file_name))
                    return
                end
            else
                -- No decompression available (test environment with real gzip).
                -- This path is not expected in tests (passthrough_compress is used).
                self.logger("FileWriter: patch_previous_run_header warning: "
                    .. "gzip data but no decompressor available for "
                    .. tostring(previous_file_name))
                return
            end
        else
            -- Plain JSON (test environment with passthrough_compress).
            json_str = data
        end

        -- Decode the JSON record.
        local ok_dec, record = pcall(function()
            return self.serializer.decode(json_str)
        end)
        if not ok_dec or type(record) ~= "table" then
            self.logger("FileWriter: patch_previous_run_header warning: "
                .. "failed to decode JSON from " .. tostring(previous_file_name))
            return
        end

        -- Update next_run_id.
        record.next_run_id = next_run_id

        -- Upgrade outcome to "interrupted" only when currently null or
        -- "in_progress". Never overwrite "win" or "loss".
        local current_outcome = record.outcome
        local is_null = current_outcome == nil
            or current_outcome == self.serializer.null
        if is_null or current_outcome == "in_progress" then
            record.outcome = "interrupted"
        end

        -- Re-encode and write back atomically.
        local new_json = self.serializer.encode(record)
        local new_data = self.compress(new_json)
        self:write_atomic(previous_file_name, new_data)

        self.logger("FileWriter: patched " .. tostring(previous_file_name)
            .. " with next_run_id=" .. tostring(next_run_id))
    end)

    if not ok then
        self.logger("FileWriter: patch_previous_run_header error for "
            .. tostring(previous_file_name) .. ": " .. tostring(err))
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

--- Scan the log directory for the most-recent interrupted run file that
--- matches `seed`. Returns the run_id string when found, nil otherwise.
---
--- This is the resume-detection helper for Bug F. When `Game:start_run`
--- fires and the game state indicates a continue (ante > 1), we call
--- this to find the pre-quit file and reuse its run_id so capture
--- appends to the same logical run.
---
--- Detection heuristic: filename starts with `seed .. "_"` and the
--- decoded record has `outcome == "interrupted"`. We pick the one with
--- the highest `start_timestamp` (most recent) in case the player has
--- multiple interrupted sessions for the same seed.
---
--- @param seed string  The run seed from G.GAME.pseudorandom.seed
--- @return string|nil  The matching run_id, or nil if none found
function FileWriter:find_interrupted_run_for_seed(seed)
    if not seed or seed == "" or seed == "unknown" then return nil end
    local prefix = seed .. "_"
    local best_run_id   = nil
    local best_timestamp = 0

    local ok, names = pcall(function() return self.fs:list() end)
    if not ok or not names then return nil end

    for _, name in ipairs(names) do
        -- Only consider files that start with our seed prefix.
        if name:sub(1, #prefix) == prefix and name:sub(-#FINAL_EXT) == FINAL_EXT then
            local run_id = name:sub(1, -#FINAL_EXT - 1)
            pcall(function()
                local raw = self.fs:read(name)
                if not raw then return end
                -- Detect gzip magic bytes and decompress if needed.
                local json = raw
                if raw:sub(1, 2) == "\x1f\x8b" then
                    if love and love.data and love.data.decompress then
                        local ok2, decompressed = pcall(function()
                            return love.data.decompress("string", "gzip", raw)
                        end)
                        if ok2 and decompressed then
                            json = type(decompressed) == "string"
                                and decompressed
                                or decompressed:getString()
                        end
                    end
                end
                local record = self.serializer.decode(json)
                if type(record) == "table"
                    and record.outcome == "interrupted"
                    and type(record.start_timestamp) == "number"
                    and record.start_timestamp > best_timestamp
                then
                    best_run_id    = run_id
                    best_timestamp = record.start_timestamp
                end
            end)
        end
    end

    return best_run_id
end

--- Returns the directory where run files are saved.
function FileWriter:save_path()
    return self.fs.log_dir
end

return FileWriter
