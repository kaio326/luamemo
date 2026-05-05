-- lapis_memory.summarizers.openai
--
-- HTTP summarizer adapter targeting OpenAI's /v1/chat/completions endpoint
-- (or any compatible API: Together, Fireworks, vLLM, LM Studio, ...).
-- Configure setup() with:
--   summarizer_url     = "https://api.openai.com/v1/chat/completions"
--   summarizer_model   = "gpt-4o-mini"
--   summarizer_headers = { Authorization = "Bearer sk-..." }
--
-- Contract: summarize(memories, cfg) -> { title, body, metadata }, err

local cjson = require("cjson.safe")

local M = {}

local function build_messages(memories)
    local lines = { "Memories to summarise:" }
    for i, m in ipairs(memories) do
        lines[#lines + 1] = string.format("[%d] %s\n%s",
            i, m.title or "", m.body or "")
    end
    return {
        {
            role    = "system",
            content = "You compact a list of agent memories into one note. "
                .. "Preserve concrete facts (names, IDs, dates, decisions). "
                .. "Reply ONLY with JSON: {\"title\":\"...\",\"body\":\"...\"}.",
        },
        { role = "user", content = table.concat(lines, "\n") },
    }
end

function M.summarize(memories, cfg)
    if type(memories) ~= "table" or #memories == 0 then
        return nil, "openai.summarize: no memories"
    end
    local url = cfg.summarizer_url
    if not url then return nil, "openai.summarize: summarizer_url not set" end

    local http = require("resty.http")
    local httpc = http.new()
    httpc:set_timeout(cfg.summarizer_timeout_ms or 60000)

    local req_body = cjson.encode({
        model       = cfg.summarizer_model or "gpt-4o-mini",
        messages    = build_messages(memories),
        temperature = 0.2,
        response_format = { type = "json_object" },
    })

    local headers = { ["Content-Type"] = "application/json" }
    for k, v in pairs(cfg.summarizer_headers or {}) do headers[k] = v end

    local res, err = httpc:request_uri(url, {
        method = "POST", body = req_body, headers = headers,
    })
    if not res then return nil, "openai.summarize: HTTP error: " .. tostring(err) end
    if res.status >= 300 then
        return nil, "openai.summarize: HTTP " .. res.status .. ": " .. tostring(res.body)
    end

    local payload = cjson.decode(res.body)
    if not payload or not payload.choices or not payload.choices[1] then
        return nil, "openai.summarize: malformed response"
    end
    local content = payload.choices[1].message and payload.choices[1].message.content
    if type(content) ~= "string" then
        return nil, "openai.summarize: missing message.content"
    end
    local parsed = cjson.decode(content)
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
