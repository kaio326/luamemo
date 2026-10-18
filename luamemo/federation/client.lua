-- luamemo.federation.client
-- Dev side of federation: keep a READ-ONLY local replica of the org scope and
-- push local feedback up to the org central.
--
--   client.pull(opts)   → stats | nil, err   (opts: full, budget_s, timeout_ms)
--   client.push(opts)   → stats | nil, err   (opts: budget_s, timeout_ms)
--   client.sync(opts)   → { pull = …, push = … } | nil, err
--   client.maybe_sync(opts) → TTL-debounced sync (search / session-start trigger)
--   client.status()     → local federation state
--   client.pair(opts)   → ask the central to pair this device's key (pending → admin approves the code)
--   client.central_key() → the central's key, checked against the pinned fingerprint
--
-- Transport: local network only (the central's address must resolve to
-- loopback / LAN / VPN such as Tailscale, and is connected to by that checked
-- address), the central's identity pinned by fingerprint (org_fingerprint /
-- MEMO_ORG_FINGERPRINT), and every call made inside the encrypted,
-- mutually authenticated channel (luamemo.federation.channel) with this
-- device's paired key (luamemo.federation.keys).
--
-- Pull: pages the central snapshot (resumable cursor; each page applied in one
-- transaction), writes rows through store.replica_upsert (the replica
-- capability), then reconciles against the central's versioned manifest —
-- deleting rows that left the org and re-fetching any row whose version
-- differs (so the replica converges even if a cursor skipped a late commit) —
-- and installs the central's promoted learned weights. When the central's and
-- this instance's embedders match, the central's vectors are reused; otherwise
-- rows are re-embedded locally. A change of either embedder triggers a full
-- resync that survives budget interruptions ("resync:" marker).
--
-- Push: reinforcement events and (share = "triples") retrieval triples that
-- touch replica rows, mapped to central ids, refs = "<instance>:e|r:<local id>"
-- (idempotent on the central). Cursors advance only after the central accepts
-- a batch. In "signals" mode query history is skipped for good, so switching
-- to "triples" later never ships old queries.
--
-- Offline-safe: any failure leaves the replica and cursors as they were and is
-- recorded in lm_federation_state.

local db     = require("luamemo.db")
local json   = require("luamemo.json")
local common = require("luamemo.federation.common")
local policy = require("luamemo.federation.policy")

local M = {}

M.PAGE               = 200
M.REPAIR_BATCH       = 500
M.PUSH_BATCH         = 500
M.DEFAULT_TIMEOUT_MS = 15000
M.THROTTLE_S         = 60    -- in-process: at most one TTL check per minute

local function cfg()   return require("luamemo").config end
local function store() return require("luamemo.store") end
local util = require("luamemo.util")

-- -------------------------------------------------------------------------
-- Transport: local network only, pinned central key, encrypted channel
-- -------------------------------------------------------------------------
local channel = require("luamemo.federation.channel")
local keys    = require("luamemo.federation.keys")

local redact = require("luamemo.util").redact_url
local parse_url = require("luamemo.netguard").parse_url

