-- luamemo.index.walker
-- Pure file walker. No config, no DB. Safe to require() directly.
--
-- Strategy (tried in order):
--   1. lfs.dir() when LuaFileSystem is available
--   2. io.popen("find ...")
--   3. nil, error message

local M = {}

local DEFAULT_EXTENSIONS   = { lua = true }
local DEFAULT_MAX_BYTES    = 512 * 1024   -- 512 KB
local BINARY_SAMPLE_BYTES  = 256
local BINARY_THRESHOLD     = 0.10         -- >10% non-printable → binary

-- Credential files are NEVER walked, whatever exclude_patterns / gitignore say:
-- index file rows keep a file's first line and symbol rows its text, and the map
-- is served to agents (index_search) — a DB URL or API key must never land there.
local SECRET_NAMES = {
    [".luamemorc"] = true, [".memorc"] = true,          -- luamemo's own config (MEMO_MASTER_KEY)
    [".env"] = true, [".envrc"] = true,
    [".pgpass"] = true, [".netrc"] = true, [".npmrc"] = true, [".pypirc"] = true,
    [".htpasswd"] = true, [".git-credentials"] = true, [".dockercfg"] = true,
    ["id_rsa"] = true, ["id_dsa"] = true, ["id_ecdsa"] = true, ["id_ed25519"] = true,
}
local SECRET_EXTS   = { pem = true, key = true, p12 = true, pfx = true, jks = true, keystore = true }
local SECRET_DIRS   = { [".ssh"] = true, [".aws"] = true, [".gnupg"] = true }
-- ".env.<variant>" is a secret (.env.local, .env.production) unless it is a
-- committed template.
local ENV_TEMPLATES = { example = true, sample = true, template = true, dist = true }

