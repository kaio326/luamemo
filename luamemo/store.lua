-- luamemo.store
-- Persistence + retrieval on the luamemo database (SQLite, via luamemo.db).
--
-- Search is hybrid: an exact vector scan and FTS5 (ranked like Postgres's ts_rank_cd —
-- luamemo.fts) each give their top N; the union is scored, normalised and blended, then
-- weighted by importance and decay. Vectors are float32 BLOBs (luamemo.vectors).
-- Timestamps are stored as integer microseconds; rows leave this module with them as text
-- ("2026-10-08 03:03:14.831072+00") and was_truncated as a boolean.

local db          = require("luamemo.db")
local embed       = require("luamemo.embed")
local util        = require("luamemo.util")
local temporal    = require("luamemo.temporal")
local consolidate = require("luamemo.consolidate")
local digest      = require("luamemo.digest")
local patterns    = require("luamemo.patterns")
local vectors     = require("luamemo.vectors")
local fts         = require("luamemo.fts")
-- Federation write policy: org: scopes are read-only replicas (role=dev) or
-- protected with a directive-only core tier (role=org). No-op when role=solo.
local policy      = require("luamemo.federation.policy")

local M = {}

local cfg = nil

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

function M.configure(config)
    cfg = config
    consolidate.configure(config)
    digest.configure(config)
end

--- The storage engine ("sqlite"). Kept for callers that report it.
function M.backend() return "sqlite" end

local TBL = "lm_memories"
local function tbl() return TBL end

--- The memories table's name (for ad-hoc tools that query it directly).
function M.table_name() return TBL end

-- Validate a numeric weight against [lo, hi].  Delegates to util.
local clamp_check = util.clamp_check
-- Every title / body is stored scrubbed (util.redact_secrets); so are the strings in tags
-- and metadata (scrub_all: a copy, nested tables too, their metatables — JSON nulls and
-- arrays — kept).
local scrub = util.redact_secrets
local function scrub_all(v, depth)
    if type(v) == "string" then return scrub(v) end
    if type(v) ~= "table" or (depth or 0) > 16 then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = scrub_all(x, (depth or 0) + 1) end
    return setmetatable(out, getmetatable(v))
end

