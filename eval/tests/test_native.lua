-- eval/tests/test_native.lua
-- luamemo.native: the library loader, the SQLite binding and the libsodium binding.
--   Loader: the search order (env override → bundled → system soname) and its errors.
--   SQLite: round trips of every value type, bound parameters only, errors carry SQLite's
--     message and never a parameter value, transactions + savepoints, the statement cache,
--     scan(), user_version, busy timeout across two connections, new files 0600, and Lua
--     FTS5 functions in a hot loop (the "bad callback" case).
--   Sodium: RFC 8032 / 7748 / 5869 known answers, AEAD round trip + tampering, kx, size checks.
-- Needs LuaJIT, libsqlite3 and libsodium. No database server. Run: luajit eval/tests/test_native.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("native")
local check, section, finish = T.check, T.section, T.finish

if not jit then io.write("\n[INFO] needs LuaJIT — skipping\n"); finish() end
local ffi = require("ffi")

local function hex(s) return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
local function unhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end
local TMP = os.tmpname(); os.remove(TMP); os.execute("mkdir -p " .. TMP)

-- ---------------------------------------------------------------------------
section("loader", function()
io.write("\n--- loader ---\n")
local loader = require("luamemo.native.loader")
local lib, where = loader.load("sqlite3")
check("libsqlite3 loads", lib ~= nil, where)
local slib, swhere = loader.load("sodium")
check("libsodium loads", slib ~= nil, swhere)
local _, err = loader.load("nope")
check("an unknown library is an error", err and err:find("unknown library", 1, true) ~= nil, err)
-- an override that does not load → error names the variable and the packages
local out = H.sh(("MEMO_LIB_SODIUM=/nonexistent/libsodium.so luajit -e %q 2>&1"):format(
    'package.path="./?.lua;./?/init.lua;"..package.path; local l=require("luamemo.native.loader"); '
    .. 'local ok, e = l.load("sodium"); print(ok and "LOADED" or e)'))
check("a bad MEMO_LIB_SODIUM is named, with the install command", out:find("MEMO_LIB_SODIUM=/nonexistent", 1, true)
    ~= nil and out:find("apt install libsodium23", 1, true) ~= nil, out)
check("bundled copies are looked up under native/lib/<os>-<arch>/",
    loader._bundled_path(loader.LIBS.sqlite3):find("/native/lib/" .. ffi.os:lower() .. "-" .. ffi.arch .. "/libsqlite3", 1, true) ~= nil)
end)

-- ---------------------------------------------------------------------------
section("sqlite values", function()
io.write("\n--- sqlite: values ---\n")
local sqlite = require("luamemo.native.sqlite")
check("SQLite version reported", sqlite.version():match("^3%.%d+") ~= nil, sqlite.version())
local path = TMP .. "/v.db"
local db = assert(sqlite.open(path))
check("new database file is 0600", H.mode(path) == "600", H.mode(path))
check("WAL is on", db:value("PRAGMA journal_mode") == "wal", db:value("PRAGMA journal_mode"))
check("foreign keys on", db:value("PRAGMA foreign_keys") == 1)
assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, i INTEGER, r REAL, s TEXT, b BLOB, n TEXT)"))
local bin = "a\0b\255\0c"
local n, id = db:run("INSERT INTO t (i, r, s, b, n) VALUES (?, ?, ?, ?, ?)",
    { 1759900000123456, 3.25, "héllo\0wörld", sqlite.blob(bin), nil, n = 5 })
check("run → changes 1, last rowid", n == 1 and id == 1, tostring(n) .. "/" .. tostring(id))
local row = db:first("SELECT * FROM t WHERE id = ?", { id })
check("µs integer round trip (> 2^31)", row.i == 1759900000123456, tostring(row.i))
check("real round trip", row.r == 3.25)
check("text with NUL + UTF-8 round trip", row.s == "héllo\0wörld")
check("blob with NUL / 0xFF round trip", row.b == bin)
check("NULL → nil", row.n == nil)
db:run("INSERT INTO t (i) VALUES (?)", { ffi.new("int64_t", 2 ^ 53) + 1 })
check("integer past 2^53 → exact decimal string", db:value("SELECT i FROM t WHERE id = 2") == "9007199254740993",
    tostring(db:value("SELECT i FROM t WHERE id = 2")))
