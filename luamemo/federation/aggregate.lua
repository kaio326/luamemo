-- luamemo.federation.aggregate
-- Org central: turn the feedback every dev pushed into org-wide learning.
--
--   aggregate.run(opts) → report | nil, err
--     1. digest the org scope — consolidation of tier-0 observations + tier
--        promotion over the aggregated reinforcements (the policy caps
--        everything below the core tier; directives are never touched);
--     2. the Phase-11 promotion harness on the org scope's aggregated triples,
--        with one extra gate — the DIRECTIVES gate — before any new reranker
--        can be promoted (and so pulled down by every dev).
--   opts: dry_run, min_samples, margin, directive_k (default 3), skip_digest
--
-- Directives gate: every directive (tier 3) is probed with its own title; a
-- candidate reranker is rejected if it pushes ANY directive out of the top-k
-- that the incumbent keeps it in. Collective learning may inform the ranking,
-- never override the org's standards.

local db     = require("luamemo.db")
local policy = require("luamemo.federation.policy")

local M = {}

M.DIRECTIVE_K = 3
M.MAX_DIRECTIVES = 500          -- probes per gate run (bounded cost)

-- Rank (1-based) of the positive under `weights` (ties rank the positive first).
local function rank_of(learned, weights, ex)
    local sp = learned.score_one(weights, ex.features[ex.positive])
    local r = 1
    for j, fv in ipairs(ex.features) do
        if j ~= ex.positive and learned.score_one(weights, fv) > sp then r = r + 1 end
    end
    return r
end

--- Probe examples: one per directive whose unreranked candidate pool contains it.
function M.directive_probes(scope, reuse, opts)
    opts = opts or {}
    local store   = require("luamemo.store")
    local learned = require("luamemo.rerankers.learned")
    local rows = db.query("SELECT id, title FROM lm_memories WHERE scope = ? AND tier = 3 "
        .. "ORDER BY id LIMIT ?", scope, M.MAX_DIRECTIVES) or {}
    local probes, unreachable = {}, 0
    for _, d in ipairs(rows) do
        local hits = (d.title and d.title ~= "") and store.search({
            query = d.title, scope = scope, limit = tonumber(opts.candidate_limit) or 20,
            skip_temporal = true, skip_observations = true, rerank = false, skip_feedback = true }) or {}
        local p
        for i, h in ipairs(hits) do
            h.reuse_count = (reuse and reuse[tonumber(h.id)]) or 0
            if tonumber(h.id) == tonumber(d.id) then p = i end
        end
        if p and #hits > 1 then
            probes[#probes + 1] = { id = tonumber(d.id), title = d.title,
                                    features = learned.pool_features(hits), positive = p }
        elseif not p then
            unreachable = unreachable + 1     -- a retrieval miss no reranker can fix
        end
    end
    return probes, unreachable
end

--- The gate (promote.run `gates` entry): ctx = { scope, candidate, incumbent, reuse, opts }.
function M.directives_gate(ctx)
    local learned = require("luamemo.rerankers.learned")
    local k = math.max(1, math.floor(tonumber(ctx.opts and ctx.opts.directive_k) or M.DIRECTIVE_K))
    local probes, unreachable = M.directive_probes(ctx.scope, ctx.reuse, ctx.opts)
    if #probes == 0 then
        return true, ("no directive probes (%d unreachable by retrieval)"):format(unreachable)
    end
    local hit_new, hit_inc, demoted = 0, 0, {}
    for _, ex in ipairs(probes) do
        local rn, ri = rank_of(learned, ctx.candidate, ex), rank_of(learned, ctx.incumbent, ex)
        if rn <= k then hit_new = hit_new + 1 end
        if ri <= k then hit_inc = hit_inc + 1 end
        if ri <= k and rn > k then demoted[#demoted + 1] = ("%q (rank %d → %d)"):format(ex.title, ri, rn) end
    end
    local info = ("directive recall@%d %d/%d (incumbent %d/%d)"):format(k, hit_new, #probes, hit_inc, #probes)
    if #demoted > 0 then
        local shown = {}
        for i = 1, math.min(3, #demoted) do shown[i] = demoted[i] end
        return false, info .. "; demotes " .. table.concat(shown, ", ") .. (#demoted > 3 and ", …" or "")
    end
    return true, info
end

local function count(sql, ...)
    return tonumber((db.value(sql, ...))) or 0
end

--- Feedback the central holds for its org scope (pushed by devs).
function M.feedback_summary(scope)
    return {
        events     = count("SELECT count(*) FROM lm_reinforcements WHERE scope = ?", scope),
        retrievals = count("SELECT count(*) FROM lm_retrieval_feedback WHERE scope = ?", scope),
        devs       = count("SELECT count(DISTINCT source) FROM (SELECT source FROM lm_reinforcements "
            .. "WHERE scope = ? AND source IS NOT NULL UNION SELECT source FROM "
            .. "lm_retrieval_feedback WHERE scope = ? AND source IS NOT NULL) s", scope, scope),
    }
end

function M.run(opts)
    opts = opts or {}
    if policy.role() ~= "org" then
        return nil, "aggregate: this instance is not an org central (set MEMO_ROLE=org + MEMO_ORG_NAME)"
    end
    local scope = require("luamemo.federation.central").org_scope()
    if not scope then return nil, "aggregate: org_name is not set" end
    local report = { scope = scope, dry_run = opts.dry_run and true or false,
                     feedback = M.feedback_summary(scope) }
    if not opts.skip_digest then
        local ok, res = pcall(require("luamemo.digest").run, scope, { dry_run = opts.dry_run })
        report.digest = ok and res or { errors = { tostring(res) } }
    end
    report.promotion = require("luamemo.promote").run(scope, {
        dry_run = opts.dry_run, min_samples = opts.min_samples, margin = opts.margin,
        directive_k = opts.directive_k, note = "org aggregate",
        gates = { { name = "directives", fn = M.directives_gate } },
    })
    return report
end

return M
