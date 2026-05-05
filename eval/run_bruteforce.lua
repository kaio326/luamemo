-- Phase 8.1 wrapper: wires the pgmoon shim into package.loaded["lapis.db"]
-- so eval/run.lua can run under plain lua5.1 against a non-pgvector
-- Postgres. Forwards args to run.lua.
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

-- Ensure the eval table exists (separate from the main lapis_memory table).
db_shim.query([[
CREATE TABLE IF NOT EXISTS lapis_memory_eval (LIKE lapis_memory INCLUDING ALL);
]])

-- Hand off to run.lua.
dofile("eval/run.lua")
db_shim._disconnect()
