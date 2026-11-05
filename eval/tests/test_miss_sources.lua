-- eval/tests/test_miss_sources.lua
-- Which writes may count as a retrieval "miss". With the usage log on (MEMO_FEEDBACK_ENABLED), a write that
-- is a near-duplicate of a memory already there is recorded as a miss — "retrieval failed to surface it, so it
-- was written again" — and, where the write leaves the old row alone, its importance goes up (a merge writes
-- the row's own importance back, so a calibrate rerun never moved it; the miss events are what pile up — they
-- feed `memo usage`, the learners, and what a dev pushes to an org). That is right for a person's or an
-- agent's own write. It is wrong for what luamemo writes by itself, over and over: `memo calibrate` writing
-- its scan rows again, the session hooks' raw conversation (each snapshot repeats the one before), a promoted
-- summary, org knowledge, the benchmark ledger. Measured before the fix: a calibrate rerun recorded a miss for
-- every row it rewrote (12 after four runs of a four-row project); four hook snapshots recorded three.
--   A. calibrate's rows, rewritten five times: no miss, importance and row count unchanged
--   B. the same decision written twice by an agent: one miss, importance up when the write keeps the old row
--   C. raw conversation (tier 0): no miss
--   D. luamemo's own writes (no_miss), a promoted summary written twice: no miss; the same write without
--      the flag: a miss; no tool can pass the flag (ops.write_fields drops it)
--   E. import and index ingest of the same rows twice: no miss (they never recorded one — kept so)
-- Run: luajit eval/tests/run.lua --only miss_sources

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Miss sources")
local check, section, finish = T.check, T.section, T.finish

local luamemo = require("luamemo")
local db      = require("luamemo.db")
local json    = require("luamemo.json")
local ops     = require("luamemo.ops")

local MAIN = assert(os.getenv("MEMO_DB"), "run it with eval/tests/run.lua (MEMO_DB)")
local lua_bin = H.lua_bin()
local TMP = os.tmpname(); os.remove(TMP); os.execute(("mkdir -p %q"):format(TMP))

luamemo.setup({ db = MAIN, embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false,
                feedback_enabled = true })

local function misses(scope)
    return H.count("SELECT count(*) FROM lm_reinforcements WHERE event_type = 'miss' AND scope = ?", scope)
end
local function importance_sum(scope)
    return H.count("SELECT COALESCE(sum(importance), 0) FROM lm_memories WHERE scope = ?", scope)
end
local function count(scope) return H.count("SELECT count(*) FROM lm_memories WHERE scope = ?", scope) end
local env = ("env MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_FEEDBACK_ENABLED=true MEMO_LUA=%q"):format(MAIN, lua_bin)

