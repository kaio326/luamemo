-- luamemo.federation.channel
-- The federation wire protocol: a mutually authenticated, encrypted channel
-- between a dev and the org central (pure functions — no I/O, no storage).
--
-- Identities are Ed25519 keys (luamemo.federation.keys). The dev pins the
-- central's key (verified against the fingerprint the org admin gave it); the
-- central knows each dev's key from pairing.
--
-- Pairing (dev key → pending → admin approval):
--   pair_request(central_pk, dev_pk, identity, sign) → msg        (dev)
--   pair_verify(msg, central_pk)        → request | nil, err, http_status  (central)
--   pair_ack(request, status, sign)     → ack                      (central)
--   pair_check_ack(request_msg, ack, central_pk) → status | nil, err  (dev)
--   Both sides show keys.pairing_code(central_pk, dev_pk); the admin compares.
--
-- Handshake (one round trip; the pattern SIGMA / Noise-style designs use):
--   dev  → hello   { dev key, ephemeral X25519 key, ts, nonce, Ed25519 sig over
--                    the transcript — which also names the central's key —, and
--                    a MAC over it under the hello key }
--   central checks the dev key is APPROVED, then the MAC (one HMAC), and only
--   then the signature; answers welcome { its ephemeral key, session id, ttl,
--   Ed25519 sig over the hello hash + its fields }; the dev verifies with the
--   pinned key.
--   Hello key = HKDF(X25519 of the two STATIC identities — Ed25519 keys mapped
--   to X25519; reusing a key this way is proven safe, Thormarker 2021): both
--   sides compute it, nothing is exchanged or stored, and only the device's own
--   key can produce it — knowing a device's public key lets nobody make the
--   central do signature work, nor lock that device out.
--   Session keys = HKDF-SHA256(X25519(eph, eph), salt = SHA-256(hello ‖ welcome))
--   → one c2s and one s2c key. Ephemeral keys → forward secrecy.
--
-- Envelope (every request / response after the handshake):
--   "LMC2" ‖ session id (16) ‖ n (8, big-endian) ‖ ciphertext ‖ tag (16)
--   XChaCha20-Poly1305 (libsodium) under the direction's key; nonce = n ‖ 0^16;
--   associated data = dir ‖ session ‖ n (the header is authenticated too).
--   n strictly increases per request (replay / reorder protection, checked by
--   the caller); the response reuses the request's n under the s2c key, which
--   binds each response to its request — a nonce never repeats under one key.
-- All primitives are libsodium's (luamemo.native.sodium). Version 2 of the
-- handshake / "LMC2" frames: version-1 peers (pure-Lua AES-CTR + HMAC) are refused.

local sodium = require("luamemo.native.sodium")
local util   = require("luamemo.util")
local common = require("luamemo.federation.common")

local M = {}

M.VERSION     = 2
M.MAGIC       = "LMC2"
M.SESSION_TTL = 600        -- seconds a session lives on the central
M.MAX_SKEW    = 300        -- tolerated clock difference for hello / pair (seconds)
M.HEADER_LEN  = 4 + 16 + 8
M.TAG_LEN     = 16
M.MAX_IDENTITY = 254

local floor = math.floor
local ZERO16 = string.rep("\0", 16)

local hex, unhex = util.to_hex, util.from_hex
M.hex, M.unhex = hex, unhex

local function verify(pk, msg, sig) return sodium.verify(sig, msg, pk) end

local function u64be(n)
    local b = {}
    for i = 8, 1, -1 do b[i] = n % 256; n = floor(n / 256) end
    return string.char(b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8])
end
local function read_u64be(s, i)
    local n = 0
    for j = i, i + 7 do n = n * 256 + s:byte(j) end
    return n
end

-- A hex field of exactly `nbytes` bytes → binary, else nil.
local function field(t, k, nbytes)
    local v = t[k]
    if type(v) ~= "string" or #v ~= 2 * nbytes or not v:match("^%x+$") then return nil end
    return unhex(v)
end

local function int_field(t, k)
    local v = tonumber(t[k])
    if not v or v < 0 or v ~= floor(v) or v >= 2 ^ 53 then return nil end
    return v
end

-- ---------------------------------------------------------------------------
-- Pairing
-- ---------------------------------------------------------------------------

