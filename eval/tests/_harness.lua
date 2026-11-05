-- eval/tests/_harness.lua
-- Shared helpers for eval/tests/test_*.lua (not a test file itself — the suite
-- runs test_*.lua only). Load with:
--   local H = require("eval.tests._harness")
--   local T = H.new("Federation client")          -- the results line's label
--   local check, section = T.check, T.section     -- … T.finish() at the end

local H = {}

--- Result counting. check / pass / fail print [PASS] / [FAIL] lines (the suite
--- counts those); section runs a block under pcall so a crash fails that block
--- instead of the run; finish prints the totals and exits 0 / 1.
function H.new(label)
    local T = { passed = 0, failed = 0 }
    function T.pass(m) T.passed = T.passed + 1; io.write("[PASS] " .. m .. "\n") end
    function T.fail(m) T.failed = T.failed + 1; io.write("[FAIL] " .. m .. "\n") end
    function T.check(name, cond, detail)
        if cond then T.pass(name) else T.fail(name .. (detail and (" — " .. tostring(detail)) or "")) end
    end
    -- `after` (optional) runs when the block ends, crashed or not: put back what the block stubbed.
    function T.section(name, fn, after)
        local ok, err = pcall(fn)
        if not ok then T.fail(name .. " crashed: " .. tostring(err)) end
        if after then pcall(after) end
    end
    function T.finish()
        io.write(("\n=== %s results: %d passed, %d failed ===\n"):format(label, T.passed, T.failed))
        os.exit(T.failed > 0 and 1 or 0)
    end
    return T
end

-- pcall's results kept whole (a nil in the middle of them does not cut them short), and given back — or raised again
local function packed(ok, ...) return { ok = ok, n = select("#", ...), ... } end
local function unpacked(res)
    if not res.ok then error(res[1], 0) end
    return unpack(res, 1, res.n)
end

--- Run fn(...) with luamemo's clock `delta_us` microseconds in the past (util.now_us), then put the clock back — also
--- when fn raises (the error is raised again after) → fn's results.
function H.at_age(delta_us, fn, ...)
    local util = require("luamemo.util")
    local real = util.now_us
    return H.with(util, "now_us", function() return real() - delta_us end, fn, ...)
end

--- Run fn(...) with tbl[key] replaced by `stub`, then put the original back — also when fn raises (the error is
--- raised again after) → fn's results. For a stub of a module function, a config value, a clock.
function H.with(tbl, key, stub, fn, ...)
    local real = tbl[key]
    tbl[key] = stub
    local res = packed(pcall(fn, ...))
    tbl[key] = real
    return unpacked(res)
end

--- Run fn(...) with tbl[key] (a function of luamemo.db taking the SQL first: run, first, value, query …) replaced so that
--- a statement containing `fragment` (plain text; "" is every statement) goes to `handler(real, sql, ...)` — what it
--- returns is the statement's result: `nil, "why"` to make it fail, `real(sql, ...)` after a side effect to count it or
--- to race it — and every other statement to the original. The original is put back after, also when fn raises
--- → fn's results.
function H.on_sql(tbl, key, fragment, handler, fn, ...)
    local real = tbl[key]
    return H.with(tbl, key, function(sql, ...)
        if tostring(sql):find(fragment, 1, true) then return handler(real, sql, ...) end
        return real(sql, ...)
    end, fn, ...)
end

