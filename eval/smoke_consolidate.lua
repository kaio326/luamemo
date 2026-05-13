-- smoke_consolidate.lua — Verify Plan 9: Observation Consolidation.
--
-- Seeds a scope with related memories, runs consolidate.process(), then
-- asserts that:
--   * observations are created from clustered memories
--   * repeated similar memories reinforce (proof_count increments)
--   * processed memories have consolidated_at set
--   * consolidate.search() returns observations in search results
--   * store.search() surfaces observations via the new search leg
--
-- Usage:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/luamemo_dev \
--     lua5.1 eval/smoke_consolidate.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local memory      = require("luamemo")
local db          = require("luamemo.db")
local consolidate = require("luamemo.consolidate")

memory.setup({
    db_table          = "lm_memories",
    embedder_local    = "hash",
    embed_dim         = 384,
    backend           = "auto",
    default_scope     = "smoke:consolidate",
    auth_fn           = function() return true end,
    summarizer_adapter = "noop",   -- no LLM needed; uses highest-importance body
    consolidate_threshold          = 0.70,  -- lower than default so hash vecs cluster
    consolidate_reinforce_threshold = 0.50,
})

local SCOPE   = "smoke:consolidate"
local MEM_TBL = "lm_memories"
local OBS_TBL = "lm_observations"

-- Clean up from previous runs.
db.query("DELETE FROM " .. MEM_TBL .. " WHERE scope = " .. db.escape_literal(SCOPE))
db.query("DELETE FROM " .. OBS_TBL .. " WHERE scope = " .. db.escape_literal(SCOPE))

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
-- 1. Check observations table exists (migration applied)
-- ---------------------------------------------------------------------------
print("\n-- migration check --")
local tbl_check = db.query([[
    SELECT 1 FROM information_schema.tables
     WHERE table_name = 'lm_observations' LIMIT 1]])