-- A memory's fields as the store takes them, checked where they come in: MCP arguments
-- are JSON — an object or a null as the title / body crashed deep in the write ("attempt
-- to concatenate"), a string as metadata surfaced as a raw SQLite error. Numbers are taken
-- as text. → a shallow copy (JSON nulls dropped) | nil, why
local JSON_NULL = require("luamemo.json").null
local function _clean(a)
    local out = {}
    for k, v in pairs(a) do if v ~= JSON_NULL then out[k] = v end end
    for _, k in ipairs({ "title", "body", "kind", "scope" }) do
        local v = out[k]
        if v ~= nil and type(v) ~= "string" and type(v) ~= "number" then
            return nil, k .. " must be text, not " .. (type(v) == "table" and "an object or a list" or type(v))
        end
    end
    if out.tags ~= nil then
        local ok = type(out.tags) == "table"
        for _, t in ipairs(ok and out.tags or {}) do
            if type(t) ~= "string" and type(t) ~= "number" then ok = false end
        end
        if not ok then return nil, "tags must be a list of words" end
    end
    if out.metadata ~= nil and type(out.metadata) ~= "table" then return nil, "metadata must be an object" end
    return out
end

-- Standard column list returned by all read paths. Kept in one place so new
-- columns are surfaced everywhere automatically.
local RETURN_COLS = "id, scope, kind, title, body, tags, metadata, "
    .. "importance, decay_rate, was_truncated, created_at, updated_at, tier"
M.RETURN_COLS = RETURN_COLS

-- Derive initial tier from importance value (delegates to util).
local _importance_to_tier = util.importance_to_tier

local DEFAULT_EMBED_TIMEOUT_MS = 30000  -- fallback when embed_timeout_ms not set by M.setup()
local US_PER_DAY = 86400000000

-- Trim table `t` to at most `n` entries.  Returns a new table when trimming
-- is needed, or `t` itself when len(t) <= n (no copy).
local function _trim(t, n)
    if #t <= n then return t end
    local out = {}
    for i = 1, n do out[i] = t[i] end
    return out
end

-- Rows leave the store with readable timestamps and a boolean was_truncated.
local function _out(r)
    if type(r) ~= "table" then return r end
    util.iso_fields(r, { "created_at", "updated_at", "consolidated_at" })
    if r.was_truncated ~= nil and type(r.was_truncated) ~= "boolean" then
        r.was_truncated = (r.was_truncated == 1)
    end
    return r
end
local function _out_all(rows)
    for _, r in ipairs(rows or {}) do _out(r) end
    return rows
end
M._out = _out

-- A temporal bound (`since` / `until`) → integer µs. Accepts a number or a numeric
-- string (Unix epoch seconds) or ISO 8601 (YYYY-MM-DD or a full RFC 3339 timestamp).
local function _parse_time(v, name)
    if v == nil or v == "" then return nil, nil end
    if type(v) == "string" and v:match("^%d+%.?%d*$") then v = tonumber(v) end
    if type(v) == "number" then
        if v < 0 then return nil, name .. ": epoch must be non-negative" end
        return math.floor(v * 1000000), nil
    end
    if type(v) == "string" then
        if not v:match("^%d%d%d%d%-") then
            return nil, name .. ": expected ISO 8601 (YYYY-MM-DD or RFC3339), got " .. v
        end
        local us, err = util.iso_to_us(v)
        if not us then return nil, name .. ": " .. tostring(err) end
        return us, nil
    end
    return nil, name .. ": must be number (epoch) or ISO 8601 string, got " .. type(v)
end

-- Cosine similarity — delegates to util.cosine (shared with consolidate + digest).
local function _cosine(a, b) return util.cosine(a, b) end
M._cosine = _cosine    -- exposed for tests

-- ---------------------------------------------------------------------------
-- One embedding space per database: the first vector stored fixes its dimension
-- (lm_meta.embed_dim, read on every check — another process may have switched it);
-- a vector of another size is refused with the fix. Re-embedding (`switching`) may
-- write the new size: the database moves to it once no vector of the old size is
-- left (_finish_switch). Until then a vector of the other size scores 0 against a
-- query — those rows are still found by their words.
-- ---------------------------------------------------------------------------
local function _db_dim()
    return tonumber((db.value("SELECT value FROM lm_meta WHERE key = 'embed_dim'")))
end

local function _check_dim(vec, switching)
    if not vec then return true end
    local n = #vec
    local dim = _db_dim()
    if not dim then
        db.run("INSERT OR IGNORE INTO lm_meta (key, value) VALUES ('embed_dim', ?)", tostring(n))
        dim = _db_dim() or n
    end
    if dim ~= n and not switching then
        return nil, ("this database holds %d-dimension vectors and the embedder gave %d — use the "
            .. "database's embedder, or move the database to this one with `memo reembed --all`")
            :format(dim, n)
    end
    return true
end

-- After re-embedding: when every stored vector has the embedder's size `n`, the
-- database's dimension becomes n. → true when it moved
local function _finish_switch(n)
    n = tonumber(n)
    if not n or _db_dim() == n then return false end
    if db.value("SELECT 1 FROM lm_memories WHERE embedding IS NOT NULL AND length(embedding) != ? LIMIT 1",
            n * 4) then
        return false   -- vectors of another size remain (other scopes not re-embedded yet)
    end
    db.run("INSERT INTO lm_meta (key, value) VALUES ('embed_dim', ?) "
        .. "ON CONFLICT (key) DO UPDATE SET value = excluded.value", tostring(n))
    return true
end
--- The database moves to dimension n once no vector of another size is left
--- (after reembed, and after a dev's replica sync). → true when it moved
M.finish_switch = _finish_switch

local function _vec_params(vec)
    if not vec then return nil, nil end
    local blob, norm = vectors.pack(vec)
    return db.blob(blob), norm
end

-- Embed a row's text → vec, truncated | false, true, warning | nil, err.
-- `false`: the embedder rejected the text as too long even shortened (luamemo.embed):
-- the row is still stored — without a vector, searchable by its words — never lost.
local function _embed_row(text)
    local vec, err, truncated, why = embed.embed(text)
    if vec then return vec, truncated and true or false end
    if why == "too_long" then
        return false, true, "stored without a vector (found by its words only): " .. tostring(err)
    end
    return nil, err
end
M._embed_row = _embed_row

-- ---------------------------------------------------------------------------
-- _find_near_duplicate
-- The row in `scope` most similar to `vec` (exact scan) when its cosine is >=
-- `threshold`, plus that similarity — or nil. Only rows of the same band as the new one
-- (`raw`: tier 0, the hooks' raw conversation; else tier ≥ 1): a decision merged into a
-- tier-0 chunk stayed tier 0 — hidden from search, then purged by the digest — and a
-- chunk merged into a memory overwrote its text.
-- ---------------------------------------------------------------------------
local function _find_near_duplicate(scope, vec, threshold, raw)
    if not scope or not vec or not threshold then return nil end
    local q = vectors.query(vec)
    local best_id, best_sim = nil, -1
    local n, err = db.scan("SELECT id, embedding, emb_norm FROM " .. tbl()
        .. " WHERE scope = ? AND embedding IS NOT NULL AND " .. (raw and "tier = 0" or "tier >= 1"), { scope }, function(r)
        local p, bytes = r:blob_ptr(1)
        local s = vectors.cosine_ptr(p, bytes, r:double(2), q)
        if s > best_sim then best_sim, best_id = s, r:int(0) end
    end)
    if not n then return nil, err end
    if best_id and best_sim >= threshold then
        return M.get(best_id), best_sim
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
        local row = db.first("UPDATE " .. tbl() .. " SET updated_at = ? WHERE id = ? RETURNING " .. RETURN_COLS,
            util.now_us(), existing.id)
        return row and _out(row) or existing
    end
    return M.update(existing.id, patch)
end

local INSERT_SQL = "INSERT INTO " .. TBL .. " (scope, kind, title, body, tags, metadata, embedding, emb_norm, "
    .. "importance, decay_rate, was_truncated, tier, created_at, updated_at) "
    .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING " .. RETURN_COLS

-- A row's time: exact µs (`us`), else `at` — epoch seconds (a number or digits) or an
-- ISO 8601 time → µs | nil (none given) | false, err (unreadable — never silently "now").
local function _time_us(us, at)
    if tonumber(us) then
        us = math.floor(tonumber(us))
        if not util.us_in_range(us) then return false, "out of range (years 1000–9999): " .. us .. " µs" end
        return us
    end
    if at == nil then return nil end
    local v, err = util.iso_to_us(tonumber(at) or at)
    if not v then return false, err end
    return v
end

-- Insert one prepared row → row | nil, err   (p.created_us defaults to now, p.updated_us to created)
local function _insert(p, h)
    local blob, norm = _vec_params(p.vec)
    local c_us = p.created_us or util.now_us()
    return (h or db).first(INSERT_SQL, p.scope, p.kind, p.title, p.body, db.json(p.tags or {}),
        db.json(p.meta or {}), blob, norm, p.importance, p.decay_rate, p.truncated and 1 or 0,
        p.tier or 1, c_us, p.updated_us or c_us)
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
    local cerr
    args, cerr = _clean(args)
    if not args then return nil, "write: " .. cerr end
    local scope = args.scope or cfg.default_scope
    local kind  = args.kind or "fact"
    local title = scrub(args.title or "")   -- credential-looking strings → [redacted]
    local body  = scrub(args.body  or "")
    local tags  = scrub_all(args.tags  or {})
    local meta  = scrub_all(args.metadata or {})

    if title == "" and body == "" then
        return nil, "write: title or body required"
    end

    -- Federation gate before any embed cost. args._cap is an in-process
    -- capability (sync writer / directive ingest); callers can't forge it.
    local cap = args._cap
    local ok_ins, perr = policy.check_insert(scope, cap)
    if not ok_ins then return nil, "write: " .. perr end

    local importance, ierr = clamp_check("importance", args.importance, 0.0, 10.0)
    if ierr then return nil, ierr end
    if importance == nil then importance = cfg.default_importance or 1.0 end

    local decay_rate, derr = clamp_check("decay_rate", args.decay_rate, 0.0, 1.0)
    if derr then return nil, derr end
    if decay_rate == nil then decay_rate = cfg.default_decay_rate or 0.0 end

    -- A backdated write (memo write --created-at, memory_write created_at).
    local created_us, cterr = _time_us(nil, args.created_at)
    if created_us == false then return nil, "write: created_at: " .. tostring(cterr) end

    -- Tier: caller may override; otherwise derived from importance (a directive:
    -- the core tier). Protected org scopes cap at 2 unless this is directive ingest.
    local tier = args.tier
    if tier ~= nil then
        tier = math.max(0, math.min(3, math.floor(tonumber(tier) or 1)))
    else
        tier = policy.default_tier(scope, cap, _importance_to_tier(importance))
    end
    tier = policy.cap_tier(scope, tier, cap)

    local vec, truncated, warning = _embed_row(title .. "\n" .. body)
    if vec == nil then return nil, truncated end
    vec = vec or nil   -- false → no vector (too long); the row is kept
    local dok, dimerr = _check_dim(vec)
    if not dok then return nil, "write: " .. dimerr end

    -- Dedup pre-search. Per-call dedup_strategy="append" disables dedup
    -- without touching global config; useful for migration/import scripts.
    --
    -- Dedup and the retrieval-miss signal (learned-from-usage, opt-in via
    -- feedback_enabled) both need the nearest existing memory, so run ONE lookup
    -- at the lower of the two thresholds and classify by the returned similarity —
    -- never two searches. A near-duplicate write means retrieval failed to surface
    -- an existing memory (it got re-created): recording a 'miss' bumps that
    -- memory's importance (more findable next time) and feeds the ranker.
    -- A capability write (federation directive ingest) is a system write keyed
    -- by its source: never merged into another row, never a retrieval miss.
    local strategy     = args.dedup_strategy or cfg.dedup_strategy or "update"
    local dedup_active = cfg.dedup_enabled and strategy ~= "append" and not cap
    local miss_active  = cfg.feedback_enabled and not cap
    local dedup_thr    = cfg.dedup_threshold or 0.95
    local miss_thr     = cfg.miss_threshold or 0.90

    local existing
    if vec and (dedup_active or miss_active) then
        local low
        if dedup_active and miss_active then low = math.min(dedup_thr, miss_thr)
        elseif dedup_active then low = dedup_thr
        else low = miss_thr end

        local near, sim = _find_near_duplicate(scope, vec, low, tier == 0)
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
        -- Never merge into a row this caller may not change (an org directive on
        -- the central, a replica row on a dev): the existing row already covers it.
        if not policy.check_mutation(existing.scope or scope, existing.tier, cap) then
            return existing, nil, "skipped"
        end
        if strategy == "skip" then
            return existing, nil, "skipped"
        elseif strategy == "update" then
            local merged, merr = _merge_into(existing, args)
            if not merged then return nil, merr end
            return merged, nil, "merged"
        end
    end

    local row, qerr = _insert({ scope = scope, kind = kind, title = title, body = body, tags = tags, meta = meta,
        vec = vec, importance = importance, decay_rate = decay_rate, truncated = truncated, tier = tier,
        created_us = created_us })
    if not row then return nil, "write: db error: " .. tostring(qerr) end
    -- Preference extraction: create synthetic companion memories for
    -- preference / habit / sentiment signals in the body.
    -- Skipped for synthetic rows (avoids infinite recursion) and when disabled.
    -- Uses write_many() so multiple synthetics are embedded in one batch call.
    -- Capability writes (replica sync, directive ingest) mirror / define org
    -- content verbatim, so they never spawn synthetic companions. Nor does tier 0: raw
    -- conversation the hooks save for the digest — its assistant lines became tier-1
    -- "User has mentioned …" rows that every search returned.
    if cfg.patterns_enabled ~= false and not cap and tier > 0 then
        local is_syn = type(args.metadata) == "table" and args.metadata.is_synthetic
        if not is_syn then
            local syns = patterns.extract(args.body or "")
            if #syns > 0 then
                local syn_rows = {}
                for _, syn_body in ipairs(syns) do
                    syn_rows[#syn_rows + 1] = {
                        scope      = scope,
                        kind       = "fact",
                        title      = "Preference: " .. util.cut_utf8(syn_body, 60),
                        body       = syn_body,
                        importance = 0.4,
                        metadata   = { is_synthetic = true, source_id = row.id },
                    }
                end
                -- Best-effort: the real rows are already written.
                pcall(M.write_many, syn_rows, { dedup_strategy = "skip" })
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
    -- Never inside a caller's transaction: a digest may call the summarizer, and
    -- that would hold the database's write lock for the whole call.
    if cfg.auto_digest_enabled and not db.in_transaction() then
        pcall(function() digest.maybe_run(scope) end)
    end
    -- The same for summaries, every MEMO_SUMMARIZER_INTERVAL_SECONDS (0: on demand only).
    if (tonumber(cfg.summarizer_interval_seconds) or 0) > 0 and not db.in_transaction() then
        pcall(function() require("luamemo.summarizer").maybe_run(scope) end)
    end
    _out(row)
    row.warning = warning
    return row, nil, "inserted"
end

-- ---------------------------------------------------------------------------
-- write_many
-- Batched ingest: embed N rows (concurrently for HTTP embedders), then insert them
-- in transactions of `batch_size` rows. Skips dedup by default (set
-- opts.dedup_strategy = "update" or "skip" to opt back in).
--
-- Returns (results, err) where `results` is a list (parallel to `rows`) of
-- { row = <inserted row or nil>, action = "inserted"|"skipped"|"merged",
--   error = <string or nil> }. A single per-row failure does not abort the
-- batch — that row's slot carries `error` and `row = nil`, the rest succeed.
--
-- opts:
--   batch_size       — rows per insert transaction (default 100)
--   dedup_strategy   — "append" (default), "skip", or "update"
-- Per row, besides write()'s fields: created_at / updated_at (epoch seconds or ISO
-- 8601 — a backdated row; created_us / updated_us take exact µs), no_embed (FTS-only), and
-- for memo import a vector the row already has: embedding (+ was_truncated) — used
-- instead of calling the embedder.
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
    -- inserted with no vector (FTS-only). Used for rows whose retrieval is
    -- purely lexical (e.g. codebase file rows), to avoid paid embed calls.
    local prepared = {}
    local embed_queue = {}   -- { i, text, title, body, importance, decay_rate, args }
    local noembed_rows = {}  -- { i, title, body, importance, decay_rate, args }
    for i, raw in ipairs(rows_in) do
        local args, cerr
        if type(raw) == "table" then args, cerr = _clean(raw) end
        if type(raw) ~= "table" then
            results[i] = { row = nil, action = nil, error = "row must be a table" }
        elseif not args then
            results[i] = { row = nil, action = nil, error = cerr }
        else
            local title = scrub(args.title or "")
            local body  = scrub(args.body  or "")
            local ok_ins, perr = policy.check_insert(args.scope or cfg.default_scope, args._cap)
            if not ok_ins then
                results[i] = { row = nil, action = nil, error = perr }
            elseif title == "" and body == "" then
                results[i] = { row = nil, action = nil, error = "title or body required" }
            else
                local importance, ierr = clamp_check("importance", args.importance, 0.0, 10.0)
                if ierr then
                    results[i] = { row = nil, action = nil, error = ierr }
                else
                    if importance == nil then importance = cfg.default_importance or 1.0 end
                    local decay_rate, derr = clamp_check("decay_rate", args.decay_rate, 0.0, 1.0)
                    local c_us, cterr = _time_us(args.created_us, args.created_at)
                    local u_us, uterr = _time_us(args.updated_us, args.updated_at)
                    if derr then
                        results[i] = { row = nil, action = nil, error = derr }
                    elseif c_us == false or u_us == false then
                        results[i] = { row = nil, action = nil,
                            error = (c_us == false and "created_at: " or "updated_at: ") .. tostring(cterr or uterr) }
                    else
                        if decay_rate == nil then decay_rate = cfg.default_decay_rate or 0.0 end
                        local item = { i = i, title = title, body = body, importance = importance,
                            decay_rate = decay_rate, args = args }
                        if args.no_embed then
                            noembed_rows[#noembed_rows + 1] = item
                        else
                            item.text = title .. "\n" .. body
                            if type(args.embedding) == "table" and #args.embedding > 0 then
                                item.given = args.embedding
                            end
                            embed_queue[#embed_queue + 1] = item
                        end
                    end
                end
            end
        end
    end

    -- Phase A2: embed the queued rows that brought no vector of their own.
    -- With an HTTP embedder and more than one row, fan out concurrently via
    -- luamemo.async so total latency ≈ 1 × embed_latency.
    local vecs = {}   -- [j] = { vec = table, truncated = bool } for embed_queue[j]
    local pending = {}  -- indexes j of embed_queue still to embed
    for j, item in ipairs(embed_queue) do
        if item.given then
            vecs[j] = { vec = item.given, truncated = item.args.was_truncated == true }
        else
            pending[#pending + 1] = j
        end
    end
    if #pending > 1 then
        local async = require("luamemo.async")
        local tasks = {}
        for t, j in ipairs(pending) do
            local text = embed_queue[j].text
            tasks[t] = function()
                local vec, eerr, vtrunc, why = embed.embed_async(text, async.wait)
                return { vec = vec, err = eerr, truncated = vtrunc, why = why }
            end
        end
        local timeout_per = tonumber(cfg.embed_timeout_ms) or DEFAULT_EMBED_TIMEOUT_MS
        local async_results = async.run_all(tasks, timeout_per * #pending + 5000)
        for t, ar in ipairs(async_results) do
            local j = pending[t]
            local r = ar.result
            if ar.ok and r and r.vec then
                vecs[j] = { vec = r.vec, truncated = r.truncated }
            elseif ar.ok and r and r.why == "too_long" then
                -- kept without a vector (see _embed_row)
                embed_queue[j].warning = "stored without a vector (found by its words only): " .. tostring(r.err)
                noembed_rows[#noembed_rows + 1] = embed_queue[j]
            else
                local errmsg = (r and r.err) or (not ar.ok and tostring(ar.result)) or "embed failed"
                results[embed_queue[j].i] = { row = nil, action = nil, error = errmsg }
            end
        end
    else
        -- Sequential path: a single row.
        for _, j in ipairs(pending) do
            local item = embed_queue[j]
            local vec, vtrunc, warning = _embed_row(item.text)
            if vec then
                vecs[j] = { vec = vec, truncated = vtrunc }
            elseif vec == false then
                item.warning = warning
                noembed_rows[#noembed_rows + 1] = item
            else
                results[item.i] = { row = nil, action = nil, error = vtrunc }
            end
        end
    end
    for j, item in ipairs(embed_queue) do
        if vecs[j] then
            local dok, dimerr = _check_dim(vecs[j].vec)
            if not dok then
                results[item.i] = { row = nil, action = nil, error = dimerr }
                vecs[j] = nil
            end
        end
    end

    -- Phase A3: batch dedup + build prepared INSERT entries.
    --   1. Intra-batch dedup: compare all pairs within the embed_queue first so
    --      rows that duplicate each other within the same batch are handled correctly
    --      (DB candidates won't include rows being inserted in this very call).
    --   2. Group embedded rows by scope (usually 1 scope, sometimes a few).
    --   3. Issue ONE candidate fetch per distinct scope from the DB.
    --   4. Run cosine comparisons in Lua memory — no extra DB round-trips.
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
                            if strategy == "skip" then
                                results[i_k] = { action = "skipped", batch_of = i_j }   -- (resolved after Phase B)
                                vecs[k] = nil
                            elseif strategy == "update" then
                                -- Merge k into j: k's text appended to j's, k's tags / metadata
                                -- replacing j's — on j's item (the row is inserted from it) and
                                -- on a copy of j's args (a match in the database merges those).
                                -- The text was lost (only the caller's args got it), the
                                -- caller's table was changed, and a j without a body crashed.
                                local item_j, a_k = embed_queue[j], embed_queue[k].args
                                local a_j = {}
                                for key, v in pairs(item_j.args) do a_j[key] = v end
                                local kb = embed_queue[k].body
                                if kb ~= "" then
                                    a_j.body = (a_j.body and a_j.body ~= "") and (a_j.body .. "\n" .. a_k.body) or a_k.body
                                    item_j.body = item_j.body ~= "" and (item_j.body .. "\n" .. kb) or kb
                                end
                                if a_k.tags     then a_j.tags     = a_k.tags     end
                                if a_k.metadata then a_j.metadata = a_k.metadata end
                                item_j.args = a_j
                                results[i_k] = { action = "merged", batch_of = i_j }   -- (resolved after Phase B)
                                vecs[k] = nil
                            end
                        end
                    end
                end
            end
        end
    end

    -- 2+3. Group by scope; one candidate fetch per distinct scope.
    local scope_candidates = {}  -- [scope_str] = array of { row, vec }
    if dedup_active then
        local scopes_needed = {}
        for j, item in ipairs(embed_queue) do
            if vecs[j] and not results[item.i] then
                scopes_needed[item.args.scope or cfg.default_scope] = true
            end
        end
        local cap = tonumber(cfg.dedup_candidate_limit) or 1000
        for sc in pairs(scopes_needed) do
            local rows = db.query("SELECT " .. RETURN_COLS .. ", embedding, emb_norm FROM " .. tbl()
                .. " WHERE scope = ? AND embedding IS NOT NULL ORDER BY updated_at DESC LIMIT ?", sc, cap)
            local cands = {}
            -- The stored float32 vector and its norm, scored in place (vectors.cosine_ptr) as
            -- a single write's dedup does — not unpacked into a Lua table per candidate.
            for _, row in ipairs(rows or {}) do
                local blob, norm = row.embedding, tonumber(row.emb_norm)
                row.embedding, row.emb_norm = nil, nil
                cands[#cands + 1] = { row = _out(row), blob = blob, norm = norm }
            end
            scope_candidates[sc] = cands
        end
    end

    -- 4. Per-row dedup against in-memory candidates + build prepared entries.
    local function tier_for(args_i, importance)
        local p_tier = args_i.tier
        if p_tier ~= nil then
            p_tier = math.max(0, math.min(3, math.floor(tonumber(p_tier) or 1)))
        else
            p_tier = policy.default_tier(args_i.scope or cfg.default_scope, args_i._cap,
                _importance_to_tier(importance))
        end
        return policy.cap_tier(args_i.scope or cfg.default_scope, p_tier, args_i._cap)
    end
    -- A backdated row: created_us / updated_us (exact µs) or created_at / updated_at
    -- (epoch seconds or ISO 8601; checked in phase A1) → µs | nil (now)
    local function us_of(us, at) return _time_us(us, at) or nil end

    for j, item in ipairs(embed_queue) do
        local slot = vecs[j]
        if slot then
            local i, args_i = item.i, item.args
            if dedup_active and not results[i] then
                local sc = args_i.scope or cfg.default_scope
                local best_row, best_sim = nil, -1
                local q = vectors.query(slot.vec)
                local raw = tier_for(args_i, item.importance) == 0   -- same band only (see write())
                for _, c in ipairs(scope_candidates[sc] or {}) do
                    if type(c.blob) == "string" and ((tonumber(c.row.tier) or 1) == 0) == raw then
                        local sim = vectors.cosine_ptr(c.blob, #c.blob, c.norm, q)
                        if sim > best_sim then best_sim = sim; best_row = c.row end
                    end
                end
                if best_row and best_sim >= threshold then
                    -- Never merge into a row this caller may not change (see write()).
                    if not policy.check_mutation(best_row.scope or sc, best_row.tier, args_i._cap) then
                        results[i] = { row = best_row, action = "skipped" }
                    elseif strategy == "skip" then
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
                prepared[i] = {
                    scope      = args_i.scope or cfg.default_scope,
                    kind       = args_i.kind or "fact",
                    title      = item.title,
                    body       = item.body,
                    tags       = scrub_all(args_i.tags or {}),
                    meta       = scrub_all(args_i.metadata or {}),
                    vec        = slot.vec,
                    importance = item.importance,
                    decay_rate = item.decay_rate,
                    truncated  = slot.truncated and true or false,
                    tier       = tier_for(args_i, item.importance),
                    created_us = us_of(args_i.created_us, args_i.created_at),
                    updated_us = us_of(args_i.updated_us, args_i.updated_at),
                }
            end
        end
    end

    -- no_embed rows (and rows too long for the embedder): insert with no vector, no dedup.
    for _, item in ipairs(noembed_rows) do
        local i, args_i = item.i, item.args
        prepared[i] = {
            scope      = args_i.scope or cfg.default_scope,
            kind       = args_i.kind or "fact",
            title      = item.title,
            body       = item.body,
            tags       = scrub_all(args_i.tags or {}),
            meta       = scrub_all(args_i.metadata or {}),
            vec        = nil,
            importance = item.importance,
            decay_rate = item.decay_rate,
            truncated  = item.warning ~= nil or args_i.was_truncated == true,
            tier       = tier_for(args_i, item.importance),
            created_us = us_of(args_i.created_us, args_i.created_at),
            updated_us = us_of(args_i.updated_us, args_i.updated_at),
            warning    = item.warning,
        }
    end

    -- Phase B: insert in transactions of batch_size rows (all of a chunk or none).
    local indices = {}
    for i = 1, #rows_in do
        if prepared[i] then indices[#indices + 1] = i end
    end
    local pos = 1
    while pos <= #indices do
        local last = math.min(pos + batch_size - 1, #indices)
        local inserted = {}
        local ok, terr = db.transaction(function(h)
            for jj = pos, last do
                local row, ierr = _insert(prepared[indices[jj]], h)
                if not row then error(ierr, 0) end
                inserted[jj] = row
            end
        end)
        for jj = pos, last do
            if ok then
                local row = _out(inserted[jj])
                row.warning = prepared[indices[jj]].warning
                results[indices[jj]] = { row = row, action = "inserted" }
            else
                results[indices[jj]] = { row = nil, action = nil, error = "write_many: db error: " .. tostring(terr) }
            end
        end
        pos = last + 1
    end

    -- A duplicate within the batch is answered with the row it went into (merged_into:
    -- that item) — it was a failure ("merged into batch item N", no row), so an agent
    -- sent it again; a duplicate of a stored memory was already a success.
    for i, r in pairs(results) do
        if r.batch_of then
            local into = results[r.batch_of]
            results[i] = (into and into.row) and { row = into.row, action = r.action, merged_into = r.batch_of }
                or { error = ("batch item %d, which it went into, failed"):format(r.batch_of) }
        end
    end

    -- Notify consolidation engine for each scope touched by this batch.
    local seen_scopes = {}
    for _, r in pairs(results) do
        if r.row and r.row.scope and not seen_scopes[r.row.scope] then
            seen_scopes[r.row.scope] = true
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
    id = tonumber(id)
    if not id then return nil end
    local row = db.first("SELECT " .. RETURN_COLS .. " FROM " .. tbl() .. " WHERE id = ?", id)
    return row and _out(row) or nil
end

-- What was derived from these memories goes with them (a delete, new text) — both went on
-- reaching agents after the memory was deleted or rewritten:
--   · the "Preference: …" companions written from their text (luamemo.patterns:
--     metadata.is_synthetic + source_id; lm_memories_synthetic_idx finds them);
--   · the observations distilled from them (luamemo.consolidate): an observation's text
--     may be a memory's own (the default summarizer keeps a member's body). The rest of
--     its evidence keeps its memories.
-- scope: where to look (nil: every scope).
local function _forget_derived(ids, scope)
    if #ids == 0 then return end
    local function q(sql, ...)   -- sql with an optional "scope = ? AND " at %s → sql, params…
        if scope then return sql:format("scope = ? AND "), scope, ... end
        return sql:format(""), ...
    end
    local in_ids, ids_json = db.in_list(ids)
    local all = {}
    for _, id in ipairs(ids) do all[#all + 1] = id end
    local syn = db.query(q("SELECT id FROM " .. tbl() .. " WHERE %sjson_extract(metadata, '$.is_synthetic') = 1 "
        .. "AND json_extract(metadata, '$.source_id') IN " .. in_ids, ids_json)) or {}
    if #syn > 0 then
        for _, r in ipairs(syn) do all[#all + 1] = r.id end
        local syn_in, syn_json = db.in_list({ unpack(all, #ids + 1) })
        db.run("DELETE FROM " .. tbl() .. " WHERE id IN " .. syn_in, syn_json)
        in_ids, ids_json = db.in_list(all)
    end
    if not db.value(q("SELECT 1 FROM lm_observations WHERE %s1 = 1 LIMIT 1")) then
        return   -- (none here: a code map's per-file replace pays index probes only)
    end
    db.run(q("DELETE FROM lm_observations WHERE id IN (SELECT o.id FROM lm_observations o, json_each(o.evidence_ids) e "
        .. "WHERE %sCAST(e.value AS INTEGER) IN " .. in_ids .. ")", ids_json))
end

-- ---------------------------------------------------------------------------
-- update (re-embeds if title or body changed)
-- ---------------------------------------------------------------------------
function M.update(id, patch)
    id = tonumber(id)
    if not id then return nil, "update: invalid id" end
    local cerr
    patch, cerr = _clean(patch or {})
    if not patch then return nil, "update: " .. cerr end
    -- An empty scope or kind changes nothing (scope "" moved the memory where only its id found it).
    if patch.scope == "" then patch.scope = nil end
    if patch.kind == "" then patch.kind = nil end
    local existing = M.get(id)
    if not existing then return nil, "update: not found" end
    local new_title, new_body = scrub(patch.title), scrub(patch.body)
    -- New text (not a re-embed of the same): what was distilled from the old goes, and the
    -- memory is consolidated again.
    local rewritten = not patch._reembed and ((new_title and new_title ~= existing.title)
        or (new_body and new_body ~= existing.body))

    -- Federation: the row itself must be mutable by this caller, and a move
    -- (patch.scope) must be allowed into the destination — never carrying tier 3
    -- into a protected org scope without the directive capability.
    local ok_m, merr = policy.check_mutation(existing.scope, existing.tier, patch._cap)
    if not ok_m then return nil, "update: " .. merr end
    local moved_tier
    if patch.scope and patch.scope ~= existing.scope then
        local ok_i, ierr = policy.check_insert(patch.scope, patch._cap)
        if not ok_i then return nil, "update: " .. ierr end
        local capped = policy.cap_tier(patch.scope, tonumber(existing.tier) or 1, patch._cap)
        if capped ~= (tonumber(existing.tier) or 1) then moved_tier = capped end
    end

    -- (counted: a nil value — no vector for a too-long text — binds as NULL; `#params`
    -- skipped it and shifted every later parameter, the id to NULL: no row updated)
    local sets, params, np = {}, {}, 0
    local function set(col, val)
        sets[#sets + 1] = col .. " = ?"
        np = np + 1
        params[np] = val
    end
    if patch.scope then set("scope", patch.scope) end
    if moved_tier then set("tier", math.floor(moved_tier)) end
    if patch.kind  then set("kind",  patch.kind)  end
    if new_title then set("title", new_title) end
    if new_body  then set("body",  new_body)  end
    if patch.tags     then set("tags", db.json(scrub_all(patch.tags))) end
    if patch.metadata then set("metadata", db.json(scrub_all(patch.metadata))) end
    if patch.importance ~= nil then
        local imp, ierr = clamp_check("importance", patch.importance, 0.0, 10.0)
        if ierr then return nil, ierr end
        set("importance", imp)
    end
    if patch.decay_rate ~= nil then
        local dr, derr = clamp_check("decay_rate", patch.decay_rate, 0.0, 1.0)
        if derr then return nil, derr end
        set("decay_rate", dr)
    end

    -- Re-embed when text changed.
    local warning
    if new_title or new_body then
        local title = new_title or existing.title
        local body  = new_body  or existing.body
        local vec, vtrunc
        vec, vtrunc, warning = _embed_row(title .. "\n" .. body)
        if vec == nil then return nil, vtrunc end
        vec = vec or nil   -- false → no vector (too long); the new text is kept
        local dok, dimerr = _check_dim(vec, patch._reembed)   -- re-embedding may switch the size
        if not dok then return nil, "update: " .. dimerr end
        local blob, norm = _vec_params(vec)
        set("embedding", blob)
        set("emb_norm", norm)
        set("was_truncated", vtrunc and 1 or 0)
    end
    if rewritten then set("consolidated_at", nil) end

    if #sets == 0 then return existing end
    set("updated_at", util.now_us())

    np = np + 1
    params[np] = id
    local row, err = db.first("UPDATE " .. tbl() .. " SET " .. table.concat(sets, ", ")
        .. " WHERE id = ? RETURNING " .. RETURN_COLS, unpack(params, 1, np))
    if not row then return nil, "update: db error: " .. tostring(err) end
    if rewritten then
        _forget_derived({ id }, existing.scope)
        consolidate.notify(row.scope)
    end
    _out(row)
    row.warning = warning
    return row
end

-- ---------------------------------------------------------------------------
-- _build_metadata_conds  (shared by search and delete_where)
-- Returns { sql fragments }, { their parameters } — or nil.
-- ---------------------------------------------------------------------------
local function _build_metadata_conds(metadata_filter, prefix)
    if not metadata_filter then return end
    prefix = prefix or ""
    local out, params = {}, {}
    -- Org project filter (search `project`): narrows ONLY org: scopes to that
    -- project's memories plus org-wide ones (no project tag); other scopes in a
    -- multi-scope search are untouched.
    local proj = metadata_filter.__org_project
    if type(proj) == "string" and proj ~= "" then
        out[#out + 1] = ("(%sscope NOT GLOB 'org:*' OR json_extract(%smetadata, '$.project') IS NULL "
            .. "OR json_extract(%smetadata, '$.project') = ?)"):format(prefix, prefix, prefix)
        params[#params + 1] = proj
    end
    for k, v in pairs(metadata_filter) do
        -- Plain keys (they become a JSON path); text / number values compared as text,
        -- true / false as JSON booleans. Anything else is refused (check_metadata_filter).
        if k ~= "__org_project" and type(k) == "string" and k:match("^[%a_][%w_]*$") then
            if type(v) == "string" and not tonumber(v) then
                -- Text that isn't a number matches the same rows compared directly — in a
                -- form an index on the path can answer (lm_memories_path_idx: the key is
                -- written into the SQL, safe as a plain name; a bound path matches no index).
                out[#out + 1] = ("json_extract(%smetadata, '$.%s') = ?"):format(prefix, k)
                params[#params + 1] = v
            elseif type(v) == "string" or type(v) == "number" then
                out[#out + 1] = ("CAST(json_extract(%smetadata, ?) AS TEXT) = ?"):format(prefix)
                params[#params + 1] = "$." .. k
                params[#params + 1] = tostring(v)
            elseif type(v) == "boolean" then
                out[#out + 1] = ("json_type(%smetadata, ?) = '%s'"):format(prefix, v and "true" or "false")
                params[#params + 1] = "$." .. k
            end
        end
    end
    return out, params
end

--- nil when `mf` is a metadata filter luamemo can apply — an object of plain keys
--- (letters, digits, _) with text, number or true / false values — else why not. A
--- filter entry is never skipped silently: a bulk delete would match more than asked.
function M.check_metadata_filter(mf)
    if mf == nil then return nil end
    if type(mf) ~= "table" or mf[1] ~= nil then return "metadata filter: a JSON object, e.g. {\"source\": \"x\"}" end
    for k, v in pairs(mf) do
        if k ~= "__org_project" then
            if type(k) ~= "string" or not k:match("^[%a_][%w_]*$") then
                return ("metadata filter: %q — keys are plain names (letters, digits, _)"):format(tostring(k))
            end
            local t = type(v)
            if t ~= "string" and t ~= "number" and t ~= "boolean" then
                return ("metadata filter: %s — values are text, numbers or true / false"):format(k)
            end
        end
    end
    return nil
end

local function push_all(dst, src) for _, v in ipairs(src or {}) do dst[#dst + 1] = v end end

-- ---------------------------------------------------------------------------
-- delete
-- ---------------------------------------------------------------------------
function M.delete(id, opts)
    id = tonumber(id)
    if not id then return nil, "delete: invalid id" end
    local row = db.first("SELECT scope, tier FROM " .. tbl() .. " WHERE id = ?", id)
    if row and policy.active() then
        local ok_m, merr = policy.check_mutation(row.scope, row.tier, opts and opts._cap)
        if not ok_m then return nil, "delete: " .. merr end
    end
    local n, err = db.run("DELETE FROM " .. tbl() .. " WHERE id = ?", id)
    if not n then return nil, "delete: " .. tostring(err) end
    if row and n > 0 then _forget_derived({ id }, row.scope) end
    return { affected_rows = n }
end

-- ---------------------------------------------------------------------------
-- delete_where  — bulk delete by scope/kind/metadata_filter
-- args: { scope?, kind?, metadata_filter? }
-- Returns: total count of deleted rows, or nil, err on failure.
-- match_where(args, n) — what delete_where(args) would delete: { count, titles }.
-- ---------------------------------------------------------------------------

-- The WHERE clause of a bulk operation by filter → where, params | nil, err.
local function _bulk_where(args, who)
    local merr = M.check_metadata_filter(args.metadata_filter)
    if merr then return nil, who .. ": " .. merr end
    local conds, params = {}, {}
    if args.scope then conds[#conds + 1] = "scope = ?"; params[#params + 1] = args.scope end
    if args.kind  then conds[#conds + 1] = "kind = ?";  params[#params + 1] = args.kind end
    local mc, mp = _build_metadata_conds(args.metadata_filter)
    push_all(conds, mc); push_all(params, mp)

    if #conds == 0 then return nil, who .. ": at least one filter required" end

    -- Federation: a replica scope can't be bulk-deleted (explicit error), and
    -- rows the role must not touch (replicas / org directives) are excluded
    -- from any other filter. The directive/replica capability lifts both.
    if args.scope then
        local ok_m, perr = policy.check_mutation(args.scope, nil, args._cap)
        if not ok_m then return nil, who .. ": " .. perr end
    end
    local excl = policy.maintenance_exclusion_sql(args._cap)
    if excl then conds[#conds + 1] = excl end
    return " WHERE " .. table.concat(conds, " AND "), params
end
M._bulk_where = _bulk_where   -- (tests: the query plan of a bulk filter)

function M.match_where(args, n)
    local where, params = _bulk_where(args or {}, "match_where")
    if not where then return nil, params end
    local count, cerr = db.value("SELECT count(*) FROM " .. tbl() .. where, unpack(params, 1, #params))
    if not count then return nil, "match_where: " .. tostring(cerr) end
    local p2 = { unpack(params, 1, #params) }
    p2[#p2 + 1] = math.max(0, tonumber(n) or 5)
    local rows = db.query("SELECT id, title FROM " .. tbl() .. where .. " ORDER BY updated_at DESC, id DESC LIMIT ?",
        unpack(p2, 1, #p2)) or {}
    local titles = {}
    for i, r in ipairs(rows) do titles[i] = r.title end
    return { count = tonumber(count) or 0, titles = titles }
end

function M.delete_where(args)
    args = args or {}
    local where, params = _bulk_where(args, "delete_where")
    if not where then return nil, params end
    local total = 0
    while true do
        local rows, qerr = db.query("SELECT id FROM " .. tbl() .. where .. " LIMIT 500", unpack(params, 1, #params))
        if not rows then return nil, "delete_where: " .. tostring(qerr) end
        if #rows == 0 then break end
        local ids = {}
        for _, r in ipairs(rows) do ids[#ids + 1] = r.id end
        local dn, derr = db.run("DELETE FROM " .. tbl() .. " WHERE id IN (" .. db.placeholders(#ids) .. ")",
            unpack(ids, 1, #ids))
        if not dn then return nil, "delete_where: " .. tostring(derr) end
        _forget_derived(ids, args.scope)
        total = total + #rows
        if #rows < 500 then break end
    end
    return total
end

-- ---------------------------------------------------------------------------
-- Federation replica API (dev role). The ONLY way a replica row changes — the
-- sync writer (luamemo.federation.client) holds the replica capability. Rows
-- are keyed by the central id in metadata.lm_org_id (unique index
-- lm_memories_org_replica_uq → atomic upsert), and carry the central's
-- updated_at as metadata.lm_org_updated_us for manifest reconciliation.
-- ---------------------------------------------------------------------------

--- { [central_id] = { id = local_id, us = central_updated_us } } for a replica scope.
function M.replica_index(scope)
    local rows = db.query("SELECT id, json_extract(metadata, '$.lm_org_id') AS org_id, "
        .. "json_extract(metadata, '$.lm_org_updated_us') AS us FROM " .. tbl()
        .. " WHERE scope = ? AND json_extract(metadata, '$.lm_org_id') IS NOT NULL", scope)
    local idx = {}
    for _, r in ipairs(rows or {}) do
        local oid = tonumber(r.org_id)
        if oid then idx[oid] = { id = tonumber(r.id), us = tonumber(r.us) } end
    end
    return idx
end

--- Insert or update one replica row from a central snapshot item.
--- item: { id, kind, title, body, tags, metadata, importance, decay_rate, tier,
---         created_us, updated_us }; vec: the central's vector when the embedding
--- spaces match, else nil → embedded here. opts.force rewrites an unchanged row.
--- opts.known: the caller's replica_index entry for this central id ({ id, us },
--- or false = not in the replica) — saves the per-row lookup during a pull.
--- Returns local_id, "inserted"|"updated"|"unchanged" — or nil, err.
function M.replica_upsert(scope, item, vec, cap, opts)
    opts = opts or {}
    if not policy.replica(scope) then
        return nil, "replica_upsert: " .. tostring(scope) .. " is not a replica scope on this instance"
    end
    local ok_i, ierr = policy.check_insert(scope, cap)
    if not ok_i then return nil, "replica_upsert: " .. ierr end
    local org_id = tonumber(item and item.id)
    if not org_id or org_id <= 0 or org_id ~= math.floor(org_id) then
        return nil, "replica_upsert: item.id (central id) required"
    end
    local key = ("%d"):format(org_id)
    local us  = math.floor(tonumber(item.updated_us) or 0)
    local existing
    if type(opts.known) == "table" then
        existing = opts.known
    elseif opts.known == nil then
        existing = db.first("SELECT id, json_extract(metadata, '$.lm_org_updated_us') AS us FROM " .. tbl()
            .. " WHERE scope = ? AND json_extract(metadata, '$.lm_org_id') = ? LIMIT 1", scope, key)
    end
    if existing and tonumber(existing.us) == us and not opts.force then
        return tonumber(existing.id), "unchanged"
    end

    -- Untrusted wire data: JSON null decodes to a sentinel table, so coerce.
    local function str(v, dflt) return type(v) == "string" and v or dflt end
    local title, body = str(item.title, ""), str(item.body, "")
    local truncated = false
    if vec and cfg.embed_dim and #vec ~= tonumber(cfg.embed_dim) then vec = nil end
    if not vec then
        local v, vtrunc = _embed_row(title .. "\n" .. body)
        if v == nil then return nil, "replica_upsert: embed failed: " .. tostring(vtrunc) end
        vec, truncated = v or nil, vtrunc   -- v == false: too long, kept text-only
    end
    -- The replica follows the configured embedder even while the database still
    -- holds vectors of another size: its rows can only change through sync, so a
    -- refusal here would leave a dimension change stuck for good (the database
    -- moves once the other scopes are re-embedded — finish_switch).
    local dok, dimerr = _check_dim(vec, true)
    if not dok then return nil, "replica_upsert: " .. dimerr end

    local meta = {}
    for k, v in pairs(type(item.metadata) == "table" and item.metadata or {}) do meta[k] = v end
    meta.lm_org_id, meta.lm_org_updated_us = key, ("%d"):format(us)
    local tier = math.max(0, math.min(3, math.floor(tonumber(item.tier) or 1)))
    local imp  = math.max(0.0, math.min(10.0, tonumber(item.importance) or 1.0))
    local dr   = math.max(0.0, math.min(1.0, tonumber(item.decay_rate) or 0.0))
    local c_us = math.floor(tonumber(item.created_us) or us)
    local blob, norm = _vec_params(vec)
    local row, qerr = db.first("INSERT INTO " .. tbl() .. " (scope, kind, title, body, tags, metadata, "
        .. "embedding, emb_norm, importance, decay_rate, was_truncated, tier, created_at, updated_at) "
        .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
        .. "ON CONFLICT (scope, json_extract(metadata, '$.lm_org_id')) "
        .. "WHERE json_extract(metadata, '$.lm_org_id') IS NOT NULL "
        .. "DO UPDATE SET kind = excluded.kind, title = excluded.title, body = excluded.body, "
        .. "tags = excluded.tags, metadata = excluded.metadata, embedding = excluded.embedding, "
        .. "emb_norm = excluded.emb_norm, importance = excluded.importance, decay_rate = excluded.decay_rate, "
        .. "was_truncated = excluded.was_truncated, tier = excluded.tier, created_at = excluded.created_at, "
        .. "updated_at = excluded.updated_at RETURNING id",
        scope, str(item.kind, "fact"), title, body, db.json(type(item.tags) == "table" and item.tags or {}),
        db.json(meta), blob, norm, imp, dr, truncated and 1 or 0, tier, c_us, us)
    if not row then return nil, "replica_upsert: db error: " .. tostring(qerr) end
    return tonumber(row.id), existing and "updated" or "inserted"
end

--- Delete replica rows (local ids) that left the org. Replica capability only.
function M.replica_delete(scope, local_ids, cap)
    if not policy.replica(scope) then
        return nil, "replica_delete: " .. tostring(scope) .. " is not a replica scope on this instance"
    end
    local ok_m, merr = policy.check_mutation(scope, nil, cap)
    if not ok_m then return nil, "replica_delete: " .. merr end
    local ids = {}
    for _, v in ipairs(local_ids or {}) do
        local n = tonumber(v)
        if n then ids[#ids + 1] = math.floor(n) end
    end
    if #ids == 0 then return 0 end
    local in_ids, ids_json = db.in_list(ids)   -- forget / reconcile: a whole replica
    local n, qerr = db.run("DELETE FROM " .. tbl() .. " WHERE scope = ? AND json_extract(metadata, "
        .. "'$.lm_org_id') IS NOT NULL AND id IN " .. in_ids, scope, ids_json)
    if not n then return nil, "replica_delete: " .. tostring(qerr) end
    return n
end

-- SQL weight of a row at time ? (µs): importance × exp(−decay_rate × age in days).
local WEIGHT_SQL = "(importance * exp(-decay_rate * ((? - updated_at) / 86400000000.0)))"

-- ---------------------------------------------------------------------------
-- select_for_summarization
-- Returns a list of {scope, memories[]} batches. A memory qualifies when:
--   * weight (importance * exp(-decay_rate * days_since_updated))
--     is below `weight_threshold` (default 0.5), AND
--   * updated_at is older than `retention_days` (default 30)
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
    local now = util.now_us()

    local conds = { "kind != 'summary'", "updated_at < ?", WEIGHT_SQL .. " < ?" }
    local params = { now - retention_days * US_PER_DAY, now, weight_threshold }
    if opts.scope then conds[#conds + 1] = "scope = ?"; params[#params + 1] = opts.scope end
    -- Federation: never fold replicas (dev) or directives (org) into summaries.
    local excl = policy.maintenance_exclusion_sql()
    if excl then conds[#conds + 1] = excl end
    params[#params + 1] = batch_size * max_batches

    local rows = db.query("SELECT " .. RETURN_COLS .. " FROM " .. tbl() .. " WHERE " .. table.concat(conds, " AND ")
        .. " ORDER BY scope, updated_at ASC LIMIT ?", unpack(params, 1, #params)) or {}
    _out_all(rows)

    -- Group by scope, then chunk each scope into batch_size pieces.
    local by_scope, order = {}, {}
    for _, r in ipairs(rows) do
        if not by_scope[r.scope] then by_scope[r.scope] = {}; order[#order + 1] = r.scope end
        table.insert(by_scope[r.scope], r)
    end
    local batches = {}
    for _, s in ipairs(order) do
        local list = by_scope[s]
        for i = 1, #list, batch_size do
            if #batches >= max_batches then break end
            local chunk = {}
            for j = i, math.min(i + batch_size - 1, #list) do chunk[#chunk + 1] = list[j] end
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
    local clean = {}
    for _, v in ipairs(ids) do
        local n = tonumber(v)
        if n then clean[#clean + 1] = math.floor(n) end
    end
    if #clean == 0 then return nil, "replace_with_summary: no valid ids" end

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

    local row
    local ok, err = db.transaction(function(h)
        local r, werr = M.write(insert_args)
        if not r then error("insert failed: " .. tostring(werr), 0) end
        row = r
        -- Folded rows the role must not touch (replicas / org directives) stay put.
        local excl = policy.maintenance_exclusion_sql(summary_args._cap)
        local dn, derr = h.run("DELETE FROM " .. tbl() .. " WHERE id IN (" .. db.placeholders(#clean) .. ")"
            .. (excl and (" AND " .. excl) or ""), unpack(clean, 1, #clean))
        if not dn then error("delete failed: " .. tostring(derr), 0) end
    end)
    if not ok then return nil, "replace_with_summary: " .. tostring(err) end
    return row
end

-- ---------------------------------------------------------------------------
-- recent
-- ---------------------------------------------------------------------------
function M.recent(args)
    args = args or {}
    local limit  = math.min(tonumber(args.limit) or 20, 200)
    local offset = math.max(tonumber(args.offset) or 0, 0)
    local conds, params = {}, {}
    if args.scope then conds[#conds + 1] = "scope = ?"; params[#params + 1] = args.scope end
    if args.kind then conds[#conds + 1] = "kind = ?"; params[#params + 1] = args.kind end
    if tonumber(args.tier_min) then conds[#conds + 1] = "tier >= ?"; params[#params + 1] = tonumber(args.tier_min) end
    local where = #conds > 0 and (" WHERE " .. table.concat(conds, " AND ")) or ""
    params[#params + 1] = limit
    params[#params + 1] = offset
    return _out_all(db.query("SELECT " .. RETURN_COLS .. " FROM " .. tbl() .. where
        .. " ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?", unpack(params, 1, #params)) or {})
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

    local conds = { "decay_rate > 0", "importance > 0", WEIGHT_SQL .. " < ?" }
    local params = { util.now_us(), threshold }
    if opts.scope then conds[#conds + 1] = "scope = ?"; params[#params + 1] = opts.scope end
    -- Federation: decay never touches replicas (dev) or directives (org).
    local excl = policy.maintenance_exclusion_sql()
    if excl then conds[#conds + 1] = excl end
    params[#params + 1] = max_rows

    local rows, qerr = db.query("SELECT id FROM " .. tbl() .. " WHERE " .. table.concat(conds, " AND ")
        .. " ORDER BY updated_at ASC LIMIT ?", unpack(params, 1, #params))
    if not rows then return nil, "find_decayed: db error: " .. tostring(qerr) end

    local ids = {}
    for _, r in ipairs(rows) do ids[#ids + 1] = r.id end
    if apply and #ids > 0 then
        local un, uerr = db.run("UPDATE " .. tbl() .. " SET importance = 0 WHERE id IN ("
            .. db.placeholders(#ids) .. ")", unpack(ids, 1, #ids))
        if not un then return nil, "find_decayed: update failed: " .. tostring(uerr) end
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
-- Returns (clusters, err) where each cluster is:
--   { ids={...}, titles={...}, members=[{row without embedding}] }
-- ---------------------------------------------------------------------------
function M.find_clusters(opts)
    opts = opts or {}
    local threshold = tonumber(opts.similarity_threshold) or 0.85
    local max_rows  = math.min(tonumber(opts.max_rows) or 500, 5000)

    local conds, params = { "importance > 0" }, {}
    if opts.scope then conds[#conds + 1] = "scope = ?"; params[#params + 1] = opts.scope end
    params[#params + 1] = max_rows
    local rows, qerr = db.query("SELECT " .. RETURN_COLS .. ", embedding FROM " .. tbl() .. " WHERE "
        .. table.concat(conds, " AND ") .. " ORDER BY importance DESC, updated_at DESC LIMIT ?",
        unpack(params, 1, #params))
    if not rows then return nil, "find_clusters: db error: " .. tostring(qerr) end
    if #rows == 0 then return {}, nil end
    for _, r in ipairs(rows) do r.embedding = vectors.unpack(r.embedding); _out(r) end

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
    for i = 1, #rows do
        for j = i + 1, #rows do
            if _cosine(rows[i].embedding, rows[j].embedding) >= threshold then
                local ri, rj = find(i), find(j)
                if ri ~= rj then parent[ri] = rj end
            end
        end
    end

    local groups = {}
    for i = 1, #rows do
        local root = find(i)
        groups[root] = groups[root] or {}
        table.insert(groups[root], i)
    end
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
-- include_summaries=true to override. opts.tier_min: only rows of that tier or above.
-- ---------------------------------------------------------------------------
function M.list_by_scope(scope, opts)
    if not scope or scope == "" then
        return nil, "list_by_scope: scope required"
    end
    opts = opts or {}
    local limit = math.min(tonumber(opts.limit) or 200, 1000)
    local extra = (opts.include_summaries and "" or " AND kind != 'summary'")
        .. (tonumber(opts.tier_min) and (" AND tier >= " .. math.floor(tonumber(opts.tier_min))) or "")
    return _out_all(db.query("SELECT " .. RETURN_COLS .. " FROM " .. tbl() .. " WHERE scope = ?" .. extra
        .. " ORDER BY created_at ASC, id ASC LIMIT ?", scope, limit) or {})
end

-- ---------------------------------------------------------------------------
-- reembed_scope
--
-- Re-embeds every memory in a scope with the CURRENTLY configured embedder.
-- Needed after switching embedders: two different models' vector spaces are
-- never comparable, even at the same dimension, so existing rows silently lose
-- vector-search relevance until re-embedded. (FTS still works, which is exactly
-- why this is easy to miss — hybrid search doesn't collapse, it quietly gets worse.)
--
-- Cursor-paginated by id (ASC). Re-embeds via M.update(id, {title, body}) — the
-- same write path a real edit uses; only title/body are passed.
--
-- An embedder of another dimension is allowed here: the database takes the new
-- dimension once every scope has been re-embedded (`switched` in the result says
-- when that happened); until then writes of the new size are refused elsewhere.
--
-- opts.batch    rows per page (default 100, max 1000)
-- opts.dry_run  true → just count matching rows, no writes
-- opts.on_progress  optional fn(updated, last_id) called after each page
-- Returns { updated, errors, last_id, dim, switched } (errors: list of {id, err}),
-- or for dry_run: { would_update, dry_run = true }.
-- ---------------------------------------------------------------------------
function M.reembed_scope(scope, opts)
    if not scope or scope == "" then
        return nil, "reembed_scope: scope required"
    end
    opts = opts or {}
    -- Federation. A dev's org replica re-embeds itself: the embedder signature
    -- is part of the sync, so a changed embedder forces a full resync. On the
    -- central, re-embedding recomputes vectors of unchanged text — content- and
    -- tier-preserving — so it may cover the directives too (after an embedder
    -- switch nothing else could refresh them).
    if policy.replica(scope) then
        return nil, "reembed_scope: " .. scope .. " is the org replica — it re-embeds on sync "
            .. "when the embedder changes (force it with: memo org pull --full)"
    end
    local cap = policy.protected(scope) and policy.capability("directive") or nil

    if opts.dry_run then
        return { would_update = tonumber(db.value("SELECT count(*) FROM " .. tbl() .. " WHERE scope = ?", scope)) or 0,
            dry_run = true }
    end

    local batch = math.max(1, math.min(tonumber(opts.batch) or 100, 1000))
    local updated, errors = 0, {}
    local last_id = 0
    local dim     -- the embedder's dimension, seen on a re-embedded row
    while true do
        local rows = db.query("SELECT id, title, body FROM " .. tbl()
            .. " WHERE scope = ? AND id > ? ORDER BY id ASC LIMIT ?", scope, last_id, batch)
        if not rows or #rows == 0 then break end
        for _, r in ipairs(rows) do
            local _, uerr = M.update(r.id, { title = r.title, body = r.body, _cap = cap, _reembed = true })
            if uerr then
                errors[#errors + 1] = { id = r.id, err = uerr }
            else
                updated = updated + 1
                dim = dim or tonumber((db.value("SELECT length(embedding) / 4 FROM " .. tbl()
                    .. " WHERE id = ? AND embedding IS NOT NULL", r.id)))
            end
            last_id = r.id
        end
        if opts.on_progress then opts.on_progress(updated, last_id) end
        if #rows < batch then break end
    end
    -- The scope's observations are in the same vector space: re-embedded from their text
    -- too (they kept the old one — after a change of size no search found them again; of
    -- the same size, their similarities came from another model).
    local observations = 0
    for _, o in ipairs(db.query("SELECT id, body FROM lm_observations WHERE scope = ?", scope) or {}) do
        local vec, verr = _embed_row(o.body or "")
        if vec == nil then
            errors[#errors + 1] = { id = o.id, err = "observation: " .. tostring(verr) }
        else   -- (false: too long even shortened — no vector, rather than the stale one)
            local blob, norm = _vec_params(vec or nil)
            db.run("UPDATE lm_observations SET embedding = ?, emb_norm = ? WHERE id = ?", blob, norm, o.id)
            observations = observations + 1
        end
    end
    local switched = dim and _finish_switch(dim) or false
    return { updated = updated, errors = errors, last_id = last_id, dim = dim, switched = switched,
             observations = observations }
end

-- ---------------------------------------------------------------------------
-- search (hybrid: exact vector cosine ∪ FTS, normalised, blended, weighted)
-- ---------------------------------------------------------------------------

-- WHERE fragments + parameters for the filters every search leg shares. `scope` may
-- be a string or a scope SET (hierarchical multi-scope search). `p` prefixes the
-- columns ("m." in the FTS join). Tier already factors into the candidate weight,
-- so a higher-tier memory (e.g. an org directive) outranks a lower-tier one across
-- the union automatically.
local function _filters(f, p, with_time)
    p = p or ""
    local conds, params = {}, {}
    if type(f.scope) == "table" then
        local parts = {}
        for _, s in ipairs(f.scope) do if s ~= nil and s ~= "" then parts[#parts + 1] = s end end
        if #parts > 0 then
            conds[#conds + 1] = p .. "scope IN (" .. db.placeholders(#parts) .. ")"
            push_all(params, parts)
        end
    elseif f.scope and f.scope ~= "" then
        conds[#conds + 1] = p .. "scope = ?"; params[#params + 1] = f.scope
    end
    if f.kind then conds[#conds + 1] = p .. "kind = ?"; params[#params + 1] = f.kind end
    if with_time then
        if f.since_us then conds[#conds + 1] = p .. "updated_at >= ?"; params[#params + 1] = f.since_us end
        if f.until_us then conds[#conds + 1] = p .. "updated_at < ?"; params[#params + 1] = f.until_us end
    end
    if f.tier_min then
        conds[#conds + 1] = p .. "tier >= ?"
        params[#params + 1] = math.max(0, math.min(3, math.floor(tonumber(f.tier_min))))
    end
    if f.tier_max then
        conds[#conds + 1] = p .. "tier <= ?"
        params[#params + 1] = math.max(0, math.min(3, math.floor(tonumber(f.tier_max))))
    end
    local mc, mp = _build_metadata_conds(f.metadata_filter, p)
    push_all(conds, mc); push_all(params, mp)
    return conds, params
end

local function _weight(r, ignore_decay, now_us)
    if ignore_decay then return 1.0 end
    local age_days = math.max(0, (now_us - (tonumber(r.updated_at) or now_us)) / US_PER_DAY)
    return (tonumber(r.importance) or 1.0) * math.exp(-(tonumber(r.decay_rate) or 0) * age_days)
end

-- The FTS leg's query, `where` = the filters (" AND m.…"); parameters: the MATCH string,
-- the filters', the limit. (A function so the test can check its plan.)
function M._fts_sql(where)
    return "SELECT m.id AS id, ts_cd(lm_memories_fts) AS s FROM lm_memories_fts CROSS JOIN " .. tbl()
        .. " m ON m.id = lm_memories_fts.rowid WHERE lm_memories_fts MATCH ?" .. (where or "")
        .. " ORDER BY s DESC LIMIT ?"
end

-- The hybrid leg: the exact vector top N ∪ the FTS top N (N = max(50, limit)), each
-- candidate scored on both signals, normalised by the candidates' maximum, blended
-- wv·vec + wf·fts, times importance × decay.
local function _search_hybrid(q, qvec, f, limit, wv, wf, ignore_decay)
    local N = math.max(50, math.floor(tonumber(limit) or 10))
    local conds, params = _filters(f, "", true)

    -- vector leg: exact scan, keeping the top N in a min-heap (the weakest kept score at
    -- the root) — no table per row, no sort of every row
    local qv = vectors.query(qvec)
    local cosine_ptr = vectors.cosine_ptr
    local hid, hsc, hn = {}, {}, 0
    local vconds = { "embedding IS NOT NULL" }
    push_all(vconds, conds)
    local n, serr = db.scan("SELECT id, embedding, emb_norm FROM " .. tbl() .. " WHERE "
        .. table.concat(vconds, " AND "), params, function(r)
        local ptr, bytes = r:blob_ptr(1)
        local s = cosine_ptr(ptr, bytes, r:double(2), qv)
        local i
        if hn < N then
            hn = hn + 1; i = hn
            while i > 1 do                              -- sift up
                local p = math.floor(i / 2)
                if hsc[p] <= s then break end
                hid[i], hsc[i] = hid[p], hsc[p]; i = p
            end
        elseif s > hsc[1] then
            i = 1
            while true do                               -- sift down from the root
                local c = 2 * i
                if c > hn then break end
                if c < hn and hsc[c + 1] < hsc[c] then c = c + 1 end
                if hsc[c] >= s then break end
                hid[i], hsc[i] = hid[c], hsc[c]; i = c
            end
        else
            return
        end
        hid[i], hsc[i] = r:int(0), s
    end)
    if not n then return nil, "search: db error: " .. tostring(serr) end
    local vec_of, cand, seen = {}, {}, {}
    for i = 1, hn do vec_of[hid[i]] = hsc[i]; cand[#cand + 1] = hid[i]; seen[hid[i]] = true end

    -- FTS leg: FTS5 MATCH (all query words), ranked by ts_cd. CROSS JOIN keeps the FTS index
    -- the outer loop: with a bound LIMIT ? SQLite chose to walk every row of the scope by
    -- the (scope, tier) index and run MATCH per row — 0.5–2 s a search at 5,000 memories,
    -- ~15 ms this way.
    local fts_of = {}
    local mq = fts.match_query(q)
    if mq then
        local fconds, fparams = _filters(f, "m.", true)
        local where = (#fconds > 0) and (" AND " .. table.concat(fconds, " AND ")) or ""
        local fp = { mq }
        push_all(fp, fparams)
        fp[#fp + 1] = N
        local rows, ferr = db.query(M._fts_sql(where), unpack(fp, 1, #fp))
        if not rows then return nil, "search: db error: " .. tostring(ferr) end
        local extra = {}
        for _, r in ipairs(rows) do
            fts_of[r.id] = tonumber(r.s) or 0
            if not seen[r.id] then seen[r.id] = true; cand[#cand + 1] = r.id; extra[#extra + 1] = r.id end
        end
        -- text-only candidates are still scored on the vector signal
        if #extra > 0 then
            local en, eerr = db.scan("SELECT id, embedding, emb_norm FROM " .. tbl() .. " WHERE embedding IS NOT NULL "
                .. "AND id IN (" .. db.placeholders(#extra) .. ")", extra, function(r)
                local ptr, bytes = r:blob_ptr(1)
                vec_of[r:int(0)] = cosine_ptr(ptr, bytes, r:double(2), qv)
            end)
            if not en then return nil, "search: db error: " .. tostring(eerr) end
        end
    end
    if #cand == 0 then return {} end

    local rows, qerr = db.query("SELECT " .. RETURN_COLS .. " FROM " .. tbl() .. " WHERE id IN ("
        .. db.placeholders(#cand) .. ")", unpack(cand, 1, #cand))
    if not rows then return nil, "search: db error: " .. tostring(qerr) end
    local max_vec, max_fts = 0, 0
    for _, r in ipairs(rows) do
        r.vec_score = vec_of[r.id] or 0
        r.fts_score = fts_of[r.id] or 0
        if r.vec_score > max_vec then max_vec = r.vec_score end
        if r.fts_score > max_fts then max_fts = r.fts_score end
    end
    local now_us = util.now_us()
    for _, r in ipairs(rows) do
        local vec_n = (max_vec > 0) and (r.vec_score / max_vec) or 0
        local fts_n = (max_fts > 0) and (r.fts_score / max_fts) or 0
        r.weight = _weight(r, ignore_decay, now_us)
        r.score  = (wv * vec_n + wf * fts_n) * r.weight
    end
    table.sort(rows, function(a, b) return (a.score or 0) > (b.score or 0) end)
    return _trim(rows, limit)
end

-- Third search leg: proximity-weighted date filter. Fires only when the caller's
-- query has a temporal expression. Same filters as the hybrid leg except since/until.
local function _search_temporal(f, window, fetch_limit, ignore_decay)
    local half_us = math.max(1, window.half_secs) * 1000000
    local center_us = math.floor(window.center) * 1000000
    local conds, params = _filters(f, "", false)
    -- Widen the date filter to 3× the half-window so nearby-but-outside rows
    -- still contribute (they'll receive a low proximity score).
    conds[#conds + 1] = "created_at BETWEEN ? AND ?"
    params[#params + 1] = center_us - 3 * half_us
    params[#params + 1] = center_us + 3 * half_us
    -- The nearest first, `fetch_limit` of them, chosen by SQLite (the proximity score falls
    -- with the distance): it read every row of the window, whole, to sort them in Lua.
    params[#params + 1] = center_us
    params[#params + 1] = math.max(1, math.floor(tonumber(fetch_limit) or 20))
    local rows = db.query("SELECT " .. RETURN_COLS .. " FROM " .. tbl() .. " WHERE "
        .. table.concat(conds, " AND ") .. " ORDER BY abs(created_at - ?) LIMIT ?", unpack(params, 1, #params))
    if not rows then return {} end  -- temporal leg is best-effort
    local now_us = util.now_us()
    for _, r in ipairs(rows) do
        local ts = math.max(0.0, 1.0 - math.abs(r.created_at - center_us) / half_us)
        r.vec_score, r.fts_score = 0, 0
        r.temporal_score = ts
        r.weight = _weight(r, ignore_decay, now_us)
        r.score = ts * r.weight
    end
    return rows
end

-- The creation day of a row (µs, UTC) as local-midnight epoch seconds — the
-- granularity the temporal proximity boost has always used.
local function _day_epoch(us)
    local t = os.date("!*t", math.floor((tonumber(us) or 0) / 1000000))
    return os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 })
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
    -- Federation (dev): searching the org replica refreshes it first when stale
    -- (TTL-debounced — a per-process throttle + one atomic claim; time-boxed;
    -- offline-safe). No-op for solo / org roles and for non-org searches.
    if policy.role() == "dev" then
        local touches_org = policy.replica(scope)
        if type(args.scopes) == "table" then
            for _, s in ipairs(args.scopes) do if policy.replica(s) then touches_org = true end end
        end
        if touches_org then
            -- Pull only: the search is waiting (push + proposals run at session start).
            pcall(function() require("luamemo.federation.client").maybe_sync({ budget_s = 3, pull_only = true }) end)
        end
    end
    local limit = math.min(tonumber(args.limit) or 10, 100)
    local ignore_decay = args.ignore_decay and true or false

    -- Optional explicit temporal bounds. `args["until"]` uses the bracket
    -- syntax because `until` is a Lua reserved word; accept both forms.
    local since_us, t_err = _parse_time(args.since, "since")
    if t_err then return nil, t_err end
    local until_us
    until_us, t_err = _parse_time(args["until"] or args.until_, "until")
    if t_err then return nil, t_err end

    -- Natural-language temporal parsing (opt-in; disabled when skip_temporal=true).
    local twindow = nil
    if not args.skip_temporal then twindow = temporal.parse(q) end

    local weights = args.hybrid_weights or cfg.hybrid_weights
    local wv = weights.vector or 0.7
    local wf = weights.fts or 0.3

    local mferr = M.check_metadata_filter(args.metadata_filter)
    if mferr then return nil, "search: " .. mferr end
    local metadata_filter = (type(args.metadata_filter) == "table") and args.metadata_filter or nil
    if type(args.project) == "string" and args.project ~= "" then
        local mf = {}
        for k, v in pairs(metadata_filter or {}) do mf[k] = v end
        mf.__org_project = args.project
        metadata_filter = mf
    end
    local f = {
        scope = scope_arg, kind = args.kind, since_us = since_us, until_us = until_us,
        tier_min = (args.tier_min ~= nil) and tonumber(args.tier_min) or nil,
        tier_max = (args.tier_max ~= nil) and tonumber(args.tier_max) or nil,
        metadata_filter = metadata_filter,
    }

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
        local top_n = tonumber(args.rerank_top_n) or tonumber(cfg.rerank_top_n) or 20
        if top_n > limit then fetch_limit = math.min(top_n, 100) end
    end
    -- Over-fetch for RRF when temporal leg is active.
    local rrf_fetch = twindow and math.min(fetch_limit * 2, 100) or fetch_limit

    local rows
    rows, err = _search_hybrid(q, qvec, f, rrf_fetch, wv, wf, ignore_decay)
    if not rows then return nil, err end

    -- When a temporal window was detected, run the temporal leg and fuse
    -- all legs with RRF. Fall back to weighted-blend when no temporal
    -- expression was found (unchanged behaviour for existing queries).
    if twindow then
        local t_rows = _search_temporal(f, twindow, rrf_fetch, ignore_decay)
        -- Apply temporal proximity boost to the baseline rows, then re-sort
        -- so that RRF uses the boost-adjusted rank (not the raw vector rank).
        local alpha = (cfg.temporal_alpha) or 0.2
        for _, r in ipairs(rows) do
            r.score = (r.score or 0) * temporal.proximity_boost(_day_epoch(r.created_at), twindow, alpha)
        end
        table.sort(rows, function(a, b) return (a.score or 0) > (b.score or 0) end)
        local lists = { rows }
        if #t_rows > 0 then lists[#lists + 1] = t_rows end
        if #lists > 1 then rows = temporal.rrf_merge(lists) end
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
                if _boosted then
                    table.sort(rows, function(a, b) return (a.score or 0) > (b.score or 0) end)
                end
            end
        end
    end

    -- Trim to fetch_limit before reranking.
    rows = _trim(rows, fetch_limit)

    -- Apply reranking (memory rows only — observations are appended afterward
    -- so they never compete with primary evidence in the reranker).
    local final_rows
    if not rerank_on or #rows <= 1 then
        final_rows = _trim(rows, limit)
    else
        -- Lazy-require to avoid a circular dependency at module load.
        local rerank = require("luamemo.rerank")
        local rok, reranked = pcall(rerank.rerank, q, rows, {
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
        -- Rerank is best-effort: on adapter failure — an error returned, or raised (a
        -- model's malformed answer) — fall back to the baseline ranking so search()
        -- never fails or returns nothing because of it.
        if not rok then io.stderr:write("[luamemo] rerank failed (baseline order kept): ", tostring(reranked), "\n") end
        final_rows = (rok and reranked) or _trim(rows, limit)
    end

    -- min_score: drop memories scoring below it (the score is the hybrid relevance
    -- × the importance / decay weight, with the query boosts — reranking only reorders).
    local min_score = tonumber(args.min_score)
    if min_score then
        local kept = {}
        for _, r in ipairs(final_rows) do
            if (tonumber(r.score) or 0) >= min_score then kept[#kept + 1] = r end
        end
        final_rows = kept
    end

    -- Phase 3: feedback capture. When enabled, append-only log the retrieval
    -- event (query + candidate memory ids in final rank order) so a later
    -- reinforcement on any candidate can form a (query, positive, negatives)
    -- training triple. Off by default; fail-silent; never affects results.
    -- args.skip_feedback: a system search (training / gating / evaluation), not
    -- a retrieval anyone acted on — logging it would feed learning its own probes.
    if cfg.feedback_enabled and not args.skip_feedback and args.query and args.query ~= "" then
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
    -- Observations never displace primary evidence from the top positions. They have no
    -- kind, metadata, tier or time of their own: a search filtered on one gets none (they
    -- came back whatever the filter), and min_score holds for them as for memories.
    local filtered = args.kind or since_us or until_us or f.tier_max
        or (type(args.metadata_filter) == "table" and next(args.metadata_filter) ~= nil)
    if not args.skip_observations and not filtered then
        if consolidate.pending(scope or "") then
            -- (a bounded slice: a bulk write's backlog drains over the next searches; tier ≥ 1
            -- — tier 0 is raw conversation, the digest's: distilled here, a search's tier
            -- filter didn't hold for it)
            pcall(consolidate.process, scope or "", { limit = 100, tier_min = 1 })
        end
        local obs_rows = consolidate.search(scope or "", qvec, rrf_fetch)
        if #obs_rows > 0 then
            local obs_max = tonumber(args.obs_max_slots)
                or tonumber(cfg.obs_max_slots) or 3
            -- An observation saying what a result already says is left out (the default
            -- summarizer keeps a member's body: the same text twice in one answer).
            local shown = {}
            for _, r in ipairs(final_rows) do if r.body then shown[r.body] = true end end
            local added = 0
            for _, o in ipairs(obs_rows) do
                if added >= obs_max then break end
                if not shown[o.body] and not (min_score and (tonumber(o.score) or 0) < min_score) then
                    -- Its own id (lm_observations), never `id`: memory_get / update / delete
                    -- read that as a memory id — an agent acting on an observation reached
                    -- an unrelated memory, in any scope.
                    o.observation_id, o.id = o.id, nil
                    final_rows[#final_rows + 1] = o
                    shown[o.body], added = true, added + 1
                end
            end
        end
    end

    return _out_all(final_rows)
end

return M
