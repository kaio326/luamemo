-- eval/tests/test_usage_signals.lua
-- The usage log, read well: what `memo doctor` says about it, whose miss a miss is, when the rates are only anecdotes, and
-- what a miss or a reversal does to a memory's importance on importance's own scale (0–10, an ordinary memory is 1).
--   A. memo doctor: off (what it keeps and enables) / on (how much, how long, who else sees it)
--   B. a near-duplicate write is a miss of one of three kinds: no search first / offered anyway / the ranking missed it
--   C. memo usage: the kinds, the retention line, the small-sample line
--   D. importance: a miss lifts an ordinary memory (and a low one toward 1), within a ceiling; a reversal lowers in proportion
--      and demotes the tier by importance's own thresholds
-- Run: luajit eval/tests/run.lua --only usage_signals

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Usage signals")
local check, section, finish = T.check, T.section, T.finish

local luamemo  = require("luamemo")
local db       = require("luamemo.db")
local feedback = require("luamemo.feedback")
local digest   = require("luamemo.digest")
local usage    = require("luamemo.cli.usage")

local MAIN = assert(os.getenv("MEMO_DB"), "run it with eval/tests/run.lua (MEMO_DB)")
local lua_bin = H.lua_bin()

local function setup(extra) H.setup(extra, { feedback_enabled = true }) end

section("memo doctor says what the log is", function()
    local off = table.concat(feedback.status_lines({ feedback_enabled = false, feedback_retention_days = 45 }), "\n")
    check("off: says it is off, what it keeps and for how long, and what it enables",
        off:find("off", 1, true) and off:find("45 days", 1, true) and off:find("memo usage", 1, true)
        and off:find("learned reranker", 1, true), off)
    check("off, retention 0: forever", table.concat(feedback.status_lines({ feedback_enabled = false, feedback_retention_days = 0 }), "\n"):find("forever", 1, true))

    setup()
    local scope = "repo:sig-a"
    feedback.log_retrieval(scope, "one", { 1 })
    local on = table.concat(feedback.status_lines({ feedback_enabled = true, feedback_retention_days = 90, rerank_adapter = "learned" }), "\n")
    check("on: counts the searches, the retention, that the text is stored, and the reranker", on:find("on, ", 1, true)
        and on:find("search kept for 90 days", 1, true) and on:find("stored in this database", 1, true)
        and on:find("learned reranker: chosen (trains from this log every 7 days)", 1, true), on)
    local plain = table.concat(feedback.status_lines({ feedback_enabled = true, feedback_retention_days = 90 }), "\n")
    check("… with no learned reranker it says 'not chosen'", plain:find("learned reranker: not chosen", 1, true) and not plain:find("every 7 days", 1, true), plain)
    local manual = table.concat(feedback.status_lines({ feedback_enabled = true, rerank_adapter = "learned", learn_auto = false }), "\n")
    check("… with MEMO_LEARN_AUTO=false it says it trains only when asked", manual:find("MEMO_LEARN_AUTO=false", 1, true), manual)
    local daily = table.concat(feedback.status_lines({ feedback_enabled = true, rerank_adapter = "learned", learn_interval_days = 1 }), "\n")
    check("… and it names the interval it is set to", daily:find("every 1 days", 1, true), daily)
    local short = table.concat(feedback.status_lines({ feedback_enabled = true, feedback_retention_days = 7 }), "\n")
    check("a retention shorter than the fold grace period (30 days) is warned about: offers older than that no longer show a memory useful",
        short:find("no longer counts as 'shown useful'", 1, true) ~= nil and not on:find("shown useful", 1, true), short)
    local shared = table.concat(feedback.status_lines({ feedback_enabled = true, org_url = "https://org.example", org_share = "triples" }), "\n")
    check("on, joined to an organization with triples: says the queries go there", shared:find("sent to it", 1, true), shared)
    local quiet = table.concat(feedback.status_lines({ feedback_enabled = true, org_url = "https://org.example", org_share = "signals" }), "\n")
    check("… with signals only it does not", not quiet:find("sent to it", 1, true), quiet)

    local env = ("env MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q MEMO_FEEDBACK_ENABLED=false"):format(MAIN, lua_bin)
    local out = H.sh(env .. " ./cli/memo doctor 2>&1")
    check("the real `memo doctor` has the line", out:find("usage log:", 1, true) and out:find("off (the default)", 1, true), out:sub(1, 400))
end)

