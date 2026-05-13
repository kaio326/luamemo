-- luamemo.digest
-- Hippocampus Digest: idle-triggered tier promotion + reinforcement processing.
--
-- Design:
--   * `notify_write(scope)` is called on every write to update an idle clock.
--   * A per-scope idle timer table tracks the last-write epoch. When no write
--     has arrived for `digest_idle_seconds` (default 30 min), `run(scope)` fires.
--   * The background coroutine poll requires the caller to drive the scheduler
--     (luamemo.async); in plain Lua scripts the caller can call `run()` directly.
--   * `run(scope, opts)` is also callable explicitly (CLI, MCP tool, test harness).
--
-- Public API:
--   digest.configure(cfg)                -- called by luamemo.store after setup
--   digest.notify_write(scope)           -- call on every write
--   digest.run(scope [, opts])           -- explicit trigger; returns summary table
--   digest.record_event(memory_id, scope, event_type, delta, note)
--                                        -- log a reinforcement event
--
-- Config keys consumed:
--   digest_idle_seconds       (default 1800 = 30 min)
--   digest_grace_days         (default 7) — days before ephemeral rows are deleted
--   digest_escalate_alpha     (default 0.4) — sigmoid slope for mistake escalation
--   digest_promote_tier2_at   (default 3) — min proof_count for tier-1 → tier-2
--   digest_promote_tier3_at   (default 5) — min proof_count for mistake → tier-3
--
-- Digest pipeline (per scope):
--   1. Fetch unconsolidated tier-0 memories.
--   2. Cluster by cosine similarity (reuses consolidate clustering).
--   3. For each cluster:
--      a. overlaps existing observation → reinforce via consolidate
--      b. has a mistake-type reinforcement → escalate importance, promote tier
--      c. otherwise → synthesise via summarizer, store as tier=1
--   4. Promote tier-1 with proof_count >= tier2_at and trend != 'stale' → tier 2.
--   5. Promote tier-2 + mistake events with proof_count >= tier3_at → tier 3.
--   6. Stamp consolidated_at on all processed tier-0 rows.
--   7. After grace_days, delete tier-0 rows with non-null consolidated_at.

local M = {}

local db          = require("luamemo.db")
local util        = require("luamemo.util")
local embed       = require("luamemo.embed")
local consolidate = require("luamemo.consolidate")

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
local _cfg = {}

local DEFAULTS = {
    digest_idle_seconds     = 1800,
    digest_grace_days       = 7,
    digest_escalate_alpha   = 0.4,
    digest_promote_tier2_at = 3,
    digest_promote_tier3_at = 5,
}

function M.configure(cfg)
    cfg = cfg or {}
    for k, default in pairs(DEFAULTS) do
        _cfg[k] = cfg[k] ~= nil and cfg[k] or default
    end
end

-- ---------------------------------------------------------------------------
-- Idle timer
-- ---------------------------------------------------------------------------
local _last_write = {}   -- scope → os.time() of last write

function M.notify_write(scope)
    if scope and scope ~= "" then
        _last_write[scope] = os.time()
    end
end

-- Check whether a scope is idle long enough to trigger a digest.
-- Returns true if the scope has had at least one write AND has been quiet
-- for >= digest_idle_seconds. Never fires for scopes that never had a write.
function M.should_run(scope)
    local t = _last_write[scope]
    if not t then return false end
    return (os.time() - t) >= (_cfg.digest_idle_seconds or 1800)
end

-- ---------------------------------------------------------------------------
-- Importance-escalation / diminishment helpers
-- ---------------------------------------------------------------------------

-- Sigmoid-like escalation: asymptotes toward 1.0 as reinforcement_count grows.
--   After 1 mistake: ≈ 0.29. After 3: ≈ 0.55. After 8: ≈ 0.82. After 15: ≈ 0.92.
local function _escalate(current, reinforcement_count)
    local x = math.max(0, tonumber(reinforcement_count) or 0)
    local alpha = tonumber(_cfg.digest_escalate_alpha) or 0.4
    local new = 1.0 - 1.0 / (1.0 + x * alpha)
    -- Only move upward; never lower importance via mistake escalation.
    return math.max(tonumber(current) or 0.0, new)
end

-- Soft diminishment for reversals: moves importance halfway toward 0.3
-- (the tier-1/tier-0 boundary), scaled by delta strength.
--   delta = 1.0 → moves halfway: new = current - (current - 0.3) * 0.5
--   delta = 0.5 → moves quarter:  new = current - (current - 0.3) * 0.25
-- Result is clamped to [0.0, 1.0].
local function _diminish(current, delta)
    local c = tonumber(current) or 0.5
    local d = math.min(math.abs(tonumber(delta) or 0.5), 1.0)
    local new = c - (c - 0.3) * d * 0.5
    return math.max(0.0, math.min(1.0, new))