local function pair_transcript(central_pk, dev_pk, identity, ts, nonce)
    return "luamemo-pair-v1" .. central_pk .. dev_pk .. u64be(#identity) .. identity .. u64be(ts) .. nonce
end

function M.pair_request(central_pk, dev_pk, identity, sign, now)
    local ts, nonce = now or os.time(), sodium.random_bytes(16)
    local sig, err = sign(pair_transcript(central_pk, dev_pk, identity, ts, nonce))
    if not sig then return nil, err end
    return { v = M.VERSION, central_pk = hex(central_pk), dev_pk = hex(dev_pk), identity = identity,
             ts = ts, nonce = hex(nonce), sig = hex(sig) }
end

--- Central: validate a pairing request. Returns { dev_pk, identity, transcript } or nil, err, status.
function M.pair_verify(msg, central_pk, now)
    if type(msg) ~= "table" or msg.v ~= M.VERSION then return nil, "unsupported pairing version", 400 end
    local cpk, dpk = field(msg, "central_pk", 32), field(msg, "dev_pk", 32)
    local nonce, sig, ts = field(msg, "nonce", 16), field(msg, "sig", 64), int_field(msg, "ts")
    local identity = msg.identity
    if not (cpk and dpk and nonce and sig and ts) or type(identity) ~= "string"
       or #identity > M.MAX_IDENTITY or not require("luamemo.federation.identity").valid(identity) then
        return nil, "malformed pairing request (identity must be user:<email>)", 400
    end
    if cpk ~= central_pk then
        return nil, "this request was meant for a different central — re-check the fingerprint you pinned", 409
    end
    if math.abs((now or os.time()) - ts) > M.MAX_SKEW then return nil, "clock skew too large", 400 end
    local t = pair_transcript(cpk, dpk, identity, ts, nonce)
    if not verify(dpk, t, sig) then return nil, "bad pairing signature", 401 end
    return { dev_pk = dpk, identity = identity:lower(), transcript = t }
end

function M.pair_ack(request, status, sign)
    local sig = sign("luamemo-pair-ack-v1" .. sodium.sha256(request.transcript) .. status)
    return { v = M.VERSION, status = status, sig = hex(sig) }
end

--- Dev: verify the central's signed answer to our pairing request.
function M.pair_check_ack(request_msg, ack, central_pk)
    if type(ack) ~= "table" or type(ack.status) ~= "string" then return nil, "malformed pairing answer" end
    local sig = field(ack, "sig", 64)
    local t = pair_transcript(central_pk, unhex(request_msg.dev_pk), request_msg.identity, request_msg.ts,
        unhex(request_msg.nonce))
    if not sig or not verify(central_pk, "luamemo-pair-ack-v1" .. sodium.sha256(t) .. ack.status, sig) then
        return nil, "the central's pairing answer is not signed by the pinned key"
    end
    return ack.status
end

-- ---------------------------------------------------------------------------
-- Handshake
-- ---------------------------------------------------------------------------

local function hello_transcript(central_pk, dev_pk, eph, ts, nonce)
    return "luamemo-hello-v1" .. central_pk .. dev_pk .. eph .. u64be(ts) .. nonce
end

-- Everything the welcome tells the dev is signed — including the identity the
-- central attributes this device to.
local function welcome_transcript(hello_t, eph, sid, ttl, identity)
    return "luamemo-welcome-v2" .. sodium.sha256(hello_t) .. eph .. sid .. u64be(ttl)
        .. u64be(#identity) .. identity
end

-- 64 bytes: the c2s key, then the s2c key
local function derive(shared, hello_t, welcome_t)
    return sodium.hkdf_sha256(shared, sodium.sha256(hello_t .. welcome_t), "luamemo-session-v2", 64)
end

--- The hello key from the static X25519 secret of the two identities
--- (keys.dh(role, peer_pk) — on the dev with the central's key, on the central
--- with the dev's).
function M.hello_key(static_shared, central_pk, dev_pk)
    return sodium.hkdf_sha256(static_shared, "luamemo-hello-key-v2", central_pk .. dev_pk, 32)
end

local function hello_mac(key, t) return sodium.hmac_sha256(key, "luamemo-hello-mac-v2" .. t) end

--- Dev: start a handshake. sign(msg) signs with the dev identity key;
--- hello_key = M.hello_key(…) for this device and central.
function M.client_hello(central_pk, dev_pk, sign, hello_key, now)
    assert(type(hello_key) == "string" and #hello_key == 32, "client_hello: hello_key required")
    local eph_sk = sodium.random_bytes(32)
    local eph = sodium.x25519_base(eph_sk)
    local ts, nonce = now or os.time(), sodium.random_bytes(16)
    local t = hello_transcript(central_pk, dev_pk, eph, ts, nonce)
    local sig, err = sign(t)
    if not sig then return nil, err end
    return { v = M.VERSION, central_pk = hex(central_pk), dev_pk = hex(dev_pk), eph = hex(eph), ts = ts,
             nonce = hex(nonce), sig = hex(sig), mac = hex(hello_mac(hello_key, t)) },
           { eph_sk = eph_sk, transcript = t, central_pk = central_pk }
end

--- Central: answer a hello. opts: central_pk, sign (central identity signer),
--- lookup(dev_pk) → { id, identity, status } | nil — consulted FIRST, so an
--- unknown or unapproved key costs nothing; hello_key(dev_pk) → the device's
--- hello key — its MAC is checked before any signature work; now, ttl.
--- Returns welcome, session { id, keys, dev, ttl } — or nil, err, http_status
--- [, reason "unknown" | "pending" | "removed" | "mac" for a refused hello].
function M.server_accept(msg, opts)
    if type(msg) ~= "table" or msg.v ~= M.VERSION then return nil, "unsupported handshake version", 400 end
    local cpk, dpk, eph = field(msg, "central_pk", 32), field(msg, "dev_pk", 32), field(msg, "eph", 32)
    local nonce, sig, ts = field(msg, "nonce", 16), field(msg, "sig", 64), int_field(msg, "ts")
    local mac = field(msg, "mac", 32)
    if not (cpk and dpk and eph and nonce and sig and ts and mac) then return nil, "malformed hello", 400 end
    if cpk ~= opts.central_pk then
        return nil, "hello meant for a different central — re-check the fingerprint you pinned", 409
    end
    local dev = opts.lookup(dpk)
    if not dev then return nil, "unknown device key — pair it first (memo org pair)", 403, "unknown" end
    if dev.status == "pending" then
        return nil, "pairing pending — the org admin has not approved this device yet", 403, "pending"
    end
    if dev.status ~= "approved" then return nil, "this device key is not approved", 403, "removed" end
    if math.abs((opts.now or os.time()) - ts) > M.MAX_SKEW then return nil, "clock skew too large", 400 end
    local t = hello_transcript(cpk, dpk, eph, ts, nonce)
    local hk = opts.hello_key(dpk)
    if not hk or not common.secure_eq(hello_mac(hk, t), mac) then
        return nil, "hello not authenticated by this device's key", 401, "mac"
    end
    if not verify(dpk, t, sig) then return nil, "bad hello signature", 401 end

    local e_sk = sodium.random_bytes(32)
    local e_pk = sodium.x25519_base(e_sk)
    local shared = sodium.x25519(e_sk, eph)
    if not shared then return nil, "x25519: low-order ephemeral key refused", 400 end
    local sid, ttl = sodium.random_bytes(16), opts.ttl or M.SESSION_TTL
    local identity = tostring(dev.identity or "")
    local wt = welcome_transcript(t, e_pk, sid, ttl, identity)
    return { v = M.VERSION, eph = hex(e_pk), session = hex(sid), ttl = ttl, sig = hex(opts.sign(wt)),
             identity = identity },
           { id = sid, keys = derive(shared, t, wt), dev = dev, ttl = ttl }
end

--- Dev: finish the handshake with the central's welcome.
--- Returns session { id, keys, n, ttl, identity } or nil, err.
function M.client_finish(state, msg)
    if type(msg) ~= "table" or msg.v ~= M.VERSION then return nil, "unsupported handshake version" end
    local e_pk, sid, sig, ttl = field(msg, "eph", 32), field(msg, "session", 16), field(msg, "sig", 64),
        int_field(msg, "ttl")
    if not (e_pk and sid and sig and ttl) or type(msg.identity) ~= "string" then return nil, "malformed welcome" end
    local wt = welcome_transcript(state.transcript, e_pk, sid, ttl, msg.identity)
    if not verify(state.central_pk, wt, sig) then
        return nil, "the central's handshake is not signed by the pinned key — refusing (possible impersonation)"
    end
    local shared = sodium.x25519(state.eph_sk, e_pk)
    if not shared then return nil, "x25519: low-order ephemeral key refused" end
    return { id = sid, keys = derive(shared, state.transcript, wt), n = 0, ttl = ttl,
             identity = msg.identity }
end

-- ---------------------------------------------------------------------------
-- Envelope
-- ---------------------------------------------------------------------------

local DIR = { c2s = 1, s2c = 33 }   -- offset of the direction's key in the session keys

--- Encrypt + authenticate `plaintext` as message `n` in direction dir ("c2s" | "s2c").
function M.seal(keys, sid, dir, n, plaintext)
    local off = assert(DIR[dir], "seal: dir must be c2s or s2c")
    local nb = u64be(n)
    local ct = sodium.aead_encrypt(plaintext, dir .. sid .. nb, nb .. ZERO16, keys:sub(off, off + 31))
    return M.MAGIC .. sid .. nb .. ct
end

--- Header only (no verification): session id + n, for the session lookup.
function M.peek(bytes)
    if type(bytes) ~= "string" or #bytes < M.HEADER_LEN + M.TAG_LEN or bytes:sub(1, 4) ~= M.MAGIC then
        if type(bytes) == "string" and bytes:sub(1, 4) == "LMC1" then
            return nil, "a version-1 federation envelope — update luamemo on both ends (protocol 3)"
        end
        return nil, "not a federation envelope"
    end
    -- Counters stay below 2^53 (exact as a double, no integer wrap on 5.3+).
    if bytes:byte(21) ~= 0 or bytes:byte(22) >= 0x20 then
        return nil, "message counter out of range"
    end
    return bytes:sub(5, 20), read_u64be(bytes, 21)
end

--- Verify and decrypt. Returns plaintext, n — or nil, err.
function M.unseal(keys, sid, dir, bytes)
    local off = assert(DIR[dir], "unseal: dir must be c2s or s2c")
    local got_sid, n = M.peek(bytes)
    if not got_sid then return nil, n end
    if got_sid ~= sid then return nil, "session mismatch" end
    local nb, ct = bytes:sub(21, 28), bytes:sub(29)
    local pt = sodium.aead_decrypt(ct, dir .. sid .. nb, nb .. ZERO16, keys:sub(off, off + 31))
    if not pt then return nil, "message authentication failed" end
    return pt, n
end

return M
