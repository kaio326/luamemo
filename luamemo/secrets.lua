-- luamemo/secrets.lua
-- Encrypted secret storage for luamemo.
--
-- Secrets live in the lm_secrets table of the luamemo database: the value
-- encrypted (XChaCha20-Poly1305, libsodium) under the master key, with the
-- secret's name as associated data (a value can't be moved to another name);
-- name, description and usage counters in clear. Writes run in a transaction,
-- so two processes storing at once never lose a write.
--
-- Activation: configure a master key. Without one, all write operations
-- return a graceful error and execute_with_secret is disabled. The rest of
-- luamemo works normally.
--
-- Stored value format: "x1:" .. hex(nonce24 .. ciphertext+tag16)
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
-- When no key is configured, all write operations return an error;
-- list() returns an empty table; enabled() returns false.
--
-- HTTP dependency for execute_with_secret:
--   luamemo.http  (luasocket; luasec for HTTPS)

local sodium = require("luamemo.native.sodium")
local http   = require("luamemo.http")
local util   = require("luamemo.util")

local M = {}

-- A store = { db = function() → database handle, key = 32-byte master key }.
-- The module-level API (store / delete / list / execute_with_secret — what the
-- MCP tools and the CLI use) works on `_default`, the configured luamemo
-- database; M.open() returns further, independent stores in their own file
-- (e.g. the per-user federation keyring).
local Store = {}
Store.__index = Store
local function default_db() return require("luamemo.db").get() end
local _default = setmetatable({ db = default_db, key = nil }, Store)

-- Names under this prefix are reserved for luamemo's own INTERNAL secrets
-- (federation identity keys …): the public API can't create, overwrite or
-- delete them, and execute_with_secret refuses them.
M.RESERVED_PREFIX = "luamemo."

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local to_hex, from_hex = util.to_hex, util.from_hex

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

-- Configuration problems (bad key, chmod failure) — never a key or a value.
local function _log_warn(msg)
    io.stderr:write("luamemo secrets: ", msg, "\n")
end

-- ---------------------------------------------------------------------------
-- configure (called from init.lua setup())
-- ---------------------------------------------------------------------------

-- Whether configure() was given a key source (then the default key file is not used).
local _key_configured = false

--- The default master key file: vault.key in the per-user luamemo directory (where the
--- federation keyring lives — ~/.config/luamemo). Used when no key is configured and
--- the file exists; the first `memo secret-store` creates it (create_default_key).
function M.default_key_path()
    local dir = require("luamemo.federation.keys").dir()
    return dir and (dir .. "/vault.key") or nil
end

--- Configure the secrets module.  Called automatically by M.setup().
--- Safe to call multiple times; the last successful key source wins.
--- @param config table  The global luamemo config table.
function M.configure(config)
    config        = config or {}
    _default.key  = nil
    _key_configured = (config.master_key_path or config.master_key_env or config.master_key) ~= nil
    if not _key_configured then
        local path = M.default_key_path()
        local raw = path and _read_file(path)
        if raw then
            local k, err = parse_key(raw)
            if k then _default.key = k; return end
            _log_warn(path .. " invalid: " .. err)
        end
        return
    end

    if config.master_key_path then
        local raw = _read_file(config.master_key_path)
        if raw then
            local k, err = parse_key(raw)
            if k then _default.key = k; return end
            _log_warn("master_key_path invalid: " .. err)
        end
    end

    if config.master_key_env then
        local raw = os.getenv(config.master_key_env)
        if raw then
            local k, err = parse_key(raw)
            if k then _default.key = k; return end
            _log_warn("master_key_env invalid: " .. err)
        end
    end

    if config.master_key then
        local k, err = parse_key(config.master_key)
        if k then _default.key = k; return end
        _log_warn("master_key invalid: " .. err)
    end
end

function Store:enabled()
    return self.key ~= nil
end

--- Returns true when a master key is configured.
function M.enabled()
    return _default:enabled()
end

-- The store's database handle | nil, err
function Store:_db()
    local ok, h, err = pcall(self.db)
    if not ok then return nil, "secrets: " .. tostring(h) end
    if not h then return nil, "secrets: " .. tostring(err) end
    return h
end

