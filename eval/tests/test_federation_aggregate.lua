-- eval/tests/test_federation_aggregate.lua
-- Phase 12.4 — org central aggregation.
--   A. directives.parse (pure): sections, document-title context, deeper
--      headings, fenced code, front matter, preamble, duplicate slugs, CRLF
--   B. directives.sync (DB, org role): add → unchanged → update in place →
--      prune; dry-run; empty-path guard + allow_empty; source isolation; file
--      root; role gate; capability writes never merged, never a miss
--   C. directives gate: incumbent-equal candidate passes; a candidate that
--      demotes directives fails, naming them
--   D. promote.run pluggable gates: fail → reject (audited), pass → promote,
--      raising gate fails closed, dry-run
--   E. aggregate.run: role gate, report, the directives gate wired in
--   F. `memo org` on an org central: status / directives / aggregate
--
-- Uses the run's database (MEMO_DB), scope org:fedagg, cleaned before and
-- after. Run: luajit eval/tests/run.lua --only federation_aggregate

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Federation aggregate")
local check, section, finish = T.check, T.section, T.finish

local directives = require("luamemo.federation.directives")

-- ---------------------------------------------------------------------------
section("A parse", function()
io.write("\n--- A: directives.parse ---\n")
local doc = table.concat({
    "---", "title: ignored", "---",
    "Intro before any heading.",
    "# Security",
    "## Passwords",
    "Use a password manager.",
    "### Rotation", "Rotate yearly.",
    "```", "# not a heading", "```",
    "## Empty", "",
    "## Passwords",
    "Second passwords section.",
    "# Style",
    "Prefer small functions.",
}, "\r\n")
local s = directives.parse(doc, "std/security.md")
check("4 sections (empty + title-only skipped)", #s == 4, #s)
check("preamble → titled by the file name", s[1] and s[1].title == "security" and s[1].key == "std/security.md#_"
    and s[1].body == "Intro before any heading.", s[1] and s[1].title)
check("front matter dropped", not doc:find("ignored", 1, true) or not (s[1].body):find("ignored", 1, true))
check("level-2 title carries the document title", s[2] and s[2].title == "Security — Passwords", s[2] and s[2].title)
check("key = relpath#h1/h2 slug", s[2] and s[2].key == "std/security.md#security/passwords", s[2] and s[2].key)
check("deeper headings stay inside the section", s[2] and s[2].body:find("### Rotation", 1, true) ~= nil)
check("# inside fenced code is text", s[2] and s[2].body:find("# not a heading", 1, true) ~= nil)
check("duplicate heading → unique key", s[3] and s[3].key == "std/security.md#security/passwords-2", s[3] and s[3].key)
check("level-1 section with text", s[4] and s[4].title == "Style" and s[4].key == "std/security.md#style")
check("CRLF normalised", s[4] and not s[4].body:find("\r", 1, true))
local h = directives.parse("\239\187\191## Use C#\nx\n## Closed ##\ny\n##\nz\n", "h.md")
check("BOM stripped; '## C#' keeps its #", h[1] and h[1].title == "Use C#", h[1] and h[1].title)
check("space-separated closing #-run dropped", h[2] and h[2].title == "Closed", h[2] and h[2].title)
check("bare '##' is text, not a heading", h[2] and h[2].body:find("##\nz", 1, true) ~= nil, h[2] and h[2].body)
local flat = directives.parse("Just one rule.\n", "rules/plain.md")
check("no headings → one directive titled by the file", #flat == 1 and flat[1].title == "plain")
check("empty document → none", #directives.parse("\n\n", "x.md") == 0)
end)

local lua_bin = H.lua_bin()

local luamemo = require("luamemo")
local db      = require("luamemo.db")
local store   = require("luamemo.store")
local SCOPE   = "org:fedagg"
local ORG_CFG = { embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false,
                  role = "org", org_name = "fedagg", dedup_enabled = true, feedback_enabled = true }
local function org() luamemo.setup(ORG_CFG) end
local function q1(sql) return db.first(sql) or {} end
local function n(sql) return tonumber(q1(sql).n) or -1 end
local function wipe()
    for _, t in ipairs({ "lm_reinforcements", "lm_retrieval_feedback", "lm_learner_weights", "lm_promotion_runs" }) do
        db.run("DELETE FROM " .. t .. " WHERE scope = ?", SCOPE)
    end
    db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE)
end
local function ndir(src)
    return n("SELECT count(*) AS n FROM lm_memories WHERE scope = '" .. SCOPE .. "' AND tier = 3"
        .. (src and (" AND json_extract(metadata, '$.lm_directive_source') = '" .. src .. "'") or ""))
end

local TMP = os.tmpname(); os.remove(TMP)
local ROOT = TMP .. "/standards"
local function put(rel, text)
    os.execute(("mkdir -p %q"):format((ROOT .. "/" .. rel):match("^(.*)/")))
    local f = assert(io.open(ROOT .. "/" .. rel, "w")); f:write(text); f:close()
end

org()
wipe()

-- ---------------------------------------------------------------------------
section("B sync", function()
io.write("\n--- B: directives.sync ---\n")
put("security.md", "# Security\n## Passwords\nUse a password manager for every credential.\n"
    .. "## Reviews\nEvery change needs one approving review.\n")
put("style/lua.md", "# Lua style\n## Locals\nDeclare every variable local.\n## Errors\nReturn nil, err for expected failures.\n")
put("notes.txt", "# Not ingested\nplain text is not a standards document\n")
local r1, e1 = directives.sync(ROOT)
check("sync succeeds", r1 ~= nil, e1)
r1 = r1 or {}
check("4 directives added (only *.md)", r1.added == 4 and r1.files == 2 and r1.source == "standards",
    ("added=%s files=%s source=%s"):format(tostring(r1.added), tostring(r1.files), tostring(r1.source)))
local row = q1("SELECT id, tier, kind, importance, decay_rate, json_extract(metadata, '$.lm_directive_key') AS k "
    .. "FROM lm_memories WHERE scope = '" .. SCOPE .. "' AND title = 'Lua style — Locals'")
check("directive row: core tier, kind, never decays",
    tonumber(row.tier) == 3 and row.kind == "directive" and tonumber(row.decay_rate) == 0
        and tonumber(row.importance) == 1, ("tier=%s kind=%s dr=%s"):format(tostring(row.tier), tostring(row.kind),
        tostring(row.decay_rate)))
check("directive keyed by relpath#slug", row.k == "style/lua.md#lua-style/locals", row.k)
local r2 = directives.sync(ROOT) or {}
check("re-sync: all unchanged", r2.unchanged == 4 and r2.added == 0 and r2.updated == 0 and r2.removed == 0)

put("style/lua.md", "# Lua style\n## Locals\nDeclare every variable local, always.\n## Errors\nReturn nil, err for expected failures.\n")
local r3 = directives.sync(ROOT) or {}
local row2 = q1("SELECT id, body, tier FROM lm_memories WHERE scope = '" .. SCOPE .. "' AND title = 'Lua style — Locals'")
check("edited section updated in place", r3.updated == 1 and row2.id == row.id
    and row2.body == "Declare every variable local, always." and tonumber(row2.tier) == 3, r3.updated)

put("security.md", "# Security\n## Passwords\nUse a password manager for every credential.\n")
local r4 = directives.sync(ROOT) or {}
check("removed section pruned", r4.removed == 1 and ndir("standards") == 3, r4.removed)

put("testing.md", "# Testing\nEvery change ships with tests.\n")
local r5 = directives.sync(ROOT, { dry_run = true }) or {}
check("dry-run reports the plan, writes nothing",
    r5.added == 1 and r5.plan[1] and r5.plan[1].action == "add" and ndir("standards") == 3, r5.added)
local r6 = directives.sync(ROOT, { prune = false }) or {}
check("prune=false still adds", r6.added == 1 and ndir("standards") == 4)

local saved = directives.MAX_FILE_BYTES
directives.MAX_FILE_BYTES = 80          -- style/lua.md (~110 bytes) is now skipped by the walker
local okz, rz = pcall(directives.sync, ROOT)
directives.MAX_FILE_BYTES = saved
rz = (okz and rz) or {}
check("a skipped file is reported and its directives are NOT pruned",
    #(rz.errors or {}) > 0 and rz.prune_skipped ~= nil and rz.removed == 0 and ndir("standards") == 4,
    ("errors=%d removed=%s n=%d"):format(#(rz.errors or {}), tostring(rz.removed), ndir("standards")))

local other = TMP .. "/other.md"
local f = assert(io.open(other, "w")); f:write("# Incidents\nPage the on-call within 5 minutes.\n"); f:close()
local r7 = directives.sync(other) or {}
check("file root → source = file name", r7.source == "other" and r7.added == 1, r7.source)
directives.sync(ROOT)
check("sources never prune each other", ndir("other") == 1 and ndir("standards") == 4)
local function otag()
    return q1("SELECT json_extract(metadata, '$.project') AS p FROM lm_memories WHERE scope = '" .. SCOPE
        .. "' AND json_extract(metadata, '$.lm_directive_source') = 'other'").p
end
local r10 = directives.sync(other, { project = "api" }) or {}
check("project tag: the source's directives belong to that project (a new tag = an update)",
    r10.updated == 1 and r10.project == "api" and otag() == "api", r10.updated)
local r11 = directives.sync(other) or {}
check("no project → org-wide again", r11.updated == 1 and otag() == nil, r11.updated)
check("invalid project name refused", select(2, directives.sync(other, { project = "a b" })) ~= nil
    and ndir("other") == 1)

os.execute(("mkdir -p %q"):format(TMP .. "/empty"))
local r8, e8 = directives.sync(TMP .. "/empty", { source = "standards" })
check("empty path refused (nothing pruned)", r8 == nil and tostring(e8):find("no sections", 1, true)
    and ndir("standards") == 4, e8)
local r9 = directives.sync(TMP .. "/empty", { source = "standards", allow_empty = true }) or {}
check("allow_empty removes the whole source", r9.removed == 4 and ndir("standards") == 0 and ndir("other") == 1)
check("bad source name refused", directives.sync(ROOT, { source = "a b" }) == nil)
check("missing path refused", directives.sync(TMP .. "/nope.md") == nil)

-- Capability writes: identical sections in two files are two directives, and
-- ingesting never records retrieval misses.
put("dup/a.md", "# Dup\nIdentical rule text for both files.\n")
put("dup/b.md", "# Dup\nIdentical rule text for both files.\n")
directives.sync(ROOT .. "/dup")
check("identical sections → two directives (never merged)", ndir("dup") == 2, ndir("dup"))
check("directive ingest never records a retrieval miss",
    n("SELECT count(*) AS n FROM lm_reinforcements WHERE scope = '" .. SCOPE .. "' AND event_type = 'miss'") == 0)
os.execute(("rm -rf %q"):format(ROOT .. "/dup"))   -- keep the standards source at 4 below
local plain = store.update(row.id, { body = "tampered" })
check("a directive stays immutable without the capability", plain == nil)

luamemo.setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false,
                role = "solo" })
local rs, es = directives.sync(ROOT)
check("solo instance: directives refused", rs == nil and tostring(es):find("not an org central", 1, true), es)
org()
end)

-- ---------------------------------------------------------------------------
-- Org memories + aggregated feedback for C–E.
directives.sync(ROOT)                             -- standards: 4 directives
local NOTES = {}
for i, t in ipairs({ "password rotation notes", "review checklist draft", "local variable naming ideas",
                     "error handling examples", "testing tips collection", "credential storage howto" }) do
    local w = store.write({ scope = SCOPE, title = t, body = "collective note " .. i .. ": " .. t, importance = 0.5 })
    NOTES[i] = w and w.id
end
local agg     = require("luamemo.federation.aggregate")
local trainer = require("luamemo.rerank_train")
local PRIOR   = trainer.prior()
local BAD     = { bias = 0 }                      -- ranks by lowest tier/importance: buries directives
for _, name in ipairs(require("luamemo.rerankers.learned").FEATURES) do BAD[name] = 0 end
BAD.tier, BAD.importance = -5, -5

section("C gate", function()
io.write("\n--- C: directives gate ---\n")
local probes = agg.directive_probes(SCOPE, {}, {})
check("a probe per retrievable directive", #probes >= 3, #probes)
local ok1, info1 = agg.directives_gate({ scope = SCOPE, candidate = PRIOR, incumbent = PRIOR, reuse = {}, opts = {} })
check("candidate equal to the incumbent passes", ok1 == true, info1)
check("gate reports directive recall", tostring(info1):find("directive recall@3", 1, true) ~= nil, info1)
local ok2, info2 = agg.directives_gate({ scope = SCOPE, candidate = BAD, incumbent = PRIOR, reuse = {}, opts = {} })
check("candidate that buries directives fails", ok2 == false, info2)
check("failure names the demoted directives", tostring(info2):find("demotes", 1, true) ~= nil, info2)
end)

-- Aggregated feedback, as devs' pushes land on the central.
local QUERIES = { "password rotation notes", "review checklist draft", "local variable naming ideas",
                  "error handling examples", "testing tips collection", "credential storage howto" }
local NOW = require("luamemo.util").now_us()
for i, id in ipairs(NOTES) do
    if id then
        local cands = { id }
        for j, o in ipairs(NOTES) do if j ~= i and o then cands[#cands + 1] = o end end
        assert(db.run("INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids, source, source_ref, created_at) "
            .. "VALUES (?, ?, ?, 'user:a@corp.io', ?, ?)", SCOPE, QUERIES[i], db.json(cands), "r" .. i, NOW))
        assert(db.run("INSERT INTO lm_reinforcements (memory_id, scope, event_type, delta, source, source_ref, "
            .. "created_at) VALUES (?, ?, 'praise', 0.5, 'user:a@corp.io', ?, ?)", id, SCOPE, "e" .. i, NOW))
    end
end

local real_train, real_loss = trainer.train, trainer.loss
local function with_trainer(candidate, fn)
    trainer.train = function() return candidate end
    trainer.loss  = function(w) return (w == candidate) and 0.1 or 0.5 end   -- candidate always beats the loss gate
    local ok, err = pcall(fn)
    trainer.train, trainer.loss = real_train, real_loss
    if not ok then error(err, 0) end
end
local function reset_weights() db.run("DELETE FROM lm_learner_weights WHERE scope = ?", SCOPE) end
local promote = require("luamemo.promote")
local BASE = { min_samples = 2, gate_frac = 0.5 }
local function opts(extra) local o = {} for k, v in pairs(BASE) do o[k] = v end for k, v in pairs(extra) do o[k] = v end return o end
local function last_run() return q1("SELECT decision, note FROM lm_promotion_runs WHERE scope = '" .. SCOPE .. "' ORDER BY id DESC LIMIT 1") end

section("D gates", function()
io.write("\n--- D: promote.run pluggable gates ---\n")
local cand = {}; for k, v in pairs(PRIOR) do cand[k] = v end; cand.reuse = 0.1
with_trainer(cand, function()
    local r1 = promote.run(SCOPE, opts({ gates = { { name = "nope", fn = function() return false, "not today" end } } }))
    check("failing gate → reject", r1.decision == "reject" and tostring(r1.reason):find("nope gate failed: not today", 1, true),
        tostring(r1.decision) .. " " .. tostring(r1.reason))
    check("rejected run audited with the gate reason", last_run().decision == "reject"
        and tostring(last_run().note):find("nope gate", 1, true) ~= nil, last_run().note)
    check("nothing promoted", require("luamemo.learner_store").current_version(SCOPE, "reranker") == nil)
    local r2 = promote.run(SCOPE, opts({ gates = { { name = "boom", fn = function() error("kaput") end } } }))
    check("raising gate fails closed", r2.decision == "reject" and tostring(r2.reason):find("gate error", 1, true),
        r2.reason)
    local r3 = promote.run(SCOPE, opts({ dry_run = true, gates = { { name = "nope", fn = function() return false end } } }))
    check("dry-run with a failing gate → would-reject", r3.decision == "would-reject", r3.decision)
    local r4 = promote.run(SCOPE, opts({ gates = { { name = "yes", fn = function() return true, "fine" end } } }))
    check("passing gates → promote", r4.decision == "promote" and r4.version ~= nil and r4.gates
        and r4.gates[1].pass == true, r4.decision)
end)
check("training / gating searches never log retrieval feedback",
    n("SELECT count(*) AS n FROM lm_retrieval_feedback WHERE scope = '" .. SCOPE .. "'") == #NOTES)
reset_weights()
end)

section("E aggregate", function()
io.write("\n--- E: aggregate.run ---\n")
luamemo.setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false,
                role = "solo" })
check("solo instance: aggregate refused", agg.run() == nil)
org()
local r
with_trainer(BAD, function() r = agg.run({ min_samples = 2 }) end)
r = r or {}
local p = r.promotion or {}
check("report: feedback aggregated across devs",
    r.feedback and r.feedback.events == #NOTES and r.feedback.retrievals == #NOTES and r.feedback.devs == 1,
    r.feedback and (r.feedback.events .. "/" .. r.feedback.retrievals .. "/" .. r.feedback.devs))
check("report: digest ran on the org scope", type(r.digest) == "table" and r.digest.skipped == nil)
check("directives gate rejects a reranker that buries directives",
    p.decision == "reject" and tostring(p.reason):find("directives gate failed", 1, true), tostring(p.reason))
check("nothing distributed to devs", require("luamemo.learner_store").current_version(SCOPE, "reranker") == nil)
local cand = {}; for k, v in pairs(PRIOR) do cand[k] = v end; cand.reuse = 0.1
local r2
with_trainer(cand, function() r2 = agg.run({ min_samples = 2 }) end)
local p2 = (r2 or {}).promotion or {}
check("a reranker that keeps directives in place is promoted",
    p2.decision == "promote" and p2.gates and p2.gates[1].name == "directives" and p2.gates[1].pass, p2.reason)
check("directives untouched by the digest", ndir("standards") == 4 and n("SELECT count(*) AS n FROM lm_memories "
    .. "WHERE scope = '" .. SCOPE .. "' AND tier = 3 AND decay_rate <> 0") == 0)
local body0 = q1("SELECT body FROM lm_memories WHERE scope = '" .. SCOPE .. "' AND title = 'Lua style — Locals'").body
local re = store.reembed_scope(SCOPE) or {}
check("central: reembed (after an embedder switch) covers the directives",
    (re.updated or 0) > 0 and #(re.errors or { 1 }) == 0, re.errors and re.errors[1] and re.errors[1].err)
check("reembed preserved directive content + tier", ndir("standards") == 4
    and q1("SELECT body FROM lm_memories WHERE scope = '" .. SCOPE .. "' AND title = 'Lua style — Locals'").body == body0)
reset_weights()
end)

-- ---------------------------------------------------------------------------
section("F cli", function()
io.write("\n--- F: memo org (org central) ---\n")
local sh = H.sh
local env = ("MEMO_EMBEDDER=hash MEMO_LUA=%q MEMO_ROLE=org MEMO_ORG_NAME=fedagg MEMO_FEDERATION_DIR=%q ")
    :format(lua_bin, TMP .. "/keyring")
local o1, c1 = sh(env .. "./cli/memo org status")
check("org status", c1 == 0 and o1:find("org central", 1, true) and o1:find(SCOPE, 1, true)
    and o1:find("t3=", 1, true) and o1:find("devices:", 1, true), o1)
local o2, c2 = sh(env .. ("./cli/memo org directives %q --dry-run"):format(ROOT))
check("org directives --dry-run", c2 == 0 and o2:find("would:", 1, true), o2)
local o2b, c2b = sh(env .. ("./cli/memo org directives %q --dry-run --project portal"):format(ROOT))
check("org directives --project", c2b == 0 and o2b:find("project: *portal") ~= nil, o2b)
local o3, c3 = sh(env .. "./cli/memo org aggregate --dry-run --min-samples 2")
check("org aggregate --dry-run", c3 == 0 and o3:find("reranker:", 1, true) and o3:find("feedback:", 1, true), o3)
local _, c4 = sh(env .. "./cli/memo org directives")
check("org directives without a path → exit 2", c4 == 2, c4)
local _, c5 = sh(env .. "./cli/memo org pull")
check("dev subcommand on an org central → exit 2", c5 == 2, c5)
end)

-- ---------------------------------------------------------------------------
wipe()
os.execute(("rm -rf %q"):format(TMP))
finish()
