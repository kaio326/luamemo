-- luamemo.init
-- Public entry point. Holds runtime config and re-exports the high-level API.

local store       = require("luamemo.store")
local embed       = require("luamemo.embed")
local routes      = require("luamemo.routes")
local summarizer  = require("luamemo.summarizer")
local rerank      = require("luamemo.rerank")
local secrets     = require("luamemo.secrets")

local M = {}

-- ---------------------------------------------------------------------------
-- Default configuration. Overridden by setup().
-- ---------------------------------------------------------------------------
M.config = {
    db_table       = "lapis_memory",
    -- HTTP embedder config (used when embedder_local is nil):
    embedder_url   = nil,
    embedder_adapter = "generic",          -- "generic" | "ollama" | "openai" | "tei" | "voyage" | "cohere"
    embedder_headers = {},                 -- e.g. { Authorization = "Bearer ..." }
    -- In-process embedder (overrides HTTP when set):
    --   "hash" -> luamemo.embedders.hash  (pure Lua, zero deps)
    embedder_local = nil,
    embed_dim      = 384,
    embed_timeout_ms = 5000,
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
        assert(M.config.embedder_url,
            "setup(): either embedder_local or embedder_url is required")
    end
    assert(type(M.config.auth_fn) == "function",
        "setup(): auth_fn must be a function")
    embed.configure(M.config)
    store.configure(M.config)
    summarizer.configure(M.config)
    rerank.configure(M.config)
    secrets.configure(M.config)

    -- Fail-fast embedder health check. Skip for the `hash` embedder
    -- (cannot fail) and when callers explicitly opt out (offline tests,
    -- pgmoon-shim eval scripts).
    if not M.config.skip_embed_probe and M.config.embedder_local ~= "hash" then
        local dim, err = embed.probe()
        if not dim then
            error("setup() embed probe failed: " .. tostring(err) ..
                "\n  Check embedder_url / embedder_model / network access." ..
                "\n  To bypass during offline testing, pass `skip_embed_probe = true`.")
        end
        if dim ~= M.config.embed_dim then
            error(("setup() embed_dim mismatch: configured %d, embedder returned %d." ..
                "\n  Update setup({ embed_dim = %d }) to match your embedder.")
                :format(M.config.embed_dim, dim, dim))
        end
    end

    if M.config.corpus_health_check then
        -- Best-effort. Wrapped in pcall so a missing table on a fresh
        -- install never blocks startup; the warnings are advisory only.
        pcall(M.corpus_health_check)
    end

    return M
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
M.web     = require("luamemo.web")
M.embed   = embed
M.store   = store
M.summarizer = summarizer
M.rerank  = rerank
M.hooks   = require("luamemo.hooks")
M.tune_weights = require("luamemo.tune_weights")
M.kg      = require("luamemo.kg")
M.secrets = secrets

--- Manual one-shot summariser cycle (no timer).
M.summarize = function(opts) return summarizer.run(opts) end
M.promote   = function(opts) return summarizer.promote(opts) end

return M
