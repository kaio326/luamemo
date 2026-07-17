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
-- Config: MEMO_DB_URL or individual PG* env vars (see luamemo.db).
--   Optional: MEMO_MASTER_KEY, MEMO_SECRETS_FILE  (for secret-* commands)
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
    -- Shared MEMO_* → config construction (incl. secrets); see cli._common.
    local cfg = require("luamemo.cli._common").config_from_env({ secrets = true })
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

-- Coerce string "true"/"1" to true, "false"/"0" to false.
local to_bool = util.to_bool

-- ---------------------------------------------------------------------------
-- Command handlers
-- ---------------------------------------------------------------------------

local handlers = {}

-- write
handlers["write"] = function(p)
    local store = require("luamemo.store")
    local row, err, action = store.write({
        scope          = p.scope,
        kind           = p.kind,
        title          = p.title,
        body           = p.body,
        tags           = p.tags,
        metadata       = p.metadata,
        importance     = tonumber(p.importance),
        decay_rate     = tonumber(p.decay_rate),
        dedup_strategy = p.dedup_strategy,
        embedding      = p.embedding,
    })
    if not row then return err_out(err) end
    out({ ok = true, memory = row, action = action })
end

-- write-many: reads NDJSON from stdin, writes each line, streams results.
-- Used by calibrate ingest loop.
handlers["write-many"] = function(_p)
    local store = require("luamemo.store")
    local written, errors = 0, 0
    for line in io.lines() do
        line = line:match("^%s*(.-)%s*$") -- trim
        if line ~= "" then
            local p, jerr = json.decode(line)
            if not p then
                io.stderr:write("write-many: bad JSON line: " .. tostring(jerr) .. "\n")
                errors = errors + 1
            else
                local row, werr, action = store.write({
                    scope          = p.scope,
                    kind           = p.kind,
                    title          = p.title,
                    body           = p.body,
                    tags           = p.tags,
                    metadata       = p.metadata,
                    importance     = tonumber(p.importance),
                    decay_rate     = tonumber(p.decay_rate),
                    dedup_strategy = p.dedup_strategy,
                    embedding      = p.embedding,
                })
                if not row then
                    io.stderr:write("write-many: " .. tostring(werr) .. "\n")
                    errors = errors + 1
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
handlers["search"] = function(p)
    local store = require("luamemo.store")
    local rows, err = store.search({
        query        = p.q or p.query,
        scope        = p.scope,
        scopes       = (type(p.scopes) == "table") and p.scopes or nil,
        limit        = tonumber(p.limit),
        min_score    = tonumber(p.min_score),
        kind         = p.kind,
        tags         = p.tags,
        fts_weight   = tonumber(p.fts_weight),
        vec_weight   = tonumber(p.vec_weight),
        decay_weight = tonumber(p.decay_weight),
    })
    if not rows then return err_out(err) end
    out({ ok = true, results = rows })
end

-- recent
handlers["recent"] = function(p)
    local store = require("luamemo.store")
    local rows, err = store.recent({
        scope  = p.scope,
        limit  = tonumber(p.limit),
        kind   = p.kind,
        offset = tonumber(p.offset),
    })
    if not rows then return err_out(err) end
    out({ ok = true, results = rows })
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
    local store = require("luamemo.store")
    local id = p.id or p[1]
    if not id then return err_out("update: id is required") end
    local row, err = store.update(tonumber(id), {
        title      = p.title,
        body       = p.body,
        tags       = p.tags,
        metadata   = p.metadata,
        importance = tonumber(p.importance),
        decay_rate = tonumber(p.decay_rate),
        kind       = p.kind,
    })
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

-- summarize
handlers["summarize"] = function(p)
    local summarizer = require("luamemo.summarizer")
    local result, err = summarizer.run({
        scope          = p.scope,
        dry_run        = to_bool(p.dry_run),
        retention_days = tonumber(p.retention_days),
        batch_size     = tonumber(p.batch_size),
        max_batches    = tonumber(p.max_batches),
    })
    if not result then return err_out(err) end
    out({ ok = true, result = result })
end

