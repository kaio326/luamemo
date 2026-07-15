-- luamemo.index.checksum
-- Pure-Lua 5.1 file fingerprinting using DJB2 (polynomial hash).
-- No bit library required. No config, no DB. Safe to require() directly.
--
-- IMPORTANT: \r\n is normalised to \n before hashing so that Windows and
-- Linux checkouts of the same file produce identical digests.

local util = require("luamemo.util")

local M = {}

-- Normalise line endings: \r\n → \n, standalone \r → \n.
local function _normalise(s)
    return s:gsub("\r\n", "\n"):gsub("\r", "\n")
end

-- M.source(str) → hex string
-- Hash a string (e.g. already-loaded file content). Normalises line endings.
-- Uses the shared DJB2 (util.djb2_hex, mod 2^32 + 8-char hex) — byte-identical
-- to the previous inline implementation, so existing index checksums are stable.
function M.source(str)
    if type(str) ~= "string" then return nil, "checksum.source: expected string" end
    return util.djb2_hex(_normalise(str))
end

-- M.file(path) → hex string, or nil, err
-- Read the file at path and return its DJB2 checksum.
function M.file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, "checksum.file: " .. tostring(err) end
    local content = f:read("*a")
    f:close()
    if content == nil then return nil, "checksum.file: read failed" end
    return M.source(content)
end

return M
