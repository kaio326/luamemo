-- eval/tests/test_index_explore.lua
-- Phase 6 exit criteria:
--   1. index.explore("store.write") returns matched symbols for store.lua
--   2. callers leg returns symbols from modules that require luamemo.store
--   3. callees leg returns symbols from modules that luamemo.store requires
--   4. Results are deduplicated (a symbol appears once across legs)
--   5. all = matched ∪ callers ∪ callees with no duplicate ids
--
-- Requires MEMO_DB_URL. Builds a fresh index (needs Phase 4 KG facts).
-- Run: lua5.1 eval/tests/test_index_explore.lua

package.path = "./?/init.lua;./?.lua;" .. package.path

local PASS, FAIL = 0, 0

local function pass(msg) PASS = PASS + 1; io.write("[PASS] " .. msg .. "\n") end
local function fail(msg) FAIL = FAIL + 1; io.write("[FAIL] " .. msg .. "\n") end
local function info(msg) io.write("[INFO] " .. msg .. "\n") end

local function assert_ge(a, b, label)
    if a >= b then pass(label .. " (" .. a .. " >= " .. b .. ")")
    else fail(label .. " — got " .. tostring(a) .. " expected >= " .. tostring(b)) end
end

-- ---------------------------------------------------------------------------
-- Env / setup
-- ---------------------------------------------------------------------------
local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    io.stderr:write("[SKIP] MEMO_DB_URL not set\n")
    os.exit(0)
end

local ok_lm, luamemo = pcall(require, "luamemo")
if not ok_lm then
    io.stderr:write("[ERROR] cannot load luamemo: " .. tostring(luamemo) .. "\n")
    os.exit(1)
end

local embedder_url = os.getenv("MEMO_EMBEDDER_URL")
local cfg = { db_url = db_url, auth_fn = function() return true end }
if embedder_url and embedder_url ~= "" then
    cfg.embedder_url     = embedder_url
    cfg.embedder_adapter = os.getenv("MEMO_EMBEDDER_ADAPTER") or "generic"
else
    cfg.embedder_local = os.getenv("MEMO_EMBEDDER") or "hash"
end
local embed_dim = tonumber(os.getenv("MEMO_EMBED_DIM"))
if embed_dim then cfg.embed_dim = embed_dim end

local ok_setup, setup_err = pcall(luamemo.setup, cfg)
if not ok_setup then
    io.stderr:write("[ERROR] luamemo.setup failed: " .. tostring(setup_err) .. "\n")
    os.exit(1)
end
info("luamemo setup OK, embedder=" .. (cfg.embedder_local or cfg.embedder_url or "?"))

local scope = "codeindex:test_explore"
local db = require("luamemo.db")
local st = luamemo.store

-- Clean slate: wipe memory rows + KG facts.
st.delete_where({ scope = scope })
db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))
info("wiped scope " .. scope .. " before test")

-- ---------------------------------------------------------------------------
-- Build the index (symbols + dependency rows + KG facts).
-- ---------------------------------------------------------------------------
io.write("\n--- Building index for explore ---\n")

local ingest, ierr = luamemo.index.ingest(".", {
    scope            = scope,
    exclude_patterns = { ".git", "vendor/", "node_modules/", "eval/", "examples/" },
})
if not ingest then
    fail("ingest failed: " .. tostring(ierr))
    st.delete_where({ scope = scope })
    db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))
    io.write(("\n=== Phase 6 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
    os.exit(1)
end
info(("ingest: files=%d symbols=%d requires=%d"):format(
    ingest.files, ingest.symbols, ingest.requires))
pass("index built for explore")

-- Sanity: KG facts exist (required for the traversal legs).
local kg_n = db.query(("SELECT COUNT(*) AS n FROM lm_kg_facts WHERE scope = %s"):format(
    db.escape_literal(scope)))
local n_kg = kg_n and kg_n[1] and tonumber(kg_n[1].n) or 0
assert_ge(n_kg, 10, "KG facts present for traversal")

-- ---------------------------------------------------------------------------
-- Test: explore "store write memory"
-- ---------------------------------------------------------------------------
io.write("\n--- Test: index.explore ---\n")

local res, eerr = luamemo.index.explore("store write memory", { scope = scope, limit = 10 })
if not res then
    fail("explore failed: " .. tostring(eerr))
else
    pass("explore returned a result table")
    info(("matched=%d callers=%d callees=%d all=%d"):format(
        #res.matched, #res.callers, #res.callees, #res.all))

    -- 1. Matched symbols present.
    assert_ge(#res.matched, 1, "explore: matched symbols >= 1")

    -- 2. At least one neighbour leg is non-empty (store is heavily connected).
    assert_ge(#res.callers + #res.callees, 1, "explore: at least one neighbour symbol found")

    -- 3. Dedup: no id appears twice across the `all` union.
    local seen = {}
    local dup = false
    for _, r in ipairs(res.all) do
        local key = tostring(r.id)
        if seen[key] then dup = true end
        seen[key] = true
    end
    if not dup then pass("explore: all[] has no duplicate ids")
    else fail("explore: duplicate ids found in all[]") end

    -- 4. all == matched + callers + callees in size (since each leg is pre-deduped).
    if #res.all == #res.matched + #res.callers + #res.callees then
        pass("explore: all[] size equals sum of legs (legs mutually disjoint)")
    else
        fail(("explore: all[]=%d but legs sum to %d"):format(
            #res.all, #res.matched + #res.callers + #res.callees))
    end

    -- 5. Every matched row carries a path in metadata (used for module derivation).
    local all_have_path = true
    for _, r in ipairs(res.matched) do
        if not (r.metadata and r.metadata.path) then all_have_path = false end
    end
    if all_have_path then pass("explore: matched rows all carry metadata.path")
    else fail("explore: some matched rows missing metadata.path") end
end

-- ---------------------------------------------------------------------------
-- Test: explore on a specific known-connected module (luamemo.db).
-- luamemo.db is required by many modules → callers leg must be non-empty.
-- ---------------------------------------------------------------------------
io.write("\n--- Test: explore connectivity (db) ---\n")

local res2, _ = luamemo.index.explore("escape_literal query database", { scope = scope, limit = 10 })
if res2 then
    info(("db explore: matched=%d callers=%d callees=%d"):format(
        #res2.matched, #res2.callers, #res2.callees))
    -- db.lua is a leaf-ish module required by store/kg/etc → expect callers.
    assert_ge(#res2.callers, 1, "explore(db): callers leg non-empty (db is widely required)")
else
    fail("second explore failed")
end

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
st.delete_where({ scope = scope })
db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))
info("cleaned up scope and KG facts")

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
io.write(("\n=== Phase 6 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
