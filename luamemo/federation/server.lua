-- luamemo.federation.server
-- Minimal HTTP/1.1 server for the org central (`memo serve`): pure Lua over
-- luasocket, one request per connection. Enough for a team's periodic pull /
-- push; several instances can share one database.
--
-- LOCAL NETWORK ONLY: it refuses to bind a public address and drops any
-- connection whose peer is not loopback / LAN / VPN overlay (Tailscale …) —
-- see luamemo.netguard. Transport security is the federation channel's own
-- (mutual key authentication + encryption), so no TLS proxy is needed.
--
-- Concurrency: an event loop over select(), one coroutine per connection —
-- a client that sends (or reads) slowly waits in select while the others are
-- served; the handlers themselves (short DB / crypto work) run one at a time.
-- Open connections are capped overall and per source address; when a cap is
-- hit, the connection that has gone longest without sending anything (a real
-- client sends its request at once) is closed to make room, so idle or
-- trickling connections can't fill the server.
--
-- Hardening: per-request deadline and hard caps (request head, body), so a
-- slow or hostile client can neither pin memory nor hold a connection past the
-- deadline. Chunked request bodies are rejected (clients must send
-- Content-Length). Logs carry method + path only.

local socket   = require("socket")
local json     = require("luamemo.json")
local handlers = require("luamemo.federation.handlers")
local netguard = require("luamemo.netguard")

local M = {}

M.MAX_HEAD     = 16 * 1024
M.MAX_BODY     = handlers.MAX_BODY
M.DEADLINE_S   = 10
M.MAX_CONNS    = 128     -- open connections, all peers
M.MAX_PER_PEER = 16      -- open connections from one address
M.MAX_BUFFERED = 64 * 1024 * 1024   -- request bodies being received at once, all connections

