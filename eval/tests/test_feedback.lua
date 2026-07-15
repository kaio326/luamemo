-- eval/tests/test_feedback.lua
-- Phase 3 — learned-from-usage substrate (luamemo.feedback + store.search hook).
--   Section 1: log_retrieval / off-by-default / fail-silent
--   Section 2: store.search hook logs candidate sets when feedback_enabled
--   Section 3: harvest joins reinforcements → (query, positive, negatives) triples
--   Section 4: frequency without a reinforcement yields NO training positive
--
-- Usage:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/luamemo_dev \
--     lua5.1 eval/tests/test_feedback.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local db       = require("luamemo.db")
local memory   = require("luamemo")
local feedback = require("luamemo.feedback")

local pass, fail = 0, 0
local function check(label, ok, detail)
    if ok then io.write("[PASS] " .. label .. "\n"); pass = pass + 1
    else io.write("[FAIL] " .. label .. (detail and (" — " .. detail) or "") .. "\n"); fail = fail + 1 end
end
local function header(s) io.write(string.format("\n=== %s ===\n", s)) end

memory.setup({
    db_table = "lm_memories", embedder_local = "hash", embed_dim = 384,
    backend = "auto", auth_fn = function() return true end, skip_embed_probe = true,
})

local SCOPE = "fbtest"
local function wipe()
    db.query("DELETE FROM lm_retrieval_feedback WHERE scope = " .. db.escape_literal(SCOPE))
    db.query("DELETE FROM lm_reinforcements WHERE scope = " .. db.escape_literal(SCOPE))
    db.query("DELETE FROM lm_memories WHERE scope = " .. db.escape_literal(SCOPE))
end
local function count_events()
    local r = db.query("SELECT count(*) AS n FROM lm_retrieval_feedback WHERE scope = " .. db.escape_literal(SCOPE))
    return r and tonumber(r[1].n) or -1
end
wipe()

-- Seed a small haystack.
local ids = {}
for _, m in ipairs({
    { t = "commit rule",  b = "Never commit, tag, or push autonomously." },
    { t = "db client",    b = "Postgres access uses pgmoon, not luadbi." },
    { t = "hash embedder",b = "The hash embedder is lexical feature hashing, not semantic." },
    { t = "checksum",     b = "Change detection uses DJB2 because Lua 5.1 lacks bitwise ops." },
}) do
    local row = memory.write({ scope = SCOPE, kind = "fact", title = m.t, body = m.b, importance = 1.0 })
    ids[m.t] = row and row.id
end

-- =========================================================================
header("Section 1 — log_retrieval / off-by-default / fail-silent")

memory.config.feedback_enabled = false
memory.store.search({ query = "can I push my changes?", scope = SCOPE, limit = 5,
    skip_temporal = true, skip_observations = true })
check("search does NOT log when feedback_enabled=false", count_events() == 0, tostring(count_events()))

check("log_retrieval fail-silent on empty ids", feedback.log_retrieval(SCOPE, "q", {}) == false)
check("log_retrieval fail-silent on nil query", feedback.log_retrieval(SCOPE, nil, {1}) == false)
check("log_retrieval writes a valid event", feedback.log_retrieval(SCOPE, "manual q", { ids["commit rule"], ids["db client"] }) == true)
check("one event present after manual log", count_events() == 1, tostring(count_events()))
db.query("DELETE FROM lm_retrieval_feedback WHERE scope = " .. db.escape_literal(SCOPE))

-- =========================================================================
header("Section 2 — store.search hook logs candidate sets when enabled")

memory.config.feedback_enabled = true
local rows = memory.store.search({ query = "am I allowed to push commits myself?", scope = SCOPE,
    limit = 5, skip_temporal = true, skip_observations = true }) or {}
check("search returned candidates", #rows > 0, tostring(#rows))
check("search logged exactly one retrieval event", count_events() == 1, tostring(count_events()))
local ev = db.query("SELECT query, candidate_ids FROM lm_retrieval_feedback WHERE scope = " .. db.escape_literal(SCOPE))
check("event query recorded", ev and ev[1] and tostring(ev[1].query):find("push commits", 1, true) ~= nil)
-- candidate_ids comes back as a Lua array (pgmoon parses BIGINT[]); count its
-- length directly. (Do NOT tostring() a table — its pointer address is
-- VM-dependent, which silently varies between lua5.1 and LuaJIT.)
local logged = 0
if ev and ev[1] then
    local cid = ev[1].candidate_ids
    if type(cid) == "table" then
        logged = #cid
    else
        for _ in tostring(cid):gmatch("%d+") do logged = logged + 1 end
    end
end
check("event recorded the candidate ids", logged == #rows, "logged=" .. logged .. " returned=" .. #rows)
memory.config.feedback_enabled = false

-- =========================================================================
header("Section 3 — harvest joins reinforcements → training triples")

-- The 'commit rule' memory was a candidate for that query. Record a correction on it.
check("record_reinforcement (mistake) succeeds",
    feedback.record_reinforcement(ids["commit rule"], SCOPE, "mistake", nil, "agent committed without asking") == true)

local triples = feedback.harvest(SCOPE)
check("harvest emits at least one triple", #triples >= 1, tostring(#triples))
local t = triples[1]
check("triple positive is the corrected memory", t and t.positive == ids["commit rule"],
    t and tostring(t.positive) or "nil")
check("triple has negatives (the other candidates)", t and #t.negatives >= 1, t and tostring(#t.negatives) or "nil")
check("positive not among its own negatives", (function()
    if not t then return false end
    for _, n in ipairs(t.negatives) do if n == t.positive then return false end end
    return true
end)())
check("correction weight is 3.0 (corrections dominate)", t and t.weight == 3.0, t and tostring(t.weight) or "nil")
check("signal recorded as mistake", t and t.signal == "mistake")

-- A praise (outcome) on the same memory should not lower the weight below the correction.
feedback.record_reinforcement(ids["commit rule"], SCOPE, "praise", nil, "was right")
local t2
for _, x in ipairs(feedback.harvest(SCOPE)) do if x.positive == ids["commit rule"] then t2 = x end end
check("dedup keeps the highest-weight signal (mistake 3.0 over praise 2.0)", t2 and t2.weight == 3.0,
    t2 and tostring(t2.weight) or "nil")

-- =========================================================================
header("Section 4 — frequency without a reinforcement yields NO positive")

-- 'db client' was retrieved (a candidate) but never reinforced → no triple.
local has_dbclient = false
for _, x in ipairs(feedback.harvest(SCOPE)) do
    if x.positive == ids["db client"] then has_dbclient = true end
end
check("un-reinforced but frequently-retrieved memory produces NO training positive", not has_dbclient,
    "frequency alone must not label data")

-- =========================================================================
wipe()
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
