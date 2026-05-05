-- Phase 9 runner: tune `hybrid_weights` for a scope.
--
-- Usage (against the existing local smoke DB, no pgvector required):
--   PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=lm_bruteforce_test \
--     lua5.1 eval/tune_weights.lua --scope smoke
--
-- Optional flags:
--   --scope <name>          memory scope to evaluate (default: "smoke")
--   --samples <N>           rows to sample (default: 50)
--   --primary <metric>      r_at_1 | r_at_3 | r_at_5 | r_at_10 | mrr (default: r_at_1)
--
-- Output: a sorted blend table + a recommendation block including a
-- "safe K" estimate and the resulting prompt-token savings model.

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

-- Wire the pgmoon shim BEFORE requiring any lapis_memory module.
local db_shim = require("_smoke_lapis_db")
db_shim._connect({
    host     = os.getenv("PGHOST") or "127.0.0.1",
    port     = tonumber(os.getenv("PGPORT") or "5432"),
    database = os.getenv("PGDATABASE") or "lm_bruteforce_test",
    user     = os.getenv("PGUSER") or "postgres",
    password = os.getenv("PGPASSWORD") or "postgres",
})
package.loaded["lapis.db"] = db_shim

-- --- arg parsing ----------------------------------------------------------
local args = { scope = "smoke", samples = 50, primary = "r_at_1" }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--scope"   then args.scope   = arg[i + 1]; i = i + 2
        elseif a == "--samples" then args.samples = tonumber(arg[i + 1]); i = i + 2
        elseif a == "--primary" then args.primary = arg[i + 1]; i = i + 2
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
    end
end

local memory = require("lapis_memory")

memory.setup({
    db_table       = "lapis_memory",
    embedder_local = "hash",
    embed_dim      = 384,
    backend        = "auto",
    default_scope  = args.scope,
    auth_fn        = function() return true end,
})

print(string.format("scope=%q  samples=%d  primary=%s  backend=%s",
    args.scope, args.samples, args.primary, memory.store.backend()))

local res, err = memory.tune_weights.run({
    scope          = args.scope,
    sample_size    = args.samples,
    primary_metric = args.primary,
})
if not res then
    io.stderr:write("tune_weights failed: " .. tostring(err) .. "\n")
    os.exit(1)
end

-- --- output ---------------------------------------------------------------
local function fmt_pct(x) return string.format("%5.1f%%", (x or 0) * 100) end

print(string.format("\nN queries: %d   avg row tokens: %d", res.n_queries, res.avg_row_tokens))
print(string.rep("-", 64))
print(string.format("%-12s %-7s %-7s %-7s %-7s %-7s",
    "blend(v/f)", "R@1", "R@3", "R@5", "R@10", "MRR"))
print(string.rep("-", 64))

-- Sort by primary metric desc for display.
local function score_of(b)
    if args.primary == "mrr" then return b.mrr end
    local k = tonumber(args.primary:match("^r_at_(%d+)$")) or 1
    return b.r_at[k] or 0
end
local sorted = {}
for _, b in ipairs(res.blends) do sorted[#sorted + 1] = b end
table.sort(sorted, function(a, b)
    local sa, sb = score_of(a), score_of(b)
    if sa ~= sb then return sa > sb end
    return a.mrr > b.mrr
end)

for _, b in ipairs(sorted) do
    print(string.format("%4.1f / %4.1f  %s  %s  %s  %s  %5.3f",
        b.wv, b.wf,
        fmt_pct(b.r_at[1]), fmt_pct(b.r_at[3]),
        fmt_pct(b.r_at[5]), fmt_pct(b.r_at[10]),
        b.mrr))
end

print(string.rep("-", 64))

-- Default-vs-best diff (default = 0.7 / 0.3).
local default_blend
for _, b in ipairs(res.blends) do
    if math.abs(b.wv - 0.7) < 1e-6 and math.abs(b.wf - 0.3) < 1e-6 then
        default_blend = b; break
    end
end

print("\nRECOMMENDATION")
print(string.format("  hybrid_weights = { vector = %.1f, fts = %.1f }", res.best.wv, res.best.wf))
print(string.format("  R@1 = %s   R@5 = %s   R@10 = %s   MRR = %.3f",
    fmt_pct(res.best.r_at[1]), fmt_pct(res.best.r_at[5]),
    fmt_pct(res.best.r_at[10]), res.best.mrr))

if default_blend then
    print(string.format("  vs default (0.7/0.3):  R@1 %+.2f   R@5 %+.2f   R@10 %+.2f",
        res.best.r_at[1] - default_blend.r_at[1],
        res.best.r_at[5] - default_blend.r_at[5],
        res.best.r_at[10] - default_blend.r_at[10]))
end

-- Token-cost framing.
if res.safe_k then
    local default_k = 10
    local saved = math.max(0, default_k - res.safe_k) * res.avg_row_tokens
    print(string.format(
        "\n  Safe K = %d  (R@%d >= 85%% on this scope).",
        res.safe_k, res.safe_k))
    print(string.format(
        "  Switching K from %d -> %d on this scope frees ~%d prompt tokens",
        default_k, res.safe_k, saved))
    print("  per memory-backed agent turn. At ~$2.50/1M input tokens and 10")
    print(string.format("  turns/session that's ~$%.0f saved per 1M sessions.",
        saved * 10 * 2.50))
else
    print("\n  Safe K = none reached 85% R@K on this scope at any blend.")
    print("  Likely causes: hash embedder is too weak for this corpus, or")
    print("  the scope contains too many near-duplicates / unrelated rows.")
    print("  Try a real embedder before tuning further.")
end

print("\nOK")
