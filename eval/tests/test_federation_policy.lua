-- eval/tests/test_federation_policy.lua
-- Phase 12.1 — federation write policy (luamemo.federation.policy) + identity.
--   A. Pure: config validation, role predicates, gates, tier cap, capabilities
--      are unforgeable, maintenance exclusion SQL; identity resolution.
--   B. DB-backed, through the real store / digest / consolidate paths, per role:
--      solo  — nothing changes (control: org: scopes behave like any scope);
--      org   — core tier (3) on org: scopes = directive capability only; every
--              other write / feedback / digest effect capped at tier 2; directives
--              immutable without the capability (update, delete, merge, bulk);
--      dev   — org: scopes are a read-only replica (replica capability only);
--              feedback records the event but never mutates replica rows.
--
-- Uses the run's database (MEMO_DB), scopes org:fedtest / repo:fedtest,
-- cleaned before and after.
-- Run: luajit eval/tests/run.lua --only federation_policy

package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("eval.tests._harness").new("Federation policy")
local check = T.check

local policy   = require("luamemo.federation.policy")
local identity = require("luamemo.federation.identity")

-- ---------------------------------------------------------------------------
io.write("\n--- A1: config validation ---\n")
-- ---------------------------------------------------------------------------
local function cfg_err(cfg)
    local ok, err = pcall(policy.configure, cfg)
    return (not ok) and tostring(err) or nil
end
check("no federation config → solo", (policy.configure({}) == "solo"))
check("org_url alone implies dev", policy.configure({ org_url = "https://org.example" }) == "dev")
check("role=dev without org_url is rejected", cfg_err({ role = "dev" }) ~= nil)
check("role=org without org_name is rejected", cfg_err({ role = "org" }) ~= nil)
check("role=org with a bad org_name is rejected", cfg_err({ role = "org", org_name = "a b" }) ~= nil)
check("role=org with org:acme-style name is accepted",
    policy.configure({ role = "org", org_name = "acme.eng_1" }) == "org")
check("unknown role is rejected", cfg_err({ role = "admin" }) ~= nil)
check("bad org_share is rejected", cfg_err({ org_share = "everything" }) ~= nil)
check("explicit role=solo wins over org_url", policy.configure({ role = "solo", org_url = "https://x" }) == "solo")

-- ---------------------------------------------------------------------------
io.write("\n--- A2: gates per role ---\n")
-- ---------------------------------------------------------------------------
local REPLICA, DIRECTIVE = policy.capability("replica"), policy.capability("directive")

policy.configure({})   -- solo
check("solo: org: scope is not a replica", not policy.replica("org:acme"))
check("solo: org: scope is not protected", not policy.protected("org:acme"))
check("solo: insert into org: allowed", policy.check_insert("org:acme") == true)
check("solo: tier 3 not capped", policy.cap_tier("org:acme", 3) == 3)
check("solo: no maintenance exclusion", policy.maintenance_exclusion_sql() == nil)

policy.configure({ role = "org", org_name = "acme" })
check("org: org: scope is protected", policy.protected("org:acme"))
check("org: personal scope is not protected", not policy.protected("repo:x"))
check("org: tier 3 capped to 2", policy.cap_tier("org:acme", 3) == 2)
check("org: tier 3 allowed with directive capability", policy.cap_tier("org:acme", 3, DIRECTIVE) == 3)
check("org: tier 3 on a personal scope not capped", policy.cap_tier("repo:x", 3) == 3)
check("org: directive row immutable", policy.check_mutation("org:acme", 3) == nil)
check("org: directive row mutable with capability", policy.check_mutation("org:acme", 3, DIRECTIVE) == true)
check("org: tier-2 org row mutable", policy.check_mutation("org:acme", 2) == true)
check("org: feedback can't touch a directive", not policy.feedback_may_mutate("org:acme", 3))
check("org: feedback can touch a tier-1 org row", policy.feedback_may_mutate("org:acme", 1))
check("org: maintenance excludes directives + approved org knowledge (decay never deletes it)",
    policy.maintenance_exclusion_sql()
        == "NOT (scope GLOB 'org:*' AND (tier = 3 OR json_type(metadata, '$.lm_org_knowledge') IS NOT NULL))")
