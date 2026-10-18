-- eval/tests/test_federation_server.lua
-- Phase 12 central + 12F.3 channel: the org central's federation endpoints.
--   A. local-network policy (luamemo.netguard, server bind / peer rules)
--   B. channel protocol, pure (luamemo.federation.channel): handshake, keys,
--      envelope tamper / direction / session binding, pairing messages, and
--      "unknown or unapproved key → refused before any signature work"
--   C. central operations (DB): snapshot paging + manifest + µs strings + ids
--      repair + weights; feedback ingest (idempotent, attribution, signals)
--   D. endpoints through handlers.handle: /key, /pair (pending, newest per
--      identity, cap), devs approve-by-code / remove, /hello, encrypted /call
--      RPC (info · snapshot · feedback attributed to the key), replay, tamper,
--      unknown session, revoked device, content types, role gate, crash → 500
--   E. a real `memo serve` (public bind refused, /key over HTTP, malformed
--      raw requests, log hygiene)
-- Uses the run's database (MEMO_DB). Scopes org:fedsrv / repo:fedsrv.
-- Run: luajit eval/tests/run.lua --only federation_server

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Federation server")
local check, section, finish, fail = T.check, T.section, T.finish, T.fail

local json    = require("luamemo.json")
local sodium  = require("luamemo.native.sodium")
local channel = require("luamemo.federation.channel")
local common  = require("luamemo.federation.common")
local ng      = require("luamemo.netguard")

-- A throwaway identity: public key + secret key + signer.
local function ident()
    local pk, sk = sodium.sign_seed_keypair(sodium.random_bytes(32))
    return { pk = pk, sk = sk, sign = function(m) return sodium.sign(m, sk) end }
end
-- The hello key as `who` computes it for (central_pk, dev_pk) — keys.dh + channel.hello_key.
local function hkey(who, peer_pk, central_pk, dev_pk)
    local shared = assert(sodium.x25519(sodium.ed25519_sk_to_x25519(who.sk), sodium.ed25519_pk_to_x25519(peer_pk)))
    return channel.hello_key(shared, central_pk, dev_pk)
end
local function dev_hkey(dev, cpk) return hkey(dev, cpk, cpk, dev.pk) end

-- Count signature verifications while fn runs (the channel calls sodium.verify).
local function count_verifies(fn)
    local real, n = sodium.verify, 0
    sodium.verify = function(...) n = n + 1; return real(...) end
    local ok, a, b, c, d = pcall(fn)
    sodium.verify = real
    if not ok then error(a, 0) end
    return n, a, b, c, d
end

