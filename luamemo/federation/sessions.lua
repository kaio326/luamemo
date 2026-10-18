-- luamemo.federation.sessions
-- Org central: encrypted-channel sessions (lm_org_sessions).
-- In the database so a `memo serve` restart doesn't break an in-flight sync and
-- several instances on one database share them.
--
--   sessions.create(dev_id, sid, keys, ttl) → sid (binary, 16 bytes)
--   sessions.get(sid)                  → { dev_id, keys, recv_n, identity } | nil
--                                         (only live sessions of APPROVED devices)
--   sessions.accept(sid, n)            → true when n > recv_n (atomic; call AFTER
--                                         the MAC check so forged envelopes can't
--                                         advance the counter); also stamps the
--                                         device's last_seen_at
--   sessions.prune()                   → drop expired sessions

local db   = require("luamemo.db")
local util = require("luamemo.util")

local M = {}

local hex, unhex = util.to_hex, util.from_hex

local _last_prune = 0

function M.prune()
    db.run("DELETE FROM lm_org_sessions WHERE expires_at < ?", util.now_us())
    _last_prune = os.time()
end

function M.create(dev_id, sid, keys, ttl)
    if os.time() - _last_prune > 300 then pcall(M.prune) end
    local now = util.now_us()
    assert(db.run("INSERT INTO lm_org_sessions (id, dev_id, keys, expires_at, created_at) VALUES (?, ?, ?, ?, ?)",
        hex(sid), math.floor(tonumber(dev_id)), hex(keys), now + math.floor(tonumber(ttl) or 600) * 1000000, now))
    return sid
end

function M.get(sid)
    if type(sid) ~= "string" or #sid ~= 16 then return nil end
    local r = db.first("SELECT s.dev_id, s.keys, s.recv_n, d.identity FROM lm_org_sessions s "
        .. "JOIN lm_org_devs d ON d.id = s.dev_id "
        .. "WHERE s.id = ? AND s.expires_at > ? AND d.status = 'approved'", hex(sid), util.now_us())
    if not r then return nil end
    return { dev_id = tonumber(r.dev_id), keys = unhex(r.keys), recv_n = tonumber(r.recv_n),
             identity = r.identity }
end

-- One transaction: advance the counter and stamp the device's last_seen_at.
function M.accept(sid, n)
    local now = util.now_us()
    local ok, accepted = db.transaction(function(h)
        local s = h.first("UPDATE lm_org_sessions SET recv_n = ? WHERE id = ? AND recv_n < ? AND expires_at > ? "
            .. "RETURNING dev_id", n, hex(sid), n, now)
        if not s then return false end
        h.run("UPDATE lm_org_devs SET last_seen_at = ? WHERE id = ?", now, s.dev_id)
        return true
    end)
    return ok == true and accepted == true
end

return M
