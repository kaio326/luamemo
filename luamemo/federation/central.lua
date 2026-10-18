-- luamemo.federation.central
-- Org-central operations behind the federation endpoints (no HTTP here — see
-- federation.handlers for the transport-agnostic request layer).
--
--   central.info()                        → identification + embedder signature
--   central.snapshot({since, limit, vectors})
--        → one page of the org scope for a dev's read-only replica (rows at tier
--          >= 1, ordered by (updated_at, id) with a resumable cursor); the LAST
--          page also carries the full id manifest (so the dev can drop rows that
--          left the org) and the promoted learned weights for the org scope.
--   central.ingest_feedback(identity, payload)
--        → idempotently store a dev's pushed reinforcement events (+ retrieval
--          triples when shared), attributed to the dev, and apply each new
--          event's effect exactly once (tier policy: directives immune, the
--          rest capped at tier 2). Approved org knowledge is kept alive by use
--          (federation.knowledge.used / seen_top).
--
-- Requires role = "org" (luamemo.federation.policy) and a configured luamemo.

local db        = require("luamemo.db")
local util      = require("luamemo.util")
local vectors   = require("luamemo.vectors")
local common    = require("luamemo.federation.common")
local identity  = require("luamemo.federation.identity")
local knowledge = require("luamemo.federation.knowledge")

local M = {}

M.MAX_PAGE        = 1000
M.DEFAULT_PAGE    = 200
M.MAX_EVENTS      = 1000
M.MAX_RETRIEVALS  = 1000
M.MAX_QUERY_CHARS = 2000
M.MAX_CANDIDATES  = 100
M.MAX_NOTE_CHARS  = 200
M.MAX_REF_CHARS   = 128

local function cfg() return require("luamemo").config end
local TBL = "lm_memories"

function M.org_scope()
    local name = cfg().org_name
    return name and ("org:" .. name) or nil
end

-- Cursor = "<updated_at µs>:<id>" — strictly increasing over (updated_at, id).
local function parse_cursor(s)
    if s == nil or s == "" then return nil end
    local us, id = tostring(s):match("^(%d+):(%d+)$")
    if not us then return false end
    return tonumber(us), tonumber(id)
end

function M.info()
    local lm = require("luamemo")
    return {
        protocol     = common.PROTOCOL,
        org_scope    = M.org_scope(),
        org_name     = cfg().org_name,
        version      = lm.VERSION,
        embedder_sig = common.embedder_sig(cfg()),
        server_time  = os.time(),
        share        = { "triples", "signals" },
    }
end

-- Microsecond timestamps (the stored values) travel as decimal STRINGS: JSON encoders (cjson and
-- dkjson alike) emit 14 significant digits, which would round a ~1.8e15 µs
-- value to ~100 µs — breaking exact version compares and row-derived cursors.
local function us_str(v)
    local n = tonumber(v)
    return n and ("%d"):format(n) or nil
end

