-- eval/tests/test_federation_client.lua
-- Phase 12.3 + 12F.3 — dev client (luamemo.federation.client) against a real
-- central over the encrypted, key-paired local-network channel.
--
--   Setup: a throwaway central database (a second SQLite file, removed at
--   the end), seeded through a subprocess running as the org (directive
--   capability for the core tier) and served by luamemo.cli.serve on an
--   ephemeral loopback port, with its own keyring. THIS process is the dev:
--   MEMO_DB is its database, its keyring is a temp dir, the replica lives
--   in org:fedcli, personal rows in repo:fedcli.
--
--   A. guards without a central (role gate)
--   P. pairing: wrong pinned fingerprint refused, unpaired / pending refused,
--      pair → code → admin approves by code → access
--   B. pull: first sync, incremental no-op, central edits / adds / deletes,
--      tier-0 exclusion, vector reuse, read-only replica, manifest repair of
--      a late (back-dated) commit
--   C. resumable full resync (budget stop mid-way), embedder-signature change
--   D. learned weights: install, no-op, withdraw
--   E. push: events + triples mapped to central ids, idempotent replay,
--      signals mode never ships query history (not even after switching back)
--   F. offline / public address / revoked device: failures recorded, replica +
--      cursors untouched, re-pairing restores access
--   G. TTL triggers: maybe_sync claim + throttle, org search refresh, the
--      session brief line
--   H. `memo org` CLI
--
-- Run: luajit eval/tests/run.lua --only federation_client

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Federation client")
local check, section, finish = T.check, T.section, T.finish
local sh = H.sh

local lua_bin = H.lua_bin()

local luamemo = require("luamemo")
local db      = require("luamemo.db")
local json    = require("luamemo.json")
local store   = require("luamemo.store")
local util    = require("luamemo.util")
local vectors = require("luamemo.vectors")
local policy  = require("luamemo.federation.policy")
local client  = require("luamemo.federation.client")
local ls      = require("luamemo.learner_store")

local ORG, MINE = "org:fedcli", "repo:fedcli"
math.randomseed(os.time() + math.floor(os.clock() * 1e6))
local SUFFIX  = ("%d_%04d"):format(os.time(), math.random(0, 9999))
local CDB     = "lm_fedcli_" .. SUFFIX
local CKDIR   = os.tmpname(); os.remove(CKDIR)      -- the central's keyring
local DKDIR   = os.tmpname(); os.remove(DKDIR)      -- this dev's keyring
local keys    = require("luamemo.federation.keys")
keys.set_dir(DKDIR)
local FP                                            -- the central's fingerprint (what the admin hands out)
local central_db = H.db_path(CDB)

local function q1(sql) return db.first(sql) or {} end
local function state()
    local r = q1("SELECT * FROM lm_federation_state WHERE org_scope = '" .. ORG .. "'")
    if r.last_pull_ok ~= nil then r.last_pull_ok = (r.last_pull_ok == 1) end
    return r
end
local function replica_count() return tonumber(q1("SELECT count(*) AS n FROM lm_memories WHERE scope = '" .. ORG .. "'").n) end
local function stale()
    db.run("UPDATE lm_federation_state SET last_pull_at = ? WHERE org_scope = ?", util.now_us() - 7200 * 1000000, ORG)
end

-- Run Lua on the CENTRAL (a subprocess set up as the org). `result(v)` returns v.
local PRELUDE = [[
package.path = "./?.lua;./?/init.lua;" .. package.path
local luamemo = require("luamemo")
luamemo.setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true,
                patterns_enabled = false, role = "org", org_name = "fedcli" })
local store, db, json = luamemo.store, require("luamemo.db"), require("luamemo.json")
local DIR = require("luamemo.federation.policy").capability("directive")
local ls  = require("luamemo.learner_store")
local devs = require("luamemo.federation.devs")
local function result(v) io.write("\n@@RESULT@@" .. json.encode(v or {}) .. "\n") end
]]
local function central(code)
    local path = os.tmpname()
    local f = assert(io.open(path, "w")); f:write(PRELUDE, "\n", code, "\n"); f:close()
    local out = sh(("MEMO_DB=%q MEMO_FEDERATION_DIR=%q %s %q"):format(central_db, CKDIR, lua_bin, path))
    os.remove(path)
    local body = out:match("@@RESULT@@([^\n]*)")
    if not body then error("central helper failed: " .. out:sub(1, 600), 0) end
    return json.decode(body)
