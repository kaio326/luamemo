-- luamemo.rerankers.openai
--
-- HTTP rerank adapter targeting OpenAI's /v1/chat/completions endpoint
-- (or any compatible API: Together, Fireworks, vLLM, LM Studio, ...).
-- Configure setup() with:
--   rerank_url     = "https://api.openai.com/v1/chat/completions"
--   rerank_model   = "gpt-4o-mini"
--   rerank_headers = { Authorization = "Bearer sk-..." }
--
-- Contract: rerank(query, hits, cfg) -> { {index, score}, ... }, err

local cjson = require("cjson.safe")
local http  = require("luamemo.http")
local util  = require("luamemo.util")

local M = {}

local CHUNK_MAX = 500
local clip      = util.clip

local function build_messages(query, hits)
    local lines = { "Query: " .. query, "", "Candidates:" }
    for i, h in ipairs(hits) do
        lines[#lines + 1] = string.format("[%d] %s\n%s",
            i, clip(h.title or "", 120), clip(h.body or "", CHUNK_MAX))
    end
    return {
        {
            role = "system",
            content = "You are a relevance judge. For each candidate, "
                .. "score 0.0 (irrelevant) to 1.0 (perfect match) against "
                .. "the query. Reply ONLY with JSON: "
                .. "{\"scores\":[{\"index\":N,\"score\":F},...]}. "
                .. "Include every candidate exactly once.",
        },
        { role = "user", content = table.concat(lines, "\n") },
    }
end

function M.rerank(query, hits, cfg)
    if type(hits) ~= "table" or #hits == 0 then return {} end
    local url = cfg.rerank_url
    if not url then return nil, "openai.rerank: rerank_url not set" end

    local req_body = cjson.encode({
        model           = cfg.rerank_model or "gpt-4o-mini",
        messages        = build_messages(query, hits),
        temperature     = 0.0,
        response_format = { type = "json_object" },
    })

    local headers = { ["Content-Type"] = "application/json" }
    for k, v in pairs(cfg.rerank_headers or {}) do headers[k] = v end

    local status, body, err = http.request(url, {
        method = "POST", body = req_body, headers = headers,
        timeout_ms = cfg.rerank_timeout_ms or 30000,
    })
    if not status then return nil, "openai.rerank: HTTP error: " .. tostring(err) end
    if status >= 300 then
        return nil, "openai.rerank: HTTP " .. status .. ": " .. tostring(body)
    end

    local payload = cjson.decode(body)
    if not payload or not payload.choices or not payload.choices[1] then
        return nil, "openai.rerank: malformed response"
    end
    local content = payload.choices[1].message
                    and payload.choices[1].message.content
    if type(content) ~= "string" then
        return nil, "openai.rerank: missing message.content"
    end
    local parsed = cjson.decode(content)
    if type(parsed) ~= "table" or type(parsed.scores) ~= "table" then
        return nil, "openai.rerank: model output not valid JSON {scores:[...]}"
    end

    return util.parse_scores(parsed.scores)
end

return M
