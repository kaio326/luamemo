-- Phase 16.7 smoke test: batched ingest via memory.write_many().
-- Exercises:
--   1. Happy path: N rows ingested in one INSERT chunk
--   2. Multi-chunk: rows > batch_size split correctly, RETURNING maps back
--   3. Per-row validation error: one bad row does not abort the batch
--   4. Optional dedup ("skip" / "update") gates correctly
--
-- Run from luamemo/ dir against the same brute-force DB used by the
-- other smokes:
--   PGHOST=127.0.0.1 PGPORT=5432 lua5.1 eval/smoke_write_many.lua
package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

-- luamemo.db creates a pgmoon connection automatically from
-- PGHOST / PGDATABASE / PGUSER / PGPASSWORD env vars when outside OpenResty.

local db     = require("luamemo.db")
local memory = require("luamemo")

memory.setup({
    db_table        = "lm_memories",
    embedder_local  = "hash",
    embed_dim       = 384,
    backend         = "auto",
    default_scope   = "smoke_wm",
    dedup_enabled   = true,
    dedup_threshold = 0.95,
    auth_fn         = function() return true end,
})

local function header(s) print("\n=== " .. s .. " ===") end

assert(memory.store.backend() == "bruteforce", "expected bruteforce backend")

db.query("DELETE FROM lm_memories WHERE scope LIKE 'smoke_wm%'")

-- 1. Happy path -----------------------------------------------------------
header("happy path: 5 rows in single chunk")
local batch = {}
for i = 1, 5 do
    batch[i] = {
        scope = "smoke_wm",
        kind  = "fact",
        title = "row " .. i,
        body  = "body content number " .. i .. " with unique tokens " .. i .. i .. i,
    }
end
local results, err = memory.write_many(batch, { batch_size = 100 })
assert(not err, "unexpected err: " .. tostring(err))
assert(#results == 5, "expected 5 results, got " .. #results)
for i, r in ipairs(results) do
    assert(r.row, "row " .. i .. " missing: " .. tostring(r.error))
    assert(r.action == "inserted", "row " .. i .. " action=" .. tostring(r.action))
    assert(r.row.title == "row " .. i, "RETURNING order mismatch at " .. i)
end
print("  OK (5/5 inserted, order preserved)")

-- 2. Multi-chunk ----------------------------------------------------------
header("multi-chunk: 12 rows with batch_size=5")
db.query("DELETE FROM lm_memories WHERE scope = 'smoke_wm'")
local big = {}
for i = 1, 12 do
    big[i] = { scope = "smoke_wm", kind = "fact",
        title = "B" .. i, body = "distinct body " .. i .. " " .. (i * 17) }
end
results, err = memory.write_many(big, { batch_size = 5 })
assert(not err)
assert(#results == 12)
for i, r in ipairs(results) do
    assert(r.row and r.action == "inserted", "row " .. i)
    assert(r.row.title == "B" .. i, "order mismatch B" .. i)
end
print("  OK (12/12 inserted across 3 chunks, order preserved)")

-- 3. Mixed validation error -----------------------------------------------
header("mixed: bad row in middle does not abort batch")
db.query("DELETE FROM lm_memories WHERE scope = 'smoke_wm'")
local mixed = {
    { scope = "smoke_wm", kind = "fact", title = "good 1", body = "alpha aaa" },
    { scope = "smoke_wm", kind = "fact", title = "",       body = "" },  -- bad
    { scope = "smoke_wm", kind = "fact", title = "good 2", body = "beta bbb" },
    "not a table",  -- bad
    { scope = "smoke_wm", kind = "fact", title = "good 3", body = "gamma ccc",
      importance = 99 },  -- bad: out of range
    { scope = "smoke_wm", kind = "fact", title = "good 4", body = "delta ddd" },
}
results, err = memory.write_many(mixed)
assert(not err)
assert(#results == 6, "expected 6 results, got " .. #results)
local ok_count, err_count = 0, 0
for i, r in ipairs(results) do
    if r.row then ok_count = ok_count + 1 else err_count = err_count + 1 end
    print(string.format("  [%d] action=%s error=%s",
        i, tostring(r.action), tostring(r.error)))
end
assert(ok_count == 3, "expected 3 ok, got " .. ok_count)
assert(err_count == 3, "expected 3 err, got " .. err_count)
print("  OK (3 inserted, 3 errored)")

-- 4. Optional dedup ("skip") ---------------------------------------------
header("dedup_strategy=skip catches near-duplicates without aborting")
db.query("DELETE FROM lm_memories WHERE scope = 'smoke_wm'")
-- Seed an existing row.
local seed = memory.write({ scope = "smoke_wm", kind = "fact",
    title = "Postgres backup strategy",
    body  = "Use pg_dump nightly and ship to S3 with retention." })
assert(seed)

local skip_batch = {
    -- exact dup of seed
    { scope = "smoke_wm", kind = "fact",
      title = "Postgres backup strategy",
      body  = "Use pg_dump nightly and ship to S3 with retention." },
    -- novel
    { scope = "smoke_wm", kind = "fact",
      title = "Cache invalidation",
      body  = "Flush profile_cache after profile mutations." },
}
results, err = memory.write_many(skip_batch, { dedup_strategy = "skip" })
assert(not err)
assert(#results == 2)
assert(results[1].action == "skipped", "expected skipped, got " .. tostring(results[1].action))
assert(results[2].action == "inserted", "expected inserted, got " .. tostring(results[2].action))
print("  OK (1 skipped, 1 inserted)")

print("\nALL write_many smokes passed.")
