-- luamemo.rerankers.openai
--
-- HTTP rerank adapter targeting OpenAI's /v1/chat/completions endpoint
-- (or any compatible API: Together, Fireworks, vLLM, LM Studio, ...).
-- Settings (memo config set, or .luamemorc):
--   MEMO_RERANK_ADAPTER=openai
--   MEMO_RERANK_URL=https://api.openai.com/v1/chat/completions
--   MEMO_RERANK_MODEL=gpt-4o-mini
--   MEMO_RERANK_HEADERS={"Authorization": "Bearer {secret:openai}"}   (memo secret-store openai)
--
-- Contract: rerank(query, hits, cfg) -> { {index, score}, ... }, err

local json    = require("luamemo.json")
local http    = require("luamemo.http")
local util    = require("luamemo.util")
local _common = require("luamemo.rerankers._common")

local M = {}

local CHUNK_MAX = 500

local function build_messages(query, hits)
    local candidates = _common.build_candidates(hits, CHUNK_MAX)
    local lines = { "Query: " .. query, "", "Candidates:", candidates }
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

    local req_body = json.encode({
        model           = cfg.rerank_model or "gpt-4o-mini",
        messages        = build_messages(query, hits),
        temperature     = 0.0,
        response_format = { type = "json_object" },
    })

    local secrets = require("luamemo.secrets")
    local extra, xerr = secrets.resolve_headers(cfg.rerank_headers)   -- {secret:NAME} → the vault
    if not extra then return nil, "openai.rerank: " .. xerr end
    local headers = { ["Content-Type"] = "application/json" }
    for k, v in pairs(extra) do headers[k] = v end

    local status, body, err = http.request(url, {
        method = "POST", body = req_body, headers = headers,
        timeout_ms = cfg.rerank_timeout_ms or 30000,
    })
    local ok, herr = util.check_http(status, body, err, "openai.rerank")
    if not ok then return nil, secrets.scrub(herr, extra) end

    local payload = json.decode(body)
    if not payload or not payload.choices or not payload.choices[1] then
        return nil, "openai.rerank: malformed response"
    end
    local content = payload.choices[1].message
                    and payload.choices[1].message.content
    if type(content) ~= "string" then
        return nil, "openai.rerank: missing message.content"
    end
    local parsed = json.decode(content)
    if type(parsed) ~= "table" or type(parsed.scores) ~= "table" then
        return nil, "openai.rerank: model output not valid JSON {scores:[...]}"
    end

    return util.parse_scores(parsed.scores)
end

return M
