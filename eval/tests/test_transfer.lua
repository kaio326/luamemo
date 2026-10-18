-- eval/tests/test_transfer.lua
-- Phase 14.5 — keeping and moving memories: memo backup, memo export / memo import,
-- memo reembed --all.
--   A. backup: a consistent 0600 copy (default <data dir>/backups/, 0700) that opens
--      and holds the rows; an existing target needs --force; the database itself is
--      never replaced, not even with --force or through a symlink; --db
--   B. export → import (luamemo.transfer): same embedder → vectors reused bit for bit;
--      timestamps exact; tier / importance / decay / kind / tags / metadata kept;
--      facts carried, their memory remapped; a second import adds nothing; an export
--      of the target itself is refused; another embedder → embedded again; an org
--      replica isn't exported by default
--   C. one memory per line from any tool: --scope for lines without one; created_at
--      as epoch seconds / ISO; bad lines reported by number while the rest go in;
--      JSON nulls; dedup skip; a dry run writes nothing; the CLI's exit code
--   D. reembed --all: the database moves to another vector size once every scope is
--      re-embedded; an org replica is left to its sync (it follows the embedder)
-- Uses the run's database (MEMO_DB) and further SQLite files (H.create_db).
-- Run: luajit eval/tests/run.lua --only transfer

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Transfer")
local check, section, finish = T.check, T.section, T.finish
local sh, mode = H.sh, H.mode

local luamemo  = require("luamemo")
local db       = require("luamemo.db")
local json     = require("luamemo.json")
local util     = require("luamemo.util")
local transfer = require("luamemo.transfer")

local MAIN = assert(os.getenv("MEMO_DB"), "run it with eval/tests/run.lua (MEMO_DB)")
local lua_bin = H.lua_bin()
local TMP = os.tmpname(); os.remove(TMP); os.execute(("mkdir -p %q"):format(TMP))

-- Work on database `path` with the hash embedder at `dim` (extra: more config).
local function use(path, dim, extra)
    local cfg = { db = path, embedder_local = "hash", embed_dim = dim or 384, skip_embed_probe = true,
                  patterns_enabled = false }
    for k, v in pairs(extra or {}) do cfg[k] = v end
    luamemo.setup(cfg)
end
local function lines_of(t) local i = 0; return function() i = i + 1; return t[i] end end
local function memo(env, args) return sh(("%s MEMO_EMBEDDER=hash MEMO_LUA=%q ./cli/memo %s"):format(env, lua_bin, args)) end

-- ---------------------------------------------------------------------------
section("A backup", function()
io.write("\n--- A: memo backup ---\n")
use(MAIN)
for i = 1, 3 do assert(luamemo.store.write({ scope = "repo:bk", title = "kept " .. i, body = "backed up row " .. i })) end
local total = tonumber(db.value("SELECT count(*) FROM lm_memories"))
local env = ("MEMO_DB=%q"):format(MAIN)
local out, code = memo(env, "backup")
local path = out:match("backup:%s+(%S+)")
check("backup: default place, in the data directory's backups/", code == 0 and path ~= nil
    and path:find(db.data_dir() .. "/backups/", 1, true) == 1, out)
check("backup: the copy is 0600, its directory 0700", path and mode(path) == "600"
    and mode(db.data_dir() .. "/backups") == "700", path and mode(path))
local b = path and db.open(path, { readonly = true })
check("backup: a luamemo database holding every row", b and tonumber(b.value("SELECT count(*) FROM lm_memories")) == total
    and out:find("memories:  " .. total, 1, true) ~= nil, out)
if b then b.close() end
local target = TMP .. "/b1.db"
local o1, c1 = memo(env, ("backup %q"):format(target))
local o2, c2 = memo(env, ("backup %q"):format(target))
check("backup PATH; an existing file is not replaced without --force", c1 == 0 and c2 == 1
    and o2:find("exists", 1, true) ~= nil, o1 .. o2)
local o3, c3 = memo(env, ("backup %q --force"):format(target))
check("… and is with --force", c3 == 0, o3)
local o4, c4 = memo(env, ("backup %q --force"):format(MAIN))
os.execute(("ln -s %q %q"):format(MAIN, TMP .. "/alias.db"))
local o5, c5 = memo(env, ("backup %q --force"):format(TMP .. "/alias.db"))
check("the database itself is never the target (not even with --force, nor through a symlink)",
    c4 == 1 and o4:find("is the database itself", 1, true) ~= nil and c5 == 1
    and o5:find("is the database itself", 1, true) ~= nil
    and tonumber(db.value("SELECT count(*) FROM lm_memories")) == total, o4 .. o5)
local other = H.create_db("tr_bk_other")
local o6, c6 = memo(env, ("backup %q --db %q"):format(TMP .. "/other.db", other))
check("--db backs up another database", c6 == 0 and o6:find("memories:  0", 1, true) ~= nil, o6)
end)

