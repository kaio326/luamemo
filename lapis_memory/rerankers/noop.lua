-- lapis_memory.rerankers.noop
--
-- Pure-Lua, in-process reranker. Deterministic, no network, no LLM.
--
-- Strategy: cheap lexical overlap between the query and each candidate
-- (title + body). Scores are normalised to [0,1] by the maximum overlap
-- in the pool. Useful for:
--   * dev / CI runs where you don't want to call a real model
--   * smoke-testing the rerank plumbing
--   * a sanity baseline ("does the LLM rerank actually beat naive
--     overlap on our corpus?")
--
-- All rerank adapters share the same contract:
--   rerank(query, hits, cfg) -> { {index, score}, ... }, err
-- where:
--   * index is 1-based into the input `hits` array
--   * score is a number; higher = more relevant
--   * the orchestrator handles sorting, deduping, and limit application

local M = {}

local function tokenise(s)
    if type(s) ~= "string" then return {} end
    local out = {}
    for w in s:lower():gmatch("[%w_]+") do
        if #w >= 2 then out[#out + 1] = w end
    end
    return out
end

local function score_overlap(qset, text)
    local toks = tokenise(text)
    if #toks == 0 then return 0 end
    local hits = 0
    local seen = {}
    for _, w in ipairs(toks) do
        if qset[w] and not seen[w] then
            hits = hits + 1
            seen[w] = true
        end
    end
    return hits
end

function M.rerank(query, hits, _cfg)
    if type(hits) ~= "table" or #hits == 0 then return {} end
    local qtoks = tokenise(query)
    if #qtoks == 0 then
        local out = {}
        for i = 1, #hits do out[i] = { index = i, score = 0 } end
        return out
    end
    local qset = {}
    for _, w in ipairs(qtoks) do qset[w] = true end

    local raw = {}
    local max_score = 0
    for i, h in ipairs(hits) do
        local s = score_overlap(qset, (h.title or "") .. " " .. (h.body or ""))
        raw[i] = s
        if s > max_score then max_score = s end
    end

    local out = {}
    for i, s in ipairs(raw) do
        out[i] = {
            index = i,
            score = (max_score > 0) and (s / max_score) or 0,
        }
    end
    return out
end

return M
