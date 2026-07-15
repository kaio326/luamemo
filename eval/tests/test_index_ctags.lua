-- eval/tests/test_index_ctags.lua
-- Phase 11 exit criteria:
--   1. ctags.available()/handles() gate correctly (code exts only; opt-out honoured)
--   2. With ctags: .go/.rs files yield correct symbol rows (name, line, kind)
--   3. Native parser still wins for lua/py/js (ctags never overrides them)
--   4. Without ctags (opt-out): non-native code gets 0 symbols; native unchanged
--      — i.e. behaviour is identical to pre-Phase-11 (graceful no-op)
--
-- ctags is OPTIONAL. When the binary is absent this test SKIPS the "present"
-- assertions and only verifies the graceful-absence path.
-- Run: lua5.1 eval/tests/test_index_ctags.lua

package.path = "./?/init.lua;./?.lua;" .. package.path

local PASS, FAIL = 0, 0
local function pass(m) PASS = PASS + 1; io.write("[PASS] " .. m .. "\n") end
local function fail(m) FAIL = FAIL + 1; io.write("[FAIL] " .. m .. "\n") end
local function info(m) io.write("[INFO] " .. m .. "\n") end
local function ok(c, m) if c then pass(m) else fail(m) end end

local ctags = require("luamemo.index.ctags")
local have_ctags = ctags.available()
info("ctags available: " .. tostring(have_ctags))

-- ---------------------------------------------------------------------------
-- Test 1: gating (pure, always runs)
-- ---------------------------------------------------------------------------
io.write("\n--- Test 1: handles() gating ---\n")
if have_ctags then
    ok(ctags.handles("a/x.go") == true,  "handles .go")
    ok(ctags.handles("a/x.rs") == true,  "handles .rs")
end
ok(ctags.handles("a/x.lua") == false, "does NOT handle .lua (native parser owns it)")
ok(ctags.handles("a/x.md")  == false, "does NOT handle .md (avoids doc/data noise)")
ok(ctags.handles("a/x.json") == false, "does NOT handle .json")

-- ---------------------------------------------------------------------------
-- Test 2: direct parse (only when present)
-- ---------------------------------------------------------------------------
if have_ctags then
    io.write("\n--- Test 2: ctags.parse_file (.go/.rs) ---\n")
    -- Key by bare name: ctags full_name carries the language scope
    -- (e.g. Go package "payments.Refund"), which the ingest path replaces with a
    -- path-derived module. Assert on name + type, which are stable.
    local function names(res)
        local s = {}
        for _, sym in ipairs(res.symbols) do s[sym.name] = sym.symbol_type end
        return s
    end
    local go = names(ctags.parse_file("eval/fixtures/ctags/sample.go", "sample.go"))
    ok(go["Refund"] == "class",       "go: struct Refund → class")
    ok(go["NewRefund"] == "function", "go: func NewRefund → function")
    local rs = names(ctags.parse_file("eval/fixtures/ctags/sample.rs", "sample.rs"))
    ok(rs["Session"] == "class",      "rust: struct Session → class")
    ok(rs["new"] == "method",         "rust: impl fn new → method")
    ok(rs["create_session"] == "function", "rust: pub fn → function")
else
    info("ctags absent → skipping direct-parse assertions")
end

-- ---------------------------------------------------------------------------
-- DB-backed merge-policy tests
-- ---------------------------------------------------------------------------
local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    io.stderr:write("[SKIP] MEMO_DB_URL not set — DB tests skipped\n")
    io.write(("\n=== Phase 11 results: %d passed, %d failed (no DB) ===\n"):format(PASS, FAIL))
    os.exit(FAIL > 0 and 1 or 0)
end

local luamemo = require("luamemo")
assert(pcall(luamemo.setup, { db_url = db_url, embedder_local = os.getenv("MEMO_EMBEDDER") or "hash",
    auth_fn = function() return true end }))
local db, index = require("luamemo.db"), luamemo.index
local scope = "codeindex:test_ctags"

local function sym_count(path)
    local q = db.query(("SELECT COUNT(*) AS n FROM lm_memories WHERE scope=%s AND kind='symbol' AND metadata->>'path'=%s")
        :format(db.escape_literal(scope), db.escape_literal(path)))
    return q and q[1] and tonumber(q[1].n) or 0
end

-- Test 3: ingest with ctags enabled (default)
io.write("\n--- Test 3: ingest merge policy (ctags default-on) ---\n")
index.invalidate(scope)
index.ingest("eval/fixtures/ctags", { scope = scope })
ok(sym_count("helper.lua") >= 1, "native parser extracts helper.lua symbols (native wins)")
if have_ctags then
    ok(sym_count("sample.go") >= 2, "ctags extracts .go symbols (" .. sym_count("sample.go") .. ")")
    ok(sym_count("sample.rs") >= 3, "ctags extracts .rs symbols (" .. sym_count("sample.rs") .. ")")
else
    ok(sym_count("sample.go") == 0, "no ctags → .go has 0 symbols (graceful)")
end

-- Test 4: opt-out (use_ctags=false) → non-native code gets 0 symbols, native unchanged
io.write("\n--- Test 4: opt-out use_ctags=false ---\n")
index.invalidate(scope)
index.ingest("eval/fixtures/ctags", { scope = scope, use_ctags = false })
ok(sym_count("sample.go") == 0, "opt-out: .go has 0 symbols")
ok(sym_count("sample.rs") == 0, "opt-out: .rs has 0 symbols")
ok(sym_count("helper.lua") >= 1, "opt-out: native helper.lua still extracted (unchanged)")

index.invalidate(scope)
info("cleaned up scope")

io.write(("\n=== Phase 11 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
