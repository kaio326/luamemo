-- luamemo/crypto.lua
-- Pure Lua 5.1 AES-256-CBC + HMAC-SHA256 + CSPRNG.
-- No external dependencies.  Works in plain Lua 5.1, LuaJIT, and OpenResty.
--
-- Public API:
--   crypto.random_bytes(n)           → binary string of n random bytes
--   crypto.hmac_sha256(key, msg)     → 32-byte binary digest
--   crypto.aes256cbc_encrypt(key, iv, plaintext)  → ciphertext (PKCS7 padded)
--   crypto.aes256cbc_decrypt(key, iv, ciphertext) → plaintext | nil, err
--
-- All functions accept and return raw binary strings.
-- key must be exactly 32 bytes; iv must be exactly 16 bytes.
--
-- Design notes:
--   - SHA-256 is a straightforward table-driven implementation.
--   - AES uses the standard S-box / key-schedule / MixColumns approach.
--   - HMAC follows RFC 2104.
--   - CSPRNG: in OpenResty uses ngx.var (via ngx.now + worker pid xor) seeded
--     OS source when available; outside OpenResty reads /dev/urandom directly.
--     The implementation below reads /dev/urandom and falls back to a
--     xorshift64* PRNG seeded from os.time + os.clock only as a last resort
--     (clearly documented; callers are warned).

local M = {}

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

local band, bor, bxor, bnot, lshift, rshift, arshift
do
    local ok, bit = pcall(require, "bit")          -- LuaJIT / OpenResty
    if not ok then
        ok, bit = pcall(require, "bit32")          -- Lua 5.2+
    end
    if ok then
        band    = bit.band
        bor     = bit.bor
        bxor    = bit.bxor
        bnot    = bit.bnot
        lshift  = bit.lshift
        rshift  = bit.rshift
        arshift = bit.arshift or rshift
    else
        -- Pure-Lua 5.1 fallback using the 2^32 modular arithmetic trick.
        local MAX = 2^32
        band  = function(a, b)
            local r, p = 0, 1
            for _ = 1, 32 do
                local ra = a % 2; local rb = b % 2
                if ra == 1 and rb == 1 then r = r + p end
                a = (a - ra) / 2; b = (b - rb) / 2; p = p * 2
            end
            return r
        end
        bor   = function(a, b)
            local r, p = 0, 1
            for _ = 1, 32 do
                local ra = a % 2; local rb = b % 2
                if ra == 1 or rb == 1 then r = r + p end
                a = (a - ra) / 2; b = (b - rb) / 2; p = p * 2
            end
            return r
        end
        bxor  = function(a, b)
            local r, p = 0, 1
            for _ = 1, 32 do
                local ra = a % 2; local rb = b % 2
                if ra ~= rb then r = r + p end
                a = (a - ra) / 2; b = (b - rb) / 2; p = p * 2
            end
            return r
        end
        bnot  = function(a) return MAX - 1 - a end
        -- Mask high bits BEFORE multiplying to stay within 2^53 float precision.
        -- (a * 2^n) can overflow for 32-bit `a` with large n, so we drop the
        -- bits that would shift past bit 31 first: a % 2^(32-n) ≤ 2^(32-n)-1,
        -- then * 2^n ≤ 2^32-1 — always < 2^53. No precision loss.
        lshift = function(a, n) return (a % 2^(32-n)) * 2^n end
        rshift = function(a, n) return math.floor(a / 2^n) % MAX end
        arshift = rshift
    end
end

-- Rotate right 32-bit integer by n bits.
local function ror32(x, n) return bor(rshift(x, n), lshift(x, 32 - n)) end

-- Pack four bytes (big-endian) into a 32-bit integer.
local function bytes_to_word(b, i)
    return bor(bor(bor(lshift(b:byte(i), 24),
                       lshift(b:byte(i+1), 16)),
                       lshift(b:byte(i+2), 8)),
                       b:byte(i+3))
end

