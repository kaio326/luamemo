-- smoke_tiers.lua — Verify Plan 10: Memory Tiers
--
-- Checks:
--   1. Migration applied: tier column exists on lm_memories
--   2. write() derives tier from importance automatically
--   3. write() respects explicit tier override
--   4. write_many() derives tier per-row
--   5. tier is present in returned rows
--   6. search() with tier_min filters out lower tiers
--   7. search() with tier_max filters out higher tiers
--   8. search() without tier params returns all tiers
--
-- Usage:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/luamemo_dev \
--     lua5.1 eval/smoke_tiers.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local memory = require("luamemo")
local db     = require("luamemo.db")

memory.setup({
    db_table          = "lm_memories",
    embedder_local    = "hash",
    embed_dim         = 384,
    backend           = "auto",
    default_scope     = "smoke:tiers",
    auth_fn           = function() return true end,
    summarizer_adapter = "noop",
    skip_observations = true,   -- disable consolidation noise
})

local SCOPE   = "smoke:tiers"
local MEM_TBL = "lm_memories"

-- Clean up from previous runs.
db.query("DELETE FROM " .. MEM_TBL .. " WHERE scope = " .. db.escape_literal(SCOPE))

local pass = 0
local fail = 0

local function check(label, condition, detail)
    if condition then
        print("[PASS] " .. label)
        pass = pass + 1
    else
        print("[FAIL] " .. label .. (detail and (" — " .. detail) or ""))
        fail = fail + 1
    end
end

-- ---------------------------------------------------------------------------
-- 1. Migration check
-- ---------------------------------------------------------------------------
print("\n-- migration check --")
local col_check = db.query([[
    SELECT 1 FROM information_schema.columns
     WHERE table_name = 'lm_memories'
       AND column_name = 'tier' LIMIT 1]])
