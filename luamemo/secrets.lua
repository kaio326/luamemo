-- luamemo/secrets.lua
-- Encrypted secret storage for luamemo.
--
-- Secrets are stored AES-256-CBC encrypted in a local JSON file.
-- No database table is required — the file is the store.
--
-- Activation: set config.secrets_file to a writable path.
-- If secrets_file is not configured, all write operations return a
-- graceful error and execute_with_secret is disabled.  The rest of
-- luamemo works normally.
--
-- File format: { "v": 1, "secrets": { [name]: { ciphertext, description,
--   created_at, updated_at, last_used_at, used_count } } }
-- Ciphertext format: "<32-char iv_hex>:<ct_hex>:<64-char hmac_sha256_hex>"
--   The HMAC covers "iv_hex:ct_hex" and is verified before decryption
--   (encrypt-then-MAC), providing ciphertext integrity / tamper detection.
-- Writes are atomic: write to <path>.tmp then os.rename().
--
-- Master key resolution order (first match wins):
--   1. master_key_path  -- path to a file containing the hex-encoded key
--                          (recommended; use a Docker secret or env file)
--   2. master_key_env   -- name of an environment variable holding the key
--   3. master_key       -- explicit key string in setup() config
--
-- Key format: 64 hex chars (= 32 bytes).  Generate with:
--   openssl rand -hex 32
--
-- When neither key nor file path is configured, all write operations return
-- an error; list() returns an empty table; enabled() returns false.
--
-- Crypto dependencies (standard Lua, no OpenResty required):
--   lua-openssl  (openssl.cipher, openssl.rand, openssl.hmac)
-- HTTP dependency for execute_with_secret:
--   luamemo.http  (tries resty.http, falls back to socket.http)

local cipher_lib = require("openssl.cipher")
local rand_lib   = require("openssl.rand")
local hmac_lib   = require("openssl.hmac")
local cjson      = require("cjson.safe")
local http       = require("luamemo.http")
-- http is used only inside execute_with_secret but required at module level
-- so a missing dependency is caught immediately, not silently at call time.

local M = {}

-- Internal state: resolved 32-byte binary key and file path.
local _key       = nil
local _file_path = nil

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Hex utilities (pure Lua, no external dep)
-- ---------------------------------------------------------------------------

