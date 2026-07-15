-- eval/tests/test_autodigest.lua
-- Lazy op-triggered digest (self-maintaining, no external trigger). A persisted
-- per-scope cursor (lm_digest_state, migration 012) debounces a maintenance
-- digest that piggybacks on ordinary writes — so it survives across the stateless
-- CLI's process boundaries and never depends on an agent/scheduler remembering.
--   Section 1: maybe_run claims a slot, then debounces within the interval
--   Section 2: becomes due again once the cursor ages past the interval
--   Section 3: store.write piggybacks maybe_run only when auto_digest_enabled
--
-- Usage:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/luamemo_dev \
--     lua5.1 eval/tests/test_autodigest.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local db     = require("luamemo.db")
local memory = require("luamemo")
local digest = require("luamemo.digest")

local pass, fail = 0, 0
local function check(label, ok, detail)
    if ok then io.write("[PASS] " .. label .. "\n"); pass = pass + 1
    else io.write("[FAIL] " .. label .. (detail and (" — " .. detail) or "") .. "\n"); fail = fail + 1 end
end
local function header(s) io.write(string.format("\n=== %s ===\n", s)) end

memory.setup({
    db_table = "lm_memories", embedder_local = "hash", embed_dim = 384,
    backend = "auto", auth_fn = function() return true end, skip_embed_probe = true,
})

local SCOPE = "autodigesttest"
local function esc(s) return db.escape_literal(s) end
local function wipe()
    db.query("DELETE FROM lm_digest_state WHERE scope = " .. esc(SCOPE))
    db.query("DELETE FROM lm_memories     WHERE scope = " .. esc(SCOPE))
end
local function cursor()
    local r = db.query("SELECT extract(epoch from last_digested_at) AS t FROM lm_digest_state WHERE scope = " .. esc(SCOPE))
    return r and r[1] and tonumber(r[1].t) or nil
end

-- =========================================================================
header("Section 1 — maybe_run claims a slot, then debounces")
wipe()
digest.configure({ auto_digest_interval = 100000 })   -- large: only the first call is due
check("no cursor before first maybe_run", cursor() == nil)
digest.maybe_run(SCOPE)
local c1 = cursor()
check("first maybe_run creates the cursor (claimed the slot)", c1 ~= nil)
local ran2 = digest.maybe_run(SCOPE)
check("second maybe_run is debounced (returns false)", ran2 == false, tostring(ran2))
check("debounced call leaves the cursor unchanged", cursor() == c1)

-- =========================================================================
header("Section 2 — due again once the cursor ages past the interval")
db.query("UPDATE lm_digest_state SET last_digested_at = now() - interval '200000 seconds' WHERE scope = " .. esc(SCOPE))
digest.maybe_run(SCOPE)
check("maybe_run runs again after the interval elapsed", (cursor() or 0) > (c1 or 0),
    string.format("%s -> %s", tostring(c1), tostring(cursor())))
-- unavailable table / empty scope are safe no-ops
check("maybe_run on empty scope is a safe no-op", digest.maybe_run("") == false)

-- =========================================================================
header("Section 3 — store.write piggybacks maybe_run only when enabled")
wipe()
digest.configure({ auto_digest_interval = 100000 })
memory.config.auto_digest_enabled = false
memory.write({ scope = SCOPE, title = "a", body = "lazy digest sample one", importance = 0.5 })
check("write does NOT trigger a digest when auto_digest_enabled=false", cursor() == nil, tostring(cursor()))
memory.config.auto_digest_enabled = true
memory.write({ scope = SCOPE, title = "b", body = "lazy digest sample two", importance = 0.5 })
check("write triggers a debounced digest when auto_digest_enabled=true", cursor() ~= nil)
memory.config.auto_digest_enabled = false

wipe()
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
