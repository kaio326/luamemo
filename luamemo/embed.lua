-- luamemo.embed
--
-- Unified embedder client. Dispatches to either:
--   * an in-process embedder from luamemo.embedders.*  (zero network)
--   * an HTTP adapter      from luamemo.adapters.*     (Ollama/OpenAI/...)
--
-- Selection rule (resolved in configure()):
--   - if cfg.embedder_local is set    -> in-process embedder by that name
--   - else                            -> HTTP adapter by cfg.embedder_adapter

local json  = require("luamemo.json")
local util  = require("luamemo.util")

local M = {}

local DEFAULT_EMBED_TIMEOUT_MS = 30000  -- fallback when embed_timeout_ms not set by M.setup()

local cfg          = nil
local impl         = nil   -- module being used
local impl_is_local = false

local _known_fit   -- see "Input too long" below; per configured embedder

function M.configure(config)
    cfg = config
    _known_fit = nil
    if config.embedder_local then
        impl = require("luamemo.embedders." .. config.embedder_local)
        impl_is_local = true
    else
        impl = require("luamemo.adapters." .. (config.embedder_adapter or "generic"))
        impl_is_local = false
    end
end

local http = require("luamemo.http")

-- ---------------------------------------------------------------------------
-- Input too long for the embedder. Services reject an input past their context
-- (ollama: HTTP 500 "the input length exceeds the context length"; TEI: 413
-- "must have less than 512 tokens"; OpenAI: 400 "maximum context length is …").
-- embed() then retries with the text cut in half — at most MAX_SHORTEN times and
-- never below SHORTEN_FLOOR characters — and reports the result truncated. When
-- even that fails it returns nil, err, false, "too_long": the store keeps the row
-- text-only (searchable by its words) instead of losing it.
-- An adapter may recognise its own rejection with M.input_too_long(status, body).
-- ---------------------------------------------------------------------------
local MAX_SHORTEN, SHORTEN_FLOOR = 6, 256
M.MAX_SHORTEN, M.SHORTEN_FLOOR = MAX_SHORTEN, SHORTEN_FLOOR

local TOO_LONG_TEXT = { "context length", "context_length", "maximum context", "too long", "too many tokens",
    "must have less than", "maximum input", "input length", "exceeds the max", "token limit" }

local function input_too_long(status, body)
    if impl and type(impl.input_too_long) == "function" then
        local ok, yes = pcall(impl.input_too_long, status, body)
        if ok and yes ~= nil then return yes and true or false end
    end
    if not (status == 400 or status == 413 or status == 422 or status == 500) then return false end
    local b = tostring(body or ""):lower()
    for _, t in ipairs(TOO_LONG_TEXT) do
        if b:find(t, 1, true) then return true end
    end
    return false
end
M._input_too_long = input_too_long