check("org: directive capability lifts the exclusion", policy.maintenance_exclusion_sql(DIRECTIVE) == nil)

policy.configure({ org_url = "https://org.example" })   -- dev
check("dev: org: scope is a replica", policy.replica("org:acme"))
check("dev: insert into replica refused", policy.check_insert("org:acme") == nil)
check("dev: insert into replica with capability", policy.check_insert("org:acme", REPLICA) == true)
check("dev: replica row immutable", policy.check_mutation("org:acme", 1) == nil)
check("dev: personal scope untouched", policy.check_insert("repo:x") == true)
check("dev: feedback can't touch a replica row", not policy.feedback_may_mutate("org:acme", 1))
check("dev: maintenance excludes the replica", policy.maintenance_exclusion_sql() == "scope NOT GLOB 'org:*'")
check("dev: the directive capability does NOT open a replica", policy.check_insert("org:acme", DIRECTIVE) == nil)

-- Capabilities are compared by identity: nothing reconstructable counts.
local json = require("luamemo.json")
local forged = {
    { "a string naming it", tostring(REPLICA) },
    { "a fresh empty table", {} },
    { "a table decoded from JSON", json.decode('{"_cap":{}}')._cap },
    { "a copy with the same metatable", setmetatable({}, getmetatable(REPLICA)) },
}
for _, f in ipairs(forged) do
    check("forged capability refused: " .. f[1], policy.check_insert("org:acme", f[2]) == nil)
end
check("unknown capability name raises", not pcall(policy.capability, "admin"))

-- ---------------------------------------------------------------------------
io.write("\n--- A3: dev identity ---\n")
-- ---------------------------------------------------------------------------
check("explicit identity → user:<lower-cased email>",
    identity.resolve({ org_identity = "Dev.One@Example.com" }) == "user:dev.one@example.com")
check("explicit identity may carry the user: prefix",
    identity.resolve({ org_identity = "user:a@b.io" }) == "user:a@b.io")
check("explicit non-email identity is rejected", identity.resolve({ org_identity = "not an email" }) == nil)
local tmp = io.popen("mktemp -d"):read("*l")
os.execute(("git -C '%s' init -q && git -C '%s' config user.email 'Git.User@Corp.io'"):format(tmp, tmp))
check("git user.email → identity", identity.resolve({ root = tmp }) == "user:git.user@corp.io",
    tostring(identity.resolve({ root = tmp })))
os.execute(("git -C '%s' config user.email 'bad email'"):format(tmp))
local _, gerr = identity.resolve({ root = tmp })
check("invalid git e-mail is rejected with a reason", gerr ~= nil and gerr:find("not an e-mail", 1, true) ~= nil, gerr)
os.execute(("rm -rf '%s'"):format(tmp))

-- ---------------------------------------------------------------------------
-- B. DB-backed
-- ---------------------------------------------------------------------------
local luamemo = require("luamemo")
local db      = require("luamemo.db")
local store   = luamemo.store
local digest  = require("luamemo.digest")
local consolidate = require("luamemo.consolidate")

local BASE = { embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false }
local function setup_role(extra)
    local cfg = {}
    for k, v in pairs(BASE) do cfg[k] = v end
    for k, v in pairs(extra or {}) do cfg[k] = v end
    luamemo.setup(cfg)
end
local function wipe()
    db.run("DELETE FROM lm_memories WHERE scope IN ('org:fedtest', 'repo:fedtest')")
    db.run("DELETE FROM lm_reinforcements WHERE scope IN ('org:fedtest', 'repo:fedtest')")
end
-- Missing rows come back as {} so a regression fails its checks instead of
-- crashing the run and hiding every later check.
local function row(id)
    return id and db.first("SELECT id, scope, tier, importance, body FROM lm_memories WHERE id = ?",
        math.floor(tonumber(id) or 0)) or {}
end

-- Each role section runs under pcall: a regression that returns nil where a
-- row was expected fails that section loudly instead of aborting the run, and
-- the cleanup at the end always runs.
local section = T.section

setup_role({ role = "solo" })
wipe()

