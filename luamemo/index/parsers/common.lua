-- luamemo.index.parsers.common
-- Shared pure helpers for the language sub-parsers. No config, no DB.
-- Keeps arity / indent / arg-extraction / line-splitting in one place so a fix
-- lands once instead of in each parser.

local M = {}

-- Split source into a list of lines.
function M.split_lines(src)
    local lines = {}
    for l in ((src or "") .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = l
    end
    return lines
end

-- Leading-whitespace width of a raw line (each space/tab counts as 1).
function M.indent(raw)
    return #((raw or ""):match("^(%s*)") or "")
end

-- First parenthesised group of a single-line signature, or "".
-- (Languages with possibly-nested parens in the signature — Lua — use their own
-- balanced-paren scanner instead.)
function M.args_of(line)
    return (line or ""):match("%((.-)%)") or ""
end

-- Count parameters in an arg string → fixed_count (int), vararg (bool).
-- vararg_pat is the Lua pattern that detects AND strips the language's vararg
-- token: "%.%.%." for Lua/JS ("..."), "%*" for Python ("*args"/"**kw").
-- Defaults to the "..." form.
function M.arity(arg_str, vararg_pat)
    vararg_pat = vararg_pat or "%.%.%."
    arg_str = (arg_str or ""):gsub("%s+", "")
    if arg_str == "" then return 0, false end
    local vararg = arg_str:find(vararg_pat) ~= nil
    local clean = arg_str:gsub(vararg_pat, "")
    if clean == "" or clean == "," then return 0, vararg end
    local n = 1
    for _ in clean:gmatch(",") do n = n + 1 end
    if clean:sub(-1) == "," then n = n - 1 end
    return math.max(0, n), vararg
end

return M
