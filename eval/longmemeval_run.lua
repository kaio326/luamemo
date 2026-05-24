-- Roadmap Item 14 — Real LongMemEval bench runner.
--
-- End-to-end retrieval-side run of the LongMemEval `oracle` split through
-- luamemo. For every row we:
--
--   1. Wipe scope `lme:<embedder>:<question_id>`.
--   2. Write every `(session_id, turns)` in `haystack_sessions` as a
--      single memory (`metadata.session_id = session_id`).
--   3. Search the question with `limit = k_max`.
--   4. Hit  = any top-K result's `metadata.session_id` is in
--            `answer_session_ids`. Rank = position of the first such hit.
--
-- This is **retrieval-side only** — we do not score generated answers.
-- The metric isolates luamemo's contribution from the downstream LLM.
--
-- Usage:
--   PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test \
--     lua5.1 eval/longmemeval_run.lua \
--       --embedder hash --out eval/results/longmemeval_hash.json
--
-- Dataset: `eval/data/longmemeval_oracle.json` (15 MB, 500 questions).
-- Public, no HF auth gate. Download once with:
--   curl -sL -o eval/data/longmemeval_oracle.json \
--     https://huggingface.co/datasets/xiaowu0162/longmemeval/resolve/main/longmemeval_oracle
--
-- Output: `eval/results/longmemeval_<embedder>.json` with overall metrics
-- AND a per-`question_type` breakdown.

package.path = "./?.lua;./?/init.lua;eval/?.lua;eval/datasets/?.lua;" .. package.path
-- resty.http shim: lets luamemo.http use LuaSocket-backed HTTP in
-- plain lua5.1 (outside OpenResty). Without this, luamemo.http falls
-- back to socket.http directly which also works, but keeping the shim avoids
-- a second pcall round-trip inside http.lua.
package.preload["resty.http"] = function() return require("_resty_http_shim") end

local cjson = require("cjson.safe")

