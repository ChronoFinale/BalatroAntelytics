--- pairing_spec.lua
--- Tests for the in-game "Link account" pairing flow.
---
--- The state machine (what to do next given a poll response) is pure and
--- tested with plain tables. The sender/clock/save_config/open_url are
--- injected fakes here — production wires SMODS.https.asyncRequest,
--- os.time, SMODS.save_mod_config, and love.system.openURL (see
--- lib/pairing.lua).

local Pairing = require("lib.pairing")

-- ---------------------------------------------------------------------------
-- Pure core: Pairing.start_state
-- ---------------------------------------------------------------------------

describe("Pairing.start_state", function()

    it("builds the initial pending state from a well-formed /pair/start response", function()
        local state = Pairing.start_state({
            user_code         = "ABCD-1234",
            device_code       = "dev-1",
            verification_url  = "https://www.antelytics.gg/link",
            expires_in        = 600,
            interval          = 5,
        }, 1000)

        assert.are.same({
            status            = "pending",
            device_code       = "dev-1",
            user_code         = "ABCD-1234",
            verification_url  = "https://www.antelytics.gg/link",
            interval          = 5,
            expires_at        = 1600,
            poll_again_at     = 1005,
            token             = nil,
            linked_user       = nil,
            message           = "Waiting for approval...",
        }, state)
    end)

    it("defaults interval to 5 and expires_in to 600 when omitted", function()
        local state = Pairing.start_state({ user_code = "U", device_code = "D" }, 0)
        assert.are.equal(5, state.interval)
        assert.are.equal(600, state.expires_at)
        assert.are.equal(5, state.poll_again_at)
    end)

    it("clamps a non-positive interval/expires_in up to 1", function()
        local state = Pairing.start_state({
            user_code = "U", device_code = "D", interval = -1, expires_in = 0,
        }, 100)
        assert.are.equal(1, state.interval)
        assert.are.equal(101, state.expires_at)
    end)

    it("returns an error state (never crashes) on a malformed response", function()
        assert.are.same({ status = "error", message = "Could not start pairing — the server response was malformed." },
            Pairing.start_state(nil, 0))
        assert.are.equal("error", Pairing.start_state({}, 0).status)
        assert.are.equal("error", Pairing.start_state({ user_code = "U" }, 0).status) -- missing device_code
    end)

end)

-- ---------------------------------------------------------------------------
-- Pure core: Pairing.next_poll_state
-- ---------------------------------------------------------------------------

