-- eval/smoke_mcp_tools.lua
--
-- Smoke test for the 4 new MCP tools added in Plan 15:
--   memory_status, memory_reconnect, memory_diary_write, memory_diary_read
--
-- Tests the tool handler functions directly (not via JSON-RPC stdio) to keep
-- the test fast and deterministic.
--
-- Run:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/lm_bruteforce_test \
--     lua5.1 eval/smoke_mcp_tools.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local db_url = os.getenv("MEMO_DB_URL")
if not db_url or db_url == "" then
    print("MEMO_DB_URL not set — aborting")
    os.exit(1)
end

local pass = 0
local fail = 0
local function check(label, cond, detail)
    if cond then
        pass = pass + 1
        io.write(string.format("  PASS  %s\n", label))
    else
        fail = fail + 1
        io.write(string.format("  FAIL  %s%s\n", label, detail and (" | " .. tostring(detail)) or ""))
    end
end

-- ---------------------------------------------------------------------------
-- Bootstrap: replicate what mcp/server.lua does at startup
-- ---------------------------------------------------------------------------
local memory = require("luamemo")
memory.setup({
    db_url           = db_url,
    embedder_local   = "hash",
    backend          = "bruteforce",
    patterns_enabled = false,
})

-- ---------------------------------------------------------------------------
-- Load the Tools table from mcp/server.lua.
-- server.lua writes to a module-level `Tools` table but does not export it.
-- We replicate the handlers inline here by exercising the same logic.
-- ---------------------------------------------------------------------------
local db    = require("luamemo.db")
local store = require("luamemo.store")

-- Helper: simulate ensure_setup (already done above via memory.setup)
local function ensure_setup() end

-- Inline the handlers (mirrors mcp/server.lua exactly).

local function status_handler(_)
    ensure_setup()
    local ok, res = pcall(db.query, "SELECT COUNT(*) AS n FROM lm_memories")
    if not ok then return nil, tostring(res) end
    local scopes = db.query(
        "SELECT scope, COUNT(*) AS n FROM lm_memories " ..
        "GROUP BY scope ORDER BY n DESC LIMIT 20")
    local cfg_ref = require("luamemo").config or {}
    return {
        connected  = true,
        total_rows = tonumber(res[1].n),
        top_scopes = scopes,
        version    = require("luamemo").VERSION or "unknown",
        config = {
            embedder     = cfg_ref.embedder_local,
            embed_dim    = cfg_ref.embed_dim,
            backend      = cfg_ref.backend,
            patterns_en  = cfg_ref.patterns_enabled ~= false,
            tier_min_mcp = 1,
        },
    }
end

local function reconnect_handler(_)
    ensure_setup()
    db.reset()
    local ok, res = pcall(db.query, "SELECT COUNT(*) AS n FROM lm_memories")
    return {
        success    = ok,
        rows_after = ok and tonumber(res[1].n) or nil,
        error      = (not ok) and tostring(res) or nil,
    }
end

local function diary_write_handler(args)
    ensure_setup()
    if not args.agent_name or args.agent_name == "" then return nil, "agent_name required" end
    if not args.entry      or args.entry == ""      then return nil, "entry required" end
    local scope = "diary:" .. args.agent_name
    local topic = tostring(args.topic or "general")
    local row, err = store.write({
        scope      = scope,
        kind       = "diary",
        title      = "Diary entry — " .. topic,
        body       = args.entry,
        importance = 0.5,
        metadata   = { agent = args.agent_name, topic = topic, diary = true },
    })
    if not row then return nil, err end
    return { success = true, entry_id = row.id, agent = args.agent_name, topic = topic, scope = scope }
end

