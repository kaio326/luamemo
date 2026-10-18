-- eval/tests/test_federation_orgdb.lua
-- Phase 12F.5 — one org database per machine, project tags, joining / leaving.
--   A. search `project` filter: narrows org: scopes only (project + org-wide
--      rows), other scopes untouched, temporal leg obeys it too
--   B. registry (per-user orgs.json): link / get / unlink / remove, db only
--      from the first project, 0600
--   C. _common.rc_set: set / replace / delete, 0600
--   D. adopt: copy a project's database into the org database — memories,
--      reinforcements, retrieval events (remapped), graph facts, weights; org
--      rows never copied; idempotent re-run; source untouched; vector-size
--      mismatch or another embedder → re-embedded with the org database's
--      embedder; no answer / wrong size → copied without a vector
--   E. `memo org link | adopt | leave` across four projects: register (with the
--      database's embedder), join a fresh project (takes that embedder), adopt
--      one with memories (re-embedded), one that keeps its own database (not a
--      user of the org database; leaving cleans its own), leave keeps the
--      replica while others use it and removes it with the last one
-- Uses the run's database (MEMO_DB) and further SQLite files (H.create_db).
-- Run: luajit eval/tests/run.lua --only federation_orgdb

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Federation org-db")
local check, section, finish = T.check, T.section, T.finish
local sh, slurp, mode, rcv = H.sh, H.slurp, H.mode, H.rc_get

local lua_bin = H.lua_bin()

local TMP = os.tmpname(); os.remove(TMP)
os.execute(("mkdir -p %q"):format(TMP))
local keys = require("luamemo.federation.keys")
keys.set_dir(TMP .. "/xdg/luamemo")

local luamemo = require("luamemo")
local db      = require("luamemo.db")
local store   = require("luamemo.store")
local util    = require("luamemo.util")
local policy  = require("luamemo.federation.policy")
local ORG, MINE = "org:fedodb", "repo:fedodb"
local function dev()
    luamemo.setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false,
                    org_url = "http://127.0.0.1:1", org_fingerprint = "0000-0000-0000-0000-0000" })
end
local function wipe()
    db.run("DELETE FROM lm_memories WHERE scope IN (?, ?)", ORG, MINE)
end

