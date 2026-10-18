-- eval/tests/test_http.lua
-- luamemo.http (luasocket path) against a throwaway local HTTP server:
--   1. 200 → status is the real HTTP code (not luasocket's success flag "1")
--   2. 404 / 500 → real code, so util.check_http reports the HTTP error
--   3. POST body round-trips
--   4. max_bytes → the body cut at that size, and a 4th result saying so
--   5. connection refused → nil status + a transport error message
--
-- Needs luasocket (a luamemo dependency). No DB.
-- Run: luajit eval/tests/run.lua --only http

package.path = "./?/init.lua;./?.lua;" .. package.path

local http = require("luamemo.http")
local util = require("luamemo.util")

local PASS, FAIL = 0, 0
local function pass(m) PASS = PASS + 1; io.write("[PASS] " .. m .. "\n") end
local function fail(m) FAIL = FAIL + 1; io.write("[FAIL] " .. m .. "\n") end
local function eq(a, b, label)
    if a == b then pass(label) else fail(label .. " — got " .. tostring(a) .. " expected " .. tostring(b)) end
end

local q = require("luamemo.util").shell_quote

-- Background server: answers N requests by path (/ok → 200, /missing → 404,
-- /boom → 500, /echo → 200 with the request body), writes its port to a file.
local portfile = os.tmpname()
local server = [[
local socket = require("socket")
local srv = assert(socket.bind("127.0.0.1", 0))
local _, port = srv:getsockname()
local f = assert(io.open(PORTFILE, "w")); f:write(port); f:close()
srv:settimeout(10)
for _ = 1, 5 do
    local c = srv:accept()
    if not c then break end
    c:settimeout(5)
    local line = c:receive("*l") or ""
    local path = line:match("^%u+ (%S+)") or "/"
    local len = 0
    while true do
        local h = c:receive("*l")
        if not h or h == "" then break end
        local n = h:lower():match("^content%-length:%s*(%d+)")
        if n then len = tonumber(n) end
    end
    local body = len > 0 and c:receive(len) or ""
    local code, reason, out = 200, "OK", "ok"
    if path == "/missing" then code, reason, out = 404, "Not Found", "no such thing"
    elseif path == "/boom" then code, reason, out = 500, "Internal Server Error", "kaboom"
    elseif path == "/echo" then out = body
    elseif path == "/big" then out = ("z"):rep(100000) end
    c:send(("HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"):format(code, reason, #out, out))
    c:close()
end
]]
-- The interpreter is the lowest negative arg index (options like -e sit between).
local lua_bin = "luajit"
if arg then
    local i = -1
    while arg[i - 1] do i = i - 1 end
    lua_bin = arg[i] or lua_bin
end
-- (`lua -e CODE FILE` would run FILE as a script, so the port file path is
-- baked into the server source instead of passed as an argument.)
server = ("local PORTFILE = %q\n"):format(portfile) .. server
os.execute(("%s -e %s >/dev/null 2>&1 &"):format(lua_bin, q(server)))

local port
for _ = 1, 50 do
    local f = io.open(portfile, "r")
    local p = f and f:read("*a")
    if f then f:close() end
    if p and p ~= "" then port = tonumber(p); break end
    os.execute("sleep 0.1")
end
os.remove(portfile)
if not port then
    fail("test server did not start")
    io.write(("\n=== HTTP results: %d passed, %d failed ===\n"):format(PASS, FAIL))
    os.exit(1)
end
local base = "http://127.0.0.1:" .. port

io.write("\n--- luamemo.http status codes (luasocket path) ---\n")

local st, body = http.request(base .. "/ok", { method = "GET", timeout_ms = 3000 })
eq(st, 200, "GET /ok → status 200 (not luasocket's success flag)")
eq(body, "ok", "GET /ok → body")

local st404, body404 = http.request(base .. "/missing", { method = "GET", timeout_ms = 3000 })
eq(st404, 404, "GET /missing → status 404")
local ok404, err404 = util.check_http(st404, body404, nil, "test")
eq(ok404, nil, "check_http flags the 404")
if err404 and err404:find("HTTP 404", 1, true) then pass("check_http error names the status")
else fail("check_http error names the status — got " .. tostring(err404)) end

local st500 = http.request(base .. "/boom", { method = "GET", timeout_ms = 3000 })
eq(st500, 500, "GET /boom → status 500")

local stp, bodyp = http.request(base .. "/echo", {
    method = "POST", body = '{"x":1}', headers = { ["Content-Type"] = "application/json" }, timeout_ms = 3000 })
eq(stp, 200, "POST /echo → status 200")
eq(bodyp, '{"x":1}', "POST /echo → body round-trips")

local stb, bodyb, _, cut = http.request(base .. "/big", { method = "GET", timeout_ms = 3000, max_bytes = 1000 })
eq(stb, 200, "GET /big with max_bytes → status 200")
eq(#(bodyb or ""), 1000, "… the body is cut at max_bytes (the rest read and dropped)")
eq(cut, true, "… and the 4th result says it was cut")

io.write("\n--- transport failure ---\n")
-- The server has exited after 5 requests, so its port now refuses connections.
os.execute("sleep 0.2")
local stc, _, errc = http.request(base .. "/ok", { method = "GET", timeout_ms = 2000 })
eq(stc, nil, "closed port → nil status")
if errc and errc:find("refused", 1, true) then pass("closed port → error says 'refused'")
else fail("closed port → error says 'refused' — got " .. tostring(errc)) end

io.write(("\n=== HTTP results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
