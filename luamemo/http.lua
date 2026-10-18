-- luamemo.http
-- HTTP client: luasocket's socket.http; HTTPS through luasec (required for
-- https:// URLs).
--
-- Every https:// server is VERIFIED: its certificate chain against the
-- system's CA bundle (SSL_CERT_FILE / SSL_CERT_DIR, else the usual OS
-- locations) plus MEMO_CA_FILE (a self-hosted server's CA or self-signed
-- certificate), and the certificate against the URL's host. No CA found →
-- https refuses, saying what to set. Redirects are never followed (a redirect
-- would take the request — and its headers — to a host the caller never
-- checked); the 3xx status is returned.
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
-- TLS for socket.http (luasec). luasec's own ssl.https does not verify
-- anything by default, and even with verify = "peer" it never checks the
-- certificate against the host — so the connection is made here.
-- ---------------------------------------------------------------------------
M._ca_files = {                                          -- first readable one wins
    "/etc/ssl/certs/ca-certificates.crt",                -- Debian / Ubuntu / Alpine / Arch / Gentoo
    "/etc/pki/tls/certs/ca-bundle.crt",                  -- Fedora / RHEL
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", -- RHEL / CentOS 7+
    "/etc/ssl/ca-bundle.pem",                            -- openSUSE
    "/etc/pki/tls/cacert.pem",
    "/etc/ssl/cert.pem",                                 -- macOS / Alpine / BSD
    "/usr/local/etc/ssl/cert.pem",                       -- FreeBSD
    "/opt/homebrew/etc/openssl@3/cert.pem",              -- macOS Homebrew
    "/usr/local/etc/openssl@3/cert.pem",
}

local NO_CA = "https: no trusted CA certificates found on this machine — luamemo verifies every "
    .. "https server and does not connect unverified. To fix: set SSL_CERT_FILE to your system's CA "
    .. "bundle (a PEM file — install your OS's ca-certificates package, or download "
    .. "https://curl.se/ca/cacert.pem); for a self-hosted server with its own CA or a self-signed "
    .. "certificate, set MEMO_CA_FILE to that certificate (PEM)."

local env, read_file = require("luamemo.util").env, require("luamemo.util").read_file

local _tls_ctx = {}   -- trust configuration → luasec context (OpenSSL loads the CAs once)
local _os_bundle      -- the OS bundle found (false: none), looked up once

local function os_bundle()
    if _os_bundle == nil then
        _os_bundle = false
        for _, p in ipairs(M._ca_files) do
            local f = io.open(p, "rb")
            if f then f:close(); _os_bundle = p; break end
        end
    end
    return _os_bundle or nil
end

