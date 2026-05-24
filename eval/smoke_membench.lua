-- eval/smoke_membench.lua
--
-- Fixture-based smoke test for the MemBench evaluation harness.
--
-- Uses eval/data/fixtures/membench_tiny.json (3 questions, 2 categories)
-- to verify:
--   1. Dataset loader reads and iterates correctly
--   2. iter_sessions() renders turns to flat text
--   3. categories() extracts all distinct categories
--   4. Full mini-run: ingest + search + score produces expected per-category buckets
--   5. JSON output file is written and parseable
--
-- Run:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/lm_bruteforce_test \
--     lua5.1 eval/smoke_membench.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;eval/datasets/?.lua;" .. package.path
package.preload["resty.http"] = function() return require("_resty_http_shim") end

local cjson = require("cjson.safe")

local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    print("MEMO_DB_URL not set — aborting")
    os.exit(1)
end

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
-- Unit tests: dataset loader
-- ---------------------------------------------------------------------------
print("\n-- membench dataset loader --")

local membench = require("membench")
local FIXTURE  = "eval/data/fixtures/membench_tiny.json"

-- Load
local data, lerr = pcall(membench.load, FIXTURE)
check("load fixture without error", data == true or type(data) == "table", tostring(lerr))
data = membench.load(FIXTURE)
check("fixture returns 3 questions", #data == 3, "got " .. #data)

-- iter_questions
local qs = {}
for q in membench.iter_questions(data) do
    qs[#qs + 1] = q
end
check("iter_questions yields 3 items", #qs == 3, "got " .. #qs)
check("q[1].id = mb_001",             qs[1].id == "mb_001",      tostring(qs[1] and qs[1].id))
check("q[1].category = simple",       qs[1].category == "simple", tostring(qs[1] and qs[1].category))
check("q[1].question is a string",    type(qs[1].question) == "string" and #qs[1].question > 0)
check("q[1].gold_ids has 1 entry",    #qs[1].gold_ids == 1, "got " .. #(qs[1].gold_ids or {}))
check("q[3].gold_ids has 2 entries",  #qs[3].gold_ids == 2, "got " .. #(qs[3].gold_ids or {}))

-- iter_questions with limit
local qs2 = {}
for q in membench.iter_questions(data, 2) do qs2[#qs2 + 1] = q end
check("iter_questions(data, 2) yields 2 items", #qs2 == 2)

-- iter_sessions
local sids = {}
for sid, body in membench.iter_sessions(qs[1]) do
    sids[#sids + 1] = sid
    check("session body contains USER:", body:find("USER:") ~= nil, "body: " .. body:sub(1, 40))
end
check("q[1] has 2 sessions", #sids == 2, "got " .. #sids)
check("first session id = sess_a", sids[1] == "sess_a", tostring(sids[1]))

-- categories
local cats = membench.categories(data)
check("categories returns sorted array", type(cats) == "table" and #cats == 3, table.concat(cats, ", "))
check("categories[1] = 'aggregative'", cats[1] == "aggregative", tostring(cats[1]))
check("categories[2] = 'knowledge_update'", cats[2] == "knowledge_update", tostring(cats[2]))
check("categories[3] = 'simple'", cats[3] == "simple", tostring(cats[3]))

-- ---------------------------------------------------------------------------
-- Integration: mini-run through membench_run logic
-- ---------------------------------------------------------------------------
print("\n-- mini eval run --")

local memory = require("luamemo")
memory.setup({
    db_url           = db_url,
    embedder_local   = "hash",
    backend          = "bruteforce",
    patterns_enabled = false,
    skip_embed_probe = true,
})

local db = require("luamemo.db")

-- Cleanup
for q in membench.iter_questions(data) do
    local scope = "smoke_mb_hash:" .. q.id
    db.query("DELETE FROM lm_memories WHERE scope = " .. db.escape_literal(scope))
end

local k_max  = 5
local hits_1 = 0
local n_q    = 0
local by_cat = {}

for q in membench.iter_questions(data) do
    local scope = "smoke_mb_hash:" .. q.id
    -- Ingest
    for sid, body in membench.iter_sessions(q) do
        local row, werr = memory.write({
            scope    = scope,
            kind     = "session",
            title    = sid,
            body     = body,
            metadata = { session_id = sid },
        })
        check("ingest " .. sid .. " for " .. q.id,
              row ~= nil and row.id ~= nil, tostring(werr))
    end
    -- Search
    local results, rerr = memory.search({
        scope             = scope,
        query             = q.question,
        limit             = k_max,
        tier_min          = 0,
        skip_observations = true,
    })
    check("search returns results for " .. q.id,
          type(results) == "table" and #results > 0, tostring(rerr))

    -- Score
    local gold = {}
    for _, gid in ipairs(q.gold_ids) do gold[gid] = true end
    local rank = nil
    for ri, r in ipairs(results or {}) do
        local meta = type(r.metadata) == "table" and r.metadata or {}
        if gold[meta.session_id] then rank = ri; break end
    end
    if rank == 1 then hits_1 = hits_1 + 1 end
    n_q = n_q + 1
    local cat = q.category or "unknown"
    if not by_cat[cat] then by_cat[cat] = { n = 0, hits = 0 } end
    by_cat[cat].n = by_cat[cat].n + 1
    if rank then by_cat[cat].hits = by_cat[cat].hits + 1 end
end

check("all 3 questions scored", n_q == 3, "n_q=" .. n_q)
check("per-category buckets populated", next(by_cat) ~= nil)
check("categories: simple present",          by_cat.simple ~= nil)
check("categories: knowledge_update present", by_cat.knowledge_update ~= nil)
check("categories: aggregative present",      by_cat.aggregative ~= nil)
check("R@1 > 0 on fixture", hits_1 > 0, "hits_1=" .. hits_1)

-- ---------------------------------------------------------------------------
-- JSON output writing
-- ---------------------------------------------------------------------------
print("\n-- JSON output --")

local out_path = "/tmp/smoke_membench_out.json"
local result = {
    embedder    = "hash",
    n           = n_q,
    overall     = { r1 = hits_1 / n_q },
    by_category = by_cat,
}
local fh, ferr = io.open(out_path, "w")
check("output file opened", fh ~= nil, tostring(ferr))
if fh then
    fh:write(cjson.encode(result))
    fh:close()
    local rfh = io.open(out_path, "r")
    if rfh then
        local raw = rfh:read("*a"); rfh:close()
        local parsed, perr = cjson.decode(raw)
        check("output JSON is parseable", parsed ~= nil, tostring(perr))
        check("output contains n=3", parsed and parsed.n == 3)
        os.remove(out_path)
    end
end

-- Cleanup
for q in membench.iter_questions(data) do
    local scope = "smoke_mb_hash:" .. q.id
    db.query("DELETE FROM lm_memories WHERE scope = " .. db.escape_literal(scope))
end

print(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
