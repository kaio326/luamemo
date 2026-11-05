-- eval/clustering_probe.lua — what a similarity threshold means for the two ways luamemo groups memories.
--
--   MEMO_NO_MAINTENANCE=1 luajit eval/clustering_probe.lua --db bench-100k.db [--out probe.json] [--thresholds 0.75,0.8,0.85,0.9,0.95]
--
-- memo consolidate groups by SINGLE LINK (store.find_clusters: A~B and B~C put A, B and C together even when A
-- and C are nothing alike); the digest groups by PIVOT (util.cluster: a memory joins the first group whose first
-- member it matches, so a group cannot chain). Both are asked the same question on the same rows:
--   * the distinct memories of the corpus' repo: scopes (READMEs, instructions, notes — all different from
--     each other: any group of two or more of them is a false merge);
--   * for every tenth one, two copies that SHOULD be grouped with it: a near-duplicate (one sentence added at the
--     end) and a snapshot (its first three quarters — what the session hooks save as a conversation grows).
-- Per threshold: groups, rows in a group, the largest group, how many groups mix different memories (false
-- merges), and how many copies were grouped with their original (recall). Both clusterers run the real code on a
-- scratch database; the corpus is only read. The embedder is the corpus' own.

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path
local json = require("luamemo.json")
local util = require("luamemo.util")

local args = { db = nil, out = nil, thresholds = "0.75,0.8,0.85,0.9,0.95", scopes = "repo:luamemo,repo:portfolio" }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--db" then args.db = arg[i + 1]
        elseif a == "--out" then args.out = arg[i + 1]
        elseif a == "--thresholds" then args.thresholds = arg[i + 1]
        elseif a == "--scopes" then args.scopes = arg[i + 1]
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
        i = i + 2
    end
end
assert(args.db, "--db is required")
local ok, why = require("corpus.build").is_bench_path(args.db)
if not ok then io.stderr:write(tostring(why), "\n"); os.exit(1) end

