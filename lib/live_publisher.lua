--- live_publisher.lua
--- Fire-and-forget live publishing of Decision_Nodes ("Antelytics Live").
---
--- Opt-in via config (live_enabled + live_url + live_token). When any of
--- those are missing, publish() is a no-op — no network call is attempted
--- and no cost is paid. When configured, each node is POSTed to
--- `<live_url>/api/live/node` as it happens. Responses are ignored;
--- failures are logged and dropped, never retried, never surfaced to the
--- player.
---
--- Pure core (no I/O, no globals, no clock/network):
---   LivePublisher.should_publish(cfg)                               -> boolean
---   LivePublisher.build_payload(run_id, node, mod_version, sent_at)  -> table
---
--- Shell (effects at the edge):
---   LivePublisher.new(deps)      -- deps = { config, sender, clock, logger, mod_version }
---   publisher:publish(run_id, node)
---
--- The sender and clock are injected so tests substitute fakes and assert
--- on the exact payload that WOULD be sent; production wires the real
--- SMODS.https client and os.time.
---
--- Public API:
---   LivePublisher.should_publish(cfg)
---   LivePublisher.build_payload(run_id, node, mod_version, sent_at)
---   LivePublisher.new(deps)
---   publisher:publish(run_id, node)

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

-- ---------------------------------------------------------------------------
-- Shell — default sender (SMODS.https), overridable for tests
-- ---------------------------------------------------------------------------

--- Real production sender: POSTs the JSON-encoded payload via SMODS's async
--- HTTPS client (a thread per request, polled off the game thread — see
--- smods-https.lua). The response is intentionally ignored (fire-and-forget).
--- @param url string    base live_url, e.g. "https://www.antelytics.gg"
--- @param token string  bearer token
--- @param payload table the wire payload (see build_payload)
local function default_sender(url, token, payload)
    local smods = rawget(_G, "SMODS")
    if not smods or not smods.https or not smods.https.asyncRequest then
        error("SMODS.https.asyncRequest is not available")
    end
    local Serializer = require("lib.serializer")
    local body = Serializer.encode(payload)
    smods.https.asyncRequest(url .. "/api/live/node", {
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. tostring(token),
            ["Content-Type"]  = "application/json",
        },
        data = body,
    }, function(_code, _body, _headers)
        -- Fire-and-forget: response is intentionally ignored, success or not.
    end)
end

--- @param deps table {
---   config       table   live_enabled/live_url/live_token. Pass the actual
---                         mod.config table (by reference) so runtime
---                         toggles apply without re-wiring.
---   sender       fn(url, token, payload_table)  -- default: SMODS.https POST
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
    }, LivePublisher)
end

--- Publish one node if (and only if) live publishing is enabled and
--- configured. Never raises — sender errors are caught and logged, the
--- node is dropped, the run continues unaffected.
--- @param run_id string
--- @param node table
function LivePublisher:publish(run_id, node)
    if not LivePublisher.should_publish(self.config) then
        return
    end

    local payload = LivePublisher.build_payload(run_id, node, self.mod_version, self.clock())

    local ok, err = pcall(self.sender, self.config.live_url, self.config.live_token, payload)
    if not ok then
        self.logger("LivePublisher: send failed for node " .. tostring(node and node.index) .. ": " .. tostring(err))
    end
end

return LivePublisher
