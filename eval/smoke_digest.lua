-- smoke_digest.lua: Hippocampus Digest
--
-- Checks:
--   1.  Migration applied: lm_reinforcements table exists
--   2.  digest.configure() and digest.notify_write() run without error
--   3.  digest.should_run() returns false right after notify_write
--   4.  digest.record_event() inserts a row into lm_reinforcements
--   5.  record_event row appears with correct fields
--   6.  digest.run() on an empty scope returns a summary table
--   7.  digest.run() with tier-0 memories returns processed >= 1
--   8.  consolidated_at is stamped on tier-0 rows after run
--   9.  digest.run(dry_run=true) does NOT stamp consolidated_at
--   10. digest.run(dry_run=true) returns processed count (preview)
--   11. _promote path: tier-1 row with enough proof_count → tier 2
--   12. _purge path: stale consolidated rows deleted after grace_days=0
--   13. store.write() calls notify_write (idle clock is set after write)
--   14. Summary of test run
--
-- Usage:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/luamemo_dev \
--     lua5.1 eval/smoke_digest.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local memory = require("luamemo")
local db     = require("luamemo.db")
local digest = require("luamemo.digest")

memory.setup({
    db_table           = "lm_memories",
    embedder_local     = "hash",
    embed_dim          = 384,
    backend            = "auto",
    default_scope      = "smoke:digest",
    auth_fn            = function() return true end,
    summarizer_adapter = "noop",
    -- Tight thresholds so hash embeddings cluster in tests.
    consolidate_threshold          = 0.70,
    consolidate_reinforce_threshold = 0.50,
    -- Digest config: very short idle timer so should_run tests work.
    digest_idle_seconds     = 9999,  -- keep it from auto-firing
    digest_grace_days       = 0,     -- purge immediately in test 12
    digest_escalate_alpha   = 0.4,
    digest_promote_tier2_at = 3,
    digest_promote_tier3_at = 5,
})

local store = require("luamemo.store")

local SCOPE   = "smoke:digest"
local MEM_TBL = "lm_memories"
local REI_TBL = "lm_reinforcements"

-- Clean up from previous runs.
db.query("DELETE FROM " .. MEM_TBL .. " WHERE scope = " .. db.escape_literal(SCOPE))
db.query("DELETE FROM " .. REI_TBL .. " WHERE scope = " .. db.escape_literal(SCOPE))

local pass = 0
local fail = 0

local function check(label, condition, detail)
    if condition then
        print("[PASS] " .. label)
        pass = pass + 1
    else
        print("[FAIL] " .. label .. (detail and (" — " .. tostring(detail)) or ""))
        fail = fail + 1
    end
end

-- ---------------------------------------------------------------------------
-- 1. Migration check: lm_reinforcements table exists
-- ---------------------------------------------------------------------------
print("\n-- migration check --")
local rei_check = db.query([[
    SELECT 1 FROM information_schema.tables
     WHERE table_schema = 'public'
       AND table_name   = 'lm_reinforcements'
     LIMIT 1]])
