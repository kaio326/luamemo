-- Minimal `resty.http` shim for plain `lua5.1` eval harnesses.
-- Wraps LuaSocket (`socket.http`) and LuaSec (`ssl.https`) to expose just
-- enough of the lua-resty-http surface that `lapis_memory.embed.http_embed`
-- needs:
--
--     local httpc = require("resty.http").new()
--     httpc:set_timeout(ms)
--     local res, err = httpc:request_uri(url, { method=, body=, headers= })
--     -- res = { status, body }
--
-- NOT a general-purpose port; only what the eval scripts exercise. NOT
-- safe for production. Only loaded by eval/* scripts that explicitly
-- preload it into `package.preload["resty.http"]`.

local http  = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local has_https, https = pcall(require, "ssl.https")

local M = {}
M.__index = M

function M.new()
    return setmetatable({ timeout = 5 }, M)
end

function M:set_timeout(ms)
    self.timeout = (tonumber(ms) or 5000) / 1000
end

function M:request_uri(url, opts)
    opts = opts or {}
    local resp_chunks = {}
    local request = {
        url      = url,
        method   = opts.method or "GET",
        source   = opts.body and ltn12.source.string(opts.body) or nil,
        sink     = ltn12.sink.table(resp_chunks),
        headers  = opts.headers or {},
    }
    if opts.body then
        request.headers["content-length"] = tostring(#opts.body)
    end

    local backend = http
    if url:sub(1, 8) == "https://" then
        if not has_https then return nil, "https requested but ssl.https unavailable" end
        backend = https
    end

    -- LuaSocket has no per-call timeout knob via the high-level API; set the
    -- module-level default before the call. Best-effort.
    if backend == http then http.TIMEOUT = self.timeout
    elseif backend == https then https.TIMEOUT = self.timeout end

    local ok, code, headers, status_line = backend.request(request)
    if not ok then return nil, tostring(code) end

    return {
        status  = tonumber(code) or 0,
        headers = headers or {},
        body    = table.concat(resp_chunks),
    }
end

return M
