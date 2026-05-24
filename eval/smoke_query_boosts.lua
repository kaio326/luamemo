-- eval/smoke_query_boosts.lua
--
-- Smoke test for Plan 14: query-time person-name and quoted-phrase boosts.
--
-- Tests:
--   1. Helper extraction: _extract_names and _extract_quoted return correct tokens
--      (tested indirectly via search behaviour)
--   2. Person-name boost: a row mentioning a specific person's name ranks higher
--      when that name appears in the query
--   3. Quoted-phrase boost: a row containing an exact quoted phrase ranks higher
--      when that phrase is quoted in the query
--   4. No boost when disabled: person_name_boost_enabled=false suppresses reranking
--   5. No boost on empty query features (no names / no quotes)
--
-- Run:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/lm_bruteforce_test \
--     lua5.1 eval/smoke_query_boosts.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local pass = 0
local fail = 0

local function check(label, cond, detail)
    if cond then
        pass = pass + 1
        io.write(string.format("  PASS  %s\n", label))
    else
        fail = fail + 1
        io.write(string.format("  FAIL  %s%s\n", label, detail and (" | " .. tostring(detail)) or ""))
    end
end

-- ---------------------------------------------------------------------------
-- Integration tests
-- ---------------------------------------------------------------------------
local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    print("MEMO_DB_URL not set — aborting")
    os.exit(1)
end

local memory = require("luamemo")
memory.setup({
    db_url          = db_url,
    embedder_local  = "hash",
    backend         = "bruteforce",
    patterns_enabled = false,   -- disable companion writes to keep corpus clean
})

local store = require("luamemo.store")
local db    = require("luamemo.db")

local SCOPE = "smoke:qboost:" .. tostring(os.time())

-- Cleanup at start
db.query("DELETE FROM lm_memories WHERE scope = ?", SCOPE)

-- Seed three rows: one mentioning "Rachel", one generic, one with exact phrase.
local function seed(body, title)
    local row, err = store.write({
        scope      = SCOPE,
        kind       = "fact",
        title      = title or body:sub(1, 40),
        body       = body,
        importance = 0.5,
    })
    assert(row and row.id, "seed failed: " .. tostring(err) .. " | body=" .. body)
    return row
end

print("\n-- Setup: seeding memories --")
seed("Rachel plays the ukulele every Sunday morning.", "Rachel ukulele")
seed("The project uses a monorepo structure with Turborepo.", "monorepo")
seed("The user mentioned 'sexual compulsions' during a therapy session.", "therapy quote")
seed("Weekly team standup happens on Monday at 10am.", "standup")
seed("The codebase is written entirely in Lua 5.1.", "lua codebase")
print("  seeded 5 rows")

-- Give embedder a moment to settle (not needed for hash, but be safe).

-- ---------------------------------------------------------------------------
-- Test 1: person-name boost surfaces Rachel row to top-3 for Rachel query
-- ---------------------------------------------------------------------------
print("\n-- Test 1: person-name boost --")
local results = store.search({
    scope             = SCOPE,
    query             = "What does Rachel do on weekends?",
    limit             = 5,
    tier_min          = 0,
    skip_observations = true,
})
check("results returned", type(results) == "table" and #results > 0)

local rachel_rank = nil
for i, r in ipairs(results) do
    if r.body and r.body:find("Rachel") then
        rachel_rank = i
        break
    end
end
check("Rachel row is in top-3", rachel_rank ~= nil and rachel_rank <= 3,
      "rank=" .. tostring(rachel_rank) .. " / " .. #results .. " results")

-- ---------------------------------------------------------------------------
-- Test 2: quoted-phrase boost surfaces therapy row for exact-phrase query
-- ---------------------------------------------------------------------------
print("\n-- Test 2: quoted-phrase boost --")
results = store.search({
    scope             = SCOPE,
    query             = "What did the user say about 'sexual compulsions'?",
    limit             = 5,
    tier_min          = 0,
    skip_observations = true,
})
check("results returned for quoted query", type(results) == "table" and #results > 0)

local therapy_rank = nil
for i, r in ipairs(results) do
    if r.body and r.body:find("therapy") then
        therapy_rank = i
        break
    end
end
check("therapy row is in top-3 for quoted query", therapy_rank ~= nil and therapy_rank <= 3,
      "rank=" .. tostring(therapy_rank) .. " / " .. #results .. " results")

-- ---------------------------------------------------------------------------
-- Test 3: boost disabled does NOT crash, results still returned
-- ---------------------------------------------------------------------------
print("\n-- Test 3: boosts disabled gracefully --")
memory.setup({
    db_url                      = db_url,
    embedder_local              = "hash",
    backend                     = "bruteforce",
    patterns_enabled            = false,
    person_name_boost_enabled   = false,
    quoted_phrase_boost_enabled = false,
})
results = store.search({
    scope             = SCOPE,
    query             = "What does Rachel like?",
    limit             = 5,
    tier_min          = 0,
    skip_observations = true,
})
check("results returned with boosts disabled", type(results) == "table" and #results > 0,
      "got " .. tostring(results))

-- ---------------------------------------------------------------------------
-- Test 4: query with no names/quotes returns results without crash
-- ---------------------------------------------------------------------------
print("\n-- Test 4: query with no boostable tokens --")
memory.setup({
    db_url           = db_url,
    embedder_local   = "hash",
    backend          = "bruteforce",
    patterns_enabled = false,
})
results = store.search({
    scope             = SCOPE,
    query             = "what happens every week at the team?",
    limit             = 5,
    tier_min          = 0,
    skip_observations = true,
})
check("results returned for plain query", type(results) == "table" and #results > 0)

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
db.query("DELETE FROM lm_memories WHERE scope = ?", SCOPE)

print(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