end

-- The dev configuration (this process).
local PORT
local function dev(extra)
    local cfg = { embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false,
                  org_url = PORT and ("http://127.0.0.1:" .. PORT) or nil, org_fingerprint = FP,
                  org_identity = "user:dev@corp.io", org_share = "triples", org_sync_ttl = 900 }
    for k, v in pairs(extra or {}) do cfg[k] = v end
    if type(luamemo.config) == "table" then luamemo.config.embedder_model = nil end   -- setup merges
    luamemo.setup(cfg)
    client._reset_session()
end
local function approve(code)
    return central(("result({ ok = devs.approve(%q, 'test') ~= nil })"):format(code)).ok
end
local function wipe_dev()
    db.run("DELETE FROM lm_reinforcements WHERE scope IN (?, ?)", ORG, MINE)
    db.run("DELETE FROM lm_retrieval_feedback WHERE scope IN (?, ?)", ORG, MINE)
    db.run("DELETE FROM lm_learner_weights WHERE scope = ?", ORG)
    db.run("DELETE FROM lm_memories WHERE scope IN (?, ?)", ORG, MINE)
    db.run("DELETE FROM lm_federation_state WHERE org_scope = ?", ORG)
end

-- ---------------------------------------------------------------------------
section("A guards", function()
io.write("\n--- A: guards ---\n")
luamemo.setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false })
check("solo: pull refused", (client.pull()) == nil)
check("solo: push refused", (client.push()) == nil)
check("solo: maybe_sync is a no-op", client.maybe_sync() == false)
-- The central's name is resolved (and checked local) once per RESOLVE_TTL, not per call.
luamemo.setup({ org_url = "http://localhost:1", org_fingerprint = "0000-0000-0000-0000-0000" })
local ngm = require("luamemo.netguard")
local real_res, nres = ngm.resolve, 0
ngm.resolve = function(h) nres = nres + 1; return real_res(h) end
for _ = 1, 3 do client.probe_central(300) end
ngm.resolve = real_res
check("one DNS resolution serves consecutive calls", nres == 1, nres)
end)

