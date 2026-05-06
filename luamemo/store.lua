-- luamemo.store
-- Persistence + retrieval. Uses luamemo.db for raw SQL.

local db    = require("luamemo.db")
local cjson = require("cjson.safe")
local embed = require("luamemo.embed")

local M = {}

local cfg = nil
local _backend = nil   -- resolved backend: "pgvector" | "bruteforce"

-- Probe Postgres for the `vector` extension. Wrapped in pcall so a DB
-- that's not yet reachable at configure() time doesn't crash startup —
-- in that case we default to "pgvector" and the first real query surfaces
-- the error normally.
local function _probe_backend()
    local ok, rows = pcall(db.query,
        "SELECT 1 AS present FROM pg_extension WHERE extname = 'vector'")
    if not ok then return "pgvector" end
    if rows and rows[1] then return "pgvector" end
    return "bruteforce"
end

function M.configure(config)
    cfg = config
    local requested = config.backend or "auto"
    if requested == "auto" then
        _backend = _probe_backend()
    elseif requested == "pgvector" or requested == "bruteforce" then
        _backend = requested
    else
        error("store.configure: invalid backend " .. tostring(requested))
    end
    if type(ngx) == "table" and ngx.log and ngx.INFO then
        ngx.log(ngx.INFO, "luamemo backend: ", _backend)
    end
end

--- Returns the resolved backend ("pgvector" | "bruteforce"). Useful for
--- tests, the Web UI status panel, and anyone wanting to assert which
--- code path is in use.
function M.backend()
    return _backend
end

local function tbl()
    return db.escape_identifier(cfg.db_table)
end

--- Public accessor for the configured table name (already escaped as a
--- SQL identifier). Used by ad-hoc tools (`tune_weights`, eval harnesses)
--- that need to write their own queries against the same table.
function M.table_name() return tbl() end

local function pg_array(arr)
    if not arr or #arr == 0 then return "'{}'" end
    local parts = {}
    for i, v in ipairs(arr) do
        parts[i] = '"' .. tostring(v):gsub('"', '\\"') .. '"'
    end
    return "'{" .. table.concat(parts, ",") .. "}'"
end

local function as_jsonb(t)
    return db.interpolate_query("?::jsonb", cjson.encode(t or {}))
end

-- Validate a numeric weight against [lo, hi]. Returns (number, nil) on
-- success or (nil, err) on failure. Accepts string or number; returns nil
-- if the value is nil so callers can fall back to a default.
local function clamp_check(name, val, lo, hi)
    if val == nil then return nil, nil end
    local n = tonumber(val)
    if not n then
        return nil, name .. ": must be a number"
    end
    if n < lo or n > hi then
        return nil, string.format("%s: must be between %g and %g", name, lo, hi)
    end
    return n, nil
end

-- Standard column list returned by all read paths. Kept in one place so new
-- columns (e.g. importance/decay_rate from migration 002) are surfaced
-- everywhere automatically.
local RETURN_COLS = "id, scope, kind, title, body, tags, metadata, "
    .. "importance, decay_rate, was_truncated, created_at, updated_at"

-- Parse a temporal bound (`since` / `until_`) into a SQL literal expression.
-- Accepts:
--   * number  -> Unix epoch seconds, formatted as `to_timestamp(N)`
--   * string  -> ISO 8601 (YYYY-MM-DD or full RFC3339), escaped + cast to
--                 timestamptz
--   * nil     -> returns nil (caller treats as "no bound")
-- Returns (sql_expr, nil) on success, or (nil, err) on bad input.
local function _parse_time(v, name)
    if v == nil then return nil, nil end
    local t = type(v)
    if t == "number" then
        if v < 0 then
            return nil, name .. ": epoch must be non-negative"
        end
        return ("to_timestamp(%d)"):format(math.floor(v)), nil
    end
    if t == "string" then
        if v == "" then return nil, nil end   -- empty string == no bound
        -- Cheap shape check: must start with 4 digits then a dash.
        if not v:match("^%d%d%d%d%-") then
            return nil, name .. ": expected ISO 8601 (YYYY-MM-DD or RFC3339), got " .. v
        end
        return db.escape_literal(v) .. "::timestamptz", nil
    end
    return nil, name .. ": must be number (epoch) or ISO 8601 string, got " .. t
end

