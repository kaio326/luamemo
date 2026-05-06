-- Phase 16.6 — LoCoMo bench runner.
--
-- End-to-end retrieval-side run of LoCoMo through luamemo. Unlike
-- LongMemEval (one question per row) LoCoMo has multiple QA pairs that
-- share the same conversation haystack. We exploit that: one ingest per
-- row, then loop over the row's `qa` list issuing N searches against
-- the same scope.
--
-- For each (sample_id, qa_index):
--   1. (Once per sample) wipe scope `locomo:<embedder>:<sample_id>`
--      and write every session as one memory.
--   2. Search the question with `limit = k_max`.
--   3. gold = M.qa_gold_sessions(qa)  -- set of "session_<n>" derived
--      from QA's evidence dia_ids.
--   4. Hit  = any top-K result's `metadata.session_id` is in gold.
--      Rank = position of the first such hit.
--
-- Retrieval-side only — we do not score generated answers.
--
-- Usage:
--   PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test \
--     lua5.1 eval/locomo_run.lua \
--       --embedder hash --corpus eval/data/fixtures/locomo_tiny.json \
--       --out eval/results/locomo_hash_smoke.json
--
-- Output: `eval/results/locomo_<embedder>.json` with overall metrics
-- AND a per-`category` breakdown (single-hop, multi-hop, temporal,
-- open-domain, adversarial).

package.path = "./?.lua;./?/init.lua;eval/?.lua;eval/datasets/?.lua;" .. package.path
package.preload["resty.http"] = function() return require("_resty_http_shim") end

local cjson = require("cjson.safe")