section("B1 solo", function()
io.write("\n--- B1: solo (control) ---\n")
local s1 = store.write({ scope = "org:fedtest", title = "solo org row", body = "plain org scope in solo mode",
                         importance = 9.5 })
check("solo: org: write lands at tier 3 (importance 9.5 — no protected-tier cap in solo)",
    s1 and tonumber(s1.tier) == 3, s1 and s1.tier)
check("solo: org: row updatable", store.update(s1.id, { body = "edited in solo" }) ~= nil)
-- A "?" inside metadata / tags / text must survive (update used to run a second
-- placeholder pass over the whole statement).
local uq = store.update(s1.id, { title = "why? a title", metadata = { q = "why?", n = "a?b" }, tags = { "t?" } })
local rq = store.get(s1.id) or {}
check("update keeps '?' in title, metadata and tags", uq and rq.title == "why? a title"
    and type(rq.metadata) == "table" and rq.metadata.q == "why?" and rq.metadata.n == "a?b"
    and type(rq.tags) == "table" and rq.tags[1] == "t?", uq and rq.title)
check("solo: org: row deletable", store.delete(s1.id) ~= nil)
-- Control for the digest guard below: in solo mode 5 mistakes DO promote tier 2 → 3.
local c = store.write({ scope = "repo:fedtest", title = "control", body = "control row for tier-3 promotion",
                        importance = 6 })     -- tier 2
for _ = 1, 5 do digest.record_event(c.id, "repo:fedtest", "mistake", 0.5, "t") end
digest.run("repo:fedtest")
check("solo control: 5 mistakes promote tier 2 → 3", tonumber(row(c.id).tier) == 3, row(c.id).tier)
-- Feedback moves importance (a ranking weight); tiers only as proof says:
-- a miss never demotes, a reversal never raises.
local p2 = store.write({ scope = "repo:fedtest", title = "proven", body = "a proven memory", importance = 1.0, tier = 2 })
digest.record_event(p2.id, "repo:fedtest", "miss", 1.0, "t")
check("solo: a miss never demotes a proven (tier 2) memory", tonumber(row(p2.id).tier) == 2, row(p2.id).tier)
local p1 = store.write({ scope = "repo:fedtest", title = "working", body = "a working memory" })   -- default: tier 1
digest.record_event(p1.id, "repo:fedtest", "reversal", 0.5, "t")
check("solo: a reversal never raises a tier", tonumber(p1.tier) == 1 and tonumber(row(p1.id).tier) <= 1, row(p1.id).tier)
end)

