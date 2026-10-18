-- eval/tests/test_cli.lua
-- The `memo` CLI's memory commands pass every documented flag through:
--   multi-word flags are accepted with hyphens (--decay-rate → decay_rate);
--   memo search honours --since / --until / --tier-min / --tier-max /
--   --ignore-decay; memo update honours --scope (a move), --importance and
--   --decay-rate. (All were silently ignored before.)
-- The schema: a new database gets every migration once; opening it again applies
--   nothing and keeps its rows; the tier scale is importance's 0–10.
-- MEMO_PROJECT=DIR: memo loads DIR/.luamemorc (not the working directory's);
--   a value that isn't a directory is refused.
-- calibrate: a new project gets its own database (named after it, created 0600
--   in the 0700 data directory, checked by ping); a re-run keeps it; a MEMO_DB from
--   ~/.luamemorc is not taken over silently; --db picks one; --probe-only writes
--   nothing; ~/.memorc is no longer read — calibrate moves it into ~/.luamemorc.
-- The project: the nearest directory up with a .luamemorc (not ~/.luamemorc, the
--   user file); memo and luamemo.settings agree; calibrate --root DIR makes DIR one.
-- memo mcp: the MCP server with the project's settings and no MEMO_* environment —
--   from a subfolder, with --project, outside a project (the user file); no settings
--   → every tool says what to do; --print-config has no secrets; initialize carries the
--   usage rules.
-- calibrate's MCP entries: the generic one (memo mcp) for VS Code / Cursor / Claude
--   Desktop, an old-style entry replaced, the user's own kept, no MEMO_* written, the
--   entry and the client report always printed.
-- The capture hooks save through `memo` (the project's .luamemorc names the
--   database); without memo installed they do nothing.
-- Uses a throwaway scope in MEMO_DB's database, removed at the end.
-- Run: luajit eval/tests/run.lua --only cli

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("CLI")
local check, section, finish = T.check, T.section, T.finish
local sh = H.sh

local db_name = os.getenv("MEMO_DB")
if not db_name or db_name == "" then io.write("\n[SKIP] MEMO_DB not set — skipping\n"); finish() end

local json = require("luamemo.json")
require("luamemo").setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true })
local SCOPE = ("demo:clitest-%d-%04d"):format(os.time(), math.random(0, 9999))
local MOVED = SCOPE .. "-moved"
local ENV = ("MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q"):format(db_name, H.lua_bin())
local function memo(args)
    local out = sh(("%s ./cli/memo %s 2>/dev/null"):format(ENV, args))
    return json.decode(out) or {}
end
local q = require("luamemo.util").shell_quote
local function results(args) return memo("search deploy --scope " .. SCOPE .. " " .. args).results or {} end

