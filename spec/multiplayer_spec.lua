--- multiplayer_spec.lua
--- Unit tests for the Balatro Antelytics Multiplayer accessor module.
--- Validates: Requirements 4.1, 4.3, 4.4
---
--- Field paths target Multiplayer mod 0.3.3: the runtime global is `MP`
--- (MP = SMODS.current_mod), opponent state lives in MP.GAME.enemy.*, lives in
--- MP.GAME.lives, opponent name in MP.LOBBY.{host,guest}.username, the local
--- score is the vanilla G.GAME.chips, and the PvP-blind test is MP.is_pvp_boss().

-- Adjust package path to find the multiplayer module
package.path = package.path .. ";../lib/?.lua;./lib/?.lua;./Antelytics/lib/?.lua"

local Multiplayer = require("multiplayer")

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

--- Capturing logger: records every message it receives.
local function make_capturing_logger()
    local msgs = {}
    local function logger(msg)
        msgs[#msgs + 1] = msg
    end
    return logger, msgs
end

--- Install a read-counting proxy as `_G.MP` (the mod's runtime global). Any
--- index into it bumps the counter — used to prove the disabled path never
--- touches the global.
local function install_read_counter_mp()
    local counter = { count = 0 }
    _G.MP = setmetatable({}, {
        __index = function(_, _key)
            counter.count = counter.count + 1
            return nil
        end,
    })
    return counter
end

--- Install a populated `_G.MP` + `_G.G` matching the 0.3.3 field layout the
--- accessor reads.
local function install_populated_mp(overrides)
    overrides = overrides or {}
    local opp_score = overrides.opponent_score or "1200"
    _G.MP = {
        is_pvp_boss = function()
            if overrides.is_pvp_blind == nil then return true end
            return overrides.is_pvp_blind
        end,
        -- Stand-in INSANE_INT decoder: our mock score tables carry a `_s` string.
        INSANE_INT = { to_string = function(v) return type(v) == "table" and v._s or nil end },
        LOBBY = {
            is_host = true,
            guest   = { username = overrides.opponent_name or "rival_player" },
            host    = { username = "me" },
            code    = "ABC123",
            config  = { gamemode = "gamemode_mp_attrition" },
        },
        GAME = {
            lives = overrides.player_lives or 3,
            enemy = {
                lives         = overrides.opponent_lives or 2,
                hands         = overrides.opponent_hands or 4,
                score         = { _s = opp_score },
                highest_score = { _s = opp_score },
            },
        },
    }
    _G.G = {
        GAME = {
            chips = overrides.player_score or 1500,
            blind = { config = { blind = { key = "bl_mp_nemesis" } }, pvp = true },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("Multiplayer accessor module", function()

    after_each(function()
        _G.MP = nil
        _G.Multiplayer = nil
        _G.G = nil
        _G.SMODS = nil
    end)

    -- -----------------------------------------------------------------------
    -- Requirement 4.3: disabled path performs zero reads on the global.
    -- -----------------------------------------------------------------------
    describe("with pvp_enabled = false", function()

        it("enabled flag is exposed as false", function()
            local mp = Multiplayer.new({ logger = make_capturing_logger(), pvp_enabled = false })
            assert.is_false(mp.enabled)
        end)

        it("all accessors return nil", function()
            install_populated_mp()
            local mp = Multiplayer.new({ logger = make_capturing_logger(), pvp_enabled = false })
            assert.is_nil(mp.is_pvp_blind())
            assert.is_nil(mp.opponent_id())
            assert.is_nil(mp.opponent_name())
            assert.is_nil(mp.player_score())
            assert.is_nil(mp.opponent_score())
            assert.is_nil(mp.player_lives())
            assert.is_nil(mp.opponent_lives())
        end)

        it("no accessor indexes into the MP global", function()
            local counter = install_read_counter_mp()
            local mp = Multiplayer.new({ logger = make_capturing_logger(), pvp_enabled = false })
            mp.is_pvp_blind()
            mp.opponent_id()
            mp.opponent_name()
            mp.player_score()
            mp.opponent_score()
            assert.are.equal(0, counter.count)
        end)

        it("no accessor emits a log message", function()
            install_populated_mp()
            local logger, msgs = make_capturing_logger()
            local mp = Multiplayer.new({ logger = logger, pvp_enabled = false })
            mp.opponent_id(); mp.opponent_name(); mp.player_score(); mp.opponent_score()
            assert.are.equal(0, #msgs)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- Requirement 4.4: enabled path with globals present reads real fields.
    -- -----------------------------------------------------------------------
    describe("with pvp_enabled = true and globals present", function()

        it("enabled flag is exposed as true", function()
            install_populated_mp()
            local mp = Multiplayer.new({ logger = make_capturing_logger(), pvp_enabled = true })
            assert.is_true(mp.enabled)
        end)

        it("is_pvp_blind returns MP.is_pvp_boss()", function()
            install_populated_mp({ is_pvp_blind = true })
            local mp = Multiplayer.new({ logger = make_capturing_logger(), pvp_enabled = true })
            assert.is_true(mp.is_pvp_blind())
        end)

        it("is_pvp_blind returns false for a non-PvP blind", function()
            install_populated_mp({ is_pvp_blind = false })
            local mp = Multiplayer.new({ logger = make_capturing_logger(), pvp_enabled = true })
            assert.is_false(mp.is_pvp_blind())
        end)

        it("opponent_name / opponent_id read the opposing lobby username", function()
            install_populated_mp({ opponent_name = "rival" })
            local mp = Multiplayer.new({ logger = make_capturing_logger(), pvp_enabled = true })
            assert.are.equal("rival", mp.opponent_name())
            assert.are.equal("rival", mp.opponent_id())
        end)

        it("player_score reads the vanilla G.GAME.chips", function()
            install_populated_mp({ player_score = 4200 })
            local mp = Multiplayer.new({ logger = make_capturing_logger(), pvp_enabled = true })
            assert.are.equal(4200, mp.player_score())
        end)

        it("opponent_score decodes the enemy INSANE_INT score", function()
            install_populated_mp({ opponent_score = "3100" })
            local mp = Multiplayer.new({ logger = make_capturing_logger(), pvp_enabled = true })
            assert.are.equal("3100", mp.opponent_score())
        end)

        it("lives and opponent hands read from MP.GAME", function()
            install_populated_mp({ player_lives = 3, opponent_lives = 1, opponent_hands = 2 })
            local mp = Multiplayer.new({ logger = make_capturing_logger(), pvp_enabled = true })
            assert.are.equal(3, mp.player_lives())
            assert.are.equal(1, mp.opponent_lives())
            assert.are.equal(2, mp.opponent_hands_left())
        end)

        it("successful reads emit no log messages", function()
            install_populated_mp()
            local logger, msgs = make_capturing_logger()
            local mp = Multiplayer.new({ logger = logger, pvp_enabled = true })
            mp.is_pvp_blind(); mp.opponent_id(); mp.opponent_name()
            mp.player_score(); mp.opponent_score(); mp.player_lives(); mp.opponent_lives()
            assert.are.equal(0, #msgs)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- Requirement 4.4: enabled path with the MP global absent returns nil
    -- gracefully (no crash). Absence is the normal non-match case, so no
    -- warning is emitted.
    -- -----------------------------------------------------------------------
    describe("with pvp_enabled = true and MP global absent", function()

        before_each(function()
            _G.MP = nil
            _G.Multiplayer = nil
        end)

        it("every accessor returns nil without crashing", function()
            local mp = Multiplayer.new({ logger = make_capturing_logger(), pvp_enabled = true })
            assert.is_nil(mp.is_pvp_blind())
            assert.is_nil(mp.opponent_id())
            assert.is_nil(mp.opponent_name())
            assert.is_nil(mp.player_score())
            assert.is_nil(mp.opponent_score())
            assert.is_nil(mp.player_lives())
            assert.is_nil(mp.opponent_lives())
            assert.is_nil(mp.opponent_hands_left())
        end)

        it("absent global produces no warnings (normal non-match case)", function()
            local logger, msgs = make_capturing_logger()
            local mp = Multiplayer.new({ logger = logger, pvp_enabled = true })
            mp.opponent_id(); mp.player_score(); mp.opponent_score()
            assert.are.equal(0, #msgs)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- Requirement 4.1: detect() probe behavior (supporting coverage).
    -- -----------------------------------------------------------------------
    describe("Multiplayer.detect", function()

        it("returns false when SMODS is absent", function()
            _G.SMODS = nil
            assert.is_false(Multiplayer.detect())
        end)

        it("returns false when SMODS.find_mod is not a function", function()
            _G.SMODS = { find_mod = "not a function" }
            assert.is_false(Multiplayer.detect())
        end)

        it("returns false when find_mod returns an empty array", function()
            _G.SMODS = { find_mod = function(_) return {} end }
            assert.is_false(Multiplayer.detect())
        end)

        it("returns true when find_mod returns a non-empty array", function()
            _G.SMODS = { find_mod = function(_) return { { id = "Multiplayer" } } end }
            assert.is_true(Multiplayer.detect())
        end)

        it("returns false when find_mod throws", function()
            _G.SMODS = { find_mod = function(_) error("boom") end }
            assert.is_false(Multiplayer.detect())
        end)

        it("new() without pvp_enabled override falls back to detect()", function()
            _G.SMODS = { find_mod = function(_) return {} end }
            local mp = Multiplayer.new({ logger = make_capturing_logger() })
            assert.is_false(mp.enabled)
        end)
    end)
end)
