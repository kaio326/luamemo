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
    -- socket.http and ssl.https both accept a settimeout via the socket object;
    -- the simplest cross-version approach is create + configure manually.
    -- For the table-form request, timeout is set on the socket created by the
    -- module via the `create` field.
    local socket = require("socket")
    local function create()
        local sock = socket.tcp()
        sock:settimeout(timeout_s)
        return sock
    end

    local chunks = {}
    local req = {
        url    = url,
        method = (opts.method or "GET"):upper(),
        headers = headers,
        sink   = ltn12.sink.table(chunks),
        create = create,
    }
    if req_body then
        req.source = ltn12.source.string(req_body)
    end

    local _, code, _resp_headers, _status = http_mod.request(req)
    if not code then
        return nil, nil, "http: request failed (network error)"
    end
    if type(code) ~= "number" then
        -- socket.http returns the error string as the second return when it
        -- fails at the transport level (e.g. connection refused).
        return nil, nil, "http: " .. tostring(code)
    end

    return code, table.concat(chunks), nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

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
