-- luamemo.init
-- Public entry point. Holds runtime config and re-exports the high-level API.

local store       = require("luamemo.store")
local embed       = require("luamemo.embed")
local routes      = require("luamemo.routes")
local summarizer  = require("luamemo.summarizer")
local rerank      = require("luamemo.rerank")
local secrets     = require("luamemo.secrets")
local patterns    = require("luamemo.patterns")
local index       = require("luamemo.index")

local M = {}

-- Single source of truth for the package version — must be bumped alongside
-- the rockspec (luamemo-<version>-<revision>.rockspec) on every release.
-- Anything that needs to report luamemo's version (the MCP server's
-- serverInfo, diagnostics, etc.) should read this instead of hardcoding its
-- own copy, which silently goes stale the moment it does.
M.VERSION = "0.4.1"

-- Runtime state. ok is false until setup() completes a successful embedder
-- probe. ensure_ready() retries the probe on demand so a slow-starting
-- embedder sidecar can recover without a full container restart.
local _state         = { ok = false }
local _setup_called  = false  -- true after setup() completes successfully
local _last_probe_ts = 0   -- os.time() of the most recent ensure_ready() probe attempt

-- ---------------------------------------------------------------------------
-- Default configuration. Overridden by setup().
-- ---------------------------------------------------------------------------
M.config = {
    db_table       = "lm_memories",
    -- HTTP embedder config (used when embedder_local is nil):
    embedder_url   = nil,
    embedder_adapter = "generic",          -- "generic" | "ollama" | "openai" | "tei" | "voyage" | "cohere"
    embedder_headers = {},                 -- e.g. { Authorization = "Bearer ..." }
    -- In-process embedder (overrides HTTP when set):
    --   "hash" -> luamemo.embedders.hash  (pure Lua, zero deps)
    embedder_local = nil,
    embed_dim      = 384,
    embed_timeout_ms = 30000,
    -- When set, embed.embed() truncates input to this many characters
    -- before sending to the embedder, and flags the row's was_truncated
    -- column. nil = no truncation (historical default). Recommended
    -- values per embedder family are documented in EMBEDDERS.md and
    -- printed by `memo init`.
    embed_max_chars = nil,
    -- When true, M.setup() runs M.corpus_health_check() once and emits
    -- a single ngx.log(WARN) line per tripped threshold (truncation
    -- ratio, embedder mismatch, scale outgrowing bruteforce). Failures
    -- are silent (pcall) so a missing/empty table never blocks startup.
    -- Operators can also call M.corpus_health_check() on demand.
    corpus_health_check = false,
    -- When true, skip the startup embedder health check. Set this in
    -- offline tests / pgmoon-shim eval scripts where the embedder is
    -- mocked or unreachable. In production it should stay false.
    skip_embed_probe = false,
    default_scope  = "global",
    auth_fn        = function() return false end,  -- deny by default
    hybrid_weights = { vector = 0.7, fts = 0.3 },
    -- Decay + importance scoring (see migration 002):
    --   weight = importance * exp(-decay_rate * days_since_updated)
    -- Importance: 0..10, higher = more pull on search ranking.
    -- Decay rate: 0..1 per day; 0 disables decay.
    default_importance = 1.0,
    default_decay_rate = 0.0,
    -- Dedup-on-write (Roadmap Item 3):
    -- Before INSERT, run a top-1 vector search in the same scope. If
    -- cosine similarity >= dedup_threshold, dispatch per dedup_strategy:
    --   "update" -> merge body/tags/metadata into the existing row
    --   "skip"   -> return the existing row, no write
    --   "append" -> always insert a new row (disables dedup at call site)
    dedup_enabled    = true,
    dedup_threshold  = 0.95,
    dedup_strategy   = "update",
    -- Background summarizer (Roadmap Item 4):
    --   adapter: "noop" (default) | "ollama" | "openai"
    --   timer:   ngx.timer.every interval, in seconds; 0 = disabled
    --   selection: candidates have weight < threshold AND age > retention.
    --   safety: each cycle is bounded by batch_size * max_batches rows.
    summarizer_adapter         = "noop",
    summarizer_url             = nil,
    summarizer_model           = nil,
    summarizer_headers         = {},
    summarizer_timeout_ms      = 60000,
    summarizer_interval_seconds = 0,           -- 0 disables the timer
    summarizer_weight_threshold = 0.5,
    summarizer_retention_days   = 30,
    summarizer_batch_size       = 20,
    summarizer_max_batches      = 5,
    -- Storage backend (Roadmap Item 7):
    --   "auto"       -> probe pg_extension on configure(); pgvector if
    --                   the extension is installed, bruteforce otherwise.
    --   "pgvector"   -> force the pgvector path (vector(N) + HNSW + <=>).
    --   "bruteforce" -> force the brute-force path (REAL[] + Lua cosine).
    --
    -- The brute-force backend pre-filters by scope/kind/FTS and pulls up
    -- to bruteforce_candidate_limit rows into Lua for cosine ranking.
    -- Comfortable up to ~10k-50k memories per scope at 384 dims.
    backend                     = "auto",
    bruteforce_candidate_limit  = 1000,
    -- Observation supplement slots: how many observation rows (from consolidate.search)
    -- are appended AFTER memory results when skip_observations=false.
    -- Observations are never merged into the primary evidence ranking; they
    -- supplement it. Set to 0 to suppress observations from results entirely.
    obs_max_slots               = 3,
    -- Preference extraction: when true, store.write() scans each memory body for
    -- first-person preference/habit/sentiment signals ("I prefer X", "I always Y")
    -- and inserts synthetic companion memories at importance=0.4 in the same scope.
    -- Synthetic rows carry metadata.is_synthetic=true and are never re-processed.
    -- Set to false to disable (e.g. for verbatim-only deployments).
    patterns_enabled            = true,
    -- Maximum body length (bytes) scanned by patterns.extract().
    -- Bodies longer than this are skipped entirely to bound CPU cost.
    patterns_max_body_chars     = 5000,
    -- Query-time boosts: score multipliers applied after retrieval to rows matching
    -- proper names or quoted phrases extracted from the query string.
    -- person_name_boost: applied when a capitalised token from the query appears in a row body.
    -- quoted_phrase_boost: applied when a single- or double-quoted phrase from the query appears verbatim.
    -- Set *_enabled = false to disable independently.
    person_name_boost           = 0.15,
    person_name_boost_enabled   = true,
    quoted_phrase_boost         = 0.40,
    quoted_phrase_boost_enabled = true,
    -- Backoff for ensure_ready() probe retries.
    -- When the embedder is down, ensure_ready() fires an HTTP probe on each
    -- failed store.write() call.  This key caps how often retries are attempted:
    -- at most once per ensure_ready_retry_secs seconds per Lua VM.
    -- Set to 0 to disable the backoff (retry on every call).
    ensure_ready_retry_secs     = 10,
    -- LLM rerank (Roadmap Item 15.1):
    --   adapter: "noop" (lexical overlap, no network) | "ollama" | "openai"
    --   enabled: when true, every search() runs through the reranker
    --            unless the call passes `rerank = false`.
    --   top_n:   max candidates the reranker sees per call (cost cap).
    rerank_adapter      = "noop",
    rerank_url          = nil,
    rerank_model        = nil,
    rerank_headers      = {},
    rerank_timeout_ms   = 30000,
    rerank_top_n        = 20,
    rerank_enabled      = false,
    -- Learned-from-usage substrate (luamemo.feedback). When true, store.search
    -- append-only logs each retrieval event (query + candidate ids) so a later
    -- reinforcement can form a training triple. OFF by default (inert, no cost).
    feedback_enabled    = false,
    -- Retrieval-miss detection (gated on feedback_enabled): a near-duplicate write
    -- at cosine >= miss_threshold means retrieval failed to surface an existing
    -- memory, so store.write records a 'miss' on it (importance bump + ranker
    -- signal). Lower than dedup_threshold so reworded near-duplicates still count.
    miss_threshold      = 0.90,
    -- Lazy auto-digest: when true, an ordinary write opportunistically runs a
    -- debounced maintenance digest (tier promotion / consolidation / decay) for
    -- its scope — at most once per auto_digest_interval seconds, tracked in
    -- lm_digest_state so it survives across stateless CLI invocations. This keeps
    -- memory maintaining itself without relying on an agent or scheduler to call
    -- `memo digest`. OFF by default (zero-regression); calibrate can enable it.
    auto_digest_enabled  = false,
    auto_digest_interval = 3600,
    -- Optional hook called for every API request before auth_fn.
    -- Use this to enforce CSRF, rate limits, etc.
    before_request = nil,
    -- Secrets module (luamemo.secrets):
    --   secrets_file — path to the encrypted JSON store (local file; no DB table).
    --     When not set, the secrets feature is disabled; everything else works normally.
    --     The file is created automatically on first store().
    --     Mount it as a Docker volume to make it available inside the container.
    --   Master key resolution (first match wins):
    --   1. master_key_path — path to a file with the hex key (Docker secret, env file)
    --   2. master_key_env  — name of an env var holding the hex key
    --   3. master_key      — explicit 64-hex-char key in config (CI / dev only)
    secrets_file    = nil,
    master_key_path = nil,
    master_key_env  = nil,
    master_key      = nil,
    -- PostgreSQL connection (plain-Lua / non-OpenResty path only).
    -- In OpenResty, lapis.db manages connections via the nginx pool and
    -- these keys are ignored. Outside OpenResty, luamemo.db creates
    -- a pgmoon connection from these values; each unset key falls back to
    -- the corresponding PGHOST / PGPORT / PGDATABASE / PGUSER / PGPASSWORD
    -- environment variable.
    pg_host     = nil,
    pg_port     = nil,
    pg_database = nil,
    pg_user     = nil,
    pg_password = nil,
}

