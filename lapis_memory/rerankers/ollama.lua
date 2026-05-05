-- lapis_memory.rerankers.ollama
--
-- HTTP rerank adapter targeting an Ollama /api/generate endpoint.
-- Configure setup() with:
--   rerank_url   = "http://localhost:11434/api/generate"
--   rerank_model = "llama3.2"  (or any local chat model)
--
-- Contract: rerank(query, hits, cfg) -> { {index, score}, ... }, err
--
-- Token budget: we trim each candidate body to ~500 chars (enough to
-- judge relevance, cheap to send) and ask the model for compact JSON.
-- A 20-candidate rerank typically costs ~10-15k input tokens + a tiny
-- output, well within local-model latency budgets.

local cjson = require("cjson.safe")

local M = {}

local CHUNK_MAX = 500

local function clip(s, n)
    if type(s) ~= "string" then return "" end
    if #s <= n then return s end
    return s:sub(1, n) .. "\xe2\x80\xa6"
end

local function build_prompt(query, hits)
    local lines = {
        "You are a relevance judge. Score each candidate against the query",
        "from 0.0 (irrelevant) to 1.0 (perfect match).",
        "Respond ONLY with JSON: {\"scores\": [{\"index\": N, \"score\": F}, ...]}",
        "Include every candidate exactly once. Do not invent indices.",
        "",
        "Query: " .. query,
        "",
        "Candidates:",
    }
    for i, h in ipairs(hits) do
        lines[#lines + 1] = string.format("[%d] %s\n%s",
            i, clip(h.title or "", 120), clip(h.body or "", CHUNK_MAX))
    end
    return table.concat(lines, "\n")
end

function M.rerank(query, hits, cfg)
    if type(hits) ~= "table" or #hits == 0 then return {} end
    local url = cfg.rerank_url
    if not url then return nil, "ollama.rerank: rerank_url not set" end

    local http = require("resty.http")
    local httpc = http.new()
    httpc:set_timeout(cfg.rerank_timeout_ms or 30000)

    local req_body = cjson.encode({
        model  = cfg.rerank_model or "llama3.2",
        prompt = build_prompt(query, hits),
        stream = false,
        format = "json",
    })

    local res, err = httpc:request_uri(url, {
        method  = "POST",
        body    = req_body,
        headers = { ["Content-Type"] = "application/json" },
    })
    if not res then return nil, "ollama.rerank: HTTP error: " .. tostring(err) end
    if res.status >= 300 then
        return nil, "ollama.rerank: HTTP " .. res.status .. ": " .. tostring(res.body)
    end

    local payload = cjson.decode(res.body)
    if not payload or type(payload.response) ~= "string" then
        return nil, "ollama.rerank: missing 'response' field"
    end
    local parsed = cjson.decode(payload.response)
    if type(parsed) ~= "table" or type(parsed.scores) ~= "table" then
        return nil, "ollama.rerank: model output not valid JSON {scores:[...]}"
    end

    local out = {}
    for _, s in ipairs(parsed.scores) do
        out[#out + 1] = {
            index = tonumber(s.index),
            score = tonumber(s.score) or 0,
        }
    end
    return out
end

return M
