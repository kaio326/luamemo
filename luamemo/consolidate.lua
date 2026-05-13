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

local db    = require("luamemo.db")
local embed = require("luamemo.embed")
local util  = require("luamemo.util")

local M = {}

local cfg              = nil
local _pending         = {}        -- [scope] = true when a write has occurred
local _adapter_cache   = {}        -- [name] -> summarizer module
local OBS_TBL          = "lm_observations"

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

-- Parse a Postgres timestamp string to a Unix epoch (best-effort).
local function _ts_to_epoch(s)
    if not s then return 0 end
    local y, mo, d = tostring(s):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return 0 end
    return os.time({
        year  = tonumber(y),
        month = tonumber(mo),
        day   = tonumber(d),
        hour  = 0, min = 0, sec = 0,
    })
end

-- Build a Postgres BIGINT[] literal from a Lua array of integer ids.
local function _bigint_array(ids)
    if not ids or #ids == 0 then return "'{}'::bigint[]" end
    local parts = {}
    for _, id in ipairs(ids) do parts[#parts + 1] = tostring(math.floor(tonumber(id) or 0)) end
    return "'{" .. table.concat(parts, ",") .. "}'::bigint[]"
end

-- Build a Postgres TEXT[] literal from a Lua array of strings.
-- Uses the ARRAY['a','b'] constructor with properly escaped single-quote strings.
local function _text_array(strs)
    if not strs or #strs == 0 then return "'{}'::text[]" end
    local parts = {}
    for _, s in ipairs(strs) do
        -- Escape single-quotes by doubling them (standard SQL).
        local escaped = tostring(s):gsub("'", "''")
        parts[#parts + 1] = "'" .. escaped .. "'"
    end
    return "ARRAY[" .. table.concat(parts, ", ") .. "]"
end

-- Format an embedding as a REAL[] literal for INSERT.
local function _embed_literal(vec)
    if not vec then return "NULL" end
    local parts = {}
    for i, v in ipairs(vec) do parts[i] = tostring(v) end
    return "'{" .. table.concat(parts, ",") .. "}'::real[]"
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
local function _fetch_unprocessed(scope)
    local mem_tbl = db.escape_identifier(cfg.db_table)
    local sql = ([[
        SELECT id, body, title, importance, embedding
          FROM %s
         WHERE scope = %s
           AND consolidated_at IS NULL
           AND embedding IS NOT NULL
         ORDER BY id
    ]]):format(mem_tbl, db.escape_literal(scope))
    return db.query(sql) or {}
end

-- Fetch all observations for a scope including their embeddings.
local function _fetch_observations(scope)
    local obs_tbl = db.escape_identifier(OBS_TBL)
    local sql = ([[
        SELECT id, body, proof_count, evidence_ids, freshness_trend,
               last_reinforced, importance, embedding
          FROM %s
         WHERE scope = %s
         ORDER BY last_reinforced DESC
    ]]):format(obs_tbl, db.escape_literal(scope))
    return db.query(sql) or {}
end

-- Mark a batch of memory ids as consolidated (set consolidated_at = NOW()).
local function _mark_consolidated(ids)
    if not ids or #ids == 0 then return end
    local id_list, lerr = util.sql_id_list(ids)
    if not id_list then return end  -- silently skip bad ids
    local mem_tbl = db.escape_identifier(cfg.db_table)
    db.query("UPDATE " .. mem_tbl
        .. " SET consolidated_at = NOW() WHERE id IN (" .. id_list .. ")")
end

-- Reinforce an existing observation: increment proof_count, update
-- evidence_ids, and recalculate freshness_trend.
local function _reinforce(obs_id, new_ids, new_quotes, last_epoch)
    local obs_tbl = db.escape_identifier(OBS_TBL)
    -- Append new evidence ids (Postgres || operator for array concat).
    local sql = ([[
        UPDATE %s
           SET proof_count     = proof_count + %d,
               evidence_ids    = evidence_ids || %s,
               evidence_quotes = evidence_quotes || %s,
               freshness_trend = %s,
               last_reinforced = NOW()
         WHERE id = %d
    ]]):format(
        obs_tbl,
        #new_ids,
        _bigint_array(new_ids),
        _text_array(new_quotes),
        db.escape_literal(_freshness_trend(last_epoch, 0)),  -- approx; real count unknown here
        math.floor(tonumber(obs_id) or 0)
    )
    local rows, qerr = db.query(sql)
    if not rows then error("reinforce obs db error: " .. tostring(qerr)) end
end

-- Update freshness_trend for an observation based on its current proof_count
-- and last_reinforced timestamp.
local function _refresh_trend(obs)
    if not obs or not obs.id then return end
    local epoch = _ts_to_epoch(obs.last_reinforced)
    local trend = _freshness_trend(epoch, tonumber(obs.proof_count) or 1)
    if trend == obs.freshness_trend then return end
    local obs_tbl = db.escape_identifier(OBS_TBL)
    db.query("UPDATE " .. obs_tbl
        .. " SET freshness_trend = " .. db.escape_literal(trend)
        .. " WHERE id = " .. math.floor(tonumber(obs.id) or 0))
end

-- Insert a new observation row.
local function _insert_obs(scope, body, evidence_ids, evidence_quotes, obs_vec, imp)
    local obs_tbl = db.escape_identifier(OBS_TBL)
    local sql = ([[
        INSERT INTO %s
            (scope, body, proof_count, evidence_ids, evidence_quotes,
             freshness_trend, importance, embedding)
        VALUES (%s, %s, %d, %s, %s, 'new', %s, %s)
    ]]):format(
        obs_tbl,
        db.escape_literal(scope),
        db.escape_literal(body),
        #evidence_ids,
        _bigint_array(evidence_ids),
        _text_array(evidence_quotes),
        db.escape_literal(math.min(10.0, math.max(0.0, imp or 0.5))),
        _embed_literal(obs_vec)
    )
    local rows, qerr = db.query(sql)
    if not rows then error("insert obs db error: " .. tostring(qerr)) end
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
--- Returns a summary table:
---   { reinforced = N, synthesised = N, errors = {...} }
function M.process(scope)
    if not cfg then return { reinforced = 0, synthesised = 0, errors = {"consolidate: not configured"} } end

    -- Clear the pending flag first so concurrent writes queue a follow-up run.
    _pending[scope] = nil

    -- Check whether the observations table exists (migration may not have run).
    if not util.table_exists("lm_observations") then
        -- Migration 007 not applied yet; skip silently.
        return { reinforced = 0, synthesised = 0, errors = {} }
    end

    local result = { reinforced = 0, synthesised = 0, errors = {} }

    local memories = _fetch_unprocessed(scope)
    if #memories == 0 then return result end

    local observations = _fetch_observations(scope)

    -- Cluster unprocessed memories.
    local threshold = (cfg.consolidate_threshold) or 0.80
    local clusters  = util.cluster(memories, threshold)

    for _, cluster in ipairs(clusters) do
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

        -- Check if any existing observation is close enough to reinforce.
        local best_obs = nil
        local best_sim = 0
        local reinforce_threshold = (cfg.consolidate_reinforce_threshold) or 0.75
        for _, obs in ipairs(observations) do
            if type(obs.embedding) == "table" then
                local sim = util.cosine(pivot_vec, obs.embedding)
                if sim > best_sim then
                    best_sim = sim
                    best_obs = obs
                end
            end
        end

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
                -- Embed the synthesised body.
                local obs_vec, everr = embed.embed(body)
                if not obs_vec then
                    result.errors[#result.errors + 1] = "embed obs body: " .. tostring(everr)
                    obs_vec = pivot_vec  -- fall back to cluster pivot
                end
                local ok, ierr = pcall(_insert_obs, scope, body, ids, quotes, obs_vec, avg_imp)
                if not ok then
                    result.errors[#result.errors + 1] = "insert obs: " .. tostring(ierr)
                else
                    result.synthesised = result.synthesised + 1
                    -- Mark the new observation as a candidate for future reinforcement.
                    -- (It will be fetched by _fetch_observations on the next run.)
                end
                -- Suppress unused variable warning for has_neg; it will be used
                -- in Plan 11 for contradiction handling.
                _ = has_neg
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
    if not cfg then return {} end

    -- Skip if the observations table doesn't exist.
    if not util.table_exists("lm_observations") then return {} end

    local observations = _fetch_observations(scope)
    if #observations == 0 then return {} end

    local scored = {}
    for _, obs in ipairs(observations) do
        if type(obs.embedding) == "table" and #obs.embedding > 0 then
            local sim   = util.cosine(qvec, obs.embedding)
            local boost = _proof_boost(tonumber(obs.proof_count) or 1)
            local fmul  = _freshness_multiplier(obs.freshness_trend or "stable")
            local score = sim * boost * fmul
            if score > 0 then
                scored[#scored + 1] = {
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
                    created_at      = obs.created_at,
                    updated_at      = obs.last_reinforced,
                    score           = score,
                    vec_score       = sim,
                    fts_score       = 0,
                    -- Observation-specific extras:
                    type            = "observation",
                    proof_count     = tonumber(obs.proof_count) or 1,
                    freshness_trend = obs.freshness_trend or "stable",
                }
            end
        end
    end

    -- Sort descending by score.
    table.sort(scored, function(a, b) return a.score > b.score end)

    -- Trim to limit.
    local out = {}
    for i = 1, math.min(limit, #scored) do out[i] = scored[i] end
    return out
end

return M