-- ---------------------------------------------------------------------------
local SRC, LINES = nil, {}
section("B export / import", function()
io.write("\n--- B: export → import ---\n")
SRC = H.create_db("tr_src")
use(SRC)
local store, kg = luamemo.store, require("luamemo.kg")
local a = assert(store.write({ scope = "repo:tr", kind = "decision", title = "use SQLite", body = "one file per project",
    tags = { "db", "storage" }, metadata = { why = "no server", n = 3 }, importance = 7, decay_rate = 0.05, tier = 2,
    created_at = 1700000000.25 }))
local bm = assert(store.write({ scope = "repo:tr", title = "second", body = "another memory", importance = 2 }))
assert(store.update(bm.id, { body = "another memory, edited" }))
assert(store.write({ scope = "user:tr", title = "personal", body = "a personal preference" }))
assert(kg.assert_fact({ scope = "repo:tr", subject = "luamemo", predicate = "stores_in", object = "sqlite",
    source_memory_id = a.id }))
-- an org replica (this machine as a dev) is never exported by default: it re-syncs
use(SRC, 384, { role = "dev", org_url = "http://127.0.0.1:1", org_fingerprint = "0000-0000-0000-0000-0000" })
assert(store.replica_upsert("org:tr", { id = 9, title = "org row", body = "from the central", tier = 2,
    updated_us = "1700000000000000" }, nil, require("luamemo.federation.policy").capability("replica")))

local rep = assert(transfer.export(function(l) LINES[#LINES + 1] = l end))
use(SRC, 384, { role = "solo" })
local hdr = json.decode(LINES[1]) or {}
check("export: a header, then 3 memories and 1 fact (the org replica left out)", hdr.luamemo_export == 1
    and rep.memories == 3 and rep.facts == 1 and #LINES == 5 and table.concat(rep.scopes, ","):find("org:", 1, true) == nil,
    json.encode(rep))
check("export: the header names the database and its embedder", hdr.db_id == db.value("SELECT value FROM lm_meta "
    .. "WHERE key = 'db_id'") and hdr.embedder_sig == "hash||384" and hdr.embed_dim == 384, LINES[1])

local DST = H.create_db("tr_dst")
use(DST)
local r1 = transfer.import(lines_of(LINES), {})
check("import: 3 memories + 1 fact, every vector reused", r1.memories == 3 and r1.facts == 1 and r1.vectors_reused == 3
    and r1.embedded == 0 and r1.error_count == 0, json.encode(r1))
local function row(path, title)
    local c = assert(db.open(path, { readonly = true }))
    local r = c.first("SELECT * FROM lm_memories WHERE title = ?", title)
    c.close()
    return r or {}
end
local s1, d1 = row(SRC, "use SQLite"), row(DST, "use SQLite")
check("kept: kind, tier, importance, decay, tags, metadata", d1.kind == "decision" and d1.tier == 2
    and d1.importance == 7 and math.abs(d1.decay_rate - 0.05) < 1e-9 and type(d1.tags) == "table" and d1.tags[2] == "storage"
    and type(d1.metadata) == "table" and d1.metadata.why == "no server" and d1.metadata.n == 3, json.encode(d1.metadata))
check("kept: created_at / updated_at to the microsecond", d1.created_at == s1.created_at and d1.created_at == 1700000000250000
    and row(DST, "second").updated_at == row(SRC, "second").updated_at, ("%s / %s"):format(tostring(d1.created_at),
    tostring(s1.created_at)))
check("kept: the vector, bit for bit", type(d1.embedding) == "string" and d1.embedding == s1.embedding)
local f = db.first("SELECT * FROM lm_kg_facts WHERE subject = 'luamemo'") or {}
check("the fact names the IMPORTED memory", f.object == "sqlite" and f.source_memory_id == d1.id, json.encode(f))
local r2 = transfer.import(lines_of(LINES), {})
check("a second import adds nothing", r2.memories == 0 and r2.already == 3 and r2.facts == 0 and r2.facts_present == 1
    and tonumber(db.value("SELECT count(*) FROM lm_memories")) == 3, json.encode(r2))
use(SRC)
local r3 = transfer.import(lines_of(LINES), {})
check("an export of this very database is refused", r3.memories == 0 and r3.error_count == 1
    and tostring(r3.errors[1]):find("this very database", 1, true) ~= nil, json.encode(r3.errors))

local D256 = H.create_db("tr_d256")
use(D256, 256)
local r4 = transfer.import(lines_of(LINES), {})
local v = row(D256, "use SQLite").embedding
check("another embedder (256 dimensions) → every memory embedded again", r4.memories == 3 and r4.vectors_reused == 0
    and r4.embedded == 3 and type(v) == "string" and #v == 256 * 4, json.encode(r4))
end)

-- ---------------------------------------------------------------------------
section("C one memory per line", function()
io.write("\n--- C: JSON Lines from any tool ---\n")
local GEN = H.create_db("tr_gen")
use(GEN)
local file = {
    '{"title": "a", "body": "generic one"}',
    '{"scope": "repo:gen", "title": "b", "body": "with epoch seconds", "created_at": 1700000000}',
    '{"scope": "repo:gen", "title": "c", "body": "with an ISO time", "created_at": "2024-05-06T07:08:09Z"}',
    'not json',
    '{"type": "weird"}',
    '{"scope": "repo:gen", "title": "d", "body": "nulls everywhere", "tags": null, "metadata": null, "tier": null}',
    '{"title": "", "body": ""}',
    '{"scope": "repo:gen", "title": "e", "body": "bad time", "created_at": "yesterday"}',
}
local dry = transfer.import(lines_of(file), { scope = "repo:gen", dry_run = true })
check("dry run: counts, writes nothing", dry.memories == 4 and dry.error_count == 4
    and tonumber(db.value("SELECT count(*) FROM lm_memories")) == 0, json.encode(dry))
local r = transfer.import(lines_of(file), { scope = "repo:gen" })
local errs = table.concat(r.errors, " | ")
check("4 lines in, 4 reported by line number", r.memories == 4 and r.error_count == 4
    and errs:find("line 4:", 1, true) and errs:find("line 5:", 1, true) and errs:find("line 7:", 1, true)
    and errs:find("line 8: created_at", 1, true), errs)
local function c_at(t) return db.value("SELECT created_at FROM lm_memories WHERE title = ?", t) end
check("--scope for a line without one; created_at as seconds or ISO", db.value("SELECT scope FROM lm_memories "
    .. "WHERE title = 'a'") == "repo:gen" and c_at("b") == 1700000000 * 1000000
    and c_at("c") == util.iso_to_us("2024-05-06T07:08:09Z"), ("%s %s"):format(tostring(c_at("b")), tostring(c_at("c"))))
local s = transfer.import(lines_of(file), { scope = "repo:gen", dedup = "skip" })
check("dedup skip: the same lines again are skipped as duplicates", s.memories == 0 and s.skipped == 4
    and tonumber(db.value("SELECT count(*) FROM lm_memories")) == 4, json.encode(s))
-- Lines as Postgres' row_to_json prints an older luamemo's rows (the upgrade recipe in the
-- README): no header; a fact names its memory by the old id.
use(H.create_db("tr_pg"))
local pg = transfer.import(lines_of({
    '{"id": 17, "scope": "repo:pg", "kind": "decision", "title": "Cache uses LRU", "body": "Evict the least '
        .. 'recently used.", "tags": ["cache"], "metadata": {"phase": 5}, "importance": 3, "decay_rate": 0, '
        .. '"created_at": "2026-05-01T10:00:00.123456+00:00", "updated_at": "2026-05-02T08:30:00.5+00:00"}',
    '{"type": "fact", "scope": "repo:pg", "subject": "cache", "predicate": "policy", "object": "lru", '
        .. '"valid_from": "2026-05-01T10:00:00+00:00", "valid_until": null, "memory": 17}',
}), {})
local pm = db.first("SELECT id, kind, created_at, updated_at FROM lm_memories WHERE scope = 'repo:pg'") or {}
check("Postgres-shaped lines: kind, µs timestamps with a +00:00 zone", pg.memories == 1 and pg.facts == 1
    and pm.kind == "decision" and pm.created_at == util.iso_to_us("2026-05-01T10:00:00.123456Z")
    and pm.updated_at == util.iso_to_us("2026-05-02T08:30:00.5Z"), json.encode(pg))
check("… and a fact keeps its memory without a header (the line's id links them)",
    db.value("SELECT source_memory_id FROM lm_kg_facts WHERE scope = 'repo:pg'") == pm.id, json.encode(pg))
-- A dev's org: scope is the org's read-only replica: an imported fact there (memo kg add
-- refuses it) was inserted, and searches reported it as the org's current truth.
use(H.create_db("tr_dev"), 384, { role = "dev", org_url = "http://127.0.0.1:1",
    org_fingerprint = "0000-0000-0000-0000-0000" })
local planted = transfer.import(lines_of({
    '{"type": "fact", "scope": "org:acme", "subject": "payments", "predicate": "approved_vendor", "object": "x"}',
    '{"type": "fact", "scope": "repo:own", "subject": "cache", "predicate": "policy", "object": "lru"}',
}), {})
check("import: a fact for the org's read-only replica is refused (by line); one for the project's scope is in",
    planted.facts == 1 and planted.error_count == 1 and table.concat(planted.errors, " "):find("read-only", 1, true)
    and tonumber(db.value("SELECT count(*) FROM lm_kg_facts WHERE scope = 'org:acme'")) == 0, json.encode(planted))
use(GEN)   -- (role solo again: no org_url)
local path = TMP .. "/bad.jsonl"
local fh = assert(io.open(path, "w")); fh:write('{"scope": "repo:cli", "title": "x", "body": "via the CLI"}\n{oops\n'); fh:close()
local out, code = memo("", ("import %q --db %q"):format(path, GEN))
check("CLI: a failed line → exit 1, the line named, the good one in", code == 1 and out:find("line 2:", 1, true) ~= nil
    and out:find("added:     1 memories", 1, true) ~= nil, out)
local o2, c2 = memo("", ("import --db %q -"):format(GEN) .. " </dev/null")
check("CLI: reads stdin with -", c2 == 0 and o2:find("added:     0 memories", 1, true) ~= nil, o2)
local xp = TMP .. "/x.jsonl"
local xf = assert(io.open(xp, "w")); xf:close()
os.execute(("chmod 644 %q"):format(xp))
local o3, c3 = memo("", ("export --db %q --out %q"):format(GEN, xp))
check("CLI: export --out leaves the file 0600 (it holds memories), even one that existed",
    c3 == 0 and mode(xp) == "600" and o3:find("exported 5 memories", 1, true) ~= nil, o3 .. " " .. tostring(mode(xp)))
end)

-- ---------------------------------------------------------------------------
section("D reembed --all", function()
io.write("\n--- D: memo reembed --all ---\n")
local DIM = H.create_db("tr_dim")
use(DIM, 384, { role = "dev", org_url = "http://127.0.0.1:1", org_fingerprint = "0000-0000-0000-0000-0000" })
local store = luamemo.store
assert(store.write({ scope = "repo:one", title = "one", body = "first scope" }))
assert(store.write({ scope = "user:two", title = "two", body = "second scope" }))
require("luamemo.consolidate").process("repo:one")   -- an observation in repo:one's vector space
local cap = require("luamemo.federation.policy").capability("replica")
assert(store.replica_upsert("org:dim", { id = 1, title = "org", body = "replica row", tier = 2,
    updated_us = "1700000000000000" }, nil, cap))
local env = ("MEMO_DB=%q MEMO_EMBED_DIM=256 MEMO_ORG_URL=http://127.0.0.1:1 MEMO_ORG_FINGERPRINT=0000-0000-0000-0000-0000")
    :format(DIM)
local out = memo(env, "reembed --all")
local res = json.decode(out) or {}   -- (out alone: memo() also returns the exit code)
local scopes = {}
for _, x in ipairs(res.results or {}) do scopes[x.scope] = x end
local function dim() return tonumber(db.value("SELECT value FROM lm_meta WHERE key = 'embed_dim'")) end
check("every scope re-embedded but the org replica", res.ok == true and scopes["repo:one"] and scopes["user:two"]
    and not scopes["org:dim"], out)
check("… the replica still holds the old size: the database waits", dim() == 384, dim())
-- observations share the scope's vector space: they kept the old one (never found again)
check("… and the scope's observations are re-embedded too (the new size)",
    ((scopes["repo:one"] or {}).result or {}).observations == 1
    and tonumber(db.value("SELECT length(embedding) FROM lm_observations WHERE scope = 'repo:one'")) == 1024,
    json.encode(scopes["repo:one"]))
-- the replica follows the configured embedder on its next sync (the store side of it)
use(DIM, 256, { role = "dev", org_url = "http://127.0.0.1:1", org_fingerprint = "0000-0000-0000-0000-0000" })
local id, act = store.replica_upsert("org:dim", { id = 1, title = "org", body = "replica row", tier = 2,
    updated_us = "1700000000000001" }, nil, cap, { force = true })
check("the replica re-syncs at the new size although the database holds the old one", id ~= nil, act)
check("… and then the database moves to it", store.finish_switch(256) == true and dim() == 256
    and tonumber(db.value("SELECT count(*) FROM lm_memories WHERE length(embedding) != 1024")) == 0, dim())
check("writes at the new size work again", store.write({ scope = "repo:one", title = "new", body = "after" }) ~= nil)
local bad = json.decode((memo(("MEMO_DB=%q"):format(DIM), "reembed"))) or {}
check("reembed with neither --scope nor --all → an error naming both", bad.ok == false
    and tostring(bad.error):find("scope required (or all)", 1, true) ~= nil, json.encode(bad))
end)

H.drop_dbs()
os.execute(("rm -rf %q"):format(TMP))
finish()
