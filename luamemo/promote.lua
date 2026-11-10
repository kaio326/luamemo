-- luamemo.promote  (Phase 11 — per-scope promotion harness)
--
-- Closes the learned-from-usage loop safely, per scope:
--   harvest feedback triples → build (features, positive) training examples by
--   re-running retrieval → split train/gate → train the reranker → GATE on the
--   held-out split and on probes → promote the new weights ONLY if they beat the
--   incumbent and find at least as many memories by their own titles, else reject.
--   Every attempt is audited in lm_promotion_runs (a dry run changes nothing).
--
-- Weights are stored per-scope in the DB (luamemo.learner_store), so a scope with
-- enough signal activates its OWN reranker, and the org can later sync weights
-- down (Phase 12). Bounded by feedback volume — a no-op until enough labeled
-- signal exists (by design). Never throws.
--
-- The examples and the gate go through learned.pool, the one path that builds what search shows the model. An example's
-- confirmation count is as of when its search ran (the label's `at`); the rest of its pool is rebuilt from today's memories.

local util = require("luamemo.util")

local M = {}

-- Build (features, positive) examples from harvested triples by re-running search.
local function build_examples(scope, triples, opts)
    local learned  = require("luamemo.rerankers.learned")
    local temporal = require("luamemo.temporal")
    local examples = {}
    for _, t in ipairs(triples) do
        -- (a query with a time in it: its pool depends on when it ran, so it cannot be rebuilt)
        if t.query and t.positive and not temporal.parse(t.query) then
            local rows = learned.pool(scope, t.query, opts, t.at)
            local ex = rows and #rows > 1 and learned.example(rows, t.positive, t.weight)   -- (a pool of one ranks nothing)
            if ex then
                ex.query = t.query
                examples[#examples + 1] = ex
            end
        end
    end
    return examples
end

-- Deterministic held-out split, by a hash of the query: one query is never on both sides (a gate must not be asked
-- what training was shown). No RNG, so a run is reproducible and the gate is a true hold-out (never trained on).
local function split(examples, gate_frac)
    local every = math.max(2, math.floor(1 / (tonumber(gate_frac) or 0.3)))
    local train, held_out = {}, {}
    for _, ex in ipairs(examples) do
        if util.djb2(tostring(ex.query)) % every == 0 then held_out[#held_out + 1] = ex else train[#train + 1] = ex end
    end
    return train, held_out
end
M._split = split   -- tests

-- Gates (pluggable): each { name, fn } where fn(ctx) → pass, info. ctx =
-- { scope, candidate, incumbent, opts }. A gate that raises fails closed.
local function run_gates(gates, ctx)
    local results = {}
    for i, g in ipairs(gates or {}) do
        local name = (type(g) == "table" and g.name) or ("gate" .. i)
        local fn   = (type(g) == "table") and g.fn or g
        local ok, pass, info = pcall(fn, ctx)
        if not ok then pass, info = false, "gate error: " .. tostring(pass) end
        results[#results + 1] = { name = name, pass = pass and true or false, info = info }
        if not pass then return false, results, name end
    end
    return true, results
end

-- The last gate: a model must find at least as many memories first by their own titles as the incumbent.
local function make_probes_gate(probes, examples)
    return function(ctx)
        local new, inc = probes.count_first(ctx.candidate, examples), probes.count_first(ctx.incumbent, examples)
        return new >= inc, ("probe recall@1 %d/%d (incumbent %d/%d)"):format(new, #examples, inc, #examples)
    end
end

local function gates_note(gates)
    local parts = {}
    for _, g in ipairs(gates or {}) do parts[#parts + 1] = g.name .. ": " .. tostring(g.info) end
    return #parts > 0 and table.concat(parts, "; ") or nil
end

local function too_few_probes(n, min)
    return string.format("too few probes to check for harm (%d < %d: memories with a title that nobody has confirmed useful)", n, min)
end

--- run(scope, opts) -> decision table. opts: min_samples(20), margin(0.0),
--- gate_frac(0.3), epochs/lr/l2 (trainer), harvest_limit, dry_run (train + gate but never promote, and nothing audited),
--- gates (extra promotion gates — see run_gates; all must pass after the loss gate, before the probes),
--- reuse = false (train without confirmation counts), note (version note).
--- Decision ∈ skip|promote|reject (would-promote|would-reject on a dry run).
function M.run(scope, opts)
    opts = opts or {}
    local kind = "reranker"
    local out  = { scope = scope, kind = kind, decision = "skip" }
    if type(scope) ~= "string" or scope == "" then out.reason = "scope required"; return out end

    local ok_fb, feedback = pcall(require, "luamemo.feedback")
    local ok_tr, trainer  = pcall(require, "luamemo.rerank_train")
    local ok_ls, lstore   = pcall(require, "luamemo.learner_store")
    local ok_le, learned  = pcall(require, "luamemo.rerankers.learned")
    local ok_pr, probes   = pcall(require, "luamemo.probes")
    if not (ok_fb and ok_tr and ok_ls and ok_le and ok_pr) then out.reason = "deps unavailable"; return out end

    local function skip(reason, meta)
        out.reason = reason
        if not opts.dry_run then
            meta.note = reason
            lstore.record_run(scope, kind, "skip", meta)
        end
        return out
    end
    local function failed(what, err)
        out.reason = what .. " failed: " .. tostring(err)
        return out
    end

    local min_samples = tonumber(opts.min_samples) or 20
    local margin      = tonumber(opts.margin) or 0.0

    local ok_h, triples = pcall(feedback.harvest, scope, { limit = opts.harvest_limit })
    if not ok_h or type(triples) ~= "table" then out.reason = "harvest failed"; return out end

    -- (one query, before the search each label costs: is there anything to check a model against?)
    local train_rows, gate_rows
    if #triples >= min_samples then
        local ok_s, a, b = pcall(probes.sample, scope)
        if not ok_s then return failed("probes", a) end
        train_rows, gate_rows = a, b
        if #gate_rows < probes.MIN_GATE then return skip(too_few_probes(#gate_rows, probes.MIN_GATE), {}) end
    end

    local ok_b, examples = pcall(build_examples, scope, triples, opts)
    if not ok_b or type(examples) ~= "table" then return failed("example build", examples) end
    out.n_examples = #examples
    if #examples < min_samples then
        return skip(string.format("insufficient examples (%d < %d)", #examples, min_samples), { n_train = #examples })
    end

    local train, held_out = split(examples, opts.gate_frac)
    if #train == 0 or #held_out == 0 then
        return skip("train/gate split empty", { n_train = #train, n_gate = #held_out })
    end

    local ok_t, train_probes = pcall(probes.examples, scope, train_rows, opts)
    if not ok_t then return failed("probes", train_probes) end

    local fit = {}
    for _, list in ipairs({ train, train_probes }) do
        for _, ex in ipairs(list) do fit[#fit + 1] = ex end
    end
    local new_w = trainer.train(fit, { epochs = opts.epochs, lr = opts.lr, l2 = opts.l2 })
    -- Incumbent = the scope's model that search serves, else the shrink-to-prior
    -- baseline (so the very first promotion must still beat "do nothing").
    local incumbent = learned.served_model(scope) or trainer.prior()

    -- Gate: mean pairwise logistic loss on the held-out split (LOWER is better).
    local new_loss = trainer.loss(new_w, held_out)
    local inc_loss = trainer.loss(incumbent, held_out)
    out.new_score, out.incumbent_score = new_loss, inc_loss
    out.n_train, out.n_gate = #train, #held_out
    local beats = new_loss < (inc_loss - margin)

    if beats then
        -- (only now: each probe is a search, and a model that lost on the labels has no use for them)
        local ok_g, gate_probes = pcall(probes.examples, scope, gate_rows, opts)
        if not ok_g then return failed("probes", gate_probes) end
        out.n_probes = #gate_probes
        if #gate_probes < probes.MIN_GATE then
            return skip(too_few_probes(#gate_probes, probes.MIN_GATE), { n_train = #train, n_gate = #held_out })
        end
        local gates = {}
        for _, g in ipairs(opts.gates or {}) do gates[#gates + 1] = g end
        gates[#gates + 1] = { name = "probes", fn = make_probes_gate(probes, gate_probes) }
        local gates_ok, results, failed_gate = run_gates(gates, { scope = scope, candidate = new_w, incumbent = incumbent, opts = opts })
        out.gates = results
        if not gates_ok then
            out.reason = ("%s gate failed: %s"):format(failed_gate, tostring(results[#results].info or "?"))
        end
    else
        out.reason = string.format("gate not beaten (new loss %.4f >= incumbent %.4f)", new_loss, inc_loss)
    end

    if opts.dry_run then
        out.decision = out.reason and "would-reject" or "would-promote"
        return out
    end

    if out.reason then
        out.decision = "reject"
    else
        new_w.format = learned.MODEL_FORMAT
        local version, verr = lstore.save_version(scope, kind, new_w, { score = new_loss, note = opts.note })
        if version then
            lstore.promote(scope, kind, version)
            out.decision, out.version = "promote", version
        else
            out.decision, out.reason = "reject", "save failed: " .. tostring(verr)
        end
    end
    lstore.record_run(scope, kind, out.decision, {
        new_score = new_loss, incumbent_score = inc_loss,
        n_train = #train, n_gate = #held_out, version = out.version, note = out.reason or gates_note(out.gates),
    })
    return out
end

return M
