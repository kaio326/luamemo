-- luamemo.index.digester
-- Pure-Lua unified diff parser. No config, no DB.
-- Safe to require() directly without setup().
--
-- Supports the standard unified diff format produced by git diff and patch(1):
--   diff --git a/file b/file   (git header, optional)
--   --- a/file
--   +++ b/file
--   @@ -from_start,from_count +to_start,to_count @@ [optional function name]
--   -removed line
--   +added  line
--    context line

local M = {}

local MAX_BODY_BYTES = 2000   -- clip raw_hunk before embedding

-- Parse the @@ header to extract from_start, from_count, to_start, to_count.
-- Returns 4 numbers or nil.
local function _parse_hunk_header(line)
    local fs, fc, ts, tc = line:match("^@@%s*%-(%d+),?(%d*)%s*%+(%d+),?(%d*)%s*@@")
    if not fs then return nil end
    fc = (fc == "" or fc == nil) and 1 or tonumber(fc)
    tc = (tc == "" or tc == nil) and 1 or tonumber(tc)
    return tonumber(fs), fc, tonumber(ts), tc
end

-- Strip the a/ or b/ git prefix from a path.
local function _strip_git_prefix(path)
    return path:match("^[ab]/(.+)$") or path
end

-- Clip a string to at most max_bytes while keeping it valid.
local function _clip(s, max_bytes)
    if #s <= max_bytes then return s end
    return s:sub(1, max_bytes) .. "…"
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- parse(diff_text) → list of hunk tables, or nil, err
--
-- Each hunk table:
--   {
--     file_path   = "luamemo/store.lua",   -- relative path (no a/ b/ prefix)
--     hunk_header = "@@ -74,16 +74,33 @@",
--     from_line   = 74,                    -- first line of the removed block
--     to_line     = 74,                    -- first line of the added block
--     from_count  = 16,
--     to_count    = 33,
--     added       = { "+line1", ... },     -- raw lines with leading +
--     removed     = { "-line1", ... },     -- raw lines with leading -
--     context     = { " line1", ... },     -- unchanged context lines
--     raw_hunk    = "...",                 -- full hunk text, clipped to MAX_BODY_BYTES
--   }
function M.parse(diff_text)
    if type(diff_text) ~= "string" then
        return nil, "digester.parse: expected string"
    end

    local hunks = {}
    local current_file = nil
    local current_hunk = nil
    -- Remaining old-side / new-side lines to consume in the active hunk.
    -- While either is > 0 we are inside the hunk body, and EVERY line is a
    -- body line — even one that looks like "---" (a removed Lua comment) or
    -- "+++" (an added one). This count-driven approach is what makes the
    -- parser robust against diff content that mimics structural markers.
    local old_remaining, new_remaining = 0, 0

    local function _flush_hunk()
        if current_hunk then
            current_hunk.raw_hunk = _clip(current_hunk.raw_hunk, MAX_BODY_BYTES)
            hunks[#hunks + 1] = current_hunk
            current_hunk = nil
        end
        old_remaining, new_remaining = 0, 0
    end

    for raw_line in (diff_text .. "\n"):gmatch("([^\n]*)\n") do
        local in_body = current_hunk and (old_remaining > 0 or new_remaining > 0)

        -- Defensive: a body line never starts with a bare "@@" or "diff --git"
        -- (real content lines always carry a +/-/space prefix). If we see one
        -- while still "in body", the previous hunk's counts were wrong — close
        -- it and reprocess this line as a structural marker.
        if in_body and (raw_line:match("^@@") or raw_line:match("^diff %-%-git ")) then
            _flush_hunk()
            in_body = false
        end

        if in_body then
            -- Inside the hunk body: classify by leading char, decrement counts.
            local lead = raw_line:sub(1, 1)
            if lead == "+" then
                current_hunk.added[#current_hunk.added + 1] = raw_line:sub(2)
                current_hunk.raw_hunk = current_hunk.raw_hunk .. raw_line .. "\n"
                new_remaining = new_remaining - 1
            elseif lead == "-" then
                current_hunk.removed[#current_hunk.removed + 1] = raw_line:sub(2)
                current_hunk.raw_hunk = current_hunk.raw_hunk .. raw_line .. "\n"
                old_remaining = old_remaining - 1
            elseif lead == "\\" then
                -- "\ No newline at end of file" — counts toward neither side.
                current_hunk.raw_hunk = current_hunk.raw_hunk .. raw_line .. "\n"
            else
                -- Context line (leading space, or a bare empty line in the hunk).
                current_hunk.context[#current_hunk.context + 1] = raw_line:sub(2)
                current_hunk.raw_hunk = current_hunk.raw_hunk .. raw_line .. "\n"
                old_remaining = old_remaining - 1
                new_remaining = new_remaining - 1
            end
            if old_remaining <= 0 and new_remaining <= 0 then
                _flush_hunk()
            end

        -- @@ hunk header: opens a new hunk body.
        elseif raw_line:match("^@@") then
            _flush_hunk()
            local fs, fc, ts, tc = _parse_hunk_header(raw_line)
            if fs and current_file then
                current_hunk = {
                    file_path   = current_file,
                    hunk_header = raw_line:match("^(@@[^@]*@@)") or raw_line,
                    from_line   = fs,
                    to_line     = ts,
                    from_count  = fc,
                    to_count    = tc,
                    added       = {},
                    removed     = {},
                    context     = {},
                    raw_hunk    = raw_line .. "\n",
                }
                old_remaining, new_remaining = fc, tc
                -- A zero-length hunk (rare) flushes immediately.
                if old_remaining <= 0 and new_remaining <= 0 then _flush_hunk() end
            end

        -- git diff --git header: ignore (we use +++ line for path).
        elseif raw_line:match("^diff %-%-git ") then
            _flush_hunk()
            -- Don't reset current_file yet; +++ line will do that.

        -- --- a/file line: capture "from" path (secondary; +++ is authoritative).
        elseif raw_line:match("^%-%-%- ") and not raw_line:match("^%-%-%-%-") then
            _flush_hunk()
            local from_path = raw_line:match("^%-%-%- (.+)$")
            if from_path and from_path ~= "/dev/null" then
                current_file = _strip_git_prefix(from_path:match("^(.-)%s*$"))
            end

        -- +++ b/file line: authoritative file path.
        elseif raw_line:match("^%+%+%+ ") and not raw_line:match("^%+%+%+%+") then
            _flush_hunk()
            local to_path = raw_line:match("^%+%+%+ (.+)$")
            if to_path and to_path ~= "/dev/null" then
                current_file = _strip_git_prefix(to_path:match("^(.-)%s*$"))
            end
        end
        -- All other lines outside a hunk (index, mode, similarity, etc.) ignored.
    end

    _flush_hunk()
    return hunks
end

-- parse_file(path) → hunks or nil, err
function M.parse_file(path)
    local f, err = io.open(path, "r")
    if not f then return nil, "digester.parse_file: " .. tostring(err) end
    local content = f:read("*a")
    f:close()
    return M.parse(content)
end

return M
