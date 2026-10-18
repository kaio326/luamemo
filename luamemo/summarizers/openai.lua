-- luamemo.summarizers.openai
--
-- HTTP summarizer adapter targeting OpenAI's /v1/chat/completions endpoint
-- (or any compatible API: Together, Fireworks, vLLM, LM Studio, ...).
-- Settings (memo config set, or .luamemorc):
--   MEMO_SUMMARIZER_ADAPTER=openai
--   MEMO_SUMMARIZER_URL=https://api.openai.com/v1/chat/completions
--   MEMO_SUMMARIZER_MODEL=gpt-4o-mini
--   MEMO_SUMMARIZER_HEADERS={"Authorization": "Bearer {secret:openai}"}   (memo secret-store openai)
--
-- Contract: summarize(memories, cfg) -> { title, body, metadata }, err

local json    = require("luamemo.json")
local http    = require("luamemo.http")
local util    = require("luamemo.util")
local _common = require("luamemo.summarizers._common")

local M = {}

local function build_messages(memories)
    local mem_lines = _common.build_memory_lines(memories, 1500)
    return {
        {
            role    = "system",
            content = "You compact a list of agent memories into one note. "
                .. "Preserve concrete facts (names, IDs, dates, decisions). "
                .. "Reply ONLY with JSON: {\"title\":\"...\",\"body\":\"...\"}.",
        },
        { role = "user", content = "Memories to summarise:\n" .. table.concat(mem_lines, "\n") },
    }
end

function M.summarize(memories, cfg)
    if type(memories) ~= "table" or #memories == 0 then
        return nil, "openai.summarize: no memories"
    end
    local url = cfg.summarizer_url
    if not url then return nil, "openai.summarize: summarizer_url not set" end

    local req_body = json.encode({
        model       = cfg.summarizer_model or "gpt-4o-mini",
        messages    = build_messages(memories),
        temperature = 0.2,
        response_format = { type = "json_object" },
    })

    local secrets = require("luamemo.secrets")
    local extra, xerr = secrets.resolve_headers(cfg.summarizer_headers)   -- {secret:NAME} → the vault
    if not extra then return nil, "openai.summarize: " .. xerr end
    local headers = { ["Content-Type"] = "application/json" }
    for k, v in pairs(extra) do headers[k] = v end

    local status, body, err = http.request(url, {
        method = "POST", body = req_body, headers = headers,
        timeout_ms = cfg.summarizer_timeout_ms or 60000,
    })
    local ok, herr = util.check_http(status, body, err, "openai.summarize")
    if not ok then return nil, secrets.scrub(herr, extra) end

    local payload = json.decode(body)
    if not payload or not payload.choices or not payload.choices[1] then
        return nil, "openai.summarize: malformed response"
    end
    local content = payload.choices[1].message and payload.choices[1].message.content
    if type(content) ~= "string" then
        return nil, "openai.summarize: missing message.content"
    end
    local parsed = json.decode(content)
    if type(parsed) ~= "table" or not parsed.title or not parsed.body then
        return nil, "openai.summarize: model output not valid JSON {title,body}"
    end

    return {
        title    = parsed.title,
        body     = parsed.body,
        metadata = {
            summarizer   = "openai",
            model        = cfg.summarizer_model or "gpt-4o-mini",
            source_count = #memories,
        },
    }
end

return M