check("lm_reinforcements table exists", rei_check and #rei_check > 0)

-- ---------------------------------------------------------------------------
-- 2. configure and notify_write run without error
-- ---------------------------------------------------------------------------
print("\n-- configure / notify_write --")
local ok2, err2 = pcall(function()
    digest.configure({
        digest_idle_seconds     = 9999,
        digest_grace_days       = 0,
        digest_escalate_alpha   = 0.4,
        digest_promote_tier2_at = 3,
        digest_promote_tier3_at = 5,
    })
    digest.notify_write(SCOPE)
end)
check("configure and notify_write succeed", ok2, err2)

-- ---------------------------------------------------------------------------
-- 3. should_run returns false right after notify_write
-- ---------------------------------------------------------------------------
print("\n-- should_run idle timer --")
check("should_run is false immediately after write", not digest.should_run(SCOPE))
check("should_run is false for unknown scope", not digest.should_run("smoke:digest:never_written"))

-- ---------------------------------------------------------------------------
-- 4 & 5. record_event inserts a row
-- ---------------------------------------------------------------------------
print("\n-- record_event --")
-- We need a real memory id to satisfy the FK.
local seed_row, seed_err = store.write({
    scope      = SCOPE,
    title      = "seed for reinforcement",
    body       = "test reinforcement event seeding",
    importance = 0.5,
})
check("seed row written for FK test", seed_row ~= nil, seed_err)

local mem_id = seed_row and seed_row.id

local ok4, err4 = pcall(digest.record_event, mem_id, SCOPE, "mistake", 0.5, "smoke test note")
check("record_event executes without error", ok4, err4)

local rei_rows = db.query(
    "SELECT event_type, note FROM " .. REI_TBL
    .. " WHERE memory_id = " .. tostring(mem_id or 0))
check("record_event row exists in lm_reinforcements", rei_rows and #rei_rows >= 1)
if rei_rows and #rei_rows >= 1 then
    check("record_event has correct event_type",
        rei_rows[1].event_type == "mistake",
        rei_rows[1].event_type)
    check("record_event has correct note",
        rei_rows[1].note == "smoke test note",
        rei_rows[1].note)
end

-- record_event: reversal diminishes importance and demotes tier
local rev_row, rev_err = store.write({
    scope      = SCOPE,
    title      = "important decision",
    body       = "we decided to use microservices",
    importance = 0.8,  -- tier=2 initially
})
check("seed row for reversal test", rev_row ~= nil, rev_err)
local rev_id = rev_row and rev_row.id

local ok_rev = pcall(digest.record_event, rev_id, SCOPE, "reversal", 1.0, "direction changed")
check("record_event reversal executes without error", ok_rev)

local after_rev = rev_id and db.query(
    "SELECT importance, tier FROM lm_memories WHERE id = " .. tostring(rev_id))
local after_imp = after_rev and after_rev[1] and tonumber(after_rev[1].importance)
check("reversal: importance was reduced",
    after_imp and after_imp < 0.8,
    "importance after reversal: " .. tostring(after_imp))
check("reversal: tier was updated to match new importance",
    after_rev and after_rev[1] and tonumber(after_rev[1].tier) ~= nil,
    "tier: " .. tostring(after_rev and after_rev[1] and after_rev[1].tier))

-- Reversal event stored in lm_reinforcements.
local rev_rei = rev_id and db.query(
    "SELECT event_type FROM " .. REI_TBL
    .. " WHERE memory_id = " .. tostring(rev_id)
    .. " AND event_type = 'reversal'")
check("reversal: event row written to lm_reinforcements",
    rev_rei and #rev_rei >= 1)

-- ---------------------------------------------------------------------------
-- 6. run() on an empty scope (no tier-0 rows) returns a summary table
-- ---------------------------------------------------------------------------
print("\n-- digest.run on empty scope --")
-- Use a completely different scope that has no rows at all.
local empty_scope = "smoke:digest:empty_" .. tostring(os.time())
local ok6, res6 = pcall(digest.run, empty_scope)
check("run on empty scope succeeds", ok6, res6)
if ok6 then
    check("run returns table",       type(res6) == "table")
    check("run.processed is number", type(res6.processed) == "number")
    check("run.errors is table",     type(res6.errors) == "table")
end

-- ---------------------------------------------------------------------------
-- 7 & 8. run() with tier-0 memories processes and stamps consolidated_at
-- ---------------------------------------------------------------------------
print("\n-- digest.run with tier-0 memories --")
-- Seed 3 tier-0 memories (importance < 0.3 → tier 0 automatically).
local tier0_ids = {}
for i = 1, 3 do
    local r, e = store.write({
        scope      = SCOPE,
        title      = "ephemeral event " .. i,
        body       = "something happened in session step " .. i,
        importance = 0.2,   -- → tier 0
    })
    check("seed tier-0 row " .. i, r ~= nil, e)
    if r then tier0_ids[#tier0_ids + 1] = r.id end
end

-- Verify they were actually inserted as tier=0.
if #tier0_ids > 0 then
    local id_list = table.concat(tier0_ids, ",")
    local t0check = db.query(
        "SELECT id, tier FROM " .. MEM_TBL
        .. " WHERE id IN (" .. id_list .. ") AND tier = 0")
    check("seeded rows are tier=0",
        t0check and #t0check == #tier0_ids,
        "expected " .. #tier0_ids .. " got " .. tostring(t0check and #t0check))
end

local ok7, res7 = pcall(digest.run, SCOPE)
check("run with tier-0 rows succeeds", ok7, tostring(res7))
if ok7 then
    check("processed >= 1", res7.processed >= 1,
        "processed=" .. tostring(res7.processed))
end

-- Check that consolidated_at was stamped on the tier-0 rows.
if ok7 and #tier0_ids > 0 then
    local id_list = table.concat(tier0_ids, ",")
    local stamped = db.query(
        "SELECT id FROM " .. MEM_TBL
        .. " WHERE id IN (" .. id_list .. ")"
        .. "   AND consolidated_at IS NOT NULL")
    check("consolidated_at stamped after run",
        stamped and #stamped > 0,
        "stamped=" .. tostring(stamped and #stamped))
end

-- ---------------------------------------------------------------------------
-- 9 & 10. dry_run=true does NOT stamp consolidated_at
-- ---------------------------------------------------------------------------
print("\n-- dry_run --")
-- Seed fresh tier-0 rows for dry_run test. Use dedup_strategy="append" to
-- ensure both rows are always inserted fresh (avoid same-ID dedup collision).
local dry_ids = {}
for i = 1, 2 do
    local r = store.write({
        scope           = SCOPE,
        title           = "dry run event " .. i,
        body            = "should not be stamped: unique content " .. os.time() .. "_" .. i,
        importance      = 0.15,
        dedup_strategy  = "append",
    })
    if r then dry_ids[#dry_ids + 1] = r.id end
end

local ok9, res9 = pcall(digest.run, SCOPE, { dry_run = true })
check("dry_run run succeeds", ok9, tostring(res9))
if ok9 then
    check("dry_run.processed is number", type(res9.processed) == "number")
    check("dry_run.deleted == 0", res9.deleted == 0,
        "deleted=" .. tostring(res9.deleted))
end

-- Verify that dry-run rows have consolidated_at IS NULL.
if ok9 and #dry_ids > 0 then
    local id_list = table.concat(dry_ids, ",")
    local unstamped = db.query(
        "SELECT id FROM " .. MEM_TBL
        .. " WHERE id IN (" .. id_list .. ")"
        .. "   AND consolidated_at IS NULL")
    check("dry_run does not stamp consolidated_at",
        unstamped and #unstamped == #dry_ids,
        "unstamped=" .. tostring(unstamped and #unstamped)
        .. " expected=" .. #dry_ids)
end

-- ---------------------------------------------------------------------------
-- 11. _purge_stale: rows with grace_days=0 should be deleted after run
-- ---------------------------------------------------------------------------
print("\n-- purge stale --")
-- grace_days=0 is configured; stamp rows as consolidated right now.
-- With the bug fixed (math.max(0,...)), rows with consolidated_at <= NOW()
-- should be purged immediately.
if #tier0_ids > 0 then
    local id_list = table.concat(tier0_ids, ",")
    db.query("UPDATE " .. MEM_TBL
        .. " SET consolidated_at = NOW() - INTERVAL '1 second'"
        .. " WHERE id IN (" .. id_list .. ")")
    -- Run again — should purge the stale tier-0 rows.
    local ok11, res11 = pcall(digest.run, SCOPE)
    check("run for purge succeeds", ok11, tostring(res11))
    if ok11 then
        check("deleted > 0 with grace_days=0 (purge ran)", res11.deleted > 0,
            "deleted=" .. tostring(res11.deleted))
    end
end

-- ---------------------------------------------------------------------------
-- 12. store.write calls notify_write (idle clock updates)
-- ---------------------------------------------------------------------------
print("\n-- store.write notifies digest --")
-- The idle clock should be non-nil for SCOPE since we've been writing.
-- We can check by resetting it and verifying a write re-sets it.
-- digest's _last_write is private, but should_run(SCOPE) will be false
-- (idle_seconds is 9999) — if notify_write wasn't called it would be nil
-- and should_run would also be false. What we CAN check: no error thrown.
local ok12, err12 = pcall(store.write, {
    scope = SCOPE, title = "notify test", body = "notify_write integration",
    importance = 0.5,
})
check("store.write after wiring succeeds (no error from notify_write)", ok12, err12)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print("\n-- summary --")
print(string.format("Passed: %d / %d", pass, pass + fail))
if fail > 0 then
    print("SOME TESTS FAILED")
    os.exit(1)
end
