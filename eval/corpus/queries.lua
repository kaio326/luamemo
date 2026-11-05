-- eval/corpus/queries.lua — labelled queries for the benchmark corpus.
--
-- A query is a question and the row(s) that answer it. The gold comes from the REAL structure
-- of what luamemo wrote, never from a model: a symbol's own docstring (with its name's words
-- taken out) asks for that symbol; the names a file defines ask for that file; a module asks
-- who requires it; a README section's opening sentence asks for that section; a commit's
-- subject, a note's heading and its sentences ask for theirs. What a query shares with its
-- answer is measured (overlap) and bucketed, so a result can be read by how hard the question was.
--
-- Table bench_queries (beside luamemo's own tables; luamemo never reads it):
--   id, scope, project, category, query, gold_ids (JSON), overlap, bucket, split, holdout, t (µs), source
--   split   'history' (the first 70 % of a project's queries in simulated time: the usage simulator
--           replays them) or 'eval' (the last 30 %: what a learner is judged on, never logged)
--   holdout 1 for projects (about 2 in 10) whose queries are never logged at all — the transfer test
--           of global / org-wide weights on a project they never saw.
--
--   build(path, opts) → { queries, by_category }
--   Same seed, same corpus ⇒ the same queries.

local util = require("luamemo.util")
local json = require("luamemo.json")

local M = {}

local STOP = {}
for w in ([[the and for are but not you all can had her was one our out has his how its may new now old see two way who
    did get use this that with from have what when where which will would should could into than then them they their
    there these those been being were your about after also each more most only other over some such very does done
    make made just like want need used using uses]]):gmatch("%S+") do STOP[w] = true end

--- Content words of a text: lowercase, 3+ letters, not a stop word (set).
local function words(s)
    local out = {}
    for w in tostring(s or ""):lower():gmatch("[%a][%w]+") do
        if #w >= 3 and not STOP[w] then out[w] = true end
    end
    return out
end
M.words = words

--- The words an identifier is made of: "getDefaultTaxPct" / "get_default.tax" → get default tax pct.
local function ident_words(name)
    local out = {}
    local spaced = tostring(name or ""):gsub("(%l)(%u)", "%1 %2"):gsub("[^%w]+", " ")
    for w in spaced:lower():gmatch("%S+") do out[w] = true end
    return out
end

--- Shared share of the query's content words found in the answer's text → 0..1.
function M.overlap(query, answer)
    local qw, aw, n, shared = words(query), words(answer), 0, 0
    for w in pairs(qw) do n = n + 1; if aw[w] then shared = shared + 1 end end
    return n == 0 and 0 or shared / n
end

local function bucket(o) return o >= 0.5 and "high" or (o >= 0.2 and "med" or "low") end

-- The first sentence of a text, cut at a sentence end or 160 characters.
local function first_sentence(s)
    s = tostring(s or ""):gsub("%s+", " "):gsub("^%s+", "")
    local sent = s:match("^(.-[%.%?!])%s") or s:match("^(.-[%.%?!])$") or s
    return util.cut_utf8(sent, 160)
end

local function drop_words(text, drop)
    local kept = {}
    for w in text:gmatch("%S+") do
        local bare = w:lower():gsub("[^%w]", "")
        if not drop[bare] then kept[#kept + 1] = w end
    end
    return table.concat(kept, " ")
end

local function tidy(q)
    q = q:gsub("^%W+", ""):gsub("[%s:;,]+$", ""):gsub("%s+", " ")
    return q
end

-- ── the categories: each takes a row, returns { query, gold = { ids }, source } | nil ───────

local CATEGORIES = {}

-- A symbol whose docstring says what it does: "Get the default tax rate percentage — function a.b.getDefaultTaxPct".
local function doc_of(r) return tostring(r.body):match("^(.-)%s+—%s+%a+ ") end

CATEGORIES.symbol_doc = {
    sql = "SELECT id, scope, title, body, metadata FROM lm_memories WHERE kind = 'symbol' AND body LIKE '% — %' AND scope LIKE 'codeindex:%'",
    -- Several symbols of a scope can carry the same docstring ("Return the string representation.")
    -- and a question about it is answered by all of them: they are the gold, up to 5; more is no question.
    prepare = function(rows)
        local same = {}
        for _, r in ipairs(rows) do
            local doc = doc_of(r)
            if doc then
                local k = r.scope .. "\0" .. first_sentence(doc)
                same[k] = same[k] or {}
                table.insert(same[k], r.id)
            end
        end
        return { same = same }
    end,
    make = function(r, ctx)
        local doc = doc_of(r)
        if not doc or #doc < 25 then return nil end
        local drop = ident_words(r.title)
        local q = tidy(drop_words(first_sentence(doc), drop))
        local n = 0
        for _ in pairs(words(q)) do n = n + 1 end
        if n < 4 then return nil end
        local gold = ctx.same[r.scope .. "\0" .. first_sentence(doc)] or { r.id }
        if #gold > 5 then return nil end
        table.sort(gold)
        return { query = q, gold = gold, source = "docstring" }
    end,
}

-- A file, asked by two of the names it defines. The answer is the file: its own row, and the rows of the symbols
-- it defines (a result that names one of them with the file's path says which file defines it).
CATEGORIES.file_defines = {
    sql = "WITH sy AS (SELECT scope, json_extract(metadata, '$.path') AS p, group_concat(id) AS ids FROM lm_memories "
        .. "WHERE kind = 'symbol' AND scope LIKE 'codeindex:%' GROUP BY scope, p) "
        .. "SELECT f.id, f.scope, f.title, f.body, f.metadata, sy.ids AS symbol_ids FROM lm_memories f "
        .. "LEFT JOIN sy ON sy.scope = f.scope AND sy.p = json_extract(f.metadata, '$.path') "
        .. "WHERE f.kind = 'file' AND f.body LIKE '%defines: %' AND f.scope LIKE 'codeindex:%'",
    make = function(r)
        local list = tostring(r.body):match("defines: (.+)$")
        if not list then return nil end
        local names = {}
        for n in list:gmatch("[^,%s]+") do if #n >= 4 then names[#names + 1] = n end end
        if #names < 2 then return nil end
        local gold = { r.id }
        for id in tostring(r.symbol_ids or ""):gmatch("%d+") do gold[#gold + 1] = tonumber(id) end
        table.sort(gold)
        return { query = ("which file defines %s and %s"):format(names[1], names[2]), gold = gold, source = "defines" }
    end,
}

-- A module, asked who depends on it (several answers: every dependency row that requires it).
CATEGORIES.dep_who_requires = {
    sql = "SELECT min(id) AS id, scope, json_extract(metadata, '$.to_module') AS to_module, count(*) AS n, group_concat(id) AS ids "
        .. "FROM lm_memories WHERE kind = 'dependency' AND scope LIKE 'codeindex:%' AND json_extract(metadata, '$.to_module') IS NOT NULL "
        .. "GROUP BY scope, to_module HAVING n BETWEEN 1 AND 8",
    make = function(r)
        local gold = {}
        for id in tostring(r.ids):gmatch("%d+") do gold[#gold + 1] = tonumber(id) end
        local m = tostring(r.to_module)
        if #m < 5 then return nil end
        return { query = "which files require " .. m, gold = gold, source = "requires" }
    end,
}

-- A README / instruction / ADR section, asked by its opening sentence with the heading's words removed.
CATEGORIES.doc_section = {
    sql = "SELECT id, scope, title, body, metadata FROM lm_memories WHERE scope LIKE 'repo:%' AND tags LIKE '%\"calibrate\"%' "
        .. "AND (tags LIKE '%\"readme\"%' OR tags LIKE '%\"agent-instructions\"%' OR tags LIKE '%\"adr\"%')",
    make = function(r)
        local heading = tostring(r.title):gsub("^.-:%s*", ""):gsub("^Agent instructions / ", "")
        local q = tidy(drop_words(first_sentence(r.body), ident_words(heading)))
        local n = 0
        for _ in pairs(words(q)) do n = n + 1 end
        if n < 5 then return nil end
        return { query = q, gold = { r.id }, source = "section" }
    end,
}

-- A commit, asked as "what changed when …" with its conventional prefix taken off.
CATEGORIES.git_commit = {
    sql = "SELECT id, scope, title, body, metadata FROM lm_memories WHERE scope LIKE 'repo:%' AND tags LIKE '%\"git-commit\"%'",
    make = function(r)
        local subject = tostring(r.title):gsub("^git:%s*", ""):gsub("^%w+%b()%s*:%s*", ""):gsub("^%w+:%s*", "")
        if #subject < 25 then return nil end
        return { query = "what changed when we " .. subject:sub(1, 1):lower() .. subject:sub(2), gold = { r.id }, source = "commit" }
    end,
}

-- An agent-written note, asked by the heading (decision / plan / fact) …
CATEGORIES.note_heading = {
    sql = "SELECT id, scope, title, body, kind, metadata FROM lm_memories WHERE json_extract(metadata, '$.role') IS NOT NULL",
    make = function(r)
        local meta = type(r.metadata) == "table" and r.metadata or {}
        local heading = tostring(meta.section or ""):gsub("[`*_]", "")
        if #heading < 12 then return nil end
        local lead = r.kind == "decision" and "what did we decide about " or (r.kind == "plan" and "what is the plan for " or "what do we know about ")
        return { query = lead .. heading:sub(1, 1):lower() .. heading:sub(2), gold = { r.id }, source = "heading" }
    end,
}

-- … and by a sentence from its body (the note's own words, minus its heading's: how a later
-- question is phrased when the person remembers what was said, not what it was called).
CATEGORIES.note_content = {
    sql = "SELECT id, scope, title, body, kind, metadata FROM lm_memories WHERE json_extract(metadata, '$.role') IS NOT NULL AND length(body) > 300",
    make = function(r)
        local meta = type(r.metadata) == "table" and r.metadata or {}
        local best, best_n
        for s in tostring(r.body):gsub("\n", " "):gmatch("[^%.%?!]+[%.%?!]") do
            s = s:gsub("^%s+", "")
            local n = 0
            for _ in pairs(words(s)) do n = n + 1 end
            if #s >= 60 and #s <= 220 and n >= 7 and (not best_n or n > best_n) and not s:find("`", 1, true) then best, best_n = s, n end
        end
        if not best then return nil end
        local q = tidy(drop_words(best, ident_words(meta.section)))
        return { query = q, gold = { r.id }, source = "sentence" }
    end,
}

M.CATEGORIES = CATEGORIES
M.ORDER = { "symbol_doc", "file_defines", "dep_who_requires", "doc_section", "git_commit", "note_heading", "note_content" }
-- A share of the total for each; what a category cannot fill the others do not take.
M.WEIGHTS = { symbol_doc = 0.35, file_defines = 0.10, dep_who_requires = 0.10, doc_section = 0.15, git_commit = 0.07,
              note_heading = 0.08, note_content = 0.15 }

local MONTH_US = 30 * 24 * 3600 * 1000000

--- Build the queries of the corpus at `path`. opts: seed, total (default 20000), per_scope (cap, default 4000),
--- months (spread of the simulated time, default 18), say.
function M.build(path, opts)
    opts = opts or {}
    local say = opts.say or function(_) end
    local ok, why = require("corpus.build").is_bench_path(path)
    if not ok then return nil, why end
    local dbm = require("luamemo.db")
    local h = assert(dbm.open(path))
    local total, per_scope, seed = tonumber(opts.total) or 20000, tonumber(opts.per_scope) or 4000, tonumber(opts.seed) or 1
    local sha256 = require("luamemo.native.sodium").sha256
    local function key(s) return util.to_hex(sha256(tostring(seed) .. "|" .. s)):sub(1, 16) end

    h.run([[CREATE TABLE IF NOT EXISTS bench_queries (
        id INTEGER PRIMARY KEY, scope TEXT NOT NULL, project TEXT NOT NULL, category TEXT NOT NULL, query TEXT NOT NULL,
        gold_ids TEXT NOT NULL, overlap REAL NOT NULL, bucket TEXT NOT NULL, split TEXT, holdout INTEGER, t INTEGER, source TEXT)]])
    h.run("DELETE FROM bench_queries")

    local made, by_cat, scope_n = {}, {}, {}
    for _, cat in ipairs(M.ORDER) do
        local def = CATEGORIES[cat]
        local rows = h.query(def.sql) or {}
        local ctx = def.prepare and def.prepare(rows) or nil
        local cands = {}
        for _, r in ipairs(rows) do
            local m = def.make(r, ctx)
            if m then
                local gold_text = {}
                local ids = {}
                for _, id in ipairs(m.gold) do ids[#ids + 1] = tostring(id) end
                for _, g in ipairs(h.query("SELECT title, body FROM lm_memories WHERE id IN (" .. table.concat(ids, ",") .. ")")) do
                    gold_text[#gold_text + 1] = g.title .. " " .. g.body
                end
                local o = M.overlap(m.query, table.concat(gold_text, " "))
                cands[#cands + 1] = { key = key(cat .. "|" .. m.query .. "|" .. tostring(m.gold[1])), m = m, scope = r.scope,
                    overlap = o }
            end
        end
        table.sort(cands, function(a, b) return a.key < b.key end)
        local quota = math.floor(total * M.WEIGHTS[cat])
        local took = 0
        for _, c in ipairs(cands) do
            if took >= quota then break end
            if (scope_n[c.scope] or 0) < per_scope then
                scope_n[c.scope] = (scope_n[c.scope] or 0) + 1
                took = took + 1
                made[#made + 1] = { cat = cat, c = c }
            end
        end
        by_cat[cat] = { available = #cands, taken = took }
        say(("%-18s %6d possible, %5d taken"):format(cat, #cands, took))
    end

    -- simulated time and the split: per project, in a seeded order spread over the months
    local per_project = {}
    for _, q in ipairs(made) do
        local project = q.c.scope:gsub("^%a+:", "")
        q.project = project
        per_project[project] = per_project[project] or {}
        table.insert(per_project[project], q)
    end
    local start = (tonumber(opts.start_us) or (util.now_us() - (tonumber(opts.months) or 18) * MONTH_US))
    for project, list in pairs(per_project) do
        table.sort(list, function(a, b) return a.c.key < b.c.key end)
        local holdout = tonumber(util.to_hex(sha256("holdout|" .. seed .. "|" .. project)):sub(1, 4), 16) % 10 >= 8
        for i, q in ipairs(list) do
            q.t = start + math.floor((i / #list) * (tonumber(opts.months) or 18) * MONTH_US)
            q.split = (i <= math.floor(#list * 0.7)) and "history" or "eval"
            q.holdout = holdout and 1 or 0
        end
    end
    h.run("BEGIN")
    for _, q in ipairs(made) do
        h.run("INSERT INTO bench_queries (scope, project, category, query, gold_ids, overlap, bucket, split, holdout, t, source) "
            .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", q.c.scope, q.project, q.cat, q.c.m.query, json.encode(q.c.m.gold),
            q.c.overlap, bucket(q.c.overlap), q.split, q.holdout, q.t, q.c.m.source)
    end
    h.run("COMMIT")
    h.run("INSERT OR REPLACE INTO lm_meta (key, value) VALUES ('bench_queries', ?)", json.encode({ n = #made, seed = seed,
        total = total, per_scope = per_scope, months = opts.months or 18 }))
    h.close()
    return { queries = #made, by_category = by_cat }
end

return M
