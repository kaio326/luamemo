-- eval/tests/test_federation_proposals.lua
-- Phase 12F.6 — knowledge proposals (dev filter → central review → approved,
-- decaying org knowledge that use keeps alive).
--   A. pure rules: content hash, secret scan, personal / style language, code refs
--   B. dev filter: only usage-proven, grounded, non-personal, secret-free
--      fact / decision memories of repo: scopes are candidates (private,
--      synthetic, other kinds / scopes, org duplicates never); bookkeeping —
--      record / linked / withdraw / private / re-proposal as an update
--   C. central queue: merge by content (support = distinct devs), near-duplicate
--      merge, refusal of secret / personal / malformed items, signals mode and
--      org_proposals=false refused, withdraw, approve (tier 1, decays, tagged),
--      known, reject + suppression until the content changes, update in place,
--      supersede, approve --top, remove; NO SILENT LOSS — use raises importance
--      and restarts the clock, top retrieval restarts it, a correction never
--      drops it below tier 1, decay / purge / bulk delete never remove it
--   D. end to end over the encrypted channel: push proposes, the admin
--      approves, the next push links, the pull replicates it, the proposer's
--      use of its own memory reaches the org copy; signals mode proposes nothing
--   E. CLI: memo org proposals (dev), memo org review + status + the admin's
--      session brief line (org)
-- Uses the run's database (MEMO_DB) as the dev's, a second SQLite file for the
-- central. Run: luajit eval/tests/run.lua --only federation_proposals

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Federation proposals")
local check, section, finish = T.check, T.section, T.finish
local sh = H.sh

local props = require("luamemo.federation.proposals")

-- ---------------------------------------------------------------------------
section("A rules", function()
io.write("\n--- A: pure rules ---\n")
check("content hash ignores case + whitespace", props.content_hash("Creating  Users", " POST /users\n goes ")
    == props.content_hash("creating users", "post /users goes"))
check("content hash differs on content", props.content_hash("a", "b") ~= props.content_hash("a", "c"))
local secrets = {
    "password = Hunter2xyz", "api_key: \"abc123def456\"", "AKIAIOSFODNN7EXAMPLE",
    "ghp_" .. ("a1B2"):rep(9), "postgres://app:s3cret@db:5432/app", "-----BEGIN RSA PRIVATE KEY-----",
    "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123", "eyJhbGciOi.eyJzdWIiOiIx.c2lnbmF0dXJl",
    "token=" .. ("Zx9"):rep(4), "key AbCdEfGhIjKlMnOpQrStUvWxYz012345",
    -- formats the scrubber's list (util.has_token, shared) brought: they used to pass
    "glpat-" .. ("aB3d"):rep(5), "Authorization: Basic dXNlcjpwYXNz", "Bearer abcdefghijklmnopq",
}
for _, s in ipairs(secrets) do check("secret spotted: " .. s:sub(1, 24), props.looks_secret(s)) end
-- Memories are stored scrubbed: one that held a credential is still never proposed.
for _, s in ipairs(secrets) do
    check("… and scrubbed: " .. s:sub(1, 20), props.looks_secret(require("luamemo.util").redact_secrets(s)))
end
local clean = { "the auth token: passed in the X-Auth header", "POST /users calls users.create()",
                "commit 3f2a9c1b7e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b fixed it", "password reset lives in api/reset.lua" }
for _, s in ipairs(clean) do check("not a secret: " .. s:sub(1, 30), not props.looks_secret(s)) end
check("personal: 'I prefer'", props.looks_personal("style", "I prefer early returns in users.create()"))
check("personal: 'my style'", props.looks_personal("x", "My style is to keep handlers thin"))
check("personal: naming taste", props.looks_personal("naming", "we prefer camelCase for locals"))
check("not personal: interface knowledge", not props.looks_personal("Creating users",
    "POST /users goes through users.create() in api/users.lua; it validates the email first."))
check("not personal: 'likely' is not 'like'", not props.looks_personal("Spaces", "the API likely trims spaces in names"))
local refs = props.refs("POST /users → `users.create()` in api/users.lua; see UserService and parse_email(x), e.g. Config.yml")
local set = {}
for _, r in ipairs(refs) do set[r] = true end
check("refs: backtick call, path, file, camel/Pascal, snake call, dotted", set["users.create"] and set["api/users.lua"]
    and set["users.lua"] and set["UserService"] and set["parse_email"] and set["Config.yml"], table.concat(refs, " | "))
end)

local lua_bin = H.lua_bin()

local luamemo = require("luamemo")
local db      = require("luamemo.db")
local json    = require("luamemo.json")
local store   = require("luamemo.store")
local util    = require("luamemo.util")
local policy  = require("luamemo.federation.policy")
local digest  = require("luamemo.digest")
local keys    = require("luamemo.federation.keys")

local REPO, CIX, USERS, ORG = "repo:fedprop", "codeindex:fedprop", "user:fedprop", "org:fedprop"
local ORGE = "org:fedprope"
local function q1(sql) return db.first(sql) or {} end
local function n(sql) return tonumber(q1(sql).n) or 0 end
local function ago(secs) return util.now_us() - math.floor(secs * 1000000) end
local DAY = 86400

