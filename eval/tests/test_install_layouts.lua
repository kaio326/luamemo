-- eval/tests/test_install_layouts.lua
-- The MCP server in the layouts luamemo is installed in, and the GGUF shim it finds there.
-- 0.5.3's bug: a LuaRocks install put a second, partial luamemo/embedders/native/ beside
-- mcp/; the server put its own directory first on the module path, loaded that copy of
-- ffi_shim.lua, and looked for gguf_shim.so next to it, while build.sh had put the .so next
-- to the real modules. The suite runs from the checkout, where every copy is one file, so
-- nothing noticed. Here the layouts are built in temporary directories (a rock's tree, a
-- plugin/checkout) and the server is started in them, with a recorder that logs which file
-- every module came from and a stand-in shim (eval/fixtures/stub_gguf_shim.c) in place of
-- llama.cpp. eval/release/smoke.sh does the same against the real, installed rock.
-- Run: luajit eval/tests/run.lua --only install_layouts

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local json = require("luamemo.json")
local T = H.new("install layouts")
local check, section, finish = T.check, T.section, T.finish

local repo = (H.sh("pwd"))
local lua = (H.sh("command -v '" .. H.lua_bin():gsub("'", "'\\''") .. "'"))
local have_cc = (H.sh("command -v cc")) ~= ""
local base = H.tmp_path("layouts")
os.execute(("rm -rf %q && mkdir -p %q"):format(base, base))

