-- eval/tests/test_index_agentmap.lua
-- Phase 8 exit criteria:
--   1. format.lua renders compact, correct lines (symbol/file/results/outline/explore)
--   2. index.outline(path) returns the file row + all symbols, ordered by line
--   3. Compact output is >=50% smaller (bytes) than the equivalent full-JSON rows
--   4. Formatter degrades gracefully on missing fields / empty inputs
--
-- Pure formatter tests need no DB. The outline round-trip + size check need MEMO_DB_URL.
-- Run: lua5.1 eval/tests/test_index_agentmap.lua

package.path = "./?/init.lua;./?.lua;" .. package.path

local PASS, FAIL = 0, 0
local function pass(m) PASS = PASS + 1; io.write("[PASS] " .. m .. "\n") end
local function fail(m) FAIL = FAIL + 1; io.write("[FAIL] " .. m .. "\n") end
local function info(m) io.write("[INFO] " .. m .. "\n") end
local function ok(cond, m) if cond then pass(m) else fail(m) end end

local fmt  = require("luamemo.index.format")
local json = require("luamemo.json")

-- ---------------------------------------------------------------------------
-- Test 1: formatter unit tests (pure)
-- ---------------------------------------------------------------------------
io.write("\n--- Test 1: format.lua units ---\n")

local sym_doc = { kind = "symbol", title = "luamemo.store.write",
    body = "Returns (row, err, action) where action is inserted. — function luamemo.store.write(1 args)",
    metadata = { path = "luamemo/store.lua", line = 392, symbol_type = "function", exported = true } }
local sym_nodoc = { kind = "symbol", title = "luamemo.store._probe",
    body = "function luamemo.store._probe(1 args)",
    metadata = { path = "luamemo/store.lua", line = 74, symbol_type = "function" } }
local file_row = { kind = "file", title = "luamemo/store.lua",
    body = "luamemo/store.lua — local M = {}", metadata = { path = "luamemo/store.lua", lines = 1712 } }

local sl = fmt.symbol_line(sym_doc)
ok(sl:find("luamemo/store.lua:392", 1, true) ~= nil, "symbol_line has path:line")
ok(sl:find("(function)", 1, true) ~= nil, "symbol_line has (type)")
ok(sl:find("Returns %(row", 1) ~= nil, "symbol_line keeps docstring")
ok(sl:find("— function luamemo", 1, true) == nil, "symbol_line strips generated signature tail")

local sl2 = fmt.symbol_line(sym_nodoc)
ok(sl2:find("luamemo/store.lua:74", 1, true) ~= nil, "no-doc symbol_line has location")
ok(sl2:find(" — ", 1, true) == nil, "no-doc symbol_line has no dangling em-dash")

ok(fmt.file_line(file_row):find("1712 lines", 1, true) ~= nil, "file_line shows line count")

-- Doc clipping
local long = { kind = "symbol", title = "x.y",
    body = string.rep("word ", 60) .. "— function x.y(0 args)",
    metadata = { path = "a.lua", line = 1, symbol_type = "function" } }
local ll = fmt.symbol_line(long)
ok(#ll < 200, "long docstring clipped (" .. #ll .. " chars)")
ok(ll:sub(-3) == "…", "clipped line ends with ellipsis")

-- results / outline / explore
ok(fmt.results({}) == "(no matches)", "empty results → (no matches)")
local res = fmt.results({ sym_doc, file_row })
ok(select(2, res:gsub("\n", "\n")) == 1, "results joins rows with newline")

local outline = fmt.outline(file_row, { sym_doc, sym_nodoc })
ok(outline:find("2 symbols", 1, true) ~= nil, "outline header counts symbols")
ok(outline:find("\n  luamemo/store.lua:392", 1, true) ~= nil, "outline indents symbol lines")
ok(fmt.outline(nil, {}):find("not indexed", 1, true) ~= nil, "outline(nil) → not indexed")

local exp = fmt.explore({ matched = { sym_doc }, callers = { sym_nodoc }, callees = {} })
ok(exp:find("matched (1):", 1, true) ~= nil, "explore has matched section")
ok(exp:find("callers", 1, true) ~= nil, "explore has callers section")
ok(exp:find("callees", 1, true) == nil, "explore omits empty callees section")

-- Missing-metadata robustness
ok(fmt.symbol_line({ kind = "symbol", title = "x" }):find("?", 1, true) ~= nil,
   "symbol_line tolerates missing metadata")

-- ---------------------------------------------------------------------------
-- DB-backed: outline round-trip + payload size
-- ---------------------------------------------------------------------------
local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    io.stderr:write("[SKIP] MEMO_DB_URL not set — DB tests skipped\n")
    io.write(("\n=== Phase 8 results: %d passed, %d failed (format only) ===\n"):format(PASS, FAIL))
    os.exit(FAIL > 0 and 1 or 0)
end

local luamemo = require("luamemo")
local cfg = { db_url = db_url, auth_fn = function() return true end,
              embedder_local = os.getenv("MEMO_EMBEDDER") or "hash" }
local ed = tonumber(os.getenv("MEMO_EMBED_DIM")); if ed then cfg.embed_dim = ed end
assert(pcall(luamemo.setup, cfg))
info("luamemo setup OK")

local scope = "codeindex:test_agentmap"
local st, db = luamemo.store, require("luamemo.db")
st.delete_where({ scope = scope })
db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))

luamemo.index.ingest("eval/fixtures/multilang", { scope = scope })

-- Test 2: outline round-trip
io.write("\n--- Test 2: index.outline round-trip ---\n")
local o, oerr = luamemo.index.outline("sample.py", { scope = scope })
ok(o ~= nil, "outline returns a result (" .. tostring(oerr) .. ")")
if o then
    ok(o.file ~= nil, "outline includes the file row")
    ok(#o.symbols == 8, "outline returns all 8 sample.py symbols (got " .. #o.symbols .. ")")
    -- ordered by line
    local ordered = true
    for i = 2, #o.symbols do
        local a = tonumber(o.symbols[i-1].metadata and o.symbols[i-1].metadata.line)
        local b = tonumber(o.symbols[i].metadata and o.symbols[i].metadata.line)
        if a and b and a > b then ordered = false end
    end
    ok(ordered, "outline symbols ordered by line")
end
-- missing file
local o2 = luamemo.index.outline("does_not_exist.py", { scope = scope })
ok(o2 and o2.file == nil and #o2.symbols == 0, "outline of missing file → file=nil, 0 symbols")
-- empty path guarded
ok(select(1, luamemo.index.outline("", { scope = scope })) == nil, "outline('') errors")

-- Test 3: payload size — compact vs full JSON
io.write("\n--- Test 3: compact output <=50% of JSON ---\n")
local rows = luamemo.index.search("function", { scope = scope, kind = "symbol", limit = 15 })
ok(rows and #rows > 0, "search returned rows for size comparison (" .. tostring(rows and #rows) .. ")")
if rows and #rows > 0 then
    local json_bytes    = #json.encode(rows)
    local compact_bytes = #fmt.results(rows)
    local ratio = compact_bytes / json_bytes
    info(("json=%d bytes  compact=%d bytes  ratio=%.2f"):format(json_bytes, compact_bytes, ratio))
    ok(ratio <= 0.5, ("compact output is <=50%% of full JSON (%.0f%%)"):format(ratio * 100))
end

-- cleanup
st.delete_where({ scope = scope })
db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))
info("cleaned up scope")

io.write(("\n=== Phase 8 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
