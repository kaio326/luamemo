-- eval/tests/test_http_tls.lua
-- luamemo.http: redirects and HTTPS verification.
--   A. Redirects are never followed (a 3xx comes back; its target is never
--      contacted — it would get the request's headers without any check).
--   B. Certificate ↔ host matching (RFC 6125): exact / case / trailing dot,
--      one left-most wildcard label, IP addresses only against IP entries, the
--      subject CN only when the certificate lists no DNS names.
--   B2. One transport: a resty.http on the module path is never used.
--   C. End to end against `openssl s_server` (needs luasec + the openssl CLI,
--      skipped otherwise): an unknown CA is refused with the fix named;
--      MEMO_CA_FILE trusts a private CA IN ADDITION to the system's
--      (SSL_CERT_FILE); a certificate for another name is refused; a CN-only
--      self-signed certificate works via MEMO_CA_FILE; no CA anywhere → https
--      refuses and says what to set; an unreadable MEMO_CA_FILE is named.
-- No DB. Run: luajit eval/tests/run.lua --only http_tls

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("HTTP TLS")
local check, section = T.check, T.section
local sh, slurp = H.sh, H.slurp
local lua_bin = H.lua_bin()
local http = require("luamemo.http")

local TMP = os.tmpname(); os.remove(TMP)
os.execute(("mkdir -p %q"):format(TMP))

-- ---------------------------------------------------------------------------
section("A redirects", function()
io.write("\n--- A: redirects are not followed ---\n")
local ports, hit = TMP .. "/ports", TMP .. "/hit"
local server = ([[
local socket = require("socket")
local A = assert(socket.bind("127.0.0.1", 0)); local B = assert(socket.bind("127.0.0.1", 0))
local _, pa = A:getsockname(); local _, pb = B:getsockname()
local f = assert(io.open(%q, "w")); f:write(pa, " ", pb); f:close()
local deadline = socket.gettime() + 10
while socket.gettime() < deadline do
    for _, s in ipairs(socket.select({ A, B }, nil, 0.5) or {}) do
        local c = s:accept()
        if c then
            c:settimeout(3)
            repeat local l = c:receive("*l") until not l or l == ""
            if s == A then
                c:send(("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:%%d/secret\r\nContent-Length: 0\r\n\r\n"):format(pb))
            else
                local h = assert(io.open(%q, "w")); h:write("hit"); h:close()
                c:send("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            end
            c:close()
        end
    end
end
]]):format(ports, hit)
local sf = TMP .. "/redirect_server.lua"
local f = assert(io.open(sf, "w")); f:write(server); f:close()
os.execute(("%s %q >/dev/null 2>&1 &"):format(lua_bin, sf))
local pa
for _ = 1, 50 do
    pa = tonumber((slurp(ports) or ""):match("^(%d+)"))
    if pa then break end
    os.execute("sleep 0.1")
end
check("redirect test server started", pa ~= nil)
if not pa then return end
for _, m in ipairs({ "GET", "HEAD" }) do
    local st = http.request("http://127.0.0.1:" .. pa .. "/start", { method = m, timeout_ms = 3000,
        headers = { Authorization = "Bearer x" } })
    check(m .. ": the 302 comes back as the status", st == 302, st)
end
os.execute("sleep 0.2")
check("… and its target is never contacted", slurp(hit) == nil)
end)

-- ---------------------------------------------------------------------------
section("B host matching", function()
io.write("\n--- B: certificate names vs the URL host ---\n")
local function cert(dns, ips, cn)
    return {
        extensions = function() return (dns or ips) and { ["2.5.29.17"] = { dNSName = dns, iPAddress = ips } } or {} end,
        subject = function() return cn and { { oid = "2.5.4.3", name = "commonName", value = cn } } or {} end,
    }
end
local m = http._cert_names_host
local cases = {
    { cert({ "api.example.com" }), "api.example.com", true },
    { cert({ "API.Example.com" }), "api.example.COM", true },
    { cert({ "api.example.com." }), "api.example.com", true },
    { cert({ "api.example.com" }), "api.example.com.", true },
    { cert({ "api.example.com" }), "evil.com", false },
    { cert({ "api.example.com" }), "xapi.example.com", false },
    { cert({ "*.example.com" }), "a.example.com", true },
    { cert({ "*.example.com" }), "example.com", false },
    { cert({ "*.example.com" }), "a.b.example.com", false },
    { cert({ "*.com" }), "example.com", false },
    { cert({ "a*.example.com" }), "ab.example.com", false },
    { cert(nil, { "127.0.0.1" }), "127.0.0.1", true },
    { cert(nil, { "127.0.0.1" }), "127.0.0.2", false },
    { cert({ "127.0.0.1" }), "127.0.0.1", false },                  -- an IP only matches an IP entry
    { cert(nil, { "0:0:0:0:0:0:0:1" }), "::1", true },
    { cert(nil, { "::1" }), "[::1]", true },
    { cert(nil, nil, "localhost"), "localhost", true },            -- CN fallback: no DNS names at all
    { cert({ "other.test" }, nil, "localhost"), "localhost", false }, -- DNS names present → CN ignored
    { cert(nil, nil, "127.0.0.1"), "127.0.0.1", false },           -- CN never matches an IP
}
local bad = {}
for i, c in ipairs(cases) do
    if (m(c[1], c[2]) == true) ~= c[3] then bad[#bad + 1] = i .. ":" .. c[2] end
end
check("matching rules (" .. #cases .. " cases)", #bad == 0, table.concat(bad, " "))
local _, names = m(cert({ "a.test", "b.test" }, { "10.0.0.1" }), "c.test")
check("a mismatch names what the certificate does list", names == "10.0.0.1, a.test, b.test", names)
local _, cn_names = m(cert(nil, nil, "not-the-host.invalid"), "127.0.0.1")
check("… including a CN for an IP host", cn_names == "not-the-host.invalid", cn_names)
end)

-- ---------------------------------------------------------------------------
section("B2 one transport", function()
io.write("\n--- B2: a resty.http on the module path is never used (luasocket only) ---\n")
local called = false
package.loaded["resty.http"] = { new = function() called = true; error("resty.http must not be used") end }
local st, _, err = http.request("http://127.0.0.1:1/x", { timeout_ms = 1000 })
check("http.request ignores resty.http", not called)
check("… and goes through luasocket (closed port → connection error)", st == nil and err ~= nil, err)
package.loaded["resty.http"] = nil
end)

-- ---------------------------------------------------------------------------
section("C tls end to end", function()
io.write("\n--- C: HTTPS against openssl s_server ---\n")
if not pcall(require, "ssl") then io.write("[INFO] luasec not available on this interpreter — skipped\n"); return end
if not (sh("command -v openssl")):find("openssl", 1, true) then io.write("[INFO] no openssl CLI — skipped\n"); return end
local D = TMP .. "/pki"
os.execute(("mkdir -p %q"):format(D))
local function ossl(args) return select(2, sh(("cd %q && openssl %s"):format(D, args))) == 0 end
local function issue(ca, name, san)
    return ossl(("req -newkey rsa:2048 -nodes -keyout %s.key -out %s.csr -subj /CN=%s"):format(name, name, name))
        and (function()
            local e = assert(io.open(D .. "/" .. name .. ".ext", "w")); e:write("subjectAltName=" .. san .. "\n"); e:close()
            return true
        end)()
        and ossl(("x509 -req -in %s.csr -CA %s.pem -CAkey %s.key -CAcreateserial -out %s.pem -days 2 -extfile %s.ext")
            :format(name, ca, ca, name, name))
end
local made = ossl("req -x509 -newkey rsa:2048 -nodes -keyout ca1.key -out ca1.pem -days 2 -subj /CN=luamemo-test-CA1")
    and ossl("req -x509 -newkey rsa:2048 -nodes -keyout ca2.key -out ca2.pem -days 2 -subj /CN=luamemo-test-CA2")
    and issue("ca1", "srv1", "DNS:localhost,IP:127.0.0.1")
    and issue("ca2", "srv2", "DNS:localhost")
    and ossl("req -x509 -newkey rsa:2048 -nodes -keyout self.key -out self.pem -days 2 -subj /CN=localhost")
check("test certificates generated", made)
if not made then return end
local function serve(name)
    local port = 20000 + math.random(0, 20000)
    os.execute(("timeout 120 openssl s_server -accept 127.0.0.1:%d -cert %q -key %q -www >/dev/null 2>&1 &")
        :format(port, D .. "/" .. name .. ".pem", D .. "/" .. name .. ".key"))
    return port
end
math.randomseed(os.time())
local p1, p2, p3 = serve("srv1"), serve("srv2"), serve("self")
os.execute("sleep 1")
-- Each request in a fresh process: the trust settings are environment variables.
local function get(url, envs, pre)
    local code = ("package.path='./?.lua;./?/init.lua;'..package.path; %s "
        .. "local st, _, err = require('luamemo.http').request(%q, { timeout_ms = 5000 }); "
        .. "io.write(tostring(st), ' ', tostring(err))"):format(pre or "", url)
    return (sh(("env -u SSL_CERT_FILE -u SSL_CERT_DIR -u MEMO_CA_FILE %s %s -e %q"):format(envs or "", lua_bin, code)))
end
local u1, u2, u3 = "https://localhost:" .. p1 .. "/", "https://localhost:" .. p2 .. "/", "https://localhost:" .. p3 .. "/"
local ca1 = ("MEMO_CA_FILE=%q"):format(D .. "/ca1.pem")
local r = get(u1)
check("a private CA is not trusted by default — refused, naming the fix", r:find("^nil ")
    and r:find("not trusted", 1, true) and r:find("MEMO_CA_FILE", 1, true), r)
r = get(u1, ca1)
check("MEMO_CA_FILE → trusted (by name)", r:find("^200 ") ~= nil, r)
r = get("https://127.0.0.1:" .. p1 .. "/", ca1)
check("… and by IP address (IP entry in the certificate)", r:find("^200 ") ~= nil, r)
r = get("https://127.1:" .. p1 .. "/", ca1)
check("a certificate for other names is refused, listing them", r:find("^nil ")
    and r:find("certificate is for 127.0.0.1, localhost, not 127.1", 1, true), r)
local both = ca1 .. (" SSL_CERT_FILE=%q"):format(D .. "/ca2.pem")
local b1, b2 = get(u1, both), get(u2, both)
check("MEMO_CA_FILE is trusted IN ADDITION to the system CAs (SSL_CERT_FILE)",
    b1:find("^200 ") and b2:find("^200 "), b1 .. " | " .. b2)
r = get(u2, ca1)
check("a CA that is in neither is still refused", r:find("^nil ") and r:find("not trusted", 1, true), r)
r = get(u3, ("MEMO_CA_FILE=%q"):format(D .. "/self.pem"))
check("a self-signed, CN-only certificate works through MEMO_CA_FILE", r:find("^200 ") ~= nil, r)
r = get(u1, nil, "require('luamemo.http')._ca_files = {};")
check("no CA anywhere → https refuses and says what to set", r:find("^nil ")
    and r:find("no trusted CA certificates", 1, true) and r:find("SSL_CERT_FILE", 1, true)
    and r:find("MEMO_CA_FILE", 1, true), r)
r = get(u1, ("MEMO_CA_FILE=%q"):format(D .. "/missing.pem"))
check("an unreadable MEMO_CA_FILE is named", r:find("MEMO_CA_FILE=" .. D .. "/missing.pem can't be read", 1, true), r)
r = get(u1, ("MEMO_CA_FILE=%q"):format(D .. "/srv1.ext"))
check("a MEMO_CA_FILE without a PEM certificate is named (not silently ignored)",
    r:find("holds no PEM certificate", 1, true) ~= nil, r)
end)

os.execute(("rm -rf %q"):format(TMP))
T.finish()
