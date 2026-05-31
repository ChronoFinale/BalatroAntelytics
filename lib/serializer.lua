--- serializer.lua
--- Pure-Lua JSON encoder for the Balatro Antelytics.
---
--- Public API:
---   Serializer.encode(value)  -> string   (JSON text)
---   Serializer.decode(text)   -> value    (Lua value)
---
--- Encoding rules:
---   nil                  -> "null"
---   boolean              -> "true" / "false"
---   number               -> JSON number literal (integers without decimal point)
---   string               -> JSON string with proper escape sequences
---   table (array)        -> JSON array   (integer keys 1..#t, no gaps)
---   table (object)       -> JSON object  (string keys)
---   circular reference   -> "null"  (error logged via Serializer._log_error)
---
--- Requirements: 3.3, 3.4, 3.8

local Serializer = {}

-- ---------------------------------------------------------------------------
-- Null sentinel.  In Lua, assigning nil to a table key removes it.  To
-- preserve JSON null values during round-trip (Requirement 3.8), the decoder
-- stores this unique sentinel table in place of nil.  The encoder recognizes
-- it and emits "null".
--
-- Usage:
--   local json = Serializer.encode({ boss_blind_effect = Serializer.null })
--   --> {"boss_blind_effect":null}
--
--   local t = Serializer.decode('{"boss_blind_effect":null}')
--   assert(t.boss_blind_effect == Serializer.null)
-- ---------------------------------------------------------------------------
Serializer.null = setmetatable({}, { __tostring = function() return "null" end })

-- ---------------------------------------------------------------------------
-- Error logging hook.  Replace this in tests or at runtime to redirect output.
-- In the live plugin this is overwritten by logger.lua after both modules load.
-- ---------------------------------------------------------------------------
Serializer._log_error = function(msg)
    -- Default: print to stderr-equivalent.  The plugin entry point replaces
    -- this with the session-log writer once logger.lua is loaded.
    if type(print) == "function" then
        print("[Serializer ERROR] " .. tostring(msg))
    end
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Escape a raw string value into a JSON string literal (including the
--- surrounding double-quote characters).
local function encode_string(s)
    -- Replace each character that must be escaped in JSON. `%c` matches all
    -- control characters (0x00-0x1F and 0x7F) — the same set as the old
    -- `%z\1-\31\127` but WITHOUT the version-specific `%z` (which only matches
    -- NUL on Lua 5.1/LuaJIT; on 5.2+ it's a literal 'z'). Using %c keeps the
    -- encoder correct on every Lua version (runtime LuaJIT and CI's PUC Lua).
    local result = s:gsub('[\\"/%c]', function(c)
        local escapes = {
            ['"']  = '\\"',
            ['\\'] = '\\\\',
            ['/']  = '\\/',   -- optional but harmless
            ['\b'] = '\\b',
            ['\f'] = '\\f',
            ['\n'] = '\\n',
            ['\r'] = '\\r',
            ['\t'] = '\\t',
        }
        if escapes[c] then
            return escapes[c]
        end
        -- Other control characters -> \uXXXX
        return string.format('\\u%04x', c:byte())
    end)
    return '"' .. result .. '"'
end

--- Decide whether a table should be encoded as a JSON array.
--- A table is an array when:
---   - It is non-empty, AND
---   - Its only keys are consecutive integers starting at 1 with no gaps.
--- An empty table {} is treated as an empty JSON array [] for round-trip
--- compatibility (Lua has no way to distinguish {} from an empty array).
local function is_array(t)
    local max_index = 0
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
            return false
        end
        if k > max_index then max_index = k end
        count = count + 1
    end
    -- All keys are positive integers; check for gaps.
    return max_index == count
end

--- Core recursive encoder.
--- @param value   any          The Lua value to encode.
--- @param seen    table        Set of table addresses currently on the stack
---                             (used for circular-reference detection).
--- @return string              JSON text.
local function encode_value(value, seen)
    local t = type(value)

    if value == nil or value == Serializer.null then
        return "null"

    elseif t == "boolean" then
        return value and "true" or "false"

    elseif t == "number" then
        if value ~= value then          -- NaN
            return "null"
        elseif value == math.huge or value == -math.huge then
            return "null"
        elseif value == math.floor(value) and math.abs(value) < 1e15 then
            -- Encode as integer (no trailing ".0"). Use %.0f, NOT %d: under
            -- LuaJIT (LÖVE) string.format("%d", n) coerces through a 32-bit C
            -- int, so any integer above 2^31 wraps -- e.g. a 23,727,296,856
            -- PvP score was stored as -2,042,506,920. %.0f formats straight
            -- from the double and is exact for all integers below the 1e15
            -- guard (< 2^53), with no trailing decimal point.
            return string.format("%.0f", value)
        else
            -- Use enough precision to survive a round-trip.
            return string.format("%.17g", value)
        end

    elseif t == "string" then
        return encode_string(value)

    elseif t == "table" then
        -- Circular reference detection
        local addr = tostring(value)  -- unique per table in Lua 5.1+
        if seen[addr] then
            Serializer._log_error(
                "Circular reference detected at table " .. addr .. "; substituting null"
            )
            return "null"
        end
        seen[addr] = true

        local result
        if is_array(value) then
            -- JSON array
            local parts = {}
            for i = 1, #value do
                parts[i] = encode_value(value[i], seen)
            end
            result = "[" .. table.concat(parts, ",") .. "]"
        else
            -- JSON object — sort keys for deterministic output.
            -- We store both the string representation (for sorting/output)
            -- and the original key (for table lookup).
            local entries = {}  -- { {str_key, orig_key}, ... }
            for k in pairs(value) do
                if type(k) == "string" then
                    entries[#entries + 1] = { k, k }
                elseif type(k) == "number" then
                    -- Mixed or non-sequential integer keys: treat as object
                    entries[#entries + 1] = { tostring(k), k }
                end
                -- Non-string, non-number keys are silently dropped (not valid JSON)
            end
            table.sort(entries, function(a, b) return a[1] < b[1] end)

            local parts = {}
            for _, entry in ipairs(entries) do
                local str_key, orig_key = entry[1], entry[2]
                parts[#parts + 1] = encode_string(str_key) .. ":" .. encode_value(value[orig_key], seen)
            end
            result = "{" .. table.concat(parts, ",") .. "}"
        end

        seen[addr] = nil  -- pop from stack so the same table can appear in sibling branches
        return result

    else
        -- Functions, userdata, threads, etc. are not representable in JSON.
        return "null"
    end
end

-- ---------------------------------------------------------------------------
-- Public: encode
-- ---------------------------------------------------------------------------

--- Encode a Lua value as a JSON string.
--- @param value any   The value to encode (nil, boolean, number, string, table).
--- @return string     A valid JSON text representation.
function Serializer.encode(value)
    local seen = {}
    return encode_value(value, seen)
end

-- ---------------------------------------------------------------------------
-- Pretty encoder — same output shape, with indentation and newlines so
-- diffs in golden tests are readable. Used only by tests; production runs
-- always use the compact encoder.
-- ---------------------------------------------------------------------------

local encode_pretty_value
encode_pretty_value = function(value, seen, indent)
    local t = type(value)
    if value == nil or value == Serializer.null then return "null" end
    if t ~= "table" then
        -- Reuse compact encoder for all scalars.
        return encode_value(value, seen)
    end

    local addr = tostring(value)
    if seen[addr] then
        Serializer._log_error("Circular reference at " .. addr .. "; substituting null")
        return "null"
    end
    seen[addr] = true

    local pad     = string.rep("  ", indent + 1)
    local close_pad = string.rep("  ", indent)
    local result

    if is_array(value) then
        if #value == 0 then
            result = "[]"
        else
            local parts = {}
            for i = 1, #value do
                parts[i] = pad .. encode_pretty_value(value[i], seen, indent + 1)
            end
            result = "[\n" .. table.concat(parts, ",\n") .. "\n" .. close_pad .. "]"
        end
    else
        local entries = {}
        for k in pairs(value) do
            if type(k) == "string" then
                entries[#entries + 1] = { k, k }
            elseif type(k) == "number" then
                entries[#entries + 1] = { tostring(k), k }
            end
        end
        table.sort(entries, function(a, b) return a[1] < b[1] end)

        if #entries == 0 then
            result = "{}"
        else
            local parts = {}
            for _, entry in ipairs(entries) do
                local str_key, orig_key = entry[1], entry[2]
                parts[#parts + 1] = pad .. encode_string(str_key) .. ": "
                                    .. encode_pretty_value(value[orig_key], seen, indent + 1)
            end
            result = "{\n" .. table.concat(parts, ",\n") .. "\n" .. close_pad .. "}"
        end
    end

    seen[addr] = nil
    return result
end

--- Encode a Lua value as pretty JSON (2-space indent, sorted keys).
--- Matches the shape of `encode` exactly — same numbers, same strings,
--- same booleans — only whitespace differs. Round-trips through `decode`.
function Serializer.encode_pretty(value)
    return encode_pretty_value(value, {}, 0)
end

-- ---------------------------------------------------------------------------
-- Public: decode  (minimal JSON parser for round-trip testing)
-- ---------------------------------------------------------------------------
-- This is a straightforward recursive-descent parser.  It handles the full
-- JSON subset produced by Serializer.encode:
--   null, true, false, numbers, strings (with all escape sequences),
--   arrays, and objects.
-- ---------------------------------------------------------------------------

local function decode_error(text, pos, msg)
    error(string.format("JSON decode error at position %d: %s\n...%s...",
        pos, msg, text:sub(math.max(1, pos - 10), pos + 10)), 2)
end

--- Skip whitespace; return the next non-whitespace position.
local function skip_ws(text, pos)
    return text:match("^%s*()", pos)
end

local decode_value  -- forward declaration

--- Parse a JSON string starting at pos (which must point at the opening '"').
--- Returns (lua_string, next_pos).
local function decode_string(text, pos)
    assert(text:sub(pos, pos) == '"', "expected '\"' at pos " .. pos)
    pos = pos + 1  -- skip opening quote
    local parts = {}
    while pos <= #text do
        local c = text:sub(pos, pos)
        if c == '"' then
            return table.concat(parts), pos + 1
        elseif c == '\\' then
            local esc = text:sub(pos + 1, pos + 1)
            if     esc == '"'  then parts[#parts+1] = '"';  pos = pos + 2
            elseif esc == '\\' then parts[#parts+1] = '\\'; pos = pos + 2
            elseif esc == '/'  then parts[#parts+1] = '/';  pos = pos + 2
            elseif esc == 'b'  then parts[#parts+1] = '\b'; pos = pos + 2
            elseif esc == 'f'  then parts[#parts+1] = '\f'; pos = pos + 2
            elseif esc == 'n'  then parts[#parts+1] = '\n'; pos = pos + 2
            elseif esc == 'r'  then parts[#parts+1] = '\r'; pos = pos + 2
            elseif esc == 't'  then parts[#parts+1] = '\t'; pos = pos + 2
            elseif esc == 'u'  then
                local hex = text:sub(pos + 2, pos + 5)
                if #hex < 4 then decode_error(text, pos, "incomplete \\uXXXX") end
                local codepoint = tonumber(hex, 16)
                if not codepoint then decode_error(text, pos, "invalid \\uXXXX: " .. hex) end
                -- Encode codepoint as UTF-8
                if codepoint < 0x80 then
                    parts[#parts+1] = string.char(codepoint)
                elseif codepoint < 0x800 then
                    parts[#parts+1] = string.char(
                        0xC0 + math.floor(codepoint / 64),
                        0x80 + (codepoint % 64))
                else
                    parts[#parts+1] = string.char(
                        0xE0 + math.floor(codepoint / 4096),
                        0x80 + math.floor((codepoint % 4096) / 64),
                        0x80 + (codepoint % 64))
                end
                pos = pos + 6
            else
                decode_error(text, pos, "unknown escape \\" .. esc)
            end
        else
            parts[#parts+1] = c
            pos = pos + 1
        end
    end
    decode_error(text, pos, "unterminated string")
end

--- Parse a JSON array starting at pos (must point at '[').
local function decode_array(text, pos)
    assert(text:sub(pos, pos) == '[')
    pos = skip_ws(text, pos + 1)
    local arr = {}
    if text:sub(pos, pos) == ']' then
        return arr, pos + 1
    end
    while true do
        local val
        val, pos = decode_value(text, pos)
        arr[#arr + 1] = val
        pos = skip_ws(text, pos)
        local c = text:sub(pos, pos)
        if c == ']' then
            return arr, pos + 1
        elseif c == ',' then
            pos = skip_ws(text, pos + 1)
        else
            decode_error(text, pos, "expected ',' or ']' in array")
        end
    end
end

--- Parse a JSON object starting at pos (must point at '{').
local function decode_object(text, pos)
    assert(text:sub(pos, pos) == '{')
    pos = skip_ws(text, pos + 1)
    local obj = {}
    if text:sub(pos, pos) == '}' then
        return obj, pos + 1
    end
    while true do
        pos = skip_ws(text, pos)
        if text:sub(pos, pos) ~= '"' then
            decode_error(text, pos, "expected string key in object")
        end
        local key
        key, pos = decode_string(text, pos)
        pos = skip_ws(text, pos)
        if text:sub(pos, pos) ~= ':' then
            decode_error(text, pos, "expected ':' after object key")
        end
        pos = skip_ws(text, pos + 1)
        local val
        val, pos = decode_value(text, pos)
        obj[key] = val
        pos = skip_ws(text, pos)
        local c = text:sub(pos, pos)
        if c == '}' then
            return obj, pos + 1
        elseif c == ',' then
            pos = skip_ws(text, pos + 1)
        else
            decode_error(text, pos, "expected ',' or '}' in object")
        end
    end
end

--- Parse any JSON value starting at pos.
decode_value = function(text, pos)
    pos = skip_ws(text, pos)
    local c = text:sub(pos, pos)

    if c == '"' then
        return decode_string(text, pos)

    elseif c == '[' then
        return decode_array(text, pos)

    elseif c == '{' then
        return decode_object(text, pos)

    elseif c == 't' then
        if text:sub(pos, pos + 3) == "true" then
            return true, pos + 4
        end
        decode_error(text, pos, "invalid token")

    elseif c == 'f' then
        if text:sub(pos, pos + 4) == "false" then
            return false, pos + 5
        end
        decode_error(text, pos, "invalid token")

    elseif c == 'n' then
        if text:sub(pos, pos + 3) == "null" then
            return Serializer.null, pos + 4
        end
        decode_error(text, pos, "invalid token")

    else
        -- Try to parse a number
        local num_str, next_pos = text:match("^(-?%d+%.?%d*[eE]?[+-]?%d*)()", pos)
        if num_str then
            return tonumber(num_str), next_pos
        end
        decode_error(text, pos, "unexpected character '" .. c .. "'")
    end
end

--- Decode a JSON string into a Lua value.
--- @param text string   Valid JSON text.
--- @return any          The decoded Lua value (nil for JSON null).
function Serializer.decode(text)
    if type(text) ~= "string" then
        error("Serializer.decode: expected string, got " .. type(text))
    end
    local value, pos = decode_value(text, 1)
    pos = skip_ws(text, pos)
    if pos <= #text then
        decode_error(text, pos, "trailing garbage after JSON value")
    end
    return value
end

return Serializer
