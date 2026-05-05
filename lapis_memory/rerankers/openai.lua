-- lapis_memory.rerankers.openai
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

local M = {}

local CHUNK_MAX = 500

local function clip(s, n)
    if type(s) ~= "string" then return "" end
    if #s <= n then return s end
    return s:sub(1, n) .. "\xe2\x80\xa6"
end

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

    local http = require("resty.http")
    local httpc = http.new()
    httpc:set_timeout(cfg.rerank_timeout_ms or 30000)

    local req_body = cjson.encode({
        model           = cfg.rerank_model or "gpt-4o-mini",
        messages        = build_messages(query, hits),
        temperature     = 0.0,
        response_format = { type = "json_object" },
    })

    local headers = { ["Content-Type"] = "application/json" }
    for k, v in pairs(cfg.rerank_headers or {}) do headers[k] = v end

    local res, err = httpc:request_uri(url, {
        method = "POST", body = req_body, headers = headers,
    })
    if not res then return nil, "openai.rerank: HTTP error: " .. tostring(err) end
    if res.status >= 300 then
        return nil, "openai.rerank: HTTP " .. res.status .. ": " .. tostring(res.body)
    end

    local payload = cjson.decode(res.body)
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
