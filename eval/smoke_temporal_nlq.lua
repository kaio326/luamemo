-- smoke_temporal_nlq.lua — Verify natural-language temporal retrieval (Plan 8).
--
-- Seeds a scope with memories at known past dates using direct SQL UPDATEs
-- on created_at, then queries with natural-language time expressions and
-- asserts that the temporally-expected memories rank first.
--
-- Usage (plain Lua 5.1, no OpenResty required):
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/luamemo_dev \
--     lua5.1 eval/smoke_temporal_nlq.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local memory   = require("luamemo")
local db       = require("luamemo.db")
local temporal = require("luamemo.temporal")

memory.setup({
    db_table       = "lm_memories",
    embedder_local = "hash",
    embed_dim      = 384,
    backend        = "auto",
    default_scope  = "smoke:temporal_nlq",
    auth_fn        = function() return true end,
})

local SCOPE = "smoke:temporal_nlq"
local tbl   = "lm_memories"

-- Clean up from previous runs (including observations and reinforcements).
db.query("DELETE FROM " .. tbl .. " WHERE scope = " .. db.escape_literal(SCOPE))
db.query("DELETE FROM lm_observations WHERE scope = " .. db.escape_literal(SCOPE))
db.query("DELETE FROM lm_reinforcements WHERE scope = " .. db.escape_literal(SCOPE))

-- -------------------------------------------------------------------------
-- Seed memories at specific past dates.
-- ---------------------------------------------------------------------------
-- "last month" means the previous calendar month, so we compute the midpoint
-- of that month dynamically instead of hardcoding a fixed days_ago value
-- that drifts out of the window as the current date advances through the month.
-- ---------------------------------------------------------------------------
local now_epoch = os.time()
local day       = 86400

-- Compute epoch for the midpoint of the previous calendar month.
local d_now = os.date("*t", now_epoch)
local pm = d_now.month - 1
local py = d_now.year
if pm < 1 then pm = 12; py = py - 1 end
local pm_start  = os.time({ year = py, month = pm, day = 1,  hour = 0, min = 0, sec = 0 })
local next_m    = pm == 12 and 1 or pm + 1
local next_y    = pm == 12 and py + 1 or py
local pm_end    = os.time({ year = next_y, month = next_m, day = 1, hour = 0, min = 0, sec = 0 }) - 1
local pm_mid    = math.floor((pm_start + pm_end) / 2)
local jwt_days_ago = math.floor((now_epoch - pm_mid) / day)

local seeds = {
    { body = "team decided to use Postgres for the primary datastore", days_ago = 10          },
    { body = "migrated authentication to JWT tokens",                  days_ago = jwt_days_ago },
    { body = "refactored the billing module to use Stripe",            days_ago = 95           },
    { body = "onboarded three new backend engineers",                  days_ago = 200          },
    { body = "initial project kick-off meeting",                       days_ago = 400          },
}