-- ---------------------------------------------------------------------------
-- Crypto (libsodium XChaCha20-Poly1305; the name is the associated data)
-- ---------------------------------------------------------------------------
local function _ad(name) return "luamemo-secret:" .. name end

local function _encrypt(st, name, plaintext)
    if not st.key then return nil, "secrets: master key not configured" end
    local ok, nonce = pcall(sodium.random_bytes, 24)
    if not ok then return nil, "secrets: " .. tostring(nonce) end
    local ok2, ct = pcall(sodium.aead_encrypt, plaintext, _ad(name), nonce, st.key)
    if not ok2 then return nil, "secrets: " .. tostring(ct) end
    return "x1:" .. to_hex(nonce .. ct)
end

local function _decrypt(st, name, stored)
    if not st.key then return nil, "secrets: master key not configured" end
    local hex = type(stored) == "string" and stored:match("^x1:(%x+)$")
    if not hex or #hex % 2 ~= 0 or #hex < 2 * (24 + 16) then
        return nil, "secrets: invalid stored ciphertext format"
    end
    local raw = from_hex(hex)
    local pt = sodium.aead_decrypt(raw:sub(25), _ad(name), raw:sub(1, 24), st.key)
    if not pt then
        return nil, "secrets: authentication failed (wrong master key, or the value was corrupted or tampered with)"
    end
    return pt
end

-- A stored secret's value through handle h, of one kind only — internal (luamemo's own key
-- material, which never leaves the process) or not (what an agent may use): one check for
-- every reader. → value | nil, "missing" | "internal" | "not internal" | the decryption error
local function _load(st, h, name, internal)
    local entry = h.first("SELECT value, internal FROM lm_secrets WHERE name = ?", name)
    if not entry then return nil, "missing" end
    if (entry.internal == 1) ~= internal then return nil, internal and "not internal" or "internal" end
    return _decrypt(st, name, entry.value)
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

local function valid_name(name)
    if type(name) ~= "string" or name == "" then return false end
    if #name > 128 then return false end
    return name:match("^[%w%.%-_]+$") ~= nil
end

