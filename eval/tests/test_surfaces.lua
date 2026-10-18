-- eval/tests/test_surfaces.lua
-- Phase 14.5b — what the Lua API alone could do, now through BOTH surfaces: the
-- `memo` CLI (as a subprocess) and the MCP server (JSON-RPC over stdio).
--   B. Knowledge graph: memo kg assert|query|invalidate|timeline (default scope
--      $MEMO_SCOPE; --supersede; point-in-time --at); on MCP the facts a query is about
--      come with memory_search (and memo search) — no separate fact tool; a dev's org:
--      replica takes no facts.
-- Run: luajit eval/tests/run.lua --only surfaces

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Surfaces")
local check, section, finish = T.check, T.section, T.finish
local sh = H.sh
local json = require("luamemo.json")

local REPO = (sh("pwd"))
local MEMO = REPO .. "/cli/memo"
local q = require("luamemo.util").shell_quote
-- `memo ARGS` with the runner's database (MEMO_DB) and an extra env prefix.
local function memo(env, args) return sh(("%s %q %s </dev/null"):format(env or "", MEMO, args)) end
local function memo_json(env, args)
    local out, code = memo(env, args .. " 2>/dev/null")
    return json.decode(out) or {}, code, out
end

-- ---------------------------------------------------------------------------
section("B. knowledge graph", function()
io.write("\n--- B: knowledge graph ---\n")
local S = "repo:kgtest"
local E = "MEMO_SCOPE=" .. S
local a1, c1 = memo_json(E, "kg assert --subject svc --predicate status --object up --valid-from 2026-01-01")
check("memo kg assert: a fact in $MEMO_SCOPE", c1 == 0 and a1.ok and (a1.fact or {}).object == "up"
    and a1.fact.scope == S, json.encode(a1))
local a2 = memo_json(E, "kg assert --subject svc --predicate status --object down --valid-from 2026-03-01 --supersede")
check("--supersede ends the current value where the new one starts", a2.ok == true)
local cur = memo_json(E, "kg query --subject svc")
check("memo kg query: the value now", #(cur.results or {}) == 1 and cur.results[1].object == "down", json.encode(cur))
local all = memo_json(E, "kg query --subject svc --include-invalidated")
check("--include-invalidated: every value", #(all.results or {}) == 2)
local past = memo_json(E, "kg query --subject svc --at 2026-02-01")
check("--at: the value at that time", #(past.results or {}) == 1 and past.results[1].object == "up", json.encode(past))
local tl = memo_json(E, "kg timeline --subject svc --predicate status")
check("memo kg timeline: the history, oldest first", #(tl.results or {}) == 2 and tl.results[1].object == "up"
    and tl.results[1].valid_until ~= nil and tl.results[2].object == "down", json.encode(tl))
-- 2026-02-01T00:00:00Z as Unix seconds (memo write / search take them; kg refused them).
local epoch = memo_json(E, "kg query --subject svc --at 1769904000")
check("--at in Unix seconds", #(epoch.results or {}) == 1 and epoch.results[1].object == "up", json.encode(epoch))
local _, _, other_raw = memo_json("", "kg query --scope repo:elsewhere --subject svc")
local other = json.decode(other_raw) or {}
check("--scope: another scope sees nothing of this one", other.ok and #(other.results or {}) == 0)
check("… and no results print as [] (an empty Lua table encoded as {} before)",
    other_raw:find('"results": []', 1, true) ~= nil, other_raw)
local bad, bc = memo_json(E, "kg assert --subject svc --object x")
check("a missing argument: ok false, exit 1, naming it", bc == 1 and bad.ok == false
    and tostring(bad.error):find("predicate", 1, true) ~= nil, json.encode(bad))
local _, uc = memo(E, "kg bogus")
check("an unknown action prints the usage (exit 2)", uc == 2)

-- MCP: facts ride along with memory_search (owner, 2026-10-10 — KG spike 2: a separate
-- fact tool went almost unused; with facts in the search results a small model answered
-- 94 % instead of 60 %).
memo_json(E, "kg assert --subject payments_team --predicate tech_lead --object Ana --valid-from 2026-01-10")
memo_json(E, "kg assert --subject payments_team --predicate tech_lead --object Bruno --valid-from 2026-09-30 --supersede")
memo_json(E, "kg assert --scope codeindex:kgtest --subject payments --predicate requires --object db")
memo_json(E, "write --scope " .. S .. " --title 'Payments lead' --body 'Ana is the tech lead of the payments team.'")
local res = H.mcp(E, {
    { method = "tools/list" },
    { "memory_search", { query = "Who is the payments team's tech lead now?" } },
    { "memory_search", { query = "status of the svc service" } },
    { "memory_search", { query = "the office address" } },
    { "memory_search", { query = "payments tech leads", scopes = { "repo:elsewhere" } } },
})
local has_facts_tool, desc
for _, t in ipairs(((res[1] or {}).tools) or {}) do
    if t.name == "memory_facts" then has_facts_tool = true end
    if t.name == "memory_search" then desc = t.description end
end
check("MCP has no separate fact tool; memory_search says its results may carry facts", not has_facts_tool
    and tostring(desc):find("`facts`", 1, true) ~= nil, desc)
local f1 = ((res[2] or {}).facts or {})[1] or {}
check("memory_search: the fact the query is about — current value, since when, the previous value",
    f1.subject == "payments_team" and f1.value == "Bruno" and tostring(f1.since):find("2026-09-30", 1, true)
    and (f1.previous or {}).value == "Ana" and #(res[2].results or {}) >= 1, json.encode(res[2]))
local f2 = ((res[3] or {}).facts or {})[1] or {}
check("… a word of the subject or predicate is enough (\"status\" of svc)", f2.subject == "svc" and f2.value == "down",
    json.encode(res[3] and res[3].facts))
check("… none when the query names nothing recorded", (res[4] or {}).facts == nil, json.encode(res[4] and res[4].facts))
check("… only from the searched scopes", (res[5] or {}).facts == nil, json.encode(res[5] and res[5].facts))
local cli = memo_json(E, "search 'payments tech lead'")
local from_map = false
for _, f in ipairs(cli.facts or {}) do if tostring(f.scope):match("^codeindex:") then from_map = true end end
check("memo search returns the same facts (a search of every scope: never the code maps')",
    ((cli.facts or {})[1] or {}).value == "Bruno" and not from_map, json.encode(cli.facts))
local kg = require("luamemo.kg")
check("query words: lowercased, split on _ and -, stopwords dropped, a plural s trimmed",
    table.concat(kg._words("Who are the Payments_Team's tech-leads now?"), " ") == "payment team tech lead")

local inv = memo_json(E, "kg invalidate --subject svc --predicate status")
check("memo kg invalidate: the current value ends", inv.invalidated == 1
    and #(memo_json(E, "kg query --subject svc").results or { 1 }) == 0, json.encode(inv))

-- A dev's org: scope is the org's replica: no facts there.
local DEV = "MEMO_ORG_URL=http://127.0.0.1:9"
local rep, rc = memo_json(DEV, "kg assert --scope org:acme --subject a --predicate b --object c")
check("dev: a fact in the org: replica is refused", rc == 1 and rep.ok == false
    and tostring(rep.error):find("read-only replica", 1, true) ~= nil, json.encode(rep))
local rinv = memo_json(DEV, "kg invalidate --scope org:acme --subject a --predicate b")
check("… and so is invalidating one", rinv.ok == false)
end)

-- ---------------------------------------------------------------------------
-- Rows to delete: `n` memories in `scope` (kind / metadata per row).
local function seed(scope, rows)
    local store = require("luamemo.store")
    for i, r in ipairs(rows) do
        assert(store.write({ scope = scope, kind = r.kind or "note", title = r.title or (scope .. " row " .. i),
            body = (r.body or "distinct body") .. " " .. i .. " " .. scope, metadata = r.metadata,
            dedup_strategy = "append" }))
    end
end
local function count(scope)
    return tonumber(require("luamemo.db").value("SELECT count(*) FROM lm_memories WHERE scope = ?", scope))
end

section("C. bulk delete by filter", function()
io.write("\n--- C: bulk delete ---\n")
require("luamemo").setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, patterns_enabled = false })
seed("del:cli", { { kind = "a" }, { kind = "a", metadata = { flag = true } }, { kind = "b", metadata = { src = "imp" } } })
local p, pc = memo_json("", "delete --scope del:cli --kind a")
check("memo delete --scope --kind: a preview — how many, the titles, nothing deleted", pc == 0 and p.count == 2
    and #(p.titles or {}) == 2 and p.deleted == 0 and count("del:cli") == 3, json.encode(p))
local mb = memo_json("", [[delete --scope del:cli --meta '{"flag":true}']])
check("--meta matches metadata values (true / false too)", mb.count == 1, json.encode(mb))
local bad, bc = memo_json("", [[delete --scope del:cli --meta '{"a":{"b":1}}']])
check("a metadata filter luamemo can't apply is refused, not skipped", bc == 1 and bad.ok == false
    and tostring(bad.error):find("values are text", 1, true) ~= nil, json.encode(bad))
local _, nc = memo("", "delete --kind a")
check("by filter, --scope is required", nc ~= 0)
local y = memo_json("", "delete --scope del:cli --kind a --yes")
check("--yes deletes them", y.deleted == 2 and count("del:cli") == 1, json.encode(y))
local y2 = memo_json("", [[delete --scope del:cli --meta '{"src":"imp"}' --yes]])
check("… by metadata too", y2.deleted == 1 and count("del:cli") == 0)

-- MCP: preview, then confirm with the token — one server session.
seed("del:mcp", { {}, {}, {}, { kind = "keep" } })
local s = H.mcp_session("")
local pv = s.call("memory_delete", { scope = "del:mcp", kind = "note" })
check("MCP memory_delete by filter: a preview with a confirm token, nothing deleted", pv.preview == true
    and pv.count == 3 and #(pv.titles or {}) == 3 and type(pv.confirm) == "string" and pv.expires_in_seconds == 300
    and count("del:mcp") == 4, json.encode(pv))
local other = s.call("memory_delete", { scope = "del:mcp", kind = "keep", confirm = pv.confirm })
check("the token is bound to its filter: for another one, nothing deleted (a new preview)", other.preview == true
    and other.deleted == 0 and (other.note or ""):find("another filter", 1, true) ~= nil and count("del:mcp") == 4,
    json.encode(other))
local forged = s.call("memory_delete", { scope = "del:mcp", kind = "note",
    confirm = (pv.confirm:gsub("^(%x+)%.%d+", "%1.7")) })
check("… and to its count (a token edited to another count is refused)", forged.preview == true
    and count("del:mcp") == 4, json.encode(forged))
local old = s.call("memory_delete", { scope = "del:mcp", kind = "note", confirm = "abcd.3.1000" })
check("an expired token is refused", (old.note or ""):find("expired", 1, true) ~= nil and count("del:mcp") == 4)
seed("del:mcp", { {} })
local changed = s.call("memory_delete", { scope = "del:mcp", kind = "note", confirm = pv.confirm })
check("the matches changed since the preview: refused, previewed again with the new count", changed.preview == true
    and changed.count == 4 and (changed.note or ""):find("3 then, 4 now", 1, true) ~= nil and count("del:mcp") == 5,
    json.encode(changed))
local done = s.call("memory_delete", { scope = "del:mcp", kind = "note", confirm = changed.confirm })
check("the token of the latest preview deletes them", done.deleted == 4 and count("del:mcp") == 1, json.encode(done))
local keep_id = tonumber(require("luamemo.db").value("SELECT id FROM lm_memories WHERE scope = 'del:mcp'"))
local one = s.call("memory_delete", { id = keep_id })
check("memory_delete by id still deletes one", one.ok == true and count("del:mcp") == 0)
local noscope = s.call("memory_delete", { kind = "note" })
check("by filter, a scope is required", (noscope.error or ""):find("scope", 1, true) ~= nil)
s.close()

seed("del:mcp2", { {}, {} })
local s1 = H.mcp_session("")
local t1 = s1.call("memory_delete", { scope = "del:mcp2" }).confirm
s1.close()
local s2 = H.mcp_session("")
local later = s2.call("memory_delete", { scope = "del:mcp2", confirm = t1 })
s2.close()
check("a token works only in the server process that gave it", later.preview == true and count("del:mcp2") == 2,
    json.encode(later))
local dev = H.mcp_session("MEMO_ORG_URL=http://127.0.0.1:9")
local rep = dev.call("memory_delete", { scope = "org:acme" })
dev.close()
check("dev: the org replica can't be bulk-deleted", (rep.error or ""):find("read-only replica", 1, true) ~= nil,
    json.encode(rep))
end)

-- ---------------------------------------------------------------------------
section("D. backdated and batch writes", function()
io.write("\n--- D: backdated / batch writes ---\n")
local w = memo_json("", "write --scope d:cli --kind fact --title back --body " .. q("dated text one")
    .. " --created-at 2026-01-02T03:04:05Z")
check("memo write --created-at ISO: a backdated memory", ((w.memory or {}).created_at or ""):find("^2026%-01%-02 03:04:05")
    ~= nil, json.encode(w.memory))
local we = memo_json("", "write --scope d:cli --kind fact --title epoch --body " .. q("dated text two")
    .. " --created-at 1700000000")
check("… or epoch seconds", ((we.memory or {}).created_at or ""):find("^2023%-11%-14 22:13:20") ~= nil,
    json.encode(we.memory))
local wb = memo_json("", "write --scope d:cli --kind fact --title bad --body x --created-at banana")
check("an unreadable --created-at is refused (never silently now)", wb.ok == false
    and tostring(wb.error):find("created_at", 1, true) ~= nil, json.encode(wb))
local s = H.mcp_session("MEMO_SCOPE=d:mcp")
local one = s.call("memory_write", { title = "past", body = "a past event", created_at = "2025-05-06T07:08:09Z",
    verbose = true })
check("MCP memory_write created_at", ((one.memory or {}).created_at or ""):find("^2025%-05%-06 07:08:09") ~= nil,
    json.encode(one))
local batch = s.call("memory_write", { items = {
    { title = "b1", body = "first of the batch" },
    { title = "b2", body = "second of the batch", kind = "decision", created_at = "2024-01-01" },
    { title = "b3", body = "third", created_at = "not a time" },
} })
check("MCP memory_write items: several in one call, each with its own result", batch.written == 2 and batch.failed == 1
    and (batch.results[1] or {}).id ~= nil and tostring((batch.results[3] or {}).error):find("created_at", 1, true) ~= nil,
    json.encode(batch))
local got = require("luamemo.db").first("SELECT kind, created_at FROM lm_memories WHERE title = 'b2'") or {}
check("… a batch row keeps its kind and date", got.kind == "decision"
    and require("luamemo.util").us_to_iso(got.created_at):find("^2024%-01%-01") ~= nil)
local many = {}
for i = 1, 101 do many[i] = { title = "t" .. i, body = "b" } end
check("at most 100 items per call", ((s.call("memory_write", { items = many }).error) or ""):find("at most 100", 1, true) ~= nil)
check("neither items nor title / body: an error", s.call("memory_write", { kind = "fact" }).error ~= nil)
s.close()
end)

-- ---------------------------------------------------------------------------
section("E. per-call options", function()
io.write("\n--- E: per-call options ---\n")
local m = memo_json("", "write --scope e:s --kind fact --title meta --body " .. q("alpha deploy notes")
    .. [[ --metadata '{"src":"a","n":2}']])
check("memo write --metadata is stored as JSON (was a string)", type((m.memory or {}).metadata) == "table"
    and m.memory.metadata.src == "a", json.encode(m.memory and m.memory.metadata))
local mbad = memo_json("", "write --scope e:s --kind fact --title x --body y --metadata notjson")
check("… and a value that isn't a JSON object is refused", mbad.ok == false
    and tostring(mbad.error):find("JSON object", 1, true) ~= nil)
memo_json("", "write --scope e:s --kind fact --title metb --body " .. q("alpha deploy runbook")
    .. [[ --metadata '{"src":"b"}']])
memo_json("", "write --scope e:s2 --kind fact --title other --body " .. q("alpha deploy in the second scope"))
local u = memo_json("", [[update ]] .. tostring((m.memory or {}).id) .. [[ --metadata '{"src":"a","edited":true}']])
check("memo update --metadata is JSON too", ((u.memory or {}).metadata or {}).edited == true, json.encode(u))

local function titles(rows)
    local t = {}
    for _, r in ipairs(rows or {}) do if r.kind ~= "observation" then t[#t + 1] = r.title end end
    table.sort(t)
    return table.concat(t, ",")
end
local f1 = memo_json("", [[search 'alpha deploy' --scope e:s --metadata-filter '{"src":"a"}']])
check("memo search --metadata-filter", titles(f1.results) == "meta", titles(f1.results))
local sc = memo_json("", "search 'alpha deploy' --scopes e:s,e:s2")
check("memo search --scopes a,b searches both (was ignored)", titles(sc.results) == "meta,metb,other",
    titles(sc.results))
local ms = memo_json("", "search 'alpha deploy' --scope e:s --min-score 1000000")
check("--min-score is a real cut-off", ms.ok and #(ms.results or { 1 }) == 0)
local on = memo_json("", "search 'alpha deploy' --scope e:s --rerank on")
local off = memo_json("", "search 'alpha deploy' --scope e:s --rerank off")
check("--rerank on / off per search", ((on.results or {})[1] or {}).rerank_score ~= nil
    and ((off.results or {})[1] or {}).rerank_score == nil)
local hw = memo_json("", [[search 'alpha deploy' --scope e:s --hybrid-weights '{"vector":0,"fts":1}']])
local hwbad = memo_json("", [[search 'alpha deploy' --scope e:s --hybrid-weights '{"vector":0,"fts":0}']])
check("--hybrid-weights per search, checked like the setting", hw.ok == true and hwbad.ok == false
    and tostring(hwbad.error):find("both be 0", 1, true) ~= nil, json.encode(hwbad))

-- MCP: the same options.
local store = require("luamemo.store")
assert(store.write({ scope = "e:s", kind = "rule", title = "core", body = "alpha deploy core rule", importance = 10 }))
local r = H.mcp("MEMO_SCOPE=e:s", {
    { "memory_search", { query = "alpha deploy", metadata_filter = { src = "b" } } },
    { "memory_search", { query = "alpha deploy", min_score = 1000000 } },
    { "memory_search", { query = "alpha deploy", rerank = true, verbose = true } },
    { "memory_search", { query = "alpha deploy", hybrid_weights = { vector = 1, fts = 0 } } },
    { "memory_search", { query = "alpha deploy", tier_max = 1 } },
    { "memory_search", { query = "alpha deploy", metadata_filter = { src = { nested = 1 } } } },
    { "memory_recent", { kind = "rule" } },
    { "memory_recent", { limit = 1, offset = 1 } },
})
check("MCP memory_search metadata_filter", titles((r[1] or {}).results) == "metb", json.encode(r[1]))
check("MCP min_score", #((r[2] or {}).results or { 1 }) == 0)
check("MCP rerank", (((r[3] or {}).results or {})[1] or {}).rerank_score ~= nil)
check("MCP hybrid_weights", (r[4] or {}).ok == true)
check("MCP tier_max (leaves out the core-tier rule)", not titles((r[5] or {}).results):find("core", 1, true)
    and titles((r[5] or {}).results) ~= "", titles((r[5] or {}).results))
check("a metadata filter luamemo can't apply is an error, not ignored", ((r[6] or {}).error or ""):find("metadata filter", 1,
    true) ~= nil, json.encode(r[6]))
check("MCP memory_recent kind", #((r[7] or {}).results or {}) == 1 and r[7].results[1].title == "core")
local first = memo_json("", "recent --scope e:s --limit 1")
check("MCP memory_recent offset (the second newest)", (((r[8] or {}).results or {})[1] or {}).id ~= nil
    and r[8].results[1].id ~= ((first.results or {})[1] or {}).id)
end)

-- ---------------------------------------------------------------------------
section("F. summarization", function()
io.write("\n--- F: summarization ---\n")
seed("f:cli", { {}, {}, {} })
local none = memo_json("", "summarize --scope f:cli --retention-days 0 --weight-threshold 0.1")
check("memo summarize --weight-threshold is honoured (was ignored): nothing weighs < 0.1",
    ((none.result or {}).summarised) == 0, json.encode(none))
local dry = memo_json("", "summarize --scope f:cli --retention-days 0 --weight-threshold 2 --dry-run")
check("memo summarize --dry-run: what would be folded, nothing changed", ((dry.result or {}).summarised or 0) >= 1
    and count("f:cli") == 3, json.encode(dry))
local real = memo_json("", "summarize --scope f:cli --retention-days 0 --weight-threshold 2")
check("memo summarize: the memories folded into a summary", ((real.result or {}).summarised or 0) >= 1
    and tonumber(require("luamemo.db").value("SELECT count(*) FROM lm_memories WHERE scope = 'f:cli' "
        .. "AND kind = 'summary'")) == 1, json.encode(real))
seed("f:mcp", { {}, {} })
local s = H.mcp_session("MEMO_SCOPE=f:mcp")
local md = s.call("memory_summarize", { dry_run = true, retention_days = 0, weight_threshold = 2 })
local mr = s.call("memory_summarize", { retention_days = 0, weight_threshold = 2 })
s.close()
check("MCP memory_summarize: dry run, then for real", ((md.result or {}).summarised or 0) >= 1
    and ((mr.result or {}).summarised or 0) >= 1 and count("f:mcp") == 1, json.encode(mr))
-- Periodic: every MEMO_SUMMARIZER_INTERVAL_SECONDS, on writes (lazy, like the digest).
local lm = require("luamemo")
seed("f:auto", { {}, {} })
lm.setup({ summarizer_interval_seconds = 3600, summarizer_retention_days = 0, summarizer_weight_threshold = 2 })
seed("f:auto", { { title = "trigger" } })
local sums = function() return tonumber(require("luamemo.db").value(
    "SELECT count(*) FROM lm_memories WHERE scope = 'f:auto' AND kind = 'summary'")) end
check("a write summarizes its scope when the interval is due", sums() == 1)
seed("f:auto", { { title = "again" } })
check("… at most once per interval", sums() == 1)
lm.setup({ summarizer_interval_seconds = 0, summarizer_retention_days = 30, summarizer_weight_threshold = 0.5 })
end)

-- ---------------------------------------------------------------------------
section("G. learned weights", function()
io.write("\n--- G: learned weights ---\n")
local ls = require("luamemo.learner_store")
local G = "g:s"
local v1 = ls.save_version(G, "reranker", { bias = 0.1 }, { score = 0.4 }); ls.promote(G, "reranker", v1)
local v2 = ls.save_version(G, "reranker", { bias = 0.2 }, { score = 0.3 }); ls.promote(G, "reranker", v2)
local st = memo_json("", "learn " .. G .. " --status")
check("memo learn --status: the versions, the current one", ((st.status or {}).current) == 2
    and #((st.status or {}).versions or {}) == 2 and st.status.versions[1].is_current == true, json.encode(st))
local rb = memo_json("", "learn " .. G .. " --rollback")
check("memo learn --rollback: back to the previous version", rb.current == 1 and rb.previous == 2,
    json.encode(rb))
local s = H.mcp_session("MEMO_SCOPE=" .. G)
local ms = s.call("memory_learn", { action = "status" })
local again = s.call("memory_learn", { action = "rollback" })
local run = s.call("memory_learn", { action = "run", dry_run = true })
s.close()
local decisions = {}
for _, r in ipairs(((ms.status or {}).runs) or {}) do decisions[#decisions + 1] = r.decision end
check("MCP memory_learn status: current 1, the rollback recorded", (ms.status or {}).current == 1
    and table.concat(decisions, ","):find("rollback", 1, true) ~= nil, json.encode(ms))
check("MCP memory_learn rollback with nothing earlier: an error", (again.error or ""):find("no earlier version", 1, true)
    ~= nil, json.encode(again))
check("MCP memory_learn run (dry): the promotion harness answers", type(run.result) == "table"
    and run.result.scope == G, json.encode(run))
end)

-- ---------------------------------------------------------------------------
section("I. embedding", function()
io.write("\n--- I: embedding ---\n")
local txt = memo("", "embed 'the deploy gate'")
check("memo embed TEXT: the embedder and the vector size", txt:find("embedder: hash", 1, true) ~= nil
    and txt:find("dimension: 384", 1, true) ~= nil, txt)
local same = memo("", "embed 'the deploy gate' --compare-to 'the deploy gate'")
check("--compare-to: the cosine of two texts", same:find("cosine similarity: 1", 1, true) ~= nil, same)
local full = memo_json("", "embed 'the deploy gate' --json")
check("--json: the vector too", #(full.vector or {}) == 384 and full.dim == 384)
local r = H.mcp("", {
    { "memory_embed", { text = "the deploy gate", compare_to = "a cat on a mat" } },
    { "memory_embed", { text = "the deploy gate", include_vector = true } },
    { "memory_embed", { text = "" } },
})
check("MCP memory_embed: model, size, the cosine — no vector unless asked", (r[1] or {}).dim == 384
    and type(r[1].cosine) == "number" and r[1].cosine < 0.99 and r[1].vector == nil, json.encode(r[1]))
check("… include_vector", #((r[2] or {}).vector or {}) == 384)
check("… a text is required", (r[3] or {}).error ~= nil)
end)

-- ---------------------------------------------------------------------------
-- Found in the phase review: tune_weights was public Lua API (memory.tune_weights)
-- that only the repository's eval/ script reached.
section("J. search-blend tuning", function()
io.write("\n--- J: search-blend tuning ---\n")
local S = "repo:tune"
local topics = { "deploy pipeline gate", "database vacuum schedule", "token refresh flow", "cache eviction policy",
    "router middleware order", "embedding dimension switch", "backup retention window", "pairing code check",
    "index walker excludes", "vault key rotation", "search blend weights", "session brief hook" }
for i, t in ipairs(topics) do
    memo("", ("write --scope %s --kind fact --title %s --body %s"):format(S, q("Note about " .. t),
        q(("Item %d: how the %s works in this project, step by step."):format(i, t))))
end
local txt, code = memo("", "tune-weights --scope " .. S .. " --samples 12")
check("memo tune-weights: the blends, the one in force marked, the verdict", code == 0
    and txt:find("12 memories", 1, true) ~= nil and txt:find("← in force", 1, true) ~= nil
    and (txt:find("Apply it: memo config set MEMO_HYBRID_WEIGHTS", 1, true) ~= nil
         or txt:find("is the best", 1, true) ~= nil), txt)
local rep = memo_json("", "tune-weights --scope " .. S .. " --samples 12 --json")
local report = rep.report or {}
check("--json: the report (11 blends — 0.7 / 0.3 is on the grid — best, in force)", rep.ok == true
    and #(report.blends or {}) == 11 and (report.in_force or {}).vector == 0.7 and report.best ~= nil
    and rep.text == nil, json.encode(rep):sub(1, 400))
local off = memo_json([[MEMO_HYBRID_WEIGHTS='{"vector":0.65,"fts":0.35}']],
    "tune-weights --scope " .. S .. " --samples 12 --json")
check("a blend in force off the grid is measured too", #(((off.report or {}).blends) or {}) == 12
    and ((off.report or {}).in_force or {}).vector == 0.65, json.encode(off.report and off.report.in_force))
local bad, bc = memo_json("", "tune-weights --scope " .. S .. " --metric r_at_2")
check("a metric it doesn't measure is refused (exit 1)", bc == 1 and bad.ok == false
    and tostring(bad.error):find("r_at_1", 1, true) ~= nil, json.encode(bad))
local few = memo_json("", "tune-weights --scope repo:empty")
check("a scope with too few memories says so", few.ok == false and tostring(few.error):find("too few", 1, true) ~= nil,
    json.encode(few))
local r = H.mcp("MEMO_SCOPE=" .. S, {
    { "memory_tune_weights", { samples = 12, metric = "mrr" } },
    { "memory_tune_weights", { scope = S, samples = 3 } },
})
check("MCP memory_tune_weights: the same report, MEMO_SCOPE by default", (r[1] or {}).scope == S
    and #((r[1] or {}).blends or {}) == 11 and r[1].metric == "mrr" and r[1].memories_searched == 12, json.encode(r[1]):sub(1, 300))
check("… samples below 5 refused", (r[2] or {}).error ~= nil)
end)

finish()
