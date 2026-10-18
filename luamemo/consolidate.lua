-- luamemo.consolidate
--
-- Plan 9: Observation Consolidation — Evidence-Tracked Beliefs.
--
-- Clusters unprocessed memories for a scope by cosine similarity, then
-- either reinforces an existing observation (cheap UPDATE) or synthesises a
-- new one via the configured summarizer adapter (one LLM call per new
-- cluster). Also provides a search leg that surfaces observations alongside
-- regular memories in store.search().
--
-- Public API:
--   consolidate.configure(config)         -- called by M.setup()
--   consolidate.notify(scope)             -- fast, no DB; sets pending flag
--   consolidate.process(scope)            -- runs clustering + reinforcement
--   consolidate.search(scope, qvec, lim)  -- observation search leg

local db      = require("luamemo.db")
local embed   = require("luamemo.embed")
local util    = require("luamemo.util")
local vectors = require("luamemo.vectors")

local M = {}

local cfg              = nil
local _pending         = {}        -- [scope] = true when a write has occurred
local _adapter_cache   = {}        -- [name] -> summarizer module

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Compute freshness_trend from the epoch of last_reinforced and proof_count.
local function _freshness_trend(last_epoch, proof_count)
    local days = (os.time() - last_epoch) / 86400
    if days < 7  and proof_count >= 3 then return "strengthening" end
    if days < 30                       then return "stable"        end
    if days < 90                       then return "weakening"     end
    return "stale"
end

-- Detect negation language in a memory body (pure Lua string scan).
local NEGATION_MARKS = {
    "no longer", "not ", " not$", "stopped", "won't", "changed",
    "instead", "reversed", "removed", "dropped", "deprecated",
}
local function _has_negation(body)
    local lower = body:lower()
    for _, pat in ipairs(NEGATION_MARKS) do
        if lower:find(pat, 1, true) then return true end
    end
    return false
end

-- Proof-count multiplicative boost for observation search scores.
-- Asymptotes towards 1.05 from above/below; centre at proof_count=1.
local function _proof_boost(proof_count)
    local norm = math.max(0, math.min(1, 0.5 + math.log(math.max(1, proof_count)) / 10))
    return 1 + 0.1 * (norm - 0.5)   -- α=0.1, ±5%
end

-- Apply 0.85× to stale observations rather than excluding them.
local function _freshness_multiplier(trend)
    if trend == "stale" then return 0.85 end
    return 1.0
end

-- A stored timestamp (µs) → the Unix epoch of its UTC day (freshness is
-- measured in whole days since that midnight).
local function _ts_to_epoch(us)
    us = tonumber(us)
    if not us then return 0 end
    return math.floor(us / 86400000000) * 86400
end

