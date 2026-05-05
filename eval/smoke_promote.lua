-- Phase 12.1 smoke: memory.promote() session-continuity helper.
--
-- Seeds 5 rows in `session:phase12`, then exercises the promote API
-- across 3 scenarios (no-delete, delete-source, dry-run). Asserts:
--   * summary written to to_scope with provenance metadata
--   * source rows preserved unless delete_source=true
--   * dry_run mutates nothing
--
-- Usage:
--   PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=lm_bruteforce_test \
--     lua5.1 eval/smoke_promote.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local db_shim = require("_smoke_lapis_db")
db_shim._connect({
    host     = os.getenv("PGHOST") or "127.0.0.1",
    port     = tonumber(os.getenv("PGPORT") or "5432"),
    database = os.getenv("PGDATABASE") or "lm_bruteforce_test",
    user     = os.getenv("PGUSER") or "postgres",
    password = os.getenv("PGPASSWORD") or "postgres",
})
package.loaded["lapis.db"] = db_shim

local memory = require("lapis_memory")
local db     = require("lapis.db")

memory.setup({
    db_table          = "lapis_memory",
    embedder_local    = "hash",
    embed_dim         = 384,
    backend           = "auto",
    default_scope     = "session:phase12",
    auth_fn           = function() return true end,
    summarizer_adapter = "noop",  -- deterministic concatenation summary
})

local FROM = "session:phase12"
local TO   = "user:phase12:lt"

-- --- arrange --------------------------------------------------------------
db.query("DELETE FROM lapis_memory WHERE scope IN ("
    .. db.escape_literal(FROM) .. ", " .. db.escape_literal(TO) .. ")")

local seed_bodies = {
    "user asked about deploy workflow",
    "explained main vs production branch model",
    "noted db_migration.sql is idempotent",
    "user wants ssh-key-based deploys",
    "wrapped up: deploy via merge to production",
}
for _, b in ipairs(seed_bodies) do
    local row = memory.write({
        scope = FROM,
        body  = b,
    })
    assert(row and row.id, "seed write failed: " .. tostring(b))
end

local seeded = db.query("SELECT count(*) AS n FROM lapis_memory WHERE scope = "
    .. db.escape_literal(FROM))[1]
assert(tonumber(seeded.n) == 5, "expected 5 seed rows, got " .. tostring(seeded.n))
print("seeded 5 rows in " .. FROM)

-- --- case 1: dry_run ------------------------------------------------------
local r1 = memory.promote({
    from_scope    = FROM,
    to_scope      = TO,
    dry_run       = true,
})
assert(r1.promoted == 1, "dry_run: expected promoted=1, got " .. tostring(r1.promoted))
assert(r1.dry_run == true, "dry_run flag missing")
assert(#r1.source_ids == 5, "dry_run source_ids mismatch")

local after_dry = db.query("SELECT count(*) AS n FROM lapis_memory WHERE scope = "
    .. db.escape_literal(TO))[1]
assert(tonumber(after_dry.n) == 0, "dry_run wrote rows to to_scope!")
print("PASS case 1: dry_run promoted=1, no DB mutation")

-- --- case 2: real promote, keep source -----------------------------------
local r2 = memory.promote({
    from_scope    = FROM,
    to_scope      = TO,
    delete_source = false,
})
assert(r2.promoted == 1, "case2: promoted=" .. tostring(r2.promoted))
assert(r2.summary_id, "case2: missing summary_id")
assert(r2.deleted_source == false, "case2: deleted_source should be false")

local sum = db.query("SELECT title, kind, metadata FROM lapis_memory WHERE id = "
    .. tostring(r2.summary_id))[1]
assert(sum.kind == "summary", "case2: expected kind=summary, got " .. tostring(sum.kind))
assert(sum.title:sub(1, 11) == "[promoted] ",
    "case2: title missing [promoted] prefix: " .. tostring(sum.title))

-- metadata round-trip: pgmoon may auto-decode JSONB to Lua table OR leave it as a string.
local meta = sum.metadata
if type(meta) == "string" then
    local cjson = require("cjson")
    meta = cjson.decode(meta)
end
assert(meta.promoted_from == FROM,
    "case2: metadata.promoted_from missing: " .. tostring(meta.promoted_from))
assert(type(meta.source_ids) == "table" and #meta.source_ids == 5,
    "case2: metadata.source_ids should be 5 ids")

local src_after = db.query("SELECT count(*) AS n FROM lapis_memory WHERE scope = "
    .. db.escape_literal(FROM) .. " AND kind != 'summary'")[1]
assert(tonumber(src_after.n) == 5,
    "case2: source rows should be preserved, got " .. tostring(src_after.n))
print("PASS case 2: real promote, summary written, source preserved")

-- --- case 3: real promote, delete source ---------------------------------
local r3 = memory.promote({
    from_scope    = FROM,
    to_scope      = TO,
    delete_source = true,
})
assert(r3.promoted == 1, "case3: promoted=" .. tostring(r3.promoted))
assert(r3.deleted_source == true, "case3: deleted_source should be true")

local src_gone = db.query("SELECT count(*) AS n FROM lapis_memory WHERE scope = "
    .. db.escape_literal(FROM))[1]
assert(tonumber(src_gone.n) == 0,
    "case3: source rows should be gone, got " .. tostring(src_gone.n))

local target_count = db.query("SELECT count(*) AS n FROM lapis_memory WHERE scope = "
    .. db.escape_literal(TO))[1]
assert(tonumber(target_count.n) == 2,
    "case3: target should have 2 summaries (case2 + case3), got " .. tostring(target_count.n))
print("PASS case 3: delete_source removed source, target has 2 summaries")

-- --- case 4: empty source returns no_rows ---------------------------------
local r4 = memory.promote({
    from_scope = FROM,  -- already empty after case 3
    to_scope   = TO,
})
assert(r4.promoted == 0, "case4: promoted should be 0 on empty source")
assert(r4.reason == "no_rows", "case4: reason should be no_rows, got " .. tostring(r4.reason))
print("PASS case 4: empty source -> reason=no_rows")

-- --- case 5: validation -------------------------------------------------
local r5 = memory.promote({ from_scope = FROM })
assert(r5.promoted == 0 and r5.errors and r5.errors[1]:find("to_scope"),
    "case5: missing to_scope should error")
print("PASS case 5: missing to_scope rejected")

local r6 = memory.promote({ from_scope = "x", to_scope = "x" })
assert(r6.promoted == 0 and r6.errors and r6.errors[1]:find("from_scope == to_scope"),
    "case6: same scope should error")
print("PASS case 6: from_scope == to_scope rejected")

-- --- cleanup --------------------------------------------------------------
db.query("DELETE FROM lapis_memory WHERE scope IN ("
    .. db.escape_literal(FROM) .. ", " .. db.escape_literal(TO) .. ")")

print("\nAll 6 promote smoke cases pass.")
