-- luamemo.federation.handlers
-- The org central's federation endpoints, served by `memo serve`
-- (luamemo.federation.server) on the local network only.
--
--   handlers.handle(req [, prefix]) → status, body (string), content_type
--     req = { method, path, headers = { lower-case keys }, query, body = "<raw>" }
--
-- Endpoints (served only when role = "org"):
--   GET  <prefix>/key    — public: the central's identity key, fingerprint, org
--   POST <prefix>/pair   — a device asks to be paired (signed by its key)
--   POST <prefix>/hello  — channel handshake (the device key must be APPROVED)
--   POST <prefix>/call   — encrypted RPC inside a session (binary envelope):
--                          info · snapshot · feedback · proposals
--
-- No bearer tokens: a device is its Ed25519 key, approved by the org admin
-- (luamemo.federation.devs); every call after the handshake is encrypted and
-- authenticated both ways (luamemo.federation.channel). Feedback is attributed
-- to the identity the approved key was paired as.

local json     = require("luamemo.json")
local common   = require("luamemo.federation.common")
local policy   = require("luamemo.federation.policy")
local central  = require("luamemo.federation.central")
local channel  = require("luamemo.federation.channel")
local keys     = require("luamemo.federation.keys")
local devs     = require("luamemo.federation.devs")
local sessions = require("luamemo.federation.sessions")

local M = {}

M.DEFAULT_PREFIX = "/federation"
M.MAX_BODY = 8 * 1024 * 1024           -- an encrypted snapshot page / feedback batch
M.MAX_JSON = 64 * 1024                 -- pairing / handshake messages
M.PAIR_PER_MINUTE = 10                 -- /pair requests per address (IPv6: per /64) per minute —
                                       -- it's open to unknown keys: bound its signature work
                                       -- without letting one machine starve the others

local _pair_rate, _pair_rate_n = {}, 0 -- address group → { n, since }
local function pair_throttled(from)
    local now, k = os.time(), from or "?"
    local r = _pair_rate[k]
    if not r or now - r.since >= 60 then
        if not r then
            if _pair_rate_n > 4096 then
                local keep, n = {}, 0
                for key, v in pairs(_pair_rate) do if now - v.since < 60 then keep[key] = v; n = n + 1 end end
                _pair_rate, _pair_rate_n = keep, n
            end
            _pair_rate_n = _pair_rate_n + 1
        end
        r = { n = 0, since = now }
        _pair_rate[k] = r
    end
    r.n = r.n + 1
    return r.n > M.PAIR_PER_MINUTE
end

-- /hello: a forged hello costs one HMAC (the hello key only the device can
-- derive — see channel), never signature work, and never counts against the
-- device: nothing an attacker sends can lock it out. Replay: a nonce from a
-- SUCCESSFUL handshake is remembered for twice the clock-skew window, so a
-- captured hello can't open another session (only authenticated hellos are
-- recorded, so garbage can't fill it).
local _seen, _seen_n = {}, 0             -- hello nonce (hex) → expiry
local function remember_nonce(nonce, now)
    if _seen_n > 4096 then
        local keep, n = {}, 0
        for k, exp in pairs(_seen) do if exp > now then keep[k] = exp; n = n + 1 end end
        _seen, _seen_n = keep, n
    end
    _seen[nonce] = now + 2 * channel.MAX_SKEW
    _seen_n = _seen_n + 1
end

function M._reset_throttle()   -- tests
    _pair_rate, _pair_rate_n, _seen, _seen_n = {}, 0, {}, 0
    keys._reset_hello()
end

local JSON_T, BIN_T = "application/json", "application/octet-stream"

local function reply(status, tbl) return status, json.encode(tbl or {}), JSON_T end

