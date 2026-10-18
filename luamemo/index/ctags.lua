-- luamemo.index.ctags
-- Optional enrichment: use the `universal-ctags` binary (when present) to
-- extract symbols for languages that have no native pure-Lua parser (Go, Rust,
-- Ruby, Java, C/C++, …). Degrades to nothing when ctags is absent, so luamemo
-- still "runs with just Lua" — this only UPGRADES coverage when the binary
-- happens to be installed.
--
-- Not a pure `parse_source(src, path)` parser (it shells out and reads disk),
-- so it lives here rather than under parsers/. Emits the same symbol contract
-- the native parsers do, minus docstrings/imports (ctags provides neither —
-- those stay the native parsers' job, which is why native always wins).

local M = {}

local json = require("luamemo.json")

-- Extensions ctags should handle here: code languages WITHOUT a native parser.
-- (Native lua/py/js/ts are handled by parsers/ and must never reach ctags.)
-- Deliberately excludes data/doc formats (md, json, …) that ctags *can* parse
-- but which would add noise rather than a useful code map.
local CODE_EXTS = {
    go = true, rs = true, rb = true, java = true,
    c = true, cc = true, cpp = true, cxx = true, h = true, hpp = true, hxx = true,
    cs = true, php = true, swift = true, kt = true, kts = true,
    scala = true, ex = true, exs = true, clj = true, cljs = true,
    pl = true, pm = true, sh = true, bash = true, m = true, mm = true,
}

-- Map ctags "kind" names to our symbol_type. Kinds not listed are skipped so
-- the map stays focused on callable/type symbols (not every field/import).
local KIND_MAP = {
    ["function"]  = "function", ["func"] = "function",
    subroutine    = "function", procedure = "function", ["proto"] = "function",
    method        = "method",
    struct        = "class", class = "class", interface = "class",
    enum          = "class", trait = "class", type = "class",
    union         = "class", typedef = "class", ["module"] = "class",
    constant      = "constant", const = "constant", enumerator = "constant",
    macro         = "constant",
}

-- ---------------------------------------------------------------------------
-- Availability probe (cached once per process)
-- ---------------------------------------------------------------------------
local _probe = nil   -- nil = not probed; true/false after

-- available() → bool. True only for Universal Ctags built with JSON output.
-- Disabled entirely by MEMO_INDEX_NO_CTAGS=1.
function M.available()
    if _probe ~= nil then return _probe end
    _probe = false
    if os.getenv("MEMO_INDEX_NO_CTAGS") == "1" then return false end
    local vf = io.popen("ctags --version 2>/dev/null")
    if not vf then return false end
    local ver = vf:read("*a") or ""
    vf:close()
    if not ver:find("Universal Ctags", 1, true) then return false end
    -- Require JSON output support (needs libjansson at build time).
    local ff = io.popen("ctags --list-features 2>/dev/null")
    local feats = ff and ff:read("*a") or ""
    if ff then ff:close() end
    _probe = feats:find("json", 1, true) ~= nil
    return _probe
end

-- Reset the cached probe (tests toggle MEMO_INDEX_NO_CTAGS between runs).
function M._reset_probe() _probe = nil end

-- handles(rel_path) → bool: ctags-enrichable code extension (and ctags present).
function M.handles(rel_path)
    if type(rel_path) ~= "string" then return false end
    local ext = rel_path:match("%.([%w_]+)$")
    if not ext or not CODE_EXTS[ext:lower()] then return false end
    return M.available()
end

-- ---------------------------------------------------------------------------
-- Extraction
-- ---------------------------------------------------------------------------

local shq = require("luamemo.util").shell_quote

-- One line of ctags' JSON output → the file it is about and our symbol, or nil (not a
-- tag, a kind left out, a file not asked for). rel_of: on-disk path → repo-relative path.
local function _symbol(line, rel_of)
    if line == "" then return nil end
    local ok, tag = pcall(json.decode, line)
    if not (ok and type(tag) == "table" and tag._type == "tag" and tag.name) then return nil end
    local stype, rel = KIND_MAP[tag.kind or ""], rel_of[tag.path]
    if not (stype and rel) then return nil end
    local name, scope = tag.name, tag.scope
    return tag.path, {
        name        = name,
        full_name   = (scope and scope ~= "") and (scope .. "." .. name) or name,
        symbol_type = stype,
        exported    = not name:match("^_"),  -- best-effort
        module      = nil,
        line        = tonumber(tag.line) or 0,
        arity       = nil,
        vararg      = false,
        docstring   = "",                    -- ctags provides none
        path        = rel,
    }
end

M.BATCH = 200   -- files per ctags run

-- parse_files({ {path =, rel =}, … }) → { [path] = { symbols = {...}, requires = {} } },
-- an entry for every file given (empty when ctags found nothing). One ctags run per
-- M.BATCH files: a run per file cost a process start each (200 Go files: 850 ms → 13 ms).
-- Never throws. `path` is the on-disk path, `rel` (default: path) the repo-relative one
-- stored in symbol metadata.
function M.parse_files(files)
    local out, rel_of, paths = {}, {}, {}
    for _, f in ipairs(files or {}) do
        if type(f.path) == "string" and f.path ~= "" and not out[f.path] then
            out[f.path] = { symbols = {}, requires = {} }
            rel_of[f.path] = f.rel or f.path
            paths[#paths + 1] = f.path
        end
    end
    for c = 1, #paths, M.BATCH do
        local args = {}
        for i = c, math.min(c + M.BATCH - 1, #paths) do args[#args + 1] = shq(paths[i]) end
        local pipe = io.popen("ctags --output-format=json --fields=+nK -f - " .. table.concat(args, " ")
            .. " 2>/dev/null")
        if pipe then
            for line in pipe:lines() do
                local path, sym = _symbol(line, rel_of)
                if path then
                    local syms = out[path].symbols
                    syms[#syms + 1] = sym
                end
            end
            pipe:close()
        end
    end
    return out
end

-- parse_file(path, rel) → { symbols = {...}, requires = {} } — parse_files for one file.
function M.parse_file(path, rel)
    if type(path) ~= "string" or path == "" then return { symbols = {}, requires = {} } end
    return M.parse_files({ { path = path, rel = rel } })[path]
end

return M
