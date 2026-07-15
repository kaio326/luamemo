-- luamemo.rerankers.learned  (Phase 4 — learned reweighting, not hand-tuned)
--
-- A pure-Lua learned reranker: a linear model over cheap per-candidate features
-- that reorders the already-retrieved pool. Weights are trained offline
-- (luamemo.rerank_train) on feedback triples and loaded from a versioned JSON
-- artifact. It NEVER changes what is retrieved — only the order of the pool.
--
-- Safe by default: with no weights configured it returns the baseline order
-- (identity), so enabling the adapter without a trained model is a no-op.
--
-- Adapter contract (shared): rerank(query, hits, cfg) -> {{index, score}, ...}, err
--   * index 1-based into hits; score higher = more relevant.
--
-- Feature note: `score` is the baseline blended rank score — the PRIOR.
-- Initialising its weight to 1 and all others to 0 reproduces the baseline
-- order exactly (shrink-to-prior => day-1 == today). `reuse` is the usage
-- signal from the feedback substrate (Phase 3); callers enrich hits with
-- `reuse_count` (0 when absent) so the hot path stays DB-free.

local M = {}

-- Fixed feature order. Keep in sync with luamemo.rerank_train.
M.FEATURES = { "score", "vec_score", "fts_score", "importance", "tier", "reuse" }

local function raw_feature(h, name)
    if name == "reuse" then return math.log(1 + (tonumber(h.reuse_count) or 0)) end
    if name == "tier"  then return tonumber(h.tier) or 1 end
    return tonumber(h[name]) or 0
end

-- Per-pool min-max normalisation so learned weights are scale-comparable.
-- A constant feature maps to 0 for every candidate (no signal, no divide-by-zero).
function M.pool_features(hits)
    local F = M.FEATURES
    local mins, maxs, raw = {}, {}, {}
    for i, h in ipairs(hits) do
        raw[i] = {}
        for _, name in ipairs(F) do
            local v = raw_feature(h, name)
            raw[i][name] = v
            if mins[name] == nil or v < mins[name] then mins[name] = v end
            if maxs[name] == nil or v > maxs[name] then maxs[name] = v end
        end
    end
    local norm = {}
    for i = 1, #hits do
        norm[i] = {}
        for _, name in ipairs(F) do
            local lo, hi = mins[name], maxs[name]
            norm[i][name] = (hi > lo) and ((raw[i][name] - lo) / (hi - lo)) or 0
        end
    end
    return norm
end

-- Linear score of one normalised feature vector under `weights`.
function M.score_one(weights, fv)
    local s = weights.bias or 0
    for _, name in ipairs(M.FEATURES) do
        s = s + (weights[name] or 0) * (fv[name] or 0)
    end
    return s
end

-- Lazily-loaded current weights (cached per scope). cfg.rerank_weights overrides
-- (used by the trainer/bench to inject a specific version). Resolution order:
--   1. cfg.rerank_weights (explicit)
--   2. per-scope promoted weights in the DB (luamemo.learner_store) — Phase 11
--   3. the global file artifact (luamemo.rerank_train) — legacy / unscoped
-- so a scope with its own promoted model uses it, and everything else keeps the
-- prior behaviour. Cache is per-process (promotions are rare; a fresh CLI process
-- or a server restart picks up new weights; reset_cache() clears it in-process).
local _cache = {}
local function current_weights(cfg)
    if cfg and type(cfg.rerank_weights) == "table" then return cfg.rerank_weights end
    local scope = cfg and cfg.rerank_scope
    local key = (type(scope) == "string" and scope ~= "") and scope or "__global__"
    local c = _cache[key]
    if c ~= nil then return c or nil end

    local w
    if type(scope) == "string" and scope ~= "" then
        local ok_ls, lstore = pcall(require, "luamemo.learner_store")
        if ok_ls then
            local sw = lstore.load_current(scope, "reranker")
            if type(sw) == "table" then w = sw end
        end
    end
    if not w then
        local ok, train = pcall(require, "luamemo.rerank_train")
        if ok and train and train.load_current then w = train.load_current() end
    end
    _cache[key] = w or false
    return w
end
function M.reset_cache() _cache = {} end

function M.rerank(query, hits, cfg)
    if type(hits) ~= "table" or #hits == 0 then return {} end
    local weights = current_weights(cfg)
    if type(weights) ~= "table" then
        -- No model: preserve the baseline order (higher score for earlier rank).
        local out = {}
        for i = 1, #hits do out[i] = { index = i, score = (#hits - i + 1) } end
        return out
    end
    local norm = M.pool_features(hits)
    local out = {}
    for i = 1, #hits do
        out[i] = { index = i, score = M.score_one(weights, norm[i]) }
    end

    -- Optional ε-greedy exploration: with probability epsilon, jitter scores so
    -- the feedback log keeps seeing items the current model would not surface.
    -- Off by default (epsilon 0) so tests/benches are deterministic.
    local eps = tonumber(cfg and cfg.rerank_epsilon) or 0
    if eps > 0 then
        for i = 1, #out do
            if math.random() < eps then out[i].score = out[i].score + (math.random() - 0.5) end
        end
    end
    return out
end

return M
