--- pairing.lua
--- In-game "Link account" pairing flow ("Antelytics Live" device-code flow).
---
--- The player never hand-edits config.lua. Instead: click "Link account" in
--- the mod's config tab, which opens a short code + a browser approval page
--- (antelytics.gg), and the mod polls the server until the player approves
--- (or denies/lets it expire) from the web. On approval the server hands
--- back a stream key, which is written into config.live_token/linked_user
--- and saved immediately (SMODS does not autosave config — see save_config).
---
--- Wire contract (server-defined, not owned by this file):
---   POST <live_url>/api/live/pair/start
---     -> { user_code, device_code, verification_url, expires_in, interval }
---   POST <live_url>/api/live/pair/poll   body { device_code }
---     -> { status = "pending" }
---     -> { status = "approved", stream_key, linked_user }
---     -> { status = "denied" }
---     -> HTTP 410 (expired) / HTTP 429 (poll too fast, back off)
---
--- Pure core (no I/O, no globals, no clock/network read):
---   Pairing.start_state(start_response, now)          -> state
---   Pairing.next_poll_state(state, response, now)      -> state
---   Pairing.should_poll(state, now)                    -> boolean
---
--- Shell (effects at the edge, mirrors lib/live_publisher.lua):
---   Pairing.new(deps)   -- deps = { config, sender, clock, logger, save_config, open_url }
---   pairing:start_link()   -- kicks off /pair/start, opens the approval page
---   pairing:tick(now)      -- call every frame (e.g. from love.update); polls
---                             /pair/poll only when a pairing is actually in
---                             flight and the interval has elapsed
---   pairing:unlink()       -- clears the local link and best-effort revokes
---
--- `pairing.display` is a plain table of STRING fields meant to be bound
--- directly into a UI text node's `config.ref_table` (Steamodded polls a
--- bound ref_table every frame and recalculates the text when its length
--- changes — there is no "re-render the config tab" API). Fields are
--- initialized to strings, never nil, so the very first poll doesn't choke
--- on a nil ref_value.
---
--- SECURITY NOTE: like the existing live_token, SMODS stores mod config as
--- world-readable plaintext (mod.config is a plain Lua table serialized to
--- disk with no encryption). This is a known SMODS limitation, not
--- something this file can fix. The token is narrowly scoped (publish-only)
--- and server-revocable via unlink(), which is the mitigation. Never log
--- the stream key — log only linked_user.

local Pairing = {}
Pairing.__index = Pairing

-- ---------------------------------------------------------------------------
-- Pure core
-- ---------------------------------------------------------------------------

--- Shallow-merge `overrides` onto a copy of `state`. Never mutates either
--- argument — every pure-core function returns a brand new state table.
local function merge(state, overrides)
    local result = {}
    for k, v in pairs(state or {}) do result[k] = v end
    for k, v in pairs(overrides or {}) do result[k] = v end
    return result
end

--- Like `merge`, but for terminal states (expired/approved/denied) that must
--- clear `poll_again_at` to signal "stop polling". A table CONSTRUCTOR field
--- set to `nil` (e.g. `{poll_again_at = nil}`) never creates the key at all,
--- so `merge` would silently leave the old numeric value in place — this
--- clears it with a real assignment on the already-built result table,
--- which does remove the key.
local function merge_terminal(state, overrides)
    local result = merge(state, overrides)
    result.poll_again_at = nil
    return result
end

--- Build the initial polling state from the /pair/start response. Pure —
--- `now` is passed in from an injected clock, never read here.
--- @param response table { user_code, device_code, verification_url, expires_in, interval }
--- @param now number
--- @return table state
function Pairing.start_state(response, now)
    response = response or {}

    if type(response.device_code) ~= "string" or response.device_code == ""
        or type(response.user_code) ~= "string" or response.user_code == "" then
        return {
            status  = "error",
            message = "Could not start pairing — the server response was malformed.",
        }
    end

    local interval = tonumber(response.interval) or 5
    if interval < 1 then interval = 1 end
    local expires_in = tonumber(response.expires_in) or 600
    if expires_in < 1 then expires_in = 1 end

    return {
        status            = "pending",
        device_code       = response.device_code,
        user_code         = response.user_code,
        verification_url  = response.verification_url,
        interval          = interval,
        expires_at        = now + expires_in,
        poll_again_at     = now + interval,
        token             = nil,
        linked_user       = nil,
        message           = "Waiting for approval...",
    }
