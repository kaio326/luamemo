-- eval/tests/test_eval_corpus.lua
-- The benchmark corpus builder (eval/corpus/): a database of luamemo's own rows made by luamemo's
-- own ingestion — the real schema, the index's symbol / file / dependency rows and KG facts,
-- calibrate's scan rows, the agent-written notes — labelled as a benchmark database, resumable,
-- reproducible, and unwilling to write anywhere else. Built here from a tiny fixture with the
-- hash embedder.
-- Run: luajit eval/tests/run.lua --only eval_corpus

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("eval corpus")
local check, section, finish = T.check, T.section, T.finish

local json = require("luamemo.json")
local util = require("luamemo.util")
local build = require("corpus.build")
local notes = require("corpus.notes")
local sources_mod = require("corpus.sources")

local SRC = "eval/fixtures/corpus_src"
local tmp = (H.sh("mktemp -d " .. ((os.getenv("MEMO_TEST_TMP") or "") ~= "" and os.getenv("MEMO_TEST_TMP")
    or "/tmp") .. "/evalcorpus.XXXXXX"))
local function q(s) return util.shell_quote(s) end

local SOURCES = {
    { name = "alpha", kind = "own", root = SRC .. "/alpha", scan_root = SRC .. "/alpha", git = false },
    { name = "beta", kind = "lib", root = SRC .. "/beta" },
}
local NOTE_FILES = {
    { path = SRC .. "/notes/planner.md", scope = "repo:alpha", role = "planner" },
    { path = SRC .. "/notes/feedback-rules.md", scope = "repo:alpha", role = "note" },
    { path = SRC .. "/notes/user_profile.md", scope = "repo:alpha", role = "note" },
}

local function run(out, extra)
    local o = { out = out, embedder = "hash", target = 100000, seed = 1, sources = SOURCES, note_files = NOTE_FILES }
    for k, v in pairs(extra or {}) do o[k] = v end
    return build.build(o)
end