-- promote
handlers["promote"] = function(p)
    local summarizer = require("luamemo.summarizer")
    local result, err = summarizer.promote({
        from_scope    = p.from_scope,
        to_scope      = p.to_scope,
        delete_source = to_bool(p.delete_source),
        dry_run       = to_bool(p.dry_run),
        limit         = tonumber(p.limit),
        min_rows      = tonumber(p.min_rows),
    })
    if not result then return err_out(err) end
    local ok_flag = (result.promoted == 1 or result.reason == "no_rows")
    out({ ok = ok_flag, result = result })
end

-- consolidate
handlers["consolidate"] = function(p)
    local summarizer = require("luamemo.summarizer")
    local result, err = summarizer.consolidate({
        scope                = p.scope,
        dry_run              = to_bool(p.dry_run),
        similarity_threshold = tonumber(p.similarity_threshold),
        decay_threshold      = tonumber(p.decay_threshold),
        max_rows             = tonumber(p.max_rows),
    })
    if not result then return err_out(err) end
    out({ ok = true, result = result })
end

-- digest
handlers["digest"] = function(p)
    local d = require("luamemo.digest")
    local scope = p.scope
    if not scope or scope == "" then
        return err_out("digest: scope required")
    end
    local result = d.run(scope, {
        dry_run   = to_bool(p.dry_run),
        threshold = tonumber(p.threshold),
    })
    out({ ok = true, result = result })
end

-- sense: signal capture (Phase 9). The agent relays a session's turns; the
-- sensing pipeline detects corrections/commands/praise and records reinforcements
-- (which feed the tier system AND the learned-from-usage triples). luamemo cannot
-- read the chat itself, so the caller passes `turns` = [{role, text}, ...].
handlers["sense"] = function(p)
    local scope = p.scope
    if not scope or scope == "" then return err_out("sense: scope required") end
    if type(p.turns) ~= "table" then return err_out("sense: turns array required") end
    local sensing = require("luamemo.sensing")
    local result = sensing.process(scope, p.turns, {
        generative     = (p.generative == true),
        min_confidence = tonumber(p.min_confidence),
        min_similarity = tonumber(p.min_similarity),
        delta_scale    = tonumber(p.delta_scale),
    })
    out({ ok = true, result = result })
end

-- learn: per-scope promotion harness (Phase 11). Harvests feedback for the scope,
-- trains the reranker, gates on a held-out split, and promotes the new weights
-- only if they beat the incumbent — else rejects. No-op until enough signal.
handlers["learn"] = function(p)
    local scope = p.scope
    if not scope or scope == "" then return err_out("learn: scope required") end
    local promote = require("luamemo.promote")
    local result = promote.run(scope, {
        min_samples = tonumber(p.min_samples),
        margin      = tonumber(p.margin),
        gate_frac   = tonumber(p.gate_frac),
        epochs      = tonumber(p.epochs),
        dry_run     = (p.dry_run == true),
    })
    out({ ok = true, result = result })
end

-- reembed: re-embed every memory in a scope with the CURRENTLY configured
-- embedder. Needed after switching embedders — two different models' vector
-- spaces are never comparable (even at the same embed_dim), so existing rows
-- silently lose vector-search relevance until re-embedded.
handlers["reembed"] = function(p)
    local store = require("luamemo.store")
    local scope = p.scope
    if not scope or scope == "" then return err_out("reembed: scope required") end
    local result, err = store.reembed_scope(scope, {
        batch   = tonumber(p.batch),
        dry_run = (p.dry_run == true),
    })
    if not result then return err_out(err) end
    out({ ok = true, result = result })
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
    out({ ok = true, results = rows })
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
    out({ ok = true, results = rows })
end

-- secret-list
handlers["secret-list"] = function(_p)
    local secrets = require("luamemo.secrets")
    if not secrets.enabled() then
        return err_out("secrets: not configured (secrets_file or master_key not set)")
    end
    local rows = secrets.list()
    out({ ok = true, secrets = rows })
end

-- secret-store
handlers["secret-store"] = function(p)
    local secrets = require("luamemo.secrets")
    if not secrets.enabled() then
        return err_out("secrets: not configured (secrets_file or master_key not set)")
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

