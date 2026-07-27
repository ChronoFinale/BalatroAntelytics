--- http_client_spec.lua
--- Regression cover for the bug that made every live request fail silently:
--- SMODS registers its HTTPS client as a lovely MODULE named "SMODS.https"
--- (module registry), NOT as a field on the SMODS global. Reading
--- `SMODS.https.asyncRequest` therefore always yielded nil and every send
--- errored with "not available" — caught, logged, and invisible in game.

describe("http_client", function()
    local HttpClient
    local saved_smods
    local saved_loaded

    before_each(function()
        package.loaded["lib.http_client"] = nil
        HttpClient = require("lib.http_client")
        saved_smods = rawget(_G, "SMODS")
        saved_loaded = package.loaded["SMODS.https"]
    end)

    after_each(function()
        rawset(_G, "SMODS", saved_smods)
        package.loaded["SMODS.https"] = saved_loaded
    end)

    it("resolves the client from the module registry (the real SMODS path)", function()
        local fake = { asyncRequest = function() end }
        package.loaded["SMODS.https"] = fake
        rawset(_G, "SMODS", {}) -- global deliberately has no .https, as in real SMODS

        assert.are.equal(fake, HttpClient.resolve())
    end)

    it("falls back to the SMODS global if a future version also exposes it there", function()
        package.loaded["SMODS.https"] = nil
        local fake = { asyncRequest = function() end }
        rawset(_G, "SMODS", { https = fake })

        assert.are.equal(fake, HttpClient.resolve())
    end)

    it("returns nil when neither path yields a usable client", function()
        package.loaded["SMODS.https"] = nil
        rawset(_G, "SMODS", {})

        assert.is_nil(HttpClient.resolve())
    end)

    it("rejects a module that lacks asyncRequest rather than returning it", function()
        -- smods-https.lua can load without a transport (no https module, no
        -- luajit-curl), so presence is not proof of a usable client.
        package.loaded["SMODS.https"] = { request = function() end }
        rawset(_G, "SMODS", {})

        assert.is_nil(HttpClient.resolve())
    end)

    it("require_client raises a message naming what to check", function()
        package.loaded["SMODS.https"] = nil
        rawset(_G, "SMODS", {})

        local ok, err = pcall(function() HttpClient.require_client() end)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("SMODS.https", 1, true))
    end)

    it("require_client returns the client when one is available", function()
        local fake = { asyncRequest = function() end }
        package.loaded["SMODS.https"] = fake
        rawset(_G, "SMODS", {})

        assert.are.equal(fake, HttpClient.require_client())
    end)
end)
