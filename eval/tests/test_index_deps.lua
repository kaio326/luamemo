-- eval/tests/test_index_deps.lua
-- Phase 4 exit criteria:
--   1. resolver.path_to_module() and resolver.resolve() work correctly
--   2. All require() calls extracted and stored as dependency rows after ingest
--   3. KG "requires" facts created for all internal dependencies
--   4. KG "required_by" facts created (reverse direction)
--   5. Re-ingest is idempotent: no duplicate KG facts
--
-- Requires MEMO_DB_URL to be set.
-- Run: lua5.1 eval/tests/test_index_deps.lua

package.path = "./?/init.lua;./?.lua;" .. package.path

local PASS, FAIL = 0, 0

local function pass(msg) PASS = PASS + 1; io.write("[PASS] " .. msg .. "\n") end
local function fail(msg) FAIL = FAIL + 1; io.write("[FAIL] " .. msg .. "\n") end
local function info(msg) io.write("[INFO] " .. msg .. "\n") end

local function assert_eq(a, b, label)
    if a == b then pass(label)
    else fail(label .. " — got " .. tostring(a) .. " expected " .. tostring(b)) end
end

local function assert_ge(a, b, label)
    if a >= b then pass(label .. " (" .. a .. " >= " .. b .. ")")
    else fail(label .. " — got " .. tostring(a) .. " expected >= " .. tostring(b)) end
end

-- ---------------------------------------------------------------------------
-- Test 1: resolver — pure unit tests (no DB needed)
-- ---------------------------------------------------------------------------
io.write("\n--- Test 1: resolver unit tests ---\n")

local resolver = require("luamemo.index.resolver")

-- path_to_module
local cases_ptm = {
    { "luamemo/store.lua",      "luamemo.store" },
    { "luamemo/index/init.lua", "luamemo.index" },
    { "luamemo/kg.lua",         "luamemo.kg" },
    { "cli/memo",               nil },   -- no .lua suffix
    { "module.lua",             "module" },
}
for _, tc in ipairs(cases_ptm) do
    local got = resolver.path_to_module(tc[1])
    if got == tc[2] then
        pass("path_to_module(" .. tc[1] .. ") = " .. tostring(got))
    else
        fail("path_to_module(" .. tc[1] .. ") = " .. tostring(got) .. " (expected " .. tostring(tc[2]) .. ")")
    end
end

-- resolve: internal modules should resolve, external should not
local root = "."
local cases_res = {
    { "luamemo.store",   "luamemo/store.lua" },
    { "luamemo.kg",      "luamemo/kg.lua" },
    { "luamemo.index",   "luamemo/index/init.lua" },
    { "external.nonexistent", nil },
    { "socket",          nil },
}
for _, tc in ipairs(cases_res) do
    local got = resolver.resolve(tc[1], root)
    if got == tc[2] then
        pass("resolve(" .. tc[1] .. ") = " .. tostring(got))
    else
        fail("resolve(" .. tc[1] .. ") = " .. tostring(got) .. " (expected " .. tostring(tc[2]) .. ")")
    end
end

-- ---------------------------------------------------------------------------
-- DB-dependent tests
-- ---------------------------------------------------------------------------
local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    io.stderr:write("[SKIP] MEMO_DB_URL not set — DB tests skipped\n")
    io.write(("\n=== Phase 4 results: %d passed, %d failed (resolver only) ===\n"):format(PASS, FAIL))
    os.exit(FAIL > 0 and 1 or 0)
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

local scope = "codeindex:test_deps"
local db = require("luamemo.db")
local kg = luamemo.kg

-- Wipe scope and KG facts before start.
luamemo.store.delete_where({ scope = scope })
db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))
info("wiped scope " .. scope .. " before test")

-- ---------------------------------------------------------------------------
-- Test 2: Full ingest — dependency rows created
-- ---------------------------------------------------------------------------
io.write("\n--- Test 2: dependency rows after ingest ---\n")