-- schema-check: verify lm_memories and lm_kg_facts tables + columns exist.
-- Returns:
--   { ok=true, tables={ lm_memories={present, missing_cols}, lm_kg_facts={present, missing_cols} } }
handlers["schema-check"] = function(_p)
    local db = require("luamemo.db")

    -- Expected columns per table (covers all migrations 001–009).
    local expected = {
        lm_memories = {
            "id", "scope", "kind", "title", "body", "tags", "metadata",
            "embedding", "importance", "decay_rate", "was_truncated",
            "fts", "created_at", "updated_at", "tier", "consolidated_at",
        },
        lm_kg_facts = {
            "id", "scope", "subject", "predicate", "object",
            "valid_from", "valid_until", "source_memory_id", "created_at",
        },
    }

    local result = { tables = {} }

    for tbl, cols in pairs(expected) do
        -- Query information_schema for columns present in this table.
        local rows, err = db.query(
            "SELECT column_name FROM information_schema.columns "
            .. "WHERE table_schema = 'public' AND table_name = ?",
            tbl)

        if not rows then
            -- DB unreachable or query error — report as table absent.
            result.tables[tbl] = {
                present      = false,
                missing_cols = cols,
                db_error     = tostring(err),
            }
        else
            local found = {}
            for _, row in ipairs(rows) do
                found[row.column_name] = true
            end

            local missing = {}
            for _, col in ipairs(cols) do
                if not found[col] then
                    missing[#missing + 1] = col
                end
            end

            result.tables[tbl] = {
                present      = #rows > 0,
                missing_cols = missing,
            }
        end
    end

    -- Overall ok: both tables present and no missing columns.
    local all_ok = true
    for _, info in pairs(result.tables) do
        if not info.present or #info.missing_cols > 0 then
            all_ok = false
            break
        end
    end
    result.ok = all_ok
    out(result)
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
        out({ ok = true, memories = mem_rows, kg_facts = kg_rows })
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

-- brief: a tiny, no-query session-start digest (~5 lines) meant to be injected
-- automatically (e.g. by a SessionStart hook). Tells the agent what memory and
-- what codebase map exist for the project, and which tools to reach for — so it
-- knows luamemo is available without being asked. Fail-soft: on any error it
-- still returns a minimal block rather than throwing.
handlers["brief"] = function(p)
    local scope = (type(p.scope) == "string" and p.scope ~= "") and p.scope or nil
    local lines = { "=== LUAMEMO ===" }

    local okq, dberr = pcall(function()
        local db    = require("luamemo.db")
        local store = require("luamemo.store")
        local tbl   = store.table_name()

        -- Memory summary for the scope.
        if scope then
            local esc = db.escape_literal(scope)
            local cnt = db.query("SELECT COUNT(*) AS n FROM " .. tbl .. " WHERE scope = " .. esc)
            local n   = cnt and cnt[1] and tonumber(cnt[1].n) or 0
            local rows = db.query("SELECT title FROM " .. tbl .. " WHERE scope = " .. esc
                .. " AND tier >= 1 ORDER BY created_at DESC LIMIT 3")
            local titles = {}
            for _, r in ipairs(rows or {}) do
                if r.title and r.title ~= "" then
                    -- Show the full title up to a generous cap; only ellipsize
                    -- when genuinely longer, so a mid-word cut doesn't read as
                    -- "incomplete — go fetch the rest" (which makes the agent
                    -- re-query and defeats the digest's purpose).
                    local t = r.title
                    if #t > 110 then t = t:sub(1, 110):gsub("%s+%S*$", "") .. "…" end
                    titles[#titles + 1] = '"' .. t .. '"'
                end
            end
            local latest = (#titles > 0) and (" · latest: " .. table.concat(titles, ", ")) or ""
            lines[#lines + 1] = ("memory: %s — %d memories%s"):format(scope, n, latest)
        else
            lines[#lines + 1] = "memory: pass --scope repo:<name> to summarise a project"
        end

        -- Codebase map summary (derive codeindex scope from the memory scope).
        local project = scope and scope:gsub("^%a+:", "") or "default"
        if project == "" then project = "default" end
        local map_scope = "codeindex:" .. project
        local index  = require("luamemo.index")
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
    end)

    if not okq then
        lines[#lines + 1] = "status: memory backend unreachable (check MEMO_DB_URL)"
        if os.getenv("MEMO_DEBUG") == "1" then
            lines[#lines + 1] = "debug: " .. tostring(dberr)
        end
    end

    lines[#lines + 1] = "=== END ==="
    out({ ok = true, text = table.concat(lines, "\n") })
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