local function _ids(list)
    local out = {}
    for _, id in ipairs(list or {}) do
        if tonumber(id) then out[#out + 1] = math.floor(tonumber(id)) end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Summarizer dispatch (reuses summarizers adapter cache pattern)
-- ---------------------------------------------------------------------------
local function _load_adapter(name)
    return util.load_submodule(_adapter_cache, "luamemo.summarizers", name, "summarize")
end

-- Synthesise a belief body from a cluster of memories.
-- Uses the configured summarizer when available and not "noop".
-- Falls back to the body of the highest-importance memory in the cluster.
local function _synthesize(cluster)
    -- Fall back when no LLM is configured.
    local adapter_name = cfg and cfg.summarizer_adapter
    if not adapter_name or adapter_name == "noop" or adapter_name == "" then
        -- Use the body of the highest-importance memory.
        local best = cluster[1]
        for _, m in ipairs(cluster) do
            if (m.importance or 0) > (best.importance or 0) then best = m end
        end
        return best.body, nil
    end

    local adapter, aerr = _load_adapter(adapter_name)
    if not adapter then
        -- Adapter unavailable; fall back gracefully.
        local best = cluster[1]
        for _, m in ipairs(cluster) do
            if (m.importance or 0) > (best.importance or 0) then best = m end
        end
        return best.body, aerr
    end

    local result, serr = adapter.summarize(cluster, cfg)
    if not result then
        -- Synthesis failed; fall back to highest-importance body.
        local best = cluster[1]
        for _, m in ipairs(cluster) do
            if (m.importance or 0) > (best.importance or 0) then best = m end
        end
        return best.body, serr
    end

    local body = result.body or result.title or ""
    return body, nil
end

-- ---------------------------------------------------------------------------
-- DB helpers
-- ---------------------------------------------------------------------------

-- Fetch all unprocessed memories for a scope (consolidated_at IS NULL)
-- including their embedding vectors.
local function _fetch_unprocessed(scope, limit, tier_min)
    local sql = "SELECT id, body, title, importance, embedding FROM lm_memories "
        .. "WHERE scope = ? AND consolidated_at IS NULL AND embedding IS NOT NULL"
        .. (tier_min and (" AND tier >= " .. math.floor(tier_min)) or "") .. " ORDER BY id"
    local rows = (limit and db.query(sql .. " LIMIT ?", scope, limit) or db.query(sql, scope)) or {}
    for _, r in ipairs(rows) do r.embedding = vectors.unpack(r.embedding) end
    return rows
end

-- A scanned row's vector norm: its emb_norm column, or computed from the vector (a row
-- stored without one) — nil for no vector.
local function _row_norm(r, col, p, bytes)
    local norm = r:type(col) ~= 5 and r:double(col) or nil
    if norm and norm > 0 then return norm end
    if p == nil or bytes == 0 then return nil end
    return vectors.query(vectors.unpack(require("luamemo.native.loader").ffi.string(p, bytes)) or {}).norm
end