section("whose miss a miss is", function()
    setup()
    local function dup(scope, before)
        local a = assert(luamemo.store.write({ scope = scope, title = "pg", body = "Postgres access uses pgmoon, not luadbi." }))
        if before then before(a) end
        assert(luamemo.store.write({ scope = scope, title = "pg", body = "Postgres access uses pgmoon, not luadbi.", dedup_strategy = "append" }))
        local n = db.first("SELECT note FROM lm_reinforcements WHERE memory_id = ? AND event_type = 'miss'", math.floor(a.id))
        return n and n.note
    end
    check("no search first: no-search", dup("repo:sig-b") == "miss:duplicate-write:no-search")
    check("a search offered it and it was written anyway: offered",
        dup("repo:sig-c", function(a) feedback.log_retrieval("repo:sig-c", "pgmoon", { a.id }) end) == "miss:duplicate-write:offered")
    check("a search ran and did not offer it: not-offered (the ranking missed it)",
        dup("repo:sig-d", function() feedback.log_retrieval("repo:sig-d", "database access", { 999999 }) end) == "miss:duplicate-write:not-offered")
    check("a search that found nothing counts as not offering it",
        dup("repo:sig-e", function() feedback.log_no_result("repo:sig-e", "database access") end) == "miss:duplicate-write:not-offered")
    local scope = "repo:sig-f"
    local MIN = 60 * 1000000
    local a = assert(luamemo.store.write({ scope = scope, title = "pg", body = "Postgres access uses pgmoon, not luadbi." }))
    H.at_age(30 * MIN, feedback.log_retrieval, scope, "database access", { 999999 })
    check("a search from half an hour ago is not 'the search before'", feedback.miss_kind(scope, a.id) == "no-search")
    -- the window's edge: 9 minutes counts, 11 does not
    local function kind_after(minutes, ids)
        local s = "repo:sig-win" .. minutes
        local m = assert(luamemo.store.write({ scope = s, title = "w", body = "window probe " .. minutes }))
        H.at_age(minutes * MIN, feedback.log_retrieval, s, "probe", ids(m.id))
        return feedback.miss_kind(s, m.id)
    end
    check("a search 9 minutes before that offered it counts: offered", kind_after(9, function(id) return { id } end) == "offered")
    check("a search 11 minutes before does not: no-search", kind_after(11, function(id) return { id } end) == "no-search")
end)