section("calibrate's rows, written again", function()
    local scope = "repo:calib"
    local rows = require("luamemo.cli.calibrate").scan("eval/fixtures/corpus_src/alpha", scope, { no_git = true })
    check("the fixture project gives scan rows", #rows >= 3, #rows)
    local path = TMP .. "/rows.jsonl"
    local f = assert(io.open(path, "w"))
    for _, r in ipairs(rows) do f:write(json.encode(r), "\n") end
    f:close()
    -- the writer `memo calibrate` pipes its rows into
    local function ingest()
        return H.sh(("%s %q -e \"package.path='./?.lua;./?/init.lua;'..package.path; require('luamemo.cli.api').dispatch('write-many')\" < %q 2>&1")
            :format(env, lua_bin, path))
    end
    local _, c1 = ingest()
    local n, imp = count(scope), importance_sum(scope)
    check("first run: the rows are written, no miss", c1 == 0 and n >= 3 and misses(scope) == 0, n)
    for _ = 1, 5 do ingest() end
    check("five more runs: still no miss", misses(scope) == 0, misses(scope))
    check("… the importance of the rows is what it was (a miss would have raised it)", math.abs(importance_sum(scope) - imp) < 1e-9,
        importance_sum(scope) .. " vs " .. imp)
    check("… and the rows were refreshed in place, not doubled", count(scope) == n, count(scope) .. " vs " .. n)
end)

section("an agent writing the same decision again is still a miss", function()
    local scope = "repo:agent"
    local w = function(strategy)
        return luamemo.store.write({ scope = scope, kind = "decision", title = "use sqlite", importance = 0.4,
            body = "we chose sqlite for the single file database", dedup_strategy = strategy })
    end
    w()
    w()
    check("one miss recorded", misses(scope) == 1, misses(scope))
    -- (with dedup "update" the merge writes the row's own importance back; "skip" keeps the old row, bump and
    -- all — a bump on a 0–1 scale, so it only moves a memory whose importance is under 1)
    local imp = importance_sum(scope)
    w("skip")
    check("… a second one, and the memory is easier to find (importance up) when the write keeps the old row",
        misses(scope) == 2 and importance_sum(scope) > imp, misses(scope) .. ", " .. importance_sum(scope) .. " vs " .. imp)
end)

section("raw conversation", function()
    local scope = "repo:hooks"
    local convo = "user asked about the retry backoff. assistant explained the doubling wait."
    for i = 1, 4 do
        assert(luamemo.store.write({ scope = scope, kind = "conversation", tier = 0, title = "session snapshot", importance = 0.3,
            body = convo .. string.rep(" and then they discussed the cache key.", i) }))
    end
    check("tier-0 snapshots, each repeating the one before: no miss", misses(scope) == 0, misses(scope))
end)

section("luamemo's own writes", function()
    local scope = "repo:own"
    local row = { scope = scope, kind = "fact", title = "deploys", body = "the deploy runs on friday after the freeze" }
    assert(luamemo.store.write(row))
    assert(luamemo.store.write({ scope = scope, kind = "fact", title = "deploys", body = row.body, no_miss = true }))
    check("a near-duplicate written with no_miss: no miss", misses(scope) == 0, misses(scope))
    assert(luamemo.store.write({ scope = scope, kind = "fact", title = "deploys", body = row.body }))
    check("the same write without it: a miss", misses(scope) == 1, misses(scope))
    local fields = ops.write_fields({ title = "t", body = "b", no_miss = true }, scope)
    check("no tool can pass it: write_fields drops it", fields.no_miss == nil)
    -- a session folded into a summary, then again (the second summary repeats the first)
    local sess, long = "session:own", "repo:promoted"
    for i = 1, 3 do assert(luamemo.store.write({ scope = sess, title = "step " .. i, body = "ran the migration number " .. i .. " on staging" })) end
    local r1 = ops.promote({ from_scope = sess, to_scope = long })
    local r2 = ops.promote({ from_scope = sess, to_scope = long })
    check("a promoted summary written twice: no miss", r1 and r2 and misses(long) == 0, misses(long))
end)

section("import and index ingest of the same rows twice", function()
    local scope = "repo:moved"
    for i = 1, 3 do assert(luamemo.store.write({ scope = scope, title = "moved " .. i, body = "a memory about topic " .. i .. " worth keeping" })) end
    local exp = TMP .. "/export.jsonl"
    H.sh(("%s ./cli/memo export --scope %s > %q 2>/dev/null"):format(env, scope, exp))
    local before = misses(scope)
    H.sh(("%s ./cli/memo import %q --dedup update 2>&1"):format(env, exp))
    H.sh(("%s ./cli/memo import %q --dedup update 2>&1"):format(env, exp))
    check("import, twice: no miss", misses(scope) == before, misses(scope) - before)
    local iscope = "codeindex:moved"
    for _ = 1, 2 do require("luamemo.index").ingest("eval/fixtures/corpus_src/alpha", { scope = iscope }) end
    check("index ingest, twice: no miss", misses(iscope) == 0, misses(iscope))
end)

os.execute("rm -rf " .. TMP)
finish()
