-- eval/run.lua
--
-- Run a retrieval evaluation of lapis-memory against LongMemEval.
--
-- Pipeline:
--   1. Load dataset rows (eval.datasets.longmemeval.load).
--   2. Configure a fresh lapis_memory_eval table with the chosen embedder.
--   3. Per question: write the haystack sessions (one memory per session,
--      scoped to that question), then run search(question, top_k=10).
--   4. Record the ranked session_ids alongside the gold `answer_session_ids`.
--   5. Write a results JSON file. Pipe it into `eval/score.lua` to get R@k.
--
-- Usage (from a Lapis app shell or `resty` REPL with cwd=lapis-memory):
--
--   resty -I . eval/run.lua \
--      --dataset eval/data/longmemeval_oracle.json \
--      --out     eval/results/oracle_hash.json \
--      --embedder hash
--
-- LIMITATION: requires a working pgvector connection (configured the same
-- way as the host Lapis app) plus an embedder. Pure Lua runs of the eval
-- with the hash embedder need no extra services; ollama / openai do.

local cjson    = require("cjson.safe")
local memory   = require("lapis_memory")
local dataset  = require("eval.datasets.longmemeval")

local function parse_args(argv)
    local opts = {
        dataset  = "eval/data/longmemeval_oracle.json",
        out      = "eval/results/results.json",
        embedder = "hash",
        top_k    = 10,
        limit    = nil,
    }
    local i = 1
    while i <= #argv do
        local k = argv[i]:gsub("^%-+", "")
        local v = argv[i + 1]
        if k == "limit" or k == "top_k" then v = tonumber(v) end
        opts[k] = v
        i = i + 2
    end
    return opts
end

local function setup_memory(opts)
    -- Use a dedicated table so the eval cannot pollute production data.
    local cfg = {
        db_table       = "lapis_memory_eval",
        embedder_local = (opts.embedder == "hash") and "hash" or nil,
        embedder_url   = opts.embedder_url,
        embedder_adapter = (opts.embedder ~= "hash") and opts.embedder or "generic",
        embedder_model = opts.embedder_model,
        embed_dim      = tonumber(opts.embed_dim) or 384,
        default_scope  = "eval",
        auth_fn        = function() return true end,
        dedup_enabled  = false,   -- we want every haystack session as its own row
    }
    memory.setup(cfg)
end

local function reset_table()
    local db = require("lapis.db")
    db.query("TRUNCATE TABLE lapis_memory_eval RESTART IDENTITY")
end

local function run(opts)
    print("[eval] dataset=" .. opts.dataset .. " embedder=" .. opts.embedder)
    setup_memory(opts)
    reset_table()

    local rows = dataset.load(opts.dataset)
    if opts.limit then
        local trimmed = {}
        for i = 1, math.min(opts.limit, #rows) do trimmed[i] = rows[i] end
        rows = trimmed
    end
    print(("[eval] %d questions"):format(#rows))

    local results = {}
    local t_start = os.time()

    for qi, q in ipairs(rows) do
        local scope = "longmemeval:" .. tostring(q.question_id)
        -- 1. Write the haystack sessions for this question.
        for sid, turns in pairs(q.haystack_sessions or {}) do
            memory.write({
                scope    = scope,
                kind     = "session",
                title    = sid,
                body     = dataset.session_to_body(turns),
                metadata = { session_id = sid },
                dedup_strategy = "append",
            })
        end

        -- 2. Search.
        local hits, serr = memory.search({
            query = q.question, scope = scope, limit = opts.top_k,
            ignore_decay = true,
        })
        local retrieved = {}
        if hits then
            for _, h in ipairs(hits) do
                retrieved[#retrieved + 1] = h.title
            end
        end

        results[#results + 1] = {
            question_id        = q.question_id,
            question           = q.question,
            answer             = q.answer,
            question_type      = q.question_type,
            answer_session_ids = q.answer_session_ids,
            retrieved          = retrieved,
            error              = serr,
        }

        if qi % 25 == 0 or qi == #rows then
            print(("[eval] %d/%d  elapsed=%ds"):format(qi, #rows, os.time() - t_start))
        end
    end

    -- Write results JSON.
    os.execute("mkdir -p " .. (opts.out:match("(.*)/") or "."))
    local fh = assert(io.open(opts.out, "wb"))
    fh:write(cjson.encode({
        meta = {
            dataset  = opts.dataset,
            embedder = opts.embedder,
            top_k    = opts.top_k,
            n        = #results,
            seconds  = os.time() - t_start,
        },
        results = results,
    }))
    fh:close()
    print("[eval] wrote " .. opts.out)
end

return run(parse_args(arg or {}))
