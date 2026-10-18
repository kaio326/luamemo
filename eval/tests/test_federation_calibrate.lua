-- eval/tests/test_federation_calibrate.lua
-- Phase 12.5 + 12F — federation setup flows (key-based, no credentials).
--   A. config bootstrap: MEMO_ORG_FINGERPRINT / MEMO_FEDERATION_DIR are mapped;
--      the removed token variables are ignored
--   B. `memo calibrate` flag validation — rejected before anything is written
--   C. `memo calibrate --role org --org-name N` in a throwaway project: role +
--      name persisted, the central identity key created in the per-user keyring
--      (0700 / 0600, encrypted), only its PUBLIC fingerprint printed, re-run
--      keeps the same identity, `memo org status` shows it
--   D. `memo calibrate --org-url … --org-fingerprint …` (central unreachable):
--      URL + fingerprint persisted (public values only), pairing failure
--      reported, calibrate still completes; without a fingerprint nothing is
--      configured
--   E. the interactive join against a real central (pty)
--   F. switching orgs / --role solo: shared org database, old org left first,
--      last-project registry cleanup
--
-- Runs every `memo calibrate` in a temp project with HOME / XDG_CONFIG_HOME in
-- temp dirs — the repo's .luamemorc and ~/.config are never touched. The run's
-- database (MEMO_DB) is the central's and the projects'; E and F add their own.
-- Run: luajit eval/tests/run.lua --only federation_calibrate

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Federation calibrate")
local check, section, finish = T.check, T.section, T.finish
local sh, slurp, mode, rcv = H.sh, H.slurp, H.mode, H.rc_get
local lua_bin = H.lua_bin()

local TMP = os.tmpname(); os.remove(TMP)
os.execute(("mkdir -p %q"):format(TMP))

-- ---------------------------------------------------------------------------
section("A config", function()
io.write("\n--- A: config bootstrap ---\n")
local probe = [[local c = require("luamemo.cli._common").config_from_env({ warn = false })
io.write(tostring(c.org_fingerprint), "|", tostring(c.federation_dir), "|", tostring(c.org_token), "|", tostring(c.org_tokens))]]
local out = sh(("MEMO_ORG_FINGERPRINT=ABCD-EFGH MEMO_FEDERATION_DIR=/tmp/kr MEMO_ORG_TOKEN=x MEMO_ORG_TOKENS=y %s -e %q")
    :format(lua_bin, "package.path='./?.lua;./?/init.lua;'..package.path; " .. probe))
check("fingerprint + keyring dir mapped; token variables ignored", out == "ABCD-EFGH|/tmp/kr|nil|nil", out)
end)

local REPO = (sh("pwd")):gsub("%s+$", "")
local MEMO = REPO .. "/cli/memo"
-- Absolute module paths: the child runs from a temp project directory.
local abs = ("%s/?.lua;%s/?/init.lua;"):format(REPO, REPO)
-- MEMO_PROJECT= : the project is each call's working directory (not a caller's MEMO_PROJECT).
local ENV = ("HOME=%q XDG_CONFIG_HOME=%q MEMO_PROJECT= MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q LUA_PATH=%q")
    :format(TMP .. "/home", TMP .. "/xdg", tostring(os.getenv("MEMO_DB") or ""), lua_bin,
            abs .. (os.getenv("LUA_PATH") or ";"))
os.execute(("mkdir -p %q %q"):format(TMP .. "/home", TMP .. "/xdg"))
local QUIET = " --no-mcp --no-plugin --no-git --no-comments --allow-hash"
local function project(name)
    local dir = TMP .. "/" .. name
    os.execute(("mkdir -p %q"):format(dir))
    return dir
end
local function calibrate(dir, args)
    return sh(("cd %q && %s %q calibrate %s </dev/null"):format(dir, ENV, MEMO, args))
end

