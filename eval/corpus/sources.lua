-- eval/corpus/sources.lua — the real source trees the benchmark corpus is built from.
--
-- A source is a project of the corpus: its code goes through `memo index ingest`'s own code
-- (scope codeindex:<name>) and its documents, instruction files and git history through
-- `memo calibrate`'s own scan (scope repo:<name>) — so the rows are the rows luamemo writes.
--
--   { name, kind = "own" | "lib", root (code), scan_root (docs; nil: none),
--     max_files (a seeded sample of a huge tree), git (the scan reads its history) }
--
-- discover(opts) finds what this machine has: the owner's repositories (opts.own_dirs: the
-- parents to look in) and the real libraries installed offline — the Python standard
-- library, Node packages (with their READMEs from /usr/share/doc), Ruby and Perl libraries,
-- Lua rocks. A few are huge on purpose: luamemo searches one scope at a time, so a corpus
-- only tests scale if some scope is that big. Nothing outside the sampled files and
-- documents is read; nothing is copied into the repository.

local M = {}

local util = require("luamemo.util")
local sh, shq, exists = util.sh, util.shell_quote, util.exists

local function lines(cmd)
    local out = {}
    for l in (sh(cmd) .. "\n"):gmatch("([^\n]+)") do out[#out + 1] = l end
    return out
end

local function slug(s) return (s:gsub("[^%w%.%-]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")) end

--- Directories of the owner's work under `parents` that look like projects (a .git, or
--- code/docs at the top): { { name, root, git } … }.
local function own_projects(parents, max_files)
    local out = {}
    for _, parent in ipairs(parents) do
        for _, dir in ipairs(lines(("find %s -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort"):format(shq(parent)))) do
            local base = dir:match("([^/]+)$")
            local has_git = util.is_dir(dir .. "/.git")
            local has_code = sh(("find %s -maxdepth 2 \\( -name '*.lua' -o -name '*.py' -o -name '*.js' -o -name '*.md' \\) "
                .. "-not -path '*/node_modules/*' 2>/dev/null | head -1"):format(shq(dir))) ~= ""
            if base and not base:match("^%.") and (has_git or has_code) then
                out[#out + 1] = { name = slug(base:lower()), kind = "own", root = dir, scan_root = dir, git = has_git,
                                  max_files = max_files }
            end
        end
    end
    return out
end

local function newest(glob)
    local l = lines(("ls -d %s 2>/dev/null | LC_ALL=C sort -V | tail -1"):format(glob))
    return l[1]
end

--- The libraries installed on this machine, in a fixed order (names sorted).
local function libraries(opts)
    local out = {}
    local cap = opts.lib_files or 150
    -- the standard libraries: one HUGE scope each
    local py = newest("/usr/lib/python3.[0-9]*")
    if py and util.is_dir(py) then
        out[#out + 1] = { name = "cpython-stdlib", kind = "lib", root = py, max_files = opts.huge_files or 1500 }
    end
    local rb = newest("/usr/lib/ruby/[0-9]*")
    if rb and util.is_dir(rb) then
        out[#out + 1] = { name = "ruby-stdlib", kind = "lib", root = rb, max_files = opts.huge_files or 1500 }
    end
    if util.is_dir("/usr/share/perl5") then
        out[#out + 1] = { name = "perl5-modules", kind = "lib", root = "/usr/share/perl5", max_files = opts.huge_files or 1500 }
    end
    -- Node packages, with their real READMEs (/usr/share/doc/node-<name>/README.md)
    for _, dir in ipairs(lines("ls -d /usr/share/nodejs/*/ 2>/dev/null | LC_ALL=C sort")) do
        local base = dir:gsub("/$", ""):match("([^/]+)$")
        if base and not base:match("^@") then
            local doc = "/usr/share/doc/node-" .. base
            out[#out + 1] = { name = "node-" .. slug(base), kind = "lib", root = dir:gsub("/$", ""), max_files = cap,
                              scan_root = exists(doc .. "/README.md") and doc or nil }
        end
    end
    -- Lua libraries
    for _, dir in ipairs(lines("ls -d /usr/share/lua/5.1/*/ 2>/dev/null | LC_ALL=C sort")) do
        local base = dir:gsub("/$", ""):match("([^/]+)$")
        out[#out + 1] = { name = "lua-" .. slug(base), kind = "lib", root = dir:gsub("/$", ""), max_files = cap }
    end
    return out
end

--- opts: own_dirs (default: the parents this owner keeps repositories in), seed (the order
--- of the libraries after the huge ones), huge_files, lib_files, only = { name = true },
--- extra = { sources } (tests).
--- → the sources, in build order: the owner's projects, the huge libraries, the other libraries
--- (a seeded shuffle).
function M.discover(opts)
    opts = opts or {}
    if opts.extra then return opts.extra end
    -- (a project that is a crawl of thousands of pages is sampled like a library: its files
    -- would be most of the corpus)
    local own = own_projects(opts.own_dirs or { "/mnt/k/repositorios github", "/root/projects" }, opts.own_files or 1500)
    local libs = libraries(opts)
    local huge, rest = {}, {}
    for _, s in ipairs(libs) do
        if s.max_files and s.max_files >= (opts.huge_files or 1500) then huge[#huge + 1] = s else rest[#rest + 1] = s end
    end
    -- seeded shuffle (Fisher–Yates with a small LCG: reproducible, no math.random state)
    local state = (tonumber(opts.seed) or 1) % 2147483647
    if state == 0 then state = 1 end
    for i = #rest, 2, -1 do
        state = (state * 48271) % 2147483647
        local j = (state % i) + 1
        rest[i], rest[j] = rest[j], rest[i]
    end
    local out = {}
    for _, group in ipairs({ own, huge, rest }) do
        for _, s in ipairs(group) do
            if not opts.only or opts.only[s.name] then out[#out + 1] = s end
        end
    end
    return out
end

return M