section("write / search / update flags", function()
io.write("\n--- memo write / search / update ---\n")
local w = memo(("write --scope %s --kind fact --title %s --body %s --importance 5 --decay-rate 0.2")
    :format(SCOPE, q("deploy note"), q("how to deploy the app")))
local m = w.memory or {}
check("write --decay-rate (hyphenated) is stored", tonumber(m.decay_rate) and math.abs(tonumber(m.decay_rate) - 0.2) < 1e-6,
    json.encode(m.decay_rate))
check("write --importance is stored", tonumber(m.importance) == 5, json.encode(m.importance))
check("search finds it", #results("") == 1)
check("search --since (future) → nothing", #results("--since 2100-01-01") == 0)
check("search --until (past) → nothing", #results("--until 2000-01-01") == 0)
check("search --since (past) → found", #results("--since 2000-01-01") == 1)
local tier = tonumber(m.tier)
check("search --tier-min / --tier-max bound the tier", tier ~= nil
    and #results(("--tier-min %d --tier-max %d"):format(tier, tier)) == 1
    and #results(("--tier-max %d"):format(tier - 1)) == 0, tier)
local plain, raw = results("")[1] or {}, results("--ignore-decay 1")[1] or {}
check("search --ignore-decay 1 drops the importance × decay weight", tonumber(plain.weight) ~= 1
    and tonumber(raw.weight) == 1, ("%s / %s"):format(tostring(plain.weight), tostring(raw.weight)))
local u = memo(("update %d --decay-rate 0.3 --importance 7 --scope %s"):format(tonumber(m.id) or 0, MOVED))
local um = u.memory or {}
check("update --scope moves it; --decay-rate / --importance applied", um.scope == MOVED
    and math.abs((tonumber(um.decay_rate) or 0) - 0.3) < 1e-6 and tonumber(um.importance) == 7, json.encode(um))
local rec = memo("recent --scope " .. MOVED .. " --limit 5").results or {}
check("recent --scope / --limit", #rec == 1 and rec[1].title == "deploy note")
end)

section("MEMO_PROJECT picks the project's .luamemorc", function()
io.write("\n--- MEMO_PROJECT ---\n")
local base = os.tmpname(); os.remove(base)
local proj, empty = base .. "-proj", base .. "-empty"
os.execute(("mkdir -p %q %q"):format(proj, empty))
local rc_scope, env_scope = SCOPE .. "-rc", SCOPE .. "-env"
local f = assert(io.open(proj .. "/.luamemorc", "w"))
f:write(("# test project\nMEMO_DB=%s\nMEMO_SCOPE=%s\n"):format(q(db_name), q(rc_scope))); f:close()
H.trust_rc(proj .. "/.luamemorc")   -- written by hand: trusted, as its user would
-- memo brief defaults --scope to MEMO_SCOPE and names the scope in its header.
local b1 = sh(("%s MEMO_SCOPE=%q MEMO_PROJECT=%q ./cli/memo brief 2>&1"):format(ENV, env_scope, proj))
check("MEMO_PROJECT=DIR → DIR/.luamemorc is loaded (its MEMO_SCOPE wins)", b1:find(rc_scope, 1, true) ~= nil, b1)
local b2 = sh(("%s MEMO_SCOPE=%q MEMO_PROJECT=%q ./cli/memo brief 2>&1"):format(ENV, env_scope, empty))
check("MEMO_PROJECT=DIR without a .luamemorc → the environment is used", b2:find(env_scope, 1, true) ~= nil
    and not b2:find(rc_scope, 1, true), b2)
local o3, c3 = sh(("%s MEMO_PROJECT=%q ./cli/memo brief 2>&1"):format(ENV, base .. "-missing"))
check("MEMO_PROJECT that is not a directory → exit 2 with a clear message", c3 == 2
    and o3:find("MEMO_PROJECT is not a directory", 1, true) ~= nil, ("%s / %s"):format(tostring(c3), o3))
os.execute(("rm -rf %q %q"):format(proj, empty))
end)

section("the project: the nearest .luamemorc up", function()
io.write("\n--- the project, found from a subfolder ---\n")
local REPO = (sh("pwd")):gsub("%s+$", "")
local LUA_ABS = (sh("command -v " .. q(H.lua_bin())))
local REPO_PATH = ("%s/?.lua;%s/?/init.lua;"):format(REPO, REPO) .. (os.getenv("LUA_PATH") or ";")
local base = os.tmpname(); os.remove(base)
local home = base .. "-home"
local proj = home .. "/code/app"
local sub = proj .. "/src/deep"
os.execute(("mkdir -p %q %q"):format(sub, home .. "/notes"))
local f = assert(io.open(proj .. "/.luamemorc", "w")); f:write("MEMO_DEDUP_THRESHOLD='0.77'\n"); f:close()
H.trust_rc(proj .. "/.luamemorc", home .. "/.config/luamemo")
local u = assert(io.open(home .. "/.luamemorc", "w")); u:write("MEMO_DEDUP_THRESHOLD='0.66'\n"); u:close()
local WENV = ("env -u MEMO_PROJECT -u MEMO_DB HOME=%q XDG_CONFIG_HOME=%q MEMO_LUA=%q LUA_PATH=%q MEMO_EMBEDDER=hash")
    :format(home, home .. "/.config", LUA_ABS, REPO_PATH)
local function where(dir)
    local out = sh(("cd %q && %s %q config list --json 2>/dev/null </dev/null"):format(dir, WENV, REPO .. "/cli/memo"))
    local j = json.decode(out) or {}
    local v
    for _, s in ipairs(j.settings or {}) do if s.name == "MEMO_DEDUP_THRESHOLD" then v = s.value end end
    return (j.files or {}).project, v
end
local p1, v1 = where(sub)
check("from a subfolder memo finds the project's .luamemorc (and its value wins)",
    p1 == proj .. "/.luamemorc" and v1 == "0.77", tostring(p1) .. " " .. tostring(v1))
local lua_dir = sh(("cd %q && %s %q -e %q"):format(sub, WENV, LUA_ABS,
    "package.path=" .. ("%q"):format(REPO .. "/?.lua;" .. REPO .. "/?/init.lua;") .. "..package.path "
    .. "io.write(require('luamemo.settings').project_dir())"))
check("… and luamemo.settings (the MCP server) finds the same one", lua_dir == proj, lua_dir)
local p2, v2 = where(home .. "/notes")
check("~/.luamemorc is the user file, never a project: under home, no project file → this folder",
    p2 == home .. "/notes/.luamemorc" and v2 == "0.66", tostring(p2) .. " " .. tostring(v2))
local cal_out = sh(("cd %q && %s %q calibrate --root . --no-mcp --no-plugin --no-git --no-comments --allow-hash "
    .. "</dev/null"):format(sub, WENV, REPO .. "/cli/memo"))
check("calibrate --root . makes the subfolder a project of its own", H.slurp(sub .. "/.luamemorc") ~= nil
    and (where(sub)) == sub .. "/.luamemorc", cal_out:sub(-500))
os.execute(("rm -rf %q"):format(home))
end)

section("memo mcp: the server with the project's settings", function()
io.write("\n--- memo mcp ---\n")
local REPO = (sh("pwd")):gsub("%s+$", "")
local LUA_ABS = (sh("command -v " .. q(H.lua_bin()))):gsub("%s+$", "")
local base = os.tmpname(); os.remove(base)
local home, proj, other = base .. "-home", base .. "-proj", base .. "-other"
os.execute(("mkdir -p %q %q %q"):format(home, proj .. "/src/deep", other))
local f = assert(io.open(proj .. "/.luamemorc", "w"))
f:write(("MEMO_DB=%s\nMEMO_SCOPE=proj-scope\nMEMO_EMBEDDER=hash\n"):format(q(base .. "-proj.db"))); f:close()
H.trust_rc(proj .. "/.luamemorc", home .. "/.config/luamemo")   -- memo runs with HOME=home only
local u = assert(io.open(home .. "/.luamemorc", "w"))
u:write(("MEMO_DB=%s\nMEMO_SCOPE=user-scope\nMEMO_EMBEDDER=hash\n"):format(q(base .. "-user.db"))); u:close()
-- No MEMO_* in the environment at all: as a client's generic entry starts it.
local CLEAN = ("env -i HOME=%q PATH=%q"):format(home, LUA_ABS:match("^(.*)/[^/]*$") .. ":/usr/bin:/bin")
local MEMO = ("bash %q mcp"):format(REPO .. "/cli/memo")
local function session(cwd, extra, env)
    return H.mcp_session(env or CLEAN, { cwd = cwd, cmd = MEMO .. (extra or "") })
end
local s = session(proj .. "/src/deep")
local w = s.call("memory_write", { title = "mcp walk-up", body = "written through memo mcp", kind = "fact" })
local r = s.call("memory_recent", { limit = 5 })
s.close()
check("from a subfolder, no MEMO_* env: the project's settings (its scope, its database)",
    w.memory and w.memory.scope == "proj-scope" and #(r.results or {}) == 1, json.encode({ w, r }))
s = session(other, (" --project %q"):format(proj))
r = s.call("memory_recent", { limit = 5 })
s.close()
check("--project PATH from anywhere: the same project", #(r.results or {}) == 1
    and r.results[1].title == "mcp walk-up", json.encode(r))
s = session(other, (" --project %q"):format(proj), CLEAN .. (" MEMO_PROJECT=%q"):format(other))
r = s.call("memory_recent", { limit = 5 })
s.close()
check("--project wins over MEMO_PROJECT", #(r.results or {}) == 1, json.encode(r))
s = session(other)
local w2 = s.call("memory_write", { title = "user file", body = "no project here", kind = "fact" })
r = s.call("memory_recent", { scope = "proj-scope", limit = 5 })
s.close()
check("outside any project: ~/.luamemorc (the project's file beat it above)",
    w2.memory and w2.memory.scope == "user-scope" and #(r.results or {}) == 0, json.encode({ w2, r }))
s = session(other, nil, ("env -i HOME=%q PATH=%q"):format(other, LUA_ABS:match("^(.*)/[^/]*$") .. ":/usr/bin:/bin"))
local n1 = s.call("memory_search", { query = "x" })
local n2 = s.call("memory_status", {})
s.close()
check("no settings anywhere: the server starts and every tool says what to do",
    tostring(n1.error):find("memo calibrate", 1, true) and tostring(n1.error):find("--project", 1, true)
    and n2.error == n1.error, json.encode({ n1, n2 }))
local pc = sh(("cd %q && %s %s --print-config 2>&1"):format(other, CLEAN, MEMO))
local entry = json.decode(pc:match("(%b{})") or "") or {}
local e = (entry.mcpServers or {}).luamemo or {}
check("--print-config: memo's absolute path + [\"mcp\"], no env (nothing secret)",
    e.command == REPO .. "/cli/memo" and json.encode(e.args) == '["mcp"]' and e.env == nil
    and pc:find('"servers"', 1, true) and pc:find("${workspaceFolder}", 1, true)
    and not pc:find("MEMO_DB", 1, true), pc)
local init = sh(("cd %q && printf '%%s\\n' %s | %s %s 2>/dev/null"):format(other, q(json.encode({ jsonrpc = "2.0",
    id = 1, method = "initialize", params = { protocolVersion = "2025-06-18" } })), CLEAN, MEMO))
local ir = (json.decode(init) or {}).result or {}
check("over memo mcp: initialize answers the client's version, with the usage rules (instructions)",
    ir.protocolVersion == "2025-06-18" and tostring(ir.instructions):find("memory_brief", 1, true) ~= nil, init:sub(1, 300))
-- memo write from the terminal names no scope: the project's (MEMO_SCOPE), where the
-- agent searches — it used to land in "global", invisible to the agent's default search.
local cw = json.decode((sh(("cd %q && %s bash %q write --kind fact --title %s --body %s 2>/dev/null"):format(
    proj .. "/src/deep", CLEAN, REPO .. "/cli/memo", q("terminal note"), q("written with memo write"))))) or {}
s = session(proj)
local seen = s.call("memory_search", { query = "written with memo write" })
s.close()
local titles = {}
for _, row in ipairs(seen.results or {}) do titles[#titles + 1] = row.title end
check("memo write without --scope → the project's MEMO_SCOPE: the agent's (scoped) search finds it",
    (cw.memory or {}).scope == "proj-scope" and table.concat(titles, "|"):find("terminal note", 1, true) ~= nil,
    json.encode({ cw.memory and cw.memory.scope, titles }))
local bo, bc = sh(("%s %s --project %q 2>&1 </dev/null"):format(CLEAN, MEMO, base .. "-missing"))
check("--project that is not a directory → exit 2, named", bc == 2
    and bo:find("--project is not a directory", 1, true) ~= nil, ("%s / %s"):format(tostring(bc), bo))
os.execute(("rm -rf %q %q %q %q-proj.db* %q-user.db*"):format(home, proj, other, base, base))
end)

section("a project's own Lua files never run as luamemo's", function()
io.write("\n--- the working directory is not on the module path ---\n")
-- LuaJIT's default module paths begin with ./?.lua and ./?.so: memo (and the MCP server
-- started directly) used to load a project's luamemo/init.lua — e.g. from the plugin's
-- session-start hook, as soon as Claude Code opened the project. Decoys that only
-- leave a marker file stand in for such files here.
local REPO = (sh("pwd")):gsub("%s+$", "")
local LUA_DIR = ((sh("command -v " .. q(H.lua_bin()))):gsub("%s+$", "")):match("^(.*)/") or "/usr/bin"
local base = os.tmpname(); os.remove(base)
local proj, home, marks = base .. "-proj", base .. "-home", base .. "-marks"
os.execute(("mkdir -p %q %q %q %q %q"):format(proj .. "/luamemo/cli", proj .. "/cjson", home, marks,
    proj .. "/socket"))
local function decoy(path, name)
    local f = assert(io.open(proj .. "/" .. path, "w"))
    f:write(("io.open(%q, 'w'):close()\nreturn {}\n"):format(marks .. "/" .. name)); f:close()
end
decoy("luamemo/init.lua", "luamemo"); decoy("luamemo/cli/api.lua", "api")
decoy("cjson/safe.lua", "cjson"); decoy("socket.lua", "socket")
local ENV = ("env -i HOME=%q PATH=%q MEMO_DB=%q MEMO_EMBEDDER=hash"):format(home,
    LUA_DIR .. ":/usr/bin:/bin", base .. ".db")
for _, c in ipairs({ "brief", "search anything", "recent", "config list", "ping" }) do
    sh(("cd %q && %s bash %q %s </dev/null"):format(proj, ENV, REPO .. "/cli/memo", c))
end
local init = json.encode({ jsonrpc = "2.0", id = 1, method = "initialize", params = {} })
local call = json.encode({ jsonrpc = "2.0", id = 2, method = "tools/call",
    params = { name = "memory_search", arguments = { query = "x" } } })
sh(("cd %q && printf '%%s\\n%%s\\n' %s %s | %s bash %q mcp"):format(proj, q(init), q(call), ENV, REPO .. "/cli/memo"))
sh(("cd %q && printf '%%s\\n%%s\\n' %s %s | %s %q %q"):format(proj, q(init), q(call), ENV, H.lua_bin(),
    REPO .. "/mcp/server.lua"))
local hooks = json.decode(H.slurp(REPO .. "/hooks/hooks.json") or "{}") or {}
local hook = (((hooks.hooks or {}).SessionStart or {})[1] or {}).hooks
sh(("cd / && env -i HOME=%q PATH=%q CLAUDE_PROJECT_DIR=%q CLAUDE_PLUGIN_ROOT=%q sh -c %s"):format(home,
    LUA_DIR .. ":/usr/bin:/bin", proj, REPO, q(hook and hook[1].command or "true")))
local ran = sh(("ls -A %q"):format(marks))
check("memo, memo mcp, the server and the session-start hook load none of the project's Lua files",
    ran == "", "ran: " .. ran)
os.execute(("rm -rf %q %q %q %q.db*"):format(proj, home, marks, base))
end)

section("schema: applied once when a database is opened", function()
io.write("\n--- schema migrations ---\n")
local path = H.create_db(("lm_clitest_%d_%04d"):format(os.time(), math.random(0, 9999)))
local db, schema = require("luamemo.db"), require("luamemo.schema")
local c = assert(db.open(path))
local applied = c.query("SELECT name FROM lm_migrations ORDER BY name") or {}
check("a new database has every migration applied", #applied == #schema.MIGRATIONS
    and applied[1].name == schema.MIGRATIONS[1].name, json.encode(applied))
check("user_version mirrors the migration count", c.value("PRAGMA user_version") == #schema.MIGRATIONS)
check("the database has its own random id", (c.value("SELECT value FROM lm_meta WHERE key = 'db_id'") or ""):match("^%x+$") ~= nil)
c.run("INSERT INTO lm_memories (scope, kind, title, body, importance, tier) VALUES ('repo:t', 'fact', 'kept', 'x', 1.0, 1)")
local id = c.value("SELECT value FROM lm_meta WHERE key = 'db_id'")
c.close()
local c2 = assert(db.open(path))
check("opening again applies nothing", c2.value("SELECT count(*) FROM lm_migrations") == #schema.MIGRATIONS)
check("… and keeps the rows and the id", c2.value("SELECT title FROM lm_memories") == "kept"
    and c2.value("SELECT value FROM lm_meta WHERE key = 'db_id'") == id)
c2.close()
-- The tier scale (importance 0–10): a default write is tier 1, not core.
local w = memo(("write --scope %s --kind fact --title %s --body %s"):format(SCOPE, q("tier probe"), q("default importance")))
check("a default write lands in tier 1", tonumber((w.memory or {}).tier) == 1, json.encode(w.memory))
H.drop_dbs()
end)

local REPO = (sh("pwd")):gsub("%s+$", "")
local LUA_ABS = (sh("command -v " .. q(H.lua_bin())))
local REPO_PATH = ("%s/?.lua;%s/?/init.lua;"):format(REPO, REPO) .. (os.getenv("LUA_PATH") or ";")

section("calibrate: the project's own database", function()
io.write("\n--- memo calibrate: the project's database ---\n")
local base = os.tmpname(); os.remove(base)
local home, proj = base .. "-home", base .. "-dir/my proj"
os.execute(("mkdir -p %q %q"):format(home, proj))
local data = home .. "/.local/share/luamemo"
-- (no MEMO_DB in the environment: calibrate picks the project's database itself)
local CENV = ("env -u MEMO_DB HOME=%q XDG_CONFIG_HOME=%q XDG_DATA_HOME=%q MEMO_PROJECT= MEMO_EMBEDDER=hash "
    .. "MEMO_LUA=%q LUA_PATH=%q"):format(home, home .. "/.config", home .. "/.local/share", LUA_ABS, REPO_PATH)
local function cal(args)
    return sh(("cd %q && %s %q calibrate --no-mcp --no-plugin --no-git --no-comments --allow-hash %s </dev/null")
        :format(proj, CENV, REPO .. "/cli/memo", args or ""))
end
local function rc_db() return H.rc_get(H.slurp(proj .. "/.luamemorc"), "MEMO_DB") end
local _, pc = cal("--probe-only")
check("--probe-only writes nothing (no .luamemorc, no database)", pc == 0 and H.slurp(proj .. "/.luamemorc") == nil
    and select(2, sh(("test -e %q"):format(data))) ~= 0)
local out, code = cal()
local name = rc_db()
check("a new project gets its own database, named after its directory", code == 0 and name ~= nil
    and name:match("^my%-proj%-%x%x%x%x%x%x%x%x$") ~= nil, tostring(name) .. "\n" .. out:sub(-600))
check("… created in the data directory (0700, the file 0600) and checked", H.mode(data .. "/" .. tostring(name) .. ".db")
    == "600" and H.mode(data) == "700" and out:find("[PASS] Database", 1, true) ~= nil
    and out:find("[PASS] Memories", 1, true) ~= nil, out:sub(-800))
local out2 = cal()
check("calibrate again: the same database, from .luamemorc",
    out2:find("Database: " .. tostring(name) .. " (this project's, from .luamemorc)", 1, true) ~= nil, out2:sub(1, 900))
-- Edited by hand, double-quoted: calibrate read the value with its quotes (its own
-- reader knew single quotes only) — it reads it as memo loads it now.
local rcf = assert(io.open(proj .. "/.luamemorc", "w")); rcf:write(('MEMO_DB="%s"\n'):format(name)); rcf:close()
H.trust_rc(proj .. "/.luamemorc", home .. "/.config/luamemo")
local outq = cal()
check("… a double-quoted MEMO_DB (edited by hand) reads as memo loads it, without its quotes",
    outq:find("Database: " .. tostring(name) .. " (this project's", 1, true) ~= nil, outq:sub(1, 900))
-- ~/.memorc (the older name of the user file) is no longer read: memo says so, and
-- calibrate moves it into ~/.luamemorc — a setting already there is kept.
os.remove(proj .. "/.luamemorc")
local m = assert(io.open(home .. "/.memorc", "w"))
m:write("MEMO_DB='shared'\nMEMO_DEDUP_THRESHOLD='0.9'\n"); m:close()
local pre = assert(io.open(home .. "/.luamemorc", "w")); pre:write("MEMO_DEDUP_THRESHOLD='0.8'\n"); pre:close()
local warn = sh(("cd %q && %s %q config get dedup_threshold </dev/null"):format(proj, CENV, REPO .. "/cli/memo"))
check("~/.memorc is no longer read — memo says calibrate moves it", warn:find("no longer read", 1, true) ~= nil
    and warn:find("0.8", 1, true) ~= nil, warn)
local out3 = cal()
local user_rc = H.slurp(home .. "/.luamemorc") or ""
check("calibrate moves ~/.memorc into ~/.luamemorc (keeping what is there) and removes it",
    out3:find("Moved ~/.memorc into ~/.luamemorc: 1 setting(s) moved, 1 already set there", 1, true) ~= nil
    and H.rc_get(user_rc, "MEMO_DB") == "shared" and H.rc_get(user_rc, "MEMO_DEDUP_THRESHOLD") == "0.8"
    and H.slurp(home .. "/.memorc") == nil and H.mode(home .. "/.luamemorc") == "600", out3:sub(1, 900))
check("… and that MEMO_DB (every project's) is not taken over silently — the project gets its own",
    out3:find("~/.luamemorc sets MEMO_DB=shared", 1, true) ~= nil and out3:find("--db shared", 1, true) ~= nil
    and rc_db() == name, out3:sub(1, 900))
local out4 = cal("--db shared")
check("--db picks a database explicitly", out4:find("Database: shared (--db)", 1, true) ~= nil
    and rc_db() == "shared" and H.mode(data .. "/shared.db") == "600", out4:sub(1, 900))
os.remove(home .. "/.luamemorc"); os.remove(proj .. "/.luamemorc")
local u = assert(io.open(home .. "/.luamemorc", "w")); u:write("MEMO_DB='shared2'\n"); u:close()
local out5 = cal()
check("MEMO_DB from ~/.luamemorc: the project still gets its own, and the note names that file",
    out5:find("~/.luamemorc sets MEMO_DB=shared2", 1, true) ~= nil and rc_db() == name, out5:sub(1, 900))
os.execute(("rm -rf %q %q"):format(home, base .. "-dir"))
end)

section("calibrate: the generic MCP entries", function()
io.write("\n--- memo calibrate: MCP client configs ---\n")
if not (sh("command -v script")):find("script", 1, true) then
    io.write("[INFO] `script` (util-linux) not found — skipped (calibrate asks before writing)\n"); return
end
local base = os.tmpname(); os.remove(base)
local home, proj = base .. "-home", base .. "-proj"
os.execute(("mkdir -p %q %q %q %q"):format(home .. "/.cursor", home .. "/.config/Claude", proj .. "/.vscode",
    home .. "/.local/share"))
local MEMO = REPO .. "/cli/memo"
local function put(path, t) local f = assert(io.open(path, "w")); f:write(json.encode(t)); f:close() end
-- Cursor: what calibrate wrote before memo mcp (per-project key, server path, MEMO_* env) + another server.
put(home .. "/.cursor/mcp.json", { mcpServers = {
    ["luamemo-repo-app"] = { command = "luajit", args = { "/old/rock/mcp/server.lua" },
        env = { MEMO_DB = "/old/app.db", MEMO_SCOPE = "repo:app" } },
    other = { command = "other-server", args = { "--x" } } } })
-- Claude Desktop: a luamemo entry the user made themselves.
local mine = { command = MEMO, args = { "mcp", "--project", "/somewhere/else" } }
put(home .. "/.config/Claude/claude_desktop_config.json", { mcpServers = { ["luamemo-repo-app"] = mine } })
local CENV = ("env -u MEMO_DB HOME=%q XDG_CONFIG_HOME=%q XDG_DATA_HOME=%q MEMO_PROJECT= MEMO_EMBEDDER=hash "
    .. "MEMO_SCOPE=repo:app MEMO_LUA=%q LUA_PATH=%q"):format(home, home .. "/.config", home .. "/.local/share",
    LUA_ABS, REPO_PATH)
local cmd = ("cd %q && %s %q calibrate --no-plugin --no-git --no-comments --allow-hash"):format(proj, CENV, MEMO)
local before = H.slurp(home .. "/.cursor/mcp.json")
local dry = sh(("printf 'y\\ny\\ny\\ny\\ny\\ny\\ny\\ny\\n' | script -qec %q /dev/null"):format(cmd .. " --dry-run"))
check("--dry-run: no client config written (the entry is printed)", H.slurp(home .. "/.cursor/mcp.json") == before
    and H.slurp(proj .. "/.vscode/mcp.json") == nil and dry:find("[dry-run] No client config", 1, true) ~= nil,
    dry:sub(-1200))
local out = sh(("printf 'y\\ny\\ny\\ny\\ny\\ny\\ny\\ny\\n' | script -qec %q /dev/null"):format(cmd))
local cur = json.decode(H.slurp(home .. "/.cursor/mcp.json") or "") or {}
local cs = cur.mcpServers or {}
check("Cursor: the old-style entry → one generic luamemo entry (memo mcp, the workspace), other servers kept",
    cs["luamemo-repo-app"] == nil and cs.luamemo and cs.luamemo.command == MEMO and cs.luamemo.env == nil
    and json.encode(cs.luamemo.args) == '["mcp","--project","${workspaceFolder}"]'
    and cs.other and cs.other.command == "other-server", json.encode(cur) .. "\n" .. out:sub(-1500))
local vs = (json.decode(H.slurp(proj .. "/.vscode/mcp.json") or "") or {}).servers or {}
check("VS Code: .vscode/mcp.json created with the stdio entry", vs.luamemo and vs.luamemo.type == "stdio"
    and vs.luamemo.command == MEMO and vs.luamemo.env == nil, json.encode(vs))
local cd = (json.decode(H.slurp(home .. "/.config/Claude/claude_desktop_config.json") or "") or {}).mcpServers or {}
local kept = cd["luamemo-repo-app"] or {}
check("Claude Desktop: an entry of the user's own is kept", kept.command == mine.command
    and table.concat(kept.args or {}, " ") == table.concat(mine.args, " ") and kept.env == nil
    and out:find("of your own is there — kept", 1, true) ~= nil, json.encode(cd))
check("the generic entry is always printed (and the doc named)", out:find('"mcpServers"', 1, true) ~= nil
    and out:find("Connect any MCP client", 1, true) ~= nil, out:sub(-1500))
check("… and which clients have started luamemo (none yet: open one, then memo doctor)",
    out:find("No MCP client has started luamemo", 1, true) ~= nil, out:sub(-800))
local all = (H.slurp(home .. "/.cursor/mcp.json") or "") .. (H.slurp(proj .. "/.vscode/mcp.json") or "")
check("no MEMO_* setting in any client config luamemo wrote", not all:find("MEMO_", 1, true), all)
-- Again: nothing to do.
local out2 = sh(("printf 'y\\ny\\ny\\ny\\ny\\ny\\ny\\ny\\n' | script -qec %q /dev/null"):format(cmd))
check("calibrate again: the entries are up to date", select(2, out2:gsub("luamemo entry up to date", "")) == 2,
    out2:match("MCP client configuration.-Most clients") or out2:sub(-1200))
-- Claude Desktop, no entry yet: one for this project, its folder pinned (Desktop has no workspace).
local empty = assert(io.open(home .. "/.config/Claude/claude_desktop_config.json", "w"))
empty:write('{"mcpServers": {}}'); empty:close()   -- (an empty Lua table may encode as [])
sh(("printf 'y\\ny\\ny\\ny\\ny\\ny\\ny\\ny\\n' | script -qec %q /dev/null"):format(cmd))
cd = (json.decode(H.slurp(home .. "/.config/Claude/claude_desktop_config.json") or "") or {}).mcpServers or {}
local real = (sh(("cd %q && pwd"):format(proj))):gsub("%s+$", "")
check("Claude Desktop: luamemo-<scope> → memo mcp --project <this project>",
    cd["luamemo-repo-app"] and json.encode(cd["luamemo-repo-app"].args) == json.encode({ "mcp", "--project", real }),
    json.encode(cd))
os.execute(("rm -rf %q %q"):format(home, proj))
end)

section("a downloaded project's .luamemorc", function()
io.write("\n--- a downloaded project's settings ---\n")
-- A project with no git (a zip download, a tarball, a copied folder) brings a
-- .luamemorc nobody on this machine wrote. It was used as the user's own: its MEMO_LUA
-- ran the project's own script on `memo brief` (the plugin's session-start hook), and its
-- embedder URL + {secret:NAME} headers sent the vault's key to the project's server.
local base = os.tmpname(); os.remove(base)
local home, proj, mark = base .. "-home", base .. "-zip", base .. "-RAN"
os.execute(("mkdir -p %q %q/tools"):format(home, proj))
local s = assert(io.open(proj .. "/tools/lua.sh", "w"))
s:write(("#!/bin/sh\necho ran > %q\nexec %q \"$@\"\n"):format(mark, LUA_ABS)); s:close()
os.execute(("chmod +x %q"):format(proj .. "/tools/lua.sh"))
local rc = assert(io.open(proj .. "/.luamemorc", "w"))
rc:write("MEMO_LUA='./tools/lua.sh'\nMEMO_SCOPE='repo:zip'\n"); rc:close()
local DENV = ("env -u MEMO_LUA -u MEMO_DB -u MEMO_PROJECT HOME=%q XDG_CONFIG_HOME=%q LUA_PATH=%q MEMO_EMBEDDER=hash")
    :format(home, home .. "/.config", REPO_PATH)
local function dmemo(args) return sh(("cd %q && %s %q %s </dev/null"):format(proj, DENV, REPO .. "/cli/memo", args)) end
local o1 = dmemo("brief")
check("a project file memo didn't write is ignored (memo says why) — the project's script doesn't run",
    H.slurp(mark) == nil and o1:find("didn't write it", 1, true) ~= nil, o1:sub(1, 300))
-- … and the agent is told (stderr never reaches it): without this the memories went
-- into the user's database, scope "global", with nothing said.
local b1 = dmemo("brief 2>/dev/null")
check("… the brief the agent reads names it, and the user's step (memo config trust)",
    b1:find("settings: " .. proj .. "/.luamemorc is ignored", 1, true) ~= nil
    and b1:find("memo config trust", 1, true) ~= nil, b1)
dmemo("config trust")
local o2 = dmemo("config get MEMO_SCOPE")
check("trusted, it is used — but never its MEMO_LUA (code is named only by the user's own settings)",
    H.slurp(mark) == nil and o2:find("repo:zip", 1, true) ~= nil and o2:find("ignoring MEMO_LUA", 1, true) ~= nil,
    o2:sub(1, 300))
-- memo's own writes are trusted as written; a hand edit needs trusting again.
local fresh = base .. "-fresh"
os.execute(("mkdir -p %q"):format(fresh))
sh(("cd %q && %s %q config set MEMO_SCOPE repo:fresh </dev/null"):format(fresh, DENV, REPO .. "/cli/memo"))
local o3 = sh(("cd %q && %s %q config get MEMO_SCOPE </dev/null"):format(fresh, DENV, REPO .. "/cli/memo"))
check("a project file memo config set wrote is used as it is", o3 == "repo:fresh", o3)
-- calibrate / org link write through the same writer: a project's .luamemorc that is a
-- symlink is left alone (it was appended to through the link).
local other = base .. "-other.json"
local of = assert(io.open(other, "w")); of:write('{"theme":1}\n'); of:close()
local linked = base .. "-linked"
os.execute(("mkdir -p %q && ln -s %q %q"):format(linked, other, linked .. "/.luamemorc"))
local wr = sh(("cd %q && %s %q -e %q 2>&1"):format(linked, DENV, LUA_ABS, "package.path = '" .. REPO_PATH
    .. "' .. package.path; local ok, err = require('luamemo.cli._common').rc_set('" .. linked
    .. "/.luamemorc', 'MEMO_DB', '/x.db'); io.write(tostring(ok), ' ', tostring(err))"))
check("memo's settings writer leaves a symlinked project file alone (and the file it points to)",
    wr:find("symbolic link", 1, true) ~= nil and H.slurp(other) == '{"theme":1}\n', wr)
os.execute(("rm -rf %q %q %q %q %q %q"):format(home, proj, mark, fresh, other, linked))
end)

section("memo runs its own modules from any directory", function()
io.write("\n--- memo outside the checkout ---\n")
-- It found them only from the repository's root (./?.lua) or an installed rock — from
-- a project it loaded no luamemo, or an older installed one; the plugin's session-start
-- hook runs the clone's memo from the user's project.
local dir = os.tmpname(); os.remove(dir)
os.execute(("mkdir -p %q && ln -s %q %q"):format(dir, REPO .. "/cli/memo", dir .. "/memo"))
local f = assert(io.open(dir .. "/.luamemorc", "w")); f:write("MEMO_DB='elsewhere-db'\n"); f:close()
H.trust_rc(dir .. "/.luamemorc")
local out, code = sh(("cd %q && env -u LUA_PATH -u MEMO_DB MEMO_PROJECT= MEMO_LUA=%q ./memo config get MEMO_DB"):format(
    dir, LUA_ABS))
check("from a project directory, through a symlink, with no LUA_PATH", code == 0 and out == "elsewhere-db", out)
os.execute(("rm -rf %q"):format(dir))
end)

section("capture hooks save through memo", function()
io.write("\n--- capture hooks ---\n")
local base = os.tmpname(); os.remove(base)
local proj, bin, tr = base .. "-proj", base .. "-bin", base .. "-transcript.jsonl"
os.execute(("mkdir -p %q %q && ln -s %q %q"):format(proj, bin, REPO .. "/cli/memo", bin .. "/memo"))
local f = assert(io.open(proj .. "/.luamemorc", "w"))
f:write(("MEMO_DB=%s\nMEMO_EMBEDDER='hash'\n"):format(q(db_name))); f:close()
H.trust_rc(proj .. "/.luamemorc")
local t = assert(io.open(tr, "w"))
t:write(json.encode({ type = "human", content = "remember: deploys go through the staging gate" }), "\n",
    json.encode({ type = "assistant", content = { { type = "text", text = "noted, the staging gate first" } } }), "\n")
t:close()
local HSCOPE = SCOPE .. "-hook"
local db = require("luamemo.db")
local function saved() return tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope = ?", HSCOPE)) end
-- The project's .luamemorc names the database — the hook's environment doesn't.
local function hook(path)
    return sh(("cd %q && env -u MEMO_DB MEMO_PROJECT= PATH=%q MEMO_LUA=%q LUA_PATH=%q MEMO_SCOPE=%q "
        .. "CLAUDE_TRANSCRIPT_PATH=%q CLAUDE_SESSION_ID=hooktest bash %q"):format(proj, path, LUA_ABS, REPO_PATH,
        HSCOPE, tr, REPO .. "/hooks/claude/pre_compact.sh"))
end
local _, c1 = hook("/usr/bin:/bin")
check("no memo installed → the hook does nothing (exit 0)", c1 == 0 and saved() == 0, saved())
local _, c2 = hook(bin .. ":/usr/bin:/bin")
local body = db.value("SELECT body FROM lm_memories WHERE scope = ?", HSCOPE) or ""
check("with memo installed the hook saves the last messages into the project's database", c2 == 0 and saved() == 1
    and body:find("staging gate", 1, true) ~= nil, body)
db.run("DELETE FROM lm_memories WHERE scope = ?", HSCOPE)

-- As Claude Code runs them: the hook input is JSON on stdin (no CLAUDE_* variables)
-- and the transcript's lines are {"type": "user" | "assistant", "message": {...}}.
-- Both hooks saved nothing that way (they read only the variables), and given the
-- variable they saved "ASSISTANT: " lines with every word lost (they read a
-- top-level "content" and type "human").
local cc = base .. "-cc.jsonl"
local w = assert(io.open(cc, "w"))
for _, line in ipairs({
    { type = "user", message = { role = "user", content = "Please move the cache to LRU eviction." } },
    { type = "assistant", message = { role = "assistant", content = {
        { type = "text", text = "Moved the cache to LRU, capacity 512." },
        { type = "tool_use", id = "t1", name = "Edit", input = {} } } } },
    { type = "user", message = { role = "user", content = { { type = "tool_result", tool_use_id = "t1",
        content = "TOOL OUTPUT" } } } },
    { type = "user", isMeta = true, message = { role = "user", content = "<command-name>/clear</command-name>" } },
    { type = "assistant", isSidechain = true, message = { role = "assistant", content = { { type = "text",
        text = "SUBAGENT TALK" } } } },
    { type = "assistant", message = { role = "assistant", content = { { type = "text", text = "Tests pass." } } } },
}) do w:write(json.encode(line), "\n") end
w:close()
local function cc_hook(script, session)
    local input = json.encode({ session_id = session, transcript_path = cc, hook_event_name = "Hook" })
    return sh(("cd %q && printf '%%s' %s | env -u MEMO_DB -u MEMO_SCOPE MEMO_PROJECT= PATH=%q MEMO_LUA=%q "
        .. "LUA_PATH=%q XDG_CACHE_HOME=%q bash %q"):format(proj, q(input), bin .. ":/usr/bin:/bin", LUA_ABS,
        REPO_PATH, proj .. "/.cache", REPO .. "/hooks/claude/" .. script))
end
local function bodies(scope)
    local out = {}
    for _, r in ipairs(db.query("SELECT body FROM lm_memories WHERE scope = ? ORDER BY id", scope) or {}) do
        out[#out + 1] = r.body
    end
    return out
end
local pc_out = cc_hook("pre_compact.sh", "cc-pre")
local pc = bodies("session:cc-pre")
check("pre_compact as Claude Code runs it: the conversation's text, in session:<session_id>", #pc == 1
    and pc[1] == "USER: Please move the cache to LRU eviction.\nASSISTANT: Moved the cache to LRU, capacity 512.\n"
        .. "ASSISTANT: Tests pass.", tostring(pc[1]))
check("… tool calls / results, meta and subagent lines left out; nothing printed", pc_out == ""
    and not tostring(pc[1]):find("TOOL OUTPUT", 1, true) and not tostring(pc[1]):find("SUBAGENT", 1, true)
    and not tostring(pc[1]):find("/clear", 1, true), pc_out)
-- Tier 0: the digest's raw input, not what searches return (at tier 1 every unscoped
-- search got the whole transcript chunks).
local ops = require("luamemo.ops")   -- what memory_search runs (tier_min 1 by default)
local default_hits, all_hits = 0, 0
for _, r in ipairs(ops.search({ query = "LRU eviction capacity", limit = 20 }, { tier_min = 1 }) or {}) do
    if r.scope == "session:cc-pre" then default_hits = default_hits + 1 end
end
for _, r in ipairs(ops.search({ query = "LRU eviction capacity", limit = 20, tier_min = 0 }, { tier_min = 1 }) or {}) do
    if r.scope == "session:cc-pre" then all_hits = all_hits + 1 end
end
check("… saved at tier 0: not in a default search (tier_min 1), there with tier_min 0",
    tonumber(db.value("SELECT tier FROM lm_memories WHERE scope = 'session:cc-pre'")) == 0
    and default_hits == 0 and all_hits == 1, ("%d / %d"):format(default_hits, all_hits))
cc_hook("post_message.sh", "cc-post")
cc_hook("post_message.sh", "cc-post")
local pm = bodies("session:cc-post")
check("post_message as Claude Code runs it: saved once (cooldown per session)", #pm == 1
    and pm[1]:find("ASSISTANT: Tests pass.", 1, true) ~= nil, json.encode(pm))
check("… its cooldown file in the user's own 0700 cache directory, not the shared /tmp",
    H.slurp(proj .. "/.cache/luamemo/hooks/cc-post.last_save") ~= nil
    and H.mode(proj .. "/.cache/luamemo/hooks") == "700", H.mode(proj .. "/.cache/luamemo/hooks"))
-- A key pasted into the chat: the hooks (working since 0.5.0) would store it as typed,
-- and it came back in every search of the session. memo scrubs it before storing; the
-- text reaches memo on stdin, never its command line (ps shows that to other users).
local leak = "sk-proj-" .. ("Zq7r"):rep(10)
w = assert(io.open(cc, "w"))
w:write(json.encode({ type = "user", message = { role = "user", content = "the key is " .. leak } }), "\n")
w:close()
cc_hook("pre_compact.sh", "cc-key")
local kb = bodies("session:cc-key")
check("a key pasted into the chat is stored as [redacted]", #kb == 1 and not kb[1]:find(leak, 1, true)
    and kb[1]:find("the key is [redacted]", 1, true) ~= nil, json.encode(kb))
local spy = base .. "-spy"
os.execute(("mkdir -p %q"):format(spy))
local sf = assert(io.open(spy .. "/memo", "w"))
sf:write('#!/bin/sh\nprintf "%s\\n" "$@" > "$0.args"; cat > "$0.stdin"\n'); sf:close()
os.execute(("chmod +x %q"):format(spy .. "/memo"))
local input = json.encode({ session_id = "cc-spy", transcript_path = cc })
sh(("printf '%%s' %s | env PATH=%q bash %q"):format(q(input), spy .. ":/usr/bin:/bin",
    REPO .. "/hooks/claude/pre_compact.sh"))
local args, stdin = H.slurp(spy .. "/memo.args") or "", H.slurp(spy .. "/memo.stdin") or ""
check("… the conversation goes to memo on stdin (--body -), not on its command line",
    stdin:find("the key is", 1, true) ~= nil and not args:find("the key is", 1, true)
        and args:find("--body\n-\n", 1, true) ~= nil, args)
db.run("DELETE FROM lm_memories WHERE scope IN (?, ?, ?)", "session:cc-pre", "session:cc-post", "session:cc-key")
os.execute(("rm -rf %q %q %q %q %q"):format(proj, bin, tr, cc, spy))
end)

section("memo write: --body - and a flag without its value", function()
io.write("\n--- memo write flags ---\n")
local WS = SCOPE .. "-stdin"
local out, code = sh(("printf 'from stdin: a/b \"q\"' | %s ./cli/memo write --scope %s --title t --body -")
    :format(ENV, q(WS)))
local body = require("luamemo.db").value("SELECT body FROM lm_memories WHERE scope = ?", WS)
check("--body - reads the body from stdin, as given", code == 0 and body == 'from stdin: a/b "q"', out)
local id = tonumber(((json.decode(out) or {}).memory or {}).id)
sh(("%s ./cli/memo update %d --body %s"):format(ENV, id or 0, q("now MEMO_TOKEN=abc123def456xyz")))
check("an update is scrubbed too", require("luamemo.db").value("SELECT body FROM lm_memories WHERE id = ?", id)
    == "now MEMO_TOKEN=[redacted]")
local _, c2 = sh(("%s timeout 20 ./cli/memo write --scope %s --title"):format(ENV, q(WS)))
check("a flag without its value → exit 2 with a message (it looped forever)", c2 == 2, c2)
require("luamemo.db").run("DELETE FROM lm_memories WHERE scope = ?", WS)
end)

section("secret-store off command lines; index ingest where the brief looks", function()
io.write("\n--- secret-store / index ingest ---\n")
local REPO = (sh("pwd")):gsub("%s+$", "")
local tmp = os.tmpname(); os.remove(tmp)
os.execute(("mkdir -p %q %q %q"):format(tmp .. "/bin", tmp .. "/home", tmp .. "/proj/src"))
-- a jq that logs its arguments, then runs the real one: a command line is readable by any
-- local user (ps, /proc/<pid>/cmdline) — the value went there as --arg v
local real_jq = (sh("command -v jq")):gsub("%s+$", "")
local f = assert(io.open(tmp .. "/bin/jq", "w"))
f:write(("#!/bin/sh\nprintf '%%s\\n' \"$@\" >> %q\nexec %q \"$@\"\n"):format(tmp .. "/jq.args", real_jq))
f:close()
os.execute(("chmod +x %q"):format(tmp .. "/bin/jq"))
local secret = "sk-test-NOT-ON-ARGV-123456"
local sf = assert(io.open(tmp .. "/secret.txt", "w")); sf:write(secret); sf:close()
-- (its own HOME and XDG dirs: the vault key it creates must not land in the run's shared
-- XDG_CONFIG_HOME, where the other test files would find it)
local SENV = ("HOME=%q XDG_CONFIG_HOME=%q XDG_DATA_HOME=%q MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q")
    :format(tmp .. "/home", tmp .. "/xdg-config", tmp .. "/xdg-data", tmp .. "/s.db", H.lua_bin())
local out = sh(("(env PATH=%q %s ./cli/memo secret-store CLITEST --file %q 2>/dev/null)")
    :format(tmp .. "/bin:" .. os.getenv("PATH"), SENV, tmp .. "/secret.txt"))
check("secret-store: stored, the value on no command line (jq reads it on stdin)",
    out:find('"ok": true', 1, true) ~= nil and not (H.slurp(tmp .. "/jq.args") or ""):find(secret, 1, true), out)
-- the map memo index ingest builds is the one the brief and the index_* tools read
-- (it built codeindex:default; they looked in codeindex:<project>)
local pf = assert(io.open(tmp .. "/proj/src/a.lua", "w"))
pf:write("local M = {}\nfunction M.hello() return 1 end\nreturn M\n"); pf:close()
local IENV = SENV .. " MEMO_SCOPE=repo:clidemo"
local ing = sh(("cd %q && %s %q index ingest"):format(tmp .. "/proj", IENV, REPO .. "/cli/memo"))
local brief = sh(("cd %q && %s %q brief"):format(tmp .. "/proj", IENV, REPO .. "/cli/memo"))
check("index ingest builds codeindex:<MEMO_SCOPE's project> — the map the brief names",
    ing:find("scope=codeindex:clidemo", 1, true) ~= nil
    and brief:find("map:    codeindex:clidemo — 1 files", 1, true) ~= nil, ing .. "\n" .. brief)
os.execute(("rm -rf %q"):format(tmp))
end)

pcall(function()
    require("luamemo.db").run("DELETE FROM lm_memories WHERE scope IN (?, ?)", SCOPE, MOVED)
end)
finish()