local iso = util.us_to_iso

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local function reserved(name) return name:sub(1, #M.RESERVED_PREFIX) == M.RESERVED_PREFIX end

local NOT_CONFIGURED = "secrets: no vault key yet — store a secret with `memo secret-store NAME` in a "
    .. "terminal (it creates one), or set MEMO_MASTER_KEY_PATH"
M.NOT_CONFIGURED = NOT_CONFIGURED

--- Store (create or update) a secret in this store. opts.internal = true marks
--- it INTERNAL (luamemo's own key material): only an instance obtained via
--- M.open can write one, and the public API can't overwrite or delete it.
--- Returns {name, description, created_at, updated_at, internal} or nil, err.
function Store:put(name, value, description, opts)
    opts = opts or {}
    if not self.key then return nil, NOT_CONFIGURED end
    if not valid_name(name) then
        return nil, "secrets: name must be alphanumeric / hyphen / underscore / dot, max 128 chars"
    end
    if type(value) ~= "string" or value == "" then
        return nil, "secrets: value must be a non-empty string"
    end
    local internal = opts.internal == true
    if opts.public and (internal or reserved(name)) then
        return nil, ("secrets: names starting with %q are reserved for luamemo's internal secrets")
            :format(M.RESERVED_PREFIX)
    end

    local ciphertext, cerr = _encrypt(self, name, value)
    if not ciphertext then return nil, cerr end
    local h, herr = self:_db()
    if not h then return nil, herr end

    local out
    local ok, terr = h.transaction(function(t)
        local existing = t.first("SELECT internal FROM lm_secrets WHERE name = ?", name)
        if existing and existing.internal == 1 and not internal then
            error("secrets: " .. name .. " is an internal secret — it can't be replaced here", 0)
        end
        local now = util.now_us()
        out = t.first("INSERT INTO lm_secrets (name, value, description, internal, created_at, updated_at) "
            .. "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value, "
            .. "description = COALESCE(excluded.description, lm_secrets.description), "
            .. "internal = excluded.internal, updated_at = excluded.updated_at "
            .. "RETURNING name, description, created_at, updated_at",
            name, ciphertext, description, internal and 1 or 0, now, now)
        if not out then error("secrets: could not store " .. name, 0) end
    end)
    if not ok then return nil, (tostring(terr):gsub("^sqlite: transaction rolled back: ", "secrets: ")) end
    return { name = out.name, description = out.description, created_at = iso(out.created_at),
             updated_at = iso(out.updated_at), internal = internal }
end

--- Decrypt an INTERNAL secret for luamemo's own in-process use (e.g. signing
--- with a federation key). Ordinary secrets are refused — there is no general
--- read API; they are only ever injected by execute_with_secret.
function Store:get_internal(name)
    if not self:enabled() then return nil, NOT_CONFIGURED end
    if not valid_name(name) then return nil, "secrets: invalid name" end
    local h, err = self:_db()
    if not h then return nil, err end
    local value, why = _load(self, h, name, true)
    if why == "missing" then return nil, "secrets: not found: " .. name end
    if why == "not internal" then return nil, "secrets: " .. name .. " is not an internal secret" end
    return value, why
end

--- Permanently delete a secret. Internal secrets need opts.internal = true.
function Store:delete(name, opts)
    opts = opts or {}
    if not self:enabled() then return nil, NOT_CONFIGURED end
    if not valid_name(name) then return nil, "secrets: invalid name" end
    local h, herr = self:_db()
    if not h then return false, herr end
    local ok, terr = h.transaction(function(t)
        local entry = t.first("SELECT internal FROM lm_secrets WHERE name = ?", name)
        if not entry then error("secrets: not found: " .. name, 0) end
        if entry.internal == 1 and opts.internal ~= true then
            error("secrets: " .. name .. " is an internal secret — it can't be deleted here", 0)
        end
        assert(t.run("DELETE FROM lm_secrets WHERE name = ?", name))
    end)
    if not ok then return false, (tostring(terr):gsub("^sqlite: transaction rolled back: ", "secrets: ")) end
    return true
end

--- Names and metadata only — values are never included. `internal` marks
--- luamemo's own secrets.
function Store:list()
    local h = self:_db()
    if not h then return {} end
    local rows = h.query("SELECT name, description, created_at, updated_at, last_used_at, used_count, internal "
        .. "FROM lm_secrets ORDER BY name") or {}
    local out = {}
    for i, s in ipairs(rows) do
        out[i] = {
            name         = s.name,
            description  = s.description,
            created_at   = iso(s.created_at),
            updated_at   = iso(s.updated_at),
            last_used_at = iso(s.last_used_at),
            used_count   = s.used_count,
            internal     = s.internal == 1 or nil,
        }
    end
    return out
end

--- Store (create or update) a secret by name — the public API (MCP
--- secret_store, `memo secret-store`). Can't touch internal / reserved names.
--- @param name        string   Unique secret identifier
--- @param value       string   Plaintext secret value
--- @param description string?  Optional human-readable description
--- @return table|nil  {name, description, created_at, updated_at}
--- @return string|nil Error message
function M.store(name, value, description)
    return _default:put(name, value, description, { public = true })
end

--- Permanently delete a secret (public API — internal secrets are refused).
--- @param name  string  Secret name
--- @return bool   true on success
--- @return string|nil  Error message
function M.delete(name)
    return _default:delete(name)
end

--- List all secrets.  Returns names and metadata — values are never included.
--- @return table[]  {name, description, created_at, updated_at, last_used_at, used_count, internal?}[]
function M.list()
    return _default:list()
end

-- Create a master key file exclusively (never clobbers one another process
-- just created): directory 0700, key written to a temp file inside it, then
-- hard-linked into place (`ln` fails if the target exists).
local function create_master_key(path)
    util.private_dir(path:match("^(.*)[/\\][^/\\]+$"), true)
    local ok_rand, key = pcall(sodium.random_bytes, 32)
    if not ok_rand then return nil, tostring(key) end
    local tmp = path .. ".tmp." .. to_hex(sodium.random_bytes(6))
    local f = io.open(tmp, "w")
    if not f then return nil, "secrets: cannot write " .. tmp end
    f:write(to_hex(key), "\n")
    f:close()
    os.execute("chmod 600 " .. util.shell_quote(tmp))
    os.execute("ln " .. util.shell_quote(tmp) .. " " .. util.shell_quote(path) .. " 2>/dev/null")
    os.remove(tmp)
    return true
end

--- Set up the vault's key when none is configured: create the default key file (0600,
--- in a 0700 directory) unless it exists, and use it. For `memo secret-store` — people
--- set the vault up, an agent's secret_store doesn't. → path | nil, err
function M.create_default_key()
    if _key_configured then
        return nil, "secrets: the configured master key can't be used — check MEMO_MASTER_KEY_PATH / "
            .. "MEMO_MASTER_KEY_ENV / MEMO_MASTER_KEY"
    end
    local path = M.default_key_path()
    if not path then return nil, "secrets: no home directory for the vault key — set MEMO_MASTER_KEY_PATH" end
    if not _read_file(path) then
        local ok, err = create_master_key(path)
        if not ok then return nil, err end
    end
    local key, err = parse_key(_read_file(path) or "")
    if not key then return nil, "secrets: " .. path .. ": " .. tostring(err) end
    _default.key = key
    return path
