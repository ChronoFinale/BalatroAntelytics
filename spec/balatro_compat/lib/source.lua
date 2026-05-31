--- spec/balatro_compat/lib/source.lua
---
--- Helpers for loading Balatro's actual source code in tests so we
--- can run the real game logic against synthetic state and verify
--- our viewer formulas match.
---
--- Intentionally LOCAL-ONLY — the source isn't redistributed with the
--- repo. Specs that use this module skip themselves cleanly when the
--- source dir isn't populated.

local Source = {}

--- Candidate directories holding extracted Balatro source files, in
--- priority order:
---
---   1. BALATRO_SOURCE_DIR env var (explicit override)
---   2. ~/.cache/balatro-source/ (original mac dev setup)
---   3. ../Balatro/ relative to cwd (sibling-repo fallback — the
---      BalatroMod/ layout that ships the decompiled source as a
---      reference checkout next to BalatroAntelytics/)
---
--- @return table  list of absolute paths (no trailing slash)
local function source_dirs()
    local dirs = {}
    local override = os.getenv("BALATRO_SOURCE_DIR")
    if override and override ~= "" then dirs[#dirs + 1] = override end
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
    dirs[#dirs + 1] = home .. "/.cache/balatro-source"
    -- Sibling-repo fallback. busted runs from repo root so cwd is
    -- ".../BalatroAntelytics/" — the Balatro source repo lives at
    -- "../Balatro/" in the project layout.
    dirs[#dirs + 1] = "../Balatro"
    return dirs
end

--- Read a source file from the first configured dir that has it.
--- Returns nil + reason when the file isn't present in any candidate
--- (lets specs skip themselves).
---
--- @param relative_name string  e.g. "card.lua"
--- @return string|nil contents, string|nil error
function Source.read(relative_name)
    local last_err = nil
    for _, dir in ipairs(source_dirs()) do
        local path = dir .. "/" .. relative_name
        local f, err = io.open(path, "r")
        if f then
            local content = f:read("*all")
            f:close()
            return content, nil
        end
        last_err = err
    end
    return nil, last_err
end

--- Skip the calling spec when the Balatro source isn't available.
--- Prints a friendly message so the dev knows what to do.
---
--- Usage in a spec:
---   if Source.skip_unless_present("card.lua") then return end
---
--- @param relative_name string  filename to check for
--- @return boolean true when source is missing (caller should bail)
function Source.skip_unless_present(relative_name)
    local _, err = Source.read(relative_name)
    if err then
        local searched = {}
        for _, dir in ipairs(source_dirs()) do
            searched[#searched + 1] = dir
        end
        print("\n[balatro-compat] Skipping: " .. relative_name ..
              " not found. Searched: " .. table.concat(searched, ", "))
        print("[balatro-compat] See spec/balatro_compat/README.md for setup.")
        return true
    end
    return false
end

--- Slice a single named `function name(...)` block out of source text.
--- Best-effort: matches `function <name>(` through the matching
--- top-level `end`. Useful for pulling one calc_function or scoring
--- branch out of card.lua without loading the whole file.
---
--- @param source string   full file contents
--- @param name string     function name to extract
--- @return string|nil     extracted function source (or nil when not found)
function Source.slice_function(source, name)
    local pattern = "function%s+" .. name .. "%s*%("
    local start_pos = source:find(pattern)
    if not start_pos then return nil end

    -- Walk forward counting nested function/end pairs to find the
    -- matching top-level `end`. We scan the source character by
    -- character, tracking line/keyword boundaries.
    local depth = 0
    local i = start_pos
    while i <= #source do
        local chunk = source:sub(i, i + 8)
        if chunk:sub(1, 8) == "function" and (i == start_pos or source:sub(i-1, i-1):match("[%s%(]")) then
            depth = depth + 1
            i = i + 8
        elseif chunk:sub(1, 3) == "end" and source:sub(i+3, i+3):match("[%s,%);]") then
            depth = depth - 1
            if depth == 0 then
                return source:sub(start_pos, i + 2)
            end
            i = i + 3
        else
            i = i + 1
        end
    end
    return nil
end

return Source
