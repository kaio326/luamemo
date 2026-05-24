-- luamemo.http
-- Portable HTTP client abstraction.
--
-- Priority order for the underlying transport:
--   1. resty.http   — non-blocking, available inside OpenResty workers.
--                     Preferred when present because it avoids blocking the
--                     event loop.
--   2. ssl.https    — luasec-backed HTTPS for plain-Lua environments.
--                     Required when calling HTTPS URLs outside OpenResty.
--   3. socket.http  — plain HTTP via luasocket.  No TLS support.
--
-- Public API:
--   http.request(url, opts) → status_code, body, err
--
-- opts fields:
--   method      string   HTTP method (default "GET")
--   headers     table    request headers
--   body        string   request body
--   timeout_ms  number   timeout in milliseconds (default 10000)
--
-- Returns:
--   status_code  number   HTTP status code, or nil on error
--   body         string   response body, or nil on error
--   err          string   error message, or nil on success

local M = {}

-- ---------------------------------------------------------------------------
-- resty.http adapter  (OpenResty / non-blocking)
-- ---------------------------------------------------------------------------
local function try_resty(url, opts)
    local ok, resty_http = pcall(require, "resty.http")
    if not ok then return nil end

    return function()
        local httpc, herr = resty_http.new()
        if not httpc then
            return nil, nil, "http: resty.http.new() failed: " .. tostring(herr)
        end
        httpc:set_timeout(opts.timeout_ms or 10000)
        local res, rerr = httpc:request_uri(url, {
            method  = opts.method  or "GET",
            headers = opts.headers or {},
            body    = opts.body,
        })
        if not res then
            return nil, nil, "http: request failed: " .. tostring(rerr)
        end
        return res.status, res.body, nil
    end
end