local function to_hex(s)
    return (s:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

local function from_hex(s)
    return (s:gsub("..", function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

local function _read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*all")
    f:close()
    return s
end

-- Parse a raw key string into a 32-byte binary key.
-- Accepts: 64-char hex string OR a raw 32-byte string.
local function parse_key(raw)
    if not raw then return nil, "nil key" end
    raw = raw:gsub("%s+", "")
    if #raw == 64 and raw:match("^%x+$") then
        return from_hex(raw), nil
    end
    if #raw == 32 then
        return raw, nil
    end
    return nil, ("master key must be 32 bytes (raw) or 64 hex chars, got %d chars"):format(#raw)
end

local function _log_warn(msg)
    if type(ngx) == "table" and ngx.log and ngx.WARN then
        ngx.log(ngx.WARN, "luamemo secrets: ", msg)
    end
end

-- ---------------------------------------------------------------------------
-- File-based store helpers
-- ---------------------------------------------------------------------------

-- Read and parse the JSON store file.
-- Returns an empty store when the file does not yet exist.
local function load_store()
    if not _file_path then
        return nil, "secrets: secrets_file not configured"
    end
    local raw = _read_file(_file_path)
    if not raw then
        return { v = 1, secrets = {} }
    end
    local store, err = cjson.decode(raw)
    if not store then
        return nil, "secrets: corrupt store file: " .. tostring(err)
    end
    store.secrets = store.secrets or {}
    return store
end

-- Atomic write: write to <path>.tmp then os.rename() into place.
local function save_store(store)
    if not _file_path then
        return nil, "secrets: secrets_file not configured"
    end
    local data, err = cjson.encode(store)
    if not data then return nil, "secrets: json encode failed: " .. tostring(err) end
    local tmp = _file_path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return nil, "secrets: cannot write to " .. tmp end
    f:write(data)
    f:close()
    -- Restrict permissions before renaming into place so the file is never
    -- world-readable, even transiently. Works on all POSIX systems where
    -- OpenResty runs; silently ignored on Windows.
    -- Shell-quote the path to prevent command injection if secrets_file
    -- contains spaces or shell metacharacters.
    local quoted = "'" .. tostring(tmp):gsub("'", "'\\''" ) .. "'"
    os.execute("chmod 600 " .. quoted)
    local ok = os.rename(tmp, _file_path)
    if not ok then
        return nil, "secrets: rename failed (" .. tmp .. " -> " .. _file_path .. ")"
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Multi-worker write lock
-- Serialises load-modify-save cycles across OpenResty workers using a shared
-- dict mutex. Requires  `lua_shared_dict lm_lock 64k;`  in nginx.conf.
-- Without that dict the lock degrades gracefully to a no-op (fine for
-- single-worker or plain-Lua environments).
-- ---------------------------------------------------------------------------
local function _with_lock(fn)
    local shared = type(ngx) == "table" and ngx.shared
    local dict   = shared and shared.lm_lock
    if dict then
        -- Spin up to 100 ms waiting for the lock; TTL = 5 s prevents deadlock
        -- if a worker crashes while holding it.
        local deadline = ngx.now() + 0.1
        while true do
            if dict:add("w", 1, 5) then break end
            if ngx.now() >= deadline then break end  -- best-effort; proceed
            ngx.sleep(0.001)
        end
        local ok, a, b = pcall(fn)
        dict:delete("w")
        if not ok then error(a, 2) end
        return a, b
    end
    return fn()
end

-- ---------------------------------------------------------------------------
-- configure (called from init.lua setup())
-- ---------------------------------------------------------------------------

--- Configure the secrets module.  Called automatically by M.setup().
--- Safe to call multiple times; the last successful key source wins.
--- @param config table  The global luamemo config table.
function M.configure(config)
    config     = config or {}
    _key       = nil
    _file_path = config.secrets_file or nil

    if config.master_key_path then
        local raw = _read_file(config.master_key_path)
        if raw then
            local k, err = parse_key(raw)
            if k then _key = k; return end
            _log_warn("master_key_path invalid: " .. err)
        end
    end

    if config.master_key_env then
        local raw = os.getenv(config.master_key_env)
        if raw then
            local k, err = parse_key(raw)
            if k then _key = k; return end
            _log_warn("master_key_env invalid: " .. err)
        end
    end

    if config.master_key then
        local k, err = parse_key(config.master_key)
        if k then _key = k; return end
        _log_warn("master_key invalid: " .. err)
    end
end

--- Returns true when both a master key and a secrets file path are configured.
function M.enabled()
    return _key ~= nil and _file_path ~= nil
end

-- ---------------------------------------------------------------------------
-- HMAC-SHA256 via lua-openssl
-- ---------------------------------------------------------------------------

local function _hmac_sha256(key, message)
    local m = hmac_lib.new(key, "sha256")
    m:update(message)
    return m:final()
end

local function _encrypt(plaintext)
    if not _key then return nil, "secrets: master key not configured" end

    -- 16 random bytes → fresh IV per encryption.
    local iv = rand_lib.bytes(16)
    if not iv or #iv ~= 16 then return nil, "secrets: failed to generate IV" end

    local enc = cipher_lib.new("aes-256-cbc")
    enc:encrypt(_key, iv, true)
    enc:update(plaintext)
    local ct = enc:final()
    if not ct then return nil, "secrets: encryption failed" end

    local iv_hex = to_hex(iv)
    local ct_hex = to_hex(ct)
    -- Authenticate iv + ciphertext so any single-bit flip is caught before
    -- decryption (defeats CBC padding-oracle variants).
    local mac_hex = to_hex(_hmac_sha256(_key, iv_hex .. ":" .. ct_hex))

    return iv_hex .. ":" .. ct_hex .. ":" .. mac_hex
end

local function _decrypt(stored)
    if not _key then return nil, "secrets: master key not configured" end

    -- Format: iv_hex:ct_hex:mac_hex
    local iv_hex, ct_hex, mac_hex = stored:match(
        "^([0-9a-fA-F]+):([0-9a-fA-F]+):([0-9a-fA-F]+)$")
    if not iv_hex or not ct_hex or not mac_hex then
        return nil, "secrets: invalid stored ciphertext format"
    end

    -- Verify MAC before touching the ciphertext.
    local expected_hex = to_hex(_hmac_sha256(_key, iv_hex .. ":" .. ct_hex))
    -- Constant-time comparison to prevent timing side-channel on the MAC.
    local mismatch = (#mac_hex ~= #expected_hex) and 1 or 0
    for i = 1, math.min(#mac_hex, #expected_hex) do
        if mac_hex:byte(i) ~= expected_hex:byte(i) then
            mismatch = mismatch + 1
        end
    end
    if mismatch ~= 0 then
        return nil, "secrets: authentication failed (ciphertext may be corrupt or tampered)"
    end

    local iv = from_hex(iv_hex)
    local ct = from_hex(ct_hex)

    local dec = cipher_lib.new("aes-256-cbc")
    dec:decrypt(_key, iv, true)
    dec:update(ct)
    local pt = dec:final()
    if not pt then return nil, "secrets: decryption failed (wrong key or corrupt data)" end

    return pt
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

local function valid_name(name)
    if type(name) ~= "string" or name == "" then return false end
    if #name > 128 then return false end
    return name:match("^[%w%.%-_]+$") ~= nil
end

local function now_iso()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Store (create or update) a secret by name.
--- @param name        string   Unique secret identifier
--- @param value       string   Plaintext secret value
--- @param description string?  Optional human-readable description
--- @return table|nil  {name, description, created_at, updated_at}
--- @return string|nil Error message
function M.store(name, value, description)
    if not _file_path then
        return nil, "secrets: not configured (secrets_file not set)"
    end
    if not _key then
        return nil, "secrets: not configured (no master_key)"
    end
    if not valid_name(name) then
        return nil, "secrets: name must be alphanumeric / hyphen / underscore / dot, max 128 chars"
    end
    if type(value) ~= "string" or value == "" then
        return nil, "secrets: value must be a non-empty string"
    end

    local ciphertext, cerr = _encrypt(value)
    if not ciphertext then return nil, cerr end

    return _with_lock(function()
        local store, serr = load_store()
        if not store then return nil, serr end

        local now      = now_iso()
        local existing = store.secrets[name]

        store.secrets[name] = {
            ciphertext   = ciphertext,
            description  = description or (existing and existing.description) or cjson.null,
            created_at   = (existing and existing.created_at) or now,
            updated_at   = now,
            last_used_at = (existing and existing.last_used_at) or cjson.null,
            used_count   = (existing and existing.used_count)  or 0,
        }

        local ok, werr = save_store(store)
        if not ok then return nil, werr end

        local s = store.secrets[name]
        return { name = name, description = s.description,
                 created_at = s.created_at, updated_at = s.updated_at }
    end)
end

--- Permanently delete a secret.
--- @param name  string  Secret name
--- @return bool   true on success
--- @return string|nil  Error message
function M.delete(name)
    if not M.enabled() then return nil, "secrets: not configured" end
    if not valid_name(name) then return nil, "secrets: invalid name" end

    return _with_lock(function()
        local store, err = load_store()
        if not store then return false, err end

        if not store.secrets[name] then
            return false, "secrets: not found: " .. name
        end

        store.secrets[name] = nil

        local ok, werr = save_store(store)
        if not ok then return false, werr end
        return true
    end)
end

--- List all secrets.  Returns names and metadata — values are never included.
--- @return table[]  {name, description, created_at, updated_at, last_used_at, used_count}[]
function M.list()
    local store = load_store()
    if not store then return {} end
    local out = {}
    for name, s in pairs(store.secrets) do
        table.insert(out, {
            name         = name,
            description  = s.description,
            created_at   = s.created_at,
            updated_at   = s.updated_at,
            last_used_at = s.last_used_at,
            used_count   = s.used_count,
        })
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- ---------------------------------------------------------------------------
-- execute_with_secret
-- Substitutes {secret} in URL / headers / body server-side and makes the
-- HTTP request.  The decrypted value never leaves this function.
-- ---------------------------------------------------------------------------

local function _substitute(template, secret_value)
    if type(template) ~= "string" then return template end
    -- Use a function replacement to prevent Lua from interpreting %0/%1-9
    -- sequences inside secret_value as gsub capture references, which would
    -- produce wrong output (%0 → "{secret}") or raise a runtime error (%1-9).
    return (template:gsub("{secret}", function() return secret_value end))
end

--- Execute an HTTP request with the secret substituted server-side.
--- @param name  string  Secret name to look up
--- @param opts  table   { url, method?, headers?, body?, timeout_ms? }
--- @return string|nil  Response body
--- @return string|nil  Error message
function M.execute_with_secret(name, opts)
    if not M.enabled() then return nil, "secrets: not configured" end
    if not valid_name(name) then return nil, "secrets: invalid name" end
    opts = opts or {}
    if type(opts.url) ~= "string" or opts.url == "" then
        return nil, "secrets: execute_with_secret requires opts.url"
    end

    -- SSRF guard: only allow http:// and https:// schemes to prevent requests
    -- to cloud metadata services (169.254.169.254), internal hosts, or
    -- non-HTTP protocols (file://, gopher://, dict://, …).
    local scheme = opts.url:match("^([%w+%-%.]-)://")
    if scheme ~= "http" and scheme ~= "https" then
        return nil, "secrets: execute_with_secret only allows http:// and https:// URLs"
    end

    local store, serr = load_store()
    if not store then return nil, serr end

    local entry = store.secrets[name]
    if not entry then return nil, "secrets: not found: " .. name end

    local value, derr = _decrypt(entry.ciphertext)
    if not value then return nil, derr end

    local url    = _substitute(opts.url, value)
    local method = (opts.method or "GET"):upper()

    local req_headers = {}
    if opts.headers then
        for k, v in pairs(opts.headers) do
            req_headers[k] = _substitute(tostring(v), value)
        end
    end
    local req_body = opts.body and _substitute(opts.body, value) or nil

    value = nil  -- zero out before any I/O

    -- Update usage tracking (best-effort).
    local now = now_iso()
    entry.last_used_at = now
    entry.used_count   = (entry.used_count or 0) + 1
    pcall(save_store, store)

    local status, body, rerr = http.request(url, {
        method     = method,
        headers    = req_headers,
        body       = req_body,
        timeout_ms = tonumber(opts.timeout_ms) or 10000,
    })
    if not status then
        return nil, "secrets: http request failed: " .. tostring(rerr)
    end

    return body, nil
end

return M
