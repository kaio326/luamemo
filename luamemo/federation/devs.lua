-- luamemo.federation.devs
-- Org central: the registry of paired device keys (lm_org_devs).
--
--   devs.find_by_key(dev_pk)             → row | nil   (row.status: pending / approved / removed)
--   devs.request(identity, dev_pk, central_pk [, from]) → status | nil, err, http_status
--   devs.pending_from(from)              → pending requests from that address (group)
--   devs.list([status])                  → rows (newest first)
--   devs.approve(code [, by])            → row | nil, err
--   devs.remove(ref [, by])              → count | nil, err   (ref: identity, code or fingerprint)
--   devs.clear_pending()                 → count of pending requests removed
--   devs.touch(id)                       → last_seen_at = now
--
-- Approval is BY PAIRING CODE: the admin types the code the dev reads out, so
-- a request swapped in by someone else (different key → different code) can
-- never be approved by mistake. Pending requests (`from` = the requesting
-- address, IPv6 per /64 — common.peer_group): at most MAX_PENDING_PER_ADDR per
-- address, so one machine can't crowd the queue; a newer request for the same
-- identity FROM THE SAME ADDRESS replaces the older one (a device re-pairing
-- with a new key) — never one from elsewhere, so claiming someone's identity
-- can't delete their request. MAX_PENDING bounds storage only: when full, the
-- oldest pending request makes room. Requests expire after PENDING_TTL_H hours.
-- Removing a device also ends its sessions.
-- Times are stored as µs; rows come back with them as text.

local db   = require("luamemo.db")
local util = require("luamemo.util")
local keys = require("luamemo.federation.keys")

local M = {}

M.MAX_PENDING          = 1000
M.MAX_PENDING_PER_ADDR = 3
M.PENDING_TTL_H        = 24

local hex = util.to_hex
local function org() return require("luamemo.federation.central").org_scope() end
local function ttl_cut() return util.now_us() - M.PENDING_TTL_H * 3600 * 1000000 end

local COLS = "id, identity, public_key, fingerprint, pairing_code, status, requested_at, decided_at, "
    .. "decided_by, last_seen_at"

local function out(r) return util.iso_fields(r, { "requested_at", "decided_at", "last_seen_at" }) end

local function prune_pending(scope)
    db.run("DELETE FROM lm_org_devs WHERE org_scope = ? AND status = 'pending' AND requested_at < ?", scope, ttl_cut())
end

function M.find_by_key(dev_pk)
    local scope = org()
    if not scope or type(dev_pk) ~= "string" or #dev_pk ~= 32 then return nil end
    return out(db.first("SELECT " .. COLS .. " FROM lm_org_devs WHERE org_scope = ? AND public_key = ? "
        .. "AND NOT (status = 'pending' AND requested_at < ?)", scope, hex(dev_pk), ttl_cut()))
end

-- `requested_from = ?` / `requested_from IS NULL`, and its parameters
local function from_cond(from)
    if from then return "requested_from = ?", { from } end
    return "requested_from IS NULL", {}
end