-- Unpack a 32-bit integer into four bytes (big-endian).
local function word_to_bytes(w)
    return string.char(band(rshift(w, 24), 0xff))
        .. string.char(band(rshift(w, 16), 0xff))
        .. string.char(band(rshift(w,  8), 0xff))
        .. string.char(band(w, 0xff))
end

-- ---------------------------------------------------------------------------
-- SHA-256
-- (FIPS 180-4)
-- ---------------------------------------------------------------------------

local SHA256_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256_compress(h, block)
    local w = {}
    for i = 1, 16 do w[i] = bytes_to_word(block, (i-1)*4+1) end
    for i = 17, 64 do
        local s0 = bxor(ror32(w[i-15], 7),  bxor(ror32(w[i-15], 18), rshift(w[i-15], 3)))
        local s1 = bxor(ror32(w[i-2],  17), bxor(ror32(w[i-2],  19), rshift(w[i-2],  10)))
        w[i] = (w[i-16] + s0 + w[i-7] + s1) % 0x100000000
    end
    local a,b,c,d,e,f,g,hh = h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8]
    for i = 1, 64 do
        local S1   = bxor(ror32(e,6), bxor(ror32(e,11), ror32(e,25)))
        local ch   = bxor(band(e,f), band(bnot(e),g))
        local temp1= (hh + S1 + ch + SHA256_K[i] + w[i]) % 0x100000000
        local S0   = bxor(ror32(a,2), bxor(ror32(a,13), ror32(a,22)))
        local maj  = bxor(band(a,b), bxor(band(a,c), band(b,c)))
        local temp2= (S0 + maj) % 0x100000000
        hh=g; g=f; f=e
        e = (d + temp1) % 0x100000000
        d=c; c=b; b=a
        a = (temp1 + temp2) % 0x100000000
    end
    h[1]=(h[1]+a)%0x100000000; h[2]=(h[2]+b)%0x100000000
    h[3]=(h[3]+c)%0x100000000; h[4]=(h[4]+d)%0x100000000
    h[5]=(h[5]+e)%0x100000000; h[6]=(h[6]+f)%0x100000000
    h[7]=(h[7]+g)%0x100000000; h[8]=(h[8]+hh)%0x100000000
end

