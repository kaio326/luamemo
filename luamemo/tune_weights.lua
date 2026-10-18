-- luamemo.tune_weights
--
-- Sweep `hybrid_weights = { vector = wv, fts = wf }` blends across a
-- scope and report which blend best surfaces the right row in top-K.
--
-- Why this exists: the library's primary use is feeding rows into agent
-- prompts. A trustworthy top-K lets the agent safely lower K, which
-- directly cuts prompt-token spend per turn. The default 0.7/0.3 blend
-- is a guess; the right blend is corpus-specific.
--
-- Method: leave-one-out self-retrieval. For each sampled row we build a
-- query (the title when usable, otherwise the first 60% of the body),
-- run search at every blend in the grid, and check whether the source
-- row's id appears in top-K. R@K, MRR, and a recommended blend fall
-- straight out of the counts.
--
-- This is FREE: no LLM calls, no external dataset, no labels. The user's
-- own writes are the gold pairs.
--
--   M.run(opts)        → the sweep
--   M.recommend(opts)  → what `memo tune-weights` and MCP memory_tune_weights report:
--                        the sweep with the blend in force added, the best blend, its gain,
--                        and the command that applies it (a person changes the setting)
--   M.format(report)   → that report as text

local store = require("luamemo.store")
local db    = require("luamemo.db")

local M = {}

local DEFAULT_BLENDS = {
    { 1.0, 0.0 }, { 0.9, 0.1 }, { 0.8, 0.2 }, { 0.7, 0.3 },
    { 0.6, 0.4 }, { 0.5, 0.5 }, { 0.4, 0.6 }, { 0.3, 0.7 },
    { 0.2, 0.8 }, { 0.1, 0.9 }, { 0.0, 1.0 },
}
local DEFAULT_KS = { 1, 3, 5, 10 }
local DEFAULT_SAMPLE_SIZE = 50
local MIN_TITLE_CHARS = 8

local function _table_name()
    return store.table_name()
end

