-- eval/tests/run.lua — the test runner (development only; never shipped in the rock).
--
--   luajit eval/tests/run.lua [--only NAME,…] [--list] [--keep] [--timeout SECONDS] [--lua BIN]
--
-- Runs every eval/tests/test_*.lua from the repository root, one file at a time,
-- each in a clean environment:
--   * its own new database: MEMO_DB is a fresh SQLite file in the run's temporary
--     directory (MEMO_TEST_TMP; tests make further databases there — _harness.lua);
--   * a temporary HOME and XDG directories, so the user's ~/.memorc, ~/.luamemorc,
--     data directory and federation keyring are never touched;
--   * MEMO_PROJECT pointing at an empty directory, so the checkout's own .luamemorc
--     never redirects a `memo` a test runs from the repository root;
--   * every MEMO_* variable inherited from the shell removed (optional test knobs
--     MEMO_GGUF_* / MEMO_GEN_* / MEMO_LIB_* / MEMO_LIVE_* kept), and the PG* variables too;
--     MEMO_EMBEDDER=hash.
-- Prints one line per file and the totals, and exits 1 when any file fails. Logs of a
-- failing run are kept (the path is printed). No credential is ever printed.
-- Don't edit repository files while it runs: some tests index the live checkout.
--
-- Needs LuaJIT, the native libraries (SQLite, libsodium — see luamemo.native.loader) and
-- the rocks the tests use on the module path (e.g. eval "$(luarocks --lua-version 5.1 path)").

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then
    io.stderr:write("run.lua: run it with luajit (it needs the FFI)\n"); os.exit(2)
end
ffi.cdef[[
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
int getpid(void);
extern char **environ;
typedef struct { long tv_sec; long tv_nsec; } lm_timespec;
int clock_gettime(int clk, lm_timespec *ts);
]]
local C = ffi.C

local function die(msg) io.stderr:write("run.lua: " .. msg .. "\n"); os.exit(2) end
local function setenv(k, v) C.setenv(k, v, 1) end
local ts = ffi.new("lm_timespec[1]")
local function now() C.clock_gettime(1, ts); return tonumber(ts[0].tv_sec) + tonumber(ts[0].tv_nsec) * 1e-9 end

--- Run a shell command → output (stderr included, trailing whitespace trimmed), exit code.
local function sh(cmd)
    local p = io.popen(cmd .. " 2>&1; echo \"@@EXIT=$?\"")
    if not p then return "", 127 end
    local out = p:read("*a"); p:close()
    local code = tonumber(out:match("@@EXIT=(%d+)%s*$"))
    return (out:gsub("@@EXIT=%d+%s*$", ""):gsub("%s+$", "")), code
end
local q = require("luamemo.util").shell_quote

-- ---------------------------------------------------------------------------
-- Arguments
-- ---------------------------------------------------------------------------
local opts = { timeout = 600 }
do
    local i = 1
    while arg[i] do
        local a = arg[i]
        if a == "--only" then opts.only = arg[i + 1]; i = i + 2
        elseif a == "--timeout" then opts.timeout = tonumber(arg[i + 1]) or die("--timeout needs seconds"); i = i + 2
        elseif a == "--lua" then opts.lua = arg[i + 1]; i = i + 2
        elseif a == "--list" then opts.list = true; i = i + 1
        elseif a == "--keep" then opts.keep = true; i = i + 1
        elseif a == "-h" or a == "--help" then
            io.write("usage: luajit eval/tests/run.lua [--only NAME,…] [--list] [--keep] [--timeout SECONDS] [--lua BIN]\n")
            os.exit(0)
        else die("unknown argument: " .. a) end
    end
end
if not opts.lua then
    local i = -1
    while arg[i - 1] do i = i - 1 end
    opts.lua = arg[i] or "luajit"
end

if not io.open("luamemo/init.lua") or not io.open("eval/tests/_harness.lua") then
    die("run it from the repository root (luamemo/ and eval/tests/ must be here)")
end