-- The module and C paths of the caller without what could supply luamemo (the checkout, the
-- working directory): only where the dependencies (luasocket …) are.
local function deps(var)
    local keep = {}
    for e in (os.getenv(var) or ""):gmatch("[^;]+") do
        if e:sub(1, 1) == "/" and e:sub(1, #repo) ~= repo then keep[#keep + 1] = e end
    end
    return table.concat(keep, ";")
end
local DEP_PATH, DEP_CPATH = deps("LUA_PATH"), deps("LUA_CPATH")

-- A shell prefix: nothing of the runner's MEMO_*, a home of its own, and the dependencies' paths.
-- `lua_path` (optional) goes first on LUA_PATH, as memo puts a rock's tree.
local function child_env(home, vars, lua_path)
    local p = { "env -i", ("HOME=%q"):format(home),
        ("PATH=%q"):format(lua:match("^(.*)/[^/]+$") .. ":/usr/bin:/bin"),
        ("LUA_PATH=%q"):format((lua_path and (lua_path .. ";") or "") .. DEP_PATH .. ";;"),
        ("LUA_CPATH=%q"):format(DEP_CPATH .. ";;") }
    for _, v in ipairs({ "MEMO_LIB_SQLITE3", "MEMO_LIB_SODIUM", "MEMO_LUA" }) do
        if os.getenv(v) then p[#p + 1] = ("%s=%q"):format(v, os.getenv(v)) end
    end
    for k, v in pairs(vars or {}) do p[#p + 1] = ("%s=%q"):format(k, v) end
    return table.concat(p, " ")
end

-- Start `server` (a mcp/server.lua) as a client does: initialize, then one tools/call each.
-- → the decoded replies by id (1 = initialize), the raw output. `launcher` replaces the
-- interpreter (the recorder).
local function serve(env, server, calls, cwd, launcher)
    local inp = base .. "/in.jsonl"
    local f = assert(io.open(inp, "w"))
    f:write(json.encode({ jsonrpc = "2.0", id = 1, method = "initialize", params = {} }), "\n")
    for i, c in ipairs(calls or {}) do
        f:write(json.encode({ jsonrpc = "2.0", id = i + 1, method = "tools/call",
            params = { name = c[1], arguments = c[2] or {} } }), "\n")
    end
    f:close()
    local out = H.sh(("cd %q && %s %s %q < %q"):format(cwd, env, launcher or lua, server, inp))
    local replies = {}
    for line in out:gmatch("[^\n]+") do
        local ok, msg = pcall(json.decode, line)
        if ok and type(msg) == "table" and msg.id then replies[msg.id] = msg end
    end
    return replies, out
end
local function text_of(msg) return msg and msg.result and msg.result.content and msg.result.content[1].text or "" end

local recorder = ("LUA_RECORDER_BIN=%q bash %q"):format(lua, repo .. "/eval/release/lua_recorder.sh")
-- → the files the recorder logged for luamemo modules: { module = file }
local function loaded(log)
    local m, n = {}, 0
    for line in (H.slurp(log) or ""):gmatch("[^\n]+") do
        local name, file = line:match("^(luamemo[^\t]*)\t(.+)$")
        if name then m[name] = file; n = n + 1 end
    end
    return m, n
end
local function outside(mods, dir)
    local bad = {}
    for name, file in pairs(mods) do if file:sub(1, #dir) ~= dir then bad[#bad + 1] = name .. " <- " .. file end end
    table.sort(bad)
    return bad
end

local function mkdirs(...)
    local q = {}
    for i, p in ipairs({ ... }) do q[i] = ("%q"):format(p) end
    os.execute("mkdir -p " .. table.concat(q, " "))
end
local function copy(from, to) os.execute(("cp -R %q %q"):format(from, to)) end
-- Run Lua `code` with `root`'s luamemo first on the module path → output, exit code.
local function in_tree(root, code, env_prefix)
    H.write_file(base .. "/probe.lua", ('package.path = %q .. package.path\n%s\n'):format(
        root .. "/?.lua;" .. root .. "/?/init.lua;", code))
    return H.sh(("cd %q && %s %q %q"):format(base, env_prefix or child_env(base .. "/probe-home"), lua, base .. "/probe.lua"))
end
local function build_stub(dest)
    mkdirs(dest:match("^(.*)/[^/]+$"))
    local _, code = H.sh(("cc -O2 -fPIC -shared %q -o %q -lm"):format(repo .. "/eval/fixtures/stub_gguf_shim.c", dest))
    return code == 0
end
local function no_shim_files(dir) os.execute(("find %q -name 'gguf_shim.so' -delete"):format(dir)) end

-- A model for the stand-in: the embedder only needs a file to exist.
local model = base .. "/stub.gguf"
H.write_file(model, "")

-- ── a rock's tree ────────────────────────────────────────────────────────────────
local tree = base .. "/tree"
local rockdir = tree .. "/lib/luarocks/rocks-5.1/luamemo/" .. require("luamemo").VERSION .. "-1"
local share = tree .. "/share/lua/5.1"
mkdirs(rockdir, share)
copy(repo .. "/mcp", rockdir .. "/mcp")
copy(repo .. "/gguf", rockdir .. "/gguf")
copy(repo .. "/luamemo", share .. "/luamemo")
no_shim_files(share)
local rock_server = rockdir .. "/mcp/server.lua"
local rock_home = base .. "/rock-home"
mkdirs(rock_home, base .. "/proj")
local gguf_vars = { MEMO_DB = base .. "/rock.db", MEMO_SCOPE = "repo:layouts", MEMO_EMBEDDER = "gguf_ffi",
    MEMO_GGUF_MODEL = model }

section("a rock's tree: the server runs the tree's modules, not a copy beside mcp/", function()
io.write("\n--- rock tree ---\n")
-- A copy of a module where 0.5.3's rock put one (the bookkeeping directory): it must never load.
local planted = rockdir .. "/luamemo/embedders/native"
mkdirs(planted)
H.write_file(planted .. "/ffi_shim.lua", 'error("PLANTED COPY LOADED")\n')
local log = base .. "/rock1.tsv"; os.remove(log)
local vars = { LUA_RECORDER_OUT = log }
for k, x in pairs(gguf_vars) do vars[k] = x end
local env = child_env(rock_home, vars, share .. "/?.lua;" .. share .. "/?/init.lua")   -- (what memo gives it)
local replies, out = serve(env, rock_server, { { "memory_search", { query = "anything" } } }, base .. "/proj", recorder)
local mods, n = loaded(log)
check("L1 the server answers and loads luamemo modules", replies[1] ~= nil and n > 20, ("%d modules; %s"):format(n, out:sub(1, 300)))
check("L1 ffi_shim came from the tree", (mods["luamemo.embedders.native.ffi_shim"] or ""):sub(1, #share) == share,
    tostring(mods["luamemo.embedders.native.ffi_shim"]))
local bad = outside(mods, share)
check("L1 no luamemo module came from beside mcp/", #bad == 0, table.concat(bad, "; "))
check("L1 the planted copy never ran", not out:find("PLANTED COPY LOADED", 1, true) and not text_of(replies[2]):find("PLANTED", 1, true))
os.execute(("rm -rf %q"):format(rockdir .. "/luamemo"))

-- Started on its own: no memo, no LUA_PATH for luamemo. Under the recorder: answering with the right
-- version is not enough, because a luamemo of the same version installed on this machine would
-- answer too — every module must come from the tree.
local function direct_start(server, tag)
    local log = base .. "/" .. tag .. ".tsv"; os.remove(log)
    local env = child_env(rock_home, { MEMO_DB = base .. "/" .. tag .. ".db", MEMO_EMBEDDER = "hash", LUA_RECORDER_OUT = log })
    local r, out = serve(env, server, {}, base .. "/proj", recorder)
    local ok, version = pcall(function() return r[1].result.serverInfo.version end)
    local mods, n = loaded(log)
    local bad = outside(mods, share)
    return ok and version == require("luamemo").VERSION and n > 20 and #bad == 0,
        ("%s | %d modules; elsewhere: %s"):format(out:sub(1, 200), n, table.concat(bad, "; "))
end
check("L2 started directly (no memo, no LUA_PATH): its own version, every module from the tree",
    direct_start(rock_server, "rock2"))
-- … by a path with a doubled slash (ls -d of a rock's directory ends in one).
check("L2 … also through a path with a doubled slash", direct_start(rockdir .. "//mcp/server.lua", "rock3"))
end)

-- ── the plugin / a checkout ──────────────────────────────────────────────────────
section("a plugin or checkout: the root's modules win over another copy on LUA_PATH", function()
io.write("\n--- plugin ---\n")
local plugin, other = base .. "/plugin", base .. "/other"
mkdirs(plugin, other)
copy(repo .. "/mcp", plugin .. "/mcp")
copy(repo .. "/luamemo", plugin .. "/luamemo")
copy(repo .. "/luamemo", other .. "/luamemo")
no_shim_files(plugin); no_shim_files(other)
local log = base .. "/plugin.tsv"; os.remove(log)
local env = child_env(base .. "/plugin-home", { MEMO_DB = base .. "/plugin.db", MEMO_EMBEDDER = "hash",
    LUA_RECORDER_OUT = log }, other .. "/?.lua;" .. other .. "/?/init.lua")
mkdirs(base .. "/plugin-home")
local replies = serve(env, plugin .. "/mcp/server.lua", { { "memory_search", { query = "anything" } } }, base .. "/proj", recorder)
local mods, n = loaded(log)
local bad = outside(mods, plugin)
check("L3 every luamemo module came from the plugin's own root", replies[1] ~= nil and n > 20 and #bad == 0,
    ("%d modules; %s"):format(n, table.concat(bad, "; ")))

-- Where gguf/build.sh is, as the install knows it: a rock's directory (with a gguf/ beside mcp/), the
-- checkout, and a layout that has none (the hint then says where to get it, not "ask memo gguf status").
local script, code = in_tree(share, 'io.write(require("luamemo.embedders.native.ffi_shim").build_script() or "nil")')
check("L8 build_script() finds the rock's own gguf/build.sh", code == 0 and script == rockdir .. "/gguf/build.sh", script)
script = in_tree(repo, 'io.write(require("luamemo.embedders.native.ffi_shim").build_script() or "nil")')
check("L8 … and the checkout's", script == repo .. "/gguf/build.sh", script)
local hint = in_tree(other, 'local s = require("luamemo.embedders.native.ffi_shim"); io.write(tostring(s.build_script()), "|", s.build_hint())')
check("L8 where it can't be found, the hint says where to get it", hint:find("^nil|gguf/build.sh") and hint:find("github.com", 1, true)
    and not hint:find("memo gguf status", 1, true), hint)
-- … and every caller says it the same way: calibrate's line is pasteable (a comment, not prose), status and the
-- prebuilt runtime's message carry the hint.
local step = in_tree(other, 'io.write(require("luamemo.cli.calibrate").upgrade_guide({}))')
local line = step:match("\n%s*(LLAMA_DIR=[^\n]*)")
H.write_file(base .. "/cmd.sh", (line or "") .. "\n")
local _, syntax = H.sh(("bash -n %q"):format(base .. "/cmd.sh"))
check("L8 the build line calibrate prints is valid shell where the script can't be found",
    line ~= nil and syntax == 0 and line:find("   # from luamemo's source", 1, true) ~= nil, step:sub(-300))
local status_out = in_tree(other, 'require("luamemo.cli.gguf").run({ "status" })')
check("L8 memo gguf status: where to get gguf/build.sh when it isn't here", status_out:find("build:     not found from here — get gguf/build.sh (from luamemo's source", 1, true) ~= nil, status_out:sub(1, 500))
local why = in_tree(other, 'local _, why = require("luamemo.embedders.native.bundle").available(); io.write(tostring(why))')
check("L8 the prebuilt runtime's message carries the same hint", why:find("gguf/build.sh (from luamemo's source", 1, true) ~= nil
    and not why:find("memo gguf status", 1, true), why:sub(1, 300))
end)

-- ── the shim: one place, for memo and for the server ─────────────────────────────
section("the GGUF shim is looked for where build.sh puts it, by memo and by the server", function()
io.write("\n--- shim ---\n")
-- L5: build.sh --where is what luamemo looks for (no llama.cpp needed for --where), and it is the place
-- the documentation names: <data dir>/native/gguf_shim.so.
H.write_file(base .. "/shim_path.lua", ('package.path = %q .. package.path\nio.write(require("luamemo.embedders.native.ffi_shim").shim_path())\n')
    :format(repo .. "/?.lua;" .. repo .. "/?/init.lua;"))
local where_home = base .. "/where-home"
mkdirs(where_home)
local function where(label, expected, extra_env, no_home)
    local pre = ("env -u XDG_DATA_HOME -u MEMO_GGUF_SHIM -u MEMO_GEMMA_SHIM %s PATH=%q %s"):format(
        no_home and "-u HOME" or ("HOME=" .. ("%q"):format(where_home)),
        lua:match("^(.*)/[^/]+$") .. ":/usr/bin:/bin", extra_env or "")
    local want = H.sh(("cd %q && %s bash gguf/build.sh --where"):format(repo, pre))
    local got = H.sh(("cd %q && %s %q %q"):format(repo, pre, lua, base .. "/shim_path.lua"))
    check("L5 build.sh --where is where luamemo looks (" .. label .. ")", want == expected and got == expected,
        ("expected: %s | build.sh: %s | luamemo: %s"):format(expected, want, got))
end
where("default data dir", where_home .. "/.local/share/luamemo/native/gguf_shim.so")
where("XDG_DATA_HOME set", base .. "/xdg/luamemo/native/gguf_shim.so", ("XDG_DATA_HOME=%q"):format(base .. "/xdg"))
where("HOME unset", "./.local/share/luamemo/native/gguf_shim.so", nil, true)

-- L9: a place that depends on the working directory is never loaded from (a project could put its own
-- library there), and build.sh refuses it. HOME and XDG_DATA_HOME unset, a library at ./.local/share/….
local rel = base .. "/relative-cwd"
mkdirs(rel .. "/.local/share/luamemo/native")
-- The fixture: a library whose constructor writes ./LOADED when something dlopens it (not a library at all
-- without a C compiler: then only the error texts below can tell).
local relso = rel .. "/.local/share/luamemo/native/gguf_shim.so"
H.write_file(base .. "/ctor.c", '#include <stdio.h>\n__attribute__((constructor)) static void init(void) { FILE *f = fopen("LOADED", "w"); if (f) fclose(f); }\n')
local built_ctor = have_cc and select(2, H.sh(("cc -shared -fPIC -o %q %q"):format(relso, base .. "/ctor.c"))) == 0
if not built_ctor then H.write_file(relso, "not a library") end
local function was_loaded() local f = io.open(rel .. "/LOADED"); if f then f:close(); os.remove(rel .. "/LOADED"); return true end return false end
local unset = "env -u HOME -u XDG_DATA_HOME -u MEMO_GGUF_SHIM -u MEMO_GEMMA_SHIM PATH=" .. ("%q"):format(lua:match("^(.*)/[^/]+$") .. ":/usr/bin:/bin")
local lpath = repo .. "/?.lua;" .. repo .. "/?/init.lua;"
H.write_file(base .. "/relative.lua", ('package.path = %q .. package.path\nlocal s = require("luamemo.embedders.native.ffi_shim")\n'
    .. 'local ok, err = pcall(s.load)\nio.write(tostring(s.missing()), "|", tostring(ok), "|", tostring(err))\n'):format(lpath))
local rout = H.sh(("cd %q && %s %q %q"):format(rel, unset, lua, base .. "/relative.lua"))
local r_missing, r_ok, r_err = rout:match("^(.-)|(%a+)|(.*)$")
check("L9 luamemo refuses a shim place relative to the working directory, and says what to set",
    r_missing and r_missing:find("relative to the working directory", 1, true) and r_missing:find("MEMO_GGUF_SHIM", 1, true), rout:sub(1, 400))
-- (load() itself: its error is the refusal — a load() that skipped the check would fail with the dlopen error)
check("L9 … and load() itself refuses it", r_ok == "false" and (r_err or ""):find("relative to the working directory", 1, true) ~= nil,
    tostring(r_err):sub(1, 300))
check("L9 … without loading the library", not was_loaded())
-- … `memo gguf status` doesn't dlopen it either (a status that tried would say "loads, but this GGUF shim was built
-- before luamemo 0.5.0 …" for the fixture, which has no lmembed_last_truncated, or "present, but it doesn't load"
-- where it isn't a library), and `memo gguf install` has no place to put a download.
H.write_file(base .. "/relative_status.lua", ('package.path = %q .. package.path\nrequire("luamemo.cli.gguf").run({ "status" })\n'):format(lpath))
local rst = H.sh(("cd %q && %s %q %q"):format(rel, unset, lua, base .. "/relative_status.lua"))
check("L9 memo gguf status: not installed, nothing loaded from the relative place",
    rst:find("state:     not installed", 1, true) and rst:find("relative to the working directory", 1, true)
    and not rst:find("doesn't load", 1, true) and not rst:find("state:     loads", 1, true), rst:sub(1, 500))
check("L9 … and never dlopen'd the library to find out", not was_loaded())
H.write_file(base .. "/relative_install.lua", ('package.path = %q .. package.path\nlocal b = require("luamemo.embedders.native.bundle")\n'
    .. 'local plat = b.platform()\nif not plat then io.write("skip") return end\nb.cpu_ok = function() return true end\n'
    .. 'package.loaded["luamemo.embedders.native.bundles"] = { version = require("luamemo").VERSION,\n'
    .. '  [plat] = { sha256 = "aa", asset = "luamemo-gguf-x-" .. plat .. ".tar.gz" } }\n'
    .. 'local r, why = b.available()\nio.write(tostring(r), "|", tostring(why))\n'):format(lpath))
local rin = H.sh(("cd %q && %s %q %q"):format(rel, unset, lua, base .. "/relative_install.lua"))
check("L9 the prebuilt runtime has no place to install into either", rin == "skip" or (rin:find("^nil|") and rin:find("no place to install", 1, true)), rin:sub(1, 300))
local bout, bcode = H.sh(("cd %q && %s LLAMA_DIR=/nonexistent bash %q"):format(rel, unset, repo .. "/gguf/build.sh"))
check("L9 build.sh refuses it too", bcode ~= 0 and bout:find("HOME is not set", 1, true) ~= nil, bout:sub(1, 300))

-- L7: with no runtime anywhere, memo gguf status and memo doctor say where it was looked for and the fixes.
local home7, proj7 = base .. "/l7-home", base .. "/l7-proj"
mkdirs(proj7)
local prefix7 = "env -u MEMO_GGUF_SHIM -u MEMO_GEMMA_SHIM " .. H.memo_env(home7, proj7) ..
    (" MEMO_EMBEDDER=gguf_ffi MEMO_GGUF_MODEL=%q MEMO_DB=%q MEMO_SKIP_EMBED_PROBE=true"):format(model, home7 .. "/l7.db")
local st = H.memo_in(prefix7, proj7, "gguf status")
check("L7 memo gguf status: not installed, the place it looked, and both fixes",
    st:find("state:     not installed", 1, true) and st:find(home7 .. "/.local/share/luamemo/native/gguf_shim.so", 1, true)
    and st:find("memo gguf install", 1, true) and st:find("build.sh", 1, true), st:sub(1, 600))
local dout, dcode = H.memo_in(prefix7, proj7, "doctor")
check("L7 memo doctor fails and names the fix", dcode == 1 and dout:find("[FAIL] the GGUF runtime is not installed", 1, true) ~= nil
    and dout:find("[OK] No issues detected", 1, true) == nil, dout:sub(-500))

-- L10: MEMO_GGUF_SHIM names a file that isn't there: building can't help (the override wins), so the
-- message says so, offers the two fixes that work, and doesn't hint at a pre-0.5.4 file.
local prefix10 = prefix7 .. " MEMO_GGUF_SHIM=/nonexistent/x.so"
local st10 = H.memo_in(prefix10, proj7, "gguf status")
check("L10 memo gguf status: the override is the place in force, and it is missing",
    st10:find("/nonexistent/x.so (MEMO_GGUF_SHIM)", 1, true) and st10:find("state:     not installed", 1, true)
    and st10:find("wins over a runtime built from source", 1, true) and st10:find("memo gguf install", 1, true)
    and st10:find("memo config unset --user MEMO_GGUF_SHIM", 1, true), st10:sub(1, 700))
-- (and no hint at a pre-0.5.4 file even where one exists: a copy of the modules with a legacy file beside them)
local legacy = base .. "/legacy-tree"
mkdirs(legacy)
copy(repo .. "/luamemo", legacy .. "/luamemo")
H.write_file(legacy .. "/luamemo/embedders/native/gguf_shim.so", "x")
local missing_code = 'io.write(require("luamemo.embedders.native.ffi_shim").missing() or "nil")'
local with_override = in_tree(legacy, missing_code, child_env(base .. "/probe-home", { MEMO_GGUF_SHIM = "/nonexistent/x.so" }))
local without_override = in_tree(legacy, missing_code, child_env(base .. "/probe-home"))
check("L10 the override message doesn't point at a pre-0.5.4 file (the default one does, where one exists)",
    without_override:find("before luamemo 0.5.4", 1, true) and with_override:find("wins over a runtime built from source", 1, true)
    and not with_override:find("before luamemo 0.5.4", 1, true), with_override:sub(1, 300))
local d10, c10 = H.memo_in(prefix10, proj7, "doctor")
check("L10 memo doctor names the override and exits 1", c10 == 1 and d10:find("[FAIL] the GGUF runtime is not at /nonexistent/x.so", 1, true) ~= nil,
    d10:sub(-400))

if not have_cc then io.write("[SKIP] L4, L6: no C compiler for a stand-in shim\n"); return end

-- L4: the checkout's memo and its MCP server with the stand-in shim at the default place.
local home, proj = base .. "/l4-home", base .. "/l4-proj"
mkdirs(proj)
local shimfile = home .. "/.local/share/luamemo/native/gguf_shim.so"
check("L4 the stand-in builds", build_stub(shimfile))
local prefix = "env -u MEMO_GGUF_SHIM -u MEMO_GEMMA_SHIM " .. H.memo_env(home, proj) ..
    (" MEMO_EMBEDDER=gguf_ffi MEMO_GGUF_MODEL=%q MEMO_DB=%q MEMO_SCOPE=repo:layouts"):format(model, home .. "/l4.db")
local out, code = H.memo_in(prefix, proj, [[write --kind fact --title "layouts deploy" --body "releases go through the canary ring first"]])
check("L4 memo write with gguf_ffi", code == 0 and out:find("layouts deploy", 1, true) ~= nil, out:sub(1, 300))
out = H.memo_in(prefix, proj, [[search "canary ring"]])
check("L4 memo search finds it", out:find("layouts deploy", 1, true) ~= nil, out:sub(1, 300))
local s = H.mcp_session(prefix, { cwd = proj, cmd = ("%q mcp"):format(repo .. "/cli/memo") })
local w = s.call("memory_write", { kind = "fact", title = "layouts mcp note", body = "the nightly build runs on the blue pool" })
local r = s.call("memory_search", { query = "blue pool" })
local stderr = s.close()
check("L4 the MCP server writes with gguf_ffi", not w.error, tostring(w.error))
check("L4 … and searches", not r.error and json.encode(r):find("layouts mcp note", 1, true) ~= nil, tostring(r.error or json.encode(r)):sub(1, 300) .. stderr:sub(1, 200))

-- With the runtime in place: status names the checkout's build.sh and the default place; doctor is clear.
local st4 = H.memo_in(prefix, proj, "gguf status")
check("L4 memo gguf status: loads, the default place, and the checkout's gguf/build.sh",
    st4:find("state:     loads", 1, true) and st4:find(shimfile .. " (the default place)", 1, true)
    and st4:find("build:     " .. repo .. "/gguf/build.sh", 1, true), st4:sub(1, 600))
local d4, c4 = H.memo_in(prefix, proj, "doctor")
check("L4 memo doctor: no GGUF failure, exit 0", c4 == 0 and not d4:find("[FAIL]", 1, true), d4:sub(-400))
-- … and an override that wins over a runtime built from source is said so.
local other_so = home .. "/other.so"
os.execute(("cp %q %q"):format(shimfile, other_so))
local st4b = H.memo_in(prefix .. (" MEMO_GGUF_SHIM=%q"):format(other_so), proj, "gguf status")
check("L4 memo gguf status: a built shim is unused while MEMO_GGUF_SHIM is set",
    st4b:find(other_so .. " (MEMO_GGUF_SHIM)", 1, true) and st4b:find("unused while MEMO_GGUF_SHIM is set", 1, true)
    and st4b:find("state:     loads", 1, true), st4b:sub(1, 600))

-- L6: a shim left next to the modules (where build.sh used to put it) is named, not loaded.
local plugin = base .. "/plugin"
local old = plugin .. "/luamemo/embedders/native/gguf_shim.so"
check("L6 the stand-in builds at the old place", build_stub(old))
local home6 = base .. "/l6-home"
mkdirs(home6)
local env6 = child_env(home6, { MEMO_DB = base .. "/l6.db", MEMO_SCOPE = "repo:layouts", MEMO_EMBEDDER = "gguf_ffi",
    MEMO_GGUF_MODEL = model })
local replies = serve(env6, plugin .. "/mcp/server.lua", { { "memory_search", { query = "anything" } } }, base .. "/proj")
local msg = text_of(replies[2])
check("L6 the server's error names the old file, the expected place and memo gguf install",
    msg:find(old, 1, true) and msg:find(home6 .. "/.local/share/luamemo/native/gguf_shim.so", 1, true)
    and msg:find("memo gguf install", 1, true), msg:sub(1, 500))
os.execute(("rm -f %q"):format(old))
end)

os.execute(("rm -rf %q"):format(base))
finish()