local function _is_secret(rel)
    local parts = {}
    for p in rel:gmatch("[^/\\]+") do parts[#parts + 1] = p end
    local base = parts[#parts] or rel
    for i = 1, #parts do
        if SECRET_DIRS[parts[i]] then return true end
    end
    if SECRET_NAMES[base] then return true end
    local variant = base:match("^%.env%.(.+)$")
    if variant then return not ENV_TEMPLATES[variant:lower()] end
    local ext = base:match("%.([^%.]+)$")
    if ext and SECRET_EXTS[ext:lower()] then return true end
    return base:match("^lm_master_key") ~= nil      -- luamemo secrets master key
end
--- Is this (relative) path a credential file? Also secret_execute's upload check.
M.is_secret = _is_secret

-- Simple glob/prefix pattern matcher for exclude_patterns.
-- Supports path prefix matches and basic glob patterns.
local function _glob_match(pattern, path)
    -- Exact prefix match (e.g. ".git", "vendor/").
    if path:sub(1, #pattern) == pattern then return true end
    -- Escape magic chars except * which we handle specially.
    local esc = pattern:gsub("([%.%+%-%?%^%$%(%)%[%]%{%}|])", "%%%1")
    -- "**" is parked on a \1 sentinel while single "*" is expanded. Not \0: a
    -- Lua 5.1 pattern ends at an embedded NUL, so gsub("\0", ".*") matched the
    -- empty pattern and put ".*" between every char — each exclude became a
    -- subsequence match (".git" dropped luamemo/sensing/init.lua via g…i…t).
    esc = esc:gsub("%*%*", "\1"):gsub("%*", "[^/\\]*"):gsub("\1", ".*")
    return path:match("^" .. esc .. "$") ~= nil or path:match(esc) ~= nil
end

local function _is_binary(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local sample = f:read(BINARY_SAMPLE_BYTES) or ""
    f:close()
    if #sample == 0 then return false end
    local non_print = 0
    for i = 1, #sample do
        local b = sample:byte(i)
        if b < 9 or (b > 13 and b < 32) or b == 127 then
            non_print = non_print + 1
        end
    end
    return (non_print / #sample) > BINARY_THRESHOLD
end

local function _file_size(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local size = f:seek("end") or 0
    f:close()
    return size
end

local function _is_excluded(rel, entry, excludes)
    if _is_secret(rel) then return true end
    for _, pat in ipairs(excludes) do
        if _glob_match(pat, rel) or _glob_match(pat, entry) then return true end
    end
    return false
end

-- Resolve the extension-filter mode from opts.extensions.
-- Returns: all_mode (bool), exts (table). When opts.extensions == "*" the
-- walker accepts every non-binary file (the extension table is unused).
local function _resolve_exts(opts)
    local all_mode = (opts.extensions == "*")
    local exts = (type(opts.extensions) == "table") and opts.extensions or DEFAULT_EXTENSIONS
    return all_mode, exts
end

-- lfs-based recursive walk. Returns list of { path, rel, mtime } tables.
local function _walk_lfs(lfs, root, opts)
    local all_mode, exts = _resolve_exts(opts)
    local max_bytes = opts.max_file_bytes  or DEFAULT_MAX_BYTES
    local excludes  = opts.exclude_patterns or {}

    local stack   = { root }
    local results = {}
    local seen    = {}   -- symlink guard

    while #stack > 0 do
        local dir  = table.remove(stack)
        -- lfs.dir returns (iterator, dir_object); the iterator needs the object
        -- as its state argument — luafilesystem ≥ 1.8 raises "directory
        -- metatable expected, got nil" when it's dropped.
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if ok then
            for entry in iter, dir_obj do
                if entry ~= "." and entry ~= ".." then
                    local full = dir .. "/" .. entry
                    local rel  = full:sub(#root + 2)

                    -- Symlink guard.
                    local skip = false
                    if lfs.symlinkattributes then
                        local sattr = lfs.symlinkattributes(full)
                        if sattr and sattr.mode == "link" then skip = true end
                    end

                    if not skip and not _is_excluded(rel, entry, excludes) then
                        local fat = lfs.attributes(full)
                        if fat then
                            if fat.mode == "directory" then
                                if not seen[full] then
                                    seen[full] = true
                                    stack[#stack + 1] = full
                                end
                            elseif fat.mode == "file" then
                                local ext = full:match("%.([^%.]+)$")
                                if all_mode or (ext and exts[ext]) then
                                    if fat.size <= max_bytes and not _is_binary(full) then
                                        results[#results + 1] = {
                                            path  = full,
                                            rel   = rel,
                                            mtime = fat.modification,
                                        }
                                    elseif fat.size > max_bytes and opts.warn_fn then
                                        opts.warn_fn("skipping (too large): " .. rel)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return results
end

-- A file extension is only safe to interpolate into a shell command (find/dir)
-- when it is purely alphanumeric. Reject anything else (quotes, spaces, shell
-- metacharacters) to prevent command injection via opts.extensions.
local function _shell_safe_ext(ext)
    return type(ext) == "string" and ext:match("^%w+$") ~= nil
end

-- popen-based walk (Unix find).
local function _walk_find(root, opts)
    local all_mode, exts = _resolve_exts(opts)
    local max_bytes = opts.max_file_bytes  or DEFAULT_MAX_BYTES
    local excludes  = opts.exclude_patterns or {}

    -- In all-files mode emit no -name filter; binary/size checks below gate
    -- inclusion. Otherwise build "( -name '*.lua' -o ... )".
    local name_expr = ""
    if not all_mode then
        local name_parts = {}
        for ext in pairs(exts) do
            if _shell_safe_ext(ext) then
                name_parts[#name_parts + 1] = ("-name '*.%s'"):format(ext)
            elseif opts.warn_fn then
                opts.warn_fn("skipping unsafe extension: " .. tostring(ext))
            end
        end
        name_expr = #name_parts > 0
            and ("\\( " .. table.concat(name_parts, " -o ") .. " \\)")
            or  ""
    end

    local cmd = ("find '%s' -type f %s 2>/dev/null"):format(
        root:gsub("'", "'\\''"), name_expr)
    local pipe = io.popen(cmd)
    if not pipe then return nil, "find: io.popen failed" end

    local results = {}
    for raw_line in pipe:lines() do
        local line = raw_line:gsub("\r$", "")
        local rel = line:sub(#root + 2)
        local entry = line:match("[^/\\]+$") or ""
        if not _is_excluded(rel, entry, excludes) then
            local sz = _file_size(line)
            if sz <= max_bytes and not _is_binary(line) then
                results[#results + 1] = { path = line, rel = rel, mtime = nil }
            elseif sz > max_bytes and opts.warn_fn then
                opts.warn_fn("skipping (too large): " .. rel)
            end
        end
    end
    pipe:close()
    return results
end

local function _norm(root)
    return root:gsub("[/\\]+$", "")
end

-- The files git treats as part of the project under root: tracked + untracked
-- files that are not gitignored (global excludes included), as rel paths.
-- Returns nil — the caller then keeps the plain walk — when git is unavailable,
-- root is not inside a git work tree, or root itself is gitignored (the caller
-- explicitly chose ignored content, e.g. a scratch dir; filtering would empty it).
local function _git_visible(root)
    local q = require("luamemo.util").shell_quote(root)
    local null = "2>/dev/null"
    local function first_line(args)
        local p = io.popen(("git -C %s %s %s"):format(q, args, null))
        if not p then return nil end
        local line = p:read("*l")
        p:close()
        return line
    end
    if first_line("rev-parse --is-inside-work-tree") ~= "true" then return nil end
    if first_line("check-ignore .") == "." then return nil end

    local pipe = io.popen(("git -C %s -c core.quotepath=off ls-files --cached --others --exclude-standard %s")
        :format(q, null))
    if not pipe then return nil end
    local set = {}
    for line in pipe:lines() do
        local rel = line:gsub("\r$", "")
        set[rel] = true
    end
    pipe:close()
    return set
end

-- Drop walked files git ignores. ls-files lists a submodule as one gitlink
-- entry (its directory), so a file whose ancestor directory is in the set lives
-- in a submodule and is kept.
local function _filter_gitignored(files, visible)
    local kept = {}
    for _, f in ipairs(files) do
        local rel = f.rel:gsub("\\", "/")
        local keep = visible[rel]
        if not keep then
            local dir = rel:match("^(.*)/[^/]*$")
            while dir and not keep do
                keep = visible[dir]
                dir = dir:match("^(.*)/[^/]*$")
            end
        end
        if keep then kept[#kept + 1] = f end
    end
    return kept
end

-- Raw filesystem walk (lfs → find), before gitignore filtering.
local function _walk_fs(root, opts)
    local lfs_ok, lfs = pcall(require, "lfs")
    if lfs_ok and lfs and lfs.dir then
        return _walk_lfs(lfs, root, opts)
    end
    local res, find_err = _walk_find(root, opts)
    if res then return res end
    return nil, "walker: " .. tostring(find_err)
end

-- Public API
-- walk(root, opts) → list of { path, rel, mtime }, or nil, err
-- opts:
--   extensions       = { lua=true, ... } | "*"  (default: { lua=true };
--                       "*" = every non-binary text file, no extension filter,
--                       including extensionless files like Makefile/Dockerfile)
--   max_file_bytes   = number                   (default: 524288)
--   exclude_patterns = { "pattern", ... }       (matched against rel path and basename)
--   respect_gitignore = bool                    (default true: inside a git work tree,
--                       skip files git ignores; tracked files are always kept)
--   warn_fn          = function(msg)            (called for skipped files)
-- Credential files (.env, .luamemorc, *.pem, id_rsa, .ssh/, …) are always skipped.
function M.walk(root, opts)
    opts = opts or {}
    root = _norm(root)

    local files, err = _walk_fs(root, opts)
    if files and opts.respect_gitignore ~= false then
        local visible = _git_visible(root)
        if visible then files = _filter_gitignored(files, visible) end
    end
    return files, err
end

M.is_secret = _is_secret

return M
