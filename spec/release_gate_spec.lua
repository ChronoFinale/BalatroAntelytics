--- spec/release_gate_spec.lua
--- Release tripwire for Antelytics Live, which ships dark: the code is in the
--- zip but must not be enableable. Pins the two values main.lua relies on so a
--- stray edit cannot ship live by accident. When live is ready to launch, flip
--- LIVE_AVAILABLE deliberately and delete this spec in the same commit.

local function read(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

describe("release gate: Antelytics Live ships dark", function()
    it("main.lua hard-disables live", function()
        local src = read("main.lua")
        assert.truthy(src:find("local LIVE_AVAILABLE = false", 1, true),
            "main.lua must declare `local LIVE_AVAILABLE = false`")
        assert.falsy(src:find("LIVE_AVAILABLE = true", 1, true),
            "LIVE_AVAILABLE must not be flipped on")
    end)

    it("main.lua forces live_enabled off when gated", function()
        local src = read("main.lua")
        assert.truthy(src:find("config.live_enabled = false", 1, true),
            "the gated branch must force config.live_enabled = false")
    end)

    it("config.lua defaults live off with no token", function()
        local cfg = assert(loadfile("config.lua"))()
        assert.is_false(cfg.live_enabled)
        assert.equals("", cfg.live_token)
        assert.equals("", cfg.linked_user)
    end)
end)
