-- eval/tests/test_index_parse.lua
-- Phase 1 exit criteria:
--   1. walker.walk() returns correct file list for luamemo codebase
--   2. parser.parse_file() extracts ≥95% of real symbols with 0 crashes
--   3. checksum.file() produces stable, collision-free hashes
--
-- Run: lua5.1 eval/tests/test_index_parse.lua [--root <path>]

package.path = "./?/init.lua;./?.lua;" .. package.path

local walker   = require("luamemo.index.walker")
local parser   = require("luamemo.index.parser")
local checksum = require("luamemo.index.checksum")

local PASS, FAIL = 0, 0

local function pass(msg) PASS = PASS + 1; io.write("[PASS] " .. msg .. "\n") end
local function fail(msg) FAIL = FAIL + 1; io.write("[FAIL] " .. msg .. "\n") end
local function info(msg) io.write("[INFO] " .. msg .. "\n") end

local function assert_eq(a, b, label)
    if a == b then pass(label)
    else fail(label .. " — got " .. tostring(a) .. " expected " .. tostring(b)) end
end

-- ---------------------------------------------------------------------------
-- Parse root from args
-- ---------------------------------------------------------------------------
local root = "."
for i, a in ipairs(arg or {}) do
    if a == "--root" and arg[i+1] then root = arg[i+1] end
end

-- ---------------------------------------------------------------------------
-- Test 1: Walker
-- ---------------------------------------------------------------------------
io.write("\n--- Test 1: Walker ---\n")

local files, werr = walker.walk(root, {
    extensions = { lua = true },
    exclude_patterns = { ".git", "vendor/", "node_modules/", "eval/", "examples/" },
})

if not files then
    fail("walker.walk returned error: " .. tostring(werr))