-- Cosine similarity over two equal-length numeric arrays. Returns 0 when
-- either side has zero magnitude (matches pgvector's behaviour for null
-- vectors). Pure Lua so it runs anywhere — used by the bruteforce backend
-- and exposed for tests.
local function _cosine(a, b)
    if not a or not b then return 0 end
    local n = #a
    if n == 0 or n ~= #b then return 0 end
    local dot, na, nb = 0, 0, 0
    for i = 1, n do
        local x, y = a[i], b[i]
        dot = dot + x * y
        na  = na + x * x
        nb  = nb + y * y
    end
    if na == 0 or nb == 0 then return 0 end
    return dot / (math.sqrt(na) * math.sqrt(nb))
end
M._cosine = _cosine   -- exposed for tests

-- Format an embedding for INSERT depending on backend.
local function _embed_literal(vec)
    if _backend == "bruteforce" then
        return embed.to_pg_array(vec)
    end
    return embed.to_pg_literal(vec)
end

-- ---------------------------------------------------------------------------
-- _find_near_duplicate
-- Returns the top-1 row in `scope` whose cosine similarity to `vec` is >=
-- `threshold`, or nil if none qualify.
--
-- pgvector backend: HNSW-backed `ORDER BY embedding <=> $vec LIMIT 1`.
-- bruteforce backend: SELECT scope-scoped candidates (capped by
--   bruteforce_candidate_limit), compute cosine in Lua, pick the max.
-- ---------------------------------------------------------------------------
local function _find_near_duplicate(scope, vec, threshold)
    if not scope or not vec or not threshold then return nil end

    if _backend == "bruteforce" then
        local cap = tonumber(cfg.bruteforce_candidate_limit) or 1000
        local sql = ([[
            SELECT %s, embedding
            FROM %s
            WHERE scope = %s
            ORDER BY updated_at DESC
            LIMIT %d
        ]]):format(RETURN_COLS, tbl(), db.escape_literal(scope), cap)
        local rows = db.query(sql)
        if not rows or #rows == 0 then return nil end
        local best, best_sim = nil, -1
        for _, row in ipairs(rows) do
            local sim = _cosine(row.embedding, vec)
            if sim > best_sim then best_sim, best = sim, row end
        end
        if best and best_sim >= threshold then
            best.embedding = nil
            return best
        end
        return nil
    end

    -- pgvector path
    local sql = ([[
        SELECT %s, (1 - (embedding <=> %s)) AS sim
        FROM %s
        WHERE scope = %s
        ORDER BY embedding <=> %s
        LIMIT 1
    ]]):format(
        RETURN_COLS,
        embed.to_pg_literal(vec),
        tbl(),
        db.escape_literal(scope),
        embed.to_pg_literal(vec)
    )
    local rows = db.query(sql)
    if not rows or #rows == 0 then return nil end
    local row = rows[1]
    if (tonumber(row.sim) or 0) >= threshold then
        row.sim = nil
        return row
    end
    return nil
end

-- Merge new body/tags/metadata into an existing row (dedup_strategy="update").
-- Re-embeds with the merged title+body, bumps updated_at via the UPDATE.
local function _merge_into(existing, args)
    local patch = {}
    -- Only patch fields the caller actually supplied; never overwrite with "".
    if args.title    and args.title ~= "" then patch.title    = args.title end
    if args.body     and args.body  ~= "" then patch.body     = args.body  end
    if args.tags     then patch.tags     = args.tags     end
    if args.metadata then patch.metadata = args.metadata end
    -- Importance/decay are intentionally NOT bumped on merge — the original
    -- weights are preserved so dedup can't be used to silently rewrite them.
    if next(patch) == nil then
        -- Nothing to change; still bump updated_at so decay clock resets.
        local rows = db.query(
            "UPDATE " .. tbl() .. " SET updated_at = now() "
            .. "WHERE id = ? RETURNING " .. RETURN_COLS, existing.id)
        return rows and rows[1] or existing
    end
    return M.update(existing.id, patch)
end

