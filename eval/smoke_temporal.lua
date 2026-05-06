-- Phase 11.1 smoke: temporal filters on store.search.
--
-- Reuses the existing `tune_test` scope (30 rows, all freshly seeded
-- with updated_at = now()). We backdate exactly 10 of them by 60 days
-- and confirm `since` / `until_` partition the result set correctly.
--
-- Usage:
--   PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=lm_bruteforce_test \
--     lua5.1 eval/smoke_temporal.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

-- luamemo.db creates a pgmoon connection automatically from
-- PGHOST / PGDATABASE / PGUSER / PGPASSWORD env vars when outside OpenResty.

local memory = require("luamemo")
local db     = require("luamemo.db")

memory.setup({
    db_table       = "lapis_memory",
    embedder_local = "hash",
    embed_dim      = 384,
    backend        = "auto",
    default_scope  = "tune_test",
    auth_fn        = function() return true end,
})

-- --- arrange --------------------------------------------------------------
-- Disable the touch trigger so backdating sticks.
db.query("ALTER TABLE lapis_memory DISABLE TRIGGER lapis_memory_touch_updated_at_trg")

-- Reset all rows to "now" first (in case of leftover state from prior runs).
db.query("UPDATE lapis_memory SET updated_at = now() WHERE scope = 'tune_test'")

-- Backdate the 10 lowest-id rows by 60 days.
db.query([[
    UPDATE lapis_memory SET updated_at = now() - interval '60 days'
     WHERE id IN (SELECT id FROM lapis_memory WHERE scope = 'tune_test'
                  ORDER BY id LIMIT 10)
]])

db.query("ALTER TABLE lapis_memory ENABLE TRIGGER lapis_memory_touch_updated_at_trg")

-- Sanity-check the split.
local counts = db.query([[
    SELECT
      sum(CASE WHEN updated_at >= now() - interval '30 days' THEN 1 ELSE 0 END) AS recent,
      sum(CASE WHEN updated_at <  now() - interval '30 days' THEN 1 ELSE 0 END) AS old
    FROM lapis_memory WHERE scope = 'tune_test'
]])[1]
print(("backdated split: recent=%s  old=%s"):format(counts.recent, counts.old))
assert(tonumber(counts.recent) == 20, "expected 20 recent rows")
assert(tonumber(counts.old)    == 10, "expected 10 backdated rows")

-- --- act + assert ---------------------------------------------------------
-- Use a query that matches many rows so all 30 are candidates.
local Q = "docker"   -- hash embedder; cap is 1000 by default; FTS uniform.

-- Case 1: no temporal filter -> all 30 pass through (limit defaults to 10
-- but candidate pool has all 30; we use a high limit for assertion).
local r1 = assert(memory.search({ query = Q, scope = "tune_test", limit = 100 }))
print(("case 1: no filter -> %d rows"):format(#r1))
assert(#r1 == 30, ("expected 30 rows total, got %d"):format(#r1))

-- Case 2: since = now()-30 days -> excludes the 10 backdated rows.
local thirty_days_ago = os.time() - 30 * 86400
local r2 = assert(memory.search({
    query = Q, scope = "tune_test", limit = 100,
    since = thirty_days_ago,
}))
print(("case 2: since=epoch(now-30d) -> %d rows"):format(#r2))
assert(#r2 == 20, ("expected 20 rows after since-filter, got %d"):format(#r2))

-- Case 3: until_ = now()-30 days -> ONLY the 10 backdated rows.
local r3 = assert(memory.search({
    query = Q, scope = "tune_test", limit = 100,
    until_ = thirty_days_ago,
}))
print(("case 3: until_=epoch(now-30d) -> %d rows"):format(#r3))
assert(#r3 == 10, ("expected 10 rows before until-filter, got %d"):format(#r3))

-- Case 4: ISO-8601 date string also accepted.
local iso = os.date("!%Y-%m-%d", thirty_days_ago)
local r4 = assert(memory.search({
    query = Q, scope = "tune_test", limit = 100,
    since = iso,
}))
print(("case 4: since=%q -> %d rows"):format(iso, #r4))
-- ISO date is at midnight UTC of that day; allow +/-1 row of slop vs. epoch.
assert(#r4 >= 19 and #r4 <= 21, ("expected ~20 rows for ISO since, got %d"):format(#r4))

-- Case 5: bad input -> clean error.
local r5, err5 = memory.search({
    query = Q, scope = "tune_test", since = {},
})
assert(r5 == nil, "expected nil result for bad since")
assert(tostring(err5):find("since:", 1, true), "expected 'since:' in error: " .. tostring(err5))
print("case 5: bad input -> error: " .. tostring(err5))

-- Case 6: half-open interval semantics (>=since AND <until_).
-- since = 90d ago, until_ = 30d ago -> exactly the 10 backdated rows
-- (60d ago is between 90d and 30d).
local r6 = assert(memory.search({
    query = Q, scope = "tune_test", limit = 100,
    since  = os.time() - 90 * 86400,
    until_ = os.time() - 30 * 86400,
}))
print(("case 6: since=90d, until_=30d -> %d rows"):format(#r6))
assert(#r6 == 10, ("expected 10 rows in [90d, 30d), got %d"):format(#r6))

print("\nALL OK")