end

-- Store files opened by M.open, one connection per path for the process.
local _files = {}
local function file_db(path)
    return function()
        if _files[path] then return _files[path] end
        local h, err = require("luamemo.db").open(path, { migrations = require("luamemo.schema").SECRETS_MIGRATIONS })
        if not h then return nil, err end
        _files[path] = h
        return h
    end
end

--- Open an independent store (e.g. the per-user federation keyring).
--- opts: file (its SQLite file, created 0600), master_key_path (64-hex key file),
---       create = true → create the key (0600, OS random source — fails
---       closed) and its directory (0700) when missing.
--- Returns a store (methods: enabled / put / get_internal / delete / list) or nil, err.
function M.open(opts)
    opts = opts or {}
    if type(opts.file) ~= "string" or opts.file == "" then return nil, "secrets.open: file required" end
    if type(opts.master_key_path) ~= "string" or opts.master_key_path == "" then
        return nil, "secrets.open: master_key_path required"
    end
    local raw = _read_file(opts.master_key_path)
    if not raw and opts.create then
        local ok, err = create_master_key(opts.master_key_path)
        if not ok then return nil, err end
        raw = _read_file(opts.master_key_path)
    end
    if not raw then return nil, "secrets.open: master key not found: " .. opts.master_key_path end
    local key, kerr = parse_key(raw)
    if not key then return nil, "secrets.open: " .. tostring(kerr) end
    return setmetatable({ db = file_db(opts.file), key = key }, Store)
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

