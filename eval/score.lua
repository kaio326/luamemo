-- eval/score.lua
--
-- Compute Recall@k from a results JSON file written by eval/run.lua.
--
-- Usage:
--   lua eval/score.lua eval/results/oracle_hash.json
--
-- A "hit" at rank k means at least one of the question's `answer_session_ids`
-- appears in the top-k entries of `retrieved`. Reports R@1, R@5, R@10.

local cjson = require("cjson.safe")

local function load_results(path)
    local fh = assert(io.open(path, "rb"))
    local raw = fh:read("*a"); fh:close()
    return assert(cjson.decode(raw), "score: invalid JSON in " .. path)
end

local function set_of(list)
    local s = {}
    for _, v in ipairs(list or {}) do s[v] = true end
    return s
end

local function recall_at(retrieved, gold_set, k)
    for i = 1, math.min(k, #retrieved) do
        if gold_set[retrieved[i]] then return 1 end
    end
    return 0
end

local function score(path)
    local data = load_results(path)
    local results = data.results or {}
    local n = #results
    if n == 0 then
        print("score: no results in " .. path); return
    end

    local r1, r5, r10 = 0, 0, 0
    local by_type = {}     -- {[type] = {n, r1, r5, r10}}

    for _, row in ipairs(results) do
        local gold = set_of(row.answer_session_ids)
        local h1   = recall_at(row.retrieved or {}, gold, 1)
        local h5   = recall_at(row.retrieved or {}, gold, 5)
        local h10  = recall_at(row.retrieved or {}, gold, 10)
        r1, r5, r10 = r1 + h1, r5 + h5, r10 + h10

        local t = row.question_type or "unknown"
        by_type[t] = by_type[t] or { n = 0, r1 = 0, r5 = 0, r10 = 0 }
        local b = by_type[t]
        b.n, b.r1, b.r5, b.r10 = b.n + 1, b.r1 + h1, b.r5 + h5, b.r10 + h10
    end

    local function pct(num) return string.format("%.1f%%", 100 * num / n) end
    print(string.format("=== %s ===", path))
    print(string.format("n=%d  embedder=%s  dataset=%s",
        n, (data.meta or {}).embedder or "?", (data.meta or {}).dataset or "?"))
    print(string.format("R@1=%s  R@5=%s  R@10=%s", pct(r1), pct(r5), pct(r10)))

    print("\nBy question_type:")
    print(string.format("  %-30s %5s  %6s  %6s  %6s", "type", "n", "R@1", "R@5", "R@10"))
    for t, b in pairs(by_type) do
        print(string.format("  %-30s %5d  %5.1f%%  %5.1f%%  %5.1f%%",
            t, b.n, 100*b.r1/b.n, 100*b.r5/b.n, 100*b.r10/b.n))
    end
end

local path = arg and arg[1]
if not path then
    print("usage: lua eval/score.lua <results.json>")
    os.exit(1)
end
score(path)
