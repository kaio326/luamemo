-- eval/tests/test_index_fileindex.lua
-- Phase 7A exit criteria (whole-repo file index):
--   1. Default ingest walks ALL text files (incl. extensionless) → file rows
--   2. Non-code files get a file row and zero symbols; code files get symbols
--   3. opts.symbols=false → file rows only, zero symbol rows anywhere
--   4. opts.extensions={lua=true} narrows the walk back to Lua only
--   5. Re-ingest is idempotent (file + symbol counts stable)
--
-- Requires MEMO_DB_URL.
-- Run: lua5.1 eval/tests/test_index_fileindex.lua

package.path = "./?/init.lua;./?.lua;" .. package.path

local PASS, FAIL = 0, 0
local function pass(m) PASS = PASS + 1; io.write("[PASS] " .. m .. "\n") end
local function fail(m) FAIL = FAIL + 1; io.write("[FAIL] " .. m .. "\n") end
local function info(m) io.write("[INFO] " .. m .. "\n") end
local function eq(a, b, label)
    if a == b then pass(label) else fail(label .. " — got " .. tostring(a) .. " expected " .. tostring(b)) end
end
local function ge(a, b, label)
    if a >= b then pass(label .. " (" .. a .. " >= " .. b .. ")")
    else fail(label .. " — got " .. tostring(a) .. " expected >= " .. tostring(b)) end
end

local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    io.stderr:write("[SKIP] MEMO_DB_URL not set\n"); os.exit(0)
end

local luamemo = require("luamemo")
local cfg = { db_url = db_url, auth_fn = function() return true end,
              embedder_local = os.getenv("MEMO_EMBEDDER") or "hash" }
local ed = tonumber(os.getenv("MEMO_EMBED_DIM")); if ed then cfg.embed_dim = ed end
local ok_setup, serr = pcall(luamemo.setup, cfg)
if not ok_setup then io.stderr:write("[ERROR] setup: " .. tostring(serr) .. "\n"); os.exit(1) end
info("luamemo setup OK")

local FIX = "eval/fixtures/multilang"
local scope = "codeindex:test_fileindex"
local st, db = luamemo.store, require("luamemo.db")

local function wipe()
    st.delete_where({ scope = scope })
    db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))
end

local function count(kind)
    local r = db.query(("SELECT COUNT(*) AS n FROM lm_memories WHERE scope=%s AND kind=%s")
        :format(db.escape_literal(scope), db.escape_literal(kind)))
    return r and r[1] and tonumber(r[1].n) or 0
end

local function file_exists(path)
    local r = db.query(("SELECT COUNT(*) AS n FROM lm_memories WHERE scope=%s AND kind='file' AND metadata->>'path'=%s")
        :format(db.escape_literal(scope), db.escape_literal(path)))
    return (r and r[1] and tonumber(r[1].n) or 0) > 0
end

wipe()
info("wiped scope before test")

-- ---------------------------------------------------------------------------
-- Test 1: Default ingest = whole-repo file index
-- ---------------------------------------------------------------------------
io.write("\n--- Test 1: whole-repo default ---\n")

local res, ierr = luamemo.index.ingest(FIX, { scope = scope })
if not res then
    fail("ingest failed: " .. tostring(ierr))
    wipe(); io.write(("\n=== Phase 7A results: %d passed, %d failed ===\n"):format(PASS, FAIL)); os.exit(1)
end
info(("ingest: files=%d symbols=%d"):format(res.files, res.symbols))

-- Fixture dir has: sample.py, sample.js, helper.lua, notes.md, config.json, Dockerfile = 6 files.
ge(count("file"), 6, "file rows for all text files (incl. extensionless Dockerfile)")
for _, p in ipairs({ "sample.py", "sample.js", "helper.lua", "notes.md", "config.json", "Dockerfile" }) do
    if file_exists(p) then pass("file row present: " .. p) else fail("file row MISSING: " .. p) end
end

-- Code files contribute symbols; non-code files do not.
ge(count("symbol"), 10, "symbols extracted from code files")

-- ---------------------------------------------------------------------------
-- Test 2: opts.symbols=false → file index only
-- ---------------------------------------------------------------------------
io.write("\n--- Test 2: symbols=false (file index only) ---\n")
wipe()
local res2 = luamemo.index.ingest(FIX, { scope = scope, symbols = false })
if res2 then
    info(("ingest(symbols=false): files=%d symbols=%d"):format(res2.files, res2.symbols))
    ge(count("file"), 6, "file-only mode still writes file rows")
    eq(count("symbol"), 0, "file-only mode writes ZERO symbol rows")
    eq(count("dependency"), 0, "file-only mode writes ZERO dependency rows")
else
    fail("ingest(symbols=false) failed")
end

-- ---------------------------------------------------------------------------
-- Test 3: extensions override narrows the walk
-- ---------------------------------------------------------------------------
io.write("\n--- Test 3: extensions={lua=true} narrows walk ---\n")
wipe()
local res3 = luamemo.index.ingest(FIX, { scope = scope, extensions = { lua = true } })
if res3 then
    info(("ingest(lua only): files=%d symbols=%d"):format(res3.files, res3.symbols))
    eq(count("file"), 1, "lua-only walk indexes exactly 1 file (helper.lua)")
    if file_exists("helper.lua") and not file_exists("sample.py") then
        pass("lua-only walk excludes .py/.js/.md")
    else
        fail("lua-only walk did not narrow correctly")
    end
    ge(count("symbol"), 1, "lua-only walk still extracts helper.lua symbols")
else
    fail("ingest(lua only) failed")
end

-- ---------------------------------------------------------------------------
-- Test 4: Idempotency under whole-repo default
-- ---------------------------------------------------------------------------
io.write("\n--- Test 4: idempotency ---\n")
wipe()
luamemo.index.ingest(FIX, { scope = scope })
local f1, s1 = count("file"), count("symbol")
luamemo.index.ingest(FIX, { scope = scope })
local f2, s2 = count("file"), count("symbol")
info(("before: files=%d symbols=%d  after: files=%d symbols=%d"):format(f1, s1, f2, s2))
eq(f1, f2, "idempotency: file count stable across re-ingest")
eq(s1, s2, "idempotency: symbol count stable across re-ingest")

wipe()
info("cleaned up scope")

io.write(("\n=== Phase 7A results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