-- --- arg parsing ---------------------------------------------------------
local args = {
    embedder = "hash",
    n        = nil,
    k_max    = 20,
    out      = nil,
    corpus   = "eval/data/locomo.json",
    rerank          = false,
    rerank_adapter  = "noop",
    rerank_top_n    = 20,
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
        elseif a == "--rerank"   then args.rerank = true; i = i + 1
        elseif a == "--rerank-adapter" then args.rerank_adapter = arg[i + 1]; i = i + 2
        elseif a == "--rerank-top-n"   then args.rerank_top_n = tonumber(arg[i + 1]); i = i + 2
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
    end
end
args.out = args.out or ("eval/results/locomo_" .. args.embedder
    .. (args.rerank and ("_rerank-" .. args.rerank_adapter) or "") .. ".json")

local fh = io.open(args.corpus, "rb")
if not fh then
    io.stderr:write("corpus missing: " .. args.corpus .. "\n")
    io.stderr:write("see eval/sidecars/locomo.md for download protocol.\n")
    os.exit(1)
end
fh:close()

-- luamemo.db creates a pgmoon connection automatically from
-- PGHOST / PGDATABASE / PGUSER / PGPASSWORD env vars when outside OpenResty.

local memory  = require("luamemo")
local db      = require("luamemo.db")
local locomo  = require("locomo")

-- --- embedder config (mirrors longmemeval_run.lua) -----------------------
local setup_opts = {
    db_table         = "lapis_memory",
    backend          = "auto",
    auth_fn          = function() return true end,
    skip_embed_probe = true,
    default_scope    = "locomo:" .. args.embedder,
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

if args.rerank then
    memory.config.rerank_enabled = true
    memory.config.rerank_adapter = args.rerank_adapter
    memory.config.rerank_top_n   = args.rerank_top_n
    if args.rerank_adapter == "ollama" then
        memory.config.rerank_url   = os.getenv("OLLAMA_RERANK_URL")
            or "http://127.0.0.1:11434/api/generate"
        memory.config.rerank_model = os.getenv("OLLAMA_RERANK_MODEL") or "llama3.2"
    elseif args.rerank_adapter == "openai" then
        memory.config.rerank_url   = os.getenv("OPENAI_RERANK_URL")
            or "https://api.openai.com/v1/chat/completions"
        memory.config.rerank_model = os.getenv("OPENAI_RERANK_MODEL") or "gpt-4o-mini"
        local key = os.getenv("OPENAI_API_KEY")
        if key and key ~= "" then
            memory.config.rerank_headers = { Authorization = "Bearer " .. key }
        end
    elseif args.rerank_adapter == "cross_encoder" then
        memory.config.rerank_url   = os.getenv("RERANK_URL")
            or "http://127.0.0.1:8080/rerank"
        memory.config.rerank_model = os.getenv("RERANK_MODEL")
            or "BAAI/bge-reranker-v2-m3"
        local key = os.getenv("RERANK_API_KEY")
        if key and key ~= "" then
            memory.config.rerank_headers = { Authorization = "Bearer " .. key }
        end
    end
    memory.rerank.configure(memory.config)
end

-- --- load corpus ---------------------------------------------------------
local rows = locomo.load(args.corpus)
if args.n and args.n < #rows then
    local trimmed = {}
    for i = 1, args.n do trimmed[i] = rows[i] end
    rows = trimmed
end

-- Count total QA pairs up front (each becomes one search).
local total_qa = 0
for _, r in ipairs(rows) do total_qa = total_qa + #(r.qa or {}) end

print(string.format("embedder=%s  samples=%d  qa_pairs=%d  k_max=%d  backend=%s  rerank=%s",
    args.embedder, #rows, total_qa, args.k_max, memory.store.backend(),
    args.rerank and args.rerank_adapter or "off"))

-- --- per-category accumulator -------------------------------------------
local function new_bucket()
    return {
        n            = 0,
        sum_mrr      = 0,
        hits         = { [1] = 0, [5] = 0, [10] = 0, [20] = 0 },
        rank_list    = {},
        miss_count   = 0,
    }
end
local overall = new_bucket()
local by_cat  = {}

-- --- run -----------------------------------------------------------------
local per_question = {}
local t_start      = os.time()
local q_done       = 0

for ri, r in ipairs(rows) do
    local sample_id = tostring(r.sample_id or ("row_" .. ri))
    local scope     = "locomo:" .. args.embedder .. ":" .. sample_id

    -- 1. wipe + ingest haystack once per sample
    db.query("DELETE FROM lapis_memory WHERE scope = " .. db.escape_literal(scope))

    local n_haystack = 0
    local batch = {}
    for sid, turns in locomo.iter_sessions(r) do
        n_haystack = n_haystack + 1
        local body = locomo.session_to_body(turns)
        local max_chars = tonumber(os.getenv("EMBED_MAX_CHARS") or "6000")
        if max_chars > 0 and #body > max_chars then body = body:sub(1, max_chars) end
        batch[#batch + 1] = {
            scope    = scope,
            kind     = "session",
            title    = sid,
            body     = body,
            metadata = { session_id = sid },
        }
    end

    local results, batch_err
    if os.getenv("INGEST_MODE") == "perrow" then
        results = {}
        for bi, brow in ipairs(batch) do
            local row, werr = memory.write(brow)
            results[bi] = { row = row, error = werr }
        end
    else
        results, batch_err = memory.write_many(batch,
            { batch_size = tonumber(os.getenv("INGEST_BATCH_SIZE") or "50") })
        if batch_err then
            io.stderr:write(("write_many fatal for sample=%s: %s\n")
                :format(sample_id, tostring(batch_err)))
        end
    end
    for bi, ar in ipairs(results or {}) do
        if ar.error then
            io.stderr:write(("write failed sample=%s sess=%s: %s\n")
                :format(sample_id, tostring(batch[bi].title), tostring(ar.error)))
        end
    end

    -- 2. one search per QA against the shared scope
    for qi, qa in locomo.iter_qa(r) do
        if not qa.question or qa.question == "" then
            -- skip malformed entry
        else
            local gold = locomo.qa_gold_sessions(qa)
            local cat  = locomo.category_name(qa.category)
            by_cat[cat] = by_cat[cat] or new_bucket()

            local sresults, serr = memory.search({
                query = qa.question,
                scope = scope,
                limit = args.k_max,
            })
            if not sresults then
                io.stderr:write(("search failed sample=%s qa=%d: %s\n")
                    :format(sample_id, qi, tostring(serr)))
                os.exit(1)
            end

            local rank
            for sri, sr in ipairs(sresults) do
                local meta = sr.metadata
                if type(meta) == "string" then meta = cjson.decode(meta) or {} end
                local sid = meta and meta.session_id
                if sid and gold[sid] then rank = sri; break end
            end

            local function record(b)
                b.n = b.n + 1
                if rank then
                    b.sum_mrr = b.sum_mrr + (1.0 / rank)
                    b.rank_list[#b.rank_list + 1] = rank
                    for _, k in ipairs({ 1, 5, 10, 20 }) do
                        if rank <= k then b.hits[k] = b.hits[k] + 1 end
                    end
                else
                    b.miss_count = b.miss_count + 1
                end
            end
            record(overall)
            record(by_cat[cat])
            per_question[#per_question + 1] = {
                sample_id  = sample_id,
                qa_index   = qi,
                category   = cat,
                rank       = rank,
                n_haystack = n_haystack,
                n_gold     = (function()
                    local c = 0; for _ in pairs(gold) do c = c + 1 end; return c
                end)(),
            }
            q_done = q_done + 1
        end
    end

    if ri % 5 == 0 or ri == #rows then
        io.write(string.format("\r  progress: row %d/%d (%d/%d qa)",
            ri, #rows, q_done, total_qa)); io.flush()
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

local function summarise(b)
    local n = b.n
    return {
        n_questions   = n,
        ["recall@1"]  = n > 0 and (b.hits[1]  / n) or 0,
        ["recall@5"]  = n > 0 and (b.hits[5]  / n) or 0,
        ["recall@10"] = n > 0 and (b.hits[10] / n) or 0,
        ["recall@20"] = n > 0 and (b.hits[20] / n) or 0,
        mrr           = n > 0 and (b.sum_mrr  / n) or 0,
        median_rank   = median(b.rank_list),
        tail_misses   = b.miss_count,
    }
end

local report = {
    embedder      = args.embedder,
    embed_dim     = setup_opts.embed_dim,
    backend       = memory.store.backend(),
    corpus        = args.corpus,
    k_max         = args.k_max,
    rerank        = args.rerank and args.rerank_adapter or "off",
    rerank_top_n  = args.rerank and args.rerank_top_n or nil,
    elapsed_sec   = os.time() - t_start,
    overall       = summarise(overall),
    by_category   = {},
    per_question  = per_question,
}
for cat, b in pairs(by_cat) do
    report.by_category[cat] = summarise(b)
end

-- --- print ---------------------------------------------------------------
local function fmt_pct(x) return string.format("%5.1f%%", x * 100) end
local function print_row(label, s)
    print(string.format("  %-28s n=%4d  R@1=%s  R@5=%s  R@10=%s  R@20=%s  MRR=%.3f  miss=%d",
        label, s.n_questions,
        fmt_pct(s["recall@1"]),  fmt_pct(s["recall@5"]),
        fmt_pct(s["recall@10"]), fmt_pct(s["recall@20"]),
        s.mrr, s.tail_misses))
end

print(string.rep("-", 96))
print(string.format("embedder      : %s (dim=%d, backend=%s)",
    report.embedder, report.embed_dim, report.backend))
print(string.format("samples=%d  qa_pairs=%d  k_max=%d  elapsed=%ds",
    #rows, report.overall.n_questions, report.k_max, report.elapsed_sec))
print("")
print_row("OVERALL", report.overall)
print("")
print("by category:")
local cats_sorted = {}
for k in pairs(report.by_category) do cats_sorted[#cats_sorted + 1] = k end
table.sort(cats_sorted)
for _, k in ipairs(cats_sorted) do print_row(k, report.by_category[k]) end

os.execute("mkdir -p " .. (args.out:match("(.*)/") or "."))
local ofh = assert(io.open(args.out, "wb"))
ofh:write(cjson.encode(report))
ofh:close()
print("\nwrote " .. args.out)
