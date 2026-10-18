-- eval/tests/test_parity.lua
-- Phase 14.5b, kept for good: luamemo's Lua API is internal, so everything it can do
-- must be reachable from the `memo` CLI AND the MCP server. This test reads the
-- source — the arguments each surfaced function actually reads, every config key the
-- modules read — and fails when one is not reachable:
--   * a config key: a setting (luamemo.settings: .luamemorc / MEMO_<KEY> / memo config)
--     that MCP lists (memory_status {details}) — read-only there by the owner's decision;
--   * a function argument: a `memo` flag (the api handler maps it; a command that
--     names its flags names this one) AND a parameter of the MCP tool;
--   * the learner operations run / status / rollback: on both.
-- Exceptions are the commented lists below — keep them short, each with its reason.
-- Run: luajit eval/tests/run.lua --only parity

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("CLI / MCP parity")
local check, section, finish = T.check, T.section, T.finish
local slurp = H.slurp
local settings = require("luamemo.settings")

local MEMO = assert(slurp("cli/memo"))
local API  = assert(slurp("luamemo/cli/api.lua"))
local OPS  = assert(slurp("luamemo/ops.lua"))   -- the operations both surfaces share

-- The text of a function: from its definition line to the first `end` at column 0.
local function body(text, def)
    local s = text:find(def, 1, true)
    assert(s, "not found: " .. def)
    local e = text:find("\nend\n", s, true) or text:find("\n}\n", s, true)
    return text:sub(s, e)
