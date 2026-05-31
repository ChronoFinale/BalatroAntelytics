--- spec/golden/lib/runner.lua
--- Discovers every scenario in spec/golden/scenarios/, drives it through
--- the production hooks, serializes the resulting nodes via the production
--- serializer, and compares the output against a checked-in expected
--- JSON file in spec/golden/expected/.
---
--- Mismatches print the first differing node side-by-side and fail the
--- test. Set REGEN=1 in the environment to overwrite the expected file
--- instead of failing.
---
--- Usage:
---     busted spec/golden/runner_spec.lua          -- compare and fail on diff
---     REGEN=1 busted spec/golden/runner_spec.lua  -- regenerate expected files

local Runner = {}

local World      = assert(loadfile("spec/golden/lib/world.lua"))()
local Serializer = assert(loadfile("lib/serializer.lua"))()

local SCENARIOS_DIR = "spec/golden/scenarios"
local EXPECTED_DIR  = "spec/golden/expected"

--- Read every file from a directory. lfs would be cleaner but isn't
--- guaranteed in our test env, so we shell out via the platform-native
--- listing command. Windows uses `dir /b` (basename only, no headers);
--- Unix uses `ls`.
local function list_dir(path)
    local cmd
    if package.config:sub(1, 1) == "\\" then
        cmd = 'dir /b "' .. path:gsub("/", "\\") .. '" 2>nul'
    else
        cmd = 'ls "' .. path .. '" 2>/dev/null'
    end
    local pipe = io.popen(cmd)
    if not pipe then return {} end
    local entries = {}
    for line in pipe:lines() do entries[#entries + 1] = line end
    pipe:close()
    return entries
end

local function read_file(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local content = fh:read("*a")
    fh:close()
    return content
end

local function write_file(path, content)
    local fh = assert(io.open(path, "w"))
    fh:write(content)
    fh:close()
end

local function pretty_json(value)
    -- Two-space indented JSON for readable diffs.
    return Serializer.encode_pretty(value)
end

--- Pretty-print two values side by side and find the first differing line.
local function diff(expected, actual)
    local function lines(s)
        local out = {}
        for line in (s .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
        return out
    end
    local exp_lines = lines(expected)
    local act_lines = lines(actual)
    local max = math.max(#exp_lines, #act_lines)
    local report = {}
    local first_diff = nil
    for i = 1, max do
        local a, b = exp_lines[i] or "", act_lines[i] or ""
        if a ~= b and first_diff == nil then
            first_diff = i
            -- 5 lines of context before
            for j = math.max(1, i - 5), i - 1 do
                report[#report + 1] = ("  %4d  %s"):format(j, exp_lines[j] or "")
            end
            report[#report + 1] = ("- %4d  %s"):format(i, a)
            report[#report + 1] = ("+ %4d  %s"):format(i, b)
            for j = i + 1, math.min(max, i + 5) do
                local ja, jb = exp_lines[j] or "", act_lines[j] or ""
                if ja == jb then
                    report[#report + 1] = ("  %4d  %s"):format(j, ja)
                else
                    report[#report + 1] = ("- %4d  %s"):format(j, ja)
                    report[#report + 1] = ("+ %4d  %s"):format(j, jb)
                end
            end
            break
        end
    end
    return first_diff, table.concat(report, "\n")
end

--- Discover scenarios and return list of {name, scenario_path, expected_path}.
function Runner.discover()
    local scenarios = {}
    for _, fname in ipairs(list_dir(SCENARIOS_DIR)) do
        if fname:match("%.lua$") then
            local name = fname:gsub("%.lua$", "")
            scenarios[#scenarios + 1] = {
                name          = name,
                scenario_path = SCENARIOS_DIR .. "/" .. fname,
                expected_path = EXPECTED_DIR  .. "/" .. name .. ".json",
            }
        end
    end
    table.sort(scenarios, function(a, b) return a.name < b.name end)
    return scenarios
end

--- Run a scenario and return its normalized JSON output.
function Runner.run_scenario(scenario_path)
    local scenario = assert(loadfile(scenario_path))()
    local fn, spec
    if type(scenario) == "function" then
        fn, spec = scenario, {}
    elseif type(scenario) == "table" and type(scenario.run) == "function" then
        fn, spec = scenario.run, scenario.spec or {}
    else
        error("scenario " .. scenario_path .. " must return a function or { run = function, spec = table }")
    end
    local world = World.new(spec)
    fn(world)
    return pretty_json(world:normalized_nodes())
end

--- Compare scenario output to expected file. Returns ok, diff_message.
function Runner.check(entry)
    local actual = Runner.run_scenario(entry.scenario_path)
    local expected = read_file(entry.expected_path)
    if not expected then
        return false, "no expected file at " .. entry.expected_path .. " — run with REGEN=1 to create"
    end
    if expected:gsub("%s+$", "") == actual:gsub("%s+$", "") then
        return true
    end
    local _, msg = diff(expected, actual)
    return false, msg
end

--- Regenerate the expected file for a scenario.
function Runner.regenerate(entry)
    local actual = Runner.run_scenario(entry.scenario_path)
    write_file(entry.expected_path, actual)
end

return Runner
