-- eval/tests/test_promote.lua
-- Phase 11 — per-scope promotion harness. Weights live per-scope in the DB
-- (lm_learner_weights, migration 013); promote.run harvests → trains → gates on a
-- held-out split → promotes only if it beats the incumbent, else rejects; every
-- attempt is audited (lm_promotion_runs).
--   Section 1: learner_store lifecycle (save/promote/load/rollback, per-scope, audit)
--   Section 2: the reranker loads per-scope promoted weights
--   Section 3: promote.run decisions (skip / valid decision + audit / dry-run)
--
-- Usage:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/luamemo_dev \
--     lua5.1 eval/tests/test_promote.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local db      = require("luamemo.db")
local memory  = require("luamemo")
local store   = require("luamemo.store")
local lstore  = require("luamemo.learner_store")
local promote = require("luamemo.promote")
local learned = require("luamemo.rerankers.learned")

local pass, fail = 0, 0
local function check(label, ok, detail)
    if ok then io.write("[PASS] " .. label .. "\n"); pass = pass + 1
    else io.write("[FAIL] " .. label .. (detail and (" — " .. detail) or "") .. "\n"); fail = fail + 1 end
end
local function header(s) io.write(string.format("\n=== %s ===\n", s)) end
local function esc(s) return db.escape_literal(s) end

memory.setup({
    db_table = "lm_memories", embedder_local = "hash", embed_dim = 384,
    backend = "auto", auth_fn = function() return true end, skip_embed_probe = true,
})

local function wipe_learner(s)
    db.query("DELETE FROM lm_learner_weights WHERE scope = " .. esc(s))
    db.query("DELETE FROM lm_promotion_runs  WHERE scope = " .. esc(s))
end
local function runs_for(s)
    local r = db.query("SELECT count(*) AS n FROM lm_promotion_runs WHERE scope = " .. esc(s))
    return r and tonumber(r[1].n) or -1
end

-- =========================================================================
header("Section 1 — learner_store lifecycle (per-scope, versioned, audited)")
local A = "ps:A"
wipe_learner(A)
local v1 = lstore.save_version(A, "reranker", { bias = 0.1 }, { score = 0.9 })
check("save_version returns version 1", v1 == 1, tostring(v1))
check("a saved-but-unpromoted version is not current", lstore.load_current(A, "reranker") == nil)
lstore.promote(A, "reranker", v1)
local w1 = lstore.load_current(A, "reranker")
check("promote makes it current (weights load)", type(w1) == "table" and math.abs((w1.bias or 0) - 0.1) < 1e-9,
    w1 and tostring(w1.bias))
check("current_version is 1", lstore.current_version(A, "reranker") == 1)
local v2 = lstore.save_version(A, "reranker", { bias = 0.2 }, {})
lstore.promote(A, "reranker", v2)
check("promoting v2 switches current", (lstore.load_current(A, "reranker") or {}).bias == 0.2 and lstore.current_version(A, "reranker") == 2)
local rb = lstore.rollback(A, "reranker")
check("rollback returns to v1", rb == 1 and lstore.current_version(A, "reranker") == 1 and (lstore.load_current(A, "reranker") or {}).bias == 0.1)
check("other scopes are isolated (no current)", lstore.load_current("ps:other", "reranker") == nil)
lstore.record_run(A, "reranker", "promote", { new_score = 0.3, incumbent_score = 0.5, version = 1 })
check("record_run writes an audit row", runs_for(A) >= 1)

-- =========================================================================
header("Section 2 — the reranker loads per-scope promoted weights")
local X = "ps:X"
wipe_learner(X)
learned.reset_cache()
local hits = {}
for i = 1, 4 do
    hits[i] = { id = i, score = (5 - i) / 5, vec_score = 0.5, fts_score = 0.1, importance = 0.5, tier = 1, reuse_count = 0 }
end
local base = learned.rerank("q", hits, { rerank_scope = X })
check("no per-scope weights → baseline order (distinct scores)", base[1].score ~= base[2].score)
lstore.save_version(X, "reranker", { bias = 5.0 }, {})   -- all-bias → constant score
lstore.promote(X, "reranker", 1)
learned.reset_cache()
local mod = learned.rerank("q", hits, { rerank_scope = X })
check("per-scope weights are applied (constant-bias → equal scores)",
    math.abs(mod[1].score - 5.0) < 1e-9 and math.abs(mod[2].score - 5.0) < 1e-9,
    tostring(mod[1].score) .. "," .. tostring(mod[2].score))
learned.reset_cache()

-- =========================================================================
header("Section 3 — promote.run decisions (skip / valid decision + audit / dry-run)")
local S = "ps:run"
local function wipe_run()
    db.query("DELETE FROM lm_retrieval_feedback WHERE scope = " .. esc(S))
    db.query("DELETE FROM lm_reinforcements     WHERE scope = " .. esc(S))
    db.query("DELETE FROM lm_memories           WHERE scope = " .. esc(S))
    wipe_learner(S)
end
wipe_run()

-- No feedback yet → skip (and audited).
local r0 = promote.run(S, { min_samples = 3 })
check("no feedback → decision skip", r0.decision == "skip", r0.decision .. "/" .. tostring(r0.reason))
check("skip is audited", runs_for(S) >= 1)

-- Seed memories + retrieval events + reinforcements so harvest yields triples.
local topics = { "alpha config", "beta pipeline", "gamma cache", "delta queue", "epsilon auth", "zeta deploy" }
local ids = {}
for _, t in ipairs(topics) do
    local row = memory.write({ scope = S, title = t, body = "About " .. t .. " in the system.", importance = 0.8 })
    ids[t] = row and row.id
end
local all = {}; for _, t in ipairs(topics) do all[#all + 1] = math.floor(ids[t]) end
local candarr = "'{" .. table.concat(all, ",") .. "}'"
for _, t in ipairs(topics) do
    db.query("INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids) VALUES ("
        .. esc(S) .. ", " .. esc(t) .. ", " .. candarr .. ")")
    db.query("INSERT INTO lm_reinforcements (memory_id, scope, event_type, delta, note) VALUES ("
        .. math.floor(ids[t]) .. ", " .. esc(S) .. ", 'praise', 0.5, 'seed')")
end

local runs0 = runs_for(S)
local r1 = promote.run(S, { min_samples = 2, gate_frac = 0.4, epochs = 50 })
check("with feedback → a valid decision", r1.decision == "promote" or r1.decision == "reject",
    tostring(r1.decision) .. "/" .. tostring(r1.reason))
check("examples were built from harvested triples", (r1.n_examples or 0) >= 2, tostring(r1.n_examples))
check("the attempt is audited", runs_for(S) > runs0)
if r1.decision == "promote" then
    check("a promoted run persisted a current version", lstore.load_current(S, "reranker") ~= nil)
else
    check("a rejected run left no current version", lstore.current_version(S, "reranker") == nil)
end

-- dry-run never changes the current version.
local cv = lstore.current_version(S, "reranker")
local rd = promote.run(S, { min_samples = 2, gate_frac = 0.4, dry_run = true })
check("dry-run yields a would-* decision", tostring(rd.decision):find("would", 1, true) ~= nil, rd.decision)
check("dry-run does not change the current version", lstore.current_version(S, "reranker") == cv)

wipe_run(); wipe_learner(A); wipe_learner(X)
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
