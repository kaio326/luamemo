-- Phase 16.5 smoke test: knowledge-graph layer (luamemo.kg).
-- Runs against the lm_bruteforce_test Postgres used by smoke_bruteforce.
--
-- Prereqs:
--   docker exec -i <postgres-container> psql -U postgres -c \
--     'DROP DATABASE IF EXISTS lm_bruteforce_test; CREATE DATABASE lm_bruteforce_test;'
--   docker exec -i <postgres-container> psql -U postgres -d lm_bruteforce_test \
--     < luamemo/schema_bruteforce.sql
--   docker exec -i <postgres-container> psql -U postgres -d lm_bruteforce_test \
--     < luamemo/migrations/003_kg.sql
--   PGHOST=127.0.0.1 PGPORT=5432 lua5.1 eval/smoke_kg.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

-- luamemo.db creates a pgmoon connection automatically from
-- PGHOST / PGDATABASE / PGUSER / PGPASSWORD env vars when outside OpenResty.

local db     = require("luamemo.db")
local memory = require("luamemo")
memory.setup({
    db_table       = "lm_memories",
    embedder_local = "hash",
    embed_dim      = 384,
    backend        = "auto",
    default_scope  = "smoke_kg",
    auth_fn        = function() return true end,
})

local kg = memory.kg
assert(kg, "memory.kg should be exported")

-- Clean slate. Assumes migration 003_kg.sql has been applied (see header).
db.query("TRUNCATE lm_kg_facts RESTART IDENTITY")

local function header(s) print("\n=== " .. s .. " ===") end

-- ---------------------------------------------------------------------------
-- Test 1: assert + currently-valid query
-- ---------------------------------------------------------------------------
header("assert_fact + query (currently valid)")
local r1, err1 = kg.assert_fact({
    scope = "user:42", subject = "user:42",
    predicate = "theme", object = "dark",
})
assert(r1, "assert_fact failed: " .. tostring(err1))
print(string.format("  inserted id=%d (%s %s = %s)",
    r1.id, r1.subject, r1.predicate, r1.object))

local rows = assert(kg.query({ scope = "user:42", subject = "user:42",
                               predicate = "theme" }))
assert(#rows == 1 and rows[1].object == "dark", "expected dark only")
print("  current = " .. rows[1].object .. " OK")

-- ---------------------------------------------------------------------------
-- Test 2: supersede flips the current value, timeline keeps both
-- ---------------------------------------------------------------------------
header("supersede + timeline")
-- Use a fresh subject for this test so it doesn't share invalidations
-- with Test 4 (which expects user:42's theme to flow dark -> light over
-- explicit timestamps t1 < t2). Without the split, supersede invalidates
-- the t2 row at the wrong wall-clock instant.
local r2 = assert(kg.assert_fact({
    scope = "user:42", subject = "user:99",
    predicate = "theme", object = "dark",
}))
local r3 = assert(kg.assert_fact({
    scope = "user:42", subject = "user:99",
    predicate = "theme", object = "light",
    supersede = true,
}))
print(string.format("  superseded: dark(id=%d) -> light(id=%d)", r2.id, r3.id))

local cur = assert(kg.query({ scope = "user:42", subject = "user:99",
                              predicate = "theme" }))
assert(#cur == 1 and cur[1].object == "light",
    "expected light only after supersede, got " .. (cur[1] and cur[1].object or "<none>"))
print("  current = " .. cur[1].object .. " OK")

local tl = assert(kg.timeline({ scope = "user:42", subject = "user:99",
                                predicate = "theme" }))
assert(#tl == 2, "expected 2 rows in timeline, got " .. #tl)
assert(tl[1].object == "dark"  and tl[1].valid_until ~= nil, "first row should be invalidated dark")
assert(tl[2].object == "light" and tl[2].valid_until == nil, "second row should be open light")
print("  timeline: dark[invalidated] -> light[open] OK")

-- ---------------------------------------------------------------------------
-- Test 3: scope isolation
-- ---------------------------------------------------------------------------
header("scope isolation")
assert(kg.assert_fact({ scope = "user:7", subject = "user:7",
                        predicate = "theme", object = "monokai" }))
local in7 = assert(kg.query({ scope = "user:7", subject = "user:7",
                              predicate = "theme" }))
assert(#in7 == 1 and in7[1].object == "monokai")
local in42 = assert(kg.query({ scope = "user:42", subject = "user:7" }))
assert(#in42 == 0, "user:7's row leaked into scope user:42")
print("  scopes do not leak OK")

-- ---------------------------------------------------------------------------
-- Test 4: point-in-time query (`at`)
-- ---------------------------------------------------------------------------
header("point-in-time query")
-- Wipe and replay with explicit timestamps.
db.query("TRUNCATE lm_kg_facts RESTART IDENTITY")
local t1 = "2025-01-01T00:00:00Z"
local t2 = "2025-06-01T00:00:00Z"
assert(kg.assert_fact({ scope = "user:42", subject = "user:42",
                        predicate = "theme", object = "dark",
                        valid_from = t1 }))
assert(kg.assert_fact({ scope = "user:42", subject = "user:42",
                        predicate = "theme", object = "light",
                        valid_from = t2, supersede = true }))

local at_apr = assert(kg.query({ scope = "user:42", subject = "user:42",
                                 predicate = "theme",
                                 at = "2025-04-01T00:00:00Z" }))
assert(#at_apr == 1 and at_apr[1].object == "dark",
    "April should be dark, got " .. (at_apr[1] and at_apr[1].object or "<none>"))
print("  at=2025-04-01 -> dark OK")

local at_aug = assert(kg.query({ scope = "user:42", subject = "user:42",
                                 predicate = "theme",
                                 at = "2025-08-01T00:00:00Z" }))
assert(#at_aug == 1 and at_aug[1].object == "light",
    "August should be light, got " .. (at_aug[1] and at_aug[1].object or "<none>"))
print("  at=2025-08-01 -> light OK")

-- ---------------------------------------------------------------------------
-- Test 5: invalidate without supersede
-- ---------------------------------------------------------------------------
header("explicit invalidate")
db.query("TRUNCATE lm_kg_facts RESTART IDENTITY")
assert(kg.assert_fact({ scope = "team:eng", subject = "csp",
                        predicate = "inline_styles_allowed", object = "true" }))
local n = assert(kg.invalidate({ scope = "team:eng", subject = "csp",
                                 predicate = "inline_styles_allowed" }))
assert(n == 1, "expected to invalidate 1 row, got " .. tostring(n))
local after = assert(kg.query({ scope = "team:eng", subject = "csp",
                                predicate = "inline_styles_allowed" }))
assert(#after == 0, "expected 0 currently-valid rows after invalidate")
local hist = assert(kg.query({ scope = "team:eng", subject = "csp",
                               predicate = "inline_styles_allowed",
                               include_invalidated = true }))
assert(#hist == 1 and hist[1].valid_until ~= nil)
print("  invalidate -> 0 current, 1 historical OK")

-- ---------------------------------------------------------------------------
-- Test 6: validation errors
-- ---------------------------------------------------------------------------
header("validation errors")
local ok, e = kg.assert_fact({ scope = "x", subject = "s", predicate = "p" })
assert(not ok and e and e:find("object"), "missing object should error")
print("  missing object rejected OK")

local ok2, e2 = kg.query({})  -- no scope
assert(not ok2 and e2 and e2:find("scope"), "missing scope should error")
print("  missing scope rejected OK")

print("\nAll Phase 16.5 KG smoke tests passed.")
