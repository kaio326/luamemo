-- eval/tests/test_storage.lua
-- The SQLite storage core (Phase 14.3):
--   1. Rows: text timestamps, boolean was_truncated, decoded JSON, the schema's
--      triggers (FTS kept in step — integrity-checked —, retrieval candidates).
--   2. Text search: stopwords indexed as a placeholder, plainto_tsquery-like queries,
--      metadata filters compared as text, org: scope prefixes case-sensitive.
--   3. Embedder input too long: shortened and retried, the row kept (truncated),
--      text-only when even the shortest try fails — never lost; write / write_many /
--      update / reembed; other embedder errors still fail.
--   4. One embedding space per database: another dimension is refused, `reembed`
--      moves the database to it once every scope is re-embedded.
--   5. Database files: a name lives in the data directory (0700), files are 0600.
--   6. The vault: encrypted at rest, a value bound to its name, internal secrets,
--      a separate store file (the keyring), two processes storing at once.
-- Run: MEMO_DB=/tmp/x.db luajit eval/tests/test_storage.lua   (the runner sets MEMO_DB)

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Storage")
local check, section = T.check, T.section

if not os.getenv("MEMO_DB") or os.getenv("MEMO_DB") == "" then
    io.write("[SKIP] MEMO_DB not set\n"); T.finish()
end

local lm    = require("luamemo")
local db    = require("luamemo.db")
local store = require("luamemo.store")
local embed = require("luamemo.embed")
local fts   = require("luamemo.fts")
local util  = require("luamemo.util")
local json  = require("luamemo.json")

local function setup(extra)
    local cfg = { embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false }
    for k, v in pairs(extra or {}) do cfg[k] = v end
    lm.setup(cfg)
end
setup()
local function count(sql, ...) return tonumber((db.value(sql, ...))) end
local function fts_ok() return db.run("INSERT INTO lm_memories_fts (lm_memories_fts, rank) VALUES ('integrity-check', 0)") ~= nil end

