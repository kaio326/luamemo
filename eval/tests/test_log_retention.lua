-- eval/tests/test_log_retention.lua
-- The usage log keeps a search MEMO_FEEDBACK_RETENTION_DAYS and no longer — except what something learns from.
--   A. the setting, and what goes: old searches (found something or nothing), what stays: young ones, a search that offered a
--      reinforced memory (the learner's training triples), a row adopted from an organization
--   B. harvest gives the same triples before and after pruning
--   C. 0 keeps everything; the daily throttle; `memo maintain` prunes
--   D. only the newest 20 per reinforced memory and scope stay past the retention; a search never prunes (the brief
--      starts the run that does); a prune that fails says so; `memo doctor` warns when the retention is shorter than
--      either grace period
-- Run: luajit eval/tests/run.lua --only log_retention

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Usage log retention")
local check, finish = T.check, T.finish

local luamemo     = require("luamemo")
local db          = require("luamemo.db")
local util        = require("luamemo.util")
local settings    = require("luamemo.settings")
local feedback    = require("luamemo.feedback")
local maintenance = require("luamemo.maintenance")

-- (a section that stubs the process start puts it back when it ends, a failed check or a crash included)
local function section(name, fn) T.section(name, fn, function() maintenance.spawner = nil end) end

local DAY = util.DAY_US

local function setup(extra) H.setup(extra, { feedback_enabled = true, feedback_retention_days = 90 }) end

local function logged(scope, extra)
    return H.count("SELECT count(*) FROM lm_retrieval_feedback WHERE scope = ?" .. (extra or ""), scope)
end

-- a search logged `days` days ago
local function log_at(days, fn, ...) return H.at_age(days * DAY, fn, ...) end

section("the setting", function()
    local d = settings.defaults()
    check("shipped: 90 days; the log itself stays off", d.feedback_retention_days == 90 and d.feedback_enabled == false)
    setup({ feedback_retention_days = 30 })
    check("feedback.retention_days() follows the setting", feedback.retention_days() == 30)
    setup({})
    check("… and back", feedback.retention_days() == 90)
    -- memo doctor warns when searches go before a folded memory is reviewed — by either grace period
    local function warns(extra)
        setup(extra)
        return table.concat(feedback.status_lines(luamemo.config), "\n"):find("no longer counts", 1, true) ~= nil
    end
    check("no warning at the shipped numbers (90 days kept, 30 to review)", not warns({}))
    check("a retention shorter than the fold grace warns", warns({ feedback_retention_days = 20 }))
    check("… and so does one shorter than the digest's own grace",
        warns({ feedback_retention_days = 60, digest_grace_days = 100 }))
    setup({ digest_grace_days = false })
end)

section("what goes and what stays", function()
    setup({})
    local scope = "repo:ret-a"
    local m1 = assert(luamemo.store.write({ scope = scope, title = "one", body = "the retry backoff is exponential" }))
    local m2 = assert(luamemo.store.write({ scope = scope, title = "two", body = "the cache key includes the tenant" }))
    log_at(120, feedback.log_retrieval, scope, "old plain search", { m1.id })
    log_at(120, feedback.log_no_result, scope, "old search that found nothing")
    log_at(120, feedback.log_retrieval, scope, "old search that offered a praised memory", { m2.id })
    log_at(10,  feedback.log_retrieval, scope, "young search", { m1.id })
    log_at(120, function()
        db.run("INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids, created_at, source, source_ref) VALUES (?, ?, ?, ?, 'org', 'x1')",
            scope, "old row adopted from an org", db.json({ m1.id }), util.now_us())
    end)
    feedback.record_reinforcement(m2.id, scope, "praise")
    check("five rows to start with", logged(scope) == 5, logged(scope))

    local n = feedback.prune()
    check("pruning removes the old plain search and the old empty one (2)", n == 2, n)
    check("… the young one stays", logged(scope, " AND query = 'young search'") == 1)
    check("… the old one that offered a reinforced memory stays (a training example)",
        logged(scope, " AND query LIKE '%praised memory'") == 1)
    check("… the old row adopted from an organization stays", logged(scope, " AND query LIKE '%adopted%'") == 1)
    check("its candidate rows follow the removal (cascade)", tonumber(db.value("SELECT count(*) FROM lm_retrieval_candidates c "
        .. "LEFT JOIN lm_retrieval_feedback f ON f.id = c.feedback_id WHERE f.id IS NULL")) == 0)
end)

section("the learner's training set is the same after pruning", function()
    setup({})
    local scope = "repo:ret-b"
    local a = assert(luamemo.store.write({ scope = scope, title = "alpha", body = "alpha fact about deploys" }))
    local b = assert(luamemo.store.write({ scope = scope, title = "beta", body = "beta fact about rollbacks" }))
    log_at(200, feedback.log_retrieval, scope, "how do deploys work", { b.id, a.id })
    log_at(200, feedback.log_retrieval, scope, "something nobody confirmed", { b.id })
    log_at(5,   feedback.log_retrieval, scope, "how do rollbacks work", { b.id })
    feedback.record_reinforcement(a.id, scope, "praise")
    local function key(ts)
        local out = {}
        for i, t in ipairs(ts) do out[i] = t.query .. ">" .. tostring(t.positive) .. "/" .. #(t.negatives or {}) end
        table.sort(out)
        return table.concat(out, "|")
    end
    local before = key(feedback.harvest(scope))
    local n = feedback.prune()
    local after = key(feedback.harvest(scope))
    check("the unconfirmed old search went (1)", n == 1 and logged(scope, " AND query = 'something nobody confirmed'") == 0, n)
    check("harvest gives the very same triples", before ~= "" and before == after, before .. " vs " .. after)
end)

section("every kind of reinforcement keeps its searches", function()
    setup({})
    local scope = "repo:ret-e"
    local kinds = { "mistake", "reversal", "direct_command", "miss", "praise" }
    local mems = {}
    for i, k in ipairs(kinds) do
        mems[k] = assert(luamemo.store.write({ scope = scope, title = k, body = "note for the " .. k .. " case, number " .. i,
            dedup_strategy = "append" }))
        log_at(200, feedback.log_retrieval, scope, "old search about " .. k, { mems[k].id })
        feedback.record_reinforcement(mems[k].id, scope, k)
    end
    local plain = assert(luamemo.store.write({ scope = scope, title = "plain", body = "a note nobody reinforced", dedup_strategy = "append" }))
    log_at(200, feedback.log_retrieval, scope, "old search about the plain one", { plain.id })
    local n = feedback.prune()
    check("only the search that offered nothing reinforced goes (1 of 6)", n == 1 and logged(scope) == 5, n)
    for _, k in ipairs(kinds) do
        check("a search that offered a memory with a '" .. k .. "' stays", logged(scope, " AND query = 'old search about " .. k .. "'") == 1)
    end
end)

section("past the retention only the newest searches per reinforced memory stay", function()
    setup({})
    local scope = "repo:ret-f"
    local m = assert(luamemo.store.write({ scope = scope, title = "hot", body = "a memory every search offers", dedup_strategy = "append" }))
    feedback.record_reinforcement(m.id, scope, "praise")
    for i = 1, 30 do log_at(100 + i, feedback.log_retrieval, scope, "old search " .. i, { m.id }) end   -- 1 is the newest
    log_at(5, feedback.log_retrieval, scope, "a young search", { m.id })
    local before = feedback.harvest(scope)
    local n = feedback.prune()
    check("31 searches offered it: the newest 20 of all stay (the young one and 19 old), the other 11 old ones go",
        n == 11 and logged(scope, " AND query LIKE 'old search %'") == 19, n)
    check("… the ones that stay are the newest", logged(scope, " AND query = 'old search 1'") == 1 and logged(scope, " AND query = 'old search 19'") == 1
        and logged(scope, " AND query = 'old search 20'") == 0)
    check("… and the young one stays whatever (it is not old)", logged(scope, " AND query = 'a young search'") == 1)
    check("the setting's text and `memo usage` name the same number the code keeps (" .. feedback.KEEP_PER_REINFORCED .. ")",
        settings.get("MEMO_FEEDBACK_RETENTION_DAYS").doc:find("newest " .. feedback.KEEP_PER_REINFORCED .. " ", 1, true) ~= nil
        and feedback.KEEP_PER_REINFORCED > feedback.HARVEST_EVENTS)
    local function keyset(ts) local o = {}; for i, t in ipairs(ts) do o[i] = t.query .. ">" .. tostring(t.positive) end; table.sort(o); return table.concat(o, "|") end
    check("harvest reads the newest few: the same triples after as before", keyset(before) == keyset(feedback.harvest(scope)))
end)

section("the newest are counted per scope, and a tie in time is broken by the later row", function()
    setup({})
    local m = assert(luamemo.store.write({ scope = "repo:ret-m", title = "shared", body = "one memory searched from two scopes", dedup_strategy = "append" }))
    feedback.record_reinforcement(m.id, "repo:ret-m", "praise")
    local K = feedback.KEEP_PER_REINFORCED
    local scopes = { "repo:ret-g1", "repo:ret-g2" }
    for _, s in ipairs(scopes) do
        for i = 1, K + 3 do log_at(100 + i, feedback.log_retrieval, s, "old " .. i, { m.id }) end
    end
    local n = feedback.prune()
    check("each scope keeps its own newest " .. K .. " (the other scope's searches do not use them up)",
        n == 6 and logged(scopes[1]) == K and logged(scopes[2]) == K, n)

    -- three searches in the very same microsecond: the one logged last counts as the newest
    local scope = "repo:ret-h"
    local t = util.now_us() - 100 * DAY
    for i = 1, 3 do
        feedback.log_retrieval(scope, "tied " .. i, { m.id })
    end
    db.run("UPDATE lm_retrieval_feedback SET created_at = ? WHERE scope = ?", t, scope)
    local old = feedback.KEEP_PER_REINFORCED
    local ok = pcall(function()
        feedback.KEEP_PER_REINFORCED = 2
        feedback.prune()
    end)
    feedback.KEEP_PER_REINFORCED = old
    check("pruned with room for two", ok and logged(scope) == 2)
    check("… the first-logged of three equal times is the one that went", logged(scope, " AND query = 'tied 1'") == 0
        and logged(scope, " AND query = 'tied 3'") == 1)
end)

section("0 keeps everything; the daily throttle", function()
    setup({ feedback_retention_days = 0 })
    local scope = "repo:ret-c"
    log_at(900, feedback.log_no_result, scope, "ancient gap")
    check("retention 0: nothing is removed", feedback.prune() == 0 and logged(scope) == 1)

    setup({})
    db.run("DELETE FROM lm_meta WHERE key = 'feedback_pruned_at'")
    local first = feedback.prune_daily()
    check("the first daily prune runs (and removes the ancient gap)", first == 1 and logged(scope) == 0, tostring(first))
    log_at(900, feedback.log_no_result, scope, "another ancient gap")
    check("… the second within the day does not run", feedback.prune_daily() == nil and logged(scope) == 1)
    db.run("UPDATE lm_meta SET value = ? WHERE key = 'feedback_pruned_at'", ("%.0f"):format(util.now_us() - 2 * DAY))
    check("… two days later it does", feedback.prune_daily() == 1 and logged(scope) == 0)
end)

section("a search never prunes; the session brief and the maintenance runs do", function()
    setup({})
    local scope = "repo:ret-g"
    db.run("DELETE FROM lm_meta WHERE key = 'feedback_pruned_at'")
    feedback.log_retrieval(scope, "a search that found something", { 1 })
    feedback.log_no_result(scope, "a search that found nothing")
    check("neither kind of search touches the daily stamp (a search would wait for the prune)",
        tonumber(db.value("SELECT count(*) FROM lm_meta WHERE key = 'feedback_pruned_at'")) == 0)
    -- the brief starts the prune when nothing else is due
    local started = {}
    maintenance.spawner = function(s, what) started[#started + 1] = { scope = s, what = what }; return true end
    local function brief_kick(extra)
        setup(extra)
        db.run("DELETE FROM lm_meta WHERE key = 'maintain_kick'")
        started = {}
        require("luamemo.brief").text(scope)
        return #started
    end
    local n_on = brief_kick({ feedback_enabled = true })
    check("usage log on, nothing to review: the brief starts a background run for its scope (which ends with the prune)",
        n_on == 1 and started[1].scope == scope and started[1].what.review == true and not started[1].what.all)
    check("usage log off: nothing is started for it", brief_kick({ feedback_enabled = false }) == 0)
    check("retention 0 (kept for ever): nothing is started for it", brief_kick({ feedback_enabled = true, feedback_retention_days = 0 }) == 0)
    maintenance.spawner = nil
    setup({})
end)

section("a real search leaves the log's old rows alone; a prune that fails says so", function()
    setup({ feedback_enabled = true })
    local scope = "repo:ret-s"
    assert(luamemo.store.write({ scope = scope, title = "x", body = "the retry backoff is exponential", dedup_strategy = "append" }))
    log_at(400, feedback.log_no_result, scope, "an old gap")
    db.run("DELETE FROM lm_meta WHERE key = 'feedback_pruned_at'")
    luamemo.search({ scope = scope, query = "retry backoff" })
    luamemo.search({ scope = scope, query = "zzqq xxww unmatched words" })
    check("two searches through luamemo.search: the old row is still there and the daily stamp is not taken",
        logged(scope, " AND query = 'an old gap'") == 1
        and tonumber(db.value("SELECT count(*) FROM lm_meta WHERE key = 'feedback_pruned_at'")) == 0)
    -- the delete fails
    local function with_failing_delete(fn)
        return H.with_trigger("ret_no_delete", "BEFORE DELETE ON lm_retrieval_feedback BEGIN SELECT RAISE(ABORT, 'no'); END", fn)
    end
    local pruned, why = with_failing_delete(feedback.prune)
    check("a prune whose delete fails returns nil and the reason (it is not '0 rows')", pruned == nil and why ~= nil, tostring(why))
    db.run("DELETE FROM lm_meta WHERE key = 'feedback_pruned_at'")
    local out = with_failing_delete(function() return maintenance.run(scope, { review = true }) end)
    local problems = maintenance.problems(out)
    check("… and a maintenance run reports it with its other problems", problems and problems[#problems]:find("usage log prune", 1, true) ~= nil,
        require("luamemo.json").encode(problems))
end)

section("memo maintain prunes", function()
    setup({})
    local scope = "repo:ret-d"
    log_at(400, feedback.log_no_result, scope, "an old gap before the run")
    db.run("DELETE FROM lm_meta WHERE key = 'feedback_pruned_at'")
    local out = maintenance.run(scope, { review = true })
    check("a maintenance run prunes the log and says how many", out.pruned and out.pruned >= 1 and logged(scope) == 0, tostring(out.pruned))
end)

finish()