-- ---------------------------------------------------------------------------
section("B flags", function()
io.write("\n--- B: flag validation ---\n")
local dir = project("flags")
local cases = {
    { "--role org", "needs --org-name" },
    { "--role org --org-name 'a b'", "needs --org-name" },
    { "--role bogus", "must be solo, dev or org" },
    { "--role dev", "needs --org-url" },
    { "--org-url ftp://x", "http(s)://" },
    { "--org-fingerprint ABCD", "needs --org-url" },
    { "--role org --org-name x --org-url http://c", "--org-url is for devs" },
    { "--org-token t", "unknown arg" },
}
for _, c in ipairs(cases) do
    local out, code = calibrate(dir, c[1])
    check("rejected: " .. c[1], code == 1 and out:find(c[2], 1, true) ~= nil, out:sub(1, 200))
end
check("nothing written for rejected flags", slurp(dir .. "/.luamemorc") == nil)
local _, dc = calibrate(dir, "--db 'not a name'")
check("rejected: --db with a bad name (before anything is written)", dc == 1 and slurp(dir .. "/.luamemorc") == nil)
-- Arguments reach Lua as data, never as code: a value closing the old
-- [==[ … ]==] quoting (a search query, a project directory name) must not run.
local payload = "x]==],(function() io.open('PWNED','w'):close() end)(),[==["
local pdir = project(payload)
sh(("cd %q && %s %q index search %q"):format(pdir, ENV, MEMO, payload))
local pout, pc = calibrate(pdir, QUIET)          -- the ingest phase gets scope repo:<dir name>
check("CLI arguments and a crafted directory name never execute as Lua", slurp(pdir .. "/PWNED") == nil
    and pc == 0 and pout:find("Done:", 1, true) ~= nil, pout:sub(-300))
pcall(require("luamemo.db").run, "DELETE FROM lm_memories WHERE substr(scope, 1, 8) = ?", "repo:x]=")
end)

-- ---------------------------------------------------------------------------
section("C central", function()
io.write("\n--- C: calibrate --role org ---\n")
local dir = project("central")
local out, code = calibrate(dir, "--role org --org-name fedcal" .. QUIET)
check("central calibrate succeeds", code == 0, out:sub(-600))
local rc = slurp(dir .. "/.luamemorc") or ""
check("role + name persisted", rcv(rc, "MEMO_ROLE") == "org" and rcv(rc, "MEMO_ORG_NAME") == "fedcal", rc)
check("no credential of any kind in .luamemorc", not rc:find("TOKEN", 1, true) and not rc:find("KEY", 1, true), rc)
local kr = TMP .. "/xdg/luamemo"
check("central identity in the per-user keyring (0700 / 0600)", mode(kr) == "700"
    and mode(kr .. "/keyring.key") == "600" and mode(kr .. "/keyring.db") == "600", mode(kr))
local fp = out:match("fingerprint: (%w%w%w%w%-%w%w%w%w%-%w%w%w%w%-%w%w%w%w%-%w%w%w%w)")
check("public fingerprint printed", fp ~= nil, out:sub(-800))
local ring = require("luamemo.db").open(kr .. "/keyring.db", { readonly = true })
local key_row = ring and ring.first("SELECT value, internal FROM lm_secrets WHERE name = 'luamemo.identity.central'")
if ring then ring.close() end
check("keyring holds ciphertext only (an internal secret, sealed)", key_row and key_row.internal == 1
    and tostring(key_row.value):match("^x1:%x+$") ~= nil)
check("recipe: serve on LAN / Tailscale, approve devices by code, join command with the fingerprint",
    out:find("memo serve --host", 1, true) and out:find("memo org devs approve", 1, true)
        and fp and out:find("--org-fingerprint " .. fp, 1, true))
check("per-dev phases skipped", not out:find("Ingesting codebase", 1, true))
local out2, code2 = calibrate(dir, "--role org --org-name fedcal" .. QUIET)
check("re-run keeps the same identity", code2 == 0 and fp and out2:find(fp, 1, true) ~= nil)
local st, c3 = sh(("cd %q && %s %q org status"):format(dir, ENV, MEMO))
check("memo org status shows the fingerprint + devices", c3 == 0 and fp and st:find(fp, 1, true)
    and st:find("0 approved, 0 pending", 1, true), st)
end)