--- Run fn(...) with the statements of luamemo.db's `key` function (run, query, …) that contain `fragment` failing ("boom")
--- and what fn writes to io.stderr kept → fn's first result, the lines written to stderr (one entry per write).
function H.failing_sql(key, fragment, fn, ...)
    local db, lines, res = require("luamemo.db"), {}, nil
    local args = { ... }
    H.with(io, "stderr", { write = function(_, ...) lines[#lines + 1] = table.concat({ ... }) end }, function()
        res = H.on_sql(db, key, fragment, function() return nil, "boom" end, fn, unpack(args))
    end)
    return res, lines
end

--- Run fn(...) with a trigger in place that makes a statement fail, then drop it — also when fn raises (the error is
--- raised again after) → fn's results. `body` is the trigger from its timing on: "BEFORE DELETE ON lm_memories BEGIN
--- SELECT RAISE(ABORT, 'no'); END". Temporary (this connection only) unless `shared` is true, for a test that runs
--- another process on the same database.
function H.with_trigger(name, body, fn, shared, ...)
    local db = require("luamemo.db")
    assert(db.run(("CREATE %sTRIGGER %s %s"):format(shared and "" or "TEMP ", name, body)))
    local res = packed(pcall(fn, ...))
    db.run("DROP TRIGGER IF EXISTS " .. name)
    return unpacked(res)
end

--- Are two values equal, tables by content (key order does not matter)? For metadata read back from the database.
function H.same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not H.same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

--- Hold an flock(2) on `path` from a process of its own for up to `seconds`, as a running `memo maintain` holds its
--- lock → release(), held. release() ends that process (the kernel then drops the lock: nothing is cleaned up after
--- it); held says whether the lock was taken.
function H.hold_flock(path, seconds)
    local script, ready = os.tmpname(), os.tmpname()
    os.remove(ready)
    local f = assert(io.open(script, "w"))
    f:write(([[
local ffi = require("ffi")
ffi.cdef("int open(const char *path, int flags, ...); int flock(int fd, int operation); unsigned int sleep(unsigned int seconds);")
local f = assert(io.open(%q, "a")); f:close()
assert(ffi.C.flock(ffi.C.open(%q, 2), 6) == 0)
local r = assert(io.open(%q, "w")); r:write("1"); r:close()
ffi.C.sleep(%d)
]]):format(path, path, ready, seconds or 30))
    f:close()
    local out = H.sh(("%s %q >/dev/null 2>&1 & echo \"PID=$!\""):format(H.lua_bin(), script))
    local pid = tonumber(out:match("PID=(%d+)"))
    for _ = 1, 50 do
        if H.slurp(ready) then break end
        os.execute("sleep 0.1")
    end
    local held = H.slurp(ready) ~= nil
    return function()
        if pid then
            os.execute("kill " .. pid .. " 2>/dev/null")
            for _ = 1, 50 do   -- (the lock is let go when the process is gone: wait for that, not for the signal)
                if os.execute("kill -0 " .. pid .. " 2>/dev/null") ~= 0 then break end
                os.execute("sleep 0.1")
            end
        end
        os.remove(script); os.remove(ready)
    end, held
end

--- Run a shell command → output (stderr included, trailing whitespace trimmed), exit code.
function H.sh(cmd)
    local p = io.popen(cmd .. " 2>&1; echo \"@@EXIT=$?\"")
    local out = p:read("*a"); p:close()
    local code = tonumber(out:match("@@EXIT=(%d+)%s*$"))
    return (out:gsub("@@EXIT=%d+%s*$", ""):gsub("%s+$", "")), code
end

--- Write `text` to `path` (the file is replaced) → true. A failure raises: a test fixture that was not written is a broken test.
function H.write_file(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text); f:close()
    return true
end

--- The directory of the Lua interpreter the tests run under (a narrowed PATH must still find it) — "/usr/bin" when unknown.
function H.lua_dir()
    return (H.sh("command -v " .. H.lua_bin())):match("^(.*)/[^/]+$") or "/usr/bin"
end

function H.slurp(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

--- Octal permission bits of a path ("600") — GNU stat -c, else BSD / macOS stat -f.
function H.mode(path)
    return (H.sh(("stat -c %%a %q 2>/dev/null || stat -f %%Lp %q"):format(path, path))):match("%d+")
end

-- The platform's tools differ: GNU (Linux) or BSD (macOS).
local BSD = (H.sh("uname -s")) == "Darwin"

--- "timeout N " to put before a command — GNU timeout, or Homebrew's gtimeout on macOS;
--- "" when neither is installed (the command then runs with no limit).
local _timeout
function H.timeout(secs)
    if _timeout == nil then _timeout = (H.sh("command -v timeout || command -v gtimeout")):match("[^\n]+") or false end
    return _timeout and ("%s %d "):format(_timeout, secs) or ""
end

--- The system part of a test's narrowed PATH: /usr/bin:/bin, and where jq lives when it is
--- elsewhere (Homebrew on macOS: /opt/homebrew/bin) — memo and the hooks need it.
function H.sys_path()
    local p = "/usr/bin:/bin"
    local jq_dir = (H.sh("command -v jq")):match("^(/.*)/[^/]+$")
    if jq_dir and jq_dir ~= "/usr/bin" and jq_dir ~= "/bin" then p = p .. ":" .. jq_dir end
    return p
end

--- A shell command that runs `cmd` (a shell command line) on a pseudo-terminal, its input
--- from this one's stdin: util-linux script -qec on Linux, BSD script -q on macOS.
function H.pty(cmd)
    local q = require("luamemo.util").shell_quote
    if BSD then return ("script -q /dev/null sh -c %s"):format(q(cmd)) end
    return ("script -qec %s /dev/null"):format(q(cmd))
end

--- A project's .luamemorc a test wrote by hand is used only once trusted (luamemo uses
--- one memo wrote or its user trusted): trust it as it is, as `memo config trust` would
--- — in this process's trust list (XDG_CONFIG_HOME, or MEMO_FEDERATION_DIR when given).
--- Write the file, then call this; → path.
function H.trust_rc(path, federation_dir)
    local settings = require("luamemo.settings")
    if federation_dir then
        local tf = federation_dir .. "/trusted_rc"
        local saved = settings.trust_file
        settings.trust_file = function() return tf end
        local ok, err = settings.trust(path)
        settings.trust_file = saved
        assert(ok, err)
    else
        assert(settings.trust(path))
    end
    return path
end

--- The interpreter running this test (arg[-1] …), for child processes.
function H.lua_bin(default)
    local bin = default or "luajit"
    if arg then local i = -1; while arg[i - 1] do i = i - 1 end; bin = arg[i] or bin end
    return bin
end

--- A value from .luamemorc text: the last `KEY=…` line, single quotes removed
--- (memo writes 'value' with '\'' escapes; legacy unquoted lines read as-is).
function H.rc_get(text, key)
    local v
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local val = line:match("^" .. key .. "=(.*)$")
        if val then v = val end
    end
    if v and #v >= 2 and v:sub(1, 1) == "'" and v:sub(-1) == "'" then
        v = v:sub(2, -2):gsub("'\\''", "'")
    end
    return v
end

-- ---------------------------------------------------------------------------
-- Throwaway databases: SQLite files in the run's temporary directory
-- (MEMO_TEST_TMP, set by run.lua; else next to MEMO_DB).
-- ---------------------------------------------------------------------------
local _dbs = {}

local function tmp_dir()
    local t = os.getenv("MEMO_TEST_TMP")
    if t and t ~= "" then return t .. "/db" end
    local d = tostring(os.getenv("MEMO_DB") or ""):match("^(.*)/[^/]+$")
    return d or "/tmp"
end

--- Path of throwaway database `name`.
function H.db_path(name)
    return tmp_dir() .. "/" .. name .. ".db"
end

--- Path of a throwaway file or directory `name` next to the throwaway databases (the run's temporary directory, so a
--- crashed test leaves its leftovers where the runner cleans up). The caller removes it.
function H.tmp_path(name)
    return tmp_dir() .. "/" .. name
end

--- luamemo.setup for the run's database with the hash embedder (no model, no probe) and the preference companions off,
--- `base` (a test file's own defaults) and then `extra` on top. luamemo.setup merges onto the config before it, so a
--- test that changes a setting names it back; the embedder's model is the one thing that is cleared each time.
function H.setup(extra, base)
    local lm = require("luamemo")
    local cfg = { db = assert(os.getenv("MEMO_DB"), "run it with eval/tests/run.lua (MEMO_DB)"), embedder_local = "hash",
                  embed_dim = 384, skip_embed_probe = true, patterns_enabled = false }
    for _, layer in ipairs({ base or {}, extra or {} }) do
        for k, v in pairs(layer) do cfg[k] = v end
    end
    if type(lm.config) == "table" then lm.config.embedder_model = nil end
    lm.setup(cfg)
end

--- A query's first value as a number — `SELECT count(*) …`. A statement that fails raises (a check "== 0" must not
--- pass because the question could not be asked); no row at all is 0, so ask for a count, not for a column.
function H.count(sql, ...)
    local v, err = require("luamemo.db").value(sql, ...)
    if err then error("H.count: " .. tostring(err), 2) end
    return tonumber(v) or 0
end

--- How many rows of a scope the fold has archived (hidden, waiting for their review), and how many are still visible
--- at a tier (never folded, or given back).
function H.folded(scope)
    return H.count("SELECT count(*) FROM lm_memories WHERE scope = ? AND json_type(metadata, '$.lm_fold') IS NOT NULL", scope)
end
function H.visible(scope)
    return H.count("SELECT count(*) FROM lm_memories WHERE scope = ? AND tier >= 1 AND json_type(metadata, '$.lm_fold') IS NULL", scope)
end

--- Create database `name` (a new file, the schema applied). Removed by H.drop_dbs().
--- Returns its path.
function H.create_db(name)
    local path = H.db_path(name)
    for _, sfx in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. sfx) end
    local h = assert(require("luamemo.db").open(path))
    h.close()
    _dbs[#_dbs + 1] = path
    return path
end

--- Remove every database create_db made (best effort, never raises).
function H.drop_dbs()
    for _, path in ipairs(_dbs) do
        for _, sfx in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. sfx) end
    end
    _dbs = {}
end

--- The environment of a `memo` with its own HOME, data and project — none of the
--- runner's MEMO_DB / MEMO_EMBEDDER — as a shell prefix; memo_in runs one command there.
function H.memo_env(home, proj)
    local repo = (H.sh("pwd"))
    local lua_abs = (H.sh("command -v '" .. H.lua_bin():gsub("'", "'\\''") .. "'"))
    local path = ("%s/?.lua;%s/?/init.lua;"):format(repo, repo) .. (os.getenv("LUA_PATH") or ";")
    return ("env -u MEMO_DB -u MEMO_EMBEDDER HOME=%q XDG_CONFIG_HOME=%q XDG_DATA_HOME=%q MEMO_PROJECT=%q "
        .. "MEMO_LUA=%q LUA_PATH=%q"):format(home, home .. "/.config", home .. "/.local/share", proj, lua_abs, path)
end

--- Run `memo ARGS` in project dir `proj` with environment prefix `env` → output, exit code.
function H.memo_in(env, proj, args)
    return H.sh(("cd %q && %s %q %s </dev/null"):format(proj, env, (H.sh("pwd")) .. "/cli/memo", args))
end

--- Run the MCP server (mcp/server.lua) over stdio, as a client does: initialize, then
--- one request per entry of `calls` — { tool_name, arguments } is a tools/call,
--- { method = M, params = P } any other method. env: a shell prefix of variable
--- assignments; opts.cwd: the server's working directory (default: here).
--- Returns { [i] = the i-th tool's decoded result, or { error = text } — a method's raw
--- result }, the server's stderr.
function H.mcp(env, calls, opts)
    opts = opts or {}
    local json = require("luamemo.json")
    local repo = (H.sh("pwd"))
    local inp, errf = os.tmpname(), os.tmpname()
    local f = assert(io.open(inp, "w"))
    f:write(json.encode({ jsonrpc = "2.0", id = 0, method = "initialize", params = {} }), "\n")
    local raw = {}
    for i, c in ipairs(calls) do
        if c.method then
            raw[i] = true
            f:write(json.encode({ jsonrpc = "2.0", id = i, method = c.method, params = c.params or {} }), "\n")
        else
            f:write(json.encode({ jsonrpc = "2.0", id = i, method = "tools/call",
                params = { name = c[1], arguments = c[2] or {} } }), "\n")
        end
    end
    f:close()
    local p = io.popen(("cd %q && %s %q %q < %q 2> %q"):format(opts.cwd or repo, env or "", H.lua_bin(),
        repo .. "/mcp/server.lua", inp, errf))
    local out = p:read("*a"); p:close()
    local results = {}
    for line in out:gmatch("[^\n]+") do
        local msg = json.decode(line)
        local id = type(msg) == "table" and tonumber(msg.id)
        if id and id > 0 then
            local r = msg.result
            if msg.error then results[id] = { error = tostring(msg.error.message) }
            elseif raw[id] then results[id] = r
            elseif type(r) == "table" and r.isError then results[id] = { error = r.content[1].text }
            elseif type(r) == "table" then results[id] = json.decode(r.content[1].text) or {} end
        end
    end
    local stderr = H.slurp(errf) or ""
    os.remove(inp); os.remove(errf)
    return results, stderr
end

--- An MCP server session over stdio, one request at a time — a client's back and forth
--- (a later call can use what an earlier one returned):
---   local s = H.mcp_session(env); local r = s.call("memory_delete", { … }); s.close()
--- call → the tool's decoded result, or { error = text }; close → the server's stderr.
--- opts.cwd: where it starts; opts.cmd: the command that starts it (shell words; default
--- luajit mcp/server.lua) — e.g. `memo mcp`.
function H.mcp_session(env, opts)
    opts = opts or {}
    local json = require("luamemo.json")
    local repo = (H.sh("pwd"))
    local dir = os.tmpname(); os.remove(dir)
    os.execute(("mkdir -p %q && mkfifo %q"):format(dir, dir .. "/in"))
    local outf, errf = dir .. "/out", dir .. "/err"
    os.execute(("cd %q && %s %s < %q > %q 2> %q &"):format(opts.cwd or repo, env or "",
        opts.cmd or ("%q %q"):format(H.lua_bin(), repo .. "/mcp/server.lua"), dir .. "/in", outf, errf))
    local w = assert(io.open(dir .. "/in", "w"))   -- returns once the server has its end open
    local id = 0
    local function send(method, params)
        id = id + 1
        w:write(json.encode({ jsonrpc = "2.0", id = id, method = method, params = params or {} }), "\n")
        w:flush()
        for _ = 1, 600 do
            for line in (H.slurp(outf) or ""):gmatch("[^\n]+") do
                local msg = json.decode(line)
                if type(msg) == "table" and msg.id == id then return msg end
            end
            os.execute("sleep 0.05")
        end
        error("mcp_session: no answer to request " .. id .. " — stderr: " .. (H.slurp(errf) or ""))
    end
    send("initialize", {})
    local S = {}
    function S.call(name, args)
        local msg = send("tools/call", { name = name, arguments = args or {} })
        if msg.error then return { error = tostring(msg.error.message) } end
        if msg.result.isError then return { error = msg.result.content[1].text } end
        return json.decode(msg.result.content[1].text) or {}
    end
    function S.close()
        w:close()
        os.execute("sleep 0.1")
        local stderr = H.slurp(errf) or ""
        os.execute(("rm -rf %q"):format(dir))
        return stderr
    end
    return S
end

--- Wait (up to ~10 s) for `memo serve`'s "LISTENING <host> <port>" line in its
--- log file. Returns port | nil, and the log text.
function H.wait_port(log_path)
    local text = ""
    for _ = 1, 100 do
        text = H.slurp(log_path) or ""
        local port = tonumber(text:match("LISTENING %S+ (%d+)"))
        if port then return port, text end
        os.execute("sleep 0.1")
    end
    return nil, text
end

return H
