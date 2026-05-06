-- Phase 8.3 smoke: decay + dedup + summarizer against bruteforce backend.
-- Run from luamemo/ dir after smoke_bruteforce.lua's setup recipe.
package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

-- luamemo.db creates a pgmoon connection automatically from
-- PGHOST / PGDATABASE / PGUSER / PGPASSWORD env vars when outside OpenResty.

local db     = require("luamemo.db")
local memory = require("luamemo")

memory.setup({
    db_table       = "lapis_memory",
    embedder_local = "hash",
    embed_dim      = 384,
    backend        = "auto",
    default_scope  = "h83",
    auth_fn        = function() return true end,
    summarizer_adapter        = "noop",
    summarizer_weight_threshold = 0.5,
    summarizer_retention_days   = 7,
    summarizer_batch_size       = 5,
    summarizer_max_batches      = 2,
})

local function header(s) print("\n=== " .. s .. " ===") end

db.query("TRUNCATE lapis_memory")

----------------------------------------------------------------------
-- 1. DECAY
----------------------------------------------------------------------
header("decay: high-decay row should sink after we backdate it")

local stable, e1 = memory.write({
    scope = "h83-decay", kind = "fact",
    title = "stable doctrine",
    body  = "The deploy procedure is documented in our runbook.",
    importance = 5.0, decay_rate = 0.0,   -- never decays
})
assert(stable, e1)

local rotting, e2 = memory.write({
    scope = "h83-decay", kind = "fact",
    title = "ephemeral note",
    body  = "The deploy procedure is documented in our runbook.",
    importance = 5.0, decay_rate = 0.5,   -- aggressive decay
    dedup_strategy = "append",            -- avoid the merge path
})
assert(rotting, e2)

-- Without backdating: identical bodies, identical importance, decay window
-- of 0 days -> scores tie. Search returns both with similar weight.
local pre = memory.search({ query = "deploy procedure runbook", scope = "h83-decay", limit = 5 })
print("  pre-backdate:")
for i, r in ipairs(pre) do
    print(string.format("    %d. id=%d weight=%.4f score=%.4f title=%q",
        i, r.id, r.weight, r.score, r.title))
end

-- Backdate the rotting row by 30 days. The touch trigger on UPDATE would
-- otherwise reset updated_at = now(), so disable it briefly.
db.query("ALTER TABLE lapis_memory DISABLE TRIGGER lapis_memory_touch_updated_at_trg")
db.query("UPDATE lapis_memory SET updated_at = now() - interval '30 days' WHERE id = " .. rotting.id)
db.query("ALTER TABLE lapis_memory ENABLE TRIGGER lapis_memory_touch_updated_at_trg")

local post = memory.search({ query = "deploy procedure runbook", scope = "h83-decay", limit = 5 })
print("  post-backdate (30 days):")
for i, r in ipairs(post) do
    print(string.format("    %d. id=%d weight=%.4f score=%.4f title=%q",
        i, r.id, r.weight, r.score, r.title))
end

-- The stable row should now outrank the rotting row.
local stable_pos, rotting_pos
for i, r in ipairs(post) do
    if r.id == stable.id  then stable_pos  = i end
    if r.id == rotting.id then rotting_pos = i end
end
assert(stable_pos and rotting_pos and stable_pos < rotting_pos,
    "decay: expected stable row to outrank rotting row after 30d backdate; got stable=" ..
    tostring(stable_pos) .. " rotting=" .. tostring(rotting_pos))
print("  decay OK")

-- Re-run with ignore_decay; ranking should differ (decay no longer applied).
local ignored = memory.search({
    query = "deploy procedure runbook", scope = "h83-decay",
    limit = 5, ignore_decay = true,
})
print("  ignore_decay=true:")
for i, r in ipairs(ignored) do
    print(string.format("    %d. id=%d weight=%.4f score=%.4f", i, r.id, r.weight, r.score))
end
for _, r in ipairs(ignored) do
    assert(r.weight == 1.0, "ignore_decay should yield weight=1.0; got " .. tostring(r.weight))
end
print("  ignore_decay OK")

----------------------------------------------------------------------
-- 2. DEDUP
----------------------------------------------------------------------
header("dedup: same body twice -> merged; explicit append -> two rows")

local d1, _, a1 = memory.write({
    scope = "h83-dedup", kind = "fact",
    title = "client onboarding script",
    body  = "Read the welcome packet then run the onboarding checklist.",
})
assert(d1 and a1 == "inserted", "first write should be inserted; got " .. tostring(a1))

local d2, _, a2 = memory.write({
    scope = "h83-dedup", kind = "fact",
    title = "client onboarding script",
    body  = "Read the welcome packet then run the onboarding checklist.",
})
assert(d2 and a2 == "merged", "second write should merge; got " .. tostring(a2))
assert(d2.id == d1.id, "merge should preserve original id")

