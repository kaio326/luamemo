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
-- Run: luajit eval/tests/run.lua --only index_ctags

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

    -- parse_files: one ctags run per M.BATCH files (it was one per file — a process
    -- start each), the same symbols per file as parse_file. Counted through a wrapper
    -- on PATH that logs each run.
    io.write("\n--- Test 2b: ctags.parse_files (batched) ---\n")
    local tmp = os.tmpname(); os.remove(tmp)
    local real = (io.popen("command -v ctags"):read("*l"))
    os.execute(("mkdir -p %s/bin %s/src"):format(tmp, tmp))
    local w = assert(io.open(tmp .. "/bin/ctags", "w"))
    w:write(("#!/bin/sh\necho run >> %s/runs\nexec %s \"$@\"\n"):format(tmp, real)); w:close()
    os.execute("chmod +x " .. tmp .. "/bin/ctags")
    local files = {}
    for i = 1, 5 do
        local p = ("%s/src/f%d.go"):format(tmp, i)
        local f = assert(io.open(p, "w"))
        f:write(("package p\n\nfunc F%d() int { return %d }\n\ntype T%d struct{}\n"):format(i, i, i)); f:close()
        files[i] = { path = p, rel = ("f%d.go"):format(i) }
    end
    local ffi = require("ffi"); pcall(ffi.cdef, "int setenv(const char*, const char*, int);")
    local old_path = os.getenv("PATH")
    ffi.C.setenv("PATH", tmp .. "/bin:" .. old_path, 1)
    local batch = ctags.parse_files(files)
    local runs_batch = select(2, (io.open(tmp .. "/runs"):read("*a")):gsub("run", ""))
    local saved = ctags.BATCH
    ctags.BATCH = 2
    local small = ctags.parse_files(files)
    ctags.BATCH = saved
    ffi.C.setenv("PATH", old_path, 1)
    local same = true
    for i, f in ipairs(files) do
        local b, s = names(batch[f.path]), names(small[f.path])
        same = same and b["F" .. i] == "function" and b["T" .. i] == "class" and s["F" .. i] == "function"
            and #batch[f.path].symbols == 2 and batch[f.path].symbols[1].path == f.rel
    end
    ok(runs_batch == 1, "parse_files: 5 files → one ctags run (got " .. tostring(runs_batch) .. ")")
    ok(same, "parse_files: each file's own symbols, its rel path; any batch size gives the same")
    os.execute("rm -rf " .. tmp)
else
    info("ctags absent → skipping direct-parse assertions")
end

-- ---------------------------------------------------------------------------
-- DB-backed merge-policy tests
-- ---------------------------------------------------------------------------
local db_name = os.getenv("MEMO_DB")
if not db_name or db_name == "" then
    io.stderr:write("[SKIP] MEMO_DB not set — DB tests skipped\n")
    io.write(("\n=== Phase 11 results: %d passed, %d failed (no DB) ===\n"):format(PASS, FAIL))
    os.exit(FAIL > 0 and 1 or 0)
end

local luamemo = require("luamemo")
assert(pcall(luamemo.setup, { embedder_local = os.getenv("MEMO_EMBEDDER") or "hash" }))
local db, index = require("luamemo.db"), luamemo.index
local scope = "codeindex:test_ctags"

local function sym_count(path)
    return tonumber(db.value("SELECT COUNT(*) FROM lm_memories WHERE scope = ? AND kind = 'symbol' "
        .. "AND json_extract(metadata, '$.path') = ?", scope, path)) or 0
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