end

-- Derive tier from importance via the shared formula in util.
local _tier_from_imp = util.importance_to_tier

-- ---------------------------------------------------------------------------
-- Public: record_event
-- Log a discrete reinforcement event for a memory. Silently does nothing if
-- the lm_reinforcements table has not been created (migration 009 not applied).
--
-- For "reversal" events the memory's importance is also immediately diminished
-- and its tier is updated to match.  The raw secret value of the change is
-- recorded in lm_reinforcements so the digest pipeline can later detect
-- contradictions and evolve the related observation.
-- ---------------------------------------------------------------------------
function M.record_event(memory_id, scope, event_type, delta, note)
    if not util.table_exists("lm_reinforcements") then return end
    if not memory_id or not scope then return end
    local valid_types = {
        direct_command = true, mistake = true,
        reversal = true, praise = true,
    }
    if not valid_types[event_type] then return end

    local mid = math.floor(tonumber(memory_id) or 0)
    if mid == 0 then return end  -- guard against invalid / zero FK

    local clamped_delta = math.max(-1.0, math.min(1.0, tonumber(delta) or 0.5))

    local sql = ([[
        INSERT INTO lm_reinforcements
            (memory_id, scope, event_type, delta, note)
        VALUES (%d, %s, %s, %s, %s)
    ]]):format(
        mid,
        db.escape_literal(scope),
        db.escape_literal(event_type),
        db.escape_literal(tostring(clamped_delta)),
        note and db.escape_literal(note) or "NULL"
    )
    db.query(sql)  -- fire-and-forget; errors silently discarded

    -- Reversal: immediately apply importance diminishment + tier demotion.
    if event_type == "reversal" then
        local mem_rows = db.query(
            "SELECT importance FROM lm_memories WHERE id = "
            .. mid .. " LIMIT 1")
        if mem_rows and mem_rows[1] then
            local cur_imp = tonumber(mem_rows[1].importance) or 0.5
            local new_imp  = _diminish(cur_imp, clamped_delta)
            local new_tier = _tier_from_imp(new_imp)
            db.query(([[
                UPDATE lm_memories
                   SET importance = %s, tier = %d
                 WHERE id = %d
            ]]):format(
                db.escape_literal(tostring(new_imp)),
                new_tier,
                mid))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