-- ---------------------------------------------------------------------------
-- write
-- Returns (row, err, action) where action is "inserted" | "merged" | "skipped".
-- The third return is additive — existing `local row, err = write(...)`
-- callers continue to work unchanged.
-- ---------------------------------------------------------------------------
function M.write(args)
    assert(type(args) == "table", "write(args) requires a table")
    local scope = args.scope or cfg.default_scope
    local kind  = args.kind or "fact"
    local title = args.title or ""
    local body  = args.body  or ""
    local tags  = args.tags  or {}
    local meta  = args.metadata or {}

    if title == "" and body == "" then
        return nil, "write: title or body required"
    end

    local importance, ierr = clamp_check("importance", args.importance, 0.0, 10.0)
    if ierr then return nil, ierr end
    if importance == nil then importance = cfg.default_importance or 1.0 end

    local decay_rate, derr = clamp_check("decay_rate", args.decay_rate, 0.0, 1.0)
    if derr then return nil, derr end
    if decay_rate == nil then decay_rate = cfg.default_decay_rate or 0.0 end

    local vec, err, truncated = embed.embed(title .. "\n" .. body)
    if not vec then return nil, err end

    -- Dedup pre-search. Per-call dedup_strategy="append" disables dedup
    -- without touching global config; useful for migration/import scripts.
    local strategy = args.dedup_strategy or cfg.dedup_strategy or "update"
    if cfg.dedup_enabled and strategy ~= "append" then
        local existing = _find_near_duplicate(
            scope, vec, cfg.dedup_threshold or 0.95)
        if existing then
            if strategy == "skip" then
                return existing, nil, "skipped"
            elseif strategy == "update" then
                local merged, merr = _merge_into(existing, args)
                if not merged then return nil, merr end
                return merged, nil, "merged"
            end
        end
    end

    local sql = ([[
        INSERT INTO %s (scope, kind, title, body, tags, metadata, embedding, importance, decay_rate, was_truncated)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        RETURNING %s
    ]]):format(
        tbl(),
        db.escape_literal(scope),
        db.escape_literal(kind),
        db.escape_literal(title),
        db.escape_literal(body),
        pg_array(tags),
        as_jsonb(meta),
        _embed_literal(vec),
        db.escape_literal(importance),
        db.escape_literal(decay_rate),
        db.escape_literal(truncated and true or false),
        RETURN_COLS
    )
    local rows, qerr = db.query(sql)
    if not rows then return nil, "write: db error: " .. tostring(qerr) end
    return rows[1], nil, "inserted"
end

