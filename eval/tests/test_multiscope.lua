-- eval/tests/test_multiscope.lua
-- Phase 10 — hierarchical / multi-scope search. store.search accepts a scope SET
-- (args.scopes) and returns the UNION with tier-priority: a higher-importance/tier
-- memory (e.g. an org directive) outranks lower-tier content across the union,
-- via the existing weight — no new ranking logic. Single-scope stays unchanged.
--   Section 1: search over a scope set returns the union
--   Section 2: tier/importance priority — the org directive ranks first
--   Section 3: single-scope search is unchanged (only that scope's rows)
--   Section 4: resolve_scopes composes a deduped, nil-skipping set
--
-- Usage:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/luamemo_dev \
--     lua5.1 eval/tests/test_multiscope.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local db     = require("luamemo.db")
local memory = require("luamemo")
local store  = require("luamemo.store")

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

local ORG, REPO, USER = "ms:org", "ms:repo", "ms:user"
local function wipe()
    for _, s in ipairs({ ORG, REPO, USER }) do
        db.query("DELETE FROM lm_memories WHERE scope = " .. db.escape_literal(s))
    end
end
wipe()

-- Same topic across three scopes; the org directive carries the highest importance/tier.
local o = memory.write({ scope = ORG,  title = "deploy rule", body = "Deployment must go through the release pipeline.", importance = 1.0, tier = 3 })
local r = memory.write({ scope = REPO, title = "deploy note", body = "Deployment uses the staging server first.",       importance = 0.3, tier = 1 })
local u = memory.write({ scope = USER, title = "deploy pref", body = "Deployment I like to watch the logs live.",        importance = 0.3, tier = 1 })

-- =========================================================================
header("Section 1 — search over a scope SET returns the union")
local rows = store.search({ query = "deployment process", scopes = { ORG, REPO, USER }, limit = 10, skip_temporal = true })
local seen = {}
for _, row in ipairs(rows or {}) do seen[row.scope] = true end
check("results span all three scopes", seen[ORG] and seen[REPO] and seen[USER],
    table.concat({ tostring(seen[ORG]), tostring(seen[REPO]), tostring(seen[USER]) }, ","))

-- =========================================================================
header("Section 2 — tier/importance priority across the union")
check("the org directive (tier 3) ranks first", rows and rows[1] and rows[1].scope == ORG,
    rows and rows[1] and rows[1].scope or "none")

-- =========================================================================
header("Section 3 — single-scope search is unchanged")
local only_repo = store.search({ query = "deployment", scope = REPO, limit = 10, skip_temporal = true })
local all_repo = #only_repo > 0
for _, row in ipairs(only_repo) do if row.scope ~= REPO then all_repo = false end end
check("single scope returns only that scope's rows", all_repo, tostring(#only_repo))

-- A two-scope set excludes the third scope.
local pair = store.search({ query = "deployment", scopes = { ORG, REPO }, limit = 10, skip_temporal = true })
local no_user = true
for _, row in ipairs(pair) do if row.scope == USER then no_user = false end end
check("a scope set excludes scopes not in it", no_user)

-- =========================================================================
header("Section 4 — resolve_scopes composes a deduped, ordered set")
local set = store.resolve_scopes({ org = ORG, repo = REPO, user = USER })
check("resolve_scopes returns all parts in order", #set == 3 and set[1] == ORG and set[3] == USER,
    table.concat(set, ","))
local dedup = store.resolve_scopes({ org = nil, repo = REPO, user = REPO, global = "global" })
check("resolve_scopes skips nils and dedups", #dedup == 2 and dedup[1] == REPO and dedup[2] == "global",
    table.concat(dedup, ","))

wipe()
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