section("B2 org", function()
io.write("\n--- B2: org central ---\n")
setup_role({ role = "org", org_name = "fedtest" })
local DIR = policy.capability("directive")

local w = store.write({ scope = "org:fedtest", title = "remote insight", body = "high importance remote write",
                        importance = 9.5 })
check("org: remote write capped at tier 2", w and tonumber(w.tier) == 2, w and w.tier)
local d = store.write({ scope = "org:fedtest", title = "Directive: code review", importance = 1.0,
                        body = "Every change needs one approving review before merge.", _cap = DIR })
check("org: directive capability writes tier 3 (whatever its importance)", d and tonumber(d.tier) == 3, d and d.tier)
local explicit = store.write({ scope = "org:fedtest", title = "tier smuggle", body = "explicit tier 3",
                               tier = 3 })
check("org: explicit tier=3 without capability capped to 2", explicit and tonumber(explicit.tier) == 2)

local up, uerr = store.update(d.id, { body = "tampered directive" })
check("org: directive update refused", up == nil and uerr and uerr:find("read-only", 1, true), uerr)
check("org: directive update allowed with capability",
    store.update(d.id, { body = "Every change needs one approving review.", _cap = DIR }) ~= nil)
local del, derr = store.delete(d.id)
check("org: directive delete refused", del == nil and derr ~= nil, derr)

-- Dedup never merges into a directive.
local dup, _, act = store.write({ scope = "org:fedtest", title = "Directive: code review",
                                  body = "Every change needs one approving review.", dedup_strategy = "update" })
check("org: near-duplicate of a directive is skipped, not merged",
    act == "skipped" and dup and dup.id == d.id, act)
check("org: directive body unchanged after the duplicate write",
    row(d.id).body == "Every change needs one approving review.")

-- write_many: capped + no merge into the directive.
local res = store.write_many({
    { scope = "org:fedtest", title = "batch hi", body = "batch high importance", importance = 9.9 },
    { scope = "org:fedtest", title = "Directive: code review", body = "Every change needs one approving review." },
}, { dedup_strategy = "update" })
check("org: write_many row capped at tier 2", res[1] and res[1].row and tonumber(res[1].row.tier) == 2)
check("org: write_many duplicate of directive skipped", res[2] and res[2].action == "skipped", res[2] and res[2].action)

-- Moving a tier-3 personal memory into the org scope drops it to tier 2.
local personal = store.write({ scope = "repo:fedtest", title = "personal core", body = "personal tier three",
                               importance = 9.5 })
check("org: personal scope keeps tier 3", tonumber(personal.tier) == 3)
local moved = store.update(personal.id, { scope = "org:fedtest" })
check("org: moving a tier-3 row into org: lands at tier 2", moved and tonumber(moved.tier) == 2, moved and moved.tier)

-- Feedback: never moves a directive; caps others at 2.
local before = row(d.id)
digest.record_event(d.id, "org:fedtest", "reversal", 1.0, "t")
digest.record_event(d.id, "org:fedtest", "miss", 1.0, "t")
local after = row(d.id)
check("org: feedback leaves the directive's importance and tier alone",
    after.importance == before.importance and tonumber(after.tier) == 3)
local ev = db.value("SELECT count(*) FROM lm_reinforcements WHERE memory_id = ?", d.id)
check("org: the feedback events are still recorded", tonumber(ev) == 2, ev)
local low = store.write({ scope = "org:fedtest", title = "low", body = "low importance org row", importance = 0.5 })
for _ = 1, 4 do digest.record_event(low.id, "org:fedtest", "miss", 1.0, "t") end
check("org: repeated misses never lift an org row above tier 2", tonumber(row(low.id).tier) <= 2, row(low.id).tier)

-- Digest: the mistake-driven tier-3 promotion (see solo control) never fires here.
for _ = 1, 5 do digest.record_event(w.id, "org:fedtest", "mistake", 0.5, "t") end
digest.run("org:fedtest")
check("org: 5 mistakes do NOT promote an org row to tier 3", tonumber(row(w.id).tier) == 2, row(w.id).tier)

-- Bulk paths spare directives.
local decayer = store.write({ scope = "org:fedtest", title = "Directive: decaying", importance = 0.9,
                             body = "directive with a decay rate", decay_rate = 1.0, _cap = DIR })
local plain_decayer = store.write({ scope = "org:fedtest", title = "decaying note", importance = 0.9,
                                   body = "ordinary org row with a decay rate", decay_rate = 1.0 })
-- Backdating sticks (the updated_at trigger only touches implicit updates).
db.run("UPDATE lm_memories SET updated_at = ? WHERE id IN (?, ?)",
    require("luamemo.util").now_us() - 400 * 86400 * 1000000, decayer.id, plain_decayer.id)
local decayed = store.find_decayed({ scope = "org:fedtest", apply = false })
local hit, control = false, false
for _, id in ipairs(decayed or {}) do
    if tonumber(id) == decayer.id then hit = true end
    if tonumber(id) == plain_decayer.id then control = true end
end
check("org: decay control — an ordinary org row IS selected", control)
check("org: decay never selects a directive", not hit)
store.delete_where({ scope = "org:fedtest" })
local left = db.query("SELECT tier FROM lm_memories WHERE scope = 'org:fedtest'")
local only_dirs = #left > 0
for _, r in ipairs(left) do if tonumber(r.tier) ~= 3 then only_dirs = false end end
check("org: delete_where(scope) removes org rows but keeps every directive", only_dirs, #left)
-- memory_promote(delete_source) deletes source rows with raw SQL — directives survive.
local keep = store.write({ scope = "org:fedtest", title = "Directive: keep", importance = 0.9,
                          body = "directive that promote must not delete", _cap = DIR })
store.write({ scope = "org:fedtest", title = "foldable", body = "ordinary org row to fold", importance = 0.5 })
local summarizer = require("luamemo.summarizer")
local pr = summarizer.promote({ from_scope = "org:fedtest", to_scope = "repo:fedtest", delete_source = true })
check("org: promote(delete_source) from org: still runs", pr and pr.promoted == 1, pr and pr.errors and pr.errors[1])
check("org: promote(delete_source) keeps the directive", row(keep.id).id ~= nil)
local folded = db.value("SELECT count(*) FROM lm_memories WHERE scope = 'org:fedtest' AND tier < 3")
check("org: promote(delete_source) deletes the non-directive rows", tonumber(folded) == 0, folded)
check("org: delete with capability removes a directive", store.delete(d.id, { _cap = DIR }) ~= nil)
end)

section("B3 dev", function()
io.write("\n--- B3: dev replica ---\n")
setup_role({ role = "dev", org_url = "http://127.0.0.1:9" })
local REP = policy.capability("replica")

local nw, nerr = store.write({ scope = "org:fedtest", title = "local edit", body = "dev writes to replica" })
check("dev: write to the org replica refused", nw == nil and nerr:find("read-only replica", 1, true), nerr)
local rr = store.write({ scope = "org:fedtest", title = "replicated", body = "row from the central",
                         importance = 1.0, tier = 3, _cap = REP })   -- (the sync writer passes the central's tier)
check("dev: replica capability writes (tier kept, no cap on dev)", rr and tonumber(rr.tier) == 3, rr and rr.tier)
check("dev: forged capability string refused",
    store.write({ scope = "org:fedtest", title = "x", body = "forged", _cap = tostring(REP) }) == nil)
local ur, uer = store.update(rr.id, { body = "local tamper" })
check("dev: replica row update refused", ur == nil and uer ~= nil, uer)
check("dev: replica row delete refused", store.delete(rr.id) == nil)
local wm = store.write_many({ { scope = "org:fedtest", title = "wm", body = "batch into replica" } })
check("dev: write_many into replica refused per row", wm[1] and wm[1].error ~= nil and wm[1].row == nil)
local imp0 = row(rr.id).importance
digest.record_event(rr.id, "org:fedtest", "reversal", 1.0, "t")
check("dev: feedback does not change the replica row", row(rr.id).importance == imp0)
check("dev: digest skips the replica", (digest.run("org:fedtest") or {}).skipped == "replica")
check("dev: consolidation skips the replica", (consolidate.process("org:fedtest") or {}).skipped == "replica")
local bw, berr = store.delete_where({ scope = "org:fedtest" })
check("dev: bulk delete of the replica refused", bw == nil and berr ~= nil, berr)
local pw = store.write({ scope = "repo:fedtest", title = "personal", body = "dev personal scope still normal",
                         importance = 9.5 })
check("dev: personal scopes unaffected (tier 3 at importance 9.5)", pw and tonumber(pw.tier) == 3)
-- memory_promote(delete_source) from the replica would wipe it via raw SQL.
local pr = require("luamemo.summarizer").promote({ from_scope = "org:fedtest", to_scope = "repo:fedtest",
                                                   delete_source = true })
check("dev: promote(delete_source) from the replica is refused",
    pr and pr.promoted == 0 and pr.errors and tostring(pr.errors[1]):find("read-only replica", 1, true),
    pr and pr.errors and pr.errors[1])
check("dev: the replica row survives the refused promote", row(rr.id).id ~= nil)
local pr2 = require("luamemo.summarizer").promote({ from_scope = "org:fedtest", to_scope = "repo:fedtest" })
check("dev: promote WITHOUT delete_source reads the replica fine", pr2 and pr2.promoted == 1,
    pr2 and pr2.errors and pr2.errors[1])
check("dev: replica capability can delete (sync writer)", store.delete(rr.id, { _cap = REP }) ~= nil)
end)

-- Cleanup + restore solo (always runs).
setup_role({ role = "solo" })
wipe()
check("cleanup: test scopes empty",
    tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope IN ('org:fedtest','repo:fedtest')")) == 0)

T.finish()
