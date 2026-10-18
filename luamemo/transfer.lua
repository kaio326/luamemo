-- luamemo.transfer
-- Moving memories between databases or embedders: `memo export` / `memo import`.
-- The format is JSON Lines, one object per line:
--
--   header (first line; optional for a hand-made file):
--     { "luamemo_export": 1, "version": "…", "db_id": "…", "embedder_sig": "hash||384",
--       "embed_dim": 384, "exported_at": "…", "scopes": ["repo:x", …] }
--   a memory — a line without "type" is one too, so any tool can write one memory per line:
--     { "type": "memory", "id": 12, "scope": "repo:x", "kind": "fact", "title": "…",
--       "body": "…", "tags": […], "metadata": {…}, "importance": 0.5, "decay_rate": 0,
--       "tier": 1, "was_truncated": false, "created_at": "…", "updated_at": "…",
--       "vector": "<base64: the float32 little-endian vector>" }
--   a knowledge-graph fact:
--     { "type": "fact", "scope": "…", "subject": "…", "predicate": "…", "object": "…",
--       "valid_from": "…", "valid_until": "…", "memory": 12 }
-- Timestamps are the API's text ("YYYY-MM-DD HH:MM:SS.ffffff+00"); a line may also give
-- epoch seconds or "YYYY-MM-DD[THH:MM[:SS]][Z|±HH:MM]".
--
--   transfer.export(emit, opts) → report | nil, err
--     emit(text) gets each line. opts.scopes: the scopes to export (default: every
--     scope but an org replica, which re-syncs); opts.vectors = false leaves vectors out.
--   transfer.import(next_line, opts) → report
--     next_line() → the next line | nil at the end. opts.dedup: "append" (default) |
--     "skip" | "update"; opts.scope: the scope of a memory line that names none;
--     opts.dry_run: read and check every line, write nothing.
--
-- Vectors are reused only when the export's embedder is the database's (same signature,
-- same size) — any other embedder's vectors never compare, so those rows are embedded
-- again. Re-importing the same export adds nothing twice: each memory remembers where it
-- came from (metadata.lm_imported_from = "<source database id>:<id>"). Carried: memories
-- and facts. Not carried: learned weights, observations, feedback history — the target
-- rebuilds those from use.

local db      = require("luamemo.db")
local json    = require("luamemo.json")
local util    = require("luamemo.util")
local vectors = require("luamemo.vectors")

local M = {}

M.FORMAT = 1
M.PAGE   = 500    -- rows read per query
M.BATCH  = 100    -- memories per write_many call
M.MAX_ERRORS_KEPT = 20

local function sodium() return require("luamemo.native.sodium") end
local function config() return require("luamemo").config or {} end
local iso = util.us_to_iso
local function meta(key) return db.value("SELECT value FROM lm_meta WHERE key = ?", key) end
local function embedder_sig(cfg) return require("luamemo.federation.common").embedder_sig(cfg) end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------