end

--- Decide the next pairing state given the current state, a plain poll
--- response, and the current time. No I/O, no globals — `response` is
--- already-parsed data and `now` is an injected clock read.
---
--- Never clears an existing link: this function only ever returns a
--- `token`/`linked_user` pair when the response is an unambiguous, valid
--- "approved" — malformed/unknown responses just keep polling.
---
--- @param state table         see Pairing.start_state / Pairing.next_poll_state
--- @param response table {
---   ok           boolean  false on network/transport-level failure
---   http_status  number|nil
---   body         table|nil   decoded JSON: { status, stream_key, linked_user }
--- }
--- @param now number
--- @return table  new state
function Pairing.next_poll_state(state, response, now)
    state = state or {}
    response = response or {}

    -- No pairing in flight — nothing for the poll response to change.
    if state.status ~= "pending" then
        return state
    end

    -- Expiry wins over everything else: an approval landing the same tick
    -- the window closes is still too late per the wire contract.
    if type(state.expires_at) == "number" and now >= state.expires_at then
        return merge_terminal(state, {
            status  = "expired",
            message = "Pairing expired — click Link account to try again.",
        })
    end

    local interval = state.interval or 5

    -- Transport failure or a body we can't read at all: keep polling.
    if response.ok == false or type(response.body) ~= "table" then
        return merge(state, { poll_again_at = now + interval })
    end

    if response.http_status == 410 then
        return merge_terminal(state, {
            status  = "expired",
            message = "Pairing expired — click Link account to try again.",
        })
    end

    if response.http_status == 429 then
        -- Back off: wait at least one extra interval before trying again.
        return merge(state, { poll_again_at = now + interval * 2 })
    end

    local body = response.body
    if body.status == "pending" then
        return merge(state, { poll_again_at = now + interval })
    elseif body.status == "approved" then
        if type(body.stream_key) ~= "string" or body.stream_key == "" then
            -- Malformed approval (no key to store) — keep polling rather
            -- than "succeeding" with nothing to save.
            return merge(state, { poll_again_at = now + interval })
        end
        local linked_user = body.linked_user
        if type(linked_user) ~= "string" or linked_user == "" then
            linked_user = "Unknown"
        end
        return merge_terminal(state, {
            status      = "approved",
            token       = body.stream_key,
            linked_user = linked_user,
            message     = "Linked as " .. linked_user,
        })
    elseif body.status == "denied" then
        return merge_terminal(state, {
            status  = "denied",
            message = "Pairing request was denied.",
        })
    else
        -- Unknown/malformed status string — keep polling.
        return merge(state, { poll_again_at = now + interval })
    end
end

--- True if a poll request should be fired right now: a pairing must be
--- actively "pending" AND the interval must have elapsed. Zero-cost when
--- no pairing is in flight — the shell should call this before touching
--- the network at all.
--- @param state table
--- @param now number
--- @return boolean
function Pairing.should_poll(state, now)
    if not state or state.status ~= "pending" then return false end
    if type(state.poll_again_at) ~= "number" then return false end
    return now >= state.poll_again_at
end

-- ---------------------------------------------------------------------------
-- Shell — default collaborators (SMODS.https / os.time / SMODS.save_mod_config
-- / love.system.openURL), overridable for tests
-- ---------------------------------------------------------------------------

local function encode_json(value)
    local Serializer = require("lib.serializer")
    return Serializer.encode(value or {})
end

