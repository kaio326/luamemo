-- luamemo.federation.adopt
-- Bring a project's memories from its own (solo) database into the org
-- database this machine uses for an org, so all of that org's projects share
-- one local database.
--
--   adopt.run(source, target, opts) → report | nil, err     (database names or paths)
--     opts.dry_run    → count only, write nothing
--     opts.same_space → false when the two databases' embedders differ (vectors
--                       of two models never compare, even at the same size)
--     opts.embed      → function(text) → vector, embedding with the TARGET's
--                       embedder; used whenever vectors can't be copied (rows it
--                       can't embed get none — report.unembedded — and are
--                       re-embedded later with `memo reembed`)
--
-- COPIES — the source database is opened read-only, never modified — and is
-- idempotent: every copied memory carries metadata.lm_adopted_from = "<source
-- tag>:<old id>", and a re-run skips those. Copied: every non-org scope's memories
-- (org: rows are a replica — they re-sync), their reinforcements, retrieval events
-- (candidate ids remapped, events with no copied candidate dropped),
-- knowledge-graph facts (deduplicated, source_memory_id remapped), observations
-- (deduplicated, evidence remapped) and learned weights (only for scope/kind pairs
-- the target doesn't have yet). No double push: a dev pushes only events that
-- touch org replica rows, and those are never copied. Vectors are copied only when
-- both databases share the embedding space (same embedder, same dimension).
-- A database's identity is its own random id (lm_meta.db_id), whatever path
-- reaches it.

local db      = require("luamemo.db")
local util    = require("luamemo.util")
local vectors = require("luamemo.vectors")

local M = {}

M.PAGE = 300

local int_list = require("luamemo.federation.common").int_array
local vec_params = require("luamemo.federation.common").vec_params   -- a vector → BLOB, norm

local function meta(conn, key) return conn.value("SELECT value FROM lm_meta WHERE key = ?", key) end

function M.run(source, target, opts)
    opts = opts or {}
    local src, serr = db.open(source, { readonly = true })
    if not src then return nil, "source database: " .. tostring(serr) end
    local tgt, terr = db.open(target)
    if not tgt then src.close(); return nil, "org database: " .. tostring(terr) end
    local ok, report, err = pcall(function()
        local sid, tid = meta(src, "db_id"), meta(tgt, "db_id")
        if not sid then return nil, "the source is not a luamemo database" end
        if sid == tid then return nil, "the project already uses the org database — nothing to adopt" end
        local tag = sid:sub(1, 12)
        local sdim, tdim = tonumber(meta(src, "embed_dim")), tonumber(meta(tgt, "embed_dim"))
        -- Same embedder + same dimension → vectors copy as-is.
        local copy_vectors = opts.same_space ~= false and sdim ~= nil and (tdim == nil or tdim == sdim)
        local rep = { memories = 0, skipped = 0, reinforcements = 0, retrievals = 0, facts = 0, observations = 0,
                      weights = 0, reembedded = 0, unembedded = 0, dry_run = opts.dry_run and true or false }
        local copied_dim   -- the size of the vectors written (fixes the target's dimension when it has none)

        -- Already adopted from this source (re-runs skip them).
        local map = require("luamemo.federation.common").origin_map(tgt, "lm_adopted_from", tag)
        local fresh = {}   -- old ids copied in THIS run (their reinforcements follow)

        local function vector_for(emb, text)
            if copy_vectors and type(emb) == "string" and #emb > 0 then
                local v = vectors.unpack(emb)
                return v, false
            elseif not copy_vectors and opts.embed then
                local v = opts.embed(text)
                if type(v) == "table" and #v > 0 and (not tdim or #v == tdim) then return v, true end
            end
            return nil, false
        end

        local cursor = 0
        while true do
            local rows = src.query("SELECT id, scope, kind, title, body, tags, metadata, embedding, importance, "
                .. "decay_rate, was_truncated, tier, created_at, updated_at, consolidated_at FROM lm_memories "
                .. "WHERE scope NOT GLOB 'org:*' AND id > ? ORDER BY id LIMIT ?", cursor, M.PAGE) or {}
            if #rows == 0 then break end
            local ok_page, perr = (opts.dry_run and function(f) f(); return true end or tgt.transaction)(function()
                for _, r in ipairs(rows) do
                    local old = tonumber(r.id)
                    cursor = old
                    if map[old] then
                        rep.skipped = rep.skipped + 1
                    elseif opts.dry_run then
                        rep.memories = rep.memories + 1
                    else
                        local m = type(r.metadata) == "table" and r.metadata or {}
                        m.lm_adopted_from = tag .. ":" .. old
                        local v, reembedded = vector_for(r.embedding, (r.title or "") .. "\n" .. (r.body or ""))
                        if v then
                            copied_dim = copied_dim or #v
                            if reembedded then rep.reembedded = rep.reembedded + 1 end
                        elseif not copy_vectors then
                            rep.unembedded = rep.unembedded + 1
                        end
                        local blob, norm = vec_params(v)
                        local ins = tgt.first("INSERT INTO lm_memories (scope, kind, title, body, tags, metadata, "
                            .. "embedding, emb_norm, importance, decay_rate, was_truncated, tier, created_at, updated_at, "
                            .. "consolidated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id",
                            r.scope, r.kind or "fact", r.title or "", r.body or "",
                            db.json(type(r.tags) == "table" and r.tags or {}), db.json(m), blob, norm,
                            tonumber(r.importance) or 1, tonumber(r.decay_rate) or 0, tonumber(r.was_truncated) or 0,
                            tonumber(r.tier) or 1, r.created_at, r.updated_at, r.consolidated_at)
                        local nid = ins and tonumber(ins.id)
                        if not nid then error("could not copy memory " .. old, 0) end
                        map[old], fresh[#fresh + 1] = nid, old
                        rep.memories = rep.memories + 1
                    end
                end
            end)
            if not ok_page then error(perr, 0) end
        end
        if opts.dry_run then return rep end
        if copied_dim and not tdim then
            tgt.run("INSERT OR IGNORE INTO lm_meta (key, value) VALUES ('embed_dim', ?)", tostring(copied_dim))
        end

        local ok_rest, rerr = tgt.transaction(function()
            -- Reinforcements of the memories copied now (older ones came with them before).
            for i = 1, #fresh, 500 do
                local ids = {}
                for j = i, math.min(#fresh, i + 499) do ids[#ids + 1] = fresh[j] end
                for _, r in ipairs(src.query("SELECT memory_id, scope, event_type, delta, note, created_at "
                    .. "FROM lm_reinforcements WHERE memory_id IN (" .. db.placeholders(#ids) .. ")",
                    unpack(ids, 1, #ids)) or {}) do
                    assert(tgt.run("INSERT INTO lm_reinforcements (memory_id, scope, event_type, delta, note, "
                        .. "created_at) VALUES (?, ?, ?, ?, ?, ?)", map[tonumber(r.memory_id)], r.scope,
                        r.event_type, tonumber(r.delta) or 0.5, r.note, r.created_at))
                    rep.reinforcements = rep.reinforcements + 1
                end
            end

            -- Retrieval events whose candidates include a memory copied now.
            local fresh_set = {}
            for _, old in ipairs(fresh) do fresh_set[old] = true end
            if #fresh > 0 then
                for _, r in ipairs(src.query("SELECT scope, query, candidate_ids, created_at FROM lm_retrieval_feedback "
                    .. "WHERE scope NOT GLOB 'org:*'") or {}) do
                    local cands, touches = {}, false
                    for _, c in ipairs(int_list(r.candidate_ids)) do
                        if fresh_set[c] then touches = true end
                        if map[c] then cands[#cands + 1] = map[c] end
                    end
                    if touches and #cands > 0 then
                        assert(tgt.run("INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids, created_at) "
                            .. "VALUES (?, ?, ?, ?)", r.scope, r.query, db.json(cands), r.created_at))
                        rep.retrievals = rep.retrievals + 1
                    end
                end
            end

            -- Knowledge-graph facts (deduplicated).
            for _, r in ipairs(src.query("SELECT scope, subject, predicate, object, valid_from, valid_until, "
                .. "source_memory_id, created_at FROM lm_kg_facts WHERE scope NOT GLOB 'org:*'") or {}) do
                if not tgt.value("SELECT 1 FROM lm_kg_facts WHERE scope = ? AND subject = ? AND predicate = ? "
                        .. "AND object = ? LIMIT 1", r.scope, r.subject, r.predicate, r.object) then
                    assert(tgt.run("INSERT INTO lm_kg_facts (scope, subject, predicate, object, valid_from, "
                        .. "valid_until, source_memory_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                        r.scope, r.subject, r.predicate, r.object, r.valid_from or util.now_us(), r.valid_until,
                        map[tonumber(r.source_memory_id or -1)], r.created_at or util.now_us()))
                    rep.facts = rep.facts + 1
                end
            end

            -- Observations (consolidated beliefs — the copied memories keep their
            -- consolidated_at, so they would not be re-derived): evidence remapped,
            -- deduplicated by (scope, body); vectors like the memories'.
            for _, r in ipairs(src.query("SELECT scope, body, proof_count, evidence_ids, evidence_quotes, "
                .. "freshness_trend, last_reinforced, created_at, importance, embedding "
                .. "FROM lm_observations WHERE scope NOT GLOB 'org:*' ORDER BY id") or {}) do
                if not tgt.value("SELECT 1 FROM lm_observations WHERE scope = ? AND body = ? LIMIT 1", r.scope, r.body) then
                    local ev = {}
                    for _, old in ipairs(int_list(r.evidence_ids)) do
                        if map[old] then ev[#ev + 1] = map[old] end
                    end
                    local blob, norm = vec_params((vector_for(r.embedding, r.body or "")))
                    assert(tgt.run("INSERT INTO lm_observations (scope, body, proof_count, evidence_ids, "
                        .. "evidence_quotes, freshness_trend, last_reinforced, created_at, importance, embedding, "
                        .. "emb_norm) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", r.scope, r.body,
                        math.max(1, tonumber(r.proof_count) or 1), db.json(ev),
                        db.json(type(r.evidence_quotes) == "table" and r.evidence_quotes or {}),
                        r.freshness_trend or "new", r.last_reinforced or util.now_us(),
                        r.created_at or util.now_us(), tonumber(r.importance) or 0.5, blob, norm))
                    rep.observations = rep.observations + 1
                end
            end

            -- Learned weights: every version of a scope + kind the target had NONE of
            -- before this run (never mixed into an existing version history).
            local present = {}
            for _, r in ipairs(tgt.query("SELECT DISTINCT scope, kind FROM lm_learner_weights") or {}) do
                present[r.scope .. "\0" .. r.kind] = true
            end
            for _, r in ipairs(src.query("SELECT scope, kind, version, weights, score, note, is_current, created_at "
                .. "FROM lm_learner_weights WHERE scope NOT GLOB 'org:*'") or {}) do
                if not present[r.scope .. "\0" .. r.kind] then
                    assert(tgt.run("INSERT INTO lm_learner_weights (scope, kind, version, weights, score, note, "
                        .. "is_current, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", r.scope, r.kind,
                        tonumber(r.version) or 1, db.json(r.weights), r.score, r.note, tonumber(r.is_current) or 0,
                        r.created_at))
                    rep.weights = rep.weights + 1
                end
            end
        end)
        if not ok_rest then error(rerr, 0) end
        return rep
    end)
    src.close(); tgt.close()
    if not ok then return nil, tostring(report) end
    return report, err
end

return M