-- --- arg parsing ---------------------------------------------------------
local args = {
    embedder = "hash",
    n        = nil,           -- nil = use full dataset
    k_max    = 20,
    out      = nil,
    corpus   = "eval/data/longmemeval_oracle.json",
    backend  = "auto",
    rerank          = false,
    rerank_adapter  = "noop",
    rerank_top_n    = 20,
    -- Default true: consolidation observations are not part of the gold dataset.
    -- Pass --with-observations to opt in (implied when --summarizer-model is set).
    skip_observations = true,
    skip_temporal     = false,
    -- Timestamp replay: pass original session dates to store.write_many so
    -- temporal search sees real time windows instead of today's date.
    -- Enabled by default; pass --no-timestamps to disable.
    use_timestamps    = true,
    -- LLM summarizer for consolidation synthesis (sets summarizer_adapter="ollama").
    -- nil = noop (fast, no LLM needed). Set to e.g. "llama3.1:8b".
    summarizer_model  = nil,
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
        elseif a == "--sweep-weights"  then args.sweep_weights = arg[i + 1]; i = i + 2
        elseif a == "--with-observations"  then args.skip_observations = false; i = i + 1
        elseif a == "--skip-observations"   then args.skip_observations = true; i = i + 1
        elseif a == "--skip-temporal"     then args.skip_temporal = true; i = i + 1
        elseif a == "--no-timestamps"     then args.use_timestamps = false; i = i + 1
        elseif a == "--summarizer-model"  then args.summarizer_model = arg[i + 1]; i = i + 2
        elseif a == "--backend"           then args.backend = arg[i + 1]; i = i + 2
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
    end
end
-- When a real LLM summarizer is configured, enable observations by default
-- so consolidation synthesis actually runs and contributes to search.
if args.summarizer_model and args.skip_observations then
    args.skip_observations = false
end
args.out = args.out or ("eval/results/longmemeval_" .. args.embedder
    .. (args.rerank and ("_rerank-" .. args.rerank_adapter) or "")
    .. (args.sweep_weights and "_sweep" or "") .. ".json")

-- --- parse --sweep-weights -----------------------------------------------
-- Format: "v1,v2,v3,..."  -> convex pairs (v, 1-v) for each.
-- This is the standard hybrid-weight sweep: vector vs. fts as a 1D curve
-- summing to 1.0. Empty / nil = no sweep.
local sweep_points = nil
if args.sweep_weights and args.sweep_weights ~= "" then
    sweep_points = {}
    for tok in args.sweep_weights:gmatch("[^,]+") do
        local v = tonumber(tok)
        if not v or v < 0 or v > 1 then
            io.stderr:write("--sweep-weights: invalid value '" .. tok
                .. "' (must be 0.0..1.0)\n")
            os.exit(2)
        end
        sweep_points[#sweep_points + 1] = { vector = v, fts = 1.0 - v }
    end
    if #sweep_points == 0 then
        io.stderr:write("--sweep-weights: no valid points parsed\n")
        os.exit(2)
    end
end

local fh = io.open(args.corpus, "rb")
if not fh then
    io.stderr:write("corpus missing: " .. args.corpus .. "\n")
    io.stderr:write("download with:\n  curl -sL -o " .. args.corpus
        .. " https://huggingface.co/datasets/xiaowu0162/longmemeval/resolve/main/longmemeval_oracle\n")
    os.exit(1)
end
fh:close()

-- --- db / library --------------------------------------------------------
-- luamemo.db detects the absence of `ngx` and creates a pgmoon
-- connection automatically using PGHOST / PGDATABASE / PGUSER / PGPASSWORD
-- env vars. No separate shim or package.loaded injection needed.
local memory     = require("luamemo")
local db         = require("luamemo.db")
local longmemev  = require("longmemeval")

-- --- embedder config (kept in sync with recall_bench.lua) ----------------
local setup_opts = {
    db_table         = "lm_memories",
    backend          = args.backend or "auto",
    auth_fn          = function() return true end,
    skip_embed_probe = true,
    default_scope    = "lme:" .. args.embedder,
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
    -- HuggingFace text-embeddings-inference (TEI) sidecar.
    -- Used for bge-m3 because Ollama's bge-m3 path returns NaN on
    -- inputs >~600 chars (upstream bug). See eval/sidecars/tei.md.
    setup_opts.embedder_url     = os.getenv("TEI_URL")
        or "http://127.0.0.1:8081/embed"
    setup_opts.embedder_adapter = "tei"
    setup_opts.embedder_model   = os.getenv("TEI_MODEL") or "BAAI/bge-m3"
    setup_opts.embed_dim        = tonumber(os.getenv("TEI_DIM") or "1024")
    -- CPU TEI can take 30-90 s per request; override the library default.
    setup_opts.embed_timeout_ms = tonumber(os.getenv("EMBED_TIMEOUT_MS") or "120000")
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

-- Summarizer config for consolidation synthesis (used when --with-observations).
if args.summarizer_model then
    setup_opts.summarizer_adapter = "ollama"
    setup_opts.summarizer_url     = os.getenv("OLLAMA_SUMMARIZER_URL")
        or "http://127.0.0.1:11434/api/generate"
    setup_opts.summarizer_model   = args.summarizer_model
end

memory.setup(setup_opts)

if args.rerank then
    memory.config.rerank_enabled = true
    memory.config.rerank_adapter = args.rerank_adapter
    memory.config.rerank_top_n   = args.rerank_top_n
    -- For ollama/openai, allow env-var configuration of rerank URL/model
    -- so the bench can target the same local Ollama as the embedder.
    if args.rerank_adapter == "ollama" then
        memory.config.rerank_url   = os.getenv("OLLAMA_RERANK_URL")
            or "http://127.0.0.1:11434/api/generate"
        memory.config.rerank_model = os.getenv("OLLAMA_RERANK_MODEL")
            or "llama3.2"
    elseif args.rerank_adapter == "openai" then
        memory.config.rerank_url   = os.getenv("OPENAI_RERANK_URL")
            or "https://api.openai.com/v1/chat/completions"
        memory.config.rerank_model = os.getenv("OPENAI_RERANK_MODEL")
            or "gpt-4o-mini"
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
    -- Re-configure rerank module with the now-updated config table.
    memory.rerank.configure(memory.config)
end

-- --- load corpus ---------------------------------------------------------
local rows = longmemev.load(args.corpus)
if args.n and args.n < #rows then
    local trimmed = {}
    for i = 1, args.n do trimmed[i] = rows[i] end
    rows = trimmed
end
print(string.format("embedder=%s  questions=%d  k_max=%d  backend=%s  rerank=%s%s",
    args.embedder, #rows, args.k_max, memory.store.backend(),
    args.rerank and args.rerank_adapter or "off",
    sweep_points and ("  sweep=" .. #sweep_points .. "pts") or ""))

-- --- helpers -------------------------------------------------------------
local function set_of(list)
    local s = {}
    for _, v in ipairs(list or {}) do s[v] = true end
    return s
end

-- --- per-type accumulator ------------------------------------------------
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
local by_type = {}

-- Sweep mode: one bucket per (vector, fts) point. Keyed by "v=X.XX_f=X.XX".
local function point_key(p)
    return string.format("v=%.2f_f=%.2f", p.vector, p.fts)
end
local point_buckets = nil
if sweep_points then
    point_buckets = {}
    for _, p in ipairs(sweep_points) do
        point_buckets[point_key(p)] = new_bucket()
    end
end

-- --- run -----------------------------------------------------------------
local per_question = {}
local t_start      = os.time()

for qi, q in ipairs(rows) do
    local scope = "lme:" .. args.embedder .. ":" .. tostring(q.question_id)
    db.query("DELETE FROM lm_memories WHERE scope = " .. db.escape_literal(scope))
    db.query("DELETE FROM lm_observations WHERE scope = " .. db.escape_literal(scope))
    db.query("DELETE FROM lm_reinforcements WHERE scope = " .. db.escape_literal(scope))

    local n_haystack = 0
    local batch = {}
    for sid, turns, date_str in longmemev.iter_sessions(q) do
        n_haystack = n_haystack + 1
        local body = longmemev.session_to_body(turns)
        -- Cap body length so embedders with small context windows
        -- (e.g. nomic-embed-text @ 2048 tokens) don't reject long sessions.
        -- Default 0 = no truncation (matches the original benchmark baseline).
        -- Set EMBED_MAX_CHARS=N to cap at N chars for HTTP embedders with
        -- small context windows (e.g. EMBED_MAX_CHARS=6000 for nomic-embed-text).
        local max_chars = tonumber(os.getenv("EMBED_MAX_CHARS") or "0")
        if max_chars > 0 and #body > max_chars then
            body = body:sub(1, max_chars)
            -- Trim any incomplete UTF-8 multi-byte sequence at the cut boundary.
            -- body:sub(1,N) cuts at a byte offset that may fall mid-character
            -- (e.g. the first two bytes of a 3-byte Korean char).  The trailing
            -- fragment causes PostgreSQL to reject the whole INSERT batch with
            -- "invalid byte sequence for encoding UTF8: 0xXX 0x27" (0x27 is the
            -- pgmoon SQL literal closing-quote that immediately follows).
            -- Fix: walk back over any trailing continuation bytes to the lead byte,
            -- then drop the lead + its continuations if the sequence is incomplete.
            local n = #body
            local trail = 0
            while n - trail > 0 do
                local b = body:byte(n - trail)
                if b < 0x80 or b >= 0xC0 then break end  -- ASCII or lead byte
                trail = trail + 1
            end
            -- Check whether the multi-byte sequence at n-trail is complete.
            -- Also handles trail==0 when the last byte is itself a bare lead byte.
            local lead_pos = n - trail
            local lead     = lead_pos > 0 and body:byte(lead_pos) or 0
            local needed   = (lead >= 0xF0 and 3)
                         or (lead >= 0xE0 and 2)
                         or (lead >= 0xC0 and 1) or 0
            if needed > 0 and trail < needed then
                -- Incomplete sequence: drop the lead byte and its partial continuations.
                body = body:sub(1, lead_pos - 1)
            end
        end
        local item = {
            scope    = scope,
            kind     = "session",
            title    = sid,
            body     = body,
            metadata = { session_id = sid },
        }
        if args.use_timestamps and date_str then
            item.created_at = longmemev.parse_session_date(date_str)
        end
        batch[#batch + 1] = item
    end
    -- Phase 16.7: batched ingest. Embeds sequentially but compresses N
    -- INSERTs into a single multi-VALUES statement per chunk, removing
    -- per-row round-trip overhead. Set INGEST_MODE=perrow to fall back to
    -- the legacy memory.write loop for A/B speedup measurement.
    local results = {}
    if os.getenv("INGEST_MODE") == "perrow" then
        for ri, args_row in ipairs(batch) do
            local row, werr = memory.write(args_row)
            results[ri] = { row = row, error = werr }
        end
    else
        local batch_err
        results, batch_err = memory.write_many(batch,
            { batch_size = tonumber(os.getenv("INGEST_BATCH_SIZE") or "50") })
        if batch_err then
            io.stderr:write(("write_many fatal for q=%s: %s\n")
                :format(q.question_id, tostring(batch_err)))
        end
    end
    for ri, r in ipairs(results or {}) do
        if r.error then
            io.stderr:write(("write failed for q=%s sess=%s: %s\n")
                :format(q.question_id, tostring(batch[ri].title), tostring(r.error)))
            -- Skip this session rather than abort the whole run; embedders
            -- with hard input limits can fail on very long single sessions.
        end
    end

    local gold = set_of(q.answer_session_ids)
    local function rank_for(results)
        for ri, r in ipairs(results) do
            local meta = r.metadata
            if type(meta) == "string" then meta = cjson.decode(meta) or {} end
            local sid = meta and meta.session_id
            if sid and gold[sid] then return ri end
        end
        return nil
    end
    local function record(b, rank)
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

    local qtype = q.question_type or "unknown"
    by_type[qtype] = by_type[qtype] or new_bucket()

    if sweep_points then
        -- Sweep mode: one search per grid point, ingest amortized.
        -- per_question records the rank under the FIRST grid point only
        -- (acts as the canonical pointer); per-point ranks live in their
        -- own buckets only.
        local first_rank
        for pi, p in ipairs(sweep_points) do
            local results, serr = memory.search({
                query          = q.question,
                scope          = scope,
                limit          = args.k_max,
                hybrid_weights = p,
            })
            if not results then
                io.stderr:write(("search failed for q=%s point=%s: %s\n")
                    :format(q.question_id, point_key(p), tostring(serr)))
                os.exit(1)
            end
            local rank = rank_for(results)
            record(point_buckets[point_key(p)], rank)
            if pi == 1 then first_rank = rank end
        end
        record(overall, first_rank)
        record(by_type[qtype], first_rank)
        per_question[#per_question + 1] = {
            question_id   = q.question_id,
            question_type = qtype,
            rank          = first_rank,
            n_haystack    = n_haystack,
            n_gold        = #(q.answer_session_ids or {}),
        }
    else
        -- Standard single-point mode (unchanged).
        local results, serr = memory.search({
            query              = q.question,
            scope              = scope,
            limit              = args.k_max,
            skip_observations  = args.skip_observations or nil,
            skip_temporal      = args.skip_temporal or nil,
        })
        if not results then
            io.stderr:write(("search failed for q=%s: %s\n")
                :format(q.question_id, tostring(serr)))
            os.exit(1)
        end
        local rank = rank_for(results)
        record(overall, rank)
        record(by_type[qtype], rank)
        per_question[#per_question + 1] = {
            question_id   = q.question_id,
            question_type = qtype,
            rank          = rank,
            n_haystack    = n_haystack,
            n_gold        = #(q.answer_session_ids or {}),
        }
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
    by_type       = {},
    per_question  = per_question,
}
for qtype, b in pairs(by_type) do
    report.by_type[qtype] = summarise(b)
end

if sweep_points then
    report.sweep = {
        weights_csv = args.sweep_weights,
        n_points    = #sweep_points,
        points      = {},
    }
    for _, p in ipairs(sweep_points) do
        local k = point_key(p)
        report.sweep.points[#report.sweep.points + 1] = {
            vector  = p.vector,
            fts     = p.fts,
            key     = k,
            metrics = summarise(point_buckets[k]),
        }
    end
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
print(string.format("questions     : %d   k_max=%d   elapsed=%ds",
    report.overall.n_questions, report.k_max, report.elapsed_sec))
print("")
print_row("OVERALL", report.overall)
print("")
print("by question_type:")
local types_sorted = {}
for k in pairs(report.by_type) do types_sorted[#types_sorted + 1] = k end
table.sort(types_sorted)
for _, k in ipairs(types_sorted) do print_row(k, report.by_type[k]) end

if report.sweep then
    print("")
    print("sweep over hybrid_weights (vector, fts):")
    local best_r5, best_label = -1, nil
    for _, pt in ipairs(report.sweep.points) do
        local label = string.format("v=%.2f f=%.2f", pt.vector, pt.fts)
        print_row(label, pt.metrics)
        if pt.metrics["recall@5"] > best_r5 then
            best_r5    = pt.metrics["recall@5"]
            best_label = label
        end
    end
    print(string.format("\n  best R@5: %s -> %s", best_label, fmt_pct(best_r5)))
end

os.execute("mkdir -p " .. (args.out:match("(.*)/") or "."))
local ofh = assert(io.open(args.out, "wb"))
ofh:write(cjson.encode(report))
ofh:close()
print("\nwrote " .. args.out)
