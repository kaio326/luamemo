-- eval/tests/test_federation_keys.lua
-- Phase 12F.2 — secrets store instances + internal secrets + the per-user
-- federation keyring (luamemo.federation.keys).
--   A. secrets.open: create → directory 0700, master key 0600 (64 hex, from
--      the OS random source), store file 0600; put / get_internal / list /
--      delete; ciphertext only on disk; instances independent.
--   B. Internal secrets are sealed off from the public API: the reserved
--      `luamemo.` prefix, no overwrite / delete through secrets.store /
--      secrets.delete, execute_with_secret refuses them BEFORE any network
--      call, listings mark them, get_internal refuses ordinary secrets.
--   C. keys: identity created once and stable across processes, per role;
--      signatures verify; forget → a new identity; the seed never appears in
--      the keyring file; fingerprints / pairing codes (format, determinism,
--      binding to both keys, normalisation).
-- The public API (B) works on the run's database (MEMO_DB).
-- Run: luajit eval/tests/run.lua --only federation_keys

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Federation keys")
local check, section = T.check, T.section
local sh, mode, slurp = H.sh, H.mode, H.slurp

local secrets = require("luamemo.secrets")
local sodium  = require("luamemo.native.sodium")
local hex     = require("luamemo.util").to_hex

local TMP = os.tmpname(); os.remove(TMP)
local DIR = TMP .. "/cfg/luamemo"

-- A database file and its write-ahead log, as one string (recent pages live in the log).
local function on_disk(path) return (slurp(path) or "") .. (slurp(path .. "-wal") or "") end

-- A new Ed25519 public key
local function new_pk() return (sodium.sign_seed_keypair(sodium.random_bytes(32))) end