-- the distinct memories, with the corpus' vectors
local dbm = require("luamemo.db")
local vectors = require("luamemo.vectors")
local src = assert(dbm.open(args.db, { readonly = true }))
local originals = {}
for scope in args.scopes:gmatch("[^,]+") do
    for _, r in ipairs(src.query("SELECT id, scope, kind, title, body, embedding FROM lm_memories WHERE scope = ? "
        .. "AND embedding IS NOT NULL AND length(body) >= 300 ORDER BY id", scope) or {}) do
        r.embedding = vectors.unpack(r.embedding)
        originals[#originals + 1] = r
    end
end
src.close()
assert(#originals > 20, "too few memories in " .. args.scopes)

-- a scratch database in the corpus' embedding space
local scratch = os.tmpname(); os.remove(scratch)
scratch = scratch .. "-probe.db"
local setup = assert(require("corpus.build").embedder_from_meta(args.db, {}))
setup.db, setup.skip_embed_probe, setup.dedup_enabled, setup.patterns_enabled = scratch, true, false, false
local memory = require("luamemo")
memory.setup(setup)
local db = require("luamemo.db")
local embed = require("luamemo.embed")

local SCOPE = "probe:clusters"
local family = {}   -- memory id -> the original it belongs to
local rows = {}
for _, o in ipairs(originals) do
    rows[#rows + 1] = { scope = SCOPE, kind = "fact", title = o.title, body = o.body, embedding = o.embedding, _orig = o.id }
end
local n_copies = 0
for i = 1, #originals, 10 do
    local o = originals[i]
    local variants = {
        { name = "edit", body = o.body .. " This section was reviewed and is still current." },
        { name = "snapshot", body = o.body:sub(1, math.floor(#o.body * 0.75)) },
    }
    for _, v in ipairs(variants) do
        local vec = assert(embed.embed(o.title .. "\n" .. v.body))
        rows[#rows + 1] = { scope = SCOPE, kind = "fact", title = o.title, body = v.body, embedding = vec, _orig = o.id, _copy = v.name }
        n_copies = n_copies + 1
    end
    io.stderr:write(("  embedded the copies of %d / %d\r"):format(i, #originals))
end
io.stderr:write("\n")
local batch = {}
for i, r in ipairs(rows) do batch[i] = { scope = r.scope, kind = r.kind, title = r.title, body = r.body, embedding = r.embedding } end
local res = memory.store.write_many(batch, { dedup_strategy = "append", batch_size = 100 })
for i, r in ipairs(res) do
    assert(r.row, tostring(r.error))
    family[tonumber(r.row.id)] = rows[i]._orig
    rows[i].id = tonumber(r.row.id)
end

-- score a clustering: groups = array of arrays of row ids
local function score(groups)
    local out = { groups = 0, grouped_rows = 0, largest = 1, false_merge_groups = 0, false_merge_rows = 0, edit_recall = 0, snapshot_recall = 0 }
    local group_of = {}
    for gi, g in ipairs(groups) do
        if #g > 1 then
            out.groups = out.groups + 1
            out.grouped_rows = out.grouped_rows + #g
            if #g > out.largest then out.largest = #g end
            local fams, nf = {}, 0
            for _, id in ipairs(g) do
                if not fams[family[id]] then fams[family[id]] = true; nf = nf + 1 end
            end
            if nf > 1 then out.false_merge_groups = out.false_merge_groups + 1; out.false_merge_rows = out.false_merge_rows + #g end
        end
        for _, id in ipairs(g) do group_of[id] = gi end
    end
    local orig_row, n_edit, n_snap = {}, 0, 0
    for _, r in ipairs(rows) do if not r._copy then orig_row[r._orig] = r.id end end
    for _, r in ipairs(rows) do
        if r._copy then
            local same = group_of[r.id] and group_of[r.id] == group_of[orig_row[r._orig]]
            if r._copy == "edit" then n_edit = n_edit + 1; if same then out.edit_recall = out.edit_recall + 1 end
            else n_snap = n_snap + 1; if same then out.snapshot_recall = out.snapshot_recall + 1 end end
        end
    end
    out.edit_recall, out.snapshot_recall = out.edit_recall / math.max(n_edit, 1), out.snapshot_recall / math.max(n_snap, 1)
    return out
end

local result = { rows = #rows, distinct = #originals, copies = n_copies, scopes = args.scopes, thresholds = {} }
local store = memory.store
for th in args.thresholds:gmatch("[%d%.]+") do
    local t = tonumber(th)
    -- consolidate: single link, over the scope's most important rows (the tool's own limit is 5,000)
    local cl = assert(store.find_clusters({ scope = SCOPE, similarity_threshold = t, max_rows = 5000 }))
    local single = {}
    for _, c in ipairs(cl) do
        local g = {}
        for _, id in ipairs(c.ids) do g[#g + 1] = tonumber(id) end
        single[#single + 1] = g
    end
    -- digest: pivot, over the same rows in write order
    local mem = {}
    for _, r in ipairs(rows) do mem[#mem + 1] = { id = r.id, embedding = r.embedding } end
    local pivot = {}
    for _, c in ipairs(util.cluster(mem, t)) do
        local g = {}
        for _, m in ipairs(c) do g[#g + 1] = m.id end
        pivot[#pivot + 1] = g
    end
    result.thresholds[#result.thresholds + 1] = { threshold = t, consolidate = score(single), digest = score(pivot) }
    local a, b = result.thresholds[#result.thresholds].consolidate, result.thresholds[#result.thresholds].digest
    print(("%.2f  consolidate: %3d groups, largest %4d, %4d rows in %3d mixed groups · copies grouped with their original: edit %3.0f %% snapshot %3.0f %%"):format(
        t, a.groups, a.largest, a.false_merge_rows, a.false_merge_groups, 100 * a.edit_recall, 100 * a.snapshot_recall))
    print(("      digest:      %3d groups, largest %4d, %4d rows in %3d mixed groups · copies grouped with their original: edit %3.0f %% snapshot %3.0f %%"):format(
        b.groups, b.largest, b.false_merge_rows, b.false_merge_groups, 100 * b.edit_recall, 100 * b.snapshot_recall))
end

-- The three decisions that compare ONE new text with what is already there — dedup (a write is a duplicate),
-- miss (a write nearly repeats a memory a search should have found) and reinforce (a group of new memories
-- matches an existing observation; the originals stand for the observations here) — all ask: is the nearest
-- existing memory at least t similar? For each threshold:
--   false rate    a DISTINCT memory, written among the others, finds a nearest one at or above t (a wrong "yes")
--   true rate     an edited copy / a snapshot finds ITS OWN original as the nearest one at or above t
local nn = { thresholds = {} }
do
    local orig_rows = {}
    for _, r in ipairs(rows) do if not r._copy then orig_rows[#orig_rows + 1] = r end end
    local near_other = {}      -- per original: its best similarity to any OTHER original
    for i, a in ipairs(orig_rows) do
        local best = -1
        for j, b in ipairs(orig_rows) do
            if i ~= j then
                local s = util.cosine(a.embedding, b.embedding)
                if s > best then best = s end
            end
        end
        near_other[i] = best
    end
    local own = { edit = {}, snapshot = {} }   -- per copy: similarity to its own original, when that original is its nearest
    for _, c in ipairs(rows) do
        if c._copy then
            local best, best_id, own_sim = -1, nil, -1
            for _, o in ipairs(orig_rows) do
                local s = util.cosine(c.embedding, o.embedding)
                if s > best then best, best_id = s, o._orig end
                if o._orig == c._orig then own_sim = s end
            end
            table.insert(own[c._copy], best_id == c._orig and own_sim or -1)
        end
    end
    for t in ("0.70,0.75,0.80,0.85,0.90,0.93,0.95,0.97"):gmatch("[%d%.]+") do
        t = tonumber(t)
        local function share(list, pred)
            local n = 0
            for _, v in ipairs(list) do if pred(v) then n = n + 1 end end
            return n / math.max(#list, 1)
        end
        local row = { threshold = t,
            false_rate = share(near_other, function(v) return v >= t end),
            edit_true = share(own.edit, function(v) return v >= t end),
            snapshot_true = share(own.snapshot, function(v) return v >= t end) }
        nn.thresholds[#nn.thresholds + 1] = row
    end
    -- the rule: the lowest threshold with both true rates >= 95 % and a false rate <= 1 %
    for _, row in ipairs(nn.thresholds) do
        if not nn.suggested and row.edit_true >= 0.95 and row.snapshot_true >= 0.95 and row.false_rate <= 0.01 then
            nn.suggested = row.threshold
        end
    end
    print("\nnearest existing memory at least t similar (dedup / miss / reinforce all ask this):")
    print("  t      distinct memory wrongly matched   near-duplicate found   snapshot found")
    for _, row in ipairs(nn.thresholds) do
        print(("  %.2f   %5.1f %%                           %5.1f %%                %5.1f %%"):format(
            row.threshold, 100 * row.false_rate, 100 * row.edit_true, 100 * row.snapshot_true))
    end
    print(("  rule (true >= 95 %% on both, wrongly matched <= 1 %%): lowest t = %s"):format(tostring(nn.suggested)))
end
result.nearest = nn

if args.out then
    local f = assert(io.open(args.out, "w"))
    f:write(json.encode(result)); f:close()
end
for _, sfx in ipairs({ "", "-wal", "-shm" }) do os.remove(scratch .. sfx) end