--- Best-effort JSON decode: returns nil (never raises) on anything that
--- isn't a parseable JSON object, so a malformed/empty server response
--- degrades to "no body" for the pure core instead of crashing the shell.
local function decode_json(text)
    if type(text) ~= "string" or text == "" then return nil end
    local Serializer = require("lib.serializer")
    local ok, result = pcall(Serializer.decode, text)
    if not ok or type(result) ~= "table" then return nil end
    return result
end

--- Real production sender: POSTs a JSON body to `<live_url><path>` via
--- SMODS's async HTTPS client and decodes the JSON response. `config` is
--- captured by reference so a runtime change to live_url takes effect on
--- the next call without re-wiring.
--- @param config table   the mod.config table (reads live_url)
--- @return fun(path: string, body: table, callback: fun(ok: boolean, http_status: number|nil, body: table|nil))
local function make_default_sender(config)
    return function(path, body, callback)
        local smods = rawget(_G, "SMODS")
        if not smods or not smods.https or not smods.https.asyncRequest then
            error("SMODS.https.asyncRequest is not available")
        end
        local base_url = config and config.live_url
        if type(base_url) ~= "string" or base_url == "" then
            error("live_url is not configured")
        end
        smods.https.asyncRequest(base_url .. path, {
            method = "POST",
            headers = { ["Content-Type"] = "application/json" },
            data = encode_json(body),
        }, function(code, resp_body, _headers)
            local ok = type(code) == "number" and code >= 200 and code < 300
            callback(ok, code, decode_json(resp_body))
        end)
    end
end

--- Default save: SMODS does not autosave mod config, so approval/unlink
--- must call this explicitly or the link is lost on exit. Prefers the
--- registered mod-list entry (matches how SMODS itself looks mods up),
--- falling back to SMODS.current_mod (what main.lua uses at load time).
local function default_save_config()
    local smods = rawget(_G, "SMODS")
    if not (smods and smods.save_mod_config) then return end
    local target = (smods.Mods and smods.Mods["Antelytics"]) or smods.current_mod
    if target then smods.save_mod_config(target) end
end

local function default_open_url(url)
    if type(url) ~= "string" or url == "" then return end
    local l = rawget(_G, "love")
    if l and l.system and l.system.openURL then
        l.system.openURL(url)
    end
end

local function default_status_text(config)
    if config and type(config.linked_user) == "string" and config.linked_user ~= "" then
        return "Linked as " .. config.linked_user
    end
    return "Not linked"
end

--- @param deps table {
---   config       table   the actual mod.config table (by reference) — read
---                         for live_url, written on approval/unlink
---   sender       fn(path, body, callback)  -- default: SMODS.https POST
---   clock        fn() -> number            -- default: os.time
---   logger       fn(msg)                   -- default: no-op
---   save_config  fn()                      -- default: SMODS.save_mod_config
---   open_url     fn(url)                   -- default: love.system.openURL
--- }
function Pairing.new(deps)
    deps = deps or {}
    local config = deps.config or {}
    local self = setmetatable({
        config         = config,
        sender         = deps.sender or make_default_sender(config),
        clock          = deps.clock or os.time,
        logger         = deps.logger or function() end,
        save_config    = deps.save_config or default_save_config,
        open_url       = deps.open_url or default_open_url,
        state          = { status = "idle" },
        poll_in_flight = false,
        display        = {
            user_code   = "",
            status_text = default_status_text(config),
            linked_user = (type(config.linked_user) == "string" and config.linked_user) or "",
        },
    }, Pairing)
    return self
end

--- True while a pairing is actively pending (a poll should be in progress).
function Pairing:is_pending()
    return self.state.status == "pending"
end

--- Kick off a new pairing: POST /pair/start, then start polling. A no-op if
--- a pairing is already in flight. Never raises — sender errors are caught
--- and surfaced only via display.status_text/logger.
function Pairing:start_link()
    if self:is_pending() then return end

    self.display.status_text = "Starting..."
    local ok, err = pcall(function()
        self.sender("/api/live/pair/start", {}, function(ok2, _http_status, body)
            local completion_ok, cerr = pcall(function()
                self:_handle_start_response(ok2, body)
            end)
            if not completion_ok then
                self.logger("Pairing: start response handling failed: " .. tostring(cerr))
            end
        end)
    end)
    if not ok then
        self.logger("Pairing: start request failed: " .. tostring(err))
        self.display.status_text = "Could not start pairing — check live_url."
    end
