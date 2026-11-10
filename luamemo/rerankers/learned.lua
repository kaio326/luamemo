-- luamemo.rerankers.learned  (Phase 4 — learned reweighting, not hand-tuned)
--
-- A pure-Lua learned reranker: a linear model over cheap per-candidate features
-- that reorders the already-retrieved pool. Weights are trained by luamemo.promote
-- (through luamemo.rerank_train) on feedback triples and stored per scope in the
-- database. It NEVER changes what is retrieved — only the order of the pool.
--
-- Safe by default: with no weights configured it returns the baseline order
-- (identity), so enabling the adapter without a trained model is a no-op.
--
-- Adapter contract (shared): rerank(query, hits, cfg) -> {{index, score}, ...}, err
--   * index 1-based into hits; score higher = more relevant.
--
-- Feature note: `score` is the baseline blended rank score — the PRIOR.
-- Initialising its weight to 1 and all others to 0 reproduces the baseline
-- order exactly (shrink-to-prior => day-1 == today). `reuse` is how often the
-- memory was confirmed useful. M.enrich is the one place it is read, by search
-- and by training alike (an example asks as of the moment its search ran), so a
-- model is trained and judged on what search really gives it. It costs one
-- indexed query per search, and only where a promoted model exists.

local M = {}

-- Fixed feature order. Keep in sync with luamemo.rerank_train.
M.FEATURES = { "score", "vec_score", "fts_score", "importance", "tier", "reuse" }

-- What a promoted model must say it is to be served. 2: trained on labels that a search really earned, with the
-- features search supplies, and past a gate that checks for harm. A model from before that (no format) ranks
-- worse than it was measured to, wherever it came from: an old row, a rollback, an organization's pull.
M.MODEL_FORMAT = 2
function M.usable(weights) return type(weights) == "table" and weights.format == M.MODEL_FORMAT end

--- The scope's promoted model, if it is one search may use → weights | nil.
function M.served_model(scope)
    local w = require("luamemo.learner_store").load_current(scope, "reranker")
    return M.usable(w) and w or nil
end

--- Set each hit's reuse_count: how many times its memory was confirmed useful (feedback.POSITIVE_SQL) before `at`
--- (µs; nil: up to now). A hit with no id is left alone.
function M.enrich(hits, at)
    local ids = {}
    for _, h in ipairs(hits) do
        local id = tonumber(h.id)
        if id then ids[#ids + 1] = math.floor(id) end
    end
    if #ids == 0 then return end
    local db, positive = require("luamemo.db"), require("luamemo.feedback").POSITIVE_SQL
    local in_ids, ids_json = db.in_list(ids)
    local sql = "SELECT memory_id, count(*) AS n FROM lm_reinforcements WHERE memory_id IN " .. in_ids
        .. " AND event_type IN " .. positive .. (at and " AND created_at < ?" or "") .. " GROUP BY memory_id"
    local rows, err
    if at then rows, err = db.query(sql, ids_json, at) else rows, err = db.query(sql, ids_json) end
    if not rows then error("learned.enrich: " .. tostring(err), 0) end
    local n = {}
    for _, r in ipairs(rows) do n[tonumber(r.memory_id)] = tonumber(r.n) end
    for _, h in ipairs(hits) do
        local id = tonumber(h.id)
        if id then h.reuse_count = n[math.floor(id)] or 0 end
    end
end

--- The pool search would rerank for `query` in `scope`, its `reuse` as of `at` (nil: now) → rows | nil, err: what training and
--- every gate score. As memory_search builds it: tier 1 and up, as many as search shows the model.
--- opts.reuse = false: no counts (the model must not lean on them, see aggregate).
function M.pool(scope, query, opts, at)
    local store = require("luamemo.store")
    local rows, err = store.search({ query = query, scope = scope, limit = store.rerank_pool_size(), tier_min = store.DEFAULT_TIER_MIN,
        skip_temporal = true, skip_observations = true, rerank = false, skip_feedback = true })
    if rows and #rows > 0 and not (opts and opts.reuse == false) then M.enrich(rows, at) end
    return rows, err
end

--- The training example that says `memory_id` should win this pool → { features, positive, weight } | nil (not in the pool).
function M.example(rows, memory_id, weight)
    for i, r in ipairs(rows) do
        if tonumber(r.id) == tonumber(memory_id) then
            return { features = M.pool_features(rows), positive = i, weight = weight or 1.0 }
        end
    end
end

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

--- Score a pool under `weights`, its reuse_count already set → { { index, score }, … }.
function M.score_pool(weights, hits)
    local norm = M.pool_features(hits)
    local out = {}
    for i = 1, #hits do
        out[i] = { index = i, score = M.score_one(weights, norm[i]) }
    end
    return out
end

-- Lazily-loaded current weights (cached per scope). cfg.rerank_weights overrides
-- (used by tests and benches to inject a specific version); otherwise the scope's
-- promoted model, if it may be served. Cache is per-process (promotions are rare; a fresh CLI process
-- or a server restart picks up new weights; reset_cache() clears it in-process).
local _cache = {}
local function current_weights(cfg)
    if cfg and type(cfg.rerank_weights) == "table" then return cfg.rerank_weights end
    local scope = cfg and cfg.rerank_scope
    if type(scope) ~= "string" or scope == "" then return nil end
    local c = _cache[scope]
    if c ~= nil then return c or nil end
    local w = M.served_model(scope)
    _cache[scope] = w or false
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
    M.enrich(hits)
    local out = M.score_pool(weights, hits)

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
