-- lapis_memory.embed
--
-- Unified embedder client. Dispatches to either:
--   * an in-process embedder from lapis_memory.embedders.*  (zero network)
--   * an HTTP adapter      from lapis_memory.adapters.*     (Ollama/OpenAI/...)
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
        impl = require("lapis_memory.embedders." .. config.embedder_local)
        impl_is_local = true
    else
        impl = require("lapis_memory.adapters." .. (config.embedder_adapter or "generic"))
        impl_is_local = false
    end
end

local function http_embed(text)
    -- Lazy require so the library still loads when lua-resty-http is absent
    -- (e.g. plain Lua test harness using only the local hash embedder).
    local ok, http = pcall(require, "resty.http")
    if not ok then
        return nil, "resty.http unavailable (HTTP embedders require lua-resty-http or OpenResty)"
    end
    local httpc = http.new()
    httpc:set_timeout(cfg.embed_timeout_ms or 5000)

    local req_body, body_err = impl.build_request(text, cfg)
    if not req_body then return nil, "embed: " .. (body_err or "build_request failed") end

    local headers = { ["Content-Type"] = "application/json" }
    for k, v in pairs(cfg.embedder_headers or {}) do headers[k] = v end
    for k, v in pairs(impl.extra_headers or {}) do headers[k] = v end

    local res, err = httpc:request_uri(impl.url(cfg), {
        method  = "POST",
        body    = req_body,
        headers = headers,
    })
    if not res then return nil, "embed: HTTP error: " .. tostring(err) end
    if res.status >= 300 then
        return nil, "embed: HTTP " .. res.status .. ": " .. tostring(res.body)
    end

    local payload = cjson.decode(res.body)
    if not payload then return nil, "embed: invalid JSON response" end

    local vec, vec_err = impl.parse_response(payload, cfg)
    if not vec then return nil, "embed: " .. (vec_err or "parse_response failed") end
    return vec
end

--- Embed a text into a vector of floats.
-- @param text string
-- @return table|nil vector
-- @return string|nil err
function M.embed(text)
    if not cfg then return nil, "embed: not configured (call setup() first)" end
    if type(text) ~= "string" or #text == 0 then
        return nil, "embed: text must be a non-empty string"
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
    return vec
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
