-- luamemo.native.sodium
-- The libsodium primitives luamemo uses, through LuaJIT's FFI. Every input size is
-- checked (a wrong size raises — it is a programming error, never data-dependent);
-- verification failures return false / nil.
--
--   random_bytes(n)                          → n random bytes
--   sign_seed_keypair(seed32)                → pk32, sk64        (Ed25519)
--   sign(msg, sk64) → sig64 ; verify(sig64, msg, pk32) → bool
--   ed25519_pk_to_x25519(pk32) → pk32 | nil ; ed25519_sk_to_x25519(sk64) → sk32
--   x25519_base(sk32) → pk32 ; x25519(sk32, pk32) → shared32 | nil (all-zero result refused)
--   aead_encrypt(msg, ad, nonce24, key32) → ciphertext (msg + 16-byte tag)   (XChaCha20-Poly1305)
--   aead_decrypt(ct, ad, nonce24, key32)  → msg | nil, "authentication failed"
--   sha256(msg) ; hmac_sha256(key, msg) ; hkdf_sha256(ikm, salt, info, len)  (RFC 5869)
--   to_base64(bytes) → text (standard alphabet, padded) ; from_base64(text) → bytes | nil
--   version() → "1.0.18" …
-- All values are Lua strings of raw bytes.

local loader = require("luamemo.native.loader")
local ffi = loader.ffi

pcall(ffi.cdef, [[
int sodium_init(void);
const char *sodium_version_string(void);
int sodium_library_version_major(void);
int sodium_library_version_minor(void);
void randombytes_buf(void * const buf, const size_t size);
int crypto_sign_ed25519_seed_keypair(unsigned char *pk, unsigned char *sk, const unsigned char *seed);
int crypto_sign_ed25519_detached(unsigned char *sig, unsigned long long *siglen_p, const unsigned char *m,
                                 unsigned long long mlen, const unsigned char *sk);
int crypto_sign_ed25519_verify_detached(const unsigned char *sig, const unsigned char *m, unsigned long long mlen,
                                        const unsigned char *pk);
int crypto_sign_ed25519_pk_to_curve25519(unsigned char *curve25519_pk, const unsigned char *ed25519_pk);
int crypto_sign_ed25519_sk_to_curve25519(unsigned char *curve25519_sk, const unsigned char *ed25519_sk);
int crypto_scalarmult_curve25519(unsigned char *q, const unsigned char *n, const unsigned char *p);
int crypto_scalarmult_curve25519_base(unsigned char *q, const unsigned char *n);
int crypto_aead_xchacha20poly1305_ietf_encrypt(unsigned char *c, unsigned long long *clen_p, const unsigned char *m,
    unsigned long long mlen, const unsigned char *ad, unsigned long long adlen, const unsigned char *nsec,
    const unsigned char *npub, const unsigned char *k);
int crypto_aead_xchacha20poly1305_ietf_decrypt(unsigned char *m, unsigned long long *mlen_p, unsigned char *nsec,
    const unsigned char *c, unsigned long long clen, const unsigned char *ad, unsigned long long adlen,
    const unsigned char *npub, const unsigned char *k);
size_t crypto_auth_hmacsha256_statebytes(void);
int crypto_auth_hmacsha256_init(void *state, const unsigned char *key, size_t keylen);
int crypto_auth_hmacsha256_update(void *state, const unsigned char *in, unsigned long long inlen);
int crypto_auth_hmacsha256_final(void *state, unsigned char *out);
int crypto_hash_sha256(unsigned char *out, const unsigned char *in, unsigned long long inlen);
size_t sodium_base64_encoded_len(const size_t bin_len, const int variant);
char *sodium_bin2base64(char * const b64, const size_t b64_maxlen, const unsigned char * const bin,
                        const size_t bin_len, const int variant);
int sodium_base642bin(unsigned char * const bin, const size_t bin_maxlen, const char * const b64,
                      const size_t b64_len, const char * const ignore, size_t * const bin_len,
                      const char ** const b64_end, const int variant);
]])

local M = {}

local lib, HMAC_STATE_BYTES
local function L()
    if lib then return lib end
    local l = loader.require("sodium")
    local maj, min = l.sodium_library_version_major(), l.sodium_library_version_minor()
    -- 1.0.18 reports library version 10.3; older releases report less.
    if maj < 10 or (maj == 10 and min < 3) then
        error(("native: libsodium %s is too old — luamemo needs 1.0.18 or newer (%s)")
            :format(ffi.string(l.sodium_version_string()), loader.LIBS.sodium.install), 3)
    end
    if l.sodium_init() < 0 then error("native: libsodium failed to initialise", 3) end
    lib = l
    HMAC_STATE_BYTES = tonumber(l.crypto_auth_hmacsha256_statebytes())
    return lib
end