-- ---------------------------------------------------------------------------
section("A instances", function()
io.write("\n--- A: secrets.open ---\n")
local st, err = secrets.open({ file = DIR .. "/ring.db", master_key_path = DIR .. "/ring.key" })
check("open without create: missing master key → error", st == nil and err ~= nil, err)
st, err = secrets.open({ file = DIR .. "/ring.db", master_key_path = DIR .. "/ring.key", create = true })
check("open with create", st ~= nil, err)
check("keyring directory is 0700", mode(DIR) == "700", mode(DIR))
check("master key file is 0600", mode(DIR .. "/ring.key") == "600", mode(DIR .. "/ring.key"))
local rawkey = (slurp(DIR .. "/ring.key") or ""):gsub("%s", "")
check("master key is 64 hex chars", #rawkey == 64 and rawkey:match("^%x+$") ~= nil)
local st2 = secrets.open({ file = DIR .. "/ring.db", master_key_path = DIR .. "/ring.key", create = true })
check("re-open with create keeps the existing master key",
    st2 ~= nil and (slurp(DIR .. "/ring.key") or ""):gsub("%s", "") == rawkey)
check("no temp files left behind", sh(("ls -A %q"):format(DIR)) == "ring.key")
local secret_value = "s3cr3t-" .. hex(sodium.random_bytes(8))
check("put internal", st:put("luamemo.test.one", secret_value, "unit test", { internal = true }) ~= nil)
check("store file is 0600", mode(DIR .. "/ring.db") == "600", mode(DIR .. "/ring.db"))
check("get_internal returns the value (in-process only)", st2:get_internal("luamemo.test.one") == secret_value)
check("no plaintext on disk", not on_disk(DIR .. "/ring.db"):find(secret_value, 1, true))
check("put ordinary", st:put("plain-one", "v1", nil) ~= nil)
check("get_internal refuses an ordinary secret (no general read API)", st:get_internal("plain-one") == nil)
local names = {}
for _, r in ipairs(st:list()) do names[r.name] = r end
check("list: names + internal flag, never values",
    names["luamemo.test.one"] and names["luamemo.test.one"].internal == true and names["plain-one"] ~= nil
        and not names["plain-one"].internal and names["plain-one"].value == nil
        and names["plain-one"].ciphertext == nil)
check("instance delete of an internal secret needs internal = true",
    not st:delete("luamemo.test.one") and st:delete("luamemo.test.one", { internal = true }) == true)
local other = secrets.open({ file = TMP .. "/other/o.db", master_key_path = TMP .. "/other/o.key", create = true })
check("instances are independent (own master key, own entries)",
    other ~= nil and other:get_internal("plain-one") == nil
        and (slurp(TMP .. "/other/o.key") or "") ~= (slurp(DIR .. "/ring.key") or ""))
end)

-- ---------------------------------------------------------------------------
section("B public api", function()
io.write("\n--- B: internal secrets vs the public API ---\n")
-- The public (MCP / CLI) API works on the luamemo database: give it a master
-- key, and plant an internal secret there through a store instance over the
-- same database (internal secrets normally live in the keyring only).
secrets.configure({ master_key_path = DIR .. "/ring.key" })
local ring = secrets.open({ file = DIR .. "/ring.db", master_key_path = DIR .. "/ring.key" })
local st = setmetatable({ db = require("luamemo.db").get, key = ring.key }, getmetatable(ring))
local seed = "seed-bytes-00000000000000000000!"
check("internal secret planted in the luamemo database",
    st:put("luamemo.identity.dev", seed, "identity", { internal = true }) ~= nil)
local r1, e1 = secrets.store("luamemo.anything", "x")
check("public store refuses the reserved luamemo. prefix", r1 == nil and tostring(e1):find("reserved", 1, true), e1)
local r2, e2 = secrets.store("luamemo.identity.dev", "attacker-known-value")
check("public store cannot overwrite an internal secret", r2 == nil and e2 ~= nil, e2)
check("internal value untouched", st:get_internal("luamemo.identity.dev") == seed)
local ok3, e3 = secrets.delete("luamemo.identity.dev")
check("public delete cannot remove an internal secret", not ok3 and e3 ~= nil, e3)
local http = require("luamemo.http")
local real, called = http.request, false
http.request = function(...) called = true; return real(...) end
local body, e4 = secrets.execute_with_secret("luamemo.identity.dev",
    { url = "https://example.com/?k={secret}" })
http.request = real
check("execute_with_secret refuses an internal secret", body == nil and tostring(e4):find("internal", 1, true), e4)
check("… before any network request", called == false)
local found
for _, r in ipairs(secrets.list()) do if r.name == "luamemo.identity.dev" then found = r end end
check("public list marks internal secrets", found ~= nil and found.internal == true)
check("ordinary secrets still work through the public API",
    secrets.store("plain-two", "v2") ~= nil and secrets.delete("plain-two") == true)
-- DNS rebinding: http:// goes to the address the SSRF check approved — never to
-- a second lookup (simulated: the check's lookup says public, the name itself
-- would reach loopback).
local ng = require("luamemo.netguard")
local real_resolve = ng.resolve
ng.resolve = function(h) if h == "localhost." then return { "203.0.113.7" } end return real_resolve(h) end
local seen
http.request = function(u, o) seen = { url = u, headers = o.headers }; return 200, "ok" end
secrets.store("rebind-token", "S3CRET")
local b5 = secrets.execute_with_secret("rebind-token",
    { url = "http://localhost.:8080/p?q=1", headers = { Authorization = "Bearer {secret}" } })
local host_hdr
for k, v in pairs(seen and seen.headers or {}) do if tostring(k):lower() == "host" then host_hdr = v end end
check("secret_execute (http): connects to the CHECKED address, name kept as the Host header",
    b5 == "ok" and seen and seen.url == "http://203.0.113.7:8080/p?q=1" and host_hdr == "localhost.:8080",
    seen and (seen.url .. " host=" .. tostring(host_hdr)))
secrets.execute_with_secret("rebind-token", { url = "https://localhost.:8443/p" })
check("secret_execute (https): keeps the name (certificate verification)",
    seen and seen.url == "https://localhost.:8443/p", seen and seen.url)
seen = nil
secrets.execute_with_secret("rebind-token", { url = "http://[localhost.]/q?k={secret}" })
check("secret_execute (http): bracketed name → pinned URL built from the parsed parts",
    seen and seen.url == "http://203.0.113.7/q?k=S3CRET", seen and seen.url)
-- Userinfo: the check must see the host the request connects to — an
-- `x:y@host` authority is refused, never checked on `x`.
local reached = 0
http.request = function() reached = reached + 1; return 200, "ok" end
for _, u in ipairs({ "http://8.8.8.8:80@127.0.0.1:9/a", "http://8.8.8.8@127.0.0.1/b",
                     "http://8.8.8.8?@127.0.0.1/c", "https://8.8.8.8:443@10.0.0.1/d" }) do
    local b, e = secrets.execute_with_secret("rebind-token", { url = u })
    check("secret_execute refuses a URL with userinfo: " .. u,
        b == nil and (tostring(e):find("no user@", 1, true) or tostring(e):find("SSRF blocked", 1, true)) ~= nil, e)
end
local b6, e6 = secrets.execute_with_secret("rebind-token", { url = "http://{secret}.example.com/" })
check("secret_execute refuses {secret} in the host", b6 == nil and tostring(e6):find("host part", 1, true), e6)
local b7 = secrets.execute_with_secret("rebind-token", { url = "http://8.8.8.8:{secret}/" })
check("… and in the port", b7 == nil)
check("… all refused before any request", reached == 0, reached)
-- A failed request's error goes back to the agent: it must not quote the value.
http.request = function(u) return nil, nil, "http: timeout — " .. u .. " (sent S3CRET)" end
local b8, e8 = secrets.execute_with_secret("rebind-token", { url = "http://localhost.:8080/p?k={secret}" })
check("failed request: the error shows the {secret} template, never the value",
    b8 == nil and not tostring(e8):find("S3CRET", 1, true)
        and tostring(e8):find("http://localhost.:8080/p?k={secret}", 1, true) ~= nil, e8)
http.request = function() return 302, "" end
local b9, e9 = secrets.execute_with_secret("rebind-token", { url = "http://localhost.:8080/p" })
check("a redirect answer is reported as such (never followed)", b9 == nil
    and tostring(e9):find("redirect", 1, true) ~= nil, e9)
ng.resolve, http.request = real_resolve, real
secrets.delete("rebind-token")
-- Every value is sealed under a fresh random nonce (libsodium's OS random
-- source, which has no weak fallback): the same value stored twice under the
-- same name never gives the same ciphertext.
local db = require("luamemo.db")
secrets.store("nonce-check", "same value")
local c1 = db.value("SELECT value FROM lm_secrets WHERE name = 'nonce-check'")
secrets.store("nonce-check", "same value")
local c2 = db.value("SELECT value FROM lm_secrets WHERE name = 'nonce-check'")
check("a fresh 24-byte nonce per stored value", type(c1) == "string" and type(c2) == "string"
    and c1:match("^x1:%x+$") and c1 ~= c2 and c1:sub(4, 51) ~= c2:sub(4, 51), tostring(c1) .. " / " .. tostring(c2))
secrets.delete("nonce-check")
secrets.configure({})
end)

-- ---------------------------------------------------------------------------
section("C keys", function()
io.write("\n--- C: federation keyring ---\n")
local keys = require("luamemo.federation.keys")
local KDIR = TMP .. "/xdg/luamemo"
keys.set_dir(KDIR)
check("no identity yet", keys.public_key("dev") == nil)
local pk = keys.ensure_identity("dev")
check("identity created (32-byte public key)", type(pk) == "string" and #pk == 32)
check("idempotent", keys.ensure_identity("dev") == pk)
check("roles are separate identities", keys.ensure_identity("central") ~= pk)
local seed = secrets.open({ file = KDIR .. "/keyring.db", master_key_path = KDIR .. "/keyring.key" })
    :get_internal("luamemo.identity.dev")
local ring = on_disk(KDIR .. "/keyring.db")
check("keyring holds ciphertext only (the seed is not in the clear)",
    type(seed) == "string" and #seed == 32 and #ring > 0 and not ring:find(seed, 1, true)
        and not ring:find(hex(seed), 1, true))
check("keyring files are private", mode(KDIR) == "700" and mode(KDIR .. "/keyring.key") == "600"
    and mode(KDIR .. "/keyring.db") == "600")
local msg = "handshake transcript"
local sig = keys.sign("dev", msg)
check("signature verifies with the public key", sig ~= nil and sodium.verify(sig, msg, pk))
check("unknown role rejected", not pcall(keys.sign, "admin", msg))
-- A new process sees the same identity (fresh module state).
package.loaded["luamemo.federation.keys"] = nil
local keys2 = require("luamemo.federation.keys")
keys2.set_dir(KDIR)
check("identity stable across processes", keys2.public_key("dev") == pk)
check("forget_identity", keys2.forget_identity("dev") == true and keys2.public_key("dev") == nil)
check("a new identity after forget differs", keys2.ensure_identity("dev") ~= pk)

local fp = keys2.fingerprint(pk)
check("fingerprint: 5 groups of 4 Crockford base32 chars",
    fp:match("^[0-9A-HJKMNP-TV-Z]+%-[0-9A-HJKMNP-TV-Z]+%-[0-9A-HJKMNP-TV-Z]+%-[0-9A-HJKMNP-TV-Z]+%-[0-9A-HJKMNP-TV-Z]+$")
        ~= nil and #fp == 24, fp)
check("fingerprint deterministic", keys2.fingerprint(pk) == fp)
local c_pk, d_pk = new_pk(), new_pk()
local code = keys2.pairing_code(c_pk, d_pk)
check("pairing code: 2 groups of 4", code:match("^[0-9A-HJKMNP-TV-Z]+%-[0-9A-HJKMNP-TV-Z]+$") ~= nil and #code == 9, code)
check("pairing code deterministic", keys2.pairing_code(c_pk, d_pk) == code)
check("pairing code binds the dev key", keys2.pairing_code(c_pk, new_pk()) ~= code)
check("pairing code binds the central key", keys2.pairing_code(new_pk(), d_pk) ~= code)
check("normalisation: case / dashes / spaces / look-alikes",
    keys2.normalize_code(code:lower():gsub("%-", " ")) == keys2.normalize_code(code)
        and keys2.normalize_code("o1-iL") == "0111")
keys2.set_dir(nil)
end)

os.execute(("rm -rf %q"):format(TMP))
T.finish()