-- ---------------------------------------------------------------------------
section("D dev", function()
io.write("\n--- D: calibrate --org-url ---\n")
local dir = project("dev")
local url = "http://127.0.0.1:1"
local out0, code0 = calibrate(dir, ("--org-url %s"):format(url) .. QUIET)
local rc0 = slurp(dir .. "/.luamemorc") or ""
check("without a fingerprint: guidance, nothing pinned", code0 == 0 and out0:find("--org-fingerprint", 1, true)
    and not rc0:find("MEMO_ORG_URL", 1, true), out0:sub(-400))
local fp = "0123-4567-89AB-CDEF-GHJK"
local out, code = calibrate(dir, ("--org-url %s --org-fingerprint %s"):format(url, fp) .. QUIET)
check("dev calibrate completes although the central is unreachable", code == 0, out:sub(-600))
local rc = slurp(dir .. "/.luamemorc") or ""
check("URL + fingerprint persisted (public values)", rcv(rc, "MEMO_ORG_URL") == url
    and rcv(rc, "MEMO_ORG_FINGERPRINT") == fp, rc)
check("pairing failure reported, config kept", out:find("Pairing failed", 1, true) ~= nil, out:sub(-800))
check("calibrate continued with the normal phases", out:find("Ingesting codebase", 1, true) ~= nil)
-- .luamemorc is sourced as shell: a value is data, never a command.
local edir = project("devevil")
local evil = "http://127.0.0.1:1/$(touch${IFS}PWNED)"
calibrate(edir, ("--org-url '%s' --org-fingerprint %s"):format(evil, fp) .. QUIET)
sh(("cd %q && %s %q org status"):format(edir, ENV, MEMO))
check("an org URL carrying $(…) is stored inert and never runs when .luamemorc is sourced",
    slurp(edir .. "/PWNED") == nil and rcv(slurp(edir .. "/.luamemorc"), "MEMO_ORG_URL") == evil,
    slurp(edir .. "/.luamemorc"))
-- A hand-made, world-readable .luamemorc is 0600 once memo writes to it.
local mdir = project("devmode")
local mf = assert(io.open(mdir .. "/.luamemorc", "w")); mf:write("MEMO_SCOPE='repo:devmode'\n"); mf:close()
os.execute(("chmod 644 %q"):format(mdir .. "/.luamemorc"))
H.trust_rc(mdir .. "/.luamemorc", TMP .. "/xdg/luamemo")   -- hand-made: trusted, as its user would
calibrate(mdir, ("--org-url %s --org-fingerprint %s"):format(url, fp) .. QUIET)
check("an existing 0644 .luamemorc becomes 0600 when memo writes to it", mode(mdir .. "/.luamemorc") == "600",
    mode(mdir .. "/.luamemorc"))
-- `memo org pair --wait` when every status check fails: say so, not "not approved yet".
local ws = TMP .. "/wait_stub.lua"
local wf = assert(io.open(ws, "w"))
wf:write([[
package.path = "./?.lua;./?/init.lua;" .. package.path
local client = require("luamemo.federation.client")
client.pair = function() return { status = "pending", code = "ABCD-1234", identity = "user:dev@corp.io",
    device_fingerprint = "DEV0-DEV0-DEV0-DEV0-DEV0", central_fingerprint = "CEN0-CEN0-CEN0-CEN0-CEN0" } end
client.pair_status = function() return nil, "org central unreachable: connection refused" end
require("luamemo.cli.org").run({ "pair", "--wait", "1" })
]])
wf:close()
local wout = sh(("MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_ORG_URL=%q MEMO_ORG_FINGERPRINT=%s MEMO_FEDERATION_DIR=%q %s %q")
    :format(os.getenv("MEMO_DB"), url, fp, TMP .. "/waitkr", lua_bin, ws))
check("pair --wait: failed checks are reported as such (not as 'not approved yet')",
    wout:find("could not check the approval", 1, true) and wout:find("unreachable", 1, true)
        and not wout:find("not approved yet", 1, true), wout:sub(-300))
local po = sh(("cd %q && %s %q ping"):format(dir, ENV, MEMO))
check("memo ping names the project's database (from its .luamemorc)", po:find("[INFO] config: " .. dir, 1, true)
    and po:find("[PASS] Database         " .. os.getenv("MEMO_DB"), 1, true) ~= nil, po)
local st, c2 = sh(("cd %q && %s %q org status"):format(dir, ENV, MEMO))
check("memo org status: pinned key shown, no device key yet", c2 == 0 and st:find(fp, 1, true)
    and st:find("none yet", 1, true), st)
local br = sh(("cd %q && %s %q brief --scope repo:dev"):format(dir, ENV, MEMO))
check("session brief tells the agent the device isn't paired (and what the person does)",
    br:find("not paired yet", 1, true) and br:find("memo org pair", 1, true), br)
end)