-- ---------------------------------------------------------------------------
-- Central: create, migrate, seed, serve.
local seed, SERVER_PID, LOG
local up = false
section("setup central", function()
dev()
wipe_dev()
H.create_db(CDB)
seed = central([[
local D  = store.write({ scope = "org:fedcli", title = "Directive: tests", importance = 1.0,
                         body = "Every change ships with tests.", _cap = DIR })   -- a directive: tier 3
local N1 = store.write({ scope = "org:fedcli", title = "small PRs", body = "prefer small pull requests", importance = 0.5 })
local N2 = store.write({ scope = "org:fedcli", title = "api docs", body = "document public APIs", importance = 0.7 })
local E  = store.write({ scope = "org:fedcli", title = "ephemeral", body = "raw session event", importance = 0.1 })
local t = db.query("SELECT tier FROM lm_memories WHERE id = " .. D.id)[1].tier
result({ D = D.id, N1 = N1.id, N2 = N2.id, E = E.id, tierD = t })
]])
check("central seeded (directive at the core tier)", seed.D and tonumber(seed.tierD) == 3, seed.tierD)
FP = central([[
local k = require("luamemo.federation.keys")
result({ fp = k.fingerprint(assert(k.ensure_identity("central"))) })
]]).fp
check("central identity created (the admin hands out its fingerprint)", type(FP) == "string" and #FP == 24, FP)

LOG = os.tmpname()
local code_s = "package.path='./?/init.lua;'..package.path; require('luamemo.cli.serve').run({'--port','0'})"
local out = sh(("MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_ROLE=org MEMO_ORG_NAME=fedcli MEMO_FEDERATION_DIR=%q "
    .. "timeout 900 %s -e %q >/dev/null 2>%q & echo \"PID=$!\""):format(central_db, CKDIR, lua_bin, code_s, LOG))
SERVER_PID = tonumber(out:match("PID=(%d+)"))
PORT = H.wait_port(LOG)
check("central serving (memo serve)", PORT ~= nil)
up = PORT ~= nil
end)

if up then
local idx   -- central id → { id = local id, us = version }
local function local_of(oid) idx = store.replica_index(ORG); return idx[oid] and idx[oid].id end
local function body_of(oid) return q1("SELECT body FROM lm_memories WHERE id = " .. (local_of(oid) or 0)).body end
-- A row's stored vector as text ("[1,0,0,…]"), "nil" when it has none.
local function vec_of(oid)
    local blob = db.value("SELECT embedding FROM lm_memories WHERE id = ?", local_of(oid) or 0)
    if not blob then return "nil" end
    local parts = {}
    for i, x in ipairs(vectors.unpack(blob)) do parts[i] = ("%.6g"):format(x) end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- ---------------------------------------------------------------------------
section("P pairing", function()
io.write("\n--- P: pairing ---\n")
dev()
check("dev role implied by org_url", policy.role() == "dev")
local s0, e0 = client.pull()
check("unpaired device: pull refused with the next step", s0 == nil and tostring(e0):find("memo org pair", 1, true), e0)
dev({ org_fingerprint = "ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ" })
local p0, pe0 = client.pair()
check("wrong pinned fingerprint → refuses to talk to the central", p0 == nil
    and tostring(pe0):find("does not match the pinned fingerprint", 1, true), pe0)
dev({ org_fingerprint = false })
check("no pinned fingerprint → refused with guidance", select(2, client.pair()):find("MEMO_ORG_FINGERPRINT", 1, true) ~= nil)
dev()
local pr, perr = client.pair()
check("pair → pending + a code", pr and pr.status == "pending" and pr.code:match("^%w%w%w%w%-%w%w%w%w$"), perr)
check("the device key lives in this user's keyring", keys.public_key("dev") ~= nil
    and pr and pr.device_fingerprint == keys.fingerprint(keys.public_key("dev")))
local s1, e1 = client.pull()
check("pending device: pull refused (admin hasn't approved)", s1 == nil and tostring(e1):find("pending", 1, true), e1)
check("admin approval with a wrong code fails", approve("0000-0000") == false)
check("admin approves the code the dev reads out", pr and approve(pr.code) == true)
local p2 = client.pair()
check("pairing again → approved", p2 and p2.status == "approved")
end)

-- ---------------------------------------------------------------------------
section("B pull", function()
io.write("\n--- B: pull ---\n")
dev()
check("push before the first pull asks to pull first", select(2, client.push()) ~= nil)
local s1, e1 = client.pull()
check("first pull succeeds", s1 ~= nil, e1)
s1 = s1 or {}
check("first pull learns the org scope from the central", s1.org_scope == ORG, s1.org_scope)
check("first pull: 3 rows (tier-0 excluded)", s1.upserted == 3, s1.upserted)
check("first pull is a full sync", s1.full == true)
check("same embedder → the central's vectors are reused", s1.vectors_reused == true)
idx = store.replica_index(ORG)
check("replica index maps central ids → local rows",
    idx[seed.D] and idx[seed.N1] and idx[seed.N2] and not idx[seed.E])
local rD = q1("SELECT tier, title FROM lm_memories WHERE id = " .. (local_of(seed.D) or 0))
check("directive replicated at the core tier", tonumber(rD.tier) == 3 and rD.title == "Directive: tests", rD.tier)
check("state: last pull ok", state().last_pull_ok == true)

local okw, w, werr = pcall(store.write, { scope = ORG, title = "local", body = "local edit" })
check("replica is read-only: local write refused", not okw or w == nil, werr)
local oku, u = pcall(store.update, local_of(seed.N1), { body = "local edit" })
check("replica is read-only: local update refused", not oku or u == nil)
check("replica body unchanged", body_of(seed.N1) == "prefer small pull requests")
local re, rerr = store.reembed_scope(ORG)
check("reembed of the replica refused (it re-embeds on sync)",
    re == nil and tostring(rerr):find("memo org pull --full", 1, true) ~= nil, rerr)

local s2 = client.pull() or {}
check("no central change → nothing applied",
    s2.upserted == 0 and s2.repaired == 0 and s2.deleted == 0 and s2.unchanged == 0, json.encode(s2))
check("second pull is incremental", s2.full == false)
check("… and, the replica digest matching, no manifest was shipped (idle sync = O(1))", s2.manifest_same == true)
local dg = central([[
local common, c = require("luamemo.federation.common"), require("luamemo.federation.central")
local real, n = common.manifest_digest, 0
common.manifest_digest = function(e) n = n + 1; return real(e) end
local p1 = c.snapshot({ limit = 1000 })
local plain = n
local p2 = c.snapshot({ limit = 1000, manifest_digest = "0000" })
result({ plain = plain, asked = n - plain, m1 = p1.manifest ~= nil, m2 = p2.manifest ~= nil })
]])
check("central hashes the manifest only when the dev sent a digest",
    dg.plain == 0 and dg.asked == 1 and dg.m1 and dg.m2, json.encode(dg))
-- One query per applied row: the pull reads the replica index once instead of
-- looking each row up (a full resync re-applies every row). Counted on the
-- database handle itself, so statements inside a transaction count too.
local h, lookups = assert(db.get()), 0
local real_first, real_query = h.first, h.query
local function counting(real)
    return function(sql, ...)
        if type(sql) == "string" and sql:find("'$.lm_org_id') = ", 1, true) then lookups = lookups + 1 end
        return real(sql, ...)
    end
end
h.first, h.query = counting(real_first), counting(real_query)
local sf = client.pull({ full = true }) or {}
h.first, h.query = real_first, real_query
check("a pull does no per-row replica lookups", sf.upserted == 3 and lookups == 0,
    ("upserted=%s lookups=%d"):format(tostring(sf.upserted), lookups))

-- Central edits: update N1, add N3, delete N2, stamp a marker vector on D.
local c = central(([[
assert(store.update(%d, { body = "prefer small, focused pull requests" }))
local N3 = store.write({ scope = "org:fedcli", title = "naming", body = "use descriptive names", importance = 0.6 })
assert(store.delete(%d))
local v = { 1 }; for i = 2, 384 do v[i] = 0 end
local blob, norm = require("luamemo.vectors").pack(v)
assert(db.run("UPDATE lm_memories SET embedding = ?, emb_norm = ? WHERE id = %d", db.blob(blob), norm))
result({ N3 = N3.id })
]]):format(seed.N1, seed.N2, seed.D))
seed.N3 = c.N3
local s3 = client.pull() or {}
check("central edit + add + vector change → 3 upserted", s3.upserted == 3, json.encode(s3))
check("central delete → removed locally", s3.deleted == 1 and not local_of(seed.N2), s3.deleted)
check("edited body replicated", body_of(seed.N1) == "prefer small, focused pull requests", body_of(seed.N1))
check("new central row replicated", local_of(seed.N3) ~= nil)
check("central vector reused verbatim", vec_of(seed.D):sub(1, 7) == "[1,0,0,", vec_of(seed.D):sub(1, 20))

-- A late commit: a row changes with a timestamp behind the dev's cursor.
central(([[
assert(db.run("UPDATE lm_memories SET body = 'late body', updated_at = updated_at - 3600000000 WHERE id = %d"))
result({})
]]):format(seed.N3))
local s4 = client.pull() or {}
check("late commit: incremental page misses it, manifest repairs it",
    s4.upserted == 0 and s4.repaired == 1, json.encode(s4))
check("late commit body replicated", body_of(seed.N3) == "late body", body_of(seed.N3))
local s5 = client.pull() or {}
check("after repair the replica has converged", s5.repaired == 0 and s5.upserted == 0, json.encode(s5))
end)

-- ---------------------------------------------------------------------------
section("C resync", function()
io.write("\n--- C: resumable resync + embedder change ---\n")
dev()
-- Runs a full pull whose time budget runs out right after the first row applied.
local function pull_budget_stop()
    local mod = require("luamemo.store")
    local real_upsert, real_time = mod.replica_upsert, os.time
    local fake
    mod.replica_upsert = function(...)
        local a, b = real_upsert(...)
        fake = real_time() + 3600
        return a, b
    end
    os.time = function(t) if t == nil and fake then return fake end return real_time(t) end
    local ok, res = pcall(client.pull, { full = true, budget_s = 30 })
    mod.replica_upsert, os.time = real_upsert, real_time
    return ok, res
end
client.PAGE = 1
local okp, p1 = pull_budget_stop()
check("budget stop: pull returns partial stats", okp and p1 and p1.partial == true, tostring(p1))
p1 = (okp and p1) or {}
check("budget stop after exactly one page", p1.pages == 1 and p1.upserted == 1, json.encode(p1))
local st = state()
check("interrupted resync is remembered (resync marker + cursor)",
    tostring(st.embedder_sig):match("^resync:") and (st.snapshot_cursor or "") ~= "", st.embedder_sig)
check("partial pull recorded as the last error", tostring(st.last_error):find("partial", 1, true) ~= nil)
local p2 = client.pull() or {}
client.PAGE = 200
check("next pull resumes the resync (not a restart)",
    p2.full == true and p2.pages == 2 and p2.upserted == 2, json.encode(p2))
check("resync completed: marker cleared", not tostring(state().embedder_sig):match("^resync:"))
local p3 = client.pull() or {}
check("then back to incremental", p3.full == false and p3.upserted == 0, json.encode(p3))

-- The same stop inside one page (e.g. slow local re-embedding): the applied
-- prefix commits with its own cursor instead of overrunning the budget.
local okm, m1 = pull_budget_stop()
m1 = (okm and m1) or {}
check("mid-page budget stop: applied prefix committed, rest deferred",
    m1.partial == true and m1.pages == 1 and m1.upserted == 1, json.encode(m1))
local mst = state()
local m2 = client.pull() or {}
check("resume continues after the last applied row",
    m2.full == true and m2.upserted == 2 and not m2.partial,
    json.encode(m2) .. " state=" .. tostring(mst.snapshot_cursor) .. " " .. tostring(mst.embedder_sig))

dev({ embedder_model = "variant-b" })
local g1 = client.pull() or {}
check("embedder change → full resync", g1.full == true and g1.upserted == 3, json.encode(g1))
check("embedder change → vectors re-embedded locally, not reused", g1.vectors_reused == false
    and vec_of(seed.D):sub(1, 7) ~= "[1,0,0," and vec_of(seed.D) ~= "nil", vec_of(seed.D):sub(1, 20))
local g2 = client.pull() or {}
check("same (changed) embedder next time → incremental", g2.full == false and g2.upserted == 0, json.encode(g2))
dev()
local g3 = client.pull() or {}
check("embedder switched back → full resync reusing the central's vectors",
    g3.full == true and g3.vectors_reused == true and vec_of(seed.D):sub(1, 7) == "[1,0,0,", json.encode(g3))

-- An embedder of another SIZE: the replica re-syncs at that size although the
-- database still holds the old one (its rows change only through sync — a
-- refusal would leave the change stuck for good); the database moves once the
-- dev's own memories are re-embedded too. Both ways.
local function db_dim() return tonumber(db.value("SELECT value FROM lm_meta WHERE key = 'embed_dim'")) end
local function vec_bytes(oid) return #(db.value("SELECT embedding FROM lm_memories WHERE id = ?", local_of(oid) or 0) or "") end
local own = assert(store.write({ scope = MINE, title = "own note", body = "a note of this dev" }))
dev({ embed_dim = 256 })
local z1 = client.pull() or {}
check("embedder of another size → the replica re-syncs at that size, the database waits for the rest",
    z1.full == true and z1.upserted == 3 and vec_bytes(seed.N1) == 256 * 4 and db_dim() == 384 and not z1.switched,
    json.encode(z1) .. " dim=" .. tostring(db_dim()))
local rz = store.reembed_scope(MINE) or {}
check("… and moves to it once the dev's own scope is re-embedded", rz.switched == true and db_dim() == 256,
    json.encode(rz))
dev()
local z2 = client.pull() or {}
local rz2 = store.reembed_scope(MINE) or {}
check("… and back the same way", z2.full == true and vec_bytes(seed.N1) == 384 * 4 and rz2.switched == true
    and db_dim() == 384, json.encode(z2) .. " " .. json.encode(rz2))
store.delete(own.id)
end)

-- ---------------------------------------------------------------------------
section("D weights", function()
io.write("\n--- D: learned weights ---\n")
dev()
local c = central([[
local v = ls.save_version("org:fedcli", "reranker", { w = { 0.1, 0.2 }, bias = 0.3 }, { note = "central" })
ls.promote("org:fedcli", "reranker", v)
result({ v = v })
]])
local w1 = client.pull() or {}
check("central's promoted model installed", w1.weights == 1, json.encode(w1))
check("installed as the org version", ls.current_note(ORG, "reranker") == ("org:v%d"):format(c.v),
    ls.current_note(ORG, "reranker"))
local cur = ls.load_current(ORG, "reranker") or {}
check("installed weights match the central's", cur.bias == 0.3)
local w2 = client.pull() or {}
check("unchanged model → not reinstalled", w2.weights == 0, w2.weights)
central([[ ls.deactivate("org:fedcli", "reranker"); result({}) ]])
local w3 = client.pull() or {}
check("central withdrew its model → deactivated locally",
    w3.weights == 1 and ls.current_note(ORG, "reranker") == nil, json.encode(w3))
end)

-- ---------------------------------------------------------------------------
local function central_feedback()
    return central([[
local ev = db.query("SELECT memory_id, event_type, note, source, source_ref FROM lm_reinforcements WHERE source IS NOT NULL ORDER BY id")
local rf = db.query("SELECT query, candidate_ids AS c, source, source_ref FROM lm_retrieval_feedback WHERE source IS NOT NULL ORDER BY id")
result({ ev = ev, rf = rf, nev = #ev, nrf = #rf })
]])
end

section("E push", function()
io.write("\n--- E: push ---\n")
dev()
local digest = require("luamemo.digest")
local P = store.write({ scope = MINE, title = "personal", body = "my own notes", importance = 0.5 })
local n1 = local_of(seed.N1)
local imp0 = tonumber(q1("SELECT importance FROM lm_memories WHERE id = " .. n1).importance)
digest.record_event(n1, ORG, "praise", 0.5, "helpful")
digest.record_event(P.id, MINE, "praise", 0.5)
check("feedback on a replica row never mutates it locally",
    tonumber(q1("SELECT importance FROM lm_memories WHERE id = " .. n1).importance) == imp0)
assert(db.run("INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids, created_at) VALUES "
    .. "(?, 'how small should PRs be', ?, ?), (?, 'personal only', ?, ?)",
    MINE, db.json({ n1, P.id }), util.now_us(), MINE, db.json({ P.id }), util.now_us()))
local r1, e1 = client.push()
check("push succeeds", r1 ~= nil, e1)
r1 = r1 or {}
check("push: 1 event + 1 retrieval (personal-only data stays local)",
    r1.events == 1 and r1.retrievals == 1 and r1.duplicates == 0 and r1.rejected == 0, json.encode(r1))
local cf = central_feedback()
local ev, rf = (cf.ev or {})[1] or {}, (cf.rf or {})[1] or {}
check("central event mapped to the central id", tonumber(ev.memory_id) == seed.N1 and ev.event_type == "praise",
    json.encode(ev))
check("central event attributed + idempotency ref",
    ev.source == "user:dev@corp.io" and tostring(ev.source_ref):match("^%x+:e:%d+$") ~= nil, ev.source_ref)
check("triples: event note shared", ev.note == "helpful", ev.note)
check("central triple: query kept, candidates mapped (personal ids dropped)",
    rf.query == "how small should PRs be" and rf.c == ("[%d]"):format(seed.N1), json.encode(rf))
check("personal-only retrieval never shipped", cf.nrf == 1, cf.nrf)

local r2 = client.push() or {}
check("nothing new → nothing sent", r2.events == 0 and r2.retrievals == 0 and r2.duplicates == 0, json.encode(r2))
db.run("UPDATE lm_federation_state SET last_push_reinforcement_id = 0, last_push_feedback_id = 0 WHERE org_scope = ?", ORG)
local r3 = client.push() or {}
check("replay after a lost cursor → all duplicates, nothing re-applied",
    r3.duplicates == 2 and r3.events == 0 and r3.retrievals == 0, json.encode(r3))
local cf2 = central_feedback()
check("central counts unchanged by the replay", cf2.nev == 1 and cf2.nrf == 1, json.encode({ cf2.nev, cf2.nrf }))

dev({ org_share = "signals" })
local n3 = local_of(seed.N3)
digest.record_event(n3, ORG, "mistake", -0.5, "outdated")
assert(db.run("INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids, created_at) VALUES "
    .. "(?, 'secret project name', ?, ?)", MINE, db.json({ n3 }), util.now_us()))
local r4 = client.push() or {}
check("signals: events pushed, retrieval triples not", r4.events == 1 and r4.retrievals == 0 and r4.share == "signals",
    json.encode(r4))
dev()
local r5 = client.push() or {}
check("switching back to triples never ships the old query", r5.retrievals == 0 and r5.events == 0, json.encode(r5))
local cf3 = central_feedback()
check("central never saw the signals-mode query", cf3.nrf == 1 and cf3.nev == 2, json.encode({ cf3.nev, cf3.nrf }))
local sev = (cf3.ev or {})[2] or {}
check("signals: event shipped without its free-text note", sev.event_type == "mistake" and sev.note == nil,
    json.encode(sev))
end)

-- ---------------------------------------------------------------------------
section("F offline", function()
io.write("\n--- F: offline / public address / revoked device ---\n")
local before = replica_count()
dev({ org_url = "http://127.0.0.1:1" })
local s, e = client.pull()
check("offline pull → nil + unreachable error", s == nil and tostring(e):find("unreachable", 1, true), e)
local st = state()
check("offline failure recorded", st.last_pull_ok == false and st.last_error ~= nil, st.last_error)
check("offline: replica untouched", replica_count() == before)
local digest = require("luamemo.digest")
digest.record_event(local_of(seed.D), ORG, "praise", 0.5)
local cur0 = tonumber(state().last_push_reinforcement_id)
local ps, pe = client.push()
check("offline push → nil + error", ps == nil and pe ~= nil, pe)
check("offline push: cursor not advanced", tonumber(state().last_push_reinforcement_id) == cur0)
dev({ org_url = "http://8.8.8.8:8765" })
local s2, e2 = client.pull()
check("public central address refused before any connection", s2 == nil
    and tostring(e2):find("local-network only", 1, true), e2)
dev({ org_url = "http://ops:pw-leak@127.0.0.1:" .. PORT })
local s2b, e2b = client.pull()
check("central URL with credentials refused (and not echoed)", s2b == nil
    and not tostring(e2b):find("pw-leak", 1, true), e2b)
-- Revoke this device on the central: access ends, re-pairing restores it.
central([[ result({ n = devs.remove("user:dev@corp.io", "test") }) ]])
dev()
local s2c, e2c = client.pull()
check("revoked device: refused", s2c == nil and tostring(e2c):find("403", 1, true), e2c)
local rp = client.pair()
check("re-pair after revocation → pending again", rp and rp.status == "pending")
check("… and the admin approves it again", rp and approve(rp.code) == true)
dev()
local s3 = client.sync()
check("back online: sync pulls and pushes the pending event",
    s3 and s3.pull and s3.push and s3.push.events == 1, json.encode(s3 or {}))
st = state()
check("back online: failure cleared", st.last_pull_ok == true and st.last_error == nil, st.last_error)
end)

-- ---------------------------------------------------------------------------
section("G triggers", function()
io.write("\n--- G: TTL triggers ---\n")
dev()
local c = central([[
local a = store.write({ scope = "org:fedcli", title = "ttl row", body = "arrives by TTL sync", importance = 0.5 })
result({ id = a.id })
]])
stale(); client._reset_throttle()
local r = client.maybe_sync()
check("stale replica → maybe_sync syncs", type(r) == "table" and local_of(c.id) ~= nil, tostring(r))
client._reset_throttle()
check("fresh replica → maybe_sync skips (atomic claim fails)", client.maybe_sync() == false)
stale()
check("throttled → skips without touching the DB",
    client.maybe_sync() == false and (util.now_us() - (tonumber(state().last_pull_at) or 0)) / 1e6 > 3600)
local function aged(secs, err)
    db.run("UPDATE lm_federation_state SET last_pull_at = ?, last_error = ? WHERE org_scope = ?",
        util.now_us() - secs * 1000000, err, ORG)
    client._reset_throttle()
end
aged(120, nil)
check("complete pull 2 min ago, TTL 15 min → not due", client.maybe_sync() == false)
aged(120, "partial pull: time budget exhausted (resumes next sync)")
check("partial pull 2 min ago → due again (large syncs converge in chunks)", type(client.maybe_sync()) == "table")

local c2 = central([[
local a = store.write({ scope = "org:fedcli", title = "search row", body = "arrives by org search", importance = 0.5 })
result({ id = a.id })
]])
stale(); client._reset_throttle()
store.search({ query = "anything", scope = MINE })
check("personal search never syncs", local_of(c2.id) == nil)
client._reset_throttle()
local real_push, pushes = client.push, 0
client.push = function(...) pushes = pushes + 1; return real_push(...) end
store.search({ query = "org search", scopes = { MINE, ORG } })
client.push = real_push
check("search touching the org scope refreshes the stale replica", local_of(c2.id) ~= nil)
check("… by pulling only (no push / proposals while the search waits)", pushes == 0, pushes)

local out = sh(("MEMO_EMBEDDER=hash MEMO_LUA=%q MEMO_ORG_URL=%q MEMO_ORG_FINGERPRINT=%q MEMO_FEDERATION_DIR=%q "
    .. "MEMO_ORG_IDENTITY=user:dev@corp.io ./cli/memo brief --scope %s")
    :format(lua_bin, "http://127.0.0.1:" .. PORT, FP, DKDIR, MINE))
check("session brief announces the org replica",
    out:find("org:    " .. ORG .. " — " .. replica_count() .. " org memories (read-only)", 1, true) ~= nil, out)
end)

-- ---------------------------------------------------------------------------
section("H cli", function()
io.write("\n--- H: memo org ---\n")
local env = ("MEMO_EMBEDDER=hash MEMO_LUA=%q MEMO_ORG_URL=%q MEMO_ORG_FINGERPRINT=%q MEMO_FEDERATION_DIR=%q "
    .. "MEMO_ORG_IDENTITY=user:dev@corp.io "):format(lua_bin, "http://127.0.0.1:" .. PORT, FP, DKDIR)
local o1, c1 = sh(env .. "./cli/memo org status")
check("org status", c1 == 0 and o1:find(ORG, 1, true) and o1:find("org memories (read-only)", 1, true), o1)
check("org status shows the pinned central key and this device's key (public fingerprints)",
    o1:find(FP, 1, true) and o1:find(keys.fingerprint(keys.public_key("dev")), 1, true), o1)
local o1p, c1p = sh(env .. "./cli/memo org pair")
check("org pair (already approved)", c1p == 0 and o1p:find("approved", 1, true), o1p)
local o1b = sh(("MEMO_EMBEDDER=hash MEMO_LUA=%q MEMO_ORG_URL=%q MEMO_ORG_FINGERPRINT=%q ./cli/memo org status")
    :format(lua_bin, "http://ops:s3cr3t-pw@127.0.0.1:" .. PORT, FP))
check("org status redacts credentials in the central URL",
    o1b:find("//ops:***@127.0.0.1", 1, true) and not o1b:find("s3cr3t-pw", 1, true), o1b)
local o2, c2 = sh(env .. "./cli/memo org pull")
check("org pull", c2 == 0 and o2:find("pulled:", 1, true), o2)
local o3, c3 = sh(env .. "./cli/memo org pull --full")
check("org pull --full", c3 == 0 and o3:find("full resync", 1, true), o3)
local o4, c4 = sh(env .. "./cli/memo org sync")
check("org sync", c4 == 0 and o4:find("pulled:", 1, true) and o4:find("pushed:", 1, true), o4)
local o5, c5 = sh(env .. "./cli/memo org --help")
check("org --help", c5 == 0 and o5:find("usage:", 1, true) and o5:find("memo org pair | status | pull", 1, true), o5)
local _, c6 = sh(env .. "./cli/memo org bogus")
check("org: unknown subcommand → exit 2", c6 == 2, c6)
local o7, c7 = sh(("MEMO_EMBEDDER=hash MEMO_LUA=%q ./cli/memo org status"):format(lua_bin))
check("org without a central → exit 2 + hint", c7 == 2 and o7:find("MEMO_ORG_URL", 1, true), o7)
local o8, c8 = sh(("MEMO_EMBEDDER=hash MEMO_LUA=%q MEMO_ORG_URL=http://127.0.0.1:1 MEMO_ORG_FINGERPRINT=%q "
    .. "MEMO_FEDERATION_DIR=%q ./cli/memo org pull"):format(lua_bin, FP, DKDIR))
check("org pull offline → exit 1", c8 == 1 and o8:find("unreachable", 1, true), o8)
local o9, c9 = sh(("MEMO_EMBEDDER=hash MEMO_LUA=%q MEMO_ORG_URL=http://ops:pw-leak@127.0.0.1:1 MEMO_ORG_FINGERPRINT=%q "
    .. "./cli/memo org pull"):format(lua_bin, FP))
check("URL credentials are refused and never echoed", c9 == 1 and not o9:find("pw-leak", 1, true), o9)
end)
end

-- ---------------------------------------------------------------------------
-- Teardown (always).
client.PAGE = 200
if SERVER_PID then os.execute("kill " .. SERVER_PID .. " 2>/dev/null") end
if LOG then
    local s = H.slurp(LOG) or ""
    check("central log carries method + path only (no envelopes / bodies)",
        s:find("POST /federation/call 200", 1, true) ~= nil and not s:find("LMC2", 1, true))
    os.remove(LOG)
end
pcall(function() dev(); wipe_dev() end)
H.drop_dbs()
os.execute(("rm -rf %q %q"):format(CKDIR, DKDIR))
keys.set_dir(nil)
finish()
