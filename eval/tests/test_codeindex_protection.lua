-- eval/tests/test_codeindex_protection.lua
-- The code index is not memory: `codeindex:` scopes are rebuilt from source by memo index, and their rows look like
-- exactly what maintenance clears away — a dependency edge weighs 0.2, a file 0.3 (light), they are old, and similar
-- ones group at any threshold. With a real summarizer on and the digest running by default, nothing may fold, merge,
-- expire, digest, review or observe them. Rows here come from the real indexer (not hand-made), aged, and every
-- maintenance path is run on them; a control scope of ordinary old light memories shows the same paths DO act on
-- memory (so a pass is not a test that cannot fail).
-- Run: luajit eval/tests/run.lua --only codeindex_protection

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Code index protection")
local check, section, finish = T.check, T.section, T.finish

local luamemo     = require("luamemo")
local db          = require("luamemo.db")
local util        = require("luamemo.util")
local store       = require("luamemo.store")
local fold        = require("luamemo.fold")
local digest      = require("luamemo.digest")
local summarizer  = require("luamemo.summarizer")
local consolidate = require("luamemo.consolidate")
local maintenance = require("luamemo.maintenance")

local MAIN = assert(os.getenv("MEMO_DB"), "run it with eval/tests/run.lua (MEMO_DB)")
local lua_bin = H.lua_bin()