-- The db's rows as one checksum (what a rebuild must reproduce): scope, kind, title, body, importance.
local function digest(path)
    local h = assert(require("luamemo.db").open(path, { readonly = true }))
    local parts = {}
    for _, r in ipairs(h.query("SELECT scope, kind, title, body, importance FROM lm_memories ORDER BY scope, kind, title, body")) do
        parts[#parts + 1] = table.concat({ r.scope, r.kind, r.title, r.body, tostring(r.importance) }, "\30")
    end
    local facts = {}
    for _, r in ipairs(h.query("SELECT scope, subject, predicate, object FROM lm_kg_facts ORDER BY scope, subject, predicate, object")) do
        facts[#facts + 1] = table.concat({ r.scope, r.subject, r.predicate, tostring(r.object) }, "\30")
    end
    h.close()
    return util.djb2_hex(table.concat(parts, "\31")) .. "/" .. util.djb2_hex(table.concat(facts, "\31")), #parts
end

section("the guard: only a benchmark database", function()
    io.write("\n--- guard ---\n")
    check("a name that isn't bench*.db is refused", select(1, build.is_bench_path(tmp .. "/luamemo-abc.db")) == false)
    check("a new bench*.db path is fine", build.is_bench_path(tmp .. "/bench-new.db") == true)
    local real = tmp .. "/bench-real.db"          -- named like a benchmark's, but a real database (no label)
    require("luamemo.db").open(real).close()
    local ok, why = build.is_bench_path(real)
    check("an existing database without the benchmark label is refused", ok == false and tostring(why):find("not a benchmark database", 1, true), why)
    local res, err = run(real)
    check("… and build() writes nothing into it", res == nil and tostring(err):find("refusing", 1, true)
        and select(1, build.is_bench_path(real)) == false)
end)

section("a build from real ingestion", function()
    io.write("\n--- build ---\n")
    local out = tmp .. "/bench-a.db"
    local res, err = run(out)
    check("build succeeds", res ~= nil, err)
    if not res then return end
    local h = assert(require("luamemo.db").open(out, { readonly = true }))
    local function n(sql, ...)   -- (a statement that fails raises: a check "== 0" must not pass because the question was not asked)
        local v, err = h.value(sql, ...)
        if err then error("n: " .. tostring(err), 2) end
        return tonumber(v) or 0
    end
    check("labelled: lm_meta bench = 1, the seed, the luamemo version and the embedder",
        h.value("SELECT value FROM lm_meta WHERE key = 'bench'") == "1" and h.value("SELECT value FROM lm_meta WHERE key = 'bench_seed'") == "1"
        and h.value("SELECT value FROM lm_meta WHERE key = 'bench_luamemo'") == require("luamemo").VERSION
        and tostring(h.value("SELECT value FROM lm_meta WHERE key = 'bench_embedder'")):find("^hash"))
    local names = {}
    for _, r in ipairs(h.query("SELECT name FROM lm_migrations ORDER BY name")) do names[#names + 1] = r.name end
    local want = {}
    for _, m in ipairs(require("luamemo.schema").MIGRATIONS) do want[#want + 1] = m.name end
    table.sort(want)
    check("the real schema: exactly luamemo's migrations were applied", table.concat(names, ",") == table.concat(want, ","))
    check("code index: symbol, file and dependency rows in codeindex:alpha",
        n("SELECT count(*) FROM lm_memories WHERE scope='codeindex:alpha' AND kind='symbol'") >= 3
        and n("SELECT count(*) FROM lm_memories WHERE scope='codeindex:alpha' AND kind='file'") >= 2
        and n("SELECT count(*) FROM lm_memories WHERE scope='codeindex:alpha' AND kind='dependency'") >= 2)
    check("… and a python library parsed too (beta)", n("SELECT count(*) FROM lm_memories WHERE scope='codeindex:beta' AND kind='symbol'") >= 2)
    check("KG facts of the index: requires / required_by", n("SELECT count(*) FROM lm_kg_facts WHERE predicate='requires'") >= 1
        and n("SELECT count(*) FROM lm_kg_facts WHERE predicate='required_by'") >= 1)
    check("calibrate's scan: README sections, the ADR (decision), as calibrate tags and weights them",
        n("SELECT count(*) FROM lm_memories WHERE scope='repo:alpha' AND tags LIKE '%readme%' AND importance = 3") >= 2
        and n("SELECT count(*) FROM lm_memories WHERE scope='repo:alpha' AND kind='decision' AND tags LIKE '%adr%' AND importance = 4") == 1)
    check("the agent-written notes: a plan, a decision-titled fact and the feedback rule (importance 5 → tier 2)",
        n("SELECT count(*) FROM lm_memories WHERE scope='repo:alpha' AND kind='plan' AND tags LIKE '%planner%'") == 1
        and n("SELECT count(*) FROM lm_memories WHERE scope='repo:alpha' AND tags LIKE '%\"note\"%' AND importance = 5 AND tier = 2") == 1)
    check("a note about the person (type: user) is not read", n("SELECT count(*) FROM lm_memories WHERE body LIKE '%must never reach%'") == 0)
    check("the embedding column holds vectors (symbols and notes), as luamemo writes them",
        n("SELECT count(*) FROM lm_memories WHERE kind='symbol' AND embedding IS NULL") == 0
        and n("SELECT count(*) FROM lm_memories WHERE tags LIKE '%\"planner\"%' AND embedding IS NULL") == 0)
    local m = nil
    for _, r in ipairs(h.query("SELECT metadata FROM lm_memories WHERE kind='symbol' LIMIT 1")) do m = r.metadata end
    check("a symbol row carries what the index writes (path, line, module, symbol_type)",
        type(m) == "table" and m.path and m.line and m.module and m.symbol_type, json.encode(m))
    h.close()
end)

section("resumable, reproducible, seeded", function()
    io.write("\n--- resume / determinism ---\n")
    local a, b = tmp .. "/bench-a.db", tmp .. "/bench-b.db"
    local da, na = digest(a)
    check("a second run of the same database adds nothing (every source recorded as done)", select(2, digest(a)) == na
        and (function() local r = run(a); return r and r.rows == na end)())
    -- an interrupted source starts again, ending with the same rows
    local h = assert(require("luamemo.db").open(a))
    h.run("DELETE FROM lm_meta WHERE key = 'done:alpha'")
    h.run("DELETE FROM lm_memories WHERE scope = 'codeindex:alpha' AND kind = 'symbol' AND id % 2 = 0")
    h.close()
    local r = run(a)
    check("a source without its done mark is built again, not doubled", r and digest(a) == da, tostring(digest(a)) .. " vs " .. da)
    -- a rescan refreshes the scan rows, it does not write them again
    local before_rescan = select(2, digest(a))
    local rs = run(a, { rescan = true })
    check("a rescan does not double the scan rows (they are refreshed in place)", rs and select(2, digest(a)) == before_rescan,
        tostring(select(2, digest(a))) .. " vs " .. tostring(before_rescan))
    -- … and the repeats an older rescan left are removed, the oldest row kept; the code index keeps its own
    local hd = assert(require("luamemo.db").open(a))
    local victim = hd.query("SELECT scope, kind, title, body, importance FROM lm_memories WHERE scope LIKE 'repo:%' LIMIT 1")[1]
    local symbols = tonumber(hd.value("SELECT count(*) FROM lm_memories WHERE scope LIKE 'codeindex:%'"))
    hd.run("INSERT INTO lm_memories (scope, kind, title, body, importance) VALUES (?, ?, ?, ?, ?)", victim.scope, victim.kind, victim.title, victim.body, victim.importance)
    hd.close()
    local dd = build.dedupe(a)
    local hd2 = assert(require("luamemo.db").open(a))
    check("dedupe: an exact repeat in a repo: scope is removed, the code index's rows are untouched",
        dd and dd.removed == 1 and tonumber(hd2.value("SELECT count(*) FROM lm_memories WHERE scope LIKE 'codeindex:%'")) == symbols
        and select(2, digest(a)) == before_rescan, dd and dd.removed)
    hd2.close()
    check("dedupe refuses a database that is not a benchmark's", select(1, build.dedupe(tmp .. "/luamemo-nope.db")) == nil)
    local rb = run(b)
    check("determinism: the same seed and sources build the same rows and facts", rb and digest(b) == da)
    local _, why = run(a, { seed = 2 })
    check("a different seed on an existing corpus is refused", tostring(why):find("seed 1", 1, true) ~= nil, why)
end)

section("the seeded sample of a huge tree", function()
    io.write("\n--- sampler ---\n")
    local files = {}
    for i = 1, 100 do files[i] = { rel = ("pkg/mod%03d.py"):format(i), path = "/x/" .. i } end
    local s1, s2 = build.sampler(10, 1, "p")(files), build.sampler(10, 1, "p")(files)
    local function names(l) local o = {} for i, f in ipairs(l) do o[i] = f.rel end return table.concat(o, ",") end
    check("the same seed picks the same files, in the tree's own order", #s1 == 10 and names(s1) == names(s2)
        and names(s1) == (function() local o = {} for _, f in ipairs(s1) do o[#o + 1] = f.rel end table.sort(o) return table.concat(o, ",") end)())
    check("another seed, another sample", names(build.sampler(10, 2, "p")(files)) ~= names(s1))
    -- not "the first files by name" (what a djb2 ordering of near-identical names gave)
    local first_ten = {}
    for i = 1, 10 do first_ten[i] = files[i].rel end
    local spread = 0
    for _, f in ipairs(s1) do if tonumber(f.rel:match("%d+")) > 50 then spread = spread + 1 end end
    check("the sample is spread over the tree, not its first names", names(s1) ~= table.concat(first_ten, ",") and spread >= 1
        and spread <= 9, spread)
    check("a small tree is taken whole", #build.sampler(500, 1, "p")(files) == 100)
end)

section("sources and notes", function()
    io.write("\n--- sources / notes ---\n")
    local list = sources_mod.discover({ seed = 1, own_dirs = { SRC } })
    local seen = {}
    for _, s in ipairs(list) do seen[s.name] = s end
    check("the owner's projects come first, as sources of their own", list[1] and list[1].kind == "own" and seen.alpha and seen.alpha.git == false
        and seen.alpha.max_files == 1500)
    local again = sources_mod.discover({ seed = 1, own_dirs = { SRC } })
    local function names(l) local o = {} for i, s in ipairs(l) do o[i] = s.name end return table.concat(o, ",") end
    check("discovery is deterministic for a seed", names(list) == names(again))
    local rows = notes.load({ files = NOTE_FILES })
    check("notes: sections become memories — planner → plan (3), a note → fact (5), the person's note skipped",
        #rows == 3 and rows[1].kind and (function()
            local kinds = {}
            for _, r in ipairs(rows) do kinds[r.tags[2] .. ":" .. r.kind .. ":" .. r.importance] = true end
            return kinds["planner:plan:3"] and kinds["planner:fact:3"] and kinds["note:fact:5"]
        end)(), json.encode((function() local o = {} for _, r in ipairs(rows) do o[#o + 1] = r.title end return o end)()))
    check("… titled by file and heading, bodies kept whole (≤ 4,000), every row asks for dedup update",
        rows[1].title:find(": ", 1, true) and #rows[1].body <= 4000 and rows[1].dedup_strategy == "update")
end)

section("calibrate.scan and index.ingest keep their command-line behaviour", function()
    io.write("\n--- shared code paths ---\n")
    local rows = require("luamemo.cli.calibrate").scan(SRC .. "/alpha", "repo:alpha", { no_git = true })
    check("calibrate.scan returns the rows memo calibrate writes (and touches nothing: no .luamemorc created)",
        #rows >= 3 and not util.exists(SRC .. "/alpha/.luamemorc") and not util.exists(SRC .. "/alpha/.gitignore"))
    -- A young repository (2 commits): calibrate used to ask git for HEAD~200..HEAD — an error
    -- below 200 commits, dropped — and never scanned its history at all.
    local repo = tmp .. "/young"
    H.sh(("mkdir -p %q && cd %q && git init -q && git config user.email t@t && git config user.name t "
        .. "&& echo one > a.txt && git add . && git commit -qm 'feat: add invoice export for finance' "
        .. "&& echo two > b.txt && git add . && git commit -qm 'refactor: replace the rate table with a loader'"):format(repo, repo))
    local grows = require("luamemo.cli.calibrate").scan(repo, "repo:young", { no_comments = true })
    local commits = 0
    for _, r in ipairs(grows or {}) do for _, t in ipairs(r.tags) do if t == "git-commit" then commits = commits + 1 end end end
    check("calibrate's git scan reads a repository with fewer than 200 commits", commits == 2, commits)
    local picked = 0
    require("luamemo").setup({ db = tmp .. "/bench-sel.db", embedder_local = "hash", embed_dim = 384, skip_embed_probe = true })
    local res = require("luamemo.index").ingest(SRC .. "/alpha", { scope = "codeindex:sel", select_files = function(fs)
        picked = #fs; return { fs[1] } end })
    check("index.ingest select_files narrows the walk", res and res.files == 1 and picked >= 3, res and res.files)
end)

local queries_mod = require("corpus.queries")
local paraphrase = require("corpus.paraphrase")
local simulate = require("corpus.simulate")

local function qdigest(path)
    local h = assert(require("luamemo.db").open(path, { readonly = true }))
    local parts = {}
    for _, r in ipairs(h.query("SELECT category, query, gold_ids, bucket, split, holdout, source FROM bench_queries ORDER BY category, query, source")) do
        parts[#parts + 1] = table.concat({ r.category, r.query, r.gold_ids, r.bucket, r.split, tostring(r.holdout), r.source }, "\30")
    end
    h.close()
    return util.djb2_hex(table.concat(parts, "\31")), #parts
end

section("labelled queries from the real structure", function()
    io.write("\n--- queries ---\n")
    local a = tmp .. "/bench-qa.db"
    assert(run(a))
    local res, err = queries_mod.build(a, { total = 80, seed = 1, per_scope = 40 })
    check("queries build", res and res.queries >= 6, err)
    if not res then return end
    local h = assert(require("luamemo.db").open(a, { readonly = true }))
    local rows = h.query("SELECT * FROM bench_queries")
    local ok_gold, ok_range, cats = true, true, {}
    for _, r in ipairs(rows) do
        cats[r.category] = true
        local ids = json.decode(r.gold_ids)
        if #ids == 0 then ok_gold = false end
        for _, id in ipairs(ids) do if h.value("SELECT count(*) FROM lm_memories WHERE id = ?", id) ~= 1 then ok_gold = false end end
        if r.overlap < 0 or r.overlap > 1 or not (r.bucket == "low" or r.bucket == "med" or r.bucket == "high") then ok_range = false end
    end
    check("every query's gold is a row of the corpus; overlap in 0..1, bucketed", ok_gold and ok_range)
    check("categories drawn from the code index and the scan: symbol docs, defined names, README sections",
        cats.symbol_doc and cats.file_defines and cats.doc_section, json.encode(cats))
    local fd = h.query("SELECT gold_ids FROM bench_queries WHERE category = 'file_defines' LIMIT 1")[1]
    local kinds = {}
    for _, id in ipairs(fd and json.decode(fd.gold_ids) or {}) do kinds[h.value("SELECT kind FROM lm_memories WHERE id = ?", id)] = true end
    check("file_defines: the answer is the file's row and the rows of the symbols it defines", kinds.file and kinds.symbol, json.encode(kinds))
    local dup = h.query("SELECT gold_ids, query FROM bench_queries WHERE category = 'symbol_doc' AND query LIKE '%sum%invoices issued%'")[1]
    check("identical docstrings on several symbols: all of them are the gold (multi-gold)", dup and #json.decode(dup.gold_ids) == 2,
        dup and dup.gold_ids)
    local ident_leak = false
    for _, r in ipairs(h.query("SELECT query FROM bench_queries WHERE category = 'symbol_doc'")) do
        if r.query:lower():find("monthly_total", 1, true) or r.query:lower():find("legacy", 1, true) then ident_leak = true end
    end
    check("a symbol query carries none of its own name", not ident_leak)
    local split = h.query("SELECT split, count(*) n FROM bench_queries GROUP BY split")
    local by = {}
    for _, r in ipairs(split) do by[r.split] = r.n end
    local eval_share = (by.eval or 0) / math.max(1, (by.history or 0) + (by.eval or 0))
    check("history / eval split about 70 / 30 (the eval share is between a fifth and 40 %)", eval_share >= 0.2 and eval_share <= 0.4, json.encode(by))
    local late = 0
    local pairs_seen = 0
    for _, r in ipairs(h.query("SELECT scope, max(CASE WHEN split = 'history' THEN t END) AS hmax, "
        .. "min(CASE WHEN split = 'eval' THEN t END) AS emin FROM bench_queries GROUP BY scope")) do
        if r.hmax and r.emin then
            pairs_seen = pairs_seen + 1
            if tonumber(r.hmax) > tonumber(r.emin) then late = late + 1 end
        end
    end
    h.close()
    check("… and within every scope the eval queries come after the history ones", pairs_seen >= 1 and late == 0, pairs_seen .. " scopes, " .. late .. " out of order")
    local b = tmp .. "/bench-qb.db"
    assert(run(b))
    queries_mod.build(b, { total = 80, seed = 1, per_scope = 40, start_us = 0 })
    queries_mod.build(a, { total = 80, seed = 1, per_scope = 40, start_us = 0 })
    check("determinism: the same corpus and seed give the same queries", qdigest(a) == qdigest(b))
    local _, why = queries_mod.build(tmp .. "/luamemo-abc.db", {})
    check("the query builder refuses a database that isn't a benchmark's", why ~= nil)
    check("overlap: shared content words / the query's", math.abs(queries_mod.overlap("find the billing queue", "billing queue worker") - 2 / 3) < 1e-9)
end)

section("paraphrases by a model: kept only when they are really different", function()
    io.write("\n--- paraphrases ---\n")
    local a = tmp .. "/bench-qa.db"
    local calls = 0
    local stub = function(prompt)
        calls = calls + 1
        if calls % 2 == 0 then return "Question: " .. prompt:match("Sentence: (.-)\n") end   -- unchanged → rejected
        return "What helps me add up everything we charged customers during a calendar period?"
    end
    local r1 = paraphrase.run(a, { n = 40, complete = stub })
    check("the model is asked once per sampled query; rewrites are kept or rejected on measured grounds",
        r1 and r1.asked >= 2 and r1.kept >= 1 and r1.rejected >= 1 and r1.asked == calls, json.encode(r1))
    local h = assert(require("luamemo.db").open(a, { readonly = true }))
    local llm = h.query("SELECT * FROM bench_queries WHERE source = 'llm'")
    local low = true
    for _, r in ipairs(llm) do if r.overlap >= 0.4 then low = false end end
    check("kept rewrites are rows with the gold of their original and an overlap under 0.4", #llm == r1.kept and low
        and (#llm == 0 or json.decode(llm[1].gold_ids)[1] ~= nil))
    h.close()
    local calls_before = calls
    local r2 = paraphrase.run(a, { n = 40, complete = stub })
    check("a rerun replays the cache and asks the model nothing", r2.asked == 0 and calls == calls_before and r2.kept == r1.kept,
        json.encode(r2))
    check("the cache is a file beside the database", util.exists(a .. ".paraphrases.jsonl"))
    local good = paraphrase.acceptable("What helps me add up everything we charged customers?", "sum of invoices", "sum invoices issued", {})
    local bad_id = paraphrase.acceptable("how is monthly_total computed for the customers each month", "x", "monthly total", { monthly = true })
    local bad_code = paraphrase.acceptable("what does `sum(i)` return for all of them here", "x", "y z", {})
    check("acceptable(): a different question passes; identifiers and code are refused", good and not bad_id and not bad_code)
end)

section("the usage simulator drives the real search and writes through the real feedback code", function()
    io.write("\n--- simulation ---\n")
    -- the click model alone: where the gold ranked decides what a person says
    local function tally(rank, n)
        local rnd, count = (function() local s = 7 return function() s = (s * 48271) % 2147483647 return s / 2147483647 end end)(), {}
        for _ = 1, n do
            local ev = simulate.outcome(rank, 1, 2, rnd)
            local k = ev and ev.type or "none"
            count[k] = (count[k] or 0) + 1
        end
        for k, v in pairs(count) do count[k] = v / n end
        return count
    end
    local top, deep, absent = tally(1, 20000), tally(8, 20000), tally(nil, 20000)
    check("rank 1: usually praised or silent, rarely a correction", (top.praise or 0) > 0.2 and (top.praise or 0) < 0.32
        and (top.mistake or 0) < 0.06 and (top.miss or 0) == 0, json.encode(top))
    check("rank 8: read less (position bias), so more mistakes than at rank 1", (deep.mistake or 0) > (top.mistake or 0) * 2, json.encode(deep))
    check("not offered at all: a miss half of the time", math.abs((absent.miss or 0) - 0.5) < 0.03 and (absent.praise or 0) == 0, json.encode(absent))
    local a = tmp .. "/bench-qa.db"
    local res, err = simulate.run(a, { seed = 1, limit = 200 })
    check("simulate runs on the corpus", res ~= nil, err)
    if not res then return end
    local h = assert(require("luamemo.db").open(a, { readonly = true }))
    local nfb = tonumber(h.value("SELECT count(*) FROM lm_retrieval_feedback"))
    local nre = tonumber(h.value("SELECT count(*) FROM lm_reinforcements"))
    local hist = tonumber(h.value("SELECT count(*) FROM bench_queries WHERE split = 'history' AND holdout = 0"))
    check("every replayed query left a retrieval log (written by store.search itself)", nfb == res.queries and res.queries <= hist and nfb >= 1,
        ("%s vs %s"):format(tostring(nfb), tostring(res.queries)))
    check("reinforcements are the real kinds, on the corpus' memories", nre == res.reinforcements
        and tonumber(h.value("SELECT count(*) FROM lm_reinforcements r JOIN lm_memories m ON m.id = r.memory_id")) == nre
        and tonumber(h.value("SELECT count(*) FROM lm_reinforcements WHERE event_type NOT IN ('direct_command','mistake','reversal','praise','miss')")) == 0)
    local holdout = tonumber(h.value("SELECT count(*) FROM lm_retrieval_feedback f JOIN bench_queries b ON b.query = f.query AND b.scope = f.scope WHERE b.holdout = 1"))
    check("holdout projects are never logged", holdout == 0, holdout)
    local stamp = h.value("SELECT value FROM lm_meta WHERE key = 'bench_sim'")
    check("the click model's parameters are recorded with the history", tostring(stamp):find("attention", 1, true) and tostring(stamp):find("noise", 1, true), stamp)
    local first = h.query("SELECT created_at FROM lm_retrieval_feedback ORDER BY id LIMIT 1")[1]
    check("logged at the simulated time (18 months, not now)", first and tonumber(first.created_at) < require("luamemo.util").now_us() - 24 * 3600 * 1000000 * 30)
    h.close()
    local before = res.reinforcements
    local again = simulate.run(a, { seed = 1, limit = 200 })
    check("a rerun starts from no history and gives the same counts (seeded)", again and again.reinforcements == before and again.queries == res.queries)
    -- busy projects are asked again: with heavy_min 1 every scope is, heavy_cycles times over
    local one = simulate.run(a, { seed = 1, heavy_cycles = 1 })
    local three = simulate.run(a, { seed = 1, heavy_cycles = 3, heavy_min = 1 })
    check("heavy scopes are asked again in later cycles (3 cycles = 3x the questions)",
        one and three and three.queries == one.queries * 3 and three.heavy_scopes >= 1, json.encode(three))
    local h2 = assert(require("luamemo.db").open(a, { readonly = true }))
    local newest = tonumber(h2.value("SELECT max(created_at) FROM lm_retrieval_feedback"))
    h2.close()
    check("… never later than now", newest and newest <= require("luamemo.util").now_us())
end)

section("the grep baseline shared with the codemap benchmark", function()
    local grep = require("eval.grep_baseline")
    check("words: lower-case, three letters or more, no stop words, once each",
        table.concat(grep.words_of("Where is the Parser parser of tokens?"), ","):find("^parser,tokens$") ~= nil,
        table.concat(grep.words_of("Where is the Parser parser of tokens?"), ","))
    local files = {
        { path = "a.lua", text = ("parser tokens lexer " .. ("x"):rep(80)):lower() },
        { path = "b.lua", text = ("parser " .. ("y"):rep(93)):lower() },
        { path = "c.lua", text = "nothing here" },
    }
    local rank, bytes = grep.rank(files, "parser tokens", { ["b.lua"] = true }, 10)
    check("the file with more of the words is read first; bytes are what was read to reach the gold file",
        rank == 2 and bytes == 200, tostring(rank) .. " " .. tostring(bytes))
    check("a gold file grep never opens is a miss", grep.rank(files, "parser tokens", { ["c.lua"] = true }, 10) == nil)
    check("the limit cuts the files grep opens", grep.rank(files, "parser tokens", { ["b.lua"] = true }, 1) == nil)
end)

section("the benchmarks on the corpus", function()
    io.write("\n--- corpus benchmarks ---\n")
    local a = tmp .. "/bench-qa.db"
    local before = digest(a)
    local function runner(suite, out, extra)
        return H.sh(("env -u MEMO_DB -u MEMO_SCOPE %q eval/corpus_run.lua --suite %s --db %q --out %q %s"):format(
            H.lua_bin(), suite, a, out, extra or ""))
    end
    local out1, c1 = runner("scale", tmp .. "/scale.json")
    local s = json.decode(H.slurp(tmp .. "/scale.json") or "")
    check("scale: the eval queries searched the way the agent's tools search", c1 == 0 and s and s.n >= 1
        and s.overall["recall@10"] and s.overall.miss_rate and s.overall.search_ms_p50, out1)
    check("… by category, difficulty (overlap bucket) and source; latency by the size of the scope",
        s and next(s.by_category) and next(s.by_bucket) and next(s.by_source) and next(s.latency), json.encode(s and s.latency))
    check("… it reports the corpus it ran on and the simulated person", s and s.corpus.rows > 10 and s.simulated_user
        and s.simulated_user.params.attention == 0.4)
    local out2, c2 = runner("learned", tmp .. "/learned.json", "--points 100,1000")
    local l = json.decode(H.slurp(tmp .. "/learned.json") or "")
    check("learned: a curve of points; with too little history every project is skipped (the gate asks for 20 outcomes)",
        c2 == 0 and l and #l.curve == 2 and l.curve[1].scopes_promoted == 0
        and l.curve[1].scopes_rejected == 0 and l.curve[1].scopes_skipped == l.curve[2].scopes_skipped, out2)
    check("… and it worked on a copy: the benchmark database is exactly as it was, the copy gone",
        digest(a) == before and not util.exists(tmp .. "/learned.json.work.db") and not util.exists(tmp .. "/bench-work-learned.json.work.db"))
    local out4, c4 = runner("multiscope", tmp .. "/multi.json", "--n 20")
    local m = json.decode(H.slurp(tmp .. "/multi.json") or "")
    check("multiscope: the same questions over 1, 2, 4 and 8 scopes, and the project pair against its right scope alone",
        c4 == 0 and m and m.overall.s1_r1 and m.overall.s2_r1 and m.overall.s4_r1 and m.overall.s8_r1
        and m.overall.s8_ms_p50 and m.overall.pair_n ~= nil, out4)
    local before_m = digest(a)
    local out5, c5 = runner("maintenance", tmp .. "/maint.json")
    local mt = json.decode(H.slurp(tmp .. "/maint.json") or "")
    check("maintenance: the cost of the near-duplicate search by working-set size, on a copy",
        c5 == 0 and mt and mt.overall.big_rows and mt.overall.big_cons_ms_500 and mt.overall.big_clusters_500 ~= nil
        and mt.overall.big_r10_before ~= nil and digest(a) == before_m, out5)
    local out6, c6 = runner("task_cost", tmp .. "/cost.json")
    check("task_cost: runs (the fixture's projects have no source tree on this machine, so it asks nothing)",
        c6 == 0 and json.decode(H.slurp(tmp .. "/cost.json") or "{}").n == 0, out6)
    local _, c3 = H.sh(("env -u MEMO_DB %q eval/corpus_run.lua --suite scale --db %q --out %q"):format(H.lua_bin(), tmp .. "/luamemo-x.db", tmp .. "/x.json"))
    check("the runner refuses a database that is not a benchmark's", c3 ~= 0)
end)

os.execute("rm -rf " .. q(tmp))
finish()