end
local function read_args(path, def, var)
    local b, set, list = body(assert(slurp(path)), def), {}, {}
    for k in b:gmatch("[^%w_]" .. var .. "%.([%a_][%w_]*)") do set[k] = true end
    for k in b:gmatch(var .. "%[\"([%a_][%w_]*)\"%]") do set[k] = true end
    for k in pairs(set) do list[#list + 1] = k end
    table.sort(list)
    return list
end

-- MCP: every tool's parameters, as a client sees them (tools/list over stdio).
local tools = {}
local listed = H.mcp("", { { method = "tools/list" } })
for _, t in ipairs(((listed[1] or {}).tools) or {}) do
    local props = {}
    for k in pairs((t.inputSchema or {}).properties or {}) do props[k] = true end
    tools[t.name] = { props = props, schema = t.inputSchema }
end

-- ---------------------------------------------------------------------------
section("config keys", function()
io.write("\n--- every config key luamemo reads is a setting ---\n")
-- Names read through a variable called cfg that are not luamemo config:
local NOT_CONFIG = {
    projection_W   = "tests / eval inject projection weights (MEMO_PROJECTION_W)",
    rerank_scope   = "the reranker's per-call view (the search's scope)",
    rerank_weights = "the reranker's per-call view (explicit weights: eval / tests, MEMO_RERANK_WEIGHTS)",
    root           = "federation/identity.lua's own options table",
    max_tokens     = "sensing generation length — the sense call's own options (default 256)",
}
local files = io.popen("ls luamemo/*.lua luamemo/adapters/*.lua luamemo/rerankers/*.lua luamemo/summarizers/*.lua "
    .. "luamemo/embedders/*.lua luamemo/embedders/native/*.lua luamemo/sensing/*.lua luamemo/index/*.lua "
    .. "luamemo/federation/*.lua"):read("*a")
local missing, seen = {}, {}
for path in files:gmatch("[^\n]+") do
    local text = assert(slurp(path))
    local function see(key)
        if not settings.get(key) and not NOT_CONFIG[key] and not seen[key] then
            seen[key] = true
            missing[#missing + 1] = key .. " (" .. path .. ")"
        end
    end
    for key in text:gmatch("[^%w_%.][%w_]*cfg%.([%a_][%w_]*)") do see(key) end
    for key in text:gmatch("[^%w_]config%.([%a_][%w_]*)") do see(key) end
end
check("every config key the modules read is a setting (.luamemorc / MEMO_<KEY> / memo config)", #missing == 0,
    table.concat(missing, ", "))
local status = H.mcp("", { { "memory_status", { details = true } } })
check("MCP lists every setting (memory_status {details}; read-only there — owner, 2026-10-08)",
    #(((status[1] or {}).settings) or {}) == #settings.LIST)
local cli = require("luamemo.json").decode((H.sh(("%q config list --json 2>/dev/null"):format("cli/memo")))) or {}
check("memo config lists every setting", #(cli.settings or {}) == #settings.LIST)
end)

-- ---------------------------------------------------------------------------
-- Surfaced functions: the Lua function (where its arguments are read), its api
-- handler, its memo command (generic = the command passes any --flag on as a field),
-- its MCP tool (nil: CLI-only, with the reason), and names that differ per surface.
local INTERNAL = {   -- arguments no surface takes, with the reason
    _cap              = "a capability token for luamemo's own writers (replica sync, directive ingest)",
    _reembed          = "memo reembed's own path",
    skip_feedback     = "system searches (training, gating, evaluation) — not a retrieval anyone acted on",
    skip_observations = "internal searches that don't want observation rows appended",
    skip_temporal     = "internal searches that don't parse time expressions in the query",
    until_            = "an alias of until",
    rerank_adapter    = "per-call override of MEMO_RERANK_ADAPTER (the setting reaches both surfaces)",
    rerank_url        = "per-call override of MEMO_RERANK_URL",
    rerank_model      = "per-call override of MEMO_RERANK_MODEL",
    rerank_headers    = "per-call override of MEMO_RERANK_HEADERS (credentials stay in settings / the vault)",
    rerank_timeout_ms = "per-call override of MEMO_RERANK_TIMEOUT_MS",
    rerank_top_n      = "per-call override of MEMO_RERANK_TOP_N",
    rerank_weights    = "explicit learned-reranker weights: eval / tests (MEMO_RERANK_WEIGHTS)",
    obs_max_slots     = "per-call override of MEMO_OBS_MAX_SLOTS",
    epochs            = "learner training hyper-parameter (the harness's default; eval only)",
    gate_frac         = "learner training hyper-parameter",
    lr                = "learner training hyper-parameter",
    l2                = "learner training hyper-parameter",
    harvest_limit     = "learner training hyper-parameter",
    gates             = "extra promotion gates (luamemo's own federation aggregate passes them)",
    note              = "the promotion audit row's note (set by luamemo)",
    in_force          = "the blend in force — the MEMO_HYBRID_WEIGHTS setting, read by both surfaces",
}
local SURFACES = {
    { name = "store.search", file = "luamemo/store.lua", def = "function M.search(args)", var = "args",
      api = "search", ops = "function M.search(p, d)", cmd = "cmd_search", generic = true, tool = "memory_search",
      names = { query = { cli = "q" } } },
    { name = "store.write", file = "luamemo/store.lua", def = "function M.write(args)", var = "args",
      api = "write", ops = "function M.write_fields(p, scope)", cmd = "cmd_write", generic = true,
      tool = "memory_write" },
    { name = "store.recent", file = "luamemo/store.lua", def = "function M.recent(args)", var = "args",
      api = "recent", ops = "function M.recent(p, d)", cmd = "cmd_recent", generic = true, tool = "memory_recent" },
    { name = "store.update", file = "luamemo/store.lua", def = "function M.update(id, patch)", var = "patch",
      api = "update", ops = "function M.update(id, p)", cmd = "cmd_update", generic = true, tool = "memory_update" },
    { name = "store.delete_where", file = "luamemo/store.lua", def = "local function _bulk_where(args, who)",
      var = "args", api = "delete-where", cmd = "cmd_delete", tool = "memory_delete",
      names = { metadata_filter = { flag = "--meta" } } },
    { name = "kg.assert_fact", file = "luamemo/kg.lua", def = "function M.assert_fact(args)", var = "args",
      api = "kg-assert", cmd = "cmd_kg", tool = nil, why = "KG writes are CLI-only on purpose (owner, 2026-10-09: the spike)",
      names = { source_memory_id = { flag = "--source-memory" } } },
    { name = "kg.query", file = "luamemo/kg.lua", def = "function M.query(args)", var = "args",
      api = "kg-query", cmd = "cmd_kg", tool = nil, why = "agents get the facts a query is about inside "
          .. "memory_search results; full queries and timelines are CLI (owner, 2026-10-10: KG spike 2)",
      extra = { "subject", "predicate", "object" } },   -- read through a loop over those names
    { name = "kg.invalidate", file = "luamemo/kg.lua", def = "function M.invalidate(args)", var = "args",
      api = "kg-invalidate", cmd = "cmd_kg", tool = nil, why = "KG writes are CLI-only on purpose (owner, 2026-10-09)" },
    { name = "kg.timeline", file = "luamemo/kg.lua", def = "function M.timeline(args)", var = "args",
      api = "kg-timeline", cmd = "cmd_kg", tool = nil, why = "the history of a value is CLI (memo kg timeline); "
          .. "memory_search's facts carry the previous value (owner, 2026-10-10: KG spike 2)" },
    { name = "promote.run (memo learn)", file = "luamemo/promote.lua", def = "function M.run(scope, opts)",
      var = "opts", api = "learn", ops = "function M.learn(p, scope)", cmd = "cmd_learn", tool = "memory_learn" },
    { name = "summarizer.run", file = "luamemo/summarizer.lua", def = "function M.run(opts)", var = "opts",
      api = "summarize", ops = "function M.summarize(p, scope)", cmd = "cmd_summarize", generic = true,
      tool = "memory_summarize" },
    { name = "summarizer.promote", file = "luamemo/summarizer.lua", def = "function M.promote(opts)", var = "opts",
      api = "promote", ops = "function M.promote(p)", cmd = "cmd_promote", generic = true, tool = "memory_promote",
      names = { from_scope = { flag = "--from" }, to_scope = { flag = "--to" } } },
    { name = "summarizer.consolidate", file = "luamemo/summarizer.lua", def = "function M.consolidate(opts)",
      var = "opts", api = "consolidate", ops = "function M.consolidate(p)", cmd = "cmd_consolidate", generic = true,
      tool = "memory_consolidate" },
    { name = "embed.inspect", file = "luamemo/embed.lua", def = "function M.inspect(text, opts)", var = "opts",
      api = "embed", ops = "function M.embed(p)", cmd = "cmd_embed", tool = "memory_embed",
      names = { vector = { flag = "--json", mcp = "include_vector" } } },
    -- Public Lua API until Phase 14 (memory.tune_weights); missed by the 14.5b audit, found
    -- in the phase review: only the repository's eval/ script reached it.
    { name = "tune_weights.recommend", file = "luamemo/tune_weights.lua", def = "function M.recommend(opts)",
      var = "opts", api = "tune-weights", ops = "function M.tune_weights(p, scope)", cmd = "cmd_tune_weights",
      tool = "memory_tune_weights" },
}

section("function arguments", function()
io.write("\n--- every argument: a memo flag AND an MCP parameter ---\n")
for _, s in ipairs(SURFACES) do
    local list = read_args(s.file, s.def, s.var)
    for _, x in ipairs(s.extra or {}) do list[#list + 1] = x end
    -- The memo handler — and, for an operation both surfaces share, its luamemo.ops function
    -- (where the arguments are read).
    local handler = body(API, ('handlers["%s"] = function(p)'):format(s.api)) .. (s.ops and body(OPS, s.ops) or "")
    local cmd = body(MEMO, s.cmd .. "() {")
    local missing = {}
    for _, arg in ipairs(list) do
        if not INTERNAL[arg] then
            local n = (s.names or {})[arg] or {}
            local cli_name = n.cli or arg
            local reads = handler:find("p%." .. cli_name .. "[^%w_]") or handler:find('p%["' .. cli_name .. '"%]')
            local flag = n.flag or ("--" .. cli_name:gsub("_", "-"))
            local named = s.generic or cmd:find(flag, 1, true) or cli_name == "scope" and cmd:find("MEMO_SCOPE", 1, true)
            if not (reads and named) then missing[#missing + 1] = arg .. " (memo)" end
            if s.tool then
                local tool = tools[s.tool]
                if not (tool and tool.props[n.mcp or arg]) then missing[#missing + 1] = arg .. " (" .. s.tool .. ")" end
            end
        end
    end
    check(("%s: %d arguments, each on memo%s"):format(s.name, #list, s.tool and (" and " .. s.tool)
        or (" — not on MCP: " .. s.why)), #missing == 0, table.concat(missing, ", "))
end
end)

-- ---------------------------------------------------------------------------
section("learner operations", function()
io.write("\n--- learner operations ---\n")
local enum = ((tools.memory_learn or {}).schema or { properties = {} }).properties.action
check("MCP memory_learn: run / status / rollback", enum and table.concat(enum.enum or {}, ",") == "run,status,rollback")
local learn = body(MEMO, "cmd_learn() {")
check("memo learn: run (default) / --status / --rollback", learn:find("--status", 1, true) ~= nil
    and learn:find("--rollback", 1, true) ~= nil)
local handler = body(OPS, "function M.learn(p, scope)")
local SERVER = assert(slurp("mcp/server.lua"))
check("… both through the same code (luamemo.ops.learn: run / status / rollback)",
    handler:find('"status"', 1, true) ~= nil and handler:find('"rollback"', 1, true) ~= nil
    and API:find("ops.learn", 1, true) ~= nil and SERVER:find("ops.learn(", 1, true) ~= nil)
end)

-- ---------------------------------------------------------------------------
section("the MCP tools", function()
io.write("\n--- MCP tools ---\n")
local names = {}
for n in pairs(tools) do names[#names + 1] = n end
table.sort(names)
check("27 tools (22 + memory_summarize, memory_learn, memory_embed, memory_tune_weights, memory_brief)",
    #names == 27, table.concat(names, " "))
check("memory_brief is memo brief (the hooks' digest): both call luamemo.brief",
    tools.memory_brief ~= nil and body(API, 'handlers["brief"] = function(p)'):find('require("luamemo.brief")', 1, true)
    and assert(slurp("mcp/server.lua")):find('require("luamemo.brief").text(', 1, true))
-- VS Code lets the luamemo agent call only the tools its file lists: a listed name the
-- server doesn't have is silently dropped.
local agent = assert(slurp("agents/luamemo.agent.md"))
local listed_n, unknown = 0, {}
for name in agent:match("^%-%-%-\n(.-)\n%-%-%-"):gmatch("\n%s*%- luamemo/([%w_]+)") do
    listed_n = listed_n + 1
    if not tools[name] then unknown[#unknown + 1] = name end
end
check("every tool the luamemo agent lists exists", listed_n > 0 and #unknown == 0, table.concat(unknown, ", "))
end)

-- ---------------------------------------------------------------------------
section("the usage rules: one text in three files", function()
io.write("\n--- core rules ---\n")
-- The server sends mcp/instructions.md to every client; the skill and the agent carry
-- the same rules for clients that load them. Edit the block in instructions.md and
-- copy it into the other two.
local function block(path)
    local text = slurp(path) or ""
    return text:match("<!%-%- luamemo:core%-rules:begin %-%->\n(.-)<!%-%- luamemo:core%-rules:end %-%->")
end
local canon = block("mcp/instructions.md")
check("mcp/instructions.md holds the core-rules block", canon ~= nil and #canon > 200)
for _, path in ipairs({ "skills/session-memory/SKILL.md", "agents/luamemo.agent.md" }) do
    local b = block(path)
    check(path .. ": the same block, word for word", canon ~= nil and b == canon,
        b == nil and "no block" or "differs from mcp/instructions.md")
end
local tools_named, missing = 0, {}
for name in (canon or ""):gmatch("`([%l_]+)`") do
    if name:match("^memory_") or name:match("^index_") or name:match("^secret_") then
        tools_named = tools_named + 1
        if not tools[name] then missing[#missing + 1] = name end
    end
end
check("every tool the rules name exists", tools_named > 0 and #missing == 0, table.concat(missing, ", "))
end)

finish()
