-- luamemo.cli._common
-- Shared CLI bootstrap helpers. Centralises the MEMO_* environment → config
-- construction that the `memo` subcommand entrypoints (api, index, …) all need,
-- including the "empty string means unset" guard (Lua treats "" as truthy).

local M = {}

-- Return a trimmed env var value, or nil when unset OR empty.
local function env(name)
    local v = os.getenv(name)
    if v and v ~= "" then return v end
    return nil
end

-- Build a luamemo config table from the standard MEMO_* environment variables.
-- opts:
--   secrets = true → also read MEMO_SECRETS_FILE / MEMO_MASTER_KEY_ENV /
--                    MEMO_MASTER_KEY
--   auth    = true → set auth_fn (always-allow) + skip_embed_probe = false
function M.config_from_env(opts)
    opts = opts or {}
    local cfg = {}

    -- Embedder: an HTTP embedder (MEMO_EMBEDDER_URL) takes priority; otherwise
    -- a local embedder selected by MEMO_EMBEDDER, defaulting to "hash".
    local embedder_url = env("MEMO_EMBEDDER_URL")
    if embedder_url then
        cfg.embedder_url     = embedder_url
        cfg.embedder_adapter = env("MEMO_EMBEDDER_ADAPTER") or "generic"
        local em = env("MEMO_EMBEDDER_MODEL")
        if em then cfg.embedder_model = em end
    else
        cfg.embedder_local = env("MEMO_EMBEDDER") or "hash"
    end

    local embed_dim = tonumber(os.getenv("MEMO_EMBED_DIM"))
    if embed_dim then cfg.embed_dim = embed_dim end

    -- Truncation safety knob (embed.lua uses cfg.embed_max_chars to bound
    -- request size / stay inside a local model's context window). calibrate
    -- recommends and persists this to .luamemorc — it must actually reach
    -- the CLI's write/search path, not just the ping/doctor display code.
    local embed_max_chars = tonumber(os.getenv("MEMO_EMBED_MAX_CHARS"))
    if embed_max_chars then cfg.embed_max_chars = embed_max_chars end

    local db_url = env("MEMO_DB_URL")
    if db_url then cfg.db_url = db_url end

    if opts.secrets then
        local sf = env("MEMO_SECRETS_FILE")
        if sf then cfg.secrets_file = sf end
        -- Preserve historical behaviour: MEMO_MASTER_KEY_ENV is taken raw (an
        -- explicit empty string is honoured, not treated as unset).
        local mke = os.getenv("MEMO_MASTER_KEY_ENV")
        if mke then cfg.master_key_env = mke end
        local mk = env("MEMO_MASTER_KEY")
        if mk then cfg.master_key = mk end
    end

    if opts.auth then
        cfg.auth_fn = function() return true end
        cfg.skip_embed_probe = false
    end

    M.apply_learning_flags(cfg)
    return cfg
end

-- Apply the opt-in learned-from-usage switches from the MEMO_* environment onto a
-- config table. Shared by the api/CLI (config_from_env) and the MCP server so both
-- enable them identically. Everything stays OFF unless explicitly set, preserving
-- zero-regression defaults.
--   MEMO_FEEDBACK_ENABLED=1      → log retrievals + enable duplicate-write miss detection
--   MEMO_AUTO_DIGEST=1           → self-maintaining lazy digest on writes
--   MEMO_AUTO_DIGEST_INTERVAL=N  → seconds between lazy digests per scope
--   MEMO_MISS_THRESHOLD=F        → cosine threshold for the duplicate-write miss
function M.apply_learning_flags(cfg)
    if env("MEMO_FEEDBACK_ENABLED") == "1" then cfg.feedback_enabled = true end
    if env("MEMO_AUTO_DIGEST") == "1" then cfg.auto_digest_enabled = true end
    local adi = tonumber(env("MEMO_AUTO_DIGEST_INTERVAL"))
    if adi then cfg.auto_digest_interval = adi end
    local mt = tonumber(env("MEMO_MISS_THRESHOLD"))
    if mt then cfg.miss_threshold = mt end
    return cfg
end

return M
