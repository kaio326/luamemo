-- luamemo.init
-- Internal API — no stability promise. luamemo is used through the `memo` CLI and its
-- MCP server, both built on these modules; this holds their shared runtime config and
-- entry points.

local store       = require("luamemo.store")
local embed       = require("luamemo.embed")
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
M.VERSION = "0.5.1"

-- Runtime state. ok is false until setup() completes a successful embedder
-- probe. ensure_ready() retries the probe on demand so a slow-starting
-- embedder sidecar can recover without a full container restart.
local _state         = { ok = false }
local _setup_called  = false  -- true after setup() completes successfully
local _last_probe_ts = 0   -- os.time() of the most recent ensure_ready() probe attempt

-- ---------------------------------------------------------------------------
-- Configuration: every setting's default. luamemo.settings lists the settings —
-- their MEMO_ names, types, ranges and meanings; setup() merges a partial config
-- over these.
-- ---------------------------------------------------------------------------
M.config = require("luamemo.settings").defaults()

--- Configure the library. Must be called once at app startup.
-- @param opts table  partial config; merged into M.config. opts.settings_errors (from
--   cli._common.config_from_env): strict settings that didn't parse — refused here.
function M.setup(opts)
    assert(type(opts) == "table", "setup() requires a table")
    if opts.settings_errors then
        error("setup(): " .. table.concat(opts.settings_errors, "; ")
            .. " — fix it with memo config set (or in .luamemorc)", 0)
    end
    for k, v in pairs(opts) do
        M.config[k] = v
    end
    if not M.config.embedder_local then
        if not M.config.embedder_url then
            local adapter = M.config.embedder_adapter
            if adapter and adapter ~= "generic" then
                error(string.format(
                    "setup(): MEMO_EMBEDDER_ADAPTER = %q is set but MEMO_EMBEDDER_URL is not.\n" ..
                    "  The adapter selects the HTTP request format; the URL is still " ..
                    "required.\n  Set MEMO_EMBEDDER_URL to your %s endpoint.",
                    adapter, adapter))
            end
            error("setup(): an embedder is required — MEMO_EMBEDDER (in-process) or MEMO_EMBEDDER_URL")
        end
    end
    -- A different database than the open one: reopen on next use.
    require("luamemo.db").reconfigure()
    -- Federation policy first: it validates role/org config (raises on bad values)
    -- and every write path below consults it.
    require("luamemo.federation.policy").configure(M.config)
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
            "\n  Check MEMO_EMBEDDER_URL / MEMO_EMBEDDER_MODEL / network access (memo ping --embedder)." ..
            "\n  To start without checking it: MEMO_SKIP_EMBED_PROBE=true.")
    end
    _state.ok     = true
    _setup_called = true

    if M.config.corpus_health_check then
        -- Best-effort. Wrapped in pcall so a missing table on a fresh
        -- install never blocks startup; the warnings are advisory only.
        local ok, stats = pcall(M.corpus_health_check)
        if ok and type(stats) == "table" then
            for _, w in ipairs(stats.warnings or {}) do io.stderr:write(w, "\n") end
        end
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
        return false, ("embed_dim mismatch: MEMO_EMBED_DIM is %d, the embedder returns %d." ..
            "  Set it to match: memo config set MEMO_EMBED_DIM %d")
            :format(config.embed_dim, dim, dim)
    end
    return true
end

--- Has setup() completed?
function M.is_setup() return _setup_called end

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
    if M._init_embedder(M.config) then _state.ok = true end
    return _state.ok
end

-- ---------------------------------------------------------------------------
-- Corpus health check
--
-- Read-only aggregate stats over the memories table, and one warning per
-- tripped threshold.
--
-- Returns a stats table { rows, p95_chars, avg_chars, max_chars, truncated, warnings }
-- so callers (memo doctor) can render it however they like.
-- ---------------------------------------------------------------------------
function M.corpus_health_check()
    local db = require("luamemo.db")
    local stats, err = db.first("SELECT count(*) AS rows, "
        .. "CAST(COALESCE(avg(length(title) + length(body)), 0) AS INTEGER) AS avg_chars, "
        .. "COALESCE(max(length(title) + length(body)), 0) AS max_chars, "
        .. "COALESCE(sum(was_truncated), 0) AS truncated FROM lm_memories")
    if not stats then
        return nil, "corpus_health_check: " .. tostring(err)
    end
    -- percentile_disc(0.95): the smallest length with at least 95% of rows at or below it
    stats.p95_chars = 0
    if stats.rows > 0 then
        stats.p95_chars = tonumber((db.value("SELECT length(title) + length(body) FROM lm_memories "
            .. "ORDER BY 1 LIMIT 1 OFFSET ?", math.ceil(0.95 * stats.rows) - 1))) or 0
    end
    stats.warnings = {}

    -- Threshold A: truncation ratio. Anything above 1% of rows being
    -- truncated by the embedder client is a strong signal the embedder
    -- context is too small for the workload.
    if stats.rows > 0 and stats.truncated > 0 then
        local ratio = stats.truncated / stats.rows
        if ratio >= 0.01 then
            local msg = ("luamemo: %d/%d rows (%.1f%%) were truncated " ..
                "before embedding. Consider switching to a larger-context " ..
                "embedder (run `memo calibrate`) or lowering MEMO_EMBED_MAX_CHARS.")
                :format(stats.truncated, stats.rows, ratio * 100)
            table.insert(stats.warnings, msg)
        end
    end

    return stats
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

M.embed   = embed
M.store   = store
M.summarizer = summarizer
M.rerank  = rerank
M.tune_weights = require("luamemo.tune_weights")
M.kg      = require("luamemo.kg")
M.secrets = secrets
M.index   = index
M.delete_where = function(args) return store.delete_where(args) end

--- Manual one-shot summariser cycle (no timer).
M.summarize = function(opts) return summarizer.run(opts) end
M.promote   = function(opts) return summarizer.promote(opts) end

return M
