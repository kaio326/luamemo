-- eval/tests/test_session_brief.lua
-- Phase 9 exit criteria:
--   1. `memo brief --scope <s>` prints a compact digest block (memory + map + tools)
--   2. Digest is small (<=300 tokens ≈ well under 1200 bytes)
--   3. No-map scope reports "none" + the build hint
--   4. Database unavailable → returns quickly, exit 0, session-safe (no hang)
--   5. The plugin's SessionStart hook (hooks/hooks.json) injects the project's brief
--      with no MEMO_* environment and no sourced .luamemorc (memo reads it)
--
-- Drives the real ./cli/memo brief path (the same command the SessionStart hook
-- runs). Requires MEMO_DB + a POSIX shell with the `memo` CLI.
-- Run: luajit eval/tests/test_session_brief.lua

package.path = "./?/init.lua;./?.lua;" .. package.path

local PASS, FAIL = 0, 0
local function pass(m) PASS = PASS + 1; io.write("[PASS] " .. m .. "\n") end
local function fail(m) FAIL = FAIL + 1; io.write("[FAIL] " .. m .. "\n") end
local function info(m) io.write("[INFO] " .. m .. "\n") end
local function ok(cond, m) if cond then pass(m) else fail(m) end end

local db_name = os.getenv("MEMO_DB")
if not db_name or db_name == "" then
    io.stderr:write("[SKIP] MEMO_DB not set\n")
    os.exit(0)
end
local embedder = os.getenv("MEMO_EMBEDDER") or "hash"

-- Seed a scope with memories + a code map.
local luamemo = require("luamemo")
assert(pcall(luamemo.setup, { embedder_local = embedder }))
local st, db = luamemo.store, require("luamemo.db")
local mem_scope, map_scope = "repo:test_sb", "codeindex:test_sb"
st.delete_where({ scope = mem_scope })
st.delete_where({ scope = map_scope })
db.run("DELETE FROM lm_kg_facts WHERE scope = ?", map_scope)
st.write({ scope = mem_scope, kind = "decision", title = "Chose SQLite over a database server",
    body = "one file, no daemon to run", importance = 0.8 })
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

local env = ("MEMO_DB=%q MEMO_EMBEDDER=%s"):format(db_name, embedder)

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
io.write("\n--- Test 4: database unavailable is fail-soft ---\n")
local t0 = os.time()
local function mode(p) return (sh("stat -c %a " .. p .. " 2>/dev/null"):gsub("%s+$", "")) end
local devnull_before = mode("/dev/null")
local out4 = sh("MEMO_DB=/dev/null/nope.db "
    .. "MEMO_EMBEDDER=" .. embedder .. " MEMO_BRIEF_TIMEOUT=2 "
    .. "./cli/memo brief --scope " .. mem_scope .. " 2>/dev/null; echo \"rc=$?\"")
local elapsed = os.time() - t0
ok(out4:find("rc=0", 1, true) ~= nil, "brief exits 0 even when the database is unavailable")
ok(out4:find("memory database unavailable", 1, true) ~= nil, "brief says the database is unavailable")
ok(elapsed <= 6, "brief returns within timeout budget (" .. elapsed .. "s, no hang)")
ok(mode("/dev/null") == devnull_before, "… and /dev/null keeps its mode (" .. devnull_before .. " → "
    .. mode("/dev/null") .. "; luamemo used to chmod 0700 the database's directory)")

-- ---------------------------------------------------------------------------
-- Test 5: the plugin's SessionStart hook, as Claude Code runs it — the settings come
-- from the project's .luamemorc (memo reads it; the hook sources nothing), from
-- whatever directory the hook starts in.
-- ---------------------------------------------------------------------------
io.write("\n--- Test 5: the plugin's SessionStart hook (hooks/hooks.json) ---\n")
local json = require("luamemo.json")
local hooks = json.decode(io.open("hooks/hooks.json"):read("*a"))
local cmd = hooks.hooks.SessionStart[1].hooks[1].command
ok(not cmd:find("luamemorc", 1, true), "the hook doesn't source a .luamemorc itself")
local base = os.tmpname(); os.remove(base)
local proj, home = base .. "-proj", base .. "-home"
os.execute(("mkdir -p %q %q"):format(proj .. "/sub", home))
local rc = assert(io.open(proj .. "/.luamemorc", "w"))
rc:write(("MEMO_DB=%q\nMEMO_SCOPE=%s\nMEMO_EMBEDDER=%s\n"):format(db_name, mem_scope, embedder)); rc:close()
-- written by hand: trusted, as its user would (the hook runs with HOME=home only)
require("eval.tests._harness").trust_rc(proj .. "/.luamemorc", home .. "/.config/luamemo")
local repo = sh("pwd"):gsub("%s+$", "")
local lua_dir = (sh("command -v " .. (os.getenv("MEMO_LUA") or "luajit")):gsub("%s+$", "")):match("^(.*)/") or "/usr/bin"
local out5 = sh(("cd / && env -i HOME=%q PATH=%q CLAUDE_PROJECT_DIR=%q CLAUDE_PLUGIN_ROOT=%q sh -c %s 2>&1")
    :format(home, lua_dir .. ":/usr/bin:/bin", proj, repo, require("luamemo.util").shell_quote(cmd)))
local ctx = ((json.decode(out5) or {}).hookSpecificOutput or {}).additionalContext or ""
ok(ctx:find("memory: " .. mem_scope .. " — 2 memories", 1, true) ~= nil,
    "the hook injects the brief of the project's scope (no MEMO_* in its environment)")
if not ctx:find(mem_scope, 1, true) then info(out5:sub(1, 400)) end
os.execute(("rm -rf %q %q"):format(proj, home))

-- cleanup
st.delete_where({ scope = mem_scope })
st.delete_where({ scope = map_scope })
db.run("DELETE FROM lm_kg_facts WHERE scope = ?", map_scope)
info("cleaned up")

io.write(("\n=== Phase 9 results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