-- ---------------------------------------------------------------------------
-- socket.http / ssl.https adapter  (plain Lua / luasocket)
-- ---------------------------------------------------------------------------
-- NOTE: This call BLOCKS the Lua thread for the full HTTP round-trip
-- (typically 10-2000 ms depending on the server and network).  In OpenResty
-- all requests go through try_resty() above, which is non-blocking via nginx
-- cosockets.  In plain Lua, use luamemo.async + M.request_async() when
-- concurrent HTTP fan-out is needed (see store.write_many()).
local function try_socket(url, opts)
    local scheme = url:match("^([%w+%-%.]+)://")
    local is_https = (scheme == "https")

    local http_mod
    if is_https then
        local ok, mod = pcall(require, "ssl.https")
        if not ok then
            return nil, nil,
                "http: HTTPS request requires luasec (ssl.https). "
                .. "Install it with: luarocks install luasec"
        end
        http_mod = mod
    else
        -- Pre-load ltn12 before socket.http to prevent LuaSocket's lazy _G
        -- assignment from triggering OpenResty's __newindex guard.
        pcall(require, "ltn12")
        local ok, mod = pcall(require, "socket.http")
        if not ok then
            return nil, nil,
                "http: socket.http unavailable. "
                .. "Install luasocket: luarocks install luasocket"
        end
        http_mod = mod
    end

    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    if not ok_ltn12 then
        return nil, nil, "http: ltn12 unavailable (install luasocket)"
    end

    local req_body = opts.body
    local headers  = {}
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    if req_body then
        headers["content-length"] = headers["content-length"]
                                    or tostring(#req_body)
    end

    local timeout_s = (opts.timeout_ms or 10000) / 1000
    -- socket.http.TIMEOUT is the effective per-operation timeout used by
    -- socket.http for all socket reads and writes.  The `create`-callback
    -- settimeout() approach is silently ignored by socket.http (it resets
    -- the socket timeout internally after create() returns).  We therefore
    -- set http_mod.TIMEOUT directly for this request and restore it afterwards.
    local prev_timeout = http_mod.TIMEOUT
    http_mod.TIMEOUT = timeout_s

    local chunks = {}
    local req = {
        url    = url,
        method = (opts.method or "GET"):upper(),
        headers = headers,
        sink   = ltn12.sink.table(chunks),
    }
    if req_body then
        req.source = ltn12.source.string(req_body)
    end

    -- NOTE: try_socket is not re-entrant-safe across coroutines — two concurrent
    -- calls interleaved at a yield point will interfere via http_mod.TIMEOUT.
    -- Plain Lua is single-threaded so this is safe in normal use; avoid calling
    -- try_socket concurrently from coroutines.
    local ok_call, code, _resp_headers, _status = pcall(http_mod.request, req)
    http_mod.TIMEOUT = prev_timeout  -- restore regardless of outcome or error
    if not ok_call then
        return nil, nil, "http: request error: " .. tostring(code)
    end

    if not code then
        return nil, nil, "http: request failed (network error)"
    end
    if type(code) ~= "number" then
        -- socket.http returns the error string as the second return when it
        -- fails at the transport level (e.g. "timeout", "connection refused").
        return nil, nil, "http: " .. tostring(code)
    end

    return code, table.concat(chunks), nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Non-blocking HTTP request for use inside luamemo.async task coroutines.
-- Supports HTTP only (not HTTPS) — HTTPS falls back to the synchronous path.
-- Uses raw socket.tcp() in non-blocking mode; yields via wait_fn(sock, event)
-- whenever the socket would block, allowing the async scheduler to interleave
-- other tasks. Returns the same (status, body, err) triple as M.request().
-- @param url     string    http:// URL (https:// falls back to sync)
-- @param opts    table     same as M.request()
-- @param wait_fn function  wait_fn(sock, event) from luamemo.async
-- @return number|nil, string|nil, string|nil
function M.request_async(url, opts, wait_fn)
    opts = opts or {}

    -- HTTPS is not supported in async mode — fall back to blocking.
    local scheme = url:match("^([%w+%-%.]-)://")
    if scheme ~= "http" then
        return M.request(url, opts)
    end

    -- Parse URL into components.
    local host, port_str, path = url:match("^https?://([^/:?#]+):?(%d*)(/[^%s]*)")
    if not host then
        -- Try without explicit path.
        host, port_str = url:match("^https?://([^/:?#]+):?(%d*)$")
        path = "/"
    end
    if not host then
        return nil, nil, "http.request_async: could not parse URL: " .. url
    end
    path = (path == nil or path == "") and "/" or path
    local port = tonumber(port_str) or 80

    -- DNS lookup is synchronous in plain Lua — unavoidable without a
    -- non-blocking resolver.  For local embedder URLs the OS caches the result.
    local sock_mod = require("socket")
    local ip, dns_err = sock_mod.dns.toip(host)
    if not ip then
        return nil, nil, "http.request_async: DNS failed for " .. host .. ": " .. tostring(dns_err)
    end

    local sock = sock_mod.tcp()
    sock:settimeout(0)  -- non-blocking mode

    -- Initiate connect; "timeout" is expected when the kernel is setting up
    -- the TCP handshake in the background.
    local _, cerr = sock:connect(ip, port)
    if cerr and cerr ~= "timeout" then
        sock:close()
        return nil, nil, "http.request_async: connect error: " .. cerr
    end
    wait_fn(sock, "write")  -- wait for the connection to complete

    -- Build the HTTP/1.1 request.
    local method   = (opts.method or "GET"):upper()
    local req_body = opts.body or ""
    local hdr_lines = {
        "Host: " .. host,
        "Connection: close",
        "Content-Length: " .. tostring(#req_body),
    }
    for k, v in pairs(opts.headers or {}) do
        hdr_lines[#hdr_lines + 1] = k .. ": " .. v
    end
    local req_str = method .. " " .. path .. " HTTP/1.1\r\n"
        .. table.concat(hdr_lines, "\r\n") .. "\r\n\r\n" .. req_body

    -- Send the full request, yielding on partial writes.
    local send_i = 1
    local send_j = #req_str
    while send_i <= send_j do
        local last, serr, partial = sock:send(req_str, send_i, send_j)
        if last then
            break  -- all bytes sent
        elseif serr == "timeout" then
            send_i = (partial or send_i - 1) + 1
            wait_fn(sock, "write")
        else
            sock:close()
            return nil, nil, "http.request_async: send error: " .. tostring(serr)
        end
    end

    -- Receive the response, yielding on partial reads.
    -- Read until we have the complete header block (ending with \r\n\r\n).
    local buf = ""
    local CRLF2 = "\r\n\r\n"
    while not buf:find(CRLF2, 1, true) do
        local chunk, rerr, partial = sock:receive(4096)
        if chunk then
            buf = buf .. chunk
        elseif rerr == "timeout" then
            if partial and #partial > 0 then buf = buf .. partial end
            wait_fn(sock, "read")
        elseif rerr == "closed" then
            if partial and #partial > 0 then buf = buf .. partial end
            break
        else
            sock:close()
            return nil, nil, "http.request_async: header receive error: " .. tostring(rerr)
        end
    end

    -- Parse status code.
    local status_code = tonumber(buf:match("^HTTP/%d+%.%d+ (%d+)"))
    if not status_code then
        sock:close()
        return nil, nil, "http.request_async: invalid HTTP response"
    end

    -- Split headers from body prefix.
    local hdr_end = buf:find(CRLF2, 1, true)
    local raw_hdrs = buf:sub(1, hdr_end - 1)
    local body_buf = buf:sub(hdr_end + 4)

    -- Determine transfer encoding and expected body length.
    local content_length = tonumber(raw_hdrs:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
    local is_chunked = raw_hdrs:lower():find("transfer%-encoding:%s*chunked") ~= nil

    -- Read remaining raw bytes (shared by both chunked and identity paths).
    while true do
        if content_length and #body_buf >= content_length then break end
        local want = content_length
            and math.min(4096, content_length - #body_buf)
            or  4096
        local chunk, rerr, partial = sock:receive(want)
        if chunk then
            body_buf = body_buf .. chunk
        elseif rerr == "timeout" then
            if partial and #partial > 0 then body_buf = body_buf .. partial end
            wait_fn(sock, "read")
        elseif rerr == "closed" then
            if partial and #partial > 0 then body_buf = body_buf .. partial end
            break  -- server closed cleanly (no Content-Length)
        else
            sock:close()
            return nil, nil, "http.request_async: body receive error: " .. tostring(rerr)
        end
    end

    sock:close()

    -- Decode chunked transfer encoding if required.
    -- Format: <hex-size>\r\n<data>\r\n ... 0\r\n\r\n
    if is_chunked then
        local decoded = {}
        local pos = 1
        while pos <= #body_buf do
            -- Read chunk size line (hex digits, optional extensions before \r\n).
            local size_end = body_buf:find("\r\n", pos, true)
            if not size_end then break end
            local size_str = body_buf:sub(pos, size_end - 1):match("^([0-9a-fA-F]+)")
            local chunk_size = tonumber(size_str, 16)
            if not chunk_size then break end
            if chunk_size == 0 then break end  -- terminal chunk
            pos = size_end + 2
            decoded[#decoded + 1] = body_buf:sub(pos, pos + chunk_size - 1)
            pos = pos + chunk_size + 2  -- skip trailing \r\n
        end
        body_buf = table.concat(decoded)
    end

    return status_code, body_buf, nil
end

--- Make an HTTP/HTTPS request.
-- @param url   string  Full URL including scheme
-- @param opts  table   { method, headers, body, timeout_ms }
-- @return number|nil  HTTP status code
-- @return string|nil  Response body
-- @return string|nil  Error message
function M.request(url, opts)
    opts = opts or {}

    -- Prefer resty.http when available (OpenResty / non-blocking).
    local resty_fn = try_resty(url, opts)
    if resty_fn then
        return resty_fn()
    end

    -- Fall back to luasocket / luasec.
    return try_socket(url, opts)
end

return M
