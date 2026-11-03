--- run_dir_spec.lua
--- Run files must land in LÖVE's save directory, never inside the mod folder.
---
--- Steamodded walks every folder under Mods/ on boot and parses anything
--- whose name contains ".json" as mod metadata, so a log/ of *.json.gz run
--- files next to main.lua costs a warning per run and a gzip read per launch.
--- Pins: with SMODS.NFS present the facade resolves to
--- <love save dir>/Antelytics/log and writes there; without it the
--- love.filesystem fallback uses the same relative folder.

local FileWriter = require("lib.file_writer")
local Serializer = require("lib.serializer")

local MOD_PATH = "/game/Mods/Antelytics/"
local SAVE_DIR = "/game-save"

local function with_globals(globals, fn)
    local saved = {}
    for k, v in pairs(globals) do
        saved[k] = rawget(_G, k)
        rawset(_G, k, v)
    end
    local ok, err = pcall(fn)
    for k in pairs(globals) do rawset(_G, k, saved[k]) end
    if not ok then error(err, 0) end
end

local function make_nfs(written, created)
    return {
        createDirectory = function(path) created[#created + 1] = path; return true end,
        write = function(path, data) written[path] = data; return true end,
        read = function(path) return written[path] end,
        rename = function(from, to) written[to] = written[from]; written[from] = nil end,
        remove = function(path) written[path] = nil end,
        getDirectoryItems = function() return {} end,
    }
end

describe("run directory — outside Mods/", function()
    it("resolves to <save dir>/Antelytics/log when SMODS.NFS is available", function()
        local written, created = {}, {}
        with_globals({
            SMODS = { NFS = make_nfs(written, created) },
            love  = { filesystem = { getSaveDirectory = function() return SAVE_DIR end } },
        }, function()
            local fw = FileWriter.new({ serializer = Serializer, logger = function() end, mod_path = MOD_PATH })
            assert.are.equal(SAVE_DIR .. "/Antelytics/log", fw.fs.log_dir)
            assert.are.same({ SAVE_DIR .. "/Antelytics/log" }, created)

            fw.fs:write("run.json.gz", "data")
            assert.are.equal("data", written[SAVE_DIR .. "/Antelytics/log/run.json.gz"])
            for path in pairs(written) do
                assert.is_nil(path:find(MOD_PATH, 1, true), "wrote inside the mod folder: " .. path)
            end
        end)
    end)

    it("falls back to the relative Antelytics/log folder without SMODS.NFS", function()
        local written = {}
        with_globals({
            SMODS = nil,
            love  = { filesystem = {
                createDirectory = function() return true end,
                write = function(path, data) written[path] = data; return true end,
            } },
        }, function()
            local fw = FileWriter.new({ serializer = Serializer, logger = function() end, mod_path = MOD_PATH })
            assert.are.equal("Antelytics/log", fw.fs.log_dir)
            fw.fs:write("run.json.gz", "data")
            assert.are.equal("data", written["Antelytics/log/run.json.gz"])
        end)
    end)

    it("falls back to love.filesystem when the save directory is unknown", function()
        local written = {}
        with_globals({
            SMODS = { NFS = make_nfs({}, {}) },
            love  = { filesystem = {
                getSaveDirectory = function() return nil end,
                createDirectory = function() return true end,
                write = function(path, data) written[path] = data; return true end,
            } },
        }, function()
            local fw = FileWriter.new({ serializer = Serializer, logger = function() end, mod_path = MOD_PATH })
            assert.are.equal("Antelytics/log", fw.fs.log_dir)
            fw.fs:write("run.json.gz", "data")
            assert.are.equal("data", written["Antelytics/log/run.json.gz"])
        end)
    end)
end)
