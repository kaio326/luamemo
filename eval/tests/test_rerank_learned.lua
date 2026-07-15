-- eval/tests/test_rerank_learned.lua
-- Phase 4 — learned reranker MACHINERY (not the win): adapter, trainer, weight
-- lifecycle. These assert correctness/safety; whether a trained model beats the
-- baseline on real data is measured by eval/rerank_bench.lua (a gate, not a unit
-- test). No DB required.
--
-- Usage:
--   MEMO_RERANK_WEIGHTS=/tmp/rrw_test.json lua5.1 eval/tests/test_rerank_learned.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

-- Isolate the weight artifact to a scratch path so we never touch a real one.
if not os.getenv("MEMO_RERANK_WEIGHTS") or os.getenv("MEMO_RERANK_WEIGHTS") == "" then
    io.stderr:write("set MEMO_RERANK_WEIGHTS to a scratch path before running\n"); os.exit(2)
end

local learned = require("luamemo.rerankers.learned")
local trainer = require("luamemo.rerank_train")

local pass, fail = 0, 0
local function check(l, ok, d) if ok then io.write("[PASS] "..l.."\n"); pass=pass+1
    else io.write("[FAIL] "..l..(d and (" — "..d) or "").."\n"); fail=fail+1 end end
local function header(s) io.write(string.format("\n=== %s ===\n", s)) end

local function fv(t) local o={}; for _,k in ipairs(learned.FEATURES) do o[k]=t[k] or 0 end; return o end

-- =========================================================================
header("Section 1 — feature normalisation + identity fallback")

local hits = {
    { score=0.9, vec_score=0.5, fts_score=0.0, importance=1, tier=2, id=1 },
    { score=0.3, vec_score=0.1, fts_score=0.2, importance=1, tier=2, id=2 },
    { score=0.6, vec_score=0.9, fts_score=0.1, importance=1, tier=2, id=3 },
}
local nf = learned.pool_features(hits)
check("min of a feature normalises to 0", nf[2].score == 0, tostring(nf[2].score))
check("max of a feature normalises to 1", nf[1].score == 1, tostring(nf[1].score))
check("constant feature (importance) normalises to 0", nf[1].importance == 0 and nf[3].importance == 0)

-- No weights configured -> identity (baseline order preserved).
local ident = learned.rerank("q", hits, { rerank_weights = nil })
check("no weights => identity order", ident[1].score > ident[2].score and ident[2].score > ident[3].score)

-- Prior weights => rank by `score` (baseline order): hit1(.9) > hit3(.6) > hit2(.3).
local scored = learned.rerank("q", hits, { rerank_weights = trainer.prior() })
check("prior weights rank by baseline score",
    scored[1].score > scored[3].score and scored[3].score > scored[2].score,
    string.format("s1=%.3f s2=%.3f s3=%.3f", scored[1].score, scored[2].score, scored[3].score))

-- =========================================================================
header("Section 2 — trainer learns a separating feature + reduces loss")

-- Two pools; the positive is the ONLY one with vec_score=1, score tied (=> 0 after
-- norm), so the prior cannot rank it first but a learner can.
local examples = {
    { features = { fv{vec_score=1}, fv{vec_score=0}, fv{vec_score=0} }, positive = 1, weight = 1 },
    { features = { fv{vec_score=0}, fv{vec_score=1}, fv{vec_score=0} }, positive = 2, weight = 1 },
}
local loss0 = trainer.loss(trainer.prior(), examples)
local w = trainer.train(examples, { epochs = 300, lr = 0.2, l2 = 0.0 })
local loss1 = trainer.loss(w, examples)
check("training reduces pairwise loss", loss1 < loss0, string.format("%.4f -> %.4f", loss0, loss1))
check("learned weight on the separating feature is positive", (w.vec_score or 0) > 0, tostring(w.vec_score))
check("positive now outscores negatives in pool 1",
    learned.score_one(w, examples[1].features[1]) > learned.score_one(w, examples[1].features[2]))

-- =========================================================================
header("Section 3 — versioned weight lifecycle (promote / rollback)")

os.remove(os.getenv("MEMO_RERANK_WEIGHTS"))
learned.reset_cache()
check("load_current is nil on empty artifact", trainer.load_current() == nil)

local wA = trainer.prior();  wA.vec_score = 0.5
local wB = trainer.prior();  wB.vec_score = 0.9
local idA = trainer.save_version(wA, { score = 0.60 })
local idB = trainer.save_version(wB, { score = 0.71 })
check("save_version returns distinct ids", idA ~= idB, idA .. "," .. idB)
check("saving does not auto-promote", trainer.load_current() == nil)

trainer.promote(idA)
check("promote A => current is A's weights", (trainer.load_current() or {}).vec_score == 0.5)
trainer.promote(idB)
check("promote B => current is B's weights", (trainer.load_current() or {}).vec_score == 0.9)
local restored = trainer.rollback()
check("rollback restores the previously-current version (A)", restored == idA and (trainer.load_current() or {}).vec_score == 0.5)

os.remove(os.getenv("MEMO_RERANK_WEIGHTS"))

-- =========================================================================
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
