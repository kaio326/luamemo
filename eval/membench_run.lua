-- eval/membench_run.lua
--
-- MemBench (ACL 2025) retrieval-side evaluation harness for luamemo.
-- "MemBench: Towards More Comprehensive Evaluation on the Memory of LLM-based Agents"
-- Source: https://github.com/import-myself/Membench
--
-- Standard 8500-item evaluation protocol:
--   - role-keyed categories (aggregative, comparative, conditional,
--     knowledge_update, noisy, post_processing, simple): 1000 q each
--   - topic-keyed categories (highlevel, highlevel_rec, lowlevel_rec):
--     500 q each (movie topic only)
--   - RecMultiSession excluded
--
-- For every question we:
--   1. Wipe scope  `mb:<embedder>:q<id>`
--   2. Write every turn as an individual memory
--      (metadata.sid = turn_sid_string)
--   3. Search the question with limit = k_max
--   4. Hit = any top-K result's metadata.sid is in target_sids
--      Rank = position of first such hit
--
-- This is retrieval-side only — no generated answers scored.
-- Primary metric: R@5.
--
-- Usage:
--   MEMO_DB_URL=postgresql://... \
--     lua5.1 eval/membench_run.lua --embedder hash \
--       --data-dir eval/data/membench --n 850 \
--       --out eval/results/membench_hash_v032.json
--
-- Full 8500-item run:
--   MEMO_DB_URL=postgresql://... \
--     lua5.1 eval/membench_run.lua --embedder hash \
--       --data-dir eval/data/membench \
--       --out eval/results/membench_hash_v032.json
--
-- TEI bge-m3:
--   TEI_URL=http://127.0.0.1:8081/embed TEI_DIM=1024 EMBED_TIMEOUT_MS=120000 \
--   MEMO_DB_URL=postgresql://... \
--     lua5.1 eval/membench_run.lua --embedder tei \
--       --out eval/results/membench_tei_bge-m3_v032.json
--
-- Flags:
--   --embedder hash|ollama|tei|openai
--   --n N              limit to N questions (smoke test)
--   --k-max N          retrieve top-N per question (default 20)
--   --cats cat1,cat2   run only these categories (comma-separated)
--   --topic TOPIC      filter topic-keyed categories (default movie)
--   --patterns         enable write-time extraction (ablation only; see comment below)
--   --with-observations include observation tier in search results
--
-- See eval/datasets/membench.lua for schema notes.

package.path = "./?.lua;./?/init.lua;eval/?.lua;eval/datasets/?.lua;" .. package.path
package.preload["resty.http"] = function() return require("_resty_http_shim") end

local cjson = require("cjson.safe")

-- ---------------------------------------------------------------------------
-- Argument parsing
-- ---------------------------------------------------------------------------
local args = {
    embedder          = "hash",
    n                 = nil,        -- nil = use full dataset
    k_max             = 20,
    out               = nil,
    data_dir          = "eval/data/membench",
    topic             = "movie",    -- filter for topic-keyed categories
    skip_observations = true,
    patterns          = false,      -- enable write-time pattern extraction (real-usage default)
}

do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if     a == "--embedder"          then args.embedder = arg[i + 1]; i = i + 2
        elseif a == "--n"                 then args.n = tonumber(arg[i + 1]); i = i + 2
        elseif a == "--k-max"             then args.k_max = tonumber(arg[i + 1]); i = i + 2
        elseif a == "--out"               then args.out = arg[i + 1]; i = i + 2
        elseif a == "--data-dir"          then args.data_dir = arg[i + 1]; i = i + 2
        elseif a == "--topic"             then args.topic = arg[i + 1]; i = i + 2
        elseif a == "--cats"              then args.cats = arg[i + 1]; i = i + 2
        elseif a == "--with-observations" then args.skip_observations = false; i = i + 1
        elseif a == "--patterns"          then args.patterns = true; i = i + 1
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
    end
end

local patterns_suffix = args.patterns and "_patterns" or ""
args.out = args.out or ("eval/results/membench_" .. args.embedder .. patterns_suffix .. ".json")

-- ---------------------------------------------------------------------------
-- Data directory check
-- ---------------------------------------------------------------------------
local fh_check = io.open(args.data_dir .. "/simple.json", "rb")
if not fh_check then
    io.stderr:write("data directory missing: " .. args.data_dir .. "\n")
    io.stderr:write("Download the MemBench dataset from:\n")
    io.stderr:write("  https://github.com/import-myself/Membench/tree/main/MemData/FirstAgent\n")
    io.stderr:write("Place the JSON files in: " .. args.data_dir .. "/\n")
    io.stderr:write("(See eval/datasets/membench.lua for schema notes.)\n")
    os.exit(1)
