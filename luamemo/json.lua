-- luamemo/json.lua
--
-- Portable JSON shim.
--
-- Tries cjson.safe first (often installed).  Falls back to the bundled
-- pure-Lua dkjson when
-- cjson is not available, so `luarocks install luamemo` never fails because
-- of a missing C compiler.
--
-- Public API (identical regardless of backend):
--   json.encode(value)          → string, raises on unencodable value
--   json.decode(str)            → value  (or nil, err_string on bad JSON)
--   json.null                   → sentinel for explicit JSON null
--   json.empty_array            → encodes as [] (an empty Lua table encodes as {})
--
-- The bundled dkjson 2.5 (LuaDist copy, SHA-256 9d3e5c82dcd572a6a4b764d705f72b948094124b
-- 0e338cec0d6dfefea59693b7 as received) is changed to encode like lua-cjson — marked
-- "luamemo change" in it: a field `n` is an ordinary field (dkjson read a numeric `n`
-- as an array length: {n = 7} became seven nulls), and an empty table is {} (dkjson
-- wrote [], so MCP capabilities {"tools": {}} went out as {"tools": []}).

local M = {}

--- A list for an answer: an empty one encodes as [] (a bare empty table encodes as {}).
function M.list(t)
    if type(t) == "table" and next(t) == nil then return M.empty_array end
    return t
end

-- ── Try cjson.safe first ──────────────────────────────────────────────────
local ok, cjson_safe = pcall(require, "cjson.safe")
if ok and type(cjson_safe) == "table" then
    -- cjson.safe.decode already returns nil, err on bad JSON (never raises).
    M.encode = cjson_safe.encode
    M.decode = cjson_safe.decode
    M.null   = cjson_safe.null
    M.empty_array = cjson_safe.empty_array
        or (cjson_safe.array_mt and setmetatable({}, cjson_safe.array_mt)) or {}
    return M
end

-- ── Fallback: bundled dkjson (pure Lua, MIT) ─────────────────────────────
local dkjson = require("luamemo.vendor.dkjson")

-- json.null: use dkjson's own sentinel so decode returns it for JSON nulls.
M.null = dkjson.null
M.empty_array = setmetatable({}, { __jsontype = "array" })

-- encode: dkjson.encode raises on unencodable value — matches cjson default.
function M.encode(value)
    return dkjson.encode(value)
end

-- decode: dkjson.decode returns (value, next_pos) on success and
-- (nil, pos, err_string) on failure.  Wrap to the cjson.safe signature:
-- returns value on success, nil + err_string on failure, never raises.
function M.decode(str)
    if type(str) ~= "string" then
        return nil, "json.decode: expected string, got " .. type(str)
    end
    -- (pcall: dkjson recurses per nesting level — ~5,000 levels overflowed the Lua stack
    -- and the error ended the MCP server; lua-cjson refuses past 1,000 instead)
    local ok, val, _, err = pcall(dkjson.decode, str, 1, dkjson.null)
    if not ok then return nil, "json.decode: " .. tostring(val):gsub("^.-:%d+: ", "") end
    if err then
        return nil, err
    end
    return val
end

return M