-- ids param: "1,2,3" / array → validated positive ints (≤ MAX_PAGE); false if malformed.
local function parse_ids(v)
    if v == nil or v == "" then return nil end
    local out = {}
    local items = {}
    if type(v) == "table" then items = v else for x in tostring(v):gmatch("[^,]+") do items[#items + 1] = x end end
    for _, x in ipairs(items) do
        local n = tonumber(x)
        if not n or n <= 0 or n ~= math.floor(n) then return false end
        out[#out + 1] = n
        if #out > M.MAX_PAGE then return false end
    end
    return out
end

--- One snapshot page. opts: since (cursor), limit (1..MAX_PAGE), vectors (bool),
--- ids (fetch exactly these org rows — the dev's repair path, see manifest).
--- The last page's manifest lists every row as { id, "updated_us" }: a dev
--- compares it with its replica and re-fetches any mismatch by `ids`, so the
--- replica converges even when a long transaction commits an updated_at older
--- than a cursor the dev already passed. Returns page table, or nil, err.
function M.snapshot(opts)
    opts = opts or {}
    local scope = M.org_scope()
    if not scope then return nil, "org central has no org_name" end
    local limit = math.floor(tonumber(opts.limit) or M.DEFAULT_PAGE)
    if limit < 1 then limit = 1 elseif limit > M.MAX_PAGE then limit = M.MAX_PAGE end
    local since_us, since_id = parse_cursor(opts.since)
    if since_us == false then return nil, "invalid cursor" end
    local ids = parse_ids(opts.ids)
    if ids == false then return nil, ("invalid ids (positive integers, at most %d)"):format(M.MAX_PAGE) end

    local cols = "id, kind, title, body, tags, metadata, importance, decay_rate, tier, "
        .. "created_at AS c_us, updated_at AS u_us"
    if opts.vectors then cols = cols .. ", embedding AS vec" end
    local where, params = { "scope = ?", "tier >= 1" }, { scope }
    if ids then
        if #ids == 0 then return nil, "invalid ids" end
        where[#where + 1] = "id IN (" .. db.placeholders(#ids) .. ")"
        for _, id in ipairs(ids) do params[#params + 1] = id end
        limit = #ids
    elseif since_us then
        where[#where + 1] = "(updated_at, id) > (?, ?)"
        params[#params + 1] = since_us
        params[#params + 1] = since_id
    end
    params[#params + 1] = limit + 1
    local rows, qerr = db.query(("SELECT %s FROM %s WHERE %s ORDER BY u_us ASC, id ASC LIMIT ?")
        :format(cols, TBL, table.concat(where, " AND ")), unpack(params, 1, #params))
    if not rows then return nil, "snapshot: " .. tostring(qerr) end

    local more = #rows > limit
    local out = {}
    for i = 1, math.min(#rows, limit) do
        local r = rows[i]
        local item = {
            id = tonumber(r.id), kind = r.kind, title = r.title, body = r.body,
            tags = (type(r.tags) == "table") and r.tags or {},
            metadata = (type(r.metadata) == "table") and r.metadata or {},
            importance = tonumber(r.importance), decay_rate = tonumber(r.decay_rate),
            tier = tonumber(r.tier), created_us = us_str(r.c_us), updated_us = us_str(r.u_us),
        }
        if opts.vectors then item.vector = vectors.unpack(r.vec) end
        out[#out + 1] = item
    end
    local page = {
        protocol     = common.PROTOCOL,
        org_scope    = scope,
        embedder_sig = common.embedder_sig(cfg()),
        rows         = out,
    }
    if ids then return page end   -- repair fetch: rows only, no cursor / manifest

    local last = out[#out]
    page.more   = more
    page.cursor = last and (last.updated_us .. ":" .. ("%d"):format(last.id)) or (opts.since or "")
    if not more then
        local mrows = db.query("SELECT id, updated_at AS u_us FROM " .. TBL
            .. " WHERE scope = ? AND tier >= 1 ORDER BY id", scope)
        local manifest = {}
        for _, r in ipairs(mrows or {}) do manifest[#manifest + 1] = { tonumber(r.id), us_str(r.u_us) } end
        -- A dev whose replica already matches (same digest) gets no list: an idle
        -- sync then ships O(1), not O(rows). (Hashed only when a digest came.)
        if type(opts.manifest_digest) == "string"
            and opts.manifest_digest == common.manifest_digest(manifest) then
            page.manifest_same = true
        else
            page.manifest = manifest
        end
        local ls = require("luamemo.learner_store")
        local weights = {}
        for _, kind in ipairs(common.WEIGHT_KINDS) do
            local v = ls.current_version(scope, kind)
            if v then weights[kind] = { version = v, weights = ls.load_current(scope, kind) } end
        end
        page.weights = weights
    end
    return page
end

local function int_or_nil(x)
    local n = tonumber(x)
    if n and n == math.floor(n) and n > 0 then return n end
    return nil
end

local clip = common.clip

--- Ingest a dev push. `bound` = the identity the credential is bound to (nil
--- for a shared token). Returns result table, or nil, err, http_status.
function M.ingest_feedback(dev_identity, payload, bound)
    local scope = M.org_scope()
    if not scope then return nil, "org central has no org_name", 500 end
    if type(payload) ~= "table" then return nil, "body must be a JSON object", 400 end

    if type(dev_identity) ~= "string" or not dev_identity:match("^user:")
       or not identity._valid_email(dev_identity:sub(6)) then
        return nil, "identity must be user:<email>", 400
    end
    dev_identity = dev_identity:lower()
    if bound and bound ~= dev_identity then
        return nil, "identity does not match the credential", 403
    end

    local events     = payload.events or {}
    local retrievals = payload.retrievals or {}
    if type(events) ~= "table" or type(retrievals) ~= "table" then
        return nil, "events / retrievals must be arrays", 400
    end
    if #events > M.MAX_EVENTS or #retrievals > M.MAX_RETRIEVALS then
        return nil, ("at most %d events and %d retrievals per push"):format(M.MAX_EVENTS, M.MAX_RETRIEVALS), 413
    end
    local share = (payload.share == "signals") and "signals" or "triples"

    -- Which referenced ids are org memories on this central (one query).
    local want = {}
    for _, e in ipairs(events) do
        local id = type(e) == "table" and int_or_nil(e.memory)
        if id then want[id] = true end
    end
    if share == "triples" then
        for _, r in ipairs(retrievals) do
            if type(r) == "table" and type(r.candidates) == "table" then
                for i = 1, math.min(#r.candidates, M.MAX_CANDIDATES) do
                    local id = int_or_nil(r.candidates[i])
                    if id then want[id] = true end
                end
            end
        end
    end
    local id_list = {}
    for id in pairs(want) do id_list[#id_list + 1] = id end
    local valid = {}
    if #id_list > 0 then
        local in_ids, ids_json = db.in_list(id_list)   -- up to 101,000 ids
        local rows = db.query("SELECT id FROM " .. TBL .. " WHERE scope = ? AND id IN " .. in_ids, scope, ids_json)
        for _, r in ipairs(rows or {}) do valid[tonumber(r.id)] = true end
    end

    local res = { accepted_events = 0, accepted_retrievals = 0, duplicates = 0, rejected = {} }
    local function reject(kind, i, why)
        if #res.rejected < 50 then res.rejected[#res.rejected + 1] = { kind = kind, index = i, reason = why } end
    end
    local digest = require("luamemo.digest")

    for i, e in ipairs(events) do
        local mid  = type(e) == "table" and int_or_nil(e.memory)
        local ref  = type(e) == "table" and clip(e.ref, M.MAX_REF_CHARS)
        local kind = type(e) == "table" and e.type
        if not mid or not valid[mid] then reject("event", i, "memory is not in " .. scope)
        elseif not common.EVENT_TYPES[kind] then reject("event", i, "unknown event type")
        elseif not ref or ref == "" then reject("event", i, "ref required (idempotency key)")
        else
            local delta = math.max(-1.0, math.min(1.0, tonumber(e.delta) or 0.5))
            -- signals mode: no free text at all, whatever the client sent
            local note  = (share == "triples") and clip(e.note, M.MAX_NOTE_CHARS) or nil
            local rows = db.query("INSERT INTO lm_reinforcements "
                .. "(memory_id, scope, event_type, delta, note, source, source_ref, created_at) "
                .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
                .. "ON CONFLICT (source, source_ref) WHERE source_ref IS NOT NULL DO NOTHING RETURNING id",
                mid, scope, kind, delta, note, dev_identity, ref, util.now_us())
            if rows and rows[1] then
                res.accepted_events = res.accepted_events + 1
                digest.apply_event_effect(mid, scope, kind, delta)   -- once: only on a new row
                if delta > 0 then knowledge.used(mid, kind) end      -- approved knowledge: use keeps it alive
                if kind == "reversal" then knowledge.floor(mid) end  -- …and a correction never hides it
            elseif rows then
                res.duplicates = res.duplicates + 1
            else
                reject("event", i, "store failed")
            end
        end
    end

    if share == "triples" then
        for i, r in ipairs(retrievals) do
            local query = type(r) == "table" and clip(r.query, M.MAX_QUERY_CHARS)
            local ref   = type(r) == "table" and clip(r.ref, M.MAX_REF_CHARS)
            local cands = {}
            if type(r) == "table" and type(r.candidates) == "table" then
                for j = 1, math.min(#r.candidates, M.MAX_CANDIDATES) do
                    local id = int_or_nil(r.candidates[j])
                    if id and valid[id] then cands[#cands + 1] = id end
                end
            end
            if not query or query == "" then reject("retrieval", i, "query required")
            elseif not ref or ref == "" then reject("retrieval", i, "ref required (idempotency key)")
            elseif #cands == 0 then reject("retrieval", i, "no candidate is in " .. scope)
            else
                local rows = db.query("INSERT INTO lm_retrieval_feedback "
                    .. "(scope, query, candidate_ids, source, source_ref, created_at) "
                    .. "VALUES (?, ?, ?, ?, ?, ?) "
                    .. "ON CONFLICT (source, source_ref) WHERE source_ref IS NOT NULL DO NOTHING RETURNING id",
                    scope, query, db.json(cands), dev_identity, ref, util.now_us())
                if rows and rows[1] then
                    res.accepted_retrievals = res.accepted_retrievals + 1
                    -- The dev's top result was this org row: its decay clock restarts.
                    local top = int_or_nil(r.top)
                    if top and valid[top] then knowledge.seen_top(top) end
                elseif rows then res.duplicates = res.duplicates + 1
                else reject("retrieval", i, "store failed") end
            end
        end
    end
    res.share = share
    return res
end

M._parse_cursor = parse_cursor   -- tests

return M