check("lm_observations table exists",
    tbl_check and #tbl_check > 0, "migration 007 not applied")

local col_check = db.query([[
    SELECT 1 FROM information_schema.columns
     WHERE table_name = 'lm_memories'
       AND column_name = 'consolidated_at' LIMIT 1]])
check("lm_memories.consolidated_at column exists",
    col_check and #col_check > 0, "migration 007 not applied")

-- Abort early if migrations missing — rest of the test can't run.
if not (tbl_check and #tbl_check > 0 and col_check and #col_check > 0) then
    print("\nMigration 007 not applied — apply it before running this smoke test:")
    print("  psql -d luamemo_dev < luamemo/migrations/007_observations.sql")
    os.exit(1)
end

-- ---------------------------------------------------------------------------
-- 2. Seed memories and run consolidation
-- ---------------------------------------------------------------------------
print("\n-- consolidation --")

-- Three semantically-related memories (will cluster together under hash embedder)
-- and one unrelated memory.
local related_bodies = {
    "We decided to use PostgreSQL as the primary database",
    "The team chose PostgreSQL for all data persistence",
    "PostgreSQL was selected as the main database system",
}
local unrelated_body = "The frontend is built with React and TypeScript"

for _, body in ipairs(related_bodies) do
    local row, err = memory.write({ scope = SCOPE, body = body, importance = 1.5 })
    assert(row and row.id, "seed write failed: " .. tostring(err))
end
local unrelated_row, err = memory.write({ scope = SCOPE, body = unrelated_body })
assert(unrelated_row and unrelated_row.id, "seed write failed: " .. tostring(err))

local seeded_count = db.query(
    "SELECT COUNT(*) AS n FROM " .. MEM_TBL
    .. " WHERE scope = " .. db.escape_literal(SCOPE))[1]
check("4 memories seeded", tonumber(seeded_count.n) == 4,
    "got " .. tostring(seeded_count.n))

-- Run consolidation explicitly.
local result = consolidate.process(SCOPE)
check("consolidate.process() returned no fatal errors",
    type(result) == "table" and #(result.errors or {}) == 0,
    "errors: " .. table.concat(result.errors or {}, "; "))
check("at least 1 observation synthesised OR reinforced",
    (result.synthesised or 0) + (result.reinforced or 0) >= 1,
    "synthesised=" .. tostring(result.synthesised)
    .. " reinforced=" .. tostring(result.reinforced))

-- Check consolidated_at was stamped.
local unconsolidated = db.query([[
    SELECT COUNT(*) AS n FROM ]] .. MEM_TBL .. [[
     WHERE scope = ]] .. db.escape_literal(SCOPE) .. [[
       AND consolidated_at IS NULL]])[1]
check("all memories marked consolidated_at",
    tonumber(unconsolidated.n) == 0,
    tostring(unconsolidated.n) .. " rows still unconsolidated")

-- At least one observation row should exist.
local obs_count = db.query(
    "SELECT COUNT(*) AS n FROM " .. OBS_TBL
    .. " WHERE scope = " .. db.escape_literal(SCOPE))[1]
check("at least 1 observation row created",
    tonumber(obs_count.n) >= 1,
    "got " .. tostring(obs_count.n))

-- ---------------------------------------------------------------------------
-- 3. Reinforcement: write more similar memories and re-run
-- ---------------------------------------------------------------------------
print("\n-- reinforcement --")

local proof_before = db.query(
    "SELECT COALESCE(MAX(proof_count), 0) AS max_pc FROM " .. OBS_TBL
    .. " WHERE scope = " .. db.escape_literal(SCOPE))[1]
local max_before = tonumber(proof_before.max_pc) or 0

-- Add two more PostgreSQL-related memories (not yet consolidated).
memory.write({ scope = SCOPE, body = "PostgreSQL is our chosen persistence layer", importance = 1.0 })
memory.write({ scope = SCOPE, body = "DB decision: use PostgreSQL", importance = 1.0 })

local result2 = consolidate.process(SCOPE)
check("second consolidation.process() succeeds",
    type(result2) == "table" and #(result2.errors or {}) == 0,
    "errors: " .. table.concat(result2.errors or {}, "; "))

local proof_after = db.query(
    "SELECT COALESCE(MAX(proof_count), 0) AS max_pc FROM " .. OBS_TBL
    .. " WHERE scope = " .. db.escape_literal(SCOPE))[1]
local max_after = tonumber(proof_after.max_pc) or 0

check("proof_count increased after second consolidation",
    max_after > max_before,
    "before=" .. max_before .. " after=" .. max_after)

-- ---------------------------------------------------------------------------
-- 4. consolidate.search() returns observation rows
-- ---------------------------------------------------------------------------
print("\n-- consolidate.search() --")

local store = require("luamemo.store")
local qvec, everr = require("luamemo.embed").embed("PostgreSQL database choice")
assert(qvec, "embed failed: " .. tostring(everr))

local obs_results = consolidate.search(SCOPE, qvec, 10)
check("consolidate.search() returns at least 1 observation",
    #obs_results >= 1,
    "got " .. tostring(#obs_results))

if #obs_results >= 1 then
    check("observation row has type='observation'",
        obs_results[1].type == "observation",
        "got type=" .. tostring(obs_results[1].type))
    check("observation row has proof_count field",
        type(obs_results[1].proof_count) == "number",
        "got " .. tostring(obs_results[1].proof_count))
    check("observation row has freshness_trend field",
        type(obs_results[1].freshness_trend) == "string",
        "got " .. tostring(obs_results[1].freshness_trend))
    check("observation row has a positive score",
        (obs_results[1].score or 0) > 0,
        "got score=" .. tostring(obs_results[1].score))
end

-- ---------------------------------------------------------------------------
-- 5. store.search() surfaces observations in results
-- ---------------------------------------------------------------------------
print("\n-- store.search() with observation leg --")

local search_results, serr = memory.search({
    scope = SCOPE,
    query = "what database did we choose?",
    limit = 10,
})
assert(search_results, "store.search failed: " .. tostring(serr))
check("store.search() returns at least 1 result", #search_results >= 1,
    "got " .. tostring(#search_results))

-- At least one result should be an observation.
local found_obs = false
for _, r in ipairs(search_results) do
    if r.type == "observation" then found_obs = true; break end
end
check("store.search() includes at least 1 observation in results", found_obs,
    "no observation found in top " .. #search_results .. " results")

-- skip_observations=true should work without error (regression guard).
local skip_results, skerr = memory.search({
    scope              = SCOPE,
    query              = "PostgreSQL database",
    limit              = 10,
    skip_observations  = true,
})
assert(skip_results, "skip_observations search failed: " .. tostring(skerr))
local skip_obs = false
for _, r in ipairs(skip_results) do
    if r.type == "observation" then skip_obs = true; break end
end
check("skip_observations=true excludes observations from results", not skip_obs,
    "observation found despite skip_observations=true")

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
db.query("DELETE FROM " .. MEM_TBL .. " WHERE scope = " .. db.escape_literal(SCOPE))
db.query("DELETE FROM " .. OBS_TBL .. " WHERE scope = " .. db.escape_literal(SCOPE))
print("\n[cleanup] done")

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
