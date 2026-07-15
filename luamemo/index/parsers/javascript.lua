-- luamemo.index.parsers.javascript
-- Pattern-based JavaScript / TypeScript symbol extractor. No config, no DB.
-- One of the language sub-parsers dispatched by luamemo.index.parser.
--
-- Registered for .js/.jsx/.ts/.tsx. Covers the common cases: function
-- declarations, arrow/function-expression consts, classes, class methods, and
-- import / require / export-from dependency edges. Pure patterns (no AST), so
-- minified code, multi-line signatures, and dynamically-built members are
-- best-effort. TypeScript type syntax is tolerated but not deeply parsed.

local common = require("luamemo.index.parsers.common")

local M = {}

M.extensions = { "js", "jsx", "ts", "tsx", "mjs", "cjs" }

-- Names that look like `name(...) {` but are control flow, not definitions.
local KEYWORD = {
    ["if"]=true, ["for"]=true, ["while"]=true, ["switch"]=true, ["catch"]=true,
    ["return"]=true, ["function"]=true, ["else"]=true, ["do"]=true, ["try"]=true,
    ["finally"]=true, ["with"]=true, ["await"]=true, ["typeof"]=true,
}

-- JS rest params are "...rest" → the default "..." vararg token.
local function _arity(arg_str) return common.arity(arg_str) end

-- import/require/export-from → list of module specifier strings.
local function _extract_deps(line)
    local mods = {}
    -- import ... from 'mod'   |   export ... from 'mod'
    for mod in line:gmatch("from%s+['\"]([^'\"]+)['\"]") do
        mods[#mods + 1] = mod
    end
    -- bare side-effect import: import 'mod'
    local bare = line:match("^import%s+['\"]([^'\"]+)['\"]")
    if bare then mods[#mods + 1] = bare end
    -- require('mod')
    for mod in line:gmatch("require%s*%(%s*['\"]([^'\"]+)['\"]%s*%)") do
        mods[#mods + 1] = mod
    end
    return mods
end

-- Preceding-comment docstring: // lines and /** ... */ JSDoc blocks. Strips
-- comment sigils, skips rule/blank-comment lines, terminates on code or blank.
local function _extract_docstring(lines, idx)
    local docs = {}
    local i = idx - 1
    while i >= 1 do
        local l = lines[i]:match("^%s*(.-)%s*$")
        local content
        if l:match("^//") then
            content = l:match("^//+%s?(.*)")
        elseif l:match("^/%*") then           -- /** opener (maybe with text and closer)
            content = (l:match("^/%*+%s?(.*)") or ""):gsub("%*/%s*$", "")
        elseif l:match("^%*") then            -- JSDoc body "* text" or closing "*/"
            content = (l:match("^%*+/?%s?(.*)") or ""):gsub("%*/%s*$", "")
        elseif l == "" then
            break
        else
            break
        end
        if content and content:match("%w") then
            table.insert(docs, 1, content)
        end
        i = i - 1
    end
    return table.concat(docs, " ")
end

-- Strip leading definition qualifiers so the bare member name is matchable.
local function _strip_qualifiers(s)
    return (s:gsub("^export%s+", "")
             :gsub("^default%s+", "")
             :gsub("^public%s+", ""):gsub("^private%s+", ""):gsub("^protected%s+", "")
             :gsub("^static%s+", "")
             :gsub("^async%s+", "")
             :gsub("^get%s+", ""):gsub("^set%s+", ""))
end

-- parse_source(src, path) → { symbols, requires, module_var = nil }
function M.parse_source(src, path)
    path = path or ""
    local lines = common.split_lines(src)

    local symbols, requires = {}, {}
    local class_stack = {}   -- { {indent=, name=}, ... }

    local function add(name, full_name, stype, exported, line_no, arity, vararg)
        symbols[#symbols + 1] = {
            name        = name,
            full_name   = full_name,
            symbol_type = stype,
            exported    = exported,
            module      = nil,
            line        = line_no,
            arity       = arity or 0,
            vararg      = vararg or false,
            docstring   = _extract_docstring(lines, line_no),
            path        = path,
        }
    end

    for i, raw in ipairs(lines) do
        local line = raw:match("^%s*(.-)%s*$")

        if line ~= "" and not line:match("^//") and not line:match("^%*") then
            for _, mod in ipairs(_extract_deps(line)) do
                requires[#requires + 1] = { module = mod, line = i, path = path }
            end

            local indent = common.indent(raw)
            while #class_stack > 0 and indent <= class_stack[#class_stack].indent do
                class_stack[#class_stack] = nil
            end

            local exported = line:match("^export") ~= nil
            local bare = _strip_qualifiers(line)

            -- class Name  /  class Name extends Base  /  export default class Name
            local cls = bare:match("^class%s+([%w_$]+)")
            if cls then
                add(cls, cls, "class", exported or (not cls:match("^_")), i, 0, false)
                class_stack[#class_stack + 1] = { indent = indent, name = cls }

            -- function name(...)  /  export async function name(...)
            elseif bare:match("^function%s+[%w_$]+") then
                local fn = bare:match("^function%s+([%w_$]+)")
                local arity, vararg = _arity(common.args_of(line))
                add(fn, fn, "function", exported, i, arity, vararg)

            -- const/let/var name = (...) => ...   |   = function ...
            elseif bare:match("^const%s") or bare:match("^let%s") or bare:match("^var%s") then
                local nm = bare:match("^%a+%s+([%w_$]+)%s*=")
                if nm and (line:find("=>") or line:find("function")) then
                    local arity, vararg = _arity(common.args_of(line))
                    add(nm, nm, "function", exported, i, arity, vararg)
                end

            else
                -- Class method:  name(...) {   (inside a class block, ends with {)
                local enclosing = class_stack[#class_stack]
                if enclosing and line:match("{%s*$") then
                    local nm = bare:match("^([%w_$#]+)%s*%(")
                    if nm and not KEYWORD[nm] then
                        local arity, vararg = _arity(common.args_of(line))
                        add(nm, enclosing.name .. "." .. nm, "method",
                            not nm:match("^[_#]"), i, arity, vararg)
                    end
                end
            end
        end
    end

    return { symbols = symbols, requires = requires, module_var = nil }
end

function M.parse_file(path)
    local f, err = io.open(path, "r")
    if not f then return nil, "parsers.javascript.parse_file: " .. tostring(err) end
    local src = f:read("*a")
    f:close()
    return M.parse_source(src, path)
end

return M
