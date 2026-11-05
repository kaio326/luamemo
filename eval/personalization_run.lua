#!/usr/bin/env luajit
-- Project-personalization eval (Phase 2 of the learned-from-usage feature).
--
-- Measures whether luamemo surfaces THIS project's conventions/decisions/
-- corrections when asked in natural language — the scoreboard the learned
-- reranker (Phase 4) and projection (Phase 5) are tuned and rolled back against.
-- Unlike the LME/LoCoMo/ConvoMem suites (generic prose recall, a regression
-- rail), this set is project-specific knowledge a fresh model would NOT have.
--
-- Protocol:
--   1. Ingest eval/personalization/corpus.jsonl into scope perso:<embedder>
--      (metadata.item_id = the row's id). Uniform importance so the corpus
--      does not pre-bake the ranking — the learners must earn it.
--   2. For each query in eval/personalization/queries.jsonl, run store.search
--      and find the rank of the gold row (metadata.item_id == gold_id).
--   3. Report recall@{1,3,5,10} + MRR overall and by lexical_overlap bucket.
--
-- Database: MEMO_DB (a scratch name or path; the run wipes its own scope).
-- Usage: the embedder defaults to hash (self-contained). Override with --embedder.
--
--   MEMO_NO_MAINTENANCE=1 MEMO_DB=bench luajit eval/personalization_run.lua --embedder hash
-- (MEMO_NO_MAINTENANCE=1: its writes start no `memo maintain` on the scratch database)

package.path = "./?/init.lua;./?.lua;" .. package.path
local cjson  = require("luamemo.json")

-- --- args ----------------------------------------------------------------
local args = { embedder = "hash",
               corpus = "eval/personalization/corpus.jsonl",
               queries = "eval/personalization/queries.jsonl", out = nil }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if     a == "--embedder" then args.embedder = arg[i + 1]; i = i + 2
        elseif a == "--out"      then args.out      = arg[i + 1]; i = i + 2
        elseif a == "--corpus"   then args.corpus   = arg[i + 1]; i = i + 2
        elseif a == "--queries"  then args.queries  = arg[i + 1]; i = i + 2
        elseif a == "--rerank"   then args.rerank   = true; i = i + 1
        elseif a == "--rerank-adapter" then args.rerank_adapter = arg[i + 1]; i = i + 2
        elseif a == "--rerank-top-n"   then args.rerank_top_n   = tonumber(arg[i + 1]); i = i + 2
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
    end
end
args.out = args.out or ("eval/results/personalization_" .. args.embedder .. ".json")

-- --- jsonl loader --------------------------------------------------------
local function load_jsonl(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local rows = {}
    for line in f:lines() do
        if line:match("%S") then
            local obj = cjson.decode(line)
            if obj then rows[#rows + 1] = obj end
        end
    end
    f:close()
    return rows
end

local corpus  = load_jsonl(args.corpus)
local queries = load_jsonl(args.queries)

-- --- setup ---------------------------------------------------------------
local memory = require("luamemo")
local db     = require("luamemo.db")

local setup_opts = {
    skip_embed_probe = true,
}
if args.embedder == "hash" then
    setup_opts.embedder_local = "hash"; setup_opts.embed_dim = 384
elseif args.embedder == "ollama" then
    setup_opts.embedder_url     = os.getenv("OLLAMA_URL") or "http://127.0.0.1:11434/api/embeddings"
    setup_opts.embedder_adapter = "ollama"
    setup_opts.embedder_model   = os.getenv("OLLAMA_MODEL") or "nomic-embed-text"
    setup_opts.embed_dim        = tonumber(os.getenv("OLLAMA_DIM") or "768")
elseif args.embedder == "tei" then
    setup_opts.embedder_url     = os.getenv("TEI_URL") or "http://127.0.0.1:8081/embed"
    setup_opts.embedder_adapter = "tei"
    setup_opts.embedder_model   = os.getenv("TEI_MODEL") or "BAAI/bge-m3"
    setup_opts.embed_dim        = tonumber(os.getenv("TEI_DIM") or "1024")
    setup_opts.embed_timeout_ms = tonumber(os.getenv("EMBED_TIMEOUT_MS") or "120000")
elseif args.embedder == "gguf" then
    -- In-process GGUF embedder (EmbeddingGemma via LuaJIT FFI), as the other runners.
    setup_opts.embedder_local = "gguf_ffi"
    setup_opts.embedder_model = os.getenv("MEMO_GGUF_MODEL")
        or (os.getenv("HOME") .. "/models/embeddinggemma-300M-Q8_0.gguf")
    setup_opts.embed_dim      = tonumber(os.getenv("MEMO_GGUF_DIM") or "768")
else
    io.stderr:write("unknown --embedder: " .. tostring(args.embedder) .. "\n"); os.exit(2)
end
setup_opts.embed_prompts = os.getenv("EMBED_PROMPTS")   -- none | auto | JSON (luamemo.embed)
memory.setup(setup_opts)
if args.rerank then   -- as the other runners: the endpoint from OLLAMA_RERANK_* / RERANK_*
    memory.config.rerank_enabled = true
    memory.config.rerank_adapter = args.rerank_adapter or "noop"
    memory.config.rerank_top_n   = args.rerank_top_n or 20
    if memory.config.rerank_adapter == "ollama" then
        memory.config.rerank_url   = os.getenv("OLLAMA_RERANK_URL") or "http://127.0.0.1:11434/api/generate"
        memory.config.rerank_model = os.getenv("OLLAMA_RERANK_MODEL") or "llama3.2"
        memory.config.rerank_timeout_ms = tonumber(os.getenv("RERANK_TIMEOUT_MS") or "180000")
    elseif memory.config.rerank_adapter == "cross_encoder" then
        memory.config.rerank_url   = os.getenv("RERANK_URL") or "http://127.0.0.1:8080/rerank"
        memory.config.rerank_model = os.getenv("RERANK_MODEL") or "BAAI/bge-reranker-v2-m3"
    end
end

local scope = "perso:" .. args.embedder

-- --- ingest corpus -------------------------------------------------------
assert(db.run("DELETE FROM lm_memories WHERE scope = ?", scope))
local batch = {}
for _, m in ipairs(corpus) do
    batch[#batch + 1] = {
        scope      = scope,
        kind       = m.kind or "fact",
        title      = m.title or m.id,
        body       = m.body or "",
        tags       = m.tags,
        importance = 1.0,               -- uniform: corpus must not pre-bake ranking
        metadata   = { item_id = m.id, project_specific = m.project_specific and true or false },
    }
end
local results, werr = memory.store.write_many(batch, {})
assert(results, "ingest failed: " .. tostring(werr))
local ingested = 0
for _, r in ipairs(results) do if not r.error then ingested = ingested + 1 end end

print(string.format("embedder=%s  backend=%s  corpus=%d (ingested %d)  queries=%d",
    args.embedder, memory.store.backend(), #corpus, ingested, #queries))

-- --- helpers -------------------------------------------------------------
local function item_id_of(row)
    local md = row.metadata
    if type(md) == "string" then md = cjson.decode(md) end
    return (type(md) == "table") and md.item_id or nil
end

-- eval/metrics.lua: R@k, MRR, miss rate, bytes to the hit
local metrics = require("eval.metrics")
local function new_bucket() return metrics.new({ ks = { 1, 3, 5, 10 } }) end
local record = metrics.record
local function finalize(b)
    local o = metrics.summary(b)
    o.n = b.n
    return o
end

-- --- run queries ---------------------------------------------------------
local overall = new_bucket()
local by_overlap = {}
local per_query = {}

for _, q in ipairs(queries) do
    local rows, serr = memory.store.search({
        query = q.query, scope = scope, limit = 20,
        skip_temporal = true, skip_observations = true,
    })
    rows = rows or {}
    if serr then io.stderr:write("search error: " .. tostring(serr) .. "\n") end

    local rank = nil
    for idx, row in ipairs(rows) do
        if item_id_of(row) == q.gold_id then rank = idx; break end
    end

    record(overall, rank, rows)
    local ov = q.lexical_overlap or "unknown"
    by_overlap[ov] = by_overlap[ov] or new_bucket()
    record(by_overlap[ov], rank, rows)

    per_query[#per_query + 1] = { query = q.query, gold_id = q.gold_id,
        lexical_overlap = ov, rank = rank or 0, hit = rank ~= nil }
end

-- --- report --------------------------------------------------------------
local O = finalize(overall)
for k, v in pairs(metrics.rerank_summary()) do O[k] = v end   -- the reranker's cost
print(string.format("\nOVERALL  n=%d  R@1=%.1f%%  R@3=%.1f%%  R@5=%.1f%%  R@10=%.1f%%  MRR=%.3f",
    O.n, 100*O["recall@1"], 100*O["recall@3"], 100*O["recall@5"], 100*O["recall@10"], O.mrr))
print("         " .. metrics.line(O))
local overlap_report = {}
for ov, b in pairs(by_overlap) do
    local f = finalize(b)
    overlap_report[ov] = f
    print(string.format("  overlap=%-7s n=%2d  R@1=%.1f%%  R@5=%.1f%%  R@10=%.1f%%  MRR=%.3f",
        ov, f.n, 100*f["recall@1"], 100*f["recall@5"], 100*f["recall@10"], f.mrr))
    print(string.format("  %-17s %s", "", metrics.line(f)))
end

-- --- write result --------------------------------------------------------
local report = {
    suite = "personalization", embedder = args.embedder,
    backend = memory.store.backend(), embed_dim = setup_opts.embed_dim,
    corpus_size = #corpus, n_queries = #queries,
    overall = O, by_overlap = overlap_report, per_query = per_query,
}
local jf = io.open(args.out, "w")
if jf then jf:write(cjson.encode(report)); jf:close(); print("\nwrote " .. args.out) end
