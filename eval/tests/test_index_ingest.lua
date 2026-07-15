-- eval/tests/test_index_ingest.lua
-- Phase 2 exit criteria:
--   1. metadata_filter works in store.search()
--   2. store.delete_where() works correctly
--   3. index.ingest(".") completes without errors
--   4. All symbols visible via index.search()
--   5. index.status() shows correct counts
--   6. Re-running index.ingest() is idempotent (no duplicate rows)
--
-- Requires MEMO_DB_URL to be set and lm_memories table to exist.
-- Run: lua5.1 eval/tests/test_index_ingest.lua [--root <path>] [--scope codeindex:test]

package.path = "./?/init.lua;./?.lua;" .. package.path

local PASS, FAIL = 0, 0

local function pass(msg) PASS = PASS + 1; io.write("[PASS] " .. msg .. "\n") end
local function fail(msg) FAIL = FAIL + 1; io.write("[FAIL] " .. msg .. "\n") end
local function info(msg) io.write("[INFO] " .. msg .. "\n") end

local function assert_ge(a, b, label)
    if a >= b then pass(label .. " (" .. a .. " >= " .. b .. ")")
    else fail(label .. " — got " .. tostring(a) .. " expected >= " .. tostring(b)) end
end

local function assert_eq(a, b, label)
    if a == b then pass(label)
    else fail(label .. " — got " .. tostring(a) .. " expected " .. tostring(b)) end
end

-- ---------------------------------------------------------------------------
-- Parse args and setup
-- ---------------------------------------------------------------------------
local root  = "."
local scope = "codeindex:test_ingest"
for i, a in ipairs(arg or {}) do
    if a == "--root"  and arg[i+1] then root  = arg[i+1] end
    if a == "--scope" and arg[i+1] then scope = arg[i+1] end
end

-- Check MEMO_DB_URL.
local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    io.stderr:write("[SKIP] MEMO_DB_URL not set — DB tests skipped\n")
    io.write("Phase 2 tests require a running DB. Set MEMO_DB_URL and re-run.\n")
    os.exit(0)
end

-- Bootstrap luamemo.
local ok_lm, luamemo = pcall(require, "luamemo")
if not ok_lm then
    io.stderr:write("[ERROR] cannot load luamemo: " .. tostring(luamemo) .. "\n")
    os.exit(1)
end

local embedder_url = os.getenv("MEMO_EMBEDDER_URL")
local cfg = {}
if embedder_url and embedder_url ~= "" then
    cfg.embedder_url     = embedder_url
    cfg.embedder_adapter = os.getenv("MEMO_EMBEDDER_ADAPTER") or "generic"
else
    cfg.embedder_local = os.getenv("MEMO_EMBEDDER") or "hash"
end
local embed_dim = tonumber(os.getenv("MEMO_EMBED_DIM"))
if embed_dim then cfg.embed_dim = embed_dim end
cfg.db_url  = db_url
cfg.auth_fn = function() return true end

local ok_setup, setup_err = pcall(luamemo.setup, cfg)
if not ok_setup then
    io.stderr:write("[ERROR] luamemo.setup failed: " .. tostring(setup_err) .. "\n")
    os.exit(1)
end
info("luamemo setup OK, embedder=" .. (cfg.embedder_local or cfg.embedder_url or "?"))

-- ---------------------------------------------------------------------------
-- Cleanup: wipe the test scope before starting.
-- ---------------------------------------------------------------------------
local st = luamemo.store
local wipe_n = st.delete_where({ scope = scope })
info(("wiped %s rows from %s before test"):format(tostring(wipe_n), scope))

-- ---------------------------------------------------------------------------
-- Test 1: metadata_filter in store.search()
-- ---------------------------------------------------------------------------
io.write("\n--- Test 1: metadata_filter ---\n")

-- Write a test row with a known path in metadata.
local test_row, werr = st.write({
    scope    = scope,
    kind     = "symbol",
    title    = "test.marker",
    body     = "test symbol for metadata_filter validation",
    metadata = { path = "luamemo/test_marker.lua", line = 42 },
})
if not test_row then
    fail("write test row: " .. tostring(werr))
