-- luamemo.embed
--
-- Unified embedder client. Dispatches to either:
--   * an in-process embedder from luamemo.embedders.*  (zero network)
--   * an HTTP adapter      from luamemo.adapters.*     (Ollama/OpenAI/...)
--
-- Selection rule (resolved in configure()):
--   - if cfg.embedder_local is set    -> in-process embedder by that name
--   - else                            -> HTTP adapter by cfg.embedder_adapter

local cjson = require("cjson.safe")

local M = {}

local cfg          = nil
local impl         = nil   -- module being used
local impl_is_local = false

function M.configure(config)
    cfg = config
    if config.embedder_local then
        impl = require("luamemo.embedders." .. config.embedder_local)
        impl_is_local = true
    else
        impl = require("luamemo.adapters." .. (config.embedder_adapter or "generic"))
        impl_is_local = false
    end
end

local http = require("luamemo.http")

local function http_embed(text)
    local req_body, body_err = impl.build_request(text, cfg)
    if not req_body then return nil, "embed: " .. (body_err or "build_request failed") end

    local headers = { ["Content-Type"] = "application/json" }
    for k, v in pairs(cfg.embedder_headers or {}) do headers[k] = v end
    for k, v in pairs(impl.extra_headers or {}) do headers[k] = v end

    local status, body, err = http.request(impl.url(cfg), {
        method     = "POST",
        body       = req_body,
        headers    = headers,
        timeout_ms = cfg.embed_timeout_ms or 5000,
    })
    if not status then return nil, "embed: HTTP error: " .. tostring(err) end
    if status >= 300 then
        return nil, "embed: HTTP " .. status .. ": " .. tostring(body)
    end

    local payload = cjson.decode(body)
    if not payload then return nil, "embed: invalid JSON response" end

    local vec, vec_err = impl.parse_response(payload, cfg)
    if not vec then return nil, "embed: " .. (vec_err or "parse_response failed") end
    return vec
end

--- Embed a text into a vector of floats.
-- When cfg.embed_max_chars is set and `text` exceeds it, the text is
-- truncated before being sent to the embedder. The third return value
-- signals whether truncation happened so callers can record it.
-- @param text string
-- @return table|nil vector
-- @return string|nil err
-- @return boolean    truncated  true when the input was clipped to fit
function M.embed(text)
    if not cfg then return nil, "embed: not configured (call setup() first)" end
    if type(text) ~= "string" or #text == 0 then
        return nil, "embed: text must be a non-empty string"
    end

    local truncated = false
    local max_chars = tonumber(cfg.embed_max_chars)
    if max_chars and max_chars > 0 and #text > max_chars then
        text = text:sub(1, max_chars)
        truncated = true
    end

    local vec, err
    if impl_is_local then
        vec, err = impl.embed(text, cfg)
    else
        vec, err = http_embed(text)
    end
    if not vec then return nil, err end

    if #vec ~= cfg.embed_dim then
        return nil, ("embed: dimension mismatch: got %d, expected %d")
            :format(#vec, cfg.embed_dim)
    end
    return vec, nil, truncated
end

--- Format a Lua array of numbers as a pgvector literal: '[1.0,2.0,...]'
function M.to_pg_literal(vec)
    if not vec then return "NULL" end
    local parts = {}
    for i, v in ipairs(vec) do parts[i] = tostring(v) end
    return "'[" .. table.concat(parts, ",") .. "]'"
end

--- Format a Lua array of numbers as a Postgres REAL[] literal cast:
--- '{1.0,2.0,...}'::real[]
-- Used by the brute-force backend (no pgvector extension required).
function M.to_pg_array(vec)
    if not vec then return "NULL" end
    local parts = {}
    for i, v in ipairs(vec) do parts[i] = tostring(v) end
    return "'{" .. table.concat(parts, ",") .. "}'::real[]"
end

--- One-shot health check on the configured embedder.
--- Embeds a short fixed string and verifies the returned vector matches
--- the configured `embed_dim`. Useful at startup to fail fast on
--- misconfigured `embedder_url` / `embedder_model` / `embed_dim`.
--- @return number|nil dim   the dimension of the returned vector
--- @return string|nil err   error message on failure
function M.probe()
    if not cfg then return nil, "probe: not configured (call setup() first)" end
    local vec, err = M.embed("probe")
    if not vec then return nil, err end
    return #vec
end

return M
