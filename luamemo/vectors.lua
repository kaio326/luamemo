-- luamemo.vectors
-- Embedding vectors as float32 BLOBs (with their L2 norm stored next to them), and exact
-- cosine similarity computed in place — on the BLOB a row scan hands over — with LuaJIT's FFI.
--
--   pack(vec)                      → blob (string), norm      | nil (no / empty vector)
--   unpack(blob)                   → { numbers }
--   query(vec)                     → a prepared query vector { cv, n, norm }
--   cosine_ptr(ptr, bytes, norm, q) → similarity (0 when sizes differ or a norm is 0)
--   cosine(a, b)                   → similarity of two Lua vectors (luamemo.util.cosine)

local ffi = require("luamemo.native.loader").ffi
local util = require("luamemo.util")

local M = {}

function M.pack(vec)
    if type(vec) ~= "table" or #vec == 0 then return nil end
    local n = #vec
    local buf = ffi.new("float[?]", n)
    local nn = 0
    for i = 1, n do
        local x = tonumber(vec[i]) or 0
        buf[i - 1] = x
        local f = buf[i - 1]          -- the stored (float32) value
        nn = nn + f * f
    end
    return ffi.string(buf, n * 4), math.sqrt(nn)
end

function M.unpack(blob)
    if type(blob) ~= "string" or #blob < 4 then return nil end
    local n = math.floor(#blob / 4)
    local p = ffi.cast("const float*", blob)
    local out = {}
    for i = 0, n - 1 do out[i + 1] = p[i] end
    return out
end

function M.query(vec)
    local n = #vec
    local cv = ffi.new("double[?]", n)
    local nn = 0
    for i = 1, n do
        local x = tonumber(vec[i]) or 0
        cv[i - 1] = x
        nn = nn + x * x
    end
    return { cv = cv, n = n, norm = math.sqrt(nn) }
end

function M.cosine_ptr(ptr, bytes, norm, q)
    if ptr == nil or bytes ~= q.n * 4 or not norm or norm == 0 or q.norm == 0 then return 0 end
    local f = ffi.cast("const float*", ptr)
    local cv = q.cv
    local dot = 0
    for i = 0, q.n - 1 do dot = dot + f[i] * cv[i] end
    return dot / (norm * q.norm)
end

M.cosine = util.cosine

return M