-- ---------------------------------------------------------------------------
-- E. The whole dev flow against a real central, answered through a pty:
--    probe → confirm fingerprint → pair (code) → wait → admin approves → sync,
--    and an existing .vscode/mcp.json entry gets its org settings updated.
local function has_script() return (sh("command -v script")):find("script", 1, true) ~= nil end
section("E interactive", function()
io.write("\n--- E: interactive join against a real central ---\n")
if not has_script() then io.write("[INFO] `script` (util-linux) not found — skipped\n"); return end
-- The answers are typed ahead into a pseudo-terminal; macOS's BSD script doesn't hand
-- them to a question asked after the central's probe (the read gets nothing), while
-- util-linux script does. The flow is plain bash; Linux runs this section.
if (sh("uname -s")) == "Darwin" then
    io.write("[INFO] macOS: BSD script doesn't deliver typed-ahead answers here — run on Linux\n"); return
end
local db = require("luamemo.db")
local json = require("luamemo.json")
local ORG = "org:fedcale"
local SUFFIX = ("%d_%04d"):format(os.time(), math.random(0, 9999))
local luamemo = require("luamemo")
luamemo.setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true })
-- A database that doesn't exist yet: calibrate creates it (and its schema); its
-- vector size follows the embedder the probe picks.
local dev_db = H.db_path("lm_fedcal_" .. SUFFIX)
local CK = TMP .. "/central-keys"
local CENV = ("MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_ROLE=org MEMO_ORG_NAME=fedcale MEMO_FEDERATION_DIR=%q")
    :format(os.getenv("MEMO_DB"), CK)
local function central_lua(code)
    local path = os.tmpname()
    local f = assert(io.open(path, "w"))
    f:write("package.path='./?.lua;./?/init.lua;'..package.path\n",
        "local luamemo = require('luamemo')\n",
        "luamemo.setup(require('luamemo.cli._common').config_from_env({}))\n", code)
    f:close()
    return path
end
db.run("DELETE FROM lm_org_devs WHERE org_scope = ?", ORG)
db.run("DELETE FROM lm_memories WHERE scope = ?", ORG)
local seed = central_lua([[luamemo.store.write({ scope = "org:fedcale", title = "org note",
    body = "shared with every dev", importance = 0.5 })]])
sh(("%s %s %q"):format(CENV, lua_bin, seed)); os.remove(seed)

local LOG = TMP .. "/serve.log"
local srv = "package.path='./?/init.lua;'..package.path; require('luamemo.cli.serve').run({'--port','0'})"
local pid = tonumber((sh(("%s %s%s -e %q >/dev/null 2>%q & echo \"PID=$!\""):format(CENV, H.timeout(300), lua_bin, srv, LOG)))
    :match("PID=(%d+)"))
