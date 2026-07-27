--- http_client.lua
--- Resolves Steamodded's async HTTPS client.
---
--- WHY THIS EXISTS: SMODS registers the client as a lovely MODULE PATCH named
--- "SMODS.https" (smods/lovely/libs.toml: `[patches.module] name = "SMODS.https"`),
--- which puts it in Lua's module registry — it is NOT assigned as a field on the
--- SMODS global table. Grepping a shipped SMODS for `SMODS.https =` finds nothing.
--- So it must be reached with `require("SMODS.https")`; `SMODS.https.asyncRequest`
--- is always nil and every send fails with "not available".
---
--- That mistake is easy to repeat because the name in libs.toml *looks* like a
--- field path, which is exactly how it got made the first time. Both the live
--- publisher and the pairing flow need this, so it is resolved in one place.
---
--- The module itself may also come up without a transport: smods-https.lua does
--- `pcall(require, "https")` then falls back to luajit-curl, and if neither loads
--- it has no working request path. So presence of the module is not proof of a
--- usable client — asyncRequest is checked explicitly.

local HttpClient = {}

--- Resolve the async HTTPS client, or nil when unavailable.
--- Tries the real (module-registry) path first, then the global, so a future
--- SMODS that also exposes `SMODS.https` keeps working without a change here.
--- @return table|nil  a table with .asyncRequest(url, options, cb)
function HttpClient.resolve()
    local client, _ = HttpClient.resolve_with_reason()
    return client
end

--- Resolve, and also return a human-readable account of what was tried.
--- Exists because "not available" on its own has now cost several debugging
--- rounds: it cannot distinguish "require raised", "module loaded but has no
--- asyncRequest" (smods-https only defines it when it decides it is NOT running
--- in a thread — see `local isThread = arg == nil` at the top of that file), and
--- "module missing entirely".
--- @return table|nil client, string reason
function HttpClient.resolve_with_reason()
    local notes = {}

    local ok, mod = pcall(require, "SMODS.https")
    if not ok then
        notes[#notes + 1] = 'require("SMODS.https") raised: ' .. tostring(mod)
    elseif type(mod) ~= "table" then
        notes[#notes + 1] = 'require("SMODS.https") returned ' .. type(mod)
    elseif type(mod.asyncRequest) ~= "function" then
        local keys = {}
        for k in pairs(mod) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        notes[#notes + 1] = 'require("SMODS.https") gave a table with no asyncRequest; keys = {'
            .. table.concat(keys, ", ") .. "}; arg is " .. type(rawget(_G, "arg"))
    else
        return mod, "ok: require(\"SMODS.https\")"
    end

    local smods = rawget(_G, "SMODS")
    if not smods then
        notes[#notes + 1] = "SMODS global is absent"
    elseif type(smods.https) ~= "table" then
        notes[#notes + 1] = "SMODS.https is " .. type(smods.https)
    elseif type(smods.https.asyncRequest) ~= "function" then
        notes[#notes + 1] = "SMODS.https exists but has no asyncRequest"
    else
        return smods.https, "ok: SMODS.https global"
    end

    -- Is LOVE's own https module (Balatro ships https.dll) reachable at all?
    local lok, lhttps = pcall(require, "https")
    notes[#notes + 1] = lok and ('require("https") OK, type ' .. type(lhttps))
        or ('require("https") raised: ' .. tostring(lhttps))

    return nil, table.concat(notes, " | ")
end

--- Resolve or raise with a message that says what to check. Callers wrap sends
--- in pcall, so this surfaces in the mod log rather than reaching the player.
--- @return table
function HttpClient.require_client()
    local client, reason = HttpClient.resolve_with_reason()
    if not client then
        error("Steamodded HTTPS client unavailable -- " .. tostring(reason))
    end
    return client
end

return HttpClient
