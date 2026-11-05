-- eval/tests/test_usage.lua
-- `memo usage`: what the usage log says about real use. A scratch database is filled the way luamemo
-- fills it (feedback.log_retrieval / feedback.record_reinforcement) and the report is read back:
-- searches, follow-ups (repeat / reworded), what was said afterwards, the rank of a
-- memory confirmed useful, the window, the scope filter, the text and --json outputs, and a log that
-- is off.
-- Run: luajit eval/tests/run.lua --only usage

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Usage report")
local check, section, finish = T.check, T.section, T.finish

local luamemo  = require("luamemo")
local db       = require("luamemo.db")
local json     = require("luamemo.json")
local util     = require("luamemo.util")
local usage    = require("luamemo.cli.usage")
local feedback = require("luamemo.feedback")

local MAIN = assert(os.getenv("MEMO_DB"), "run it with eval/tests/run.lua (MEMO_DB)")
local lua_bin = H.lua_bin()

luamemo.setup({ db = MAIN, embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false,
                feedback_enabled = true })

local SEC = 1000000
local DAY = 24 * 3600 * SEC
local real_now = util.now_us
local t0 = real_now() - 3 * DAY
local clock = t0
util.now_us = function() return clock end
local function at(sec) clock = t0 + sec * SEC end

-- (four memories that share no words: writing a near-duplicate is itself recorded as a 'miss')
local TOPICS = { "retry backoff doubles the wait after each failure", "database migrations run in filename order",
                 "the cache key includes the tenant identifier", "release notes are written before tagging" }
local ids = {}
for i = 1, 4 do ids[i] = assert(luamemo.store.write({ scope = "repo:u", title = "topic " .. i, body = TOPICS[i] })).id end

section("an empty log says how to turn it on", function()
    local r = usage.report(db, { days = 30 })
    check("no searches", r.searches == 0)
    local out, code = H.sh(("env MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q ./cli/memo usage --days 30"):format(MAIN, lua_bin))
    check("the command says the log is off and how to turn it on", code == 0 and out:find("MEMO_FEEDBACK_ENABLED", 1, true)
        and out:find("no searches logged", 1, true), out)
end)

section("searches, follow-ups and what was said afterwards", function()
    at(0);    feedback.log_retrieval("repo:u", "how does the retry backoff work", { ids[1], ids[2], ids[3] })
    at(30);   feedback.log_retrieval("repo:u", "how does the retry backoff work", { ids[1], ids[2], ids[3] })      -- repeat
    at(60);   feedback.log_retrieval("repo:u", "retry backoff how is it computed", { ids[1], ids[2] })            -- reworded
    at(90);   feedback.log_retrieval("repo:u", "something else entirely different", { ids[4] })                  -- shares nothing
    at(3600); feedback.log_retrieval("repo:u", "database migration order", { ids[4], ids[3] })                   -- an hour later: not a follow-up
    at(3700); assert(feedback.log_no_result("repo:u", "database migration ordering broken"))                     -- found nothing; reworded, 100 s later
    at(7200); feedback.log_retrieval("repo:v", "other scope question", { ids[1] })
    at(61);   assert(feedback.record_reinforcement(ids[2], "repo:u", "praise"))        -- offered at rank 2 in the search at 60 s
    at(3601); assert(feedback.record_reinforcement(ids[4], "repo:u", "praise"))        -- rank 1
    at(3602); assert(feedback.record_reinforcement(ids[3], "repo:u", "mistake"))
    at(3603); assert(feedback.record_reinforcement(ids[1], "repo:u", "miss"))
    local r = usage.report(db, { days = 30 })
    check("searches, and the one that found nothing", r.searches == 7 and r.empty == 1, json.encode({ r.searches, r.empty }))
    check("follow-ups: 4 within the gap (a repeat, two reworded, one that shares nothing)",
        r.follow_ups == 4 and r.repeats == 1 and r.reworded == 2, json.encode({ r.follow_ups, r.repeats, r.reworded }))
    check("what was said afterwards", r.reinforcements.praise == 2 and r.reinforcements.mistake == 1 and r.reinforcements.miss == 1,
        json.encode(r.reinforcements))
    check("a memory confirmed useful: its rank in the latest search that offered it",
        r.confirmed.n == 2 and r.confirmed.rank1 == 1 and r.confirmed.top3 == 2 and r.confirmed.unseen == 0
        and math.abs(r.confirmed.mrr - 0.75) < 1e-9, json.encode(r.confirmed))
    check("searches a day over the span", r.searches_per_day and r.searches_per_day > 0)
    local scoped = usage.report(db, { days = 30, scope = "repo:v" })
    check("--scope narrows searches and what was said", scoped.searches == 1 and (scoped.reinforcements.praise or 0) == 0)
    local gap = usage.report(db, { days = 30, gap = 10 })
    check("--gap: with ten seconds nothing follows anything", gap.follow_ups == 0)
    util.now_us = real_now
    local old = usage.report(db, { days = 1 })
    check("the window: three days ago is outside one day", old.searches == 0)
end)

section("the command", function()
    util.now_us = real_now
    -- the rows are 3 days old, so --days 30 keeps them
    local out, code = H.sh(("env MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q ./cli/memo usage --days 30"):format(MAIN, lua_bin))
    check("text: the lines a person reads", code == 0 and out:find("searches:", 1, true) and out:find("follow-ups:", 1, true)
        and out:find("said afterwards:", 1, true) and out:find("confirmed useful: 2", 1, true), out)
    local js, jc = H.sh(("env MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q ./cli/memo usage --days 30 --json 2>/dev/null"):format(MAIN, lua_bin))
    local r = json.decode(js:match("(%b{})") or "")
    check("--json: the same report", jc == 0 and r and r.searches == 7 and r.empty == 1 and r.confirmed and r.confirmed.n == 2, js)
    local _, bad = H.sh(("env MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q ./cli/memo usage --days 0 2>&1"):format(MAIN, lua_bin))
    check("a bad number is refused", bad ~= 0)
    local _, bad2 = H.sh(("env MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q ./cli/memo usage --nope 2>&1"):format(MAIN, lua_bin))
    check("an unknown option is refused", bad2 ~= 0)
end)

util.now_us = real_now
finish()