-- The scope's observations (without their vectors, most recently reinforced first) and
-- each cluster's closest one: a single pass, every stored vector scored where it lies
-- against each cluster's pivot (vectors.cosine_ptr). They were all unpacked into Lua
-- tables and scored in Lua on every run — the first search after any write: 37 ms at
-- 1,575 observations. → observations, closest[ci] = { obs = row, sim = cosine }
local function _observations_near(scope, clusters)
    local qs = {}
    for ci, cl in ipairs(clusters) do
        local v = cl[1].embedding
        qs[ci] = type(v) == "table" and #v > 0 and vectors.query(v) or false
    end
    local observations, closest = {}, {}
    db.scan("SELECT id, proof_count, freshness_trend, last_reinforced, embedding, emb_norm FROM lm_observations "
        .. "WHERE scope = ? ORDER BY last_reinforced DESC, id DESC", { scope }, function(r)
        local obs = { id = r:int(0), proof_count = r:int(1), freshness_trend = r:value(2),
                      last_reinforced = r:int(3) }
        observations[#observations + 1] = obs
        if r:type(4) ~= 4 then return end
        local p, bytes = r:blob_ptr(4)
        local norm = _row_norm(r, 5, p, bytes)
        for ci = 1, #qs do
            local sim = qs[ci] and vectors.cosine_ptr(p, bytes, norm, qs[ci]) or 0
            if sim > (closest[ci] and closest[ci].sim or 0) then closest[ci] = { obs = obs, sim = sim } end
        end
    end)
    return observations, closest
end

-- Mark a batch of memory ids as consolidated (set consolidated_at = now).
local function _mark_consolidated(ids)
    ids = _ids(ids)
    if #ids == 0 then return end
    local params = { util.now_us() }
    for _, id in ipairs(ids) do params[#params + 1] = id end
    assert(db.run("UPDATE lm_memories SET consolidated_at = ? WHERE id IN (" .. db.placeholders(#ids) .. ")",
        unpack(params, 1, #params)))
end

local function _append(list, more)
    local out = {}
    for _, v in ipairs(type(list) == "table" and list or {}) do out[#out + 1] = v end
    for _, v in ipairs(more or {}) do out[#out + 1] = v end
    return out
end

-- Reinforce an existing observation: increment proof_count, update
-- evidence_ids, and recalculate freshness_trend.
local function _reinforce(obs_id, new_ids, new_quotes, last_epoch)
    local ok, err = db.transaction(function(h)
        local cur = h.first("SELECT evidence_ids, evidence_quotes FROM lm_observations WHERE id = ?",
            math.floor(tonumber(obs_id) or 0))
        if not cur then error("observation " .. tostring(obs_id) .. " not found", 0) end
        local n, uerr = h.run("UPDATE lm_observations SET proof_count = proof_count + ?, evidence_ids = ?, "
            .. "evidence_quotes = ?, freshness_trend = ?, last_reinforced = ? WHERE id = ?",
            #new_ids, db.json(_append(cur.evidence_ids, _ids(new_ids))),
            db.json(_append(cur.evidence_quotes, new_quotes)),
            _freshness_trend(last_epoch, 0),  -- approx; real count unknown here
            util.now_us(), math.floor(tonumber(obs_id) or 0))
        if not n then error(uerr, 0) end
    end)
    if not ok then error("reinforce obs db error: " .. tostring(err)) end
end

-- Update freshness_trend for an observation based on its current proof_count
-- and last_reinforced timestamp.
local function _refresh_trend(obs)
    if not obs or not obs.id then return end
    local epoch = _ts_to_epoch(obs.last_reinforced)
    local trend = _freshness_trend(epoch, tonumber(obs.proof_count) or 1)
    if trend == obs.freshness_trend then return end
    db.run("UPDATE lm_observations SET freshness_trend = ? WHERE id = ?", trend, math.floor(tonumber(obs.id) or 0))
end

-- Insert a new observation row.
local function _insert_obs(scope, body, evidence_ids, evidence_quotes, obs_vec, imp)
    local blob, norm = vectors.pack(obs_vec)
    local now = util.now_us()
    local n, qerr = db.run("INSERT INTO lm_observations (scope, body, proof_count, evidence_ids, evidence_quotes, "
        .. "freshness_trend, importance, embedding, emb_norm, last_reinforced, created_at) "
        .. "VALUES (?, ?, ?, ?, ?, 'new', ?, ?, ?, ?, ?)",
        scope, body, math.max(1, #evidence_ids), db.json(_ids(evidence_ids)), db.json(evidence_quotes or {}),
        math.min(10.0, math.max(0.0, imp or 0.5)), db.blob(blob), norm, now, now)
    if not n then error("insert obs db error: " .. tostring(qerr)) end
end

-- ---------------------------------------------------------------------------
-- Clustering
-- ---------------------------------------------------------------------------

-- Greedy single-linkage clustering.
-- Assigns each memory to the first existing cluster whose centroid (first
-- member) has cosine similarity >= threshold.  New memories start their own
-- cluster if none qualifies.
-- Returns a list of lists, each inner list being memory rows.
-- _cluster and _cosine are provided by util.cluster / util.cosine.

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.configure(config)
    cfg = config
    _pending = {}
end

--- Mark a scope as having unprocessed writes.  Fast, no DB.
--- Called by store.write() and store.write_many().
function M.notify(scope)
    if scope then _pending[scope] = true end
end

--- Check whether a scope has pending unprocessed writes.
function M.pending(scope)
    return _pending[scope] == true
end

--- Run the consolidation pipeline for a scope.
--- Fetches memories with consolidated_at IS NULL, clusters them by cosine
--- similarity, then either reinforces an existing observation or synthesises
--- a new one.  Marks all processed memories as consolidated.
---
--- opts.limit: at most that many memories (the oldest), the scope left pending while more
--- remain — what a search runs inline: the whole backlog there (clustering is O(n ×
--- clusters) in Lua) stalled the search after a bulk write (9 s after 5,000 rows).
--- opts.tier_min: only memories of that tier or above (a search: 1 — tier 0 is the digest's).
---
--- Returns a summary table:
---   { reinforced = N, synthesised = N, errors = {...} }
function M.process(scope, opts)
    if not cfg then return { reinforced = 0, synthesised = 0, errors = {"consolidate: not configured"} } end

    -- Clear the pending flag first so concurrent writes queue a follow-up run.
    _pending[scope] = nil

    -- Federation: a dev's org replica mirrors the central, which consolidates it.
    if require("luamemo.federation.policy").replica(scope) then
        return { reinforced = 0, synthesised = 0, errors = {}, skipped = "replica" }
    end

    local result = { reinforced = 0, synthesised = 0, errors = {} }

    local limit = opts and tonumber(opts.limit)
    local memories = _fetch_unprocessed(scope, limit, opts and tonumber(opts.tier_min))
    if #memories == 0 then return result end
    if limit and #memories >= limit then _pending[scope] = true end   -- more remain: the next call goes on

    -- Cluster unprocessed memories.
    local threshold = (cfg.consolidate_threshold) or 0.80
    local clusters  = util.cluster(memories, threshold)
    local observations, closest = _observations_near(scope, clusters)

    for ci, cluster in ipairs(clusters) do
        -- Collect ids and quote snippets.
        local ids    = {}
        local quotes = {}
        local avg_imp = 0
        for _, m in ipairs(cluster) do
            ids[#ids + 1]    = m.id
            quotes[#quotes + 1] = util.clip(m.body or "", 200)
            avg_imp = avg_imp + (tonumber(m.importance) or 0.5)
        end
        avg_imp = avg_imp / #cluster

        -- Find the pivot embedding (first member's vec).
        local pivot_vec = cluster[1].embedding

        -- Is the closest existing observation close enough to reinforce?
        local best_obs = closest[ci] and closest[ci].obs
        local best_sim = closest[ci] and closest[ci].sim or 0
        local reinforce_threshold = (cfg.consolidate_reinforce_threshold) or 0.75

        if best_obs and best_sim >= reinforce_threshold then
            -- Reinforcement path: no LLM needed.
            local last_epoch = _ts_to_epoch(best_obs.last_reinforced)
            local ok, rerr = pcall(_reinforce, best_obs.id, ids, quotes, last_epoch)
            if not ok then
                result.errors[#result.errors + 1] = "reinforce obs "
                    .. tostring(best_obs.id) .. ": " .. tostring(rerr)
            else
                result.reinforced = result.reinforced + 1
                -- Update freshness_trend in-memory for later iterations.
                best_obs.proof_count = (tonumber(best_obs.proof_count) or 1) + #ids
            end
        else
            -- Synthesis path: one LLM call (or fallback concatenation).
            local has_neg = false
            for _, m in ipairs(cluster) do
                if _has_negation(m.body or "") then has_neg = true; break end
            end

            local body, serr = _synthesize(cluster)
            if serr and cfg.consolidate_log_errors then
                result.errors[#result.errors + 1] = "synthesize: " .. tostring(serr)
            end
            if body and body ~= "" then
                -- The default summarizer keeps a member's body: its stored vector serves (an
                -- embedder call per new memory went to that text again). Else embed it.
                local obs_vec
                for _, m in ipairs(cluster) do
                    if m.body == body and type(m.embedding) == "table" then obs_vec = m.embedding; break end
                end
                if not obs_vec then
                    local everr
                    obs_vec, everr = embed.embed(body)
                    if not obs_vec then
                        result.errors[#result.errors + 1] = "embed obs body: " .. tostring(everr)
                        obs_vec = pivot_vec  -- fall back to cluster pivot
                    end
                end
                local ok, ierr = pcall(_insert_obs, scope, body, ids, quotes, obs_vec, avg_imp)
                if not ok then
                    result.errors[#result.errors + 1] = "insert obs: " .. tostring(ierr)
                else
                    result.synthesised = result.synthesised + 1
                    -- Mark the new observation as a candidate for future reinforcement.
                    -- (It will be scanned by _observations_near on the next run.)
                end
                -- Suppress unused variable warning for has_neg; it will be used
                -- in Plan 11 for contradiction handling.
                local _ = has_neg
            end
        end

        -- Mark memories as consolidated regardless of synthesis outcome so
        -- they are not re-processed on the next run.
        local ok2, merr = pcall(_mark_consolidated, ids)
        if not ok2 then
            result.errors[#result.errors + 1] = "mark consolidated: " .. tostring(merr)
        end
    end

    -- Refresh freshness trends for all existing observations.
    for _, obs in ipairs(observations) do
        pcall(_refresh_trend, obs)
    end

    return result
end

--- Observation search leg for store.search().
--- Returns a list of rows with fields compatible with regular memory rows:
---   id, scope, body, score, type="observation", proof_count, freshness_trend
--- The score is pure cosine similarity with proof_count and freshness boosts.
--- @param scope   string   scope to search within
--- @param qvec    table    query embedding (Lua number array)
--- @param limit   number   max results to return
--- @return        table    array of result rows (may be empty)
function M.search(scope, qvec, limit)
    limit = limit or 10
    if not cfg or type(qvec) ~= "table" or #qvec == 0 then return {} end

    -- Every observation's vector is scored where it is stored (vectors.cosine_ptr, as the
    -- write path's duplicate check does) — it was unpacked into a Lua table per observation
    -- on every search (12.7 → 3.4 ms at 482 observations); only the top rows are read whole.
    local q, hits = vectors.query(qvec), {}
    local n = db.scan("SELECT id, embedding, emb_norm, proof_count, freshness_trend FROM lm_observations "
        .. "WHERE scope = ? AND embedding IS NOT NULL", { scope }, function(r)
        local p, bytes = r:blob_ptr(1)
        local sim = vectors.cosine_ptr(p, bytes, _row_norm(r, 2, p, bytes), q)
        local score = sim * _proof_boost(r:type(3) ~= 5 and r:int(3) or 1)
            * _freshness_multiplier(r:value(4) or "stable")
        if score > 0 then hits[#hits + 1] = { id = r:int(0), score = score, sim = sim } end
    end)
    if not n or #hits == 0 then return {} end
    table.sort(hits, function(a, b) return a.score > b.score end)

    local top, ids = {}, {}
    for i = 1, math.min(limit, #hits) do top[i] = hits[i]; ids[i] = hits[i].id end
    local by = {}
    for _, r in ipairs(db.query("SELECT id, body, proof_count, freshness_trend, importance, created_at, "
        .. "last_reinforced FROM lm_observations WHERE id IN (" .. db.placeholders(#ids) .. ")",
        unpack(ids, 1, #ids)) or {}) do
        by[r.id] = r
    end
    local out = {}
    for _, h in ipairs(top) do
        local obs = by[h.id]
        if obs then
            out[#out + 1] = {
                id              = obs.id,
                scope           = scope,
                kind            = "observation",
                title           = "",
                body            = obs.body or "",
                tags            = {},
                metadata        = {},
                importance      = tonumber(obs.importance) or 0.5,
                decay_rate      = 0.0,
                was_truncated   = false,
                created_at      = obs.created_at and util.us_to_iso(obs.created_at),
                updated_at      = obs.last_reinforced and util.us_to_iso(obs.last_reinforced),
                score           = h.score,
                vec_score       = h.sim,
                fts_score       = 0,
                -- Observation-specific extras:
                type            = "observation",
                proof_count     = tonumber(obs.proof_count) or 1,
                freshness_trend = obs.freshness_trend or "stable",
            }
        end
    end
    return out
end

return M
