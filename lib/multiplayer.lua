--- multiplayer.lua
--- PvP / Multiplayer mod accessor for the Balatro Antelytics.
---
--- Public API:
---   Multiplayer.detect()    -- returns boolean: true iff the Multiplayer mod
---                              is installed (via SMODS.find_mod).
---   Multiplayer.new(opts)   -- factory returning a gated accessor object.
---
--- The accessor object exposes:
---   enabled          (boolean)   -- whether the Multiplayer mod is detected
---   is_pvp_blind()   (function)  -- true iff the current blind is a PvP blind
---   opponent_id()    (function)  -- opponent player id
---   opponent_name()  (function)  -- opponent display name
---   player_score()   (function)  -- player's running PvP score
---   opponent_score() (function)  -- opponent's running PvP score
---
--- Gating contract (Requirement 4.3):
---   When `enabled` is false, every accessor returns `nil` WITHOUT touching
---   any `Multiplayer`-namespaced global. This keeps the plugin safe when the
---   Multiplayer mod is absent — no phantom global reads, no warnings.
---
--- Read contract (Requirement 4.4):
---   When `enabled` is true, each accessor wraps its read in `pcall`. On
---   failure, the accessor returns `nil` and invokes the injected logger with
---   a field-level warning. This isolates the Antelytics from future
---   changes to the Multiplayer mod's API surface.
---
--- Dependencies are injected via `Multiplayer.new({ logger = fn })`; this
--- module does NOT use require().
---
--- Requirements: 4.1, 4.3, 4.4

local Multiplayer = {}

-- ---------------------------------------------------------------------------
-- Internal: default no-op logger. Replaced when opts.logger is provided.
-- ---------------------------------------------------------------------------
local function default_logger(_) end

-- ---------------------------------------------------------------------------
-- Internal: fetch the global `Multiplayer` table.
--
-- This module's local variable is also named `Multiplayer`, so a bare
-- reference would resolve to the module table, not the global. `rawget(_G, ...)`
-- reaches the actual global without triggering any metamethod-based read
-- counter on the Multiplayer table itself — relevant for tests that install a
-- read-counter metatable to prove the disabled path touches nothing.
-- ---------------------------------------------------------------------------
local function get_mp_global()
    -- The Multiplayer mod's runtime namespace is the global `MP`
    -- (MP = SMODS.current_mod, core.lua:1). It is NOT `_G.Multiplayer` —
    -- reading that returned nil, which is why every PvP field was null.
    -- Fall back to alternate handles defensively.
    local smods = rawget(_G, "SMODS")
    return rawget(_G, "MP")
        or rawget(_G, "Multiplayer")
        or (type(smods) == "table" and smods.Mods and smods.Mods.Multiplayer)
        or nil
end

-- A score that overflowed a double to inf/NaN is rendered in-game as the
-- string "naneinf" -- that's number_format(inf) (misc_functions.lua:956):
-- "%.3f" of inf/inf = "nan", concatenated with 'e' and tostring(inf) = "inf".
-- JSON has no inf literal and the serializer encodes non-finite numbers as
-- null, which would silently drop a maxed-out run. Substitute the string the
-- game itself shows so a ceilinged score round-trips to the viewer.
local function score_or_naneinf(v)
    if type(v) == "number" and (v ~= v or v == math.huge or v == -math.huge) then
        return "naneinf"
    end
    return v
end

