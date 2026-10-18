-- eval/tests/test_mcp_protocol.lua
-- The MCP server speaks both protocol eras (dual-era):
--   modern 2026-07-28 — no handshake; every request carries its version and the client's
--     capabilities in _meta; server/discover; every result says resultType "complete" and
--     names the server in _meta; lists and discover carry caching hints; an unknown
--     version → -32022 with the supported ones; missing _meta fields → -32602;
--   legacy (2024-11-05 … 2025-11-25) — initialize echoes a version it speaks (else its
--     newest legacy one) and the results keep their old shape; a 2025-03-26 batch gets
--     one array of answers.
-- Both eras get the guidance (mcp/instructions.md, comments left out) and memory_brief.
-- Run: luajit eval/tests/run.lua --only mcp_protocol

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("MCP protocol")
local check, section, finish = T.check, T.section, T.finish
local json = require("luamemo.json")

local MODERN = "2026-07-28"
local M = "io.modelcontextprotocol/"
local function meta(version, caps, info)
    local m = { [M .. "protocolVersion"] = version, [M .. "clientCapabilities"] = caps }
    if info then m[M .. "clientInfo"] = info end
    return m
end

--- Send these messages (tables, or raw strings) to a fresh server; → its answers by id
--- (a batch's answers under "batch"), the raw lines and stderr.
local function exchange(msgs, env)
    local inp = os.tmpname()
    local f = assert(io.open(inp, "w"))
    for _, m in ipairs(msgs) do f:write(type(m) == "string" and m or json.encode(m), "\n") end
    f:close()
    local errf = os.tmpname()
    local out = H.sh(("%s %q mcp/server.lua < %q 2> %q"):format(env or "", H.lua_bin(), inp, errf))
    local by, lines = {}, {}
    for line in out:gmatch("[^\n]+") do
        lines[#lines + 1] = line
        local msg = json.decode(line)
        if type(msg) == "table" and msg[1] ~= nil then by.batch = msg
        elseif type(msg) == "table" and msg.id ~= nil and msg.id ~= json.null then by[msg.id] = msg
        elseif type(msg) == "table" then by.noid = msg end
    end
    local stderr = H.slurp(errf) or ""
    os.remove(inp); os.remove(errf)
    return by, lines, stderr
end

local GUIDE = assert(H.slurp("mcp/instructions.md"))

section("modern (2026-07-28): stateless, _meta on every request", function()
io.write("\n--- modern ---\n")
local caps = {}
local r = exchange({
    { jsonrpc = "2.0", id = "d", method = "server/discover",
      params = { _meta = meta(MODERN, caps, { name = "modern-client", version = "1.0" }) } },
    { jsonrpc = "2.0", id = 2, method = "tools/list", params = { _meta = meta(MODERN, caps) } },
    { jsonrpc = "2.0", id = 3, method = "tools/call",
      params = { name = "memory_write", arguments = { title = "modern write", body = "over the modern protocol",
          kind = "fact", scope = "proto:modern" }, _meta = meta(MODERN, caps) } },
    { jsonrpc = "2.0", id = 4, method = "tools/call",
      params = { name = "memory_brief", arguments = { scope = "proto:modern" }, _meta = meta(MODERN, caps) } },
    { jsonrpc = "2.0", id = 5, method = "tools/list", params = { _meta = meta("1900-01-01", caps) } },
    { jsonrpc = "2.0", id = 6, method = "tools/list",
      params = { _meta = { [M .. "protocolVersion"] = MODERN } } },
    { jsonrpc = "2.0", id = 7, method = "server/discover", params = {} },
    { jsonrpc = "2.0", id = 8, method = "initialize", params = { _meta = meta(MODERN, caps) } },
})
local d = (r.d or {}).result or {}
check("server/discover: versions (modern first, then legacy), capabilities, identity",
    d.supportedVersions and d.supportedVersions[1] == MODERN and #d.supportedVersions == 5
    and d.capabilities and d.capabilities.tools
    and (d._meta or {})[M .. "serverInfo"] and d._meta[M .. "serverInfo"].name == "luamemo", json.encode(d))
check("… the guidance (instructions), without the file's comments",
    type(d.instructions) == "string" and d.instructions:find("memory_brief", 1, true)
    and not d.instructions:find("<!--", 1, true), tostring(d.instructions))
check("… caching hints (ttlMs ≥ 0, cacheScope public), resultType complete",
    tonumber(d.ttlMs) and d.ttlMs >= 0 and d.cacheScope == "public" and d.resultType == "complete", json.encode(d))
local list = (r[2] or {}).result or {}
local names, sorted = {}, true
for i, t in ipairs(list.tools or {}) do
    names[#names + 1] = t.name
    if i > 1 and names[i - 1] > t.name then sorted = false end
end
check("tools/list: every tool, in a fixed order, with caching hints and serverInfo",
    #names == 27 and sorted and list.resultType == "complete" and list.ttlMs and list.cacheScope == "public"
    and (list._meta or {})[M .. "serverInfo"] ~= nil, table.concat(names, " "))
local w = (r[3] or {}).result or {}
check("tools/call works without initialize: resultType complete, serverInfo", w.resultType == "complete"
    and w.isError == false and (w._meta or {})[M .. "serverInfo"] ~= nil and w.ttlMs == nil, json.encode(w))
local b = (((r[4] or {}).result or {}).content or {})[1] or {}
check("memory_brief: the session brief, as text", tostring(b.text):find("=== LUAMEMO ===", 1, true)
    and b.text:find("proto:modern — 1 memories", 1, true), tostring(b.text))
local e5 = (r[5] or {}).error or {}
check("an unknown version → -32022, naming the requested and the supported ones", e5.code == -32022
    and (e5.data or {}).requested == "1900-01-01" and ((e5.data or {}).supported or {})[1] == MODERN, json.encode(e5))
local e6, e7 = (r[6] or {}).error or {}, (r[7] or {}).error or {}
check("missing _meta clientCapabilities / protocolVersion → -32602", e6.code == -32602
    and e6.message:find("clientCapabilities", 1, true) and e7.code == -32602
    and e7.message:find("protocolVersion", 1, true), json.encode({ e6, e7 }))
check("initialize always selects the legacy era (dual-era), whatever its _meta",
    (((r[8] or {}).result or {}).protocolVersion) == "2025-11-25", json.encode(r[8]):sub(1, 200))
end)

section("legacy (initialize): the client's version, the old result shape", function()
io.write("\n--- legacy ---\n")
local function init(version, id)
    return { jsonrpc = "2.0", id = id, method = "initialize", params = { protocolVersion = version,
        capabilities = {}, clientInfo = { name = "legacy-client", version = "0.9" } } }
end
for _, v in ipairs({ "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25" }) do
    local r = exchange({ init(v, 1), { jsonrpc = "2.0", method = "notifications/initialized" },
        { jsonrpc = "2.0", id = 2, method = "tools/list" } })
    local i, l = (r[1] or {}).result or {}, (r[2] or {}).result or {}
    check(v .. ": initialize echoes it, with the guidance; tools/list as before (no resultType)",
        i.protocolVersion == v and type(i.instructions) == "string" and i.serverInfo.name == "luamemo"
        and #(l.tools or {}) == 27 and l.resultType == nil and l._meta == nil, json.encode(i):sub(1, 300))
end
local r = exchange({ init("2099-01-01", 1) })
check("a version it doesn't speak → its newest legacy one (the client decides)",
    ((r[1] or {}).result or {}).protocolVersion == "2025-11-25", json.encode(r[1]))
local inst = (((r[1] or {}).result or {}).instructions) or ""
local canon = GUIDE:gsub("<!%-%-.-%-%->\n?", ""):gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
check("instructions are mcp/instructions.md, comments left out", inst == canon, inst:sub(1, 200))
end)

section("clients: recorded, and an old one named", function()
io.write("\n--- clients ---\n")
local dir = os.tmpname(); os.remove(dir)
local ENV = ("MEMO_FEDERATION_DIR=%q"):format(dir)
local doctor0 = H.sh(("%s ./cli/memo doctor 2>&1"):format(ENV))
check("no client yet: memo doctor says so (open the client once)",
    doctor0:find("No MCP client has started luamemo", 1, true) ~= nil, doctor0)
local brief = { jsonrpc = "2.0", method = "tools/call", params = { name = "memory_brief", arguments = {} } }
local function b(id) local m = json.decode(json.encode(brief)); m.id = id; return m end
local r = exchange({
    { jsonrpc = "2.0", id = 1, method = "initialize", params = { protocolVersion = "2024-11-05",
        capabilities = { roots = { listChanged = true }, sampling = {} },
        clientInfo = { name = "OldEditor", version = "1.2" } } },
    b(2), b(3),
}, ENV)
local t2 = ((((r[2] or {}).result or {}).content or {})[1] or {}).text or ""
local t3 = ((((r[3] or {}).result or {}).content or {})[1] or {}).text or ""
check("the brief names a 2024-11-05 client: no instructions until it's updated (once a session)",
    t2:find("client: OldEditor 1.2 speaks MCP 2024-11-05", 1, true) ~= nil
    and t2:find("instructions", 1, true) ~= nil and not t3:find("client:", 1, true), t2 .. "\n---\n" .. t3)
local rec = (json.decode(H.slurp(dir .. "/clients.json") or "") or {}).clients or {}
local old = rec.OldEditor or {}
check("the record: name, version, protocol, capability names only",
    old.version == "1.2" and old.protocol == "2024-11-05" and json.encode(old.capabilities) == '["roots","sampling"]'
    and not (H.slurp(dir .. "/clients.json") or ""):find("listChanged", 1, true), json.encode(rec))
local mode = H.mode(dir .. "/clients.json") or ""
check("… in a 0600 file", mode == "600", mode)
local doctor1 = H.sh(("%s ./cli/memo doctor 2>&1"):format(ENV))
check("memo doctor warns about it, and says what is lost",
    doctor1:find("[WARN] OldEditor 1.2 speaks MCP 2024-11-05", 1, true) ~= nil
    and doctor1:find("update it", 1, true) ~= nil, doctor1)
local clip = require("luamemo.clients")._clip
check("a client's name is stored without control characters (an escape sequence can't reach a terminal)",
    clip("Evil\27[2J\nName") == "Evil?[2J?Name")
exchange({ { jsonrpc = "2.0", id = 1, method = "server/discover",
    params = { _meta = meta(MODERN, {}, { name = "OldEditor", version = "2.0" }) } } }, ENV)
local doctor2 = H.sh(("%s ./cli/memo doctor 2>&1"):format(ENV))
check("updated (a modern request): the warning is gone",
    doctor2:find("OldEditor 2.0 (MCP 2026-07-28)", 1, true) ~= nil and not doctor2:find("[WARN] OldEditor", 1, true),
    doctor2)
os.execute(("rm -rf %q"):format(dir))
end)

section("the tool list: its size, and the core profile", function()
io.write("\n--- tool list ---\n")
local list = { jsonrpc = "2.0", id = 1, method = "tools/list" }
local all = exchange({ list })
local core = exchange({ list, { jsonrpc = "2.0", id = 2, method = "tools/call",
    params = { name = "memory_digest", arguments = {} } } }, "MEMO_MCP_TOOLS=core")
local all_tools, core_tools = (all[1].result or {}).tools or {}, (core[1].result or {}).tools or {}
local bytes = #json.encode(all_tools)
-- Every tool's description sits in each session's context (and every request of an
-- API-billed agent): kept short — the usage rules live in instructions.md, once.
check(("all 27 tools in under 16 KB of JSON (%d bytes; 24 KB before trimming)"):format(bytes),
    #all_tools == 27 and bytes < 16000, bytes)
local names = {}
for _, t in ipairs(core_tools) do names[#names + 1] = t.name end
check("MEMO_MCP_TOOLS=core: the 16 everyday tools (no maintenance, diary or vault admin)",
    #core_tools == 16 and not table.concat(names, " "):find("digest", 1, true)
    and table.concat(names, " "):find("memory_brief", 1, true) ~= nil, table.concat(names, " "))
local refused = ((((core[2] or {}).result or {}).content or {})[1] or {}).text or ""
check("… a hidden tool, called anyway, says how to reach it", refused:find("MEMO_MCP_TOOLS", 1, true) ~= nil, refused)
end)

section("framing: batches, parse errors", function()
io.write("\n--- framing ---\n")
local r, lines = exchange({
    { jsonrpc = "2.0", id = 1, method = "initialize", params = { protocolVersion = "2025-03-26" } },
    json.encode({ { jsonrpc = "2.0", id = 2, method = "ping" },
                  { jsonrpc = "2.0", method = "notifications/initialized" },
                  { jsonrpc = "2.0", id = 3, method = "tools/list" } }),
    "this is not json",
})
local batch = r.batch or {}
check("a batch (2025-03-26) → one array with an answer per request (none for the notification)",
    #batch == 2 and batch[1].id == 2 and batch[2].id == 3 and #((batch[2].result or {}).tools or {}) == 27,
    table.concat(lines, "\n"):sub(1, 400))
check("a line that isn't JSON → -32700 (id null), and the server goes on",
    ((r.noid or {}).error or {}).code == -32700, json.encode(r.noid))
local e = exchange({ { jsonrpc = "2.0", id = 1, method = "tools/call", params = { name = "memory_search",
    arguments = { query = "anything", scope = "proto:nothing-here" } } } })
local text = ((((e[1] or {}).result or {}).content or {})[1] or {}).text or ""
check("no results → \"results\":[] (a list, not {})", text:find('"results":[]', 1, true) ~= nil, text)
end)

section("the text a model reads: no needless escapes", function()
io.write("\n--- result text ---\n")
-- lua-cjson writes "/" as "\/" (a character per path / URL separator, for nothing), and
-- the index tools' prose went out inside JSON ("\n" for every line break).
local body = [[paths like luamemo/cli/api.lua and a literal C:\/odd stay as written]]
local r = exchange({
    { jsonrpc = "2.0", id = 1, method = "tools/call", params = { name = "memory_write",
        arguments = { title = "slashes", body = body, scope = "proto:slash", verbose = true } } },
    { jsonrpc = "2.0", id = 2, method = "tools/call", params = { name = "index_search",
        arguments = { query = "anything", scope = "codeindex:proto-none" } } },
})
local function text_of(m) return ((((m or {}).result or {}).content or {})[1] or {}).text or "" end
local wt = text_of(r[1])
check("JSON results keep \"/\" as it is, and decode back to the exact text",
    wt:find("luamemo/cli/api.lua", 1, true) ~= nil and ((json.decode(wt) or {}).memory or {}).body == body, wt)
check("index_search answers in plain text, not text inside JSON", text_of(r[2]) == "(no matches)", text_of(r[2]))
-- A long body in a list row: at most 2,000 bytes (cut on a character, `truncated`) —
-- memory_get has it whole. One long memory cost its full length in every search.
local long = ("ação "):rep(700)   -- 4,900 bytes, a 2-byte character at every cut point
local lw = exchange({
    { jsonrpc = "2.0", id = 1, method = "tools/call", params = { name = "memory_write",
        arguments = { title = "long notes", body = long, scope = "proto:long" } } },
    { jsonrpc = "2.0", id = 2, method = "tools/call", params = { name = "memory_search",
        arguments = { query = "ação", scope = "proto:long" } } },
})
local lid = ((json.decode(text_of(lw[1])) or {}).memory or {}).id
local hit = (((json.decode(text_of(lw[2])) or {}).results) or {})[1] or {}
local lg = exchange({ { jsonrpc = "2.0", id = 1, method = "tools/call", params = { name = "memory_get",
    arguments = { id = lid } } } })
local whole = ((json.decode(text_of(lg[1])) or {}).memory or {}).body
-- the cut text (without the "…") is the body's start, ending where a character ends
local cut = type(hit.body) == "string" and hit.body:sub(1, -4) or ""
local next_byte = long:byte(#cut + 1) or 0
check("a long body in search rows: ≤ 2,000 bytes, cut on a character, truncated; memory_get has it whole",
    hit.truncated == true and #cut <= 2000 and #cut > 1900 and long:sub(1, #cut) == cut
    and not (next_byte >= 0x80 and next_byte < 0xC0) and whole == long,
    ("%s / %s"):format(tostring(hit.body and #hit.body), tostring(whole and #whole)))
-- Text stored with a broken character (an earlier version cut one; another source) reaches
-- the client as valid UTF-8, U+FFFD in place of the stray byte — a strict JSON reader
-- refused the whole message.
local broken = exchange({
    '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"memory_write","arguments":'
        .. '{"title":"broken","body":"decis\195 cut here","scope":"proto:utf8","verbose":true}}}',
})
local bline
for _, l in ipairs(select(2, exchange({ { jsonrpc = "2.0", id = 2, method = "tools/call", params = {
    name = "memory_recent", arguments = { scope = "proto:utf8" } } } }))) do bline = l end
check("a stored invalid byte goes out as U+FFFD (every message is valid UTF-8)", broken[1] ~= nil
    and type(bline) == "string" and require("luamemo.util").fix_utf8(bline) == bline
    and bline:find("decis\239\191\189 cut", 1, true) ~= nil, tostring(bline):sub(1, 200))
-- memory_recent hides tier 0 unless asked, as memory_search: the hooks' raw transcript
-- chunks were a session scope's whole answer (26 KB); and a deleted id is "not found".
local function call(id, name, a) return { jsonrpc = "2.0", id = id, method = "tools/call",
    params = { name = name, arguments = a } } end
local rec = exchange({
    call(1, "memory_write", { scope = "proto:tier", title = "raw chunk", body = "USER: hi\nASSISTANT: hello", tier = 0 }),
    call(2, "memory_write", { scope = "proto:tier", title = "kept", body = "a decision worth keeping" }),
    call(3, "memory_recent", { scope = "proto:tier" }),
    call(4, "memory_recent", { scope = "proto:tier", tier_min = 0 }),
    call(5, "memory_get", { id = 999999 }),
})
local function text(m) return m and m.result and m.result.content and m.result.content[1].text or "" end
check("memory_recent: tier 0 left out by default, tier_min = 0 shows it",
    text(rec[3]):find("kept", 1, true) and not text(rec[3]):find("raw chunk", 1, true)
    and text(rec[4]):find("raw chunk", 1, true), text(rec[3]):sub(1, 200))
check("memory_get of a missing id: \"not found\", not \"Error: nil\"", text(rec[5]):find("not found", 1, true) ~= nil,
    text(rec[5]))
-- Compact rows leave out luamemo's bookkeeping (lm_*) and an org memory's proposers (people's
-- e-mail identities) — half of an org search's answer; a duplicate inside one batch is
-- answered with the row it went into (it was a failure, so an agent sent it again).
local mb = exchange({
    call(1, "memory_write", { scope = "proto:meta", title = "Deploy rule", body = "deploys go through the pipeline",
        metadata = { project = "web", lm_org_id = "7", lm_org_updated_us = "1", proposers = { "user:a@corp.example" } } }),
    call(2, "memory_search", { scope = "proto:meta", query = "deploys pipeline" }),
    call(3, "memory_write", { scope = "proto:batch", items = {
        { title = "Queue", body = "We use PostgreSQL for the job queue" },
        { title = "Queue", body = "We use PostgreSQL for the job queue" } } }),
})
local srow = ((json.decode(text(mb[2])) or {}).results or {})[1] or {}
check("compact rows: metadata without lm_* / proposers (verbose keeps them)",
    type(srow.metadata) == "table" and srow.metadata.project == "web" and srow.metadata.lm_org_id == nil
    and srow.metadata.proposers == nil, json.encode(srow.metadata))
local batch = json.decode(text(mb[3])) or {}
check("memory_write items: a duplicate within the batch is a success, merged_into the item it joined",
    batch.ok == true and batch.failed == 0 and (batch.results or {})[2] and batch.results[2].merged_into == 1
    and batch.results[2].id == batch.results[1].id, text(mb[3]))
-- Without lua-cjson (optional; the bundled dkjson then parses) a deeply nested line raised
-- "stack overflow" out of the main loop: the server exited, later calls went unanswered.
local stub = os.tmpname(); os.remove(stub)
os.execute(("mkdir -p %q"):format(stub .. "/cjson"))
local sf = assert(io.open(stub .. "/cjson/safe.lua", "w")); sf:write('error("no lua-cjson here")'); sf:close()
local deep = exchange({
    '{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":' .. ("["):rep(6000) .. ("]"):rep(6000) .. "}}",
    { jsonrpc = "2.0", id = 2, method = "ping" },
}, ("LUA_PATH=%q"):format(stub .. "/?.lua;;"))
os.execute(("rm -rf %q"):format(stub))
check("dkjson: a 6,000-deep line is a parse error, and the server goes on (the next call answered)",
    deep.noid and deep.noid.error and deep.noid.error.code == -32700 and deep[2] and deep[2].result ~= nil,
    json.encode({ deep.noid, deep[2] }))
-- Wrong-typed fields from an agent: an object / null as the title or body crashed deep in
-- the store (a bare "Internal error"), a string as metadata surfaced a raw SQLite message.
-- Now each is a tool error that says what is wrong; a number is taken as text.
local typed = {}
for i, a in ipairs({ { title = "t", body = { x = 1 } }, { title = { x = 1 }, body = "b" },
                     { title = "t", body = "b", metadata = "m" }, { title = "t", body = "b", tags = "a,b" },
                     { items = { { title = "t", body = { x = 1 } } } } }) do
    a.scope = "proto:typed"
    typed[#typed + 1] = { jsonrpc = "2.0", id = i, method = "tools/call",
        params = { name = "memory_write", arguments = a } }
end
typed[#typed + 1] = '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"memory_write",'
    .. '"arguments":{"title":null,"body":"b","scope":"proto:typed"}}}'
typed[#typed + 1] = { jsonrpc = "2.0", id = 7, method = "tools/call", params = { name = "memory_write",
    arguments = { title = 42, body = "the answer", scope = "proto:typed" } } }
local tr = exchange(typed)
local plain, why = true, {}
for i = 1, 4 do
    local m = tr[i] or {}
    local t = text_of(m)
    if m.error or not (m.result or {}).isError or not t:find("must be", 1, true) then plain = false end
    why[#why + 1] = t:sub(1, 60)
end
-- (items: each memory is answered on its own — the bad one carries its error)
local item1 = (((json.decode(text_of(tr[5])) or {}).results) or {})[1] or {}
check("wrong-typed write fields → a tool error that says what's wrong, never an internal error",
    plain and tr[5] and tr[5].error == nil and tostring(item1.error):find("must be text", 1, true) ~= nil
    and tr[6] and tr[6].error == nil and tr[7] and not (tr[7].result or {}).isError,
    table.concat(why, " | "))
-- Every tool, every argument, a wrong type (object, list, boolean, null, text): a tool error or
-- an answer — never a JSON-RPC internal error (a Lua error in the handler). There were 45
-- in 9 tools (index_* project / scope / kind, the diary's agent_name / entry, …).
local tl = exchange({ { jsonrpc = "2.0", id = 1, method = "tools/list" } })
local fuzz, what, fid = {}, {}, 1000
for _, t in ipairs((((tl[1] or {}).result or {}).tools) or {}) do
    local props = (t.inputSchema or {}).properties or {}
    for pname in pairs(props) do
        for _, wv in ipairs({ '{"x":1}', '[1,2]', 'true', 'null', '"text"' }) do
            fid = fid + 1
            local parts = {}
            for _, r in ipairs((t.inputSchema or {}).required or {}) do
                if r ~= pname then
                    local ty = (props[r] or {}).type
                    parts[#parts + 1] = ('"%s":%s'):format(r, (ty == "integer" or ty == "number") and "1"
                        or ty == "object" and "{}" or ty == "array" and "[]" or '"x"')
                end
            end
            parts[#parts + 1] = ('"%s":%s'):format(pname, wv)
            fuzz[#fuzz + 1] = ('{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"%s",'
                .. '"arguments":{%s}}}'):format(fid, t.name, table.concat(parts, ","))
            what[fid] = t.name .. "." .. pname .. "=" .. wv
        end
    end
end
local fr = exchange(fuzz)
local internal, answered = {}, 0
for k, m in pairs(fr) do
    if what[k] then
        answered = answered + 1
        if m.error and m.error.code == -32603 then internal[#internal + 1] = what[k] end
    end
end
check(("every tool × wrong-typed argument (%d calls): no internal error"):format(#fuzz),
    #fuzz > 300 and answered == #fuzz and #internal == 0,
    ("%d answered, %d internal: %s"):format(answered, #internal, table.concat(internal, ", "):sub(1, 300)))
-- Oversized lists / objects: 10,000 scopes or metadata-filter keys overran LuaJIT's unpack
-- (an internal error) or SQLite's expression depth (a raw SQLite message). Bounded now.
local many, keys = {}, {}
for i = 1, 10000 do many[i] = "repo:x" .. i; keys[#keys + 1] = ('"k%d":"v"'):format(i) end
local big = exchange({
    { jsonrpc = "2.0", id = 1, method = "tools/call", params = { name = "memory_search",
        arguments = { query = "x", scopes = many } } },
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_delete","arguments":'
        .. '{"scope":"s","metadata_filter":{' .. table.concat(keys, ",") .. '}}}}',
})
check("10,000 scopes / filter keys → a tool error naming the bound, not an internal error",
    (big[1] or {}).error == nil and text_of(big[1]):find("at most 200", 1, true) ~= nil
    and (big[2] or {}).error == nil and text_of(big[2]):find("at most 200", 1, true) ~= nil,
    text_of(big[1]):sub(1, 80) .. " | " .. text_of(big[2]):sub(1, 80))
-- Tags and metadata are stored scrubbed too (nested values, JSON arrays kept as arrays).
local gh = "ghp_" .. ("a1B2"):rep(9)
local m = exchange({ { jsonrpc = "2.0", id = 1, method = "tools/call", params = { name = "memory_write",
    arguments = { title = "meta", body = "plain", scope = "proto:meta", verbose = true, tags = { "deploy", gh },
        metadata = { db = "postgres://app:pa55word@db/x", nested = { auth = "Bearer abcdefghijklmnop1234" },
                     list = { "a", gh } } } } } })
local mem = ((json.decode(text_of(m[1])) or {}).memory) or {}
local md = mem.metadata or {}
check("tags and metadata values are scrubbed (nested too); lists stay lists",
    json.encode(mem.tags) == '["deploy","[redacted]"]' and md.db == "postgres://app:***@db/x"
    and (md.nested or {}).auth == "Bearer [redacted]" and json.encode(md.list) == '["a","[redacted]"]',
    json.encode(mem))
end)

finish()