--- Pending requests from one address (group) — not counting `except_identity`'s,
--- which a new request for that identity from there would replace.
function M.pending_from(from, except_identity)
    local scope = org()
    if not scope then return 0 end
    local fc, fp = from_cond(from)
    local params = { scope }
    for _, v in ipairs(fp) do params[#params + 1] = v end
    params[#params + 1] = ttl_cut()
    local extra = ""
    if except_identity then extra = " AND identity <> ?"; params[#params + 1] = except_identity end
    return tonumber((db.value("SELECT count(*) FROM lm_org_devs WHERE org_scope = ? AND status = 'pending' AND "
        .. fc .. " AND requested_at >= ?" .. extra, unpack(params, 1, #params)))) or 0
end

--- A dev asks to pair `dev_pk` as `identity` (from: its address group, see
--- common.peer_group). Idempotent for the same key.
function M.request(identity, dev_pk, central_pk, from)
    local scope = org()
    if not scope then return nil, "org central has no org_name", 500 end
    prune_pending(scope)
    local pk = hex(dev_pk)
    local existing = M.find_by_key(dev_pk)
    local function as_approved(row)
        if row.identity ~= identity then
            return nil, "this device key is already paired as " .. row.identity, 409
        end
        return "approved"
    end
    if existing then
        if existing.status == "approved" then return as_approved(existing) end
        -- pending (refresh) or removed (asks again) → pending under the claimed identity.
        -- Never over an approval: the admin may approve between the read above and
        -- this write (a device re-sends its request while waiting) — that must stick.
        local upd = db.first("UPDATE lm_org_devs SET status = 'pending', identity = ?, requested_at = ?, "
            .. "requested_from = ?, decided_at = NULL, decided_by = NULL "
            .. "WHERE id = ? AND status <> 'approved' RETURNING id",
            identity, util.now_us(), from, tonumber(existing.id))
        if not upd then
            local now = M.find_by_key(dev_pk)
            if now and now.status == "approved" then return as_approved(now) end
            return nil, "pairing request changed concurrently — try again", 409
        end
    else
        -- A newer key for the same identity from the same address replaces its
        -- older request (first, so it doesn't count against the address).
        local fc, fp = from_cond(from)
        local dp = { scope, identity }
        for _, v in ipairs(fp) do dp[#dp + 1] = v end
        db.run("DELETE FROM lm_org_devs WHERE org_scope = ? AND identity = ? AND status = 'pending' AND " .. fc,
            unpack(dp, 1, #dp))
        if M.pending_from(from) >= M.MAX_PENDING_PER_ADDR then
            return nil, ("this address already has %d pairing requests waiting — ask the org admin to review "
                .. "them (memo org devs pending)"):format(M.MAX_PENDING_PER_ADDR), 429
        end
        local over = M.pending_count() - M.MAX_PENDING + 1
        if over > 0 then   -- storage bound: the oldest pending requests make room
            db.run("DELETE FROM lm_org_devs WHERE id IN (SELECT id FROM lm_org_devs WHERE org_scope = ? "
                .. "AND status = 'pending' ORDER BY requested_at, id LIMIT ?)", scope, over)
        end
        db.run("INSERT INTO lm_org_devs (org_scope, identity, public_key, fingerprint, pairing_code, status, "
            .. "requested_from, requested_at) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?) "
            .. "ON CONFLICT (org_scope, public_key) DO NOTHING",
            scope, identity, pk, keys.fingerprint(dev_pk), keys.pairing_code(central_pk, dev_pk), from, util.now_us())
    end
    return "pending"
end

--- Remove every pending request (the admin clearing junk). Approved and
--- removed devices are untouched.
function M.clear_pending()
    local scope = org()
    if not scope then return 0 end
    return db.run("DELETE FROM lm_org_devs WHERE org_scope = ? AND status = 'pending'", scope) or 0
end

function M.pending_count()
    local scope = org()
    if not scope then return 0 end
    prune_pending(scope)
    return tonumber((db.value("SELECT count(*) FROM lm_org_devs WHERE org_scope = ? AND status = 'pending'",
        scope))) or 0
end

function M.list(status)
    local scope = org()
    if not scope then return {} end
    prune_pending(scope)
    local rows
    if status then
        rows = db.query("SELECT " .. COLS .. " FROM lm_org_devs WHERE org_scope = ? AND status = ? "
            .. "ORDER BY requested_at DESC, id DESC", scope, status)
    else
        rows = db.query("SELECT " .. COLS .. " FROM lm_org_devs WHERE org_scope = ? "
            .. "ORDER BY requested_at DESC, id DESC", scope)
    end
    for _, r in ipairs(rows or {}) do out(r) end
    return rows or {}
end

--- Approve the pending request whose pairing code the dev reads out. Two
--- pending requests with the same code can only come from a key ground to
--- collide with someone's code — never approved: the admin removes them and
--- the dev pairs again.
function M.approve(code, by)
    local want = keys.normalize_code(code)
    if want == "" then return nil, "pairing code required" end
    local matches = {}
    for _, r in ipairs(M.list("pending")) do
        if keys.normalize_code(r.pairing_code) == want then matches[#matches + 1] = r end
    end
    if #matches == 0 then
        return nil, "no pending request with that code — ask the dev to run `memo org pair` again and read "
            .. "you the code it shows"
    end
    if #matches > 1 then
        local who = {}
        for _, r in ipairs(matches) do who[#who + 1] = r.identity .. " (device " .. r.fingerprint .. ")" end
        return nil, "that code matches " .. #matches .. " pending requests — not approved (a colliding key is "
            .. "suspicious): " .. table.concat(who, ", ") .. ". Remove them (memo org devs remove <code>) and "
            .. "ask the dev to pair again"
    end
    local row = db.first("UPDATE lm_org_devs SET status = 'approved', decided_at = ?, decided_by = ? "
        .. "WHERE id = ? AND status = 'pending' RETURNING " .. COLS, util.now_us(), by, tonumber(matches[1].id))
    if not row then return nil, "approval failed" end
    return out(row)
end

--- Revoke device keys: by identity (all its keys), pairing code or fingerprint.
--- Their sessions end immediately.
function M.remove(ref, by)
    local scope = org()
    if not scope then return nil, "org central has no org_name" end
    ref = tostring(ref or "")
    local cond, params
    if ref:match("^user:") then
        cond, params = "identity = ?", { ref:lower() }
    else
        local want = keys.normalize_code(ref)
        if #want < 8 then return nil, "give an identity (user:<email>), a pairing code or a fingerprint" end
        local ids = {}
        for _, r in ipairs(M.list()) do
            if keys.normalize_code(r.pairing_code) == want or keys.normalize_code(r.fingerprint) == want then
                ids[#ids + 1] = tonumber(r.id)
            end
        end
        if #ids == 0 then return 0 end
        cond, params = "id IN (" .. db.placeholders(#ids) .. ")", ids
    end
    local all = { util.now_us(), by, scope }
    for _, v in ipairs(params) do all[#all + 1] = v end
    local rows = db.query("UPDATE lm_org_devs SET status = 'removed', decided_at = ?, decided_by = ? "
        .. "WHERE org_scope = ? AND " .. cond .. " AND status <> 'removed' RETURNING id", unpack(all, 1, 3 + #params)) or {}
    for _, r in ipairs(rows) do
        db.run("DELETE FROM lm_org_sessions WHERE dev_id = ?", tonumber(r.id))
    end
    return #rows
end

function M.touch(id)
    db.run("UPDATE lm_org_devs SET last_seen_at = ? WHERE id = ?", util.now_us(), tonumber(id) or 0)
end

return M