-- Decode an MP enemy score, which is an INSANE_INT table
-- {coeffiocient, exponent, e_count} (the field is misspelled in the mod).
-- Returns a string (scores can exceed Lua number range). Falls back to the
-- coefficient when the converter isn't available.
local function decode_mp_score(mp, val)
    if val == nil then return nil end
    if type(val) == "number" then return score_or_naneinf(val) end
    if type(val) == "table" then
        if mp and mp.INSANE_INT and type(mp.INSANE_INT.to_string) == "function" then
            local ok, s = pcall(mp.INSANE_INT.to_string, val)
            -- to_string groups with commas ("8,106"); strip them so the stored
            -- score is a clean numeric string the viewer parses directly. (A
            -- comma'd string broke the PvP win check: Number("8,106") = NaN.)
            if ok and s ~= nil then return (tostring(s):gsub(",", "")) end
        end
        -- Fallback (to_string unavailable): the coeffiocient IS the whole value
        -- only BELOW the INSANE_INT switch point, where exponent/e_count are 0.
        -- Above it the magnitude lives in exponent/e_count and the bare
        -- coeffiocient is just a small mantissa (4.07 for a 4.07e12 score), so
        -- return nil (→ "—" in the viewer) rather than a wildly wrong number the
        -- PvP win-check would trust.
        local exp = val.exponent or 0
        local ec = val.e_count or 0
        if exp == 0 and ec == 0 then
            return val.coeffiocient or val.coefficient or nil
        end
        return nil
    end
    return nil
end

local function get_G()
    return rawget(_G, "G")
end

-- Normalize a Balatro edition value to the string the viewer uses. An edition
-- is a table like {foil=true} / {holo=true} / {polychrome=true} / {negative=true}
-- (or a bare string). Mirrors build_joker_list in capture.lua so the opponent's
-- end-game jokers carry the same edition shape as the local jokers.
local function edition_string(ed)
    if type(ed) == "string" then return ed end
    if type(ed) == "table" then
        if ed.foil then return "foil"
        elseif ed.holo then return "holographic"
        elseif ed.polychrome then return "polychrome"
        elseif ed.negative then return "negative" end
    end
    return "base"
end

-- Decode a CardArea:save() table (the structure produced by G.jokers:save() and
-- carried in the opponent's end-game jokers payload) into the same
-- {id, name, edition, slot} joker shape the rest of the capture emits. Each
-- card save stores the center key in save_fields.center (card.lua:4625) and the
-- display name in ability.name.
local function decode_joker_save(card_area_save)
    if type(card_area_save) ~= "table" then return nil end
    local cards = card_area_save.cards
    if type(cards) ~= "table" then return nil end
    local list = {}
    for i = 1, #cards do
        local c = cards[i]
        if type(c) == "table" then
            local id   = c.save_fields and c.save_fields.center
            local name = c.ability and c.ability.name
            local entry = {
                id      = id and tostring(id) or "j_unknown",
                name    = name and tostring(name) or nil,
                slot    = i,
                edition = edition_string(c.edition),
            }
            if type(c.sort_id) == "number" then entry.sort_id = c.sort_id end
            list[#list + 1] = entry
        end
    end
    return list
end
-- Exposed for unit tests; not part of the accessor contract.
Multiplayer._decode_joker_save = decode_joker_save

-- The opponent's score (MP.GAME.enemy.score) is an EASED display value: the MP
-- mod queues three vanilla "ease" events that lerp the INSANE_INT sub-fields
-- (coeffiocient/exponent/e_count) toward the new target over ~3 frames
-- (action_handlers.lua:279-316). A snapshot taken WHILE that animation is in
-- flight reads a partial value — e.g. an opponent's 99,360 final hand caught at
-- 58% reads 76,791 instead of 118,312. The round-end / game-over node fires the
-- same instant the opponent's final hand lands, so it routinely catches the
-- climb mid-flight. The un-eased target is not persisted on enemy anywhere
-- usable (highest_score is a match-wide max that over-reports per blind), BUT
-- the vanilla engine stores each ease's final target verbatim on the queued
-- Event as `ev.ease.end_val` (event.lua:31), readable before the animation
-- completes. We scan G.E_MANAGER for any pending eases targeting this exact
-- score table and substitute their end_val for the still-animating sub-fields,
-- yielding the settled total even mid-animation. Sub-fields with no pending
-- ease are already settled, so we keep their current value.
local function settled_score_table(enemy_score)
    if type(enemy_score) ~= "table" then return enemy_score end
    local G = get_G()
    local em = G and G.E_MANAGER
    local queues = em and em.queues
    if type(queues) ~= "table" then return enemy_score end

    -- Start from a shallow copy of the live (eased) sub-fields; overwrite any
    -- that have a pending ease with the authoritative target.
    local target = {
        coeffiocient = enemy_score.coeffiocient,
        exponent     = enemy_score.exponent,
        e_count      = enemy_score.e_count,
    }
    local found = false
    for _, queue in pairs(queues) do
        if type(queue) == "table" then
            for _, ev in ipairs(queue) do
                if type(ev) == "table" and ev.trigger == "ease" and type(ev.ease) == "table"
                    and ev.ease.ref_table == enemy_score then
                    local field = ev.ease.ref_value
                    if field ~= nil and ev.ease.end_val ~= nil and target[field] ~= nil then
                        -- MP's ease func is math.floor; end_val is already an
                        -- integer, so floor is a no-op. Apply func when present
                        -- to match exactly what the table will settle to.
                        local v = ev.ease.end_val
                        if type(ev.func) == "function" then
                            local ok, fv = pcall(ev.func, v)
                            if ok and fv ~= nil then v = fv end
                        end
                        -- Last ease wins per field. The three sub-field eases for
                        -- one enemyInfo are queued together (in order), so
                        -- overwriting as we iterate yields the MOST RECENT target
                        -- triple intact. NOTE: do NOT take a per-field max here.
                        -- Above the INSANE_INT switch point a larger total has a
                        -- SMALLER coeffiocient (magnitude carries in exponent/
                        -- e_count), so max-per-field would staple the old large
                        -- coeffiocient onto the new large exponent and fabricate a
                        -- score that never existed. Most-recent-wins keeps the
                        -- triple consistent at any magnitude.
                        target[field] = v
                        found = true
                    end
                end
            end
        end
    end
    if not found then return enemy_score end
    return target
end

-- ---------------------------------------------------------------------------
-- Public: detection probe (Requirement 4.1)
-- ---------------------------------------------------------------------------

--- Check whether the Multiplayer mod is installed by probing
--- `SMODS.find_mod("Multiplayer")`. Steamodded's `find_mod` returns an array
--- of matching mods; we treat any non-empty array as "installed".
---
--- Absent / malformed SMODS globals and runtime errors from `find_mod` all
--- coerce to `false` so this probe can never crash the plugin init path.
---
--- @return boolean true when the Multiplayer mod is present
function Multiplayer.detect()
    local smods = rawget(_G, "SMODS")
    if type(smods) ~= "table" or type(smods.find_mod) ~= "function" then
        return false
    end
    local ok, result = pcall(smods.find_mod, "Multiplayer")
    if not ok or result == nil then
        return false
    end
    if type(result) == "table" then
        return #result > 0
    end
    -- Defensive fallback for any other truthy return value.
    return result and true or false
end

-- ---------------------------------------------------------------------------
-- Public: accessor factory
-- ---------------------------------------------------------------------------

--- Build a gated accessor object over the Multiplayer mod's state.
---
--- @param opts table|nil  Optional dependencies:
---   - logger       function(msg): called on accessor read failures; defaults
---                  to a no-op.
---   - pvp_enabled  boolean: forces the `enabled` flag. When omitted, defaults
---                  to `Multiplayer.detect()`. Exposed primarily for tests.
--- @return table  Accessor with fields:
---   enabled, is_pvp_blind, opponent_id, opponent_name, player_score,
---   opponent_score.
function Multiplayer.new(opts)
    opts = opts or {}
    local logger = (type(opts.logger) == "function") and opts.logger or default_logger

    local enabled
    if opts.pvp_enabled ~= nil then
        enabled = opts.pvp_enabled and true or false
    else
        enabled = Multiplayer.detect()
    end

    --- Build a gated accessor for a single Multiplayer field.
    --- Returns a closure that:
    ---   1. Short-circuits to nil (zero global reads) when `enabled` is false.
    ---   2. Checks that the Multiplayer global actually exists (it may only
    ---      be populated during PvP matches even when the mod is installed).
    ---   3. Otherwise invokes `reader()` under pcall.
    ---   4. On pcall failure or missing global, returns nil (no warning for
    ---      missing global — that's normal when not in a PvP match).
    --- @param field_name string  Human-readable field name used in warnings.
    --- @param reader     function Zero-argument reader that returns the value.
    --- @return function   A zero-argument accessor.
    local function make_accessor(field_name, reader)
        return function()
            if not enabled then
                return nil
            end
            -- The Multiplayer global only exists during PvP matches.
            -- Don't warn when it's absent — that's the normal non-PvP case.
            local mp = get_mp_global()
            if not mp then
                return nil
            end
            local ok, result = pcall(reader)
            if not ok then
                logger(
                    "Multiplayer field '" .. tostring(field_name) ..
                    "' unavailable: " .. tostring(result)
                )
                return nil
            end
            return result
        end
    end

    return {
        enabled = enabled,

        is_pvp_blind = make_accessor("is_pvp_blind", function()
            local mp = get_mp_global()
            -- Prefer the mod's own predicate (objects/blinds/nemesis.lua).
            if mp and type(mp.is_pvp_boss) == "function" then
                local ok, r = pcall(mp.is_pvp_boss)
                if ok then return r and true or false end
            end
            -- Fallback: read the blind key / pvp flag off G directly.
            local G = get_G()
            local blind = G and G.GAME and G.GAME.blind
            if not blind then return false end
            local key = blind.config and blind.config.blind and blind.config.blind.key
            return (key == "bl_mp_nemesis") or (blind.pvp and true or false)
        end),

        -- No numeric peer id exists in 0.3.3 — opponents are keyed by username.
        opponent_id = make_accessor("opponent_id", function()
            local mp = get_mp_global()
            local L = mp and mp.LOBBY
            if not L then return nil end
            local opp = L.is_host and L.guest or L.host
            return opp and opp.username or nil
        end),

        opponent_name = make_accessor("opponent_name", function()
            local mp = get_mp_global()
            local L = mp and mp.LOBBY
            if not L then return nil end
            local opp = L.is_host and L.guest or L.host
            return opp and opp.username or nil
        end),

        -- My running score this blind is the vanilla engine total, not an
        -- MP field (MP doesn't mirror the local score).
        player_score = make_accessor("player_score", function()
            local G = get_G()
            return score_or_naneinf(G and G.GAME and G.GAME.chips)
        end),

        -- Opponent's CURRENT-blind score. Use enemy.score, NOT highest_score:
        -- highest_score is the opponent's ALL-TIME max across the match, so it
        -- over-reports a blind where they scored less than a prior peak (e.g.
        -- it showed 29.6M for a 6,307 blind). Verified against the MP log
        -- parser: enemy.score matches the per-blind totals exactly.
        --
        -- enemy.score EASES toward each new total over a few frames. We used to
        -- assume snapshots landed after the animation settled, but the round-end
        -- / game-over node fires the same instant the opponent's final hand
        -- lands, so a big final hand was captured mid-climb (118,312 read as
        -- 76,791). settled_score_table() substitutes the ease target so we
        -- always read the settled total regardless of animation state.
        opponent_score = make_accessor("opponent_score", function()
            local mp = get_mp_global()
            local e = mp and mp.GAME and mp.GAME.enemy
            if not e then return nil end
            return decode_mp_score(mp, settled_score_table(e.score))
        end),

        player_lives = make_accessor("player_lives", function()
            local mp = get_mp_global()
            return mp.GAME and mp.GAME.lives
        end),

        opponent_lives = make_accessor("opponent_lives", function()
            local mp = get_mp_global()
            return mp.GAME and mp.GAME.enemy and mp.GAME.enemy.lives
        end),

        -- Opponent's settled score this PvP blind. Same source as
        -- opponent_score; resolves the ease target so the round-end win/loss
        -- comparison (main.lua) sees the true total, not a mid-animation frame.
        opponent_hand_score = make_accessor("opponent_hand_score", function()
            local mp = get_mp_global()
            local e = mp and mp.GAME and mp.GAME.enemy
            if not e then return nil end
            return decode_mp_score(mp, settled_score_table(e.score))
        end),

        -- Opponent's hands remaining this PvP blind
        opponent_hands_left = make_accessor("opponent_hands_left", function()
            local mp = get_mp_global()
            return mp.GAME and mp.GAME.enemy and mp.GAME.enemy.hands
        end),

        -- The ante at which PvP/nemesis blinds begin (default 2). Lets the
        -- viewer label "Nth PvP Blind" = current_ante - pvp_start_round + 1.
        pvp_start_round = make_accessor("pvp_start_round", function()
            local mp = get_mp_global()
            return mp.LOBBY and mp.LOBBY.config and mp.LOBBY.config.pvp_start_round
        end),

        -- Shared lobby/room code (MP.LOBBY.code, action_handlers.lua:78). Both
        -- clients in a match see the SAME code, so it's the join key for merging
        -- two players' run files into one per-hand PvP view — and unlike the run
        -- seed it survives `different_seeds=true` (different_seeds gives the two
        -- clients DIFFERENT seeds, so state.seed alone can't join them then).
        -- Capture it live on every node: the mod clears LOBBY.code to nil on
        -- game-end/leave (functions.lua:150), so a post-run read would miss it.
        -- The viewer joins on (lobby_code, seed) and aligns the Nth nemesis blind
        -- in each file by node order — the ordinal is derivable by walk, so it's
        -- not captured here.
        lobby_code = make_accessor("lobby_code", function()
            local mp = get_mp_global()
            return mp.LOBBY and mp.LOBBY.code
        end),

        -- Opponent's per-shop spending array (set by spentLastShop network messages)
        opponent_shop_spending = make_accessor("opponent_shop_spending", function()
            local mp = get_mp_global()
            return mp.GAME and mp.GAME.enemy and mp.GAME.enemy.spent_in_shop
        end),

        -- Opponent's FINAL jokers — knowable only after the match-end pull lands.
        -- When our end screen opens, the mod requests the opponent's build and
        -- stores the reply in MP.end_game_jokers_payload (a base64/gzip/STR_PACK
        -- CardArea save; receiveEndGameJokers, action_handlers.lua:774). We decode
        -- it with the mod's own helper. Returns nil until the payload arrives (the
        -- caller polls), or an empty list when the opponent held no jokers (the
        -- mod sends keys={} in that case).
        opponent_end_game_jokers = make_accessor("opponent_end_game_jokers", function()
            local mp = get_mp_global()
            local payload = mp and mp.end_game_jokers_payload
            -- keys = {} (a table) is the explicit "no jokers" reply.
            if type(payload) == "table" then return {} end
            if type(payload) ~= "string" or payload == "" then return nil end
            local utils = mp.UTILS
            if not (utils and type(utils.str_decode_and_unpack) == "function") then
                return nil
            end
            local ok, save = pcall(utils.str_decode_and_unpack, payload)
            if not ok or type(save) ~= "table" then return nil end
            return decode_joker_save(save)
        end),

        -- Opponent's total joker sells
        opponent_sells = make_accessor("opponent_sells", function()
            local mp = get_mp_global()
            return mp.GAME and mp.GAME.enemy and mp.GAME.enemy.sells
        end),

        -- Your reroll stats as tracked by the Multiplayer mod
        player_reroll_count = make_accessor("player_reroll_count", function()
            local mp = get_mp_global()
            return mp.GAME and mp.GAME.stats and mp.GAME.stats.reroll_count
        end),

        player_reroll_cost_total = make_accessor("player_reroll_cost_total", function()
            local mp = get_mp_global()
            return mp.GAME and mp.GAME.stats and mp.GAME.stats.reroll_cost_total
        end),

        -- Lobby config (ruleset, stake, lives, modifiers)
        lobby_config = make_accessor("lobby_config", function()
            local mp = get_mp_global()
            if not mp or not mp.LOBBY or not mp.LOBBY.config then return nil end
            local cfg = mp.LOBBY.config
            return {
                ruleset       = cfg.ruleset,
                gamemode      = cfg.gamemode,
                stake         = cfg.stake,
                starting_lives = cfg.starting_lives,
                gold_on_life_loss    = cfg.gold_on_life_loss,
                death_on_round_loss  = cfg.death_on_round_loss,
                no_gold_on_round_loss = cfg.no_gold_on_round_loss,
                different_decks = cfg.different_decks,
                different_seeds = cfg.different_seeds,
                timer           = cfg.timer,
                timer_base_seconds = cfg.timer_base_seconds,
                pvp_start_round = cfg.pvp_start_round,
            }
        end),
    }
end

return Multiplayer
