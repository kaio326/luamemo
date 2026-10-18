-- eval/tests/test_autodigest.lua
-- Lazy op-triggered digest (self-maintaining, no external trigger). A persisted
-- per-scope cursor (lm_digest_state) debounces a maintenance
-- digest that piggybacks on ordinary writes — so it survives across the stateless
-- CLI's process boundaries and never depends on an agent/scheduler remembering.
--   Section 1: maybe_run claims a slot, then debounces within the interval
--   Section 2: becomes due again once the cursor ages past the interval
--   Section 3: store.write piggybacks maybe_run only when auto_digest_enabled
--
-- Usage (the test runner sets a new MEMO_DB per file):
--   MEMO_DB=/tmp/test_autodigest.db luajit eval/tests/test_autodigest.lua

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

memory.setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true })

local SCOPE = "autodigesttest"
local function wipe()
    db.run("DELETE FROM lm_digest_state WHERE scope = ?", SCOPE)
    db.run("DELETE FROM lm_memories     WHERE scope = ?", SCOPE)
end
local function cursor()   -- µs
    return tonumber((db.value("SELECT last_digested_at FROM lm_digest_state WHERE scope = ?", SCOPE)))
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
db.run("UPDATE lm_digest_state SET last_digested_at = ? WHERE scope = ?",
    require("luamemo.util").now_us() - 200000 * 1000000, SCOPE)
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