describe("Pairing.next_poll_state", function()

    local function pending_state(overrides)
        local base = {
            status            = "pending",
            device_code       = "dev-1",
            user_code         = "ABCD-1234",
            verification_url  = "https://www.antelytics.gg/link",
            interval          = 5,
            expires_at        = 1000,
            poll_again_at     = 100,
            token             = nil,
            linked_user       = nil,
            message           = "Waiting for approval...",
        }
        for k, v in pairs(overrides or {}) do base[k] = v end
        return base
    end

    it("pending body: keeps polling, respecting the state's interval", function()
        local state = pending_state({ interval = 7 })
        local next_state = Pairing.next_poll_state(state, { ok = true, http_status = 200, body = { status = "pending" } }, 200)

        assert.are.equal("pending", next_state.status)
        assert.are.equal(207, next_state.poll_again_at)
        -- Unrelated fields are preserved unchanged.
        assert.are.equal("dev-1", next_state.device_code)
        assert.is_nil(next_state.token)
    end)

    it("approved: returns the token + linked_user and signals stop-polling", function()
        local state = pending_state()
        local next_state = Pairing.next_poll_state(state, {
            ok = true, http_status = 200,
            body = { status = "approved", stream_key = "sk_live_abc123", linked_user = "chrono" },
        }, 200)

        assert.are.equal("approved", next_state.status)
        assert.are.equal("sk_live_abc123", next_state.token)
        assert.are.equal("chrono", next_state.linked_user)
        assert.is_nil(next_state.poll_again_at)
        assert.are.equal("Linked as chrono", next_state.message)
    end)

    it("approved without linked_user falls back to 'Unknown'", function()
        local state = pending_state()
        local next_state = Pairing.next_poll_state(state, {
            ok = true, http_status = 200,
            body = { status = "approved", stream_key = "sk_live_abc123" },
        }, 200)

        assert.are.equal("Unknown", next_state.linked_user)
        assert.are.equal("Linked as Unknown", next_state.message)
    end)

    it("denied: stops polling with a denied status", function()
        local state = pending_state()
        local next_state = Pairing.next_poll_state(state, {
            ok = true, http_status = 200, body = { status = "denied" },
        }, 200)

        assert.are.equal("denied", next_state.status)
        assert.is_nil(next_state.poll_again_at)
    end)

    it("HTTP 410: expired, stops polling", function()
        local state = pending_state()
        local next_state = Pairing.next_poll_state(state, { ok = true, http_status = 410, body = {} }, 200)

        assert.are.equal("expired", next_state.status)
        assert.is_nil(next_state.poll_again_at)
    end)

    it("HTTP 429: backs off — next poll is scheduled further out than a normal interval", function()
        local state = pending_state({ interval = 5, poll_again_at = 100 })
        local next_state = Pairing.next_poll_state(state, { ok = true, http_status = 429, body = {} }, 200)

        assert.are.equal("pending", next_state.status)
        assert.are.equal(210, next_state.poll_again_at) -- 200 + interval*2
        assert.is_true(next_state.poll_again_at > 200 + state.interval)
    end)

    it("expiry: stops polling once now has passed expires_at, even with a pending body", function()
        local state = pending_state({ expires_at = 500 })
        local next_state = Pairing.next_poll_state(state, {
            ok = true, http_status = 200, body = { status = "pending" },
        }, 500)

        assert.are.equal("expired", next_state.status)
        assert.is_nil(next_state.poll_again_at)
    end)

    it("expiry wins even over a same-tick approval", function()
        local state = pending_state({ expires_at = 500 })
        local next_state = Pairing.next_poll_state(state, {
            ok = true, http_status = 200,
            body = { status = "approved", stream_key = "sk_live_abc123", linked_user = "chrono" },
        }, 500)

        assert.are.equal("expired", next_state.status)
        assert.is_nil(next_state.token)
    end)

    it("network/transport failure (ok=false): keeps polling, does not crash", function()
        local state = pending_state({ interval = 5 })
        local next_state = Pairing.next_poll_state(state, { ok = false }, 200)

        assert.are.equal("pending", next_state.status)
        assert.are.equal(205, next_state.poll_again_at)
    end)

    it("malformed body (nil / not a table): keeps polling, does not crash, does not clear the link", function()
        local state = pending_state({ interval = 5 })

        local a = Pairing.next_poll_state(state, { ok = true, http_status = 200, body = nil }, 200)
        assert.are.equal("pending", a.status)
        assert.is_nil(a.token)

        local b = Pairing.next_poll_state(state, { ok = true, http_status = 200, body = "not a table" }, 200)
        assert.are.equal("pending", b.status)
        assert.is_nil(b.token)
    end)

    it("unknown body.status string: keeps polling, does not crash", function()
        local state = pending_state({ interval = 5 })
        local next_state = Pairing.next_poll_state(state, {
            ok = true, http_status = 200, body = { status = "some_future_status" },
        }, 200)

        assert.are.equal("pending", next_state.status)
        assert.are.equal(205, next_state.poll_again_at)
    end)

    it("approved with an empty/missing stream_key is treated as malformed: keeps polling", function()
        local state = pending_state({ interval = 5 })
        local next_state = Pairing.next_poll_state(state, {
            ok = true, http_status = 200, body = { status = "approved", linked_user = "chrono" },
        }, 200)

        assert.are.equal("pending", next_state.status)
        assert.is_nil(next_state.token)
    end)

    it("does nothing when no pairing is in flight (state.status is not 'pending')", function()
        for _, status in ipairs({ "idle", "approved", "denied", "expired", "error" }) do
            local state = pending_state({ status = status, token = "existing-token", linked_user = "chrono" })
            local next_state = Pairing.next_poll_state(state, {
                ok = true, http_status = 200, body = { status = "denied" },
            }, 200)
            assert.are.same(state, next_state)
        end
    end)

end)