local port = H.wait_port(LOG)
check("central serving", port ~= nil)
if not port then return end
local cfp = (slurp(LOG) or ""):match("fingerprint (%w+%-%w+%-%w+%-%w+%-%w+)")
-- The "admin": approves the first pending request it sees (the test then
-- checks it's the very code the dev was shown).
local approver = central_lua([[
local devs = require("luamemo.federation.devs")
for _ = 1, 90 do
    local p = devs.list("pending")[1]
    if p then
        local ok, err = devs.approve(p.pairing_code, "admin")
        if ok then io.write("APPROVED ", p.pairing_code, "\n"); return end
        io.write("approve failed: ", tostring(err), " — retrying\n")
    end
    os.execute("sleep 1")
end]])
sh(("%s %s%s %q > %q 2>&1 &"):format(CENV, H.timeout(120), lua_bin, approver, TMP .. "/approver.log"))

local dir = project("devp")
os.execute(("mkdir -p %q"):format(dir .. "/.vscode"))
local f = assert(io.open(dir .. "/.vscode/mcp.json", "w"))
f:write(json.encode({ servers = { ["luamemo-repo-devp"] = { type = "stdio", command = "luajit",
    args = { "server.lua" }, env = { MEMO_SCOPE = "repo:devp", MEMO_ORG_TOKEN_FILE = "/stale" } } } }))
f:close()
local DENV = ENV:gsub("MEMO_DB=%b\"\"", ("MEMO_DB=%q"):format(dev_db))
    :gsub("XDG_CONFIG_HOME=%b\"\"", ("XDG_CONFIG_HOME=%q"):format(TMP .. "/xdg-dev"))
local CAF = TMP .. "/private-ca.pem"   -- (never read here: nothing in this flow is https)
local cf = assert(io.open(CAF, "w")); cf:write("placeholder\n"); cf:close()
local cmd = ("cd %q && %s MEMO_ORG_IDENTITY=user:dev@corp.io MEMO_CA_FILE=%q %q calibrate --org-url "
    .. "http://127.0.0.1:%d --no-plugin --no-git --no-comments --allow-hash"):format(dir, DENV, CAF, MEMO, port)
local out, code = sh(("printf 'y\\ny\\ny\\ny\\ny\\ny\\ny\\ny\\ny\\ny\\ny\\ny\\n' | %s"):format(H.pty(cmd)))
check("interactive calibrate completes (the new database created on first use)", code == 0
    and out:find("[PASS] Database", 1, true) ~= nil and slurp(dev_db) ~= nil, out:sub(-1200))
check("shows the central's fingerprint for the person to compare", cfp and out:find(cfp, 1, true) ~= nil
    and out:find("presents", 1, true) ~= nil, out:sub(1, 600))
local shown = out:match("code:%s+(%w%w%w%w%-%w%w%w%w)")
local approved = (slurp(TMP .. "/approver.log") or ""):match("APPROVED (%S+)")
check("pairing code shown to the dev = the code the admin approved", shown ~= nil and shown == approved,
    ("%s vs %s"):format(tostring(shown), tostring(approved)))
check("waited for the approval, then synced", out:find("approved", 1, true) and out:find("pulled:", 1, true),
    out:match("Federation:.-Ingesting") or out:sub(1, 1500))
local rc = slurp(dir .. "/.luamemorc") or ""
check("pinned URL + fingerprint persisted", rcv(rc, "MEMO_ORG_URL") == "http://127.0.0.1:" .. port
    and cfp and rcv(rc, "MEMO_ORG_FINGERPRINT") == cfp, rc)
local dc = db.open(dev_db, { readonly = true })
local n = dc and tonumber(dc.value("SELECT count(*) FROM lm_memories WHERE scope = ?", ORG)) or 0
if dc then dc.close() end
check("the org replica arrived in the dev's database", n >= 1, n)
local m = json.decode(slurp(dir .. "/.vscode/mcp.json") or "{}")
local servers = m and m.servers or {}
local entry = servers.luamemo or {}
check("the old-style MCP entry (server path + MEMO_* env) → the generic one: memo mcp, no env",
    servers["luamemo-repo-devp"] == nil and entry.env == nil and entry.command == MEMO
    and json.encode(entry.args) == '["mcp","--project","${workspaceFolder}"]', json.encode(servers))
rc = slurp(dir .. "/.luamemorc") or ""
check("… and the org settings only the shell had (MEMO_CA_FILE, MEMO_ORG_IDENTITY) are saved in "
    .. ".luamemorc, where memo mcp reads them", rcv(rc, "MEMO_CA_FILE") == CAF
    and rcv(rc, "MEMO_ORG_IDENTITY") == "user:dev@corp.io", rc)
check("no secret anywhere in the output (only public values)", not out:find("keyring.key", 1, true)
    and not out:find("BEGIN", 1, true))

-- A person who says the fingerprint does NOT match: nothing gets pinned.
local dir2 = project("devp2")
local cmd2 = ("cd %q && %s MEMO_ORG_IDENTITY=user:dev@corp.io %q calibrate --org-url http://127.0.0.1:%d "
    .. "--no-mcp --no-plugin --no-git --no-comments --allow-hash"):format(dir2, DENV, MEMO, port)
local out2 = sh(("printf 'n\\nn\\nn\\n' | %s"):format(H.pty(cmd2)))
check("fingerprint rejected by the person → nothing configured", out2:find("Not pinned", 1, true)
    and not (slurp(dir2 .. "/.luamemorc") or ""):find("MEMO_ORG_URL", 1, true), out2:sub(-600))

if pid then os.execute("kill " .. pid .. " 2>/dev/null") end
os.remove(approver)
db.run("DELETE FROM lm_org_devs WHERE org_scope = ?", ORG)
db.run("DELETE FROM lm_memories WHERE scope = ?", ORG)
for _, sfx in ipairs({ "", "-wal", "-shm" }) do os.remove(dev_db .. sfx) end
end)

