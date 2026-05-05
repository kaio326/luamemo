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
-- Prereqs:
--   docker exec -i <postgres-container> psql -U postgres -c \
--     'DROP DATABASE IF EXISTS lm_bruteforce_test; CREATE DATABASE lm_bruteforce_test;'
--   docker exec -i <postgres-container> psql -U postgres -d lm_bruteforce_test \
--     < lapis_memory/schema_bruteforce.sql
--
-- Run:
--   PGHOST=127.0.0.1 PGPORT=5432 lua5.1 eval/smoke_locomo.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;eval/datasets/?.lua;" .. package.path

local locomo = require("locomo")
local cjson  = require("cjson.safe")

local FIXTURE = "eval/data/fixtures/locomo_tiny.json"

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
local OUT = "eval/results/locomo_hash_smoke.json"
os.execute("rm -f " .. OUT)
local cmd = string.format(
    "PGHOST=%s PGPORT=%s PGDATABASE=%s PGUSER=%s PGPASSWORD=%s "
    .. "lua5.1 eval/locomo_run.lua --embedder hash --corpus %s --out %s 2>&1 | tail -20",
    os.getenv("PGHOST")     or "127.0.0.1",
    os.getenv("PGPORT")     or "5432",
    os.getenv("PGDATABASE") or "lm_bruteforce_test",
    os.getenv("PGUSER")     or "postgres",
    os.getenv("PGPASSWORD") or "postgres",
    FIXTURE, OUT)
print("  $ " .. cmd)
local rc = os.execute(cmd)
assert(rc == 0 or rc == true, "locomo_run.lua exit non-zero")

local fh = assert(io.open(OUT, "rb"), "smoke output not written: " .. OUT)
local raw = fh:read("*a"); fh:close()
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

print("\nAll Phase 16.6a LoCoMo smoke tests passed.")
