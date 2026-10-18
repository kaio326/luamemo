-- luamemo.federation.directives
-- Org central: ingest the org's standards documents (Markdown) into the
-- protected core tier of the org scope — tier 3, never decaying — through the
-- directive capability, the ONLY way anything reaches that tier there.
--
--   directives.parse(text, name) → { { key, title, body }, ... }   (pure)
--   directives.sync(path, opts)  → report | nil, err
--
-- Granularity: every level-1/2 ATX section (`#` / `##`) with text is one directive; a level-2
-- title carries its document title for context ("Security — Passwords").
-- Deeper headings stay inside their section, `#` lines inside fenced code are
-- text, YAML front matter is dropped, and text before the first heading is a
-- directive titled by the file name.
--
-- Idempotent, keyed by (source, "<relpath>#<slug>"): unchanged sections are
-- skipped, edited ones updated in place (re-embedded), new ones added, and —
-- unless opts.prune == false — directives of this source whose section is gone
-- are deleted (never after a skipped / unreadable file). `source` defaults to
-- the name of `path` (a file's name without extension), so separate document
-- sets never prune each other.
--   opts: source, project (metadata.project tag; none = org-wide), dry_run,
--         prune (default true), allow_empty, extensions ({ md = true, … })

local db     = require("luamemo.db")
local policy = require("luamemo.federation.policy")

local M = {}

M.MAX_FILE_BYTES = 1024 * 1024
M.DEFAULT_EXTENSIONS = { md = true, markdown = true }

local trim, is_dir = require("luamemo.util").trim, require("luamemo.util").is_dir

local function slugify(s)
    local x = s:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    return x ~= "" and x or "section"
end

local function basename(p) return (p:gsub("[/\\]+$", ""):match("[^/\\]+$")) or p end
local function stem(name) return (name:gsub("%.[^%.]+$", "")) end

--- Split one Markdown document into directive sections. `name` is the file's
--- relative path (the key prefix).
function M.parse(text, name)
    text = tostring(text or ""):gsub("^\239\187\191", ""):gsub("\r\n?", "\n")   -- BOM, CRLF
    if text:sub(1, 4) == "---\n" then                         -- YAML front matter
        local _, e = text:find("\n%-%-%-[ \t]*\n", 4)
        if e then text = text:sub(e + 1) end
    end
    local doc_title = stem(basename(name))
    local out, seen = {}, {}
    local h1
    local cur = { level = 0, lines = {} }
    local function flush()
        local body = trim(table.concat(cur.lines, "\n"))
        if body == "" then return end
        local title, slug
        if cur.level == 0 then title, slug = h1 or doc_title, "_"
        elseif cur.level == 1 then title, slug = cur.heading, slugify(cur.heading)
        else
            title = h1 and (h1 .. " — " .. cur.heading) or cur.heading
            slug  = (h1 and (slugify(h1) .. "/") or "") .. slugify(cur.heading)
        end
        local n = (seen[slug] or 0) + 1
        seen[slug] = n
        if n > 1 then slug = slug .. "-" .. n end
        out[#out + 1] = { key = name .. "#" .. slug, title = title, body = body }
    end
    local fence
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local f = line:match("^ ? ? ?(```+)") or line:match("^ ? ? ?(~~~+)")
        local hashes, heading
        if not fence and not f then
            hashes, heading = line:match("^(##?)[ \t]+(.-)[ \t]*$")
            -- a closing #-run only when space-separated ("## C#" keeps its #)
            if heading then heading = heading:gsub("^#+$", ""):gsub("[ \t]+#+$", "") end
        end
        if f then
            if not fence then fence = f elseif f:sub(1, 1) == fence:sub(1, 1) and #f >= #fence then fence = nil end
            cur.lines[#cur.lines + 1] = line
        elseif hashes and heading ~= "" then
            flush()
            if #hashes == 1 then h1 = heading end
            cur = { level = #hashes, heading = heading, lines = {} }
        else
            cur.lines[#cur.lines + 1] = line
        end
    end
    flush()
    return out
end

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read(M.MAX_FILE_BYTES + 1)
    f:close()
    if data and #data > M.MAX_FILE_BYTES then return nil, "larger than " .. M.MAX_FILE_BYTES .. " bytes" end
    return data or ""
end

--- Sync the directives from a file or directory into the org scope.
function M.sync(path, opts)
    opts = opts or {}
    if policy.role() ~= "org" then
        return nil, "directives: this instance is not an org central (set MEMO_ROLE=org + MEMO_ORG_NAME)"
    end
    local scope = require("luamemo.federation.central").org_scope()
    if not scope then return nil, "directives: org_name is not set" end
    path = tostring(path or ""):gsub("[/\\]+$", "")
    if path == "" then return nil, "directives: a file or directory path is required" end

    local files, skipped = {}, {}
    local dir = is_dir(path)
    if dir then
        local list, werr = require("luamemo.index.walker").walk(path,
            { extensions = opts.extensions or M.DEFAULT_EXTENSIONS, max_file_bytes = M.MAX_FILE_BYTES,
              warn_fn = function(msg) skipped[#skipped + 1] = msg end })
        if not list then return nil, "directives: " .. tostring(werr) end
        for _, f in ipairs(list) do files[#files + 1] = { path = f.path, rel = f.rel } end
        table.sort(files, function(a, b) return a.rel < b.rel end)
    else
        local probe = io.open(path, "rb")
        if not probe then return nil, "directives: not found: " .. path end
        probe:close()
        files[1] = { path = path, rel = basename(path) }
    end
    local source = opts.source or (dir and basename(path) or stem(basename(path)))
    if type(source) ~= "string" or not source:match("^[%w][%w%._%-]*$") or #source > 64 then
        return nil, "directives: invalid source name " .. ("%q"):format(tostring(source))
            .. " (letters, digits, . _ -; at most 64) — pass --source NAME"
    end
    -- Optional project tag (metadata.project): no tag = an org-wide directive.
    local project = opts.project
    if project ~= nil and (type(project) ~= "string" or not project:match("^[%w][%w%._%-]*$") or #project > 64) then
        return nil, "directives: invalid project name (letters, digits, . _ -; at most 64)"
    end

    local report = { scope = scope, source = source, project = project, files = #files, sections = 0,
                     added = 0, updated = 0, unchanged = 0, removed = 0, errors = {},
                     dry_run = opts.dry_run and true or false, plan = {} }
    for _, msg in ipairs(skipped) do report.errors[#report.errors + 1] = msg end
    local want, order = {}, {}
    for _, f in ipairs(files) do
        local text, rerr = read_file(f.path)
        if not text then
            report.errors[#report.errors + 1] = f.rel .. ": " .. tostring(rerr)
        else
            for _, d in ipairs(M.parse(text, f.rel)) do
                want[d.key] = d
                order[#order + 1] = d
            end
        end
    end
    report.sections = #order
    if #order == 0 and opts.prune ~= false and not opts.allow_empty then
        -- An empty or unreadable path must not silently wipe the source's directives.
        return nil, "directives: no sections found under " .. path
            .. " — nothing ingested, nothing pruned (allow_empty / --allow-empty to remove them all)"
    end

    local have = {}
    local rows = db.query("SELECT id, title, body, json_extract(metadata, '$.lm_directive_key') AS k, "
        .. "json_extract(metadata, '$.project') AS p FROM lm_memories "
        .. "WHERE scope = ? AND json_extract(metadata, '$.lm_directive_source') = ?", scope, source) or {}
    for _, r in ipairs(rows) do if r.k then have[r.k] = r end end

    local store = require("luamemo.store")
    local DIR   = policy.capability("directive")
    local COUNTER = { add = "added", update = "updated", remove = "removed" }
    -- Record the action; unless dry-running, perform it (fn → ok, err).
    local function apply(action, key, title, fn)
        report.plan[#report.plan + 1] = { action = action, key = key, title = title }
        local ok, err = true, nil
        if not opts.dry_run then ok, err = fn() end
        if ok then report[COUNTER[action]] = report[COUNTER[action]] + 1
        else report.errors[#report.errors + 1] = key .. ": " .. tostring(err) end
    end

    for _, d in ipairs(order) do
        local meta = { lm_directive_source = source, lm_directive_key = d.key, project = project }
        local cur = have[d.key]
        if cur and cur.title == d.title and cur.body == d.body and cur.p == project then
            report.unchanged = report.unchanged + 1
        elseif cur then
            apply("update", d.key, d.title, function()
                return store.update(cur.id, { title = d.title, body = d.body, metadata = meta,
                    importance = 1.0, decay_rate = 0, _cap = DIR })
            end)
        else
            apply("add", d.key, d.title, function()
                return store.write({ scope = scope, kind = "directive", title = d.title, body = d.body,
                    tags = { "directive" }, metadata = meta, importance = 1.0, decay_rate = 0, tier = 3,
                    _cap = DIR })
            end)
        end
    end
    -- A file that was skipped or unreadable contributes no sections — pruning
    -- now would delete its directives. Never prune on an incomplete read.
    local prune = opts.prune ~= false
    if prune and #report.errors > 0 then
        prune, report.prune_skipped = false, "some files could not be read — nothing pruned"
    end
    if prune then
        local gone = {}
        for key, r in pairs(have) do if not want[key] then gone[#gone + 1] = r end end
        table.sort(gone, function(a, b) return a.k < b.k end)
        for _, r in ipairs(gone) do
            apply("remove", r.k, r.title, function() return store.delete(r.id, { _cap = DIR }) end)
        end
    end
    return report
end

return M
