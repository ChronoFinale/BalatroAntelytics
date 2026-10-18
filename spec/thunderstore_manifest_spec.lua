--- spec/thunderstore_manifest_spec.lua
--- Tripwire for the Thunderstore package metadata in thunderstore/. The
--- packaging scripts re-stamp version_number at build time, but the committed
--- manifest is also what a manual upload uses, so keep it in lockstep with
--- Antelytics.json and inside Thunderstore's limits (name charset, description
--- length, exactly 256x256 PNG icon).

local function read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local function json_string(src, key)
    return src:match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

describe("thunderstore package metadata", function()
    local manifest = read("thunderstore/manifest.json")

    it("version_number is Antelytics.json's version without the ~prerelease tag", function()
        local mod_version = assert(json_string(read("Antelytics.json"), "version"))
        local expected = mod_version:match("^([^~]+)")
        assert.equals(expected, json_string(manifest, "version_number"))
        assert.truthy(expected:match("^%d+%.%d+%.%d+$"), "Thunderstore needs plain semver")
    end)

    it("name is the install folder name and uses only [A-Za-z0-9_]", function()
        local name = assert(json_string(manifest, "name"))
        assert.equals("Antelytics", name)
        assert.truthy(name:match("^[%w_]+$"))
    end)

    it("description fits Thunderstore's 250-character limit", function()
        local desc = assert(json_string(manifest, "description"))
        assert.is_true(#desc > 0 and #desc <= 250, "description length " .. #desc)
    end)

    it("depends on Steamodded via a Thunderstore dependency string", function()
        assert.truthy(manifest:match('"Steamodded%-Steamodded%-%d+%.%d+%.%d+"'))
        assert.truthy(json_string(manifest, "website_url"), "website_url key is required")
    end)

    it("icon.png is a 256x256 PNG", function()
        local png = read("thunderstore/icon.png")
        assert.equals("\137PNG\r\n\26\n", png:sub(1, 8), "not a PNG signature")
        -- IHDR: 4-byte big-endian width at offset 17, height at offset 21.
        local function be32(s, i)
            local a, b, c, d = s:byte(i, i + 3)
            return ((a * 256 + b) * 256 + c) * 256 + d
        end
        assert.equals(256, be32(png, 17))
        assert.equals(256, be32(png, 21))
    end)
end)
