--- live_publisher.lua
--- Fire-and-forget live publishing of Decision_Nodes ("Antelytics Live").
---
--- Opt-in via config (live_enabled + live_url + live_token). When any of
--- those are missing, publish() is a no-op — no network call is attempted
--- and no cost is paid. When configured, each node is POSTed to
--- `<live_url>/api/live/node` as it happens.
---
--- Responses are mostly ignored (fire-and-forget by design — a run must
--- never be blocked or crashed by networking), EXCEPT for one permanent,
--- actionable case: HTTP 401/403 means the configured stream key is
--- revoked/invalid/unknown. That will never succeed by retrying, so it
--- halts sending (no further node reaches the network) and records a
--- string in `display.status_text` the Config tab binds to via
--- `ref_table`, mirroring lib/pairing.lua's `pairing.display` pattern.
--- Every other outcome (5xx, timeout, no response at all) is transient:
--- logged and dropped, never retried, never surfaced to the player. Sending
--- resumes only on an explicit `reset_auth_state()` (relinking, or toggling
--- "Live publishing" off/on) — see lib/pairing_ui.lua.
---
--- Pure core (no I/O, no globals, no clock/network):
---   LivePublisher.should_publish(cfg)                               -> boolean
---   LivePublisher.build_payload(run_id, node, mod_version, sent_at)  -> table
---   LivePublisher.classify_response(http_status)                    -> "auth_failure"|"ok"
---   LivePublisher.next_auth_state(http_status)                      -> halt, message
---
--- Shell (effects at the edge):
---   LivePublisher.new(deps)      -- deps = { config, sender, clock, logger, mod_version }
---   publisher:publish(run_id, node)
---   publisher:reset_auth_state()
---
--- The sender and clock are injected so tests substitute fakes and assert
--- on the exact payload that WOULD be sent; production wires the real
--- SMODS.https client and os.time.
---
--- Public API:
---   LivePublisher.should_publish(cfg)
---   LivePublisher.build_payload(run_id, node, mod_version, sent_at)
---   LivePublisher.classify_response(http_status)
---   LivePublisher.next_auth_state(http_status)
---   LivePublisher.new(deps)
---   publisher:publish(run_id, node)
---   publisher:reset_auth_state()

local LivePublisher = {}
LivePublisher.__index = LivePublisher

-- ---------------------------------------------------------------------------
-- Pure core
-- ---------------------------------------------------------------------------

--- Decide whether live publishing should happen at all, given plain config
--- values. Off by default: requires live_enabled == true AND a non-empty
--- live_url AND a non-empty live_token.
--- @param cfg table { live_enabled, live_url, live_token }
--- @return boolean
function LivePublisher.should_publish(cfg)
    cfg = cfg or {}
    return cfg.live_enabled == true
        and type(cfg.live_url) == "string" and cfg.live_url ~= ""
        and type(cfg.live_token) == "string" and cfg.live_token ~= ""
end

--- Build the exact wire payload for a node. Pure — sent_at is passed in
--- from an injected clock, never read from os.time()/os.clock() here.
--- @param run_id string
--- @param node table          the captured Decision_Node
--- @param mod_version string
--- @param sent_at number
--- @return table { run_id, seq, node, mod_version, sent_at }
function LivePublisher.build_payload(run_id, node, mod_version, sent_at)
    return {
        run_id      = run_id,
        seq         = node and node.index,
        node        = node,
        mod_version = mod_version,
        sent_at     = sent_at,
    }
end

--- User-facing message shown in the Config tab while sending is halted.
LivePublisher.UNAUTHORIZED_MESSAGE = "Publishing unauthorized — relink your account"

--- Classify a completed send by its HTTP status. Pure — no I/O, decides
--- purely from the status code. 401/403 mean the configured stream key is
--- permanently invalid (revoked, unknown, or malformed) and retrying will
--- never succeed. Everything else — 2xx, any other 4xx, 5xx, or nil (a
--- transport-level failure: timeout / no response at all) — is transient:
--- Antelytics Live is fire-and-forget by design and must not halt for it.
--- @param http_status number|nil
--- @return "auth_failure"|"ok"
function LivePublisher.classify_response(http_status)
    if http_status == 401 or http_status == 403 then
        return "auth_failure"
    end
    return "ok"
end

--- Decide what publishing should do next given one completed send's HTTP
--- status. Pure. Only an auth failure halts sending; a transient failure
--- (or a success) leaves sending exactly as it was — the shell never calls
--- this again once halted (see publish()/reset_auth_state()), so it does
--- not need the prior state to answer "should THIS response halt sending".
--- @param http_status number|nil
--- @return boolean halt     true = stop sending until an explicit reset
--- @return string  message  "" when not halting, else the UI-facing string
function LivePublisher.next_auth_state(http_status)
    if LivePublisher.classify_response(http_status) == "auth_failure" then
        return true, LivePublisher.UNAUTHORIZED_MESSAGE
    end
    return false, ""
end

-- ---------------------------------------------------------------------------
-- Shell — default sender (SMODS.https), overridable for tests
-- ---------------------------------------------------------------------------