--- Configure the library. Must be called once at app startup.
-- @param opts table  partial config; merged into M.config
function M.setup(opts)
    assert(type(opts) == "table", "setup() requires a table")
    for k, v in pairs(opts) do
        M.config[k] = v
    end
    if not M.config.embedder_local then
        if not M.config.embedder_url then
            local adapter = M.config.embedder_adapter
            if adapter and adapter ~= "generic" then
                error(string.format(
                    "setup(): embedder_adapter = %q is set but embedder_url is nil.\n" ..
                    "  embedder_adapter selects the HTTP request format; embedder_url is " ..
                    "still required.\n  Set embedder_url to your %s endpoint URL.",
                    adapter, adapter))
            end
            error("setup(): either embedder_local or embedder_url is required")
        end
    end
    assert(type(M.config.auth_fn) == "function",
        "setup(): auth_fn must be a function")
    embed.configure(M.config)
    store.configure(M.config)
    summarizer.configure(M.config)
    rerank.configure(M.config)
    secrets.configure(M.config)
    patterns.configure(M.config)
    index.configure(M.config)

    -- Fail-fast embedder health check.
    local probe_ok, probe_err = M._init_embedder(M.config)
    if not probe_ok then
        error("setup() " .. probe_err ..
            "\n  Check embedder_url / embedder_model / network access." ..
            "\n  To bypass during offline testing, pass `skip_embed_probe = true`.")
    end
    _state.ok     = true
    _setup_called = true

    if M.config.corpus_health_check then
        -- Best-effort. Wrapped in pcall so a missing table on a fresh
        -- install never blocks startup; the warnings are advisory only.
        pcall(M.corpus_health_check)
    end

    return M