end

function Pairing:_handle_start_response(ok, body)
    if not ok or type(body) ~= "table" then
        self.state = { status = "idle" }
        self.display.status_text = "Could not start pairing — check live_url."
        return
    end

    local now = self.clock()
    local new_state = Pairing.start_state(body, now)
    self.state = new_state

    if new_state.status == "error" then
        self.display.status_text = new_state.message
        return
    end

    self.display.user_code   = tostring(new_state.user_code or "")
    self.display.status_text = new_state.message

    if new_state.verification_url then
        local open_ok, open_err = pcall(self.open_url, new_state.verification_url)
        if not open_ok then
            self.logger("Pairing: could not open verification URL: " .. tostring(open_err))
        end
    end
end

--- Call every frame (e.g. from love.update). Fires a /pair/poll request
--- only when a pairing is in flight AND its interval has elapsed — zero
--- network cost otherwise. Never raises.
--- @param now number|nil  defaults to the injected clock
function Pairing:tick(now)
    now = now or self.clock()
    if self.poll_in_flight then return end
    if not Pairing.should_poll(self.state, now) then return end

    self.poll_in_flight = true
    local device_code = self.state.device_code
    local ok, err = pcall(function()
        self.sender("/api/live/pair/poll", { device_code = device_code }, function(ok2, http_status, body)
            self.poll_in_flight = false
            local completion_ok, cerr = pcall(function()
                self:_handle_poll_response(ok2, http_status, body)
            end)
            if not completion_ok then
                self.logger("Pairing: poll response handling failed: " .. tostring(cerr))
            end
        end)
    end)
    if not ok then
        self.poll_in_flight = false
        self.logger("Pairing: poll request failed: " .. tostring(err))
        -- Treat a synchronous sender failure as a transport error so the
        -- pure core just schedules a retry instead of getting stuck.
        local retry_now = self.clock()
        self.state = Pairing.next_poll_state(self.state, { ok = false }, retry_now)
    end
end

function Pairing:_handle_poll_response(ok, http_status, body)
    local now = self.clock()
    local new_state = Pairing.next_poll_state(self.state, { ok = ok, http_status = http_status, body = body }, now)
    self.state = new_state

    if new_state.message then
        self.display.status_text = new_state.message
    end

    if new_state.status == "approved" then
        self.config.live_token  = new_state.token
        self.config.linked_user = new_state.linked_user
        self.display.linked_user = new_state.linked_user
        self.display.user_code   = ""

        local save_ok, save_err = pcall(self.save_config)
        if not save_ok then
            self.logger("Pairing: failed to save config after approval: " .. tostring(save_err))
        else
            self.logger("Pairing: linked as " .. tostring(new_state.linked_user))
        end
    end
end

--- Clear the local link and best-effort revoke it server-side. Clearing +
--- saving locally happens unconditionally and first — a failed (or skipped,
--- when no live_url is configured) revoke never leaves the local link
--- half-cleared.
function Pairing:unlink()
    local old_token = self.config.live_token

    self.config.live_token  = ""
    self.config.linked_user = ""
    self.state              = { status = "idle" }
    self.display.user_code   = ""
    self.display.linked_user = ""
    self.display.status_text = "Not linked"

    local save_ok, save_err = pcall(self.save_config)
    if not save_ok then
        self.logger("Pairing: failed to save config after unlink: " .. tostring(save_err))
    end

    if type(self.config.live_url) == "string" and self.config.live_url ~= ""
        and type(old_token) == "string" and old_token ~= "" then
        local revoke_ok, revoke_err = pcall(function()
            self.sender("/api/live/pair/revoke", { stream_key = old_token }, function() end)
        end)
        if not revoke_ok then
            self.logger("Pairing: revoke request failed (link already cleared locally): " .. tostring(revoke_err))
        end
    end
end

return Pairing