local function need(v, n, what)
    if type(v) ~= "string" or (n and #v ~= n) then
        error(("sodium: %s must be %s"):format(what, n and (n .. " bytes") or "a string"), 3)
    end
end

local function buf(n) return ffi.new("unsigned char[?]", math.max(n, 1)) end

function M.version() return ffi.string(L().sodium_version_string()) end

function M.random_bytes(n)
    L()
    n = math.floor(tonumber(n) or -1)
    if n < 0 then error("sodium: random_bytes needs a byte count", 2) end
    local b = buf(n)
    lib.randombytes_buf(b, n)
    return ffi.string(b, n)
end

function M.sign_seed_keypair(seed)
    L(); need(seed, 32, "seed")
    local pk, sk = buf(32), buf(64)
    lib.crypto_sign_ed25519_seed_keypair(pk, sk, seed)
    return ffi.string(pk, 32), ffi.string(sk, 64)
end

function M.sign(msg, sk)
    L(); need(msg, nil, "message"); need(sk, 64, "secret key")
    local sig = buf(64)
    lib.crypto_sign_ed25519_detached(sig, nil, msg, #msg, sk)
    return ffi.string(sig, 64)
end

function M.verify(sig, msg, pk)
    L(); need(msg, nil, "message"); need(pk, 32, "public key")
    if type(sig) ~= "string" or #sig ~= 64 then return false end
    return lib.crypto_sign_ed25519_verify_detached(sig, msg, #msg, pk) == 0
end

function M.ed25519_pk_to_x25519(pk)
    L(); need(pk, 32, "public key")
    local out = buf(32)
    if lib.crypto_sign_ed25519_pk_to_curve25519(out, pk) ~= 0 then return nil end
    return ffi.string(out, 32)
end

function M.ed25519_sk_to_x25519(sk)
    L(); need(sk, 64, "secret key")
    local out = buf(32)
    lib.crypto_sign_ed25519_sk_to_curve25519(out, sk)
    return ffi.string(out, 32)
end

function M.x25519_base(sk)
    L(); need(sk, 32, "secret key")
    local out = buf(32)
    lib.crypto_scalarmult_curve25519_base(out, sk)
    return ffi.string(out, 32)
end

--- → shared32 | nil (libsodium refuses an all-zero result: a low-order peer key)
function M.x25519(sk, pk)
    L(); need(sk, 32, "secret key"); need(pk, 32, "public key")
    local out = buf(32)
    if lib.crypto_scalarmult_curve25519(out, sk, pk) ~= 0 then return nil end
    return ffi.string(out, 32)
end

M.AEAD_NONCE_BYTES, M.AEAD_KEY_BYTES, M.AEAD_TAG_BYTES = 24, 32, 16

function M.aead_encrypt(msg, ad, nonce, key)
    L(); need(msg, nil, "message"); need(nonce, 24, "nonce"); need(key, 32, "key")
    ad = ad or ""
    need(ad, nil, "additional data")
    local c, clen = buf(#msg + 16), ffi.new("unsigned long long[1]")
    lib.crypto_aead_xchacha20poly1305_ietf_encrypt(c, clen, msg, #msg, ad, #ad, nil, nonce, key)
    return ffi.string(c, tonumber(clen[0]))
end

function M.aead_decrypt(ct, ad, nonce, key)
    L(); need(nonce, 24, "nonce"); need(key, 32, "key")
    ad = ad or ""
    need(ad, nil, "additional data")
    if type(ct) ~= "string" or #ct < 16 then return nil, "authentication failed" end
    local m, mlen = buf(#ct - 16), ffi.new("unsigned long long[1]")
    if lib.crypto_aead_xchacha20poly1305_ietf_decrypt(m, mlen, nil, ct, #ct, ad, #ad, nonce, key) ~= 0 then
        return nil, "authentication failed"
    end
    return ffi.string(m, tonumber(mlen[0]))
end

function M.sha256(msg)
    L(); need(msg, nil, "message")
    local out = buf(32)
    lib.crypto_hash_sha256(out, msg, #msg)
    return ffi.string(out, 32)
end

function M.hmac_sha256(key, msg)
    L(); need(key, nil, "key"); need(msg, nil, "message")
    local st, out = ffi.new("unsigned char[?]", HMAC_STATE_BYTES), buf(32)
    lib.crypto_auth_hmacsha256_init(st, key, #key)
    lib.crypto_auth_hmacsha256_update(st, msg, #msg)
    lib.crypto_auth_hmacsha256_final(st, out)
    return ffi.string(out, 32)
end

local B64_ORIGINAL = 1   -- sodium_base64_VARIANT_ORIGINAL: standard alphabet, padded

function M.to_base64(bin)
    L(); need(bin, nil, "data")
    local n = tonumber(lib.sodium_base64_encoded_len(#bin, B64_ORIGINAL))
    local out = ffi.new("char[?]", n)
    lib.sodium_bin2base64(out, n, bin, #bin, B64_ORIGINAL)
    return ffi.string(out)
end

--- → bytes | nil when `s` is not exactly base64 (no stray characters)
function M.from_base64(s)
    L()
    if type(s) ~= "string" then return nil end
    local out, len = buf(#s), ffi.new("size_t[1]")
    if lib.sodium_base642bin(out, #s, s, #s, nil, len, nil, B64_ORIGINAL) ~= 0 then return nil end
    return ffi.string(out, tonumber(len[0]))
end

--- RFC 5869 HKDF-SHA256 (libsodium 1.0.18 has no HKDF API; built on its HMAC).
function M.hkdf_sha256(ikm, salt, info, len)
    need(ikm, nil, "input key material")
    salt, info = salt or "", info or ""
    need(salt, nil, "salt"); need(info, nil, "info")
    len = math.floor(tonumber(len) or -1)
    if len < 1 or len > 255 * 32 then error("sodium: hkdf length must be 1..8160", 2) end
    local prk = M.hmac_sha256(#salt > 0 and salt or string.rep("\0", 32), ikm)
    local out, t, i = {}, "", 1
    while #table.concat(out) < len do
        t = M.hmac_sha256(prk, t .. info .. string.char(i))
        out[#out + 1] = t
        i = i + 1
    end
    return table.concat(out):sub(1, len)
end

return M