end

--- Run only the embedder probe portion of setup(). Returns true on success
-- or false, err_string on failure. Called by setup() and ensure_ready().
-- @param config table  M.config (or a compatible table for unit tests)
function M._init_embedder(config)
    if config.skip_embed_probe or config.embedder_local == "hash" then
        return true
    end
    local dim, err = embed.probe()
    if not dim then
        return false, "embed probe failed: " .. tostring(err)
    end
    if dim ~= config.embed_dim then
        return false, ("embed_dim mismatch: configured %d, embedder returned %d." ..
            "  Update setup({ embed_dim = %d }) to match your embedder.")
            :format(config.embed_dim, dim, dim)
    end
    return true
end

--- Returns true when the library is fully operational (setup succeeded and
-- the embedder is reachable). On the first call after a failed startup,
-- retries the embedder probe once. If the sidecar is now up, sets
-- _state.ok = true so subsequent calls are cheap O(1) checks.
-- @return boolean
function M.ensure_ready()
    if _state.ok then return true end
    -- Nothing to retry if setup() was never called.
    if not _setup_called then return false end
    -- Backoff: only probe the embedder at most once per retry_secs to avoid
    -- thundering-herd when the embedder is down and writes are arriving at
    -- high frequency.  Each failed attempt resets the backoff window.
    local retry_secs = M.config.ensure_ready_retry_secs or 10
    if retry_secs > 0 and (os.time() - _last_probe_ts) < retry_secs then
        return false  -- still within backoff window
    end
    _last_probe_ts = os.time()
    local ok = M._init_embedder(M.config)
    if ok then
        _state.ok = true
        if type(ngx) == "table" and ngx.log and ngx.INFO then
            ngx.log(ngx.INFO, "[luamemo] embedder recovered, writes re-enabled")
        end
    end
    return _state.ok
end

