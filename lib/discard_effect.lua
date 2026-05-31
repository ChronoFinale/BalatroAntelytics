--- discard_effect.lua
--- Predicts the money delta that joker effects will apply to the player's
--- wallet when a discard fires. Mirrors the shape and conventions of
--- `lib/consumable_effect.lua`.
---
--- The capture pipeline snapshots `state.money` BEFORE Balatro's deferred
--- ease_dollars events fire (the same way it does for consumables), so the
--- viewer can't reconstruct the discard payout from `state.money` alone —
--- the next node is typically `play_hand` with its own joker scoring and
--- money flux. This module reads already-described discarded cards plus
--- the joker list and current_round metadata to predict the delta
--- deterministically, so the discard hook can attach `expected_money_delta`
--- and `money_breakdown` to the action.
---
--- Pure module: takes already-described cards and a plain joker list,
--- never reads `G` directly. This makes it unit-testable without a `G`
--- mock (matching `consumable_effect.lua`'s pattern).
---
--- Three jokers contribute to the prediction:
---   - Mail-In Rebate: $5 per discarded card whose rank matches
---     `current_round.mail_card.id`.
---   - Faceless Joker: $5 when 3 or more discarded cards are face cards.
---     Pareidolia in the joker list makes every card count as a face.
---   - Trading Card: $3 when this is the first discard of the round AND
---     exactly one card is being discarded.
---
--- Out of scope: chip/mult prediction (Castle, Green Joker, Hit the Road,
--- Ramen). Those mutate joker internal state but don't affect money — see
--- the future "scaling capture" spec.
---
--- Public API:
---   DiscardEffect.predict_money_delta(discarded_descriptors, jokers, current_round)
---     -> { total = N, breakdown = { { joker = "...", amount = N }, ... } }
---     or  nil  when NONE of Mail-In Rebate, Faceless Joker, or Trading
---              Card is in `jokers` (distinguishes "didn't predict" from
---              "predicted zero").

local DiscardEffect = {}

-- ---------------------------------------------------------------------------
-- Joker name constants — keep typos out of comparisons
-- ---------------------------------------------------------------------------

local JOKER_MAIL_IN_REBATE = "Mail-In Rebate"
local JOKER_FACELESS       = "Faceless Joker"
local JOKER_TRADING_CARD   = "Trading Card"
local JOKER_PAREIDOLIA     = "Pareidolia"

-- Ranks Balatro treats as face cards (J/Q/K). Pareidolia overrides this
-- by making every card count as a face — see `is_face_card` below.
local FACE_RANK_IDS = {
    J = true,
    Q = true,
    K = true,
}

-- The set of jokers whose presence makes the predictor return a structure
-- (rather than nil). If none of these are held, the predictor abstains.
local RELEVANT_JOKER_NAMES = {
    [JOKER_MAIL_IN_REBATE] = true,
    [JOKER_FACELESS]       = true,
    [JOKER_TRADING_CARD]   = true,
}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Look up a joker in `jokers` by its `ability.name`. Returns the joker
--- table when found, nil otherwise.
local function find_joker_by_name(jokers, name)
    if type(jokers) ~= "table" then return nil end
    for _, joker in ipairs(jokers) do
        if type(joker) == "table"
            and type(joker.ability) == "table"
            and joker.ability.name == name
        then
            return joker
        end
    end
    return nil
end

--- True when at least one of the three relevant discard-money jokers is in
--- `jokers`. Used to gate "return nil" vs "return structure".
local function has_any_relevant_joker(jokers)
    if type(jokers) ~= "table" then return false end
    for _, joker in ipairs(jokers) do
        if type(joker) == "table"
            and type(joker.ability) == "table"
            and RELEVANT_JOKER_NAMES[joker.ability.name]
        then
            return true
        end
    end
    return false
end

--- Count discarded descriptors whose rank `id` matches the mail card's
--- target rank `id`. Mail-In Rebate pays $5 per match.
---
--- Type bridging: `card.base.id` is a Lua number (2..14) at the engine
--- layer, so `current_round.mail_card.id` is also numeric. Our captured
--- descriptors stringify ids via `tostring(card.base.id)` for JSON-shape
--- consistency. Compare both sides as strings so a numeric mail rank
--- still matches the stringified descriptor rank.
local function count_mail_rank_matches(discarded_descriptors, mail_rank_id)
    if mail_rank_id == nil then return 0 end
    if type(discarded_descriptors) ~= "table" then return 0 end
    local mail_rank_str = tostring(mail_rank_id)
    local matches = 0
    for _, descriptor in ipairs(discarded_descriptors) do
        if type(descriptor) == "table"
            and tostring(descriptor.id) == mail_rank_str
        then
            matches = matches + 1
        end
    end
    return matches
end

--- Compute Mail-In Rebate's contribution. Returns `(amount, count)` where
--- `amount` is the dollars predicted ($5 × count) and `count` is the number
--- of matching discards. Returns `(0, 0)` when Mail-In Rebate is not held.
local function mail_in_rebate_contribution(jokers, discarded_descriptors, current_round)
    if not find_joker_by_name(jokers, JOKER_MAIL_IN_REBATE) then
        return 0, 0
    end
    local mail_rank_id = nil
    if type(current_round) == "table"
        and type(current_round.mail_card) == "table"
    then
        mail_rank_id = current_round.mail_card.id
    end
    local matches = count_mail_rank_matches(discarded_descriptors, mail_rank_id)
    return 5 * matches, matches
end

--- True when `descriptor` should count as a face card for Faceless Joker.
--- Pareidolia in `jokers` overrides per-rank face status and makes every
--- card count as a face. Otherwise only J/Q/K ranks count.
---
--- We deliberately do NOT trust `descriptor.is_face` here because the
--- Pareidolia override comes from the joker list, not the descriptor —
--- the discard hook stamps `is_face` based on rank alone, and a unit
--- caller might pass descriptors built without Pareidolia awareness.
local function is_face_card(descriptor, jokers)
    if type(descriptor) ~= "table" then return false end
    if find_joker_by_name(jokers, JOKER_PAREIDOLIA) then
        return true
    end
    return FACE_RANK_IDS[descriptor.id] == true
end

--- Count face cards in `discarded_descriptors`, applying the Pareidolia
--- override when it is present in `jokers`.
local function count_face_cards(discarded_descriptors, jokers)
    if type(discarded_descriptors) ~= "table" then return 0 end
    local face_count = 0
    for _, descriptor in ipairs(discarded_descriptors) do
        if is_face_card(descriptor, jokers) then
            face_count = face_count + 1
        end
    end
    return face_count
end

--- Compute Faceless Joker's contribution. Pays a flat $5 when Faceless
--- Joker is held AND at least 3 face cards are in `discarded_descriptors`
--- (with Pareidolia override applied). Returns `0` otherwise.
local function faceless_joker_contribution(jokers, discarded_descriptors)
    if not find_joker_by_name(jokers, JOKER_FACELESS) then
        return 0
    end
    local face_count = count_face_cards(discarded_descriptors, jokers)
    if face_count >= 3 then
        return 5
    end
    return 0
end

--- Derive the number of discards the player has already consumed this
--- round, BEFORE the current discard fires. Trading Card only triggers
--- when this value is exactly 0 (i.e. the in-flight discard is the first
--- one of the round).
---
--- Strategy:
---   1. Prefer `current_round.discards_used` when present and numeric —
---      this is the field the discard hook stamps directly when it
---      mocks Balatro's per-round counters.
---   2. Otherwise, derive from `starting_discards - discards_left - 1`
---      when both are present and numeric. The `-1` accounts for this
---      discard not yet being consumed at hook time (Balatro decrements
---      `discards_left` after the calculate context fires).
---   3. Otherwise return nil — the predictor treats unknown discard
---      count as "can't fire safely" and Trading Card abstains.
local function derive_discards_used(current_round)
    if type(current_round) ~= "table" then return nil end
    if type(current_round.discards_used) == "number" then
        return current_round.discards_used
    end
    if type(current_round.starting_discards) == "number"
        and type(current_round.discards_left) == "number"
    then
        return current_round.starting_discards
            - current_round.discards_left
            - 1
    end
    return nil
end

--- Compute Trading Card's contribution. Pays a flat $3 when ALL of:
---   - Trading Card is held in `jokers`
---   - This is the first discard of the round (`discards_used == 0`)
---   - Exactly one card is being discarded (`#discarded_descriptors == 1`)
---
--- Returns `0` otherwise. Trading Card abstains when the discard count
--- is unknown (`derive_discards_used` returns nil) — Balatro's actual
--- rule requires "first discard of round", so without that signal we
--- can't fire safely.
local function trading_card_contribution(jokers, discarded_descriptors, current_round)
    if not find_joker_by_name(jokers, JOKER_TRADING_CARD) then
        return 0
    end
    local discards_used = derive_discards_used(current_round)
    if discards_used ~= 0 then
        return 0
    end
    if type(discarded_descriptors) ~= "table" then return 0 end
    if #discarded_descriptors ~= 1 then
        return 0
    end
    return 3
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Predict the wallet change the discard hook should attach to the
--- discard action's `expected_money_delta`. Pure function: never mutates
--- inputs, never reads `G`.
---
--- @param discarded_descriptors table  Array of `Capture.describe_playing_card`-shaped
---                                     entries with `id` (rank) and `is_face` set.
--- @param jokers table                  Array of joker objects with `ability.name`.
--- @param current_round table           Table with `mail_card.id` (mail rank) and
---                                     `discards_used` (count consumed before this
---                                     discard).
--- @return table|nil                    `{ total, breakdown }` when at least one of
---                                     Mail-In Rebate, Faceless Joker, or Trading
---                                     Card is held; `nil` otherwise.
function DiscardEffect.predict_money_delta(discarded_descriptors, jokers, current_round)
    -- Gate: when none of the three relevant jokers are held, abstain
    -- entirely. Returning nil tells the discard hook not to attach
    -- `expected_money_delta` / `money_breakdown` at all.
    if not has_any_relevant_joker(jokers) then
        return nil
    end

    local total = 0
    local breakdown = {}

    -- Mail-In Rebate: $5 per discarded card matching the round's mail rank.
    local mail_amount, _mail_matches = mail_in_rebate_contribution(
        jokers, discarded_descriptors, current_round
    )
    if mail_amount > 0 then
        total = total + mail_amount
        breakdown[#breakdown + 1] = {
            joker  = JOKER_MAIL_IN_REBATE,
            amount = mail_amount,
        }
    end

    -- Faceless Joker: $5 when 3+ face cards are discarded (Pareidolia
    -- in `jokers` makes every card count as a face).
    local faceless_amount = faceless_joker_contribution(
        jokers, discarded_descriptors
    )
    if faceless_amount > 0 then
        total = total + faceless_amount
        breakdown[#breakdown + 1] = {
            joker  = JOKER_FACELESS,
            amount = faceless_amount,
        }
    end

    -- Trading Card: $3 on the first single-card discard of the round.
    local trading_amount = trading_card_contribution(
        jokers, discarded_descriptors, current_round
    )
    if trading_amount > 0 then
        total = total + trading_amount
        breakdown[#breakdown + 1] = {
            joker  = JOKER_TRADING_CARD,
            amount = trading_amount,
        }
    end

    return { total = total, breakdown = breakdown }
end

return DiscardEffect