check("booleans bind as 1/0", db:value("SELECT ? + ?", { true, false }) == 1)
check("empty text and empty blob", db:value("SELECT ?", { "" }) == "" and db:value("SELECT ?", { sqlite.blob("") }) == "")
check("value() with no row → nil", db:value("SELECT i FROM t WHERE id = 999") == nil)
local rows = db:query("SELECT id FROM t ORDER BY id")
check("query → all rows", #rows == 2 and rows[2].id == 2)
check("json functions available", db:value("SELECT json_extract(?, '$.a')", { '{"a":7}' }) == 7)
local ok_b = pcall(db.query, db, "SELECT ?", { {} })
check("binding a plain table raises", not ok_b)
local ok_n = pcall(db.query, db, "SELECT ?", { 1, 2 })
check("too many parameters raises", not ok_n)
-- a raise mid-bind must not leave the first parameter bound for the next call
pcall(db.query, db, "SELECT ? AS a, ? AS b", { "leftover", {} })
local clean = db:first("SELECT ? AS a, ? AS b", { nil, nil, n = 2 })
check("a failed bind leaves nothing behind for the next call", clean and clean.a == nil and clean.b == nil)
db:close()
end)

-- ---------------------------------------------------------------------------
section("sqlite errors", function()
io.write("\n--- sqlite: errors ---\n")
local sqlite = require("luamemo.native.sqlite")
local db = assert(sqlite.open(TMP .. "/e.db"))
assert(db:exec("CREATE TABLE u (name TEXT UNIQUE NOT NULL)"))
local _, e1 = db:query("SELEC broken")
check("syntax error carries SQLite's message", e1 and e1:find("syntax error", 1, true) ~= nil, e1)
local SECRET = "sk-test-0123456789abcdef"
db:run("INSERT INTO u (name) VALUES (?)", { SECRET })
local _, e2 = db:run("INSERT INTO u (name) VALUES (?)", { SECRET })
check("constraint error carries SQLite's message", e2 and e2:find("UNIQUE", 1, true) ~= nil, e2)
check("… and never the bound value", e2 and not e2:find(SECRET, 1, true), e2)
local _, e3 = db:query("SELECT 1; SELECT 2")
check("two statements in query() → error naming exec()", e3 and e3:find("exec()", 1, true) ~= nil, e3)
local _, e4 = db:exec("CREATE TABLE u (x)")
check("exec() errors carry SQLite's message", e4 and e4:find("already exists", 1, true) ~= nil, e4)
-- the cached statement still works after an error (reset properly)
check("statement reusable after an error", db:value("SELECT count(*) FROM u") == 1)
db:close()
local ok_c = pcall(db.query, db, "SELECT 1")
check("using a closed database raises", not ok_c)
db:close()
check("close() twice is harmless", true)
local _, eo = sqlite.open(TMP .. "/no/such/dir/x.db")
check("open in a missing directory → error with the path", eo and eo:find("no/such/dir", 1, true) ~= nil, eo)
end)

