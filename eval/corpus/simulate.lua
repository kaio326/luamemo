-- eval/corpus/simulate.lua — eighteen months of use, replayed through luamemo's own code.
--
-- The learned reranker / projection train on what real use leaves behind: which memories a
-- search offered (lm_retrieval_feedback) and what the person said about them afterwards
-- (lm_reinforcements: praise, mistake, direct_command, miss). A benchmark database has no such
-- history, so this stage makes one: it replays the corpus' 'history' queries (corpus/queries.lua)
-- in time order through the REAL search (store.search with feedback on — it writes the
-- retrieval log itself) and writes the outcomes through the REAL feedback writer. The only
-- invented part is the person, and it is explicit — a click model with the parameters below,
-- recorded in lm_meta (bench_sim), so a result can always be read with them:
--
--   attention at rank r        1 / (1 + 0.4 (r - 1))      position bias: the first results are read
--   uses the gold if examined  0.9
--   used the gold   → praise 0.30 · direct_command 0.03   (a confirmed, useful memory)
--   gold offered but not read  → mistake 0.35              (the agent erred; the person corrected it)
--   gold not offered           → miss 0.50                 (retrieval failed; found by other means)
--   label noise                → 0.04 of the events go to the first result instead of the gold
--
-- A learner can overfit this model of a person; every result trained on it carries that caveat.
-- Holdout projects (about 2 in 10) are never logged: global weights are judged on them.
--
--   run(path, opts) → { queries, logged, reinforcements, by_type }
--   opts: seed, limit (queries), say, search(q) (tests), params (override)

local util = require("luamemo.util")
local json = require("luamemo.json")

local M = {}

local WEEK_US = 7 * 24 * 3600 * 1000000
M.HEAVY_CYCLES, M.HEAVY_MIN = 6, 200

M.PARAMS = { attention = 0.4, use_gold = 0.9, praise = 0.30, direct_command = 0.03, mistake = 0.35, miss = 0.50, noise = 0.04 }

-- A small reproducible generator (no math.random state shared with anything else).
local function rng(seed)
    local state = (tonumber(seed) or 1) % 2147483647
    if state == 0 then state = 1 end
    return function()
        state = (state * 48271) % 2147483647
        return state / 2147483647
    end
end

--- The event (if any) one search leaves behind, given where the gold ranked.
--- rank: the gold's position among the results (nil: not offered); first_id: the first result.
--- → { type, memory_id } | nil
function M.outcome(rank, gold_id, first_id, rand, p)
    p = p or M.PARAMS
    local target = gold_id
    local noisy = rand() < p.noise and first_id ~= nil
    if noisy then target = first_id end
    if rank then
        local examined = rand() < 1 / (1 + p.attention * (rank - 1))
        if examined and rand() < p.use_gold then
            local r = rand()
            if r < p.direct_command then return { type = "direct_command", memory_id = target } end
            if r < p.direct_command + p.praise then return { type = "praise", memory_id = target } end
            return nil
        end
        if rand() < p.mistake then return { type = "mistake", memory_id = target } end
        return nil
    end
    if rand() < p.miss then return { type = "miss", memory_id = target } end
    return nil
end

local function ids_of(rows)
    local out = {}
    for i, r in ipairs(rows or {}) do out[i] = tonumber(r.id) end
    return out
end

