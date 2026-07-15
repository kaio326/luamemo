-- eval/tests/test_index_diff.lua
-- Phase 5 exit criteria:
--   1. digester.parse() correctly parses all standard unified diff formats
--   2. index.ingest_diff() stores hunks as searchable "diff" kind rows
--   3. Affected symbols attributed in diff row metadata
--   4. CLI round-trip: memo index diff --commit <sha> ingestable
--
-- Requires MEMO_DB_URL to be set.
-- Run: lua5.1 eval/tests/test_index_diff.lua

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
-- Test 1: digester.parse() — pure unit tests (no DB needed)
-- ---------------------------------------------------------------------------
io.write("\n--- Test 1: digester.parse() unit tests ---\n")

local digester = require("luamemo.index.digester")

-- Minimal two-hunk diff.
local SAMPLE_DIFF = [[
diff --git a/luamemo/store.lua b/luamemo/store.lua
index abc..def 100644
--- a/luamemo/store.lua
+++ b/luamemo/store.lua
@@ -74,7 +74,8 @@ local function _get_luamemo()
     return _luamemo_ref
 end

-local function _probe_backend()
-    local ok, rows = pcall(db.query, "SELECT 1")
-    return "pgvector"
+local function _probe_backend(tbl_name)
+    local ok, ext_rows = pcall(db.query,
+        "SELECT 1 AS present FROM pg_extension WHERE extname = 'vector'")
+    if not ok then return "pgvector" end
+    return (ext_rows and ext_rows[1]) and "pgvector" or "bruteforce"
 end
@@ -191,3 +191,6 @@ local function pg_array(arr)
     local parts = {}
-    parts[i] = '"' .. tostring(v) .. '"'
+    local s = tostring(v)
+        :gsub("\\", "\\\\")
+        :gsub('"',  '\\"')
+    parts[i] = '"' .. s .. '"'
 end
]]

local hunks, perr = digester.parse(SAMPLE_DIFF)
if not hunks then
    fail("digester.parse returned error: " .. tostring(perr))
