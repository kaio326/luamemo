-- eval/tests/test_golden.lua
-- Phase 14.5b — the golden fixture of 14.1b (eval/fixtures/golden_routes_hooks.json:
-- what luamemo/routes.lua and luamemo/hooks.lua wrote and returned before both were
-- removed) reproduced through the `memo` CLI and through the MCP server, each on a
-- fresh database, normalised as it was recorded (symbolic ids, no times / scores /
-- vectors):
--   * every route call has its CLI and MCP equivalent with the same rows and results
--     (knowledge-graph writes are CLI-only by the owner's decision — MCP reads them);
--     search results compare as sets with the same top result (ranking across
--     storage engines is 14.7's gate);
--   * the capture helpers' four shapes (user turn, assistant turn with tool calls,
--     tool call, decision) written with memo write / memory_write and the conventions
--     in SESSION_CONTINUITY.md give the recorded rows — a repeated tool call and a
--     restated decision merge into the same row.
-- Run: luajit eval/tests/run.lua --only golden

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Golden fixtures")
local check, section, finish = T.check, T.section, T.finish
local sh, slurp = H.sh, H.slurp
local json = require("luamemo.json")

local fixture = json.decode((assert(slurp("eval/fixtures/golden_routes_hooks.json"), "fixture missing")))
local MEMO = (sh("pwd")) .. "/cli/memo"
local KEY = ("ab"):rep(32)
local q = require("luamemo.util").shell_quote

-- ---------------------------------------------------------------------------
-- Normalisation, as the recorder did it (eval/fixtures: ids per table m / f / o).
-- ---------------------------------------------------------------------------
local function normaliser(start)   -- start: the numbering so far, e.g. { m = 7 }
    local idmap, nid, real = {}, {}, {}
    for ns, n in pairs(start or {}) do nid[ns] = n end
    local function sym(id, ns)
        if id == nil or id == json.null then return nil end
        ns = ns or "m"
        local k = ns .. tostring(id)
        if not idmap[k] then nid[ns] = (nid[ns] or 0) + 1; idmap[k] = ns .. nid[ns]; real[idmap[k]] = id end
        return idmap[k]
    end
    local DROP = { created_at = true, updated_at = true, consolidated_at = true, embedding = true, score = true,
        vec_score = true, fts_score = true, weight = true, rrf_score = true, temporal_score = true,
        recorded_at = true, last_used_at = true, valid_from = "time", valid_to = "time", valid_until = "time",
        invalidated_at = "time", elapsed_ms = true, duration_ms = true }
    local IDS = { id = true, source_id = true, source_memory_id = true, memory_id = true, merged_into = true,
        source_ids = true, summary_id = true, new_ids = true, replaced_ids = true }
    local function norm(v, key, ns)
        if type(v) ~= "table" then
            if key == "id" then return sym(v, ns) end
            if IDS[key] then return sym(v, "m") end
            if type(v) == "number" and v ~= math.floor(v) then return tonumber(("%.6g"):format(v)) end
            return v
        end
        local out = {}
        if #v > 0 then
            for i, x in ipairs(v) do out[i] = norm(x, key, ns) end
            return out
        end
        local own = (v.predicate ~= nil and "f") or ((v.kind == "observation" or v.type == "observation") and "o") or "m"
        for k, x in pairs(v) do
            local d = DROP[k]
            if d == "time" then out[k] = (x ~= nil and x ~= "" and x ~= json.null) and "<time>" or nil
            elseif not d then out[k] = norm(x, k, own) end
        end
        return out
    end
    return norm, real
end

-- Does `got` hold everything `want` (the fixture) says? → nil | the first difference.
-- A fixture null matches nothing / null / false / 0; an empty fixture table matches an
-- absent or empty one; numbers compare to 1e-6.
local function differs(want, got, path)
    path = path or "$"
    if want == json.null then
        if got == nil or got == json.null or got == false or got == 0 then return nil end
        return path .. ": expected nothing, got " .. json.encode(got)
    end
    if type(want) == "table" then
        if next(want) == nil then
            if got == nil or got == json.null or (type(got) == "table" and next(got) == nil) then return nil end
            return path .. ": expected empty, got " .. json.encode(got)
        end
        if type(got) ~= "table" then return path .. ": expected a table, got " .. tostring(got) end
        if #want > 0 then
            if #got ~= #want then return ("%s: %d items, expected %d"):format(path, #got, #want) end
            for i = 1, #want do
                local d = differs(want[i], got[i], path .. "[" .. i .. "]")
                if d then return d end
            end
            return nil
        end
        for k, w in pairs(want) do
            local d = differs(w, got[k], path .. "." .. tostring(k))
            if d then return d end
        end
        return nil
    end
    if type(want) == "number" and tonumber(got) and math.abs(want - tonumber(got)) < 1e-6 then return nil end
    if want ~= got then return ("%s: expected %s, got %s"):format(path, tostring(want), tostring(got)) end
    return nil
end

local function is_error(r) return type(r) == "table" and (r.ok == false or r.error ~= nil) end
local function memories(rows)
    local out = {}
    for _, r in ipairs(rows or {}) do if r.kind ~= "observation" then out[#out + 1] = r.id end end
    return out
end
local function same_set(a, b)
    if #a ~= #b then return false end
    local seen = {}
    for _, x in ipairs(a) do seen[x] = (seen[x] or 0) + 1 end
    for _, x in ipairs(b) do if not seen[x] or seen[x] == 0 then return false end; seen[x] = seen[x] - 1 end
    return true
end

-- One check per recorded route call: kind "same" (the response holds the fixture's),
-- "error", "search" (same memories, same top one).
local function compare(i, label, kind, got)
    local want = fixture.routes[i].response
    local d
    if kind == "error" then
        d = (not is_error(got)) and ("expected an error, got " .. json.encode(got)) or nil
    elseif kind == "search" then
        local w, g = memories(want.results), memories((got or {}).results)
        d = (not (same_set(w, g) and w[1] == g[1])) and ("memories " .. json.encode(g) .. ", expected "
            .. json.encode(w)) or nil
    else
        d = differs(want, got)
    end
    check(("route %d %s → %s"):format(i, fixture.routes[i].request.route, label), d == nil, d)
end

-- ---------------------------------------------------------------------------
-- The route calls, through the CLI
-- ---------------------------------------------------------------------------
local tmp = os.tmpname(); os.remove(tmp)
os.execute(("mkdir -p %q"):format(tmp))
local secret_file, empty_file = tmp .. "/secret", tmp .. "/empty"
local f = assert(io.open(secret_file, "w")); f:write("not-a-real-secret\n"); f:close()
f = assert(io.open(empty_file, "w")); f:close()

local S, K = "golden:routes", "golden:kg"
local BODY1 = "How to deploy the app with docker compose on the staging host"

section("routes through the CLI", function()
io.write("\n--- route calls through memo ---\n")
local ENV = ("MEMO_DB=%q MEMO_MASTER_KEY=%s MEMO_PROJECT=%q"):format(H.db_path("golden_cli"), KEY, tmp)
local norm, real = normaliser()
local function memo(args)
    local out, code = sh(("%s %q %s 2>/dev/null </dev/null"):format(ENV, MEMO, args))
    local t = json.decode(out)
    if type(t) ~= "table" then t = { ok = false, error = out, exit = code } end
    if code ~= 0 and t.ok == nil then t.ok = false end
    return norm(t)
end
compare(1, "memo write", "same", memo(("write --scope %s --kind fact --title 'Deploy guide' --body %s "
    .. "--tags deploy,docker --metadata '{\"source\":\"golden\"}' --importance 2 --decay-rate 0.01"):format(S, q(BODY1))))
compare(2, "memo write", "same", memo(("write --scope %s --kind decision --title 'Cache notes' --body %s "
    .. "--importance 3"):format(S, q("We keep the Redis cache TTL at ten minutes for session data"))))
compare(3, "memo write --dedup-strategy update", "same", memo(("write --scope %s --kind fact --title 'Deploy guide' "
    .. "--body %s --dedup-strategy update --tags deploy"):format(S, q(BODY1))))
compare(4, "memo write (title only)", "same", memo(("write --scope %s --kind fact --title 'no body'"):format(S)))
compare(5, "memo search", "search", memo(("search 'deploy docker compose' --scope %s --limit 5"):format(S)))
compare(6, "memo search --kind", "search", memo(("search 'redis cache' --scope %s --kind decision"):format(S)))
compare(7, "memo search (no query)", "error", memo(("search '' --scope %s"):format(S)))
compare(8, "memo recent", "same", memo(("recent --scope %s --limit 10"):format(S)))
compare(9, "memo get", "same", memo("get " .. tostring(real.m1)))
compare(10, "memo update", "same", memo(("update %s --title 'Cache notes v2' --importance 5"):format(tostring(real.m2))))
compare(11, "memo delete", "same", memo("delete " .. tostring(real.m2)))
compare(12, "memo get (deleted)", "error", memo("get " .. tostring(real.m2)))
compare(13, "memo summarize --dry-run", "same", memo(("summarize --scope %s --dry-run"):format(S)))
for i = 1, 3 do
    compare(13 + i, "memo write", "same", memo(("write --scope golden:session --kind chat --title 'turn %d' --body %s")
        :format(i, q(("session turn %d about the deploy plan"):format(i)))))
end
compare(17, "memo promote --dry-run", "same", memo("promote --from golden:session --to golden:long --dry-run"))
compare(18, "memo promote", "same", memo("promote --from golden:session --to golden:long"))
compare(19, "memo consolidate --dry-run", "same", memo(("consolidate --scope %s --dry-run"):format(S)))
compare(20, "memo kg assert", "same", memo(("kg assert --scope %s --subject luamemo --predicate stores_in "
    .. "--object postgres"):format(K)))
compare(21, "memo kg assert --supersede", "same", memo(("kg assert --scope %s --subject luamemo --predicate stores_in "
    .. "--object sqlite --supersede"):format(K)))
compare(22, "memo kg assert", "same", memo(("kg assert --scope %s --subject luamemo --predicate written_in "
    .. "--object lua"):format(K)))
compare(23, "memo kg query", "same", memo(("kg query --scope %s --subject luamemo"):format(K)))
compare(24, "memo kg query --include-invalidated", "same",
    memo(("kg query --scope %s --subject luamemo --include-invalidated"):format(K)))
compare(25, "memo kg timeline", "same", memo(("kg timeline --scope %s --subject luamemo --predicate stores_in"):format(K)))
compare(26, "memo kg invalidate", "same", memo(("kg invalidate --scope %s --subject luamemo --predicate written_in"):format(K)))
compare(27, "memo kg query", "same", memo(("kg query --scope %s --subject luamemo"):format(K)))
compare(28, "memo kg assert (no predicate)", "error", memo(("kg assert --scope %s --subject x"):format(K)))
compare(29, "memo secret-store", "same", memo("secret-store golden_token --desc fixture --file " .. q(secret_file)))
local list = memo("secret-list")
compare(30, "memo secret-list", "same", { ok = true, secrets = list })
compare(31, "memo secret-store (no value)", "error", memo("secret-store golden_token --file " .. q(empty_file)))
compare(32, "memo secret-delete", "same", memo("secret-delete golden_token"))
compare(33, "memo secret-delete (missing)", "error", memo("secret-delete missing_one"))
compare(34, "memo secret-list", "same", { ok = true, secrets = memo("secret-list") })
compare(35, "memo secret-execute (no URL)", "error", memo("secret-execute golden_token"))
end)

-- ---------------------------------------------------------------------------
-- The route calls, through the MCP server (one session)
-- ---------------------------------------------------------------------------
section("routes through MCP", function()
io.write("\n--- route calls through the MCP server ---\n")
local DB = H.db_path("golden_mcp")
local ENV = ("MEMO_DB=%q MEMO_MASTER_KEY=%s MEMO_PROJECT=%q"):format(DB, KEY, tmp)
local norm, real = normaliser()
local s = H.mcp_session(ENV)
-- The fixture holds whole rows: writes and recent lists ask for them (verbose); their
-- compact default — what an agent gets — is checked after the routes.
local FULL = { memory_write = true, memory_recent = true, memory_get = true }
local function call(tool, args)
    if FULL[tool] and args.verbose == nil then args.verbose = true end
    return norm(s.call(tool, args))
end
local function kg_cli(args)   -- the knowledge graph is the CLI's (MCP search carries current facts)
    local out = sh(("%s %q kg %s 2>/dev/null </dev/null"):format(ENV, MEMO, args))
    return norm(json.decode(out) or { ok = false })
end
compare(1, "memory_write", "same", call("memory_write", { scope = S, kind = "fact", title = "Deploy guide",
    body = BODY1, tags = { "deploy", "docker" }, metadata = { source = "golden" }, importance = 2, decay_rate = 0.01 }))
compare(2, "memory_write", "same", call("memory_write", { scope = S, kind = "decision", title = "Cache notes",
    body = "We keep the Redis cache TTL at ten minutes for session data", importance = 3 }))
compare(3, "memory_write dedup_strategy=update", "same", call("memory_write", { scope = S, kind = "fact",
    title = "Deploy guide", body = BODY1, dedup_strategy = "update", tags = { "deploy" } }))
compare(4, "memory_write (title only)", "same", call("memory_write", { scope = S, kind = "fact", title = "no body" }))
compare(5, "memory_search", "search", call("memory_search", { query = "deploy docker compose", scope = S, limit = 5 }))
compare(6, "memory_search kind", "search", call("memory_search", { query = "redis cache", scope = S, kind = "decision" }))
compare(7, "memory_search (no query)", "error", call("memory_search", { scope = S }))
compare(8, "memory_recent", "same", call("memory_recent", { scope = S, limit = 10 }))
-- What an agent gets by default (token cost): no echo of what it wrote, lists and
-- memory_get without the scoring internals.
local cw = s.call("memory_write", { scope = S, kind = "fact", title = "compact check", body = "a body to not echo" })
local cm = cw.memory or {}
check("memory_write answers id / scope / kind / title / tier only (the body isn't echoed)",
    cw.ok and cm.id and cm.scope == S and cm.title == "compact check" and cm.body == nil and cm.tags == nil
    and cm.created_at == nil, json.encode(cw))
local cr = (s.call("memory_recent", { scope = S, limit = 3 }).results or {})[1] or {}
local cs = (s.call("memory_search", { query = "deploy docker compose", scope = S, limit = 3 }).results or {})[1] or {}
check("memory_recent / memory_search rows: text and place, no scoring internals, time to the second",
    cr.id and cr.body and cr.vec_score == nil and cr.decay_rate == nil and cr.updated_at == nil
    and cs.id and cs.body and cs.vec_score == nil and cs.fts_score == nil and cs.weight == nil
    and type(cs.score) == "number" and #tostring(cs.created_at) == 19, json.encode({ cr, cs }))
local vs = (s.call("memory_search", { query = "deploy docker compose", scope = S, limit = 3, verbose = true })
    .results or {})[1] or {}
check("… verbose = true: the whole row", vs.vec_score ~= nil and vs.updated_at ~= nil, json.encode(vs))
local cg = (s.call("memory_get", { id = cm.id }) or {}).memory or {}
local vg = (s.call("memory_get", { id = cm.id, verbose = true }) or {}).memory or {}
check("memory_get: the compact row (no decay_rate / updated_at); verbose = true the whole one",
    cg.id == cm.id and cg.body == "a body to not echo" and cg.decay_rate == nil and cg.updated_at == nil
    and vg.decay_rate ~= nil and vg.updated_at ~= nil, json.encode({ cg, vg }))
s.call("memory_delete", { id = cm.id })
compare(9, "memory_get", "same", call("memory_get", { id = real.m1 }))
local cu = (s.call("memory_update", { id = real.m2, importance = 4 }) or {}).memory or {}
check("memory_update: the row's handle, not its body back (verbose = true: the whole row)",
    cu.id == real.m2 and cu.title ~= nil and cu.body == nil and cu.importance == nil, json.encode(cu))
compare(10, "memory_update", "same", call("memory_update", { id = real.m2, title = "Cache notes v2", importance = 5,
    verbose = true }))
compare(11, "memory_delete", "same", call("memory_delete", { id = real.m2 }))
compare(12, "memory_get (deleted)", "error", call("memory_get", { id = real.m2 }))
compare(13, "memory_summarize dry_run", "same", call("memory_summarize", { scope = S, dry_run = true }))
for i = 1, 3 do
    compare(13 + i, "memory_write", "same", call("memory_write", { scope = "golden:session", kind = "chat",
        title = "turn " .. i, body = ("session turn %d about the deploy plan"):format(i) }))
end
compare(17, "memory_promote dry_run", "same", call("memory_promote", { from_scope = "golden:session",
    to_scope = "golden:long", dry_run = true }))
compare(18, "memory_promote", "same", call("memory_promote", { from_scope = "golden:session", to_scope = "golden:long" }))
compare(19, "memory_consolidate dry_run", "same", call("memory_consolidate", { scope = S, dry_run = true }))
compare(20, "memo kg assert (CLI: writes)", "same", kg_cli(("assert --scope %s --subject luamemo --predicate stores_in "
    .. "--object postgres"):format(K)))
compare(21, "memo kg assert --supersede (CLI)", "same", kg_cli(("assert --scope %s --subject luamemo "
    .. "--predicate stores_in --object sqlite --supersede"):format(K)))
compare(22, "memo kg assert (CLI)", "same", kg_cli(("assert --scope %s --subject luamemo --predicate written_in "
    .. "--object lua"):format(K)))
-- Knowledge-graph reads are CLI too: MCP has no fact tool (owner, 2026-10-10 — the facts a
-- query is about come inside memory_search results; checked in test_surfaces).
compare(23, "memo kg query (CLI)", "same", kg_cli(("query --scope %s --subject luamemo"):format(K)))
compare(24, "memo kg query --include-invalidated (CLI)", "same", kg_cli(("query --scope %s --subject luamemo "
    .. "--include-invalidated"):format(K)))
compare(25, "memo kg timeline (CLI)", "same", kg_cli(("timeline --scope %s --subject luamemo --predicate stores_in")
    :format(K)))
compare(26, "memo kg invalidate (CLI)", "same", kg_cli(("invalidate --scope %s --subject luamemo --predicate written_in")
    :format(K)))
compare(27, "memo kg query (CLI)", "same", kg_cli(("query --scope %s --subject luamemo"):format(K)))
compare(28, "memo kg assert, no predicate (CLI)", "error", kg_cli(("assert --scope %s --subject x"):format(K)))
compare(29, "secret_store", "same", call("secret_store", { name = "golden_token", value = "not-a-real-secret",
    description = "fixture" }))
compare(30, "secret_list", "same", call("secret_list", {}))
compare(31, "secret_store (no value)", "error", call("secret_store", { name = "golden_token" }))
-- Over MCP a secret is never replaced, and deleting takes a preview and a confirm token
-- (a prompt-injected agent could otherwise swap or destroy the user's keys).
local again = call("secret_store", { name = "golden_token", value = "another" })
check("MCP secret_store refuses to replace an existing secret (the user's memo secret-store)",
    is_error(again) and tostring(again.error):find("memo secret-store", 1, true) ~= nil, json.encode(again))
local preview = s.call("secret_delete", { name = "golden_token" })
check("MCP secret_delete: the first call only previews (nothing deleted) and gives a confirm token",
    preview.ok == false and (preview.preview or {}).name == "golden_token" and type(preview.confirm) == "string"
    and #(s.call("secret_list", {}).secrets or {}) == 1, json.encode(preview))
check("… a made-up token is refused", is_error(norm(s.call("secret_delete", { name = "golden_token",
    confirm = "00.1.9999999999" }))))
compare(32, "secret_delete (confirmed)", "same", call("secret_delete", { name = "golden_token",
    confirm = preview.confirm }))
compare(33, "secret_delete (missing)", "error", call("secret_delete", { name = "missing_one" }))
compare(34, "secret_list", "same", call("secret_list", {}))
compare(35, "secret_execute (no URL)", "error", call("secret_execute", { name = "golden_token" }))
s.close()
end)

-- ---------------------------------------------------------------------------
-- The capture helpers' shapes, through memo write and memory_write
-- ---------------------------------------------------------------------------
-- The conventions (SESSION_CONTINUITY.md "Capture conventions"): turns in
-- user:<u>:session:<s>, decisions in user:<u>:long_term; kind / title / tags / metadata
-- per shape; dedup append for chat turns, update for tool calls and decisions.
local SESSION, LONG = "user:u1:session:s1", "user:u1:long_term"
local AFTER_ROUTES = { m = 7 }   -- the recording ran the helpers after the routes: their rows start at m8
local SHAPES = {
    { hook = 3, scope = SESSION, kind = "chat", title = "user: I want to refactor the auth helper.",
      body = "I want to refactor the auth helper.", tags = { "chat", "user" }, dedup = "append",
      metadata = { role = "user", session_id = "s1", user_id = "u1" } },
    { hook = 4, scope = SESSION, kind = "chat", title = "assistant: Here is the refactor plan for the auth helper.",
      body = "Here is the refactor plan for the auth helper.", tags = { "chat", "assistant" }, dedup = "append",
      metadata = { role = "assistant", session_id = "s1", user_id = "u1",
                   tool_calls = { { name = "read_file", args = { filename = "auth.lua" } } } } },
    { hook = 5, scope = SESSION, kind = "tool_call", title = "tool: read_file",
      body = "tool: read_file\nsuccess: true\nargs: auth.lua\nresult: local M = {} return M", tags = { "tool", "read_file" },
      dedup = "update", metadata = { role = "tool", tool = "read_file", success = true, args = "auth.lua",
      result = "local M = {} return M", session_id = "s1", user_id = "u1" } },
    { hook = 6 },   -- the same tool call again
    { hook = 7, scope = LONG, kind = "decision", title = "preference: tailwind v4",
      body = "User prefers Tailwind v4 utilities.", tags = { "decision" }, importance = 3, decay_rate = 0, dedup = "update",
      metadata = { role = "decision", session_id = "s1", user_id = "u1" } },
    { hook = 8 },   -- restated
}
for i, sh_ in ipairs(SHAPES) do if not sh_.scope then
    local prev = SHAPES[i - 1]
    for k, v in pairs(prev) do if k ~= "hook" then sh_[k] = v end end
end end

local function final_rows(recent)
    check("… the session's rows are the recorded ones", differs(fixture.hooks_final_rows.session,
        recent(SESSION)) == nil, differs(fixture.hooks_final_rows.session, recent(SESSION)))
    check("… and the long-term ones", differs(fixture.hooks_final_rows.long_term, recent(LONG)) == nil,
        differs(fixture.hooks_final_rows.long_term, recent(LONG)))
end

section("capture shapes through the CLI", function()
io.write("\n--- capture shapes through memo write ---\n")
local ENV = ("MEMO_DB=%q MEMO_PROJECT=%q"):format(H.db_path("golden_hooks_cli"), tmp)
local norm = normaliser(AFTER_ROUTES)
local function memo(args)
    return norm(json.decode((sh(("%s %q %s 2>/dev/null </dev/null"):format(ENV, MEMO, args)))) or { ok = false })
end
for _, shp in ipairs(SHAPES) do
    local args = ("write --scope %s --kind %s --title %s --body %s --tags %s --metadata %s --dedup-strategy %s")
        :format(q(shp.scope), shp.kind, q(shp.title), q(shp.body), q(table.concat(shp.tags, ",")),
            q(json.encode(shp.metadata)), shp.dedup)
    if shp.importance then args = args .. " --importance " .. shp.importance end
    if shp.decay_rate then args = args .. " --decay-rate " .. shp.decay_rate end
    local r = memo(args)
    local hook = fixture.hooks[shp.hook]
    check(("%s → memo write"):format(hook.helper), differs(hook.row, r.memory) == nil, differs(hook.row, r.memory))
end
local empty = memo("write --scope " .. q(SESSION) .. " --kind chat --title '' --body ''")
check("an empty turn is not written (the helper refused it too)", empty.ok == false)
final_rows(function(scope) return memo("recent --scope " .. q(scope) .. " --limit 20").results end)
end)

section("capture shapes through MCP", function()
io.write("\n--- capture shapes through memory_write ---\n")
local s = H.mcp_session(("MEMO_DB=%q MEMO_PROJECT=%q"):format(H.db_path("golden_hooks_mcp"), tmp))
local norm = normaliser(AFTER_ROUTES)
for _, shp in ipairs(SHAPES) do
    local r = norm(s.call("memory_write", { scope = shp.scope, kind = shp.kind, title = shp.title, body = shp.body,
        tags = shp.tags, metadata = shp.metadata, dedup_strategy = shp.dedup, importance = shp.importance,
        decay_rate = shp.decay_rate, verbose = true }))
    local hook = fixture.hooks[shp.hook]
    check(("%s → memory_write"):format(hook.helper), differs(hook.row, r.memory) == nil, differs(hook.row, r.memory))
end
local empty = s.call("memory_write", { scope = SESSION, kind = "chat", title = "", body = "" })
check("an empty turn is not written", empty.error ~= nil)
final_rows(function(scope) return norm(s.call("memory_recent", { scope = scope, limit = 20, verbose = true })).results end)
s.close()
end)

os.execute(("rm -rf %q"):format(tmp))
H.drop_dbs()
finish()
