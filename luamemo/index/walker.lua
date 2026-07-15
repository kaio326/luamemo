-- luamemo.index.walker
-- Pure file walker. No config, no DB. Safe to require() directly.
--
-- Strategy (tried in order):
--   1. lfs.dir() when LuaFileSystem is available
--   2. io.popen("find ...") on Unix
--   3. io.popen("dir /s /b ...") on Windows
--   4. nil, error message

local M = {}

local DEFAULT_EXTENSIONS   = { lua = true }
local DEFAULT_MAX_BYTES    = 512 * 1024   -- 512 KB
local BINARY_SAMPLE_BYTES  = 256
local BINARY_THRESHOLD     = 0.10         -- >10% non-printable → binary

-- Simple glob/prefix pattern matcher for exclude_patterns.
-- Supports path prefix matches and basic glob patterns.
local function _glob_match(pattern, path)
    -- Exact prefix match (e.g. ".git", "vendor/").
    if path:sub(1, #pattern) == pattern then return true end
    -- Escape magic chars except * which we handle specially.
    local esc = pattern:gsub("([%.%+%-%?%^%$%(%)%[%]%{%}|])", "%%%1")
    esc = esc:gsub("%*%*", "\0"):gsub("%*", "[^/\\]*"):gsub("\0", ".*")
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
        local ok, iter = pcall(lfs.dir, dir)
        if ok then
            for entry in iter do
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
    for line in pipe:lines() do
        line = line:gsub("\r$", "")
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

-- popen-based walk (Windows dir).
local function _walk_dir(root, opts)
    local all_mode, exts = _resolve_exts(opts)
    local max_bytes = opts.max_file_bytes or DEFAULT_MAX_BYTES
    local excludes  = opts.exclude_patterns or {}
    local results   = {}
    -- All-files mode: a single "dir /s /b" over everything. Otherwise one pass
    -- per extension. Both rely on the binary/size/exclude checks below.
    local patterns = {}
    if all_mode then
        patterns[1] = ('dir /s /b "%s\\*" 2>nul'):format(root)
    else
        for ext in pairs(exts) do
            if _shell_safe_ext(ext) then
                patterns[#patterns + 1] = ('dir /s /b "%s\\*.%s" 2>nul'):format(root, ext)
            elseif opts.warn_fn then
                opts.warn_fn("skipping unsafe extension: " .. tostring(ext))
            end
        end
    end
    for _, cmd in ipairs(patterns) do
        local pipe = io.popen(cmd)
        if pipe then
            for line in pipe:lines() do
                line = line:gsub("\r$", "")
                local rel = line:sub(#root + 2)
                local entry = line:match("[^/\\]+$") or ""
                local sz  = _file_size(line)
                if not _is_excluded(rel, entry, excludes)
                   and sz <= max_bytes and not _is_binary(line) then
                    results[#results + 1] = { path = line, rel = rel, mtime = nil }
                end
            end
            pipe:close()
        end
    end
    return results
end

local function _norm(root)
    return root:gsub("[/\\]+$", "")
end

-- Public API
-- walk(root, opts) → list of { path, rel, mtime }, or nil, err
-- opts:
--   extensions       = { lua=true, ... } | "*"  (default: { lua=true };
--                       "*" = every non-binary text file, no extension filter,
--                       including extensionless files like Makefile/Dockerfile)
--   max_file_bytes   = number                   (default: 524288)
--   exclude_patterns = { "pattern", ... }       (matched against rel path and basename)
--   warn_fn          = function(msg)            (called for skipped files)
function M.walk(root, opts)
    opts = opts or {}
    root = _norm(root)

    local lfs_ok, lfs = pcall(require, "lfs")
    if lfs_ok and lfs and lfs.dir then
        return _walk_lfs(lfs, root, opts)
    end

    -- Unix fallback
    local uname = io.popen("uname 2>/dev/null")
    local is_unix = false
    if uname then
        local out = uname:read("*l") or ""
        is_unix = out ~= ""
        uname:close()
    end

    if is_unix then
        local res, find_err = _walk_find(root, opts)
        if res then return res end
        -- fall through to Windows fallback on error
        if opts.warn_fn then opts.warn_fn("find failed: " .. tostring(find_err)) end
    end

    -- Windows fallback
    local res = _walk_dir(root, opts)
    if res and #res > 0 then return res end

    return nil, "walker: no working filesystem API found (tried lfs, find, dir)"
end

return M
