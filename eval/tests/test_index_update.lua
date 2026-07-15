-- eval/tests/test_index_update.lua
-- Phase 3 exit criteria:
--   1. index.update() on unchanged codebase → zero writes/deletes (all files skipped)
--   2. Modify a file (rename symbol) → old row deleted, new row written, no duplicates
--   3. Delete a file → all associated rows deleted
--   4. Add a new file → new rows created
--
-- Requires MEMO_DB_URL to be set.
-- Run: lua5.1 eval/tests/test_index_update.lua

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

local scope = "codeindex:test_update"
local st = luamemo.store

-- Clean up before start.
st.delete_where({ scope = scope })
info("wiped scope " .. scope .. " before test")

-- ---------------------------------------------------------------------------
-- Helpers: temp directory managed within ./eval/tmp/
-- ---------------------------------------------------------------------------
local tmp_root = "./eval/tmp/test_update_" .. tostring(os.time())

local function mkdir(path)
    os.execute(('mkdir -p "%s"'):format(path))
end

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

local function rm_file(path)
    os.remove(path)
end

local function rm_dir(path)
    os.execute(('rm -rf "%s"'):format(path))
end

mkdir(tmp_root)
info("temp dir: " .. tmp_root)

-- Create an initial set of files.
local file_a = tmp_root .. "/module_a.lua"
local file_b = tmp_root .. "/module_b.lua"
local file_c = tmp_root .. "/module_c.lua"  -- will be added later

local src_a_v1 = [[
local M = {}
-- Compute the sum of two numbers.
function M.add(a, b)
    return a + b
end
-- Subtract b from a.
function M.subtract(a, b)
    return a - b
end
return M
]]

local src_a_v2 = [[
local M = {}
-- Compute the sum of two numbers.
function M.add(a, b)
    return a + b
end
-- Multiply two numbers.
function M.multiply(a, b)
    return a * b
end
return M
]]

local src_b = [[
local M = {}
function M.hello()
    return "hello"
end
return M
]]

local src_c = [[
local M = {}
function M.new_fn()
    return true
end
return M
]]

write_file(file_a, src_a_v1)
write_file(file_b, src_b)

-- ---------------------------------------------------------------------------
-- BASELINE: full ingest of initial files.
-- ---------------------------------------------------------------------------
io.write("\n--- Baseline ingest ---\n")