local result, ierr = luamemo.index.ingest(".", {
    scope           = scope,
    exclude_patterns = { ".git", "vendor/", "node_modules/", "eval/", "examples/" },
})
if not result then
    fail("ingest failed: " .. tostring(ierr))
    luamemo.store.delete_where({ scope = scope })
    db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))
    io.write(("\n=== Phase 4 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
    os.exit(1)
end
pass("ingest completed")
info(("ingest: files=%d symbols=%d requires=%d errors=%d"):format(
    result.files, result.symbols, result.requires, #result.errors))
assert_eq(#result.errors, 0, "ingest: 0 file errors")
assert_ge(result.requires, 10, "ingest: at least 10 dependency rows written")

-- Verify dependency rows exist in DB.
local dep_count = db.query(
    ("SELECT COUNT(*) AS n FROM lm_memories WHERE scope = %s AND kind = 'dependency'"):format(
        db.escape_literal(scope)))
local n_dep = dep_count and dep_count[1] and tonumber(dep_count[1].n) or 0
assert_ge(n_dep, 10, "dependency rows in lm_memories >= 10")

-- Check a known dependency: luamemo/init.lua requires luamemo.store
local init_deps = db.query(
    ("SELECT * FROM lm_memories WHERE scope = %s AND kind = 'dependency' "
  .. "AND metadata->>'from_path' = 'luamemo/init.lua' "
  .. "AND metadata->>'to_module' LIKE '%%store%%' LIMIT 5"):format(
        db.escape_literal(scope)))
if init_deps and #init_deps > 0 then
    pass("luamemo/init.lua → luamemo.store dependency row found")
    -- Check resolved_path is set.
    local row = init_deps[1]
    local rp = row.metadata and row.metadata.resolved_path
    if rp then
        pass("resolved_path set: " .. tostring(rp))
    else
        -- Try reading metadata as string (some drivers return JSONB as string).
        local meta_str = tostring(row.metadata or "")
        if meta_str:find("resolved_path") then
            pass("resolved_path present in metadata")
        else
            fail("resolved_path missing in dependency metadata")
        end
    end
else
    fail("luamemo/init.lua → luamemo.store dependency row not found")
end

-- ---------------------------------------------------------------------------
-- Test 3: KG "requires" facts
-- ---------------------------------------------------------------------------
io.write("\n--- Test 3: KG requires facts ---\n")

-- luamemo.init should have "requires" facts for luamemo.store and luamemo.kg etc.
local req_facts, rferr = kg.query({ scope=scope, predicate="requires", subject="luamemo" })
if rferr then
    fail("kg.query requires failed: " .. tostring(rferr))
else
    info("luamemo.init requires facts: " .. tostring(req_facts and #req_facts or 0))
    if req_facts and #req_facts > 0 then
        pass("KG requires facts found for luamemo")
        for _, f in ipairs(req_facts) do
            info("  luamemo requires " .. f.object)
        end
    else
        fail("no KG requires facts for luamemo")
    end
end

-- Check a specific known fact: luamemo.store requires luamemo.db
local store_reqs, _ = kg.query({ scope=scope, predicate="requires", subject="luamemo.store" })
if store_reqs and #store_reqs > 0 then
    pass("luamemo.store has requires facts (" .. #store_reqs .. ")")
else
    fail("luamemo.store has no requires facts")
end

-- ---------------------------------------------------------------------------
-- Test 4: KG "required_by" facts (reverse direction)
-- ---------------------------------------------------------------------------
io.write("\n--- Test 4: KG required_by facts ---\n")

-- luamemo.store is required by multiple modules.
local rb_facts, rberr = kg.query({ scope=scope, predicate="required_by", subject="luamemo.store" })
if rberr then
    fail("kg.query required_by failed: " .. tostring(rberr))
else
    info("luamemo.store required_by facts: " .. tostring(rb_facts and #rb_facts or 0))
    if rb_facts and #rb_facts > 0 then
        pass("luamemo.store has required_by facts (" .. #rb_facts .. ")")
        for _, f in ipairs(rb_facts) do
            info("  luamemo.store required_by " .. f.object)
        end
    else
        fail("luamemo.store has no required_by facts")
    end
end

-- luamemo.db should be required_by at least store, kg, etc.
local db_rb, _ = kg.query({ scope=scope, predicate="required_by", subject="luamemo.db" })
if db_rb and #db_rb > 0 then
    pass("luamemo.db required_by facts exist (" .. #db_rb .. ")")
else
    fail("luamemo.db has no required_by facts")
end

-- ---------------------------------------------------------------------------
-- Test 5: Idempotency — re-ingest produces same KG facts, no duplicates
-- ---------------------------------------------------------------------------
io.write("\n--- Test 5: KG idempotency ---\n")

local kg_count_before = db.query(
    ("SELECT COUNT(*) AS n FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))
local n_before = kg_count_before and kg_count_before[1] and tonumber(kg_count_before[1].n) or 0
info("KG facts before re-ingest: " .. n_before)

-- Re-ingest.
local result2, _ = luamemo.index.ingest(".", {
    scope           = scope,
    exclude_patterns = { ".git", "vendor/", "node_modules/", "eval/", "examples/" },
})
if not result2 then
    fail("second ingest failed")
else
    local kg_count_after = db.query(
        ("SELECT COUNT(*) AS n FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))
    local n_after = kg_count_after and kg_count_after[1] and tonumber(kg_count_after[1].n) or 0
    info("KG facts after re-ingest: " .. n_after)
    assert_eq(n_before, n_after, "KG fact count unchanged after re-ingest (no duplicates)")
end

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
luamemo.store.delete_where({ scope = scope })
db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))
info("cleaned up scope and KG facts")

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
io.write(("\n=== Phase 4 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
