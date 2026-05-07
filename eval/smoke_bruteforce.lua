-- Phase 7.5 smoke test: brute-force backend against plain Postgres 15
-- (no pgvector). Run from luamemo/ dir:
--   docker exec -i <postgres-container> psql -U postgres -c \
--     'DROP DATABASE IF EXISTS lm_bruteforce_test; CREATE DATABASE lm_bruteforce_test;'
--   docker exec -i <postgres-container> psql -U postgres -d lm_bruteforce_test \
--     < luamemo/schema_bruteforce.sql
--   PGHOST=127.0.0.1 PGPORT=5432 lua5.1 eval/smoke_bruteforce.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

-- luamemo.db creates a pgmoon connection automatically from
-- PGHOST / PGDATABASE / PGUSER / PGPASSWORD env vars when outside OpenResty.

local db     = require("luamemo.db")
local memory = require("luamemo")

memory.setup({
    db_table       = "lm_memories",
    embedder_local = "hash",
    embed_dim      = 384,
    backend        = "auto",   -- should resolve to bruteforce
    default_scope  = "smoke",
    auth_fn        = function() return true end,
})

local function header(s) print("\n=== " .. s .. " ===") end

header("backend probe")
print("resolved backend =", memory.store.backend())
assert(memory.store.backend() == "bruteforce", "expected bruteforce")

-- Clean slate.
db.query("TRUNCATE lm_memories")

header("write 5 unrelated memories")
local seeds = {
    { title = "How to deploy with Docker", body = "Run docker compose up to start the stack." },
    { title = "PostgreSQL backup strategy", body = "Use pg_dump nightly and ship to S3." },
    { title = "Cache invalidation guide", body = "Flush profile_cache after profile updates." },
    { title = "JWT vs sessions", body = "We use sessions because of CSRF and revocation." },
    { title = "T2125 expense categories", body = "Meals at 50%, motor vehicle, home office." },
}
for i, s in ipairs(seeds) do
    local row, err, action = memory.write({
        scope = "smoke", kind = "fact", title = s.title, body = s.body,
    })
    assert(row, "write " .. i .. " failed: " .. tostring(err))
    print(string.format("  inserted id=%d action=%s title=%q", row.id, action, row.title))
    assert(action == "inserted", "expected inserted, got " .. tostring(action))
end

header("write near-duplicate (expect merged)")
local dup, derr, daction = memory.write({
    scope = "smoke", kind = "fact",
    title = "How to deploy with Docker",
    body  = "Run docker compose up to start the stack.",
})
assert(dup, "dup write failed: " .. tostring(derr))
print("  action =", daction, "id =", dup.id)
assert(daction == "merged", "expected merged, got " .. tostring(daction))

header("force append (expect inserted)")
local app, aerr, aaction = memory.write({
    scope = "smoke", kind = "fact",
    title = "How to deploy with Docker",
    body  = "Run docker compose up to start the stack.",
    dedup_strategy = "append",
})
assert(app, "append write failed: " .. tostring(aerr))
print("  action =", aaction, "id =", app.id)
assert(aaction == "inserted", "expected inserted, got " .. tostring(aaction))

header("search semantic-ish (deploy)")
local results, serr = memory.search({
    query = "docker deploy command",
    scope = "smoke",
    limit = 3,
})
assert(results, "search failed: " .. tostring(serr))
for i, r in ipairs(results) do
    print(string.format("  %d. id=%d score=%.4f vec=%.4f fts=%.4f title=%q",
        i, r.id, r.score, r.vec_score, r.fts_score, r.title))
end
assert(#results > 0, "no results")
assert(results[1].title:find("Docker"), "top result should mention Docker")

header("search lexical-only (T2125)")
local results2 = memory.search({ query = "T2125 meals", scope = "smoke", limit = 3 })
for i, r in ipairs(results2) do
    print(string.format("  %d. id=%d score=%.4f vec=%.4f fts=%.4f title=%q",
        i, r.id, r.score, r.vec_score, r.fts_score, r.title))
end
assert(results2[1].title:find("T2125"), "top result should be T2125 row")

header("search returns no embedding payload")
assert(results[1].embedding == nil, "embedding column should be stripped")

header("recent")
local recents = memory.recent({ scope = "smoke", limit = 10 })
print("  total recent rows =", #recents)
assert(#recents >= 6, "expected at least 6 rows total (5 seeds + 1 append)")

header("ALL PASS")
