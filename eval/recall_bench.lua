-- Phase 13.1 — Real-Embedder Recall Benchmark harness.
--
-- Measures recall@K + MRR for a configured embedder against the
-- LongMemEval-shaped synthetic surrogate (eval/_make_synthetic.lua).
-- One scope per question (`bench:<embedder>:<question_id>`) so haystacks
-- never bleed across questions; that mirrors the way agents would
-- actually scope memories at run time and isolates ranking quality from
-- cross-scope contamination.
--
-- The runner is **retrieval-side only**: a hit means the answer session
-- appeared in the top-K results, not that an LLM produced the right
-- answer. That isolates luamemo's contribution from the downstream
-- generator.
--
-- Usage:
--   PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=lm_bruteforce_test \
--     lua5.1 eval/recall_bench.lua \
--       --embedder hash --n 20 --out eval/results/recall_hash.json
--
-- Embedders:
--   hash    pure-Lua deterministic hash (zero deps; expected to be poor)
--   ollama  HTTP to local Ollama (set OLLAMA_URL, default
--           http://127.0.0.1:11434/api/embeddings; set OLLAMA_MODEL,
--           default nomic-embed-text)
--   openai  HTTP to OpenAI embeddings API (set OPENAI_API_KEY,
--           OPENAI_MODEL default text-embedding-3-small, embed_dim 1536)
--
-- Prereq for --embedder ollama:
--   ollama serve  &&  ollama pull nomic-embed-text
--
-- The synthetic corpus is auto-generated on first run by invoking
-- eval/_make_synthetic.lua; subsequent runs reuse the cached file.
--
-- CI mode (`--mode ci`) forces `--embedder hash` and asserts the
-- recall@K / MRR numbers against a locked-in baseline. Designed to run
-- in <5 s with no network deps so it can guard regressions in any CI
-- pipeline. Non-zero exit on metric drift beyond the configured
-- tolerance (default 0.001 absolute).

package.path = "./?.lua;./?/init.lua;eval/?.lua;eval/datasets/?.lua;" .. package.path

-- Preload a `resty.http` shim so HTTP embedders (Ollama / OpenAI) work
-- under plain `lua5.1`. The shim wraps LuaSocket; it is NOT loaded when
-- the embedder is `hash` (no HTTP traffic) and is harmless when unused.
package.preload["resty.http"] = function() return require("_resty_http_shim") end

local cjson = require("cjson.safe")

-- --- arg parsing ---------------------------------------------------------
local args = {
    embedder = "hash",
    n        = 20,
    k_max    = 20,
    out      = nil,
    corpus   = "eval/data/longmemeval_synthetic.json",
    mode     = "report",
    tol      = 0.001,
    diagnostics  = false,
    k_diag       = 100,
    paraphrase   = "none",   -- "none" | "det" | "ollama"
    paraphrase_n = 3,
}
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if     a == "--embedder" then args.embedder = arg[i + 1]; i = i + 2
        elseif a == "--n"        then args.n = tonumber(arg[i + 1]); i = i + 2
        elseif a == "--k-max"    then args.k_max = tonumber(arg[i + 1]); i = i + 2
        elseif a == "--out"      then args.out = arg[i + 1]; i = i + 2
        elseif a == "--corpus"   then args.corpus = arg[i + 1]; i = i + 2
        elseif a == "--mode"     then args.mode = arg[i + 1]; i = i + 2
        elseif a == "--tol"      then args.tol = tonumber(arg[i + 1]); i = i + 2
        elseif a == "--diagnostics"  then args.diagnostics = true; i = i + 1
        elseif a == "--k-diag"       then args.k_diag = tonumber(arg[i + 1]); i = i + 2
        elseif a == "--paraphrase"   then args.paraphrase = arg[i + 1]; i = i + 2
        elseif a == "--paraphrase-n" then args.paraphrase_n = tonumber(arg[i + 1]); i = i + 2
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
    end
