-- luamemo.store
-- Persistence + retrieval. Uses luamemo.db for raw SQL.

local db          = require("luamemo.db")
local json        = require("luamemo.json")
local embed       = require("luamemo.embed")
local util        = require("luamemo.util")
local temporal    = require("luamemo.temporal")
local consolidate = require("luamemo.consolidate")
local digest      = require("luamemo.digest")
local patterns    = require("luamemo.patterns")

local M = {}

local cfg = nil
local _backend = nil   -- resolved backend: "pgvector" | "bruteforce"
local lsh_mod    = nil  -- lazily required "luamemo.lsh" (never loads for pgvector backend)
local _lsh_index = {}   -- [scope_string] = lsh-idx-object | false | nil

-- Lazy reference to the parent luamemo module for ensure_ready() calls.
-- Fetched on first write() to avoid circular-require at module load time.
local _luamemo_ref          = nil
local _luamemo_ref_fetched  = false
local _has_ensure_ready     = false   -- cached: _luamemo_ref.ensure_ready is a function

-- ---------------------------------------------------------------------------
-- Query-time boost helpers (Plan 14)
-- ---------------------------------------------------------------------------

-- Capitalised words that are structural query tokens, not proper names.
local _NAME_STOPWORDS = {
    what=1, when=1, where=1, who=1, why=1, how=1, which=1,
    did=1, does=1, ["do"]=1, is=1, are=1, was=1, were=1, will=1,
    the=1, a=1, an=1, ["in"]=1, on=1, at=1, to=1, of=1,
    ["and"]=1, ["or"]=1, but=1, ["for"]=1, with=1, from=1, about=1, i=1,
    my=1, me=1, we=1, our=1, you=1, your=1, he=1, she=1, they=1,
}

