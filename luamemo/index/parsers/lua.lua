-- luamemo.index.parsers.lua
-- Pattern-based Lua symbol extractor. No config, no DB.
-- One of the language sub-parsers dispatched by luamemo.index.parser.
--
-- Covers ~90% of luamemo-style module code with Lua string patterns.
-- Known hard cases deferred (dynamic assignment, multi-line sigs, metamethods).

local common = require("luamemo.index.parsers.common")

local M = {}

-- Extensions this parser handles (used by the dispatcher registry).
M.extensions = { "lua" }

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Extract the argument string between the first '(' and matching ')'.
-- Lua keeps its own balanced-paren scanner (common.args_of stops at the first
-- ')' and would mis-handle nested parens in a signature).
-- Returns the raw arg string, or "" on failure.
local function _extract_args(line)
    local s = line:find("%(")
    if not s then return "" end
    local depth, pos = 0, s
    while pos <= #line do
        local c = line:sub(pos, pos)
        if c == "(" then depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then return line:sub(s + 1, pos - 1) end
        end
        pos = pos + 1
    end
    return line:sub(s + 1)  -- unmatched paren (multi-line sig)
end

-- Walk backwards from line_idx collecting consecutive -- or --[[ comment lines.
-- "Rule" lines — separators made only of dashes/equals/punctuation, and empty
-- "--" lines — carry no information and are skipped (not added, not terminating)
-- so the walk bridges across them. This matters because the luamemo style places
-- a "-- ----..." separator directly above each function; terminating there would
-- drop the real docstring that sits between two separators.
local function _extract_docstring(lines, line_idx)
    local docs = {}
    local i = line_idx - 1
    while i >= 1 do
        local l = lines[i]:match("^%s*(.-)%s*$")
        if l:match("^%-%-") then
            -- Strip leading -- or ---
            local text = l:match("^%-%-+%s?(.*)") or ""
            -- Keep only lines with real content (at least one word character);
            -- skip separator rules and blank comment lines without stopping.
            if text:match("%w") then
                table.insert(docs, 1, text)
            end
        elseif l == "" then
            break  -- blank (non-comment) line terminates the docstring block
        else
            break
        end
        i = i - 1
    end
    return table.concat(docs, " ")
end

-- Determine the module table name from "local M = {}" style declarations.
-- Returns the name string, or nil if not found in the first 60 lines.
local function _detect_module_var(lines)
    for i = 1, math.min(60, #lines) do
        local l = lines[i]
        -- local M = {} or local M = setmetatable({}, ...)
        local name = l:match("^local%s+([A-Z][%w_]*)%s*=%s*{")
                  or l:match("^local%s+([A-Z][%w_]*)%s*=%s*setmetatable")
        if name then return name end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Symbol extraction patterns
-- Priority-ordered; first match wins for a given line.
-- ---------------------------------------------------------------------------

-- Each entry: { pattern, handler(line, captures, ctx) → symbol_fields or nil }
-- ctx = { module_var, path, lines, lineno }

local PATTERNS = {
    -- function M.name(args)  or  function M:name(args)
    {
        pat = "^function%s+([A-Za-z_][%w_]*)([%.:]([A-Za-z_][%w_]*)%s*%()",
        fn  = function(_, cap, ctx)
            local tbl_name, sep_and_rest = cap[1], cap[2]
            local method_sep = sep_and_rest:sub(1, 1) == ":"
            local sym_name = sep_and_rest:match("[%.:]([A-Za-z_][%w_]*)") or "?"
            local is_module = (tbl_name == ctx.module_var)
            return {
                name        = sym_name,
                full_name   = tbl_name .. (method_sep and ":" or ".") .. sym_name,
                symbol_type = method_sep and "method" or "function",
                exported    = is_module,
                module      = is_module and tbl_name or nil,
            }
        end,
    },
    -- local function name(args)
    {
        pat = "^local%s+function%s+([A-Za-z_][%w_]*)%s*%(",
        fn  = function(_, cap, _ctx)
            return {
                name        = cap[1],
                full_name   = cap[1],
                symbol_type = "function",
                exported    = false,
                module      = nil,
            }
        end,
    },
    -- function name(args)  (top-level, no module prefix)
    {
        pat = "^function%s+([A-Za-z_][%w_]*)%s*%(",
        fn  = function(_, cap, _ctx)
            return {
                name        = cap[1],
                full_name   = cap[1],
                symbol_type = "function",
                exported    = false,
                module      = nil,
            }
        end,
    },
    -- M.name = function(args)
    {
        pat = "^([A-Za-z_][%w_]*)%.([A-Za-z_][%w_]*)%s*=%s*function%s*%(",
        fn  = function(_, cap, ctx)
            local tbl_name, sym_name = cap[1], cap[2]
            local is_module = (tbl_name == ctx.module_var)
            return {
                name        = sym_name,
                full_name   = tbl_name .. "." .. sym_name,
                symbol_type = "function",
                exported    = is_module,
                module      = is_module and tbl_name or nil,
            }
        end,
    },
    -- local name = function(args)
    {
        pat = "^local%s+([A-Za-z_][%w_]*)%s*=%s*function%s*%(",
        fn  = function(_, cap, _ctx)
            return {
                name        = cap[1],
                full_name   = cap[1],
                symbol_type = "function",
                exported    = false,
                module      = nil,
            }
        end,
    },
    -- name = function(args)  (bare assignment, may be module-exported)
    {
        pat = "^([A-Za-z_][%w_]*)%s*=%s*function%s*%(",
        fn  = function(_, cap, ctx)
            local sym_name = cap[1]
            -- Heuristic: exported if the name looks like it could be a public API var
            local exported = ctx.module_var == nil  -- conservative; no module table detected
            return {
                name        = sym_name,
                full_name   = sym_name,
                symbol_type = "function",
                exported    = exported,
                module      = nil,
            }
        end,
    },
}

-- Extract require() calls from a single line.
-- Returns list of module strings (may be multiple per line, rare but possible).
local function _extract_requires(line)
    local mods = {}
    for mod in line:gmatch('require%s*%(%s*["\']([^"\']+)["\']%s*%)') do
        mods[#mods + 1] = mod
    end
    -- Also match: require "mod.name" without parens (unusual but valid Lua)
    for mod in line:gmatch('require%s+["\']([^"\']+)["\']') do
        mods[#mods + 1] = mod
    end
    return mods
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- parse_source(src, path) → { symbols = [...], requires = [...] }
--
-- src  : string — file content (already loaded)
-- path : string — relative path (used in metadata only, not for IO)
--
-- Each symbol:
--   { name, full_name, symbol_type, exported, module,
--     line, arity, vararg, docstring, path }
--
-- Each require:
--   { module, line, path }
function M.parse_source(src, path)
    path = path or ""
    local lines = common.split_lines(src)

    local module_var = _detect_module_var(lines)
    local symbols = {}
    local requires = {}

    for i, raw_line in ipairs(lines) do
        -- Strip leading/trailing whitespace for pattern matching.
        local line = raw_line:match("^%s*(.-)%s*$")

        -- Skip pure comment lines and blank lines.
        if not (line:match("^%-%-") or line == "") then
            -- Require extraction (before symbol patterns).
            local mods = _extract_requires(line)
            for _, mod in ipairs(mods) do
                requires[#requires + 1] = { module = mod, line = i, path = path }
            end

            -- Symbol extraction: first matching pattern wins.
            local ctx = { module_var = module_var, path = path, lines = lines, lineno = i }
            local matched = false
            local pi = 1
            while not matched and pi <= #PATTERNS do
                local entry = PATTERNS[pi]
                local caps = { line:match(entry.pat) }
                if caps[1] then
                    local fields = entry.fn(line, caps, ctx)
                    if fields then
                        local arg_str = _extract_args(raw_line)
                        local arity, vararg = common.arity(arg_str)
                        local doc = _extract_docstring(lines, i)
                        symbols[#symbols + 1] = {
                            name        = fields.name,
                            full_name   = fields.full_name,
                            symbol_type = fields.symbol_type,
                            exported    = fields.exported,
                            module      = fields.module or module_var,
                            line        = i,
                            arity       = arity,
                            vararg      = vararg,
                            docstring   = doc,
                            path        = path,
                        }
                        matched = true
                    end
                end
                pi = pi + 1
            end
        end
    end

    return { symbols = symbols, requires = requires, module_var = module_var }
end

-- parse_file(path) → result table (same shape as parse_source), or nil, err
function M.parse_file(path)
    local f, err = io.open(path, "r")
    if not f then return nil, "parsers.lua.parse_file: " .. tostring(err) end
    local src = f:read("*a")
    f:close()
    return M.parse_source(src, path)
end

return M
