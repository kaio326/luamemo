-- eval/corpus_run.lua — benchmarks on the 100,000-entry corpus (eval/corpus/).
--
--   luajit eval/corpus_run.lua --suite scale   --db bench-100k.db --out r.json [--n N]
--   luajit eval/corpus_run.lua --suite learned --db bench-100k.db --out r.json [--points 100,1000,10000]
--
-- scale    The 'eval' queries (the last 30 % of each project's, never logged) searched the way an agent
--          searches: codeindex scopes with index_search's code path, repo scopes with memory_search's.
--          R@k / MRR / miss rate / bytes to hit overall and by category, difficulty (overlap bucket)
--          and source (mechanical vs rewritten by a model), and the time one search takes by the size
--          of the scope it ran in.
-- learned  The learned reranker's learning curve, on a COPY of the database: for each project with a
--          history, the real promotion gate (luamemo.promote) trains on the newest N outcomes of that
--          project and promotes only if it wins on its held-out split; the project's 'eval' queries are
--          then searched with and without the reranker. Paired differences, so the result is read as
--          "of the same queries, how many ranks moved". Trained on a simulated person (corpus/simulate.lua);
--          read with that caveat. The learned projection is not part of this suite: it re-embeds.
-- multiscope  The same questions asked over 1, 2, 4 and 8 scopes (the right one plus seeded distractors from the
--          corpus' other scopes), and over the project's own pair (repo: + codeindex:) against the right scope
--          alone: what widening a search costs in rank and time.
-- maintenance  Consolidation on a COPY: how long the near-duplicate search takes at several working-set sizes
--          (it looks at the `max_rows` most important rows; O(n²)), how much is redundant, and what collapsing
--          the redundant rows does to recall; digest and summarize as dry runs.
-- task_cost  The bytes an agent reads before the file that answers a question — code map against grep — on the
--          corpus' small projects (their source trees are read from this machine).
--
--   luajit eval/corpus_run.lua --suite multiscope|maintenance|task_cost --db bench-100k.db --out r.json [--n N]
--
-- The corpus' own embedder is used (its vectors are the database's); the benchmark never writes into the
-- database it is given (learned and maintenance work on a copy). memo eval runs it (benchmarks `scale`,
-- `learned`, `multiscope`, `maintenance`, `task_cost`).

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path
local json    = require("luamemo.json")
local util    = require("luamemo.util")
local metrics = require("eval.metrics")
local socket  = require("socket")

local args = { suite = "scale", db = nil, out = nil, n = nil, points = "100,1000,10000", gguf_model = nil }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--suite" then args.suite = arg[i + 1]; i = i + 2
        elseif a == "--db" then args.db = arg[i + 1]; i = i + 2
        elseif a == "--out" then args.out = arg[i + 1]; i = i + 2
        elseif a == "--n" then args.n = tonumber(arg[i + 1]); i = i + 2
        elseif a == "--points" then args.points = arg[i + 1]; i = i + 2
        elseif a == "--gguf-model" then args.gguf_model = arg[i + 1]; i = i + 2
        elseif a == "--embedder" then i = i + 2   -- (memo eval passes one: the corpus has its own)
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
    end
end
assert(args.out and args.db, "--db and --out are required")
local ok, why = require("corpus.build").is_bench_path(args.db)
if not ok then io.stderr:write(tostring(why), "\n"); os.exit(1) end
if not util.exists(args.db) then io.stderr:write("no benchmark database at " .. args.db .. " — memo eval build-corpus\n"); os.exit(1) end

local db_path = args.db
if args.suite == "learned" or args.suite == "maintenance" then   -- a copy: promotion writes weights, maintenance deletes rows
    db_path = args.out .. ".work.db"
    local base = db_path:match("([^/]+)$")
    if not base:match("^bench") then db_path = (db_path:match("^(.*)/") or ".") .. "/bench-work-" .. base end
    os.execute(("cp %s %s"):format(util.shell_quote(args.db), util.shell_quote(db_path)))
end

local setup = assert(require("corpus.build").embedder_from_meta(args.db, { gguf_model = args.gguf_model }))
setup.db, setup.skip_embed_probe = db_path, true
-- (to compare how importance weighs in ranking: MEMO_IMPORTANCE_CURVE=linear|sqrt|log luajit eval/corpus_run.lua …)
setup.importance_curve = require("luamemo.util").env("MEMO_IMPORTANCE_CURVE")
local memory = require("luamemo")
memory.setup(setup)
local db = require("luamemo.db")
local index, format = require("luamemo.index"), require("luamemo.index.format")

local function percentile(t, p)
    if #t == 0 then return nil end
    table.sort(t)
    return t[math.max(1, math.ceil(p / 100 * #t))]
end

-- Search one query the way an agent's tool does → rows.
local function search(q, opts)
    opts = opts or {}
    if q.scope:match("^codeindex:") then
        return index.search(q.query, { scope = q.scope, limit = 10 }) or {}
    end
    local a = { scope = q.scope, query = q.query, limit = 10, skip_feedback = true }
    if opts.rerank ~= nil then a.rerank = opts.rerank end
    return memory.search(a) or {}
end

local function rank_of(rows, want)
    for r, row in ipairs(rows) do if want[tonumber(row.id)] then return r end end
end

local function bytes_of_for(scope)
    if scope:match("^codeindex:") then return function(r) return #format.results({ r }) + 1 end end
    return nil
end

local function wanted(q)
    local want = {}
    for _, id in ipairs(json.decode(q.gold_ids)) do want[tonumber(id)] = true end
    return want
end

local function eval_queries(extra_where)
    return db.query("SELECT id, scope, project, category, query, gold_ids, bucket, source, holdout FROM bench_queries "
        .. "WHERE split = 'eval'" .. (extra_where or "") .. " ORDER BY id" .. (args.n and (" LIMIT " .. args.n) or "")) or {}
end

local function scope_size(scope, cache)
    if not cache[scope] then cache[scope] = tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope = ?", scope)) or 0 end
    return cache[scope]
end

-- ── scale ────────────────────────────────────────────────────────────────────

local function run_scale()
    local qs = eval_queries()
    local overall = metrics.new()
    local groups = { category = {}, bucket = {}, source = {} }
    local times, sizes = {}, {}
    local t_start = os.time()
    for i, q in ipairs(qs) do
        local t0 = socket.gettime()
        local rows = search(q)
        local ms = (socket.gettime() - t0) * 1000
        local rank = rank_of(rows, wanted(q))
        local bf = bytes_of_for(q.scope)
        metrics.record(overall, rank, rows, bf)
        for _, g in ipairs({ { "category", q.category }, { "bucket", q.bucket }, { "source", q.source } }) do
            local m = groups[g[1]][g[2]]
            if not m then m = metrics.new(); groups[g[1]][g[2]] = m end
            metrics.record(m, rank, rows, bf)
        end
        times[#times + 1] = ms
        local n = scope_size(q.scope, sizes)
        local cls = n >= 10000 and "ge10k" or (n >= 1000 and "1k_10k" or "lt1k")
        times[cls] = times[cls] or {}
        table.insert(times[cls], ms)
        if i % 500 == 0 then io.stderr:write(("  %d / %d queries, %ds\n"):format(i, #qs, os.time() - t_start)) end
    end
    local result = { suite = "scale", n = #qs, overall = metrics.summary(overall), by_category = {}, by_bucket = {}, by_source = {},
                     latency = {} }
    for k, m in pairs(groups.category) do result.by_category[k] = metrics.summary(m) end
    for k, m in pairs(groups.bucket) do result.by_bucket[k] = metrics.summary(m) end
    for k, m in pairs(groups.source) do result.by_source[k] = metrics.summary(m) end
    local all = {}
    for i = 1, #qs do all[i] = times[i] end
    result.overall.search_ms_p50, result.overall.search_ms_p95 = percentile(all, 50), percentile(all, 95)
    for _, cls in ipairs({ "lt1k", "1k_10k", "ge10k" }) do
        if times[cls] then
            result.latency[cls] = { n = #times[cls], p50 = percentile(times[cls], 50), p95 = percentile(times[cls], 95) }
        end
    end
    return result
end

-- ── learned ──────────────────────────────────────────────────────────────────

local function run_learned()
    local promote = require("luamemo.promote")
    -- (index_search's code path follows the config's rerank switch, memory_search's takes it per call:
    -- off for the baseline, on for the reranked pass)
    memory.config.rerank_adapter = "learned"
    memory.config.rerank_enabled = false
    -- the eval queries of projects that have a history (holdout projects have none)
    local qs = eval_queries(" AND holdout = 0 AND scope IN (SELECT DISTINCT scope FROM lm_reinforcements)")
    io.stderr:write(("  %d eval queries in projects with a history\n"):format(#qs))

    local base, by_scope = {}, {}
    for i, q in ipairs(qs) do
        local rows = search(q, { rerank = false })
        base[i] = rank_of(rows, wanted(q))
        by_scope[q.scope] = by_scope[q.scope] or {}
        table.insert(by_scope[q.scope], i)
    end
    local scopes = {}
    for s in pairs(by_scope) do scopes[#scopes + 1] = s end
    table.sort(scopes)

    local result = { suite = "learned", n = #qs, scopes = #scopes, curve = {}, overall = { n_questions = #qs } }
    local function r1(rank) return rank == 1 and 1 or 0 end
    local function rr(rank) return rank and 1 / rank or 0 end
    local b1, brr = 0, 0
    for i = 1, #qs do b1 = b1 + r1(base[i]); brr = brr + rr(base[i]) end
    result.overall["recall@1"], result.overall.mrr = b1 / math.max(#qs, 1), brr / math.max(#qs, 1)

    for pt in args.points:gmatch("%d+") do
        local limit = tonumber(pt)
        db.run("DELETE FROM lm_learner_weights"); db.run("DELETE FROM lm_promotion_runs")
        local promoted, rejected, skipped = {}, 0, 0
        for _, s in ipairs(scopes) do
            local d = promote.run(s, { harvest_limit = limit, min_samples = 20, candidate_limit = 20 })
            if d.decision == "promote" then promoted[s] = true elseif d.decision == "reject" then rejected = rejected + 1 else skipped = skipped + 1 end
        end
        local n, d1, drr, diffs = 0, 0, 0, {}
        -- (the reranker keeps each scope's weights in memory for the life of the process: without this the
        -- second and third points would be searched with the first point's weights)
        require("luamemo.rerankers.learned").reset_cache()
        memory.config.rerank_enabled = true
        for s in pairs(promoted) do
            for _, i in ipairs(by_scope[s]) do
                local rows = search(qs[i], { rerank = true })
                local rank = rank_of(rows, wanted(qs[i]))
                n = n + 1
                d1 = d1 + (r1(rank) - r1(base[i])); drr = drr + (rr(rank) - rr(base[i]))
                diffs[#diffs + 1] = r1(rank) - r1(base[i])
            end
        end
        memory.config.rerank_enabled = false
        local mean = n > 0 and d1 / n or 0
        local var = 0
        for _, x in ipairs(diffs) do var = var + (x - mean) ^ 2 end
        local ci = n > 1 and 1.96 * math.sqrt(var / (n - 1) / n) or nil
        local npromoted = 0
        for _ in pairs(promoted) do npromoted = npromoted + 1 end
        local point = { outcomes = limit, scopes_promoted = npromoted, scopes_rejected = rejected, scopes_skipped = skipped,
                        n_eval = n, d_recall1 = mean, d_recall1_ci95 = ci, d_mrr = n > 0 and drr / n or 0 }
        result.curve[#result.curve + 1] = point
        io.stderr:write(("  %6d outcomes: %d promoted / %d rejected / %d skipped; ΔR@1 %+.2f pts (±%.2f) over %d queries\n"):format(
            limit, npromoted, rejected, skipped, mean * 100, (ci or 0) * 100, n))
        result.overall["learned_promoted_" .. pt] = npromoted
        result.overall["learned_d_r1_" .. pt] = mean
        result.overall["learned_n_eval_" .. pt] = n
    end
    return result
end

-- ── multiscope ───────────────────────────────────────────────────────────────

-- A small seeded generator (no shared math.random state).
local function lcg(seed)
    local state = (tonumber(seed) or 1) % 2147483647
    if state == 0 then state = 1 end
    return function(n)
        state = (state * 48271) % 2147483647
        return (state % n) + 1
    end
end

local function run_multiscope()
    local all = eval_queries()
    local cap = args.n or 800
    local qs, stride = {}, math.max(1, math.floor(#all / cap))
    for i = 1, #all, stride do
        qs[#qs + 1] = all[i]
        if #qs >= cap then break end
    end
    -- the scopes a search can be widened with: the ones with real content
    local crowd = {}
    for _, r in ipairs(db.query("SELECT scope FROM lm_memories GROUP BY scope HAVING count(*) >= 100 ORDER BY scope") or {}) do
        crowd[#crowd + 1] = r.scope
    end
    local exists = {}
    for _, r in ipairs(db.query("SELECT DISTINCT scope FROM lm_memories") or {}) do exists[r.scope] = true end

    local VARIANTS = { { "s1", 1 }, { "s2", 2 }, { "s4", 4 }, { "s8", 8 } }
    local ms, mets = {}, {}
    for _, v in ipairs(VARIANTS) do mets[v[1]] = metrics.new(); ms[v[1]] = {} end
    local pair, pair_single = metrics.new(), metrics.new()
    local function ask(q, scopes)
        local t0 = socket.gettime()
        local rows = memory.search({ scope = q.scope, scopes = scopes, query = q.query, limit = 10, skip_feedback = true }) or {}
        return rows, (socket.gettime() - t0) * 1000
    end
    -- A row of another scope that says exactly what the gold row says (the same function in two copies of a
    -- library) answers the question as well: it counts as the hit.
    local function twin_rank(rows, want, twins)
        for r, row in ipairs(rows) do
            if want[tonumber(row.id)] or twins[row.title .. "\0" .. row.body] then return r end
        end
    end
    local t_start = os.time()
    for i, q in ipairs(qs) do
        local want, pick = wanted(q), lcg(q.id)
        local twins = {}
        for id in pairs(want) do
            for _, r in ipairs(db.query("SELECT title, body FROM lm_memories WHERE id = ?", id) or {}) do
                twins[r.title .. "\0" .. r.body] = true
            end
        end
        -- the other scopes of the set: a seeded draw without repeats, nested (s2 ⊂ s4 ⊂ s8)
        local fam = q.scope:match("^([^:]+):")
        local pool, rest = {}, {}
        for _, s in ipairs(crowd) do
            if s ~= q.scope then table.insert(s:match("^([^:]+):") == fam and pool or rest, s) end
        end
        local extra = {}
        for _ = 1, 7 do   -- (the same family first: another project's code for a code question, its memories for a note)
            local from = #pool > 0 and pool or rest
            if #from == 0 then break end
            extra[#extra + 1] = table.remove(from, pick(#from))
        end
        for _, v in ipairs(VARIANTS) do
            local scopes = { q.scope }
            for k = 1, v[2] - 1 do scopes[#scopes + 1] = extra[k] end
            local rows, t = ask(q, v[2] > 1 and scopes or nil)
            metrics.record(mets[v[1]], twin_rank(rows, want, twins), rows)
            table.insert(ms[v[1]], t)
        end
        if i % 100 == 0 then io.stderr:write(("  %d / %d queries, %ds\n"):format(i, #qs, os.time() - t_start)) end
    end
    -- the project's own two scopes (repo: + codeindex:), as an agent whose brief names both searches them
    local pq = {}
    for _, q in ipairs(all) do
        local other = q.scope:match("^repo:") and ("codeindex:" .. q.project) or (q.scope:match("^codeindex:") and ("repo:" .. q.project))
        if other and exists[other] then q.other = other; pq[#pq + 1] = q end
    end
    local pstride = math.max(1, math.floor(#pq / math.max(1, math.floor(cap / 4))))
    for i = 1, #pq, pstride do
        local q = pq[i]
        local want, twins = wanted(q), {}
        for id in pairs(want) do
            for _, r in ipairs(db.query("SELECT title, body FROM lm_memories WHERE id = ?", id) or {}) do twins[r.title .. "\0" .. r.body] = true end
        end
        local rows = ask(q, { q.scope, q.other })
        metrics.record(pair, twin_rank(rows, want, twins), rows)
        local single = ask(q, nil)
        metrics.record(pair_single, twin_rank(single, want, twins), single)
    end
    local o = { n_questions = #qs }
    for _, v in ipairs(VARIANTS) do
        local s = metrics.summary(mets[v[1]])
        o[v[1] .. "_r1"], o[v[1] .. "_r10"], o[v[1] .. "_mrr"] = s["recall@1"], s["recall@10"], s.mrr
        o[v[1] .. "_ms_p50"], o[v[1] .. "_ms_p95"] = percentile(ms[v[1]], 50), percentile(ms[v[1]], 95)
    end
    local ps, ss = metrics.summary(pair), metrics.summary(pair_single)
    o.pair_n, o.pair_r1, o.pair_r10, o.pair_single_r1, o.pair_single_r10 = ps.n_questions, ps["recall@1"], ps["recall@10"], ss["recall@1"], ss["recall@10"]
    return { suite = "multiscope", n = #qs, overall = o, scopes_in_corpus = #crowd }
end

-- ── maintenance ──────────────────────────────────────────────────────────────

local function run_maintenance()
    local summarizer, digest = require("luamemo.summarizer"), require("luamemo.digest")
    local o = {}
    local function biggest(like)
        return db.value("SELECT scope FROM lm_memories WHERE scope LIKE ? GROUP BY scope ORDER BY count(*) DESC LIMIT 1", like)
    end
    local function clock(f)
        local t0 = socket.gettime()
        local r = f()
        return r, (socket.gettime() - t0) * 1000
    end
    -- One scope: the cost of looking for near-duplicates at several working-set sizes (consolidate looks at the
    -- `max_rows` most important rows only; O(n²) in them), and what collapsing the groups it finds does to recall.
    local function one(scope, p, caps, recall_cap)
        o[p .. "rows"] = tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope = ?", scope))
        for _, cap in ipairs(caps) do
            local r, t = clock(function() return summarizer.consolidate({ scope = scope, dry_run = true, max_rows = cap }) end)
            local redundant = 0
            for _, c in ipairs(r.clusters or {}) do redundant = redundant + #c.ids - 1 end
            o[("%scons_ms_%d"):format(p, cap)] = t
            o[("%sclusters_%d"):format(p, cap)] = #(r.clusters or {})
            o[("%sredundant_%d"):format(p, cap)] = redundant
            o[("%sexpired_%d"):format(p, cap)] = #(r.expired or {})
            io.stderr:write(("  %s %d rows: consolidate over %d → %.0f ms, %d groups, %d redundant rows\n"):format(scope, o[p .. "rows"], cap, t, #(r.clusters or {}), redundant))
        end
        local qs = eval_queries((" AND scope = '%s'"):format(scope:gsub("'", "''")))
        local keep = {}
        for i = 1, math.min(#qs, 300) do keep[i] = qs[i] end
        local function recall()
            local r1, r10 = 0, 0
            for _, q in ipairs(keep) do
                local rank = rank_of(search(q), wanted(q))
                if rank == 1 then r1 = r1 + 1 end
                if rank then r10 = r10 + 1 end
            end
            return r1 / math.max(#keep, 1), r10 / math.max(#keep, 1)
        end
        o[p .. "n_eval"] = #keep
        o[p .. "r1_before"], o[p .. "r10_before"] = recall()
        -- What reducing each group to its first member (no summary written) does to recall, at the default
        -- similarity threshold (0.85) and at 0.95 — inside a transaction that is rolled back, so each reading
        -- starts from the whole scope. The groups at a threshold: how many, how many rows, the largest.
        for _, th in ipairs({ { 0.85, "" }, { 0.95, "_95" } }) do
            local r = summarizer.consolidate({ scope = scope, dry_run = true, max_rows = recall_cap, similarity_threshold = th[1] })
            local drop, largest = {}, 0
            for _, c in ipairs(r.clusters or {}) do
                largest = math.max(largest, #c.ids)
                for k = 2, #c.ids do drop[#drop + 1] = tonumber(c.ids[k]) end
            end
            db.run("BEGIN")
            for i = 1, #drop, 400 do
                db.run("DELETE FROM lm_memories WHERE id IN (" .. table.concat(drop, ",", i, math.min(i + 399, #drop)) .. ")")
            end
            local r1, r10 = recall()
            db.run("ROLLBACK")
            o[p .. "collapsed" .. th[2]], o[p .. "largest_group" .. th[2]] = #drop, largest
            o[p .. "r1_after" .. th[2]], o[p .. "r10_after" .. th[2]] = r1, r10
            io.stderr:write(("  %s: threshold %.2f — %d groups (largest %d), collapsing %d rows moves R@10 %.1f → %.1f %%\n"):format(
                scope, th[1], #(r.clusters or {}), largest, #drop, 100 * o[p .. "r10_before"], 100 * r10))
        end
    end
    -- The code index is out of consolidation's reach by design (it is not memory). To measure what the near-duplicate
    -- search costs on a scope of 20,000 memories, the largest code scope is re-scoped as `repo:bench-big` — in THIS copy
    -- of the database, with its questions — and treated as memory.
    local code_big = biggest("codeindex:%")
    local big
    if code_big then
        db.run("UPDATE lm_memories SET scope = 'repo:bench-big' WHERE scope = ?", code_big)
        db.run("UPDATE bench_queries SET scope = 'repo:bench-big' WHERE scope = ?", code_big)
        big = "repo:bench-big"
    end
    local repo = biggest("repo:%")
    if repo == big then repo = biggest("repo:luamemo%") end
    if big then one(big, "big_", { 500, 1000, 2000, 5000 }, 1000) end
    if repo then one(repo, "repo_", { 500, 1000, 2000 }, 1000) end
    o.big_scope, o.repo_scope = big, repo
    -- the other two jobs, read-only (what they would do, and how long it takes to find out)
    if repo then
        local dr, dt = clock(function() return select(2, pcall(digest.run, repo, { dry_run = true })) end)
        o.digest_ms = dt
        local sr, st = clock(function() return select(2, pcall(summarizer.run, { scope = repo, dry_run = true })) end)
        o.summarize_ms = st
        o.digest_ok, o.summarize_ok = type(dr) == "table", type(sr) == "table"
    end
    return { suite = "maintenance", n = (o.big_n_eval or 0) + (o.repo_n_eval or 0), overall = o }
end

-- ── task_cost ────────────────────────────────────────────────────────────────

-- The bytes an agent reads before the file that answers a question: with luamemo's code map
-- (index_search results up to the first one in the gold file) against grep (the question's words,
-- files read whole). On the corpus' own small projects, whose source trees are on this machine.
local function run_task_cost()
    local grep = require("eval.grep_baseline")
    local roots = {}
    for _, s in ipairs(require("corpus.sources").discover({})) do roots[s.name] = s.root end
    local projects = {}
    for _, r in ipairs(db.query("SELECT scope, count(*) AS n FROM lm_memories WHERE scope LIKE 'codeindex:%' AND kind = 'file' "
        .. "GROUP BY scope HAVING n BETWEEN 5 AND 400 ORDER BY scope") or {}) do
        local name = r.scope:sub(#"codeindex:" + 1)
        if roots[name] and util.exists(roots[name]) then projects[r.scope] = { name = name, root = roots[name] } end
    end
    local cache = {}
    local function files_of(scope)
        if cache[scope] then return cache[scope] end
        local list = {}
        for _, r in ipairs(db.query("SELECT json_extract(metadata, '$.path') AS path FROM lm_memories WHERE scope = ? AND kind = 'file' ORDER BY path", scope) or {}) do
            local f = io.open(projects[scope].root .. "/" .. r.path, "rb")
            if f then list[#list + 1] = { path = r.path, text = f:read("*a"):lower() }; f:close() end
        end
        cache[scope] = list
        return list
    end
    -- (the model-written questions are the fair test — a verbatim fragment is what grep is built for — so they
    -- take half of the sample when there are that many)
    local mech, llm = {}, {}
    for _, q in ipairs(eval_queries(" AND category IN ('symbol_doc', 'file_defines')")) do
        if projects[q.scope] then table.insert(q.source == "llm" and llm or mech, q) end
    end
    local cap = args.n or 300
    local qs = {}
    local function take(list, n)
        local stride = math.max(1, math.floor(#list / math.max(n, 1)))
        for i = 1, #list, stride do
            if n <= 0 then break end
            qs[#qs + 1] = list[i]
            n = n - 1
        end
    end
    take(llm, math.floor(cap / 2))
    take(mech, cap - #qs)
    local line_bytes = function(r) return #format.results({ r }) + 1 end
    local function median(t)
        if #t == 0 then return nil end
        table.sort(t)
        local mid = math.floor(#t / 2) + 1
        return #t % 2 == 1 and t[mid] or (t[mid - 1] + t[mid]) / 2
    end
    local groups = {}
    local function group(name)
        if not groups[name] then groups[name] = { m = metrics.new(), hit = {}, miss = 0, n = 0 } end
        return groups[name]
    end
    for _, q in ipairs(qs) do
        local gold = {}
        for _, id in ipairs(json.decode(q.gold_ids)) do
            local p = db.value("SELECT json_extract(metadata, '$.path') FROM lm_memories WHERE id = ?", tonumber(id))
            if p then gold[tostring(p)] = true end
        end
        local rows = index.search(q.query, { scope = q.scope, limit = metrics.LIMIT }) or {}
        local rank
        for i, r in ipairs(rows) do
            local p = type(r.metadata) == "table" and r.metadata.path
            if p and gold[p] then rank = i; break end
        end
        local grank, gbytes = grep.rank(files_of(q.scope), q.query, gold, metrics.LIMIT)
        for _, name in ipairs({ "all", q.source == "llm" and "llm" or "mechanical" }) do
            local g = group(name)
            metrics.record(g.m, rank, rows, line_bytes)
            g.n = g.n + 1
            if grank then g.hit[#g.hit + 1] = gbytes else g.miss = g.miss + 1 end
        end
    end
    local function summary(g)
        local s = metrics.summary(g.m)
        local sum = 0
        for _, v in ipairs(g.hit) do sum = sum + v end
        s.grep_bytes_to_hit_mean = #g.hit > 0 and sum / #g.hit or nil
        s.grep_bytes_to_hit_median = median(g.hit)
        s.grep_miss_rate = g.n > 0 and g.miss / g.n or 0
        return s
    end
    local result = { suite = "task_cost", n = #qs, overall = summary(group("all")), by_source = {}, projects = 0 }
    for name, g in pairs(groups) do if name ~= "all" then result.by_source[name] = summary(g) end end
    for _ in pairs(projects) do result.projects = result.projects + 1 end
    return result
end

local SUITES = { scale = run_scale, learned = run_learned, multiscope = run_multiscope, maintenance = run_maintenance,
                 task_cost = run_task_cost }
local runner = SUITES[args.suite]
if not runner then io.stderr:write("unknown suite " .. tostring(args.suite) .. " (scale, learned, multiscope, maintenance, task_cost)\n"); os.exit(2) end
local result = runner()
result.importance_curve = require("luamemo.settings").value(memory.config, "importance_curve")
result.corpus = { rows = tonumber(db.value("SELECT count(*) FROM lm_memories")), embedder = db.value("SELECT value FROM lm_meta WHERE key = 'bench_embedder'") }
local sim = db.value("SELECT value FROM lm_meta WHERE key = 'bench_sim'")
if sim then result.simulated_user = json.decode(tostring(sim)) end
local jf = assert(io.open(args.out, "w"))
jf:write(json.encode(result)); jf:close()
if db_path ~= args.db then
    for _, sfx in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. sfx) end
end
local o = result.overall
if args.suite == "scale" then
    print(("scale: %d queries · R@1 %.1f %% · R@10 %.1f %% · miss %.1f %% · bytes to hit %s · search p50 %.0f ms / p95 %.0f ms"):format(
        result.n, 100 * o["recall@1"], 100 * o["recall@10"], 100 * o.miss_rate, tostring(o.bytes_to_hit_mean and math.floor(o.bytes_to_hit_mean) or "—"),
        o.search_ms_p50 or 0, o.search_ms_p95 or 0))
elseif args.suite == "multiscope" then
    print(("multiscope: %d queries · R@1 %.1f / %.1f / %.1f / %.1f %% with 1 / 2 / 4 / 8 scopes · project pair %.1f %% vs alone %.1f %%"):format(
        result.n, 100 * o.s1_r1, 100 * o.s2_r1, 100 * o.s4_r1, 100 * o.s8_r1, 100 * (o.pair_r1 or 0), 100 * (o.pair_single_r1 or 0)))
elseif args.suite == "maintenance" then
    print(("maintenance: consolidate over 1000 rows %.0f ms (%s), %d redundant rows collapsed moves R@10 %.1f → %.1f %%"):format(
        o.big_cons_ms_1000 or 0, tostring(o.big_scope), o.big_collapsed or 0, 100 * (o.big_r10_before or 0), 100 * (o.big_r10_after or 0)))
elseif args.suite == "task_cost" then
    print(("task_cost: %d questions in %d projects · code map R@1 %.1f %% · bytes to hit %s · grep bytes to hit %s / miss %.1f %%"):format(
        result.n, result.projects, 100 * o["recall@1"], tostring(o.bytes_to_hit_mean and math.floor(o.bytes_to_hit_mean) or "—"),
        tostring(o.grep_bytes_to_hit_mean and math.floor(o.grep_bytes_to_hit_mean) or "—"), 100 * (o.grep_miss_rate or 0)))
end