end
if args.mode == "ci" then
    -- CI mode is deterministic: hash embedder only, full canonical corpus,
    -- locked baseline. Override any conflicting flags.
    args.embedder    = "hash"
    args.corpus      = "eval/data/longmemeval_synthetic.json"
    args.n           = nil  -- use every question in the corpus
    args.k_max       = 20
    args.diagnostics = false
    args.paraphrase  = "none"
end
args.out = args.out or ("eval/results/recall_" .. args.embedder .. ".json")

-- Locked-in baseline for `--mode ci`. Only the hash embedder + the
-- canonical synthetic corpus produce these numbers deterministically.
-- Update this block intentionally if and only if either changes.
local CI_BASELINE = {
    n_questions    = 33,
    ["recall@1"]   = 0.63636363636364,
    ["recall@5"]   = 0.87878787878788,
    ["recall@10"]  = 0.96969696969697,
    ["recall@20"]  = 1.0,
    mrr            = 0.74782162282162,
    median_rank    = 1,
    tail_misses    = 0,
}

-- --- corpus (auto-generate the synthetic surrogate on first use) ---------
local function ensure_corpus(path)
    local fh = io.open(path, "rb")
    if fh then fh:close(); return end
    io.write("corpus missing, generating " .. path .. " ... ")
    local cmd = "lua5.1 eval/_make_synthetic.lua " .. path
    local ok = os.execute(cmd)
    if ok ~= true and ok ~= 0 then
        io.stderr:write("\nfailed to run: " .. cmd .. "\n")
        os.exit(1)
    end
    print("done")
end
ensure_corpus(args.corpus)

-- luamemo.db creates a pgmoon connection automatically from
-- PGHOST / PGDATABASE / PGUSER / PGPASSWORD env vars when outside OpenResty.

local memory     = require("luamemo")
local db         = require("luamemo.db")
local longmemev  = require("longmemeval")
local paraphrase
if args.paraphrase ~= "none" then
    paraphrase = require("paraphrase")
end

-- --- embedder config -----------------------------------------------------
local setup_opts = {
    db_table         = "lm_memories",
    backend          = "auto",
    auth_fn          = function() return true end,
    skip_embed_probe = true,
    default_scope    = "bench:" .. args.embedder,
}
if args.embedder == "hash" then
    setup_opts.embedder_local = "hash"
    setup_opts.embed_dim      = 384
elseif args.embedder == "ollama" then
    setup_opts.embedder_url     = os.getenv("OLLAMA_URL")
        or "http://127.0.0.1:11434/api/embeddings"
    setup_opts.embedder_adapter = "ollama"
    setup_opts.embedder_model   = os.getenv("OLLAMA_MODEL") or "nomic-embed-text"
    setup_opts.embed_dim        = tonumber(os.getenv("OLLAMA_DIM") or "768")
elseif args.embedder == "openai" then
    local key = os.getenv("OPENAI_API_KEY")
    if not key or key == "" then
        io.stderr:write("OPENAI_API_KEY required for --embedder openai\n")
        os.exit(2)
    end
    setup_opts.embedder_url     = os.getenv("OPENAI_URL")
        or "https://api.openai.com/v1/embeddings"
    setup_opts.embedder_adapter = "openai"
    setup_opts.embedder_model   = os.getenv("OPENAI_MODEL") or "text-embedding-3-small"
    setup_opts.embedder_headers = { Authorization = "Bearer " .. key }
    setup_opts.embed_dim        = tonumber(os.getenv("OPENAI_DIM") or "1536")
else
    io.stderr:write("unknown --embedder: " .. tostring(args.embedder) .. "\n")
    os.exit(2)
end

memory.setup(setup_opts)

-- --- load + cap corpus ---------------------------------------------------
local rows = longmemev.load(args.corpus)
if args.n and args.n < #rows then
    local trimmed = {}
    for i = 1, args.n do trimmed[i] = rows[i] end
    rows = trimmed
