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
-- HTTP dependency for execute_with_secret:
--   luamemo.http  (tries resty.http, falls back to socket.http)

-- Pure-Lua crypto backend — always available, no external packages.
local _crypto = require("luamemo.crypto")

local cjson = require("cjson.safe")
local http  = require("luamemo.http")
local util  = require("luamemo.util")

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

local _read_file = util.read_file

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
    return nil, "master_key: invalid format (must be 32-byte raw or 64-char hex)"
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
    -- world-readable, even transiently. Works on all POSIX systems; on
    -- Windows (no chmod) the call fails silently — secure the directory
    -- via NTFS ACLs instead.
    -- Shell-quote the path to prevent command injection if secrets_file
    -- contains spaces or shell metacharacters.
    local chmod_ok = os.execute("chmod 600 " .. util.shell_quote(tmp))
    -- os.execute returns an integer (0=success) in Lua 5.1 and a boolean in 5.2+.
    local chmod_failed = (chmod_ok == false)
        or (type(chmod_ok) == "number" and chmod_ok ~= 0)
    if chmod_failed and package.config:sub(1,1) ~= "\\" then
        -- Non-Windows and chmod still failed — warn but do not abort.
        _log_warn("chmod 600 failed for secrets temp file: " .. tmp)
    end
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

--- Returns true when a master key and secrets file path are configured.
function M.enabled()
    return _key ~= nil and _file_path ~= nil
end

-- ---------------------------------------------------------------------------
-- Crypto backend  (luamemo.crypto — pure Lua, always available)
-- ---------------------------------------------------------------------------

local function _rand_bytes(n)
    return _crypto.random_bytes(n)
end

local function _hmac_sha256(key, msg)
    return _crypto.hmac_sha256(key, msg)
end

local function _aes_encrypt(key, iv, plaintext)
    return _crypto.aes256cbc_encrypt(key, iv, plaintext)
end

local function _aes_decrypt(key, iv, ciphertext)
    return _crypto.aes256cbc_decrypt(key, iv, ciphertext)
end

