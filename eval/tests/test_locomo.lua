-- eval/tests/test_locomo.lua
-- Phase 16.6a smoke test: LoCoMo loader + runner against the tiny
-- hand-crafted fixture.
--
-- Validates:
--   1. locomo.load parses the fixture JSON.
--   2. iter_sessions yields sessions in numeric order.
--   3. session_no_from_dia_id parses dia_id strings correctly.
--   4. qa_gold_sessions maps evidence dia_ids -> session id set.
--   5. End-to-end run via the locomo_run.lua bench writes results JSON.
--
-- Run (the end-to-end step uses the database MEMO_DB names; the test runner sets a
-- new one per file):
--   MEMO_DB=/tmp/test_locomo.db luajit eval/tests/test_locomo.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;eval/datasets/?.lua;" .. package.path

local locomo = require("locomo")
local cjson  = require("luamemo.json")

-- Tracked fixture (eval/data/ is gitignored — a fresh clone would not have it).
local FIXTURE = "eval/fixtures/locomo_tiny.json"

-- The runner is launched with the same interpreter as this test, so a LuaJIT
-- run exercises locomo_run.lua under LuaJIT too. The interpreter is the
-- lowest negative arg index (options like -e sit between).
local LUA_BIN = "luajit"
if arg then
    local i = -1
    while arg[i - 1] do i = i - 1 end
    LUA_BIN = arg[i] or LUA_BIN
end

local function header(s) print("\n=== " .. s .. " ===") end

-- ---------------------------------------------------------------------------
-- Test 1: load
-- ---------------------------------------------------------------------------
header("load fixture")
local rows = locomo.load(FIXTURE)
assert(#rows == 2, "expected 2 fixture rows, got " .. #rows)
print(string.format("  %d rows OK", #rows))

-- ---------------------------------------------------------------------------
-- Test 2: dia_id parsing
-- ---------------------------------------------------------------------------
header("dia_id parsing")
assert(locomo.session_no_from_dia_id("D2:3") == 2)
assert(locomo.session_no_from_dia_id("D10:1") == 10)
assert(locomo.session_no_from_dia_id("garbage") == nil)
assert(locomo.session_no_from_dia_id(nil) == nil)
print("  D2:3 -> 2, D10:1 -> 10, garbage -> nil OK")

-- ---------------------------------------------------------------------------
-- Test 3: iter_sessions ordering
-- ---------------------------------------------------------------------------
header("iter_sessions")
local r1 = rows[1]
local sids = {}
for sid, turns in locomo.iter_sessions(r1) do
    sids[#sids + 1] = sid
    assert(type(turns) == "table" and #turns >= 1,
        "session " .. sid .. " missing turns")
end
assert(#sids == 3, "expected 3 sessions in row 1")
assert(sids[1] == "session_1" and sids[2] == "session_2" and sids[3] == "session_3",
    "sessions out of order: " .. table.concat(sids, ","))
print("  row1 sessions = " .. table.concat(sids, ", ") .. " OK")

-- ---------------------------------------------------------------------------
-- Test 4: gold mapping per QA
-- ---------------------------------------------------------------------------
header("qa_gold_sessions")
local qa_paris = r1.qa[1]
local g_paris  = locomo.qa_gold_sessions(qa_paris)
assert(g_paris["session_1"] == true, "Paris evidence should map to session_1")
assert(next(g_paris, "session_1") == nil
   or  (function() local c=0; for _ in pairs(g_paris) do c=c+1 end; return c end)() == 1,
   "Paris evidence should be exactly {session_1}")
print("  paris qa gold = {session_1} OK")

local qa_berlin = r1.qa[3]
local g_berlin  = locomo.qa_gold_sessions(qa_berlin)
assert(g_berlin["session_1"] == true and g_berlin["session_2"] == true,
    "Berlin evidence should include session_1 and session_2")
print("  berlin qa gold = {session_1, session_2} OK")

-- ---------------------------------------------------------------------------
-- Test 5: category names
-- ---------------------------------------------------------------------------
header("category names")
assert(locomo.category_name(1) == "single-hop")
assert(locomo.category_name(3) == "temporal")
assert(locomo.category_name("multi-hop") == "multi-hop")
assert(locomo.category_name(99) == "unknown")
print("  1->single-hop, 3->temporal, str passthrough, 99->unknown OK")

-- ---------------------------------------------------------------------------
-- Test 6: end-to-end via locomo_run.lua against fixture
-- ---------------------------------------------------------------------------
header("end-to-end against fixture (hash embedder)")
-- Smoke output goes to a temp file, not eval/results/ (real benchmark results).
local OUT = os.tmpname()
assert(os.getenv("MEMO_DB") and os.getenv("MEMO_DB") ~= "", "MEMO_DB must name the database for the end-to-end run")
local cmd = string.format("%s eval/locomo_run.lua --embedder hash --corpus %s --out %s 2>&1 | tail -20",
    LUA_BIN, FIXTURE, OUT)
print("  $ " .. cmd)
local rc = os.execute(cmd)
assert(rc == 0 or rc == true, "locomo_run.lua exit non-zero")

local fh = assert(io.open(OUT, "rb"), "smoke output not written: " .. OUT)
local raw = fh:read("*a"); fh:close()
os.remove(OUT)
local report = assert(cjson.decode(raw), "smoke output malformed JSON")
assert(report.overall and report.overall.n_questions == 4,
    "expected 4 QA pairs across the fixture, got "
    .. tostring(report.overall and report.overall.n_questions))
print(string.format("  overall n=%d  R@1=%.2f  R@5=%.2f  MRR=%.3f",
    report.overall.n_questions,
    report.overall["recall@1"], report.overall["recall@5"],
    report.overall.mrr))
assert(report.by_category["single-hop"] or report.by_category["temporal"]
    or report.by_category["multi-hop"],
    "by_category did not populate")

print("\nAll LoCoMo smoke tests passed.")
