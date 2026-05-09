-- luamemo.summarizers.ollama
--
-- HTTP summarizer adapter targeting an Ollama /api/generate endpoint.
-- Configure setup() with:
--   summarizer_url   = "http://localhost:11434/api/generate"
--   summarizer_model = "llama3.2"  (or any local chat model)
--
-- Contract: summarize(memories, cfg) -> { title, body, metadata }, err

local cjson   = require("cjson.safe")
local http    = require("luamemo.http")
local util    = require("luamemo.util")
local _common = require("luamemo.summarizers._common")

local M = {}

local function build_prompt(memories)
    local lines = {
        "Summarise the following memories into a single concise note.",
        "Preserve concrete facts (names, IDs, dates, decisions).",
        "Output JSON: { \"title\": \"...\", \"body\": \"...\" }.",
        "",
        "Memories:",
    }
    for _, line in ipairs(_common.build_memory_lines(memories, 1500)) do
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
end

function M.summarize(memories, cfg)
    if type(memories) ~= "table" or #memories == 0 then
        return nil, "ollama.summarize: no memories"
    end
    local url = cfg.summarizer_url
    if not url then return nil, "ollama.summarize: summarizer_url not set" end

    local req_body = cjson.encode({
        model  = cfg.summarizer_model or "llama3.2",
        prompt = build_prompt(memories),
        stream = false,
        format = "json",
    })

    local status, body, err = http.request(url, {
        method     = "POST",
        body       = req_body,
        headers    = { ["Content-Type"] = "application/json" },
        timeout_ms = cfg.summarizer_timeout_ms or 60000,
    })
    local ok, herr = util.check_http(status, body, err, "ollama.summarize")
    if not ok then return nil, herr end

    local payload = cjson.decode(body)
    if not payload or type(payload.response) ~= "string" then
        return nil, "ollama.summarize: missing 'response' field"
    end
    local parsed = cjson.decode(payload.response)
    if type(parsed) ~= "table" or not parsed.title or not parsed.body then
        return nil, "ollama.summarize: model output not valid JSON {title,body}"
    end

    return {
        title    = parsed.title,
        body     = parsed.body,
        metadata = {
            summarizer   = "ollama",
            model        = cfg.summarizer_model or "llama3.2",
            source_count = #memories,
        },
    }
end

return M
