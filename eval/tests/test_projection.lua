-- eval/tests/test_projection.lua
-- Phase 5 — learned projection MACHINERY: identity default == raw hash,
-- contrastive training pulls positives closer, weight lifecycle. No DB.
-- (Whether a trained W beats raw hash is measured by eval/projection_bench.lua.)
--
-- Usage:
--   MEMO_PROJECTION_W=/tmp/projW_test.json lua5.1 eval/tests/test_projection.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path
if not os.getenv("MEMO_PROJECTION_W") or os.getenv("MEMO_PROJECTION_W") == "" then
    io.stderr:write("set MEMO_PROJECTION_W to a scratch path before running\n"); os.exit(2)
end

local hash    = require("luamemo.embedders.hash")
local hl      = require("luamemo.embedders.hash_learned")
local proj    = require("luamemo.projection_train")

local pass, fail = 0, 0
local function check(l, ok, d) if ok then io.write("[PASS] "..l.."\n"); pass=pass+1
    else io.write("[FAIL] "..l..(d and (" — "..d) or "").."\n"); fail=fail+1 end end
local function header(s) io.write(string.format("\n=== %s ===\n", s)) end
local function dot(a,b) local s=0; for i=1,#a do s=s+a[i]*b[i] end; return s end
local function approx_eq(a,b) if #a~=#b then return false end
    for i=1,#a do if math.abs(a[i]-b[i])>1e-9 then return false end end; return true end

local D = 32

-- =========================================================================
header("Section 1 — identity default == raw hash")

hl.reset_cache()
local raw   = hash.embed("never commit autonomously", { embed_dim = D })
local plain = hl.embed("never commit autonomously", { embed_dim = D })   -- no W anywhere
check("hash_learned with no W equals raw hash", approx_eq(raw, plain))

local I = proj.identity(D)
local viaI = hl.embed("never commit autonomously", { embed_dim = D, projection_W = I })
check("hash_learned with identity W equals raw hash", approx_eq(raw, viaI))
check("identity() has 1s on the diagonal", I.m[1] == 1 and I.m[D + 2] == 1 and I.m[2] == 0)

-- =========================================================================
header("Section 2 — contrastive training pulls positive closer than negative")

-- Choose a MARGIN-VIOLATED triple: the query is lexically closer to the NEGATIVE
-- than to the (semantically correct) positive — exactly the low-overlap case the
-- projection must fix. q shares "postgres" with n but nothing with p.
local q = hash.embed("which database postgres client library do we use", { embed_dim = D })
local p = hash.embed("never commit or push autonomously without asking", { embed_dim = D })
local n = hash.embed("postgres access uses pgmoon rather than luadbi here", { embed_dim = D })
local ex = { { q = q, p = p, negs = { n } } }

local margin0 = dot(q, p) - dot(q, n)                 -- under identity (should be < margin)
assert(margin0 < 0.1, "test fixture must be margin-violated; got " .. margin0)
local loss0   = proj.loss(proj.identity(D), ex, 0.1)
local W = proj.train(ex, { dim = D, epochs = 200, lr = 0.1, l2 = 0.0, margin = 0.1 })
local loss1 = proj.loss(W, ex, 0.1)

local function pn(v) local s=0; for i=1,#v do s=s+v[i]*v[i] end; s=math.sqrt(s)
    local o={}; for i=1,#v do o[i]=v[i]/s end; return o end
local wq, wp, wn = pn(hl.project(q, W)), pn(hl.project(p, W)), pn(hl.project(n, W))
local margin1 = dot(wq, wp) - dot(wq, wn)

check("training reduces triplet loss", loss1 < loss0, string.format("%.4f -> %.4f", loss0, loss1))
check("projected (q·p - q·n) margin increases", margin1 > margin0,
    string.format("%.4f -> %.4f", margin0, margin1))

-- =========================================================================
header("Section 3 — versioned matrix lifecycle (promote / rollback)")

