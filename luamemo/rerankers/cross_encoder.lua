-- luamemo.rerankers.cross_encoder
--
-- HTTP rerank adapter for cross-encoder rerankers served via a sidecar
-- process. The reference target is HuggingFace's
-- `text-embeddings-inference` (TEI) running a model like
-- `BAAI/bge-reranker-v2-m3`. TEI exposes a native `/rerank` endpoint:
--
--   POST {rerank_url}
--   {"query":"...","texts":["doc1","doc2",...],"raw_scores":false}
--   -> [{"index":2,"score":0.91}, {"index":0,"score":0.62}, ...]
--
-- The same payload shape is also accepted (loosely) by Cohere /
-- Jina rerank endpoints, with an extra `model` field. We send both
-- and let the server ignore unknown keys.
--
-- This adapter is opt-in: callers must set `rerank_url` to the
-- sidecar's `/rerank` URL. There is NO Ollama fallback because
-- Ollama (as of 0.23.x) does not host cross-encoder reranker models.
--
-- Configure setup() with:
--   rerank_url     = "http://127.0.0.1:8080/rerank"     -- TEI sidecar
--   rerank_model   = "BAAI/bge-reranker-v2-m3"          -- optional
--   rerank_headers = {}                                  -- optional
--
-- See `eval/sidecars/tei.md` for the docker-compose stub.
--
-- Contract: rerank(query, hits, cfg) -> { {index, score}, ... }, err

local cjson = require("cjson.safe")
local http  = require("luamemo.http")
local util  = require("luamemo.util")

local M = {}

local CHUNK_MAX = 1500   -- TEI default max_input_length is 8192 tokens
local clip      = util.clip

local function build_text(h)
    local title = clip(h.title or "", 200)
    local body  = clip(h.body  or "", CHUNK_MAX)
    if title == "" then return body end
    if body  == "" then return title end
    return title .. "\n" .. body
end

-- Parse two known response shapes:
--   1. TEI native:    [{"index":N,"score":F}, ...]
--   2. Cohere/Jina:   {"results":[{"index":N,"relevance_score":F},...]}
local function parse_response(body_text)
    local parsed = cjson.decode(body_text)
    if type(parsed) ~= "table" then
        return nil, "cross_encoder: response is not JSON"
    end
    -- Cohere/Jina shape
    if type(parsed.results) == "table" then
        local out = {}
        for _, r in ipairs(parsed.results) do
            out[#out + 1] = {
                index = tonumber(r.index),
                score = tonumber(r.relevance_score or r.score) or 0,
            }
        end
        return out
    end
    -- TEI native: array of {index, score}
    if parsed[1] and type(parsed[1]) == "table" then
        local out = {}
        for _, r in ipairs(parsed) do
            out[#out + 1] = {
                index = tonumber(r.index),
                score = tonumber(r.score) or 0,
            }
        end
        return out
    end
    return nil, "cross_encoder: unrecognised response shape"
end

function M.rerank(query, hits, cfg)
    if type(hits) ~= "table" or #hits == 0 then return {} end
    local url = cfg.rerank_url
    if not url then
        return nil, "cross_encoder.rerank: rerank_url not set "
            .. "(point at a TEI /rerank sidecar)"
    end

    local texts = {}
    for i, h in ipairs(hits) do texts[i] = build_text(h) end

    local req_body = cjson.encode({
        model      = cfg.rerank_model,   -- nil for TEI; required for Cohere/Jina
        query      = query,
        texts      = texts,              -- TEI key
        documents  = texts,              -- Cohere/Jina key (server ignores extras)
        raw_scores = false,
    })

    local headers = { ["Content-Type"] = "application/json" }
    for k, v in pairs(cfg.rerank_headers or {}) do headers[k] = v end

    local status, body, err = http.request(url, {
        method = "POST", body = req_body, headers = headers,
        timeout_ms = cfg.rerank_timeout_ms or 30000,
    })
    if not status then
        return nil, "cross_encoder.rerank: HTTP error: " .. tostring(err)
    end
    if status >= 300 then
        return nil, "cross_encoder.rerank: HTTP " .. status
            .. ": " .. tostring(body)
    end

    local out, perr = parse_response(body)
    if not out then return nil, perr end
    return out
end

return M
