-- eval/tests/test_learn_auto.lua
-- The learned reranker, on where it is chosen: `memo maintain` trains each scope's reranker in the background when it
-- is due, from the usage log, and the gate (luamemo.promote) promotes a model only if it beats the current ranking on
-- held-out data. The shipped default stays `noop`: none of this happens unless MEMO_RERANK_ADAPTER=learned.
--   A. the defaults (noop, not enabled), and that a learned adapter with no model leaves the order untouched
--   B. the training step: only with the learned adapter AND the usage log on; once per interval per scope; not for the
--      code index or a replica; it is part of the hourly digest run and of `memo maintain --learn`
--   C. `memo usage` says what the training did
-- Run: luajit eval/tests/run.lua --only learn_auto

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Learn automatically")
local check, section, finish = T.check, T.section, T.finish

local luamemo     = require("luamemo")
local db          = require("luamemo.db")
local util        = require("luamemo.util")
local store       = require("luamemo.store")
local settings    = require("luamemo.settings")
local maintenance = require("luamemo.maintenance")
local usage       = require("luamemo.cli.usage")

local MAIN = assert(os.getenv("MEMO_DB"), "run it with eval/tests/run.lua (MEMO_DB)")
local lua_bin = H.lua_bin()
local DAY = util.DAY_US

local function setup(extra)
    local cfg = { db = MAIN, embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false }
    for k, v in pairs(extra or {}) do cfg[k] = v end
    luamemo.setup(cfg)
end

section("the defaults, and a learned reranker with no model", function()
    local d = settings.defaults()
    check("shipped: the reranker is noop and reranking is off; training is on but acts only where the learned one is chosen",
        d.rerank_adapter == "noop" and d.rerank_enabled == false and d.learn_auto == true and d.learn_interval_days == 7)
    setup({ rerank_adapter = "noop", rerank_enabled = false })
    local scope = "repo:learn-a"
    for i = 1, 6 do
        assert(store.write({ scope = scope, title = "topic " .. i, body = "note number " .. i .. " about the retry backoff and the cache key",
            importance = 1, dedup_strategy = "append" }))
    end
    local function order(extra)
        setup(extra)
        local rows = luamemo.search({ scope = scope, query = "retry backoff cache key", limit = 6, skip_feedback = true })
        local ids = {}
        for i, r in ipairs(rows or {}) do ids[i] = r.id end
        return table.concat(ids, ",")
    end
    local plain = order({ rerank_adapter = "noop", rerank_enabled = false })
    local learned = order({ rerank_adapter = "learned", rerank_enabled = true })
    check("the learned reranker, on, with no promoted model: the very same order", plain ~= "" and plain == learned, plain .. " vs " .. learned)
end)

section("the training step", function()
    local promote = require("luamemo.promote")
    local real_run, calls = promote.run, {}
    promote.run = function(scope, opts) calls[#calls + 1] = scope; return { scope = scope, decision = "skip", reason = "insufficient examples (3 < 20)" } end
    local function reset() calls = {}; db.run("DELETE FROM lm_meta WHERE key LIKE 'learn_last:%'") end

    setup({ rerank_adapter = "noop", feedback_enabled = true })
    reset()
    check("noop reranker: nothing is trained", maintenance.learn("repo:learn-b").skipped == "off" and #calls == 0)
    setup({ rerank_adapter = "learned", feedback_enabled = false })
    check("learned, but no usage log: nothing to learn from", maintenance.learn("repo:learn-b").skipped == "off" and #calls == 0)
    setup({ rerank_adapter = "learned", feedback_enabled = true, learn_auto = false })
    check("MEMO_LEARN_AUTO=false: off", maintenance.learn("repo:learn-b").skipped == "off" and #calls == 0)

    setup({ rerank_adapter = "learned", feedback_enabled = true, learn_auto = true, learn_interval_days = 7 })
    local r1 = maintenance.learn("repo:learn-b")
    check("learned + the log: the gate is asked, once", r1.decision == "skip" and #calls == 1 and calls[1] == "repo:learn-b", #calls)
    local r2 = maintenance.learn("repo:learn-b")
    check("… and not again within the interval (even though there was not enough to learn from)", r2.skipped == "not due" and #calls == 1)
    check("another scope has its own interval", maintenance.learn("repo:learn-c").decision == "skip" and #calls == 2)
    db.run("UPDATE lm_meta SET value = ? WHERE key = 'learn_last:repo:learn-b'", ("%.0f"):format(util.now_us() - 8 * DAY))
    check("… after the interval it is due again", maintenance.learn("repo:learn-b").decision == "skip" and #calls == 3)
    check("the code index is never trained on", maintenance.learn("codeindex:learn-d").skipped == "codeindex" and #calls == 3)

    -- it rides on the hourly digest run, and on --learn; the other parts do not start it
    reset()
    maintenance.run("repo:learn-e", { digest = true })
    check("a digest run trains (the hourly one: the weekly throttle keeps it cheap)", #calls == 1 and calls[1] == "repo:learn-e", #calls)
    reset()
    maintenance.run("repo:learn-e", { summarize = true })
    check("a summarizing run alone does not", #calls == 0, #calls)
    maintenance.run("repo:learn-e", { learn = true })
    check("`--learn` does", #calls == 1, #calls)
    reset()
    maintenance.run("repo:learn-f")
    check("a run with nothing named does all of it, training included", #calls == 1, #calls)

    local started
    maintenance.spawner = function(scope, what) started = what; return true end
    maintenance.spawn("repo:learn-g", { learn = true })
    maintenance.spawner = nil
    check("the process is started with --learn when asked", started and started.learn == true)

    promote.run = real_run
    setup({})
end)

section("the command and the report", function()
    local scope = "repo:learn-h"
    local env = ("env MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q MEMO_RERANK_ADAPTER=learned MEMO_FEEDBACK_ENABLED=true"):format(MAIN, lua_bin)
    local out, code = H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " --learn 2>&1")
    check("`memo maintain --learn` runs the gate and says what it decided", code == 0 and out:find("learned reranker", 1, true)
        and out:find("insufficient", 1, true), out)
    local again = H.sh(env .. " ./cli/memo maintain --scope " .. scope .. " --learn 2>&1")
    check("… and the second time within the interval it says it was not due", again:find("not due", 1, true), again)
    local plain = H.sh(("env MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q ./cli/memo maintain --scope %s --learn 2>&1"):format(MAIN, lua_bin, scope))
    check("with the shipped noop reranker it does nothing", plain:find("off", 1, true) and not plain:find("insufficient", 1, true), plain)

    setup({})
    db.run("INSERT INTO lm_promotion_runs (scope, kind, decision, created_at) VALUES ('repo:learn-i', 'reranker', 'promote', ?)", util.now_us())
    db.run("INSERT INTO lm_promotion_runs (scope, kind, decision, created_at) VALUES ('repo:learn-i', 'reranker', 'reject', ?)", util.now_us())
    db.run("INSERT INTO lm_promotion_runs (scope, kind, decision, created_at) VALUES ('repo:learn-i', 'reranker', 'skip', ?)", util.now_us())
    local r = usage.report(db, { days = 30, scope = "repo:learn-i" })
    check("memo usage counts the attempts: promoted, rejected, without enough", r.learned and r.learned.attempts == 3
        and r.learned.promoted == 1 and r.learned.rejected == 1 and r.learned.skipped == 1, require("luamemo.json").encode(r.learned))
end)

finish()
