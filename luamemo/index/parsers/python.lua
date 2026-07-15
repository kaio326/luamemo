-- luamemo.index.parsers.python
-- Pattern-based Python symbol extractor. No config, no DB.
-- One of the language sub-parsers dispatched by luamemo.index.parser.
--
-- Covers the common cases: top-level and nested def/async def, class, and
-- import / from-import statements. Indentation drives scope: a def nested in a
-- class becomes a "method" with a ClassName.name full_name. Pure patterns —
-- no AST — so decorated/dynamically-built symbols and multi-line signatures
-- are best-effort.

local common = require("luamemo.index.parsers.common")

local M = {}

M.extensions = { "py" }

-- Python varargs are "*args"/"**kw" → detect/strip the "*" token.
local function _arity(arg_str) return common.arity(arg_str, "%*") end

-- import / from-import → list of module strings.
local function _extract_imports(line)
    local mods = {}
    -- from X.Y import a, b   (also relative: "from . import x", "from .mod import y")
    local from_mod = line:match("^from%s+([%.%w_]+)%s+import")
    if from_mod then
        mods[#mods + 1] = from_mod
        return mods
    end
    -- import a, b.c as d, e
    local rest = line:match("^import%s+(.+)$")
    if rest then
        for part in rest:gmatch("[^,]+") do
            local mod = part:match("^%s*([%.%w_]+)")
            if mod then mods[#mods + 1] = mod end
        end
    end
    return mods
end

-- Python docstring: the first triple-quoted string immediately inside a
-- def/class body. Returns the first line of its content (trimmed), or "".
local function _docstring(lines, def_idx)
    local i = def_idx + 1
    while i <= #lines do
        local s = lines[i]:match("^%s*(.-)%s*$")
        if s == "" then
            i = i + 1
        else
            local q = s:match('^(""")') or s:match("^('''")
            if not q then return "" end
            -- Single-line docstring: """text"""
            local single = s:match('^"""(.-)"""$') or s:match("^'''(.-)'''$")
            if single and single ~= "" then return single end
            -- Multi-line: take the remainder of the opening line, else next line.
            local rest = s:sub(4):match("^%s*(.-)%s*$")
            if rest ~= "" then return rest end
            local nxt = lines[i + 1] and lines[i + 1]:match("^%s*(.-)%s*$") or ""
            return nxt
        end
    end
    return ""
end

-- parse_source(src, path) → { symbols, requires, module_var = nil }
function M.parse_source(src, path)
    path = path or ""
    local lines = common.split_lines(src)

    local symbols, requires = {}, {}
    local class_stack = {}   -- { {indent=, name=}, ... } innermost last

    for i, raw in ipairs(lines) do
        local line = raw:match("^%s*(.-)%s*$")

        if line ~= "" and not line:match("^#") then
            -- Imports first.
            for _, mod in ipairs(_extract_imports(line)) do
                requires[#requires + 1] = { module = mod, line = i, path = path }
            end

            local indent = common.indent(raw)
            -- Pop classes that this line has dedented out of.
            while #class_stack > 0 and indent <= class_stack[#class_stack].indent do
                class_stack[#class_stack] = nil
            end

            -- class Name  /  class Name(Base):
            local cls = line:match("^class%s+([%w_]+)")
            if cls then
                symbols[#symbols + 1] = {
                    name        = cls,
                    full_name   = cls,
                    symbol_type = "class",
                    exported    = not cls:match("^_"),
                    module      = nil,
                    line        = i,
                    arity       = 0,
                    vararg      = false,
                    docstring   = _docstring(lines, i),
                    path        = path,
                }
                class_stack[#class_stack + 1] = { indent = indent, name = cls }
            else
                -- def name(...)  /  async def name(...)
                local fn = line:match("^def%s+([%w_]+)%s*%(")
                          or line:match("^async%s+def%s+([%w_]+)%s*%(")
                if fn then
                    local enclosing = class_stack[#class_stack]
                    local is_method = enclosing ~= nil
                    local arity, vararg = _arity(common.args_of(line))
                    symbols[#symbols + 1] = {
                        name        = fn,
                        full_name   = is_method and (enclosing.name .. "." .. fn) or fn,
                        symbol_type = is_method and "method" or "function",
                        exported    = not fn:match("^_"),
                        module      = nil,
                        line        = i,
                        arity       = arity,
                        vararg      = vararg,
                        docstring   = _docstring(lines, i),
                        path        = path,
                    }
                end
            end
        end
    end

    return { symbols = symbols, requires = requires, module_var = nil }
end

function M.parse_file(path)
    local f, err = io.open(path, "r")
    if not f then return nil, "parsers.python.parse_file: " .. tostring(err) end
    local src = f:read("*a")
    f:close()
    return M.parse_source(src, path)
end

return M