local function _encrypt(plaintext)
    if not _key then return nil, "secrets: master key not configured" end

    -- 16 random bytes → fresh IV per encryption.
    local iv, ierr = _rand_bytes(16)
    if not iv or #iv ~= 16 then
        return nil, "secrets: failed to generate IV: " .. tostring(ierr)
    end

    local ct, cerr = _aes_encrypt(_key, iv, plaintext)
    if not ct then return nil, "secrets: " .. tostring(cerr) end

    local iv_hex = to_hex(iv)
    local ct_hex = to_hex(ct)
    -- Authenticate iv + ciphertext so any single-bit flip is caught before
    -- decryption (defeats CBC padding-oracle variants).
    local mac, merr = _hmac_sha256(_key, iv_hex .. ":" .. ct_hex)
    if not mac then return nil, "secrets: " .. tostring(merr) end

    return iv_hex .. ":" .. ct_hex .. ":" .. to_hex(mac)
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
    local expected, merr = _hmac_sha256(_key, iv_hex .. ":" .. ct_hex)
    if not expected then return nil, "secrets: " .. tostring(merr) end
    local expected_hex = to_hex(expected)
    -- Constant-time comparison: always iterate the full expected length so
    -- an attacker cannot distinguish a wrong-length MAC from a wrong-content
    -- MAC via response-time differences (timing side-channel).
    local mismatch = (#mac_hex ~= #expected_hex) and 1 or 0
    for i = 1, #expected_hex do
        local got = (i <= #mac_hex) and mac_hex:byte(i) or 0
        if got ~= expected_hex:byte(i) then mismatch = mismatch + 1 end
    end
    if mismatch ~= 0 then
        return nil, "secrets: authentication failed (ciphertext may be corrupt or tampered)"
    end

    local iv = from_hex(iv_hex)
    local ct = from_hex(ct_hex)

    local pt, derr = _aes_decrypt(_key, iv, ct)
    if not pt then return nil, "secrets: decryption failed: " .. tostring(derr) end

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
    -- NOTE: {secret} substitution is intentionally plain-text replacement.
    -- When the destination field is a JSON body, the caller must ensure the
    -- secret value does not contain unescaped quotes/backslashes that would
    -- break JSON structure.  Use headers or URL fields when in doubt.
    return (template:gsub("{secret}", function() return secret_value end))
end

-- Build a multipart/form-data body from a field table.
-- fields: { field_name = string | { file = "/path", content_type? = "..." } }
-- String values have {secret} substituted.  File contents are read as-is.
-- Returns body_string, content_type_header_value, err.
local function _build_multipart(fields, secret_value)
    -- Use CSPRNG for the boundary to guarantee both uniqueness and
    -- resistance to boundary-injection attacks via attacker-controlled content.
    local boundary = "luamemoBoundary" .. to_hex(_crypto.random_bytes(8))

    local parts = {}
    for field_name, spec in pairs(fields) do
        local disposition = 'Content-Disposition: form-data; name="' .. field_name .. '"'
        if type(spec) == "table" and spec.file then
            -- File upload part
            local fpath = spec.file
            -- Path traversal guard: reject absolute paths and any path
            -- component containing ".." to prevent reading arbitrary files.
            if type(fpath) ~= "string" or fpath == ""
                or fpath:find("..", 1, true)
                or fpath:sub(1, 1) == "/"
                or fpath:sub(1, 1) == "\\"
                or fpath:match("^%a:") then
                return nil, nil,
                    "secrets: multipart: file path must be relative and cannot contain '..'"
            end
            -- Reject symlinks: a symlink could point outside the intended
            -- directory tree (e.g. ./uploads/x -> /etc/passwd).
            -- os.execute returns 0/true on POSIX when the file is NOT a
            -- symlink; any non-zero / false result is treated as "is or may
            -- be a symlink" — fail-closed on Windows too (no `test` command).
            local symlink_check = os.execute(
                "test ! -L " .. util.shell_quote(fpath) .. " 2>/dev/null")
            local is_symlink = (symlink_check == false)
                or (type(symlink_check) == "number" and symlink_check ~= 0)
            if is_symlink then
                return nil, nil,
                    "secrets: multipart: symlinks are not allowed for field '" .. field_name .. "'"
            end
            local f = io.open(fpath, "rb")
            if not f then
                return nil, nil,
                    "secrets: multipart: cannot read file for field '" .. field_name .. "': " .. fpath
            end
            local content = f:read("*all")
            f:close()
            local fname = fpath:match("([^/\\]+)$") or fpath
            local ct    = spec.content_type or "application/octet-stream"
            table.insert(parts,
                "--" .. boundary .. "\r\n" ..
                disposition .. '; filename="' .. fname .. '"\r\n' ..
                "Content-Type: " .. ct .. "\r\n\r\n" ..
                content .. "\r\n")
        else
            -- Plain field — apply {secret} substitution.
            local value = _substitute(tostring(spec or ""), secret_value)
            table.insert(parts,
                "--" .. boundary .. "\r\n" ..
                disposition .. "\r\n\r\n" ..
                value .. "\r\n")
        end
    end

    local body = table.concat(parts) .. "--" .. boundary .. "--\r\n"
    local ct   = "multipart/form-data; boundary=" .. boundary
    return body, ct, nil
end

--- Execute an HTTP request with the secret substituted server-side.
--- @param name  string  Secret name to look up
--- @param opts  table   { url, method?, headers?, body?, multipart?, timeout_ms? }
---   multipart: { field_name = string | { file="/path", content_type?="..." } }
---   body and multipart are mutually exclusive.
--- @return string|nil  Response body
--- @return string|nil  Error message
function M.execute_with_secret(name, opts)
    if not M.enabled() then return nil, "secrets: not configured" end
    if not valid_name(name) then return nil, "secrets: invalid name" end
    opts = opts or {}
    if type(opts.url) ~= "string" or opts.url == "" then
        return nil, "secrets: execute_with_secret requires opts.url"
    end
    if opts.body and opts.multipart then
        return nil, "secrets: body and multipart are mutually exclusive"
    end

    -- SSRF guard: only allow http:// and https:// schemes; also block known
    -- internal/metadata IP ranges that cannot be reached from a user context.
    local scheme = opts.url:match("^([%w+%-%.]-)://")
    if scheme ~= "http" and scheme ~= "https" then
        return nil, "secrets: execute_with_secret only allows http:// and https:// URLs"
    end
    local host = opts.url:match("^https?://([^/:?#]+)")
    if host then
        local blocked = host == "localhost"
            or host == "::1"
            or host:match("^127%.")
            or host:match("^169%.254%.")
            or host:match("^10%.")
            or host:match("^192%.168%.")
            or host:match("^172%.1[6-9]%.")
            or host:match("^172%.2%d%.")
            or host:match("^172%.3[0-1]%.")
        if blocked then
            return nil, "secrets: SSRF blocked: disallowed host " .. host
        end
        -- DNS rebinding / split-horizon bypass guard.
        -- Resolve the hostname and re-check the resulting IP against the
        -- same private-range list.  Fail-closed: if DNS lookup fails or
        -- returns nothing, the request is blocked.
        local dns_ok, resolved_ip = pcall(function()
            local sock = require("socket")
            return sock.dns.toip(host)
        end)
        if not dns_ok or not resolved_ip then
            return nil, "secrets: SSRF blocked: could not resolve host " .. host
        end
        local ip_blocked = resolved_ip == "127.0.0.1"
            or resolved_ip == "::1"
            or resolved_ip:match("^127%.")
            or resolved_ip:match("^169%.254%.")
            or resolved_ip:match("^10%.")
            or resolved_ip:match("^192%.168%.")
            or resolved_ip:match("^172%.1[6-9]%.")
            or resolved_ip:match("^172%.2%d%.")
            or resolved_ip:match("^172%.3[0-1].")
        if ip_blocked then
            return nil, "secrets: SSRF blocked: " .. host
                .. " resolves to disallowed IP " .. resolved_ip
        end
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

    local req_body
    if opts.multipart then
        -- Build multipart body *before* zeroing the secret so {secret} can
        -- appear in plain-field values.  File contents are never substituted.
        local mp_body, mp_ct, mp_err = _build_multipart(opts.multipart, value)
        if not mp_body then
            value = nil
            return nil, mp_err
        end
        req_body = mp_body
        req_headers["content-type"] = mp_ct
        method = (opts.method or "POST"):upper()  -- POST is the sane default for multipart
    else
        req_body = opts.body and _substitute(opts.body, value) or nil
    end

    -- Overwrite the local variable holding the plaintext secret.
    -- NOTE: In Lua 5.1 strings are immutable and interned, so this
    -- assignment does NOT securely erase memory — the backing bytes
    -- remain live until the GC collects the string object, and may
    -- persist in swap or core dumps afterward.
    -- OS-level mitigations (deployment-agnostic):
    --   ulimit -c 0          — disable core dumps so plaintext cannot
    --                           be extracted from a crash file
    --   swapoff -a           — disable swap so pages are never written
    --                           to disk; or use an encrypted swap device
    --   mlock / mlockall     — pin process memory (requires CAP_IPC_LOCK)
    -- Short-lived process / container lifetime is the most practical
    -- defence: the secret exists in RAM only for the duration of this call.
    value = nil  -- clear reference; GC will reclaim when no other refs remain

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