section("the doctor's counts and the report's order", function()
    setup()
    local s = "repo:sig-doc"
    H.at_age(3 * require("luamemo.util").DAY_US, feedback.log_retrieval, s, "three days ago", { 1 })
    feedback.log_retrieval(s, "today", { 1 })
    local text = table.concat(feedback.status_lines({ feedback_enabled = true }), "\n")
    local total = tonumber(db.value("SELECT count(*) FROM lm_retrieval_feedback"))
    check("the count, in the plural, and the oldest search's age (3 days)",
        total > 1 and text:find(total .. " searches kept", 1, true) and text:find("the oldest 3 days old", 1, true), text)
    local r = usage.report(db, { days = 30 })
    check("the report lists the scopes by searches, the biggest first", r.by_scope[1] and r.by_scope[1].searches >= r.by_scope[#r.by_scope].searches)
end)

section("memo usage reads it", function()
    setup()
    local r = usage.report(db, { days = 30, scope = "repo:sig-d" })
    check("the report counts the kinds", r.miss_kinds["not-offered"] == 1 and r.miss_kinds.offered == 0 and r.miss_kinds["no-search"] == 0
        and r.miss_kinds.other == 0, require("luamemo.json").encode(r.miss_kinds))
    local total = { offered = 0, ["no-search"] = 0, ["not-offered"] = 0 }
    for _, s in ipairs({ "repo:sig-b", "repo:sig-c", "repo:sig-d", "repo:sig-e" }) do
        for k, v in pairs(usage.report(db, { days = 30, scope = s }).miss_kinds) do if total[k] then total[k] = total[k] + v end end
    end
    check("… the four scopes together: no-search 1, offered 1, not-offered 2 (exactly)",
        total["no-search"] == 1 and total.offered == 1 and total["not-offered"] == 2, require("luamemo.json").encode(total))
    db.run("INSERT INTO lm_reinforcements (memory_id, scope, event_type, delta, note, created_at) VALUES (1, 'repo:sig-g', 'miss', 0.5, 'miss:duplicate-write', ?)",
        require("luamemo.util").now_us())
    check("an older note (before kinds were recorded) is 'other'", usage.report(db, { days = 30, scope = "repo:sig-g" }).miss_kinds.other == 1)

    local env = ("env MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q MEMO_FEEDBACK_ENABLED=true MEMO_FEEDBACK_RETENTION_DAYS=60"):format(MAIN, lua_bin)
    local out = H.sh(env .. " ./cli/memo usage --scope repo:sig-d 2>&1")
    check("the text: the retention, the misses by kind, and that a few searches are not rates",
        out:find("keeps a search 60 days", 1, true) and out:find("the ranking missed it 1", 1, true)
        and out:find("too few to read", 1, true), out)
    local asked = H.sh(env .. " ./cli/memo usage --days 200 2>&1")
    check("asking for more days than the log keeps says so", asked:find("older searches are not there", 1, true), asked)
    local plenty = H.sh(env .. " ./cli/memo usage --scope repo:sig-nothing 2>&1")
    check("no searches: says how the log is kept, and that there are none", plenty:find("keeps a search 60 days", 1, true)
        and plenty:find("no searches logged", 1, true), plenty)
end)

section("importance on its own scale", function()
    setup()
    local scope = "repo:sig-h"
    local n = 0
    local function mem(imp)
        n = n + 1
        return assert(luamemo.store.write({ scope = scope, title = "scale " .. n, body = "scale probe number " .. n .. " about " .. ("x"):rep(n), importance = imp,
            dedup_strategy = "append" }))
    end
    local function row(m) return db.first("SELECT importance, tier FROM lm_memories WHERE id = ?", math.floor(m.id)) end
    local function near(a, b) return math.abs(a - b) < 1e-6 end

    local low = mem(0.4)
    digest.apply_event_effect(low.id, scope, "miss", 0.5)
    check("a miss on a low-importance memory lifts it toward 1 (0.4 → 0.55)", near(row(low).importance, 0.55), row(low).importance)

    local ordinary = mem(1.0)
    digest.apply_event_effect(ordinary.id, scope, "miss", 0.5)
    check("a miss on an ordinary memory (1.0) lifts it: 1.25", near(row(ordinary).importance, 1.25), row(ordinary).importance)
    for _ = 1, 3 do digest.apply_event_effect(ordinary.id, scope, "miss", 0.5) end
    check("… again and again, in proportion (1.25 × 1.25³ = 2.44)", near(row(ordinary).importance, 1.25 ^ 4), row(ordinary).importance)

    local mid = mem(5)
    digest.apply_event_effect(mid.id, scope, "miss", 1.0)
    check("a strong miss on a 5 would give 7.5: the ceiling is 7", near(row(mid).importance, 7.0), row(mid).importance)
    for _ = 1, 4 do digest.apply_event_effect(mid.id, scope, "miss", 1.0) end
    check("… and repeated misses cannot go past the ceiling", near(row(mid).importance, 7.0), row(mid).importance)

    local high = mem(9)
    digest.apply_event_effect(high.id, scope, "miss", 1.0)
    check("a memory already above the ceiling is left as it is", near(row(high).importance, 9.0), row(high).importance)

    local five = mem(5)
    local t0 = row(five).tier
    digest.apply_event_effect(five.id, scope, "reversal", 0.5)
    check("a reversal lowers a 5 in proportion (5 → 3.825), not to 1", near(row(five).importance, 5 - (5 - 0.3) * 0.25), row(five).importance)
    check("… and the tier follows importance's thresholds (a 5 is tier 2; 3.8 is tier 1)", t0 == 2 and row(five).tier == 1, tostring(t0) .. " → " .. tostring(row(five).tier))

    local tiny = mem(0.2)
    digest.apply_event_effect(tiny.id, scope, "reversal", 1.0)
    check("a reversal never raises (0.2 stays 0.2)", near(row(tiny).importance, 0.2), row(tiny).importance)
end)

finish()
