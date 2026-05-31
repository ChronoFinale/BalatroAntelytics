--- spec/skip_blind_action_spec.lua
--- Unit tests for lib/skip_blind_action.lua — the pure helper that turns
--- post-skip engine state into a JSON-ready skip_blind_tag action payload.
---
--- Background: the previous capture path recorded only `{type =
--- "skip_blind_tag"}` with no identifying fields, so the viewer had no
--- way to show which blind was skipped or which tag was taken. This
--- spec pins the new payload shape against the engine state shape we
--- observed in real run files.

local SkipBlindAction = assert(loadfile("lib/skip_blind_action.lua"))()
local Serializer      = assert(loadfile("lib/serializer.lua"))()

--- Build a fake G mirroring the real engine state right after a Big
--- Blind skip with the "Investment" tag taken.
local function fake_G_after_skip(opts)
    opts = opts or {}
    return {
        GAME = {
            round_resets = {
                blind_states = opts.blind_states or {
                    Small = "Defeated",
                    Big   = "Skipped",
                    Boss  = "Upcoming",
                },
                blind_choices = opts.blind_choices or {
                    Small = "bl_small",
                    Big   = "bl_big",
                    Boss  = "bl_pillar",
                },
            },
            blind_on_deck = opts.blind_on_deck or "Boss",
            tags = opts.tags or {
                { key = "tag_investment", name = "Investment Tag" },
            },
        },
        P_BLINDS = opts.P_BLINDS or {
            bl_small  = { name = "Small Blind" },
            bl_big    = { name = "Big Blind" },
            bl_pillar = { name = "The Pillar", boss = true },
        },
    }
end

describe("SkipBlindAction.build", function()

    it("captures the slot, blind key, blind name, and tag for a Big Blind skip", function()
        local action = SkipBlindAction.build(fake_G_after_skip(), Serializer)

        assert.are.equal("skip_blind_tag",  action.type)
        assert.are.equal("big",             action.blind_slot)
        assert.are.equal("bl_big",          action.blind_key)
        assert.are.equal("Big Blind",       action.blind_name)
        assert.are.equal("tag_investment",  action.tag_id)
        assert.are.equal("Investment Tag",  action.tag_name)
        assert.are.equal("boss",            action.next_blind_slot)
    end)

    it("captures a Small Blind skip", function()
        local action = SkipBlindAction.build(fake_G_after_skip{
            blind_states = { Small = "Skipped", Big = "Upcoming", Boss = "Upcoming" },
            blind_on_deck = "Big",
        }, Serializer)

        assert.are.equal("small", action.blind_slot)
        assert.are.equal("big",   action.next_blind_slot)
    end)

    it("uses the last tag in G.GAME.tags as the most-recent tag", function()
        -- A second skip: the player previously took an Investment tag and
        -- now took a Boss tag. The last entry is the most recent.
        local action = SkipBlindAction.build(fake_G_after_skip{
            tags = {
                { key = "tag_investment", name = "Investment Tag" },
                { key = "tag_boss",       name = "Boss Tag"       },
            },
        }, Serializer)
        assert.are.equal("tag_boss", action.tag_id)
        assert.are.equal("Boss Tag", action.tag_name)
    end)

    it("falls back to the blind_key when P_BLINDS is missing the entry", function()
        local action = SkipBlindAction.build(fake_G_after_skip{
            P_BLINDS = {},  -- no name lookups available
        }, Serializer)
        assert.are.equal("bl_big", action.blind_key)
        assert.are.equal("bl_big", action.blind_name)
    end)

    it("never records Boss as the skipped slot", function()
        -- Sanity: even if the engine somehow marks Boss as Skipped (it
        -- never should), we don't report a Boss-skipped action.
        local action = SkipBlindAction.build(fake_G_after_skip{
            blind_states = { Small = "Defeated", Big = "Defeated", Boss = "Skipped" },
        }, Serializer)
        assert.are.equal(Serializer.null, action.blind_slot)
        assert.are.equal(Serializer.null, action.blind_key)
    end)

    it("returns the second-skipped slot when already_emitted blocks the first", function()
        -- After Small was skipped and emitted, blind_states has Small=Skipped.
        -- When the player then skips Big, blind_states has BOTH Small=Skipped
        -- and Big=Skipped. Without the already_emitted parameter, the resolver
        -- might return Small in hash-iteration order. Passing Small in
        -- already_emitted forces it to find Big.
        local G = fake_G_after_skip{
            blind_states = { Small = "Skipped", Big = "Skipped", Boss = "Upcoming" },
            blind_on_deck = "Boss",
            tags = {
                { key = "tag_coupon", name = "Coupon Tag" },
                { key = "tag_investment", name = "Investment Tag" },
            },
        }
        local action = SkipBlindAction.build(G, Serializer, { small = true })
        assert.are.equal("big", action.blind_slot)
        assert.are.equal("bl_big", action.blind_key)
        assert.are.equal("Investment Tag", action.tag_name)
    end)

    it("returns nil when all skipped slots are already emitted", function()
        local G = fake_G_after_skip{
            blind_states = { Small = "Skipped", Big = "Skipped", Boss = "Upcoming" },
        }
        local action = SkipBlindAction.build(G, Serializer, { small = true, big = true })
        assert.are.equal(Serializer.null, action.blind_slot)
    end)

    it("emits null sentinels when game state is empty", function()
        local action = SkipBlindAction.build({}, Serializer)
        assert.are.equal("skip_blind_tag", action.type)
        assert.are.equal(Serializer.null,  action.blind_slot)
        assert.are.equal(Serializer.null,  action.blind_key)
        assert.are.equal(Serializer.null,  action.blind_name)
        assert.are.equal(Serializer.null,  action.tag_id)
        assert.are.equal(Serializer.null,  action.tag_name)
        assert.are.equal(Serializer.null,  action.next_blind_slot)
    end)

    it("emits null sentinels when nil is passed", function()
        local action = SkipBlindAction.build(nil, Serializer)
        assert.are.equal("skip_blind_tag", action.type)
        assert.are.equal(Serializer.null,  action.blind_slot)
    end)

    it("works without a serializer (returns nil for unknown fields)", function()
        -- Defensive: if someone calls without injecting Serializer, we
        -- still produce a valid payload (with nil instead of NULL).
        local action = SkipBlindAction.build(nil, nil)
        assert.are.equal("skip_blind_tag", action.type)
        assert.is_nil(action.blind_slot)
    end)
end)
