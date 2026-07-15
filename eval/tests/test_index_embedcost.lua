-- eval/tests/test_index_embedcost.lua
-- Phase 10 exit criteria:
--   1. File rows are FTS-only (NULL embedding) by default; symbols/deps embedded
--   2. file_row_embeddings=true restores file-row vectors
--   3. File-row body is enriched (split path words + "defines: <names>")
--   4. Hybrid search finds a NULL-embedding file row at scale (>50 rows) — the
--      core fix: candidate pool = vector-nearest UNION fts-top
--   5. Ranking safety: a NULL-embedding row does NOT wrongly dominate an
--      unrelated query (COALESCE gives it a real 0 vector score, not NULL)
--   6. util.cosine is NULL-safe (bruteforce path relies on this)
--
-- Requires MEMO_DB_URL.
-- Run: lua5.1 eval/tests/test_index_embedcost.lua

package.path = "./?/init.lua;./?.lua;" .. package.path

local PASS, FAIL = 0, 0
local function pass(m) PASS = PASS + 1; io.write("[PASS] " .. m .. "\n") end
local function fail(m) FAIL = FAIL + 1; io.write("[FAIL] " .. m .. "\n") end
local function info(m) io.write("[INFO] " .. m .. "\n") end
local function ok(c, m) if c then pass(m) else fail(m) end end

-- Test 6 (pure): util.cosine NULL-safety — no DB needed.
io.write("\n--- Test 6: util.cosine NULL-safety ---\n")
local util = require("luamemo.util")
ok(util.cosine(nil, {1,2,3}) == 0, "cosine(nil, vec) = 0")
ok(util.cosine({1,2,3}, nil) == 0, "cosine(vec, nil) = 0")

local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    io.stderr:write("[SKIP] MEMO_DB_URL not set — DB tests skipped\n")
    io.write(("\n=== Phase 10 results: %d passed, %d failed (pure only) ===\n"):format(PASS, FAIL))
    os.exit(FAIL > 0 and 1 or 0)
end

local luamemo = require("luamemo")
assert(pcall(luamemo.setup, { db_url = db_url, embedder_local = os.getenv("MEMO_EMBEDDER") or "hash",
    auth_fn = function() return true end }))
local store, db, index = luamemo.store, require("luamemo.db"), luamemo.index

local function nrows(scope, kind, extra)
    local q = "SELECT COUNT(*) AS n FROM lm_memories WHERE scope = " .. db.escape_literal(scope)
    if kind then q = q .. " AND kind = " .. db.escape_literal(kind) end
    if extra then q = q .. " AND " .. extra end
    local r = db.query(q)
    return r and r[1] and tonumber(r[1].n) or 0
end

-- ---------------------------------------------------------------------------
-- Test 1 + 3: default ingest → file rows NULL-embedded + enriched body
-- ---------------------------------------------------------------------------
io.write("\n--- Test 1+3: default FTS-only file rows + enriched body ---\n")
local scope = "codeindex:test_embedcost"
index.invalidate(scope)
index.ingest("eval/fixtures/multilang", { scope = scope })

local files      = nrows(scope, "file")
local files_null = nrows(scope, "file", "embedding IS NULL")
local syms       = nrows(scope, "symbol")
local syms_embed = nrows(scope, "symbol", "embedding IS NOT NULL")
info(("files=%d (null=%d)  symbols=%d (embedded=%d)"):format(files, files_null, syms, syms_embed))
ok(files > 0 and files_null == files, "all file rows have NULL embedding by default")
ok(syms > 0 and syms_embed == syms, "all symbol rows are embedded")

local b = db.query(("SELECT body FROM lm_memories WHERE scope=%s AND kind='file' AND metadata->>'path'='sample.py'")
    :format(db.escape_literal(scope)))
local body = b and b[1] and b[1].body or ""
ok(body:find("defines:", 1, true) ~= nil, "file body lists defined symbols")
ok(body:find("make_dog", 1, true) ~= nil, "file body includes a symbol name (make_dog)")

-- ---------------------------------------------------------------------------
-- Test 2: file_row_embeddings=true restores vectors
-- ---------------------------------------------------------------------------
io.write("\n--- Test 2: opt back in with file_row_embeddings ---\n")
index.invalidate(scope)
index.ingest("eval/fixtures/multilang", { scope = scope, file_row_embeddings = true })
local files_embed = nrows(scope, "file", "embedding IS NOT NULL")
ok(nrows(scope, "file") > 0 and files_embed == nrows(scope, "file"),
   "file rows are embedded when file_row_embeddings=true")
index.invalidate(scope)

-- ---------------------------------------------------------------------------
-- Test 4 + 5: hybrid search at scale — findable + no false domination
-- ---------------------------------------------------------------------------
io.write("\n--- Test 4+5: hybrid search at scale (>50 rows) ---\n")
local sc = "test_embedcost_scale"
store.delete_where({ scope = sc })
local rows = {}
for i = 1, 80 do
    rows[i] = { scope = sc, kind = "symbol", title = "func" .. i,
                body = "handles data processing routine item " .. i }
end
rows[81] = { scope = sc, kind = "file", title = "src/payments/refund.lua",
    body = "src/payments/refund.lua — defines processRefund issueChargeback", no_embed = true }
store.write_many(rows, { dedup_strategy = "append" })
info("scope has 81 rows (80 embedded symbols + 1 NULL-embedding file row)")

-- Test 4: the file row is findable via a matching FTS token, fts-heavy weights.
local res = store.search({ query = "processRefund", scope = sc, limit = 90,
    hybrid_weights = { vector = 0.3, fts = 0.7 }, skip_temporal = true, skip_observations = true })
local file_rank
for i, r in ipairs(res or {}) do if r.kind == "file" then file_rank = i; break end end
ok(file_rank ~= nil, "NULL-embedding file row is in results at scale (was unfindable pre-fix)")
ok(file_rank == 1, "file row ranks #1 for its distinctive term under fts-heavy weights")

-- Test 5: an unrelated query must NOT rank the file row first (no NULL-domination).
local res2 = store.search({ query = "data processing routine", scope = sc, limit = 5,
    skip_temporal = true, skip_observations = true })
ok(res2[1] and res2[1].kind == "symbol",
   "unrelated query ranks a real match first, not the NULL-embedding file row")
store.delete_where({ scope = sc })

io.write(("\n=== Phase 10 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
