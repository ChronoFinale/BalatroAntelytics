--- recorder.lua
--- The single source of truth for sending Decision_Nodes.
---
--- All capture paths (mod.calculate, monkey-patched hooks, love.update polling)
--- send through Recorder.send_node. Recorder decides whether the run is being
--- recorded (active + correct gamemode) and writes to the file_writer.
---
--- Public API:
---   Recorder.new(deps)           -- factory
---   recorder:start_run(...)      -- begin capturing
---   recorder:end_run(outcome, final_ante, pvp_summary)
---   recorder:next_index()        -- assign + increment seq
---   recorder:send(node)          -- record a Decision_Node
---   recorder:is_active()         -- whether we're currently recording

local Recorder = {}
Recorder.__index = Recorder

--- @param deps table { file_writer, logger }
function Recorder.new(deps)
    deps = deps or {}
    return setmetatable({
        file_writer = deps.file_writer,
        logger      = deps.logger or function() end,
        -- Per-run state
        run_id = nil,
        seq    = 0,
        active = false,
    }, Recorder)
end

function Recorder:start_run(run_id, player_id, seed, start_timestamp, gamemode, previous_run_id, deck_back, stake)
    self.run_id = run_id
    self.seq    = 0
    self.active = true
    if self.file_writer then
        self.file_writer:start_run(run_id, player_id, seed, start_timestamp, gamemode, previous_run_id, deck_back, stake)
    end
end

function Recorder:end_run(outcome, final_ante, pvp_summary)
    if not self.active then return end
    if self.file_writer then
        self.file_writer:end_run(outcome, final_ante, pvp_summary)
    end
    self.active = false
end

function Recorder:is_active()
    return self.active == true
end

function Recorder:next_index()
    local idx = self.seq
    self.seq = self.seq + 1
    return idx
end

--- Append a Decision_Node to the current run.
--- Silently no-ops when not active.
function Recorder:send(node)
    if not self.active then return end
    if not self.file_writer then return end
    local ok, err = pcall(function()
        self.file_writer:append_node(node)
    end)
    if not ok then
        self.logger("Recorder: send failed for node " .. tostring(node and node.index) .. ": " .. tostring(err))
    end
end

return Recorder