-- ---------------------------------------------------------------------------
section("sqlite transactions", function()
io.write("\n--- sqlite: transactions ---\n")
local sqlite = require("luamemo.native.sqlite")
local db = assert(sqlite.open(TMP .. "/t.db"))
assert(db:exec("CREATE TABLE k (v INTEGER)"))
local ok, a, b = db:transaction(function(d) d:run("INSERT INTO k VALUES (1)"); return "x", 2 end)
check("commit → true + fn's results", ok == true and a == "x" and b == 2)
local r, err = db:transaction(function(d) d:run("INSERT INTO k VALUES (2)"); error("boom") end)
check("raise → rolled back, nil + error", r == nil and err:find("boom", 1, true) ~= nil and
    db:value("SELECT count(*) FROM k") == 1, err)
db:transaction(function(d)
    d:run("INSERT INTO k VALUES (3)")
    local inner = d:transaction(function(d2) d2:run("INSERT INTO k VALUES (4)"); error("inner fails") end)
    check("nested failure returns nil (savepoint)", inner == nil)
    check("still inside the outer transaction", d:in_transaction())
end)
check("outer commit keeps 3, inner rolled back 4", db:value("SELECT group_concat(v) FROM (SELECT v FROM k ORDER BY v)") == "1,3",
    db:value("SELECT group_concat(v) FROM (SELECT v FROM k ORDER BY v)"))
check("user_version starts at 0", db:user_version() == 0)
db:set_user_version(17)
check("user_version set", db:user_version() == 17)
-- busy timeout: a second connection waits, then fails cleanly
local db2 = assert(sqlite.open(TMP .. "/t.db", { busy_ms = 200 }))
assert(db:exec("BEGIN IMMEDIATE"))
local r2, e2 = db2:transaction(function(d) d:run("INSERT INTO k VALUES (9)") end)
check("a second writer waits for busy_ms, then gets a clear error", r2 == nil and e2 and e2:find("locked", 1, true) ~= nil, e2)
db:exec("COMMIT")
check("… and succeeds once the lock is gone", (db2:transaction(function(d) d:run("INSERT INTO k VALUES (9)") end)) == true)
db2:close(); db:close()
end)