end
fh_check:close()

-- ---------------------------------------------------------------------------
-- Library setup
-- ---------------------------------------------------------------------------
local memory   = require("luamemo")
local db       = require("luamemo.db")
local membench = require("membench")

local setup_opts = {
    db_table         = "lm_memories",
    backend          = "bruteforce",
    auth_fn          = function() return true end,
    skip_embed_probe = true,
    -- patterns_enabled: false keeps the haystack clean for this benchmark.
    -- Write-time extraction (patterns_enabled=true) inserts companion memories that
    -- lack a target SID and would only dilute the haystack; with TEI it also triggers
    -- an embed call per companion, multiplying runtime ~5x. Not recommended here.
    -- Search-time boosts (person_name_boost, quoted_phrase_boost) are always active
    -- since they are separate config keys defaulting to true.
    -- Pass --patterns to include write-time extraction (useful for ablation studies).
    patterns_enabled = args.patterns and true or false,
    dedup_enabled    = false,     -- each turn is unique; skip O(n²) dedup scan
    default_scope    = "mb:" .. args.embedder .. (args.patterns and ":p" or ""),
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
elseif args.embedder == "tei" then
    setup_opts.embedder_url     = os.getenv("TEI_URL")
        or "http://127.0.0.1:8081/embed"
    setup_opts.embedder_adapter = "tei"
    setup_opts.embedder_model   = os.getenv("TEI_MODEL") or "BAAI/bge-m3"
    setup_opts.embed_dim        = tonumber(os.getenv("TEI_DIM") or "1024")
    setup_opts.embed_timeout_ms = tonumber(os.getenv("EMBED_TIMEOUT_MS") or "120000")
elseif args.embedder == "openai" then
    local key = os.getenv("OPENAI_API_KEY")
    if not key or key == "" then
        io.stderr:write("OPENAI_API_KEY required for --embedder openai\n"); os.exit(2)
    end
    setup_opts.embedder_url     = os.getenv("OPENAI_URL")
        or "https://api.openai.com/v1/embeddings"
    setup_opts.embedder_adapter = "openai"
    setup_opts.embedder_model   = os.getenv("OPENAI_MODEL") or "text-embedding-3-small"
    setup_opts.embedder_headers = { Authorization = "Bearer " .. key }
    setup_opts.embed_dim        = tonumber(os.getenv("OPENAI_DIM") or "1536")
else
    io.stderr:write("unknown --embedder: " .. tostring(args.embedder) .. "\n"); os.exit(2)
end

memory.setup(setup_opts)

-- ---------------------------------------------------------------------------
-- Load corpus
-- ---------------------------------------------------------------------------
-- Parse optional --cats comma-separated filter, e.g. "highlevel,highlevel_rec,lowlevel_rec"
local cats_filter = nil
if args.cats then
    cats_filter = {}
    for cat in args.cats:gmatch("[^,]+") do cats_filter[#cats_filter+1] = cat end
end
local data = membench.load(args.data_dir, { topic = args.topic, limit = args.n, cats = cats_filter })

print(string.format("embedder=%s  questions=%d  k_max=%d  topic=%s  backend=%s",
    args.embedder, #data, args.k_max, args.topic, memory.store.backend()))

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function new_bucket()
    return {
        n         = 0,
        sum_mrr   = 0,
        hits      = { [1] = 0, [5] = 0, [10] = 0, [20] = 0 },
        miss      = 0,
    }
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------
local overall  = new_bucket()
local by_cat   = {}
local per_q    = {}
local t_start  = os.time()

for _, q in ipairs(data) do
    local scope = "mb:" .. args.embedder .. ":" .. tostring(q.id)

    -- Wipe previous run for this scope.
    db.query("DELETE FROM lm_memories WHERE scope = " .. db.escape_literal(scope))

    -- Ingest haystack turns (one memory per turn, sid stored in metadata).
    for _, turn in ipairs(q.turns or {}) do
        local row, werr = memory.write({
            scope    = scope,
            kind     = "turn",
            title    = turn.sid,
            body     = turn.text,
            metadata = { sid = turn.sid },
        })
        if not row then
            io.stderr:write(("write failed q=%s sid=%s: %s\n")
                :format(tostring(q.id), turn.sid, tostring(werr)))
        end
    end

    -- Search.
    local results, rerr = memory.search({
        scope             = scope,
        query             = q.question,
        limit             = args.k_max,
        tier_min          = 0,
        skip_observations = args.skip_observations,
    })
    if not results then
        io.stderr:write(("search failed q=%s: %s\n"):format(tostring(q.id), tostring(rerr)))
        results = {}
    end

    -- Score: find the first result whose metadata.sid is in target_sids.
    local rank = nil
    for ri, r in ipairs(results) do
        local meta = type(r.metadata) == "table" and r.metadata or {}
        if q.target_sids[meta.sid or ""] then
            rank = ri
            break
        end
    end

    -- Accumulate into overall and per-category buckets.
    local cat = q.category or "unknown"
    if not by_cat[cat] then by_cat[cat] = new_bucket() end
    local function accum(b)
        b.n = b.n + 1
        if rank then
            local mrr = 1.0 / rank
            b.sum_mrr = b.sum_mrr + mrr
            for k in pairs(b.hits) do
                if rank <= k then b.hits[k] = b.hits[k] + 1 end
            end
        else
            b.miss = b.miss + 1
        end
    end
    accum(overall)
    accum(by_cat[cat])

    local n_target = 0
    for _ in pairs(q.target_sids) do n_target = n_target + 1 end
    per_q[#per_q + 1] = {
        id         = q.id,
        category   = cat,
        topic      = q.topic,
        rank       = rank,
        n_target   = n_target,
        n_turns    = #(q.turns or {}),
    }

    -- Progress every 50 questions.
    if #per_q % 50 == 0 then
        io.stderr:write(string.format("  [%d/%d] R@1=%.1f%%  MRR=%.3f\n",
            #per_q, #data,
            100 * (overall.hits[1] / overall.n),
            overall.sum_mrr / overall.n))
    end
end

local t_elapsed = os.time() - t_start

-- ---------------------------------------------------------------------------
-- Final metrics
-- ---------------------------------------------------------------------------
local function metrics(b)
    if b.n == 0 then return { n = 0, r1 = 0, r5 = 0, r10 = 0, r20 = 0, mrr = 0 } end
    return {
        n   = b.n,
        r1  = b.hits[1]  / b.n,
        r5  = b.hits[5]  / b.n,
        r10 = b.hits[10] / b.n,
        r20 = b.hits[20] / b.n,
        mrr = b.sum_mrr  / b.n,
        miss = b.miss,
    }
end

local result = {
    embedder = args.embedder,
    k_max    = args.k_max,
    n        = #data,
    elapsed_s = t_elapsed,
    overall  = metrics(overall),
    by_category = {},
    per_question = per_q,
}
local sorted_cats = {}
for cat in pairs(by_cat) do sorted_cats[#sorted_cats + 1] = cat end
table.sort(sorted_cats)
for _, cat in ipairs(sorted_cats) do
    result.by_category[cat] = metrics(by_cat[cat])
end

-- ---------------------------------------------------------------------------
-- Print summary
-- ---------------------------------------------------------------------------
print(string.format("\n=== MemBench results — embedder=%s, n=%d, elapsed=%ds ===",
    args.embedder, #data, t_elapsed))
print(string.format("Overall  R@1=%.1f%%  R@5=%.1f%%  R@10=%.1f%%  MRR=%.3f  (n=%d)",
    100 * result.overall.r1,
    100 * result.overall.r5,
    100 * result.overall.r10,
    result.overall.mrr,
    result.overall.n))
print("\nBy category:")
for _, cat in ipairs(sorted_cats) do
    local m = result.by_category[cat]
    print(string.format("  %-20s  R@1=%5.1f%%  R@5=%5.1f%%  R@10=%5.1f%%  MRR=%.3f  n=%d",
        cat,
        100 * m.r1, 100 * m.r5, 100 * m.r10, m.mrr, m.n))
end

-- ---------------------------------------------------------------------------
-- Write JSON output
-- ---------------------------------------------------------------------------
local out_fh, out_err = io.open(args.out, "w")
if not out_fh then
    io.stderr:write("cannot write output: " .. tostring(out_err) .. "\n")
    os.exit(1)
end
out_fh:write(cjson.encode(result))
out_fh:close()
print("\nWrote: " .. args.out)