--- The client TLS context for the current trust configuration | nil, err.
local function tls_context(ssl)
    local extra, sys_file, sys_dir = env("MEMO_CA_FILE"), env("SSL_CERT_FILE"), env("SSL_CERT_DIR")
    local from_env = sys_file
    if not sys_file and not sys_dir then sys_file = os_bundle() end
    local key = table.concat({ tostring(sys_file), tostring(sys_dir), tostring(extra) }, "\0")
    if _tls_ctx[key] then return _tls_ctx[key] end

    -- Building a context: check what it will read first (clear errors, not OpenSSL's).
    if from_env then
        local f = io.open(from_env, "rb")
        if not f then
            return nil, "https: SSL_CERT_FILE=" .. from_env .. " can't be read — point it at a PEM CA bundle, "
                .. "or unset it to use the system's"
        end
        f:close()
    end
    if extra then
        local pem = read_file(extra)
        if not pem then
            return nil, "https: MEMO_CA_FILE=" .. extra .. " can't be read — point it at the PEM certificate "
                .. "(or CA) of the server you want to trust"
        end
        -- (OpenSSL would silently skip a file without a certificate in it)
        if not pem:find("-----BEGIN CERTIFICATE-----", 1, true) then
            return nil, "https: MEMO_CA_FILE=" .. extra .. " holds no PEM certificate (\"-----BEGIN CERTIFICATE-----\""
                .. " … ) — export the server's certificate or CA in PEM format"
        end
    end
    if not (sys_file or sys_dir or extra) then return nil, NO_CA end

    -- MEMO_CA_FILE is trusted IN ADDITION to the system's CAs: one bundle file,
    -- read by OpenSSL when the context is made, then removed.
    local cafile, tmp = sys_file or extra, nil
    if extra and sys_file then
        tmp = os.tmpname()
        local out = io.open(tmp, "wb")
        if not out then
            os.remove(tmp)
            return nil, "https: cannot write a temporary CA bundle (" .. tmp .. ")"
        end
        out:write(read_file(sys_file), "\n", read_file(extra), "\n")
        out:close()
        cafile = tmp
    end
    -- TLS 1.2 or newer (1.0 and 1.1 are deprecated — RFC 8996); a luasec built without the
    -- 1.1 switch gets the rest (its OpenSSL then predates 1.1 anyway).
    local function context(opts)
        return ssl.newcontext({ mode = "client", protocol = "any", verify = "peer", options = opts,
            cafile = cafile, capath = sys_dir })
    end
    local ctx, err = context({ "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" })
    if not ctx and tostring(err):find("no_tlsv1_1", 1, true) then
        ctx, err = context({ "all", "no_sslv2", "no_sslv3", "no_tlsv1" })
    end
    if tmp then os.remove(tmp) end
    if not ctx then
        return nil, "https: cannot load the trusted CA certificates (" .. tostring(err)
            .. ") — check SSL_CERT_FILE / SSL_CERT_DIR / MEMO_CA_FILE"
    end
    _tls_ctx[key] = ctx
    return ctx
end

-- IP text → comparable form (IPv6 groups expanded), nil when not an IP.
local function ip_key(s)
    local ng = require("luamemo.netguard")
    s = tostring(s or ""):gsub("^%[", ""):gsub("%]$", "")
    if not ng.is_ip(s) then return nil end
    local g = s:find(":", 1, true) and ng._parse_v6(s)
    if not g then return s end
    local parts = {}
    for i = 1, 8 do parts[i] = ("%x"):format(g[i]) end
    return table.concat(parts, ":")
end

-- RFC 6125: exact name, or one left-most wildcard label ("*.example.com"
-- matches "a.example.com", not "example.com" nor "a.b.example.com").
local function dns_match(pattern, host)
    pattern = tostring(pattern or ""):lower():gsub("%.$", "")
    if pattern == host then return true end
    local rest = pattern:match("^%*%.([^*]+%.[^*]+)$")
    return rest ~= nil and host:match("^[^.]+%.(.+)$") == rest
end

--- Does the certificate name `host`? → true | false, "the names it has".
local function cert_names_host(cert, host)
    host = tostring(host):lower():gsub("%.$", "")
    local ext = cert:extensions() or {}
    local san = ext["2.5.29.17"] or {}
    local want_ip = ip_key(host)
    local names = {}
    for _, ip in ipairs(san.iPAddress or {}) do
        names[#names + 1] = ip
        if want_ip and ip_key(ip) == want_ip then return true end
    end
    local dns = san.dNSName or {}
    for _, n in ipairs(dns) do
        names[#names + 1] = n
        if not want_ip and dns_match(n, host) then return true end
    end
    -- No DNS names in the certificate: its subject CN (OpenSSL's fallback; a
    -- host name only — an IP must be listed as an IP address).
    if #dns == 0 then
        for _, e in ipairs(cert:subject() or {}) do
            if e.oid == "2.5.4.3" or e.name == "commonName" or e.name == "CN" then
                names[#names + 1] = e.value
                if not want_ip and dns_match(e.value, host) then return true end
            end
        end
    end
    return false, (#names > 0 and table.concat(names, ", ") or "no name at all")
end

--- A socket.http `create` function whose connections are TLS, verified.
local function tls_create(ssl)
    local socket = require("socket")
    return function()
        local ctx, cerr = tls_context(ssl)
        if not ctx then return nil, cerr end
        local conn = { sock = socket.tcp(), t = nil }
        function conn:settimeout(t) self.t = t; return self.sock:settimeout(t) end
        function conn:close() return self.sock:close() end   -- socket.http closes on a failed connect
        function conn:connect(host, port)
            local ok, err = self.sock:connect(host, port)
            if not ok then return nil, err end
            local s, werr = ssl.wrap(self.sock, ctx)
            if not s then return nil, "https: " .. tostring(werr) end
            self.sock = s
            s:settimeout(self.t)
            if not ip_key(host) then s:sni(host) end
            local hok, herr = s:dohandshake()
            if not hok then
                s:close()
                if tostring(herr):find("verify failed", 1, true) then
                    return nil, ("https: %s's certificate is not trusted (%s) — for a self-hosted server with its "
                        .. "own CA or a self-signed certificate, set MEMO_CA_FILE to that certificate (PEM)")
                        :format(host, tostring(herr))
                end
                return nil, "https: TLS handshake with " .. host .. " failed: " .. tostring(herr)
            end
            local named, has = cert_names_host(s:getpeercertificate(), host)
            if not named then
                s:close()
                return nil, ("https: %s's certificate is for %s, not %s — refusing (connect with a host name "
                    .. "the certificate lists)"):format(host, has, host)
            end
            -- Everything else socket.http calls goes to the TLS socket.
            for name, fn in pairs(getmetatable(s).__index) do
                if type(fn) == "function" and name ~= "connect" then
                    self[name] = function(me, ...) return fn(me.sock, ...) end
                end
            end
            return 1
        end
        return conn
    end
end

M._cert_names_host = cert_names_host   -- tests

-- ---------------------------------------------------------------------------
-- socket.http adapter  (plain Lua / luasocket; TLS via luasec)
-- ---------------------------------------------------------------------------
-- NOTE: This call BLOCKS the Lua thread for the full HTTP round-trip
-- (typically 10-2000 ms depending on the server and network). Use
-- luamemo.async + M.request_async() when concurrent HTTP fan-out is needed
-- (see store.write_many()).
local function try_socket(url, opts)
    local scheme = url:match("^([%w+%-%.]+)://")
    local is_https = (scheme == "https")

    pcall(require, "ltn12")
    local ok_http, http_mod = pcall(require, "socket.http")
    if not ok_http then
        return nil, nil,
            "http: socket.http unavailable. "
            .. "Install luasocket: luarocks install luasocket"
    end
    local create, req_url = nil, url
    if is_https then
        local ok, ssl = pcall(require, "ssl")
        if not ok then
            return nil, nil,
                "http: HTTPS request requires luasec (ssl.https). "
                .. "Install it with: luarocks install luasec"
        end
        create = tls_create(ssl)
        -- An explicit port: older luasocket defaults every scheme to 80.
        local surl = require("socket.url")
        req_url = surl.build(surl.parse(url, { port = 443 }))
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

    -- opts.max_bytes: keep at most that much of the body (the rest is read and
    -- dropped — memory stays bounded); the 4th result says it was cut.
    local chunks, kept, truncated = {}, 0, false
    local max = tonumber(opts.max_bytes)
    local sink = ltn12.sink.table(chunks)
    if max then
        sink = function(chunk)
            if chunk then
                local part = (kept < max) and chunk:sub(1, max - kept) or ""
                if #part < #chunk then truncated = true end
                if #part > 0 then chunks[#chunks + 1] = part; kept = kept + #part end
            end
            return 1
        end
    end
    local req = {
        url      = req_url,
        method   = (opts.method or "GET"):upper(),
        headers  = headers,
        sink     = sink,
        redirect = false,   -- never followed: see the header comment
        create   = create,  -- https: verified TLS (nil = plain TCP)
    }
    if req_body then
        req.source = ltn12.source.string(req_body)
    end

    -- NOTE: try_socket is not re-entrant-safe across coroutines — two concurrent
    -- calls interleaved at a yield point will interfere via http_mod.TIMEOUT.
    -- Plain Lua is single-threaded so this is safe in normal use; avoid calling
    -- try_socket concurrently from coroutines.

    -- The table form of socket.http.request returns
    -- (1, code, headers, status_line) on success and (nil, err) on a transport
    -- failure — the FIRST value is a success flag, the HTTP status is SECOND.
    -- (Reading the flag as the status made every response look like "1", so
    -- check_http's >= 300 test never fired: 404/500 bodies were parsed as data.)
    local ok_call, r1, r2 = pcall(http_mod.request, req)
    http_mod.TIMEOUT = prev_timeout  -- restore regardless of outcome or error
    -- Mask user:password@host credentials. Note: API keys passed as query
    -- parameters (e.g. ?api_key=...) are not masked — current adapters use
    -- Authorization headers instead, so this is intentionally not covered.
    local safe_url = require("luamemo.util").redact_url(url)
    if not ok_call then
        return nil, nil, "http: request error: " .. tostring(r1) .. " — " .. safe_url
    end
    if not r1 then
        -- Transport-level failure: r2 is the error ("timeout", "connection refused").
        return nil, nil, "http: " .. tostring(r2 or "request failed (network error)") .. " — " .. safe_url
    end
    local code = tonumber(r2)
    if not code then
        return nil, nil, "http: invalid status " .. tostring(r2) .. " — " .. safe_url
    end

    return code, table.concat(chunks), nil, truncated
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

    -- Parse URL into components. Supports both regular hosts and IPv6 bracket
    -- notation (e.g. http://[::1]:8080/path).
    local host, port_str, path
    -- IPv6: http://[<addr>]:<port><path>  or  http://[<addr>]<path>
    host, port_str, path = url:match("^https?://%[([^%]]+)%]:(%d+)(/[^%s]*)")
    if not host then
        host, path = url:match("^https?://%[([^%]]+)%](/[^%s]*)")
    end
    if not host then
        -- Regular hostname/IP: http://host:port/path  or  http://host/path
        host, port_str, path = url:match("^https?://([^/:?#]+):?(%d*)(/[^%s]*)")
    end
    if not host then
        -- Try without explicit path (IPv6 then regular).
        host, port_str = url:match("^https?://%[([^%]]+)%]:?(%d*)$")
        if not host then
            host, port_str = url:match("^https?://([^/:?#]+):?(%d*)$")
        end
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
    return try_socket(url, opts or {})
end

return M
