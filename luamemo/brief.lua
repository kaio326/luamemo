-- luamemo/brief.lua
-- The session brief: a tiny, no-query digest (~5 lines) for the start of a session —
-- what memory and what codebase map exist for the project, which tools to reach for,
-- and what waits for the user (org pairing, proposals). `memo brief` prints it for the
-- SessionStart hooks; the MCP tool memory_brief returns it to clients without hooks.
-- Fail-soft: on any error it still returns a minimal block rather than throwing.

local M = {}

--- The brief's text for `scope` (nil: no memory summary, the line says how to get one).
--- opts.extra: more lines, before the end marker (the MCP server's client warnings).
function M.text(scope, opts)
    opts = opts or {}
    scope = (type(scope) == "string" and scope ~= "") and scope or nil
    local lines = { "=== LUAMEMO ===" }

    local okq, dberr = pcall(function()
        local db    = require("luamemo.db")
        local store = require("luamemo.store")
        local tbl   = store.table_name()

        -- Memory summary for the scope.
        if scope then
            local n, cerr = db.value("SELECT COUNT(*) FROM " .. tbl .. " WHERE scope = ?", scope)
            if not n then error(cerr or "no database") end
            n = tonumber(n) or 0
            local rows = db.query("SELECT title FROM " .. tbl .. " WHERE scope = ? "
                .. "AND tier >= 1 ORDER BY created_at DESC, id DESC LIMIT 3", scope)
            local titles = {}
            for _, r in ipairs(rows or {}) do
                if r.title and r.title ~= "" then
                    -- Show the full title up to a generous cap; only ellipsize
                    -- when genuinely longer, so a mid-word cut doesn't read as
                    -- "incomplete — go fetch the rest" (which makes the agent
                    -- re-query and defeats the digest's purpose).
                    local t = r.title
                    if #t > 110 then t = require("luamemo.util").cut_utf8(t, 110):gsub("%s+%S*$", "") .. "…" end
                    titles[#titles + 1] = '"' .. t .. '"'
                end
            end
            local latest = (#titles > 0) and (" · latest: " .. table.concat(titles, ", ")) or ""
            lines[#lines + 1] = ("memory: %s — %d memories%s"):format(scope, n, latest)
        else
            lines[#lines + 1] = "memory: pass --scope repo:<name> to summarise a project"
        end

        -- Codebase map summary (derive codeindex scope from the memory scope).
        local index  = require("luamemo.index")
        local map_scope = "codeindex:" .. index.project_of(scope)   -- (memo index ingest's own rule)
        local counts = index.status({ scope = map_scope })
        local mapped = counts and ((counts.file or 0) + (counts.symbol or 0)) > 0
        if mapped then
            lines[#lines + 1] = ("map:    %s — %d files / %d symbols indexed"):format(
                map_scope, counts.file or 0, counts.symbol or 0)
            lines[#lines + 1] = "tools:  memory_search (decisions/facts) · "
                .. "index_search (find code) · index_outline <file> before editing"
        else
            lines[#lines + 1] = ("map:    none for %s — build with: memo index ingest"):format(map_scope)
            lines[#lines + 1] = "tools:  memory_search (decisions/facts)"
        end

        -- Federation (dev): refresh a stale org replica (TTL-debounced, time-boxed
        -- to fit the SessionStart hook, offline-safe) and tell the agent it exists.
        if require("luamemo.federation.policy").role() == "dev" then
            local client = require("luamemo.federation.client")
            client.maybe_sync({ budget_s = 4, timeout_ms = 2000 })
            local org = client.org_scope()
            local paired = require("luamemo.federation.keys").public_key("dev") ~= nil
            if not paired then
                -- Pairing needs a person: the dev reads a code to the org admin.
                lines[#lines + 1] = "org:    this device is not paired yet — run: memo org pair "
                    .. "(the user reads the code it shows to their org admin, who approves it)"
            elseif org then
                local oc = db.value("SELECT COUNT(*) FROM " .. tbl .. " WHERE scope = ?", org)
                lines[#lines + 1] = ('org:    %s — %d org memories (read-only) · search with scopes=["%s", "%s"]')
                    :format(org, tonumber(oc) or 0, scope or "repo:<name>", org)
                local st = client.status()
                if st.last_pull_ok == false and st.last_error then
                    lines[#lines + 1] = "org:    last sync failed: "
                        .. require("luamemo.util").cut_utf8(tostring(st.last_error), 160)
                end
            else
                lines[#lines + 1] = "org:    not synced yet — if pairing is pending, the org admin approves the "
                    .. "code from `memo org pair`; then: memo org sync"
            end
        elseif require("luamemo.federation.policy").role() == "org" then
            -- The central: what waits for the admin (the decisions are theirs, never the agent's).
            pcall(function()
                local util = require("luamemo.util")
                local pairing = util.table_exists("lm_org_devs")
                    and #require("luamemo.federation.devs").list("pending") or 0
                local props = util.table_exists("lm_org_proposals")
                    and (require("luamemo.federation.knowledge").counts().pending or 0) or 0
                if pairing > 0 or props > 0 then
                    lines[#lines + 1] = ("org:    %d pairing request(s), %d knowledge proposal(s) await the org "
                        .. "admin — memo org devs pending · memo org review (show them; the admin decides)")
                        :format(pairing, props)
                end
            end)
        end
    end)

    -- A project settings file luamemo ignores (memo didn't write it and nobody trusted it):
    -- the database and scope then come from the user's own settings, so the agent's
    -- memories may land elsewhere — said here, where the agent reads it (stderr is hidden).
    -- Trusting is the user's step.
    local note = M.settings_note()
    if note then lines[#lines + 1] = note end

    if not okq then
        lines[#lines + 1] = "status: memory database unavailable (check MEMO_DB in .luamemorc — or run memo calibrate)"
        if os.getenv("MEMO_DEBUG") == "1" then
            lines[#lines + 1] = "debug: " .. tostring(dberr)
        end
    end

    for _, l in ipairs(opts.extra or {}) do lines[#lines + 1] = l end
    lines[#lines + 1] = "=== END ==="
    return table.concat(lines, "\n")
end

--- The line about the project's settings file when luamemo ignores it, or some of it
--- (settings.files: untrusted, user_only) — nil when it is used as it is.
function M.settings_note()
    local ok, note = pcall(function()
        local settings = require("luamemo.settings")
        local files = settings.files()
        if files.untrusted then
            return ("settings: %s is ignored — %s. Tell the user: they review it, then run memo config trust "
                .. "in that folder (until then the database and scope come from ~/.luamemorc)")
                :format(files.paths.project, files.untrusted)
        elseif files.user_only then
            return "settings: " .. settings.user_only_message(files.paths.project, files.user_only)
        end
    end)
    return ok and note or nil
end

return M