local function header(req, name)
    local v = req.headers and req.headers[name]
    if type(v) == "table" then v = v[#v] end
    return v
end

local function json_body(req)
    local ctype = (header(req, "content-type") or ""):lower()
    if not ctype:find("application/json", 1, true) then return nil, 415, "Content-Type must be application/json" end
    if #(req.body or "") > M.MAX_JSON then return nil, 413, "message too large" end
    local t = json.decode(req.body or "")
    if type(t) ~= "table" then return nil, 400, "invalid JSON body" end
    return t
end

-- The central's identity (created on first use; `memo calibrate --role org` does it up front).
local function identity()
    local pk, err = keys.ensure_identity("central")
    if not pk then error("central identity unavailable: " .. tostring(err), 0) end
    return pk
end
local function csign(msg) return assert(keys.sign("central", msg)) end

-- An approved device's hello key (only approved keys get here — the device lookup comes first).
local function device_hello_key(dev_pk) return (keys.hello_key("central", identity(), dev_pk)) end

-- ---------------------------------------------------------------------------
-- Encrypted RPC methods (plaintext JSON inside the channel)
-- ---------------------------------------------------------------------------
local RPC = {
    info = function() return central.info() end,
    snapshot = function(_, p)
        return central.snapshot({ since = p.since, limit = p.limit, ids = p.ids, vectors = p.vectors == true,
                                  manifest_digest = p.manifest_digest })
    end,
    feedback = function(dev, p)
        -- The identity comes from the approved key, never from the payload.
        return central.ingest_feedback(dev.identity, p, dev.identity)
    end,
    proposals = function(dev, p)
        return require("luamemo.federation.knowledge").ingest(dev.identity, p)
    end,
}

local function do_call(req)
    local body = req.body or ""
    local sid, n = channel.peek(body)
    if not sid then return reply(400, { error = n }) end
    local sess = sessions.get(sid)
    if not sess then
        return reply(401, { error = "unknown or expired session — handshake again", code = "session" })
    end
    local plaintext, uerr = channel.unseal(sess.keys, sid, "c2s", body)
    if not plaintext then return reply(401, { error = uerr, code = "session" }) end
    if not sessions.accept(sid, n) then
        return reply(409, { error = "replayed or out-of-order message", code = "replay" })
    end
    local call = json.decode(plaintext)
    local out
    local fn = type(call) == "table" and RPC[call.method]
    if not fn then
        out = { ok = false, status = 404, error = "unknown method" }
    else
        local ok, res, err, status = pcall(fn, sess, type(call.params) == "table" and call.params or {})
        if not ok then
            io.stderr:write("[luamemo federation] rpc error: " .. tostring(res) .. "\n")
            out = { ok = false, status = 500, error = "internal error" }
        elseif res == nil then
            out = { ok = false, status = status or 400, error = err }
        else
            out = { ok = true, result = res }
        end
    end
    -- (last_seen_at was stamped by sessions.accept — no extra round trip)
    return 200, channel.seal(sess.keys, sid, "s2c", n, json.encode(out)), BIN_T
end

local ROUTES = {
    ["GET /key"] = function()
        local pk = identity()
        return reply(200, { v = channel.VERSION, protocol = common.PROTOCOL, org_scope = central.org_scope(),
                            org_name = require("luamemo").config.org_name, central_pk = channel.hex(pk),
                            fingerprint = keys.fingerprint(pk) })
    end,

    ["POST /pair"] = function(req)
        local msg, st, err = json_body(req)
        if not msg then return reply(st, { error = err }) end
        -- Cheap refusals before any signature verification (this endpoint is
        -- open to unknown keys), both PER ADDRESS so one machine can't block
        -- the others: a rate, and a cap on its pending requests for keys that
        -- aren't already known (a known key may refresh its request).
        local from = common.peer_group(req.peer)
        if pair_throttled(from) then
            return reply(429, { error = "too many pairing requests from this address — try again in a minute" })
        end
        local dpk = type(msg.dev_pk) == "string" and #msg.dev_pk == 64 and msg.dev_pk:match("^%x+$")
            and channel.unhex(msg.dev_pk)
        -- (a request for an identity already waiting from here replaces it: not counted)
        local claimed = type(msg.identity) == "string" and msg.identity:lower() or nil
        if dpk and not devs.find_by_key(dpk) and devs.pending_from(from, claimed) >= devs.MAX_PENDING_PER_ADDR then
            return reply(429, { error = ("this address already has %d pairing requests waiting — ask the org "
                .. "admin to review them"):format(devs.MAX_PENDING_PER_ADDR) })
        end
        local cpk = identity()
        local r, verr, vst = channel.pair_verify(msg, cpk)
        if not r then return reply(vst or 400, { error = verr }) end
        local status, derr, dst = devs.request(r.identity, r.dev_pk, cpk, from)
        if not status then return reply(dst or 400, { error = derr }) end
        return reply(200, channel.pair_ack(r, status, csign))
    end,

    ["POST /hello"] = function(req)
        local msg, st, err = json_body(req)
        if not msg then return reply(st, { error = err }) end
        local now = os.time()
        local nonce = type(msg.nonce) == "string" and msg.nonce:lower() or ""
        if _seen[nonce] and _seen[nonce] > now then
            return reply(409, { error = "replayed handshake", code = "replay" })
        end
        local cpk = identity()
        local welcome, sess, hst, why = channel.server_accept(msg, {
            central_pk = cpk, sign = csign,
            lookup = function(dev_pk) return devs.find_by_key(dev_pk) end,
            hello_key = device_hello_key,
        })
        if not welcome then return reply(hst or 400, { error = sess, code = why }) end
        remember_nonce(nonce, now)
        sessions.create(sess.dev.id, sess.id, sess.keys, sess.ttl)
        devs.touch(sess.dev.id)
        return reply(200, welcome)
    end,

    ["POST /call"] = do_call,
}

--- Route a request. Never raises: internal errors become a generic 500 (the
--- detail goes to stderr, never to the client).
function M.handle(req, prefix)
    prefix = prefix or M.DEFAULT_PREFIX
    if policy.role() ~= "org" then
        return reply(404, { error = "federation endpoints are served only by an org central (role=org)" })
    end
    local path = tostring(req.path or "")
    if path:sub(1, #prefix) ~= prefix then return reply(404, { error = "not found" }) end
    local rel = path:sub(#prefix + 1)
    local route = ROUTES[tostring(req.method or ""):upper() .. " " .. rel]
    if not route then return reply(404, { error = "not found" }) end
    if req.body and #req.body > M.MAX_BODY then return reply(413, { error = "request body too large" }) end
    local ok, status, body, ctype = pcall(route, req)
    if not ok then
        io.stderr:write("[luamemo federation] handler error: " .. tostring(status) .. "\n")
        return reply(500, { error = "internal error" })
    end
    return status, body, ctype
end

return M
