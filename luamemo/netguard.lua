-- luamemo/netguard.lua
-- IP address classification shared by the two network policies luamemo has:
--
--   * federation is LOCAL-NETWORK ONLY — the central binds / accepts and the
--     dev connects only over loopback, private LAN ranges, and VPN overlays
--     such as Tailscale (CGNAT 100.64.0.0/10, IPv6 ULA fd7a:115c:a1e0::/48);
--   * secrets.execute_with_secret is the opposite — egress to PUBLIC hosts
--     only (SSRF guard).
--
--   netguard.classify(ip)      → "loopback" | "private" | "cgnat" | "ula" |
--                                "link-local" | "unspecified" | "multicast" |
--                                "reserved" | "public" | nil (not an IP)
--   netguard.is_local(ip)      → loopback / private / cgnat / ula / link-local
--   netguard.is_public(ip)     → a globally routable unicast address
--   netguard.resolve(host)     → { ip, … } | nil, err   (literals pass through)
--   netguard.parse_url(url)    → scheme, host, port, path | nil  (no userinfo)
--   netguard.host_is_local(host)  → true | false, reason  (ALL addresses local)
--   netguard.host_is_public(host) → true | false, reason  (ALL addresses public)

local M = {}

local floor = math.floor

-- Canonical dotted decimal only. A leading zero is NOT decimal to the C
-- resolver luasocket connects through (inet_aton reads "0177" as octal 127,
-- "010" as 8), so such text is no literal here: it goes through resolve(),
-- which returns the address the connection would really use.
local function parse_v4(s)
    local p = { tostring(s):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
    if #p ~= 4 then return nil end
    local q = {}
    for i = 1, 4 do
        if #p[i] > 1 and p[i]:sub(1, 1) == "0" then return nil end
        q[i] = tonumber(p[i])
        if q[i] > 255 then return nil end
    end
    return q
end

-- IPv6 text → 8 × 16-bit groups (handles "::", an embedded IPv4 tail,
-- brackets and a %zone suffix). nil when malformed.
local function parse_v6(s)
    s = tostring(s):gsub("^%[", ""):gsub("%]$", ""):gsub("%%.*$", "")
    if not s:find(":", 1, true) or s:find(":::", 1, true) then return nil end
    local head, v4 = s:match("^(.*:)(%d+%.%d+%.%d+%.%d+)$")
    if v4 then
        local q = parse_v4(v4)
        if not q then return nil end
        s = head .. ("%x:%x"):format(q[1] * 256 + q[2], q[3] * 256 + q[4])
    end
    local function split(part, out)
        if part == "" then return true end
        if part:sub(1, 1) == ":" or part:sub(-1) == ":" then return false end
        for g in (part .. ":"):gmatch("([^:]*):") do
            if not g:match("^%x%x?%x?%x?$") then return false end
            out[#out + 1] = tonumber(g, 16)
        end
        return true
    end
    local groups = {}
    local left, right = s:match("^(.-)::(.*)$")
    if left then
        if right:find("::", 1, true) then return nil end
        local l, r = {}, {}
        if not split(left, l) or not split(right, r) then return nil end
        local fill = 8 - #l - #r
        if fill < 1 then return nil end
        for _, v in ipairs(l) do groups[#groups + 1] = v end
        for _ = 1, fill do groups[#groups + 1] = 0 end
        for _, v in ipairs(r) do groups[#groups + 1] = v end
    else
        if not split(s, groups) or #groups ~= 8 then return nil end
    end
    return groups
end

local function classify_v4(q)
    local a, b = q[1], q[2]
    if a == 127 then return "loopback" end
    if a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168) then return "private" end
    if a == 100 and b >= 64 and b <= 127 then return "cgnat" end          -- 100.64.0.0/10 (Tailscale)
    if a == 169 and b == 254 then return "link-local" end
    if a == 0 then return "unspecified" end
    if a >= 224 and a <= 239 then return "multicast" end
    if a >= 240 then return "reserved" end
    if (a == 192 and b == 0 and q[3] == 0) or (a == 198 and (b == 18 or b == 19)) then return "reserved" end
    return "public"
end

local function classify_v6(g)
    local zero = true
    for i = 1, 7 do if g[i] ~= 0 then zero = false; break end end
    if zero and g[8] == 1 then return "loopback" end
    if zero and g[8] == 0 then return "unspecified" end
    local function v4(hi, lo) return { floor(hi / 256), hi % 256, floor(lo / 256), lo % 256 } end
    -- IPv4-mapped (::ffff:a.b.c.d): classify the IPv4 address.
    if g[1] == 0 and g[2] == 0 and g[3] == 0 and g[4] == 0 and g[5] == 0 and g[6] == 0xffff then
        return classify_v4(v4(g[7], g[8]))
    end
    -- Forms that carry an IPv4 address to a translator — IPv4-compatible
    -- (::a.b.c.d), NAT64 (64:ff9b::/96, local-use 64:ff9b:1::/48), 6to4
    -- (2002:AABB:CCDD::/16): public only when the embedded address is; a
    -- non-public one is neither public nor local (it goes through a gateway).
    local embedded
    if g[1] == 0 and g[2] == 0 and g[3] == 0 and g[4] == 0 and g[5] == 0 and g[6] == 0 then
        embedded = v4(g[7], g[8])
    elseif g[1] == 0x64 and g[2] == 0xff9b and (g[3] == 0 or g[3] == 1) then
        embedded = v4(g[7], g[8])
    elseif g[1] == 0x2002 then
        embedded = v4(g[2], g[3])
    end
    if embedded then
        return classify_v4(embedded) == "public" and "public" or "reserved"
    end
    if floor(g[1] / 512) == 0x7e then return "ula" end            -- fc00::/7 (Tailscale fd7a:115c:a1e0::/48)
    if floor(g[1] / 64) == 0x3fa then return "link-local" end     -- fe80::/10
    if floor(g[1] / 64) == 0x3fb then return "reserved" end       -- fec0::/10 (deprecated site-local)
    if floor(g[1] / 256) == 0xff then return "multicast" end      -- ff00::/8
    return "public"
end

function M.classify(ip)
    if type(ip) ~= "string" then return nil end
    local q = parse_v4(ip)
    if q then return classify_v4(q) end
    local g = parse_v6(ip)
    if g then return classify_v6(g) end
    return nil
end

M.LOCAL = { loopback = true, private = true, cgnat = true, ula = true, ["link-local"] = true }

function M.is_ip(s) return M.classify(s) ~= nil end
function M.is_local(ip) return M.LOCAL[M.classify(ip) or ""] == true end
function M.is_public(ip) return M.classify(ip) == "public" end

--- All addresses of `host` (IPv4 and IPv6). Literal IPs are returned as-is.
function M.resolve(host)
    if type(host) ~= "string" or host == "" then return nil, "empty host" end
    host = host:gsub("^%[", ""):gsub("%]$", "")
    if M.is_ip(host) then return { host } end
    local ok, socket = pcall(require, "socket")
    if not ok then return nil, "luasocket unavailable" end
    local out, seen = {}, {}
    local infos = socket.dns.getaddrinfo and socket.dns.getaddrinfo(host)
    for _, a in ipairs(infos or {}) do
        if a.addr and not seen[a.addr] then seen[a.addr] = true; out[#out + 1] = a.addr end
    end
    if #out == 0 then
        local ip, info = socket.dns.toip(host)
        for _, a in ipairs(type(info) == "table" and info.ip or { ip }) do
            if a and not seen[a] then seen[a] = true; out[#out + 1] = a end
        end
    end
    if #out == 0 then return nil, "cannot resolve " .. host end
    return out
end

--- http(s)://host[:port][/path] | http(s)://[v6][:port][/path] → scheme, host,
--- port ("" when absent), path | nil. Strict, and split the way luasocket splits
--- it (the authority runs to the first "/"), so the host a policy checks is the
--- host the request connects to: userinfo ("x:y@host") is refused.
function M.parse_url(url)
    local scheme, rest = tostring(url):match("^(https?)://(.*)$")
    if not scheme then return nil end
    local authority, path = rest:match("^([^/]*)(.*)$")
    if authority:find("@", 1, true) then return nil end
    local host, port
    if authority:sub(1, 1) == "[" then
        host, port = authority:match("^%[([^%]]+)%]:?(%d*)$")
    else
        host, port = authority:match("^([^:]+):?(%d*)$")
    end
    if not host then return nil end
    return scheme, host, port, path
end

local function all(host, pred, what)
    local ips, err = M.resolve(host)
    if not ips then return false, err end
    for _, ip in ipairs(ips) do
        if not pred(ip) then
            return false, ("%s resolves to %s (%s), not %s"):format(host, ip, M.classify(ip) or "?", what), ips
        end
    end
    return true, nil, ips
end

--- Every address of `host` is local (loopback / LAN / VPN). Returns ok, reason, ips.
function M.host_is_local(host) return all(host, M.is_local, "a local-network address") end
--- Every address of `host` is public (SSRF guard). Returns ok, reason, ips.
function M.host_is_public(host) return all(host, M.is_public, "a public address") end

M._parse_v6 = parse_v6

return M
