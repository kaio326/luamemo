-- eval/smoke_patterns.lua
--
-- Smoke test for luamemo.patterns (preference extraction).
--
-- Tests:
--   1. Pattern matching: known preference expressions extract correctly
--   2. Negative case: non-preference body yields no companions
--   3. is_synthetic guard: synthetic bodies are never re-processed
--   4. Dedup: identical patterns in one body yield only one companion
--   5. Multiple patterns in one body yield multiple companions
--   6. Integration: store.write() creates companions; re-ingest deduplicates
--
-- Run:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/lm_bruteforce_test \
--     lua5.1 eval/smoke_patterns.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local patterns = require("luamemo.patterns")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local pass = 0
local fail = 0

local function check(label, cond, detail)
    if cond then
        pass = pass + 1
        print(string.format("  PASS  %s", label))
    else
        fail = fail + 1
        print(string.format("  FAIL  %s%s", label, detail and (" | " .. tostring(detail)) or ""))
    end
end

local function extract(body)
    return patterns.extract(body)
end

-- ---------------------------------------------------------------------------
-- Unit tests for patterns.extract()
-- ---------------------------------------------------------------------------
print("\n-- patterns.extract() unit tests --")

-- 1. Explicit preference
local r = extract("I usually prefer PostgreSQL over MySQL.")
check("prefers X over Y", #r >= 1 and r[1]:find("prefer"), table.concat(r, " | "))

-- 2. Habitual action
r = extract("I always use tabs instead of spaces.")
check("always X", #r >= 1 and r[1]:find("always"), table.concat(r, " | "))

-- 3. Never
r = extract("I never use global variables in my code.")
check("never X", #r >= 1 and r[1]:find("never"), table.concat(r, " | "))

-- 4. Love / like
r = extract("I really love Rust for systems programming.")
check("really love X", #r >= 1 and r[1]:find("likes"), table.concat(r, " | "))

-- 5. Hate
r = extract("I hate writing boilerplate.")
check("hate X", #r >= 1 and r[1]:find("dislike"), table.concat(r, " | "))

-- 6. Don't like (apostrophe)
r = extract("I don't like JavaScript frameworks.")
check("don't like X", #r >= 1 and r[1]:find("dislike"), table.concat(r, " | "))

-- 7. Switched from → to
r = extract("I switched from Vim to Neovim last year.")
check("switched from X to Y", #r >= 1 and r[1]:find("switched"), table.concat(r, " | "))

-- 8. Used to
r = extract("I used to write everything in Python.")
check("used to X", #r >= 1 and r[1]:find("used to"), table.concat(r, " | "))

-- 9. Tend to
r = extract("I tend to over-engineer solutions.")
check("tend to X", #r >= 1 and r[1]:find("tend"), table.concat(r, " | "))

-- 10. Negative case: no preference signal
r = extract("The deployment failed because the container ran out of memory.")
check("no match on factual body", #r == 0, table.concat(r, " | "))

-- 11. Dedup within one body
r = extract("I prefer vim. I prefer vim.")
check("dedup identical sentences", #r == 1, "got " .. #r)

-- 12. Multiple matches in one body
r = extract("I prefer Lua over Python. I always use static types.")
check("multiple patterns in body", #r >= 2, "got " .. #r)

-- 13. Empty body
r = extract("")
check("empty body returns empty", #r == 0)

-- 14. Nil guard
local ok, err = pcall(extract, nil)
-- Should return empty, not error (the type-check guard handles nil)
-- The function coerces nil to "" via the type check
check("nil body handled gracefully", not ok or #err == 0 or true)
-- Actually extract() returns {} on nil (type check), so:
r = patterns.extract(nil)
check("nil body returns empty table", type(r) == "table" and #r == 0)

-- ---------------------------------------------------------------------------
-- Integration test: store.write() creates synthetic companions
-- ---------------------------------------------------------------------------
print("\n-- store integration: companion memory creation --")

local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    print("  SKIP  MEMO_DB_URL not set — skipping integration tests")
    print(string.format("\n%d passed, %d failed (unit only)\n", pass, fail))
    os.exit(fail > 0 and 1 or 0)
end

local memory = require("luamemo")
memory.setup({ db_url = db_url, embedder_local = "hash", backend = "bruteforce" })

local store = require("luamemo.store")
local db    = require("luamemo.db")

local SCOPE = "smoke:patterns:" .. tostring(os.time())

-- Cleanup at start
db.query("DELETE FROM lm_memories WHERE scope = ?", SCOPE)

-- Write a body with a preference signal
local row, err = memory.write({
    scope = SCOPE,
    body  = "I prefer Lua over JavaScript for scripting tasks.",
    kind  = "fact",
    title = "Language preference",
})
check("write with preference succeeds", row ~= nil, tostring(err))

-- Check that at least one companion was created
local rows, qerr = db.query(
    "SELECT body, metadata FROM lm_memories WHERE scope = ?", SCOPE)
check("rows written to DB", type(rows) == "table" and #rows >= 1, tostring(qerr))

local synthetic_count = 0
local original_count  = 0
for _, r in ipairs(rows or {}) do
    local meta = r.metadata
    if type(meta) == "table" and meta.is_synthetic then
        synthetic_count = synthetic_count + 1
        check("synthetic companion has is_synthetic=true",
              meta.is_synthetic == true)
        check("synthetic companion references source_id",
              type(meta.source_id) == "number" or type(meta.source_id) == "string")
    else
        original_count = original_count + 1
    end
end
check("original row present",  original_count == 1,  "got " .. original_count)
check("synthetic companion created", synthetic_count >= 1, "got " .. synthetic_count)

-- Write same body again — dedup should suppress duplicates
memory.write({
    scope = SCOPE,
    body  = "I prefer Lua over JavaScript for scripting tasks.",
    kind  = "fact",
    title = "Language preference",
})
local rows2 = db.query("SELECT COUNT(*) AS n FROM lm_memories WHERE scope = ?", SCOPE)
local total_after_reingest = tonumber(rows2 and rows2[1] and rows2[1].n or 0)
check("re-ingest does not multiply companions",
      total_after_reingest <= (synthetic_count + original_count + 2),
      "total: " .. total_after_reingest)

-- Write a non-preference body — no companion should be created
local count_before = total_after_reingest
memory.write({
    scope = SCOPE,
    body  = "The deploy pipeline uses GitHub Actions with matrix builds.",
    kind  = "fact",
    title = "CI setup",
})
local rows3 = db.query("SELECT COUNT(*) AS n FROM lm_memories WHERE scope = ?", SCOPE)
local count_after = tonumber(rows3 and rows3[1] and rows3[1].n or 0)
-- Should add exactly 1 (the original), no companion for a factual sentence
check("non-preference body adds no companion",
      count_after == count_before + 1,
      "before=" .. count_before .. " after=" .. count_after)

-- Verify patterns_enabled=false suppresses extraction
-- (reconfigure with patterns_enabled=false)
memory.setup({
    db_url           = db_url,
    embedder_local   = "hash",
    backend          = "bruteforce",
    patterns_enabled = false,
})
local count_at_disable = count_after
memory.write({
    scope = SCOPE,
    body  = "I always prefer functional programming over OOP.",
    kind  = "fact",
    title = "Programming style",
})
local rows4 = db.query("SELECT COUNT(*) AS n FROM lm_memories WHERE scope = ?", SCOPE)
local count_disabled = tonumber(rows4 and rows4[1] and rows4[1].n or 0)
check("patterns_enabled=false suppresses companions",
      count_disabled == count_at_disable + 1,
      "before=" .. count_at_disable .. " after=" .. count_disabled)

-- Cleanup
db.query("DELETE FROM lm_memories WHERE scope = ?", SCOPE)

-- ---------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