-- ---------------------------------------------------------------------------
-- F. Switching orgs / going solo (central unreachable), on a throwaway database:
--    a second project of the same org shares the org database; a different
--    central key = a different org → the old one is left first (its replica
--    kept while another project uses it) and, one org per database, the new
--    one is joined only once the project has its own database; --role solo
--    leaves and, as the last project, drops the org from the per-user registry.
section("F switch", function()
io.write("\n--- F: switching orgs / --role solo ---\n")
require("luamemo").setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true })
local FDB = ("lm_fedsw_%d_%04d"):format(os.time(), math.random(0, 9999))
local fdb = H.create_db(FDB)
local FENV = ENV:gsub("MEMO_DB=%b\"\"", ("MEMO_DB=%q"):format(fdb))
    :gsub("XDG_CONFIG_HOME=%b\"\"", ("XDG_CONFIG_HOME=%q"):format(TMP .. "/xdg-sw"))
local function fcal(dir, args) return sh(("cd %q && %s %q calibrate %s </dev/null"):format(dir, FENV, MEMO, args)) end
local function orgs() return require("luamemo.json").decode(slurp(TMP .. "/xdg-sw/luamemo/orgs.json") or "{}") or {} end
local url, FP1, FP2 = "http://127.0.0.1:1", "0123-4567-89AB-CDEF-GHJK", "1111-2222-3333-4444-5555"
local d1, d2 = project("sw1"), project("sw2")
local o1, c1 = fcal(d1, ("--org-url %s --org-fingerprint %s"):format(url, FP1) .. QUIET)
check("first project: its database becomes the org database", c1 == 0
    and o1:find("now this org's database", 1, true) ~= nil, o1:sub(-900))
local o2 = fcal(d2, ("--org-url %s --org-fingerprint %s"):format(url, FP1) .. QUIET)
check("second project of the same org: already on the org database", o2:find("already the org database", 1, true),
    o2:match("Federation.-Pairing") or o2:sub(-900))
