-- luamemo.federation.keys
-- This machine's federation identity: an Ed25519 key pair per role ("dev" or
-- "central"), kept in a PER-USER keyring — one identity serves every project
-- and every org of this user (like an SSH key).
--
--   keys.dir()                            → keyring directory
--   keys.ensure_identity(role)            → public key (created on first use)
--   keys.public_key(role)                 → public key | nil (none yet)
--   keys.sign(role, msg)                  → 64-byte signature | nil, err
--   keys.dh(role, peer_pk)                → static X25519 secret with a peer | nil, err
--   keys.forget_identity(role)            → true | nil, err
--   keys.fingerprint(pk)                  → "XXXX-XXXX-XXXX-XXXX-XXXX" (public; 100 bits)
--   keys.pairing_code(central_pk, dev_pk) → "XXXX-XXXX" (public; 40 bits)
--   keys.normalize_code(s)                → canonical form for comparisons
--
-- The keyring is a luamemo secrets store (luamemo.secrets.open, keyring.db):
-- XChaCha20-Poly1305 encrypted at rest, master key in a 0600 file, directory
-- 0700, both created on first use from the OS random source (fails closed). Private keys
-- are INTERNAL secrets: never returned by any API, never usable by
-- secret_execute, not overwritable / deletable through the public secrets
-- API. They are decrypted only inside keys.sign / keys.dh.
--
-- Location (first match): config `federation_dir`, env MEMO_FEDERATION_DIR,
-- $XDG_CONFIG_HOME/luamemo, $HOME/.config/luamemo.

local sodium  = require("luamemo.native.sodium")
local secrets = require("luamemo.secrets")

local M = {}

M.ROLES = { dev = "luamemo.identity.dev", central = "luamemo.identity.central" }

local _dir_override

--- Tests / embedding: pin the keyring directory (nil restores the default).
function M.set_dir(path) _dir_override = path end

function M.dir()
    if _dir_override then return _dir_override end
    local lm = package.loaded["luamemo"]
    local cfg = type(lm) == "table" and type(lm.config) == "table" and lm.config or {}
    if type(cfg.federation_dir) == "string" and cfg.federation_dir ~= "" then return cfg.federation_dir end
    local env = os.getenv("MEMO_FEDERATION_DIR")
    if env and env ~= "" then return env end
    local xdg = os.getenv("XDG_CONFIG_HOME")
    if xdg and xdg ~= "" then return xdg .. "/luamemo" end
    local home = os.getenv("HOME")
    if not home or home == "" then return nil end
    return home .. "/.config/luamemo"
end

local function keyring(create)
    local dir = M.dir()
    if not dir then return nil, "federation keyring: no home directory (set MEMO_FEDERATION_DIR)" end
    return secrets.open({ file = dir .. "/keyring.db", master_key_path = dir .. "/keyring.key",
                          create = create })
end

local function name_of(role)
    local n = M.ROLES[role]
    if not n then error("federation keys: role must be 'dev' or 'central' (got " .. tostring(role) .. ")", 3) end
    return n
end

-- Public keys are public: cached per (keyring dir, role) so a busy central
-- doesn't re-derive its key (decrypt + scalar multiplication) per handshake.
local _pk = {}
local function cache_key(role) return tostring(M.dir()) .. "\0" .. role end

function M.public_key(role)
    local name = name_of(role)
    local ck = cache_key(role)
    if _pk[ck] then return _pk[ck] end
    local ring = keyring(false)
    if not ring then return nil end
    local seed = ring:get_internal(name)
    if not seed then return nil end
    _pk[ck] = (sodium.sign_seed_keypair(seed))
    return _pk[ck]
end

function M.ensure_identity(role)
    local name = name_of(role)
    local pk = M.public_key(role)
    if pk then return pk end
    local ring, err = keyring(true)
    if not ring then return nil, err end
    local seed = sodium.random_bytes(32)
    local ok, perr = ring:put(name, seed,
        ("federation identity (%s) %s"):format(role, M.fingerprint((sodium.sign_seed_keypair(seed)))),
        { internal = true })
    if not ok then return nil, perr end
    -- Re-read: if another process created one concurrently, the stored key wins.
    return M.public_key(role)
end

