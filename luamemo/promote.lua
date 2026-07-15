-- luamemo.promote  (Phase 11 — per-scope promotion harness)
--
-- Closes the learned-from-usage loop safely, per scope:
--   harvest feedback triples → build (features, positive) training examples by
--   re-running retrieval → split train/gate → train the reranker → GATE on the
--   held-out split → promote the new weights ONLY if they beat the incumbent on
--   the gate, else reject. Every attempt is audited in lm_promotion_runs.
--
-- Weights are stored per-scope in the DB (luamemo.learner_store), so a scope with
-- enough signal activates its OWN reranker, and the org can later sync weights
-- down (Phase 12). Bounded by feedback volume — a no-op until enough labeled
-- signal exists (by design). Never throws.
--
-- Reuses the exact feature-prep the offline bench validated: search → set
-- reuse_count → rerankers.learned.pool_features → find the positive's rank.

local M = {}

-- Build (features, positive) examples from harvested triples by re-running search.
local function build_examples(scope, triples, opts)
    local store   = require("luamemo.store")
    local learned = require("luamemo.rerankers.learned")
    -- reuse feature: how often each memory is a labelled positive across triples.
    local reuse = {}
    for _, t in ipairs(triples) do
        if t.positive then reuse[t.positive] = (reuse[t.positive] or 0) + 1 end
    end
    local cand = tonumber(opts.candidate_limit) or 20
    local examples = {}
    for _, t in ipairs(triples) do
        if t.query and t.positive then
            local rows = store.search({
                query = t.query, scope = scope, limit = cand,
                skip_temporal = true, skip_observations = true, rerank = false,
            })
            if rows and #rows > 0 then
                for _, r in ipairs(rows) do r.reuse_count = reuse[r.id] or 0 end
                local p
                for i, r in ipairs(rows) do
                    if tonumber(r.id) == tonumber(t.positive) then p = i; break end
                end
                if p then
                    examples[#examples + 1] = {
                        features = learned.pool_features(rows), positive = p, weight = t.weight or 1.0,
                    }
                end
            end
        end
    end
    return examples
end

-- Deterministic held-out split (every Nth example → gate). No RNG, so a run is
-- reproducible and the gate is a true hold-out (never trained on).
local function split(examples, gate_frac)
    local every = math.max(2, math.floor(1 / (tonumber(gate_frac) or 0.3)))
    local train, gate = {}, {}
    for i, ex in ipairs(examples) do
        if (i % every) == 0 then gate[#gate + 1] = ex else train[#train + 1] = ex end
    end
    return train, gate
end

--- run(scope, opts) -> decision table. opts: min_samples(20), margin(0.0),
--- gate_frac(0.3), epochs/lr/l2 (trainer), candidate_limit(20), harvest_limit,
--- dry_run (train + gate but never promote). Decision ∈ skip|promote|reject.
function M.run(scope, opts)
    opts = opts or {}
    local kind = "reranker"
    local out  = { scope = scope, kind = kind, decision = "skip" }
    if type(scope) ~= "string" or scope == "" then out.reason = "scope required"; return out end

    local ok_fb, feedback = pcall(require, "luamemo.feedback")
    local ok_tr, trainer  = pcall(require, "luamemo.rerank_train")
    local ok_ls, lstore   = pcall(require, "luamemo.learner_store")
    if not (ok_fb and ok_tr and ok_ls) then out.reason = "deps unavailable"; return out end

    local min_samples = tonumber(opts.min_samples) or 20
    local margin      = tonumber(opts.margin) or 0.0

    local ok_h, triples = pcall(feedback.harvest, scope, { limit = opts.harvest_limit })
    if not ok_h or type(triples) ~= "table" then out.reason = "harvest failed"; return out end

    local ok_b, examples = pcall(build_examples, scope, triples, opts)
    if not ok_b or type(examples) ~= "table" then out.reason = "example build failed"; return out end
    out.n_examples = #examples
    if #examples < min_samples then
        out.reason = string.format("insufficient examples (%d < %d)", #examples, min_samples)
        lstore.record_run(scope, kind, "skip", { note = out.reason, n_train = #examples })
        return out
    end

    local train, gate = split(examples, opts.gate_frac)
    if #train == 0 or #gate == 0 then
        out.reason = "train/gate split empty"
        lstore.record_run(scope, kind, "skip", { note = out.reason, n_train = #train, n_gate = #gate })
        return out
    end

    local new_w = trainer.train(train, { epochs = opts.epochs, lr = opts.lr, l2 = opts.l2 })
    -- Incumbent = the scope's current promoted weights, else the shrink-to-prior
    -- baseline (so the very first promotion must still beat "do nothing").
    local incumbent = lstore.load_current(scope, kind) or trainer.prior()

    -- Gate: mean pairwise logistic loss on the held-out split (LOWER is better).
    local new_loss = trainer.loss(new_w, gate)
    local inc_loss = trainer.loss(incumbent, gate)
    out.new_score, out.incumbent_score = new_loss, inc_loss
    out.n_train, out.n_gate = #train, #gate

    if opts.dry_run then
        out.decision = (new_loss < inc_loss - margin) and "would-promote" or "would-reject"
        return out
    end

    if new_loss < (inc_loss - margin) then
        local version, verr = lstore.save_version(scope, kind, new_w, { score = new_loss, note = opts.note })
        if version then
            lstore.promote(scope, kind, version)
            out.decision, out.version = "promote", version
        else
            out.decision, out.reason = "reject", "save failed: " .. tostring(verr)
        end
    else
        out.decision = "reject"
        out.reason = string.format("gate not beaten (new loss %.4f >= incumbent %.4f)", new_loss, inc_loss)
    end
    lstore.record_run(scope, kind, out.decision, {
        new_score = new_loss, incumbent_score = inc_loss,
        n_train = #train, n_gate = #gate, version = out.version, note = out.reason,
    })
    return out
end

return M