-- ---------------------------------------------------------------------------
-- Pure core: Pairing.should_poll
-- ---------------------------------------------------------------------------

describe("Pairing.should_poll", function()

    it("false when idle / not pending", function()
        assert.is_false(Pairing.should_poll(nil, 0))
        assert.is_false(Pairing.should_poll({ status = "idle" }, 0))
        assert.is_false(Pairing.should_poll({ status = "approved", poll_again_at = 0 }, 100))
    end)

    it("false when pending but the interval hasn't elapsed yet", function()
        assert.is_false(Pairing.should_poll({ status = "pending", poll_again_at = 200 }, 100))
    end)

    it("true when pending and now has reached poll_again_at", function()
        assert.is_true(Pairing.should_poll({ status = "pending", poll_again_at = 100 }, 100))
        assert.is_true(Pairing.should_poll({ status = "pending", poll_again_at = 100 }, 150))
    end)

end)

-- ---------------------------------------------------------------------------
-- Shell: Pairing.new / start_link / tick / unlink (injected fakes)
-- ---------------------------------------------------------------------------

--- A fake sender that records every call and lets the test manually invoke
--- the callback later — mirrors how SMODS.https.asyncRequest completes on a
--- later frame, on the main thread.
local function make_fake_sender()
    local calls = {}
    local sender = function(path, body, callback)
        calls[#calls + 1] = { path = path, body = body, callback = callback }
    end
    return sender, calls
end

local function make_pairing(overrides)
    overrides = overrides or {}
    local sender, calls = make_fake_sender()
    local saves = 0
    local logged = {}
    local opened = {}
    local config = overrides.config or {
        live_enabled = false,
        live_url     = "https://www.antelytics.gg",
        live_token   = "",
        linked_user  = "",
    }
    local now = overrides.now or 1000
    local relinks = 0
    local pairing = Pairing.new({
        config      = config,
        sender      = overrides.sender or sender,
        clock       = overrides.clock or function() return now end,
        logger      = overrides.logger or function(msg) logged[#logged + 1] = msg end,
        save_config = overrides.save_config or function() saves = saves + 1 end,
        open_url    = overrides.open_url or function(url) opened[#opened + 1] = url end,
        on_relink   = overrides.on_relink or function() relinks = relinks + 1 end,
    })
    return pairing, {
        calls    = calls,
        saves    = function() return saves end,
        relinks  = function() return relinks end,
        logged   = logged,
        opened   = opened,
    }
end

describe("Pairing — shell (injected fakes)", function()

    it("start_link posts to /pair/start and, on a well-formed response, opens the approval page", function()
        local pairing, spy = make_pairing()

        pairing:start_link()
        assert.are.equal(1, #spy.calls)
        assert.are.equal("/api/live/pair/start", spy.calls[1].path)

        spy.calls[1].callback(true, 200, {
            user_code = "ABCD-1234", device_code = "dev-1",
            verification_url = "https://www.antelytics.gg/link",
            expires_in = 600, interval = 5,
        })

        assert.are.equal("pending", pairing.state.status)
        assert.are.equal("ABCD-1234", pairing.display.user_code)
        assert.are.equal(1, #spy.opened)
        assert.are.equal("https://www.antelytics.gg/link", spy.opened[1])
    end)

    it("start_link is a no-op while a pairing is already pending", function()
        local pairing, spy = make_pairing()
        pairing:start_link()
        spy.calls[1].callback(true, 200, {
            user_code = "U", device_code = "D", expires_in = 600, interval = 5,
        })

        pairing:start_link() -- second call while status == "pending"
        assert.are.equal(1, #spy.calls)
    end)

    it("no polling occurs when no pairing is in flight", function()
        local pairing, spy = make_pairing()
        pairing:tick(1000)
        assert.are.equal(0, #spy.calls)
    end)

    it("tick polls only once the interval has elapsed, then approval writes config AND calls save exactly once", function()
        local pairing, spy = make_pairing({ now = 1000 })
        pairing:start_link()
        spy.calls[1].callback(true, 200, {
            user_code = "U", device_code = "dev-1", expires_in = 600, interval = 5,
        })

        -- Too early: no poll yet.
        pairing:tick(1002)
        assert.are.equal(1, #spy.calls)

        -- Interval elapsed: poll fires.
        pairing:tick(1005)
        assert.are.equal(2, #spy.calls)
        assert.are.equal("/api/live/pair/poll", spy.calls[2].path)
        assert.are.same({ device_code = "dev-1" }, spy.calls[2].body)

        spy.calls[2].callback(true, 200, { status = "approved", stream_key = "sk_live_abc", linked_user = "chrono" })

        assert.are.equal("sk_live_abc", pairing.config.live_token)
        assert.are.equal("chrono", pairing.config.linked_user)
        assert.are.equal(1, spy.saves())
        assert.are.equal(1, spy.relinks())
        assert.are.equal("approved", pairing.state.status)
        assert.are.equal("Linked as chrono", pairing.display.status_text)

        -- Approved: no further polling.
        pairing:tick(2000)
        assert.are.equal(2, #spy.calls)
    end)

    it("on_relink is NOT called for denied or expired outcomes — only a genuine new token warrants clearing a halt", function()
        local pairing, spy = make_pairing({ now = 1000 })
        pairing:start_link()
        spy.calls[1].callback(true, 200, {
            user_code = "U", device_code = "dev-1", expires_in = 600, interval = 5,
        })

        pairing:tick(1005)
        spy.calls[2].callback(true, 200, { status = "denied" })

        assert.are.equal("denied", pairing.state.status)
        assert.are.equal(0, spy.relinks())
    end)

    it("on_relink is NOT called while a pairing is merely pending (no approval yet)", function()
        local pairing, spy = make_pairing({ now = 1000 })
        pairing:start_link()
        spy.calls[1].callback(true, 200, {
            user_code = "U", device_code = "dev-1", expires_in = 600, interval = 5,
        })

        pairing:tick(1005)
        spy.calls[2].callback(true, 200, { status = "pending" })

        assert.are.equal("pending", pairing.state.status)
        assert.are.equal(0, spy.relinks())
    end)

    it("on_relink defaults to a safe no-op when not provided", function()
        local pairing = Pairing.new({
            config      = { live_url = "https://www.antelytics.gg" },
            sender      = function(_path, _body, callback) callback(true, 200, { status = "approved", stream_key = "sk_live_x", linked_user = "chrono" }) end,
            clock       = function() return 1000 end,
            logger      = function() end,
            save_config = function() end,
        })
        pairing.state = { status = "pending", device_code = "dev-1", interval = 5, poll_again_at = 1000, expires_at = 2000 }

        assert.has_no.errors(function()
            pairing:tick(1000)
        end)
        assert.are.equal("sk_live_x", pairing.config.live_token)
    end)

    it("an on_relink callback that throws is caught and does not propagate", function()
        local logged = {}
        local pairing = Pairing.new({
            config      = { live_url = "https://www.antelytics.gg" },
            sender      = function(_path, _body, callback) callback(true, 200, { status = "approved", stream_key = "sk_live_x", linked_user = "chrono" }) end,
            clock       = function() return 1000 end,
            logger      = function(msg) logged[#logged + 1] = msg end,
            save_config = function() end,
            on_relink   = function() error("live_publisher blew up") end,
        })
        pairing.state = { status = "pending", device_code = "dev-1", interval = 5, poll_again_at = 1000, expires_at = 2000 }

        assert.has_no.errors(function()
            pairing:tick(1000)
        end)
        -- Approval itself still succeeded despite on_relink failing.
        assert.are.equal("sk_live_x", pairing.config.live_token)
        assert.is_true(#logged > 0)
    end)

    it("a sender error during tick() is caught and does not propagate", function()
        local pairing = Pairing.new({
            config      = { live_url = "https://www.antelytics.gg" },
            sender      = function() error("network is on fire") end,
            clock       = function() return 1000 end,
            logger      = function() end,
            save_config = function() end,
        })
        pairing.state = { status = "pending", device_code = "dev-1", interval = 5, poll_again_at = 1000, expires_at = 2000 }

        assert.has_no.errors(function()
            pairing:tick(1000)
        end)
        assert.is_false(pairing.poll_in_flight)
    end)

    it("a sender error during start_link() is caught and does not propagate", function()
        local pairing = Pairing.new({
            config      = {},
            sender      = function() error("network is on fire") end,
            clock       = function() return 1000 end,
            logger      = function() end,
        })

        assert.has_no.errors(function()
            pairing:start_link()
        end)
        assert.are.equal("Could not start pairing — check live_url.", pairing.display.status_text)
    end)

    it("unlink clears config + saves even when the revoke call fails", function()
        local config = { live_url = "https://www.antelytics.gg", live_token = "sk_live_old", linked_user = "chrono" }
        local pairing, spy = make_pairing({
            config = config,
            sender = function() error("revoke endpoint is down") end,
        })

        assert.has_no.errors(function()
            pairing:unlink()
        end)

        assert.are.equal("", config.live_token)
        assert.are.equal("", config.linked_user)
        assert.are.equal(1, spy.saves())
        assert.are.equal("Not linked", pairing.display.status_text)
    end)

    it("unlink saves locally even when live_url is empty (no revoke attempted)", function()
        local config = { live_url = "", live_token = "sk_live_old", linked_user = "chrono" }
        local revoke_calls = 0
        local pairing, spy = make_pairing({
            config = config,
            sender = function() revoke_calls = revoke_calls + 1 end,
        })

        pairing:unlink()

        assert.are.equal("", config.live_token)
        assert.are.equal(1, spy.saves())
        assert.are.equal(0, revoke_calls)
    end)

end)

describe("pairing enables publishing on approval", function()
    -- Regression: a player who completes the entire link flow and then sees
    -- nothing happen has hit a dead end. Approval is the request to publish.
    it("sets live_enabled when a stream key is written", function()
        local config = { live_url = "https://example.test", live_enabled = false }
        local saved = 0
        local p = Pairing.new({
            config = config,
            clock = function() return 1000 end,
            save_config = function() saved = saved + 1 end,
            sender = function() end,
        })
        p.state = {
            status = "pending", device_code = "d", user_code = "U",
            interval = 5, expires_at = 9999, poll_again_at = 0,
        }

        p:_handle_poll_response(true, 200, { status = "approved", stream_key = "k", linked_user = "Chrono" })

        assert.are.equal("k", config.live_token)
        assert.is_true(config.live_enabled)
        assert.is_true(saved >= 1)
    end)

    it("does not re-enable publishing that the player turned off after linking", function()
        -- unlink() clears the link; it must not also flip a manual preference
        -- back on behind the player's back.
        local config = { live_url = "https://example.test", live_enabled = false, live_token = "k", linked_user = "Chrono" }
        local p = Pairing.new({
            config = config,
            clock = function() return 1000 end,
            save_config = function() end,
            sender = function() end,
        })

        p:unlink()

        assert.are.equal("", config.live_token)
        assert.is_false(config.live_enabled)
    end)
end)
