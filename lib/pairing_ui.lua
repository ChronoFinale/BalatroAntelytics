--- pairing_ui.lua
--- Thin UI shell for the "Link account" pairing flow. All decision logic
--- lives in lib/pairing.lua (pure core + shell); this file only builds and
--- wires the Steamodded mod config tab — no branching beyond "which nodes
--- to show for the current state".
---
--- Steamodded calls the config_tab function fresh every time the player
--- opens the mod's UI or re-selects the Config tab (G.FUNCS.change_tab
--- re-invokes tab_definition_function — see smods ui.lua), so the
--- unlinked / pending / linked structural branch below is decided at that
--- moment. There is no separate "re-render the tab" API — live text
--- updates WITHIN one open tab instead come from binding text nodes to
--- `pairing.display` via `config.ref_table`: Steamodded polls a bound
--- ref_table every frame and recalculates the text when its string length
--- changes (see lib/pairing.lua's docs on `display`).
---
--- The same live-updating-text trick covers "Antelytics Live" auth-failure
--- visibility: a permanently-present row is bound to
--- `live_publisher.display.status_text` (empty string while sending is
--- healthy, "Publishing unauthorized — relink your account" once a 401/403
--- halts it — see lib/live_publisher.lua). It must stay unconditionally in
--- the node tree (never added/removed based on halted-or-not) for the same
--- reason: there is no way to change the structure of an already-open tab.
---
--- Public API:
---   PairingUI.register_funcs(pairing)                          -- wires G.FUNCS.antelytics_*
---   PairingUI.make_config_tab(pairing, config, live_publisher)  -- returns a config_tab function

local PairingUI = {}

--- Register the button handlers this tab's buttons dispatch to. G.FUNCS is
--- a single GLOBAL table shared by every mod (Steamodded does not namespace
--- it per mod — see UIBox_button/button_callbacks.lua), so every key here
--- is prefixed `antelytics_` per this mod's manifest prefix.
--- @param pairing table  a lib.pairing Pairing instance
function PairingUI.register_funcs(pairing)
    G.FUNCS.antelytics_start_link = function(_e)
        pairing:start_link()
    end
    G.FUNCS.antelytics_unlink = function(_e)
        pairing:unlink()
    end
end

--- Always-present row for the "Antelytics Live" publish auth status
--- (empty/blank while healthy — see module docs above on why this can't be
--- conditionally added/removed).
--- @param display table  a live_publisher.display table (has status_text)
local function publish_status_row(display)
    return {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.05 },
        nodes = {
            { n = G.UIT.T, config = { ref_table = display, ref_value = "status_text", scale = 0.35, colour = G.C.RED } },
        },
    }
end

local function title_row(text)
    return {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.1 },
        nodes = {
            { n = G.UIT.T, config = { text = text, scale = 0.5, colour = G.C.UI.TEXT_LIGHT } },
        },
    }
end

--- The live-updating status/code block. Bound directly to `pairing.display`
--- (plain string fields, never nil) so "Waiting for approval...", the
--- user_code, and the eventual "Linked as X" all update without the tab
--- needing to be rebuilt.
--- The code + status lines.
---
--- Returns a ROW, not a column. Balatro's UI nests row -> column -> row, and
--- this block sits among G.UIT.R siblings — returning a bare G.UIT.C there put
--- the text in the wrong place on screen. The column now lives INSIDE a row, so
--- the alternation holds.
local function status_block(pairing)
    return {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.05 },
        nodes = {
            {
                n = G.UIT.C,
                config = { align = "cm" },
                nodes = {
                    {
                        n = G.UIT.R,
                        config = { align = "cm" },
                        nodes = {
                            { n = G.UIT.T, config = { ref_table = pairing.display, ref_value = "user_code", scale = 0.8, colour = G.C.WHITE } },
                        },
                    },
                    {
                        n = G.UIT.R,
                        config = { align = "cm" },
                        nodes = {
                            { n = G.UIT.T, config = { ref_table = pairing.display, ref_value = "status_text", scale = 0.4, colour = G.C.UI.TEXT_LIGHT } },
                        },
                    },
                },
            },
        },
    }
end

--- Build the config_tab function. Reads `pairing`/`config` fresh every time
--- it's called (see module docs above) — never called directly by this
--- file, only handed to `mod.config_tab`.
--- @param pairing table         a lib.pairing Pairing instance
--- @param config  table         the mod.config table (reads linked_user/live_enabled)
--- @param live_publisher table|nil  a lib.live_publisher LivePublisher instance;
---                                   its auth-halt status is shown and its halt
---                                   is cleared when the player retoggles
---                                   "Live publishing". Optional so callers
---                                   that don't wire live publishing at all
---                                   still get a working tab.
--- @return fun(): table  a Steamodded config_tab function
function PairingUI.make_config_tab(pairing, config, live_publisher)
    local publish_display = (live_publisher and live_publisher.display) or { status_text = "" }

    --- Toggling "Live publishing" off/on is one of the two player-driven
    --- ways to resume sending after an auth-failure halt (the other is
    --- relinking — see lib/pairing.lua's on_relink). Fires on every toggle
    --- click, not just off->on: harmless when already clear, and simpler
    --- than tracking the previous value to detect the on-edge specifically.
    local function on_publishing_toggle()
        pairing.save_config()
        if live_publisher then
            live_publisher:reset_auth_state()
        end
    end

    return function()
        local link_nodes

        if pairing:is_pending() then
            link_nodes = { status_block(pairing) }
        elseif type(config.linked_user) == "string" and config.linked_user ~= "" then
            link_nodes = {
                status_block(pairing),
                {
                    n = G.UIT.R,
                    config = { align = "cm", padding = 0.1 },
                    nodes = {
                        UIBox_button({
                            button = "antelytics_unlink",
                            label  = { "Unlink" },
                            colour = G.C.RED,
                            minw   = 3,
                        }),
                    },
                },
            }
        else
            link_nodes = {
                {
                    n = G.UIT.R,
                    config = { align = "cm", padding = 0.1 },
                    nodes = {
                        UIBox_button({
                            button = "antelytics_start_link",
                            label  = { "Link account" },
                            colour = G.C.BLUE,
                            minw   = 4,
                        }),
                    },
                },
                status_block(pairing),
            }
        end

        return {
            n = G.UIT.ROOT,
            config = { r = 0.1, minw = 8, align = "tm", padding = 0.2, colour = G.C.BLACK },
            nodes = {
                title_row("Antelytics Live"),
                {
                    n = G.UIT.R,
                    config = { align = "cm", padding = 0.1 },
                    nodes = {
                        create_toggle({
                            label     = "Live publishing",
                            ref_table = config,
                            ref_value = "live_enabled",
                            callback  = on_publishing_toggle,
                        }),
                    },
                },
                publish_status_row(publish_display),
                { n = G.UIT.R, config = { minh = 0.1 } },
                {
                    n = G.UIT.R,
                    config = { align = "cm" },
                    nodes = link_nodes,
                },
            },
        }
    end
end

return PairingUI