-- Build a query string + gold-id pair from a row. Returns nil when the
-- row has neither a usable title nor a usable body (those rows are
-- skipped in the sweep).
local function _query_for_row(row)
    local title = row.title or ""
    if #title >= MIN_TITLE_CHARS then return title end
    local body = row.body or ""
    if #body < MIN_TITLE_CHARS then return nil end
    -- First 60% of body, capped at 200 chars to keep FTS fair.
    local cut = math.max(MIN_TITLE_CHARS, math.floor(#body * 0.6))
    if cut > 200 then cut = 200 end
    return require("luamemo.util").cut_utf8(body, cut)
end

-- ORDER BY random() is fine here: we sweep at most ~50 rows by default
-- and this only runs ad-hoc (eval / CLI), never on a hot path.
local function _sample_rows(scope, sample_size)
    local n = math.max(1, math.floor(sample_size))
    local rows, err
    if scope then
        rows, err = db.query("SELECT id, title, body FROM " .. _table_name() .. " WHERE scope = ? "
            .. "ORDER BY random() LIMIT ?", scope, n)
    else
        rows, err = db.query("SELECT id, title, body FROM " .. _table_name() .. " ORDER BY random() LIMIT ?", n)
    end
    if not rows then return nil, "tune_weights: sample query failed: " .. tostring(err) end
    return rows
end

-- Approximate token count from char count (~4 chars per token, English).
local function _approx_tokens(s) return math.ceil((#(s or "")) / 4) end

-- Evaluate one blend against the prepared queries. Returns r_at[k]
-- counts and a sum of reciprocal ranks (turned into MRR by the caller).
local function _eval_blend(queries, scope, wv, wf, k_max, ks)
    local hits = {}
    for _, k in ipairs(ks) do hits[k] = 0 end
    local mrr_sum = 0
    local errs = 0

    for _, q in ipairs(queries) do
        local results, serr = store.search({
            query          = q.query,
            scope          = scope,
            limit          = k_max,
            hybrid_weights = { vector = wv, fts = wf },
            ignore_decay   = true,
            skip_feedback  = true,   -- evaluation probe, not a user retrieval
        })
        if not results then
            errs = errs + 1
        else
            local rank = nil
            for i, r in ipairs(results) do
                if r.id == q.gold_id then rank = i; break end
            end
            if rank then
                mrr_sum = mrr_sum + (1.0 / rank)
                for _, k in ipairs(ks) do
                    if rank <= k then hits[k] = hits[k] + 1 end
                end
            end
        end
    end

    local n = #queries
    local r_at = {}
    for _, k in ipairs(ks) do
        r_at[k] = (n > 0) and (hits[k] / n) or 0
    end
    return {
        wv = wv, wf = wf,
        r_at = r_at,
        mrr  = (n > 0) and (mrr_sum / n) or 0,
        errors = errs,
    }
end

-- Public entry point.
function M.run(opts)
    opts = opts or {}
    local scope         = opts.scope
    local sample_size   = tonumber(opts.sample_size) or DEFAULT_SAMPLE_SIZE
    local ks            = opts.ks or DEFAULT_KS
    local blends        = opts.blends or DEFAULT_BLENDS
    local primary       = opts.primary_metric or "r_at_1"

    -- 1. Sample rows.
    local rows, serr = _sample_rows(scope, sample_size)
    if not rows then return nil, serr end
    if #rows < 5 then
        return nil, ("tune_weights: scope %q has too few rows (%d < 5) to be meaningful"):format(
            tostring(scope or "<all>"), #rows)
    end

    -- 2. Build (query, gold_id) pairs; skip rows with no usable text.
    local queries = {}
    local total_tokens = 0
    local n_rows = 0
    for _, r in ipairs(rows) do
        local q = _query_for_row(r)
        if q then
            queries[#queries + 1] = { query = q, gold_id = r.id }
            total_tokens = total_tokens + _approx_tokens(r.title) + _approx_tokens(r.body)
            n_rows = n_rows + 1
        end
    end
    if #queries < 5 then
        return nil, ("tune_weights: only %d sampled rows have usable text (need >= 5)"):format(#queries)
    end

    local k_max = 0
    for _, k in ipairs(ks) do if k > k_max then k_max = k end end

    -- 3. Sweep blends.
    local out_blends = {}
    for _, b in ipairs(blends) do
        out_blends[#out_blends + 1] = _eval_blend(queries, scope, b[1], b[2], k_max, ks)
    end

    -- 4. Pick best by primary metric. Tie-break on MRR.
    local function score_of(b)
        if primary == "mrr" then return b.mrr end
        local k = tonumber((primary:match("^r_at_(%d+)$"))) or 1
        return b.r_at[k] or 0
    end
    local best = out_blends[1]
    for _, b in ipairs(out_blends) do
        local s, sb = score_of(b), score_of(best)
        if s > sb or (s == sb and b.mrr > best.mrr) then best = b end
    end

    -- 5. Estimate "safe K" — the smallest K where best blend's R@K >= 0.85.
    -- That's the K the agent can switch to without losing answers.
    local safe_k = nil
    table.sort(ks)
    for _, k in ipairs(ks) do
        if (best.r_at[k] or 0) >= 0.85 then safe_k = k; break end
    end

    return {
        scope        = scope,
        n_queries    = #queries,
        n_sampled    = #rows,
        k_max        = k_max,
        ks           = ks,
        blends       = out_blends,
        best         = {
            wv          = best.wv,
            wf          = best.wf,
            r_at        = best.r_at,
            mrr         = best.mrr,
            metric_name = primary,
            metric_value= score_of(best),
        },
        safe_k       = safe_k,
        avg_row_tokens = math.floor(total_tokens / math.max(1, n_rows)),
    }
end

-- ---------------------------------------------------------------------------
-- recommend / format — the CLI and MCP report
-- ---------------------------------------------------------------------------
local METRICS = { r_at_1 = true, r_at_3 = true, r_at_5 = true, r_at_10 = true, mrr = true }

local function same(a, b) return math.abs(a - b) < 1e-9 end

--- opts: scope (required), samples (5–1000, default 50), metric (r_at_1 | r_at_3 |
--- r_at_5 | r_at_10 | mrr, default r_at_1), in_force ({ vector, fts }: the blend in
--- force, added to the grid when it isn't on it). → report | nil, err
function M.recommend(opts)
    opts = opts or {}
    local scope = opts.scope
    if type(scope) ~= "string" or scope == "" then return nil, "tune-weights: a scope is required" end
    local samples = tonumber(opts.samples) or DEFAULT_SAMPLE_SIZE
    if samples ~= math.floor(samples) or samples < 5 or samples > 1000 then
        return nil, "tune-weights: samples must be a whole number from 5 to 1000"
    end
    local metric = opts.metric or "r_at_1"
    if not METRICS[metric] then
        return nil, "tune-weights: metric must be r_at_1, r_at_3, r_at_5, r_at_10 or mrr, not " .. tostring(metric)
    end
    local cur = opts.in_force or { vector = 0.7, fts = 0.3 }
    local cv, cf = tonumber(cur.vector) or 0, tonumber(cur.fts) or 0
    local grid, on_grid = {}, false
    for _, b in ipairs(DEFAULT_BLENDS) do
        grid[#grid + 1] = b
        if same(b[1], cv) and same(b[2], cf) then on_grid = true end
    end
    if not on_grid then grid[#grid + 1] = { cv, cf } end

    local res, err = M.run({ scope = scope, sample_size = samples, primary_metric = metric, blends = grid })
    if not res then return nil, err end

    local function row(b)
        return { vector = b.wv, fts = b.wf, r_at_1 = b.r_at[1], r_at_3 = b.r_at[3], r_at_5 = b.r_at[5],
                 r_at_10 = b.r_at[10], mrr = b.mrr,
                 in_force = (same(b.wv, cv) and same(b.wf, cf)) or nil }
    end
    local rows, in_force = {}, nil
    for _, b in ipairs(res.blends) do
        local r = row(b)
        rows[#rows + 1] = r
        if r.in_force then in_force = r end
    end
    table.sort(rows, function(a, b)
        if a[metric] ~= b[metric] then return a[metric] > b[metric] end
        if a.mrr ~= b.mrr then return a.mrr > b.mrr end
        return a.vector > b.vector
    end)
    local best = rows[1]
    -- The blend in force stays when nothing beats it on the metric.
    if in_force and in_force[metric] >= best[metric] then best = in_force end
    local safe_k
    for _, k in ipairs({ 1, 3, 5, 10 }) do
        if (best["r_at_" .. k] or 0) >= 0.85 then safe_k = k; break end
    end
    local settings = require("luamemo.settings")
    local weights = settings.format(settings.get("hybrid_weights"), { vector = best.vector, fts = best.fts })
    return {
        scope = scope, metric = metric, memories_searched = res.n_queries, blends = rows,
        best = best, in_force = in_force, safe_k = safe_k,
        apply = (best ~= in_force) and ("memo config set MEMO_HYBRID_WEIGHTS '%s'"):format(weights) or nil,
    }
end

--- The report as text (memo tune-weights).
function M.format(r)
    local function pct(x) return ("%5.1f%%"):format((x or 0) * 100) end
    local label = r.metric == "mrr" and "MRR" or ("R@" .. r.metric:match("%d+"))
    local out = {
        ("%s — %d memories, each searched for by its title (or the start of its body) at %d blends, "
            .. "no model calls")
            :format(r.scope, r.memories_searched, #r.blends),
        "",
        "vector   fts     R@1     R@3     R@5    R@10    MRR",
    }
    for _, b in ipairs(r.blends) do
        out[#out + 1] = ("%5.2f  %5.2f  %s  %s  %s  %s  %5.3f%s"):format(b.vector, b.fts, pct(b.r_at_1),
            pct(b.r_at_3), pct(b.r_at_5), pct(b.r_at_10), b.mrr, b.in_force and "   ← in force" or "")
    end
    out[#out + 1] = ""
    local function val(b) return r.metric == "mrr" and ("%.3f"):format(b.mrr) or pct(b[r.metric]):gsub("^%s+", "") end
    if not r.apply then
        out[#out + 1] = ("The blend in force is the best for %s on this scope (%s)."):format(label, val(r.best))
    else
        local gain = r.in_force and (r.metric == "mrr" and (" (%+.3f over the blend in force)"):format(
            r.best.mrr - r.in_force.mrr) or (" (%+.1f points over the blend in force)"):format(
            (r.best[r.metric] - r.in_force[r.metric]) * 100)) or ""
        out[#out + 1] = ("Best for %s: vector %.2f / fts %.2f — %s%s"):format(label, r.best.vector, r.best.fts,
            val(r.best), gain)
    end
    if r.safe_k then
        out[#out + 1] = ("Safe K: %d — the fewest results that still hold the right memory 85%% of the time."):format(r.safe_k)
    else
        out[#out + 1] = "Safe K: none — no blend finds the right memory 85% of the time within 10 results; "
            .. "a stronger embedder helps more than any blend (EMBEDDERS.md)."
    end
    if r.apply then out[#out + 1] = "Apply it: " .. r.apply end
    return table.concat(out, "\n")
end

return M
