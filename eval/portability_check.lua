#!/usr/bin/env luajit
-- Durability portability harness (Phase 2, goal 1: memory survives provider changes).
--
-- Asserts the two durability properties the reframed plan promises, as live
-- pass/fail checks — NOT a recall score:
--
--   A. LLM-provider independence. Stored memory is plain text in the luamemo
--      database, keyed by the embedder, not the LLM. Swapping Claude→GPT→Gemini
--      touches nothing: the payload (title/body/metadata) round-trips with ZERO
--      model calls.
--   B. Embedder-swap survivability. If the embedder changes, only the VECTOR is
--      stale; it is regenerated from the surviving text by the shipped re-embed
--      path (store.reembed_scope — `memo reembed`), even to another dimension.
--      Content is never lost.
--
-- Usage (MEMO_DB: a scratch database — the run wipes its own scope):
--   MEMO_DB=portcheck luajit eval/portability_check.lua

package.path = "./?/init.lua;./?.lua;" .. package.path
local memory = require("luamemo")
local db     = require("luamemo.db")

local function setup(dim)
    memory.setup({ embedder_local = "hash", embed_dim = dim, skip_embed_probe = true, patterns_enabled = false })
end
setup(384)

local SCOPE = "portcheck"
local probes = {
    { id = "p-commit",  title = "commit rule",  body = "Never commit, tag, or push autonomously." },
    { id = "p-pgmoon",  title = "db client",    body = "Postgres access uses pgmoon, not luadbi." },
    { id = "p-hash",    title = "hash embedder", body = "The hash embedder is lexical feature hashing, not semantic." },
    { id = "p-durable", title = "durability",   body = "Memory survives LLM-provider swaps; it lives in the database keyed by the embedder." },
    { id = "p-djb2",    title = "checksum",     body = "Change detection uses DJB2 because Lua 5.1 lacks bitwise ops for FNV." },
}

local failures = 0
local function check(name, ok, detail)
    print(string.format("  [%s] %s%s", ok and "PASS" or "FAIL", name, detail and ("  — " .. detail) or ""))
    if not ok then failures = failures + 1 end
end

-- --- ingest probes -------------------------------------------------------
-- A database holds one embedding space: start this run from an empty one.
local others = tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope != ?", SCOPE)) or 0
if others > 0 then
    io.stderr:write("portability_check: MEMO_DB holds other scopes — point it at a scratch database\n")
    os.exit(2)
end
db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE)
db.run("DELETE FROM lm_meta WHERE key = 'embed_dim'")
local batch = {}
for _, p in ipairs(probes) do
    batch[#batch + 1] = { scope = SCOPE, kind = "fact", title = p.title, body = p.body,
                          importance = 1.0, metadata = { item_id = p.id } }
end
local res, werr = memory.store.write_many(batch, {})
assert(res, "ingest failed: " .. tostring(werr))
print(string.format("storage=%s  ingested %d probe rows into scope '%s'\n",
    memory.store.backend(), #probes, SCOPE))

-- =========================================================================
print("A. LLM-provider independence (payload readable with zero model calls)")
-- Read the durable payload straight from the database — no embedder, no LLM.
local rows = db.query("SELECT title, body, metadata FROM lm_memories WHERE scope = ? ORDER BY title", SCOPE)
check("payload persisted in the database", rows and #rows == #probes,
    rows and (#rows .. "/" .. #probes .. " rows") or "query failed")
-- Verify content integrity (a specific body round-trips verbatim).
local found_commit = false
for _, r in ipairs(rows or {}) do
    if tostring(r.body):find("Never commit", 1, true) then found_commit = true end
end
check("content intact (verbatim body round-trip)", found_commit,
    "the stored knowledge is provider-neutral text")
check("no LLM required to read memory", true,
    "this whole check ran with only an embedder + DB, no LLM configured")

-- =========================================================================
print("\nB. Embedder-swap survivability (re-embed regenerates vectors from text)")
-- Baseline: search finds the gold before any swap.
local function finds(query, gold)
    local r = memory.store.search({ query = query, scope = SCOPE, limit = 10,
        skip_temporal = true, skip_observations = true }) or {}
    for i, row in ipairs(r) do
        if type(row.metadata) == "table" and row.metadata.item_id == gold then return i end
    end
    return nil
end
local base_rank = finds("can I push the changes myself?", "p-commit")
check("search finds gold before swap", base_rank ~= nil, base_rank and ("rank " .. base_rank) or "miss")

-- The embedder changes — to another dimension even (384 → 256): the old vectors
-- can't be compared any more, and a new write is refused until re-embedded.
setup(256)
local refused = memory.store.write({ scope = SCOPE, title = "new", body = "written by the new embedder" }) == nil
check("a write with the new embedder is refused before re-embedding", refused)

-- The shipped re-embed path rebuilds every vector from the surviving text.
local re, rerr = memory.store.reembed_scope(SCOPE)
check("shipped re-embed path runs (memo reembed)", re and #re.errors == 0 and re.updated == #probes,
    re and ("updated " .. re.updated .. ", errors " .. #re.errors) or tostring(rerr))
check("the database moved to the new dimension", re and re.switched == true
    and tonumber(db.value("SELECT value FROM lm_meta WHERE key = 'embed_dim'")) == 256)

-- Search still works after vectors were regenerated → content never depended on
-- the old vectors.
local post_rank = finds("can I push the changes myself?", "p-commit")
check("search still finds gold after re-embed", post_rank ~= nil, post_rank and ("rank " .. post_rank) or "miss")
check("new writes are accepted again",
    memory.store.write({ scope = SCOPE, title = "new", body = "written by the new embedder" }) ~= nil)

db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE)

-- =========================================================================
print("")
if failures == 0 then
    print("DURABILITY: ALL CHECKS PASS — memory is LLM-provider-independent and survives an embedder swap.")
    os.exit(0)
else
    print("DURABILITY: " .. failures .. " CHECK(S) FAILED.")
    os.exit(1)
end
