-- eval/tests/test_index_multilang.lua
-- Phase 7B exit criteria:
--   1. parser dispatches by extension to the right sub-parser
--   2. Python parser extracts def/async def/class with qualified method names,
--      docstrings, exported flags, and import dependency edges
--   3. JavaScript parser extracts function/const-arrow/class/method and
--      import/require dependency edges
--   4. A DB ingest of a mixed-language dir writes symbol rows for .py/.js/.lua
--
-- Pure-parser tests need no DB. The ingest round-trip needs MEMO_DB_URL.
-- Run: lua5.1 eval/tests/test_index_multilang.lua

package.path = "./?/init.lua;./?.lua;" .. package.path

local PASS, FAIL = 0, 0
local function pass(m) PASS = PASS + 1; io.write("[PASS] " .. m .. "\n") end
local function fail(m) FAIL = FAIL + 1; io.write("[FAIL] " .. m .. "\n") end
local function info(m) io.write("[INFO] " .. m .. "\n") end

local FIX = "eval/fixtures/multilang"

-- Find a symbol by full_name in a parse result.
local function find(syms, full_name)
    for _, s in ipairs(syms) do
        if s.full_name == full_name then return s end
    end
    return nil
end

-- Count symbols of a given symbol_type.
local function count_type(syms, t)
    local n = 0
    for _, s in ipairs(syms) do if s.symbol_type == t then n = n + 1 end end
    return n
end

-- Does requires contain a module?
local function has_req(reqs, mod)
    for _, r in ipairs(reqs) do if r.module == mod then return true end end
    return false
end

local parser = require("luamemo.index.parser")

-- ---------------------------------------------------------------------------
-- Test 1: dispatcher routing
-- ---------------------------------------------------------------------------
io.write("\n--- Test 1: dispatcher routing ---\n")

local exts = parser.supported_extensions()
local exts_str = table.concat(exts, ",")
if exts_str:find("lua") and exts_str:find("py") and exts_str:find("js") and exts_str:find("ts") then
    pass("supported_extensions includes lua, py, js, ts: " .. exts_str)
else
    fail("supported_extensions missing a language: " .. exts_str)
end

if parser.has_parser("a/b.py") and parser.has_parser("a/b.js")
   and parser.has_parser("a/b.lua") and not parser.has_parser("a/b.md")
   and not parser.has_parser("a/b.json") then
    pass("has_parser: true for py/js/lua, false for md/json")
else
    fail("has_parser routing incorrect")
end

-- ---------------------------------------------------------------------------
-- Test 2: Python parser
-- ---------------------------------------------------------------------------
io.write("\n--- Test 2: Python parser ---\n")

local rpy, perr = parser.parse_file(FIX .. "/sample.py")
if not rpy then
    fail("parse_file(sample.py): " .. tostring(perr))