-- The central's base URLs rewritten to checked LOCAL addresses (resolved once
-- here and connected to directly — no second lookup a DNS rebind could
-- redirect), IPv4 first: a Tailscale name resolves to both 100.x and fd7a:…,
-- and a central bound to an IPv4 address must still be reached.
-- Returns { base, … }, host_header | nil, err. The checked addresses are kept for
-- RESOLVE_TTL seconds (a sync makes many calls; one lookup serves them all).
M.RESOLVE_TTL = 60
local _bases = {}
local function central_bases()
    local c = cfg()
    local url = c.org_url
    if not url or url == "" then return nil, "org_url (MEMO_ORG_URL) is not set" end
    local ck = url .. "\0" .. tostring(c.org_prefix)
    local hit = _bases[ck]
    if hit and hit.expires > os.time() then return hit.bases, hit.host end
    local scheme, host, port, rest = parse_url(url)
    if not scheme then
        return nil, "org_url must look like http://<host>:<port> (no credentials in the URL)"
    end
    local ok, why, ips = require("luamemo.netguard").host_is_local(host)
    if not ok then
        return nil, "federation is local-network only (LAN / Tailscale): " .. redact(tostring(why))
    end
    local portpart = (port ~= "") and (":" .. port) or ""
    local tail = portpart .. (rest:gsub("/+$", "")) .. (c.org_prefix or "/federation")
    local v4, v6 = {}, {}
    for _, ip in ipairs(ips) do
        if ip:find(":", 1, true) then v6[#v6 + 1] = scheme .. "://[" .. ip .. "]" .. tail
        else v4[#v4 + 1] = scheme .. "://" .. ip .. tail end
    end
    for _, b in ipairs(v6) do v4[#v4 + 1] = b end
    _bases[ck] = { bases = v4, host = host .. portpart, expires = os.time() + M.RESOLVE_TTL }
    return v4, host .. portpart
end

-- One HTTP exchange (trying the next address only on a transport failure).
-- Returns status, body | nil, err.
local function http_call(method, path, body, ctype, timeout_ms)
    local bases, host = central_bases()
    if not bases then return nil, host end
    local headers = { Host = host, Accept = "application/json" }
    if body then headers["Content-Type"] = ctype end
    local last
    for _, base in ipairs(bases) do
        local st, resp, err = require("luamemo.http").request(base .. path, {
            method = method, headers = headers, body = body, timeout_ms = timeout_ms or M.DEFAULT_TIMEOUT_MS })
        if st then return st, resp or "" end
        last = err
    end
    return nil, "org central unreachable: " .. redact(last)
end

local function json_call(method, path, tbl, timeout_ms)
    local st, resp = http_call(method, path, tbl and json.encode(tbl), "application/json", timeout_ms)
    if not st then return nil, resp end
    local parsed = json.decode(resp)
    if st ~= 200 then
        local msg = (type(parsed) == "table" and parsed.error) or util.cut_utf8(resp, 200)
        return nil, ("org central answered %d: %s"):format(st, tostring(msg)), st, parsed
    end
    if type(parsed) ~= "table" then return nil, "org central sent invalid JSON" end
    return parsed
end

-- The central's identity key, checked against the pinned fingerprint
-- (org_fingerprint / MEMO_ORG_FINGERPRINT). Cached per process.
local _central = {}
function M.central_key(timeout_ms)
    local c = cfg()
    local pin = keys.normalize_code(c.org_fingerprint)
    if pin == "" then
        return nil, "no central fingerprint pinned (MEMO_ORG_FINGERPRINT) — get it from the org admin "
            .. "and run: memo calibrate --org-url <url> --org-fingerprint <fingerprint>"
    end
    local cached = _central[c.org_url]
    if cached and cached.pin == pin then return cached.pk, cached.info end
    local info, err = json_call("GET", "/key", nil, timeout_ms)
    if not info then return nil, err end
    if tonumber(info.protocol) ~= common.PROTOCOL then
        return nil, ("federation protocol mismatch: central %s, this instance %d — upgrade the older side")
            :format(tostring(info.protocol), common.PROTOCOL)
    end
    local pk = type(info.central_pk) == "string" and #info.central_pk == 64 and channel.unhex(info.central_pk)
    if not pk or keys.normalize_code(keys.fingerprint(pk)) ~= pin then
        return nil, "the central's key does not match the pinned fingerprint — refusing to talk to it "
            .. "(re-check the fingerprint with the org admin; the server at this address is not the one you paired with)"
    end
    _central[c.org_url] = { pk = pk, pin = pin, info = info }
    return pk, info
end

--- Ask the central to pair this device's key. Returns
--- { status, code, identity, device_fingerprint, central_fingerprint } | nil, err.
function M.pair(opts)
    opts = opts or {}
    if policy.role() ~= "dev" then return nil, "not a dev instance (set MEMO_ORG_URL)" end
    local cpk, cerr = M.central_key(opts.timeout_ms)
    if not cpk then return nil, cerr end
    local ident, ierr = require("luamemo.federation.identity").resolve(cfg())
    if not ident then return nil, ierr end
    local dpk, derr = keys.ensure_identity("dev")
    if not dpk then return nil, derr end
    local req = channel.pair_request(cpk, dpk, ident, function(m) return keys.sign("dev", m) end)
    local ack, aerr = json_call("POST", "/pair", req, opts.timeout_ms)
    if not ack then return nil, aerr end
    local status, verr = channel.pair_check_ack(req, ack, cpk)
    if not status then return nil, verr end
    return { status = status, code = keys.pairing_code(cpk, dpk), identity = ident,
             device_fingerprint = keys.fingerprint(dpk), central_fingerprint = keys.fingerprint(cpk) }
end

--- The central's PUBLIC identity fetched WITHOUT a pin — only for a person to
--- compare with the fingerprint their org admin gave them (never trusted as
--- is; the fingerprint is computed here from the key, not taken from the reply).
function M.probe_central(timeout_ms)
    local info, err = json_call("GET", "/key", nil, timeout_ms)
    if not info then return nil, err end
    local hexpk = info.central_pk
    local pk = type(hexpk) == "string" and #hexpk == 64 and hexpk:match("^%x+$") and channel.unhex(hexpk)
    if not pk then return nil, "the central sent an invalid key" end
    return { fingerprint = keys.fingerprint(pk), org_name = info.org_name, org_scope = info.org_scope,
             protocol = info.protocol }
end

local _session = {}   -- per org_url: { id, keys, n, expires }

local function handshake(timeout_ms)
    local c = cfg()
    local cpk, cerr = M.central_key(timeout_ms)
    if not cpk then return nil, cerr end
    local dpk = keys.public_key("dev")
    if not dpk then return nil, "this device is not paired yet — run: memo org pair" end
    local hk, hkerr = keys.hello_key("dev", cpk, dpk)
    if not hk then return nil, hkerr end
    local hello, state_ = channel.client_hello(cpk, dpk, function(m) return keys.sign("dev", m) end, hk)
    if not hello then return nil, state_ end
    local welcome, err, st, body = json_call("POST", "/hello", hello, timeout_ms)
    if not welcome then
        local why = type(body) == "table" and body.code or nil
        if st == 403 then return nil, err .. " (memo org pair · then the org admin approves your code)", why end
        return nil, err
    end
    local sess, ferr = channel.client_finish(state_, welcome)
    if not sess then return nil, ferr end
    sess.expires = os.time() + math.max(30, sess.ttl - 60)
    _session[c.org_url] = sess
    return sess
end

--- One encrypted RPC. Returns result | nil, err, status.
local function rpc(method, params, timeout_ms)
    local url = cfg().org_url
    for attempt = 1, 2 do
        local sess = _session[url]
        if not sess or os.time() >= sess.expires then
            local herr
            sess, herr = handshake(timeout_ms)
            if not sess then return nil, herr end
        end
        sess.n = sess.n + 1
        local n = sess.n
        local body = channel.seal(sess.keys, sess.id, "c2s", n, json.encode({ method = method, params = params or {} }))
        local st, resp = http_call("POST", "/call", body, "application/octet-stream", timeout_ms)
        if not st then return nil, resp end
        if st == 200 then
            local plaintext, uerr = channel.unseal(sess.keys, sess.id, "s2c", resp)
            local _, rn = channel.peek(resp)
            if not plaintext then return nil, "org central reply failed authentication: " .. tostring(uerr) end
            if rn ~= n then return nil, "org central reply does not match the request" end
            local out = json.decode(plaintext)
            if type(out) ~= "table" then return nil, "org central sent an invalid reply" end
            if not out.ok then return nil, ("org central: %s"):format(tostring(out.error)), out.status end
            return out.result
        end
        local parsed = json.decode(resp)
        _session[url] = nil
        -- Session gone (central restarted / expired / device re-approved): one fresh handshake.
        if not (st == 401 and type(parsed) == "table" and parsed.code == "session" and attempt == 1) then
            return nil, ("org central answered %d: %s"):format(st,
                tostring(type(parsed) == "table" and parsed.error or util.cut_utf8(resp, 200))), st
        end
    end
end

--- Is this device approved? One handshake attempt (a pending / unknown key is
--- refused before the central does any signature work, so polling is cheap).
--- Returns "approved" | "pending" | "unknown" | "removed" | nil, err.
function M.pair_status(timeout_ms)
    _session[cfg().org_url] = nil
    local sess, err, why = handshake(timeout_ms)
    if sess then return "approved" end
    if why then return why, err end
    return nil, err
end

function M._reset_session() _session = {}; _central = {}; keys._reset_hello() end   -- tests

--- Remove every trace of an org this device no longer belongs to from the
--- local database: its read-only replica, pulled weights, sync state and the
--- record of what was proposed to it (local feedback on the replica rows goes
--- with them; the dev's own memories stay). The replica capability makes this
--- the only path that may delete replica rows.
--- Returns { replica = n } or nil, err.
function M.forget(scope)
    if not (type(scope) == "string" and scope:match("^org:")) then return nil, "forget: an org: scope is required" end
    local idx = store().replica_index(scope)
    local ids = {}
    for _, v in pairs(idx) do ids[#ids + 1] = v.id end
    local n = 0
    if #ids > 0 then
        local deleted, err = store().replica_delete(scope, ids, policy.capability("replica"))
        if not deleted then return nil, err end
        n = deleted
    end
    db.run("DELETE FROM lm_learner_weights WHERE scope = ?", scope)
    db.run("DELETE FROM lm_federation_state WHERE org_scope = ?", scope)
    db.run("DELETE FROM lm_org_proposed WHERE org_scope = ?", scope)
    _session = {}; _central = {}
    return { replica = n }
end

-- -------------------------------------------------------------------------
-- State (lm_federation_state)
-- -------------------------------------------------------------------------
local function state(scope)
    return db.first("SELECT * FROM lm_federation_state WHERE org_scope = ?", scope)
end

-- state_set values: plain Lua values; NOW = the current time, NULL = SQL NULL.
local NOW, NULL = {}, {}

local function state_set(scope, fields)
    local cols, params, sets = { "org_scope" }, { scope }, {}
    local now = util.now_us()
    for k, v in pairs(fields) do
        cols[#cols + 1] = k
        if v == NOW then v = now elseif v == NULL then v = nil end
        params[#cols] = v
        sets[#sets + 1] = k .. " = excluded." .. k
    end
    cols[#cols + 1] = "updated_at"
    params[#cols] = now
    sets[#sets + 1] = "updated_at = excluded.updated_at"
    assert(db.run("INSERT INTO lm_federation_state (" .. table.concat(cols, ", ") .. ") VALUES ("
        .. db.placeholders(#cols) .. ") ON CONFLICT (org_scope) DO UPDATE SET " .. table.concat(sets, ", "),
        unpack(params, 1, #cols)))
end

--- The org scope this dev replicates (learned from the central on first pull).
function M.org_scope()
    return (db.value("SELECT org_scope FROM lm_federation_state ORDER BY updated_at DESC LIMIT 1"))
end

local function record_failure(scope, err)
    scope = scope or M.org_scope()
    if scope then
        pcall(state_set, scope, { last_pull_ok = false, last_error = util.cut_utf8(tostring(err), 500) })
    end
end

local function ensure_instance(scope, st)
    if st and st.instance_id and st.instance_id ~= "" then return st.instance_id end
    local id = util.to_hex(require("luamemo.native.sodium").random_bytes(8))
    state_set(scope, { instance_id = id })
    return id
end

local function past(deadline) return deadline and os.time() >= deadline end

-- -------------------------------------------------------------------------
-- Pull
-- -------------------------------------------------------------------------
local function apply_weights(scope, weights)
    local ls = require("luamemo.learner_store")
    local changed = 0
    for _, kind in ipairs(common.WEIGHT_KINDS) do
        local w    = type(weights) == "table" and weights[kind]
        local ver  = type(w) == "table" and tonumber(w.version)
        local want = ver and ("org:v%d"):format(math.floor(ver)) or nil   -- %d: no "1.0" on 5.3+
        local have = ls.current_note(scope, kind)
        if want and type(w.weights) == "table" then
            if have ~= want then
                local v = ls.save_version(scope, kind, w.weights, { note = want })
                if v then ls.promote(scope, kind, v); changed = changed + 1 end
            end
        elseif have and tostring(have):match("^org:v") then
            ls.deactivate(scope, kind)   -- the central withdrew its model
            changed = changed + 1
        end
    end
    return changed
end

-- Applies rows in snapshot order. Past the deadline it stops early (always
-- after at least one row, so every call makes progress) and returns the cursor
-- of the last applied row: the caller commits that prefix and resumes exactly
-- there — a slow page (local re-embedding) never overruns the budget by more
-- than one row.
-- idx: the replica index (central id → { id, us }), read once per pull and kept
-- current here — one query per row instead of a lookup + a write.
local function apply_rows(scope, rows, vectors, force, stats, counter, deadline, idx)
    local s, cap = store(), policy.capability("replica")
    for i, item in ipairs(rows or {}) do
        if i > 1 and past(deadline) then
            local last = rows[i - 1]
            return ("%d:%d"):format(math.floor(tonumber(last.updated_us) or 0), math.floor(tonumber(last.id) or 0))
        end
        local oid = tonumber(item.id)
        local id, action = s.replica_upsert(scope, item, vectors and item.vector or nil, cap,
            { force = force, known = oid and idx[oid] or false })
        if not id then error(action, 0) end
        if oid then idx[oid] = { id = tonumber(id), us = tonumber(item.updated_us) } end
        if action == "unchanged" then stats.unchanged = stats.unchanged + 1
        else stats[counter] = stats[counter] + 1 end
    end
end

local function in_tx(fn)
    return db.transaction(function() fn() end)
end

function M.pull(opts)
    opts = opts or {}
    if policy.role() ~= "dev" then return nil, "not a dev instance (set MEMO_ORG_URL)" end
    local deadline = opts.budget_s and (os.time() + math.max(0, tonumber(opts.budget_s) or 0)) or nil

    local info, err = rpc("info", nil, opts.timeout_ms)
    if not info then record_failure(nil, err); return nil, err end
    if tonumber(info.protocol) ~= common.PROTOCOL then
        local perr = ("federation protocol mismatch: central %s, this instance %d")
            :format(tostring(info.protocol), common.PROTOCOL)
        record_failure(nil, perr)
        return nil, perr
    end
    local scope = info.org_scope
    if type(scope) ~= "string" or not scope:match("^org:[%w][%w%._%-]*$") then
        record_failure(nil, "org central sent an invalid org scope")
        return nil, "org central sent an invalid org scope"
    end

    local st        = state(scope) or {}
    local local_sig = common.embedder_sig(cfg())
    local sig_key   = tostring(info.embedder_sig) .. " -> " .. local_sig
    local vectors   = (info.embedder_sig == local_sig)
    local resync, cursor
    if opts.full or (st.embedder_sig ~= sig_key and st.embedder_sig ~= "resync:" .. sig_key) then
        resync, cursor = true, nil                      -- start a (re)sync from scratch
    elseif st.embedder_sig == "resync:" .. sig_key then
        resync, cursor = true, st.snapshot_cursor       -- continue an interrupted resync
    else
        resync, cursor = false, st.snapshot_cursor      -- incremental
    end
    if cursor == "" then cursor = nil end
    local sig_state = resync and ("resync:" .. sig_key) or sig_key

    local stats = { org_scope = scope, upserted = 0, unchanged = 0, repaired = 0, deleted = 0,
                    pages = 0, weights = 0, vectors_reused = vectors, full = resync }
    local idx = store().replica_index(scope)
    -- An incremental pull tells the central what its replica holds (a digest):
    -- when nothing changed, no manifest comes back (an idle sync stays O(1)).
    local digest
    if not resync then
        local entries = {}
        for oid, v in pairs(idx) do entries[#entries + 1] = { oid, v.us } end
        digest = common.manifest_digest(entries)
    end
    local final
    while true do
        if past(deadline) then stats.partial = true; break end
        local page, perr = rpc("snapshot", { since = cursor, limit = M.PAGE, vectors = vectors,
                                             manifest_digest = digest }, opts.timeout_ms)
        digest = nil   -- later pages: rows were applied since, the digest no longer describes the replica
        if not page then record_failure(scope, perr); return nil, perr end
        local stopped
        local ok, terr = in_tx(function()
            stopped = apply_rows(scope, page.rows, vectors, resync, stats, "upserted", deadline, idx)
            state_set(scope, { snapshot_cursor = stopped or page.cursor or "", embedder_sig = sig_state })
        end)
        if not ok then record_failure(scope, terr); return nil, tostring(terr) end
        stats.pages = stats.pages + 1
        if stopped then stats.partial = true; break end
        cursor = page.cursor
        if not page.more then final = page; break end
    end

    -- Reconcile with the versioned manifest: drop rows that left the org, repair
    -- any row whose version differs from the central's. manifest_same: the
    -- central confirmed the replica digest — nothing to reconcile.
    if final and not final.manifest_same then
        local keep, need = {}, {}
        for _, m in ipairs(final.manifest or {}) do
            local oid, us = tonumber(m[1]), tonumber(m[2])
            if oid then
                keep[oid] = true
                local have = idx[oid]
                if not have or have.us ~= us then need[#need + 1] = oid end
            end
        end
        local dels = {}
        for oid, v in pairs(idx) do if not keep[oid] then dels[#dels + 1] = v.id end end
        if #dels > 0 then
            local n, derr = store().replica_delete(scope, dels, policy.capability("replica"))
            if not n then record_failure(scope, derr); return nil, derr end
            stats.deleted = n
        end
        for i = 1, #need, M.REPAIR_BATCH do
            if past(deadline) then stats.partial = true; break end
            local batch = {}
            for j = i, math.min(#need, i + M.REPAIR_BATCH - 1) do batch[#batch + 1] = ("%d"):format(need[j]) end
            local rp, rerr = rpc("snapshot", { ids = table.concat(batch, ","), vectors = vectors }, opts.timeout_ms)
            if not rp then record_failure(scope, rerr); return nil, rerr end
            local stopped
            local ok, terr = in_tx(function()
                stopped = apply_rows(scope, rp.rows, vectors, false, stats, "repaired", deadline, idx)
            end)
            if not ok then record_failure(scope, terr); return nil, tostring(terr) end
            if stopped then stats.partial = true; break end   -- the rest is repaired next pull
        end
    end
    if final and not stats.partial then
        stats.manifest_same = final.manifest_same == true or nil
        stats.weights = apply_weights(scope, final.weights)
        state_set(scope, { last_pull_at = NOW, last_pull_ok = true, last_error = NULL, embedder_sig = sig_key })
        -- After an embedder change the replica now has the new vector size: the
        -- database moves to it once the dev's own scopes are re-embedded too.
        stats.switched = store().finish_switch(cfg().embed_dim) or nil
    end
    if stats.partial then
        state_set(scope, { last_error = "partial pull: time budget exhausted (resumes next sync)" })
    end
    return stats
end

-- -------------------------------------------------------------------------
-- Push
-- -------------------------------------------------------------------------
local int_array = common.int_array

function M.push(opts)
    opts = opts or {}
    if policy.role() ~= "dev" then return nil, "not a dev instance (set MEMO_ORG_URL)" end
    local scope = M.org_scope()
    if not scope then return nil, "nothing to push yet — pull first (the org scope comes from the central)" end
    local deadline = opts.budget_s and (os.time() + math.max(0, tonumber(opts.budget_s) or 0)) or nil

    local st    = state(scope) or {}
    local inst  = ensure_instance(scope, st)
    local share = (cfg().org_share == "signals") and "signals" or "triples"
    local by_local, local_ids = {}, {}
    for oid, v in pairs(store().replica_index(scope)) do
        by_local[v.id] = oid
        local_ids[#local_ids + 1] = v.id
    end
    -- A memory of this dev that became (or already was) org knowledge: its use
    -- counts for the org copy (proposer link).
    local props = require("luamemo.federation.proposals")
    for src, oid in pairs(props.linked(scope)) do
        if not by_local[src] then
            by_local[src] = oid
            local_ids[#local_ids + 1] = src
        end
    end
    local stats = { org_scope = scope, share = share, events = 0, retrievals = 0, duplicates = 0, rejected = 0 }
    local ev_cursor = tonumber(st.last_push_reinforcement_id) or 0
    local fb_cursor = tonumber(st.last_push_feedback_id) or 0

    if share == "signals" then   -- never ship query history, not even after a later switch
        local m = tonumber((db.value("SELECT COALESCE(max(id), 0) FROM lm_retrieval_feedback"))) or fb_cursor
        if m > fb_cursor then
            fb_cursor = m
            state_set(scope, { last_push_feedback_id = m })
        end
    end
    -- the ids as one JSON parameter (a replica can outgrow SQLite's parameter limit)
    local id_json = db.json(local_ids)

    while #local_ids > 0 do
        if past(deadline) then stats.partial = true; break end
        local ev_rows = db.query("SELECT id, memory_id, event_type, delta, note FROM lm_reinforcements "
            .. "WHERE id > ? AND memory_id IN (SELECT value FROM json_each(?)) ORDER BY id LIMIT ?",
            ev_cursor, id_json, M.PUSH_BATCH) or {}
        local events, new_ev = {}, ev_cursor
        for _, r in ipairs(ev_rows) do
            new_ev = tonumber(r.id)
            local oid = by_local[tonumber(r.memory_id)]
            if oid then   -- notes are free text: only shared along with queries (triples)
                events[#events + 1] = { ref = ("%s:e:%d"):format(inst, new_ev), memory = oid,
                    type = r.event_type, delta = tonumber(r.delta),
                    note = (share == "triples") and r.note or nil }
            end
        end
        local retrievals, new_fb, fb_rows = {}, fb_cursor, {}
        if share == "triples" then
            fb_rows = db.query("SELECT f.id, f.query, f.candidate_ids FROM lm_retrieval_feedback f "
                .. "WHERE f.id > ? AND EXISTS (SELECT 1 FROM lm_retrieval_candidates c WHERE c.feedback_id = f.id "
                .. "AND c.memory_id IN (SELECT value FROM json_each(?))) ORDER BY f.id LIMIT ?",
                fb_cursor, id_json, M.PUSH_BATCH) or {}
            for _, r in ipairs(fb_rows) do
                new_fb = tonumber(r.id)
                local cands, all = {}, int_array(r.candidate_ids)
                for _, lid in ipairs(all) do
                    local oid = by_local[lid]
                    if oid then cands[#cands + 1] = oid end
                end
                if #cands > 0 and r.query and r.query ~= "" then
                    -- top: the org row that was this search's best result, if any.
                    retrievals[#retrievals + 1] = { ref = ("%s:r:%d"):format(inst, new_fb),
                        query = r.query, candidates = cands, top = all[1] and by_local[all[1]] or nil }
                end
            end
        end
        if #events > 0 or #retrievals > 0 then
            -- Attribution comes from the paired device key, not from anything sent here.
            local res, perr = rpc("feedback", { share = share, events = events, retrievals = retrievals },
                opts.timeout_ms)
            if not res then
                pcall(state_set, scope, { last_error = util.cut_utf8("push failed: " .. tostring(perr), 500) })
                return nil, perr
            end
            stats.events     = stats.events + (tonumber(res.accepted_events) or 0)
            stats.retrievals = stats.retrievals + (tonumber(res.accepted_retrievals) or 0)
            stats.duplicates = stats.duplicates + (tonumber(res.duplicates) or 0)
            stats.rejected   = stats.rejected + #(res.rejected or {})
        end
        if new_ev ~= ev_cursor or new_fb ~= fb_cursor then
            ev_cursor, fb_cursor = new_ev, new_fb
            state_set(scope, { last_push_reinforcement_id = ev_cursor,
                               last_push_feedback_id = fb_cursor, last_push_at = NOW })
        end
        if #ev_rows < M.PUSH_BATCH and #fb_rows < M.PUSH_BATCH then break end
    end

    -- Knowledge proposals: filtered project knowledge only, text — so never in
    -- signals mode. A central that doesn't take them doesn't fail the push.
    if share == "triples" and cfg().org_propose ~= false and not past(deadline) then
        local batch = props.outgoing(scope, inst)
        if batch then
            local wire = props.wire(batch)
            wire.share = share
            local res, perr = rpc("proposals", wire, opts.timeout_ms)
            if res then
                stats.proposals = props.record(scope, batch, res)
                stats.proposed = #batch.propose
            else
                stats.proposals_error = tostring(perr)
            end
        end
    end
    return stats
end

-- -------------------------------------------------------------------------
-- Sync + triggers
-- -------------------------------------------------------------------------
function M.sync(opts)
    opts = opts or {}
    local t0 = os.time()
    local pulled, perr = M.pull(opts)
    if not pulled then return nil, perr end
    local popts = {}
    for k, v in pairs(opts) do popts[k] = v end
    if opts.budget_s then popts.budget_s = math.max(1, opts.budget_s - (os.time() - t0)) end
    local pushed, qerr = M.push(popts)
    return { pull = pulled, push = pushed, push_error = qerr }
end

local _next_check = 0

--- TTL-debounced sync for implicit triggers (org-scope search, session start).
--- Cheap when not due: a per-process throttle, then one atomic claim on
--- lm_federation_state so concurrent processes don't all sync. A pull cut short
--- by its time budget is due again after a minute (not a full TTL), so a large
--- first sync converges in budget-sized chunks. opts.pull_only: refresh the
--- replica only (a search is waiting — push + proposals go at session start /
--- `memo org sync`). Never raises.
function M.maybe_sync(opts)
    if policy.role() ~= "dev" then return false end
    local t = os.time()
    if t < _next_check then return false end
    _next_check = t + M.THROTTLE_S
    local ok, res = pcall(function()
        local ttl = math.max(0, math.floor(tonumber(cfg().org_sync_ttl) or 900))
        local scope = M.org_scope()
        if scope then
            local now = util.now_us()
            local claim = db.first("UPDATE lm_federation_state SET last_pull_at = ? "
                .. "WHERE org_scope = ? AND (last_pull_at IS NULL OR last_pull_at <= ? "
                .. "OR (substr(last_error, 1, 13) = 'partial pull:' AND last_pull_at <= ?)) RETURNING org_scope",
                now, scope, now - ttl * 1000000, now - M.THROTTLE_S * 1000000)
            if not claim then return false end
        end
        local sopts = { budget_s = (opts and opts.budget_s) or 5, timeout_ms = (opts and opts.timeout_ms) or 3000 }
        if opts and opts.pull_only then return M.pull(sopts) end
        return M.sync(sopts)
    end)
    return ok and res or false
end

function M._reset_throttle() _next_check = 0 end   -- tests

function M.status()
    local scope = M.org_scope()
    local out = { role = policy.role(), org_url = cfg().org_url, org_scope = scope,
                  share = cfg().org_share or "triples", central_fingerprint = cfg().org_fingerprint }
    out.identity, out.identity_error = require("luamemo.federation.identity").resolve(cfg())
    local dpk = keys.public_key("dev")
    out.device_fingerprint = dpk and keys.fingerprint(dpk) or nil
    if scope then
        local st = state(scope) or {}
        local function iso(v) return type(v) == "number" and util.us_to_iso(v) or v end
        out.last_pull_at, out.last_error = iso(st.last_pull_at), st.last_error
        if st.last_pull_ok ~= nil then out.last_pull_ok = (st.last_pull_ok == 1) end
        out.last_push_at = iso(st.last_push_at)
        out.replica_rows = tonumber((db.value("SELECT count(*) FROM lm_memories WHERE scope = ?", scope))) or 0
    end
    return out
end

return M