local seeded_ids = {}
for _, s in ipairs(seeds) do
    local row, err = memory.write({ scope = SCOPE, body = s.body })
    assert(row and row.id, "seed write failed: " .. tostring(err))
    seeded_ids[#seeded_ids + 1] = { id = row.id, days_ago = s.days_ago, body = s.body }
end

-- Back-date each row's created_at to the intended date.
for _, item in ipairs(seeded_ids) do
    local ts = now_epoch - item.days_ago * day
    db.query(string.format(
        "UPDATE %s SET created_at = to_timestamp(%d), updated_at = to_timestamp(%d) WHERE id = %d",
        tbl, ts, ts, item.id))
end

print("[setup] seeded " .. #seeds .. " rows in scope '" .. SCOPE .. "'")

-- -------------------------------------------------------------------------
-- Helpers
-- -------------------------------------------------------------------------
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

local function search(query, extra)
    extra = extra or {}
    extra.scope = SCOPE
    extra.query = query
    extra.limit = extra.limit or 5
    -- Skip observations so this test isolates the temporal ranking leg.
    -- smoke_consolidate.lua tests the observation leg separately.
    if extra.skip_observations == nil then extra.skip_observations = true end
    local results, err = memory.search(extra)
    assert(results, "search failed for '" .. query .. "': " .. tostring(err))
    return results
end

local function top_body(query, extra)
    local r = search(query, extra)
    return r[1] and r[1].body or nil
end

local function bodies_in_top(query, n, extra)
    local r = search(query, extra)
    local out = {}
    for i = 1, math.min(n, #r) do out[#out + 1] = r[i].body end
    return out
end

local function any_contains(list, frag)
    for _, b in ipairs(list) do
        if b:find(frag, 1, true) then return true end
    end
    return false
end

-- -------------------------------------------------------------------------
-- Unit-level: temporal.parse()
-- -------------------------------------------------------------------------
print("\n-- temporal.parse() unit checks --")

local function check_parse(expr, expect_window)
    local w = temporal.parse(expr)
    if expect_window then
        check("parse('" .. expr .. "')",
            w ~= nil and w.since and w.until_ and w.center and w.half_secs > 0,
            w == nil and "got nil" or nil)
    else
        check("parse('" .. expr .. "') → nil",
            w == nil,
            w ~= nil and "got window" or nil)
    end
end

check_parse("what did we decide last month?",   true)
check_parse("show me updates from last week",   true)
check_parse("what happened recently",           true)
check_parse("events in 2024",                   true)
check_parse("decisions in June",                true)
check_parse("tasks from last year",             true)
check_parse("yesterday's stand-up notes",       true)
check_parse("today's work",                     true)
check_parse("last 30 days",                     true)
check_parse("what did we decide?",              false)   -- no temporal expr
check_parse("tell me about the billing module", false)   -- no temporal expr

-- Proximity boost: centre of window → boost above 1; edge → below 1.
local w = temporal.parse("recently")  -- window centred ~15d ago, half=15d
assert(w, "parse('recently') returned nil — cannot test boost")
local boost_centre = temporal.proximity_boost(w.center,     w, 0.2)
local boost_edge   = temporal.proximity_boost(w.center - w.half_secs, w, 0.2)
check("proximity_boost at centre > 1.0", boost_centre > 1.0,
    "got " .. tostring(boost_centre))
check("proximity_boost at edge  < 1.0", boost_edge   < 1.0,
    "got " .. tostring(boost_edge))

-- RRF merge: id=2 ranks first in both lists so it must win.
local list_a = { { id = 2, score = 0.95 }, { id = 1, score = 0.8 }, { id = 3, score = 0.1 } }
local list_b = { { id = 2, score = 0.90 }, { id = 3, score = 0.5 } }
local merged = temporal.rrf_merge({ list_a, list_b })
check("rrf_merge: id=2 ranks first (rank-1 in both lists)",
    merged[1] and tostring(merged[1].id) == "2",
    merged[1] and ("got id=" .. tostring(merged[1].id)) or "empty result")
check("rrf_merge: result contains all 3 unique ids", #merged == 3,
    "got " .. tostring(#merged))

-- -------------------------------------------------------------------------
-- Integration: queries with temporal expressions route to correct rows.
-- -------------------------------------------------------------------------
print("\n-- integration: temporal routing --")

-- "recently" (last ~30d) → Postgres row (10 days ago) should rank first.
local b_recent = top_body("what did we decide recently")
check("recently → most-recent row (Postgres)", b_recent and b_recent:find("Postgres", 1, true),
    "top body: " .. tostring(b_recent))

-- "last month" (~30–60 days ago) → JWT row (45 days ago).
local b_lm = top_body("what changed last month")
check("last month → JWT row", b_lm and b_lm:find("JWT", 1, true),
    "top body: " .. tostring(b_lm))

-- "last 3 months" → should include Stripe or JWT (both within ~90 days).
local tops_3m = bodies_in_top("what happened in the last 3 months", 3)
check("last 3 months → Stripe or JWT in top 3",
    any_contains(tops_3m, "Stripe") or any_contains(tops_3m, "JWT"),
    "top 3: " .. table.concat(tops_3m, " | "))

-- "last year" = calendar 2025; both the engineers (200d ago, ~Nov 2025)
-- and kick-off (400d ago, ~Apr 2025) rows are within that calendar year.
-- The centre of the window is ~mid-2025 (≈315d ago), so either row may
-- outrank the other. Assert only that both appear in the top-5 results.
local rows_ly = search("who joined last year")
local eng_found, kickoff_found = false, false
for _, r in ipairs(rows_ly) do
    if r.body:find("engineer", 1, true) then eng_found     = true end
    if r.body:find("kick-off",  1, true) then kickoff_found = true end
end
check("last year → engineers row appears in top 5", eng_found,
    "rows: " .. table.concat((function() local t={} for _,r in ipairs(rows_ly) do t[#t+1]=r.body:sub(1,30) end return t end)(), " | "))
check("last year → kick-off row appears in top 5", kickoff_found,
    "rows: " .. table.concat((function() local t={} for _,r in ipairs(rows_ly) do t[#t+1]=r.body:sub(1,30) end return t end)(), " | "))

-- skip_temporal=true → parsing disabled, search still works.
local b_skip = top_body("what happened recently", { skip_temporal = true })
check("skip_temporal=true → search still returns results", b_skip ~= nil,
    "got nil")

-- -------------------------------------------------------------------------
-- Cleanup
-- -------------------------------------------------------------------------
db.query("DELETE FROM " .. tbl .. " WHERE scope = " .. db.escape_literal(SCOPE))
print("\n[cleanup] done")

-- -------------------------------------------------------------------------
-- Summary
-- -------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