local base, berr = luamemo.index.ingest(tmp_root, { scope = scope })
if not base then
    fail("baseline ingest failed: " .. tostring(berr))
    st.delete_where({ scope = scope })
    rm_dir(tmp_root)
    io.write(("\n=== Phase 3 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
    os.exit(1)
end
pass("baseline ingest completed")
info(("baseline: files=%d symbols=%d"):format(base.files, base.symbols))

local status0, _ = luamemo.index.status({ scope = scope })
local sym_count_0 = status0 and status0.symbol or 0
info("baseline symbol count: " .. sym_count_0)

-- Verify expected symbols exist after baseline.
local res_add = st.search({
    query = "M.add", scope = scope, kind = "symbol",
    metadata_filter = { path = "module_a.lua" },
    limit = 5, skip_temporal = true, skip_observations = true,
})
if res_add and #res_add > 0 then
    pass("baseline: M.add symbol exists")
else
    fail("baseline: M.add symbol not found")
end

local res_sub = st.search({
    query = "M.subtract", scope = scope, kind = "symbol",
    metadata_filter = { path = "module_a.lua" },
    limit = 5, skip_temporal = true, skip_observations = true,
})
local had_subtract = res_sub and #res_sub > 0
if had_subtract then pass("baseline: M.subtract symbol exists")
else fail("baseline: M.subtract symbol not found") end

-- ---------------------------------------------------------------------------
-- Test 1: Unchanged codebase → zero writes (all files skipped).
-- ---------------------------------------------------------------------------
io.write("\n--- Test 1: unchanged codebase → zero writes ---\n")

local upd1, uerr1 = luamemo.index.update(tmp_root, { scope = scope })
if not upd1 then
    fail("update (unchanged) failed: " .. tostring(uerr1))
else
    pass("update on unchanged codebase completed without error")
    info(("update1: files=%d symbols=%d skipped=%d deleted=%d errors=%d"):format(
        upd1.files, upd1.symbols, upd1.skipped or 0,
        upd1.deleted or 0, #upd1.errors))
    assert_eq(upd1.symbols,        0,          "no symbols written on unchanged run")
    assert_eq(upd1.skipped or 0,   upd1.files, "all files skipped on unchanged run")
    assert_eq(upd1.deleted or 0,   0,          "no deletions on unchanged run")
    assert_eq(#upd1.errors,        0,          "no errors on unchanged run")
end

-- Row count must be same.
local status1, _ = luamemo.index.status({ scope = scope })
local sym_count_1 = status1 and status1.symbol or 0
assert_eq(sym_count_0, sym_count_1, "symbol count unchanged after no-op update")

-- ---------------------------------------------------------------------------
-- Test 2: Modify a file (rename M.subtract → M.multiply).
-- ---------------------------------------------------------------------------
io.write("\n--- Test 2: modify file (rename symbol) ---\n")

write_file(file_a, src_a_v2)  -- replaces M.subtract with M.multiply

local upd2, uerr2 = luamemo.index.update(tmp_root, { scope = scope })
if not upd2 then
    fail("update (modify) failed: " .. tostring(uerr2))
else
    pass("update on modified file completed without error")
    info(("update2: files=%d symbols=%d skipped=%d deleted=%d errors=%d"):format(
        upd2.files, upd2.symbols, upd2.skipped or 0,
        upd2.deleted or 0, #upd2.errors))
    -- file_a changed, file_b unchanged → exactly 1 file processed.
    assert_eq(upd2.skipped or 0, upd2.files - 1, "all but 1 file skipped")
    assert_eq(#upd2.errors, 0, "no errors on modify run")
end

-- Use direct SQL for exact title/path checks — FTS may return any row with low relevance.
local db = require("luamemo.db")
local esc_scope = db.escape_literal(scope)

local function count_sym(title_fragment, path)
    local r = db.query(
        ("SELECT COUNT(*) AS n FROM lm_memories WHERE scope = %s AND kind = 'symbol'"
      .. " AND title LIKE '%%%s%%' AND metadata->>'path' = '%s'"):format(
            esc_scope, title_fragment, path))
    return r and r[1] and tonumber(r[1].n) or 0
end

-- Old symbol (M.subtract) should be gone.
local sub_count = count_sym("subtract", "module_a.lua")
if sub_count == 0 then
    pass("M.subtract row deleted after rename")
else
    fail("M.subtract row still present after rename (" .. sub_count .. " rows)")
end

-- New symbol (M.multiply) should exist.
local mul_count = count_sym("multiply", "module_a.lua")
if mul_count > 0 then
    pass("M.multiply row present after rename")
else
    fail("M.multiply row missing after rename")
end

-- M.add should still be there (it didn't change).
local add_count = count_sym("add", "module_a.lua")
if add_count > 0 then
    pass("M.add row survives rename of sibling symbol")
else
    fail("M.add row missing after rename of sibling symbol")
end

-- No duplicate rows for module_a.lua.
local count_res = db.query(
    ("SELECT COUNT(*) AS n FROM lm_memories WHERE scope = %s AND kind = 'symbol' "
  .. "AND metadata->>'path' = 'module_a.lua'"):format(db.escape_literal(scope)))
local sym_a_count = count_res and count_res[1] and tonumber(count_res[1].n) or 0
info("module_a.lua symbol rows after modify: " .. sym_a_count)
-- v2 has M.add + M.multiply = 2 symbols.
assert_eq(sym_a_count, 2, "exactly 2 symbol rows for module_a.lua after rename (no duplicates)")

-- ---------------------------------------------------------------------------
-- Test 3: Delete a file → all rows removed.
-- ---------------------------------------------------------------------------
io.write("\n--- Test 3: delete file → rows removed ---\n")

rm_file(file_b)

local upd3, uerr3 = luamemo.index.update(tmp_root, { scope = scope })
if not upd3 then
    fail("update (delete) failed: " .. tostring(uerr3))
else
    pass("update on deleted file completed without error")
    info(("update3: files=%d symbols=%d skipped=%d deleted=%d errors=%d"):format(
        upd3.files, upd3.symbols, upd3.skipped or 0,
        upd3.deleted or 0, #upd3.errors))
    assert_ge(upd3.deleted or 0, 1, "at least 1 row deleted for removed file")
    assert_eq(#upd3.errors, 0, "no errors on delete run")
end

-- file_b rows should be gone.
local count_b = db.query(
    ("SELECT COUNT(*) AS n FROM lm_memories WHERE scope = %s "
  .. "AND metadata->>'path' = 'module_b.lua'"):format(db.escape_literal(scope)))
local b_count = count_b and count_b[1] and tonumber(count_b[1].n) or 0
assert_eq(b_count, 0, "all module_b.lua rows deleted after file removal")

-- file_a rows should still be intact.
local count_a2 = db.query(
    ("SELECT COUNT(*) AS n FROM lm_memories WHERE scope = %s "
  .. "AND metadata->>'path' = 'module_a.lua'"):format(db.escape_literal(scope)))
local a2_count = count_a2 and count_a2[1] and tonumber(count_a2[1].n) or 0
assert_ge(a2_count, 1, "module_a.lua rows still present after sibling deleted")

-- ---------------------------------------------------------------------------
-- Test 4: Add a new file → new rows created.
-- ---------------------------------------------------------------------------
io.write("\n--- Test 4: add new file → rows created ---\n")

write_file(file_c, src_c)

local upd4, uerr4 = luamemo.index.update(tmp_root, { scope = scope })
if not upd4 then
    fail("update (new file) failed: " .. tostring(uerr4))
else
    pass("update on new file completed without error")
    info(("update4: files=%d symbols=%d skipped=%d deleted=%d errors=%d"):format(
        upd4.files, upd4.symbols, upd4.skipped or 0,
        upd4.deleted or 0, #upd4.errors))
    assert_ge(upd4.symbols or 0, 1, "at least 1 symbol written for new file")
    assert_eq(#upd4.errors, 0, "no errors on new-file run")
end

-- module_c.lua rows should exist.
local count_c = db.query(
    ("SELECT COUNT(*) AS n FROM lm_memories WHERE scope = %s "
  .. "AND metadata->>'path' = 'module_c.lua'"):format(db.escape_literal(scope)))
local c_count = count_c and count_c[1] and tonumber(count_c[1].n) or 0
assert_ge(c_count, 1, "module_c.lua rows created after file added")

-- M.new_fn should be searchable.
local res_new = st.search({
    query = "M.new_fn", scope = scope, kind = "symbol",
    metadata_filter = { path = "module_c.lua" },
    limit = 5, skip_temporal = true, skip_observations = true,
})
if res_new and #res_new > 0 then
    pass("M.new_fn row found in index after new file added")
else
    fail("M.new_fn not found after new file added")
end

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
st.delete_where({ scope = scope })
rm_dir(tmp_root)
info("cleaned up scope and temp dir")

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
io.write(("\n=== Phase 3 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