local REASON = {
    [200] = "OK", [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden",
    [404] = "Not Found", [408] = "Request Timeout", [409] = "Conflict", [411] = "Length Required",
    [413] = "Payload Too Large", [415] = "Unsupported Media Type", [429] = "Too Many Requests",
    [431] = "Request Header Fields Too Large", [500] = "Internal Server Error",
    [501] = "Not Implemented", [503] = "Service Unavailable",
}

local function url_decode(s)
    s = s:gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function parse_query(qs)
    local q = {}
    for pair in (qs or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k and k ~= "" then q[url_decode(k)] = url_decode(v or "") end
    end
    return q
end

-- wait(c, "r" | "w", deadline) → true when c is ready, false at the deadline.
-- Standalone it blocks in select; inside the event loop (M.run) it yields to
-- the loop instead, which resumes the connection when its socket is ready.
local function block_wait(c, mode, deadline)
    local remaining = deadline - socket.gettime()
    if remaining <= 0 then return false end
    local r, w = socket.select(mode == "r" and { c } or nil, mode == "w" and { c } or nil, remaining)
    local ready = (mode == "r") and r or w
    return ready ~= nil and #ready > 0
end

-- Read from `c` until pred(buf) is true or a cap / the deadline is hit.
-- Returns buf, or nil + one of "too_large" | "timeout" | "closed".
local function fill(c, buf, pred, cap, deadline, wait)
    c:settimeout(0)
    while not pred(buf) do
        if #buf > cap then return nil, "too_large" end
        if not wait(c, "r", deadline) then return nil, "timeout" end
        local data, err, partial = c:receive(8192)
        local chunk = data or partial
        if chunk and #chunk > 0 then buf = buf .. chunk end
        if err == "closed" and not pred(buf) then return nil, "closed" end
    end
    return buf
end

-- Read the body: exactly `n` bytes, `have` already buffered. Chunks are
-- collected in a table and joined once (appending to a string re-copies
-- the whole buffer per read: quadratic in the body size).
-- Returns body, or nil + "timeout" | "closed".
local function read_body(c, have, n, deadline, wait)
    local parts, got = { have }, #have
    c:settimeout(0)
    while got < n do
        if not wait(c, "r", deadline) then return nil, "timeout" end
        local data, err, partial = c:receive(math.min(65536, n - got))
        local chunk = data or partial
        if chunk and #chunk > 0 then parts[#parts + 1] = chunk; got = got + #chunk end
        if err == "closed" and got < n then return nil, "closed" end
    end
    local body = table.concat(parts)
    return (#body > n) and body:sub(1, n) or body
end

--- Read + parse one request. Returns req, or nil, status, message.
function M.read_request(c, limits, wait)
    limits, wait = limits or {}, wait or block_wait
    local max_head = limits.max_head or M.MAX_HEAD
    local max_body = limits.max_body or M.MAX_BODY
    local deadline = socket.gettime() + (limits.deadline_s or M.DEADLINE_S)

    local buf, err = fill(c, "", function(b) return b:find("\r\n\r\n", 1, true) ~= nil end,
        max_head, deadline, wait)
    if not buf then
        if err == "too_large" then return nil, 431, "request head too large" end
        if err == "timeout" then return nil, 408, "request timeout" end
        return nil, nil, "client closed"
    end
    local head_end = buf:find("\r\n\r\n", 1, true)
    if head_end > max_head then return nil, 431, "request head too large" end
    local head, rest = buf:sub(1, head_end - 1), buf:sub(head_end + 4)

    local lines = {}
    for line in (head .. "\r\n"):gmatch("(.-)\r\n") do lines[#lines + 1] = line end
    local method, target, version = (lines[1] or ""):match("^(%u+) (%S+) HTTP/(%d%.%d)$")
    if not method or target:sub(1, 1) ~= "/" then return nil, 400, "malformed request line" end

    local headers = {}
    for i = 2, #lines do
        local name, value = lines[i]:match("^([%w%-]+):%s*(.-)%s*$")
        if not name then return nil, 400, "malformed header" end
        name = name:lower()
        if name == "content-length" and headers[name] and headers[name] ~= value then
            return nil, 400, "conflicting Content-Length"
        end
        headers[name] = value
    end
    if headers["transfer-encoding"] then
        return nil, 501, "chunked request bodies are not supported; send Content-Length"
    end

    local body = ""
    local clen = headers["content-length"]
    if clen then
        -- Digits only: tonumber would also take "0x10", "+5", " 5", "1e3".
        if not clen:match("^%d+$") then return nil, 400, "bad Content-Length" end
        local n = tonumber(clen)
        if n > max_body then return nil, 413, "request body too large" end
        -- (event loop: bodies received concurrently share one memory budget)
        if limits.reserve and not limits.reserve(n) then
            return nil, 503, "server busy — too much request data in flight; retry shortly"
        end
        local got, berr = read_body(c, rest, n, deadline, wait)
        if not got then
            if berr == "timeout" then return nil, 408, "request timeout" end
            return nil, 400, "incomplete body"
        end
        body = got
    elseif method == "POST" or method == "PUT" then
        return nil, 411, "Content-Length required"
    end

    local path, qs = target:match("^([^?]*)%??(.*)$")
    return { method = method, path = path, query = parse_query(qs), headers = headers,
             body = body, http_version = version }
end

-- body: a string (sent as-is with ctype) or a table (JSON-encoded). Written
-- without blocking: a slow reader waits (up to the deadline) in `wait`.
local function send(c, status, body, ctype, wait)
    if type(body) ~= "string" then body, ctype = json.encode(body or {}), "application/json" end
    local data = ("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n"
        .. "Cache-Control: no-store\r\nConnection: close\r\n\r\n")
        :format(status, REASON[status] or "Status", ctype or "application/json", #body) .. body
    local deadline, i = socket.gettime() + M.DEADLINE_S, 1
    c:settimeout(0)
    while i <= #data do
        local last, err, partial_last = c:send(data, i)
        if last then
            i = last + 1
        elseif err == "timeout" then
            i = (partial_last or i - 1) + 1
            if not wait(c, "w", deadline) then return false end
        else
            return false                                  -- closed / reset
        end
    end
    return true
end

--- Serve one connection. Returns status, method, path (method/path are nil
--- when the request couldn't be parsed). Handler errors become a generic 500.
--- (Only the handler runs under pcall: I/O may yield to the event loop, and
--- Lua 5.1 can't yield across pcall.)
function M.serve_connection(c, opts, wait)
    opts, wait = opts or {}, wait or block_wait
    local req, st, msg = M.read_request(c, opts.limits, wait)
    if not req then
        if st then send(c, st, { error = msg }, nil, wait) end
        return st or 0
    end
    req.peer = (c:getpeername())   -- /pair limits count per address
    local ok, status, body, ctype = pcall(handlers.handle, req, opts.prefix)
    if not ok then
        io.stderr:write("[luamemo serve] handler error: " .. tostring(status) .. "\n")
        status, body, ctype = 500, { error = "internal error" }, nil
    end
    send(c, status, body, ctype, wait)
    return status, req.method, req.path
end

--- Bind address policy: loopback / LAN / VPN, or a wildcard (all interfaces —
--- the per-connection peer check then enforces local-only). Returns ok, reason.
function M.bind_allowed(host)
    if host == "0.0.0.0" or host == "::" or host == "*" then return true end
    return netguard.host_is_local(host)
end

--- Peer policy: only loopback / LAN / VPN peers are served.
function M.peer_allowed(ip) return netguard.is_local(ip) end

-- Lingering close: closing a socket that still has unread request bytes makes
-- the kernel send RST, which can destroy the response we just wrote (e.g. a
-- 431/413 sent before the oversized input was consumed). Half-close our side,
-- drain what the client is still sending (bounded: 1 s / 256 KB), then close.
-- A well-behaved client closes after reading the response, so this ends at once.
local function lingering_close(c, wait)
    wait = wait or block_wait
    if c:shutdown("send") then
        c:settimeout(0)
        local deadline, drained = socket.gettime() + 1.0, 0
        while drained < 256 * 1024 and wait(c, "r", deadline) do
            local data, err, partial = c:receive(8192)
            local chunk = data or partial
            if chunk then drained = drained + #chunk end
            if err == "closed" then break end
        end
    end
    c:close()
end

--- Run the event loop. opts: host (default 127.0.0.1), port (0 = any free),
--- prefix, max_requests (accept N connections, finish them, stop — testing
--- aid), log (default stderr).
function M.run(opts)
    opts = opts or {}
    local host = opts.host or "127.0.0.1"
    local ok_bind, why = M.bind_allowed(host)
    if not ok_bind then
        error("federation is local-network only — refusing to bind " .. host .. ": " .. tostring(why), 0)
    end
    local bind_host = (host == "*") and "0.0.0.0" or host
    local srv = assert(socket.bind(bind_host, tonumber(opts.port) or 8765))
    srv:settimeout(0)
    local bound_host, bound_port = srv:getsockname()
    local log = opts.log or function(s) io.stderr:write(s .. "\n") end
    log(("LISTENING %s %d"):format(bound_host, bound_port))
    -- Path only (never the query string or bodies — no secrets in logs).
    local function log_line(ip, method, path, status, t0)
        log(("%s %s %s %s %d %.0fms"):format(os.date("!%Y-%m-%dT%H:%M:%SZ"), tostring(ip),
            method or "-", path or "-", status or 0, (socket.gettime() - t0) * 1000))
    end

    local conns, n_conns, per_peer = {}, 0, {}   -- conn = { co, c, ip, t0, mode, deadline, phase, reserved }
    local buffered = 0                           -- body bytes reserved by open connections
    local function drop(conn)
        conns[conn] = nil
        n_conns = n_conns - 1
        per_peer[conn.ip] = per_peer[conn.ip] - 1
        if per_peer[conn.ip] == 0 then per_peer[conn.ip] = nil end
        buffered = buffered - (conn.reserved or 0)
        conn.reserved = 0
    end
    -- Resume a connection's coroutine; it yields (mode, deadline) to wait, or ends.
    local function step(conn, ready)
        if ready and conn.mode == "r" then conn.last = socket.gettime() end   -- data arrived
        local ok, mode, deadline = coroutine.resume(conn.co, ready)
        if ok and coroutine.status(conn.co) == "suspended" then
            conn.mode, conn.deadline = mode, deadline
            if mode == "w" then conn.phase = "write" elseif conn.phase ~= "linger" then conn.phase = "read" end
            return
        end
        if not ok then
            io.stderr:write("[luamemo serve] connection error: " .. tostring(mode) .. "\n")
            pcall(conn.c.close, conn.c)
            conn.status = conn.status or 500
        end
        drop(conn)
        log_line(conn.ip, conn.method, conn.path, conn.status, conn.t0)
    end
    -- Make room: close the connection (optionally from one address) that has
    -- gone longest without sending anything — still waiting for its request, or
    -- lingering; never one being answered. A client uploading a large body keeps
    -- sending, so a trickling or silent one goes first. false: none.
    local function evict(ip)
        local victim
        for conn in pairs(conns) do
            if conn.phase ~= "write" and (not ip or conn.ip == ip)
                and (not victim or conn.last < victim.last) then
                victim = conn
            end
        end
        if not victim then return false end
        pcall(victim.c.close, victim.c)
        drop(victim)
        log_line(victim.ip, "EVICT", "idle", 0, victim.t0)
        return true
    end
    local function wait(_, mode, deadline) return coroutine.yield(mode, deadline) end

    local accepted, max = 0, tonumber(opts.max_requests)
    while (not max or accepted < max) or n_conns > 0 do
        local rs, ws, nearest = {}, {}, nil
        local accepting = not max or accepted < max
        if accepting then rs[1] = srv end
        for conn in pairs(conns) do
            if conn.mode == "w" then ws[#ws + 1] = conn.c else rs[#rs + 1] = conn.c end
            if not nearest or conn.deadline < nearest then nearest = conn.deadline end
        end
        local r, w = socket.select(rs, ws, nearest and math.max(0, nearest - socket.gettime()) or nil)
        r, w = r or {}, w or {}

        if accepting and r[srv] then
            while not max or accepted < max do
                local c = srv:accept()
                if not c then break end
                accepted = accepted + 1
                local ip, t0 = c:getpeername(), socket.gettime()
                if not M.peer_allowed(ip) then
                    c:close()                                 -- public peer: dropped unanswered
                    log_line(ip, "DROP", "public-peer", 0, t0)
                elseif ((per_peer[ip] or 0) >= M.MAX_PER_PEER and not evict(ip))
                    or (n_conns >= M.MAX_CONNS and not evict(nil)) then
                    c:close()                                 -- full of requests being answered
                    log_line(ip, "BUSY", "-", 0, t0)
                else
                    local conn = { c = c, ip = ip, t0 = t0, last = t0, phase = "read" }
                    local climits = setmetatable({ reserve = function(n)
                        if buffered + n > M.MAX_BUFFERED then return false end
                        buffered, conn.reserved = buffered + n, (conn.reserved or 0) + n
                        return true
                    end }, { __index = opts.limits or {} })
                    local copts = setmetatable({ limits = climits }, { __index = opts })
                    conn.co = coroutine.create(function()
                        conn.status, conn.method, conn.path = M.serve_connection(c, copts, wait)
                        conn.phase = "linger"
                        lingering_close(c, wait)
                    end)
                    conns[conn], n_conns = true, n_conns + 1
                    per_peer[ip] = (per_peer[ip] or 0) + 1
                    step(conn)
                end
            end
        end

        local now = socket.gettime()
        local due = {}
        for conn in pairs(conns) do
            local ready = (conn.mode == "w") and w[conn.c] or r[conn.c]
            if ready then due[#due + 1] = { conn, true }
            elseif conn.deadline <= now then due[#due + 1] = { conn, false } end
        end
        for _, d in ipairs(due) do
            if conns[d[1]] then step(d[1], d[2]) end
        end
    end
    srv:close()
end

M._parse_query = parse_query   -- tests

return M