-- The first half of `text` (never below the floor), cut on a UTF-8 character boundary.
local function halve(text)
    return util.cut_utf8(text, math.max(SHORTEN_FLOOR, math.floor(#text / 2)))
end
M._halve = halve

-- Learned in this process (_known_fit, reset by configure): an input of this many
-- characters was accepted after a longer one was rejected — later long inputs start
-- there instead of halving again.
function M._reset_known_fit() _known_fit = nil end

-- One request to the HTTP embedder → vec | nil, err, too_long
local function http_embed(text, wait_fn)
    local req_body, body_err = impl.build_request(text, cfg)
    if not req_body then return nil, "embed: " .. (body_err or "build_request failed") end

    local secrets = require("luamemo.secrets")
    local extra, herr = secrets.resolve_headers(cfg.embedder_headers)   -- {secret:NAME} → the vault
    if not extra then return nil, "embed: " .. herr end
    local headers = { ["Content-Type"] = "application/json" }
    for k, v in pairs(extra) do headers[k] = v end
    for k, v in pairs(impl.extra_headers or {}) do headers[k] = v end

    local req = {
        method     = "POST",
        body       = req_body,
        headers    = headers,
        timeout_ms = cfg.embed_timeout_ms or DEFAULT_EMBED_TIMEOUT_MS,
    }
    local status, body, err
    if wait_fn then
        status, body, err = http.request_async(impl.url(cfg), req, wait_fn)
    else
        status, body, err = http.request(impl.url(cfg), req)
    end
    local ok, cerr = util.check_http(status, body, err, "embed")
    if not ok then return nil, secrets.scrub(cerr, extra), status and input_too_long(status, body) end

    local payload = json.decode(body)
    if not payload then return nil, "embed: invalid JSON response" end

    local vec, vec_err = impl.parse_response(payload, cfg)
    if not vec then return nil, "embed: " .. (vec_err or "parse_response failed") end
    return vec
end

local function embed_impl(text, wait_fn)
    if not cfg then return nil, "embed: not configured (call setup() first)" end
    if type(text) ~= "string" or #text == 0 then
        return nil, "embed: text must be a non-empty string"
    end

    local truncated = false
    local max_chars = tonumber(cfg.embed_max_chars)
    if max_chars and max_chars > 0 and #text > max_chars then
        text = util.cut_utf8(text, max_chars)   -- on a character: an embedder may refuse broken UTF-8
        truncated = true
    end

    local vec, err, flag
    if impl_is_local then
        vec, err, flag = impl.embed(text, cfg)   -- flag: the embedder cut the input itself
        if vec and flag then truncated = true end
    else
        if _known_fit and #text > _known_fit then
            text = util.cut_utf8(text, _known_fit)
            truncated = true
        end
        local tries = 0
        while true do
            vec, err, flag = http_embed(text, wait_fn)
            if vec or not flag then break end
            -- rejected as too long: shorten and retry, within bounds
            if tries >= MAX_SHORTEN or #text <= SHORTEN_FLOOR then
                return nil, ("embed: input too long for the embedder, still rejected at %d characters "
                    .. "(%s)"):format(#text, tostring(err)), false, "too_long"
            end
            tries = tries + 1
            text = halve(text)
            truncated = true
        end
        if vec and tries > 0 and (not _known_fit or #text > _known_fit) then _known_fit = #text end
    end
    if not vec then return nil, err end

    if cfg.embed_dim and cfg.embed_dim > 0 and #vec ~= cfg.embed_dim then
        return nil, ("embed: dimension mismatch: got %d, expected %d")
            :format(#vec, cfg.embed_dim)
    end
    return vec, nil, truncated
end

--- Embed a text into a vector of floats.
-- When cfg.embed_max_chars is set and `text` exceeds it, the text is
-- truncated before being sent to the embedder; an embedder that rejects the
-- input as too long gets it shortened (see above). The third return value
-- signals whether truncation happened so callers can record it.
-- @param text string
-- @return table|nil vector
-- @return string|nil err
-- @return boolean    truncated  true when the input was clipped to fit
-- @return string|nil "too_long" when no vector could be had because of the length
function M.embed(text)
    return embed_impl(text, nil)
end

--- Async variant of embed() for use inside luamemo.async task coroutines.
-- Uses http.request_async() for HTTP-based embedders so the scheduler can
-- interleave multiple embedding calls concurrently.  Falls back to the
-- synchronous embed() for in-process (local) embedders (request_async itself
-- falls back for HTTPS URLs). Returns the same values as embed().
-- @param text    string
-- @param wait_fn function  async.wait from luamemo.async
function M.embed_async(text, wait_fn)
    if impl_is_local then return M.embed(text) end
    return embed_impl(text, wait_fn)
end

--- What the configured embedder makes of `text` (memo embed / memory_embed) →
--- { embedder, model, dim, truncated, cosine (opts.compare_to: the two texts'
--- similarity), vector (opts.vector = true) } | nil, err.
function M.inspect(text, opts)
    opts = opts or {}
    if not cfg then return nil, "embed: not configured (call setup() first)" end
    local vec, err, truncated = M.embed(text)
    if not vec then return nil, err end
    local name = cfg.embedder_local or cfg.embedder_adapter or "generic"
    local model = cfg.embedder_model
    if name == "gguf_ffi" then
        local p = model or os.getenv("MEMO_GGUF_MODEL") or ""
        model = p:match("[^/\\]+$") or p
    end
    local out = { embedder = name, model = model, dim = #vec, truncated = truncated == true }
    if opts.compare_to ~= nil then
        local other, oerr = M.embed(tostring(opts.compare_to))
        if not other then return nil, oerr end
        out.cosine = util.cosine(vec, other)
    end
    if opts.vector then out.vector = vec end
    return out
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
