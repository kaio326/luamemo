-- eval/tests/test_sensing.lua
-- Phase 9 — signal capture. Section 1: heuristic detector (pure, no DB).
-- (Section 2 — the orchestrator — is DB-backed and appended below.)
--
-- Usage:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/luamemo_dev \
--     lua5.1 eval/tests/test_sensing.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local pass, fail = 0, 0
local function check(l, ok, d) if ok then io.write("[PASS] " .. l .. "\n"); pass = pass + 1
    else io.write("[FAIL] " .. l .. (d and (" — " .. d) or "") .. "\n"); fail = fail + 1 end end
local function header(s) io.write(string.format("\n=== %s ===\n", s)) end

-- =========================================================================
header("Section 1 — heuristic signal detection")

local H = require("luamemo.sensing.heuristics")

local function first_of(turns, kind)
    for _, e in ipairs(H.detect(turns)) do if e.kind == kind then return e end end
end

-- corrections -> mistake
local c = first_of({ { role = "user", text = "No, we don't use luadbi here, we use pgmoon." } }, "correction")
check("detects a correction", c ~= nil and c.event_type == "mistake", c and c.event_type)
check("correction carries the turn text", c and c.text:find("pgmoon", 1, true) ~= nil)
check("'that's wrong' is a correction", first_of({ "that's wrong, the tier is derived from importance" }, "correction") ~= nil)
check("'not how we do it' is a correction", first_of({ "that is not how we handle migrations" }, "correction") ~= nil)

-- commands -> direct_command
local cmd = first_of({ { role = "user", text = "Always run memo migrate after upgrading." } }, "command")
check("detects a command", cmd ~= nil and cmd.event_type == "direct_command", cmd and cmd.event_type)
check("'never' is a command", first_of({ "never commit without asking" }, "command") ~= nil)

-- praise -> praise
local pr = first_of({ { role = "user", text = "Yes, exactly right — that's the hybrid union." } }, "praise")
check("detects praise", pr ~= nil and pr.event_type == "praise", pr and pr.event_type)