--- Extract likely proper names from a query string.
-- Matches consecutive sequences of Title-case ASCII words.
-- Returns a list of lowercased name tokens.
local function _extract_names(query)
    local names = {}
    for word in query:gmatch("%u%a+") do
        if not _NAME_STOPWORDS[word:lower()] then
            names[#names + 1] = word:lower()
        end
    end
    return names
end

--- Extract quoted phrases from a query string.
-- Supports both "double" and 'single' quotes.
-- Returns a list of lowercased phrase strings.
local function _extract_quoted(query)
    local phrases = {}
    for p in query:gmatch('"([^"]+)"') do
        phrases[#phrases + 1] = p:lower()
    end
    for p in query:gmatch("'([^']+)'") do
        phrases[#phrases + 1] = p:lower()
    end
    return phrases
end

local function _get_luamemo()
    if not _luamemo_ref_fetched then
        _luamemo_ref_fetched = true
        local ok, m = pcall(require, "luamemo")
        _luamemo_ref      = ok and type(m) == "table" and m or nil
        _has_ensure_ready = _luamemo_ref ~= nil
            and type(_luamemo_ref.ensure_ready) == "function"
    end
    return _luamemo_ref
end

-- Probe Postgres for the `vector` extension AND verify that the embedding
-- column was created as the pgvector `vector` type (not `real[]`). Both must
-- be true to use the pgvector backend. Wrapped in pcall so a DB that is not
-- yet reachable at configure() time doesn't crash startup — in that case we
-- default to "pgvector" and the first real query surfaces the error normally.
--
-- Guards the common misconfiguration: pgvector extension installed on a DB
-- whose lm_memories table was created from schema_bruteforce.sql (real[]).
-- In that case auto-detection now falls back to "bruteforce" instead of
-- crashing with "malformed array literal" on the first write.
local function _probe_backend(tbl_name)
    -- 1. Check whether the pgvector extension is installed.
    local ok, ext_rows = pcall(db.query,
        "SELECT 1 AS present FROM pg_extension WHERE extname = 'vector'")
    if not ok then return "pgvector" end        -- unreachable DB → assume pgvector
    if not (ext_rows and ext_rows[1]) then return "bruteforce" end

    -- 2. Extension present — also verify the embedding column is actually
    --    vector type, not real[] (brute-force schema).
    local col_ok, col_rows = pcall(db.query,
        "SELECT t.typname FROM pg_attribute a " ..
        "JOIN pg_class c ON a.attrelid = c.oid " ..
        "JOIN pg_type t ON a.atttypid = t.oid " ..
        "WHERE c.relname = " .. db.escape_literal(tbl_name) ..
        " AND a.attname = 'embedding' AND a.attnum > 0")
    if not col_ok or not (col_rows and col_rows[1]) then return "pgvector" end
    return (col_rows[1].typname == "vector") and "pgvector" or "bruteforce"
end

function M.configure(config)
    cfg = config
    consolidate.configure(config)
    digest.configure(config)
    local requested = config.backend or "auto"
    if requested == "auto" then
        _backend = _probe_backend(cfg.db_table or "lm_memories")
    elseif requested == "pgvector" or requested == "bruteforce" then
        _backend = requested
    else
        error("store.configure: invalid backend " .. tostring(requested))
    end
    if type(ngx) == "table" and ngx.log and ngx.INFO then
        ngx.log(ngx.INFO, "luamemo backend: ", _backend)
    end
    -- Reset per-scope LSH indices on reconfigure so tests start fresh.
    _lsh_index = {}
    lsh_mod    = nil
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

-- ---------------------------------------------------------------------------
-- LSH helpers (Phases 5.2–5.4)
-- LSH is a middle-tier ANN backend for the bruteforce case: when the corpus
-- exceeds lsh_rebuild_at rows, one candidate-fetch SELECT is replaced by an
-- in-memory hash lookup that returns ≈100–300 candidates instead of 1000.
-- ---------------------------------------------------------------------------

-- LSH is only useful on the bruteforce backend; pgvector uses HNSW already.
local function _lsh_enabled()
    if _backend ~= "bruteforce"         then return false end
    if cfg and cfg.lsh_enabled == false then return false end
    return true
end

local function _lsh_rebuild_at()
    return (cfg and tonumber(cfg.lsh_rebuild_at)) or 10000
end

-- Return the active LSH index for `scope`, building it lazily on first call
-- when the corpus crosses lsh_rebuild_at rows for that scope.
-- `vec_hint` is a sample embedding used to infer the vector dimension;
-- falls back to cfg.embed_dim (default 384) when nil.
-- Returns the index object, or nil when LSH is disabled / corpus is small.
local function _get_lsh(scope, vec_hint)
    if not _lsh_enabled() or not scope then return nil end

    local cached = _lsh_index[scope]
    if cached ~= nil then
        -- false  = corpus was below threshold when last checked
        -- <idx>  = active index object
        return cached ~= false and cached or nil
    end

    -- First access for this scope: fetch all embeddings to decide.
    -- For the bruteforce backend, embedding is real[] — pgmoon returns a Lua table.
    local rows = db.query(([[SELECT id, embedding FROM %s WHERE scope = %s
    ]]):format(tbl(), db.escape_literal(scope)))

    if not rows or #rows < _lsh_rebuild_at() then
        _lsh_index[scope] = false  -- below threshold; use full-scan bruteforce
        return nil
    end

    -- Infer dimension from first row, then fall back to config / 384.
    local dim = (vec_hint and #vec_hint)
        or  (rows[1] and type(rows[1].embedding) == "table" and #rows[1].embedding)
        or  (cfg and tonumber(cfg.embed_dim))
        or  384

    if not lsh_mod then lsh_mod = require("luamemo.lsh") end
    local new_idx = lsh_mod.new(dim,
        tonumber(cfg and cfg.lsh_tables) or 8,
        tonumber(cfg and cfg.lsh_bits)   or 12)

    local entries = {}
    for _, row in ipairs(rows) do
        if type(row.embedding) == "table" then
            entries[#entries + 1] = { id = row.id, vec = row.embedding }
        end
    end
    new_idx:rebuild(entries)
    _lsh_index[scope] = new_idx
    return new_idx
end

local function pg_array(arr)
    if not arr or #arr == 0 then return "'{}'" end
    local parts = {}
    for i, v in ipairs(arr) do
        local s = tostring(v)
            :gsub("\\", "\\\\")  -- backslash first (array element escaping)
            :gsub('"',  '\\"')   -- double-quote (array element escaping)
            :gsub("'",  "''")    -- single-quote (SQL string escaping)
        parts[i] = '"' .. s .. '"'
    end
    return "'{" .. table.concat(parts, ",") .. "}'"
end

local function as_jsonb(t)
    return db.interpolate_query("?::jsonb", json.encode(t or {}))
end

-- Validate a numeric weight against [lo, hi].  Delegates to util.
local clamp_check = util.clamp_check

-- Standard column list returned by all read paths. Kept in one place so new
-- columns (e.g. importance/decay_rate from migration 002) are surfaced
-- everywhere automatically.
local RETURN_COLS = "id, scope, kind, title, body, tags, metadata, "
    .. "importance, decay_rate, was_truncated, created_at, updated_at, tier"

-- Derive initial tier from importance value (delegates to util).
local _importance_to_tier = util.importance_to_tier

local DEFAULT_EMBED_TIMEOUT_MS = 30000  -- fallback when embed_timeout_ms not set by M.setup()

-- Trim table `t` to at most `n` entries.  Returns a new table when trimming
-- is needed, or `t` itself when len(t) <= n (no copy).
local function _trim(t, n)
    if #t <= n then return t end
    local out = {}
    for i = 1, n do out[i] = t[i] end
    return out
end

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

-- Cosine similarity — delegates to util.cosine (shared with consolidate + digest).
local function _cosine(a, b)
    return util.cosine(a, b)
end
M._cosine    = _cosine    -- exposed for tests
M._get_lsh   = _get_lsh   -- exposed for tests (trigger lazy rebuild)

-- Format an embedding for INSERT depending on backend.
local function _embed_literal(vec)
    -- A nil vector means "store no embedding" (FTS-only row); write SQL NULL.
    -- The embedding column is nullable in both schemas.
    if vec == nil then return "NULL" end
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
        -- When the LSH index is active for this scope, pre-filter to a small
        -- candidate set; fall back to a full-scope scan for small corpora.
        local lsh_idx = _get_lsh(scope, vec)
        local rows
        if lsh_idx then
            local cand_ids = lsh_idx:query(vec, cap)
            if #cand_ids > 0 then
                local id_list = util.sql_id_list(cand_ids)
                if id_list then
                    rows = db.query(([[
                        SELECT %s, embedding FROM %s WHERE id IN (%s)
                    ]]):format(RETURN_COLS, tbl(), id_list))
                end
            end
        end
        if not rows then
            -- Full scan fallback: LSH disabled or corpus below threshold.
            rows = db.query(([[
                SELECT %s, embedding
                FROM %s
                WHERE scope = %s
                ORDER BY updated_at DESC
                LIMIT %d
            ]]):format(RETURN_COLS, tbl(), db.escape_literal(scope), cap))
        end
        if not rows or #rows == 0 then return nil end
        local best, best_sim = nil, -1
        for _, row in ipairs(rows) do
            local sim = _cosine(row.embedding, vec)
            if sim > best_sim then best_sim, best = sim, row end
        end
        if best and best_sim >= threshold then
            best.embedding = nil
            return best, best_sim
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
    local sim = tonumber(row.sim) or 0
    if sim >= threshold then
        row.sim = nil
        return row, sim
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
    -- Lazy re-init: if the embedder was unreachable at startup, try once to
    -- recover before failing the write with a clear error.
    if _has_ensure_ready then
        local lm = _get_luamemo()
        if not lm.ensure_ready() then
            return nil, "luamemo not ready (embedder unavailable)"
        end
    end
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
    --
    -- Dedup and the retrieval-miss signal (learned-from-usage, opt-in via
    -- feedback_enabled) both need the nearest existing memory, so run ONE lookup
    -- at the lower of the two thresholds and classify by the returned similarity —
    -- never two searches. A near-duplicate write means retrieval failed to surface
    -- an existing memory (it got re-created): recording a 'miss' bumps that
    -- memory's importance (more findable next time) and feeds the ranker.
    local strategy     = args.dedup_strategy or cfg.dedup_strategy or "update"
    local dedup_active = cfg.dedup_enabled and strategy ~= "append"
    local miss_active  = cfg.feedback_enabled
    local dedup_thr    = cfg.dedup_threshold or 0.95
    local miss_thr     = cfg.miss_threshold or 0.90

    local existing
    if dedup_active or miss_active then
        local low
        if dedup_active and miss_active then low = math.min(dedup_thr, miss_thr)
        elseif dedup_active then low = dedup_thr
        else low = miss_thr end

        local near, sim = _find_near_duplicate(scope, vec, low)
        if near and near.id then
            if miss_active and sim >= miss_thr then       -- retrieval miss (fail-soft)
                pcall(function()
                    require("luamemo.digest").record_event(
                        near.id, scope, "miss", 0.5, "miss:duplicate-write")
                end)
            end
            if dedup_active and sim >= dedup_thr then existing = near end
        end
    end

    if existing then
        if strategy == "skip" then
            return existing, nil, "skipped"
        elseif strategy == "update" then
            local merged, merr = _merge_into(existing, args)
            if not merged then return nil, merr end
            return merged, nil, "merged"
        end
    end

    -- Tier: caller may override; otherwise derived from importance.
    local tier = args.tier
    if tier ~= nil then
        tier = math.max(0, math.min(3, math.floor(tonumber(tier) or 1)))
    else
        tier = _importance_to_tier(importance)
    end

    local ts_epoch = tonumber(args.created_at)
    local sql
    if ts_epoch then
        sql = ([[
            INSERT INTO %s (scope, kind, title, body, tags, metadata, embedding, importance, decay_rate, was_truncated, tier, created_at, updated_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %d, to_timestamp(%f), to_timestamp(%f))
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
            tier,
            ts_epoch, ts_epoch,
            RETURN_COLS
        )
    else
        sql = ([[
            INSERT INTO %s (scope, kind, title, body, tags, metadata, embedding, importance, decay_rate, was_truncated, tier)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %d)
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
            tier,
            RETURN_COLS
        )
    end
    local rows, qerr = db.query(sql)
    if not rows then return nil, "write: db error: " .. tostring(qerr) end
    -- Keep LSH index current when active for this scope.
    local _lsh = _lsh_index[scope]
    if _lsh and _lsh ~= false then _lsh:insert(rows[1].id, vec) end
    -- Preference extraction: create synthetic companion memories for
    -- preference / habit / sentiment signals in the body.
    -- Skipped for synthetic rows (avoids infinite recursion) and when disabled.
    -- Uses write_many() so multiple synthetics are embedded in one batch call.
    if cfg.patterns_enabled ~= false then
        local is_syn = type(args.metadata) == "table" and args.metadata.is_synthetic
        if not is_syn then
            local syns = patterns.extract(args.body or "")
            if #syns > 0 then
                local syn_rows = {}
                for _, syn_body in ipairs(syns) do
                    syn_rows[#syn_rows + 1] = {
                        scope      = scope,
                        kind       = "fact",
                        title      = "Preference: " .. syn_body:sub(1, 60),
                        body       = syn_body,
                        importance = 0.4,
                        metadata   = { is_synthetic = true, source_id = rows[1].id },
                    }
                end
                local _wr_ok, _wr_err = pcall(M.write_many, syn_rows, { dedup_strategy = "skip" })
                if not _wr_ok then
                    if type(ngx) == "table" and ngx.log and ngx.WARN then
                        ngx.log(ngx.WARN, "[luamemo.patterns] synthetic write failed: " .. tostring(_wr_err))
                    end
                end
            end
        end
    end
    -- Notify consolidation engine of new unprocessed memory.
    consolidate.notify(scope)
    digest.notify_write(scope)
    -- Opportunistic maintenance: piggyback a debounced digest on the write so tier
    -- promotion / consolidation / decay happen without depending on any external
    -- trigger (agent or scheduler) remembering to. Opt-in (auto_digest_enabled);
    -- atomically debounced inside maybe_run (at most once per interval per scope);
    -- fail-soft; the _running guard makes re-entry via consolidate impossible.
    if cfg.auto_digest_enabled then
        pcall(function() digest.maybe_run(scope) end)
    end
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

    -- Phase A1: validate every row and collect an embed queue.
    -- Embedding is deferred so we can fan it out concurrently in A2.
    -- Rows with args.no_embed = true skip embedding + dedup entirely and are
    -- inserted with a NULL vector (FTS-only). Used for rows whose retrieval is
    -- purely lexical (e.g. codebase file rows), to avoid paid embed calls.
    local prepared = {}
    local embed_queue = {}   -- { i, text, title, body, importance, decay_rate, args }
    local noembed_rows = {}  -- { i, title, body, importance, decay_rate, args }
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
                        if args.no_embed then
                            noembed_rows[#noembed_rows + 1] = {
                                i          = i,
                                title      = title,
                                body       = body,
                                importance = importance,
                                decay_rate = decay_rate,
                                args       = args,
                            }
                        else
                            embed_queue[#embed_queue + 1] = {
                                i          = i,
                                text       = title .. "\n" .. body,
                                title      = title,
                                body       = body,
                                importance = importance,
                                decay_rate = decay_rate,
                                args       = args,
                            }
                        end
                    end
                end
            end
        end
    end

    -- Phase A2: embed all queued rows.
    -- In plain Lua with an HTTP embedder and more than one row, fan out
    -- concurrently via luamemo.async so total latency ≈ 1 × embed_latency.
    -- In OpenResty (ngx global present) resty.http is already non-blocking,
    -- so the async scheduler adds overhead without benefit — stay sequential.
    local vecs = {}   -- [j] = { vec = table, truncated = bool } for embed_queue[j]
    local is_openresty = (type(ngx) == "table")
    if not is_openresty and #embed_queue > 1 then
        local async = require("luamemo.async")
        local tasks = {}
        for j, item in ipairs(embed_queue) do
            local text = item.text
            tasks[j] = function()
                local vec, eerr, vtrunc = embed.embed_async(text, async.wait)
                return { vec = vec, err = eerr, truncated = vtrunc }
            end
        end
        local timeout_per = tonumber(cfg.embed_timeout_ms) or DEFAULT_EMBED_TIMEOUT_MS
        local async_results = async.run_all(tasks, timeout_per * #embed_queue + 5000)
        for j, ar in ipairs(async_results) do
            local r = ar.result
            if ar.ok and r and r.vec then
                vecs[j] = { vec = r.vec, truncated = r.truncated }
            else
                local errmsg = (r and r.err) or (not ar.ok and tostring(ar.result)) or "embed failed"
                results[embed_queue[j].i] = { row = nil, action = nil, error = errmsg }
            end
        end
    else
        -- Sequential path: OpenResty, single row, or local embedder.
        for j, item in ipairs(embed_queue) do
            local vec, eerr, vtrunc = embed.embed(item.text)
            if not vec then
                results[item.i] = { row = nil, action = nil, error = eerr }
            else
                vecs[j] = { vec = vec, truncated = vtrunc and true or false }
            end
        end
    end

    -- Phase A3: batch dedup + build prepared INSERT entries.
    --
    -- Original approach: one _find_near_duplicate() DB call per row = O(N) round-trips.
    -- New approach (when dedup is active):
    --   1. Intra-batch dedup: compare all pairs within the embed_queue first so
    --      rows that duplicate each other within the same batch are handled correctly
    --      (DB candidates won't include rows being inserted in this very call).
    --   2. Group embedded rows by scope (usually 1 scope, sometimes a few).
    --   3. Issue ONE candidate fetch per distinct scope from the DB.
    --   4. Run cosine comparisons in Lua memory — no extra DB round-trips.
    -- O(distinct_scopes) DB calls instead of O(N). For N=100 rows of 1 scope
    -- this eliminates ~99 round-trips; memory footprint ≈ candidates × dim × 8B.
    local threshold = cfg.dedup_threshold or 0.95
    local dedup_active = cfg.dedup_enabled and strategy ~= "append"

    -- 1. Intra-batch dedup pass (only when dedup is active).
    --    For each successfully embedded pair (j, k) with j<k, if cosine ≥ threshold
    --    the later-indexed item (k) is treated as a duplicate of item j.
    --    We process pairs in order so the first occurrence always wins.
    if dedup_active then
        for j = 1, #embed_queue do
            if vecs[j] then
                for k = j + 1, #embed_queue do
                    if vecs[k] then
                        local sim = _cosine(vecs[j].vec, vecs[k].vec)
                        if sim >= threshold then
                            local i_j = embed_queue[j].i
                            local i_k = embed_queue[k].i
                            -- "k" duplicates "j".  Build a synthetic "existing" row
                            -- from item j's args so the skip/update logic below works
                            -- correctly.  We only have vector similarity here; the
                            -- actual DB row does not exist yet, so we skip/merge in
                            -- favour of item j by marking item k as a duplicate.
                            if strategy == "skip" then
                                -- Mark k as skipped; j will be inserted normally.
                                results[i_k] = { row = nil, action = "skipped",
                                    error = "duplicate of batch item " .. i_j }
                                vecs[k] = nil  -- remove from further processing
                            elseif strategy == "update" then
                                -- Merge k's args into j's args (title/body/tags/meta).
                                local a_j = embed_queue[j].args
                                local a_k = embed_queue[k].args
                                if a_k.body  and a_k.body  ~= "" then a_j.body  = a_j.body .. "\n" .. a_k.body  end
                                if a_k.tags     then a_j.tags     = a_k.tags     end
                                if a_k.metadata then a_j.metadata = a_k.metadata end
                                results[i_k] = { row = nil, action = "merged",
                                    error = "merged into batch item " .. i_j }
                                vecs[k] = nil
                            end
                        end
                    end
                end
            end
        end
    end

    -- 2+3. Group by scope; one candidate fetch per distinct scope.
    --      Only runs when dedup is active.
    local scope_candidates = {}  -- [scope_str] = array of { row, embedding_vec }
    if dedup_active then
        -- Collect distinct scopes among still-valid embed_queue items.
        local scopes_needed = {}
        for j, item in ipairs(embed_queue) do
            if vecs[j] and not results[item.i] then
                local sc = item.args.scope or cfg.default_scope
                scopes_needed[sc] = true
            end
        end
        -- Fetch candidates once per scope.
        local cap = tonumber(cfg.dedup_candidate_limit) or 1000
        for sc in pairs(scopes_needed) do
            local sql
            if _backend == "bruteforce" then
                sql = ([[
                    SELECT id, title, body, tags, metadata, importance,
                           decay_rate, was_truncated, created_at, updated_at,
                           scope, kind, embedding
                    FROM %s WHERE scope = %s
                    ORDER BY updated_at DESC LIMIT %d
                ]]):format(tbl(), db.escape_literal(sc), cap)
            else
                -- pgvector: embedding column is a vector type; cast to text for transfer
                -- then parse back so we can use _cosine() on it in Lua.
                sql = ([[
                    SELECT id, title, body, tags, metadata, importance,
                           decay_rate, was_truncated, created_at, updated_at,
                           scope, kind, embedding::text AS embedding_text
                    FROM %s WHERE scope = %s
                    ORDER BY updated_at DESC LIMIT %d
                ]]):format(tbl(), db.escape_literal(sc), cap)
            end
            local rows = db.query(sql)
            if rows then
                local cands = {}
                for _, row in ipairs(rows) do
                    -- Parse embedding into a Lua number array for _cosine().
                    local ev = row.embedding or row.embedding_text
                    local vec_parsed
                    if type(ev) == "table" then
                        vec_parsed = ev  -- bruteforce: pgmoon returns real[] as table
                    elseif type(ev) == "string" then
                        -- pgvector returns '[1.0,2.0,...]'; bruteforce '{1.0,...}'
                        vec_parsed = {}
                        for num in ev:gmatch("[%-]?%d+%.?%d*[eE]?[+-]?%d*") do
                            vec_parsed[#vec_parsed + 1] = tonumber(num)
                        end
                    end
                    row.embedding      = nil
                    row.embedding_text = nil
                    cands[#cands + 1] = { row = row, vec = vec_parsed }
                end
                scope_candidates[sc] = cands
            else
                scope_candidates[sc] = {}
            end
        end
    end

    -- 4. Per-row dedup against in-memory candidates + build prepared entries.
    for j, item in ipairs(embed_queue) do
        local slot = vecs[j]
        if slot then
            local i, args_i = item.i, item.args
            local vec, vtrunc = slot.vec, slot.truncated

            if dedup_active and not results[i] then
                local sc = args_i.scope or cfg.default_scope
                local cands = scope_candidates[sc] or {}
                local best_row, best_sim = nil, -1
                for _, c in ipairs(cands) do
                    if c.vec then
                        local sim = _cosine(c.vec, vec)
                        if sim > best_sim then best_sim = sim; best_row = c.row end
                    end
                end
                if best_row and best_sim >= threshold then
                    if strategy == "skip" then
                        results[i] = { row = best_row, action = "skipped" }
                    elseif strategy == "update" then
                        local merged, merr = _merge_into(best_row, args_i)
                        if not merged then
                            results[i] = { row = nil, action = nil, error = merr }
                        else
                            results[i] = { row = merged, action = "merged" }
                        end
                    end
                end
            end

            if results[i] == nil then
                local p_tier = args_i.tier
                if p_tier ~= nil then
                    p_tier = math.max(0, math.min(3, math.floor(tonumber(p_tier) or 1)))
                else
                    p_tier = _importance_to_tier(item.importance)
                end
                prepared[i] = {
                    scope      = args_i.scope or cfg.default_scope,
                    kind       = args_i.kind or "fact",
                    title      = item.title,
                    body       = item.body,
                    tags       = args_i.tags or {},
                    meta       = args_i.metadata or {},
                    vec        = vec,
                    importance = item.importance,
                    decay_rate = item.decay_rate,
                    truncated  = vtrunc and true or false,
                    tier       = p_tier,
                    created_at = tonumber(args_i.created_at),
                }
            end
        end
    end

    -- no_embed rows: insert with a NULL vector, no embed call, no dedup.
    for _, item in ipairs(noembed_rows) do
        local i, args_i = item.i, item.args
        local p_tier = args_i.tier
        if p_tier ~= nil then
            p_tier = math.max(0, math.min(3, math.floor(tonumber(p_tier) or 1)))
        else
            p_tier = _importance_to_tier(item.importance)
        end
        prepared[i] = {
            scope      = args_i.scope or cfg.default_scope,
            kind       = args_i.kind or "fact",
            title      = item.title,
            body       = item.body,
            tags       = args_i.tags or {},
            meta       = args_i.metadata or {},
            vec        = nil,   -- FTS-only: _embed_literal(nil) → NULL
            importance = item.importance,
            decay_rate = item.decay_rate,
            truncated  = false,
            tier       = p_tier,
            created_at = tonumber(args_i.created_at),
        }
    end

    -- Phase B: execute multi-VALUES INSERT chunks. We track the original
    -- index of each prepared row so RETURNING rows map back to caller order.
    local indices = {}
    for i = 1, #rows_in do
        if prepared[i] then table.insert(indices, i) end
    end

    -- Hoist timestamp check: if any prepared row has a custom created_at, use
    -- the extended column list for ALL batches (rows without ts fall back to
    -- CURRENT_TIMESTAMP via ts_expr).  This avoids a per-batch O(batch) scan.
    local any_ts = false
    for _, idx in ipairs(indices) do
        if prepared[idx] and prepared[idx].created_at then
            any_ts = true; break
        end
    end
    local col_list = any_ts
        and "scope, kind, title, body, tags, metadata, embedding, importance, decay_rate, was_truncated, tier, created_at, updated_at"
        or  "scope, kind, title, body, tags, metadata, embedding, importance, decay_rate, was_truncated, tier"
    local row_fmt = any_ts
        and "(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %d, %s, %s)"
        or  "(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %d)"

    local pos = 1
    while pos <= #indices do
        local last = math.min(pos + batch_size - 1, #indices)
        local values = {}
        for j = pos, last do
            local p = prepared[indices[j]]
            if any_ts then
                local ts_expr = p.created_at
                    and ("to_timestamp(" .. p.created_at .. ")")
                    or "CURRENT_TIMESTAMP"
                values[#values + 1] = string.format(row_fmt,
                    db.escape_literal(p.scope),
                    db.escape_literal(p.kind),
                    db.escape_literal(p.title),
                    db.escape_literal(p.body),
                    pg_array(p.tags),
                    as_jsonb(p.meta),
                    _embed_literal(p.vec),
                    db.escape_literal(p.importance),
                    db.escape_literal(p.decay_rate),
                    db.escape_literal(p.truncated and true or false),
                    p.tier or 1,
                    ts_expr, ts_expr
                )
            else
                values[#values + 1] = string.format(row_fmt,
                    db.escape_literal(p.scope),
                    db.escape_literal(p.kind),
                    db.escape_literal(p.title),
                    db.escape_literal(p.body),
                    pg_array(p.tags),
                    as_jsonb(p.meta),
                    _embed_literal(p.vec),
                    db.escape_literal(p.importance),
                    db.escape_literal(p.decay_rate),
                    db.escape_literal(p.truncated and true or false),
                    p.tier or 1
                )
            end
        end
        local sql = ([[
            INSERT INTO %s (%s)
            VALUES %s
            RETURNING %s
        ]]):format(tbl(), col_list, table.concat(values, ", "), RETURN_COLS)
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
                    -- Keep LSH index current when active for this scope.
                    local p = prepared[indices[j]]
                    if p then
                        local _lsh = _lsh_index[p.scope]
                        if _lsh and _lsh ~= false then _lsh:insert(r.id, p.vec) end
                    end
                else
                    results[indices[j]] = { row = nil, action = nil,
                        error = "write_many: missing RETURNING row" }
                end
            end
        end
        pos = last + 1
    end

    -- Notify consolidation engine for each scope touched by this batch.
    local _seen_scopes = {}
    for _, r in ipairs(results) do
        if r.row and r.row.scope and not _seen_scopes[r.row.scope] then
            _seen_scopes[r.row.scope] = true
            consolidate.notify(r.row.scope)
            digest.notify_write(r.row.scope)
        end
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
    local update_vec = nil  -- tracked so we can keep the LSH index current below
    if patch.title or patch.body then
        local title = patch.title or existing.title
        local body  = patch.body  or existing.body
        local vec, eerr, vtrunc = embed.embed(title .. "\n" .. body)
        if not vec then return nil, eerr end
        update_vec = vec
        table.insert(fields, "embedding = " .. _embed_literal(vec))
        table.insert(fields, "was_truncated = " .. db.escape_literal(vtrunc and true or false))
    end

    if #fields == 0 then return existing end

    local sql = "UPDATE " .. tbl() .. " SET " .. table.concat(fields, ", ")
        .. " WHERE id = ? RETURNING " .. RETURN_COLS
    table.insert(vals, id)
    local rows, err = db.query(db.interpolate_query(sql, unpack(vals)))
    if not rows then return nil, "update: db error: " .. tostring(err) end
    -- Keep LSH index current when the embedding was re-computed.
    if update_vec then
        local sc  = patch.scope or existing.scope
        local _lsh = _lsh_index[sc]
        if _lsh and _lsh ~= false then _lsh:insert(id, update_vec) end
    end
    return rows[1]
end

-- ---------------------------------------------------------------------------
-- _build_metadata_conds  (shared by search and delete_where)
-- ---------------------------------------------------------------------------
local function _build_metadata_conds(metadata_filter)
    if not metadata_filter then return end
    local out = {}
    for k, v in pairs(metadata_filter) do
        -- Only allow string keys and string/number values to prevent injection.
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
            if type(v) == "string" or type(v) == "number" then
                table.insert(out, "metadata->>" .. db.escape_literal(k) ..
                    " = " .. db.escape_literal(tostring(v)))
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- delete
-- ---------------------------------------------------------------------------
function M.delete(id)
    id = tonumber(id)
    if not id then return nil, "delete: invalid id" end
    return db.delete(cfg.db_table, { id = id })
end

-- ---------------------------------------------------------------------------
-- delete_where  — bulk delete by scope/kind/metadata_filter
--
-- Collects matching row IDs via a raw SQL query (not store.search, which
-- requires an embed call) and deletes them in batches of 500. Loops until
-- the scope is empty of matching rows.
--
-- args: { scope?, kind?, metadata_filter? }
-- Returns: total count of deleted rows, or nil, err on failure.
-- ---------------------------------------------------------------------------
function M.delete_where(args)
    args = args or {}
    local conds = {}
    if args.scope then table.insert(conds, "scope = " .. db.escape_literal(args.scope)) end
    if args.kind  then table.insert(conds, "kind  = " .. db.escape_literal(args.kind))  end
    local meta_conds = _build_metadata_conds(args.metadata_filter)
    if meta_conds then for _, c in ipairs(meta_conds) do table.insert(conds, c) end end

    if #conds == 0 then return nil, "delete_where: at least one filter required" end

    local where = "WHERE " .. table.concat(conds, " AND ")
    local total = 0

    while true do
        local sel = ("SELECT id FROM %s %s LIMIT 500"):format(tbl(), where)
        local rows, qerr = db.query(sel)
        if not rows then return nil, "delete_where: " .. tostring(qerr) end
        if #rows == 0 then break end

        local ids = {}
        for _, r in ipairs(rows) do ids[#ids + 1] = tostring(r.id) end
        local del = ("DELETE FROM %s WHERE id IN (%s)"):format(tbl(), table.concat(ids, ","))
        local _, derr = db.query(del)
        if derr then return nil, "delete_where: " .. tostring(derr) end
        total = total + #rows
        if #rows < 500 then break end
    end

    return total
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

    local id_list, id_err = util.sql_id_list(ids)
    if not id_list then
        db.query("ROLLBACK")
        return nil, "replace_with_summary: no valid ids"
    end
    local del_sql = "DELETE FROM " .. tbl()
        .. " WHERE id IN (" .. id_list .. ")"
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
    local limit  = math.min(tonumber(args.limit) or 20, 200)
    local offset = math.max(tonumber(args.offset) or 0, 0)
    local conds  = {}
    if args.scope then
        table.insert(conds, "scope = " .. db.escape_literal(args.scope))
    end
    if args.kind then
        table.insert(conds, "kind = " .. db.escape_literal(args.kind))
    end
    local where = #conds > 0 and ("WHERE " .. table.concat(conds, " AND ")) or ""
    local sql = ([[
        SELECT %s
        FROM %s %s
        ORDER BY created_at DESC
        LIMIT %d OFFSET %d
    ]]):format(RETURN_COLS, tbl(), where, limit, offset)
    return db.query(sql) or {}
end

-- ---------------------------------------------------------------------------
-- find_decayed
-- Finds memories whose effective importance (importance × exp(−decay_rate ×
-- days_since_updated)) has fallen below `decay_threshold` (default 0.05).
-- When `apply` is true (the default), sets their importance to 0 so they
-- drop out of future searches without being hard-deleted.
-- Returns (ids, err).
-- ---------------------------------------------------------------------------
function M.find_decayed(opts)
    opts = opts or {}
    local threshold = tonumber(opts.decay_threshold) or 0.05
    local max_rows  = math.min(tonumber(opts.max_rows) or 500, 5000)
    local apply     = opts.apply ~= false   -- default true

    local conds = {
        "decay_rate > 0",
        "importance > 0",
        ("(importance * exp(-decay_rate * (EXTRACT(EPOCH FROM (now() - updated_at)) / 86400.0))) < "
            .. db.escape_literal(threshold)),
    }
    if opts.scope then
        table.insert(conds, "scope = " .. db.escape_literal(opts.scope))
    end

    local sql = ([[
        SELECT id FROM %s
        WHERE %s
        ORDER BY updated_at ASC
        LIMIT %d
    ]]):format(tbl(), table.concat(conds, " AND "), max_rows)

    local rows, qerr = db.query(sql)
    if not rows then return nil, "find_decayed: db error: " .. tostring(qerr) end

    local ids = {}
    for _, r in ipairs(rows) do table.insert(ids, r.id) end

    if apply and #ids > 0 then
        local id_list = util.sql_id_list(ids)
        local _, uerr = db.query(
            "UPDATE " .. tbl() .. " SET importance = 0 WHERE id IN (" .. id_list .. ")")
        if uerr then
            return nil, "find_decayed: update failed: " .. tostring(uerr)
        end
    end

    return ids, nil
end

-- ---------------------------------------------------------------------------
-- find_clusters
-- Fetches up to `max_rows` memories for the given scope (importance > 0) and
-- groups them by cosine similarity using union-find (O(N²) pairwise, capped
-- at max_rows = 500 by default). Returns only multi-member clusters.
-- Embeddings are stripped from the returned members.
--
-- Works on both backends:
--   bruteforce — embedding is REAL[]; fetched directly.
--   pgvector   — embedding is vector(N); cast to REAL[] in the SELECT so
--                the Lua driver returns a parseable array.
--
-- Returns (clusters, err) where each cluster is:
--   { ids={...}, titles={...}, members=[{row without embedding}] }
-- ---------------------------------------------------------------------------
function M.find_clusters(opts)
    opts = opts or {}
    local threshold = tonumber(opts.similarity_threshold) or 0.85
    local max_rows  = math.min(tonumber(opts.max_rows) or 500, 5000)

    -- Cast vector → REAL[] on the pgvector backend so Lua gets a Lua array.
    local emb_col = (_backend == "pgvector")
        and "embedding::REAL[] AS embedding"
        or  "embedding"

    local conds = { "importance > 0" }
    if opts.scope then
        table.insert(conds, "scope = " .. db.escape_literal(opts.scope))
    end

    local sql = ([[
        SELECT %s, %s
        FROM %s
        WHERE %s
        ORDER BY importance DESC, updated_at DESC
        LIMIT %d
    ]]):format(RETURN_COLS, emb_col, tbl(), table.concat(conds, " AND "), max_rows)

    local rows, qerr = db.query(sql)
    if not rows then return nil, "find_clusters: db error: " .. tostring(qerr) end
    if #rows == 0 then return {}, nil end

    -- Union-Find with path compression.
    local parent = {}
    for i = 1, #rows do parent[i] = i end

    local function find(i)
        while parent[i] ~= i do
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end

    -- O(N²) pairwise similarity. Default cap (500 rows) keeps this < 1s
    -- in plain Lua 5.1 at 384 dimensions.
    for i = 1, #rows do
        for j = i + 1, #rows do
            if _cosine(rows[i].embedding, rows[j].embedding) >= threshold then
                local ri, rj = find(i), find(j)
                if ri ~= rj then parent[ri] = rj end
            end
        end
    end

    -- Group indices by root.
    local groups = {}
    for i = 1, #rows do
        local root = find(i)
        groups[root] = groups[root] or {}
        table.insert(groups[root], i)
    end

    -- Build result: only multi-member groups; strip embeddings.
    local result = {}
    for _, indices in pairs(groups) do
        if #indices > 1 then
            local ids, titles, members = {}, {}, {}
            for _, idx in ipairs(indices) do
                local m = rows[idx]
                table.insert(ids, m.id)
                table.insert(titles, m.title)
                local mc = {}
                for k, v in pairs(m) do if k ~= "embedding" then mc[k] = v end end
                table.insert(members, mc)
            end
            table.sort(ids)
            table.insert(result, { ids = ids, titles = titles, members = members })
        end
    end

    return result, nil
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
-- reembed_scope
--
-- Re-embeds every memory in a scope with the CURRENTLY configured embedder.
-- Needed after switching embedders (calibrate re-picking a different one on
-- a new host, or manually changing MEMO_EMBEDDER*): two different models'
-- vector spaces are never comparable, even at the same embed_dim, so
-- existing rows silently lose vector-search relevance until re-embedded.
-- (FTS still works, which is exactly why this is easy to miss — hybrid
-- search doesn't fully collapse, it just quietly gets worse.)
--
-- Cursor-paginated by id (ASC) so it scales past any single-batch limit.
-- Re-embeds via M.update(id, {title, body}) — the same write path a real
-- edit uses, so decay/tier/consolidation bookkeeping stays consistent; only
-- title/body are passed, so nothing else on the row is touched.
--
-- opts.batch    rows per page (default 100, max 1000)
-- opts.dry_run  true → just count matching rows, no writes
-- opts.on_progress  optional fn(updated, last_id) called after each page
-- Returns { updated, errors, last_id } (errors: list of {id, err}), or for
-- dry_run: { would_update, dry_run = true }.
-- ---------------------------------------------------------------------------
function M.reembed_scope(scope, opts)
    if not scope or scope == "" then
        return nil, "reembed_scope: scope required"
    end
    opts = opts or {}

    if opts.dry_run then
        local r = db.query("SELECT count(*) AS n FROM " .. tbl()
            .. " WHERE scope = " .. db.escape_literal(scope))
        return { would_update = r and tonumber(r[1].n) or 0, dry_run = true }
    end

    local batch = math.max(1, math.min(tonumber(opts.batch) or 100, 1000))
    local updated, errors = 0, {}
    local last_id = 0
    while true do
        local rows = db.query(([[
            SELECT id, title, body FROM %s
             WHERE scope = %s AND id > %d
             ORDER BY id ASC LIMIT %d
        ]]):format(tbl(), db.escape_literal(scope), last_id, batch))
        if not rows or #rows == 0 then break end
        for _, r in ipairs(rows) do
            local _, uerr = M.update(r.id, { title = r.title, body = r.body })
            if uerr then
                errors[#errors + 1] = { id = r.id, err = uerr }
            else
                updated = updated + 1
            end
            last_id = r.id
        end
        if opts.on_progress then opts.on_progress(updated, last_id) end
        if #rows < batch then break end
    end
    return { updated = updated, errors = errors, last_id = last_id }
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
-- Build a scope WHERE fragment. `scope` may be a single string (scope = 'x') or
-- an array of strings — a scope SET, for hierarchical multi-scope search
-- (scope = ANY(ARRAY[...])). Returns nil when there is no scope filter. Tier
-- already factors into the candidate weight, so a higher-tier memory (e.g. an org
-- directive) outranks a lower-tier one across the union automatically.
local function _scope_sql(scope)
    if type(scope) == "table" then
        local parts = {}
        for _, s in ipairs(scope) do
            if s ~= nil and s ~= "" then parts[#parts + 1] = db.escape_literal(s) end
        end
        if #parts == 0 then return nil end
        return "scope = ANY(ARRAY[" .. table.concat(parts, ",") .. "])"
    elseif scope and scope ~= "" then
        return "scope = " .. db.escape_literal(scope)
    end
    return nil
end

local function _search_pgvector(q, qvec, scope, kind, limit, wv, wf, ignore_decay, since_sql, until_sql, tier_min, tier_max, metadata_filter)
    local qvec_lit = embed.to_pg_literal(qvec)

    local conds = {}
    do local sc = _scope_sql(scope); if sc then table.insert(conds, sc) end end
    if kind     then table.insert(conds, "kind  = " .. db.escape_literal(kind))  end
    if since_sql then table.insert(conds, "updated_at >= " .. since_sql) end
    if until_sql then table.insert(conds, "updated_at <  " .. until_sql) end
    if tier_min then table.insert(conds, "tier >= " .. math.max(0, math.min(3, math.floor(tonumber(tier_min))))) end
    if tier_max then table.insert(conds, "tier <= " .. math.max(0, math.min(3, math.floor(tonumber(tier_max))))) end
    local meta_conds = _build_metadata_conds(metadata_filter)
    if meta_conds then for _, c in ipairs(meta_conds) do table.insert(conds, c) end end
    local where = #conds > 0 and ("WHERE " .. table.concat(conds, " AND ")) or ""

    local weight_expr = ignore_decay
        and "1.0"
        or  "importance * exp(-decay_rate * (EXTRACT(EPOCH FROM (now() - updated_at)) / 86400.0))"

    -- True hybrid candidate selection: the candidate pool is the UNION of the
    -- vector-nearest rows AND the top FTS-matching rows. Retrieving by vector
    -- distance alone (the old approach) permanently excluded rows whose match is
    -- lexical but vector-far — including rows with a NULL embedding (FTS-only),
    -- which sort NULLS-LAST and never entered the top-N window. The FTS leg fixes
    -- both: lexical hits are found regardless of vector distance, and
    -- COALESCE(...,0) gives NULL-embedding rows a real (0) vector score so the
    -- blend/sort is well-defined instead of NULL (which would sort first).
    local T        = tbl()
    local N        = math.max(50, math.floor(tonumber(limit) or 10))
    local lim      = math.floor(tonumber(limit) or 10)
    local qlit     = db.escape_literal(q)
    local tsq      = "plainto_tsquery('english', " .. qlit .. ")"
    local fts_match = "fts @@ " .. tsq
    local fts_where = (where ~= "")
        and (where .. " AND " .. fts_match)
        or  ("WHERE " .. fts_match)
    local wv_lit = ("%.6f"):format(wv)
    local wf_lit = ("%.6f"):format(wf)

    local sql =
        "WITH vec_ids AS (" ..
        "  SELECT id FROM " .. T .. " " .. where ..
        "  ORDER BY embedding <=> " .. qvec_lit .. " LIMIT " .. N ..
        "), fts_ids AS (" ..
        "  SELECT id FROM " .. T .. " " .. fts_where ..
        "  ORDER BY ts_rank_cd(fts, " .. tsq .. ") DESC LIMIT " .. N ..
        "), cand_ids AS (" ..
        "  SELECT id FROM vec_ids UNION SELECT id FROM fts_ids" ..
        "), candidates AS (" ..
        "  SELECT id, scope, kind, title, body, tags, metadata," ..
        "         importance, decay_rate, created_at, updated_at, tier," ..
        "         COALESCE(1 - (embedding <=> " .. qvec_lit .. "), 0) AS vec_score," ..
        "         ts_rank_cd(fts, " .. tsq .. ") AS fts_score," ..
        "         (" .. weight_expr .. ") AS weight" ..
        "  FROM " .. T .. " WHERE id IN (SELECT id FROM cand_ids)" ..
        "), normalised AS (" ..
        "  SELECT *," ..
        "         CASE WHEN max(vec_score) OVER () > 0" ..
        "              THEN vec_score / max(vec_score) OVER () ELSE 0 END AS vec_n," ..
        "         CASE WHEN max(fts_score) OVER () > 0" ..
        "              THEN fts_score / max(fts_score) OVER () ELSE 0 END AS fts_n" ..
        "  FROM candidates" ..
        ") SELECT id, scope, kind, title, body, tags, metadata," ..
        "         importance, decay_rate, created_at, updated_at, tier," ..
        "         vec_score, fts_score, weight," ..
        "         ((" .. wv_lit .. " * vec_n + " .. wf_lit .. " * fts_n) * weight) AS score" ..
        "  FROM normalised ORDER BY score DESC LIMIT " .. lim

    local rows, qerr = db.query(sql)
    if not rows then return nil, "search: db error: " .. tostring(qerr) end
    return rows
end

-- Brute-force search: SQL pre-filters by scope/kind and ranks candidates by
-- FTS so lexically-relevant rows survive the cap; Lua computes cosine,
-- normalises both signals, blends, applies the importance/decay weight,
-- sorts, and trims. Returns rows in the same shape as the pgvector path.
local function _search_bruteforce(q, qvec, scope, kind, limit, wv, wf, ignore_decay, since_sql, until_sql, tier_min, tier_max, metadata_filter)
    local cap = tonumber(cfg.bruteforce_candidate_limit) or 1000

    local conds = {}
    do local sc = _scope_sql(scope); if sc then table.insert(conds, sc) end end
    if kind     then table.insert(conds, "kind  = " .. db.escape_literal(kind))  end
    if since_sql then table.insert(conds, "updated_at >= " .. since_sql) end
    if until_sql then table.insert(conds, "updated_at <  " .. until_sql) end
    if tier_min then table.insert(conds, "tier >= " .. math.max(0, math.min(3, math.floor(tonumber(tier_min))))) end
    if tier_max then table.insert(conds, "tier <= " .. math.max(0, math.min(3, math.floor(tonumber(tier_max))))) end
    local meta_conds = _build_metadata_conds(metadata_filter)
    if meta_conds then for _, c in ipairs(meta_conds) do table.insert(conds, c) end end
    local where = #conds > 0 and ("WHERE " .. table.concat(conds, " AND ")) or ""

    -- When the LSH index is active for this scope, pre-filter candidates by
    -- vector proximity instead of doing a full-table FTS-ranked scan.
    -- LSH is only active for single-scope searches on the bruteforce backend.
    local lsh_sql
    -- LSH is per-scope; for a multi-scope SET fall through to the full FTS-ranked
    -- scan (which honours scope = ANY(...) via `where`).
    local lsh_idx = (type(scope) == "string") and _get_lsh(scope, qvec) or nil
    if lsh_idx then
        local cand_ids = lsh_idx:query(qvec, cap)
        if #cand_ids > 0 then
            local id_list = util.sql_id_list(cand_ids)
            if id_list then
                -- Apply any extra filters (kind, tier, time) that the LSH
                -- pre-filter cannot enforce on its own.  Scope is implicit
                -- (index is per-scope) but included here for SQL clarity.
                local extra = (#conds > 0)
                    and (" AND " .. table.concat(conds, " AND "))
                    or  ""
                lsh_sql = ([[
                    SELECT id, scope, kind, title, body, tags, metadata,
                           importance, decay_rate, created_at, updated_at, embedding, tier,
                           ts_rank_cd(fts, plainto_tsquery('english', %s)) AS fts_score
                    FROM %s
                    WHERE id IN (%s)%s
                    ORDER BY fts_score DESC NULLS LAST
                    LIMIT %d
                ]]):format(db.escape_literal(q), tbl(), id_list, extra, cap)
            end
        end
    end

    -- Order candidates by FTS rank (desc) so the cap preserves the most
    -- lexically-relevant rows. NULLS LAST keeps non-matching rows behind.
    local sql = lsh_sql or ([[
        SELECT id, scope, kind, title, body, tags, metadata,
               importance, decay_rate, created_at, updated_at, embedding, tier,
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
    local now_epoch = os.time()  -- cached once; avoids N syscalls in the loop
    for _, r in ipairs(rows) do
        local vec_n = (max_vec > 0) and (r.vec_score / max_vec) or 0
        local fts_n = (max_fts > 0) and (r.fts_score / max_fts) or 0
        local weight = 1.0
        if not ignore_decay then
            local imp = tonumber(r.importance) or 1.0
            local dr  = tonumber(r.decay_rate) or 0.0
            -- Days since updated. updated_at comes back as a string from
            -- pgmoon; we approximate by parsing the date prefix. When
            -- parsing fails, age = 0 (no decay applied).
            local age_days = 0
            local s = tostring(r.updated_at or "")
            local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
            if y then
                local row_t = os.time({
                    year = tonumber(y), month = tonumber(m), day = tonumber(d),
                    hour = 0, min = 0, sec = 0,
                })
                age_days = math.max(0, (now_epoch - row_t) / 86400.0)
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

-- ---------------------------------------------------------------------------
-- _search_temporal
-- Third search leg: proximity-weighted date filter.  Fires only when the
-- caller supplies a parsed temporal window.  Returns rows in the same shape
-- as the vector/FTS legs so they can participate in RRF fusion.
-- ---------------------------------------------------------------------------
local function _search_temporal(scope, kind, window, fetch_limit, ignore_decay, tier_min, tier_max)
    local center_sql = ("to_timestamp(%d)"):format(math.floor(window.center))
    local half_secs  = math.max(1, window.half_secs)

    local conds = {}
    do local sc = _scope_sql(scope); if sc then table.insert(conds, sc) end end
    if kind     then table.insert(conds, "kind  = " .. db.escape_literal(kind))  end
    if tier_min then table.insert(conds, "tier >= " .. math.max(0, math.min(3, math.floor(tonumber(tier_min))))) end
    if tier_max then table.insert(conds, "tier <= " .. math.max(0, math.min(3, math.floor(tonumber(tier_max))))) end
    -- Widen the date filter to 3× the half-window so nearby-but-outside rows
    -- still contribute (they'll receive a low proximity score).
    local expanded = half_secs * 3
    table.insert(conds,
        ("created_at BETWEEN to_timestamp(%d) AND to_timestamp(%d)")
        :format(math.floor(window.center - expanded),
                math.floor(window.center + expanded)))
    local where = "WHERE " .. table.concat(conds, " AND ")

    local weight_expr = ignore_decay
        and "1.0"
        or  "importance * exp(-decay_rate * (EXTRACT(EPOCH FROM (now() - updated_at)) / 86400.0))"

    local sql = ([[SELECT %s,
           GREATEST(0.0,
               1.0 - ABS(EXTRACT(EPOCH FROM (created_at - %s)) / %d.0)
           ) AS temporal_score,
           (%s) AS weight
    FROM %s %s
    ORDER BY temporal_score DESC
    LIMIT %d]]):format(
        RETURN_COLS,
        center_sql,
        half_secs,
        weight_expr,
        tbl(),
        where,
        fetch_limit
    )
    local rows, qerr = db.query(sql)
    if not rows then return {} end  -- temporal leg is best-effort

    -- Set .score = temporal_score * weight and .vec_score/.fts_score for
    -- uniform shape.
    for _, r in ipairs(rows) do
        local ts = tonumber(r.temporal_score) or 0
        local w  = tonumber(r.weight) or 1.0
        r.vec_score      = 0
        r.fts_score      = 0
        r.temporal_score = ts
        r.score          = ts * w
    end
    return rows
end

-- Resolve an effective scope SET from context parts, highest-authority first
-- (org directives → project → personal → global). Nils/blanks skipped, duplicates
-- removed. Ranking across the set is by tier/importance (not this order), so the
-- order is only for readability. This is the seam Phase 12 (federation) plugs a
-- git/identity-derived context into; today callers pass the parts explicitly.
-- Pass the result as `search{ scopes = store.resolve_scopes{...}, query = ... }`.
function M.resolve_scopes(ctx)
    ctx = ctx or {}
    local seen, out = {}, {}
    local function add(s) if s and s ~= "" and not seen[s] then seen[s] = true; out[#out + 1] = s end end
    add(ctx.org); add(ctx.repo); add(ctx.user); add(ctx.global)
    return out
end

function M.search(args)
    assert(args and args.query, "search: query is required")
    local q     = args.query
    local scope = args.scope
    -- Hierarchical multi-scope: `args.scopes` (a set) searches the UNION of scopes
    -- with tier-priority (higher-tier memories surface first via the existing
    -- weight); `args.scope` (single) is unchanged. `scope_arg` feeds the search
    -- legs; `scope` stays the PRIMARY scope for feedback logging / callers.
    local scope_arg = scope
    if type(args.scopes) == "table" and #args.scopes > 0 then
        scope_arg = args.scopes
        if not scope or scope == "" then scope = args.scopes[1] end
    end
    local kind  = args.kind
    local limit = math.min(tonumber(args.limit) or 10, 100)
    local ignore_decay = args.ignore_decay and true or false

    -- Optional explicit temporal bounds.  `args["until"]` uses the bracket
    -- syntax because `until` is a Lua reserved word; accept both forms.
    local since_sql, t_err = _parse_time(args.since, "since")
    if t_err then return nil, t_err end
    local until_sql
    until_sql, t_err = _parse_time(args["until"] or args.until_, "until")
    if t_err then return nil, t_err end

    -- Natural-language temporal parsing (opt-in; disabled when skip_temporal=true).
    local twindow = nil
    if not args.skip_temporal then
        twindow = temporal.parse(q)
    end

    local weights = args.hybrid_weights or cfg.hybrid_weights
    local wv = weights.vector or 0.7
    local wf = weights.fts or 0.3

    -- Optional tier bounds for structural filtering.
    local tier_min = (args.tier_min ~= nil) and tonumber(args.tier_min) or nil
    local tier_max = (args.tier_max ~= nil) and tonumber(args.tier_max) or nil
    local metadata_filter = (type(args.metadata_filter) == "table") and args.metadata_filter or nil

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
    -- Over-fetch for RRF when temporal leg is active.
    local rrf_fetch = twindow and math.min(fetch_limit * 2, 100) or fetch_limit

    local rows
    if _backend == "bruteforce" then
        rows, err = _search_bruteforce(q, qvec, scope_arg, kind, rrf_fetch,
            wv, wf, ignore_decay, since_sql, until_sql, tier_min, tier_max, metadata_filter)
    else
        rows, err = _search_pgvector(q, qvec, scope_arg, kind, rrf_fetch,
            wv, wf, ignore_decay, since_sql, until_sql, tier_min, tier_max, metadata_filter)
    end
    if not rows then return nil, err end

    -- When a temporal window was detected, run the temporal leg and fuse
    -- all legs with RRF.  Fall back to weighted-blend when no temporal
    -- expression was found (unchanged behaviour for existing queries).
    if twindow then
        local t_rows = _search_temporal(scope_arg, kind, twindow, rrf_fetch, ignore_decay, tier_min, tier_max)
        -- Apply temporal proximity boost to the baseline rows, then re-sort
        -- so that RRF uses the boost-adjusted rank (not the raw vector rank).
        local alpha = (cfg.temporal_alpha) or 0.2
        for _, r in ipairs(rows) do
            local epoch = 0
            local s = tostring(r.created_at or "")
            local y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
            if y then
                epoch = os.time({
                    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                    hour = 0, min = 0, sec = 0,
                })
            end
            local boost = temporal.proximity_boost(epoch, twindow, alpha)
            r.score = (r.score or 0) * boost
        end
        -- Re-sort baseline by boosted score so RRF inherits the adjusted rank.
        table.sort(rows, function(a, b) return (a.score or 0) > (b.score or 0) end)
        -- Merge lists with RRF (only when the temporal leg returned results).
        local lists = { rows }
        if #t_rows > 0 then lists[#lists + 1] = t_rows end
        if #lists > 1 then
            rows = temporal.rrf_merge(lists)
        end
    end

    -- Post-retrieval boosts: proper-name and quoted-phrase matching (Plan 14).
    -- Applied immediately after RRF merge, before fetch_limit trim, so the
    -- boosted scores are visible to the reranker and final sort.
    if args.query and (#rows > 0) then
        local pnb_on = cfg.person_name_boost_enabled  ~= false
        local qpb_on = cfg.quoted_phrase_boost_enabled ~= false
        if pnb_on or qpb_on then
            local names   = (pnb_on and args.query:find("%u", 1))    and _extract_names(args.query)  or {}
            local phrases = (qpb_on and args.query:find('["\']', 1)) and _extract_quoted(args.query) or {}
            if #names > 0 or #phrases > 0 then
                local pb = cfg.person_name_boost  or 0.15
                local qb = cfg.quoted_phrase_boost or 0.40
                local _boosted = false
                for _, r in ipairs(rows) do
                    local body_lower  -- lazy: computed once on first use per row
                    -- Person-name boost: first matching name wins.
                    if #names > 0 then
                        body_lower = body_lower or (r.body or ""):lower()
                        for _, name in ipairs(names) do
                            if body_lower:find(name, 1, true) then
                                r.score = (r.score or 1.0) * (1 + pb)
                                _boosted = true
                                break
                            end
                        end
                    end
                    -- Quoted-phrase boost: first matching phrase wins.
                    if #phrases > 0 then
                        body_lower = body_lower or (r.body or ""):lower()
                        for _, phrase in ipairs(phrases) do
                            if body_lower:find(phrase, 1, true) then
                                r.score = (r.score or 1.0) * (1 + qb)
                                _boosted = true
                                break
                            end
                        end
                    end
                end
                -- Only re-sort when at least one score was actually modified.
                if _boosted then
                    table.sort(rows, function(a, b) return (a.score or 0) > (b.score or 0) end)
                end
            end
        end
    end

    -- Trim to fetch_limit before reranking.
    if #rows > fetch_limit then
        local trimmed = {}
        for i = 1, fetch_limit do trimmed[i] = rows[i] end
        rows = trimmed
    end

    -- Apply reranking (memory rows only — observations are appended afterward
    -- so they never compete with primary evidence in the reranker).
    local final_rows
    if not rerank_on or #rows <= 1 then
        final_rows = _trim(rows, limit)
    else
        -- Lazy-require to avoid a circular dependency at module load.
        local rerank = require("luamemo.rerank")
        local reranked, rerr = rerank.rerank(q, rows, {
            limit             = limit,
            rerank_scope      = scope,   -- primary scope → per-scope learned weights (Phase 11)
            rerank_weights    = args.rerank_weights,
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
            final_rows = _trim(rows, limit)
        else
            final_rows = reranked
        end
    end

    -- Phase 3: feedback capture. When enabled, append-only log the retrieval
    -- event (query + candidate memory ids in final rank order) so a later
    -- reinforcement on any candidate can form a (query, positive, negatives)
    -- training triple. Off by default; fail-silent; never affects results.
    if cfg.feedback_enabled and args.query and args.query ~= "" then
        local ids = {}
        for i = 1, #final_rows do
            local r = final_rows[i]
            if r and r.id then ids[#ids + 1] = r.id end
        end
        if #ids > 0 then
            pcall(function()
                require("luamemo.feedback").log_retrieval(scope, args.query, ids)
            end)
        end
    end

    -- Observation supplement: run any pending consolidation, then slot-append
    -- up to obs_max_slots observation rows AFTER all memory/reranked results.
    -- Observations never displace primary evidence from the top positions.
    if not args.skip_observations then
        -- Run any pending consolidation for this scope so results are fresh.
        if consolidate.pending(scope or "") then
            pcall(consolidate.process, scope or "")
        end
        local obs_rows = consolidate.search(scope or "", qvec, rrf_fetch)
        if #obs_rows > 0 then
            local obs_max = tonumber(args.obs_max_slots)
                or tonumber(cfg.obs_max_slots) or 3
            for i = 1, math.min(obs_max, #obs_rows) do
                final_rows[#final_rows + 1] = obs_rows[i]
            end
        end
    end

    return final_rows
end

return M
