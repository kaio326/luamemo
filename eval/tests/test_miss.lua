-- eval/tests/test_miss.lua
-- Retrieval-miss sensor (learned-from-usage). A "miss" = retrieval failed to
-- surface a memory that was needed — the OPPOSITE of a content mistake.
--   Section 1: digest.record_event('miss') is valid + bumps importance/tier
--   Section 2: duplicate-write miss (store.write, gated on feedback_enabled)
--   Section 3: miss detection is inert when feedback_enabled = false
--   Section 4: sensing reclassifies mistake -> miss when the target was never retrieved
--
-- Usage:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/luamemo_dev \
--     lua5.1 eval/tests/test_miss.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local db       = require("luamemo.db")
local memory   = require("luamemo")
local digest   = require("luamemo.digest")
local feedback = require("luamemo.feedback")
local sensing  = require("luamemo.sensing")

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

local SCOPE = "misstest"
local function wipe()
    db.query("DELETE FROM lm_retrieval_feedback WHERE scope = " .. db.escape_literal(SCOPE))
    db.query("DELETE FROM lm_reinforcements    WHERE scope = " .. db.escape_literal(SCOPE))
    db.query("DELETE FROM lm_memories          WHERE scope = " .. db.escape_literal(SCOPE))
end
local function reinf(mem_id)
    local q = "SELECT event_type, note FROM lm_reinforcements WHERE scope = " .. db.escape_literal(SCOPE)
    if mem_id then q = q .. " AND memory_id = " .. math.floor(mem_id) end
    return db.query(q .. " ORDER BY id") or {}
end
local function importance_of(id)
    local r = db.query("SELECT importance FROM lm_memories WHERE id = " .. math.floor(id))
    return r and r[1] and tonumber(r[1].importance) or nil
end

-- =========================================================================
header("Section 1 — digest.record_event('miss') is valid and bumps importance")
wipe()
local m1 = memory.write({ scope = SCOPE, title = "pgmoon", body = "Postgres access uses pgmoon.", importance = 0.5 })
digest.record_event(m1.id, SCOPE, "miss", 0.5, "miss:test")
local r1 = reinf(m1.id)
check("a 'miss' reinforcement is accepted (constraint allows it)", r1[1] and r1[1].event_type == "miss",
    r1[1] and r1[1].event_type or "none")
check("miss bumps importance upward", (importance_of(m1.id) or 0) > 0.5, tostring(importance_of(m1.id)))
check("REINFORCE_WEIGHT includes miss (feeds the ranker)", feedback.REINFORCE_WEIGHT.miss ~= nil)

-- =========================================================================
header("Section 2 — duplicate-write miss (feedback_enabled)")
wipe()
memory.config.feedback_enabled = true
local a = memory.write({ scope = SCOPE, title = "db client", body = "Postgres access uses pgmoon, not luadbi.", importance = 0.5 })
local imp_before = importance_of(a.id)
-- A near-identical write with append so the row is inserted (not merged) — isolates the signal.
memory.write({ scope = SCOPE, title = "db client", body = "Postgres access uses pgmoon, not luadbi.",
    importance = 0.5, dedup_strategy = "append" })
local ra = reinf(a.id)
local has_dup_miss = false
for _, r in ipairs(ra) do if r.event_type == "miss" and (r.note or ""):find("duplicate-write", 1, true) then has_dup_miss = true end end
check("near-duplicate write records a miss on the original", has_dup_miss,
    (#ra > 0 and (ra[1].event_type .. "/" .. tostring(ra[1].note)) or "none"))
check("the miss bumped the original's importance", (importance_of(a.id) or 0) > (imp_before or 1),
    string.format("%s -> %s", tostring(imp_before), tostring(importance_of(a.id))))

-- =========================================================================
header("Section 3 — inert when feedback_enabled = false")
wipe()
memory.config.feedback_enabled = false
local b = memory.write({ scope = SCOPE, title = "secrets", body = "Secrets live in an encrypted JSON file.", importance = 0.5 })
memory.write({ scope = SCOPE, title = "secrets", body = "Secrets live in an encrypted JSON file.",
    importance = 0.5, dedup_strategy = "append" })
check("no miss recorded when feedback is off", #reinf(b.id) == 0, tostring(#reinf(b.id)))

-- =========================================================================
header("Section 4 — sensing: mistake -> miss when target was never retrieved")
local correction = { { role = "user", text = "No, that's wrong — hybrid search unions vector-nearest and top-FTS candidates." } }

-- 4a: retrieval log ACTIVE but the memory was NEVER a candidate -> reclassify to miss.
wipe()
local c = memory.write({ scope = SCOPE, title = "hybrid", body = "Hybrid search unions vector-nearest and top-FTS candidates.", importance = 0.5 })
db.query("INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids) VALUES ("
    .. db.escape_literal(SCOPE) .. ", 'unrelated query', '{999999}')")   -- log active, c absent
sensing.process(SCOPE, correction, {})
local r4a = reinf(c.id)
check("4a: correction on a never-retrieved memory is a miss", r4a[1] and r4a[1].event_type == "miss",
    r4a[1] and r4a[1].event_type or "none")

-- 4b: memory WAS a candidate -> stays a content mistake.
wipe()
local d = memory.write({ scope = SCOPE, title = "hybrid", body = "Hybrid search unions vector-nearest and top-FTS candidates.", importance = 0.5 })
db.query("INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids) VALUES ("
    .. db.escape_literal(SCOPE) .. ", 'hybrid search', '{" .. math.floor(d.id) .. "}')")
sensing.process(SCOPE, correction, {})
local r4b = reinf(d.id)
check("4b: correction on a retrieved memory stays a mistake", r4b[1] and r4b[1].event_type == "mistake",
    r4b[1] and r4b[1].event_type or "none")

-- 4c: retrieval log INACTIVE (no rows) -> cannot prove a miss, stays a mistake.
wipe()
local e = memory.write({ scope = SCOPE, title = "hybrid", body = "Hybrid search unions vector-nearest and top-FTS candidates.", importance = 0.5 })
sensing.process(SCOPE, correction, {})
local r4c = reinf(e.id)
check("4c: with no retrieval log, correction stays a mistake", r4c[1] and r4c[1].event_type == "mistake",
    r4c[1] and r4c[1].event_type or "none")

memory.config.feedback_enabled = false
wipe()
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