local d3, _, a3 = memory.write({
    scope = "h83-dedup", kind = "fact",
    title = "client onboarding script",
    body  = "Read the welcome packet then run the onboarding checklist.",
    dedup_strategy = "append",
})
assert(d3 and a3 == "inserted" and d3.id ~= d1.id, "append should create new row")

local n = db.query("SELECT count(*) AS c FROM lapis_memory WHERE scope = 'h83-dedup'")
assert(tonumber(n[1].c) == 2, "expected 2 rows in h83-dedup; got " .. tostring(n[1].c))
print("  dedup OK (1 merged + 1 appended)")

----------------------------------------------------------------------
-- 3. SUMMARIZER
----------------------------------------------------------------------
header("summarizer: low-weight + old rows replaced by single summary")

-- Seed 4 low-importance, old rows.
for i = 1, 4 do
    local r, _, _ = memory.write({
        scope = "h83-sum", kind = "fact",
        title = "old note " .. i,
        body  = "Stale content number " .. i .. ", retained for compaction tests.",
        importance = 0.2,   -- below default threshold
        decay_rate = 0.5,
    })
    assert(r, "seed " .. i .. " failed")
end

-- Backdate them all so they're outside the retention window. Disable the
-- touch trigger so our manual updated_at sticks.
db.query("ALTER TABLE lapis_memory DISABLE TRIGGER lapis_memory_touch_updated_at_trg")
db.query("UPDATE lapis_memory SET updated_at = now() - interval '30 days' WHERE scope = 'h83-sum'")
db.query("ALTER TABLE lapis_memory ENABLE TRIGGER lapis_memory_touch_updated_at_trg")

local pre_count = db.query("SELECT count(*) AS c FROM lapis_memory WHERE scope = 'h83-sum'")
print("  rows before summarize: " .. pre_count[1].c)
assert(tonumber(pre_count[1].c) == 4)

-- Dry-run.
local dry = memory.summarizer.run({
    scope = "h83-sum",
    weight_threshold = 0.5,
    retention_days = 7,
    batch_size = 5,
    max_batches = 1,
    dry_run = true,
})
print(string.format("  dry-run: batches=%d summarised=%d replaced_ids=%d errors=%d",
    dry.batches, dry.summarised, #dry.replaced_ids, #dry.errors))
assert(dry.batches == 1, "expected 1 dry-run batch")
assert(dry.summarised == 1, "expected 1 dry-run summary")
assert(#dry.replaced_ids == 4, "expected 4 ids slated for replacement")

-- Confirm dry-run did not mutate.
local mid_count = db.query("SELECT count(*) AS c FROM lapis_memory WHERE scope = 'h83-sum'")
assert(tonumber(mid_count[1].c) == 4, "dry-run should not mutate; got " .. tostring(mid_count[1].c))

-- Real run.
local real = memory.summarizer.run({
    scope = "h83-sum",
    weight_threshold = 0.5,
    retention_days = 7,
    batch_size = 5,
    max_batches = 1,
})
print(string.format("  real:    batches=%d summarised=%d replaced_ids=%d new_ids=%d errors=%d",
    real.batches, real.summarised, #real.replaced_ids, #real.new_ids, #real.errors))
for _, e in ipairs(real.errors) do print("    error: " .. tostring(e)) end
assert(real.summarised == 1, "expected 1 real summary")
assert(#real.new_ids == 1, "expected 1 new summary row id")
assert(#real.errors == 0, "expected no errors")

-- Verify single 'summary' row remains; original 4 rows are gone.
local rows = db.query("SELECT id, kind, title, metadata FROM lapis_memory WHERE scope = 'h83-sum' ORDER BY id")
print("  rows after summarize:")
for _, r in ipairs(rows) do
    print(string.format("    id=%d kind=%s title=%q", r.id, r.kind, r.title))
end
assert(#rows == 1, "expected 1 row after summarisation; got " .. #rows)
assert(rows[1].kind == "summary", "expected kind='summary'; got " .. rows[1].kind)

local raw_meta = rows[1].metadata
print("  raw metadata type=" .. type(raw_meta) .. " value=" .. tostring(raw_meta))
local meta
if type(raw_meta) == "table" then
    meta = raw_meta
else
    meta = require("cjson.safe").decode(raw_meta or "{}") or {}
end
assert(meta.summarized_ids and #meta.summarized_ids == 4,
    "summary metadata should record the 4 replaced ids")
print("  summarizer OK (4 rows -> 1 summary, source_ids tracked)")

header("PHASE 8.3 ALL PASS")
