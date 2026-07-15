-- luamemo.rerank_train  (Phase 4 — offline trainer + versioned weight store)
--
-- Trains the linear learned reranker (luamemo.rerankers.learned) by pairwise
-- learning-to-rank on feedback triples: for each labelled query, the positive
-- (a reinforced/gold memory) should outscore the negatives (the other pool
-- candidates). Logistic pairwise loss, SGD, L2-regularised toward the PRIOR
-- (rank-by-baseline-score), so an untrained/tiny model stays ~= today.
--
-- Weight lifecycle (versioned JSON artifact; path via MEMO_RERANK_WEIGHTS):
--   save_version(w, meta) -> id   (records but does NOT promote)
--   promote(id)                   (id becomes current; prior kept for rollback)
--   rollback()                    (restore the previously-current version)
--   load_current() -> weights|nil (what the adapter serves)

local cjson   = require("cjson.safe")
local learned = require("luamemo.rerankers.learned")

local M = {}

local PATH = (os.getenv("MEMO_RERANK_WEIGHTS") ~= "" and os.getenv("MEMO_RERANK_WEIGHTS"))
    or "luamemo/rerank_weights.json"

-- The prior: rank by the baseline blended `score`, nothing else. Training can
-- only move away from this with evidence (L2 pulls back toward it).
function M.prior()
    local w = { bias = 0 }
    for _, name in ipairs(learned.FEATURES) do
        w[name] = (name == "score") and 1.0 or 0.0
    end
    return w
end

local function sigmoid(x)
    if x < -30 then return 0 end
    if x > 30 then return 1 end
    return 1 / (1 + math.exp(-x))
end

-- Train on examples = { { features = {fv1, fv2, ...}, positive = idx, weight = w }, ... }
-- where each fv is a normalised feature table from learned.pool_features().
-- opts: lr (0.1), l2 (0.01), epochs (200).
function M.train(examples, opts)
    opts = opts or {}
    local lr, l2, epochs = opts.lr or 0.1, opts.l2 or 0.01, opts.epochs or 200
    local w0 = M.prior()
    local w  = {}; for k, v in pairs(w0) do w[k] = v end
    local keys = { "bias" }
    for _, name in ipairs(learned.FEATURES) do keys[#keys + 1] = name end

    for _ = 1, epochs do
        for _, ex in ipairs(examples) do
            local fvs, p, ew = ex.features, ex.positive, (ex.weight or 1.0)
            if fvs and fvs[p] then
                for j = 1, #fvs do
                    if j ~= p then
                        local margin = learned.score_one(w, fvs[p]) - learned.score_one(w, fvs[j])
                        local g = -sigmoid(-margin) * ew   -- dLoss/dmargin
                        for _, k in ipairs(keys) do
                            local fp = (k == "bias") and 1 or (fvs[p][k] or 0)
                            local fj = (k == "bias") and 1 or (fvs[j][k] or 0)
                            local grad = g * (fp - fj) + l2 * (w[k] - w0[k])
                            w[k] = w[k] - lr * grad
                        end
                    end
                end
            end
        end
    end
    return w
end

-- Mean pairwise logistic loss (for monitoring convergence).
function M.loss(weights, examples)
    local total, n = 0, 0
    for _, ex in ipairs(examples) do
        local fvs, p = ex.features, ex.positive
        if fvs and fvs[p] then
            for j = 1, #fvs do
                if j ~= p then
                    local margin = learned.score_one(weights, fvs[p]) - learned.score_one(weights, fvs[j])
                    total = total + math.log(1 + math.exp(-math.max(-30, math.min(30, margin))))
                    n = n + 1
                end
            end
        end
    end
    return n > 0 and (total / n) or 0
end

-- --- versioned artifact --------------------------------------------------
function M.load_artifact()
    local f = io.open(PATH, "r")
    if not f then return { current = nil, previous = nil, versions = {}, order = {} } end
    local s = f:read("*a"); f:close()
    return cjson.decode(s) or { current = nil, previous = nil, versions = {}, order = {} }
end

function M.save_artifact(a)
    local f = io.open(PATH, "w"); if not f then return false end
    f:write(cjson.encode(a)); f:close(); return true
end

function M.save_version(weights, meta)
    local a = M.load_artifact()
    a.order = a.order or {}
    local id = "v" .. (#a.order + 1)
    a.versions[id] = {
        weights = weights,
        score   = meta and meta.score or nil,
        note    = meta and meta.note or nil,
        created = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    a.order[#a.order + 1] = id
    M.save_artifact(a)
    learned.reset_cache()
    return id
end

function M.promote(id)
    local a = M.load_artifact()
    if not a.versions[id] then return nil, "promote: no such version " .. tostring(id) end
    a.previous = a.current
    a.current  = id
    M.save_artifact(a)
    learned.reset_cache()
    return true
end

function M.rollback()
    local a = M.load_artifact()
    if not a.previous then return nil, "rollback: no previous version" end
    a.current, a.previous = a.previous, a.current
    M.save_artifact(a)
    learned.reset_cache()
    return a.current
end

function M.load_current()
    local a = M.load_artifact()
    if a.current and a.versions[a.current] then return a.versions[a.current].weights end
    return nil
end

return M