check("lm_memories.tier column exists",
    col_check and #col_check > 0, "migration 008 not applied")

if not (col_check and #col_check > 0) then
    print("\nMigration 008 not applied — apply it first:")
    print("  psql -d luamemo_dev < luamemo/migrations/008_tiers.sql")
    os.exit(1)
end

-- ---------------------------------------------------------------------------
-- 2. Tier derivation from importance
-- ---------------------------------------------------------------------------
print("\n-- auto tier derivation --")

-- importance < 0.3  → tier 0
local r0, e0 = memory.write({ scope = SCOPE, body = "ephemeral event A", importance = 0.2 })
assert(r0 and r0.id, "write failed: " .. tostring(e0))
check("importance=0.2 → tier=0", tonumber(r0.tier) == 0,
    "got tier=" .. tostring(r0.tier))

-- importance in [0.3, 0.6) → tier 1
local r1, e1 = memory.write({ scope = SCOPE, body = "working memory B", importance = 0.5 })
assert(r1 and r1.id, "write failed: " .. tostring(e1))
check("importance=0.5 → tier=1", tonumber(r1.tier) == 1,
    "got tier=" .. tostring(r1.tier))

-- importance in [0.6, 0.85) → tier 2
local r2, e2 = memory.write({ scope = SCOPE, body = "consolidated fact C", importance = 0.7 })
assert(r2 and r2.id, "write failed: " .. tostring(e2))
check("importance=0.7 → tier=2", tonumber(r2.tier) == 2,
    "got tier=" .. tostring(r2.tier))

-- importance >= 0.85 → tier 3
local r3, e3 = memory.write({ scope = SCOPE, body = "core decision D", importance = 1.5 })
assert(r3 and r3.id, "write failed: " .. tostring(e3))
check("importance=1.5 → tier=3", tonumber(r3.tier) == 3,
    "got tier=" .. tostring(r3.tier))

-- ---------------------------------------------------------------------------
-- 3. Explicit tier override
-- ---------------------------------------------------------------------------
print("\n-- explicit tier override --")
local ro, eo = memory.write({
    scope      = SCOPE,
    body       = "manually set to tier 2",
    importance = 0.2,   -- would normally → tier 0
    tier       = 2,
})
assert(ro and ro.id, "write failed: " .. tostring(eo))
check("explicit tier=2 overrides importance-derived tier=0",
    tonumber(ro.tier) == 2, "got tier=" .. tostring(ro.tier))

-- ---------------------------------------------------------------------------
-- 4. write_many() tier derivation
-- ---------------------------------------------------------------------------
print("\n-- write_many tier derivation --")
local results = memory.write_many({
    { scope = SCOPE, body = "batch ephemeral",    importance = 0.1 },
    { scope = SCOPE, body = "batch working",      importance = 0.4 },
    { scope = SCOPE, body = "batch core",         importance = 2.0 },
}, { dedup_strategy = "append" })
check("write_many: 3 results returned", #results == 3,
    "got " .. tostring(#results))
check("write_many: batch_ephemeral tier=0",
    results[1].row and tonumber(results[1].row.tier) == 0,
    "got tier=" .. tostring(results[1].row and results[1].row.tier))
check("write_many: batch_working tier=1",
    results[2].row and tonumber(results[2].row.tier) == 1,
    "got tier=" .. tostring(results[2].row and results[2].row.tier))
check("write_many: batch_core tier=3",
    results[3].row and tonumber(results[3].row.tier) == 3,
    "got tier=" .. tostring(results[3].row and results[3].row.tier))

-- ---------------------------------------------------------------------------
-- 5. Search: tier_min filtering
-- ---------------------------------------------------------------------------
print("\n-- search tier_min filtering --")

-- All 8 rows exist; without filter all should appear.
local all_rows = memory.search({
    query      = "memory",
    scope      = SCOPE,
    limit      = 20,
    skip_observations = true,
})
check("search without tier_min returns rows",
    all_rows and #all_rows >= 1,
    "got " .. tostring(all_rows and #all_rows or "nil"))

-- With tier_min=1: tier-0 rows should be excluded.
local tier1_rows = memory.search({
    query      = "memory",
    scope      = SCOPE,
    limit      = 20,
    tier_min   = 1,
    skip_observations = true,
})
local has_tier0 = false
if tier1_rows then
    for _, r in ipairs(tier1_rows) do
        if tonumber(r.tier) == 0 then has_tier0 = true end
    end
end
check("tier_min=1 excludes tier=0 rows", not has_tier0,
    "a tier=0 row appeared in results")

-- With tier_min=3: only tier-3 rows appear.
local tier3_rows = memory.search({
    query      = "memory",
    scope      = SCOPE,
    limit      = 20,
    tier_min   = 3,
    skip_observations = true,
})
local all_tier3 = tier3_rows and #tier3_rows >= 1
if tier3_rows then
    for _, r in ipairs(tier3_rows) do
        if tonumber(r.tier) ~= 3 then all_tier3 = false end
    end
end
check("tier_min=3 returns only tier=3 rows", all_tier3,
    "non-tier-3 row appeared, or no rows returned")

-- ---------------------------------------------------------------------------
-- 6. Search: tier_max filtering
-- ---------------------------------------------------------------------------
print("\n-- search tier_max filtering --")

local tier0only = memory.search({
    query      = "memory",
    scope      = SCOPE,
    limit      = 20,
    tier_max   = 0,
    skip_observations = true,
})
local has_above0 = false
if tier0only then
    for _, r in ipairs(tier0only) do
        if tonumber(r.tier) ~= 0 then has_above0 = true end
    end
end
check("tier_max=0 returns only tier=0 rows",
    tier0only and #tier0only >= 1 and not has_above0,
    "unexpected rows: " .. tostring(tier0only and #tier0only))

-- ---------------------------------------------------------------------------
-- 7. Tier present in returned row fields
-- ---------------------------------------------------------------------------
print("\n-- tier field in returned rows --")
check("tier field present in write() row", r3.tier ~= nil, "tier is nil")
check("tier field is a number", type(tonumber(r3.tier)) == "number", "not a number")

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
db.query("DELETE FROM " .. MEM_TBL .. " WHERE scope = " .. db.escape_literal(SCOPE))
print("\n[cleanup] done")
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
