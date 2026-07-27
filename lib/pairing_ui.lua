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
--- Public API:
---   PairingUI.register_funcs(pairing)          -- wires G.FUNCS.antelytics_*
---   PairingUI.make_config_tab(pairing, config)  -- returns a config_tab function

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
--- @param pairing table  a lib.pairing Pairing instance
--- @param config  table  the mod.config table (reads linked_user/live_enabled)
--- @return fun(): table  a Steamodded config_tab function
function PairingUI.make_config_tab(pairing, config)
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
                            callback  = pairing.save_config,
                        }),
                    },
                },
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