os.remove(os.getenv("MEMO_PROJECTION_W")); hl.reset_cache()
check("load_current nil on empty artifact", proj.load_current() == nil)

local WA = proj.identity(D); WA.m[2] = 0.3
local WB = proj.identity(D); WB.m[2] = 0.9
local a = proj.save_version(WA, { score = 0.45 })
local b = proj.save_version(WB, { score = 0.47 })
check("distinct version ids", a ~= b)
check("save does not auto-promote", proj.load_current() == nil)
proj.promote(a); check("promote A", (proj.load_current() or {m={}}).m[2] == 0.3)
proj.promote(b); check("promote B", (proj.load_current() or {m={}}).m[2] == 0.9)
proj.rollback();  check("rollback restores A", (proj.load_current() or {m={}}).m[2] == 0.3)
os.remove(os.getenv("MEMO_PROJECTION_W"))

-- =========================================================================
header("Section 4 — generic `projected` wrapper over ANY base embedder")

local projected = require("luamemo.embedders.projected")
projected.reset_cache()
-- With no W and base=hash, projected == raw hash (identity default).
local base_v = hash.embed("never commit autonomously", { embed_dim = D })
local proj_v = projected.embed("never commit autonomously", { embed_dim = D, projected_base = "hash" })
check("projected(base=hash), no W == raw hash", approx_eq(base_v, proj_v))
-- Missing base -> clear error (no crash).
local nilv, perr = projected.embed("x", { embed_dim = D })
check("projected without projected_base returns error", nilv == nil and tostring(perr):find("projected_base", 1, true) ~= nil)
-- Injected low-rank identity (U=V=0) == base.
local Wid = proj.identity_lowrank(D, 8)
local id_v = projected.embed("never commit autonomously", { embed_dim = D, projected_base = "hash", projection_W = Wid })
check("projected with identity low-rank W == base", approx_eq(base_v, id_v))

-- =========================================================================
header("Section 5 — low-rank training (W = I + U·V) fixes a violated triple")

local q = hash.embed("which database postgres client library do we use", { embed_dim = D })
local p = hash.embed("never commit or push autonomously without asking", { embed_dim = D })
local n = hash.embed("postgres access uses pgmoon rather than luadbi here", { embed_dim = D })
local exlr = { { q = q, p = p, negs = { n } } }
local m0 = dot(q, p) - dot(q, n)
assert(m0 < 0.1, "fixture must be margin-violated; got " .. m0)
local loss0 = proj.loss_lowrank(proj.identity_lowrank(D, 8), exlr, 0.1)
local Wlr = proj.train_lowrank(exlr, { dim = D, rank = 8, epochs = 400, lr = 0.1, l2 = 0.0, margin = 0.1, seed = 42 })
local loss1 = proj.loss_lowrank(Wlr, exlr, 0.1)
check("low-rank training reduces triplet loss", loss1 < loss0, string.format("%.4f -> %.4f", loss0, loss1))
local function pn(v) local s=0 for i=1,#v do s=s+v[i]*v[i] end s=math.sqrt(s); local o={} for i=1,#v do o[i]=v[i]/s end return o end
local wq, wp, wn = pn(projected.apply_W(q, Wlr)), pn(projected.apply_W(p, Wlr)), pn(projected.apply_W(n, Wlr))
check("low-rank projection increases the (q·p − q·n) margin", (dot(wq,wp) - dot(wq,wn)) > m0)
check("low-rank training is deterministic (fixed seed)", (function()
    local W2 = proj.train_lowrank(exlr, { dim = D, rank = 8, epochs = 50, lr = 0.1, l2 = 0.0, margin = 0.1, seed = 42 })
    return W2.U[1] == proj.train_lowrank(exlr, { dim = D, rank = 8, epochs = 50, lr = 0.1, l2 = 0.0, margin = 0.1, seed = 42 }).U[1]
end)())

-- =========================================================================
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