--- Load one of this mod's own files.
---
--- In Balatro, SMODS loads mod files with `SMODS.load_file`; plain `require`
--- does NOT resolve them (the mod's directory is not on package.path). Under
--- busted there is no SMODS and `require` is what works. Both loads below sat
--- on the `require` path only, so publishing would have failed on every node
--- the first time it was reached -- silently, since the send path is
--- pcall-wrapped and fire-and-forget by design.
--- @param path string     SMODS path, e.g. "lib/serializer.lua"
--- @param modname string  require name, e.g. "lib.serializer"
local sibling_cache = {}
local function load_sibling(path, modname)
    local cached = sibling_cache[modname]
    if cached ~= nil then return cached end

    local smods = rawget(_G, "SMODS")
    if smods and smods.load_file then
        -- The mod id is REQUIRED here. SMODS.load_file(path) without an id only
        -- works while the mod is first loading (it reads SMODS.current_mod);
        -- at runtime -- e.g. a button press -- current_mod is nil and it errors
        -- with "No ID was provided!". See smods/src/preflight/loader.lua:870-873.
        local ok, chunk = pcall(smods.load_file, path, "Antelytics")
        if ok and type(chunk) == "function" then
            local loaded = chunk()
            sibling_cache[modname] = loaded
            return loaded
        end
    end

    local ok2, loaded2 = pcall(require, modname)
    if ok2 then
        sibling_cache[modname] = loaded2
        return loaded2
    end

    error("could not load " .. path .. " (tried SMODS.load_file and require)")
end

--- Real production sender: POSTs the JSON-encoded payload via SMODS's async
--- HTTPS client (a thread per request, polled off the game thread — see
--- smods-https.lua). The response body is ignored (fire-and-forget), but the
--- HTTP status is forwarded to `on_response` so the shell can detect a
--- permanent auth failure — see LivePublisher.classify_response.
--- @param url string    base live_url, e.g. "https://www.antelytics.gg"
--- @param token string  bearer token
--- @param payload table the wire payload (see build_payload)
--- @param on_response fun(http_status: number|nil)
local function default_sender(url, token, payload, on_response)
    -- SMODS registers its HTTPS client as a module named "SMODS.https", not as
    -- a field on the SMODS global — see lib/http_client.lua. Publishing failed
    -- silently on every node before this was corrected.
    local client = load_sibling("lib/http_client.lua", "lib.http_client").require_client()
    local Serializer = load_sibling("lib/serializer.lua", "lib.serializer")
    local body = Serializer.encode(payload)
    client.asyncRequest(url .. "/api/live/node", {
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. tostring(token),
            ["Content-Type"]  = "application/json",
        },
        data = body,
    }, function(code, _body, _headers)
        -- Body/headers are intentionally ignored; only the status code feeds
        -- the auth-failure decision (see LivePublisher:publish).
        on_response(code)
    end)
end

--- @param deps table {
---   config       table   live_enabled/live_url/live_token. Pass the actual
---                         mod.config table (by reference) so runtime
---                         toggles apply without re-wiring.
---   sender       fn(url, token, payload_table, on_response)  -- default: SMODS.https POST
---   clock        fn() -> number                 -- default: os.time
---   logger       fn(msg)                        -- default: no-op
---   mod_version  string                         -- default: "unknown"
--- }
function LivePublisher.new(deps)
    deps = deps or {}
    return setmetatable({
        config      = deps.config or {},
        sender      = deps.sender or default_sender,
        clock       = deps.clock or os.time,
        logger      = deps.logger or function() end,
        mod_version = deps.mod_version or "unknown",
        -- True once a 401/403 has been seen for the currently-configured
        -- token: publish() stops sending entirely until reset_auth_state().
        halted      = false,
        -- Plain STRING fields meant to be bound directly into a UI text
        -- node's `config.ref_table` (see lib/pairing.lua's `display` for the
        -- same pattern). Never nil, so the very first bind doesn't choke.
        display     = { status_text = "" },
    }, LivePublisher)
end

--- Publish one node if (and only if) live publishing is enabled, configured,
--- and not halted by a prior auth failure. Never raises — sender errors are
--- caught and logged, the node is dropped, the run continues unaffected.
--- @param run_id string
--- @param node table
function LivePublisher:publish(run_id, node)
    if self.halted then
        return
    end
    if not LivePublisher.should_publish(self.config) then
        return
    end

    local payload = LivePublisher.build_payload(run_id, node, self.mod_version, self.clock())

    local ok, err = pcall(self.sender, self.config.live_url, self.config.live_token, payload, function(http_status)
        local completion_ok, cerr = pcall(function()
            self:_handle_send_response(http_status)
        end)
        if not completion_ok then
            self.logger("LivePublisher: response handling failed: " .. tostring(cerr))
        end
    end)
    if not ok then
        self.logger("LivePublisher: send failed for node " .. tostring(node and node.index) .. ": " .. tostring(err))
    end
end

--- Apply the pure auth-failure decision for one completed send. Only ever
--- transitions "not halted" -> "halted" — a later response can't un-halt
--- (publish() stops calling the sender at all once halted, so this is only
--- ever reached again after an explicit reset_auth_state()).
--- @param http_status number|nil
function LivePublisher:_handle_send_response(http_status)
    local halt, message = LivePublisher.next_auth_state(http_status)
    if halt then
        self.halted = true
        self.display.status_text = message
        self.logger("LivePublisher: " .. message)
    end
end

--- Clear a halted auth-failure state so publishing resumes. Called by the
--- shell on user-taken corrective action: relinking (a new stream key is
--- saved — see lib/pairing.lua's `on_relink`) or toggling "Live publishing"
--- off/on (see lib/pairing_ui.lua). Safe to call unconditionally — a no-op
--- when not halted.
function LivePublisher:reset_auth_state()
    self.halted = false
    self.display.status_text = ""
end

return LivePublisher
