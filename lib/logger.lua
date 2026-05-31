--- logger.lua
--- Session log writer for the Balatro Antelytics.
---
--- Public API:
---   Logger.init(mod_path)      -- sets the log file path to mod_path .. "/session.log"
---   Logger.log(level, msg)     -- adds a timestamped entry to the buffer
---   Logger.info(msg)           -- shorthand for Logger.log("INFO", msg)
---   Logger.warning(msg)        -- shorthand for Logger.log("WARNING", msg)
---   Logger.error(msg)          -- shorthand for Logger.log("ERROR", msg)
---   Logger.flush()             -- writes all buffered lines to file, clears buffer
---
--- Buffer is flushed at most once per frame from the main update loop.
--- If the log file cannot be opened, writes are silently discarded.
---
--- Requirements: 2.10, 7.3, 7.4, 7.5

local Logger = {}

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

--- Path to the session log file. Set via Logger.init().
local log_file_path = nil

--- Buffer of formatted log lines waiting to be flushed.
local buffer = {}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Initialize the logger with the mod's base path.
--- Sets the log file path to mod_path .. "/session.log".
--- @param mod_path string  The mod's directory path (e.g., SMODS.current_mod.path)
function Logger.init(mod_path)
    if type(mod_path) == "string" then
        log_file_path = mod_path .. "/session.log"
    end
end

--- Add a timestamped log entry to the buffer.
--- @param level string  Log level: "INFO", "WARNING", or "ERROR"
--- @param msg string    The message to log
function Logger.log(level, msg)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local line = "[" .. timestamp .. "] [" .. tostring(level) .. "] " .. tostring(msg) .. "\n"
    buffer[#buffer + 1] = line
end

--- Shorthand for Logger.log("INFO", msg).
--- @param msg string  The message to log
function Logger.info(msg)
    Logger.log("INFO", msg)
end

--- Shorthand for Logger.log("WARNING", msg).
--- @param msg string  The message to log
function Logger.warning(msg)
    Logger.log("WARNING", msg)
end

--- Shorthand for Logger.log("ERROR", msg).
--- @param msg string  The message to log
function Logger.error(msg)
    Logger.log("ERROR", msg)
end

--- Flush all buffered log lines to the session log file.
--- Opens the file in append mode ("a"), writes all buffered lines,
--- then closes the file and clears the buffer.
--- If the file cannot be opened, the buffer is silently discarded
--- to avoid crashing the game.
--- Called at most once per frame from the main update loop.
function Logger.flush()
    if #buffer == 0 then
        return
    end

    if log_file_path then
        local file = io.open(log_file_path, "a")
        if file then
            for i = 1, #buffer do
                file:write(buffer[i])
            end
            file:close()
        end
        -- If file open fails, silently discard (don't crash the game)
    end

    -- Clear the buffer regardless of write success
    buffer = {}
end

return Logger