section("rows and triggers", function()
    io.write("\n--- rows and triggers ---\n")
    local r = assert(store.write({ scope = "st", title = "Database choice", body = "The backend uses SQLite.",
        tags = { "db" }, metadata = { project = "p1", n = 5 } }))
    check("timestamps come back as text", type(r.created_at) == "string"
        and r.created_at:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.%d%d%d%d%d%d%+00$") ~= nil, r.created_at)
    check("was_truncated is a boolean", r.was_truncated == false)
    check("JSON columns come back decoded", type(r.tags) == "table" and r.tags[1] == "db"
        and type(r.metadata) == "table" and r.metadata.n == 5)
    local old = assert(store.write({ scope = "st", title = "Old", body = "an older memory", created_at = os.time() - 40 * 86400 }))
    check("created_at (epoch seconds) is honoured", old.created_at:sub(1, 10) == os.date("!%Y-%m-%d", os.time() - 40 * 86400))
    local before = db.value("SELECT updated_at FROM lm_memories WHERE id = ?", r.id)
    db.run("UPDATE lm_memories SET importance = 2 WHERE id = ?", r.id)
    check("an UPDATE that leaves updated_at alone moves it forward (touch trigger)",
        db.value("SELECT updated_at FROM lm_memories WHERE id = ?", r.id) > before)
    -- SQLite's clock ticks in milliseconds: a µs time written a moment ago can be ahead of it.
    local ahead = util.now_us() + 5000000
    db.run("UPDATE lm_memories SET updated_at = ? WHERE id = ?", ahead, r.id)
    db.run("UPDATE lm_memories SET importance = 3 WHERE id = ?", r.id)
    check("… never backwards, even when the stored time is ahead of SQLite's clock",
        db.value("SELECT updated_at FROM lm_memories WHERE id = ?", r.id) == ahead + 1)
    db.run("UPDATE lm_memories SET updated_at = 1000 WHERE id = ?", r.id)
    check("… and an explicit updated_at is kept", db.value("SELECT updated_at FROM lm_memories WHERE id = ?", r.id) == 1000)
    store.update(r.id, { body = "The backend uses SQLite now, not Postgres." })
    store.delete(old.id)
    check("FTS index consistent after update + delete", fts_ok())
    local hits = store.search({ scope = "st", query = "postgres", skip_observations = true, skip_feedback = true }) or {}
    check("updated text is searchable", hits[1] and hits[1].id == r.id)
    -- retrieval candidates mirror the JSON array (trigger), and go with their event
    assert(db.run("INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids, created_at) VALUES (?, ?, ?, ?)",
        "st", "q", db.json({ r.id, 999 }), util.now_us()))
    check("candidates indexed by the trigger, in rank order",
        db.value("SELECT group_concat(memory_id) FROM (SELECT memory_id FROM lm_retrieval_candidates ORDER BY rank)")
            == tostring(r.id) .. ",999")
    db.run("DELETE FROM lm_retrieval_feedback")
    check("… and deleted with their event", count("SELECT count(*) FROM lm_retrieval_candidates") == 0)
    -- A time past what os.date shows (a nanosecond count as seconds: 1.8e18) was stored, and
    -- every read of the scope then raised; a millisecond count gave a 5-digit year.
    local before_n = count("SELECT count(*) FROM lm_memories WHERE scope = 'st'")
    local bad = {}
    for _, at in ipairs({ "1e17", 1.76e12, "0999-12-31", -62135596800 }) do
        local w, e = store.write({ scope = "st", title = "backdated", body = "far", created_at = at })
        if w or not tostring(e):find("out of range", 1, true) then bad[#bad + 1] = tostring(at) .. ": " .. tostring(e) end
    end
    check("a time outside years 1000–9999 is refused, nothing stored", #bad == 0
        and count("SELECT count(*) FROM lm_memories WHERE scope = 'st'") == before_n, table.concat(bad, " | "))
    db.run("UPDATE lm_memories SET created_at = 1e17 * 1000000 WHERE id = ?", r.id)   -- an older database's row
    local okr, rr = pcall(store.recent, { scope = "st" })
    local oks = pcall(store.search, { scope = "st", query = "sqlite", skip_feedback = true })
    check("… and one already stored no longer breaks reading the scope", okr and oks and type(rr) == "table", tostring(rr))
    db.run("UPDATE lm_memories SET created_at = ? WHERE id = ?", util.now_us(), r.id)
    -- A near-duplicate merges only within its band: tier 0 (the hooks' raw conversation) or
    -- tier ≥ 1. A decision merged into a tier-0 chunk stayed tier 0 — hidden from search,
    -- then purged by the digest; a chunk merged into a memory overwrote its text.
    local qtext = "We use PostgreSQL for the job queue because it is already deployed"
    local raw = assert(store.write({ scope = "band", title = "Queue choice", body = qtext, tier = 0 }))
    local dec, _, dact = store.write({ scope = "band", kind = "decision", title = "Queue choice", body = qtext, importance = 5 })
    check("a decision like a tier-0 chunk is its own memory (tier ≥ 1), not merged into the chunk",
        dec and dact == "inserted" and dec.id ~= raw.id and dec.tier >= 1, json.encode({ dact, dec and dec.tier }))
    local _, _, hact = store.write({ scope = "band", title = "Periodic save", body = qtext, tier = 0, importance = 0.4 })
    check("… and a chunk like a decision leaves the decision's text alone", hact ~= "merged" or
        db.value("SELECT body FROM lm_memories WHERE id = ?", dec.id) == qtext, hact)
    local many = store.write_many({ { scope = "band", kind = "decision", title = "Queue choice", body = qtext .. ".",
        importance = 5 } })
    check("… write_many: the same (a decision merges into the decision, not the chunk)",
        many[1].row and many[1].row.tier >= 1, json.encode(many[1].action))
    db.run("DELETE FROM lm_memories WHERE scope = 'band'")
    -- A delete by filter with no scope (kind alone): the clean-up of what was derived from the
    -- rows bound one parameter too many and raised, after they were gone.
    assert(store.write({ scope = "k1", kind = "zzkind", title = "a", body = "alpha one" }))
    assert(store.write({ scope = "k2", kind = "zzkind", title = "b", body = "beta two" }))
    local okd, nd = pcall(store.delete_where, { kind = "zzkind" })
    check("a delete by kind alone (every scope) works", okd and nd == 2, tostring(nd))
    -- update: an empty scope or kind is no change (scope "" moved the memory where only its id found it)
    local moved = store.update(r.id, { scope = "", kind = "" })
    check("update with scope = \"\" / kind = \"\" leaves both as they were", moved and moved.scope == "st"
        and moved.kind == r.kind, moved and json.encode({ moved.scope, moved.kind }))
end)

section("text search", function()
    io.write("\n--- text search ---\n")
    check("stopwords become a placeholder (positions kept)", fts.doc_text("The cat", "is here") == "zzstopzz cat zzstopzz zzstopzz")
    check("a query of stopwords has no match expression", fts.match_query("the of and") == nil)
    check("query words are quoted, all required", fts.match_query('Deploy "pipeline" OR x*') == '"deploy" "pipeline" "x"')
    -- the allocation-free ranker equals the reference on any input (positions past the
    -- cap, >256 occurrences, several terms at one position, out-of-order input)
    math.randomseed(7)
    local mismatches = 0
    for trial = 1, 3000 do
        local nterms, inst, seen = math.random(1, 6), {}, {}
        local maxoff = trial % 7 == 0 and 20000 or 300
        for _ = 1, math.random(0, trial % 50 == 0 and 900 or 40) do
            local t, o = math.random(0, nterms - 1), math.random(0, maxoff)
            if not seen[t .. ":" .. o] then seen[t .. ":" .. o] = true; inst[#inst + 1] = { t, o } end
        end
        if trial % 10 ~= 0 then
            table.sort(inst, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
        end
        local x = { phrase_count = function() return nterms end, inst_count = function() return #inst end,
                    inst = function(_, i) return inst[i + 1][1], 0, inst[i + 1][2] end }
        if fts._ts_cd(x) ~= fts._ts_cd_tables(x) then mismatches = mismatches + 1 end
    end
    check("fast ts_cd = reference on 3000 random inputs", mismatches == 0, mismatches)
    local a = assert(store.write({ scope = "ts", title = "n as number", body = "release notes alpha", metadata = { n = 7 } }))
    store.write({ scope = "ts", title = "n as text", body = "release notes beta", metadata = { n = "8" } })
    local f = store.search({ scope = "ts", query = "release notes", metadata_filter = { n = "7" },
        skip_observations = true, skip_feedback = true }) or {}
    check("metadata filter compares as text (number 7 matches '7')", #f == 1 and f[1].id == a.id, #f)
    -- (text that isn't a number is compared in the form the path index answers — same rows)
    local p = assert(store.write({ scope = "ts", title = "path row", body = "release notes gamma",
        metadata = { path = "src/a.lua", flag = true, other = "src/a.lua" } }))
    local function ids(mf)
        local out = {}
        for _, r in ipairs(store.search({ scope = "ts", query = "release notes", metadata_filter = mf,
            skip_observations = true, skip_feedback = true }) or {}) do out[#out + 1] = r.id end
        return table.concat(out, ",")
    end
    check("a text filter matches that text at that key only (not a boolean, not another key)",
        ids({ path = "src/a.lua" }) == tostring(p.id) and ids({ flag = "true" }) == ""
        and ids({ path = "src/b.lua" }) == "" and ids({ flag = true }) == tostring(p.id),
        ids({ path = "src/a.lua" }) .. " / " .. ids({ flag = "true" }))
    -- org: scopes are matched case-sensitively, like Postgres LIKE (SQLite's LIKE isn't)
    check("GLOB 'org:*' does not match 'ORG:x'", db.value("SELECT 'ORG:x' GLOB 'org:*'") == 0
        and db.value("SELECT 'org:x' GLOB 'org:*'") == 1)
end)

section("embedder input too long", function()
    io.write("\n--- embedder input too long ---\n")
    local http = require("luamemo.http")
    local real_req, real_async = http.request, http.request_async
    local LIMIT, calls = 1000, 0
    local function fake(_, opts)
        calls = calls + 1
        local req = json.decode(opts.body)
        if #req.prompt > LIMIT then return 500, '{"error":"the input length exceeds the context length"}' end
        return 200, json.encode({ embedding = require("luamemo.embedders.hash").embed(req.prompt, { embed_dim = 384 }) })
    end
    http.request = fake
    http.request_async = function(url, opts) return fake(url, opts) end
    lm.setup({ embedder_local = false, embedder_url = "http://fake.invalid/api/embeddings", embedder_adapter = "ollama",
        embed_dim = 384, skip_embed_probe = true, patterns_enabled = false })
    lm.config.embedder_local = nil
    embed.configure(lm.config)
    embed._reset_known_fit()
    local long = ("word "):rep(600)            -- 3000 characters
    local r = store.write({ scope = "tl", title = "long", body = long })
    check("rejected as too long → shortened, retried, row kept with the full text", r and #r.body == #long)
    check("… flagged was_truncated, with a vector", r and r.was_truncated == true
        and db.value("SELECT embedding IS NOT NULL FROM lm_memories WHERE id = ?", r.id) == 1)
    calls = 0
    local r2 = store.write({ scope = "tl", title = "other", body = ("different words entirely "):rep(150) })
    check("the size that worked is remembered (next long text: one call)", r2 and calls == 1, calls)
    LIMIT = 100
    embed._reset_known_fit()
    calls = 0
    local r3 = store.write({ scope = "tl", title = "never fits", body = long })
    check("still rejected at the floor → kept text-only, with a warning", r3 and r3.warning
        and r3.warning:find("without a vector", 1, true) ~= nil
        and db.value("SELECT embedding IS NULL FROM lm_memories WHERE id = ?", r3.id) == 1)
    check("… within a bounded number of tries", calls <= embed.MAX_SHORTEN + 1, calls)
    local found = false
    for _, h in ipairs(store.search({ scope = "tl", query = "never fits", skip_observations = true, skip_feedback = true }) or {}) do
        if r3 and h.id == r3.id then found = true end
    end
    check("the text-only row is found by its words", found)
    local res = store.write_many({ { scope = "tl", title = "a", body = long }, { scope = "tl", title = "b", body = "short" } })
    check("write_many (concurrent embeds) keeps every row", res[1].row and res[1].row.warning and res[2].row
        and not res[2].row.warning)
    local res1 = store.write_many({ { scope = "tl", title = "c", body = long .. " c" } })
    check("write_many (one row) keeps it", res1[1].row and res1[1].row.warning)
    -- an update's SET list bound the missing vector as no parameter at all: every later
    -- one shifted, the id to NULL — "update: db error: nil", the edit lost
    local ru, eu = store.update(r.id, { body = long .. " edited" })
    check("an update whose text never fits is kept text-only too", ru and ru.warning
        and #ru.body == #long + 7 and ru.was_truncated == true
        and db.value("SELECT embedding IS NULL FROM lm_memories WHERE id = ?", r.id) == 1, eu)
    assert(db.run("INSERT INTO lm_observations (scope, body, embedding, emb_norm, last_reinforced, created_at) "
        .. "VALUES ('tl', ?, zeroblob(1536), 1.0, 0, 0)", long))
    local rl = store.reembed_scope("tl")
    check("… and reembed: every row kept, none left with its old vector (a size switch can end)",
        rl and #rl.errors == 0 and rl.updated == count("SELECT count(*) FROM lm_memories WHERE scope = 'tl'")
        and count("SELECT count(*) FROM lm_observations WHERE scope = 'tl' AND embedding IS NOT NULL") == 0,
        rl and json.encode(rl.errors))
    db.run("DELETE FROM lm_observations WHERE scope = 'tl'")
    LIMIT = 1000
    embed._reset_known_fit()
    local re = store.reembed_scope("tl")
    check("reembed keeps every row (and vectors return once they fit)", re and #re.errors == 0
        and count("SELECT count(*) FROM lm_memories WHERE scope = 'tl' AND embedding IS NULL") == 0)
    http.request = function() return 503, "service unavailable" end
    local r6, e6 = store.write({ scope = "tl", title = "x", body = "y" })
    check("any other embedder error still fails the write", r6 == nil and tostring(e6):find("503", 1, true) ~= nil)
    check("shortening cuts on a UTF-8 character boundary", (function()
        local cut = embed._halve(("é"):rep(400))
        return #cut % 2 == 0 and cut:sub(-2) == "é"
    end)())
    http.request, http.request_async = real_req, real_async
    setup()
end)

section("one embedding space per database", function()
    io.write("\n--- embedding dimension ---\n")
    db.run("DELETE FROM lm_memories")
    db.run("DELETE FROM lm_meta WHERE key = 'embed_dim'")
    setup({ embed_dim = 384 })
    assert(store.write({ scope = "d1", title = "alpha", body = "deploy pipeline notes" }))
    assert(store.write({ scope = "d2", title = "beta", body = "cache invalidation notes" }))
    check("the first vector fixes the dimension", db.value("SELECT value FROM lm_meta WHERE key = 'embed_dim'") == "384")
    setup({ embed_dim = 256 })
    local r, e = store.write({ scope = "d1", title = "gamma", body = "new embedder" })
    check("another dimension is refused, naming the fix", r == nil and tostring(e):find("memo reembed", 1, true) ~= nil, e)
    local ra = store.reembed_scope("d1")
    check("re-embedding one scope doesn't switch yet", ra and ra.switched == false and #ra.errors == 0)
    check("… writes of the new size still refused", store.write({ scope = "d1", title = "g", body = "x" }) == nil)
    local rb = store.reembed_scope("d2")
    check("re-embedding the last scope switches the database", rb and rb.switched == true
        and db.value("SELECT value FROM lm_meta WHERE key = 'embed_dim'") == "256")
    check("writes of the new size accepted", store.write({ scope = "d1", title = "gamma", body = "new embedder" }) ~= nil)
    local s = store.search({ scope = "d2", query = "cache invalidation", skip_observations = true, skip_feedback = true }) or {}
    check("re-embedded rows score on the vector side", s[1] and (s[1].vec_score or 0) > 0)
    setup()
    db.run("DELETE FROM lm_memories")
    db.run("DELETE FROM lm_meta WHERE key = 'embed_dim'")
end)

section("database files", function()
    io.write("\n--- database files ---\n")
    local xdg = os.getenv("XDG_DATA_HOME")
    if not xdg or xdg == "" then io.write("[SKIP] XDG_DATA_HOME not set (the runner sets it)\n"); return end
    local p = db.resolve("storage_test")
    check("a name lives in the data directory", p == xdg .. "/luamemo/storage_test.db", p)
    check("a value with a '/' is a path", db.resolve("/tmp/x.db") == "/tmp/x.db")
    check("a name that isn't letters/digits/._- is refused", db.resolve("bad name!") == nil)
    local h = assert(db.open("storage_test"))
    h.close()
    check("data directory is 0700", H.mode(xdg .. "/luamemo") == "700", H.mode(xdg .. "/luamemo"))
    check("database file is 0600", H.mode(p) == "600", H.mode(p))
    os.remove(p); os.remove(p .. "-wal"); os.remove(p .. "-shm")
    -- A database's directory that exists is never luamemo's to lock down: it used to be
    -- chmod 0700 whatever it was (MEMO_DB=/tmp/x.db made /tmp 0700; a path under
    -- /dev/null made /dev/null 0700 — Ollama then failed "open /dev/null").
    local shared = os.tmpname(); os.remove(shared)
    os.execute(("mkdir -p %q && chmod 755 %q"):format(shared, shared))
    local h2 = assert(db.open(shared .. "/here.db")); h2.close()
    check("an existing directory keeps its mode (755 stays 755)", H.mode(shared) == "755", H.mode(shared))
    local h3 = assert(db.open(shared .. "/made/by/luamemo.db")); h3.close()
    check("… one luamemo creates for the file is 0700, its new parents 0755",
        H.mode(shared .. "/made/by") == "700" and H.mode(shared .. "/made") == "755",
        H.mode(shared .. "/made") .. " " .. H.mode(shared .. "/made/by"))
    os.execute(("rm -rf %q"):format(shared))
end)

section("the vault", function()
    io.write("\n--- the vault ---\n")
    setup({ master_key = ("ab"):rep(32) })
    local secrets = require("luamemo.secrets")
    check("enabled with a master key", secrets.enabled())
    local r, e = secrets.store("api_key", "s3cr3t-value", "an api key")
    check("store returns metadata (no value)", r and r.name == "api_key" and r.value == nil, e)
    check("update keeps the description", (secrets.store("api_key", "new-value") or {}).description == "an api key")
    local raw = db.value("SELECT value FROM lm_secrets WHERE name = 'api_key'")
    check("encrypted at rest", raw:match("^x1:%x+$") ~= nil and not raw:find("new%-value"))
    check("list: names + metadata only", (secrets.list()[1] or {}).value == nil and secrets.list()[1].used_count == 0)
    db.run("INSERT INTO lm_secrets (name, value, created_at, updated_at) VALUES ('moved', ?, 1, 1)", raw)
    local _, derr = secrets.execute_with_secret("moved", { url = "http://93.184.215.14/{secret}" })
    check("a value copied to another name doesn't decrypt", tostring(derr):find("authentication failed", 1, true) ~= nil, derr)
    check("reserved names refused", select(2, secrets.store("luamemo.x", "v")) ~= nil)
    check("delete", secrets.delete("moved") == true)
    local dir = os.getenv("MEMO_TEST_TMP") and (os.getenv("MEMO_TEST_TMP") .. "/ring") or (os.tmpname() .. "-ring")
    local ring = assert(secrets.open({ file = dir .. "/keyring.db", master_key_path = dir .. "/keyring.key", create = true }))
    check("a separate store holds an internal secret", ring:put("luamemo.identity.dev", "seed", nil, { internal = true }) ~= nil
        and ring:get_internal("luamemo.identity.dev") == "seed")
    check("… which the public path can't delete", select(2, ring:delete("luamemo.identity.dev")):find("internal", 1, true) ~= nil)
    check("store dir 0700, key and file 0600", H.mode(dir) == "700" and H.mode(dir .. "/keyring.key") == "600"
        and H.mode(dir .. "/keyring.db") == "600")
    -- two processes storing at once lose nothing (the old vault file could)
    local code = "package.path='./?.lua;./?/init.lua;'..package.path; local lm=require('luamemo'); "
        .. "lm.setup({embedder_local='hash', embed_dim=384, skip_embed_probe=true, master_key=os.getenv('MEMO_MASTER_KEY')}); "
        .. "local s=require('luamemo.secrets'); for i=1,40 do assert(s.store(os.getenv('PFX')..i,'v'..i)) end"
    local function writer(pfx)
        return ("PFX=%s MEMO_MASTER_KEY=%s %s -e %q"):format(pfx, ("ab"):rep(32), H.lua_bin(), code)
    end
    H.sh(("%s & %s & wait"):format(writer("A"), writer("B")))
    check("two processes storing at once: every write kept", count("SELECT count(*) FROM lm_secrets WHERE name GLOB 'A*' OR name GLOB 'B*'") == 80,
        count("SELECT count(*) FROM lm_secrets WHERE name GLOB 'A*' OR name GLOB 'B*'"))
    setup()
end)

T.finish()
