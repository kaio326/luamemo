-- eval/tests/_org.lua
-- A mock org central for tests: a real `memo serve` of its own — its own SQLite database, its own keys, the encrypted
-- channel — that a test pairs a dev with and talks to, so a test of the org paths does not have to fake the other side.
-- (Shared helpers live in _harness.lua; this one is for the tests that need a central.)
--
--   local Org = require("eval.tests._org")
--   local org = assert(Org.start({ name = "fedx", central_config = "feedback_enabled = true",
--                                  seed = [[assert(luamemo.store.write({ scope = "org:fedx", title = "t", body = "b" }))]] }))
--   org.port, org.fp, org.scope ("org:fedx"), org.db_path, org.keydir
--   org:call(code)           run Lua against the central's database and keys, in a process of its own → what the code
--                            passed to result(v). In the code: luamemo (set up as the central), db, json, k (the
--                            knowledge queue), devs, store (luamemo.store).
--   org:dev_config(extra)    the config of a dev paired with this central (role, org_url, org_fingerprint, org_identity)
--   org:as_dev(extra, keydir, base) set the calling process up as a dev of this central (keys in `keydir`, hash embedder,
--                            the test's own `base` config, org:dev_config(extra) on top, a fresh session)
--   org:pair(client)         pair the calling process (set up as a dev of this central, with its own keys directory) through
--                            `client` = luamemo.federation.client, and approve the device on the central → true | nil, err
--   org:approve(code)        the admin approves the device that read out `code` (what pair() does after client.pair()) → bool
--   org:stop()               stop the server (waits until it is gone), remove its database, keys and log
-- Run the test with eval/tests/run.lua as usual; the central needs no network beyond 127.0.0.1.

local H = require("eval.tests._harness")
local json = require("luamemo.json")

local Org = {}
Org.__index = Org

local seq = 0

--- Start a central → org | nil, err. Whatever fails on the way, nothing is left behind (database, keys, server).
-- opts.name           org name (letters; the scope is org:<name>)
-- opts.central_config extra config for the central's helper, as the inside of a Lua table: "feedback_enabled = true, ..."
-- opts.env            environment for the served central, as shell words: "MEMO_FEEDBACK_ENABLED=true" (the served process
--                     reads the environment, not central_config — a test that talks to the server over the wire sets both)
-- opts.prelude        Lua added to the helper's prelude (more locals for org:call: "local ls = require(...)")
-- opts.seed           Lua run once on the central, before the server starts (see org:call for what it can use)
-- opts.timeout        seconds the served central lives at most (default 600)
function Org.start(opts)
    opts = opts or {}
    seq = seq + 1
    local o = setmetatable({}, Org)
    o.name = opts.name or "fedmock"
    o.scope = "org:" .. o.name
    o.lua = H.lua_bin()
    local suffix = ("%d_%04d_%d"):format(os.time(), math.random(0, 9999), seq)
    o.db_name = "lm_mockorg_" .. suffix
    o.db_path = H.db_path(o.db_name)
    o.keydir = H.tmp_path("org_keys_" .. suffix)
    o.prelude = ([[
package.path = "./?.lua;./?/init.lua;" .. package.path
local luamemo = require("luamemo")
luamemo.setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false,
                role = "org", org_name = %q, %s })
local db, json = require("luamemo.db"), require("luamemo.json")
local store = luamemo.store
local k = require("luamemo.federation.knowledge")
local devs = require("luamemo.federation.devs")
local function result(v) io.write("\n@@RESULT@@" .. json.encode(v or {}) .. "\n") end
]]):format(o.name, opts.central_config or "") .. (opts.prelude or "")
    local ok, err = pcall(function()
        H.create_db(o.db_name)
        local ident = o:call([[local kk = require("luamemo.federation.keys")
]] .. (opts.seed or "") .. [[
result({ fp = kk.fingerprint(assert(kk.ensure_identity("central"))) })]])
        o.fp = ident.fp
        if not o.fp then error("the central did not start", 0) end
        o.log = H.tmp_path("org_log_" .. suffix)
        local srv = "package.path='./?/init.lua;'..package.path; require('luamemo.cli.serve').run({'--port','0'})"
        local out = H.sh(("MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_ROLE=org MEMO_ORG_NAME=%s MEMO_FEDERATION_DIR=%q %s "
            .. "%s%s -e %q >/dev/null 2>%q & echo \"PID=$!\""):format(o.db_path, o.name, o.keydir, opts.env or "",
            H.timeout(opts.timeout or 600), o.lua, srv, o.log))
        o.pid = tonumber(out:match("PID=(%d+)"))
        o.port = H.wait_port(o.log)
        if not o.port then error("the central did not listen: " .. (H.slurp(o.log) or ""):sub(1, 400), 0) end
    end)
    if not ok then
        o:stop()
        return nil, tostring(err)
    end
    return o
end

function Org:call(code)
    local path = os.tmpname()
    local f = assert(io.open(path, "w")); f:write(self.prelude, "\n", code, "\n"); f:close()
    local out = H.sh(("MEMO_DB=%q MEMO_FEDERATION_DIR=%q %s %q"):format(self.db_path, self.keydir, self.lua, path))
    os.remove(path)
    local body = out:match("@@RESULT@@([^\n]*)")
    if not body then error("central helper failed: " .. out:sub(1, 600), 0) end
    return json.decode(body)
end

function Org:dev_config(extra)
    local c = { role = "dev", org_url = "http://127.0.0.1:" .. tostring(self.port), org_fingerprint = self.fp,
                org_identity = "user:dev@corp.io" }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

--- Set the calling process up as a dev of this central: its own keys directory `keydir`, the hash embedder, the config of
--- org:dev_config(extra) on top, and a fresh session with the central
function Org:as_dev(extra, keydir, base)
    require("luamemo.federation.keys").set_dir(keydir)
    H.setup(self:dev_config(extra), base)
    require("luamemo.federation.client")._reset_session()
end

--- The admin approves the device that read out `code` → true | false
function Org:approve(code)
    return self:call(("result({ ok = devs.approve(%q, 'test') ~= nil })"):format(code)).ok == true
end

--- Pair the calling process (already set up as a dev of this central) → true | nil, err
function Org:pair(client)
    local pr, err = client.pair()
    if not pr then return nil, err end
    if not self:approve(pr.code) then return nil, "the central did not approve the device" end
    return true
end

--- Stop the server (and wait until it is gone), remove its database, keys and log. Safe to call on a half-started central.
function Org:stop()
    if self.pid then
        os.execute("kill " .. self.pid .. " 2>/dev/null")
        for _ = 1, 50 do
            if os.execute("kill -0 " .. self.pid .. " 2>/dev/null") ~= 0 then break end
            os.execute("sleep 0.1")
        end
    end
    for _, sfx in ipairs({ "", "-wal", "-shm" }) do os.remove(self.db_path .. sfx) end
    if self.keydir then os.execute(("rm -rf %q"):format(self.keydir)) end
    if self.log then os.remove(self.log) end
end

return Org