-- org_propose_scopes: this dev database holds other projects' memories too —
-- only the test project may propose.
local BASE = { embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false,
               org_share = "triples", org_propose = true, org_proposals = true,
               org_propose_scopes = { "repo:fedprop" } }
local function setup(extra)
    local c = {}
    for k, v in pairs(BASE) do c[k] = v end
    for k, v in pairs(extra or {}) do c[k] = v end
    if type(luamemo.config) == "table" then luamemo.config.embedder_model = nil end
    luamemo.setup(c)
end
local function as_dev(extra)
    local e = { role = "dev", org_url = "http://127.0.0.1:1", org_fingerprint = "0000-0000-0000-0000-0000",
                org_identity = "user:dev@corp.io" }
    for k, v in pairs(extra or {}) do e[k] = v end
    setup(e)
end
local function as_org() setup({ role = "org", org_name = "fedprop" }) end

-- dev_only: keep the org replica + sync state (the end-to-end section re-seeds
-- the dev's own memories after its first pull).
local function wipe(dev_only)
    local list = dev_only and { REPO, CIX, USERS } or { REPO, CIX, USERS, ORG, ORGE }
    local scopes = "(" .. db.placeholders(#list) .. ")"
    db.run("DELETE FROM lm_org_proposed WHERE org_scope IN (?, ?)", ORG, ORGE)
    db.run("DELETE FROM lm_reinforcements WHERE scope IN " .. scopes, unpack(list))
    db.run("DELETE FROM lm_retrieval_feedback WHERE scope IN " .. scopes, unpack(list))
    db.run("DELETE FROM lm_memories WHERE scope IN " .. scopes, unpack(list))
    if not dev_only then
        db.run("DELETE FROM lm_org_proposals WHERE org_scope IN (?, ?)", ORG, ORGE)
        db.run("DELETE FROM lm_federation_state WHERE org_scope IN (?, ?)", ORG, ORGE)
    end
end

-- The dev's project: a code index + memories of every kind of case.
local function seed_dev()
    local W = function(a) local r = assert(store.write(a)); return tonumber(r.id) end
    W({ scope = CIX, kind = "file", title = "api/users.lua", body = "users api module", importance = 0.5,
        metadata = { path = "api/users.lua" } })
    W({ scope = CIX, kind = "symbol", title = "api.users.create", body = "create a user — function create(1 args)",
        importance = 0.8, metadata = { path = "api/users.lua", symbol_type = "function" } })
    local id = {}
    id.good = W({ scope = REPO, kind = "fact", tier = 1, title = "Creating users",
        body = "POST /users goes through `users.create()` in api/users.lua; it validates the email first." })
    id.tier2 = W({ scope = REPO, kind = "decision", tier = 2, title = "Users API errors",
        body = "api/users.lua returns 422 with a field map on validation errors." })
    id.miss = W({ scope = REPO, kind = "fact", tier = 1, title = "Users pagination",
        body = "The users list in api/users.lua is paginated by an opaque cursor." })
    id.unused = W({ scope = REPO, kind = "fact", tier = 1, title = "Session cleanup",
        body = "Session cleanup lives in api/users.lua near the bottom." })
    id.secret = W({ scope = REPO, kind = "fact", tier = 2, title = "Seeding the admin",
        body = "Seed the admin with users.create() in api/users.lua, password = Hunter2xyz" })
    id.personal = W({ scope = REPO, kind = "fact", tier = 2, title = "Handlers",
        body = "I prefer calling users.create() in api/users.lua directly from handlers." })
    id.ungrounded = W({ scope = REPO, kind = "decision", tier = 2, title = "Planning",
        body = "The team meets on Mondays to plan the sprint." })
    id.private = W({ scope = REPO, kind = "fact", tier = 2, title = "Internal users flag",
        body = "api/users.lua hides soft-deleted users unless ?all=1 is passed.", metadata = { private = true } })
    id.plan = W({ scope = REPO, kind = "plan", tier = 2, title = "Refactor users",
        body = "Split api/users.lua into handlers and a service." })
    id.user = W({ scope = USERS, kind = "fact", tier = 2, title = "Users module owner",
        body = "api/users.lua is maintained by the platform team." })
    id.dup = W({ scope = REPO, kind = "fact", tier = 2, title = "Soft delete",
        body = "Users are soft-deleted by api/users.lua (deleted_at is set)." })
    -- usage
    digest.record_event(id.good, REPO, "praise", 0.5, "useful")
    digest.record_event(id.secret, REPO, "praise", 0.5, "useful")
    digest.record_event(id.miss, REPO, "miss", 0.5, "miss:duplicate-write")
    assert(db.run("INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids, created_at) "
        .. "VALUES (?, 'create a user', ?, ?)", REPO, db.json({ id.good, id.secret }), util.now_us()))
    return id
end

-- ---------------------------------------------------------------------------
local ID
section("B dev filter", function()
io.write("\n--- B: dev filter + bookkeeping ---\n")
as_dev()
wipe()
ID = seed_dev()
-- The org already has the "Soft delete" knowledge (replica row, same content).
store.replica_upsert(ORG, { id = 77, title = "soft delete", body = "Users are soft-deleted by api/users.lua  (deleted_at is set).",
    tier = 1, updated_us = "1700000000000000", metadata = {} }, nil, policy.capability("replica"))
local list, skipped = props.candidates(ORG, { explain = true })
local got, why = {}, {}
for _, c in ipairs(list) do got[c.memory_id] = c end
for _, s in ipairs(skipped) do why[s.id] = s.reason end
check("candidates: proven + grounded (praise+retrieval, tier 2, miss)", got[ID.good] and got[ID.tier2] and got[ID.miss]
    and #list == 3, #list)
check("… each grounded in the code index", got[ID.good] and table.concat(got[ID.good].grounding, ","):find("api/users.lua", 1, true)
    and table.concat(got[ID.good].grounding, ","):find("users.create", 1, true), got[ID.good] and table.concat(got[ID.good].grounding, ","))
check("… best first", list[1] and list[1].score >= (list[2] and list[2].score or 0) and list[2].score >= (list[3] and list[3].score or 0))
check("… carrying project + kind", got[ID.tier2] and got[ID.tier2].project == "fedprop" and got[ID.tier2].kind == "decision")
check("skipped: not proven by use", (why[ID.unused] or ""):find("not proven", 1, true), why[ID.unused])
check("skipped: secret", (why[ID.secret] or ""):find("secret", 1, true), why[ID.secret])
check("skipped: personal preference", (why[ID.personal] or ""):find("personal", 1, true), why[ID.personal])
check("skipped: not grounded in the code", (why[ID.ungrounded] or ""):find("code index", 1, true), why[ID.ungrounded])
check("skipped: already in the org's memory", (why[ID.dup] or ""):find("already in the org", 1, true), why[ID.dup])
check("never considered: private, plan kind, user: scope, code index rows",
    not got[ID.private] and not why[ID.private] and not got[ID.plan] and not why[ID.plan]
    and not got[ID.user] and not why[ID.user])
-- A reworded copy of an org row: other words (no content-hash match), the same
-- meaning (here: the same vector) → caught by the vector near-duplicate check.
local rw = assert(store.write({ scope = REPO, kind = "fact", tier = 2, title = "Email check first",
    body = "users.create() in api/users.lua checks the e-mail before anything else." }))
local rwv = require("luamemo.vectors").unpack(db.value("SELECT embedding FROM lm_memories WHERE id = ?", rw.id))
store.replica_upsert(ORG, { id = 78, title = "Validation order", body = "Creating a user validates the address first.",
    tier = 1, updated_us = "1700000000000001", metadata = {} }, rwv, policy.capability("replica"))
local _, skipped2 = props.candidates(ORG, { explain = true })
local why2 = {}
for _, s in ipairs(skipped2) do why2[s.id] = s.reason end
check("a reworded copy of an org row (same vector, other words) → already in the org's memory",
    (why2[rw.id] or ""):find("already in the org", 1, true) ~= nil, why2[rw.id])
local near0 = props.NEAR_DUP
props.NEAR_DUP = -1                                  -- control: no vector check
local proposed = false
for _, c in ipairs(props.candidates(ORG)) do if c.memory_id == rw.id then proposed = true end end
props.NEAR_DUP = near0
check("… (control: without the vector check it would be proposed)", proposed)

local batch = props.outgoing(ORG, "inst1")
check("outgoing: 3 proposals, nothing to check yet", batch and #batch.propose == 3 and #batch.check == 0)
local wire = props.wire(batch)
check("wire form drops bookkeeping fields", wire.propose[1]._hash == nil and wire.propose[1]._memory == nil
    and wire.propose[1].ref:match("^inst1:p:%d+$") and wire.propose[1].title ~= nil)
local refof = function(id) return "inst1:p:" .. id end
local counts = props.record(ORG, batch, { results = {
    { ref = refof(ID.good), status = "pending", proposal = 11 },
    { ref = refof(ID.tier2), status = "approved", proposal = 12, memory = 999 },
    { ref = refof(ID.miss), status = "known", memory = 998 } } })
check("record: answers stored", counts.pending == 1 and counts.approved == 1 and counts.known == 1
    and #props.list(ORG) == 3)
local linked = props.linked(ORG)
check("linked: approved / known → the org memory", linked[ID.tier2] == 999 and linked[ID.miss] == 998 and not linked[ID.good])
check("sent memories aren't candidates again (unchanged)", #props.candidates(ORG) == 0)
local b2 = props.outgoing(ORG, "inst1")
check("next push checks the pending one", b2 and #b2.check == 1 and b2.check[1] == refof(ID.good) and #b2.propose == 0)
store.update(ID.tier2, { body = "api/users.lua returns 422 with a field map and an error code on validation errors." })
local c3 = props.candidates(ORG)
check("changed after approval → re-proposed as an UPDATE of its org memory", #c3 == 1 and c3[1].memory_id == ID.tier2
    and c3[1].update_of == 999, c3[1] and c3[1].update_of)
check("withdraw an approved one → refused (the admin's)", select(2, props.withdraw(ID.tier2)):find("org admin", 1, true) ~= nil)
check("withdraw a pending one", props.withdraw(ID.good) == true)
local b3 = props.outgoing(ORG, "inst1")
check("… sent with the next push", b3 and #b3.withdraw == 1 and b3.withdraw[1] == refof(ID.good))
local before = q1("SELECT updated_at AS u FROM lm_memories WHERE id = " .. ID.miss).u
props.set_private(ID.miss, true)
local after = q1("SELECT updated_at AS u, json_type(metadata, '$.private') AS p FROM lm_memories WHERE id = " .. ID.miss)
check("private: flagged, the row's age kept", after.p == "true" and math.abs(tonumber(after.u) - tonumber(before)) <= 1,
    ("%s vs %s"):format(tostring(before), tostring(after.u)))
check("private rows are never candidates", (function()
    for _, c in ipairs(props.candidates(ORG)) do if c.memory_id == ID.miss then return false end end
    return true end)())
check("org rows can't be marked", select(2, props.set_private(q1("SELECT id FROM lm_memories WHERE scope = '" .. ORG .. "'").id, true)) ~= nil)
check("org_propose_scopes / opts.scopes limit which projects may propose",
    #props.candidates(ORG, { scopes = { "repo:someother" } }) == 0 and #props.candidates(ORG, { scopes = { "user:x" } }) == 0)
local saved = props.MAX_CHECK
props.MAX_CHECK = 0
local b4 = props.outgoing(ORG, "inst1")
props.MAX_CHECK = saved
check("status checks / withdrawals per push are bounded", b4 == nil or (#b4.check == 0 and #b4.withdraw == 0))
require("luamemo.federation.client").forget(ORG)
check("leaving the org (forget) drops what was proposed to it — the memories stay",
    n("SELECT count(*) AS n FROM lm_org_proposed WHERE org_scope = '" .. ORG .. "'") == 0
    and n("SELECT count(*) AS n FROM lm_memories WHERE id = " .. ID.good) == 1)
end)

-- ---------------------------------------------------------------------------
section("C central", function()
io.write("\n--- C: central queue + no silent loss ---\n")
as_org()
local k = require("luamemo.federation.knowledge")
local central = require("luamemo.federation.central")
db.run("DELETE FROM lm_org_proposals WHERE org_scope = ?", ORG)
db.run("DELETE FROM lm_memories WHERE scope = ?", ORG)
local A, B, C = "user:a@corp.io", "user:b@corp.io", "user:c@corp.io"
local function item(ref, title, body, extra)
    local t = { ref = ref, project = "fedprop", kind = "fact", title = title, body = body, score = 1.2,
                grounding = { "api/users.lua" } }
    for kk, v in pairs(extra or {}) do t[kk] = v end
    return t
end
local T1, B1 = "Creating users", "POST /users goes through users.create() in api/users.lua; it validates the email first."
local r1 = k.ingest(A, { propose = { item("iA:p:1", T1, B1) } }).results[1]
check("new proposal → pending", r1.status == "pending" and r1.proposal, r1.status)
local P1 = r1.proposal
local r2 = k.ingest(B, { propose = { item("iB:p:7", "creating  USERS", "  " .. B1:upper():lower()) } }).results[1]
check("same content (case / spacing) from another dev merges", r2.status == "pending" and r2.proposal == P1
    and tonumber(k.get(P1).support) == 2, r2.proposal)
local r3 = k.ingest(A, { propose = { item("iA2:p:3", T1, B1) } }).results[1]
check("the same dev from a second machine doesn't add support", r3.proposal == P1 and tonumber(k.get(P1).support) == 2)
local bad = k.ingest(C, { propose = {
    item("c1", "Seed admin", "users.create() in api/users.lua with password = Hunter2xyz"),
    item("c2", "Style", "I prefer early returns in api/users.lua"),
    item("c3", "Plan", "split api/users.lua", { kind = "plan" }),
    item("c4", "No body", ""),
    item("c5", "Bad project", "x in api/users.lua", { project = "no spaces allowed" }) } }).results
check("refused: secret / personal / kind / empty / bad project (whatever the dev sent)",
    bad[1].status == "refused" and bad[2].status == "refused" and bad[3].status == "refused"
    and bad[4].status == "refused" and bad[5].status == "refused", json.encode(bad))
check("signals mode refused", select(2, k.ingest(C, { share = "signals", propose = { item("c6", "T", "B api/users.lua") } })) ~= nil)
luamemo.config.org_proposals = false
local _, e403, s403 = k.ingest(C, { propose = { item("c7", "T", "B api/users.lua") } })
luamemo.config.org_proposals = true
check("org_proposals=false → not taken", s403 == 403, e403)
check("oversized batch refused", select(3, k.ingest(C, { propose = (function() local t = {}
    for i = 1, k.MAX_ITEMS + 1 do t[i] = item("x" .. i, "t" .. i, "b") end return t end)() })) == 413)
local ck = k.ingest(A, { check = { "iA:p:1" } }).results[1]
check("check → pending", ck.status == "pending" and ck.proposal == P1)
local wd = k.ingest(B, { withdraw = { "iB:p:7" } }).results[1]
check("withdraw: the dev leaves the item (support back to 1)", wd.status == "withdrawn" and tonumber(k.get(P1).support) == 1
    and k.get(P1).status == "pending")
-- A push's lookups by (identity, ref) read the refs mirror (migration 005, kept by triggers):
-- matched inside the proposers JSON they read every proposal per ref (1.1 s for 50 checks at 20,000).
local refs = {}
for _, r in ipairs(db.query("SELECT identity, ref FROM lm_org_proposal_refs WHERE proposal_id = ? ORDER BY ref", P1) or {}) do
    refs[#refs + 1] = r.identity .. "=" .. r.ref
end
check("the refs mirror follows the proposers (added, withdrawn)", table.concat(refs, ",")
    == A .. "=iA2:p:3," .. A .. "=iA:p:1", table.concat(refs, ","))
local pplan = {}
for _, r in ipairs(db.query("EXPLAIN QUERY PLAN SELECT p.* FROM lm_org_proposal_refs r CROSS JOIN lm_org_proposals p "
    .. "ON p.id = r.proposal_id WHERE r.identity = ? AND r.ref = ? AND p.org_scope = ? ORDER BY p.id DESC LIMIT 1",
    A, "iA:p:1", ORG) or {}) do pplan[#pplan + 1] = tostring(r.detail) end
check("… a lookup by (identity, ref) is two index searches, no scan of the org's proposals",
    table.concat(pplan, " | "):find("lm_org_proposal_refs_idx", 1, true) ~= nil
    and not table.concat(pplan, " | "):find("SCAN", 1, true), table.concat(pplan, " | "))

-- Approve.
local K1 = k.approve(P1, "admin")
local m = q1("SELECT tier, importance, decay_rate, json_type(metadata, '$.lm_org_knowledge') AS k, "
    .. "json_extract(metadata, '$.project') AS p, tags AS tg FROM lm_memories WHERE id = " .. tonumber(K1 or 0))
check("approve → org memory at tier 1 that decays (0.01/day), tagged, project", K1 and tonumber(m.tier) == 1
    and math.abs(tonumber(m.decay_rate) - 0.01) < 1e-6 and m.k == "true" and m.p == "fedprop"
    and tostring(m.tg):find("knowledge", 1, true), json.encode(m))
check("approving twice refused", select(2, k.approve(P1, "admin")) ~= nil)
local ca = k.ingest(A, { check = { "iA:p:1", "iA2:p:3" } }).results
check("check → approved + the org memory, for every proposer ref", ca[1].status == "approved" and ca[1].memory == K1
    and ca[2].status == "approved")
local wa = k.ingest(A, { withdraw = { "iA2:p:3" } }).results[1]
check("a withdrawal that arrives after the approval → told it's approved (link kept)", wa.status == "approved"
    and wa.memory == K1 and k.get(P1).status == "approved")
local kn = k.ingest(C, { propose = { item("iC:p:5", T1:upper(), B1) } }).results[1]
check("the same content later → known (linked to the org memory)", kn.status == "known" and kn.memory == K1)

-- Reject + suppression.
local T2, B2 = "Users API errors", "api/users.lua returns 422 with a field map on validation errors."
local P2 = k.ingest(B, { propose = { item("iB:p:9", T2, B2) } }).results[1].proposal
check("reject", k.reject(P2, "admin", "too vague") == true and k.get(P2).status == "rejected")
local rj = k.ingest(C, { propose = { item("iC:p:9", T2, B2) } }).results[1]
check("rejected content stays rejected (anyone, until it changes)", rj.status == "rejected" and rj.proposal == P2)
local ch = k.ingest(C, { propose = { item("iC:p:9", T2, B2 .. " Includes an error code.") } }).results[1]
check("changed content → a fresh pending item", ch.status == "pending" and ch.proposal ~= P2)
local P3 = ch.proposal

-- Near-duplicate merge (embedding similarity).
local saved = k.MERGE_SIM
k.MERGE_SIM = 0.5
local nd = k.ingest(A, { propose = { item("iA:p:4", T2, B2 .. " It also includes an error code field.") } }).results[1]
k.MERGE_SIM = saved
check("near-identical wording merges into the pending item", nd.status == "pending" and nd.proposal == P3
    and tonumber(k.get(P3).support) == 2, nd.proposal)

-- Update in place (the proposer's source changed after approval).
local up = k.ingest(A, { propose = { item("iA:p:1", T1, B1 .. " Duplicate emails get 409.", { update_of = K1 }) } }).results[1]
check("an update of approved knowledge → pending, pointing at it", up.status == "pending" and tonumber(k.get(up.proposal).update_of) == K1)
local K1b = k.approve(up.proposal, "admin")
check("approving the update revises the SAME org memory", K1b == K1
    and q1("SELECT body FROM lm_memories WHERE id = " .. K1).body:find("409", 1, true) ~= nil)
check("supersede only approved org knowledge", select(2, k.approve(P3, "admin", { supersedes = 1 })) ~= nil)

-- approve --top / remove
local P5 = k.ingest(C, { propose = { item("iC:p:21", "Users export", "api/users.lua exports CSV via users.export()", { score = 3 }) } }).results[1].proposal
local P6 = k.ingest(C, { propose = { item("iC:p:22", "Users import", "api/users.lua imports via users.import()", { score = 0.1 }) } }).results[1].proposal
local top = k.approve_top(1, "admin")
check("approve --top 1 takes the best (score × support)", #top == 1 and (top[1].id == P3 or top[1].id == P5) and top[1].memory)
local K5 = top[1].id == P5 and top[1].memory or k.approve(P5, "admin")
check("remove approved knowledge (the admin's decision)", k.remove(K5, "admin") == true
    and n("SELECT count(*) AS n FROM lm_memories WHERE id = " .. K5) == 0 and k.get(P5).status == "rejected")
local again = k.ingest(A, { propose = { item("iA:p:21", "Users export", "api/users.lua exports CSV via users.export()") } }).results[1]
check("… and its content isn't proposed back", again.status == "rejected")
check("remove refuses other rows", select(2, k.remove(P6, "admin")) ~= nil)
check("counts", (k.counts().approved or 0) >= 2 and (k.counts().rejected or 0) >= 2)

-- No silent loss.
-- K1's tier, importance and age (seconds since its last update)
local function kr()
    local r = db.first("SELECT tier, importance, updated_at FROM lm_memories WHERE id = ?", K1) or {}
    r.age = r.updated_at and (util.now_us() - r.updated_at) / 1e6
    return r
end
db.run("UPDATE lm_memories SET updated_at = ?, importance = 0.6 WHERE id = ?", ago(400 * DAY), K1)
check("use: praise raises importance + restarts the decay clock", k.used(K1, "praise")
    and math.abs(tonumber(kr().importance) - 0.65) < 1e-4 and tonumber(kr().age) < 60, json.encode(kr()))
check("… a correction is not a use", not k.used(K1, "reversal"))
db.run("UPDATE lm_memories SET updated_at = ? WHERE id = ?", ago(2 * DAY), K1)
check("top retrieval result restarts the clock", k.seen_top(K1) and tonumber(kr().age) < 60)
check("… at most daily", not k.seen_top(K1))
db.run("UPDATE lm_memories SET tier = 0 WHERE id = ?", K1)
k.floor(K1)
check("a correction never drops it below tier 1", tonumber(kr().tier) == 1)
-- Decay maintenance: a plain org row fades out, approved knowledge doesn't.
local plain = assert(store.write({ scope = ORG, title = "plain org note", body = "an ordinary org memory", tier = 1,
    importance = 0.6, decay_rate = 0.01 }))
db.run("UPDATE lm_memories SET updated_at = ? WHERE id IN (?, ?)", ago(5 * 365 * DAY), K1, plain.id)
local decayed = store.find_decayed({ scope = ORG }) or {}
local dset = {}
for _, x in ipairs(decayed) do dset[tonumber(x)] = true end
check("decay: a plain org row is zeroed, approved knowledge never", dset[tonumber(plain.id)] and not dset[K1]
    and tonumber(kr().importance) > 0, json.encode(decayed))
check("bulk delete leaves approved knowledge alone", (store.delete_where({ scope = ORG, kind = "fact" }) or 0) >= 0
    and n("SELECT count(*) AS n FROM lm_memories WHERE id = " .. K1) == 1)
-- digest purge of consolidated tier-0 rows
local p0 = assert(store.write({ scope = ORG, title = "tier0 org note", body = "ephemeral org row", tier = 0, importance = 0.1 }))
db.run("UPDATE lm_memories SET tier = 0, consolidated_at = ? WHERE id IN (?, ?)", ago(30 * DAY), K1, p0.id)
digest.run(ORG)
check("digest purge: a consolidated tier-0 org row goes, approved knowledge stays",
    n("SELECT count(*) AS n FROM lm_memories WHERE id = " .. p0.id) == 0
    and n("SELECT count(*) AS n FROM lm_memories WHERE id = " .. K1) == 1)
db.run("UPDATE lm_memories SET tier = 1, consolidated_at = NULL WHERE id = ?", K1)
-- Through the feedback path (what a dev push does).
db.run("UPDATE lm_memories SET updated_at = ?, importance = 0.6 WHERE id = ?", ago(10 * DAY), K1)
local fb = central.ingest_feedback(A, { share = "triples", events = {
    { ref = "e-praise-1", memory = K1, type = "praise", delta = 0.5 } } }, A)
check("pushed praise → importance up, clock restarted", fb and fb.accepted_events == 1
    and tonumber(kr().importance) > 0.6 and tonumber(kr().age) < 60, json.encode(fb))
central.ingest_feedback(A, { share = "triples", events = {
    { ref = "e-rev-1", memory = K1, type = "reversal", delta = 1.0 },
    { ref = "e-rev-2", memory = K1, type = "reversal", delta = 1.0 },
    { ref = "e-rev-3", memory = K1, type = "reversal", delta = 1.0 } } }, A)
check("pushed corrections lower it, never below tier 1", tonumber(kr().tier) >= 1 and tonumber(kr().importance) < 0.65,
    json.encode(kr()))
db.run("UPDATE lm_memories SET updated_at = ? WHERE id = ?", ago(3 * DAY), K1)
central.ingest_feedback(A, { share = "triples", retrievals = {
    { ref = "r-top-1", query = "how do I create a user", candidates = { K1 }, top = K1 } } }, A)
check("pushed retrieval with it on top → clock restarted", tonumber(kr().age) < 60)
end)

-- ---------------------------------------------------------------------------
-- D. End to end: a real central served over the encrypted channel.
local SUFFIX  = ("%d_%04d"):format(os.time(), math.random(0, 9999))
local CDB     = "lm_fedprop_" .. SUFFIX
local CKDIR   = os.tmpname(); os.remove(CKDIR)
local DKDIR   = os.tmpname(); os.remove(DKDIR)
local central_db = H.db_path(CDB)
local PORT, FP, SERVER_PID
local PRELUDE = [[
package.path = "./?.lua;./?/init.lua;" .. package.path
local luamemo = require("luamemo")
luamemo.setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false,
                role = "org", org_name = "fedprope" })
local db, json = require("luamemo.db"), require("luamemo.json")
local k = require("luamemo.federation.knowledge")
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
local client = require("luamemo.federation.client")
local function dev(extra)
    keys.set_dir(DKDIR)
    local e = { role = "dev", org_url = "http://127.0.0.1:" .. tostring(PORT), org_fingerprint = FP,
                org_identity = "user:dev@corp.io" }
    for kk, v in pairs(extra or {}) do e[kk] = v end
    setup(e)
    client._reset_session()
end

local up = false
section("D setup", function()
io.write("\n--- D: end to end ---\n")
H.create_db(CDB)
FP = central([[local kk = require("luamemo.federation.keys")
-- An ordinary org memory the dev's "Soft delete" note duplicates (reaches the dev with the pull).
assert(luamemo.store.write({ scope = "org:fedprope", title = "Soft delete", tier = 1, importance = 0.6,
    body = "Users are soft-deleted by api/users.lua (deleted_at is set)." }))
result({ fp = kk.fingerprint(assert(kk.ensure_identity("central"))) })]]).fp
local LOG = os.tmpname()
local srv = "package.path='./?/init.lua;'..package.path; require('luamemo.cli.serve').run({'--port','0'})"
local out = sh(("MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_ROLE=org MEMO_ORG_NAME=fedprope MEMO_FEDERATION_DIR=%q "
    .. "%s%s -e %q >/dev/null 2>%q & echo \"PID=$!\""):format(central_db, CKDIR, H.timeout(600), lua_bin, srv, LOG))
SERVER_PID = tonumber(out:match("PID=(%d+)"))
PORT = H.wait_port(LOG)
check("central serving", PORT ~= nil)
if not PORT then return end
dev()
local pr = assert(client.pair())
check("device paired + approved", central(("result({ ok = devs.approve(%q, 'test') ~= nil })"):format(pr.code)).ok == true)
local s1, e1 = client.pull()
check("first pull (learns the org scope)", s1 and s1.org_scope == ORGE, e1)
up = s1 ~= nil
end)

if up then
section("D flow", function()
dev()
wipe(true)
ID = seed_dev()
local p1, e1 = client.push()
check("push proposes the dev's 3 candidates (the duplicate of a pulled org row isn't one)",
    p1 and p1.proposed == 3 and (p1.proposals or {}).pending == 3, e1 or json.encode(p1))
local q = central([[local rows = k.list({}) ; local t = {}
for _, r in ipairs(rows) do t[#t + 1] = { id = tonumber(r.id), title = r.title, project = r.project,
    who = (type(r.proposers) == "table" and r.proposers or json.decode(r.proposers))[1].identity } end
result({ items = t })]])
check("the central queue holds them, attributed to the paired identity (not the payload)", #q.items == 3
    and q.items[1].who == "user:dev@corp.io" and q.items[1].project == "fedprop", json.encode(q))
local ap = central("result({ r = k.approve_top(10, 'admin') })")
check("the admin approves", #ap.r == 3 and ap.r[1].memory ~= nil)
local p2 = client.push()
check("next push learns the approvals", p2 and (p2.proposals or {}).approved == 3, json.encode(p2 and p2.proposals))
local links = props.linked(ORGE)
check("… and links the source memories to the org copies", links[ID.good] ~= nil and links[ID.tier2] ~= nil)
local s2 = client.pull()
local rep = q1("SELECT count(*) AS n FROM lm_memories WHERE scope = '" .. ORGE .. "' "
    .. "AND json_type(metadata, '$.lm_org_knowledge') IS NOT NULL AND tier = 1 AND decay_rate > 0")
check("the pull replicates the approved knowledge", s2 and tonumber(rep.n) == 3, rep.n)
local kid = links[ID.good]
central(("assert(db.run('UPDATE lm_memories SET importance = 0.6 WHERE id = %d')); result({})"):format(kid))
digest.record_event(ID.good, REPO, "praise", 0.5, "used it again")
local p3 = client.push()
local imp = central(("result({ i = db.value('SELECT importance FROM lm_memories WHERE id = %d') })"):format(kid)).i
check("the proposer's use of its own memory reaches the org copy (importance up)", p3 and p3.events >= 1
    and tonumber(imp) > 0.6, ("events=%s imp=%s"):format(tostring(p3 and p3.events), tostring(imp)))
-- signals mode: nothing is proposed, whatever the candidates
local extra = assert(store.write({ scope = REPO, kind = "decision", tier = 2, title = "Users rate limit",
    body = "api/users.lua allows 10 creates per minute per key via users.create()." }))
dev({ org_share = "signals" })
local p4 = client.push()
local cnt = central("result({ n = #k.list({ status = 'all', limit = 500 }) })").n
check("signals mode: no proposal is sent", p4 and p4.proposed == nil and cnt == 3, ("proposed=%s queue=%s"):format(
    tostring(p4 and p4.proposed), tostring(cnt)))
dev({ org_propose = false })
local p5 = client.push()
check("org_propose=false: none either", p5 and p5.proposed == nil)
dev()
local p6 = client.push()
check("back in triples mode: the new candidate goes", p6 and p6.proposed == 1, json.encode(p6))
store.delete(extra.id)
end)

-- ---------------------------------------------------------------------------
section("E cli", function()
io.write("\n--- E: CLI ---\n")
local REPO_DIR = (sh("pwd")):gsub("%s+$", "")
local MEMO = REPO_DIR .. "/cli/memo"
local abs = ("%s/?.lua;%s/?/init.lua;"):format(REPO_DIR, REPO_DIR)
local TMPD = os.tmpname(); os.remove(TMPD); os.execute(("mkdir -p %q"):format(TMPD))
-- MEMO_PROJECT= : the project is TMPD, the working directory (not a caller's MEMO_PROJECT).
local COMMON = ("HOME=%q MEMO_PROJECT= MEMO_EMBEDDER=hash MEMO_LUA=%q LUA_PATH=%q")
    :format(TMPD, lua_bin, abs .. (os.getenv("LUA_PATH") or ";"))
local DEVENV = ("%s MEMO_DB=%q MEMO_ORG_URL=http://127.0.0.1:%d MEMO_ORG_FINGERPRINT=%q MEMO_FEDERATION_DIR=%q "
    .. "MEMO_ORG_IDENTITY=user:dev@corp.io MEMO_ORG_PROPOSE_SCOPES=repo:fedprop"):format(COMMON, assert(db.path()),
    PORT, FP, DKDIR)
local ORGENV = ("%s MEMO_DB=%q MEMO_ROLE=org MEMO_ORG_NAME=fedprope MEMO_FEDERATION_DIR=%q")
    :format(COMMON, central_db, CKDIR)
local function run(env, args) return sh(("cd %q && %s %q org %s"):format(TMPD, env, MEMO, args)) end
local o1, c1 = run(DEVENV, "proposals")
check("dev: memo org proposals lists them with their org copies", c1 == 0 and o1:find("approved", 1, true)
    and o1:find("→ org #", 1, true), o1)
local o2, c2 = run(DEVENV, "proposals candidates --explain")
check("dev: candidates --explain shows why the rest isn't proposed", c2 == 0 and o2:find("secret", 1, true)
    and o2:find("personal", 1, true), o2)
local o3, c3 = run(DEVENV, "status")
check("dev: status shows the proposals line", c3 == 0 and o3:find("proposals:", 1, true) and o3:find("3 approved", 1, true), o3)
local o4, c4 = run(ORGENV, "review")
check("org: review lists the pending one", c4 == 0 and o4:find("Users rate limit", 1, true), o4)
local pid = o4:match("#(%d+)")
local ob = sh(("cd %q && %s %q brief --scope repo:fedprop"):format(TMPD, ORGENV, MEMO))
check("org: the session brief tells the admin's agent what waits (the admin decides)",
    ob:find("1 knowledge proposal(s) await", 1, true) and ob:find("the admin decides", 1, true), ob)
local o5, c5 = run(ORGENV, "review show " .. tostring(pid))
check("org: review show", c5 == 0 and o5:find("grounded in", 1, true) and o5:find("user:dev@corp.io", 1, true), o5)
local o6, c6 = run(ORGENV, "review reject " .. tostring(pid) .. " --reason 'covered by the API docs'")
check("org: review reject", c6 == 0 and o6:find("rejected", 1, true), o6)
local o7, c7 = run(ORGENV, "status")
check("org: status shows the queue", c7 == 0 and o7:find("proposals:", 1, true) and o7:find("3 approved", 1, true), o7)
local _, c8 = run(ORGENV, "review approve")
check("org: review approve without an id → usage (exit 2)", c8 == 2)
os.execute(("rm -rf %q"):format(TMPD))
end)
end

-- ---------------------------------------------------------------------------
pcall(function()
    if SERVER_PID then os.execute("kill " .. SERVER_PID .. " 2>/dev/null") end
    as_dev()
    wipe()
end)
H.drop_dbs()
keys.set_dir(nil)
os.execute(("rm -rf %q %q"):format(CKDIR, DKDIR))
finish()
