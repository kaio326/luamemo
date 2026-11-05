-- eval/tests/test_zero_results.lua
-- A search that finds nothing is logged (with the usage log on) because it is the clearest sign of a gap in
-- memory — and that log must never become memory, training data or something shared. So:
--   A. it is written once per such search, only with the log on, not for a system search, and with no
--      candidates (candidate_ids "[]"; the trigger makes none)
--   B. it never enters memory: no lm_memories row, nothing a search, the brief or an export returns
--   C. nothing learns from it: harvest (the learners' training set) and the org push (which go through the
--      candidates) do not see it; sensing does not take it for "the log is active"
--   D. it is kept 90 days and no longer
--   E. a correction about a memory that was never retrieved is a miss — the sensing lookup that finds the
--      memory is not itself logged as a retrieval of it (it was, with the log on)
-- Run: luajit eval/tests/run.lua --only zero_results

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Zero-result searches")
local check, section, finish = T.check, T.section, T.finish

local luamemo  = require("luamemo")
local db       = require("luamemo.db")
local util     = require("luamemo.util")
local feedback = require("luamemo.feedback")
local sensing  = require("luamemo.sensing")

local MAIN = assert(os.getenv("MEMO_DB"), "run it with eval/tests/run.lua (MEMO_DB)")
local lua_bin = H.lua_bin()

local function setup(on)
    luamemo.setup({ db = MAIN, embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false,
                    feedback_enabled = on })
end
local function logged(scope, where)
    return tonumber(db.value("SELECT count(*) FROM lm_retrieval_feedback WHERE scope = ?" .. (where or ""), scope)) or 0
end

section("when it is logged", function()
    setup(true)
    local scope = "repo:gap"
    local rows = luamemo.search({ scope = scope, query = "how do we rotate the signing key" })
    check("a search in a scope with nothing in it finds nothing", rows and #rows == 0)
    check("… and is logged once, with no candidates", logged(scope) == 1 and logged(scope, " AND candidate_ids = '[]'") == 1)
    check("… the trigger made no candidate rows for it",
        tonumber(db.value("SELECT count(*) FROM lm_retrieval_candidates c JOIN lm_retrieval_feedback f ON f.id = c.feedback_id "
            .. "WHERE f.scope = ?", scope)) == 0)
    luamemo.search({ scope = scope, query = "a system probe", skip_feedback = true })
    check("a system search (skip_feedback) is not logged", logged(scope) == 1)
    check("an empty query is not logged", feedback.log_no_result(scope, "") == false and logged(scope) == 1)
    setup(false)
    luamemo.search({ scope = scope, query = "the log is off" })
    check("with the usage log off, nothing is logged", logged(scope) == 1)
end)

section("it never enters memory", function()
    setup(true)
    local scope = "repo:gap2"
    local before = tonumber(db.value("SELECT count(*) FROM lm_memories"))
    luamemo.search({ scope = scope, query = "zebra quokka telemetry handshake" })
    check("no memory row was written", tonumber(db.value("SELECT count(*) FROM lm_memories")) == before)
    assert(luamemo.store.write({ scope = scope, title = "unrelated", body = "something about deployments on friday" }))
    local hits = luamemo.search({ scope = scope, query = "zebra quokka telemetry handshake", skip_feedback = true })
    local found = false
    for _, r in ipairs(hits or {}) do
        if tostring(r.title .. r.body):find("zebra quokka", 1, true) then found = true end
    end
    check("a later search does not return the logged query", not found)
    local out, code = H.sh(("env MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q ./cli/memo export --scope %s 2>/dev/null")
        :format(MAIN, lua_bin, scope))
    check("an export of the scope does not contain it", code == 0 and not out:find("zebra quokka", 1, true), out)
end)

section("nothing learns from it, nothing is shared", function()
    setup(true)
    local scope = "repo:gap3"
    local a = assert(luamemo.store.write({ scope = scope, title = "retry", body = "the retry backoff doubles after each failure" }))
    luamemo.search({ scope = scope, query = "nothing here matches xyzzy plugh" , min_score = 99 })
    -- a reinforcement on a memory plus an empty search: harvest has no triple to make from the empty one
    assert(feedback.record_reinforcement(a.id, scope, "praise"))
    check("harvest: the empty search gives no training triple",
        #(feedback.harvest(scope, {}) or {}) == 0)
    -- the org push selects retrievals through their candidates: an empty one has none, so it is never selected
    local pushed = db.query("SELECT f.id FROM lm_retrieval_feedback f WHERE f.scope = ? AND EXISTS "
        .. "(SELECT 1 FROM lm_retrieval_candidates c WHERE c.feedback_id = f.id)", scope) or {}
    check("the candidate join the org push goes through never selects it", #pushed == 0)
    -- sensing: a scope whose log holds only empty searches is not "active", so a correction stays a correction
    local scope2 = "repo:gap4"
    local m = assert(luamemo.store.write({ scope = scope2, title = "t", body = "body" }))
    feedback.log_no_result(scope2, "something nobody has written down")
    check("sensing: only empty searches in the log is not an active log",
        sensing._reclassify_if_miss(db, scope2, m.id, "mistake") == "mistake")
    feedback.log_retrieval(scope2, "a real search", { 999999 })
    check("… with a real search in it, a memory never offered is a miss", sensing._reclassify_if_miss(db, scope2, m.id, "mistake") == "miss")
end)

section("how long it is kept", function()
    setup(true)
    local scope = "repo:gap5"
    db.run("DELETE FROM lm_meta WHERE key = 'feedback_pruned_at'")   -- (a maintenance run of an earlier section may have taken today's stamp)
    H.at_age((feedback.retention_days() + 5) * util.DAY_US, feedback.log_no_result, scope, "an old gap")
    check("an old entry is there", logged(scope) == 1)
    -- the pruning is the maintenance run's (once a day), not a search's: searches leave the old entry alone
    for i = 1, 3 do feedback.log_no_result(scope, "a recent gap " .. i) end
    check("a search that finds nothing does not prune (it would wait for it)", logged(scope, " AND query = 'an old gap'") == 1)
    check("the maintenance run's prune removes the entries older than the retention, the recent ones stay",
        feedback.prune_daily() ~= nil and
        logged(scope, " AND query = 'an old gap'") == 0 and logged(scope, " AND query LIKE 'a recent gap%'") == 3)
    local kept = feedback.log_retrieval(scope, "a real retrieval", { 1 })
    check("a recent real retrieval is not touched by the pruning (the old ones: test_log_retention)", kept == true and logged(scope, " AND query = 'a real retrieval'") == 1)
end)

section("a correction about a memory that was never retrieved", function()
    setup(true)
    local scope = "repo:gap6"
    local c = assert(luamemo.store.write({ scope = scope, title = "hybrid",
        body = "Hybrid search unions vector-nearest and top-FTS candidates.", importance = 0.5 }))
    feedback.log_retrieval(scope, "unrelated query", { 999999 })   -- the log is active; c was never a candidate
    sensing.process(scope, { { role = "user", text = "No, that's wrong — hybrid search unions vector-nearest and top-FTS candidates." } }, {})
    local ev = db.query("SELECT event_type FROM lm_reinforcements WHERE scope = ? AND memory_id = ?", scope, math.floor(c.id)) or {}
    check("it is a miss (with the usage log on, as in real use)", ev[1] and ev[1].event_type == "miss", ev[1] and ev[1].event_type or "none")
    check("… and the lookup that found the memory was not logged as a retrieval of it", logged(scope) == 1, logged(scope))
end)

finish()