-- ---------------------------------------------------------------------------
-- Test files
-- ---------------------------------------------------------------------------
local files = {}
for f in io.popen("ls eval/tests/test_*.lua 2>/dev/null"):lines() do files[#files + 1] = f end
table.sort(files)
if opts.only then
    local want = {}
    for n in opts.only:gmatch("[^,%s]+") do want[(n:gsub("%.lua$", ""):gsub("^test_", ""))] = true end
    local sel = {}
    for _, f in ipairs(files) do
        if want[f:match("test_(.-)%.lua$")] then sel[#sel + 1] = f end
    end
    files = sel
end
if opts.list then
    for _, f in ipairs(files) do io.write(f:match("([^/]+)%.lua$"), "\n") end
    os.exit(0)
end
if #files == 0 then die("no test files matched") end

-- ---------------------------------------------------------------------------
-- Preflight: the rocks the tests load, and the native libraries
-- ---------------------------------------------------------------------------
local child_path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path
package.path = child_path
for _, mod in ipairs({ "socket" }) do
    if not pcall(require, mod) then
        die(("module '%s' not found — put the rocks on the module path first, e.g.\n"
            .. "  eval \"$(luarocks --lua-version 5.1 path)\""):format(mod))
    end
end
do
    local ok_sq, sq = pcall(function() return require("luamemo.native.sqlite").version() end)
    if not ok_sq then die(tostring(sq)) end
    local ok_so, so = pcall(function() return require("luamemo.native.sodium").version() end)
    if not ok_so then die(tostring(so)) end
end

-- ---------------------------------------------------------------------------
-- The children's environment (set here, inherited — nothing secret on a command line)
-- ---------------------------------------------------------------------------
local real_home = os.getenv("HOME") or ""
local tmp = (sh("mktemp -d -t luamemo-tests.XXXXXX"))
if tmp == "" or not tmp:match("^/") then die("mktemp failed") end
for _, d in ipairs({ "home", "xdg-config", "xdg-data", "xdg-cache", "project", "db" }) do
    os.execute("mkdir -p " .. q(tmp .. "/" .. d))
end
os.execute("chmod 700 " .. q(tmp))

local keep_env = {}
do
    local i = 0
    while C.environ[i] ~= nil do
        local kv = ffi.string(C.environ[i])
        local k, v = kv:match("^([^=]+)=(.*)$")
        if k and k:match("^MEMO_") then
            if k:match("^MEMO_GGUF_") or k:match("^MEMO_GEN_") or k:match("^MEMO_LIB_")
                or k:match("^MEMO_LIVE_") then keep_env[k] = v end
        end
        i = i + 1
    end
end
local drop = {}
do
    local i = 0
    while C.environ[i] ~= nil do
        local k = ffi.string(C.environ[i]):match("^([^=]+)=")
        if k and (k:match("^MEMO_") or k:match("^PG")) then drop[#drop + 1] = k end
        i = i + 1
    end
end
for _, k in ipairs(drop) do C.unsetenv(k) end
for k, v in pairs(keep_env) do setenv(k, v) end
if not keep_env.MEMO_GGUF_MODEL then
    local m = real_home .. "/models/embeddinggemma-300M-Q8_0.gguf"
    if io.open(m, "rb") then setenv("MEMO_GGUF_MODEL", m) end
end

setenv("HOME", tmp .. "/home")
setenv("XDG_CONFIG_HOME", tmp .. "/xdg-config")
setenv("XDG_DATA_HOME", tmp .. "/xdg-data")
setenv("XDG_CACHE_HOME", tmp .. "/xdg-cache")
setenv("MEMO_PROJECT", tmp .. "/project")
setenv("MEMO_EMBEDDER", "hash")
setenv("MEMO_LUA", opts.lua)
setenv("MEMO_PROJECTION_W", tmp .. "/projection_w.json")
setenv("MEMO_RERANK_WEIGHTS", tmp .. "/rerank_w.json")
setenv("LUA_PATH", child_path)
setenv("LUA_CPATH", package.cpath)
setenv("MEMO_TEST_TMP", tmp)

io.write(("luamemo tests — %d file(s), %s, SQLite %s, temp %s\n\n")
    :format(#files, opts.lua, require("luamemo.native.sqlite").version(), tmp))

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------
local function counts(log)
    local f = io.open(log, "r")
    if not f then return 0, 0, {}, {}, 0 end
    local p, n, fails, tail, skips = 0, 0, {}, {}, 0
    for line in f:lines() do
        if line:match("^%[PASS%]") then p = p + 1
        elseif line:match("^%[FAIL%]") then n = n + 1; fails[#fails + 1] = line
        elseif line:match("^%s*%[SKIP%]") then skips = skips + 1 end
        tail[#tail + 1] = line
        if #tail > 15 then table.remove(tail, 1) end
    end
    f:close()
    return p, n, fails, tail, skips
end

local t_all = now()
local bad, total_p, total_f, total_s = {}, 0, 0, 0
for _, f in ipairs(files) do
    local name = f:match("([^/]+)%.lua$")
    local log = tmp .. "/" .. name .. ".log"
    setenv("MEMO_DB", tmp .. "/db/" .. name .. ".db")   -- a new database per file
    local t0 = now()
    local _, rc = sh(("timeout %d %s %s > %s 2>&1"):format(opts.timeout, q(opts.lua), q(f), q(log)))
    local secs = now() - t0
    local p, n, fails, tail, skips = counts(log)
    total_p, total_f = total_p + p, total_f + n
    total_s = total_s + skips
    local status = (rc == 0 and n == 0) and "ok" or ((rc == 124) and "TIMEOUT" or "FAIL")
    local detail = (p + n > 0) and ("%d passed%s"):format(p, n > 0 and (", %d failed"):format(n) or "")
        or (rc == 0 and "assertions ok" or "")
    if skips > 0 then detail = detail .. (", %d SKIPPED"):format(skips) end
    if rc ~= 0 and status == "FAIL" then detail = detail .. (" (exit %d)"):format(rc) end
    io.write(("  %-7s %-30s %-28s %6.1fs\n"):format(status, name, detail, secs))
    io.flush()
    if status ~= "ok" then
        bad[#bad + 1] = name
        local show = (#fails > 0) and fails or tail
        for i = 1, math.min(#show, 12) do io.write("          | ", show[i], "\n") end
    end
end

io.write(("\n%d file(s): %d ok, %d failed — %d checks passed, %d failed%s — %.0fs\n")
    :format(#files, #files - #bad, #bad, total_p, total_f,
        total_s > 0 and (", %d SKIPPED"):format(total_s) or "", now() - t_all))
if #bad > 0 or opts.keep then
    io.write("logs kept in " .. tmp .. "\n")
else
    os.execute("rm -rf " .. q(tmp))
end
if #bad > 0 then io.write("failed: " .. table.concat(bad, " ") .. "\n") end
os.exit(#bad > 0 and 1 or 0)
