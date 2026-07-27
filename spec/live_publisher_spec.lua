--- live_publisher_spec.lua
--- Tests for "Antelytics Live" fire-and-forget node publishing.
---
--- The core decision (should we publish? what's the payload?) is pure and
--- tested with plain tables. The sender and clock are injected fakes here —
--- production wires SMODS.https.asyncRequest + os.time (see live_publisher.lua).

local LivePublisher = require("lib.live_publisher")
local Recorder      = require("lib.recorder")

--- A fake sender that records every call instead of doing network I/O.
local function make_fake_sender()
    local calls = {}
    local sender = function(url, token, payload)
        calls[#calls + 1] = { url = url, token = token, payload = payload }
    end
    return sender, calls
end

local function make_publisher(overrides)
    overrides = overrides or {}
    local sender, calls = make_fake_sender()
    local publisher = LivePublisher.new({
        config = overrides.config or {
            live_enabled = true,
            live_url     = "https://www.antelytics.gg",
            live_token   = string.rep("t", 32),
        },
        sender      = overrides.sender or sender,
        clock       = overrides.clock or function() return 1234 end,
        logger      = overrides.logger or function() end,
        mod_version = overrides.mod_version or "1.2.2~alpha",
    })
    return publisher, calls
end

--- A fake sender that records every call AND captures the `on_response`
--- callback so a test can simulate the async completion manually — mirrors
--- how SMODS.https.asyncRequest completes on a later frame, not inline.
local function make_responsive_fake_sender()
    local calls = {}
    local sender = function(url, token, payload, on_response)
        calls[#calls + 1] = { url = url, token = token, payload = payload, on_response = on_response }
    end
    return sender, calls
end

local function make_responsive_publisher(overrides)
    overrides = overrides or {}
    local sender, calls = make_responsive_fake_sender()
    local logged = {}
    local publisher = LivePublisher.new({
        config = overrides.config or {
            live_enabled = true,
            live_url     = "https://www.antelytics.gg",
            live_token   = string.rep("t", 32),
        },
        sender      = overrides.sender or sender,
        clock       = overrides.clock or function() return 1234 end,
        logger      = overrides.logger or function(msg) logged[#logged + 1] = msg end,
        mod_version = overrides.mod_version or "1.2.2~alpha",
    })
    return publisher, calls, logged
end

describe("LivePublisher — pure core", function()

    describe("should_publish", function()
        it("is false by default (no config at all)", function()
            assert.is_false(LivePublisher.should_publish(nil))
            assert.is_false(LivePublisher.should_publish({}))
        end)

        it("is false when live_enabled is false", function()
            assert.is_false(LivePublisher.should_publish({
                live_enabled = false,
                live_url     = "https://www.antelytics.gg",
                live_token   = string.rep("t", 32),
            }))
        end)

        it("is false when live_url is missing or empty", function()
            assert.is_false(LivePublisher.should_publish({
                live_enabled = true,
                live_url     = "",
                live_token   = string.rep("t", 32),
            }))
            assert.is_false(LivePublisher.should_publish({
                live_enabled = true,
                live_token   = string.rep("t", 32),
            }))
        end)

        it("is false when live_token is missing or empty", function()
            assert.is_false(LivePublisher.should_publish({
                live_enabled = true,
                live_url     = "https://www.antelytics.gg",
                live_token   = "",
            }))
            assert.is_false(LivePublisher.should_publish({
                live_enabled = true,
                live_url     = "https://www.antelytics.gg",
            }))
        end)

        it("is true when enabled with both url and token set", function()
            assert.is_true(LivePublisher.should_publish({
                live_enabled = true,
                live_url     = "https://www.antelytics.gg",
                live_token   = string.rep("t", 32),
            }))
        end)
    end)

    describe("build_payload", function()
        it("builds the exact wire shape: run_id, seq (from node.index), node, mod_version, sent_at", function()
            local node = { index = 7, action = { type = "play_hand" } }
            local payload = LivePublisher.build_payload("RUN1", node, "1.2.2~alpha", 1000)

            assert.are.same({
                run_id      = "RUN1",
                seq         = 7,
                node        = node,
                mod_version = "1.2.2~alpha",
                sent_at     = 1000,
            }, payload)
        end)
    end)

    describe("classify_response", function()
        it("401 and 403 are auth_failure — permanent, retrying will never succeed", function()
            assert.are.equal("auth_failure", LivePublisher.classify_response(401))
            assert.are.equal("auth_failure", LivePublisher.classify_response(403))
        end)

        it("everything else (success, other 4xx, 5xx, or nil for no response at all) is ok", function()
            assert.are.equal("ok", LivePublisher.classify_response(200))
            assert.are.equal("ok", LivePublisher.classify_response(400))
            assert.are.equal("ok", LivePublisher.classify_response(404))
            assert.are.equal("ok", LivePublisher.classify_response(429))
            assert.are.equal("ok", LivePublisher.classify_response(500))
            assert.are.equal("ok", LivePublisher.classify_response(503))
            assert.are.equal("ok", LivePublisher.classify_response(nil)) -- timeout / no response
        end)
    end)

    describe("next_auth_state", function()
        it("401 halts, with the exact unauthorized message", function()
            local halt, message = LivePublisher.next_auth_state(401)
            assert.is_true(halt)
            assert.are.equal("Publishing unauthorized — relink your account", message)
            assert.are.equal(LivePublisher.UNAUTHORIZED_MESSAGE, message)
        end)

        it("403 halts the same way", function()
            local halt, message = LivePublisher.next_auth_state(403)
            assert.is_true(halt)
            assert.are.equal(LivePublisher.UNAUTHORIZED_MESSAGE, message)
        end)

        it("500 does not halt: no message, fire-and-forget continues", function()
            local halt, message = LivePublisher.next_auth_state(500)
            assert.is_false(halt)
            assert.are.equal("", message)
        end)

        it("nil (timeout / no response at all) does not halt", function()
            local halt, message = LivePublisher.next_auth_state(nil)
            assert.is_false(halt)
            assert.are.equal("", message)
        end)

        it("a success (200) does not halt", function()
            local halt, message = LivePublisher.next_auth_state(200)
            assert.is_false(halt)
            assert.are.equal("", message)
        end)
    end)

end)

describe("LivePublisher — publish (shell, with injected sender/clock)", function()

    it("disabled by default: nothing is sent", function()
        local publisher, calls = make_publisher({
            config = { live_enabled = false, live_url = "", live_token = "" },
        })
        publisher:publish("RUN1", { index = 0 })
        assert.are.equal(0, #calls)
    end)

    it("enabled but missing live_url: nothing is sent", function()
        local publisher, calls = make_publisher({
            config = { live_enabled = true, live_url = "", live_token = string.rep("t", 32) },
        })
        publisher:publish("RUN1", { index = 0 })
        assert.are.equal(0, #calls)
    end)

    it("enabled but missing live_token: nothing is sent", function()
        local publisher, calls = make_publisher({
            config = { live_enabled = true, live_url = "https://www.antelytics.gg", live_token = "" },
        })
        publisher:publish("RUN1", { index = 0 })
        assert.are.equal(0, #calls)
    end)

    it("enabled + configured: sender is called once per node with the exact expected payload", function()
        local publisher, calls = make_publisher()
        local node = { index = 3, action = { type = "skip_blind" } }

        publisher:publish("RUN42", node)

        assert.are.equal(1, #calls)
        assert.are.equal("https://www.antelytics.gg", calls[1].url)
        assert.are.equal(string.rep("t", 32), calls[1].token)
        assert.are.same({
            run_id      = "RUN42",
            seq         = 3,
            node        = node,
            mod_version = "1.2.2~alpha",
            sent_at     = 1234,
        }, calls[1].payload)
    end)

    it("sends one call per publish() invocation, in order", function()
        local publisher, calls = make_publisher()
        publisher:publish("RUN1", { index = 0 })
        publisher:publish("RUN1", { index = 1 })

        assert.are.equal(2, #calls)
        assert.are.equal(0, calls[1].payload.seq)
        assert.are.equal(1, calls[2].payload.seq)
    end)

    it("sender throwing does not propagate — the error is caught and logged", function()
        local logged = {}
        local publisher = LivePublisher.new({
            config = {
                live_enabled = true,
                live_url     = "https://www.antelytics.gg",
                live_token   = string.rep("t", 32),
            },
            sender = function() error("network is on fire") end,
            clock  = function() return 1 end,
            logger = function(msg) logged[#logged + 1] = msg end,
            mod_version = "1.2.2~alpha",
        })

        assert.has_no.errors(function()
            publisher:publish("RUN1", { index = 0 })
        end)
        assert.are.equal(1, #logged)
        assert.truthy(logged[1]:find("network is on fire", 1, true))
    end)

    it("uses the injected clock for sent_at, not a wall-clock read", function()
        local calls_seen = 0
        local publisher, calls = make_publisher({
            clock = function() calls_seen = calls_seen + 1; return 9999 end,
        })
        publisher:publish("RUN1", { index = 0 })
        assert.are.equal(9999, calls[1].payload.sent_at)
        assert.are.equal(1, calls_seen)
    end)

end)

describe("LivePublisher — auth-failure halt (shell, injected sender/clock)", function()

    it("a fresh publisher starts unhalted with an empty, string status_text", function()
        local publisher = make_responsive_publisher()
        assert.is_false(publisher.halted)
        assert.are.equal("string", type(publisher.display.status_text))
        assert.are.equal("", publisher.display.status_text)
    end)

    it("401 flips to the unauthorized state and halts sending: no further node reaches the sender", function()
        local publisher, calls = make_responsive_publisher()

        publisher:publish("RUN1", { index = 0 })
        assert.are.equal(1, #calls)
        calls[1].on_response(401)

        assert.is_true(publisher.halted)
        assert.are.equal("string", type(publisher.display.status_text))
        assert.are.equal(LivePublisher.UNAUTHORIZED_MESSAGE, publisher.display.status_text)

        publisher:publish("RUN1", { index = 1 })
        assert.are.equal(1, #calls) -- still 1: halted, sender never called again
    end)

    it("403 halts sending the same way", function()
        local publisher, calls = make_responsive_publisher()

        publisher:publish("RUN1", { index = 0 })
        calls[1].on_response(403)

        assert.is_true(publisher.halted)
        assert.are.equal(LivePublisher.UNAUTHORIZED_MESSAGE, publisher.display.status_text)

        publisher:publish("RUN1", { index = 1 })
        assert.are.equal(1, #calls)
    end)

    it("500 does NOT halt: still fire-and-forget, the next node still sends", function()
        local publisher, calls = make_responsive_publisher()

        publisher:publish("RUN1", { index = 0 })
        calls[1].on_response(500)

        assert.is_false(publisher.halted)
        assert.are.equal("", publisher.display.status_text)

        publisher:publish("RUN1", { index = 1 })
        assert.are.equal(2, #calls)
    end)

    it("a timeout / no response at all (on_response(nil)) does NOT halt", function()
        local publisher, calls = make_responsive_publisher()

        publisher:publish("RUN1", { index = 0 })
        calls[1].on_response(nil)

        assert.is_false(publisher.halted)
        assert.are.equal("", publisher.display.status_text)

        publisher:publish("RUN1", { index = 1 })
        assert.are.equal(2, #calls)
    end)

    it("a success after a transient failure keeps publishing", function()
        local publisher, calls = make_responsive_publisher()

        publisher:publish("RUN1", { index = 0 })
        calls[1].on_response(500) -- transient failure

        publisher:publish("RUN1", { index = 1 })
        calls[2].on_response(200) -- success

        publisher:publish("RUN1", { index = 2 })

        assert.are.equal(3, #calls)
        assert.is_false(publisher.halted)
    end)

    it("reset_auth_state clears a halt and sending resumes", function()
        local publisher, calls = make_responsive_publisher()

        publisher:publish("RUN1", { index = 0 })
        calls[1].on_response(401)
        assert.is_true(publisher.halted)

        publisher:reset_auth_state()

        assert.is_false(publisher.halted)
        assert.are.equal("string", type(publisher.display.status_text))
        assert.are.equal("", publisher.display.status_text)

        publisher:publish("RUN1", { index = 1 })
        assert.are.equal(2, #calls)
    end)

    it("reset_auth_state is a safe no-op when not halted", function()
        local publisher = make_responsive_publisher()
        assert.has_no.errors(function() publisher:reset_auth_state() end)
        assert.is_false(publisher.halted)
        assert.are.equal("", publisher.display.status_text)
    end)

    it("display table identity never changes across halt/reset — required for the UI's captured ref_table binding (see lib/pairing_ui.lua)", function()
        local publisher, calls = make_responsive_publisher()
        local display_ref = publisher.display

        publisher:publish("RUN1", { index = 0 })
        calls[1].on_response(401)
        assert.are.equal(display_ref, publisher.display)

        publisher:reset_auth_state()
        assert.are.equal(display_ref, publisher.display)
    end)

end)

describe("Recorder — file_writer and live_publisher are independent sinks", function()

    local function make_fake_file_writer()
        local nodes = {}
        return {
            nodes = nodes,
            start_run = function() end,
            append_node = function(self, node) nodes[#nodes + 1] = node end,
        }, nodes
    end

    it("with live disabled: node still reaches file_writer, live_publisher gets nothing", function()
        local fw, fw_nodes = make_fake_file_writer()
        local publisher, live_calls = make_publisher({
            config = { live_enabled = false, live_url = "", live_token = "" },
        })
        local recorder = Recorder.new({ file_writer = fw, live_publisher = publisher })

        recorder:start_run("RUN1", "alice", "SEED", 1000, "solo")
        recorder:send({ index = 0, action = { type = "play_hand" } })

        assert.are.equal(1, #fw_nodes)
        assert.are.equal(0, #live_calls)
    end)

    it("with live enabled: node reaches BOTH file_writer and live_publisher", function()
        local fw, fw_nodes = make_fake_file_writer()
        local publisher, live_calls = make_publisher()
        local recorder = Recorder.new({ file_writer = fw, live_publisher = publisher })

        recorder:start_run("RUN1", "alice", "SEED", 1000, "solo")
        local node = { index = 0, action = { type = "play_hand" } }
        recorder:send(node)

        assert.are.equal(1, #fw_nodes)
        assert.are.equal(1, #live_calls)
        assert.are.equal("RUN1", live_calls[1].payload.run_id)
        assert.are.same(node, live_calls[1].payload.node)
    end)

    it("live publishing still happens when file_writer is nil (no early-return trap)", function()
        local publisher, live_calls = make_publisher()
        local recorder = Recorder.new({ file_writer = nil, live_publisher = publisher })

        recorder:start_run("RUN1", "alice", "SEED", 1000, "solo")
        recorder:send({ index = 0, action = { type = "play_hand" } })

        assert.are.equal(1, #live_calls)
    end)

    it("a live_publisher error is caught by Recorder and does not stop file_writer", function()
        local fw, fw_nodes = make_fake_file_writer()
        local exploding_publisher = { publish = function() error("boom") end }
        local logged = {}
        local recorder = Recorder.new({
            file_writer    = fw,
            live_publisher = exploding_publisher,
            logger         = function(msg) logged[#logged + 1] = msg end,
        })

        recorder:start_run("RUN1", "alice", "SEED", 1000, "solo")
        assert.has_no.errors(function()
            recorder:send({ index = 0 })
        end)

        assert.are.equal(1, #fw_nodes)
        assert.is_true(#logged > 0)
    end)

end)