function M.sign(role, msg)
    local name = name_of(role)
    local ring, err = keyring(false)
    if not ring then return nil, err end
    local seed, gerr = ring:get_internal(name)
    if not seed then return nil, gerr or ("federation keys: no " .. role .. " identity yet") end
    local _, sk = sodium.sign_seed_keypair(seed)
    return sodium.sign(msg, sk)
end

--- The static X25519 secret between this role's identity and a peer's Ed25519
--- public key (both mapped to X25519) | nil, err. The seed never leaves here.
function M.dh(role, peer_pk)
    local name = name_of(role)
    local ring, err = keyring(false)
    if not ring then return nil, err end
    local seed, gerr = ring:get_internal(name)
    if not seed then return nil, gerr or ("federation keys: no " .. role .. " identity yet") end
    if type(peer_pk) ~= "string" or #peer_pk ~= 32 then return nil, "federation keys: bad peer public key" end
    local peer_x = sodium.ed25519_pk_to_x25519(peer_pk)
    if not peer_x then return nil, "federation keys: peer key is not a valid Ed25519 point" end
    local _, sk = sodium.sign_seed_keypair(seed)
    local shared = sodium.x25519(sodium.ed25519_sk_to_x25519(sk), peer_x)
    if not shared then return nil, "federation keys: low-order peer key refused" end
    return shared
end

-- Hello keys by role ‖ central key ‖ device key: one X25519 per pair per process, not one
-- per handshake. Bounded — a central meets every approved device.
local _hello, _hello_n = {}, 0

--- The handshake's hello key between a central and a device (channel.hello_key over the
--- static secret), for `role` — "dev" (the peer is the central) or "central" | nil, err.
function M.hello_key(role, central_pk, dev_pk)
    local ck = role .. central_pk .. dev_pk
    local k = _hello[ck]
    if k then return k end
    local shared, err = M.dh(role, role == "dev" and central_pk or dev_pk)
    if not shared then return nil, err end
    if _hello_n >= 4096 then _hello, _hello_n = {}, 0 end
    k = require("luamemo.federation.channel").hello_key(shared, central_pk, dev_pk)
    _hello[ck], _hello_n = k, _hello_n + 1
    return k
end
function M._reset_hello() _hello, _hello_n = {}, 0 end   -- tests

function M.forget_identity(role)
    local name = name_of(role)
    _pk[cache_key(role)] = nil
    local ring, err = keyring(false)
    if not ring then return nil, err end
    return ring:delete(name, { internal = true })
end

-- Crockford base32 (no I, L, O, U — unambiguous when read aloud).
local B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

local function b32(bytes, nchars)
    local out, acc, bits = {}, 0, 0
    for i = 1, #bytes do
        acc = acc * 256 + bytes:byte(i)
        bits = bits + 8
        while bits >= 5 and #out < nchars do
            bits = bits - 5
            local v = math.floor(acc / 2 ^ bits) % 32
            out[#out + 1] = B32:sub(v + 1, v + 1)
        end
        acc = acc % 2 ^ bits
        if #out >= nchars then break end
    end
    return table.concat(out)
end

local function group(s, n)
    local parts = {}
    for i = 1, #s, n do parts[#parts + 1] = s:sub(i, i + n - 1) end
    return table.concat(parts, "-")
end

--- Public key → human-comparable fingerprint (100 bits, 20 base32 chars).
function M.fingerprint(pk)
    assert(type(pk) == "string" and #pk == 32, "fingerprint: 32-byte public key expected")
    return group(b32(sodium.sha256("luamemo-fingerprint-v1" .. pk), 20), 4)
end

--- Code both sides display during pairing; binds BOTH public keys (40 bits —
--- far too many to grind a colliding key within a pairing window).
function M.pairing_code(central_pk, dev_pk)
    assert(type(central_pk) == "string" and #central_pk == 32 and type(dev_pk) == "string" and #dev_pk == 32,
        "pairing_code: 32-byte public keys expected")
    return group(b32(sodium.sha256("luamemo-pairing-v1" .. central_pk .. dev_pk), 8), 4)
end

--- Canonical form of a typed fingerprint / code: case, dashes and spaces
--- ignored; Crockford look-alikes O→0 and I/L→1.
function M.normalize_code(s)
    local out = tostring(s or ""):upper():gsub("[%s%-]", ""):gsub("O", "0"):gsub("[IL]", "1")
    return out
end

return M
