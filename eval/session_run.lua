-- eval/session_run.lua — the session's fixed cost: what an agent receives from luamemo
-- before its first search, in bytes (≈ tokens = bytes / 4).
--
-- The MCP server (`memo mcp`) is started as a client starts it, on a scratch database
-- holding the personalization corpus (a project with memories), and asked what every
-- session asks: initialize (its usage rules), tools/list (every tool definition) and
-- memory_brief (the session brief). Twice: with all tools and with MEMO_MCP_TOOLS=core.
--
--   MEMO_NO_MAINTENANCE=1 MEMO_DB=scratch luajit eval/session_run.lua --memo /usr/local/bin/memo --out r.json
--
-- memo eval runs it (benchmark `session`). Deterministic: the same luamemo gives the same
-- numbers; the history shows a tool description or the rules growing.

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path
local json = require("luamemo.json")
local util = require("luamemo.util")

local args = { memo = "memo", out = nil, corpus = "eval/personalization/corpus.jsonl" }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--memo" then args.memo = arg[i + 1]; i = i + 2
        elseif a == "--out" then args.out = arg[i + 1]; i = i + 2
        elseif a == "--corpus" then args.corpus = arg[i + 1]; i = i + 2
        elseif a == "--embedder" then i = i + 2   -- (memo eval passes one; no embedder is measured here)
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
    end
end
assert(args.out, "--out is required")
local db_path = assert(util.env("MEMO_DB"), "MEMO_DB (a scratch database) is required")

-- The project: a directory named proj, its memories in repo:proj (the brief lists them).
local dir = (db_path:match("^(.*)/[^/]+$") or ".") .. "/session-proj"
os.execute("rm -rf " .. util.shell_quote(dir) .. " && mkdir -p " .. util.shell_quote(dir .. "/proj"))
local proj = dir .. "/proj"
local memory = require("luamemo")
memory.setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true })
local batch = {}
for line in io.lines(args.corpus) do
    local m = line:match("%S") and json.decode(line)
    if m then
        batch[#batch + 1] = { scope = "repo:proj", kind = m.kind or "fact", title = m.title or m.id,
                              body = m.body or "", tags = m.tags }
    end
end
assert(memory.store.write_many(batch, {}))

local REQUESTS = table.concat({
    json.encode({ jsonrpc = "2.0", id = 1, method = "initialize", params = { protocolVersion = "2025-06-18",
        capabilities = {}, clientInfo = { name = "memo-eval", version = "1" } } }),
    json.encode({ jsonrpc = "2.0", method = "notifications/initialized" }),
    json.encode({ jsonrpc = "2.0", id = 2, method = "tools/list" }),
    json.encode({ jsonrpc = "2.0", id = 3, method = "tools/call",
        params = { name = "memory_brief", arguments = {} } }),
}, "\n") .. "\n"

-- One session: the raw response line of each request (what the client receives). A home
-- of its own: memo reads ~/.luamemorc over the environment, and the user's settings (a
-- scope, MEMO_MCP_TOOLS) would change what is measured.
local home = dir .. "/home"
os.execute("mkdir -p " .. util.shell_quote(home))
local function session(tools)
    local req, out = dir .. "/req.jsonl", dir .. "/out-" .. tools .. ".jsonl"
    local f = assert(io.open(req, "w")); f:write(REQUESTS); f:close()
    local q = util.shell_quote
    local cmd = ("cd %s && env HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s MEMO_SCOPE=repo:proj MEMO_MCP_TOOLS=%s "
        .. "MEMO_EMBEDDER=hash %s mcp --project %s < %s > %s 2>/dev/null"):format(q(proj), q(home),
        q(home .. "/.config"), q(home .. "/.local/share"), tools, q(args.memo), q(proj), q(req), q(out))
    os.execute(cmd)
    local by_id = {}
    for line in io.lines(out) do
        local ok, msg = pcall(json.decode, line)
        if ok and type(msg) == "table" and msg.id then by_id[msg.id] = { line = line, msg = msg } end
    end
    for id = 1, 3 do
        if not (by_id[id] and by_id[id].msg.result) then
            io.stderr:write(("session_run: no answer to request %d (MEMO_MCP_TOOLS=%s) — %s\n"):format(id, tools, out))
            os.exit(1)
        end
    end
    local brief = by_id[3].msg.result.content and by_id[3].msg.result.content[1] or {}
    return {
        instructions = #(by_id[1].msg.result.instructions or ""),
        tools_line = #by_id[2].line,
        n_tools = #(by_id[2].msg.result.tools or {}),
        brief = #(brief.text or ""),
    }
end

local all, core = session("all"), session("core")
local overall = {
    instructions_bytes = all.instructions,
    tools_bytes = all.tools_line, n_tools = all.n_tools,
    tools_core_bytes = core.tools_line, n_tools_core = core.n_tools,
    brief_bytes = all.brief,
    session_bytes = all.instructions + all.tools_line + all.brief,
    session_core_bytes = core.instructions + core.tools_line + core.brief,
}
print(("rules %d · tools %d (%d) / core %d (%d) · brief %d · total %d / core %d bytes"):format(
    overall.instructions_bytes, overall.tools_bytes, overall.n_tools, overall.tools_core_bytes,
    overall.n_tools_core, overall.brief_bytes, overall.session_bytes, overall.session_core_bytes))
local jf = assert(io.open(args.out, "w"))
jf:write(json.encode({ suite = "session", overall = overall })); jf:close()
os.execute("rm -rf " .. util.shell_quote(dir))