-- ---------------------------------------------------------------------------
-- write_many
-- Batched ingest: embed N rows sequentially, then INSERT all of them in a
-- single multi-VALUES statement. Skips dedup by default (set
-- opts.dedup_strategy = "update" or "skip" to opt back in, at the cost of
-- one similarity probe per row — which defeats the speedup).
--
-- Returns (results, err) where `results` is a list (parallel to `rows`) of
-- { row = <inserted row or nil>, action = "inserted"|"skipped"|"merged",
--   error = <string or nil> }. A single per-row failure does not abort the
-- batch — that row's slot carries `error` and `row = nil`, the rest succeed.
--
-- opts:
--   batch_size       — chunk size for the multi-VALUES INSERT (default 100)
--   dedup_strategy   — "append" (default), "skip", or "update"
-- ---------------------------------------------------------------------------
function M.write_many(rows_in, opts)
    assert(type(rows_in) == "table", "write_many(rows, opts) requires a table of rows")
    opts = opts or {}
    local batch_size = tonumber(opts.batch_size) or 100
    if batch_size < 1 then batch_size = 1 end
    local strategy = opts.dedup_strategy or "append"

    local results = {}
    if #rows_in == 0 then return results, nil end

    -- Phase A: validate + embed every row, recording per-row errors. We embed
    -- before slicing into INSERT chunks so a bad row doesn't poison the batch.
    local prepared = {}
    for i, args in ipairs(rows_in) do
        if type(args) ~= "table" then
            results[i] = { row = nil, action = nil, error = "row must be a table" }
        else
            local title = args.title or ""
            local body  = args.body  or ""
            if title == "" and body == "" then
                results[i] = { row = nil, action = nil, error = "title or body required" }
            else
                local importance, ierr = clamp_check("importance", args.importance, 0.0, 10.0)
                if ierr then
                    results[i] = { row = nil, action = nil, error = ierr }
                else
                    if importance == nil then importance = cfg.default_importance or 1.0 end
                    local decay_rate, derr = clamp_check("decay_rate", args.decay_rate, 0.0, 1.0)
                    if derr then
                        results[i] = { row = nil, action = nil, error = derr }
                    else
                        if decay_rate == nil then decay_rate = cfg.default_decay_rate or 0.0 end
                        local vec, eerr, vtrunc = embed.embed(title .. "\n" .. body)
                        if not vec then
                            results[i] = { row = nil, action = nil, error = eerr }
                        else
                            -- Optional dedup. Costs one similarity probe per
                            -- row; opt-in only.
                            if cfg.dedup_enabled and strategy ~= "append" then
                                local scope = args.scope or cfg.default_scope
                                local existing = _find_near_duplicate(
                                    scope, vec, cfg.dedup_threshold or 0.95)
                                if existing then
                                    if strategy == "skip" then
                                        results[i] = { row = existing, action = "skipped" }
                                        -- Do not enqueue for INSERT.
                                        prepared[i] = nil
                                    elseif strategy == "update" then
                                        local merged, merr = _merge_into(existing, args)
                                        if not merged then
                                            results[i] = { row = nil, action = nil, error = merr }
                                        else
                                            results[i] = { row = merged, action = "merged" }
                                        end
                                        prepared[i] = nil
                                    end
                                end
                            end
                            if results[i] == nil then
                                prepared[i] = {
                                    scope = args.scope or cfg.default_scope,
                                    kind  = args.kind or "fact",
                                    title = title,
                                    body  = body,
                                    tags  = args.tags or {},
                                    meta  = args.metadata or {},
                                    vec   = vec,
                                    importance = importance,
                                    decay_rate = decay_rate,
                                    truncated  = vtrunc and true or false,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    -- Phase B: execute multi-VALUES INSERT chunks. We track the original
    -- index of each prepared row so RETURNING rows map back to caller order.
    local indices = {}
    for i = 1, #rows_in do
        if prepared[i] then table.insert(indices, i) end
    end

    local pos = 1
    while pos <= #indices do
        local last = math.min(pos + batch_size - 1, #indices)
        local values = {}
        for j = pos, last do
            local p = prepared[indices[j]]
            values[#values + 1] = string.format("(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                db.escape_literal(p.scope),
                db.escape_literal(p.kind),
                db.escape_literal(p.title),
                db.escape_literal(p.body),
                pg_array(p.tags),
                as_jsonb(p.meta),
                _embed_literal(p.vec),
                db.escape_literal(p.importance),
                db.escape_literal(p.decay_rate),
                db.escape_literal(p.truncated and true or false)
            )
        end
        local sql = ([[
            INSERT INTO %s (scope, kind, title, body, tags, metadata, embedding, importance, decay_rate, was_truncated)
            VALUES %s
            RETURNING %s
        ]]):format(tbl(), table.concat(values, ", "), RETURN_COLS)
        local inserted, qerr = db.query(sql)
        if not inserted then
            -- Whole-chunk failure: tag every slot in this chunk with the
            -- error so the caller sees which rows did not make it.
            for j = pos, last do
                results[indices[j]] = { row = nil, action = nil,
                    error = "write_many: db error: " .. tostring(qerr) }
            end
        else
            for j = pos, last do
                local r = inserted[j - pos + 1]
                if r then
                    results[indices[j]] = { row = r, action = "inserted" }
                else
                    results[indices[j]] = { row = nil, action = nil,
                        error = "write_many: missing RETURNING row" }
                end
            end
        end
        pos = last + 1
    end

    return results, nil
end

-- ---------------------------------------------------------------------------
-- get
-- ---------------------------------------------------------------------------
function M.get(id)
    local rows = db.query(
        "SELECT " .. RETURN_COLS .. " "
        .. "FROM " .. tbl() .. " WHERE id = ?", tonumber(id))
    return rows and rows[1] or nil
end

-- ---------------------------------------------------------------------------
-- update (re-embeds if title or body changed)
-- ---------------------------------------------------------------------------
function M.update(id, patch)
    id = tonumber(id)
    if not id then return nil, "update: invalid id" end
    local existing = M.get(id)
    if not existing then return nil, "update: not found" end

    local fields, vals = {}, {}
    local function set(name, val)
        table.insert(fields, db.escape_identifier(name) .. " = ?")
        table.insert(vals, val)
    end

    if patch.scope then set("scope", patch.scope) end
    if patch.kind  then set("kind",  patch.kind)  end
    if patch.title then set("title", patch.title) end
    if patch.body  then set("body",  patch.body)  end

    if patch.tags then
        table.insert(fields, "tags = " .. pg_array(patch.tags))
    end
    if patch.metadata then
        table.insert(fields, "metadata = " .. as_jsonb(patch.metadata))
    end

    if patch.importance ~= nil then
        local imp, ierr = clamp_check("importance", patch.importance, 0.0, 10.0)
        if ierr then return nil, ierr end
        table.insert(fields, "importance = " .. db.escape_literal(imp))
    end
    if patch.decay_rate ~= nil then
        local dr, derr = clamp_check("decay_rate", patch.decay_rate, 0.0, 1.0)
        if derr then return nil, derr end
        table.insert(fields, "decay_rate = " .. db.escape_literal(dr))
    end

    -- Re-embed when text changed.
    if patch.title or patch.body then
        local title = patch.title or existing.title
        local body  = patch.body  or existing.body
        local vec, eerr, vtrunc = embed.embed(title .. "\n" .. body)
        if not vec then return nil, eerr end
        table.insert(fields, "embedding = " .. _embed_literal(vec))
        table.insert(fields, "was_truncated = " .. db.escape_literal(vtrunc and true or false))
    end

    if #fields == 0 then return existing end

    local sql = "UPDATE " .. tbl() .. " SET " .. table.concat(fields, ", ")
        .. " WHERE id = ? RETURNING " .. RETURN_COLS
    table.insert(vals, id)
    local rows, err = db.query(db.interpolate_query(sql, unpack(vals)))
    if not rows then return nil, "update: db error: " .. tostring(err) end
    return rows[1]
end

-- ---------------------------------------------------------------------------
-- delete
-- ---------------------------------------------------------------------------
function M.delete(id)
    id = tonumber(id)
    if not id then return nil, "delete: invalid id" end
    local res = db.delete(cfg.db_table, { id = id })
    return res
end

-- ---------------------------------------------------------------------------
-- select_for_summarization
-- Returns a list of {scope, memories[]} batches. A memory qualifies when:
--   * weight (importance * exp(-decay_rate * days_since_updated))
--     is below `weight_threshold` (default 0.5), AND
--   * updated_at < now() - retention_days (default 30)
-- Batches are grouped by scope and capped at `batch_size` rows each;
-- at most `max_batches` are returned per call to bound LLM calls.
-- ---------------------------------------------------------------------------
function M.select_for_summarization(opts)
    opts = opts or {}
    local weight_threshold = tonumber(opts.weight_threshold)
        or cfg.summarizer_weight_threshold or 0.5
    local retention_days = tonumber(opts.retention_days)
        or cfg.summarizer_retention_days or 30
    local batch_size = tonumber(opts.batch_size)
        or cfg.summarizer_batch_size or 20
    local max_batches = tonumber(opts.max_batches)
        or cfg.summarizer_max_batches or 5
    local scope_filter = opts.scope

    local conds = {
        "kind != 'summary'",
        "updated_at < now() - (" .. db.escape_literal(retention_days) .. " || ' days')::interval",
        "(importance * exp(-decay_rate * (EXTRACT(EPOCH FROM (now() - updated_at)) / 86400.0))) < "
            .. db.escape_literal(weight_threshold),
    }
    if scope_filter then
        table.insert(conds, "scope = " .. db.escape_literal(scope_filter))
    end

    local sql = ([[
        SELECT %s
        FROM %s
        WHERE %s
        ORDER BY scope, updated_at ASC
        LIMIT %d
    ]]):format(
        RETURN_COLS,
        tbl(),
        table.concat(conds, " AND "),
        batch_size * max_batches
    )
    local rows = db.query(sql) or {}

    -- Group by scope, then chunk each scope into batch_size pieces.
    local by_scope = {}
    for _, r in ipairs(rows) do
        by_scope[r.scope] = by_scope[r.scope] or {}
        table.insert(by_scope[r.scope], r)
    end

    local batches = {}
    for s, list in pairs(by_scope) do
        for i = 1, #list, batch_size do
            if #batches >= max_batches then break end
            local chunk = {}
            for j = i, math.min(i + batch_size - 1, #list) do
                chunk[#chunk + 1] = list[j]
            end
            table.insert(batches, { scope = s, memories = chunk })
        end
        if #batches >= max_batches then break end
    end

    return batches
end

-- ---------------------------------------------------------------------------
-- replace_with_summary
-- Atomically: insert the summary memory, delete the originals. Returns the
-- new summary row (with id) so callers can log / surface it.
-- ---------------------------------------------------------------------------
function M.replace_with_summary(ids, summary_args)
    if type(ids) ~= "table" or #ids == 0 then
        return nil, "replace_with_summary: ids required"
    end
    if type(summary_args) ~= "table" then
        return nil, "replace_with_summary: summary_args required"
    end

    -- Stamp summarized_ids onto metadata so the new row tells you what it
    -- replaced. Caller-supplied metadata is preserved.
    local meta = summary_args.metadata or {}
    meta.summarized_ids = ids

    local insert_args = {
        scope      = summary_args.scope,
        kind       = "summary",
        title      = summary_args.title,
        body       = summary_args.body,
        tags       = summary_args.tags,
        metadata   = meta,
        importance = summary_args.importance or 1.0,
        decay_rate = summary_args.decay_rate or 0.0,
        -- Force insert; never let dedup merge a freshly-minted summary.
        dedup_strategy = "append",
    }

    db.query("BEGIN")
    local row, werr = M.write(insert_args)
    if not row then
        db.query("ROLLBACK")
        return nil, "replace_with_summary: insert failed: " .. tostring(werr)
    end

    local id_list = {}
    for _, id in ipairs(ids) do
        local n = tonumber(id)
        if n then id_list[#id_list + 1] = tostring(n) end
    end
    if #id_list == 0 then
        db.query("ROLLBACK")
        return nil, "replace_with_summary: no valid ids"
    end
    local del_sql = "DELETE FROM " .. tbl()
        .. " WHERE id IN (" .. table.concat(id_list, ",") .. ")"
    local _, derr = db.query(del_sql)
    if derr then
        db.query("ROLLBACK")
        return nil, "replace_with_summary: delete failed: " .. tostring(derr)
    end

    db.query("COMMIT")
    return row
end

-- ---------------------------------------------------------------------------
-- recent
-- ---------------------------------------------------------------------------
function M.recent(args)
    args = args or {}
    local limit = math.min(tonumber(args.limit) or 20, 200)
    local where = ""
    if args.scope then
        where = "WHERE scope = " .. db.escape_literal(args.scope)
    end
    local sql = ([[
        SELECT %s
        FROM %s %s
        ORDER BY created_at DESC
        LIMIT %d
    ]]):format(RETURN_COLS, tbl(), where, limit)
    return db.query(sql) or {}
end

-- ---------------------------------------------------------------------------
-- list_by_scope
-- Returns up to `limit` rows from the given scope, oldest first (so the
-- summarizer sees them in conversational order). Used by promote().
-- By default skips rows with kind='summary' so promotion does not fold
-- previously-promoted summaries back into a new summary; pass
-- include_summaries=true to override.
-- ---------------------------------------------------------------------------
function M.list_by_scope(scope, opts)
    if not scope or scope == "" then
        return nil, "list_by_scope: scope required"
    end
    opts = opts or {}
    local limit = math.min(tonumber(opts.limit) or 200, 1000)
    local conds = { "scope = " .. db.escape_literal(scope) }
    if not opts.include_summaries then
        table.insert(conds, "kind != 'summary'")
    end
    local sql = ([[
        SELECT %s
        FROM %s
        WHERE %s
        ORDER BY created_at ASC
        LIMIT %d
    ]]):format(RETURN_COLS, tbl(), table.concat(conds, " AND "), limit)
    return db.query(sql) or {}
end

-- ---------------------------------------------------------------------------
-- search (hybrid: vector cosine + FTS rank, weighted by importance/decay)
--
-- Branches on backend:
--   pgvector   -> single SQL CTE with `<=>` ANN, normalisation, blend.
--   bruteforce -> SQL fetches scope/kind-filtered candidates ranked by
--                 FTS, capped at `bruteforce_candidate_limit`; Lua
--                 computes cosine, normalises, blends, applies weight,
--                 sorts. Same return shape so callers don't care.
-- ---------------------------------------------------------------------------
local function _search_pgvector(q, qvec, scope, kind, limit, wv, wf, ignore_decay, since_sql, until_sql)
    local qvec_lit = embed.to_pg_literal(qvec)

    local conds = {}
    if scope then table.insert(conds, "scope = " .. db.escape_literal(scope)) end
    if kind  then table.insert(conds, "kind  = " .. db.escape_literal(kind))  end
    if since_sql then table.insert(conds, "updated_at >= " .. since_sql) end
    if until_sql then table.insert(conds, "updated_at <  " .. until_sql) end
    local where = #conds > 0 and ("WHERE " .. table.concat(conds, " AND ")) or ""

    local weight_expr = ignore_decay
        and "1.0"
        or  "importance * exp(-decay_rate * (EXTRACT(EPOCH FROM (now() - updated_at)) / 86400.0))"

    local sql = ([[
        WITH candidates AS (
            SELECT id, scope, kind, title, body, tags, metadata,
                   importance, decay_rate, created_at, updated_at,
                   (1 - (embedding <=> %s)) AS vec_score,
                   ts_rank_cd(fts, plainto_tsquery('english', %s)) AS fts_score,
                   (%s) AS weight
            FROM %s
            %s
            ORDER BY embedding <=> %s
            LIMIT 50
        ),
        normalised AS (
            SELECT *,
                   CASE WHEN max(vec_score) OVER () > 0
                        THEN vec_score / max(vec_score) OVER ()
                        ELSE 0 END AS vec_n,
                   CASE WHEN max(fts_score) OVER () > 0
                        THEN fts_score / max(fts_score) OVER ()
                        ELSE 0 END AS fts_n
            FROM candidates
        )
        SELECT id, scope, kind, title, body, tags, metadata,
               importance, decay_rate, created_at, updated_at,
               vec_score, fts_score, weight,
               ((%f * vec_n + %f * fts_n) * weight) AS score
        FROM normalised
        ORDER BY score DESC
        LIMIT %d
    ]]):format(qvec_lit,
               db.escape_literal(q),
               weight_expr,
               tbl(),
               where,
               qvec_lit,
               wv, wf,
               limit)

    local rows, qerr = db.query(sql)
    if not rows then return nil, "search: db error: " .. tostring(qerr) end
    return rows
end

-- Brute-force search: SQL pre-filters by scope/kind and ranks candidates by
-- FTS so lexically-relevant rows survive the cap; Lua computes cosine,
-- normalises both signals, blends, applies the importance/decay weight,
-- sorts, and trims. Returns rows in the same shape as the pgvector path.
local function _search_bruteforce(q, qvec, scope, kind, limit, wv, wf, ignore_decay, since_sql, until_sql)
    local cap = tonumber(cfg.bruteforce_candidate_limit) or 1000

    local conds = {}
    if scope then table.insert(conds, "scope = " .. db.escape_literal(scope)) end
    if kind  then table.insert(conds, "kind  = " .. db.escape_literal(kind))  end
    if since_sql then table.insert(conds, "updated_at >= " .. since_sql) end
    if until_sql then table.insert(conds, "updated_at <  " .. until_sql) end
    local where = #conds > 0 and ("WHERE " .. table.concat(conds, " AND ")) or ""

    -- Order candidates by FTS rank (desc) so the cap preserves the most
    -- lexically-relevant rows. NULLS LAST keeps non-matching rows behind.
    local sql = ([[
        SELECT id, scope, kind, title, body, tags, metadata,
               importance, decay_rate, created_at, updated_at, embedding,
               ts_rank_cd(fts, plainto_tsquery('english', %s)) AS fts_score
        FROM %s
        %s
        ORDER BY fts_score DESC NULLS LAST, updated_at DESC
        LIMIT %d
    ]]):format(db.escape_literal(q), tbl(), where, cap)

    local rows, qerr = db.query(sql)
    if not rows then return nil, "search: db error: " .. tostring(qerr) end
    if #rows == 0 then return {} end

    -- Compute per-row cosine + per-batch maxes for normalisation.
    local max_vec, max_fts = 0, 0
    for _, r in ipairs(rows) do
        r.vec_score = _cosine(r.embedding, qvec)
        r.fts_score = tonumber(r.fts_score) or 0
        if r.vec_score > max_vec then max_vec = r.vec_score end
        if r.fts_score > max_fts then max_fts = r.fts_score end
    end

    -- Blend + weight + drop the embedding payload before returning.
    for _, r in ipairs(rows) do
        local vec_n = (max_vec > 0) and (r.vec_score / max_vec) or 0
        local fts_n = (max_fts > 0) and (r.fts_score / max_fts) or 0
        local weight = 1.0
        if not ignore_decay then
            local imp = tonumber(r.importance) or 1.0
            local dr  = tonumber(r.decay_rate) or 0.0
            -- Days since updated. updated_at comes back as a string from
            -- lapis.db; we approximate by parsing the date prefix. When
            -- parsing fails, age = 0 (no decay applied).
            local age_days = 0
            local s = tostring(r.updated_at or "")
            local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
            if y then
                local now = os.time()
                local row_t = os.time({
                    year = tonumber(y), month = tonumber(m), day = tonumber(d),
                    hour = 0, min = 0, sec = 0,
                })
                age_days = math.max(0, (now - row_t) / 86400.0)
            end
            weight = imp * math.exp(-dr * age_days)
        end
        r.weight = weight
        r.score  = (wv * vec_n + wf * fts_n) * weight
        r.embedding = nil
    end

    table.sort(rows, function(a, b) return (a.score or 0) > (b.score or 0) end)
    if #rows > limit then
        local trimmed = {}
        for i = 1, limit do trimmed[i] = rows[i] end
        return trimmed
    end
    return rows
end

function M.search(args)
    assert(args and args.query, "search: query is required")
    local q     = args.query
    local scope = args.scope
    local kind  = args.kind
    local limit = math.min(tonumber(args.limit) or 10, 100)
    local ignore_decay = args.ignore_decay and true or false

    -- Optional temporal bounds (Phase 11). `until_` uses a trailing
    -- underscore because `until` is a Lua reserved word.
    local since_sql, t_err = _parse_time(args.since, "since")
    if t_err then return nil, t_err end
    local until_sql
    until_sql, t_err = _parse_time(args.until_, "until_")
    if t_err then return nil, t_err end

    local weights = args.hybrid_weights or cfg.hybrid_weights
    local wv = weights.vector or 0.7
    local wf = weights.fts or 0.3

    local qvec, err = embed.embed(q)
    if not qvec then return nil, err end

    -- Decide rerank up front so we can over-fetch the candidate pool.
    local rerank_on
    if args.rerank ~= nil then
        rerank_on = args.rerank and true or false
    else
        rerank_on = (cfg.rerank_enabled == true)
    end

    local fetch_limit = limit
    if rerank_on then
        local top_n = tonumber(args.rerank_top_n)
                      or tonumber(cfg.rerank_top_n) or 20
        if top_n > limit then
            fetch_limit = math.min(top_n, 100)
        end
    end

    local rows
    if _backend == "bruteforce" then
        rows, err = _search_bruteforce(q, qvec, scope, kind, fetch_limit,
            wv, wf, ignore_decay, since_sql, until_sql)
    else
        rows, err = _search_pgvector(q, qvec, scope, kind, fetch_limit,
            wv, wf, ignore_decay, since_sql, until_sql)
    end
    if not rows then return nil, err end

    if not rerank_on or #rows <= 1 then
        if #rows > limit then
            local trimmed = {}
            for i = 1, limit do trimmed[i] = rows[i] end
            return trimmed
        end
        return rows
    end

    -- Lazy-require to avoid a circular dependency at module load.
    local rerank = require("luamemo.rerank")
    local reranked, rerr = rerank.rerank(q, rows, {
        limit             = limit,
        rerank_top_n      = args.rerank_top_n,
        rerank_adapter    = args.rerank_adapter,
        rerank_model      = args.rerank_model,
        rerank_url        = args.rerank_url,
        rerank_headers    = args.rerank_headers,
        rerank_timeout_ms = args.rerank_timeout_ms,
    })
    if not reranked then
        -- Rerank is best-effort: on adapter failure, fall back to the
        -- baseline ranking so search() never returns nothing.
        if ngx and ngx.log and ngx.WARN then
            ngx.log(ngx.WARN, "luamemo rerank failed: ", tostring(rerr))
        end
        if #rows > limit then
            local trimmed = {}
            for i = 1, limit do trimmed[i] = rows[i] end
            return trimmed
        end
        return rows
    end
    return reranked
end

return M