-- ---------------------------------------------------------------------------
section("A policy", function()
io.write("\n--- A: local-network policy ---\n")
local cases = {
    { "127.0.0.1", "loopback" }, { "10.0.0.1", "private" }, { "172.16.0.1", "private" },
    { "172.31.255.255", "private" }, { "172.32.0.1", "public" }, { "192.168.0.10", "private" },
    { "100.64.0.1", "cgnat" }, { "100.127.255.254", "cgnat" }, { "100.128.0.1", "public" },
    { "100.63.255.255", "public" }, { "169.254.10.1", "link-local" }, { "8.8.8.8", "public" },
    { "0.0.0.0", "unspecified" }, { "224.0.0.1", "multicast" }, { "255.255.255.255", "reserved" },
    { "::1", "loopback" }, { "::", "unspecified" }, { "fd7a:115c:a1e0::53", "ula" }, { "fc00::1", "ula" },
    { "fe80::1%eth0", "link-local" }, { "febf::1", "link-local" }, { "fec0::1", "reserved" },
    { "feff::1", "reserved" }, { "ff02::1", "multicast" }, { "2001:4860:4860::8888", "public" },
    { "::ffff:10.1.1.1", "private" }, { "::ffff:1.1.1.1", "public" }, { "[fd00::2]", "ula" },
    -- embedded IPv4 behind a translator: public only when the embedded address is
    { "::127.0.0.1", "reserved" }, { "64:ff9b::7f00:1", "reserved" }, { "64:ff9b::808:808", "public" },
    { "2002:7f00:1::1", "reserved" }, { "2002:808:808::1", "public" }, { "64:ff9b:1::a00:1", "reserved" },
}
local bad = {}
for _, c in ipairs(cases) do
    if ng.classify(c[1]) ~= c[2] then bad[#bad + 1] = c[1] .. "=" .. tostring(ng.classify(c[1])) end
end
check("classify: IPv4 / IPv6 / Tailscale CGNAT + ULA / mapped / edges (" .. #cases .. " cases)", #bad == 0,
    table.concat(bad, " "))
check("not an IP → nil", ng.classify("example.com") == nil and ng.classify("1.2.3.256") == nil
    and ng.classify("1::2::3") == nil and ng.classify("12345::") == nil)
check("host_is_local: literals", ng.host_is_local("100.100.100.100") and not ng.host_is_local("8.8.4.4"))
check("host_is_local: localhost resolves locally", (ng.host_is_local("localhost")))
check("host_is_public: private refused (SSRF policy)", not ng.host_is_public("192.168.1.1")
    and not ng.host_is_public("fd7a:115c:a1e0::1") and ng.host_is_public("1.1.1.1"))
-- Leading zeros are octal to the resolver luasocket connects through: judged by
-- the address the connection really uses, never by the decimal reading.
check("octal-looking IPv4 is not a decimal literal (0177.0.0.1 = 127.0.0.1, 010.0.0.1 = 8.0.0.1)",
    ng.classify("0177.0.0.1") == nil and not ng.host_is_public("0177.0.0.1") and ng.host_is_local("0177.0.0.1")
    and not ng.host_is_local("010.0.0.1") and ng.host_is_public("010.0.0.1"))
check("embedded loopback / private IPv4 is neither public nor local", not ng.host_is_public("::127.0.0.1")
    and not ng.host_is_local("::127.0.0.1") and not ng.host_is_public("64:ff9b::a00:1"))
local function pu(u) return table.concat({ tostring(ng.parse_url(u)), select(2, ng.parse_url(u)) }, "|") end
check("parse_url: host / port / path, IPv6 brackets",
    pu("http://h.lan:8080/a?b") == "http|h.lan|8080|/a?b" and pu("https://[fd7a::1]/x") == "https|fd7a::1||/x"
        and pu("http://10.0.0.1") == "http|10.0.0.1||", pu("http://h.lan:8080/a?b"))
check("parse_url: userinfo / other schemes / junk ports refused",
    ng.parse_url("http://a:b@10.0.0.1/") == nil and ng.parse_url("http://8.8.8.8?@127.0.0.1/") == nil
        and ng.parse_url("ftp://h/") == nil and ng.parse_url("http://h:8x/") == nil)
local server = require("luamemo.federation.server")
check("bind: loopback / LAN / Tailscale / wildcard allowed",
    server.bind_allowed("127.0.0.1") and server.bind_allowed("192.168.10.5") and server.bind_allowed("100.90.1.2")
        and server.bind_allowed("0.0.0.0") and server.bind_allowed("::"))
check("bind: public address refused", not server.bind_allowed("8.8.8.8"))
check("peer: local served, public dropped", server.peer_allowed("100.70.1.1") and server.peer_allowed("::1")
    and not server.peer_allowed("203.0.113.9") and not server.peer_allowed("2001:db9::1"))
end)

-- ---------------------------------------------------------------------------
section("B channel", function()
io.write("\n--- B: channel protocol ---\n")
local C, Dv = ident(), ident()
local approved = { id = 7, identity = "user:dev@corp.io", status = "approved" }
local function accept(msg, lookup)
    return channel.server_accept(msg, { central_pk = C.pk, sign = C.sign, lookup = lookup or function(pk)
        return pk == Dv.pk and approved or nil end, hello_key = function(dpk) return hkey(C, dpk, C.pk, dpk) end })
end
local HK = dev_hkey(Dv, C.pk)
check("static hello key: the device and the central derive the same one (nothing exchanged)",
    HK == hkey(C, Dv.pk, C.pk, Dv.pk) and #HK == 32 and HK ~= dev_hkey(ident(), C.pk))
local hello, st = channel.client_hello(C.pk, Dv.pk, Dv.sign, HK)
local welcome, ssess = accept(hello)
check("handshake accepted", welcome ~= nil, ssess)
local csess = welcome and channel.client_finish(st, welcome)
check("both sides derive the same session keys", csess and ssess and csess.keys == ssess.keys and #csess.keys == 64)
check("welcome names the paired identity", welcome and welcome.identity == "user:dev@corp.io")
local k, sid = csess.keys, csess.id
local env = channel.seal(k, sid, "c2s", 1, '{"method":"info"}')
local pt, n = channel.unseal(k, sid, "c2s", env)
check("envelope round trip", pt == '{"method":"info"}' and n == 1)
check("ciphertext hides the plaintext", not env:find("info", 1, true))
local function flip(s, i) return s:sub(1, i - 1) .. string.char((s:byte(i) + 1) % 256) .. s:sub(i + 1) end
check("tampered ciphertext rejected", channel.unseal(k, sid, "c2s", flip(env, #env)) == nil)
check("tampered counter rejected", channel.unseal(k, sid, "c2s", flip(env, 28)) == nil)
check("direction bound (c2s ≠ s2c)", channel.unseal(k, sid, "s2c", env) == nil)
check("session bound", channel.unseal(k, sodium.random_bytes(16), "c2s", env) == nil)
check("peek: header only", select(2, channel.peek(env)) == 1 and channel.peek("junk") == nil)
local big = "LMC2" .. ("S"):rep(16) .. "\0\32\0\0\0\0\0\0" .. ("M"):rep(32)
local max = "LMC2" .. ("S"):rep(16) .. "\0\31\255\255\255\255\255\255" .. ("M"):rep(32)
check("counters ≥ 2^53 refused (no precision loss / integer wrap)", channel.peek(big) == nil
    and select(2, channel.peek(max)) == 2 ^ 53 - 1)
local v1 = "LMC1" .. env:sub(5)
local v1_sid, v1_err = channel.peek(v1)
check("a version-1 envelope is refused, naming the protocol to update to",
    v1_sid == nil and tostring(v1_err):find("protocol 3", 1, true) ~= nil
        and channel.unseal(k, sid, "c2s", v1) == nil, v1_err)

-- A forged welcome (not signed by the pinned central) is refused by the dev.
local X = ident()
local fake = channel.server_accept(hello, { central_pk = C.pk, sign = X.sign, lookup = function() return approved end,
    hello_key = function() return HK end })
check("impersonated central refused by the dev", select(2, channel.client_finish(st, fake)) ~= nil
    and channel.client_finish(st, fake) == nil)
local w2 = accept((channel.client_hello(C.pk, Dv.pk, Dv.sign, HK)))
local h2b, st2b = channel.client_hello(C.pk, Dv.pk, Dv.sign, HK)
local w3 = accept(h2b)
w3.identity = "user:ceo@corp.io"                 -- altered in transit
check("the welcome's identity is signed: altering it breaks the handshake", w2 ~= nil
    and channel.client_finish(st2b, w3) == nil)

-- Refusals: unknown / pending / removed keys cost no signature verification.
local h2 = channel.client_hello(C.pk, Dv.pk, Dv.sign, HK)
local w1, e1, s1, w2, s2, w3, s3
local calls = count_verifies(function()
    w1, e1, s1 = accept(h2, function() return nil end)
    w2, _, s2 = accept(h2, function() return { id = 1, identity = "user:x@y.z", status = "pending" } end)
    w3, _, s3 = accept(h2, function() return { id = 1, identity = "user:x@y.z", status = "removed" } end)
end)
check("unknown key → 403", w1 == nil and s1 == 403, e1)
check("pending key → 403", w2 == nil and s2 == 403)
check("removed key → 403", w3 == nil and s3 == 403)
check("… with no signature verification spent on them", calls == 0, calls)

local h3 = channel.client_hello(ident().pk, Dv.pk, Dv.sign, HK)
check("hello for a different central → 409", select(3, accept(h3)) == 409)
local h4 = channel.client_hello(C.pk, Dv.pk, Dv.sign, HK, os.time() - 3600)
check("stale timestamp → 400", select(3, accept(h4)) == 400)
-- Someone who knows only the device's PUBLIC key: its hello fails the MAC —
-- refused with one HMAC, before any signature work.
local fh = channel.client_hello(C.pk, Dv.pk, X.sign, dev_hkey(X, C.pk))
local fs, fwhy
calls = count_verifies(function() _, _, fs, fwhy = accept(fh) end)
check("forged hello (device key known, device secret not) → 401 'mac', no signature verified",
    fs == 401 and fwhy == "mac" and calls == 0, ("%s %s verifies=%d"):format(tostring(fs), tostring(fwhy), calls))
local h5 = channel.client_hello(C.pk, Dv.pk, X.sign, HK)        -- right MAC, wrong signature
check("bad hello signature → 401", select(3, accept(h5)) == 401)
local nomac = channel.client_hello(C.pk, Dv.pk, Dv.sign, HK); nomac.mac = nil
check("hello without its MAC → 400", select(3, accept(nomac)) == 400)
check("malformed hello → 400", select(3, accept({ v = channel.VERSION, dev_pk = "zz" })) == 400)
local old = channel.client_hello(C.pk, Dv.pk, Dv.sign, HK); old.v = 1
local _, oerr, ost = accept(old)
check("a version-1 hello → 400 'unsupported handshake version'", ost == 400
    and tostring(oerr):find("unsupported handshake version", 1, true) ~= nil, oerr)

-- Pairing messages.
local preq = channel.pair_request(C.pk, Dv.pk, "user:Dev@Corp.io", Dv.sign)
local pr, perr = channel.pair_verify(preq, C.pk)
check("pairing request verifies (identity lower-cased)", pr and pr.identity == "user:dev@corp.io", perr)
check("pairing for another central → 409", select(3, channel.pair_verify(preq, X.pk)) == 409)
local bad_id = channel.pair_request(C.pk, Dv.pk, "not-an-identity", Dv.sign)
check("pairing identity must be user:<email> → 400", select(3, channel.pair_verify(bad_id, C.pk)) == 400)
local forged = channel.pair_request(C.pk, Dv.pk, "user:dev@corp.io", X.sign)
check("pairing signed by another key → 401", select(3, channel.pair_verify(forged, C.pk)) == 401)
local ack = channel.pair_ack(pr, "pending", C.sign)
check("pairing answer verifies against the pinned key", channel.pair_check_ack(preq, ack, C.pk) == "pending")
check("forged pairing answer refused", channel.pair_check_ack(preq, channel.pair_ack(pr, "approved", X.sign), C.pk) == nil)
end)

local luamemo  = require("luamemo")
local db       = require("luamemo.db")
local store    = luamemo.store
local policy   = require("luamemo.federation.policy")
local handlers = require("luamemo.federation.handlers")
local central  = require("luamemo.federation.central")
local keys     = require("luamemo.federation.keys")
local devs     = require("luamemo.federation.devs")

local KDIR = os.tmpname(); os.remove(KDIR)
keys.set_dir(KDIR)
local BASE = { embedder_local = "hash", embed_dim = 384, skip_embed_probe = true,
               patterns_enabled = false, role = "org", org_name = "fedsrv" }
local function setup(extra)
    local cfg = {}
    for k, v in pairs(BASE) do cfg[k] = v end
    for k, v in pairs(extra or {}) do cfg[k] = v end
    luamemo.setup(cfg)
end
local function wipe()
    db.run("DELETE FROM lm_reinforcements WHERE scope IN ('org:fedsrv','repo:fedsrv')")
    db.run("DELETE FROM lm_retrieval_feedback WHERE scope IN ('org:fedsrv','repo:fedsrv')")
    db.run("DELETE FROM lm_learner_weights WHERE scope = 'org:fedsrv'")
    db.run("DELETE FROM lm_memories WHERE scope IN ('org:fedsrv','repo:fedsrv')")
    db.run("DELETE FROM lm_org_devs WHERE org_scope = 'org:fedsrv'")   -- sessions cascade
end
local function row(id)
    return db.first("SELECT importance, tier FROM lm_memories WHERE id = ?", math.floor(tonumber(id) or 0)) or {}
end

setup()
wipe()
local DIR = policy.capability("directive")
local D  = store.write({ scope = "org:fedsrv", title = "Directive: tests", importance = 0.9,
                         body = "Every change ships with tests.", _cap = DIR })
local R1 = store.write({ scope = "org:fedsrv", title = "org note 1", body = "prefer small pull requests", importance = 0.5 })
local R2 = store.write({ scope = "org:fedsrv", title = "org note 2", body = "document public APIs", importance = 0.7 })
local R0 = store.write({ scope = "org:fedsrv", title = "ephemeral", body = "raw session event", importance = 0.1 })
local P  = store.write({ scope = "repo:fedsrv", title = "personal", body = "not an org memory", importance = 0.5 })

-- ---------------------------------------------------------------------------
section("C central", function()
io.write("\n--- C1: snapshot ---\n")
local ls = require("luamemo.learner_store")
local wv = ls.save_version("org:fedsrv", "reranker", { w = { 0.5, -0.25 } }, { note = "test" })
ls.promote("org:fedsrv", "reranker", wv)
local seen, pages, cursors, last, since = {}, 0, {}, nil, nil
repeat
    local page, perr = central.snapshot({ since = since, limit = 2, vectors = true })
    if not page then fail("snapshot page: " .. tostring(perr)); break end
    pages = pages + 1
    for _, r in ipairs(page.rows) do
        seen[r.id] = (seen[r.id] or 0) + 1
        if not (r.vector and #r.vector == 384) then fail("vector missing on row " .. r.id) end
    end
    cursors[#cursors + 1] = page.cursor
    since, last = page.cursor, page
until not page.more or pages > 10
check("snapshot: pages until more=false", last and last.more == false and pages == 2, pages)
check("snapshot: directive + tier-1/2 rows each exactly once", seen[D.id] == 1 and seen[R1.id] == 1 and seen[R2.id] == 1)
check("snapshot: tier-0 row excluded", seen[R0.id] == nil)
check("snapshot: personal scope excluded", seen[P.id] == nil)
local m1 = last and last.manifest and last.manifest[1]
check("snapshot: manifest entries are {id, \"updated_us\"} (exact decimal string)",
    last and #last.manifest == 3 and type(m1[2]) == "string" and m1[2]:match("^%d+$") and tonumber(m1[2]) > 1e15)
local wire = json.decode(json.encode(last or {}))
local lr = wire and wire.rows and wire.rows[#wire.rows]
check("snapshot: µs values exact over JSON (cursor = last row's updated_us:id)",
    lr and type(lr.updated_us) == "string" and wire.cursor == lr.updated_us .. ":" .. ("%d"):format(lr.id))
local rep = central.snapshot({ ids = R2.id .. "," .. P.id .. "," .. D.id, vectors = true })
local got = {}
for _, r in ipairs(rep and rep.rows or {}) do got[r.id] = true end
check("snapshot ids=: exactly the requested org rows", got[R2.id] and got[D.id] and not got[P.id] and #rep.rows == 2)
check("snapshot ids=: no cursor / manifest", rep.cursor == nil and rep.manifest == nil)
check("snapshot ids=: malformed list refused", central.snapshot({ ids = "1,x" }) == nil)
check("snapshot: weights on the last page", last.weights.reranker and last.weights.reranker.version == wv
    and last.weights.reranker.weights.w[2] == -0.25)
check("snapshot: cursor advances", tonumber(cursors[2]:match("^(%d+)")) >= tonumber(cursors[1]:match("^(%d+)")))
local again = central.snapshot({ since = since })
check("snapshot: from the final cursor → empty page with the manifest", #again.rows == 0 and #again.manifest == 3)
check("snapshot: invalid cursor refused", central.snapshot({ since = "bogus" }) == nil)
check("snapshot: no vectors unless asked", central.snapshot({}).rows[1].vector == nil)

io.write("\n--- C2: feedback ingest ---\n")
local imp0 = tonumber(row(R1.id).importance)
local body = { share = "triples",
    events = { { ref = "bob:e1", memory = R1.id, type = "miss", delta = 1.0 },
               { ref = "bob:e2", memory = P.id, type = "miss" },
               { ref = "bob:e3", memory = R2.id, type = "exploded" },
               { memory = R2.id, type = "praise" },
               { ref = "bob:e5", memory = D.id, type = "miss", delta = 1.0 } },
    retrievals = { { ref = "bob:r1", query = "small pull requests", candidates = { R1.id, P.id } } } }
local r3 = central.ingest_feedback("user:bob@corp.io", body, "user:bob@corp.io")
check("ingest: 2 events accepted (R1 miss, directive miss)", r3 and r3.accepted_events == 2)
check("ingest: bad events rejected with reasons", r3 and #r3.rejected == 3)
check("ingest: retrieval accepted", r3 and r3.accepted_retrievals == 1)
local imp1 = tonumber(row(R1.id).importance)
check("ingest: the miss raised R1's importance", imp1 > imp0, ("%s → %s"):format(imp0, imp1))
check("ingest: directive untouched", tonumber(row(D.id).importance) == 0.9 and tonumber(row(D.id).tier) == 3)
local rf = db.first("SELECT candidate_ids, source FROM lm_retrieval_feedback WHERE source_ref = 'bob:r1'")
local cids = rf and rf.candidate_ids
check("ingest: org candidates only, attributed", rf and rf.source == "user:bob@corp.io"
    and type(cids) == "table" and #cids == 1 and tonumber(cids[1]) == R1.id,
    rf and json.encode(rf.candidate_ids))
local r4 = central.ingest_feedback("user:bob@corp.io", body, "user:bob@corp.io")
check("re-push: all duplicates, nothing re-applied", r4.accepted_events == 0 and r4.duplicates == 3
    and tonumber(row(R1.id).importance) == imp1)
local r5 = central.ingest_feedback("user:bob@corp.io", { share = "signals",
    events = { { ref = "bob:e-sig", memory = R2.id, type = "praise", note = "private context" } },
    retrievals = { { ref = "bob:r2", query = "x", candidates = { R1.id } } } }, "user:bob@corp.io")
local nrow = db.query("SELECT note FROM lm_reinforcements WHERE source_ref = 'bob:e-sig'")
check("signals: retrievals ignored, event kept, its note dropped", r5.accepted_retrievals == 0
    and nrow and nrow[1] and nrow[1].note == nil)
check("attribution: other identity than the credential's → 403",
    select(3, central.ingest_feedback("user:eve@corp.io", { events = {} }, "user:bob@corp.io")) == 403)
local many = {}
for i = 1, central.MAX_EVENTS + 1 do many[i] = { ref = "x" .. i, memory = R1.id, type = "praise" } end
check("too many events → 413", select(3, central.ingest_feedback("user:bob@corp.io", { events = many })) == 413)
-- A push may name MAX_EVENTS + MAX_RETRIEVALS × MAX_CANDIDATES ids: they are
-- checked in one statement whatever their number (SQLite caps a statement's
-- variables at 32,766, LuaJIT's unpack stops near 8,000).
local big = {}
for i = 1, 200 do
    local c = { R1.id }
    for j = 1, 99 do c[#c + 1] = 1000000 + i * 100 + j end
    big[i] = { ref = "bob:big" .. i, query = "big push " .. i, candidates = c }
end
local okb, rb = pcall(central.ingest_feedback, "user:bob@corp.io", { share = "triples", retrievals = big },
    "user:bob@corp.io")
check("a push naming 20,000 distinct ids is checked in one statement", okb and rb and rb.accepted_retrievals == 200,
    okb and json.encode(rb and rb.rejected or {}) or rb)
end)

-- ---------------------------------------------------------------------------
-- In-process client over handlers.handle (no network).
local function call(method, path, body, ctype, peer)
    local st, b, ct = handlers.handle({ method = method, path = path, peer = peer,
        headers = { ["content-type"] = ctype or (body and "application/json") or nil },
        body = type(body) == "table" and json.encode(body) or body or "" })
    return st, (ct == "application/json") and json.decode(b) or b, ct
end
local CPK
local function connect(dev)
    local hello, st = channel.client_hello(CPK, dev.pk, dev.sign, dev_hkey(dev, CPK))
    local s, w = call("POST", "/federation/hello", hello)
    if s ~= 200 then return nil, s, w end
    local sess = channel.client_finish(st, w)
    sess.n = 0
    return sess
end
local function rpc(sess, method, params, n)
    n = n or (sess.n + 1)
    sess.n = math.max(sess.n, n)
    local env = channel.seal(sess.keys, sess.id, "c2s", n, json.encode({ method = method, params = params or {} }))
    local s, b = call("POST", "/federation/call", env, "application/octet-stream")
    if s ~= 200 then return nil, s, b end
    local pt, rn = channel.unseal(sess.keys, sess.id, "s2c", b)
    return pt and json.decode(pt), s, rn, env
end

section("D endpoints", function()
io.write("\n--- D1: key + pairing ---\n")
policy.configure({})
check("non-org instance → 404", (call("GET", "/federation/key")) == 404)
setup()
local s1, k = call("GET", "/federation/key")
CPK = k and k.central_pk and channel.unhex(k.central_pk)
check("GET /key: central key + fingerprint + org", s1 == 200 and CPK and #CPK == 32
    and k.fingerprint == keys.fingerprint(CPK) and k.org_scope == "org:fedsrv", s1)
check("central identity lives in the per-user keyring", keys.public_key("central") == CPK)
check("unknown route → 404", (call("GET", "/federation/info")) == 404)
local alice, alice2, mallory = ident(), ident(), ident()
local function pair(dev, who, peer)
    local req = channel.pair_request(CPK, dev.pk, who, dev.sign)
    local s, b = call("POST", "/federation/pair", req, nil, peer)
    return s, b, req
end
local sp, ack, preq = pair(alice, "user:alice@corp.io")
check("pair → pending (answer signed by the central's key)", sp == 200 and ack.status == "pending"
    and channel.pair_check_ack(preq, ack, CPK) == "pending")
local pend = devs.list("pending")
check("admin sees the pending request with the code both sides compute",
    #pend == 1 and pend[1].identity == "user:alice@corp.io" and pend[1].pairing_code == keys.pairing_code(CPK, alice.pk))
check("pairing is idempotent for the same key", (pair(alice, "user:alice@corp.io")) == 200 and #devs.list("pending") == 1)
pair(mallory, "user:alice@corp.io")        -- someone else claims alice's identity
pend = devs.list("pending")
check("newest pending per identity replaces the older one", #pend == 1
    and pend[1].pairing_code == keys.pairing_code(CPK, mallory.pk))
check("approving with alice's code fails (the request on file is mallory's)",
    devs.approve(keys.pairing_code(CPK, alice.pk)) == nil)
pair(alice, "user:alice@corp.io")          -- alice asks again
local ap_row, ap_err = devs.approve(keys.pairing_code(CPK, alice.pk), "admin")
check("approve by the code the dev reads out (no error alongside the row)", ap_row ~= nil and ap_err == nil, ap_err)
-- A colliding code (only possible with a key ground to match) is never approved.
for i, who in ipairs({ "user:twin1@corp.io", "user:twin2@corp.io" }) do
    assert(db.run("INSERT INTO lm_org_devs (org_scope, identity, public_key, fingerprint, pairing_code, status, "
        .. "requested_at) VALUES ('org:fedsrv', ?, ?, ?, 'ZZZZ-9999', 'pending', ?)",
        who, ("%02x"):format(i):rep(32), "TWIN" .. i, require("luamemo.util").now_us()))
end
local amb, amb_err = devs.approve("ZZZZ-9999", "admin")
check("a code matching two pending requests is refused, naming both", amb == nil
    and tostring(amb_err):find("twin1", 1, true) and tostring(amb_err):find("twin2", 1, true), amb_err)
devs.remove("ZZZZ-9999")
check("pairing an approved key again → approved", select(2, pair(alice, "user:alice@corp.io")).status == "approved")
-- A device re-sends its request (pair --wait does) while the admin approves it:
-- the approval committed between the request's read and its write must stick.
local racer = ident()
pair(racer, "user:racer@corp.io")
local stale = devs.find_by_key(racer.pk)
devs.approve(keys.pairing_code(CPK, racer.pk), "admin")
local real_find = devs.find_by_key
devs.find_by_key = function() devs.find_by_key = real_find; return stale end
local rstat = devs.request("user:racer@corp.io", racer.pk, CPK)
check("an approval racing with the device's re-sent request is kept (not reset to pending)",
    rstat == "approved" and devs.find_by_key(racer.pk).status == "approved", rstat)
devs.remove("user:racer@corp.io")
check("an approved key can't be re-claimed under another identity",
    (pair(alice, "user:mallory@corp.io")) == 409)
local wrong_c = channel.pair_request(ident().pk, alice2.pk, "user:alice@corp.io", alice2.sign)
check("pair for a different central → 409", (call("POST", "/federation/pair", wrong_c)) == 409)
check("pair: wrong content type → 415", (call("POST", "/federation/pair",
    json.encode(channel.pair_request(CPK, alice2.pk, "user:a@b.c", alice2.sign)), "text/plain")) == 415)
check("pair: invalid JSON → 400", (call("POST", "/federation/pair", "{nope", "application/json")) == 400)
-- Pairing limits are PER ADDRESS (IPv6: per /64): one machine can't block the others.
local A, B = "192.168.1.66", "192.168.1.10"
local cap0 = devs.MAX_PENDING_PER_ADDR
devs.MAX_PENDING_PER_ADDR = 1
pair(ident(), "user:dave@corp.io", A)     -- A's one pending request …
local vcalls, sc = count_verifies(function() return (pair(ident(), "user:carol@corp.io", A)) end)
local sb = pair(ident(), "user:erin@corp.io", B)
devs.MAX_PENDING_PER_ADDR = cap0
check("pending requests are capped per address → 429 …", sc == 429, sc)
check("… refused before any signature verification", vcalls == 0, vcalls)
check("… while another address can still ask to pair", sb == 200, sb)
handlers._reset_throttle()
local p0 = handlers.PAIR_PER_MINUTE
handlers.PAIR_PER_MINUTE = 2
local codes = {}
for i = 1, 3 do codes[i] = pair(ident(), "user:flood" .. i .. "@corp.io", A) end
local other = pair(ident(), "user:frank@corp.io", B)
handlers.PAIR_PER_MINUTE = p0
handlers._reset_throttle()
check("/pair is rate-bounded per address → 429, other addresses unaffected", codes[3] == 429 and other == 200,
    table.concat(codes, ",") .. " / " .. tostring(other))
check("IPv6 addresses are limited per /64 (a host can pick any address in its own /64)",
    common.peer_group("fd00:1:2:3::5") == common.peer_group("fd00:1:2:3:aaaa::9")
        and common.peer_group("fd00:1:2:3::5") ~= common.peer_group("fd00:1:2:4::5")
        and common.peer_group("::ffff:192.168.1.66") == A and common.peer_group(A) == A)
-- Claiming someone's identity from elsewhere can't delete their pending request;
-- a newer key for the same identity from the SAME address replaces the old one
-- (even when that address is at its cap — the old request doesn't count).
devs.clear_pending()
devs.MAX_PENDING_PER_ADDR = 1
local vic, imp, vic2 = ident(), ident(), ident()
pair(vic, "user:victim@corp.io", B)
pair(imp, "user:victim@corp.io", A)
check("a request claiming the same identity from another address leaves the original pending",
    devs.find_by_key(vic.pk) and devs.find_by_key(vic.pk).status == "pending" and devs.find_by_key(imp.pk) ~= nil)
pair(vic2, "user:victim@corp.io", B)
devs.MAX_PENDING_PER_ADDR = cap0
check("… a newer key for that identity from the same address replaces its own older request",
    devs.find_by_key(vic.pk) == nil and devs.find_by_key(vic2.pk) ~= nil)
-- Storage bound: when full, the OLDEST pending request makes room (never a refusal).
local max0 = devs.MAX_PENDING
devs.MAX_PENDING = devs.pending_count()
local oldest = devs.list("pending"); oldest = oldest[#oldest]
local newest = ident()
local sn = pair(newest, "user:gina@corp.io", "10.9.9.9")
devs.MAX_PENDING = max0
check("pending queue full → the oldest pending request makes room for the new one", sn == 200
    and devs.find_by_key(newest.pk) ~= nil and devs.find_by_key(channel.unhex(oldest.public_key)) == nil, sn)
local nclear = devs.clear_pending()
check("clear_pending drops every pending request, keeps approved devices", nclear >= 2 and #devs.list("pending") == 0
    and devs.find_by_key(alice.pk).status == "approved", nclear)

io.write("\n--- D2: handshake + encrypted RPC ---\n")
local _, hs = connect(mallory)
check("pending device can't handshake → 403", hs == 403)
local sess, herr = connect(alice)
check("approved device handshakes", sess ~= nil, herr)
-- A captured hello can't open a second session.
local rh = channel.client_hello(CPK, alice.pk, alice.sign, dev_hkey(alice, CPK))
local r1s = call("POST", "/federation/hello", rh)
local r2s, r2b = call("POST", "/federation/hello", rh)
check("a replayed hello is refused (409, before any signature work)", r1s == 200 and r2s == 409
    and r2b.code == "replay", r2s)
-- A device's public key is not secret. Knowing it lets nobody make the central
-- verify signatures, nor lock the device out: without the device's hello key a
-- hello fails its MAC — one HMAC — however many are sent.
local fcodes, fwhy = {}, {}
local rv_calls = count_verifies(function()
    for i = 1, 25 do
        local s, b = call("POST", "/federation/hello", (channel.client_hello(CPK, alice.pk, mallory.sign,
            dev_hkey(mallory, CPK))))
        fcodes[i], fwhy[i] = s, b and b.code
    end
end)
local all401 = true
for i = 1, #fcodes do if fcodes[i] ~= 401 or fwhy[i] ~= "mac" then all401 = false end end
check("25 forged hellos for an approved key → all 401 'mac', no signature verified", all401 and rv_calls == 0,
    table.concat(fcodes, ",") .. " verifies=" .. rv_calls)
local after = connect(alice)
check("… and the real device still connects right after (nothing to lock it out)", after ~= nil)
local info, st1, rn = rpc(sess, "info")
check("rpc info (encrypted both ways, response bound to the request)",
    info and info.ok and info.result.org_scope == "org:fedsrv" and rn == 1, st1)
db.run("UPDATE lm_org_devs SET last_seen_at = NULL WHERE identity = 'user:alice@corp.io'")
-- (count every database entry point: the session lookup + one transaction)
local DB_FNS, real_fns, nq = { "query", "first", "value", "run", "scan", "transaction" }, {}, 0
for _, f in ipairs(DB_FNS) do
    real_fns[f] = db[f]
    db[f] = function(...) nq = nq + 1; return real_fns[f](...) end
end
local info2 = rpc(sess, "info")
for _, f in ipairs(DB_FNS) do db[f] = real_fns[f] end
local seen_row = db.first("SELECT last_seen_at FROM lm_org_devs WHERE identity = 'user:alice@corp.io' "
    .. "AND status = 'approved'")
check("an RPC stamps the device's last_seen in the counter update (lookup + one transaction per call)",
    info2 and info2.ok and seen_row and seen_row.last_seen_at ~= nil and nq == 2, nq)
local snap = rpc(sess, "snapshot", { limit = 500, vectors = true })
check("rpc snapshot", snap and snap.ok and #snap.result.rows == 3 and snap.result.rows[1].vector ~= nil)
local fb = rpc(sess, "feedback", { share = "triples",
    events = { { ref = "alice:e1", memory = R2.id, type = "praise" } } })
check("rpc feedback accepted", fb and fb.ok and fb.result.accepted_events == 1)
local src = db.query("SELECT source FROM lm_reinforcements WHERE source_ref = 'alice:e1'")
check("feedback attributed to the paired key's identity (payload can't claim one)",
    src and src[1] and src[1].source == "user:alice@corp.io")
local forged = rpc(sess, "feedback", { identity = "user:ceo@corp.io", events = {
    { ref = "alice:e2", memory = R2.id, type = "praise" } } })
local src2 = db.query("SELECT source FROM lm_reinforcements WHERE source_ref = 'alice:e2'")
check("a claimed identity in the payload is ignored", forged and forged.ok and src2[1].source == "user:alice@corp.io")
local unknown = rpc(sess, "drop_tables")
check("unknown method → encrypted 404", unknown and unknown.ok == false and unknown.status == 404)
local _, rs = rpc(sess, "info", nil, 2)                 -- n = 2 was used already
check("replayed message → 409", rs == 409, rs)
local env = channel.seal(sess.keys, sess.id, "c2s", 99, '{"method":"info"}')
local tampered = env:sub(1, #env - 1) .. string.char((env:byte(#env) + 1) % 256)
local ts, tb = call("POST", "/federation/call", tampered, "application/octet-stream")
check("tampered envelope → 401 (session code)", ts == 401 and tb.code == "session")
local ok_after = rpc(sess, "info", nil, 99)
check("… and the forged envelope did not advance the counter", ok_after and ok_after.ok)
local us, ub = call("POST", "/federation/call", channel.seal(sess.keys, sodium.random_bytes(16), "c2s", 1, "{}"),
    "application/octet-stream")
check("unknown session → 401 (client re-handshakes)", us == 401 and ub.code == "session")
check("garbage body → 400", (call("POST", "/federation/call", "garbage", "application/octet-stream")) == 400)
check("revoke by identity", devs.remove("user:alice@corp.io", "admin") >= 1)
local _, rv = rpc(sess, "info")
check("revoked device: its live session stops working", rv == 401)
check("revoked device can't handshake → 403", select(2, connect(alice)) == 403)

local real_info = central.info
local bob = ident()
pair(bob, "user:bob@corp.io"); devs.approve(keys.pairing_code(CPK, bob.pk))
local bs = connect(bob)
central.info = function() error("boom — internal detail") end
local crash = rpc(bs, "info")
central.info = real_info
check("rpc crash → generic encrypted 500 (no internals leaked)",
    crash and crash.ok == false and crash.status == 500 and crash.error == "internal error")
end)

-- ---------------------------------------------------------------------------
section("E memo serve", function()
io.write("\n--- E: memo serve ---\n")
local lua_bin = H.lua_bin()
local db_path = assert(db.path())
local env = ("MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_ROLE=org MEMO_ORG_NAME=fedsrv MEMO_FEDERATION_DIR=%q MEMO_LUA=%q")
    :format(db_path, KDIR, lua_bin)
local out = io.popen(env .. " ./cli/memo serve --host 8.8.8.8 --port 0 2>&1; echo EXIT=$?"):read("*a")
check("public bind address refused", out:find("local-network only", 1, true) ~= nil
    and out:find("EXIT=2", 1, true) ~= nil, out)
local out2 = io.popen(("MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q ./cli/memo serve --port 0 2>&1; echo EXIT=$?")
    :format(db_path, lua_bin)):read("*a")
check("refuses without MEMO_ROLE=org", out2:find("not an org central", 1, true) and out2:find("EXIT=2", 1, true), out2)

local log = os.tmpname()
local N = 7
os.execute(("%s ./cli/memo serve --port 0 --max-requests %d 2>%q &"):format(env, N, log))
local port = H.wait_port(log)
check("memo serve starts (loopback) and announces the central fingerprint", port ~= nil)
if not port then return end
local http = require("luamemo.http")
local st, bd = http.request("http://127.0.0.1:" .. port .. "/federation/key", { method = "GET", timeout_ms = 5000 })
local kj = st == 200 and json.decode(bd)
check("HTTP GET /key", kj and kj.central_pk == channel.hex(CPK), st)
check("HTTP: bearer tokens are gone (/info is not an endpoint)",
    (http.request("http://127.0.0.1:" .. port .. "/federation/info", { method = "GET", timeout_ms = 5000 })) == 404)
local socket = require("socket")
local function raw(payload)
    local c = socket.tcp(); c:settimeout(5)
    assert(c:connect("127.0.0.1", port))
    c:send(payload)
    local line = c:receive("*l") or ""
    c:close()
    return tonumber(line:match("^HTTP/1%.1 (%d+)"))
end
check("raw: malformed request line → 400", raw("GARBAGE\r\n\r\n") == 400)
check("raw: POST without Content-Length → 411", raw("POST /federation/pair HTTP/1.1\r\nHost: x\r\n\r\n") == 411)
check("raw: chunked body → 501",
    raw("POST /federation/call HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n") == 501)
check("raw: oversized head → 431", raw("GET /federation/key HTTP/1.1\r\nX-Big: " .. string.rep("a", 20000) .. "\r\n\r\n") == 431)
check("raw: hex Content-Length → 400", raw("POST /federation/call HTTP/1.1\r\nContent-Length: 0x2\r\n\r\n{}") == 400)
os.execute("sleep 0.3")
local s = H.slurp(log) or ""
check("serve printed the (public) central fingerprint", s:find(keys.fingerprint(CPK), 1, true) ~= nil)
local lines = 0
for _ in s:gmatch("\n%d%d%d%d%-%d%d%-%d%dT") do lines = lines + 1 end
check("one log line per request, stopped after --max-requests", lines == N, lines)
check("log records method + path only", s:find("GET /federation/key 200", 1, true) ~= nil)
os.remove(log)

-- Concurrency (a server with small limits: 2 connections per address, 100 bytes of bodies in flight).
local clog, cscript = os.tmpname(), os.tmpname()
local cf = assert(io.open(cscript, "w"))
cf:write([[package.path = "./?.lua;./?/init.lua;" .. package.path
local s = require("luamemo.federation.server")
s.MAX_PER_PEER, s.MAX_BUFFERED, s.DEADLINE_S = 2, 100, 5
s.run({ port = 0, max_requests = 5 })
]])
cf:close()
os.execute(("%s %s %q 2>%q &"):format(env, lua_bin, cscript, clog))
local cport = H.wait_port(clog)
check("event-loop server starts", cport ~= nil)
if not cport then return end
local function conn(partial)
    local c = socket.tcp(); c:settimeout(5); assert(c:connect("127.0.0.1", cport))
    if partial then c:send(partial) end
    return c
end
local function timed_get()
    local t0 = socket.gettime()
    local c = conn("GET /federation/key HTTP/1.1\r\nHost: x\r\n\r\n")
    local line = c:receive("*l") or ""
    c:close()
    return tonumber(line:match("^HTTP/1%.1 (%d+)")), socket.gettime() - t0
end
local slow1 = conn("GET /federation/key HTTP/1.1\r\n")      -- sends half a request, then nothing
socket.sleep(0.2)
local s1, t1 = timed_get()
-- (this bare server isn't set up as an org: any answer — 404 — shows it was served)
check("a slow client doesn't hold the server: the next request is answered at once", s1 ~= nil and t1 < 1.5,
    ("%s in %.2fs"):format(tostring(s1), t1))
-- The waits leave the server's loop time to see each event in order even on a busy machine
-- (0.2 s failed once in a full-suite run: the trickle wasn't read before the third connect).
local slow2 = conn("GET /federation/key HTTP/1.1\r\n")      -- newer, and silent from now on
socket.sleep(0.6)
slow1:send("X-Trickle: 1\r\n")                               -- the older one keeps sending
socket.sleep(0.6)
local s2, t2 = timed_get()                                   -- 2 open + this one > 2 per address
slow2:settimeout(2)
local l2, e2 = slow2:receive("*l")
slow1:settimeout(0.3)
local _, e1 = slow1:receive("*l")
check("address full: the connection silent longest makes room (not the oldest), the request is served",
    s2 ~= nil and t2 < 1.5 and l2 == nil and e2 == "closed" and e1 == "timeout",
    ("%s in %.2fs; silent: %s %s; trickling: %s"):format(tostring(s2), t2, tostring(l2), tostring(e2), tostring(e1)))
slow1:close()
local bc = conn("POST /federation/call HTTP/1.1\r\nContent-Type: application/octet-stream\r\nContent-Length: 200\r\n\r\n")
local bl = bc:receive("*l") or ""
bc:close()
check("request bodies share a memory budget: over it → 503 before reading the body", bl:find("503", 1, true) ~= nil, bl)
os.execute("sleep 1")
check("the eviction is logged", (H.slurp(clog) or ""):find("EVICT idle", 1, true) ~= nil)
os.remove(clog); os.remove(cscript)
end)

wipe()
os.execute(("rm -rf %q"):format(KDIR))
keys.set_dir(nil)
finish()