-- ---------------------------------------------------------------------------
section("sqlite scan + cache", function()
io.write("\n--- sqlite: scan, statement cache ---\n")
local sqlite = require("luamemo.native.sqlite")
local db = assert(sqlite.open(TMP .. "/s.db"))
assert(db:exec("CREATE TABLE v (id INTEGER PRIMARY KEY, emb BLOB)"))
local vec = ffi.new("float[4]", { 1, 2, 3, 4 })
db:transaction(function(d)
    for _ = 1, 500 do d:run("INSERT INTO v (emb) VALUES (?)", { sqlite.blob(vec, 16) }) end
end)
local sum, seen = 0, 0
local n = db:scan("SELECT id, emb FROM v WHERE id <= ?", { 300 }, function(r)
    local p, len = r:blob_ptr(1)
    local f = ffi.cast("const float*", p)
    sum = sum + f[0] + f[3]
    seen = seen + (len == 16 and 1 or 0)
end)
check("scan visits every row, blob read in place", n == 300 and seen == 300 and sum == 1500, n .. "/" .. sum)
local stopped = db:scan("SELECT id FROM v", nil, function(r) if r:int(0) == 10 then return false end end)
check("scan stops when fn returns false", stopped == 10, stopped)
for i = 1, 100 do db:value("SELECT " .. i) end   -- 100 distinct statements > cache size 64
check("statement cache stays bounded", #db.order <= 64, #db.order)
check("… and still answers", db:value("SELECT 42") == 42)
db:close()
end)

-- ---------------------------------------------------------------------------
section("sqlite fts5 lua function", function()
io.write("\n--- sqlite: FTS5 functions in Lua (JIT-safe) ---\n")
local sqlite = require("luamemo.native.sqlite")
local db = assert(sqlite.open(TMP .. "/f.db"))
assert(db:exec("CREATE VIRTUAL TABLE f USING fts5(doc, tokenize='porter unicode61')"))
db:transaction(function(d)
    for i = 1, 200 do d:run("INSERT INTO f (rowid, doc) VALUES (?, ?)", { i, ("deploy the cache number %d now"):format(i) }) end
end)
assert(db:create_fts5_function("hits", function(x)
    local n = 0
    for i = 0, x:inst_count() - 1 do local _, _, off = x:inst(i); n = n + 1 + off * 0 end
    return n
end))
check("the function sees phrase matches", db:value("SELECT hits(f) FROM f WHERE f MATCH ? AND rowid = 1", { '"deploy" "cache"' }) == 2)
-- the case that aborts LuaJIT ("bad callback") if sqlite3_step runs under a compiled trace
local okloop, err = pcall(function()
    for _ = 1, 3000 do assert(db:value("SELECT hits(f) FROM f WHERE f MATCH ? AND rowid = 7", { '"cache"' }) == 1) end
end)
check("3000 calls in a hot loop: no 'bad callback'", okloop, err)
local okscan = pcall(db.scan, db, "SELECT hits(f) FROM f WHERE f MATCH 'cache'", nil, function() end)
check("scan() refuses SQL that calls a Lua function", not okscan)
check("… but not SQL that merely contains the name inside another word",
    db:scan("SELECT 1 AS hits_count", nil, function() end) == 1)
local bad = db:value("SELECT hits(f) FROM f WHERE f MATCH 'nomatch'")
check("no match → no row", bad == nil)
assert(db:create_fts5_function("boom", function() error("x") end))
check("a raising Lua function gives NULL, not a crash", db:first("SELECT boom(f) AS v FROM f WHERE f MATCH 'cache' LIMIT 1").v == nil)
db:close()
end)

-- ---------------------------------------------------------------------------
section("sodium", function()
io.write("\n--- sodium ---\n")
local na = require("luamemo.native.sodium")
check("libsodium version ≥ 1.0.18", na.version():match("^1%.0%.%d+") ~= nil, na.version())
local pk, sk = na.sign_seed_keypair(unhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
check("Ed25519 seed → pk (RFC 8032 #1)", hex(pk) == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
local sig = na.sign("", sk)
check("Ed25519 sign (RFC 8032 #1)", hex(sig) == "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
check("verify ok", na.verify(sig, "", pk))
check("verify rejects a changed message", not na.verify(sig, "x", pk))
check("verify rejects a short signature", not na.verify("abc", "", pk))
local a_sk = unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
local b_pk = unhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
check("X25519 base (RFC 7748)", hex(na.x25519_base(a_sk)) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
check("X25519 shared (RFC 7748)", hex(na.x25519(a_sk, b_pk)) == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
check("X25519 refuses a low-order point (all-zero result)", na.x25519(a_sk, string.rep("\0", 32)) == nil)
check("Ed25519 → X25519: sk conversion matches pk conversion",
    na.x25519_base(na.ed25519_sk_to_x25519(sk)) == na.ed25519_pk_to_x25519(pk))
local key, nonce = na.random_bytes(32), na.random_bytes(24)
local ct = na.aead_encrypt("hello federation", "hdr", nonce, key)
check("AEAD ciphertext = message + 16-byte tag", #ct == 16 + 16)
check("AEAD round trip", na.aead_decrypt(ct, "hdr", nonce, key) == "hello federation")
local flipped = ct:sub(1, 3) .. string.char((ct:byte(4) + 1) % 256) .. ct:sub(5)
local m1, e1 = na.aead_decrypt(flipped, "hdr", nonce, key)
check("AEAD rejects tampering", m1 == nil and e1 == "authentication failed")
check("AEAD rejects other additional data", na.aead_decrypt(ct, "other", nonce, key) == nil)
check("AEAD rejects a truncated ciphertext", na.aead_decrypt("short", "hdr", nonce, key) == nil)
check("AEAD with an empty message", na.aead_decrypt(na.aead_encrypt("", nil, nonce, key), nil, nonce, key) == "")
check("SHA-256('abc')", hex(na.sha256("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("HMAC-SHA256 (RFC 4231 #2)", hex(na.hmac_sha256("Jefe", "what do ya want for nothing?"))
    == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
check("HKDF-SHA256 (RFC 5869 #1)", hex(na.hkdf_sha256(unhex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"),
    unhex("000102030405060708090a0b0c"), unhex("f0f1f2f3f4f5f6f7f8f9"), 42))
    == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
check("HKDF-SHA256 (RFC 5869 #3: no salt, no info)", hex(na.hkdf_sha256(unhex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), "", "", 42))
    == "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
local r1, r2 = na.random_bytes(32), na.random_bytes(32)
check("random_bytes: right size, not repeating", #r1 == 32 and r1 ~= r2)
check("a wrong key size raises", not pcall(na.aead_encrypt, "m", "", nonce, "short"))
check("a wrong seed size raises", not pcall(na.sign_seed_keypair, "short"))
end)

os.execute("rm -rf " .. TMP)
finish()
