-- luamemo.rerank_train  (Phase 4 — the learned reranker's trainer)
--
-- Trains the linear learned reranker (luamemo.rerankers.learned) by pairwise
-- learning-to-rank on feedback triples: for each labelled query, the positive
-- (a reinforced/gold memory) should outscore the negatives (the other pool
-- candidates). Logistic pairwise loss, SGD, L2-regularised toward the PRIOR
-- (rank-by-baseline-score), so an untrained/tiny model stays ~= today. Models are
-- gated and stored per scope by luamemo.promote.

local learned = require("luamemo.rerankers.learned")

local M = {}

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

return M
