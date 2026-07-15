-- luamemo.index.resolver
-- Converts between source-module names and relative file paths.
-- Pure function, no DB. Safe to require() directly.
--
-- Used by index/init.lua to derive a dotted module name from a file path (for
-- symbol titles and KG fact subjects), and to resolve Lua require() targets to
-- on-disk paths for dependency rows.

local M = {}

-- Extensions treated as source code for module-name derivation. Mirrors the
-- calibrate scanner's language set plus JS/TS variants.
local KNOWN_EXTS = {
    lua = true,
    py = true,
    js = true, jsx = true, ts = true, tsx = true, mjs = true, cjs = true,
    go = true, rb = true, rs = true, java = true,
    c = true, cpp = true, h = true,
    ex = true, exs = true, clj = true, scala = true,
}

-- Per-language "package entry" basenames: a file named like these represents
-- its parent directory rather than a leaf module, so the basename is dropped.
--   Lua init.lua · Python __init__.py · JS index.js · Rust mod.rs
local PACKAGE_ENTRY = { "init", "__init__", "index", "mod" }

-- path_to_module(rel_path) → dotted module name, or nil if not source code.
-- "luamemo/store.lua"       → "luamemo.store"
-- "luamemo/index/init.lua"  → "luamemo.index"   (init.lua = package entry)
-- "app/utils/helpers.py"    → "app.utils.helpers"
-- "src/index.js"            → "src"             (index.js = package entry)
-- "cli/memo"                → nil  (no known code extension)
function M.path_to_module(rel_path)
    if type(rel_path) ~= "string" then return nil end
    -- Split into base + extension; bail if the extension is not source code.
    local base, ext = rel_path:match("^(.-)%.([%w_]+)$")
    if not base or not KNOWN_EXTS[ext:lower()] then return nil end
    -- If the file's own basename is a package entry (init/__init__/index/mod),
    -- drop it so the file maps to its parent directory. Only the basename is
    -- checked — a directory literally named "index" must survive.
    local dir, name = base:match("^(.*)[/\\]([^/\\]+)$")
    if name then
        for _, entry in ipairs(PACKAGE_ENTRY) do
            if name == entry then base = dir; break end
        end
    end
    -- Replace path separators with dots.
    base = base:gsub("[/\\]", ".")
    -- Guard: module name must start with a letter/underscore.
    if not base:match("^[%a_]") then return nil end
    return base
end

-- resolve(module_name, root) → rel_path string, or nil (external dependency).
-- Lua-only for now: converts dots to path separators, then probes root for
-- <name>.lua and <name>/init.lua. Returns the first that exists, or nil.
-- Per-language resolution (Python/JS import → path) is future work; until then,
-- non-Lua dependency rows carry resolved_path=nil and produce no KG fact.
--
-- root: absolute or relative path to the project root directory.
-- Returns a relative path from root (forward slashes, no leading ./).
function M.resolve(module_name, root)
    if type(module_name) ~= "string" or type(root) ~= "string" then
        return nil
    end
    -- Normalise root: strip trailing slash.
    root = root:gsub("[/\\]+$", "")
    -- Convert dots to slashes.
    local base = module_name:gsub("%.", "/")
    -- Candidates in priority order.
    local candidates = { base .. ".lua", base .. "/init.lua" }
    for _, rel in ipairs(candidates) do
        local full = root .. "/" .. rel
        local f = io.open(full, "r")
        if f then
            f:close()
            return rel
        end
    end
    return nil  -- external or unresolvable
end

-- Extensions whose imports M.resolve() can turn into on-disk paths (and thus
-- KG dependency facts). Lua-only today; when per-language resolution lands in
-- M.resolve(), add the extension here so callers gate consistently.
local RESOLVABLE_EXTS = { lua = true }

-- has_resolver(rel_path) → bool. True when this file's language can produce
-- resolved dependency edges / KG facts. Lets callers skip KG bookkeeping
-- (e.g. stale-fact deletion) for files that can never have facts.
function M.has_resolver(rel_path)
    if type(rel_path) ~= "string" then return false end
    local ext = rel_path:match("%.([%w_]+)$")
    return ext ~= nil and RESOLVABLE_EXTS[ext:lower()] == true
end

return M
