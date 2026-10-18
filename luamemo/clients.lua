-- luamemo/clients.lua
-- The MCP clients that started luamemo on this machine, and what an old one loses.
--
-- The MCP server records what each client says about itself — its name and version
-- (clientInfo), the protocol version it speaks and the capability names it declares —
-- in a per-user file (<federation dir>/clients.json, 0600: names and versions only,
-- nothing secret). memo calibrate and memo doctor read it and name a client too old for
-- something luamemo needs; the MCP tool memory_brief tells the model the same, once.

local json = require("luamemo.json")

local M = {}

-- What luamemo needs from a client, and since which MCP revision a client can give it.
-- (Revisions are dates: they compare as strings.) Finding the project needs nothing from
-- the client — its working directory, or `memo mcp --project` (Roots are deprecated since
-- 2026-07-28 and not used).
M.NEEDS = {
    { what = "tools", since = "2024-11-05" },
    { what = "instructions", since = "2025-03-26",
      lost = "send it the session guidance (MCP server instructions)",
      instead = "the model gets it only through luamemo's hook, skill or agent" },
}

local function path()
    local dir = require("luamemo.federation.keys").dir()
    return dir and (dir .. "/clients.json") or nil
end
M.path = path

--- Every record: { [name] = { name, version, protocol, capabilities = {names}, seen } }.
function M.read()
    local p = path()
    local f = p and io.open(p, "r")
    if not f then return {} end
    local data = json.decode(f:read("*a") or "")
    f:close()
    return type(data) == "table" and type(data.clients) == "table" and data.clients or {}
end

-- What a client says about itself, as text that is safe to print (memo doctor / calibrate
-- write it to a terminal, the brief to the model): control characters — an escape
-- sequence, a line break — become "?"; at most n characters.
local function clip(v, n)
    v = type(v) == "string" and v or (type(v) == "number" and tostring(v) or nil)
    return v and require("luamemo.util").cut_utf8((v:gsub("%c", "?")), n or 80) or nil
end
M._clip = clip   -- (tests)

local recorded = {}   -- this process: name|version|protocol already written

--- Record a client (what initialize or a modern request's _meta says). Best-effort: a
--- failure to write is not the client's problem. Returns true when the file changed.
function M.record(info, protocol, capabilities)
    local name = clip(type(info) == "table" and info.name or nil) or "unknown client"
    local version = clip(type(info) == "table" and info.version or nil) or "?"
    protocol = clip(protocol, 20) or "?"
    local key = name .. "|" .. version .. "|" .. protocol
    if recorded[key] then return false end
    recorded[key] = true
    local caps = {}
    for k in pairs(type(capabilities) == "table" and capabilities or {}) do
        if type(k) == "string" then caps[#caps + 1] = clip(k, 40) end
    end
    table.sort(caps)
    local ok = pcall(function()
        local p = path()
        if not p then return end
        local all = M.read()
        all[name] = { name = name, version = version, protocol = protocol,
            capabilities = #caps > 0 and caps or json.empty_array, seen = os.date("!%Y-%m-%dT%H:%M:%SZ") }
        local util = require("luamemo.util")
        util.private_dir(p:match("^(.*)/[^/]+$"), true)   -- the keyring dir, 0700
        assert(util.write_private(p, json.encode({ clients = all })))   -- 0600, atomic
    end)
    return ok
end

--- What this client can't get from luamemo: { {what, lost, instead}, … } (empty: nothing).
function M.missing(rec)
    local out, proto = {}, type(rec) == "table" and rec.protocol or nil
    if type(proto) ~= "string" or not proto:match("^%d%d%d%d%-%d%d%-%d%d$") then return out end
    for _, n in ipairs(M.NEEDS) do
        if n.lost and proto < n.since then out[#out + 1] = n end
    end
    return out
end

--- The warning about one client (nil when it has everything).
function M.warning(rec)
    local miss = M.missing(rec)
    if #miss == 0 then return nil end
    local lost, instead = {}, {}
    for _, n in ipairs(miss) do lost[#lost + 1] = n.lost; instead[#instead + 1] = n.instead end
    return ("%s %s speaks MCP %s — luamemo can't %s until you update it (until then %s)."):format(
        rec.name, rec.version, rec.protocol, table.concat(lost, ", or "), table.concat(instead, "; "))
end

--- The lines memo calibrate / memo doctor print: one per client that misses something;
--- a note when no client has started luamemo yet. ok = every recorded client is fine.
function M.report()
    local all, names = M.read(), {}
    for name in pairs(all) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
        return { "No MCP client has started luamemo on this machine yet — open your client once "
            .. "(with luamemo in its config), then run memo doctor to check it." }, true
    end
    local lines, ok = {}, true
    for _, name in ipairs(names) do
        local w = M.warning(all[name])
        if w then lines[#lines + 1] = w; ok = false end
    end
    if ok then
        local seen = {}
        for _, name in ipairs(names) do
            local r = all[name]
            seen[#seen + 1] = ("%s %s (MCP %s)"):format(r.name, r.version, r.protocol)
        end
        lines[1] = "MCP clients: " .. table.concat(seen, ", ") .. " — each gets everything luamemo offers."
    end
    return lines, ok
end

return M
