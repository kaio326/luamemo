-- Phase 8.1 wrapper: wires the pgmoon shim into package.loaded["lapis.db"]
-- so eval/run.lua can run under plain lua5.1 against a non-pgvector
-- Postgres. Forwards args to run.lua.
package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

-- luamemo.db creates a pgmoon connection automatically from
-- PGHOST / PGDATABASE / PGUSER / PGPASSWORD env vars when outside OpenResty.

local db = require("luamemo.db")

-- Ensure the eval table exists (separate from the main lm_memories table).
db.query([[
CREATE TABLE IF NOT EXISTS lm_memories_eval (LIKE lm_memories INCLUDING ALL);
]])

-- Hand off to run.lua.
dofile("eval/run.lua")
