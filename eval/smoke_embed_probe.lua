-- Phase 10.1 smoke: confirm setup() fails fast on a misconfigured
-- HTTP embedder (dead URL). Asserts the error message is the
-- "embed probe failed" path, not some downstream crash.
--
-- Usage:
--   PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=lm_bruteforce_test \
--     lua5.1 eval/smoke_embed_probe.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local db_shim = require("_smoke_lapis_db")
db_shim._connect({
    host     = os.getenv("PGHOST") or "127.0.0.1",
    port     = tonumber(os.getenv("PGPORT") or "5432"),
    database = os.getenv("PGDATABASE") or "lm_bruteforce_test",
    user     = os.getenv("PGUSER") or "postgres",
    password = os.getenv("PGPASSWORD") or "postgres",
})
package.loaded["lapis.db"] = db_shim

local memory = require("lapis_memory")

-- Case 1: probe SHOULD fire and SHOULD fail (dead URL, no resty.http).
local ok, err = pcall(memory.setup, {
    embedder_url     = "http://127.0.0.1:1/dead",
    embedder_adapter = "ollama",
    embed_dim        = 768,
    auth_fn          = function() return true end,
    -- Note: skip_embed_probe NOT set, so the probe runs.
})
assert(not ok, "expected setup() to error on dead embedder, got success")
assert(tostring(err):find("embed probe failed", 1, true),
    "expected 'embed probe failed' in error, got: " .. tostring(err))
print("PASS case 1: dead embedder -> setup() raised:")
print("  " .. tostring(err):gsub("\n", "\n  "))

-- Case 2: probe is skipped when skip_embed_probe = true (offline mode).
-- Reset module state by re-requiring (Lua caches modules; we have to
-- force a clean config). Easiest: just call setup() again with the flag.
local ok2 = pcall(memory.setup, {
    embedder_url     = "http://127.0.0.1:1/dead",
    embedder_adapter = "ollama",
    embed_dim        = 768,
    skip_embed_probe = true,
    auth_fn          = function() return true end,
})
assert(ok2, "expected setup() with skip_embed_probe to succeed")
print("PASS case 2: skip_embed_probe = true -> setup() succeeded silently")

-- Case 3: hash embedder is exempt from the probe (no flag needed).
local ok3 = pcall(memory.setup, {
    embedder_local = "hash",
    embed_dim      = 384,
    auth_fn        = function() return true end,
})
assert(ok3, "expected setup() with hash embedder to succeed without probe")
print("PASS case 3: hash embedder -> probe skipped automatically")

print("\nALL OK")
