-- luamemo.rerank
--
-- LLM rerank step over a `search` result list. Pulls top-N candidates,
-- asks the configured rerank adapter to score / pick the most relevant
-- ones against the original query, and returns the rebalanced top-K.
--
-- Used by:
--   * store.search() when called with `rerank = true` (or when
--     cfg.rerank_enabled is true and the call doesn't override).
--   * The CLI / tests that want to wrap an existing search result.
--
-- Pluggable adapter shape mirrors `summarizer_adapter`:
--   rerank_adapter      "noop" | "ollama" | "openai" | "cross_encoder"
--   rerank_url          adapter-specific endpoint
--   rerank_model        adapter-specific model id
--   rerank_headers      extra HTTP headers
--   rerank_timeout_ms   per-request timeout (default 30000)
--   rerank_top_n        candidates passed to the LLM (default 20)
--   rerank_enabled      bool, default false (off unless explicitly enabled)
--
-- Output preserves every field on each candidate row plus:
--   rerank_score        number in [0,1], adapter-defined
--   rerank_rank         1-based new position chosen by the LLM
--
-- Token-cost note:
--   Rerank adds one short LLM call per `search` (~800-1500 tokens
--   depending on K and chunk size). It pays for itself when the host
--   uses it to lower K downstream — e.g. asking the LLM to pick the
--   single best of 20 candidates and then putting only that one in the
--   prompt is usually cheaper than putting 5-10 raw search hits in the
--   prompt and letting the model sort them itself.

local M = {}

local util            = require("luamemo.util")
local cfg             = nil
local _adapter_cache  = {}   -- [name] -> module; avoids repeated pcall+validation

function M.configure(config)
    cfg = config
end

-- Load a reranker adapter by name, caching the result so repeated calls
-- in a hot search path don't pcall+validate on every request.
local function load_adapter(name)
    return util.load_submodule(_adapter_cache, "luamemo.rerankers", name, "rerank")
end

--- Rerank a list of search hits against the original query.
-- Pure function: does not call back into store.search(). The caller is
-- responsible for already having the candidate list.
--
-- @param query  string  original search query
-- @param hits   table   array of rows as returned by store.search
-- @param opts   table   optional per-call overrides:
--                       { limit, rerank_top_n, rerank_adapter,
--                         rerank_model, rerank_url, rerank_headers,
--                         rerank_timeout_ms }
-- @return table          rebalanced array (length <= limit)
-- @return nil, err       on any failure
function M.rerank(query, hits, opts)
    opts = opts or {}
    if type(query) ~= "string" or query == "" then
        return nil, "rerank: query is required"
    end
    if type(hits) ~= "table" then
        return nil, "rerank: hits must be a table"
    end
    if #hits == 0 then return hits end

    -- Build a per-call config view: caller overrides win, then fall back
    -- to the library config.
    local view = {
        rerank_adapter    = opts.rerank_adapter
                            or (cfg and cfg.rerank_adapter) or "noop",
        rerank_url        = opts.rerank_url
                            or (cfg and cfg.rerank_url),
        rerank_model      = opts.rerank_model
                            or (cfg and cfg.rerank_model),
        rerank_headers    = opts.rerank_headers
                            or (cfg and cfg.rerank_headers) or {},
        rerank_timeout_ms = tonumber(opts.rerank_timeout_ms)
                            or (cfg and cfg.rerank_timeout_ms) or 30000,
        rerank_top_n      = tonumber(opts.rerank_top_n)
                            or (cfg and cfg.rerank_top_n) or 20,
        -- Scope for per-scope learned weights (Phase 11); nil = global/unscoped.
        rerank_scope      = opts.rerank_scope,
        rerank_weights    = opts.rerank_weights,
    }

    -- Trim the candidate pool the LLM sees to keep token cost predictable.
    local pool_size = math.min(#hits, view.rerank_top_n)
    local pool = {}
    for i = 1, pool_size do pool[i] = hits[i] end

    -- Load adapter by name from view (no global cfg mutation needed).
    local adapter, aerr = load_adapter(view.rerank_adapter)
    if not adapter then return nil, aerr end

    local scored, err = adapter.rerank(query, pool, view)
    if not scored then return nil, err end
    if type(scored) ~= "table" then
        return nil, "rerank: adapter returned non-table"
    end

    -- Normalise: each entry must carry its original index in the pool
    -- via .index (1-based). Stable sort by .score desc, then .index asc.
    for _, s in ipairs(scored) do
        s.index = tonumber(s.index)
        s.score = tonumber(s.score) or 0
        if not s.index or s.index < 1 or s.index > pool_size then
            return nil, "rerank: adapter returned invalid index "
                .. tostring(s.index)
        end
    end
    table.sort(scored, function(a, b)
        if a.score == b.score then return a.index < b.index end
        return a.score > b.score
    end)

    -- Materialise the rebalanced rows; preserve every original field
    -- plus rerank_score / rerank_rank annotations.
    local out = {}
    local seen = {}
    for new_rank, s in ipairs(scored) do
        if not seen[s.index] then
            seen[s.index] = true
            local row = pool[s.index]
            row.rerank_score = s.score
            row.rerank_rank  = new_rank
            out[#out + 1] = row
        end
    end

    -- Tail: append any pool rows the adapter did not score. This handles
    -- adapters that return only a top-K subset, so the caller still sees
    -- the full candidate list, just with the scored ones promoted.
    for i = 1, pool_size do
        if not seen[i] then
            local row = pool[i]
            row.rerank_score = row.rerank_score or 0
            row.rerank_rank  = row.rerank_rank  or (#out + 1)
            out[#out + 1] = row
        end
    end

    -- And any candidates beyond the LLM-visible pool stay at the tail
    -- in their original order.
    for i = pool_size + 1, #hits do
        out[#out + 1] = hits[i]
    end

    if opts.limit then
        local limit = math.min(tonumber(opts.limit) or #out, #out)
        local trimmed = {}
        for i = 1, limit do trimmed[i] = out[i] end
        return trimmed
    end
    return out
end

return M
