-- eval/tests/test_learned_gate.lua
-- The learned reranker is trained and gated on what search really does.
--   A. labels: a confirmation labels the search just before it, and nothing else
--   B. features: `reuse` reaches the model at search time, as of each label's own moment, by one path
--   C. the gate: reproducible, split by query, and able to say no (probes: a memory's own title finds it)
--   D. the regression corpus, end to end: the confirmed memory rises and what was already right stays right
--   E. models from before this gate are not served
-- Run: luajit eval/tests/run.lua --only learned_gate

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Learned reranker gate")
local check, section, finish = T.check, T.section, T.finish

local luamemo     = require("luamemo")
local db          = require("luamemo.db")
local util        = require("luamemo.util")
local store       = require("luamemo.store")
local feedback    = require("luamemo.feedback")
local promote     = require("luamemo.promote")
local learned     = require("luamemo.rerankers.learned")
local trainer     = require("luamemo.rerank_train")
local lstore      = require("luamemo.learner_store")
local maintenance = require("luamemo.maintenance")

maintenance.spawner = function() return true end   -- (no `memo maintain` beside the test)

local MINUTE, HOUR = 60 * 1000000, 3600 * 1000000

local function setup(extra)
    H.setup(extra, { feedback_enabled = true, auto_digest_enabled = false, rerank_enabled = false,
                     rerank_adapter = "learned", rerank_top_n = 20 })
    learned.reset_cache()
end

-- ---------------------------------------------------------------------------
-- The regression corpus: six topics; in each, the memory the user keeps confirming is NOT the best text match.
-- Its four "guide" memories nearly repeat each other, so writing them records `miss` events nobody chose to make.
-- ---------------------------------------------------------------------------
local TOPICS = {
    { "invoice", "supplier", "payment", "due", "amount" }, { "warehouse", "stock", "item", "count", "level" },
    { "contract", "renewal", "client", "term", "notice" }, { "employee", "payroll", "salary", "month", "bonus" },
    { "shipment", "carrier", "tracking", "parcel", "route" }, { "refund", "customer", "order", "return", "reason" },
}
local EXTRA = { "please", "kindly", "again", "first", "quickly", "soon" }   -- (no word that reads as a time: those are not trained on)

local function world(scope, confirm_upto)
    local w = { scope = scope, targets = {}, train = {}, held = {}, controls = {} }
    for t, words in ipairs(TOPICS) do
        for d = 1, 4 do
            local title = words[1] .. " guide " .. d
            local row = assert(luamemo.write({ scope = scope, kind = "fact", title = title,
                body = table.concat(words, " ") .. " reference number " .. d, dedup_strategy = "append" }))
            local id = tonumber(row.id)
            if id % 2 == 1 then
                -- the right answer is a memory nobody ever confirmed, asked in words no probe uses
                w.controls[#w.controls + 1] = { q = title .. " reference number " .. d, target = id, word = words[1] }
            end
        end
        local row = assert(luamemo.write({ scope = scope, kind = "fact", title = words[1] .. " house rule",
            body = words[1] .. " handled the way this team prefers", dedup_strategy = "append" }))
        w.targets[t] = tonumber(row.id)
        for k, x in ipairs(EXTRA) do
            local c = { q = words[1] .. " " .. words[2] .. " " .. words[3] .. " " .. x, target = w.targets[t], word = words[1] }
            local list = (k <= 4) and w.train or w.held
            list[#list + 1] = c
        end
    end
    for i, c in ipairs(w.train) do
        if not confirm_upto or i <= confirm_upto then
            assert(luamemo.search({ query = c.q, scope = scope, limit = 20 }))
            assert(feedback.record_reinforcement(c.target, scope, "praise", 0.5))
        end
    end
    return w
end

local SEARCH = { limit = 20, skip_temporal = true, skip_observations = true, skip_feedback = true }
local function search(scope, q, rerank, weights)
    local args = { query = q, scope = scope, rerank = rerank, rerank_weights = weights }
    for k, v in pairs(SEARCH) do args[k] = v end
    return store.search(args) or {}
end
local function ids(rows) local o = {}; for i, r in ipairs(rows) do o[i] = tostring(r.id) end; return table.concat(o, ",") end
local function rank_in(rows, id)
    for i, r in ipairs(rows) do if tonumber(r.id) == id then return i end end
    return 99
end
local function median(list)
    table.sort(list)
    return list[math.ceil(#list / 2)]
end

-- A model with the format this release serves, whatever that is.
local function model(fields)
    local w = trainer.prior()
    w.format = learned.MODEL_FORMAT
    for k, v in pairs(fields or {}) do w[k] = v end
    return w
end

-- Run fn and keep every pool the model was shown: { ids = "1,2,3", hits, features }.
local function pools_during(fn)
    local calls, real = {}, learned.pool_features
    H.with(learned, "pool_features", function(hits)
        local f = real(hits)
        local ids = {}
        for i, h in ipairs(hits) do ids[i] = tostring(tonumber(h.id)) end
        calls[#calls + 1] = { ids = table.concat(ids, ","), hits = hits, features = f }
        return f
    end, fn)
    return calls
end

local function memories(scope, n) return H.filler_memories(scope, n, { title = "note", body = "the note about subject number" }) end
local search_row, event_row = H.search_row, H.event_row

-- ---------------------------------------------------------------------------
section("A. a confirmation labels the search just before it, and nothing else", function()
    setup()
    local S = "repo:lg-a"
    local ids = memories(S, 10)
    local now = util.now_us()
    local function labels(mem)
        local out = {}
        for _, t in ipairs(feedback.harvest(S, {})) do
            if tonumber(t.positive) == mem then out[#out + 1] = t end
        end
        return out
    end

    search_row(S, "the search before", { ids[1], ids[8] }, nil, nil, now - 2 * MINUTE)
    search_row(S, "an older search before", { ids[1], ids[8] }, nil, nil, now - 4 * MINUTE)
    search_row(S, "a search after", { ids[1], ids[8] }, nil, nil, now + 2 * MINUTE)
    event_row(S, ids[1], "praise", nil, nil, now)
    local a = labels(ids[1])
    check("only the newest search before the confirmation is its label", #a == 1 and a[1].query == "the search before",
        #a .. " labels; first: " .. tostring(a[1] and a[1].query))
    check("the label says when that search ran", a[1] and tonumber(a[1].at) == now - 2 * MINUTE, a[1] and tostring(a[1].at))
    check("the others it offered are the negatives", a[1] and #a[1].negatives == 1 and tonumber(a[1].negatives[1]) == ids[8])

    search_row(S, "long before", { ids[2], ids[8] }, nil, nil, now - 2 * HOUR)
    event_row(S, ids[2], "praise", nil, nil, now)
    check("a search more than the window before it is no label", #labels(ids[2]) == 0)

    event_row(S, ids[3], "direct_command", nil, nil, now)
    check("a reinforcement with no search before it is no label", #labels(ids[3]) == 0)

    search_row(S, "search before a reversal", { ids[4], ids[8] }, nil, nil, now - MINUTE)
    event_row(S, ids[4], "reversal", nil, nil, now)
    check("a reversal is no positive (the digest lowers that memory, the fold counts it as wrong)", #labels(ids[4]) == 0)

    search_row(S, "dev one's search", { ids[5], ids[8] }, "user:one", "r1", now - MINUTE)
    event_row(S, ids[5], "praise", "user:two", "e1", now)
    check("one device's confirmation is not labelled by another's search", #labels(ids[5]) == 0)
    search_row(S, "dev two's search", { ids[5], ids[8] }, "user:two", "r2", now - 5 * MINUTE)
    local e = labels(ids[5])
    check("… its own device's search is", #e == 1 and e[1].query == "dev two's search", e[1] and e[1].query)

    search_row(S, "offered alone", { ids[6] }, nil, nil, now - MINUTE)
    event_row(S, ids[6], "praise", nil, nil, now)
    check("a search that offered nothing else has no negatives, so no label", #labels(ids[6]) == 0)

    -- the same query and memory: a correction outweighs praise
    search_row(S, "asked and corrected", { ids[7], ids[8] }, nil, nil, now - 3 * MINUTE)
    event_row(S, ids[7], "praise", nil, nil, now - MINUTE)
    event_row(S, ids[7], "mistake", nil, nil, now)
    local d = labels(ids[7])
    check("one label per query and memory, the strongest signal", #d == 1 and d[1].weight == 3.0 and d[1].signal == "mistake",
        d[1] and tostring(d[1].weight))

    -- one search, two confirmed memories: the same moment, so the memory decides the order
    search_row(S, "offered two at once", { ids[10], ids[9], ids[8] }, nil, nil, now - 7 * MINUTE)
    event_row(S, ids[10], "praise", nil, nil, now)
    event_row(S, ids[9], "praise", nil, nil, now)

    local all, sorted = feedback.harvest(S, {}), true
    for i = 2, #all do
        local a1, b1 = all[i - 1], all[i]
        if tonumber(a1.at) > tonumber(b1.at) then sorted = false end
    end
    check("harvest's order is fixed: by when the search ran", #all >= 5 and sorted and all[3].query == "dev two's search"
        and all[#all].query == "the search before", all[3] and all[3].query)
    check("… and, in the same moment, by the memory", all[1].query == "offered two at once" and tonumber(all[1].positive) == ids[9]
        and all[2].query == "offered two at once" and tonumber(all[2].positive) == ids[10], tostring(all[1].positive))
end)

section("A. harvest's limit counts reinforcements, not labels", function()
    setup()
    local S = "repo:lg-a3"
    local m = memories(S, 3)
    local now = util.now_us()
    search_row(S, "the labelled search", { m[1], m[3] }, nil, nil, now - 2 * MINUTE)
    event_row(S, m[1], "praise", nil, nil, now - MINUTE)
    event_row(S, m[2], "direct_command", nil, nil, now)   -- the newest, and no search before it
    check("limit 1 reads only the newest reinforcement, which labels nothing", #feedback.harvest(S, { limit = 1 }) == 0)
    check("limit 2 reaches the one that does", #feedback.harvest(S, { limit = 2 }) == 1)
end)

section("A. what writing a corpus records never labels anything", function()
    setup()
    local S = "repo:lg-a2"
    local w = world(S)
    local is_target = {}
    for _, id in ipairs(w.targets) do is_target[id] = true end
    local triples, stray = feedback.harvest(S, {}), 0
    for _, t in ipairs(triples) do if not is_target[tonumber(t.positive)] then stray = stray + 1 end end
    check("the corpus's near-duplicate writes did record misses", H.count("SELECT count(*) FROM lm_reinforcements WHERE scope = ? AND event_type = 'miss'", S) > 0)
    check("the 24 confirmations give 24 labels, all on the confirmed memories", #triples == 24 and stray == 0,
        #triples .. " labels, " .. stray .. " on other memories")
end)

-- ---------------------------------------------------------------------------
section("B. enrich: confirmed use, as of a moment", function()
    setup()
    local S = "repo:lg-b"
    local ids = memories(S, 3)
    local now = util.now_us()
    event_row(S, ids[1], "praise", nil, nil, now - 3 * HOUR)
    event_row(S, ids[1], "direct_command", nil, nil, now - 2 * HOUR)
    event_row(S, ids[1], "praise", nil, nil, now - HOUR)
    event_row(S, ids[1], "mistake", nil, nil, now - HOUR)
    event_row(S, ids[1], "miss", nil, nil, now - HOUR)
    event_row(S, ids[1], "reversal", nil, nil, now - HOUR)
    local hits = { { id = ids[1] }, { id = ids[2] }, { title = "no id" } }
    learned.enrich(hits)
    check("now: every confirmation of it, and only confirmations (praise, direct command)", hits[1].reuse_count == 3, tostring(hits[1].reuse_count))
    check("a memory never confirmed: 0", hits[2].reuse_count == 0, tostring(hits[2].reuse_count))
    check("a hit with no id is left alone and costs nothing", hits[3].reuse_count == nil)
    learned.enrich(hits, now - 2 * HOUR)
    check("as of a moment: only what came strictly before it", hits[1].reuse_count == 1, tostring(hits[1].reuse_count))
    learned.enrich(hits, now - 4 * HOUR)
    check("before anything: 0", hits[1].reuse_count == 0, tostring(hits[1].reuse_count))
end)

section("B. search hands the model the confirmations", function()
    setup()
    local S = "repo:lg-b2"
    local w = world(S)
    local calls = pools_during(function() search(S, w.held[1].q, true, model()) end)
    local seen
    for _, h in ipairs(calls[1] and calls[1].hits or {}) do
        if tonumber(h.id) == w.targets[1] then seen = h.reuse_count end
    end
    check("the confirmed memory reaches the model with its 4 confirmations", seen == 4, tostring(seen))

    local n, real = 0, learned.enrich
    H.with(learned, "enrich", function(...) n = n + 1; if real then return real(...) end end, function()
        search(S, w.held[1].q, true)
        check("no promoted model: the database is not asked", n == 0, n)
        setup({ rerank_adapter = "noop" })
        search(S, w.held[1].q, true)
        check("another reranker: the database is not asked", n == 0, n)
        setup()
    end)
end)

section("B. the gate scores exactly what search hands the model", function()
    setup()
    local S = "repo:lg-b3"
    local w = world(S)
    local q = w.train[1].q:gsub("please", "friendly")
    check("the query has no time in it (those are not trained on)", require("luamemo.temporal").parse(q) == nil)
    -- a raw session event that matches the query: memory_search hides it, so training must not see it either
    local raw = assert(store.write({ scope = S, title = "raw event", body = q, importance = 0.1, dedup_strategy = "append" }))
    check("the raw event is tier 0", tonumber(raw.tier) == 0, tostring(raw.tier))
    local served = pools_during(function()
        luamemo.search({ query = q, scope = S, limit = 20, rerank = true, rerank_weights = model(), tier_min = store.DEFAULT_TIER_MIN,
                         skip_temporal = true, skip_observations = true })
    end)
    assert(feedback.record_reinforcement(w.targets[1], S, "praise", 0.5))
    assert(served[1], "the served search did not rerank")
    local labelled = false
    for _, t in ipairs(feedback.harvest(S, {})) do if t.query == q then labelled = true end end
    check("that search is a label", labelled)
    local trained = pools_during(function() promote.run(S, { dry_run = true }) end)
    local match
    for _, c in ipairs(trained) do if c.ids == served[1].ids then match = c end end
    check("training rebuilt that very pool", match ~= nil)
    local worst = 0
    if match then
        for i, fv in ipairs(served[1].features) do
            for _, name in ipairs(learned.FEATURES) do
                worst = math.max(worst, math.abs((fv[name] or 0) - (match.features[i][name] or 0)))
            end
        end
    end
    check("every feature of every candidate is the one search used (1e-9)", match ~= nil and worst < 1e-9, worst)
    local reuse_used = false
    for _, fv in ipairs(served[1].features) do if fv.reuse > 0 then reuse_used = true end end
    check("… and reuse is one of them", reuse_used)

    -- a confirmation after the search changes nothing about what that search saw
    assert(feedback.record_reinforcement(w.targets[1], S, "praise", 0.5))
    local again = pools_during(function() promote.run(S, { dry_run = true }) end)
    local same
    for _, c in ipairs(again) do if c.ids == served[1].ids then same = c end end
    local moved = 0
    if same then
        for i, fv in ipairs(match and match.features or {}) do moved = math.max(moved, math.abs(fv.reuse - same.features[i].reuse)) end
    end
    check("a later confirmation does not rewrite that example", same ~= nil and moved < 1e-9, moved)
end)

section("B. an example knows only what its search could have known", function()
    setup()
    local S = "repo:lg-b6"
    local w = world(S, 0)   -- nothing confirmed yet
    local c = w.train[1]
    assert(luamemo.search({ query = c.q, scope = S, limit = 20 }))
    assert(feedback.record_reinforcement(c.target, S, "praise", 0.5))
    local pools = pools_during(function() promote.run(S, { dry_run = true, min_samples = 1 }) end)
    local target_at, hits_now
    for i, h in ipairs(pools[1] and pools[1].hits or {}) do
        if tonumber(h.id) == c.target then target_at = pools[1].features[i].reuse; hits_now = { { id = h.id } } end
    end
    check("nothing had been confirmed when that search ran, so its example has no reuse", target_at == 0, tostring(target_at))
    learned.enrich(hits_now or {})
    check("… though search would see the confirmation now", hits_now and hits_now[1].reuse_count == 1)
end)

section("B. training searches the pool search would rerank", function()
    setup({ rerank_top_n = 8 })
    local S = "repo:lg-b4"
    world(S)
    local limits, real = {}, store.search
    H.with(store, "search", function(args) limits[args.limit] = true; return real(args) end, function()
        promote.run(S, { dry_run = true })
    end)
    local list = {}
    for l in pairs(limits) do list[#list + 1] = l end
    check("MEMO_RERANK_TOP_N sets the training pool too", #list == 1 and list[1] == 8, table.concat(list, ","))
    setup({ rerank_top_n = 150 })
    check("… up to the 100 search fetches for the reranker", learned.pool(S, "invoice supplier payment", {}) ~= nil
        and store.rerank_pool_size() == 100 and store.rerank_pool_size(30) == 30, store.rerank_pool_size())
    setup()
end)

section("B. a label's weight reaches its example", function()
    setup()
    local S = "repo:lg-b8"
    local w = world(S)
    local q = "invoice supplier payment corrected"
    assert(luamemo.search({ query = q, scope = S, limit = 20 }))
    assert(feedback.record_reinforcement(w.targets[1], S, "mistake", 0.5))
    local weight = {}
    local function note(list) for _, ex in ipairs(list) do if ex.query then weight[ex.query] = ex.weight end end end
    local real_train, real_loss = trainer.train, trainer.loss
    H.with(trainer, "train", function(ex, o) note(ex); return real_train(ex, o) end, function()
        H.with(trainer, "loss", function(m, ex) note(ex); return real_loss(m, ex) end, promote.run, S, { dry_run = true })
    end)
    check("a correction trains at its own weight", weight[q] == feedback.REINFORCE_WEIGHT.mistake, tostring(weight[q]))
    check("… and a confirmation at its own", weight[w.train[1].q] == feedback.REINFORCE_WEIGHT.praise, tostring(weight[w.train[1].q]))
end)

section("B. a confirmation count that cannot be read stops the model", function()
    setup()
    local S = "repo:lg-b7"
    local w = world(S)
    local q = w.held[1].q
    local plain_order = ids(search(S, q, false))
    local COUNT = "FROM lm_reinforcements WHERE memory_id IN"
    local rows, lines = H.failing_sql("query", COUNT, function() return search(S, q, true, model({ score = -5 })) end)
    check("search keeps its plain order rather than ranking without the signal", ids(rows) == plain_order)
    check("… and says the rerank failed", table.concat(lines):find("rerank failed", 1, true) ~= nil, table.concat(lines))
    local d = H.failing_sql("query", COUNT, function() return promote.run(S, {}) end)
    check("training stops too, and says why", d.decision == "skip" and tostring(d.reason):find("example build failed", 1, true) ~= nil, tostring(d.reason))
    local probes = require("luamemo.probes")
    local p = H.with(probes, "sample", function() error("boom", 0) end, promote.run, S, {})
    check("a probe sample that fails stops it as well", p.decision == "skip" and tostring(p.reason):find("probes failed", 1, true) ~= nil, tostring(p.reason))
    local hits = H.with(store, "search", function() return nil, "database is locked" end, pcall, probes.examples, S, { { id = 1, title = "x" } }, {})
    check("a search that fails is not an unreachable memory: it raises", hits == false)
end)

section("B. a query with a time in it is left out of training", function()
    setup()
    local S = "repo:lg-b5"
    local ids = memories(S, 2 * require("luamemo.probes").MIN_GATE + 4)   -- (enough to probe, or training stops before any label)
    local now = util.now_us()
    search_row(S, "what changed last week", { ids[1], ids[2] }, nil, nil, now - MINUTE)
    event_row(S, ids[1], "praise", nil, nil, now)
    local asked, real = {}, store.search
    H.with(store, "search", function(args) asked[#asked + 1] = args.query; return real(args) end, function()
        promote.run(S, { dry_run = true, min_samples = 1 })
    end)
    local found = false
    for _, q in ipairs(asked) do if q == "what changed last week" then found = true end end
    check("its pool depends on when it ran, so it is not rebuilt", not found)
end)

-- ---------------------------------------------------------------------------
section("C. the same database gives the same result, in any process", function()
    setup()
    local S = "repo:lg-c"
    world(S)
    local child = H.tmp_path("learned_gate_child.lua")
    H.write_file(child, ([[
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
H.setup(nil, { feedback_enabled = true, auto_digest_enabled = false, rerank_adapter = "learned", rerank_top_n = 20 })
local d = require("luamemo.promote").run(%q, { dry_run = true })
print(("%%s %%.12f %%.12f %%s %%s"):format(d.decision, d.new_score or -1, d.incumbent_score or -1, tostring(d.n_train), tostring(d.n_gate)))
]]):format(S))
    local first, code
    local differ = false
    for _ = 1, 4 do
        local out, c = H.sh(("MEMO_NO_MAINTENANCE=1 %q %q"):format(H.lua_bin(), child))
        code = c
        if first == nil then first = out elseif out ~= first then differ = true end
    end
    os.remove(child)
    check("four processes agree to the last digit", code == 0 and not differ and first:find("promote", 1, true) ~= nil, first)
end)

section("C. one query is never on both sides of the split", function()
    local ex = {}
    for i = 1, 300 do ex[i] = { query = "query number " .. (i % 47), n = i } end   -- (47: no common factor with a gate's stride)
    local train, gate = promote._split(ex, 0.3)
    check("every example lands somewhere", #train + #gate == 300, #train + #gate)
    check("both sides have some", #train > 0 and #gate > 0)
    local side = {}
    local mixed = false
    for _, e in ipairs(train) do side[e.query] = "train" end
    for _, e in ipairs(gate) do if side[e.query] == "train" then mixed = true end end
    check("no query is on both sides", not mixed)
    local t2, g2 = promote._split(ex, 0.3)
    check("the split is the same every time", #t2 == #train and #g2 == #gate and g2[1].n == gate[1].n)
end)

section("C. the gate scores only what training never saw", function()
    setup()
    local S = "repo:lg-c2"
    world(S)
    local fit, scored = {}, {}
    local real_train, real_loss = trainer.train, trainer.loss
    H.with(trainer, "train", function(ex, o) for _, e in ipairs(ex) do fit[e] = true end; return real_train(ex, o) end, function()
        H.with(trainer, "loss", function(w, ex) scored[#scored + 1] = ex; return real_loss(w, ex) end, function()
            promote.run(S, { dry_run = true })
        end)
    end)
    local seen, overlap = 0, 0
    for _, ex in ipairs(scored) do
        for _, e in ipairs(ex) do seen = seen + 1; if fit[e] then overlap = overlap + 1 end end
    end
    check("the loss is computed on held-out examples only", seen > 0 and overlap == 0, seen .. " scored, " .. overlap .. " also trained on")
end)

section("C. the gate can say no", function()
    setup()
    local S = "repo:lg-c3"
    world(S)
    local BAD = model({ score = -5, vec_score = -5, fts_score = -5 })
    local real_loss = trainer.loss
    local function candidate_wins_on_loss(fn)
        return H.with(trainer, "train", function() return BAD end, function()
            return H.with(trainer, "loss", function(w, ex) return (w == BAD) and 0.1 or real_loss(w, ex) end, fn)
        end)
    end
    local d = candidate_wins_on_loss(function() return promote.run(S, {}) end)
    check("a model that wins on the labels but loses memories' own titles is rejected",
        d.decision == "reject" and tostring(d.reason):find("probes gate failed", 1, true) ~= nil, tostring(d.decision) .. " " .. tostring(d.reason))
    check("nothing was promoted", lstore.current_version(S, "reranker") == nil)
    local run = db.first("SELECT decision, note FROM lm_promotion_runs WHERE scope = ? ORDER BY id DESC LIMIT 1", S)
    check("the audit row says why, with the figures", run and run.decision == "reject" and tostring(run.note):find("probe recall", 1, true) ~= nil,
        run and run.note)

    local dry = candidate_wins_on_loss(function() return promote.run(S, { dry_run = true }) end)
    check("a dry run applies the same gate", dry.decision == "would-reject", dry.decision)

    -- every memory reinforced: nothing left to check for harm with
    local A = "repo:lg-c4"
    local ids = memories(A, 12)
    local now = util.now_us()
    for i, id in ipairs(ids) do
        search_row(A, "query for " .. i, { id, ids[(i % 12) + 1] }, nil, nil, now - MINUTE)
        event_row(A, id, "praise", nil, nil, now)
    end
    local before = H.count("SELECT count(*) FROM lm_promotion_runs WHERE scope = ?", A)
    local few_dry = promote.run(A, { min_samples = 2, dry_run = true })
    check("a dry run changes nothing, not even the audit log", few_dry.decision == "skip"
        and H.count("SELECT count(*) FROM lm_promotion_runs WHERE scope = ?", A) == before)
    local few = promote.run(A, { min_samples = 2 })
    check("too few memories to check for harm: nothing is promoted, and it says so",
        few.decision == "skip" and tostring(few.reason):find("probes", 1, true) ~= nil, tostring(few.decision) .. " " .. tostring(few.reason))
    check("… in the audit log", H.count("SELECT count(*) FROM lm_promotion_runs WHERE scope = ? AND decision = 'skip' AND note LIKE '%probes%'", A) == before + 1)
end)

section("C. what a model must clear, exactly", function()
    setup()
    local probes = require("luamemo.probes")
    local S = "repo:lg-c5"
    world(S)
    local train_rows, gate_rows = probes.sample(S)
    local function with_gate_rows(n, fn)
        local cut = {}
        for i = 1, n do cut[i] = gate_rows[i] end
        return H.with(probes, "sample", function() return train_rows, cut end, fn)
    end
    local searched, count_real, pools_built, real_pool = 0, probes.examples, 0, learned.pool
    local short = with_gate_rows(probes.MIN_GATE - 1, function()
        return H.with(probes, "examples", function(...) searched = searched + 1; return count_real(...) end, function()
            return H.with(learned, "pool", function(...) pools_built = pools_built + 1; return real_pool(...) end, promote.run, S, {})
        end)
    end)
    check("one probe short of the minimum: skipped", short.decision == "skip" and tostring(short.reason):find("too few probes", 1, true) ~= nil, tostring(short.reason))
    check("… before a single probe or label is searched", searched == 0 and pools_built == 0, searched .. "/" .. pools_built)
    local enough = with_gate_rows(probes.MIN_GATE, function() return promote.run(S, { dry_run = true }) end)
    check("at the minimum: judged", enough.decision ~= "skip", tostring(enough.reason))
    -- enough memories to probe, but search brings back too few of them
    local real_ex = probes.examples
    local thin = H.with(probes, "sample", function() return train_rows, gate_rows end, function()
        return H.with(probes, "examples", function(s, rows, o)
            local ex, unreachable = real_ex(s, rows, o)
            if rows ~= gate_rows then return ex, unreachable end
            local cut = {}
            for i = 1, probes.MIN_GATE - 1 do cut[i] = ex[i] end
            return cut, #rows - #cut
        end, promote.run, S, { dry_run = true })
    end)
    check("one short of the minimum reachable by search: skipped too", thin.decision == "skip" and tostring(thin.reason):find("too few probes", 1, true) ~= nil, tostring(thin.reason))

    -- a probe search that fails on either side stops the run, with no audit row
    local function fails_on(side)
        local before = H.count("SELECT count(*) FROM lm_promotion_runs WHERE scope = ?", S)
        local d = H.with(probes, "sample", function() return train_rows, gate_rows end, function()
            return H.with(probes, "examples", function(s, rows, o)
                if rows == side then error("probe search failed", 0) end
                return real_ex(s, rows, o)
            end, promote.run, S, {})
        end)
        return d, H.count("SELECT count(*) FROM lm_promotion_runs WHERE scope = ?", S) - before
    end
    for name, side in pairs({ train = train_rows, gate = gate_rows }) do
        local d, added = fails_on(side)
        check("a failed probe search on the " .. name .. " side: skipped, says why, nothing audited",
            d.decision == "skip" and tostring(d.reason):find("probes failed", 1, true) ~= nil and added == 0, tostring(d.reason))
    end

    -- a pool of one ranks nothing, so it is no example
    local O = "repo:lg-c9"
    local pair = memories(O, 2)
    local at = util.now_us()
    search_row(O, "only one will be left", pair, nil, nil, at - MINUTE)
    event_row(O, pair[1], "praise", nil, nil, at)
    assert(db.run("UPDATE lm_memories SET tier = 0 WHERE id = ?", pair[2]))
    local alone = H.with(probes, "sample", function() return train_rows, gate_rows end, promote.run, O, { min_samples = 1, dry_run = true })
    check("a pool of one is not an example", alone.n_examples == 0, tostring(alone.n_examples))

    -- a loss the candidate loses: the gate probes are not worth their searches, and the reason says what happened
    local real_examples, calls = probes.examples, 0
    local LOSER = model({ score = -5 })
    local rejected = H.with(probes, "examples", function(...) calls = calls + 1; return real_examples(...) end, function()
        return H.with(trainer, "train", function() return LOSER end, function()
            return H.with(trainer, "loss", function(w) return (w == LOSER) and 0.9 or 0.1 end, promote.run, S, { dry_run = true })
        end)
    end)
    check("a model that loses on the labels: would-reject, with the reason", rejected.decision == "would-reject"
        and tostring(rejected.reason):find("gate not beaten", 1, true) ~= nil, tostring(rejected.reason))
    check("… and the gate's probes were never searched", calls == 1 and rejected.n_probes == nil, calls)

    -- queries that all fall on the training side leave nothing to judge with
    local E = "repo:lg-c6"
    local ids = memories(E, 16)
    local now, n, i = util.now_us(), 0, 0
    while n < 4 do
        i = i + 1
        local q = "training side query " .. i
        if util.djb2(q) % 3 ~= 0 then
            n = n + 1
            search_row(E, q, { ids[n], ids[n + 4] }, nil, nil, now - MINUTE)
            event_row(E, ids[n], "praise", nil, nil, now)
        end
    end
    local empty = promote.run(E, { min_samples = 1 })
    check("no query on the gate's side: skipped", empty.decision == "skip" and empty.reason == "train/gate split empty", tostring(empty.reason))
end)

section("C. which memories are probed", function()
    setup()
    local probes = require("luamemo.probes")
    local S = "repo:lg-c7"
    local ids = memories(S, 8)
    local raw = assert(store.write({ scope = S, title = "raw event", body = "a raw session event", importance = 0.1, dedup_strategy = "append" }))
    local untitled = assert(store.write({ scope = S, title = "to be blanked", body = "a memory whose title goes", dedup_strategy = "append" }))
    assert(db.run("UPDATE lm_memories SET title = '' WHERE id = ?", untitled.id))
    assert(feedback.record_reinforcement(ids[1], S, "praise", 0.5))
    assert(feedback.record_reinforcement(ids[2], S, "miss", 0.5))
    local train, gate = probes.sample(S)
    local seen, sides = {}, true
    for _, p in ipairs(train) do seen[tonumber(p.id)] = true; if tonumber(p.id) % 2 ~= 0 then sides = false end end
    for _, p in ipairs(gate) do seen[tonumber(p.id)] = true; if tonumber(p.id) % 2 ~= 1 then sides = false end end
    check("a memory's id decides its side", sides and #train > 0 and #gate > 0)
    check("tier 0, an empty title and a confirmed memory are not probed", not seen[tonumber(raw.id)] and not seen[tonumber(untitled.id)] and not seen[ids[1]])
    check("a memory with only a miss is (it has no confirmation count to make it easy)", seen[ids[2]])
    local a, b = H.with(probes, "MAX", 3, probes.sample, S)
    local newest = {}
    for _, p in ipairs(a) do newest[#newest + 1] = tonumber(p.id) end
    for _, p in ipairs(b) do newest[#newest + 1] = tonumber(p.id) end
    table.sort(newest)
    check("the sample is the newest MAX", #newest == 3 and newest[3] == tonumber(ids[8]), table.concat(newest, ","))
end)

section("C. a missing module is an answer, not a crash", function()
    local saved = package.loaded["luamemo.probes"]
    package.loaded["luamemo.probes"] = nil
    package.preload["luamemo.probes"] = function() error("module 'luamemo.probes' not found") end
    local ok, d = pcall(promote.run, "repo:lg-c8", {})
    package.preload["luamemo.probes"] = nil
    package.loaded["luamemo.probes"] = saved
    check("promote.run answers 'deps unavailable'", ok and d.reason == "deps unavailable", tostring(d and d.reason or d))
end)

-- ---------------------------------------------------------------------------
section("D. the regression corpus, end to end", function()
    setup()
    local S = "repo:lg-d"
    local w = world(S)
    local probes = require("luamemo.probes")
    local train_side = probes.sample(S)
    local trained_on = {}
    for _, p in ipairs(train_side) do trained_on[tonumber(p.id)] = true end
    local held_out = 0
    for _, c in ipairs(w.controls) do if not trained_on[c.target] then held_out = held_out + 1 end end
    check("the controls are memories training's probes never used", held_out == #w.controls and #w.controls >= 10 and #train_side >= 10,
        held_out .. " of " .. #w.controls .. "; " .. #train_side .. " training probes")

    local function score(fn)
        local ranks, off, first = {}, 0, 0
        for _, c in ipairs(w.held) do
            local rows = fn(c.q)
            ranks[#ranks + 1] = rank_in(rows, c.target)
            if not (rows[1] and rows[1].title:match("^" .. c.word)) then off = off + 1 end
        end
        for _, c in ipairs(w.controls) do
            local rows = fn(c.q)
            if rows[1] and tonumber(rows[1].id) == c.target then first = first + 1 end
        end
        return median(ranks), off, first
    end
    local base_rank, base_off, base_first = score(function(q) return search(S, q, false) end)
    check("the corpus is what it should be: the confirmed memory is not first, nothing off-topic, controls right",
        base_rank > 1 and base_off == 0 and base_first == #w.controls, ("%d/%d/%d"):format(base_rank, base_off, base_first))

    local d = promote.run(S, {})
    check("a model that earns it is promoted", d.decision == "promote", tostring(d.decision) .. " " .. tostring(d.reason))
    local run = db.first("SELECT decision, note FROM lm_promotion_runs WHERE scope = ? ORDER BY id DESC LIMIT 1", S)
    check("the audit row of a promotion carries the probe figures", run and run.decision == "promote" and tostring(run.note):find("probe recall", 1, true) ~= nil, run and run.note)
    check("the gate's numbers are real (below the prior, not a leak's near-zero)", d.new_score and d.new_score > 0.05 and d.new_score < d.incumbent_score,
        tostring(d.new_score) .. " vs " .. tostring(d.incumbent_score))
    learned.reset_cache()
    local rank, off, first = score(function(q) return search(S, q, true) end)
    check("the confirmed memory rises", rank < base_rank, rank .. " vs " .. base_rank)
    check("no first result goes off-topic", off == 0, off)
    check("what was already right stays right", first == base_first, first .. " of " .. base_first)
end)

-- ---------------------------------------------------------------------------
section("E. a model from before this gate is not served", function()
    setup()
    local S = "repo:lg-e"
    local w = world(S)
    local OLD = trainer.prior()
    OLD.score, OLD.vec_score, OLD.bias = -5, -5, 7
    local v1 = assert(lstore.save_version(S, "reranker", OLD, { score = 0.3 }))
    assert(lstore.promote(S, "reranker", v1))
    learned.reset_cache()
    local q = w.held[1].q
    check("search keeps the baseline order", ids(search(S, q, true)) == ids(search(S, q, false)))

    local seen = {}
    local real = trainer.loss
    H.with(trainer, "loss", function(weights, ex) seen[#seen + 1] = weights; return real(weights, ex) end, function()
        promote.run(S, { dry_run = true })
    end)
    local compared_old = false
    for _, s in ipairs(seen) do if s.bias == 7 then compared_old = true end end
    check("the gate does not treat it as the model to beat", #seen > 0 and not compared_old)

    local ops = require("luamemo.ops")
    local st = assert(ops.learn({ action = "status" }, S)).status
    check("`memo learn --status` says it is not served", st.versions[1] and st.versions[1].served == false, st.versions[1] and tostring(st.versions[1].served))

    local d = promote.run(S, {})
    check("a new model is saved with the format this release serves", d.decision == "promote"
        and (lstore.load_current(S, "reranker") or {}).format == learned.MODEL_FORMAT, tostring(d.decision) .. " " .. tostring(d.reason))
    learned.reset_cache()
    local st2 = assert(ops.learn({ action = "status" }, S)).status
    check("… and is served", st2.versions[1].served == true and ids(search(S, q, true)) ~= ids(search(S, q, false)))

    local v3 = assert(lstore.save_version(S, "reranker", model(), {}))
    assert(lstore.promote(S, "reranker", v3))
    local fine = assert(ops.learn({ action = "rollback" }, S))
    check("rolling back onto a model search serves carries no warning", fine.current == v3 - 1 and fine.warning == nil, tostring(fine.warning))
    local r = assert(ops.learn({ action = "rollback" }, S))
    check("rolling back to the old one works and says search will not use it", r.current == v1 and tostring(r.warning):find("not served", 1, true) ~= nil, tostring(r.warning))
end)

finish()