else
    pass("write test row succeeded, id=" .. tostring(test_row.id))

    -- Search with metadata_filter that matches.
    local rows_match = st.search({
        query           = "test symbol",
        scope           = scope,
        kind            = "symbol",
        metadata_filter = { path = "luamemo/test_marker.lua" },
        limit           = 5,
        skip_temporal   = true,
        skip_observations = true,
    })
    if rows_match and #rows_match > 0 then
        pass("metadata_filter: matching filter returns rows (" .. #rows_match .. ")")
    else
        fail("metadata_filter: matching filter returned 0 rows")
    end

    -- Search with metadata_filter that does NOT match.
    local rows_no = st.search({
        query           = "test symbol",
        scope           = scope,
        kind            = "symbol",
        metadata_filter = { path = "nonexistent/path.lua" },
        limit           = 5,
        skip_temporal   = true,
        skip_observations = true,
    })
    if not rows_no or #rows_no == 0 then
        pass("metadata_filter: non-matching filter returns 0 rows")
    else
        fail("metadata_filter: non-matching filter returned " .. #rows_no .. " rows (expected 0)")
    end

    -- Clean up the test row.
    st.delete(test_row.id)
end

-- ---------------------------------------------------------------------------
-- Test 2: store.delete_where()
-- ---------------------------------------------------------------------------
io.write("\n--- Test 2: store.delete_where ---\n")

-- Write 3 rows with a specific path.
local del_path = "luamemo/del_test.lua"
local ids = {}
for i = 1, 3 do
    local r, e = st.write({
        scope    = scope,
        kind     = "symbol",
        title    = "del.sym" .. i,
        body     = "delete_where test symbol " .. i,
        metadata = { path = del_path, line = i },
    })
    if r then ids[#ids + 1] = r.id end
    if e then fail("write del_test row " .. i .. ": " .. tostring(e)) end
end

if #ids == 3 then
    pass("wrote 3 rows for delete_where test")

    -- Delete them by metadata_filter.
    local n, derr = st.delete_where({ scope = scope, metadata_filter = { path = del_path } })
    if derr then
        fail("delete_where returned error: " .. tostring(derr))
    elseif n and n >= 3 then
        pass("delete_where deleted " .. n .. " rows (expected ≥3)")
    else
        fail("delete_where returned count=" .. tostring(n) .. " (expected ≥3)")
    end

    -- Verify they're gone.
    local remaining = st.search({
        query           = "delete_where test",
        scope           = scope,
        metadata_filter = { path = del_path },
        limit           = 10,
        skip_temporal   = true,
        skip_observations = true,
    })
    if not remaining or #remaining == 0 then
        pass("delete_where: rows confirmed deleted from DB")
    else
        fail("delete_where: " .. #remaining .. " rows still present after delete")
    end
else
    fail("could not write all 3 del_test rows")
end

-- ---------------------------------------------------------------------------
-- Test 3: Full ingest
-- ---------------------------------------------------------------------------
io.write("\n--- Test 3: index.ingest ---\n")

local ingest_result, ierr = luamemo.index.ingest(root, {
    scope           = scope,
    exclude_patterns = { ".git", "vendor/", "node_modules/", "eval/", "examples/" },
    progress_fn     = function(rel, syms, done, total)
        if done % 10 == 0 or done == total then
            io.write(("  [%d/%d] %s → %d symbols\n"):format(done, total, rel, syms))
            io.flush()
        end
    end,
})

if not ingest_result then
    fail("index.ingest failed: " .. tostring(ierr))
else
    pass("index.ingest completed without fatal error")
    info(("ingest: files=%d symbols=%d deps=%d errors=%d"):format(
        ingest_result.files, ingest_result.symbols,
        ingest_result.requires, #ingest_result.errors))

    if #ingest_result.errors == 0 then
        pass("ingest: 0 file-level errors")
    else
        fail("ingest: " .. #ingest_result.errors .. " file errors")
        for _, e in ipairs(ingest_result.errors) do io.write("  " .. e .. "\n") end
    end

    assert_ge(ingest_result.files,   10, "ingest: files >= 10")
    assert_ge(ingest_result.symbols, 50, "ingest: symbols >= 50")
end

-- ---------------------------------------------------------------------------
-- Test 4: Symbols visible via index.search()
-- ---------------------------------------------------------------------------
io.write("\n--- Test 4: index.search ---\n")

local search_res, serr = luamemo.index.search("embed", {
    scope = scope,
    kind  = "symbol",
    limit = 10,
})
if not search_res then
    fail("index.search failed: " .. tostring(serr))
elseif #search_res > 0 then
    pass("index.search 'embed' returns " .. #search_res .. " symbol rows")
    info("top result: " .. (search_res[1].title or "?"))
else
    fail("index.search 'embed' returned 0 results")
end

-- Search for a known function by name.
local search_write, _ = luamemo.index.search("store write memory", { scope = scope, limit = 10 })
if search_write and #search_write > 0 then
    pass("index.search 'store write memory' returns results")
else
    fail("index.search 'store write memory' returned 0 results")
end

-- ---------------------------------------------------------------------------
-- Test 5: index.status()
-- ---------------------------------------------------------------------------
io.write("\n--- Test 5: index.status ---\n")

local counts, cerr = luamemo.index.status({ scope = scope })
if not counts then
    fail("index.status failed: " .. tostring(cerr))
else
    pass("index.status returned counts")
    info(("file=%d symbol=%d dependency=%d diff=%d"):format(
        counts.file or 0, counts.symbol or 0,
        counts.dependency or 0, counts.diff or 0))
    assert_ge(counts.file   or 0, 10, "status: file rows >= 10")
    assert_ge(counts.symbol or 0, 50, "status: symbol rows >= 50")
end

-- ---------------------------------------------------------------------------
-- Test 6: Idempotency — re-running ingest produces same count
-- ---------------------------------------------------------------------------
io.write("\n--- Test 6: Idempotency ---\n")

local count_before = counts and counts.symbol or 0

local ingest2, ierr2 = luamemo.index.ingest(root, {
    scope           = scope,
    exclude_patterns = { ".git", "vendor/", "node_modules/", "eval/", "examples/" },
})
if not ingest2 then
    fail("second ingest failed: " .. tostring(ierr2))
else
    local counts2, _ = luamemo.index.status({ scope = scope })
    local count_after = counts2 and counts2.symbol or 0
    info(("symbol rows before=%d after=%d"):format(count_before, count_after))
    assert_eq(count_before, count_after, "idempotency: symbol count unchanged after re-ingest")

    -- File count should also be stable.
    local file_before = counts and counts.file or 0
    local file_after  = counts2 and counts2.file or 0
    assert_eq(file_before, file_after, "idempotency: file count unchanged after re-ingest")
end

-- ---------------------------------------------------------------------------
-- Cleanup: wipe test scope.
-- ---------------------------------------------------------------------------
st.delete_where({ scope = scope })
info("cleaned up test scope: " .. scope)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
io.write(("\n=== Phase 2 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
