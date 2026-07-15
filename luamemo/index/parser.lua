-- luamemo.index.parser
-- Language-dispatching symbol extractor. No config, no DB.
-- Safe to require() directly without setup().
--
-- This module is a thin dispatcher: it picks a per-language sub-parser (from
-- luamemo/index/parsers/) by file extension and forwards parse_source /
-- parse_file to it. Each sub-parser is pure-Lua and pattern-based, returning
-- the same shape:
--   { symbols = { {name, full_name, symbol_type, exported, module,
--                   line, arity, vararg, docstring, path}, ... },
--     requires = { {module, line, path}, ... },
--     module_var = string|nil }
--
-- Backward-compatible: callers that require("luamemo.index.parser") and call
-- parse_source(src, path) / parse_file(path) keep working unchanged; for .lua
-- paths the Lua sub-parser runs, exactly as before.

local M = {}

-- ---------------------------------------------------------------------------
-- Registry: extension → sub-parser module.
-- Each sub-parser declares the extensions it handles via its M.extensions list.
-- ---------------------------------------------------------------------------
local SUBPARSERS = {
    require("luamemo.index.parsers.lua"),
    require("luamemo.index.parsers.python"),
    require("luamemo.index.parsers.javascript"),
}

local BY_EXT = {}
for _, sub in ipairs(SUBPARSERS) do
    for _, ext in ipairs(sub.extensions or {}) do
        BY_EXT[ext] = sub
    end
end

-- Lowercased extension of a path, or nil.
local function _ext(path)
    if not path then return nil end
    local e = path:match("%.([%w_]+)$")
    return e and e:lower() or nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- has_parser(path) → bool. True when a language sub-parser handles this path's
-- extension. Used by the orchestrator to decide whether to extract symbols.
function M.has_parser(path)
    return BY_EXT[_ext(path) or ""] ~= nil
end

-- parser_for(path) → sub-parser module, or nil.
function M.parser_for(path)
    return BY_EXT[_ext(path) or ""]
end

-- List the extensions that have a real symbol parser.
function M.supported_extensions()
    local out = {}
    for ext in pairs(BY_EXT) do out[#out + 1] = ext end
    table.sort(out)
    return out
end

-- parse_source(src, path) → result table (always non-nil).
-- Dispatches by path extension; unknown extensions yield an empty result so
-- callers never have to special-case "no parser".
function M.parse_source(src, path)
    local sub = M.parser_for(path)
    if not sub then
        return { symbols = {}, requires = {}, module_var = nil }
    end
    return sub.parse_source(src, path)
end

-- parse_file(path) → result table, or nil, err.
function M.parse_file(path)
    local sub = M.parser_for(path)
    if not sub then
        -- Unknown language: read nothing, return empty (not an error).
        return { symbols = {}, requires = {}, module_var = nil }
    end
    return sub.parse_file(path)
end

return M