else
    pass("walker.walk completed without error")
    info("files found: " .. #files)
    if #files > 0 then
        pass("walker found at least 1 .lua file")
    else
        fail("walker found 0 .lua files — root may be wrong: " .. root)
    end

    -- Verify all returned paths exist.
    local missing = 0
    for _, f in ipairs(files) do
        local h = io.open(f.path, "r")
        if not h then missing = missing + 1
        else h:close() end
    end
    if missing == 0 then
        pass("all returned file paths are readable")
    else
        fail(missing .. " returned paths are not readable")
    end

    -- Verify rel paths are relative (no leading /).
    local abs_count = 0
    for _, f in ipairs(files) do
        if f.rel:sub(1,1) == "/" then abs_count = abs_count + 1 end
    end
    if abs_count == 0 then
        pass("all rel paths are relative (no leading /)")
    else
        fail(abs_count .. " rel paths start with / (should be relative)")
    end
end

-- ---------------------------------------------------------------------------
-- Test 2: Parser — run against all found .lua files
-- ---------------------------------------------------------------------------
io.write("\n--- Test 2: Parser ---\n")

if not files or #files == 0 then
    fail("skipping parser tests: no files from walker")
else
    local total_symbols = 0
    local total_requires = 0
    local crashes = 0
    local files_parsed = 0

    for _, f in ipairs(files) do
        local ok, result = pcall(parser.parse_file, f.path)
        if not ok then
            crashes = crashes + 1
            fail("parser crash on " .. f.rel .. ": " .. tostring(result))
        else
            if result then
                files_parsed = files_parsed + 1
                total_symbols = total_symbols + #result.symbols
                total_requires = total_requires + #result.requires
            end
        end
    end

    info(("parsed %d files, %d symbols, %d requires"):format(
        files_parsed, total_symbols, total_requires))

    if crashes == 0 then
        pass("parser: 0 crashes across " .. files_parsed .. " files")
    else
        fail("parser: " .. crashes .. " crashes")
    end

    -- Spot-check: parse store.lua and look for known symbols.
    local store_path
    for _, f in ipairs(files) do
        if f.rel:match("store%.lua$") and not f.rel:match("/cli/") then
            store_path = f.path; break
        end
    end

    if store_path then
        local ok2, res = pcall(parser.parse_file, store_path)
        if not ok2 then
            fail("parser failed on store.lua: " .. tostring(res))
        else
            local found = {}
            for _, s in ipairs(res.symbols) do found[s.name] = true end
            local expected = { "write", "search", "delete", "get", "update", "recent" }
            local found_count = 0
            for _, name in ipairs(expected) do
                if found[name] then found_count = found_count + 1 end
            end
            local recall = found_count / #expected
            info(("store.lua: found %d/%d expected symbols (recall=%.0f%%)"):format(
                found_count, #expected, recall * 100))
            if recall >= 0.95 then
                pass("store.lua: recall ≥ 95%")
            elseif recall >= 0.80 then
                fail("store.lua: recall " .. math.floor(recall*100) .. "% (target: 95%)")
            else
                fail("store.lua: recall only " .. math.floor(recall*100) .. "%")
            end
        end
    else
        fail("could not find store.lua in walked files")
    end

    -- Test parse_source directly with inline Lua.
    local test_src = [[
local M = {}
-- Add two numbers
function M.add(a, b) return a + b end
local function _helper(x) return x end
function M:method(y) return y end
local x = require("some.module")
return M
]]
    local res2 = parser.parse_source(test_src, "test.lua")
    assert_eq(res2 and #res2.symbols or 0, 3, "parse_source: finds 3 symbols in test src")
    local sym_names = {}
    for _, s in ipairs(res2.symbols) do sym_names[s.name] = s end
    if sym_names["add"] then
        assert_eq(sym_names["add"].exported, true, "M.add is exported")
        assert_eq(sym_names["add"].symbol_type, "function", "M.add type=function")
        assert_eq(sym_names["add"].arity, 2, "M.add arity=2")
    else
        fail("parse_source: M.add not found")
    end
    if sym_names["method"] then
        assert_eq(sym_names["method"].symbol_type, "method", "M:method type=method")
    else
        fail("parse_source: M:method not found")
    end
    if sym_names["_helper"] then
        assert_eq(sym_names["_helper"].exported, false, "_helper exported=false")
    else
        fail("parse_source: _helper not found")
    end
    assert_eq(res2 and #res2.requires or 0, 1, "parse_source: finds 1 require")
    if res2.requires[1] then
        assert_eq(res2.requires[1].module, "some.module", "require module name")
    end
end

-- ---------------------------------------------------------------------------
-- Test 3: Checksum
-- ---------------------------------------------------------------------------
io.write("\n--- Test 3: Checksum ---\n")

-- Identical inputs → same hash.
local h1 = checksum.source("hello world")
local h2 = checksum.source("hello world")
assert_eq(h1, h2, "checksum.source: identical input → same hash")

-- One-byte change → different hash.
local h3 = checksum.source("hello World")
if h1 ~= h3 then pass("checksum.source: one-byte change → different hash")
else fail("checksum.source: one-byte change did NOT change hash") end

-- CRLF normalization: CRLF and LF versions → same hash.
local lf_src  = "line1\nline2\nline3\n"
local crlf_src = "line1\r\nline2\r\nline3\r\n"
local h_lf   = checksum.source(lf_src)
local h_crlf = checksum.source(crlf_src)
assert_eq(h_lf, h_crlf, "checksum.source: CRLF and LF versions → same hash")

-- Standalone \r also normalized.
local cr_src = "line1\rline2\rline3\r"
local h_cr = checksum.source(cr_src)
assert_eq(h_lf, h_cr, "checksum.source: standalone \\r → same hash as LF")

-- Hash is 8-char lowercase hex.
if h1 and h1:match("^%x%x%x%x%x%x%x%x$") then
    pass("checksum: output is 8-char lowercase hex")
else
    fail("checksum: unexpected format: " .. tostring(h1))
end

-- File hash on real files: same file read twice → same hash.
if files and files[1] then
    local fa = checksum.file(files[1].path)
    local fb = checksum.file(files[1].path)
    assert_eq(fa, fb, "checksum.file: same file read twice → same hash")
end

-- checksum.file on non-existent path returns nil + error.
local hnil, herr = checksum.file("/this/does/not/exist.lua")
if hnil == nil and herr then
    pass("checksum.file: missing file → nil, err")
else
    fail("checksum.file: missing file should return nil, err")
end

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
io.write(("\n=== Phase 1 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