function M.run(path, opts)
    opts = opts or {}
    local say = opts.say or function(_) end
    local ok, why = require("corpus.build").is_bench_path(path)
    if not ok then return nil, why end
    local memory = require("luamemo")
    local setup, serr = require("corpus.build").embedder_from_meta(path, opts)
    if not setup then return nil, serr end
    setup.db, setup.skip_embed_probe, setup.feedback_enabled = path, true, true
    memory.setup(setup)
    local db = require("luamemo.db")
    local feedback = require("luamemo.feedback")
    local index = require("luamemo.index")
    local rand, p = rng(opts.seed or 1), setmetatable(opts.params or {}, { __index = M.PARAMS })

    -- start from no history: a rerun replays the same queries, it does not append to an earlier run
    db.run("DELETE FROM lm_reinforcements")
    db.run("DELETE FROM lm_retrieval_feedback")

    local queries = db.query("SELECT id, scope, query, gold_ids, t FROM bench_queries WHERE split = 'history' AND holdout = 0 "
        .. "AND source != 'llm' ORDER BY t, id" .. (opts.limit and (" LIMIT " .. tonumber(opts.limit)) or "")) or {}
    -- and the paraphrases of the same questions: asked as a person would, they leave the same kind of trace
    local llm = db.query("SELECT id, scope, query, gold_ids, t FROM bench_queries WHERE split = 'history' AND holdout = 0 "
        .. "AND source = 'llm' ORDER BY t, id") or {}
    for _, q in ipairs(llm) do queries[#queries + 1] = q end
    -- A busy project is asked the same things again: the scopes with at least heavy_min history questions
    -- get each of them asked (heavy_cycles - 1) more times, a week apart, so the learning curve has points
    -- beyond what one pass over the questions leaves (1000 and 10000 outcomes in the largest scopes).
    local cycles, heavy_min = math.max(1, tonumber(opts.heavy_cycles) or M.HEAVY_CYCLES), tonumber(opts.heavy_min) or M.HEAVY_MIN
    local real_now = util.now_us
    local per_scope = {}
    for _, q in ipairs(queries) do per_scope[q.scope] = (per_scope[q.scope] or 0) + 1 end
    local base_n, heavy = #queries, {}
    local nheavy = 0
    for s, n in pairs(per_scope) do if n >= heavy_min then heavy[s] = n; nheavy = nheavy + 1 end end
    for c = 1, cycles - 1 do
        for i = 1, base_n do
            local q = queries[i]
            if heavy[q.scope] then
                local t = math.min((tonumber(q.t) or 0) + c * WEEK_US, real_now())
                queries[#queries + 1] = { id = q.id, scope = q.scope, query = q.query, gold_ids = q.gold_ids, t = t }
            end
        end
    end
    table.sort(queries, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.id < b.id end)

    -- the replay runs on the questions' own clock: util.now_us says when the question being replayed was asked
    local clock = 0
    util.now_us = function() return clock end
    local by_type, logged, n_reinf = {}, 0, 0
    local search = opts.search or function(q)
        if q.scope:match("^codeindex:") then
            return index.search(q.query, { scope = q.scope, limit = 15 })
        end
        return memory.search({ scope = q.scope, query = q.query, limit = 10 })
    end
    local okrun, err = pcall(function()
        db.run("BEGIN")
        for i, q in ipairs(queries) do
            clock = tonumber(q.t) or clock
            local rows = search(q) or {}
            local ids = ids_of(rows)
            local gold = json.decode(q.gold_ids)
            local want = {}
            for _, g in ipairs(gold) do want[g] = true end
            local rank
            for r, id in ipairs(ids) do if want[id] then rank = r; break end end
            logged = logged + 1
            local ev = M.outcome(rank, rank and ids[rank] or gold[1], ids[1], rand, p)
            if ev then
                feedback.record_reinforcement(ev.memory_id, q.scope, ev.type, nil, "sim")
                n_reinf = n_reinf + 1
                by_type[ev.type] = (by_type[ev.type] or 0) + 1
            end
            if i % 2000 == 0 then
                db.run("COMMIT"); db.run("BEGIN")
                say(("%d / %d replayed, %d reinforcements"):format(i, #queries, n_reinf))
            end
        end
        db.run("COMMIT")
    end)
    util.now_us = real_now
    if not okrun then pcall(db.run, "ROLLBACK"); return nil, tostring(err) end
    db.run("INSERT OR REPLACE INTO lm_meta (key, value) VALUES ('bench_sim', ?)", json.encode({ params = {
        attention = p.attention, use_gold = p.use_gold, praise = p.praise, direct_command = p.direct_command,
        mistake = p.mistake, miss = p.miss, noise = p.noise }, seed = opts.seed or 1, queries = #queries,
        reinforcements = n_reinf, by_type = by_type, heavy = { cycles = cycles, min = heavy_min, scopes = nheavy } }))
    return { queries = #queries, logged = logged, reinforcements = n_reinf, by_type = by_type, heavy_scopes = nheavy }
end

return M