-- assistant turns are ignored
check("assistant turns are NOT scanned",
    #H.detect({ { role = "assistant", text = "No, that's wrong and incorrect." } }) == 0)

-- neutral text -> nothing
check("neutral text yields no signal",
    #H.detect({ { role = "user", text = "Can you show me the search function?" } }) == 0)

-- multi-turn conversation: one correction + one command
local convo = {
    { role = "user",      text = "How do we store secrets?" },
    { role = "assistant", text = "In a DB table." },
    { role = "user",      text = "No, that's wrong — secrets live in an encrypted JSON file, never a table." },
    { role = "assistant", text = "Understood." },
    { role = "user",      text = "Always use the encrypted file going forward." },
}
local evs = H.detect(convo)
local kinds = {}; for _, e in ipairs(evs) do kinds[e.kind] = true end
check("multi-turn: finds both correction and command", kinds.correction and kinds.command,
    table.concat((function() local t = {} for k in pairs(kinds) do t[#t+1]=k end return t end)(), ","))
-- Dedup: a single turn with TWO correction phrases yields exactly ONE correction event.
local dbl = H.detect({ { role = "user", text = "No, that's wrong and incorrect — we don't do that." } })
local n_corr = 0; for _, e in ipairs(dbl) do if e.kind == "correction" then n_corr = n_corr + 1 end end
check("at most one event per (turn,kind)", n_corr == 1, "corrections=" .. n_corr)

-- =========================================================================
header("Section 2 — orchestrator: signals → reinforcements (idempotent, single writer)")

local db      = require("luamemo.db")
local memory  = require("luamemo")
local sensing = require("luamemo.sensing")

memory.setup({ embedder_local = "hash", embed_dim = 384, backend = "auto",
    auth_fn = function() return true end, skip_embed_probe = true })

local SCOPE = "sensingtest"
local function wipe()
    db.query("DELETE FROM lm_reinforcements WHERE scope = " .. db.escape_literal(SCOPE))
    db.query("DELETE FROM lm_memories WHERE scope = " .. db.escape_literal(SCOPE))
end
local function reinf_count()
    local r = db.query("SELECT count(*) AS n FROM lm_reinforcements WHERE scope = " .. db.escape_literal(SCOPE))
    return r and tonumber(r[1].n) or -1
end
wipe()

local ids = {}
for _, m in ipairs({
    { t = "db client", b = "Postgres access uses pgmoon, not luadbi." },
    { t = "secrets",   b = "Secrets live in an encrypted JSON file, never a DB table." },
    { t = "hybrid",    b = "Hybrid search unions vector-nearest and top-FTS candidates." },
}) do
    local row = memory.write({ scope = SCOPE, kind = "fact", title = m.t, body = m.b, importance = 1.0 })
    ids[m.t] = row and row.id
end

-- A conversation correcting the pgmoon memory.
local convo = {
    { role = "user",      text = "How do we talk to Postgres?" },
    { role = "assistant", text = "Using luadbi." },
    { role = "user",      text = "No, that's wrong — we use pgmoon, not luadbi." },
}
local res = sensing.process(SCOPE, convo, {})
check("orchestrator recorded a reinforcement", res.recorded >= 1,
    string.format("recorded=%d skipped=%d signals=%d", res.recorded, res.skipped, res.signals))
local rf = db.query("SELECT memory_id, event_type FROM lm_reinforcements WHERE scope = "
    .. db.escape_literal(SCOPE) .. " ORDER BY id")
check("reinforcement landed on the CORRECT memory (db client)",
    rf and rf[1] and tonumber(rf[1].memory_id) == ids["db client"],
    rf and rf[1] and tostring(rf[1].memory_id) or "none")
check("event_type is 'mistake' (a correction)", rf and rf[1] and rf[1].event_type == "mistake",
    rf and rf[1] and rf[1].event_type)

-- Idempotency: re-processing the same conversation records nothing new.
local before = reinf_count()
local res2 = sensing.process(SCOPE, convo, {})
check("re-processing is idempotent (recorded 0)", res2.recorded == 0, tostring(res2.recorded))
check("no duplicate reinforcement after re-run", reinf_count() == before, tostring(reinf_count()))

-- A directive lands as direct_command on the resolved memory.
local n0 = reinf_count()
sensing.process(SCOPE, { { role = "user", text = "Always use pgmoon for Postgres going forward." } }, {})
local cmd = db.query("SELECT event_type FROM lm_reinforcements WHERE scope = " .. db.escape_literal(SCOPE)
    .. " AND event_type = 'direct_command' LIMIT 1")
check("a directive is recorded as direct_command", cmd and #cmd > 0 and reinf_count() > n0)

-- Misattribution guard: a correction about something NOT in the store records nothing.
local off = sensing.process(SCOPE,
    { { role = "user", text = "No, the quarterly payroll tax deadline you gave is wrong." } },
    { min_similarity = 0.3 })
check("unrelated correction does not misattribute", off.recorded == 0, tostring(off.recorded))

-- Uses the single canonical writer: all rows have valid event_types.
local bad = db.query("SELECT count(*) AS n FROM lm_reinforcements WHERE scope = " .. db.escape_literal(SCOPE)
    .. " AND event_type NOT IN ('mistake','reversal','direct_command','praise')")
check("all reinforcements have valid event_types (single writer path)", bad and tonumber(bad[1].n) == 0)

-- =========================================================================
header("Section 3 — generative extractor: parse + label mapping (pure, no model)")

local extract = require("luamemo.sensing.extract")

local p = extract.parse(
    "CORRECTION: we use pgmoon, not luadbi\n" ..
    "COMMAND: never edit an existing migration\n" ..
    "PRAISE: yes, that's the hybrid union")
local byk = {}; for _, e in ipairs(p) do byk[e.kind] = e end
check("parse: CORRECTION -> mistake",         byk.correction and byk.correction.event_type == "mistake")
check("parse: COMMAND -> direct_command",     byk.command and byk.command.event_type == "direct_command")
check("parse: PRAISE -> praise",              byk.praise and byk.praise.event_type == "praise")
check("parse: correction text preserved",     byk.correction and byk.correction.text:find("pgmoon", 1, true) ~= nil)
check("parse: tagged source=generative",      byk.correction and byk.correction.source == "generative")
check("parse: NONE yields no signals",        #extract.parse("NONE") == 0)
check("parse: empty yields no signals",       #extract.parse("") == 0)
local md = extract.parse('**CORRECTION:** "we use pgmoon"')
check("parse: tolerates markdown/quotes",     md[1] and md[1].text == "we use pgmoon", md[1] and md[1].text)

-- =========================================================================
header("Section 4 — generative sensor in-process (gated on MEMO_GEN_MODEL + LuaJIT)")

local generate = require("luamemo.sensing.generate")
local gcfg = { gen_model = os.getenv("MEMO_GEN_MODEL"), gen_n_ctx = 2048, max_tokens = 160 }
if generate.available(gcfg) then
    -- Precision guard — the property that MUST hold for a shared reinforcement signal:
    -- a neutral question yields NO generative signals (no hallucinated reinforcement).
    local neutral = extract.run({ { role = "user", text = "Can you show me where search is defined?" } }, gcfg)
    check("generative: neutral conversation yields no signals", #neutral == 0, "#=" .. #neutral)

    -- Integration + safety: run() executes in-process and EVERY kept signal is grounded
    -- (no meta-commentary) and validly typed. Recall is model-dependent — the 1B default
    -- is precision-first; larger MEMO_GEN_MODEL raises recall. So we assert quality of
    -- whatever survives, not a recall count.
    local out = extract.run({ { role = "user", text = "No, we use pgmoon here, not luadbi." } }, gcfg)
    check("generative: run() returns a signal table", type(out) == "table")
    check("generative: all kept signals grounded & valid-typed", (function()
        for _, e in ipairs(out) do
            if e.text:lower():find("^the user") then return false end
            local et = e.event_type
            if not (et == "mistake" or et == "direct_command" or et == "praise") then return false end
        end
        return true
    end)())
else
    io.write("[SKIP] generative sensor — set MEMO_GEN_MODEL and run under luajit to exercise\n")
end

wipe()
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
