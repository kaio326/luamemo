-- eval/tests/test_convomem.lua
-- Phase 16.6a smoke test: ConvoMem loader + runner against the tiny
-- hand-crafted fixture.
--
-- Validates:
--   1. convomem.load parses the fixture JSON.
--   2. iter_sessions yields sessions in array order, with derived ids.
--   3. qa_gold_sessions builds the gold set from evidence_session_ids.
--   4. category_name passes through string categories.
--   5. End-to-end run via convomem_run.lua against the fixture.
--
-- Run (the end-to-end step uses the database MEMO_DB names; the test runner sets a
-- new one per file):
--   MEMO_DB=/tmp/test_convomem.db luajit eval/tests/test_convomem.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;eval/datasets/?.lua;" .. package.path

local convomem = require("convomem")
local cjson    = require("luamemo.json")

-- Tracked fixture (eval/data/ is gitignored — a fresh clone would not have it).
local FIXTURE = "eval/fixtures/convomem_tiny.json"

-- The runner is launched with the same interpreter as this test, so a LuaJIT
-- run exercises convomem_run.lua under LuaJIT too. The interpreter is the
-- lowest negative arg index (options like -e sit between).
local LUA_BIN = "luajit"
if arg then
    local i = -1
    while arg[i - 1] do i = i - 1 end
    LUA_BIN = arg[i] or LUA_BIN
end

local function header(s) print("\n=== " .. s .. " ===") end

-- ---------------------------------------------------------------------------
header("load fixture")
local rows = convomem.load(FIXTURE)
assert(#rows == 2, "expected 2 fixture rows, got " .. #rows)
print(string.format("  %d rows OK", #rows))

-- ---------------------------------------------------------------------------
header("iter_sessions")
local r1 = rows[1]
local sids = {}
for sid, turns in convomem.iter_sessions(r1) do
    sids[#sids + 1] = sid
    assert(type(turns) == "table" and #turns >= 1)
end
assert(#sids == 3 and sids[1] == "s1" and sids[2] == "s2" and sids[3] == "s3",
    "sessions out of order: " .. table.concat(sids, ","))
print("  row1 sessions = " .. table.concat(sids, ", ") .. " OK")

-- ---------------------------------------------------------------------------
header("qa_gold_sessions")
local g_dog = convomem.qa_gold_sessions(r1.qa[2])
assert(g_dog["s3"] == true, "dog QA gold should include s3")
local r2 = rows[2]
local g_book = convomem.qa_gold_sessions(r2.qa[1])
assert(g_book["s1"] == true and g_book["s2"] == true,
    "book QA gold should include s1 and s2")
print("  dog qa gold = {s3}; book qa gold = {s1, s2} OK")

-- ---------------------------------------------------------------------------
header("category_name")
assert(convomem.category_name("factual")   == "factual")
assert(convomem.category_name("multi-hop") == "multi-hop")
assert(convomem.category_name(nil)         == "unknown")
assert(convomem.category_name(7)           == "7")
print("  string passthrough, nil->unknown, num->str OK")

-- ---------------------------------------------------------------------------
header("end-to-end against fixture (hash embedder)")
-- Smoke output goes to a temp file, not eval/results/ (real benchmark results).
local OUT = os.tmpname()
assert(os.getenv("MEMO_DB") and os.getenv("MEMO_DB") ~= "", "MEMO_DB must name the database for the end-to-end run")
local cmd = string.format("%s eval/convomem_run.lua --embedder hash --corpus %s --out %s 2>&1 | tail -20",
    LUA_BIN, FIXTURE, OUT)
print("  $ " .. cmd)
local rc = os.execute(cmd)
assert(rc == 0 or rc == true, "convomem_run.lua exit non-zero")

local fh = assert(io.open(OUT, "rb"), "smoke output not written: " .. OUT)
local raw = fh:read("*a"); fh:close()
os.remove(OUT)
local report = assert(cjson.decode(raw), "smoke output malformed JSON")
assert(report.overall and report.overall.n_questions == 4,
    "expected 4 QA pairs, got " .. tostring(report.overall and report.overall.n_questions))
print(string.format("  overall n=%d  R@1=%.2f  R@5=%.2f  MRR=%.3f",
    report.overall.n_questions,
    report.overall["recall@1"], report.overall["recall@5"],
    report.overall.mrr))
assert(report.by_category["factual"] or report.by_category["multi-hop"],
    "by_category did not populate")

print("\nAll ConvoMem smoke tests passed.")