-- Replace every plain occurrence of `needle` (no patterns: a value may hold any byte).
local function _replace_plain(s, needle, repl)
    if type(needle) ~= "string" or needle == "" then return s end
    local out, i = {}, 1
    while true do
        local a, b = s:find(needle, i, true)
        if not a then break end
        out[#out + 1] = s:sub(i, a - 1) .. repl
        i = b + 1
    end
    out[#out + 1] = s:sub(i)
    return table.concat(out)
end

-- The file a multipart field uploads. Always a regular file, not a symlink. With
-- `restrict` (the MCP tool — an agent picks the path; unchecked, a prompt-injected one
-- could send ~/.ssh keys or a project's .env to any public URL): only inside the project
-- directory (a path relative to it, or absolute within it; symlinked directories
-- resolved), never a hidden file or a credential file (luamemo.index.walker's list: .env,
-- keys, .luamemorc, …), and no uploads when the "project" is / or the home directory (a
-- client started outside any project). Without it (`memo secret-execute --form-file`,
-- typed by the file's owner) the path is taken as given. → the path | nil, why
local function _regular_file(p)
    local q = util.shell_quote(p)
    local r = os.execute("test -f " .. q .. " && test ! -L " .. q)
    return r == 0 or r == true
end
local function _upload_path(fpath, restrict)
    if type(fpath) ~= "string" or fpath == "" or fpath:find("%z") then return nil, "a file path is required" end
    if not restrict then
        if not _regular_file(fpath) then return nil, "not a regular file (or a symlink): " .. fpath end
        return fpath
    end
    local project = require("luamemo.settings").files().dir
    local real_proj = util.real_dir(project)
    local home = util.real_dir(os.getenv("HOME") or "")
    if not real_proj or real_proj == "/" or real_proj == home then
        return nil, "uploads need a project directory (the server isn't running in one)"
    end
    local full = fpath:sub(1, 1) == "/" and fpath or (project .. "/" .. fpath)
    local dir, base = full:match("^(.*)/([^/]+)$")
    local real = dir and util.real_dir(dir ~= "" and dir or "/")
    if not real or not (real == real_proj or real:sub(1, #real_proj + 1) == real_proj .. "/") then
        return nil, "only files inside the project directory can be uploaded (" .. real_proj .. ")"
    end
    local rel = (real == real_proj and "" or (real:sub(#real_proj + 2) .. "/")) .. base
    for part in rel:gmatch("[^/]+") do
        if part:sub(1, 1) == "." then return nil, "hidden files and directories can't be uploaded: " .. rel end
    end
    if require("luamemo.index.walker").is_secret(rel) then
        return nil, "credential files can't be uploaded: " .. rel
    end
    if not _regular_file(real .. "/" .. base) then return nil, "not a regular file (or a symlink): " .. rel end
    return real .. "/" .. base
end

-- A multipart part's field name / content type: no quote or line break (they go into
-- the part's headers).
local function _header_safe(s) return type(s) == "string" and not s:find('[\r\n"]') end

-- Build a multipart/form-data body from a field table.
-- fields: { field_name = string | { file = "path", content_type? = "..." } }
-- String values have {secret} substituted.  File contents are read as-is.
-- Returns body_string, content_type_header_value, err.
-- With `restrict` (the MCP tool) the files together are at most M.MAX_UPLOAD_BYTES:
-- each is read whole, so an agent naming a huge file would exhaust the server's memory.
M.MAX_UPLOAD_BYTES = 50 * 1024 * 1024

local function _build_multipart(fields, secret_value, restrict)
    -- Use CSPRNG for the boundary to guarantee both uniqueness and
    -- resistance to boundary-injection attacks via attacker-controlled content.
    local boundary = "luamemoBoundary" .. to_hex(sodium.random_bytes(8))

    local parts, total = {}, 0
    for field_name, spec in pairs(fields) do
        if not _header_safe(field_name) then
            return nil, nil, "secrets: multipart: a field name can't hold quotes or line breaks"
        end
        local disposition = 'Content-Disposition: form-data; name="' .. field_name .. '"'
        if type(spec) == "table" and spec.file then
            local fpath, perr = _upload_path(spec.file, restrict)
            if not fpath then
                return nil, nil, "secrets: multipart: field '" .. field_name .. "': " .. perr
            end
            local f = io.open(fpath, "rb")
            if not f then
                return nil, nil,
                    "secrets: multipart: cannot read file for field '" .. field_name .. "': " .. fpath
            end
            total = total + (f:seek("end") or 0)
            f:seek("set")
            if restrict and total > M.MAX_UPLOAD_BYTES then
                f:close()
                return nil, nil, ("secrets: multipart: the files are over %d MB together — not uploaded")
                    :format(M.MAX_UPLOAD_BYTES / 1048576)
            end
            local content = f:read("*all")
            f:close()
            local fname = fpath:match("([^/\\]+)$") or fpath
            local ct    = spec.content_type or "application/octet-stream"
            if not _header_safe(ct) or not _header_safe(fname) then
                return nil, nil, "secrets: multipart: a content type or file name can't hold quotes or line breaks"
            end
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
--- @param opts  table   { url, method?, headers?, body?, multipart?, timeout_ms?, max_bytes?,
---                        restrict_uploads? (files inside the project only — the MCP tool) }
---   multipart: { field_name = string | { file="/path", content_type?="..." } }
---   body and multipart are mutually exclusive.
--- @return string|nil  Response body (every copy of the secret masked; at most max_bytes)
--- @return string|nil  Error message
--- @return table|nil   { truncated, status }
function M.execute_with_secret(name, opts)
    if not M.enabled() then return nil, NOT_CONFIGURED end
    if not valid_name(name) then return nil, "secrets: invalid name" end
    opts = opts or {}
    if type(opts.url) ~= "string" or opts.url == "" then
        return nil, "secrets: execute_with_secret requires opts.url"
    end
    if opts.body and opts.multipart then
        return nil, "secrets: body and multipart are mutually exclusive"
    end

    -- SSRF guard: http:// / https:// only, parsed strictly (netguard.parse_url
    -- splits the URL the way the HTTP client does): no userinfo — an
    -- `x:y@host` authority would pass the check on `x` while the request goes
    -- to `host` — and no {secret} in the host / port part.
    local netguard = require("luamemo.netguard")
    local scheme, host, port = netguard.parse_url(opts.url)
    if not scheme then
        return nil, "secrets: execute_with_secret only allows http:// and https:// URLs "
            .. "(http[s]://host[:port]/…, no user@ part)"
    end
    if host:find("{secret}", 1, true) then
        return nil, "secrets: {secret} can't be placed in the URL's host part"
    end
    if host:lower() == "localhost" then
        return nil, "secrets: SSRF blocked: disallowed host " .. host
    end
    -- Public destinations only: every address the host resolves to (IPv4
    -- and IPv6) must be globally routable — no loopback, LAN, VPN overlay
    -- (Tailscale / CGNAT 100.64/10, IPv6 ULA), link-local, multicast or
    -- reserved range. Fail-closed: an unresolvable host is blocked.
    local ok_pub, why, ips = netguard.host_is_public(host)
    if not ok_pub then
        return nil, "secrets: SSRF blocked: " .. tostring(why)
    end
    -- DNS rebinding: a name that answered "public" to the check could answer
    -- "private" to a second lookup at connect time. For http:// the request
    -- therefore goes to the CHECKED address (Host header = the name). https://
    -- keeps the name so the certificate can be verified against it.
    local pinned_ip
    if scheme == "http" and not netguard.is_ip(host) then
        for _, ip in ipairs(ips or {}) do
            if not ip:find(":", 1, true) then pinned_ip = ip; break end
        end
        pinned_ip = pinned_ip or (ips and ips[1])
    end

    local h, serr = _default:_db()
    if not h then return nil, serr end

    -- luamemo's own key material never leaves the process — not even to a URL
    -- an agent picks (a prompt-injected agent could otherwise exfiltrate it).
    local value, derr = _load(_default, h, name, false)
    if derr == "missing" then return nil, "secrets: not found: " .. name end
    if derr == "internal" then
        return nil, "secrets: " .. name .. " is an internal secret — not usable by execute_with_secret"
    end
    if not value then return nil, derr end

    local url    = _substitute(opts.url, value)
    local method = (opts.method or "GET"):upper()

    local req_headers = {}
    if opts.headers then
        for k, v in pairs(opts.headers) do
            req_headers[k] = _substitute(tostring(v), value)
        end
    end
    if pinned_ip then
        -- The authority is fixed text ({secret} can't be in it), so the
        -- substituted URL is http://<authority> + the substituted path.
        local portpart = (port ~= "") and (":" .. port) or ""
        local has_host = false
        for k in pairs(req_headers) do if tostring(k):lower() == "host" then has_host = true end end
        if not has_host then req_headers["Host"] = host .. portpart end
        local ip_part = pinned_ip:find(":", 1, true) and ("[" .. pinned_ip .. "]") or pinned_ip
        local authority = opts.url:match("^http://([^/]*)")
        url = "http://" .. ip_part .. portpart .. url:sub(#("http://" .. authority) + 1)
    end

    local req_body
    if opts.multipart then
        -- Build multipart body *before* zeroing the secret so {secret} can
        -- appear in plain-field values.  File contents are never substituted.
        local mp_body, mp_ct, mp_err = _build_multipart(opts.multipart, value, opts.restrict_uploads)
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
    -- (The reference is cleared once the request is done: a failed request's
    -- error is scrubbed with it first.)

    -- Update usage tracking (best-effort).
    pcall(h.run, "UPDATE lm_secrets SET used_count = used_count + 1, last_used_at = ? WHERE name = ?",
        util.now_us(), name)

    local status, body, rerr, truncated = http.request(url, {
        method     = method,
        headers    = req_headers,
        body       = req_body,
        timeout_ms = tonumber(opts.timeout_ms) or 10000,
        max_bytes  = tonumber(opts.max_bytes),
    })
    if not status then
        -- The transport error quotes the URL it was given — the substituted one.
        -- The caller (an agent) gets its own {secret} template back instead, and
        -- any other copy of the value is masked.
        local msg = _replace_plain(tostring(rerr), util.redact_url(url), util.redact_url(opts.url))
        msg = M.mask(msg, value)
        value = nil
        return nil, "secrets: http request failed: " .. msg
    end
    -- A server that echoes the request (headers, body, the URL) would hand the value
    -- back: the response is masked before anyone sees it.
    body = M.mask(body, value)
    value = nil  -- clear reference; GC will reclaim when no other refs remain
    if status >= 300 and status < 400 then
        return nil, ("secrets: the server answered %d (a redirect) — redirects are not followed (the request "
            .. "and its secret would go to a host that was never checked); call the final URL directly"):format(status)
    end

    return body, nil, { truncated = truncated == true, status = status }
end

--- `text` with every copy of the secret `value` replaced by *** — as sent, URL-encoded
--- (upper / lower hex) and JSON-escaped (with and without "/" escaped: encoders differ).
--- A value under 4 characters is left alone (masking it would garble the text; such a
--- value isn't a secret anyway).
function M.mask(text, value)
    if type(text) ~= "string" or type(value) ~= "string" or #value < 4 then return text end
    local forms, seen = {}, {}
    local function add(f) if f ~= "" and not seen[f] then seen[f] = true; forms[#forms + 1] = f end end
    add(value)
    local enc = value:gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end)
    add(enc); add((enc:gsub("%%%x%x", function(h) return h:lower() end)))
    local js = value:gsub("\\", "\\\\"):gsub('"', '\\"')
    add(js); add((js:gsub("/", "\\/")))
    table.sort(forms, function(a, b) return #a > #b end)   -- longer forms first
    for _, f in ipairs(forms) do text = _replace_plain(text, f, "***") end
    return text
end

-- ---------------------------------------------------------------------------
-- resolve_headers — {secret:NAME} in the HTTP headers people configured for the
-- embedder / reranker / summarizer (MEMO_*_HEADERS). The endpoint comes from the
-- settings, which only people change (MCP can't), so no destination check here —
-- unlike execute_with_secret, whose URL an agent picks.
-- ---------------------------------------------------------------------------

local _resolved = setmetatable({}, { __mode = "k" })   -- headers table → its secret values
local _touched = {}                                    -- names whose last_used_at this process set

--- headers with each {secret:NAME} replaced by that secret from this database's vault
--- → the new table (handed straight to the request — never logged), or the same table
--- when nothing refers to the vault | nil, err (naming the secret, never a value).
--- Internal secrets are refused.
function M.resolve_headers(headers)
    if type(headers) ~= "table" then return {} end
    local refers = false
    for _, v in pairs(headers) do
        if type(v) == "string" and v:find("{secret:", 1, true) then refers = true end
    end
    if not refers then return headers end
    if not M.enabled() then
        return nil, "secrets: a header refers to the vault ({secret:…}), which has no key yet — store the "
            .. "secret with `memo secret-store NAME` in a terminal (it creates the key)"
    end
    local h, serr = _default:_db()
    if not h then return nil, serr end
    local out, values, err = {}, {}, nil
    for k, v in pairs(headers) do
        if type(v) == "string" and v:find("{secret:", 1, true) then
            v = v:gsub("{secret:([^}]*)}", function(name)
                if err then return "" end
                if not valid_name(name) then err = ("header %s: invalid secret name %q"):format(k, name); return "" end
                local value, derr = _load(_default, h, name, false)
                if derr == "missing" then
                    err = ("header %s: no secret named %s in the vault — store it: memo secret-store %s")
                        :format(k, name, name)
                    return ""
                end
                if derr == "internal" then err = name .. " is an internal secret — not usable in a header"; return "" end
                if not value then err = tostring(derr); return "" end
                value = value:gsub("[\r\n]+$", "")              -- a key stored from a file keeps its newline
                if value:find("[\r\n]") then err = name .. " holds a line break — it can't go in a header"; return "" end
                values[#values + 1] = value
                if not _touched[name] then
                    _touched[name] = true
                    pcall(h.run, "UPDATE lm_secrets SET last_used_at = ? WHERE name = ?", util.now_us(), name)
                end
                return value
            end)
            if err then return nil, "secrets: " .. err end
        end
        out[k] = v
    end
    _resolved[out] = values
    return out
end

--- text with every secret value resolve_headers put into `headers` masked — for an
--- error that may quote the request or the server's echo of it.
function M.scrub(text, headers)
    text = tostring(text)
    for _, value in ipairs(headers and _resolved[headers] or {}) do text = _replace_plain(text, value, "***") end
    return text
end

return M