end
print(string.format("embedder=%s  questions=%d  k_max=%d  backend=%s",
    args.embedder, #rows, args.k_max, memory.store.backend()))

-- --- helpers -------------------------------------------------------------
local function set_of(list)
    local s = {}
    for _, v in ipairs(list or {}) do s[v] = true end
    return s
end

-- Find rank (1-based) of any gold session_id in `results`. Returns
-- nil when none of the results match.
local function gold_rank(results, gold_set)
    for ri, r in ipairs(results) do
        local meta = r.metadata
        if type(meta) == "string" then meta = cjson.decode(meta) or {} end
        local sid = meta and meta.session_id
        if sid and gold_set[sid] then return ri end
    end
    return nil
end

-- Run a search and classify the outcome.
-- Returns: rank_in_kmax (or nil), classification string in:
--   "hit"                       - gold within args.k_max
--   "ranked_below_k"            - gold ranked > k_max but <= k_diag
--   "missing_from_candidates"   - gold not in top k_diag at all
local function search_and_classify(query, scope, gold_set)
    local limit = args.diagnostics and args.k_diag or args.k_max
    local results, serr = memory.search({
        query = query, scope = scope, limit = limit,
    })
    if not results then return nil, "missing_from_candidates", serr end
    local rank = gold_rank(results, gold_set)
    if not rank then return nil, "missing_from_candidates" end
    if rank <= args.k_max then return rank, "hit" end
    return rank, "ranked_below_k"
end

-- --- run -----------------------------------------------------------------
local per_question = {}
local sum_mrr      = 0
local hits         = { [1] = 0, [5] = 0, [10] = 0, [20] = 0 }
local rank_list    = {}   -- numeric ranks (for median); misses excluded
local miss_count   = 0
local fail_modes   = {
    hit                     = 0,
    ranked_below_k          = 0,
    missing_from_candidates = 0,
}
-- Paraphrase aggregates (only populated when args.paraphrase ~= "none").
local pp_hits       = { [1] = 0, [5] = 0, [10] = 0, [20] = 0 }
local pp_total      = 0
local pp_sum_mrr    = 0
local pp_fail_modes = {
    hit                     = 0,
    ranked_below_k          = 0,
    missing_from_candidates = 0,
}

local t_start = os.time()

for qi, q in ipairs(rows) do
    local scope = "bench:" .. args.embedder .. ":" .. tostring(q.question_id)
    -- Wipe scope so reruns are deterministic.
    db.query("DELETE FROM lm_memories WHERE scope = " .. db.escape_literal(scope))

    -- Write every haystack session as one memory.
    for sid, turns in pairs(q.haystack_sessions or {}) do
        local _, werr = memory.write({
            scope    = scope,
            kind     = "session",
            title    = sid,
            body     = longmemev.session_to_body(turns),
            metadata = { session_id = sid },
        })
        if not _ then
            io.stderr:write(("write failed for q=%s sess=%s: %s\n")
                :format(q.question_id, sid, tostring(werr)))
            os.exit(1)
        end
    end

    -- Search and rank.
    local gold = set_of(q.answer_session_ids)
    local rank, classification = search_and_classify(q.question, scope, gold)
    fail_modes[classification] = (fail_modes[classification] or 0) + 1

    if rank and rank <= args.k_max then
        sum_mrr = sum_mrr + (1 / rank)
        rank_list[#rank_list + 1] = rank
        for _, k in ipairs({ 1, 5, 10, 20 }) do
            if rank <= k then hits[k] = hits[k] + 1 end
        end
    else
        miss_count = miss_count + 1
    end

    -- Optional paraphrase robustness pass.
    if args.paraphrase == "det" then
        local variants = paraphrase.variants(q.question, args.paraphrase_n)
        for _, vq in ipairs(variants) do
            pp_total = pp_total + 1
            local r2, cls2 = search_and_classify(vq, scope, gold)
            pp_fail_modes[cls2] = (pp_fail_modes[cls2] or 0) + 1
            if r2 and r2 <= args.k_max then
                pp_sum_mrr = pp_sum_mrr + (1 / r2)
                for _, k in ipairs({ 1, 5, 10, 20 }) do
                    if r2 <= k then pp_hits[k] = pp_hits[k] + 1 end
                end
            end
        end
    end

    if qi % 10 == 0 or qi == #rows then
        io.write(string.format("\r  progress: %d/%d", qi, #rows)); io.flush()
    end
end
print("")

-- --- aggregate -----------------------------------------------------------
local function median(t)
    if #t == 0 then return nil end
    local sorted = {}
    for _, v in ipairs(t) do sorted[#sorted + 1] = v end
    table.sort(sorted)
    local mid = math.floor(#sorted / 2) + 1
    if #sorted % 2 == 1 then return sorted[mid] end
    return (sorted[mid - 1] + sorted[mid]) / 2
end

local n = #rows
local report = {
    embedder      = args.embedder,
    embed_dim     = setup_opts.embed_dim,
    backend       = memory.store.backend(),
    n_questions   = n,
    k_max         = args.k_max,
    corpus        = args.corpus,
    elapsed_sec   = os.time() - t_start,
    ["recall@1"]  = n > 0 and (hits[1]  / n) or 0,
    ["recall@5"]  = n > 0 and (hits[5]  / n) or 0,
    ["recall@10"] = n > 0 and (hits[10] / n) or 0,
    ["recall@20"] = n > 0 and (hits[20] / n) or 0,
    mrr           = n > 0 and (sum_mrr  / n) or 0,
    median_rank   = median(rank_list),
    tail_misses   = miss_count,
}

-- Diagnostic breakdown (failure-mode classification). Always populated;
-- without --diagnostics the "ranked_below_k" bucket is folded into
-- "missing_from_candidates" (because we never search past k_max).
report.by_failure_mode = {
    hit                     = fail_modes.hit,
    ranked_below_k          = fail_modes.ranked_below_k,
    missing_from_candidates = fail_modes.missing_from_candidates,
}
report.diagnostics_enabled = args.diagnostics or false
report.k_diag              = args.diagnostics and args.k_diag or nil

-- Paraphrase robustness block (when enabled).
if args.paraphrase ~= "none" and pp_total > 0 then
    report.paraphrase = {
        mode             = args.paraphrase,
        variants_per_q   = args.paraphrase_n,
        n_variants_total = pp_total,
        ["recall@1"]     = pp_hits[1]  / pp_total,
        ["recall@5"]     = pp_hits[5]  / pp_total,
        ["recall@10"]    = pp_hits[10] / pp_total,
        ["recall@20"]    = pp_hits[20] / pp_total,
        mrr              = pp_sum_mrr  / pp_total,
        by_failure_mode  = pp_fail_modes,
        -- Robustness ratio: paraphrase recall@5 divided by base recall@5.
        robustness_at_5  = (report["recall@5"] > 0)
            and ((pp_hits[5] / pp_total) / report["recall@5"]) or 0,
    }
end

-- Dominant-failure-mode one-liner.
do
    local order = { "missing_from_candidates", "ranked_below_k", "hit" }
    local worst, worst_count = "hit", 0
    for _, mode in ipairs(order) do
        if mode ~= "hit" and (fail_modes[mode] or 0) > worst_count then
            worst, worst_count = mode, fail_modes[mode]
        end
    end
    if worst_count > 0 then
        report.dominant_failure_mode = worst
        report.dominant_failure_count = worst_count
    end
end

-- --- output --------------------------------------------------------------
local function fmt_pct(x) return string.format("%5.1f%%", x * 100) end
print(string.rep("-", 64))
print(string.format("embedder      : %s (dim=%d, backend=%s)",
    report.embedder, report.embed_dim, report.backend))
print(string.format("questions     : %d   k_max=%d   elapsed=%ds",
    report.n_questions, report.k_max, report.elapsed_sec))
print(string.format("recall@1      : %s", fmt_pct(report["recall@1"])))
print(string.format("recall@5      : %s", fmt_pct(report["recall@5"])))
print(string.format("recall@10     : %s", fmt_pct(report["recall@10"])))
print(string.format("recall@20     : %s", fmt_pct(report["recall@20"])))
print(string.format("MRR           : %.3f", report.mrr))
print(string.format("median rank   : %s",
    report.median_rank and tostring(report.median_rank) or "n/a (all miss)"))
print(string.format("tail misses   : %d / %d", report.tail_misses, report.n_questions))

-- Failure-mode breakdown (always printed; informative even without --diagnostics).
print(string.format("by_failure    : hit=%d  ranked_below_k=%d  missing_from_candidates=%d",
    report.by_failure_mode.hit,
    report.by_failure_mode.ranked_below_k,
    report.by_failure_mode.missing_from_candidates))
if report.dominant_failure_mode then
    print(string.format(">>> dominant failure mode: %s (%d/%d questions)",
        report.dominant_failure_mode,
        report.dominant_failure_count,
        report.n_questions))
end

-- Paraphrase robustness block.
if report.paraphrase then
    local p = report.paraphrase
    print(string.rep("-", 64))
    print(string.format("paraphrase    : mode=%s  variants/q=%d  total=%d",
        p.mode, p.variants_per_q, p.n_variants_total))
    print(string.format("  recall@1    : %s", fmt_pct(p["recall@1"])))
    print(string.format("  recall@5    : %s", fmt_pct(p["recall@5"])))
    print(string.format("  recall@10   : %s", fmt_pct(p["recall@10"])))
    print(string.format("  recall@20   : %s", fmt_pct(p["recall@20"])))
    print(string.format("  MRR         : %.3f", p.mrr))
    print(string.format("  robustness@5: %.3f  (paraphrase recall@5 / base recall@5)",
        p.robustness_at_5))
end

os.execute("mkdir -p " .. (args.out:match("(.*)/") or "."))
local fh = assert(io.open(args.out, "wb"))
fh:write(cjson.encode(report))
fh:close()
print("\nwrote " .. args.out)

-- --- CI-mode baseline assertion -----------------------------------------
if args.mode == "ci" then
    local fail = {}
    local function check(name, got, want, tol)
        local diff = math.abs((got or 0) - want)
        if diff > tol then
            fail[#fail + 1] = string.format(
                "  %-13s got %.6f  want %.6f  (diff %.6f > tol %.6f)",
                name, got or 0, want, diff, tol)
        end
    end
    print(string.rep("-", 64))
    print("CI mode: asserting baseline")
    if report.n_questions ~= CI_BASELINE.n_questions then
        fail[#fail + 1] = string.format(
            "  n_questions   got %d        want %d",
            report.n_questions, CI_BASELINE.n_questions)
    end
    check("recall@1",  report["recall@1"],  CI_BASELINE["recall@1"],  args.tol)
    check("recall@5",  report["recall@5"],  CI_BASELINE["recall@5"],  args.tol)
    check("recall@10", report["recall@10"], CI_BASELINE["recall@10"], args.tol)
    check("recall@20", report["recall@20"], CI_BASELINE["recall@20"], args.tol)
    check("mrr",       report.mrr,          CI_BASELINE.mrr,          args.tol)
    if report.median_rank ~= CI_BASELINE.median_rank then
        fail[#fail + 1] = string.format(
            "  median_rank   got %s        want %s",
            tostring(report.median_rank), tostring(CI_BASELINE.median_rank))
    end
    if report.tail_misses ~= CI_BASELINE.tail_misses then
        fail[#fail + 1] = string.format(
            "  tail_misses   got %d        want %d",
            report.tail_misses, CI_BASELINE.tail_misses)
    end
    if #fail > 0 then
        print("FAIL: baseline drift detected")
        for _, line in ipairs(fail) do print(line) end
        os.exit(1)
    end
    print("OK: all metrics within tolerance " .. args.tol)
end
