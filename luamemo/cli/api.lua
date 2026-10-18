-- luamemo.cli.api
-- Single-operation dispatcher for cli/memo and mcp/server.lua.
--
-- Usage:
--   lua -e "require('luamemo.cli.api').dispatch('write')"    < input.json
--   lua -e "require('luamemo.cli.api').dispatch('search')"   < input.json
--
-- Input:  one JSON object on stdin (or second arg[])
-- Output: one JSON object on stdout
--
-- Config: MEMO_DB — the database name or path (see luamemo.db).
--   Optional: MEMO_MASTER_KEY  (for secret-* commands)
--
-- Commands:
--   write            store.write(args)
--   write-many       NDJSON stream from stdin → store.write per line
--   search           store.search(args)
--   recent           store.recent(args)
--   get              store.get(id)
--   update           store.update(id, patch)
--   delete           store.delete(id)
--   summarize        summarizer.run(args)
--   promote          summarizer.promote(args)
--   consolidate      summarizer.consolidate(args)
--   digest           digest.run(scope, opts)
--   kg-query         kg.query(args)
--   kg-assert        kg.assert_fact(args)
--   kg-invalidate    kg.invalidate(args)
--   kg-timeline      kg.timeline(args)
--   secret-list      secrets.list()
--   secret-store     secrets.store(name, value, desc)
--   secret-delete    secrets.delete(name)
--   secret-execute   secrets.execute_with_secret(name, opts)
--   context          composite: store.search + kg.query → formatted block
--   reembed          store.reembed_scope(scope) — or every scope with all = true
--   db-info          open / create the database → path, created, counts (calibrate)
--   delete-where     store.match_where / delete_where (memo delete by filter)
--   embed            embed.inspect(text, opts)
--   sense            sensing (memo sense)
--   learn            promote.run / learner_store.status / rollback
--   tune-weights     tune_weights.recommend(args) → report + text
--   brief            the session-start digest

local M = {}

local json  = require("luamemo.json")
local util  = require("luamemo.util")

-- ---------------------------------------------------------------------------
-- Bootstrap: call luamemo.setup() with config from env vars.
-- Must be called before any library functions.
-- ---------------------------------------------------------------------------
local _setup_done = false
local function ensure_setup()
    if _setup_done then return end
    _setup_done = true
    local ok, luamemo = pcall(require, "luamemo")
    if not ok then
        -- luamemo.init not strictly needed for db-only operations,
        -- but it sets up config defaults. Silently skip if unavailable.
        return
    end
    -- Shared MEMO_* → config construction (incl. the vault's key); see cli._common.
    local cfg = require("luamemo.cli._common").config_from_env()
    local ok2, err = pcall(luamemo.setup, cfg)
    if not ok2 then
        io.stderr:write("luamemo.setup warning: " .. tostring(err) .. "\n")
    end
end

-- ---------------------------------------------------------------------------
-- JSON helpers
-- ---------------------------------------------------------------------------
local function read_json_stdin()
    local raw = io.read("*a")
    if not raw or raw:match("^%s*$") then return {} end
    local t, err = json.decode(raw)
    if not t then
        io.stderr:write("api: invalid JSON on stdin: " .. tostring(err) .. "\n")
        return {}
    end
    return t
end

local function out(t)
    io.write(json.encode(t) .. "\n")
    io.flush()
end

local function err_out(msg)
    out({ ok = false, error = tostring(msg) })
end

local list = json.list   -- an empty list encodes as []

-- Coerce string "true"/"1" to true, "false"/"0" to false.
local to_bool = util.to_bool

-- The operations memo shares with the MCP server (their arguments read in one place).
local ops = require("luamemo.ops")

-- ---------------------------------------------------------------------------
-- Command handlers
-- ---------------------------------------------------------------------------

local handlers = {}

-- The scope a write lands in when it names none: the project's (MEMO_SCOPE), as on MCP
-- — else store's MEMO_DEFAULT_SCOPE. (memo write used to skip MEMO_SCOPE: a memory
-- written from the terminal landed in "global", where the agent's searches, scoped to
-- the project, never found it.)
local function write_scope(s)
    if type(s) == "string" and s ~= "" then return s end
    local env = os.getenv("MEMO_SCOPE")
    return (env and env ~= "") and env or nil
end

-- write
handlers["write"] = function(p)
    local fields, ferr = ops.write_fields(p, write_scope(p.scope))   -- memo write --tier / --created-at …
    if not fields then return err_out(ferr) end
    local row, err, action = require("luamemo.store").write(fields)
    if not row then return err_out(err) end
    out({ ok = true, memory = row, action = action })
end

