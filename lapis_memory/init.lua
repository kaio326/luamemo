-- lapis_memory.init
-- Public entry point. Holds runtime config and re-exports the high-level API.

local store       = require("lapis_memory.store")
local embed       = require("lapis_memory.embed")
local routes      = require("lapis_memory.routes")
local summarizer  = require("lapis_memory.summarizer")
local rerank      = require("lapis_memory.rerank")

local M = {}

-- ---------------------------------------------------------------------------
-- Default configuration. Overridden by setup().
-- ---------------------------------------------------------------------------
M.config = {
    db_table       = "lapis_memory",
    -- HTTP embedder config (used when embedder_local is nil):
    embedder_url   = nil,
    embedder_adapter = "generic",          -- "generic" | "ollama" | "openai"
    embedder_headers = {},                 -- e.g. { Authorization = "Bearer ..." }
    -- In-process embedder (overrides HTTP when set):
    --   "hash" -> lapis_memory.embedders.hash  (pure Lua, zero deps)
    embedder_local = nil,
    embed_dim      = 384,
    embed_timeout_ms = 5000,
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

    return M
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
--       require("lapis_memory").start_background_jobs()
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
            ngx.log(ngx.ERR, "lapis_memory summarizer error: ", err)
        end
    end

    local ok, err = ngx.timer.every(interval, run_cycle)
    if not ok then
        ngx.log(ngx.ERR, "lapis_memory: failed to schedule summarizer: ", err)
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

M.routes = routes
M.web    = require("lapis_memory.web")
M.embed  = embed
M.store  = store
M.summarizer = summarizer
M.rerank = rerank
M.hooks  = require("lapis_memory.hooks")
M.tune_weights = require("lapis_memory.tune_weights")
M.kg     = require("lapis_memory.kg")

--- Manual one-shot summariser cycle (no timer).
M.summarize = function(opts) return summarizer.run(opts) end
M.promote   = function(opts) return summarizer.promote(opts) end

return M
