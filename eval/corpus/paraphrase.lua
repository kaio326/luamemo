-- eval/corpus/paraphrase.lua — the questions a person would really ask.
--
-- The mechanical queries (corpus/queries.lua) are fragments of their own answers — they share
-- almost every word with it, which only tests lexical matching. People half-remember: they
-- ask for a thing in other words. This stage has a local model (gemma4 through Ollama) rewrite a
-- seeded sample of them, then MEASURES the result: a rewrite is kept only if it shares few words
-- with its answer (overlap < 0.4), carries none of the answer's identifiers and reads as a
-- question. The kept rewrites are new rows of bench_queries (source = 'llm', the same gold,
-- project, split and time as the query they came from); the originals stay.
--
-- The model's text is not reproducible, so it is cached: every call is one line of
-- <db>.paraphrases.jsonl, and a rebuild or a rerun replays the file instead of calling the model.
-- Resumable: lines already in the cache are not asked again.
--
--   run(path, opts) → { asked, cached, kept, rejected }
--   opts: n (default 5000), model ("gemma4:e4b"), url ("http://127.0.0.1:11434/api/generate"),
--         seed, complete(prompt) → text | nil, err (tests), say, max_seconds

local util = require("luamemo.util")
local json = require("luamemo.json")

local M = {}

local PROMPT = [[A developer half-remembers something in a codebase and asks a colleague to find it. They do not remember the exact words. Rewrite the sentence below as ONE short question, in your own words: do not reuse its distinctive words, do not use identifiers, code or quotes.

Sentence: %s

Question:]]

-- Categories worth rewriting, and their share of the sample.
M.CATEGORIES = { symbol_doc = 0.40, doc_section = 0.20, note_content = 0.20, note_heading = 0.10, git_commit = 0.10 }

--- Is `q` a usable rewrite of a query whose answer text is `answer_text`, with `identifiers` taken from it?
--- → true | false, why
function M.acceptable(q, original, answer_text, identifiers)
    if type(q) ~= "string" then return false, "no text" end
    q = q:gsub("^%s+", ""):gsub("%s+$", "")
    if q:find("\n", 1, true) then return false, "more than a line" end
    local n = select(2, q:gsub("%S+", ""))
    if n < 5 or n > 32 then return false, "length " .. n end
    if q:find("[`{}]") or q:find("%f[%w]function%f[%W]") then return false, "code" end
    if q:lower() == original:lower() then return false, "unchanged" end
    for w in pairs(identifiers or {}) do
        if #w >= 5 and q:lower():find(w, 1, true) then return false, "uses the identifier " .. w end
    end
    local o = require("corpus.queries").overlap(q, answer_text)
    if o >= 0.4 then return false, ("overlap %.2f"):format(o) end
    if not q:find("%?%s*$") and not q:lower():match("^%a+%s") then return false, "not a question" end
    return true, nil, o
end

local function ollama(url, model)
    local http = require("luamemo.http")
    return function(prompt)
        local status, body, err = http.request(url, { method = "POST", headers = { ["Content-Type"] = "application/json" },
            timeout_ms = 120000, body = json.encode({ model = model, prompt = prompt, stream = false, think = false,
                options = { temperature = 0.7, num_predict = 60 } }) })
        local ok, herr = util.check_http(status, body, err, "paraphrase")
        if not ok then return nil, herr end
        local payload = json.decode(body)
        return payload and payload.response, nil
    end
end

local function read_cache(path)
    local out, f = {}, io.open(path, "r")
    if not f then return out end
    for line in f:lines() do
        local ok, row = pcall(json.decode, line)
        if ok and type(row) == "table" and row.id then out[tonumber(row.id)] = row end
    end
    f:close()
    return out
end

function M.run(path, opts)
    opts = opts or {}
    local say = opts.say or function(_) end
    local ok, why = require("corpus.build").is_bench_path(path)
    if not ok then return nil, why end
    local db = require("luamemo.db")
    local h = assert(db.open(path))
    local cache_path = path .. ".paraphrases.jsonl"
    local cache = read_cache(cache_path)
    local complete = opts.complete or ollama(opts.url or "http://127.0.0.1:11434/api/generate", opts.model or "gemma4:e4b")
    local seed, total = tonumber(opts.seed) or 1, tonumber(opts.n) or 5000
    local sha256 = require("luamemo.native.sodium").sha256

    -- the sample: per category, the mechanical queries in a seeded order
    local picks = {}
    for cat, share in pairs(M.CATEGORIES) do
        local rows = h.query("SELECT id, gold_ids, query FROM bench_queries WHERE category = ? AND source != 'llm'", cat) or {}
        for _, r in ipairs(rows) do r.key = util.to_hex(sha256(seed .. "|para|" .. r.id)):sub(1, 16) end
        table.sort(rows, function(a, b) return a.key < b.key end)
        for i = 1, math.min(#rows, math.floor(total * share)) do picks[#picks + 1] = rows[i] end
    end
    table.sort(picks, function(a, b) return a.key < b.key end)

    local f = assert(io.open(cache_path, "a"))
    local asked, replayed, kept, rejected, t0 = 0, 0, 0, 0, os.time()
    for _, p in ipairs(picks) do
        if opts.max_seconds and os.time() - t0 > opts.max_seconds then say("time budget spent — resume to continue"); break end
        local c = cache[tonumber(p.id)]
        if c then replayed = replayed + 1 else
            local text, err = complete(PROMPT:format(p.query))
            asked = asked + 1
            if text then
                c = { id = p.id, orig = p.query, para = (text:gsub("^%s*[Qq]uestion:%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")),
                      model = opts.model or "gemma4:e4b" }
                f:write(json.encode(c), "\n"); f:flush()
                cache[tonumber(p.id)] = c
            else
                say("model call failed: " .. tostring(err))
            end
        end
    end
    f:close()

    -- the kept rewrites become rows (those not already there)
    h.run("DELETE FROM bench_queries WHERE source = 'llm'")
    h.run("BEGIN")
    for _, p in ipairs(picks) do
        local c = cache[tonumber(p.id)]
        if c then
            local orig = h.query("SELECT * FROM bench_queries WHERE id = ?", p.id)[1]
            local ids = json.decode(orig.gold_ids)
            local texts, idents = {}, {}
            for _, g in ipairs(h.query("SELECT title, body FROM lm_memories WHERE id IN (" .. table.concat(ids, ",") .. ")") or {}) do
                texts[#texts + 1] = g.title .. " " .. g.body
                for w in pairs(require("corpus.queries").words(g.title:gsub("^.-[:/→]%s*", ""))) do idents[w] = true end
            end
            local good, reason, o = M.acceptable(c.para, c.orig, table.concat(texts, " "), idents)
            if good then
                kept = kept + 1
                local bucket = o >= 0.5 and "high" or (o >= 0.2 and "med" or "low")
                h.run("INSERT INTO bench_queries (scope, project, category, query, gold_ids, overlap, bucket, split, holdout, t, source) "
                    .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'llm')", orig.scope, orig.project, orig.category, c.para,
                    orig.gold_ids, o, bucket, orig.split, orig.holdout, orig.t)
            else
                rejected = rejected + 1
            end
        end
    end
    h.run("COMMIT")
    h.run("INSERT OR REPLACE INTO lm_meta (key, value) VALUES ('bench_paraphrases', ?)", json.encode({ kept = kept,
        rejected = rejected, model = opts.model or "gemma4:e4b" }))
    h.close()
    return { asked = asked, cached = replayed, kept = kept, rejected = rejected }
end

return M