-- write-many: reads NDJSON from stdin, writes each line, streams one result
-- line per input ({ok=true,…} or {ok=false,error=…}) so the calibrate ingest
-- loop counts failures too, not only successes.
-- Used by calibrate ingest loop.
handlers["write-many"] = function(_p)
    local store = require("luamemo.store")
    local written, errors = 0, 0
    for raw_line in io.lines() do
        local line = raw_line:match("^%s*(.-)%s*$") -- trim
        if line ~= "" then
            local p, jerr = json.decode(line)
            if not p then
                io.stderr:write("write-many: bad JSON line: " .. tostring(jerr) .. "\n")
                errors = errors + 1
                err_out("bad JSON line: " .. tostring(jerr))
            else
                local fields, werr = ops.write_fields(p, write_scope(p.scope))
                local row, action
                if fields then row, werr, action = store.write(fields) end
                if not row then
                    io.stderr:write("write-many: " .. tostring(werr) .. "\n")
                    errors = errors + 1
                    err_out(werr)
                else
                    written = written + 1
                    -- stream each result as NDJSON for progress reporting
                    io.write(json.encode({ ok = true, memory = row, action = action }) .. "\n")
                    io.flush()
                end
            end
        end
    end
    -- final summary on stderr so the shell can display it
    io.stderr:write("write-many: done — " .. written .. " written, " .. errors .. " errors\n")
end