local function default_scopes()
    local policy = require("luamemo.federation.policy")
    local out = {}
    for _, r in ipairs(db.query("SELECT DISTINCT scope FROM lm_memories ORDER BY scope") or {}) do
        if not policy.replica(r.scope) then out[#out + 1] = r.scope end
    end
    return out
end

function M.export(emit, opts)
    opts = opts or {}
    local scopes = (type(opts.scopes) == "table" and #opts.scopes > 0) and opts.scopes or default_scopes()
    local with_vec = opts.vectors ~= false
    local in_scopes, scopes_json = db.in_list(scopes)
    emit(json.encode({ luamemo_export = M.FORMAT, version = require("luamemo").VERSION, db_id = meta("db_id"),
        embedder_sig = embedder_sig(config()), embed_dim = tonumber(meta("embed_dim")),
        exported_at = iso(util.now_us()), scopes = scopes }))
    local rep = { memories = 0, facts = 0, vectors = 0, scopes = scopes }

    local cursor = 0
    while true do
        local rows, err = db.query("SELECT id, scope, kind, title, body, tags, metadata, importance, decay_rate, "
            .. "tier, was_truncated, created_at, updated_at" .. (with_vec and ", embedding" or "")
            .. " FROM lm_memories WHERE scope IN " .. in_scopes .. " AND id > ? ORDER BY id LIMIT ?",
            scopes_json, cursor, M.PAGE)
        if not rows then return nil, "export: " .. tostring(err) end
        if #rows == 0 then break end
        for _, r in ipairs(rows) do
            cursor = r.id
            local line = { type = "memory", id = r.id, scope = r.scope, kind = r.kind, title = r.title,
                body = r.body, tags = type(r.tags) == "table" and r.tags or {},
                metadata = type(r.metadata) == "table" and r.metadata or {}, importance = r.importance,
                decay_rate = r.decay_rate, tier = r.tier, was_truncated = r.was_truncated == 1,
                created_at = iso(r.created_at), updated_at = iso(r.updated_at) }
            if with_vec and type(r.embedding) == "string" and #r.embedding > 0 then
                line.vector = sodium().to_base64(r.embedding)
                rep.vectors = rep.vectors + 1
            end
            emit(json.encode(line))
            rep.memories = rep.memories + 1
        end
    end

    cursor = 0
    while true do
        local rows, err = db.query("SELECT id, scope, subject, predicate, object, valid_from, valid_until, "
            .. "source_memory_id FROM lm_kg_facts WHERE scope IN " .. in_scopes .. " AND id > ? ORDER BY id LIMIT ?",
            scopes_json, cursor, M.PAGE)
        if not rows then return nil, "export: " .. tostring(err) end
        if #rows == 0 then break end
        for _, r in ipairs(rows) do
            cursor = r.id
            emit(json.encode({ type = "fact", scope = r.scope, subject = r.subject, predicate = r.predicate,
                object = r.object, valid_from = iso(r.valid_from), valid_until = iso(r.valid_until),
                memory = r.source_memory_id }))
            rep.facts = rep.facts + 1
        end
    end
    return rep
end

-- ---------------------------------------------------------------------------
-- Import
-- ---------------------------------------------------------------------------

-- An optional timestamp field → µs | nil, or false + err when it is present but invalid.
local function stamp(v)
    if v == nil then return nil end
    local us, err = util.iso_to_us(v)
    if not us then return false, err end
    return us
end

local function str(v) return type(v) == "string" and v or nil end

function M.import(next_line, opts)
    opts = opts or {}
    local cfg = config()
    local store = require("luamemo.store")
    local rep = { lines = 0, memories = 0, merged = 0, skipped = 0, already = 0, facts = 0, facts_present = 0,
                  vectors_reused = 0, embedded = 0, errors = {}, error_count = 0, dry_run = opts.dry_run == true }
    local function fail(n, msg)
        rep.error_count = rep.error_count + 1
        if #rep.errors < M.MAX_ERRORS_KEPT then rep.errors[#rep.errors + 1] = ("line %d: %s"):format(n, msg) end
    end

    local header, tag, reuse, db_dim
    local map = {}          -- the source's memory id → its id here (this run and earlier imports)
    local batch = {}        -- { n = line number, src = source id | nil, args = write_many row }

    local function flush()
        if #batch == 0 then return end
        local rows = {}
        for i, b in ipairs(batch) do rows[i] = b.args end
        if not opts.dry_run then
            local results = store.write_many(rows, { dedup_strategy = opts.dedup or "append" })
            for i, b in ipairs(batch) do
                local r = results[i] or {}
                if r.error and r.action == nil then
                    fail(b.n, r.error)
                else
                    if r.action == "merged" then rep.merged = rep.merged + 1
                    elseif r.action == "skipped" then rep.skipped = rep.skipped + 1
                    else rep.memories = rep.memories + 1 end
                    if b.src and r.row and r.row.id then map[b.src] = r.row.id end
                    if b.args.embedding then rep.vectors_reused = rep.vectors_reused + 1
                    elseif r.action ~= "skipped" then rep.embedded = rep.embedded + 1 end
                end
            end
        else
            rep.memories = rep.memories + #batch
        end
        batch = {}
    end

    local function start(h)
        header = h
        if type(h.db_id) == "string" and h.db_id ~= "" then
            tag = h.db_id:sub(1, 12)
            -- Rows an earlier run already brought from this source.
            map = require("luamemo.federation.common").origin_map(db, "lm_imported_from", tag)
        end
        db_dim = tonumber(meta("embed_dim"))
        reuse = h.embedder_sig ~= nil and h.embedder_sig == embedder_sig(cfg)
            and (db_dim == nil or tonumber(h.embed_dim) == nil or tonumber(h.embed_dim) == db_dim)
    end

    local function memory_line(n, t)
        local title, body = str(t.title) or "", str(t.body) or ""
        if title == "" and body == "" then return fail(n, "a memory needs a title or a body") end
        local scope = str(t.scope) or opts.scope
        if not scope or scope == "" then return fail(n, "no scope (give the line one, or --scope)") end
        local c_us, cerr = stamp(t.created_at)
        if c_us == false then return fail(n, "created_at: " .. tostring(cerr)) end
        local u_us, uerr = stamp(t.updated_at)
        if u_us == false then return fail(n, "updated_at: " .. tostring(uerr)) end
        -- The line's id: links the facts of this file to their memory; with a header naming
        -- the source database it also makes a second import of the file add nothing.
        local id = tonumber(t.id) and math.floor(tonumber(t.id)) or nil
        local src = tag and id or nil
        if src and map[src] then rep.already = rep.already + 1; return end
        local m = {}
        for k, v in pairs(type(t.metadata) == "table" and t.metadata or {}) do m[k] = v end
        if src then m.lm_imported_from = tag .. ":" .. src end
        local args = { scope = scope, kind = str(t.kind) or "fact", title = title, body = body,
            tags = type(t.tags) == "table" and t.tags or {}, metadata = m, importance = tonumber(t.importance),
            decay_rate = tonumber(t.decay_rate), tier = tonumber(t.tier), created_us = c_us,
            updated_us = u_us or c_us }
        if reuse and type(t.vector) == "string" then
            local raw = sodium().from_base64(t.vector)
            local v = raw and #raw % 4 == 0 and vectors.unpack(raw)
            if v and (db_dim == nil or #v == db_dim) then
                args.embedding, args.was_truncated = v, t.was_truncated == true
            end
        end
        batch[#batch + 1] = { n = n, src = id, args = args }
        if #batch >= M.BATCH then flush() end
    end

    local function fact_line(n, t)
        flush()   -- a fact may name a memory of the batch still pending
        local scope, subject, predicate, object = str(t.scope) or opts.scope, str(t.subject), str(t.predicate),
            str(t.object)
        if not (scope and subject and predicate and object) then
            return fail(n, "a fact needs scope, subject, predicate and object")
        end
        -- The gate kg.assert_fact applies (the memories get it in write_many): a dev's org:
        -- scope is the org's read-only replica — a file could plant "facts of the org" there,
        -- which searches report as true.
        local ok_p, perr = require("luamemo.federation.policy").check_insert(scope)
        if not ok_p then return fail(n, perr) end
        local from, ferr = stamp(t.valid_from)
        if from == false then return fail(n, "valid_from: " .. tostring(ferr)) end
        local untl, uerr = stamp(t.valid_until)
        if untl == false then return fail(n, "valid_until: " .. tostring(uerr)) end
        from = from or util.now_us()
        if untl and untl < from then return fail(n, "valid_until is before valid_from") end
        if opts.dry_run then rep.facts = rep.facts + 1; return end
        if db.value("SELECT 1 FROM lm_kg_facts WHERE scope = ? AND subject = ? AND predicate = ? AND object = ? "
                .. "AND valid_from = ? LIMIT 1", scope, subject, predicate, object, from) then
            rep.facts_present = rep.facts_present + 1
            return
        end
        local ok, err = db.run("INSERT INTO lm_kg_facts (scope, subject, predicate, object, valid_from, valid_until, "
            .. "source_memory_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", scope, subject, predicate, object,
            from, untl, map[tonumber(t.memory) or -1], util.now_us())
        if not ok then return fail(n, tostring(err)) end
        rep.facts = rep.facts + 1
    end

    local n = 0
    while true do
        local line = next_line()
        if line == nil then break end
        n = n + 1
        if not line:match("^%s*$") then
            rep.lines = rep.lines + 1
            local t = json.decode(line)
            if type(t) == "table" then
                for k, v in pairs(t) do if v == json.null then t[k] = nil end end   -- a JSON null = absent
            end
            if type(t) ~= "table" then
                fail(n, "not a JSON object")
            elseif t.luamemo_export ~= nil then
                if header or rep.lines > 1 then
                    fail(n, "a header must be the first line")
                elseif tonumber(t.luamemo_export) ~= M.FORMAT then
                    fail(n, ("format %s — this luamemo reads format %d"):format(tostring(t.luamemo_export), M.FORMAT))
                    return rep
                elseif t.db_id ~= nil and t.db_id == meta("db_id") then
                    fail(n, "this export comes from this very database — nothing to import")
                    return rep
                else
                    start(t)
                end
            elseif t.type == nil or t.type == "memory" then
                if rep.lines == 1 then start({}) end
                memory_line(n, t)
            elseif t.type == "fact" then
                if rep.lines == 1 then start({}) end
                fact_line(n, t)
            else
                fail(n, "unknown type " .. tostring(t.type))
            end
        end
    end
    flush()
    rep.header = header
    rep.reuse = reuse == true
    return rep
end

return M
