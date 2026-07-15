-- eval/tests/test_session_brief.lua
-- Phase 9 exit criteria:
--   1. `memo brief --scope <s>` prints a compact digest block (memory + map + tools)
--   2. Digest is small (<=300 tokens ≈ well under 1200 bytes)
--   3. No-map scope reports "none" + the build hint
--   4. DB unreachable → returns quickly (timeout), exit 0, session-safe (no hang)
--
-- Drives the real ./cli/memo brief path (the same command the SessionStart hook
-- runs). Requires MEMO_DB_URL + a POSIX shell with the `memo` CLI.
-- Run: lua5.1 eval/tests/test_session_brief.lua

package.path = "./?/init.lua;./?.lua;" .. package.path

local PASS, FAIL = 0, 0
local function pass(m) PASS = PASS + 1; io.write("[PASS] " .. m .. "\n") end
local function fail(m) FAIL = FAIL + 1; io.write("[FAIL] " .. m .. "\n") end
local function info(m) io.write("[INFO] " .. m .. "\n") end
local function ok(cond, m) if cond then pass(m) else fail(m) end end

local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    io.stderr:write("[SKIP] MEMO_DB_URL not set\n")
    os.exit(0)
end
local embedder = os.getenv("MEMO_EMBEDDER") or "hash"

-- Seed a scope with memories + a code map.
local luamemo = require("luamemo")
assert(pcall(luamemo.setup, { db_url = db_url, embedder_local = embedder,
    auth_fn = function() return true end }))
local st, db = luamemo.store, require("luamemo.db")
local mem_scope, map_scope = "repo:test_sb", "codeindex:test_sb"
st.delete_where({ scope = mem_scope })
st.delete_where({ scope = map_scope })
db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(map_scope)))
st.write({ scope = mem_scope, kind = "decision", title = "Chose pgmoon over luadbi",
    body = "pure-Lua, ships in LuaRocks", importance = 0.8 })
st.write({ scope = mem_scope, kind = "plan", title = "Ship codebase map v0.4",
    body = "phases 8-11", importance = 0.8 })
luamemo.index.ingest("eval/fixtures/multilang", { scope = map_scope })
info("seeded " .. mem_scope .. " + " .. map_scope)

-- Helper: run a shell command, return stdout.
local function sh(cmd)
    local p = io.popen(cmd)
    local out = p:read("*a") or ""
    p:close()
    return out
end

local env = ("MEMO_DB_URL=%q MEMO_EMBEDDER=%s"):format(db_url, embedder)

-- ---------------------------------------------------------------------------
-- Test 1: mapped scope digest
-- ---------------------------------------------------------------------------
io.write("\n--- Test 1: brief on a mapped scope ---\n")
local t1 = sh(env .. " ./cli/memo brief --scope " .. mem_scope .. " 2>/dev/null")
info("digest bytes=" .. #t1)
ok(t1:find("=== LUAMEMO ===", 1, true) ~= nil, "has header")
ok(t1:find("=== END ===", 1, true) ~= nil, "has footer")
ok(t1:find("memory: " .. mem_scope, 1, true) ~= nil, "shows memory scope")
ok(t1:find("2 memories", 1, true) ~= nil, "shows memory count")
ok(t1:find("latest:", 1, true) ~= nil, "shows latest titles")
ok(t1:find(map_scope, 1, true) ~= nil, "shows map scope")
ok(t1:find("6 files / 16 symbols", 1, true) ~= nil, "shows map counts")
ok(t1:find("index_search", 1, true) ~= nil, "shows index tool hint when map exists")

-- ---------------------------------------------------------------------------
-- Test 2: token budget
-- ---------------------------------------------------------------------------
io.write("\n--- Test 2: digest size budget ---\n")
-- ~300 tokens ≈ ~1200 bytes for English/code text; assert comfortably under.
ok(#t1 < 1200, "digest under ~300-token budget (" .. #t1 .. " bytes)")

-- ---------------------------------------------------------------------------
-- Test 3: no-map scope
-- ---------------------------------------------------------------------------
io.write("\n--- Test 3: scope with no code map ---\n")
local t3 = sh(env .. " ./cli/memo brief --scope repo:test_sb_nomap 2>/dev/null")
ok(t3:find("none for codeindex:test_sb_nomap", 1, true) ~= nil, "reports no map")
ok(t3:find("memo index ingest", 1, true) ~= nil, "gives build hint")
ok(t3:find("index_search", 1, true) == nil, "omits index tool hint when no map")

-- ---------------------------------------------------------------------------
-- Test 4: DB unreachable → bounded + session-safe
-- ---------------------------------------------------------------------------
io.write("\n--- Test 4: DB down is fail-soft ---\n")
local t0 = os.time()
local rc = os.execute("MEMO_DB_URL='postgres://bad:bad@127.0.0.1:5999/nope' "
    .. "MEMO_EMBEDDER=" .. embedder .. " MEMO_BRIEF_TIMEOUT=2 "
    .. "./cli/memo brief --scope " .. mem_scope .. " >/dev/null 2>&1")
local elapsed = os.time() - t0
-- os.execute returns true/0 on success depending on Lua build; treat 0/true as ok.
local exit_ok = (rc == true) or (rc == 0)
ok(exit_ok, "brief exits 0 even when DB is down")
ok(elapsed <= 6, "brief returns within timeout budget (" .. elapsed .. "s, no hang)")

-- cleanup
st.delete_where({ scope = mem_scope })
st.delete_where({ scope = map_scope })
db.query(("DELETE FROM lm_kg_facts WHERE scope = %s"):format(db.escape_literal(map_scope)))
info("cleaned up")

io.write(("\n=== Phase 9 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