local function sha256(msg)
    local h = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }
    local len = #msg
    -- PKCS padding: append 0x80, then zeros, then 64-bit big-endian bit length.
    -- The zero-padding length is chosen so total length ≡ 0 (mod 64).
    local pad_zeros = (55 - len) % 64   -- gives 0..63 zero bytes
    local bits_lo = (len * 8) % 0x100000000
    local bits_hi = math.floor(len * 8 / 0x100000000) % 0x100000000
    msg = msg .. string.char(0x80)
              .. string.rep("\0", pad_zeros)
              .. word_to_bytes(bits_hi)
              .. word_to_bytes(bits_lo)
    assert(#msg % 64 == 0, "sha256 padding bug: " .. #msg)
    for i = 1, #msg, 64 do
        sha256_compress(h, msg:sub(i, i+63))
    end
    local out = ""
    for i = 1, 8 do out = out .. word_to_bytes(h[i]) end
    return out
end

-- ---------------------------------------------------------------------------
-- HMAC-SHA256  (RFC 2104)
-- ---------------------------------------------------------------------------

local HMAC_BLOCK = 64

function M.hmac_sha256(key, msg)
    assert(type(key) == "string" and type(msg) == "string")
    if #key > HMAC_BLOCK then key = sha256(key) end
    key = key .. string.rep("\0", HMAC_BLOCK - #key)
    local ipad = key:gsub(".", function(c) return string.char(bxor(c:byte(), 0x36)) end)
    local opad = key:gsub(".", function(c) return string.char(bxor(c:byte(), 0x5c)) end)
    return sha256(opad .. sha256(ipad .. msg))
end

-- ---------------------------------------------------------------------------
-- CSPRNG
-- Reads from /dev/urandom (POSIX; available on Linux, macOS, BSDs, WSL).
-- Falls back to a xorshift64* PRNG seeded with os.time() + os.clock() —
-- clearly inadequate for high-security use but prevents hard failures in
-- environments without /dev/urandom (e.g., bare Windows).
-- In production always ensure /dev/urandom is available.
-- ---------------------------------------------------------------------------

local _urandom_warned = false

function M.random_bytes(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local b = f:read(n)
        f:close()
        if b and #b == n then return b end
    end
    -- Fallback: warn once then use xorshift64*.
    if not _urandom_warned then
        _urandom_warned = true
        io.stderr:write("luamemo/crypto: WARNING: /dev/urandom unavailable; "
            .. "using weak PRNG. Do not use in production.\n")
    end
    -- xorshift64* seeded from time + clock + address of a new table.
    local seed = math.floor(os.time() * 1000 + os.clock() * 1e9)
                 + tonumber(tostring({}):match("0x(.+)") or "0", 16)
    local state = seed % 0x100000000
    local out = {}
    for _ = 1, n do
        state = bxor(state, lshift(state, 13)) % 0x100000000
        state = bxor(state, rshift(state, 7))  % 0x100000000
        state = bxor(state, lshift(state, 17)) % 0x100000000
        out[#out+1] = string.char(state % 256)
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- AES-256
-- (FIPS 197 — Electronic Codebook core; CBC + PKCS7 built on top)
-- ---------------------------------------------------------------------------

-- AES S-box (FIPS 197, Figure 7) — hardcoded to avoid GF generator bit-width
-- issues in the pure-Lua fallback path.
local AES_SBOX = {
    [0]=0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
}
local AES_SBOX_INV = {}
for i = 0, 255 do AES_SBOX_INV[AES_SBOX[i]] = i end

-- Multiply in GF(2^8) mod x^8+x^4+x^3+x+1.
local function gf_mul(a, b)
    local p = 0
    for _ = 1, 8 do
        if band(b,1) == 1 then p = bxor(p, a) end
        local hi = band(a, 0x80)
        a = band(lshift(a,1), 0xff)
        if hi ~= 0 then a = bxor(a, 0x1b) end
        b = rshift(b, 1)
    end
    return p
end

-- MixColumns lookup tables (pre-computed for performance).
local GF2, GF3, GF9, GF11, GF13, GF14
do
    GF2 = {}; GF3 = {}; GF9 = {}; GF11 = {}; GF13 = {}; GF14 = {}
    for i = 0, 255 do
        GF2[i]  = gf_mul(i, 2)
        GF3[i]  = gf_mul(i, 3)
        GF9[i]  = gf_mul(i, 9)
        GF11[i] = gf_mul(i, 11)
        GF13[i] = gf_mul(i, 13)
        GF14[i] = gf_mul(i, 14)
    end
end

local NR = 14   -- AES-256 uses 14 rounds
local NK = 8    -- key length in 32-bit words

-- AES key expansion.  Returns an array of (NR+1)*4 words.
local function aes_key_expand(key)
    assert(#key == 32, "AES-256 key must be 32 bytes")
    local w = {}
    for i = 0, NK-1 do
        w[i] = bytes_to_word(key, i*4+1)
    end
    local RCON = {0x01000000,0x02000000,0x04000000,0x08000000,
                  0x10000000,0x20000000,0x40000000,0x80000000,
                  0x1b000000,0x36000000}
    for i = NK, (NR+1)*4-1 do
        local temp = w[i-1]
        if i % NK == 0 then
            -- RotWord + SubWord + Rcon
            local b0 = AES_SBOX[band(rshift(temp,16),0xff)]
            local b1 = AES_SBOX[band(rshift(temp, 8),0xff)]
            local b2 = AES_SBOX[band(temp,0xff)]
            local b3 = AES_SBOX[band(rshift(temp,24),0xff)]
            temp = bxor(bor(lshift(b0,24), bor(lshift(b1,16), bor(lshift(b2,8), b3))), RCON[i/NK])
        elseif i % NK == 4 then
            local b0 = AES_SBOX[band(rshift(temp,24),0xff)]
            local b1 = AES_SBOX[band(rshift(temp,16),0xff)]
            local b2 = AES_SBOX[band(rshift(temp, 8),0xff)]
            local b3 = AES_SBOX[band(temp,0xff)]
            temp = bor(lshift(b0,24), bor(lshift(b1,16), bor(lshift(b2,8), b3)))
        end
        w[i] = bxor(w[i-NK], temp)
    end
    return w
end

-- AES-256 encrypt a single 16-byte block.
local function aes_block_encrypt(block, w)
    assert(#block == 16)
    -- State as a flat array of 16 bytes (column-major: s[col*4+row]).
    local s = {}
    for i = 0, 15 do s[i] = block:byte(i+1) end

    -- AddRoundKey (round 0)
    for c = 0, 3 do
        local wc = w[c]
        s[c*4+0] = bxor(s[c*4+0], band(rshift(wc,24),0xff))
        s[c*4+1] = bxor(s[c*4+1], band(rshift(wc,16),0xff))
        s[c*4+2] = bxor(s[c*4+2], band(rshift(wc, 8),0xff))
        s[c*4+3] = bxor(s[c*4+3], band(wc,0xff))
    end

    for round = 1, NR do
        -- SubBytes
        for i = 0, 15 do s[i] = AES_SBOX[s[i]] end
        -- ShiftRows
        local t1 = s[1]; s[1]=s[5]; s[5]=s[9]; s[9]=s[13]; s[13]=t1
        local t2 = s[2]; local t6 = s[6]
        s[2]=s[10]; s[6]=s[14]; s[10]=t2; s[14]=t6
        local t3 = s[15]; s[15]=s[11]; s[11]=s[7]; s[7]=s[3]; s[3]=t3
        -- MixColumns (skip on last round)
        if round < NR then
            for c = 0, 3 do
                local b0=s[c*4]; local b1=s[c*4+1]
                local b2=s[c*4+2]; local b3=s[c*4+3]
                s[c*4+0] = bxor(GF2[b0], bxor(GF3[b1], bxor(b2, b3)))
                s[c*4+1] = bxor(b0, bxor(GF2[b1], bxor(GF3[b2], b3)))
                s[c*4+2] = bxor(b0, bxor(b1, bxor(GF2[b2], GF3[b3])))
                s[c*4+3] = bxor(GF3[b0], bxor(b1, bxor(b2, GF2[b3])))
            end
        end
        -- AddRoundKey
        local base = round * 4
        for c = 0, 3 do
            local wc = w[base+c]
            s[c*4+0] = bxor(s[c*4+0], band(rshift(wc,24),0xff))
            s[c*4+1] = bxor(s[c*4+1], band(rshift(wc,16),0xff))
            s[c*4+2] = bxor(s[c*4+2], band(rshift(wc, 8),0xff))
            s[c*4+3] = bxor(s[c*4+3], band(wc,0xff))
        end
    end

    local out = {}
    for i = 0, 15 do out[i+1] = string.char(s[i]) end
    return table.concat(out)
end

-- AES-256 decrypt a single 16-byte block.
local function aes_block_decrypt(block, w)
    assert(#block == 16)
    local s = {}
    for i = 0, 15 do s[i] = block:byte(i+1) end

    -- AddRoundKey (last round key)
    local base = NR * 4
    for c = 0, 3 do
        local wc = w[base+c]
        s[c*4+0] = bxor(s[c*4+0], band(rshift(wc,24),0xff))
        s[c*4+1] = bxor(s[c*4+1], band(rshift(wc,16),0xff))
        s[c*4+2] = bxor(s[c*4+2], band(rshift(wc, 8),0xff))
        s[c*4+3] = bxor(s[c*4+3], band(wc,0xff))
    end

    for round = NR-1, 0, -1 do
        -- InvShiftRows
        local t1 = s[13]; s[13]=s[9]; s[9]=s[5]; s[5]=s[1]; s[1]=t1
        local t2 = s[2]; local t6 = s[6]
        s[2]=s[10]; s[6]=s[14]; s[10]=t2; s[14]=t6
        local t3 = s[3]; s[3]=s[7]; s[7]=s[11]; s[11]=s[15]; s[15]=t3
        -- InvSubBytes
        for i = 0, 15 do s[i] = AES_SBOX_INV[s[i]] end
        -- AddRoundKey
        base = round * 4
        for c = 0, 3 do
            local wc = w[base+c]
            s[c*4+0] = bxor(s[c*4+0], band(rshift(wc,24),0xff))
            s[c*4+1] = bxor(s[c*4+1], band(rshift(wc,16),0xff))
            s[c*4+2] = bxor(s[c*4+2], band(rshift(wc, 8),0xff))
            s[c*4+3] = bxor(s[c*4+3], band(wc,0xff))
        end
        -- InvMixColumns (skip on round 0)
        if round > 0 then
            for c = 0, 3 do
                local b0=s[c*4]; local b1=s[c*4+1]
                local b2=s[c*4+2]; local b3=s[c*4+3]
                s[c*4+0] = bxor(GF14[b0], bxor(GF11[b1], bxor(GF13[b2], GF9[b3])))
                s[c*4+1] = bxor(GF9[b0],  bxor(GF14[b1], bxor(GF11[b2], GF13[b3])))
                s[c*4+2] = bxor(GF13[b0], bxor(GF9[b1],  bxor(GF14[b2], GF11[b3])))
                s[c*4+3] = bxor(GF11[b0], bxor(GF13[b1], bxor(GF9[b2],  GF14[b3])))
            end
        end
    end

    local out = {}
    for i = 0, 15 do out[i+1] = string.char(s[i]) end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- CBC mode  (PKCS7 padding)
-- ---------------------------------------------------------------------------

function M.aes256cbc_encrypt(key, iv, plaintext)
    assert(#key == 32, "key must be 32 bytes")
    assert(#iv  == 16, "iv must be 16 bytes")
    local w = aes_key_expand(key)
    -- PKCS7 pad to 16-byte boundary.
    local pad = 16 - (#plaintext % 16)
    plaintext = plaintext .. string.rep(string.char(pad), pad)
    local out = {}
    local prev = iv
    for i = 1, #plaintext, 16 do
        local block = plaintext:sub(i, i+15)
        -- XOR with previous ciphertext block (CBC).
        local xored = {}
        for j = 1, 16 do
            xored[j] = string.char(bxor(block:byte(j), prev:byte(j)))
        end
        local ct_block = aes_block_encrypt(table.concat(xored), w)
        out[#out+1] = ct_block
        prev = ct_block
    end
    return table.concat(out)
end

function M.aes256cbc_decrypt(key, iv, ciphertext)
    if #key ~= 32 then return nil, "key must be 32 bytes" end
    if #iv  ~= 16 then return nil, "iv must be 16 bytes" end
    if #ciphertext == 0 or #ciphertext % 16 ~= 0 then
        return nil, "ciphertext length must be a non-zero multiple of 16"
    end
    local w = aes_key_expand(key)
    local out = {}
    local prev = iv
    for i = 1, #ciphertext, 16 do
        local ct_block = ciphertext:sub(i, i+15)
        local pt_block = aes_block_decrypt(ct_block, w)
        -- XOR with previous ciphertext block.
        local xored = {}
        for j = 1, 16 do
            xored[j] = string.char(bxor(pt_block:byte(j), prev:byte(j)))
        end
        out[#out+1] = table.concat(xored)
        prev = ct_block
    end
    local plaintext = table.concat(out)
    -- Remove PKCS7 padding.
    local pad = plaintext:byte(#plaintext)
    if pad == 0 or pad > 16 then
        return nil, "invalid PKCS7 padding byte: " .. tostring(pad)
    end
    for i = #plaintext - pad + 1, #plaintext do
        if plaintext:byte(i) ~= pad then
            return nil, "invalid PKCS7 padding (corrupt or wrong key)"
        end
    end
    return plaintext:sub(1, #plaintext - pad)
end

return M