-- search
-- search (luamemo.ops.search): with no --scope, every scope; the facts its query is about
-- come along, as on MCP.
handlers["search"] = function(p)
    local rows, facts = ops.search(p)
    if not rows then return err_out(facts) end
    out({ ok = true, results = list(rows), facts = #facts > 0 and facts or nil })
end

-- recent
handlers["recent"] = function(p)
    local rows, err = ops.recent(p)
    if not rows then return err_out(err) end
    out({ ok = true, results = list(rows) })
end

-- get
handlers["get"] = function(p)
    local store = require("luamemo.store")
    local id = p.id or p[1]
    if not id then return err_out("get: id is required") end
    local row, err = store.get(tonumber(id))
    if not row then return err_out(err) end
    out({ ok = true, memory = row })
end

-- update
handlers["update"] = function(p)
    local id = p.id or p[1]
    if not id then return err_out("update: id is required") end
    local row, err = ops.update(id, p)   -- (memo update ID --scope S moves it, policy-checked)
    if not row then return err_out(err) end
    out({ ok = true, memory = row })
end

-- delete
handlers["delete"] = function(p)
    local store = require("luamemo.store")
    local id = p.id or p[1]
    if not id then return err_out("delete: id is required") end
    local ok, err = store.delete(tonumber(id))
    if not ok then return err_out(err) end
    out({ ok = true })
end

-- embed (memo embed TEXT [--compare-to TEXT] [--json]): the embedder's view of a text.
handlers["embed"] = function(p)
    local res, err = ops.embed(p)
    if not res then return err_out(err) end
    res.ok = true
    out(res)
end

-- delete-where (memo delete --scope S [--kind K] [--meta JSON] [--yes]): without
-- yes, only what would be deleted.
handlers["delete-where"] = function(p)
    local store = require("luamemo.store")
    if type(p.scope) ~= "string" or p.scope == "" then
        return err_out("delete: --scope is required to delete by filter")
    end
    local filter = { scope = p.scope, kind = p.kind, metadata_filter = p.metadata_filter }
    if p.yes ~= true then
        local m, err = store.match_where(filter, 5)
        if not m then return err_out(err) end
        return out({ ok = true, deleted = 0, count = m.count, titles = list(m.titles),
            note = m.count > 0 and ("nothing deleted — re-run with --yes to delete these %d memories"):format(m.count)
                or "nothing matches" })
    end
    local n, err = store.delete_where(filter)
    if not n then return err_out(err) end
    out({ ok = true, deleted = n })
end

-- The maintenance and learning operations (luamemo.ops): the answer as ops gives it.
local function op(f, ...)
    local res, err = f(...)
    if not res then return err_out(err) end
    out(res)
end
-- summarize: no --scope, every scope.
handlers["summarize"] = function(p) op(ops.summarize, p, p.scope) end
handlers["promote"] = function(p) op(ops.promote, p) end
handlers["consolidate"] = function(p) op(ops.consolidate, p) end
handlers["digest"] = function(p) op(ops.digest, p, p.scope) end
-- sense: the turns the agent relays ([{role, text}, …]) — luamemo can't read the chat.
handlers["sense"] = function(p) op(ops.sense, p, p.scope) end
-- learn: the scope's reranker — run (promoted only if it beats the current one on a
-- held-out split), status, rollback.
handlers["learn"] = function(p) op(ops.learn, p, p.scope) end

-- reembed: re-embed every memory in a scope (or, with all, in every scope but an
-- org replica — it re-embeds on sync) with the CURRENTLY configured embedder.
-- Needed after switching embedders — two different models' vector spaces are
-- never comparable (even at the same embed_dim), so existing rows silently lose
-- vector-search relevance until re-embedded. A database moves to a new vector
-- size only once every scope is re-embedded.
handlers["reembed"] = function(p)
    local store = require("luamemo.store")
    local opts = { batch = tonumber(p.batch), dry_run = (p.dry_run == true) }
    if p.all == true then
        local policy = require("luamemo.federation.policy")
        local rows, qerr = require("luamemo.db").query("SELECT DISTINCT scope FROM lm_memories ORDER BY scope")
        if not rows then return err_out(qerr) end
        local results, failed = {}, false
        for _, r in ipairs(rows) do
            if not policy.replica(r.scope) then
                local result, err = store.reembed_scope(r.scope, opts)
                results[#results + 1] = { scope = r.scope, result = result, error = err }
                if not result then failed = true end
            end
        end
        return out({ ok = not failed, results = results })
    end
    local scope = p.scope
    if not scope or scope == "" then return err_out("reembed: scope required (or all)") end
    local result, err = store.reembed_scope(scope, opts)
    if not result then return err_out(err) end
    out({ ok = true, result = result })
end

-- tune-weights: which hybrid_weights blend finds this scope's memories best (a report —
-- a person applies it with memo config set).
handlers["tune-weights"] = function(p)
    local report, err = ops.tune_weights(p, p.scope)
    if not report then return err_out(err) end
    out({ ok = true, report = report, text = require("luamemo.tune_weights").format(report) })
end

-- kg-query
handlers["kg-query"] = function(p)
    local kg = require("luamemo.kg")
    local rows, err = kg.query({
        scope               = p.scope,
        subject             = p.subject,
        predicate           = p.predicate,
        object              = p.object,
        at                  = p.at,
        include_invalidated = to_bool(p.include_invalidated),
        limit               = tonumber(p.limit),
    })
    if not rows then return err_out(err) end
    out({ ok = true, results = list(rows) })
end

-- kg-assert
handlers["kg-assert"] = function(p)
    local kg = require("luamemo.kg")
    local row, err = kg.assert_fact({
        scope            = p.scope,
        subject          = p.subject,
        predicate        = p.predicate,
        object           = p.object,
        valid_from       = p.valid_from,
        source_memory_id = tonumber(p.source_memory_id),
        supersede        = to_bool(p.supersede),
    })
    if not row then return err_out(err) end
    out({ ok = true, fact = row })
end

-- kg-invalidate
handlers["kg-invalidate"] = function(p)
    local kg = require("luamemo.kg")
    local n, err = kg.invalidate({
        scope     = p.scope,
        subject   = p.subject,
        predicate = p.predicate,
        object    = p.object,
        at        = p.at,
    })
    if not n then return err_out(err) end
    out({ ok = true, invalidated = n })
end

-- kg-timeline
handlers["kg-timeline"] = function(p)
    local kg = require("luamemo.kg")
    local rows, err = kg.timeline({
        scope     = p.scope,
        subject   = p.subject,
        predicate = p.predicate,
    })
    if not rows then return err_out(err) end
    out({ ok = true, results = list(rows) })
end

-- secret-list
handlers["secret-list"] = function(_p)
    local secrets = require("luamemo.secrets")
    if not secrets.enabled() then
        return err_out(secrets.NOT_CONFIGURED)
    end
    local rows = secrets.list()
    out({ ok = true, secrets = list(rows) })
end

-- secret-store
handlers["secret-store"] = function(p)
    local secrets = require("luamemo.secrets")
    if not secrets.enabled() then
        -- `memo secret-store` is a person at a terminal: set the vault up (its key file).
        local path, kerr = secrets.create_default_key()
        if not path then return err_out(kerr) end
        io.stderr:write(("memo secret-store: created the vault key %s — keep it: the stored secrets "
            .. "can't be read without it\n"):format(path))
    end
    if not p.name or p.name == "" then return err_out("name is required") end
    if not p.value or p.value == "" then return err_out("value is required") end
    local row, err = secrets.store(p.name, p.value, p.description)
    if not row then return err_out(err) end
    out({ ok = true, secret = row })
end

-- secret-delete
handlers["secret-delete"] = function(p)
    local secrets = require("luamemo.secrets")
    local name = p.name or p[1]
    if not name or name == "" then return err_out("name is required") end
    local ok, err = secrets.delete(name)
    if not ok then return err_out(err) end
    out({ ok = true })
end

-- secret-execute
handlers["secret-execute"] = function(p)
    local secrets = require("luamemo.secrets")
    local name = p.name or p[1]
    if not name or name == "" then return err_out("name is required") end
    if not p.url or p.url == "" then return err_out("url is required") end
    local body, err = secrets.execute_with_secret(name, {
        url        = p.url,
        method     = p.method,
        headers    = p.headers,
        body       = p.body,
        multipart  = p.multipart,
        timeout_ms = tonumber(p.timeout_ms),
    })
    if not body then return err_out(err) end
    out({ ok = true, response = body })
end

-- db-info: open the configured database — creating it (and applying its schema)
-- when it doesn't exist yet. Returns
--   { ok=true, path, created (new now), memories, scope?, scope_memories? }
handlers["db-info"] = function(p)
    local db = require("luamemo.db")
    local path, perr = db.path()
    if not path then return err_out(perr) end
    local f = io.open(path, "rb")
    if f then f:close() end
    local h, herr = db.get()
    if not h then return err_out(herr) end
    local res = { ok = true, path = path, created = f == nil,
                  memories = tonumber(db.value("SELECT count(*) FROM lm_memories")) or 0 }
    if type(p.scope) == "string" and p.scope ~= "" then
        res.scope = p.scope
        res.scope_memories = tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope = ?", p.scope)) or 0
    end
    out(res)
end

-- context: composite search + kg-query → formatted block
handlers["context"] = function(p)
    local store = require("luamemo.store")
    local kg    = require("luamemo.kg")
    local q     = p.q or p.query or ""
    local scope = p.scope
    local limit = tonumber(p.limit) or 10
    local no_kg = to_bool(p.no_kg) or false
    local fmt   = p.format or "text"

    local mem_rows, merr = store.search({
        query = q,
        scope = scope,
        limit = limit,
    })
    if not mem_rows then mem_rows = {} end

    local kg_rows = {}
    if not no_kg and scope then
        local rows, _ = kg.query({ scope = scope, limit = 20 })
        if rows then kg_rows = rows end
    end

    if fmt == "json" then
        out({ ok = true, memories = list(mem_rows), kg_facts = list(kg_rows) })
        return
    end

    -- Text format: compact, prompt-injection-ready block.
    local lines = {}
    lines[#lines+1] = "=== MEMORY CONTEXT ==="
    if scope then lines[#lines+1] = "scope: " .. scope end
    lines[#lines+1] = 'query: "' .. q .. '"'
    lines[#lines+1] = ""

    if #mem_rows > 0 then
        for i, m in ipairs(mem_rows) do
            lines[#lines+1] = "[" .. i .. "] " .. (m.kind or "?") .. " — " .. (m.title or "")
            lines[#lines+1] = (m.body or "")
            lines[#lines+1] = ""
        end
    else
        lines[#lines+1] = "(no memories found)"
        lines[#lines+1] = ""
    end

    if #kg_rows > 0 then
        lines[#lines+1] = "=== GROUND TRUTH (knowledge graph) ==="
        for _, f in ipairs(kg_rows) do
            lines[#lines+1] = "• " .. (f.subject or "") .. " " .. (f.predicate or "") .. " " .. (f.object or "")
        end
        lines[#lines+1] = ""
    end

    lines[#lines+1] = "=== END CONTEXT ==="
    -- Emit as JSON wrapper with a "text" field so cli/memo can extract it.
    out({ ok = true, text = table.concat(lines, "\n") })
end

-- brief: the session-start digest (luamemo.brief) — memo brief prints it for the
-- SessionStart hooks; the MCP tool memory_brief returns the same text.
handlers["brief"] = function(p)
    out({ ok = true, text = require("luamemo.brief").text(p.scope) })
end

-- ---------------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------------

function M.dispatch(cmd)
    ensure_setup()
    cmd = cmd or arg and arg[1] or os.getenv("MEMO_API_CMD") or ""
    local handler = handlers[cmd]
    if not handler then
        err_out("api: unknown command: " .. tostring(cmd))
        os.exit(1)
    end
    -- write-many reads NDJSON directly from stdin; the handler ignores
    -- the pre-parsed param and calls io.lines() itself.  Skip read_json_stdin()
    -- to avoid consuming the entire NDJSON stream before the handler runs.
    local p = (cmd ~= "write-many") and read_json_stdin() or {}
    local ok, err = pcall(handler, p)
    if not ok then
        err_out("api: internal error in " .. cmd .. ": " .. tostring(err))
    end
end

return M
