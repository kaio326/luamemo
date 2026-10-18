-- luamemo.federation.knowledge
-- Knowledge proposals, org-central side: the review queue and approved org
-- knowledge (see federation.proposals for what a dev proposes and why).
--
--   knowledge.ingest(identity, params) → { results = { {ref, status, proposal, memory, reason}, … } }
--       params.propose  — new / changed proposals; the central re-checks them
--                         (secret / personal content is refused, whatever the dev sent)
--       params.check    — refs whose status the dev wants to know
--       params.withdraw — refs the dev takes back
--     status: pending · approved (memory = org memory) · known (already in the
--     org — memory = that row) · rejected (incl. content rejected before) ·
--     refused · withdrawn
--   knowledge.list({status, limit}) / get(id)
--   knowledge.approve(id, by, {supersedes}) / approve_top(n, by) / reject(id, by, reason)
--   knowledge.remove(org memory id, by)
--   knowledge.used(memory id, event type) / seen_top(memory id) / floor(memory id)   (feedback hooks)
--
-- The queue: identical content (and, when the embedder answers, near-identical
-- content) from several devs merges into ONE item — support = how many devs
-- proposed it; content the admin rejected stays rejected until it changes.
-- Ordered by score × support. The admin's agent may summarise the queue; the
-- decision is the admin's (`memo org review`).
--
-- Approved → an org memory at a LOWER tier (1; digest can promote it to 2 —
-- tier 3 stays directive-only) that DECAYS (org_knowledge_decay, default
-- 0.01/day ≈ half weight after ~70 days unused), tagged with its project and
-- proposers (metadata.lm_org_knowledge). A proposal revising an approved memory
-- (the proposer's source changed, or `--supersedes`) updates it in place.
--
-- No silent loss: use keeps it alive — a praise / direct command / miss pushed
-- for it raises its importance and restarts its decay clock; being the top
-- result of a pushed retrieval restarts the clock (at most daily). Decay never
-- deletes it: approved knowledge is outside decay maintenance and bulk deletes
-- (policy), and a correction lowers it no further than tier 1 — so a faded or
-- corrected item ranks low but stays searchable, replicated, and revivable by
-- use. It leaves only by the admin's removal or by supersession.

local db      = require("luamemo.db")
local util    = require("luamemo.util")
local vectors = require("luamemo.vectors")
local rules   = require("luamemo.federation.proposals")

local M = {}

M.MAX_ITEMS     = 50       -- per list (propose / check / withdraw) per call
M.MAX_TITLE     = 300
M.MAX_BODY      = 4000
M.MAX_REF       = 128
M.MAX_GROUNDING = 30
M.MERGE_SIM     = 0.92     -- a pending item this close absorbs the proposal
M.KNOWN_SIM     = 0.95     -- an approved org memory this close = already known
M.TIER          = 1
M.IMPORTANCE    = 0.6
M.DEFAULT_DECAY = 0.01
M.USE_BUMP      = 0.05
M.USE_CAP       = 1.0

local KINDS = { fact = true, decision = true }
local POSITIVE = { praise = true, direct_command = true, miss = true }
local DAY_US = 86400 * 1000000

local function cfg() return require("luamemo").config end
local TBL = "lm_memories"
local function scope() return require("luamemo.federation.central").org_scope() end
local json = require("luamemo.json")

local clip = require("luamemo.federation.common").clip

-- Approved org knowledge (the key present, whatever its value).
local IS_KNOWLEDGE = "json_type(metadata, '$.lm_org_knowledge') IS NOT NULL"

local function decode(v)
    if type(v) == "table" then return v end
    local t = type(v) == "string" and json.decode(v)
    return type(t) == "table" and t or {}
end

-- Proposal / memory rows leave with their times as text.
local function out(r)
    if type(r) ~= "table" then return r end
    util.iso_fields(r, { "created_at", "updated_at", "decided_at" })
    r.embedding = nil
    return r
end

-- Vectors of different sizes come from different embedders: never similar.
local function cosine(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return 0 end
    return util.cosine(a, b)
end

local function embed(title, body)
    local ok, v = pcall(require("luamemo.embed").embed, title .. "\n" .. body)
    return ok and type(v) == "table" and v or nil
end

local vec_params = require("luamemo.federation.common").vec_params   -- a vector → BLOB, norm

function M.is_knowledge(meta)
    meta = decode(meta)
    return meta.lm_org_knowledge == true or meta.lm_org_knowledge == "true"
end

-- Approved org knowledge rows: { id, title, body, hash, vec? }.
local function knowledge_rows(s, with_vec)
    local out_rows = {}
    for _, r in ipairs(db.query("SELECT id, title, body" .. (with_vec and ", embedding AS v" or "") .. " FROM "
        .. TBL .. " WHERE scope = ? AND " .. IS_KNOWLEDGE, s) or {}) do
        out_rows[#out_rows + 1] = { id = tonumber(r.id), hash = rules.content_hash(r.title, r.body),
                                    vec = with_vec and vectors.unpack(r.v) or nil }
    end
    return out_rows
end

local function status_of(row)
    local st = row.status
    if st == "approved" then return "approved", tonumber(row.memory_id) end
    return st, nil
end

-- Remove one proposer (identity + ref) from a pending item; withdrawn when none is left.
local function drop_proposer(row, identity, ref)
    local kept, ids = {}, {}
    for _, p in ipairs(decode(row.proposers)) do
        if not (p.identity == identity and p.ref == ref) then kept[#kept + 1] = p; ids[p.identity] = true end
    end
    local support = 0
    for _ in pairs(ids) do support = support + 1 end
    db.run("UPDATE lm_org_proposals SET proposers = ?, support = ?, status = ?, updated_at = ? WHERE id = ?",
        json.encode(kept), math.max(support, 1), #kept == 0 and "withdrawn" or row.status, util.now_us(),
        tonumber(row.id))
end

local function add_proposer(row, identity, ref, score)
    local list = decode(row.proposers)
    local ids, present = {}, false
    for _, p in ipairs(list) do
        ids[p.identity] = true
        if p.identity == identity and p.ref == ref then present = true end
    end
    if not present then list[#list + 1] = { identity = identity, ref = ref, at = os.time() } end
    ids[identity] = true
    local support = 0
    for _ in pairs(ids) do support = support + 1 end
    db.run("UPDATE lm_org_proposals SET proposers = ?, support = ?, score = max(score, ?), updated_at = ? WHERE id = ?",
        json.encode(list), support, score, util.now_us(), tonumber(row.id))
end

--- Handle one dev call (see the header). Returns result, or nil, err, status.
function M.ingest(identity, p)
    local s = scope()
    if not s then return nil, "org central has no org_name", 500 end
    if cfg().org_proposals == false then return nil, "this org does not take knowledge proposals", 403 end
    if type(p) ~= "table" then return nil, "params must be an object", 400 end
    if p.share == "signals" then return nil, "proposals carry text — not accepted in signals mode", 400 end
    local propose, check, withdraw = p.propose or {}, p.check or {}, p.withdraw or {}
    if type(propose) ~= "table" or type(check) ~= "table" or type(withdraw) ~= "table" then
        return nil, "propose / check / withdraw must be arrays", 400
    end
    if #propose > M.MAX_ITEMS or #check > M.MAX_ITEMS or #withdraw > M.MAX_ITEMS then
        return nil, ("at most %d items per list"):format(M.MAX_ITEMS), 413
    end
    local results = {}
    local function result(ref, status, extra)
        local r = { ref = ref, status = status }
        for k, v in pairs(extra or {}) do r[k] = v end
        results[#results + 1] = r
    end
    -- The proposal this (identity, ref) is among the proposers of: looked up from the
    -- refs mirror (migration 005; CROSS JOIN keeps SQLite from walking the org's proposals).
    local function by_ref(ref)
        return db.first("SELECT p.* FROM lm_org_proposal_refs r CROSS JOIN lm_org_proposals p ON p.id = r.proposal_id "
            .. "WHERE r.identity = ? AND r.ref = ? AND p.org_scope = ? ORDER BY p.id DESC LIMIT 1", identity, ref, s)
    end

    for _, ref in ipairs(withdraw) do
        ref = clip(ref, M.MAX_REF)
        local row = ref and by_ref(ref)
        if row and row.status == "pending" then
            drop_proposer(row, identity, ref)
            result(ref, "withdrawn")
        elseif row then
            -- Decided meanwhile (e.g. approved before the withdrawal arrived): say so.
            local st, mem = status_of(row)
            result(ref, st, { proposal = tonumber(row.id), memory = mem, reason = row.reason })
        elseif ref then
            result(ref, "withdrawn")
        end
    end

    local known, pending
    for i, item in ipairs(propose) do
        local ref   = type(item) == "table" and clip(item.ref, M.MAX_REF)
        local title = type(item) == "table" and clip(item.title, M.MAX_TITLE)
        local body  = type(item) == "table" and clip(item.body, M.MAX_BODY)
        local kind  = type(item) == "table" and item.kind
        local project = type(item) == "table" and item.project
        if not ref then
            result("#" .. i, "refused", { reason = "ref required" })
        elseif not (title and body) or not KINDS[kind] then
            result(ref, "refused", { reason = "a fact / decision with a title and a body" })
        elseif project ~= nil and not (type(project) == "string" and project:match("^[%w][%w%._%-]*$") and #project <= 64) then
            result(ref, "refused", { reason = "invalid project name" })
        elseif rules.looks_secret(title .. "\n" .. body) then
            result(ref, "refused", { reason = "looks like it contains a secret" })
        elseif rules.looks_personal(title, body) then
            result(ref, "refused", { reason = "personal preference / style" })
        else
            local hash  = rules.content_hash(title, body)
            local score = math.max(0, math.min(5, tonumber(item.score) or 0))
            local grounding = {}
            if type(item.grounding) == "table" then
                for _, g in ipairs(item.grounding) do
                    local c = clip(g, 200)
                    if c and #grounding < M.MAX_GROUNDING then grounding[#grounding + 1] = c end
                end
            end
            local update_of = tonumber(item.update_of)
            if update_of then
                local t = db.first("SELECT metadata FROM " .. TBL .. " WHERE id = ? AND scope = ?", math.floor(update_of), s)
                if not (t and M.is_knowledge(t.metadata)) then update_of = nil end
            end
            if update_of then update_of = math.floor(update_of) end
            local rej = db.first("SELECT id FROM lm_org_proposals WHERE org_scope = ? AND content_hash = ? "
                .. "AND status = 'rejected' LIMIT 1", s, hash)
            local same = db.first("SELECT * FROM lm_org_proposals WHERE org_scope = ? AND content_hash = ? "
                .. "AND status = 'pending' ORDER BY id LIMIT 1", s, hash)
            local prev = by_ref(ref)
            known = known or knowledge_rows(s, true)
            local vec = embed(title, body)
            local hit
            if not update_of then
                for _, k in ipairs(known) do
                    if k.hash == hash or (vec and cosine(vec, k.vec) >= M.KNOWN_SIM) then hit = k.id; break end
                end
            end
            if rej then
                result(ref, "rejected", { proposal = tonumber(rej.id), reason = "rejected before (unchanged content)" })
            elseif hit then
                result(ref, "known", { memory = hit })
            elseif same then
                add_proposer(same, identity, ref, score)
                if prev and tonumber(prev.id) ~= tonumber(same.id) and prev.status == "pending" then
                    drop_proposer(prev, identity, ref)
                end
                result(ref, "pending", { proposal = tonumber(same.id) })
            else
                -- Near-identical pending item (another dev's wording) absorbs it.
                local near
                if vec and not update_of then
                    pending = pending or db.query("SELECT id, proposers, status, embedding AS v FROM "
                        .. "lm_org_proposals WHERE org_scope = ? AND status = 'pending' AND embedding IS NOT NULL", s) or {}
                    for _, r in ipairs(pending) do
                        if cosine(vec, vectors.unpack(r.v)) >= M.MERGE_SIM then near = r; break end
                    end
                end
                local blob, norm = vec_params(vec)
                local now = util.now_us()
                if near then
                    add_proposer(near, identity, ref, score)
                    if prev and tonumber(prev.id) ~= tonumber(near.id) and prev.status == "pending" then
                        drop_proposer(prev, identity, ref)
                    end
                    result(ref, "pending", { proposal = tonumber(near.id) })
                elseif prev and prev.status == "pending" and tonumber(prev.support) <= 1 then
                    -- The proposer's own pending item, reworded: revise it in place.
                    db.run("UPDATE lm_org_proposals SET title = ?, body = ?, kind = ?, project = ?, content_hash = ?, "
                        .. "embedding = ?, emb_norm = ?, score = ?, grounding = ?, update_of = ?, updated_at = ? "
                        .. "WHERE id = ?", title, body, kind, project, hash, blob, norm, score, json.encode(grounding),
                        update_of, now, tonumber(prev.id))
                    result(ref, "pending", { proposal = tonumber(prev.id) })
                else
                    if prev and prev.status == "pending" then drop_proposer(prev, identity, ref) end
                    local ins = db.first("INSERT INTO lm_org_proposals (org_scope, project, kind, title, body, "
                        .. "content_hash, embedding, emb_norm, score, support, proposers, grounding, update_of, "
                        .. "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?) RETURNING id",
                        s, project, kind, title, body, hash, blob, norm, score,
                        json.encode({ { identity = identity, ref = ref, at = os.time() } }),
                        json.encode(grounding), update_of, now, now)
                    local pid = ins and tonumber(ins.id)
                    if pid then
                        result(ref, "pending", { proposal = pid })
                        pending = nil   -- re-read with the new item next time
                    else
                        result(ref, "refused", { reason = "store failed" })
                    end
                end
            end
        end
    end

    for _, ref in ipairs(check) do
        ref = clip(ref, M.MAX_REF)
        if ref then
            local row = by_ref(ref)
            if not row then
                result(ref, "withdrawn")
            else
                local st, mem = status_of(row)
                result(ref, st, { proposal = tonumber(row.id), memory = mem, reason = row.reason })
            end
        end
    end
    return { results = results }
end

-- ---------------------------------------------------------------------------
-- Review (the admin)
-- ---------------------------------------------------------------------------

function M.list(opts)
    opts = opts or {}
    local st = opts.status or "pending"
    local limit = math.max(1, math.min(500, tonumber(opts.limit) or 50))
    local cols = "id, project, kind, title, body, score, support, proposers, grounding, status, "
        .. "update_of, memory_id, decided_by, decided_at, reason, created_at"
    local rows
    if st == "all" then
        rows = db.query("SELECT " .. cols .. " FROM lm_org_proposals WHERE org_scope = ? "
            .. "ORDER BY (score * support) DESC, id LIMIT ?", scope() or "", limit)
    else
        rows = db.query("SELECT " .. cols .. " FROM lm_org_proposals WHERE org_scope = ? AND status = ? "
            .. "ORDER BY (score * support) DESC, id LIMIT ?", scope() or "", st, limit)
    end
    for _, r in ipairs(rows or {}) do out(r) end
    return rows or {}
end

function M.get(id)
    id = tonumber(id)
    if not id then return nil end
    return out(db.first("SELECT * FROM lm_org_proposals WHERE id = ? AND org_scope = ?", math.floor(id), scope() or ""))
end

function M.counts()
    local res = {}
    for _, r in ipairs(db.query("SELECT status, count(*) AS n FROM lm_org_proposals WHERE org_scope = ? "
        .. "GROUP BY status", scope() or "") or {}) do
        res[r.status] = tonumber(r.n)
    end
    return res
end

--- Approve a pending proposal. opts.supersedes = an approved org memory it
--- replaces in place. → org memory id | nil, err
function M.approve(id, by, opts)
    opts = opts or {}
    local row = M.get(id)
    if not row then return nil, "no proposal " .. tostring(id) end
    if row.status ~= "pending" then return nil, "proposal " .. row.id .. " is " .. row.status end
    local s = scope()
    local store = require("luamemo.store")
    local proposers = {}
    for _, p in ipairs(decode(row.proposers)) do proposers[#proposers + 1] = p.identity end
    local target = tonumber(opts.supersedes) or tonumber(row.update_of)
    local mid
    if target then
        local t = store.get(target)
        if not (t and t.scope == s and M.is_knowledge(t.metadata)) then
            return nil, "memory " .. target .. " is not approved org knowledge"
        end
        local meta = decode(t.metadata)
        meta.project = row.project or meta.project
        meta.lm_proposal_id = tonumber(row.id)
        meta.proposers = proposers
        -- In place: same id (links + feedback history stay), new text, clock restarted.
        local u, err = store.update(target, { kind = row.kind, title = row.title, body = row.body, metadata = meta })
        if not u then return nil, err end
        mid = target
    else
        local tags = { "knowledge" }
        if row.project then tags[2] = row.project end
        local w, err = store.write({ scope = s, kind = row.kind, title = row.title, body = row.body, tags = tags,
            tier = M.TIER, importance = M.IMPORTANCE,
            decay_rate = tonumber(cfg().org_knowledge_decay) or M.DEFAULT_DECAY,
            metadata = { project = row.project, lm_org_knowledge = true, lm_proposal_id = tonumber(row.id),
                         proposers = proposers },
            dedup_strategy = "append" })
        if not w then return nil, err end
        mid = tonumber(w.id)
    end
    local now = util.now_us()
    db.run("UPDATE lm_org_proposals SET status = 'approved', memory_id = ?, decided_by = ?, decided_at = ?, "
        .. "updated_at = ? WHERE id = ?", mid, by or "admin", now, now, tonumber(row.id))
    return mid
end

--- Approve the N best pending proposals. → { {id, memory | error}, … }
function M.approve_top(n, by)
    local res = {}
    for _, r in ipairs(M.list({ status = "pending", limit = tonumber(n) or 1 })) do
        local mid, err = M.approve(r.id, by)
        res[#res + 1] = { id = tonumber(r.id), memory = mid, error = err }
    end
    return res
end

--- Reject a pending proposal: its content stays rejected until it changes.
function M.reject(id, by, reason)
    local row = M.get(id)
    if not row then return nil, "no proposal " .. tostring(id) end
    if row.status ~= "pending" then return nil, "proposal " .. row.id .. " is " .. row.status end
    local now = util.now_us()
    db.run("UPDATE lm_org_proposals SET status = 'rejected', decided_by = ?, decided_at = ?, reason = ?, "
        .. "updated_at = ? WHERE id = ?", by or "admin", now, reason, now, tonumber(row.id))
    return true
end

--- Remove approved org knowledge (the admin's decision — decay never does it).
--- Its proposals become rejected, so the same content isn't proposed again.
function M.remove(memory_id, by)
    local store = require("luamemo.store")
    local id = tonumber(memory_id)
    local t = id and store.get(id)
    if not (t and t.scope == scope() and M.is_knowledge(t.metadata)) then
        return nil, "memory " .. tostring(memory_id) .. " is not approved org knowledge"
    end
    local ok, err = store.delete(id)
    if not ok then return nil, err end
    local now = util.now_us()
    db.run("UPDATE lm_org_proposals SET status = 'rejected', reason = ?, decided_by = ?, decided_at = ?, "
        .. "updated_at = ? WHERE memory_id = ?", "removed from the org's memory", by or "admin", now, now, id)
    return true
end

-- ---------------------------------------------------------------------------
-- No silent loss (hooks from central.ingest_feedback)
-- ---------------------------------------------------------------------------

--- A positive use of org knowledge: importance up (bounded) + decay clock restarted.
function M.used(memory_id, event_type)
    if not POSITIVE[event_type] then return false end
    return db.first("UPDATE " .. TBL .. " SET importance = max(importance, min(?, importance + ?)), updated_at = ? "
        .. "WHERE id = ? AND scope = ? AND tier < 3 AND " .. IS_KNOWLEDGE .. " RETURNING id",
        M.USE_CAP, M.USE_BUMP, util.now_us(), tonumber(memory_id), scope() or "") ~= nil
end

--- After a correction (reversal) lowered it: approved knowledge stays at tier
--- >= 1 — it ranks lower, but stays replicated and visible, so later use can
--- revive it; only the admin removes it.
function M.floor(memory_id)
    db.run("UPDATE " .. TBL .. " SET tier = 1 WHERE id = ? AND scope = ? AND tier = 0 AND " .. IS_KNOWLEDGE,
        tonumber(memory_id), scope() or "")
end

--- The top result of a pushed retrieval: decay clock restarted (at most daily).
function M.seen_top(memory_id)
    local now = util.now_us()
    return db.first("UPDATE " .. TBL .. " SET updated_at = ? WHERE id = ? AND scope = ? AND tier < 3 AND "
        .. IS_KNOWLEDGE .. " AND updated_at < ? RETURNING id",
        now, tonumber(memory_id), scope() or "", now - DAY_US) ~= nil
end

return M