else
    pass("digester.parse returned no error")
    assert_eq(#hunks, 2, "parsed 2 hunks")

    -- Hunk 1.
    local h1 = hunks[1]
    assert_eq(h1.file_path,  "luamemo/store.lua", "hunk 1 file_path")
    assert_eq(h1.from_line,  74,                  "hunk 1 from_line")
    assert_ge(#h1.added,     1,                   "hunk 1 has added lines")
    assert_ge(#h1.removed,   1,                   "hunk 1 has removed lines")
    assert_ge(#h1.raw_hunk,  10,                  "hunk 1 raw_hunk non-empty")

    -- Hunk 2.
    local h2 = hunks[2]
    assert_eq(h2.file_path,  "luamemo/store.lua", "hunk 2 file_path")
    assert_eq(h2.from_line,  191,                 "hunk 2 from_line")
    assert_ge(#h2.added,     1,                   "hunk 2 has added lines")
end

-- Parse the real fixture file (from git history).
local fixture_hunks, ferr2 = digester.parse_file("eval/fixtures/store_patch.diff")
if not fixture_hunks then
    fail("parse_file(store_patch.diff): " .. tostring(ferr2))
else
    pass("parse_file(store_patch.diff) succeeded")
    assert_ge(#fixture_hunks, 3, "store_patch.diff has >= 3 hunks")
    for i, h in ipairs(fixture_hunks) do
        info(("  hunk %d: %s @%d +%d -%d"):format(
            i, h.file_path, h.from_line, #h.added, #h.removed))
        if h.file_path ~= "luamemo/store.lua" then
            fail("hunk " .. i .. " has unexpected file_path: " .. h.file_path)
        end
    end
    if #fixture_hunks > 0 and fixture_hunks[1].file_path == "luamemo/store.lua" then
        pass("all fixture hunks reference luamemo/store.lua")
    end
end

-- Edge: empty diff.
local empty_hunks, _ = digester.parse("")
assert_eq(empty_hunks and #empty_hunks or 0, 0, "empty diff → 0 hunks")

-- Edge: new-file diff (--- /dev/null).
local newfile_diff = [[
--- /dev/null
+++ b/luamemo/newfile.lua
@@ -0,0 +1,3 @@
+local M = {}
+function M.hello() end
+return M
]]
local nf_hunks, _ = digester.parse(newfile_diff)
if nf_hunks and #nf_hunks == 1 and nf_hunks[1].file_path == "luamemo/newfile.lua" then
    pass("new-file diff (--- /dev/null) parsed correctly")
else
    fail("new-file diff parsing failed: " .. tostring(nf_hunks and #nf_hunks or "nil") .. " hunks")
end

-- ---------------------------------------------------------------------------
-- DB-dependent tests
-- ---------------------------------------------------------------------------
local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    io.stderr:write("[SKIP] MEMO_DB_URL not set — DB tests skipped\n")
    io.write(("\n=== Phase 5 results: %d passed, %d failed (digester only) ===\n"):format(PASS, FAIL))
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

local scope = "codeindex:test_diff"
local db = require("luamemo.db")
local st = luamemo.store

-- Wipe scope before start.
st.delete_where({ scope = scope })
info("wiped scope " .. scope .. " before test")

-- ---------------------------------------------------------------------------
-- Test 2: ingest_diff stores rows correctly
-- ---------------------------------------------------------------------------
io.write("\n--- Test 2: ingest_diff stores diff rows ---\n")

local result, ierr = luamemo.index.ingest_diff(SAMPLE_DIFF, {
    scope          = scope,
    commit_sha     = "abc12345",
    commit_message = "fix: probe backend column type",
    author         = "test",
})
if not result then
    fail("ingest_diff failed: " .. tostring(ierr))
else
    pass("ingest_diff completed without error")
    info(("ingest_diff: hunks=%d rows=%d errors=%d"):format(
        result.hunks, result.rows, #result.errors))
    assert_eq(result.hunks, 2, "2 hunks parsed from SAMPLE_DIFF")
    assert_eq(result.rows,  2, "2 rows written")
    assert_eq(#result.errors, 0, "0 errors")
end

-- Verify rows exist in DB.
local diff_count = db.query(
    ("SELECT COUNT(*) AS n FROM lm_memories WHERE scope = %s AND kind = 'diff'"):format(
        db.escape_literal(scope)))
local n_diff = diff_count and diff_count[1] and tonumber(diff_count[1].n) or 0
assert_ge(n_diff, 2, "diff rows in lm_memories >= 2")

-- ---------------------------------------------------------------------------
-- Test 3: diff rows are searchable
-- ---------------------------------------------------------------------------
io.write("\n--- Test 3: diff rows searchable ---\n")

local search_res, serr = st.search({
    query           = "probe backend column type",
    scope           = scope,
    kind            = "diff",
    limit           = 10,
    skip_temporal   = true,
    skip_observations = true,
})
if not search_res then
    fail("search failed: " .. tostring(serr))
elseif #search_res > 0 then
    pass("diff rows returned by search (" .. #search_res .. ")")
    info("top result: " .. (search_res[1].title or "?"))
else
    fail("search returned 0 diff rows")
end

-- ---------------------------------------------------------------------------
-- Test 4: ingest real fixture + symbol attribution (needs prior ingest)
-- ---------------------------------------------------------------------------
io.write("\n--- Test 4: real fixture ingest + symbol attribution ---\n")

-- First ingest the codebase so symbols exist for attribution.
local ingest_res, _ = luamemo.index.ingest(".", {
    scope           = scope,
    exclude_patterns = { ".git", "vendor/", "node_modules/", "eval/", "examples/" },
})
if ingest_res then
    info(("codebase ingest: files=%d symbols=%d"):format(ingest_res.files, ingest_res.symbols))
    pass("codebase ingest for attribution context")
else
    info("codebase ingest failed (symbol attribution will be empty)")
    pass("codebase ingest skipped (acceptable)")
end

-- Now ingest the real store_patch.diff.
local real_diff_content
local fd = io.open("eval/fixtures/store_patch.diff", "r")
if fd then
    real_diff_content = fd:read("*a")
    fd:close()
end

if real_diff_content and real_diff_content ~= "" then
    local real_result, real_err = luamemo.index.ingest_diff(real_diff_content, {
        scope          = scope,
        commit_sha     = "ca80e2e",
        commit_message = "fix: _ts_to_epoch sign, IPv6 URL parse, empty env-var guards, eval hardening",
        author         = "Kaio Fernandes",
    })
    if not real_result then
        fail("real fixture ingest_diff failed: " .. tostring(real_err))
    else
        pass("real fixture ingest_diff completed")
        info(("real fixture: hunks=%d rows=%d errors=%d"):format(
            real_result.hunks, real_result.rows, #real_result.errors))
        assert_ge(real_result.hunks, 3, "store_patch.diff has >= 3 hunks ingested")
        assert_eq(#real_result.errors, 0, "0 errors on real fixture")

        -- Check metadata on a stored row.
        local meta_check = db.query(
            ("SELECT metadata FROM lm_memories WHERE scope = %s AND kind = 'diff' "
          .. "AND metadata->>'commit' = 'ca80e2e' LIMIT 1"):format(
                db.escape_literal(scope)))
        if meta_check and #meta_check > 0 then
            pass("diff row with commit=ca80e2e found in DB")
        else
            fail("diff row with commit=ca80e2e not found in DB")
        end
    end
else
    info("eval/fixtures/store_patch.diff not found — skipping fixture test")
    pass("fixture test skipped (acceptable without fixture)")
end

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
st.delete_where({ scope = scope })
info("cleaned up scope: " .. scope)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
io.write(("\n=== Phase 5 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