-- Fetch tier-0 memories that have not yet been consolidated for a scope.
local function _fetch_tier0(scope)
    if not util.table_exists("lm_memories") then return {} end
    -- Cast embedding to REAL[] on pgvector backend so Lua gets a Lua array.
    local emb_col = "embedding"
    local rows, err = db.query(([[
        SELECT id, scope, title, body, importance, decay_rate, created_at,
               %s AS embedding
        FROM lm_memories
        WHERE scope = %s
          AND tier = 0
          AND consolidated_at IS NULL
        ORDER BY importance DESC, created_at ASC
        LIMIT 500
    ]]):format(emb_col, db.escape_literal(scope)))
    if not rows then
        if util.log then util.log("digest: fetch tier-0 error: " .. tostring(err)) end
        return {}
    end
    -- Parse embedding arrays returned as strings by pgmoon.
    for _, r in ipairs(rows) do
        if type(r.embedding) == "string" then
            -- Attempt to parse "{a,b,c,...}" format.
            local arr = {}
            for v in r.embedding:gmatch("[^{},]+") do
                arr[#arr + 1] = tonumber(v) or 0
            end
            r.embedding = #arr > 0 and arr or nil
        end
    end
    return rows
end

-- Greedy single-linkage clustering (delegates to util.cluster).
local function _cluster(memories, threshold)
    return util.cluster(memories, threshold)
end

-- Fetch mistake-event counts for a set of memory IDs via a single aggregate
-- query.  Returns a table keyed by memory_id (as string) → count (number).
-- Only 'mistake' and 'direct_command' events are counted.
local function _fetch_mistake_counts(ids)
    if not util.table_exists("lm_reinforcements") then return {} end
    if #ids == 0 then return {} end
    local id_list, err = util.sql_id_list(ids)
    if not id_list then return {} end
    local rows = db.query(
        "SELECT memory_id, COUNT(*) AS n FROM lm_reinforcements "
        .. "WHERE memory_id IN (" .. id_list .. ") "
        .. "AND event_type IN ('mistake', 'direct_command') "
        .. "GROUP BY memory_id")
    local by_id = {}
    for _, r in ipairs(rows or {}) do
        by_id[tostring(r.memory_id)] = tonumber(r.n) or 0
    end
    return by_id
end

-- Stamp consolidated_at on a list of memory IDs.
local function _stamp_consolidated(ids)
    local id_list = util.sql_id_list(ids)
    if not id_list then return end
    db.query("UPDATE lm_memories SET consolidated_at = NOW() "
        .. "WHERE id IN (" .. id_list .. ")")
end

-- Promote tier-0/1 rows based on proof_count and mistake history.
-- Returns counts of tier-1→2 and tier-2→3 promotions.
local function _promote(scope)
    local promoted2, promoted3 = 0, 0
    local tier2_at = tonumber(_cfg.digest_promote_tier2_at) or 3
    local tier3_at = tonumber(_cfg.digest_promote_tier3_at) or 5

    -- Tier-1 → tier-2: observations with proof_count >= tier2_at, trend != stale.
    -- We join lm_observations (if it exists) to check proof_count.
    if util.table_exists("lm_observations") then
        -- Promote memories whose consolidated observation has enough proof.
        -- We match on scope and check the corresponding observation proof.
        local obs_rows = db.query(([[
            SELECT o.id AS obs_id, o.proof_count, o.freshness_trend,
                   o.evidence_ids
            FROM lm_observations o
            WHERE o.scope = %s
              AND o.proof_count >= %d
              AND o.freshness_trend != 'stale'
        ]]):format(db.escape_literal(scope), tier2_at))
        if obs_rows and #obs_rows > 0 then
            for _, obs in ipairs(obs_rows) do
                -- Get the evidence memory IDs from the observation.
                local ev_ids = obs.evidence_ids
                if type(ev_ids) == "string" then
                    local arr = {}
                    for v in ev_ids:gmatch("[^{},]+") do
                        arr[#arr + 1] = tonumber(v)
                    end
                    ev_ids = arr
                end
                if type(ev_ids) == "table" and #ev_ids > 0 then
                    local id_list = util.sql_id_list(ev_ids)
                    if id_list then
                        local upd = db.query(
                            "UPDATE lm_memories SET tier = 2 "
                            .. "WHERE id IN (" .. id_list .. ") AND tier = 1")
                        if upd and type(upd) == "table" then
                            -- pgmoon returns affected_rows in the result table.
                            promoted2 = promoted2 + (tonumber(upd.affected_rows) or 0)
                        end
                    end
                end
            end
        end
    end

    -- Tier-2 → tier-3: memories with enough mistake-escalated reinforcements.
    if util.table_exists("lm_reinforcements") then
        -- Find memory IDs in this scope with >= tier3_at mistake/direct_command events.
        local mistake_rows = db.query(([[
            SELECT memory_id, COUNT(*) AS n
            FROM lm_reinforcements
            WHERE scope = %s
              AND event_type IN ('mistake', 'direct_command')
            GROUP BY memory_id
            HAVING COUNT(*) >= %d
        ]]):format(db.escape_literal(scope), tier3_at))
        if mistake_rows and #mistake_rows > 0 then
            local promote3_ids = {}
            for _, mr in ipairs(mistake_rows) do
                local mid = math.floor(tonumber(mr.memory_id) or 0)
                if mid > 0 then
                    promote3_ids[#promote3_ids + 1] = mid
                end
            end
            if #promote3_ids > 0 then
                local id_list = util.sql_id_list(promote3_ids)
                if id_list then
                    local upd = db.query(
                        "UPDATE lm_memories SET tier = 3 "
                        .. "WHERE id IN (" .. id_list .. ") AND tier = 2")
                    if upd and type(upd) == "table" then
                        promoted3 = promoted3 + (tonumber(upd.affected_rows) or 0)
                    end
                end
            end
        end
    end

    return promoted2, promoted3
end

-- Delete tier-0 rows whose consolidated_at is older than grace_days,
-- relative to `before_epoch` (the start of the current run). Using the
-- run-start epoch instead of NOW() prevents rows stamped during this run
-- from being deleted: those rows have consolidated_at >= run_start > cutoff.
local function _purge_stale(scope, before_epoch)
    local grace = math.max(0, math.floor(tonumber(_cfg.digest_grace_days) or 7))
    local cutoff_epoch = math.floor(before_epoch) - grace * 86400
    local sql = ([[
        DELETE FROM lm_memories
        WHERE scope = %s
          AND tier = 0
          AND consolidated_at IS NOT NULL
          AND consolidated_at < to_timestamp(%d)
    ]]):format(db.escape_literal(scope), cutoff_epoch)
    local res = db.query(sql)
    return (res and type(res) == "table" and tonumber(res.affected_rows)) or 0
end

-- ---------------------------------------------------------------------------
-- Public: run
-- ---------------------------------------------------------------------------
-- Runs the full digest pipeline for a scope. Returns a summary table:
--   { processed, promoted2, promoted3, deleted, errors }
--
-- opts (optional table):
--   dry_run      — if true, skip all writes (inspection only)
--   threshold    — cosine clustering threshold (default from consolidate config)
-- ---------------------------------------------------------------------------
function M.run(scope, opts)
    scope = scope or ""
    opts  = opts or {}
    local dry_run   = opts.dry_run and true or false
    local threshold = tonumber(opts.threshold)
                      or tonumber(_cfg.consolidate_threshold) or 0.80
    -- Capture start time before any DB writes so _purge_stale can exclude
    -- rows stamped during this run.
    local run_start = os.time()

    local summary = {
        processed  = 0,
        promoted2  = 0,
        promoted3  = 0,
        deleted    = 0,
        errors     = {},
    }

    if not util.table_exists("lm_memories") then
        summary.errors[#summary.errors + 1] = "lm_memories table not found"
        return summary
    end

    -- 1. Fetch unconsolidated tier-0 memories.
    local tier0 = _fetch_tier0(scope)
    if #tier0 == 0 then
        -- Nothing to process; still run promotion + purge.
        if not dry_run then
            local p2, p3 = _promote(scope)
            summary.promoted2 = p2
            summary.promoted3 = p3
            summary.deleted   = _purge_stale(scope, run_start)
        end
        return summary
    end

    -- 2. Cluster by embedding similarity.
    local clusters = _cluster(tier0, threshold)

    -- Gather all IDs and fetch mistake counts in one aggregate query.
    local all_ids = {}
    for _, m in ipairs(tier0) do
        all_ids[#all_ids + 1] = math.floor(tonumber(m.id) or 0)
    end
    local mistake_counts = _fetch_mistake_counts(all_ids)

    -- 3. Process each cluster.
    for _, cluster in ipairs(clusters) do
        -- Collect IDs and pick the highest-importance member as representative.
        local ids  = {}
        local best = cluster[1]
        for _, m in ipairs(cluster) do
            ids[#ids + 1] = math.floor(tonumber(m.id) or 0)
            if (tonumber(m.importance) or 0) > (tonumber(best.importance) or 0) then
                best = m
            end
        end

        local mistake_n = 0
        for _, mid in ipairs(ids) do
            mistake_n = mistake_n + (mistake_counts[tostring(mid)] or 0)
        end

        if dry_run then
            -- In dry-run mode just count.
            summary.processed = summary.processed + #cluster
        else
            -- a. Check if cluster overlaps an existing observation.
            local best_vec = best.embedding
            local obs_hit = nil
            if type(best_vec) == "table" and util.table_exists("lm_observations") then
                local obs_limit = 5
                local ok_search, obs_rows = pcall(consolidate.search,
                    scope, best_vec, obs_limit)
                if ok_search and obs_rows and #obs_rows > 0 then
                    obs_hit = obs_rows[1]   -- highest-scoring observation
                end
            end

            if obs_hit and obs_hit.id then
                -- b. Reinforce the matching observation.
                local ok_r, r_err = pcall(function()
                    consolidate.process(scope)  -- full process handles reinforcement
                end)
                if not ok_r then
                    summary.errors[#summary.errors + 1] =
                        "reinforce error: " .. tostring(r_err)
                end
            else
                -- c. Synthesise: use consolidate.process for new observations,
                --    OR apply mistake escalation if triggered.
                if mistake_n > 0 then
                    -- Escalate importance of the best member and bump its tier.
                    local new_imp = _escalate(best.importance, mistake_n)
                    local new_tier = _tier_from_imp(new_imp)
                    local mid = math.floor(tonumber(best.id) or 0)
                    if mid > 0 then
                        db.query(([[
                            UPDATE lm_memories
                               SET importance = %s, tier = %d
                             WHERE id = %d
                        ]]):format(
                            db.escape_literal(new_imp),
                            new_tier,
                            mid))
                    end
                end
                -- Let consolidate.process handle observation creation for the
                -- remaining members (it reads consolidated_at IS NULL).
                local ok_c, c_err = pcall(consolidate.process, scope)
                if not ok_c then
                    summary.errors[#summary.errors + 1] =
                        "consolidate error: " .. tostring(c_err)
                end
            end

            -- 6. Stamp consolidated_at on processed tier-0 rows.
            _stamp_consolidated(ids)
            summary.processed = summary.processed + #cluster
        end
    end

    -- 4 & 5. Tier promotion (skip in dry_run).
    if not dry_run then
        local p2, p3 = _promote(scope)
        summary.promoted2 = p2
        summary.promoted3 = p3

        -- 7. Purge stale consolidated tier-0 rows.
        summary.deleted = _purge_stale(scope, run_start)
    end

    -- Reset idle clock so the timer doesn't immediately re-fire.
    _last_write[scope] = nil

    return summary
end

return M