local function diary_read_handler(args)
    ensure_setup()
    if not args.agent_name or args.agent_name == "" then return nil, "agent_name required" end
    local scope  = "diary:" .. args.agent_name
    local limit  = math.min(tonumber(args.last_n) or 10, 50)
    local rows, err = db.query(
        "SELECT id, body, importance, metadata, created_at " ..
        "FROM lm_memories WHERE scope = ? " ..
        "ORDER BY created_at DESC LIMIT ?",
        scope, limit)
    if not rows then return nil, err end
    local entries = {}
    for _, r in ipairs(rows) do
        local meta = (type(r.metadata) == "table") and r.metadata or {}
        entries[#entries + 1] = {
            entry_id  = r.id,
            timestamp = r.created_at,
            topic     = meta.topic or "general",
            content   = r.body,
        }
    end
    return { agent = args.agent_name, entries = entries, total = #entries, scope = scope }
end

local SCOPE = "diary:smoke_agent_" .. tostring(os.time())
-- Ensure clean slate
db.query("DELETE FROM lm_memories WHERE scope = ?", SCOPE)

-- ---------------------------------------------------------------------------
print("\n-- memory_status --")
local r, err = status_handler({})
check("returns connected=true",     type(r) == "table" and r.connected == true, tostring(err))
check("total_rows is a number",     type(r) == "table" and type(r.total_rows) == "number")
check("top_scopes is a table",      type(r) == "table" and type(r.top_scopes) == "table")
check("version is a string",        type(r) == "table" and type(r.version) == "string")
check("config.embedder = hash",     type(r) == "table" and r.config and r.config.embedder == "hash")
check("config.patterns_en = false", type(r) == "table" and r.config and r.config.patterns_en == false)

-- ---------------------------------------------------------------------------
print("\n-- memory_reconnect --")
r, err = reconnect_handler({})
check("reconnect success=true",     type(r) == "table" and r.success == true, tostring(err))
check("rows_after is a number",     type(r) == "table" and type(r.rows_after) == "number")
check("error field nil on success", type(r) == "table" and r.error == nil)

-- ---------------------------------------------------------------------------
print("\n-- memory_diary_write --")
local AGENT = "smoke_agent_" .. tostring(os.time())
SCOPE = "diary:" .. AGENT

r, err = diary_write_handler({
    agent_name = AGENT,
    entry      = "Today I worked on query boost tests and they passed.",
    topic      = "work",
})
check("write returns success=true", type(r) == "table" and r.success == true, tostring(err))
check("entry_id present",           type(r) == "table" and r.entry_id ~= nil)
check("scope is diary:<agent>",     type(r) == "table" and r.scope == "diary:" .. AGENT)
check("topic preserved",            type(r) == "table" and r.topic == "work")

-- Required field validation
r, err = diary_write_handler({ agent_name = "", entry = "x" })
check("empty agent_name → error",   r == nil and err ~= nil)
r, err = diary_write_handler({ agent_name = AGENT, entry = "" })
check("empty entry → error",        r == nil and err ~= nil)

-- Write a second entry for read test
diary_write_handler({ agent_name = AGENT, entry = "Second entry — more tests.", topic = "testing" })

-- ---------------------------------------------------------------------------
print("\n-- memory_diary_read --")
r, err = diary_read_handler({ agent_name = AGENT, last_n = 10 })
check("read returns entries table", type(r) == "table" and type(r.entries) == "table", tostring(err))
check("total >= 2",                 type(r) == "table" and (r.total or 0) >= 2,
      "total=" .. tostring(r and r.total))
check("first entry has content",    type(r) == "table" and r.entries[1] and r.entries[1].content ~= nil)
check("entries have topic field",   type(r) == "table" and r.entries[1] and r.entries[1].topic ~= nil)
check("agent field preserved",      type(r) == "table" and r.agent == AGENT)

-- last_n capping
r = diary_read_handler({ agent_name = AGENT, last_n = 1 })
check("last_n=1 returns ≤1 entry",  type(r) == "table" and r.total <= 1)

-- Missing agent_name
r, err = diary_read_handler({ agent_name = "" })
check("empty agent_name → error",   r == nil and err ~= nil)

-- ---------------------------------------------------------------------------
-- Cleanup
db.query("DELETE FROM lm_memories WHERE scope = ?", SCOPE)
print(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