else
    info(("python: %d symbols, %d requires"):format(#rpy.symbols, #rpy.requires))

    -- Classes: Animal, Dog
    if count_type(rpy.symbols, "class") == 2 then pass("python: 2 classes")
    else fail("python: expected 2 classes, got " .. count_type(rpy.symbols, "class")) end

    -- Methods: Animal.__init__, Animal.speak, Animal._private_helper, Dog.speak
    if count_type(rpy.symbols, "method") == 4 then pass("python: 4 methods")
    else fail("python: expected 4 methods, got " .. count_type(rpy.symbols, "method")) end

    -- Functions: make_dog, fetch_all
    if count_type(rpy.symbols, "function") == 2 then pass("python: 2 functions")
    else fail("python: expected 2 functions, got " .. count_type(rpy.symbols, "function")) end

    -- Qualified method name.
    if find(rpy.symbols, "Animal.speak") then pass("python: Animal.speak qualified method present")
    else fail("python: Animal.speak missing") end
    if find(rpy.symbols, "Dog.speak") then pass("python: Dog.speak qualified method present")
    else fail("python: Dog.speak missing") end

    -- async def captured as function.
    if find(rpy.symbols, "fetch_all") then pass("python: async def fetch_all captured")
    else fail("python: async def fetch_all missing") end

    -- Exported flag: private method not exported.
    local priv = find(rpy.symbols, "Animal._private_helper")
    if priv and priv.exported == false then pass("python: _private_helper not exported")
    else fail("python: _private_helper exported flag wrong") end

    -- Docstring extraction.
    local md = find(rpy.symbols, "make_dog")
    if md and md.docstring:find("Create a dog") then pass("python: make_dog docstring extracted")
    else fail("python: make_dog docstring missing (" .. (md and md.docstring or "nil") .. ")") end

    -- Class docstring.
    local an = find(rpy.symbols, "Animal")
    if an and an.docstring:find("animal that can speak") then pass("python: class docstring extracted")
    else fail("python: Animal class docstring missing") end

    -- Imports → requires.
    if has_req(rpy.requires, "os") and has_req(rpy.requires, "collections") then
        pass("python: import os + from collections captured as requires")
    else
        fail("python: import requires missing")
    end
end

-- ---------------------------------------------------------------------------
-- Test 3: JavaScript parser
-- ---------------------------------------------------------------------------
io.write("\n--- Test 3: JavaScript parser ---\n")

local rjs, jerr = parser.parse_file(FIX .. "/sample.js")
if not rjs then
    fail("parse_file(sample.js): " .. tostring(jerr))
else
    info(("javascript: %d symbols, %d requires"):format(#rjs.symbols, #rjs.requires))

    -- function add, const multiply → functions
    if find(rjs.symbols, "add") and find(rjs.symbols, "add").symbol_type == "function" then
        pass("js: function add captured")
    else fail("js: function add missing") end

    local mul = find(rjs.symbols, "multiply")
    if mul and mul.symbol_type == "function" then pass("js: const arrow multiply captured as function")
    else fail("js: const arrow multiply missing") end

    -- class Calculator + methods
    if find(rjs.symbols, "Calculator") and find(rjs.symbols, "Calculator").symbol_type == "class" then
        pass("js: class Calculator captured")
    else fail("js: class Calculator missing") end

    if find(rjs.symbols, "Calculator.constructor") then pass("js: Calculator.constructor method")
    else fail("js: Calculator.constructor missing") end
    if find(rjs.symbols, "Calculator.add") then pass("js: Calculator.add method")
    else fail("js: Calculator.add missing") end
    if find(rjs.symbols, "Calculator.reset") then pass("js: async Calculator.reset method")
    else fail("js: Calculator.reset missing") end

    -- export flag.
    local addsym = find(rjs.symbols, "add")
    if addsym and addsym.exported == true then pass("js: exported function flagged exported")
    else fail("js: export flag wrong on add") end

    -- JSDoc / line-comment docstring.
    if addsym and addsym.docstring:find("Adds two numbers") then pass("js: line-comment docstring extracted")
    else fail("js: add docstring missing (" .. (addsym and addsym.docstring or "nil") .. ")") end

    -- import/require → requires.
    if has_req(rjs.requires, "react") and has_req(rjs.requires, "fs") then
        pass("js: import 'react' + require('fs') captured")
    else fail("js: import/require deps missing") end
end

-- ---------------------------------------------------------------------------
-- Test 4: DB ingest round-trip (mixed-language dir)
-- ---------------------------------------------------------------------------
local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    io.stderr:write("[SKIP] MEMO_DB_URL not set — ingest round-trip skipped\n")
    io.write(("\n=== Phase 7B results: %d passed, %d failed (parser only) ===\n"):format(PASS, FAIL))
    os.exit(FAIL > 0 and 1 or 0)
end

io.write("\n--- Test 4: DB ingest round-trip ---\n")

local luamemo = require("luamemo")
local cfg = { db_url = db_url, auth_fn = function() return true end,
              embedder_local = os.getenv("MEMO_EMBEDDER") or "hash" }
local ed = tonumber(os.getenv("MEMO_EMBED_DIM")); if ed then cfg.embed_dim = ed end
local ok_setup, serr = pcall(luamemo.setup, cfg)
if not ok_setup then
    io.stderr:write("[ERROR] setup failed: " .. tostring(serr) .. "\n"); os.exit(1)
end

local scope = "codeindex:test_multilang"
local st, db = luamemo.store, require("luamemo.db")
st.delete_where({ scope = scope })
db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))

local res, ierr = luamemo.index.ingest(FIX, { scope = scope })
if not res then
    fail("ingest failed: " .. tostring(ierr))
else
    info(("ingest: files=%d symbols=%d requires=%d errors=%d"):format(
        res.files, res.symbols, res.requires, #res.errors))
    pass("ingest of mixed-language dir completed")

    -- Symbol rows for each language by path.
    local function nsym(path)
        local r = db.query(("SELECT COUNT(*) AS n FROM lm_memories WHERE scope=%s AND kind='symbol' AND metadata->>'path'=%s")
            :format(db.escape_literal(scope), db.escape_literal(path)))
        return r and r[1] and tonumber(r[1].n) or 0
    end
    if nsym("sample.py") >= 6 then pass("ingest: sample.py symbol rows >= 6") else fail("ingest: sample.py symbols=" .. nsym("sample.py")) end
    if nsym("sample.js") >= 4 then pass("ingest: sample.js symbol rows >= 4") else fail("ingest: sample.js symbols=" .. nsym("sample.js")) end
    if nsym("helper.lua") >= 1 then pass("ingest: helper.lua symbol rows >= 1") else fail("ingest: helper.lua symbols=" .. nsym("helper.lua")) end

    -- Non-code files: file row present, zero symbols.
    local function nfile(path)
        local r = db.query(("SELECT COUNT(*) AS n FROM lm_memories WHERE scope=%s AND kind='file' AND metadata->>'path'=%s")
            :format(db.escape_literal(scope), db.escape_literal(path)))
        return r and r[1] and tonumber(r[1].n) or 0
    end
    if nfile("notes.md") == 1 and nsym("notes.md") == 0 then pass("ingest: notes.md file row, 0 symbols")
    else fail("ingest: notes.md file=" .. nfile("notes.md") .. " sym=" .. nsym("notes.md")) end
    if nfile("config.json") == 1 and nsym("config.json") == 0 then pass("ingest: config.json file row, 0 symbols")
    else fail("ingest: config.json file=" .. nfile("config.json") .. " sym=" .. nsym("config.json")) end

    -- Title uses dotted module derived from path.
    local t = db.query(("SELECT title FROM lm_memories WHERE scope=%s AND kind='symbol' AND metadata->>'path'='sample.py' AND title LIKE '%%make_dog%%' LIMIT 1")
        :format(db.escape_literal(scope)))
    if t and t[1] then pass("ingest: python symbol title = " .. t[1].title)
    else fail("ingest: make_dog title row not found") end
end

st.delete_where({ scope = scope })
db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(scope)))
info("cleaned up scope")

io.write(("\n=== Phase 7B results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
