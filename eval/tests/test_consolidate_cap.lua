-- eval/tests/test_consolidate_cap.lua
-- memo consolidate groups near-duplicates by single-link similarity: A~B and B~C put A, B and C together even
-- when A and C are nothing alike. A long chain of related-but-different memories is therefore one "group",
-- and a summarizer asked to merge it would fold unrelated memories into one and delete the originals. With
-- EmbeddingGemma 2 the default threshold (0.85) chained 251 of the 450 memories of a real scope. The limit
-- (MEMO_CONSOLIDATE_MAX_GROUP, default 8) keeps a chain out of the merge: it is reported, never merged.
--   A. a chain of 12 (each 15° from the next, the ends opposite), a pair and a triple of identical vectors
--   B. dry run: three groups reported, the chain marked too_large
--   C. with a merging summarizer: the pair and the triple are merged, the chain is untouched
--   D. 0 lifts the limit (the chain then merges, as before)
-- Run: luajit eval/tests/run.lua --only consolidate_cap

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Consolidate group limit")
local check, section, finish = T.check, T.section, T.finish

local luamemo    = require("luamemo")
local db         = require("luamemo.db")
local summarizer = require("luamemo.summarizer")

local MAIN = assert(os.getenv("MEMO_DB"), "run it with eval/tests/run.lua (MEMO_DB)")
local DIM = 384

-- a merging summarizer with no model behind it
package.loaded["luamemo.summarizers.testmerge"] = {
    summarize = function(members) return { title = "merged " .. #members, body = "merged body of " .. #members, metadata = {} } end,
}

local function setup(max_group)
    luamemo.setup({ db = MAIN, embedder_local = "hash", embed_dim = DIM, skip_embed_probe = true, patterns_enabled = false,
                    summarizer_adapter = "testmerge", consolidate_max_group = max_group })
end

-- a unit vector in the plane of coordinates (a, b), `deg` degrees from the first axis
local function vec(a, b, deg)
    local v = {}
    for i = 1, DIM do v[i] = 0 end
    local r = math.rad(deg)
    v[a], v[b] = math.cos(r), math.sin(r)
    return v
end

-- (the rows a merge folded are archived — hidden until their review — and not counted)
local function rows_of(scope)
    return tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope = ? AND json_type(metadata, '$.lm_fold') IS NULL", scope)) or 0
end

local function fill(scope)
    db.run("DELETE FROM lm_memories WHERE scope = ?", scope)
    local batch = {}
    for i = 0, 11 do   -- the chain: 15° apart (neighbours 0.966, two apart 0.866 — both over 0.85), the ends 165° apart
        batch[#batch + 1] = { scope = scope, title = "chain " .. i, body = "link " .. i, embedding = vec(1, 2, 15 * i) }
    end
    for i = 1, 2 do batch[#batch + 1] = { scope = scope, title = "pair " .. i, body = "same thing " .. i, embedding = vec(5, 6, 0) } end
    for i = 1, 3 do batch[#batch + 1] = { scope = scope, title = "triple " .. i, body = "same other thing " .. i, embedding = vec(9, 10, 0) } end
    local res = luamemo.store.write_many(batch, { dedup_strategy = "append" })
    for _, r in ipairs(res) do assert(r.row, r.error) end
end

section("the groups it finds", function()
    setup(8)
    local scope = "repo:cap"
    fill(scope)
    check("17 memories written", rows_of(scope) == 17, rows_of(scope))
    local r = summarizer.consolidate({ scope = scope, dry_run = true, max_rows = 100, similarity_threshold = 0.85 })
    local sizes = {}
    for _, c in ipairs(r.clusters) do sizes[#sizes + 1] = #c.ids end
    table.sort(sizes)
    check("three groups: the pair, the triple and the chain of 12", table.concat(sizes, ",") == "2,3,12", table.concat(sizes, ","))
    local flagged
    for _, c in ipairs(r.clusters) do if c.too_large then flagged = #c.ids end end
    check("only the chain is marked too large", flagged == 12 and r.too_large == 1, tostring(flagged) .. " / " .. tostring(r.too_large))
    check("a dry run changes nothing", rows_of(scope) == 17)
end)

section("what is merged", function()
    setup(8)
    local scope = "repo:cap2"
    fill(scope)
    local r = summarizer.consolidate({ scope = scope, max_rows = 100, similarity_threshold = 0.85 })
    check("no errors", #r.errors == 0, table.concat(r.errors, "; "))
    check("the pair and the triple were merged (5 rows into 2 summaries): 17 - 5 + 2 = 14", rows_of(scope) == 14, rows_of(scope))
    check("every one of the 12 chain memories is still there",
        tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope = ? AND title LIKE 'chain %'", scope)) == 12)
    check("the merges reported: 5 merged ids, 2 new", #r.merged == 5 and #r.new_ids == 2, #r.merged .. " / " .. #r.new_ids)
end)

section("0 lifts the limit", function()
    setup(0)
    local scope = "repo:cap3"
    fill(scope)
    local r = summarizer.consolidate({ scope = scope, max_rows = 100, similarity_threshold = 0.85 })
    check("nothing is marked too large", r.too_large == 0)
    check("the chain was merged into one: 17 - 17 + 3 = 3 rows", rows_of(scope) == 3, rows_of(scope))
end)

section("the limit's edge: a chain of exactly 8 is a group, 9 is too large", function()
    setup(8)
    local function chain(n, scope)
        db.run("DELETE FROM lm_memories WHERE scope = ?", scope)
        local batch = {}
        for i = 0, n - 1 do batch[#batch + 1] = { scope = scope, title = "link " .. i, body = "chain link " .. i, embedding = vec(1, 2, 15 * i) } end
        for _, r in ipairs(luamemo.store.write_many(batch, { dedup_strategy = "append" })) do assert(r.row, r.error) end
        return summarizer.consolidate({ scope = scope, dry_run = true, max_rows = 100, similarity_threshold = 0.85 })
    end
    local r8, r9 = chain(8, "repo:cap-edge8"), chain(9, "repo:cap-edge9")
    check("8 links: one group of 8, not too large", #r8.clusters == 1 and #r8.clusters[1].ids == 8 and r8.too_large == 0, tostring(r8.too_large))
    check("9 links: one group of 9, too large", #r9.clusters == 1 and #r9.clusters[1].ids == 9 and r9.too_large == 1 and r9.clusters[1].too_large == true)
end)

finish()