-- a merging summarizer with no model behind it
package.loaded["luamemo.summarizers.testmerge"] = {
    summarize = function(members) return { title = "merged " .. #members, body = "merged body of " .. #members, metadata = {} } end,
}
luamemo.setup({ db = MAIN, embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false,
                summarizer_adapter = "testmerge", consolidate_threshold = 0.0 })

local CODE, CONTROL = "codeindex:prot", "repo:prot-control"
local n = H.count
local function snapshot(scope)
    return n("SELECT count(*) FROM lm_memories WHERE scope = ?", scope) .. "/"
        .. n("SELECT sum(id) FROM lm_memories WHERE scope = ?", scope) .. "/"
        .. n("SELECT sum(tier) FROM lm_memories WHERE scope = ?", scope) .. "/"
        .. n("SELECT sum(importance) FROM lm_memories WHERE scope = ?", scope) .. "/"
        .. n("SELECT count(*) FROM lm_memories WHERE scope = ? AND json_type(metadata, '$.lm_fold') IS NOT NULL", scope)
end

-- the real indexer on the fixture project: symbol, file and dependency rows as luamemo writes them
local res = assert(require("luamemo.index").ingest("eval/fixtures/corpus_src/alpha", { scope = CODE }))
local kinds = {}
for _, r in ipairs(db.query("SELECT kind, tier, importance, count(*) AS c FROM lm_memories WHERE scope = ? GROUP BY kind, tier, importance", CODE)) do
    kinds[#kinds + 1] = ("%s t%d i%.1f x%d"):format(r.kind, r.tier, r.importance, r.c)
end
-- old, and consolidated (what the digest's old purge looked for)
db.run("UPDATE lm_memories SET updated_at = 1, created_at = 1, consolidated_at = 1 WHERE scope = ?", CODE)

-- the control: ordinary memories, old and light
for i = 1, 4 do
    assert(store.write({ scope = CONTROL, title = "old note " .. i, body = "an old light note about topic " .. i, importance = 0.2,
        dedup_strategy = "append" }))
end
db.run("UPDATE lm_memories SET updated_at = 1 WHERE scope = ?", CONTROL)

section("the rows are the real ones", function()
    check("the indexer wrote symbols, files and dependency edges, light and old", #kinds >= 3 and n("SELECT count(*) FROM lm_memories WHERE scope = ? AND importance < 0.5", CODE) >= 2,
        table.concat(kinds, "; "))
    check("the index has tier-0 dependency rows (what a purge of consolidated tier 0 would take)",
        n("SELECT count(*) FROM lm_memories WHERE scope = ? AND tier = 0 AND consolidated_at IS NOT NULL", CODE) >= 1)
end)

section("no maintenance path touches them", function()
    local before = snapshot(CODE)
    local sum = summarizer.run({ scope = CODE, retention_days = 0, weight_threshold = 99, batch_size = 50, max_batches = 5 })
    check("summarize: nothing selected, nothing folded", sum.summarised == 0 and (sum.errors == nil or #sum.errors == 0), require("luamemo.json").encode(sum))
    local cons = summarizer.consolidate({ scope = CODE, similarity_threshold = 0, max_rows = 500 })
    check("consolidate (everything similar at 0): no group, nothing merged, nothing expired",
        #cons.clusters == 0 and #cons.merged == 0 and #cons.expired == 0, require("luamemo.json").encode({ #cons.clusters, #cons.merged, #cons.expired }))
    check("find_decayed: nothing expired", #(store.find_decayed({ scope = CODE, decay_threshold = 99, apply = true }) or {}) == 0)
    check("the digest skips the scope", digest.run(CODE).skipped == "codeindex")
    check("the review skips the scope, and says why", fold.run(CODE).skipped == "codeindex")
    check("observation building skips the scope", consolidate.process(CODE).skipped == "codeindex")
    check("memo maintain's run skips the scope, and says why", maintenance.run(CODE).skipped == "codeindex")
    check("no observation was made", n("SELECT count(*) FROM lm_observations WHERE scope = ?", CODE) == 0)
    check("not one row changed: count, ids, tiers, importance, nothing archived", snapshot(CODE) == before, snapshot(CODE) .. " vs " .. before)
end)

section("nor the command, nor a search", function()
    local before = snapshot(CODE)
    local env = ("env -u MEMO_NO_MAINTENANCE MEMO_DB=%q MEMO_EMBEDDER=hash MEMO_LUA=%q"):format(MAIN, lua_bin)
    local out, code = H.sh(env .. " ./cli/memo maintain --scope " .. CODE .. " --quiet 2>&1")
    check("`memo maintain --scope codeindex:…` runs and prints nothing", code == 0 and out == "", out)
    local out2 = H.sh(env .. " ./cli/memo maintain --scope " .. CODE .. " --all 2>&1")
    check("… and says it did nothing with the scope: no digest, no summary, no review",
        out2:find(CODE .. ": digest — · summarized — · review —", 1, true) ~= nil
        and not out2:find("processed", 1, true) and not out2:find("deleted", 1, true), out2)
    luamemo.search({ scope = CODE, query = "greeting function", limit = 5, skip_feedback = true })
    local due = false
    for _, s in ipairs(maintenance.due_scopes()) do if s == CODE then due = true end end
    check("a search in the scope makes no observation and no review is due for it", not due and n("SELECT count(*) FROM lm_observations WHERE scope = ?", CODE) == 0)
    check("still not one row changed", snapshot(CODE) == before, snapshot(CODE) .. " vs " .. before)
end)

section("the control: the same paths do act on ordinary memory", function()
    local sum = summarizer.run({ scope = CONTROL, retention_days = 0, weight_threshold = 99, batch_size = 50, max_batches = 5 })
    check("summarize folded the four old light notes (archived: hidden, kept)",
        sum.summarised >= 1 and n("SELECT count(*) FROM lm_memories WHERE scope = ? AND json_type(metadata, '$.lm_fold') IS NOT NULL", CONTROL) == 4,
        require("luamemo.json").encode(sum))
end)

section("the knowledge graph: a search's facts never come from a code map", function()
    local kg, policy = require("luamemo.kg"), require("luamemo.federation.policy")
    db.run("DELETE FROM lm_kg_facts WHERE scope IN ('codeindex:kgx', 'repo:kgx')")
    local now = util.now_us()
    for _, s in ipairs({ "codeindex:kgx", "repo:kgx" }) do
        assert(db.run("INSERT INTO lm_kg_facts (scope, subject, predicate, object, valid_from, created_at) VALUES (?, 'Quasar', 'imports', 'x', ?, ?)",
            s, now, now))
    end
    local function scopes_of(list) local out = {} for _, f in ipairs(list) do out[#out + 1] = f.scope end table.sort(out) return table.concat(out, ",") end
    check("for_query(nil): every scope's facts but the code maps'", scopes_of(kg.for_query(nil, "quasar")) == "repo:kgx",
        scopes_of(kg.for_query(nil, "quasar")))
    check("for_query(explicit scopes): a code map's scope is skipped too",
        scopes_of(kg.for_query({ "codeindex:kgx", "repo:kgx" }, "quasar")) == "repo:kgx")
    -- the Lua and SQL spellings of "the code map's scope" agree
    local agree = true
    for _, s in ipairs({ "codeindex:a", "xcodeindex:a", "repo:codeindex:", "codeindex", "CODEINDEX:a", "" }) do
        -- (the real constant, applied to a one-row table whose scope is `s`)
        local excluded = tonumber(db.value("SELECT count(*) FROM (SELECT ? AS scope) WHERE " .. policy.NOT_CODEINDEX_SQL, s)) == 0
        if policy.is_codeindex(s) ~= excluded then agree = false end
    end
    check("policy.is_codeindex and NOT_CODEINDEX_SQL say the same", agree)
    db.run("DELETE FROM lm_kg_facts WHERE scope IN ('codeindex:kgx', 'repo:kgx')")
end)

package.loaded["luamemo.summarizers.testmerge"] = nil
finish()