-- A third project with NO database configured: it gets the org's database.
local d3 = project("sw3")
sh(("git init -q %q"):format(d3))                -- a git project: its machine settings stay out of git
local NENV = FENV:gsub("MEMO_DB=%b\"\"", 'MEMO_DB=""')
local o2c = sh(("cd %q && %s %q calibrate %s </dev/null"):format(d3, NENV, MEMO,
    ("--org-url %s --org-fingerprint %s"):format(url, FP1) .. QUIET))
check("a project with no database joins the org's database on this machine",
    o2c:find("this org's database on this machine", 1, true) and o2c:find("already the org database", 1, true)
    and rcv(slurp(d3 .. "/.luamemorc"), "MEMO_DB") == fdb, o2c:sub(1, 1500))
check("… and .luamemorc (this machine's settings) is added to the project's .gitignore",
    (slurp(d3 .. "/.gitignore") or ""):find(".luamemorc", 1, true)
    and (sh(("git -C %q status --porcelain"):format(d3))):find("luamemorc", 1, true) == nil,
    slurp(d3 .. "/.gitignore"))
local o3 = fcal(d1, ("--org-url %s --org-fingerprint %s"):format(url, FP2) .. QUIET)
local rc1 = slurp(d1 .. "/.luamemorc") or ""
check("a different central key → the old org is left first (replica kept for the other projects)",
    o3:find("leaving it first", 1, true) and o3:find("kept — 2 other project", 1, true), o3:sub(1, 1500))
check("… but its database is still the old org's (shared) → not joined, told to give it its own",
    o3:find("Not joined (one org per database)", 1, true) and o3:find("its own database", 1, true)
    and not rc1:find("MEMO_ORG_URL", 1, true) and not rc1:find("MEMO_ORG_FINGERPRINT", 1, true), o3:sub(1, 1500))
local norm = require("luamemo.federation.keys").normalize_code
local reg = orgs().orgs or {}
local e1 = reg[norm(FP1)] or {}
check("registry: the old org keeps only the projects still using it; the new one not recorded", e1.projects
    and e1.projects[d2] ~= nil and e1.projects[d3] ~= nil and e1.projects[d1] == nil and reg[norm(FP2)] == nil,
    require("luamemo.json").encode(reg))
-- Its own (fresh) database → the new org's database on this machine.
local db2 = H.create_db(FDB .. "_b")
local f = assert(io.open(d1 .. "/.luamemorc", "a"))
f:write("MEMO_DB=" .. db2 .. "\n"); f:close()
H.trust_rc(d1 .. "/.luamemorc", TMP .. "/xdg-sw/luamemo")   -- edited by hand: trusted again
local o3b = fcal(d1, ("--org-url %s --org-fingerprint %s"):format(url, FP2) .. QUIET)
local rc1b = slurp(d1 .. "/.luamemorc") or ""
check("with its own database it joins the new org", o3b:find("now this org's database", 1, true)
    and rcv(rc1b, "MEMO_ORG_FINGERPRINT") == FP2 and not o3b:find("leaving it first", 1, true),
    o3b:sub(1, 1500))
local o4, c4 = fcal(d1, "--role solo" .. QUIET)
local rc4 = slurp(d1 .. "/.luamemorc") or ""
check("--role solo leaves: org settings gone from the project", c4 == 0 and o4:find("leaving the org", 1, true)
    and not rc4:find("MEMO_ORG_URL", 1, true) and not rc4:find("MEMO_ORG_FINGERPRINT", 1, true), o4:sub(1, 1200))
check("… and the last project of that org drops it from the registry", (orgs().orgs or {})[norm(FP2)] == nil
    and (orgs().orgs or {})[norm(FP1)] ~= nil)
local o5 = fcal(d1, "--role solo" .. QUIET)
check("--role solo on a solo project: nothing to leave", not o5:find("leaving the org", 1, true), o5:sub(1, 600))
end)
H.drop_dbs()

os.execute(("rm -rf %q"):format(TMP))
finish()
