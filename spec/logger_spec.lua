--- logger_spec.lua
--- Unit tests for the Balatro Antelytics session log writer.
--- Validates: Requirements 2.10, 7.3, 7.4, 7.5

-- Adjust package path to find the logger module
package.path = package.path .. ";../lib/?.lua;./lib/?.lua;./Antelytics/lib/?.lua"

local Logger = require("logger")

-- Cross-platform temp dir + mkdir/rmdir. The spec was originally Mac-only:
-- hardcoded /tmp paths and `mkdir -p` / `rm -rf` shell commands. On Windows
-- those commands don't exist in cmd.exe, so every file read came back nil.
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local function temp_path(name)
    if IS_WINDOWS then
        local base = (os.getenv("TEMP") or "C:/Temp"):gsub("\\", "/")
        return base .. "/" .. name
    end
    return "/tmp/" .. name
end
local function ensure_dir(path)
    if IS_WINDOWS then
        os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute("mkdir -p " .. path)
    end
end
local function remove_dir(path)
    if IS_WINDOWS then
        os.execute('rmdir /s /q "' .. path:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute("rm -rf " .. path)
    end
end

-- Helper: read file contents
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- Helper: delete file if it exists
local function delete_file(path)
    os.remove(path)
end

describe("Logger", function()

    local test_dir = temp_path("dt_logger_test")
    local log_path = test_dir .. "/session.log"

    setup(function()
        ensure_dir(test_dir)
    end)

    before_each(function()
        delete_file(log_path)
        Logger.init(test_dir)
    end)

    teardown(function()
        delete_file(log_path)
        remove_dir(test_dir)
    end)

    -- -----------------------------------------------------------------------
    -- Initialization
    -- -----------------------------------------------------------------------
    describe("init", function()
        it("sets the log file path from mod_path", function()
            Logger.init(test_dir)
            Logger.info("test message")
            Logger.flush()
            local content = read_file(log_path)
            assert.is_not_nil(content)
            assert.truthy(content:find("test message"))
        end)

        it("handles non-string mod_path gracefully", function()
            -- Should not crash
            assert.has_no.errors(function()
                Logger.init(nil)
            end)
            assert.has_no.errors(function()
                Logger.init(123)
            end)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- Log levels
    -- -----------------------------------------------------------------------
    describe("log levels", function()
        it("logs INFO level messages", function()
            Logger.info("info message")
            Logger.flush()
            local content = read_file(log_path)
            assert.truthy(content:find("%[INFO%]"))
            assert.truthy(content:find("info message"))
        end)

        it("logs WARNING level messages", function()
            Logger.warning("warning message")
            Logger.flush()
            local content = read_file(log_path)
            assert.truthy(content:find("%[WARNING%]"))
            assert.truthy(content:find("warning message"))
        end)

        it("logs ERROR level messages", function()
            Logger.error("error message")
            Logger.flush()
            local content = read_file(log_path)
            assert.truthy(content:find("%[ERROR%]"))
            assert.truthy(content:find("error message"))
        end)

        it("logs custom level via Logger.log()", function()
            Logger.log("DEBUG", "debug message")
            Logger.flush()
            local content = read_file(log_path)
            assert.truthy(content:find("%[DEBUG%]"))
            assert.truthy(content:find("debug message"))
        end)
    end)

    -- -----------------------------------------------------------------------
    -- Timestamp format
    -- -----------------------------------------------------------------------
    describe("timestamp format", function()
        it("includes a timestamp in YYYY-MM-DD HH:MM:SS format", function()
            Logger.info("timestamp test")
            Logger.flush()
            local content = read_file(log_path)
            -- Match pattern: [YYYY-MM-DD HH:MM:SS]
            assert.truthy(content:find("%[%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%]"))
        end)

        it("formats each line as [timestamp] [LEVEL] message\\n", function()
            Logger.warning("format check")
            Logger.flush()
            local content = read_file(log_path)
            -- Full line format
            local pattern = "%[%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%] %[WARNING%] format check\n"
            assert.truthy(content:find(pattern))
        end)
    end)

    -- -----------------------------------------------------------------------
    -- Buffering behavior
    -- -----------------------------------------------------------------------
    describe("buffering", function()
        it("does not write to file until flush is called", function()
            Logger.info("buffered message")
            -- Before flush, file should not exist or be empty
            local content = read_file(log_path)
            assert.is_nil(content)
        end)

        it("writes all buffered messages on flush", function()
            Logger.info("message 1")
            Logger.warning("message 2")
            Logger.error("message 3")
            Logger.flush()
            local content = read_file(log_path)
            assert.truthy(content:find("message 1"))
            assert.truthy(content:find("message 2"))
            assert.truthy(content:find("message 3"))
        end)

        it("clears the buffer after flush", function()
            Logger.info("first flush")
            Logger.flush()
            Logger.flush()  -- second flush should write nothing new
            local content = read_file(log_path)
            -- Count occurrences of "first flush"
            local count = 0
            for _ in content:gmatch("first flush") do count = count + 1 end
            assert.are.equal(1, count)
        end)

        it("does nothing when buffer is empty", function()
            Logger.flush()
            local content = read_file(log_path)
            assert.is_nil(content)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- Append mode
    -- -----------------------------------------------------------------------
    describe("append mode", function()
        it("appends to existing log file content", function()
            Logger.info("first entry")
            Logger.flush()
            Logger.info("second entry")
            Logger.flush()
            local content = read_file(log_path)
            assert.truthy(content:find("first entry"))
            assert.truthy(content:find("second entry"))
        end)

        it("preserves previous content across multiple flushes", function()
            Logger.info("batch 1")
            Logger.flush()
            Logger.warning("batch 2")
            Logger.flush()
            Logger.error("batch 3")
            Logger.flush()
            local content = read_file(log_path)
            -- All three should be present in order
            local pos1 = content:find("batch 1")
            local pos2 = content:find("batch 2")
            local pos3 = content:find("batch 3")
            assert.is_true(pos1 < pos2)
            assert.is_true(pos2 < pos3)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- Error resilience
    -- -----------------------------------------------------------------------
    describe("error resilience", function()
        it("silently discards when file path is invalid", function()
            Logger.init("/nonexistent/path/that/should/not/exist")
            Logger.info("should not crash")
            -- Should not throw
            assert.has_no.errors(function()
                Logger.flush()
            end)
        end)

        it("clears buffer even when file open fails", function()
            Logger.init("/nonexistent/path/that/should/not/exist")
            Logger.info("message to discard")
            Logger.flush()
            -- Re-init with valid path
            Logger.init(test_dir)
            Logger.flush()
            -- The discarded message should not appear
            local content = read_file(log_path)
            assert.is_nil(content)
        end)

        it("handles nil message gracefully", function()
            assert.has_no.errors(function()
                Logger.info(nil)
                Logger.flush()
            end)
        end)
    end)
end)
