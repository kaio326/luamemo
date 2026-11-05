-- eval/metrics.lua — the retrieval numbers every benchmark runner reports, in one place.
--
-- A runner has, per question, the ranked rows `search` returned and the rank of the first
-- right one (nil: not among them). It records both:
--
--   local m = metrics.new()                 -- { limit = 10, ks = { 1, 5, 10, 20 } }
--   metrics.record(m, rank, rows)
--   local s = metrics.summary(m)            -- the JSON-ready table
--
-- R@k / MRR / median rank, and — what the agent actually pays — measured at the default
-- result set (limit 10, the MCP default):
--
--   bytes_to_hit_*   cumulative bytes of rows 1..rank for the questions answered within the
--                    limit (mean, median, p90). A row's size is what an agent receives: the
--                    MCP's compact row (luamemo.ops.compact_row, bodies capped at
--                    ops.BODY_CAP), JSON-encoded, plus the comma between rows. The envelope
--                    ({"ok":true,"results":[…]}, ~25 bytes) is left out. est_tokens = bytes/4,
--                    an estimate: tokenizers differ, the bytes are the figure.
--   miss_rate        the share of questions whose right memory is NOT in the top `limit`:
--                    1 − R@limit. The same information as R@10, said as the event that costs
--                    the agent — a re-search, a grep, whole-file reads.
--   bytes_on_miss_mean  the mean bytes of the `limit` rows returned on those misses (wasted).

local json = require("luamemo.json")
local ops  = require("luamemo.ops")

local M = {}

M.LIMIT = 10
M.KS = { 1, 5, 10, 20 }

-- lua-cjson writes "/" as "\/"; the server undoes it (mcp/server.lua encode_result), so
-- the bytes here do too — only with that encoder, as there.
local ESCAPES_SLASH = json.encode("/") == '"\\/"'

--- Bytes of one row as the agent receives it (compact JSON) plus the comma after it.
function M.row_bytes(row)
    local ok, s = pcall(json.encode, ops.compact_row(row, ops.BODY_CAP))
    if not ok or type(s) ~= "string" then return 0 end
    if ESCAPES_SLASH then s = s:gsub("\\/", "/") end
    return #s + 1
end

--- A new accumulator. opts.limit: the result set an agent gets (default M.LIMIT);
--- opts.ks: the cut-offs for R@k (default M.KS).
function M.new(opts)
    opts = opts or {}
    local m = { limit = opts.limit or M.LIMIT, ks = opts.ks or M.KS, n = 0, sum_mrr = 0,
                hits = {}, ranks = {}, tail_misses = 0, bytes_hit = {}, bytes_miss = {} }
    for _, k in ipairs(m.ks) do m.hits[k] = 0 end
    return m
end

--- One question: rank = position of the first right row (nil: none returned), rows = the
--- ranked rows `search` returned (tables as the store gives them). bytes_of: a row's size
--- as the agent receives it (default M.row_bytes; the code map's are its result lines).
function M.record(m, rank, rows, bytes_of)
    bytes_of = bytes_of or M.row_bytes
    m.n = m.n + 1
    if rank then
        m.sum_mrr = m.sum_mrr + 1 / rank
        m.ranks[#m.ranks + 1] = rank
        for _, k in ipairs(m.ks) do
            if rank <= k then m.hits[k] = m.hits[k] + 1 end
        end
    else
        m.tail_misses = m.tail_misses + 1
    end
    rows = rows or {}
    if rank and rank <= m.limit then
        local bytes = 0
        for i = 1, rank do bytes = bytes + bytes_of(rows[i] or {}) end
        m.bytes_hit[#m.bytes_hit + 1] = bytes
    else
        local bytes = 0
        for i = 1, math.min(#rows, m.limit) do bytes = bytes + bytes_of(rows[i]) end
        m.bytes_miss[#m.bytes_miss + 1] = bytes
    end
end

local function sorted_copy(t)
    local s = {}
    for i, v in ipairs(t) do s[i] = v end
    table.sort(s)
    return s
end

local function median(t)
    if #t == 0 then return nil end
    local s, mid = sorted_copy(t), nil
    mid = math.floor(#s / 2) + 1
    if #s % 2 == 1 then return s[mid] end
    return (s[mid - 1] + s[mid]) / 2
end

--- Nearest-rank percentile (p in 0..100).
local function percentile(t, p)
    if #t == 0 then return nil end
    local s = sorted_copy(t)
    return s[math.max(1, math.ceil(p / 100 * #s))]
end

local function mean(t)
    if #t == 0 then return nil end
    local sum = 0
    for _, v in ipairs(t) do sum = sum + v end
    return sum / #t
end

--- The JSON-ready numbers. Keys of the older runners are kept (n_questions, recall@k, mrr,
--- median_rank, tail_misses); the new ones: limit, miss_rate, bytes_to_hit_mean|median|p90,
--- est_tokens_to_hit_mean, bytes_on_miss_mean.
function M.summary(m)
    local n = m.n
    local s = { n_questions = n, mrr = n > 0 and (m.sum_mrr / n) or 0,
                median_rank = median(m.ranks), tail_misses = m.tail_misses, limit = m.limit }
    for _, k in ipairs(m.ks) do s["recall@" .. k] = n > 0 and (m.hits[k] / n) or 0 end
    s.miss_rate = n > 0 and (#m.bytes_miss / n) or 0
    local bh = mean(m.bytes_hit)
    s.bytes_to_hit_mean, s.bytes_to_hit_median = bh, median(m.bytes_hit)
    s.bytes_to_hit_p90 = percentile(m.bytes_hit, 90)
    s.est_tokens_to_hit_mean = bh and (bh / 4) or nil
    s.bytes_on_miss_mean = mean(m.bytes_miss)
    return s
end

--- The reranker's cost in this run (luamemo.rerank's stats): rerank_ms_mean / _p90 per
--- search and, when the adapter counts them (ollama), rerank_tokens_mean. {} when nothing
--- was reranked. A runner adds these to its overall result.
function M.rerank_summary()
    local ok, rr = pcall(require, "luamemo.rerank")
    local s = ok and rr.stats and rr.stats() or { ms = {}, tokens = {} }
    if #s.ms == 0 then return {} end
    return { rerank_ms_mean = mean(s.ms), rerank_ms_p90 = percentile(s.ms, 90), rerank_tokens_mean = mean(s.tokens),
             rerank_failed = s.failed or 0 }
end

--- A one-line text of the new numbers for a runner's report.
function M.line(s)
    local function f(v, fmt) return v and fmt:format(v) or "—" end
    return ("miss=%s  bytes-to-hit mean=%s median=%s p90=%s (~%s tokens)"):format(
        f(s.miss_rate and s.miss_rate * 100, "%.1f%%"), f(s.bytes_to_hit_mean, "%.0f"),
        f(s.bytes_to_hit_median, "%.0f"), f(s.bytes_to_hit_p90, "%.0f"), f(s.est_tokens_to_hit_mean, "%.0f"))
end

return M