-- ---------------------------------------------------------------------------
-- Corpus health check
--
-- One read-only SELECT against the configured table. Computes a few
-- aggregate stats and emits a WARN line per tripped threshold via
-- ngx.log when running under OpenResty (no-op under plain Lua).
--
-- Returns a stats table { rows, p95_chars, avg_chars, truncated, warnings }
-- so callers (memo doctor) can render it however they like.
-- ---------------------------------------------------------------------------
function M.corpus_health_check()
    local db = require("luamemo.db")
    local table_ident = db.escape_identifier(M.config.db_table)
    local rows, err = db.query(([[
        SELECT
            count(*)::int                          AS rows,
            COALESCE(avg(length(title) + length(body)), 0)::int AS avg_chars,
            COALESCE(percentile_disc(0.95)
                WITHIN GROUP (ORDER BY length(title) + length(body)), 0)::int AS p95_chars,
            COALESCE(max(length(title) + length(body)), 0)::int AS max_chars,
            COALESCE(sum(CASE WHEN was_truncated THEN 1 ELSE 0 END), 0)::int AS truncated
        FROM %s
    ]]):format(table_ident))
    if not rows then
        return nil, "corpus_health_check: " .. tostring(err)
    end
    local stats = rows[1] or { rows = 0, avg_chars = 0, p95_chars = 0,
                                max_chars = 0, truncated = 0 }
    stats.warnings = {}

    -- Threshold A: truncation ratio. Anything above 1% of rows being
    -- truncated by the embedder client is a strong signal the embedder
    -- context is too small for the workload.
    if stats.rows > 0 and stats.truncated > 0 then
        local ratio = stats.truncated / stats.rows
        if ratio >= 0.01 then
            local msg = ("luamemo: %d/%d rows (%.1f%%) were truncated " ..
                "before embedding. Consider switching to a larger-context " ..
                "embedder (run `memo init`) or lowering embed_max_chars.")
                :format(stats.truncated, stats.rows, ratio * 100)
            table.insert(stats.warnings, msg)
            if type(ngx) == "table" and ngx.log and ngx.WARN then
                ngx.log(ngx.WARN, msg)
            end
        end
    end

    -- Threshold B: bruteforce backend at scale. The brute-force path
    -- holds candidates in Lua; comfortable up to ~50k rows per scope.
    -- Above 100k total rows the warning fires regardless of scope shape.
    if stats.rows > 100000 and store.backend() == "bruteforce" then
        local msg = ("luamemo: %d rows on bruteforce backend " ..
            "(no pgvector). Latency will degrade past ~50k rows. " ..
            "Install pgvector and switch backend = \"pgvector\".")
            :format(stats.rows)
        table.insert(stats.warnings, msg)
        if type(ngx) == "table" and ngx.log and ngx.WARN then
            ngx.log(ngx.WARN, msg)
        end
    end

    return stats
end

-- ---------------------------------------------------------------------------
-- Background jobs (OpenResty only).
--
-- LIMITATION: this requires the OpenResty Lua API (`ngx.timer.every`,
-- `ngx.worker.id`). It is a no-op under plain Lua (CLI / tests). CLI users
-- can invoke `memo summarize` to run a cycle on demand.
--
-- Call this once from `init_worker_by_lua_block` in nginx.conf, e.g.:
--
--   init_worker_by_lua_block {
--       require("luamemo").start_background_jobs()
--   }
-- ---------------------------------------------------------------------------
function M.start_background_jobs()
    if type(ngx) ~= "table" or not ngx.timer or not ngx.worker then
        return false, "start_background_jobs: not running under OpenResty"
    end
    -- Only worker 0 to avoid duplicate cycles across workers.
    if ngx.worker.id() ~= 0 then return true end

    local interval = tonumber(M.config.summarizer_interval_seconds) or 0
    if interval <= 0 then
        return true   -- disabled by config
    end

    local function run_cycle(premature)
        if premature then return end
        local ok, err = pcall(summarizer.run, {})
        if not ok then
            ngx.log(ngx.ERR, "luamemo summarizer error: ", err)
        end
    end

    local ok, err = ngx.timer.every(interval, run_cycle)
    if not ok then
        ngx.log(ngx.ERR, "luamemo: failed to schedule summarizer: ", err)
        return false, err
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Re-exports (programmatic API)
-- ---------------------------------------------------------------------------
M.write  = function(args) return store.write(args) end
M.write_many = function(rows, opts) return store.write_many(rows, opts) end
M.search = function(args) return store.search(args) end
M.recent = function(args) return store.recent(args) end
M.get    = function(id)   return store.get(id) end
M.update = function(id, patch) return store.update(id, patch) end
M.delete = function(id)   return store.delete(id) end

M.routes  = routes
M.embed   = embed
M.store   = store
M.summarizer = summarizer
M.rerank  = rerank
M.hooks   = require("luamemo.hooks")
M.tune_weights = require("luamemo.tune_weights")
M.kg      = require("luamemo.kg")
M.secrets = secrets
M.index   = index
M.delete_where = function(args) return store.delete_where(args) end

--- Manual one-shot summariser cycle (no timer).
M.summarize = function(opts) return summarizer.run(opts) end
M.promote   = function(opts) return summarizer.promote(opts) end

return M
