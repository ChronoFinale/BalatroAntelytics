--- spec/golden/runner_spec.lua
---
--- Discovers every scenario in spec/golden/scenarios/ and asserts the
--- nodes it produces match the checked-in expected file in
--- spec/golden/expected/.
---
--- To regenerate after an intentional capture-format change:
---     REGEN=1 busted spec/golden/runner_spec.lua

local Runner = assert(loadfile("spec/golden/lib/runner.lua"))()

describe("golden scenarios", function()
    local entries = Runner.discover()

    -- A pinning test so we notice if scenarios stop being discovered.
    it("discovers at least one scenario", function()
        assert.is_true(#entries > 0, "no scenarios found in spec/golden/scenarios/")
    end)

    if os.getenv("REGEN") == "1" then
        for _, entry in ipairs(entries) do
            it("[REGEN] " .. entry.name, function()
                Runner.regenerate(entry)
                print("regenerated " .. entry.expected_path)
            end)
        end
        return
    end

    for _, entry in ipairs(entries) do
        it("matches expected output: " .. entry.name, function()
            local ok, message = Runner.check(entry)
            if not ok then
                error("\nGolden mismatch in scenario '" .. entry.name .. "':\n" ..
                      "  expected: " .. entry.expected_path .. "\n" ..
                      "  scenario: " .. entry.scenario_path .. "\n\n" ..
                      message .. "\n\n" ..
                      "Run with REGEN=1 to update the expected file " ..
                      "if this change is intentional.")
            end
        end)
    end
end)