-- ---------------------------------------------------------------------------
section("A filter", function()
io.write("\n--- A: project filter ---\n")
dev(); wipe()
local cap = policy.capability("replica")
local function rep(id, title, project)
    return store.replica_upsert(ORG, { id = id, title = title, body = title .. " — shared release checklist",
        tier = 2, updated_us = tostring(1700000000000000 + id), metadata = { project = project } }, nil, cap)
end
rep(1, "api release checklist", "api")
rep(2, "portal release checklist", "portal")
rep(3, "company release checklist", nil)
store.write({ scope = MINE, title = "my release checklist", body = "personal release checklist notes", importance = 0.6 })
local function titles(rows)
    local t = {}
    for _, r in ipairs(rows or {}) do t[r.title] = true end
    return t
end
local all = titles(store.search({ query = "release checklist", scopes = { MINE, ORG }, limit = 20 }))
check("no filter: every org row + personal", all["api release checklist"] and all["portal release checklist"]
    and all["company release checklist"] and all["my release checklist"])
local api = titles(store.search({ query = "release checklist", scopes = { MINE, ORG }, limit = 20, project = "api" }))
check("project=api: api + org-wide org rows, other projects' rows out", api["api release checklist"]
    and api["company release checklist"] and not api["portal release checklist"])
check("project filter leaves non-org scopes alone", api["my release checklist"] == true)
local tq = titles(store.search({ query = "release checklist from today", scopes = { MINE, ORG }, limit = 20,
    project = "api" }))
check("temporal leg obeys the filter too", not tq["portal release checklist"])
-- Leaving / reconciling deletes a whole replica: any number of ids (one parameter).
local del = {}
for _, v in pairs(store.replica_index(ORG)) do del[#del + 1] = v.id end
for i = 1, 10000 do del[#del + 1] = 900000000 + i end
local nd, nerr = store.replica_delete(ORG, del, cap)
check("replica_delete takes any number of ids (3 real among 10,003)", nd == 3, nerr or nd)
wipe()
end)

-- ---------------------------------------------------------------------------
section("B registry", function()
io.write("\n--- B: registry ---\n")
local reg = require("luamemo.federation.registry")
local fp = "ABCD-EFGH-JKMN-PQRS-TVWX"
check("unknown org → nil", reg.get(fp) == nil)
local e = reg.link(fp, { url = "http://10.0.0.5:8765", db = "/data/one.db", org_scope = "org:acme" },
    "/w/api", "repo:api")
check("first link records the org database", e and e.db == "/data/one.db" and e.org_scope == "org:acme")
reg.link(fp, { url = "http://10.0.0.6:8765", db = "/data/two.db" }, "/w/portal", "repo:portal")
local e2 = reg.get("abcd efgh jkmn pqrs tvwx")
check("db kept from the first project; address updated; lookup normalised",
    e2 and e2.db == "/data/one.db" and e2.url == "http://10.0.0.6:8765"
        and e2.projects["/w/portal"] == "repo:portal")
check("registry file is 0600", mode(TMP .. "/xdg/luamemo/orgs.json") == "600")
check("unlink → remaining count", reg.unlink(fp, "/w/api") == 1 and reg.unlink(fp, "/w/portal") == 0)
check("remove", reg.remove(fp) and reg.get(fp) == nil)
end)

-- ---------------------------------------------------------------------------
section("C rcfile", function()
io.write("\n--- C: .luamemorc writer ---\n")
local common = require("luamemo.cli._common")
local rc = TMP .. "/rc"
local f = assert(io.open(rc, "w")); f:write("# comment\nMEMO_DB=/data/x.db\nMEMO_SCOPE=repo:a\n"); f:close()
H.trust_rc(rc)   -- written by hand: memo rewrites a project's file only once it is trusted
common.rc_set(rc, "MEMO_DB", "/data/y.db")
common.rc_set(rc, "MEMO_ORG_URL", "http://10.0.0.5:8765")
common.rc_set(rc, "MEMO_SCOPE", nil)
local s = slurp(rc) or ""
check("replace + append + delete, comment kept", s:find("# comment", 1, true) and rcv(s, "MEMO_DB") == "/data/y.db"
    and not s:find("/data/x.db", 1, true) and rcv(s, "MEMO_ORG_URL") == "http://10.0.0.5:8765"
    and not s:find("MEMO_SCOPE", 1, true), s)
check("rc file is 0600", mode(rc) == "600")
local lf = assert(io.open(rc .. ".tmp", "w")); lf:close()
os.execute(("chmod 644 %q"):format(rc .. ".tmp"))
common.rc_set(rc, "MEMO_DB", "/data/z.db")
check("a leftover world-readable rc.tmp doesn't make the rc world-readable", mode(rc) == "600", mode(rc))
end)

-- ---------------------------------------------------------------------------
-- Throwaway databases for D / E. A database's vector size is fixed by its first
-- vector; `dim` fixes it up front (an org database that already holds vectors).
local SUFFIX = ("%d_%04d"):format(os.time(), math.random(0, 9999))
local function with(path, fn)
    local c = assert(db.open(path))
    local ok, a, b = pcall(fn, c)
    c.close()
    if not ok then error(a, 0) end
    return a, b
end
local function newdb(tag, dim)
    local path = H.create_db("lm_fodb_" .. tag .. "_" .. SUFFIX)
    if dim then
        with(path, function(c)
            assert(c.run("INSERT INTO lm_meta (key, value) VALUES ('embed_dim', ?)", tostring(dim)))
        end)
    end
    return path
end
local function q(path, sql, ...)
    local args = { n = select("#", ...), ... }
    return with(path, function(c) return assert(c.query(sql, unpack(args, 1, args.n))) end)
end
local function count(path, where) return tonumber(q(path, "SELECT count(*) AS n FROM lm_memories" .. (where or ""))[1].n) end

-- Seed a "solo project" database through a subprocess (its own MEMO_DB).
local function seed(path_db, scope, dim)
    local path = TMP .. "/seed.lua"
    local f = assert(io.open(path, "w"))
    f:write(([[
package.path = "./?.lua;./?/init.lua;" .. package.path
local luamemo = require("luamemo")
luamemo.setup({ embedder_local = "hash", embed_dim = %d, skip_embed_probe = true, patterns_enabled = false })
local store, db = luamemo.store, require("luamemo.db")
local SCOPE, now = %q, require("luamemo.util").now_us()
local a = store.write({ scope = SCOPE, kind = "decision", title = "use pgmoon", body = "pure-Lua driver", importance = 0.8 })
local b = store.write({ scope = SCOPE, kind = "fact", title = "api port", body = "the api listens on 8080", importance = 0.6 })
local c = store.write({ scope = "codeindex:p", kind = "file", title = "src/api.lua", body = "api module", importance = 0.5 })
assert(db.run("INSERT INTO lm_memories (scope, kind, title, body, metadata, importance, tier) "
    .. "VALUES ('org:x', 'fact', 'replica', 'org row', '{\"lm_org_id\":\"7\"}', 0.5, 2)"))
require("luamemo.digest").record_event(a.id, SCOPE, "praise", 0.5, "useful")
assert(db.run("INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids, created_at) "
    .. "VALUES (?, 'which driver', ?, ?)", SCOPE, db.json({ a.id, b.id }), now))
assert(db.run("INSERT INTO lm_kg_facts (scope, subject, predicate, object, valid_from, source_memory_id, created_at) "
    .. "VALUES ('codeindex:p', 'src/api.lua', 'requires', 'pgmoon', ?, ?, ?)", now, c.id, now))
assert(db.run("INSERT INTO lm_observations (scope, body, proof_count, evidence_ids, evidence_quotes, "
    .. "last_reinforced, created_at) VALUES (?, 'the project talks to Postgres through pgmoon', 2, ?, ?, ?, ?)",
    SCOPE, db.json({ a.id, b.id }), db.json({ "pure-Lua driver" }), now, now))
local ls = require("luamemo.learner_store")
ls.promote(SCOPE, "reranker", ls.save_version(SCOPE, "reranker", { bias = 0.1 }, { note = "solo" }))
io.write("SEEDED ", a.id, " ", b.id, "\n")
]]):format(dim or 384, scope))
    f:close()
    local out = sh(("MEMO_DB=%q %s %q"):format(path_db, lua_bin, path))
    return out:find("SEEDED", 1, true) ~= nil, out
end

section("D adopt", function()
io.write("\n--- D: adopt ---\n")
local src = newdb("src")
local tgt = newdb("tgt")
local ok, out = seed(src, "repo:p")
check("source project seeded", ok, out)
local adopt = require("luamemo.federation.adopt")
local before = count(src)
local dry = adopt.run(src, tgt, { dry_run = true })
check("dry-run counts, writes nothing", dry and dry.memories == 3 and count(tgt) == 0, dry and dry.memories)
local r, err = adopt.run(src, tgt)
check("adopt copies the project's memories (not the org replica row)", r and r.memories == 3
    and count(tgt, " WHERE scope GLOB 'org:*'") == 0, err or (r and r.memories))
check("… with reinforcement, retrieval event, graph fact, observation, learned weights",
    r and r.reinforcements == 1 and r.retrievals == 1 and r.facts == 1 and r.observations == 1 and r.weights == 1,
    r and ("%d/%d/%d/%d/%d"):format(r.reinforcements, r.retrievals, r.facts, r.observations, r.weights))
local ob = q(tgt, "SELECT evidence_ids AS e, proof_count, evidence_quotes AS qt FROM lm_observations")[1]
local ids2 = q(tgt, "SELECT group_concat(id, ',') AS s FROM (SELECT id FROM lm_memories WHERE scope = 'repo:p' "
    .. "ORDER BY id)")[1].s
check("observation: evidence remapped, proof count + quotes kept", ob and ob.e == "[" .. ids2 .. "]"
    and tonumber(ob.proof_count) == 2 and ob.qt:find("pure-Lua driver", 1, true), ob and (ob.e .. " vs " .. ids2))
local m = q(tgt, "SELECT id FROM lm_memories WHERE title = 'use pgmoon'")[1]
local rf = q(tgt, "SELECT candidate_ids AS c FROM lm_retrieval_feedback")[1]
local rn = q(tgt, "SELECT memory_id FROM lm_reinforcements")[1]
local kg = q(tgt, "SELECT source_memory_id AS s FROM lm_kg_facts")[1]
local cm = q(tgt, "SELECT id FROM lm_memories WHERE title = 'src/api.lua'")[1]
check("references remapped to the new ids", m and rn and tonumber(rn.memory_id) == tonumber(m.id)
    and rf and rf.c:find(tostring(m.id), 1, true) and kg and cm and tonumber(kg.s) == tonumber(cm.id))
check("vectors copied (same vector size)", count(tgt, " WHERE embedding IS NULL") == 0)
check("source untouched", count(src) == before)
local r2 = adopt.run(src, tgt)
check("re-run: everything already adopted, nothing duplicated", r2 and r2.memories == 0 and r2.skipped == 3
    and count(tgt) == 3 and r2.reinforcements == 0 and r2.retrievals == 0 and r2.facts == 0
    and r2.observations == 0 and r2.weights == 0, r2 and r2.memories)
local alias = TMP .. "/alias-src.db"
os.execute(("ln -s %q %q"):format(src, alias))
local r2b = adopt.run(alias, tgt)
check("… also when reached through another path (identity is the database, not its path)",
    r2b and r2b.memories == 0 and r2b.skipped == 3 and count(tgt) == 3, r2b and r2b.memories)
check("same database refused", select(2, adopt.run(tgt, tgt)) ~= nil)
local hash = require("luamemo.embedders.hash")
local small = newdb("small", 256)
local r3 = adopt.run(src, small, { embed = function(t) return hash.embed(t, { embed_dim = 256 }) end })
check("different vector size → re-embedded with the org database's embedder", r3 and r3.memories == 3
    and r3.reembedded == 3 and r3.unembedded == 0 and count(small, " WHERE embedding IS NULL") == 0,
    r3 and r3.reembedded)
local other = newdb("other")
-- Another embedder of the same size (its vectors differ from the source's): a
-- copied vector would compare equal.
local r4 = adopt.run(src, other, { same_space = false,
    embed = function(t) return hash.embed("another model: " .. t, { embed_dim = 384 }) end })
local v_src = q(src, "SELECT embedding AS e FROM lm_memories WHERE title = 'api port'")[1].e
local v_new = q(other, "SELECT embedding AS e FROM lm_memories WHERE title = 'api port'")[1].e
check("same vector size, another embedder → re-embedded, not copied", r4 and r4.reembedded == 3
    and v_new and v_new ~= v_src, r4 and r4.reembedded)
local none = newdb("none", 256)
local r5 = adopt.run(src, none, { embed = function() return nil end })
check("embedder not answering / wrong size → copied without a vector (memo reembed later)",
    r5 and r5.memories == 3 and r5.unembedded == 3 and count(none, " WHERE embedding IS NULL") == 3,
    r5 and r5.unembedded)
local r6 = adopt.run(src, newdb("wrong", 256), { embed = function(t) return hash.embed(t, { embed_dim = 384 }) end })
check("… a vector of the wrong size is never written", r6 and r6.unembedded == 3, r6 and r6.unembedded)
end)

-- ---------------------------------------------------------------------------
section("E cli", function()
io.write("\n--- E: memo org link | adopt | leave ---\n")
local REPO = (sh("pwd")):gsub("%s+$", "")
local MEMO = REPO .. "/cli/memo"
local abs = ("%s/?.lua;%s/?/init.lua;"):format(REPO, REPO)
-- MEMO_PROJECT= : the project is each call's working directory (not a caller's MEMO_PROJECT).
local ENV = ("HOME=%q XDG_CONFIG_HOME=%q MEMO_PROJECT= MEMO_EMBEDDER=hash MEMO_LUA=%q LUA_PATH=%q")
    :format(TMP .. "/home", TMP .. "/xdg", lua_bin, abs .. (os.getenv("LUA_PATH") or ";"))
local FPX = "1111-2222-3333-4444-5555"
local function project(name, dbpath, dim, fp)
    local dir = TMP .. "/" .. name
    os.execute(("mkdir -p %q"):format(dir))
    local f = assert(io.open(dir .. "/.luamemorc", "w"))
    f:write(("MEMO_DB=%s\nMEMO_EMBEDDER=hash\nMEMO_EMBED_DIM=%d\nMEMO_ORG_URL=http://127.0.0.1:1\n"
        .. "MEMO_ORG_FINGERPRINT=%s\nMEMO_ORG_IDENTITY=user:dev@corp.io\n"):format(dbpath, dim or 384, fp or FPX))
    f:close()
    H.trust_rc(dir .. "/.luamemorc", TMP .. "/xdg/luamemo")   -- by hand: trusted (memo's XDG_CONFIG_HOME)
    return dir
end
local function org(dir, args) return sh(("cd %q && %s %q org %s"):format(dir, ENV, MEMO, args)) end
-- An org replica row + its sync state in a database.
local function replica(path)
    with(path, function(c)
        assert(c.run("INSERT INTO lm_memories (scope, kind, title, body, metadata, importance, tier) VALUES "
            .. "('org:fedodb', 'fact', 'org rule', 'shared', '{\"lm_org_id\":\"1\"}', 0.5, 2)"))
        assert(c.run("INSERT INTO lm_federation_state (org_scope, updated_at) VALUES ('org:fedodb', ?) "
            .. "ON CONFLICT DO NOTHING", util.now_us()))
    end)
end
local A, B, C = newdb("a"), newdb("b", 256), newdb("c", 256)
seed(C, "repo:c", 256)
local pa, pb, pc = project("pa", A), project("pb", B, 256), project("pc", C, 256)
local o1 = org(pa, "link --scope repo:a")
local reg = require("luamemo.federation.registry").get(FPX) or {}
check("first project registers its database as the org database, with its embedder",
    o1:find("LINK=register", 1, true) and reg.db == A and type(reg.embed) == "table"
    and reg.embed.MEMO_EMBED_DIM == "384" and reg.embed.MEMO_EMBEDDER == "hash" and reg.embed_sig == "hash||384", o1)
local o2 = org(pb, "link --scope repo:b")
local rcb = slurp(pb .. "/.luamemorc") or ""
check("a fresh project joins the org database", o2:find("LINK=switched", 1, true)
    and rcv(rcb, "MEMO_DB") == A, o2)
check("… and takes its embedder (one embedding space per database)", rcv(rcb, "MEMO_EMBED_DIM") == "384"
    and o2:find("embedder:", 1, true), rcb)
check("… and names the database it now uses", o2:find(A, 1, true) ~= nil, o2)
local o3 = org(pc, "link --scope repo:c")
check("a project with its own memories is offered adopt (not switched)", o3:find("LINK=adopt 3", 1, true)
    and rcv(slurp(pc .. "/.luamemorc"), "MEMO_DB") == C, o3)
local o4, c4 = org(pc, "adopt --scope repo:c")
local rcc = slurp(pc .. "/.luamemorc") or ""
check("memo org adopt copies + switches", c4 == 0 and o4:find("copied", 1, true)
    and rcv(rcc, "MEMO_DB") == A and count(A, " WHERE scope = 'repo:c'") == 2, o4)
check("… re-embedding with the org database's embedder (256 → 384), and switches the embedder",
    o4:find("re%-embedded: *3") ~= nil and rcv(rcc, "MEMO_EMBED_DIM") == "384"
    and count(A, " WHERE scope = 'repo:c' AND embedding IS NULL") == 0, o4)
-- The org replica in the shared org database (A):
replica(A)
-- A project that keeps its own database (declines adopt) syncs into it; it is
-- not a user of the org database, and leaving cleans ITS database only.
local registry = require("luamemo.federation.registry")
local D2 = newdb("d")
seed(D2, "repo:d")
local pd = project("pd", D2)
local od = org(pd, "link --scope repo:d")
check("kept its own database → not counted as a user of the org database", od:find("LINK=adopt 3", 1, true)
    and registry.get(FPX).projects[pd] == nil and registry.get(FPX).projects[pc] == "repo:c", od)
replica(D2)
local ld = org(pd, "leave")
check("… leaving removes the replica from its own database, the org database's stays", ld:find("removed org:fedodb", 1, true)
    and count(D2, " WHERE scope = 'org:fedodb'") == 0 and count(A, " WHERE scope = 'org:fedodb'") == 1
    and registry.get(FPX) ~= nil, ld)
-- One org per database: a project on org X's database (still used by X's
-- projects) can't join org Y into it, nor adopt X's memories into Y's.
local FPY = "9999-8888-7777-6666-5555"
registry.link(FPY, { db = B }, "/elsewhere", "repo:e")
local pz = project("pz", A, 384, FPY)
local az, cz = org(pz, "adopt --scope repo:z")
check("adopt from another org's shared database refused", cz == 1 and az:find("another org's database", 1, true), az)
local lz = org(pz, "link --scope repo:z")
check("link into another org's database refused, org settings removed", lz:find("LINK=conflict", 1, true)
    and not (slurp(pz .. "/.luamemorc") or ""):find("MEMO_ORG_URL", 1, true)
    and registry.get(FPY).projects[pz] == nil, lz)
registry.remove(FPY)
local pn = project("pn", A, 384, "")
local ln = org(pn, "leave")
check("leave without a pinned central: only the settings go, the org database's replica is untouched",
    ln:find("left as is", 1, true) and count(A, " WHERE scope = 'org:fedodb'") == 1
    and not (slurp(pn .. "/.luamemorc") or ""):find("MEMO_ORG_URL", 1, true), ln)
local l1 = org(pb, "leave")
check("leaving while other projects still use the org keeps the replica", l1:find("kept", 1, true)
    and count(A, " WHERE scope = 'org:fedodb'") == 1, l1)
check("… and removes the org settings from that project", not (slurp(pb .. "/.luamemorc") or ""):find("MEMO_ORG_URL", 1, true))
org(pa, "leave")
local l3 = org(pc, "leave")
check("the last project leaving removes the org's replica + state", l3:find("removed org:fedodb", 1, true)
    and count(A, " WHERE scope = 'org:fedodb'") == 0
    and tonumber(q(A, "SELECT count(*) AS n FROM lm_federation_state")[1].n) == 0, l3)
check("… and the org from the registry", require("luamemo.federation.registry").get(FPX) == nil)
check("the projects' own memories stay", count(A, " WHERE scope = 'repo:c'") == 2)
end)

-- ---------------------------------------------------------------------------
pcall(function() dev(); wipe() end)
H.drop_dbs()
keys.set_dir(nil)
os.execute(("rm -rf %q"):format(TMP))
finish()
