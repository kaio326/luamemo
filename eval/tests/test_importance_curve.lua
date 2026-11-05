-- eval/tests/test_importance_curve.lua
-- MEMO_IMPORTANCE_CURVE: how much a memory's importance weighs against how well it matches the question.
-- The score is (vector blend) × importance-weight × age decay. With importances from 0.2 to 6, `linear` (the
-- importance itself) lets importance decide the order; `sqrt` and `log` (log2(1+x)) compress the spread so a
-- clearly better match can beat a more important memory. The default is `sqrt`: on the corpus it beat `linear` on
-- every comparison with no regression (eval/README.md).
--   A. the curves: 0 at 0, 1 at 1, rising, and the spreads the setting's text claims
--   B. a memory that matches the question exactly (cosine 1.0, importance 0.8) against a weak match (0.3,
--      importance 5): linear puts the weak, important one first; sqrt and log put the exact match first
--   C. the default is sqrt; a name that is not a curve behaves as the default
-- Run: luajit eval/tests/run.lua --only importance_curve

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Importance curve")
local check, section, finish = T.check, T.section, T.finish

local luamemo = require("luamemo")
local db      = require("luamemo.db")
local store   = require("luamemo.store")

local MAIN = assert(os.getenv("MEMO_DB"), "run it with eval/tests/run.lua (MEMO_DB)")
local DIM = 384
local QUERY = "how does the retry backoff work"

local function setup(curve)
    luamemo.setup({ db = MAIN, embedder_local = "hash", embed_dim = DIM, skip_embed_probe = true, patterns_enabled = false,
                    importance_curve = curve })
end

section("the curves", function()
    local C = store.IMPORTANCE_CURVES
    for _, name in ipairs({ "linear", "sqrt", "log" }) do
        local f = C[name]
        check(name .. ": 0 at 0, 1 at 1, rising", f(0) == 0 and math.abs(f(1) - 1) < 1e-12 and f(0.5) < f(1) and f(1) < f(3) and f(3) < f(6))
    end
    local function spread(f) return f(6) / f(0.2) end
    check("the spreads of 0.2 to 6 are 30x, 5.5x and 11x, as the setting says",
        math.abs(spread(C.linear) - 30) < 0.01 and math.abs(spread(C.sqrt) - 5.48) < 0.01 and math.abs(spread(C.log) - 10.7) < 0.1,
        spread(C.linear) .. " " .. spread(C.sqrt) .. " " .. spread(C.log))
end)

-- two memories whose vectors are chosen: A is the question's own vector, B is 0.3 of the way to it
local function unit(v)
    local n = 0
    for i = 1, #v do n = n + v[i] * v[i] end
    n = math.sqrt(n)
    for i = 1, #v do v[i] = v[i] / n end
    return v
end

local function fill(scope)
    db.run("DELETE FROM lm_memories WHERE scope = ?", scope)
    local q = unit(assert(require("luamemo.embed").embed(QUERY)))
    -- a direction orthogonal to q
    local w = {}
    for i = 1, DIM do w[i] = (i == 1) and 1 or 0 end
    local dot = 0
    for i = 1, DIM do dot = dot + w[i] * q[i] end
    for i = 1, DIM do w[i] = w[i] - dot * q[i] end
    unit(w)
    local c, s = 0.3, math.sqrt(1 - 0.09)
    local b = {}
    for i = 1, DIM do b[i] = c * q[i] + s * w[i] end
    local res = store.write_many({
        { scope = scope, title = "exact", body = "zzz alpha", importance = 0.8, embedding = q },
        { scope = scope, title = "weak", body = "zzz omega", importance = 5, embedding = b },
    }, { dedup_strategy = "append" })
    for _, r in ipairs(res) do assert(r.row, r.error) end
end

local function first(curve, scope)
    setup(curve)
    local rows = luamemo.search({ scope = scope, query = QUERY, limit = 2, skip_feedback = true, skip_temporal = true, skip_observations = true })
    return rows and rows[1] and rows[1].title, rows
end

section("which memory comes first", function()
    setup("linear")
    local scope = "repo:curve"
    fill(scope)
    local top = first("linear", scope)
    check("linear: the weak match with importance 5 beats the exact match with 0.8", top == "weak", top)
    local t2 = first("sqrt", scope)
    check("sqrt: the exact match comes first", t2 == "exact", t2)
    local t3 = first("log", scope)
    check("log: the exact match comes first", t3 == "exact", t3)
    check("the default is sqrt (measured against linear: eval/README.md)", require("luamemo.settings").defaults().importance_curve == "sqrt")
    local t5 = first("nonsense", scope)
    check("a name that is not a curve: the default curve (sqrt), not the odd one out", t5 == "exact", t5)
end)

finish()
