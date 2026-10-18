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
local vectors     = require("luamemo.vectors")
local consolidate = require("luamemo.consolidate")
-- Federation: never mutate a dev's org replica; never create or alter org
-- directives (tier 3) on the central. No-op when role=solo.
local policy      = require("luamemo.federation.policy")

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
    auto_digest_interval    = 3600,   -- min seconds between lazy auto-digests per scope
    consolidate_threshold   = 0.80,   -- clustering similarity (run's default threshold)
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
-- (In-memory; only meaningful inside a long-lived process such as the MCP server.)
function M.should_run(scope)
    local t = _last_write[scope]
    if not t then return false end
    return (os.time() - t) >= (_cfg.digest_idle_seconds or 1800)
end

-- Lazy, debounced auto-trigger for STATELESS callers (the CLI): piggyback a
-- maintenance digest on an ordinary operation, but at most once per
-- auto_digest_interval per scope. State lives in lm_digest_state so the debounce
-- survives across process invocations. The claim is a single atomic upsert whose
-- WHERE guard means only ONE concurrent caller wins the slot — a race can't double
-- run the digest. Fail-soft; returns the digest result, or false if not due /
-- unavailable. This is how the loop keeps maintaining itself without any external
-- trigger (agent or cron) having to remember.
local _running = false
function M.maybe_run(scope, opts)
    if _running then return false end
    if not scope or scope == "" then return false end
    if policy.replica(scope) then return false end   -- replicas mirror the central
    local interval = math.floor(tonumber(_cfg.auto_digest_interval) or 3600)
    if interval < 0 then interval = 0 end

    -- Atomic "claim the slot if due" — inserts on first sight, else updates only
    -- when the cursor is older than the interval. RETURNING tells us if we won it.
    local now = util.now_us()
    local claim = db.first(
        "INSERT INTO lm_digest_state (scope, last_digested_at) VALUES (?, ?) "
        .. "ON CONFLICT (scope) DO UPDATE SET last_digested_at = excluded.last_digested_at "
        .. "WHERE lm_digest_state.last_digested_at <= ? RETURNING scope",
        scope, now, now - interval * 1000000)
    if not claim then return false end   -- not due, or lost the race

    _running = true
    local ok, res = pcall(M.run, scope, opts or {})
    _running = false
    return ok and res or false
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

-- Miss reinforcement: retrieval failed to surface a memory that was needed, so
-- nudge its importance UP toward 1.0 (scaled by delta) — the direct remedy that
-- makes it rank higher / surface next time, independent of the learned models.
-- Only ever moves upward (never diminishes a proven-relevant memory).
--   delta = 1.0 → new = current + (1 - current) * 0.5   (halfway to ceiling)
--   delta = 0.5 → new = current + (1 - current) * 0.25
local function _reinforce_relevance(current, delta)
    local c = tonumber(current) or 0.5
    local d = math.min(math.abs(tonumber(delta) or 0.5), 1.0)
    local new = c + (1.0 - c) * d * 0.5
    return math.max(c, math.min(1.0, new))
end

-- The digest's own 0–1 relevance (_escalate / _diminish / _reinforce_relevance
-- stay within 0–1) → tier, for escalation and reversal. (Write-time tiers use
-- util.importance_to_tier on importance's 0–10 scale.)
local function _tier_from_relevance(v)
    v = tonumber(v) or 0
    if v < 0.3 then return 0 end
    if v < 0.6 then return 1 end
    if v < 0.85 then return 2 end
    return 3
end

-- ---------------------------------------------------------------------------
-- Public: record_event
-- Log a discrete reinforcement event for a memory.
--
-- For "reversal" events the memory's importance is also immediately diminished
-- and its tier is updated to match.  The raw secret value of the change is
-- recorded in lm_reinforcements so the digest pipeline can later detect
-- contradictions and evolve the related observation.
-- ---------------------------------------------------------------------------
function M.record_event(memory_id, scope, event_type, delta, note)
    if not memory_id or not scope then return end
    local valid_types = {
        direct_command = true, mistake = true,
        reversal = true, praise = true, miss = true,
    }
    if not valid_types[event_type] then return end

    local mid = math.floor(tonumber(memory_id) or 0)
    if mid == 0 then return end  -- guard against invalid / zero FK

    local clamped_delta = math.max(-1.0, math.min(1.0, tonumber(delta) or 0.5))

    -- fire-and-forget; errors silently discarded (e.g. the memory is gone)
    db.run("INSERT INTO lm_reinforcements (memory_id, scope, event_type, delta, note, created_at) "
        .. "VALUES (?, ?, ?, ?, ?, ?)", mid, scope, event_type, clamped_delta, note, util.now_us())
    M.apply_event_effect(mid, scope, event_type, clamped_delta)
end

-- ---------------------------------------------------------------------------
-- Public: apply_event_effect
-- The immediate row effect of a reinforcement event, separated from logging it
-- so the org central can apply it exactly once for an idempotent pushed event
-- (insert ON CONFLICT DO NOTHING → apply only when the row was new).
--   Reversal: importance diminishment + tier demotion.
--   Miss: importance BUMP + tier promotion so the memory that retrieval failed
--   to surface becomes more findable next time.
-- Federation: replica rows and org directives are never changed; other org
-- rows are capped at tier 2 on the central.
-- ---------------------------------------------------------------------------
function M.apply_event_effect(memory_id, scope, event_type, delta)
    local mid = math.floor(tonumber(memory_id) or 0)
    if mid == 0 then return end
    local clamped_delta = math.max(-1.0, math.min(1.0, tonumber(delta) or 0.5))
    if event_type == "reversal" or event_type == "miss" then
        local mem = db.first("SELECT importance, tier FROM lm_memories WHERE id = ?", mid)
        if mem and policy.feedback_may_mutate(scope, mem.tier) then
            local cur_imp = tonumber(mem.importance) or 0.5
            local cur_tier = tonumber(mem.tier) or 1
            local new_imp = (event_type == "miss")
                and _reinforce_relevance(cur_imp, clamped_delta)
                or  _diminish(cur_imp, clamped_delta)
            -- A miss raises importance (ranking) and never demotes; a reversal
            -- demotes to what its lowered relevance supports — never raises.
            local new_tier = (event_type == "miss") and cur_tier
                or math.min(cur_tier, _tier_from_relevance(new_imp))
            new_tier = policy.cap_tier(scope, new_tier)
            db.run("UPDATE lm_memories SET importance = ?, tier = ? WHERE id = ?",
                new_imp, math.floor(new_tier), mid)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

-- Fetch tier-0 memories that have not yet been consolidated for a scope.
local function _fetch_tier0(scope)
    local rows, err = db.query("SELECT id, scope, title, body, importance, decay_rate, tier, created_at, embedding "
        .. "FROM lm_memories WHERE scope = ? AND tier = 0 AND consolidated_at IS NULL "
        .. "ORDER BY importance DESC, created_at ASC LIMIT 500", scope)
    if not rows then
        if util.log then util.log("digest: fetch tier-0 error: " .. tostring(err)) end
        return {}
    end
    for _, r in ipairs(rows) do r.embedding = vectors.unpack(r.embedding) end
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
    if #ids == 0 then return {} end
    local rows = db.query("SELECT memory_id, COUNT(*) AS n FROM lm_reinforcements "
        .. "WHERE memory_id IN (" .. db.placeholders(#ids) .. ") "
        .. "AND event_type IN ('mistake', 'direct_command') GROUP BY memory_id", unpack(ids, 1, #ids))
    local by_id = {}
    for _, r in ipairs(rows or {}) do
        by_id[tostring(r.memory_id)] = tonumber(r.n) or 0
    end
    return by_id
end

-- Stamp consolidated_at on a list of memory IDs.
local function _stamp_consolidated(ids)
    if #ids == 0 then return end
    local params = { util.now_us() }
    for _, id in ipairs(ids) do params[#params + 1] = id end
    db.run("UPDATE lm_memories SET consolidated_at = ? WHERE id IN (" .. db.placeholders(#ids) .. ")",
        unpack(params, 1, #params))
end

-- UPDATE lm_memories SET tier = <to> WHERE id IN ids AND tier = <from> → rows changed
local function _set_tier(ids, from, to)
    if #ids == 0 then return 0 end
    local params = { to }
    for _, id in ipairs(ids) do params[#params + 1] = id end
    params[#params + 1] = from
    return db.run("UPDATE lm_memories SET tier = ? WHERE id IN (" .. db.placeholders(#ids) .. ") AND tier = ?",
        unpack(params, 1, #params)) or 0
end

-- Promote tier-0/1 rows based on proof_count and mistake history.
-- Returns counts of tier-1→2 and tier-2→3 promotions.
local function _promote(scope)
    local promoted2, promoted3 = 0, 0
    if policy.replica(scope) then return 0, 0 end
    local tier2_at = tonumber(_cfg.digest_promote_tier2_at) or 3
    local tier3_at = tonumber(_cfg.digest_promote_tier3_at) or 5

    -- Tier-1 → tier-2: memories whose consolidated observation has enough proof
    -- (proof_count >= tier2_at, trend != stale).
    local obs_rows = db.query("SELECT id AS obs_id, proof_count, freshness_trend, evidence_ids "
        .. "FROM lm_observations WHERE scope = ? AND proof_count >= ? AND freshness_trend != 'stale'",
        scope, tier2_at)
    for _, obs in ipairs(obs_rows or {}) do
        local ev_ids = {}
        for _, v in ipairs(type(obs.evidence_ids) == "table" and obs.evidence_ids or {}) do
            if tonumber(v) then ev_ids[#ev_ids + 1] = math.floor(tonumber(v)) end
        end
        promoted2 = promoted2 + _set_tier(ev_ids, 1, 2)
    end

    -- Tier-2 → tier-3: memories with enough mistake-escalated reinforcements.
    -- Never on a protected org scope: there the core tier is directive-only.
    if not policy.protected(scope) then
        local mistake_rows = db.query("SELECT memory_id, COUNT(*) AS n FROM lm_reinforcements "
            .. "WHERE scope = ? AND event_type IN ('mistake', 'direct_command') "
            .. "GROUP BY memory_id HAVING COUNT(*) >= ?", scope, tier3_at)
        local promote3_ids = {}
        for _, mr in ipairs(mistake_rows or {}) do
            local mid = math.floor(tonumber(mr.memory_id) or 0)
            if mid > 0 then promote3_ids[#promote3_ids + 1] = mid end
        end
        promoted3 = promoted3 + _set_tier(promote3_ids, 2, 3)
    end

    return promoted2, promoted3
end

-- Delete tier-0 rows whose consolidated_at is older than grace_days,
-- relative to `before_us` (the start of the current run). Using the
-- run-start time instead of now prevents rows stamped during this run
-- from being deleted: those rows have consolidated_at >= run_start > cutoff.
local function _purge_stale(scope, before_us)
    local grace = math.max(0, math.floor(tonumber(_cfg.digest_grace_days) or 7))
    local cutoff_us = before_us - grace * 86400 * 1000000
    -- Federation: a bulk delete never touches rows the role must keep
    -- (replicas; directives + approved org knowledge on the central).
    local excl = policy.maintenance_exclusion_sql()
    return db.run("DELETE FROM lm_memories WHERE scope = ? AND tier = 0 AND consolidated_at IS NOT NULL "
        .. "AND consolidated_at < ?" .. (excl and (" AND " .. excl) or ""), scope, cutoff_us) or 0
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
    local run_start = util.now_us()

    local summary = {
        processed  = 0,
        promoted2  = 0,
        promoted3  = 0,
        deleted    = 0,
        errors     = {},
    }

    -- Federation: a dev's org replica mirrors the central — the central runs
    -- the digest for it (and ships the result); nothing to do here.
    if policy.replica(scope) then
        summary.skipped = "replica"
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
            if type(best_vec) == "table" then
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
                    -- Escalate importance of the best member and bump its tier
                    -- with the mistake count: _escalate is a 0–1 relevance, so its
                    -- tier comes from the relevance thresholds (2 mistakes → 1,
                    -- 5 → 2, ~15 → 3), never below where it is.
                    local new_imp = _escalate(best.importance, mistake_n)
                    local new_tier = policy.cap_tier(scope,
                        math.max(tonumber(best.tier) or 0, _tier_from_relevance(new_imp)))
                    local mid = math.floor(tonumber(best.id) or 0)
                    if mid > 0 and policy.feedback_may_mutate(scope, best.tier) then
                        db.run("UPDATE lm_memories SET importance = ?, tier = ? WHERE id = ?",
                            new_imp, math.floor(new_tier), mid)
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
