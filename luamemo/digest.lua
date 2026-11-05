-- luamemo.digest
-- Hippocampus Digest: tier promotion + reinforcement processing.
--
-- Design:
--   * A write claims the scope's digest slot (`claim`, at most once per `auto_digest_interval`) and
--     luamemo.maintenance starts a background `memo maintain` that calls `run(scope)`.
--   * `run(scope, opts)` is also callable explicitly (CLI, MCP tool, test harness).
--
-- Public API:
--   digest.configure(cfg)                -- called by luamemo.store after setup
--   digest.claim(scope)                  -- take the scope's auto-digest slot if due (MEMO_AUTO_DIGEST_INTERVAL;
--                                           luamemo.maintenance reads it and runs the digest)
--   digest.run(scope [, opts])           -- explicit trigger; returns summary table (opts: no_llm — never ask a model,
--                                           dry_run, threshold, deadline — see Public: run below)
--   digest.record_event(memory_id, scope, event_type, delta, note)
--                                        -- log a reinforcement event
--   digest.apply_event_effect(memory_id, scope, event_type, delta)
--                                        -- the row effect of an event, without logging it (the org central applies a
--                                           pushed event once)
--
-- Config keys consumed (their defaults are in luamemo.settings; a day count for the folded rows' grace is luamemo.fold's):
--   digest_escalate_alpha     -- sigmoid slope for mistake escalation (a mistake is a "mistake" or a "direct_command" event)
--   digest_promote_tier2_at   -- min proof_count of an observation for the memories it holds to go tier-1 → tier-2
--   digest_promote_tier3_at   -- how many mistake events (direct commands count) a tier-2 memory needs for tier-3
--   consolidate_threshold     -- the cosine at which the tier-0 rows are grouped into clusters (unset: the dedup threshold;
--                                opts.threshold overrides it for the digest's own grouping, step 2, only)
--   (consolidate_reinforce_threshold — how close an observation must be to a cluster to count as matching it, step 3a —
--   is read by consolidate.would_reinforce / process, from consolidate's own config, not by this module)
--
-- Digest pipeline (per scope):
--   1. Fetch up to 500 unconsolidated tier-0 memories that have a vector, highest importance first (a note stored
--      without one is left as it is until it is re-embedded: consolidate.process cannot make an observation from it,
--      and a fold with none behind it would end in a delete). consolidate.process, step 3b, takes every unconsolidated
--      row of the scope that has a vector (consolidate.UNPROCESSED_SQL): the tier-0 rows beyond these 500 are consolidated by it too, into observations, but not
--      archived here — they are reviewed as rows consolidated before folds were recorded (luamemo.fold,
--      MEMO_DIGEST_GRACE_DAYS after). The unconsolidated rows of higher tiers are consolidated the same way but stay
--      as they are: never archived, never reviewed.
--   2. Cluster them with util.cluster at MEMO_CONSOLIDATE_THRESHOLD (the grouping consolidate.process makes of the scope;
--      opts.threshold changes this grouping only — which cluster is escalated and which rows are archived together —
--      not the one process makes the observations from).
--   3. In three steps (a and c over those clusters, b one call that works on the scope's rows itself):
--      a. a cluster with a mistake-type reinforcement (a mistake or a direct command) behind it that no observation is
--         close enough to — the threshold consolidate.process reinforces at, judged on the cluster's best (first, highest-
--         importance) member; process judges the first of its own id-ordered rows, which is the same one for a cluster
--         of near-identical notes and may differ at the edges — → escalate importance, promote tier (the member stays
--         visible at it) — all clusters, before any observation is made out of their rows; a failed lookup of the
--         observations escalates
--      b. consolidate.process, ONCE: reinforces the observation that matches, or synthesises a new one (a model, unless
--         opts.no_llm). If it raises, or reports that it did nothing (`failed`: not configured, the rows could not be
--         read), nothing is archived and the next run tries again. It marks a cluster consolidated only once an
--         observation holds it, and only the notes unchanged since it read them
--      c. archive the processed tier-0 rows that are consolidated (luamemo.fold: hidden, a review date): a cluster whose
--         observation could not be made, or a note changed meanwhile, is left for the next run
--   4. Promote tier-1 with proof_count >= tier2_at and trend != 'stale' → tier 2.
--   5. Promote tier-2 memories with at least tier3_at mistake events (direct commands count) → tier 3.
--   6. Review the archived rows that are due (luamemo.fold; stops at opts.deadline): delete, correct the observation,
--      or restore.

local M = {}

local db          = require("luamemo.db")
local util        = require("luamemo.util")
local settings    = require("luamemo.settings")   -- (same_memory: one definition of "the same memory")
local vectors     = require("luamemo.vectors")
local consolidate = require("luamemo.consolidate")
local fold        = require("luamemo.fold")
local maintenance = require("luamemo.maintenance")   -- (it requires this module only inside its functions: no cycle)
-- Federation: never mutate a dev's org replica; never create or alter org
-- directives (tier 3) on the central. No-op when role=solo.
local policy      = require("luamemo.federation.policy")
local feedback    = require("luamemo.feedback")   -- (the event-type lists; it requires nothing of luamemo's but db, util, settings)
local EVENT_TYPES = require("luamemo.federation.common").EVENT_TYPES   -- (the one list of valid reinforcement events)

-- A reinforcement event's memory id as an integer (0: none) and its delta clamped to [-1, 1] (0.5 when it is none).
-- Total: tonumber("nan") is a NaN, which math.min / math.max pass through — it is no number here, for the id and the delta.
local function _norm_event(memory_id, delta)
    local id, d = tonumber(memory_id), tonumber(delta)
    if id == nil or id ~= id then id = 0 end
    if d == nil or d ~= d then d = 0.5 end
    return math.floor(id), math.max(-1.0, math.min(1.0, d))
end

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
local _cfg = {}

-- (the numbers are read where they are used, settings.number(_cfg, key): the config's own, else the setting's default.
-- The grouping similarity has no number of its own: unset, it is the dedup threshold — settings.same_memory.)
function M.configure(cfg)
    _cfg = cfg or {}
end

--- The scope's auto-digest slot, if it is due → true when this caller won it (and so must see the digest through).
--- Lazy and debounced, for STATELESS callers (the CLI) as much as the MCP server: a write piggybacks the digest, at
--- most once per auto_digest_interval per scope, the state in lm_digest_state so the debounce survives across
--- processes. Atomic (luamemo.maintenance.claim), so of any number of callers at most one wins per interval — a race
--- can't double-run the digest. The work itself is done beside the agent (luamemo.maintenance.after_write starts a
--- background `memo maintain`): a digest may ask a language model for an observation's wording, which takes a minute.
function M.claim(scope)
    if policy.maintenance_skip(scope) then return false end   -- no scope; a replica mirrors the central; the code index is not memory
    return maintenance.claim_slot("digest", scope)
end

-- ---------------------------------------------------------------------------
-- Importance-escalation / diminishment helpers
-- ---------------------------------------------------------------------------

-- The relevance (0–1) that a number of mistakes behind a memory stands for: sigmoid-like, asymptotes toward 1.0.
--   (at the default alpha, 0.4) After 1 mistake: ≈ 0.29. After 3: ≈ 0.55. After 8: ≈ 0.76. After 15: ≈ 0.86.
local function _relevance(mistakes)
    local x = math.max(0, tonumber(mistakes) or 0)
    return 1.0 - 1.0 / (1.0 + x * settings.number(_cfg, "digest_escalate_alpha"))
end

-- Soft diminishment for reversals: moves importance halfway toward 0.3
-- (the tier-1/tier-0 boundary), scaled by delta strength.
--   delta = 1.0 → moves halfway: new = current - (current - 0.3) * 0.5
--   delta = 0.5 → moves quarter:  new = current - (current - 0.3) * 0.25
-- importance's own 0–10 scale: a 5 falls to 3.8 on one reversal (delta 0.5), not to 1.0. It never raises
-- (a memory already under 0.3 stays where it is).
local function _lower_importance(current, delta)
    local c = tonumber(current) or 0.5
    local d = math.abs(delta)   -- (delta is _norm_event's: a number in [-1, 1])
    local new = c - (c - 0.3) * d * 0.5
    return math.max(0.0, math.min(c, new))
end

-- Miss reinforcement: retrieval failed to surface a memory that was needed, so
-- raise its importance (scaled by delta) — the direct remedy that makes it rank
-- higher / surface next time, independent of the learned models. Only ever moves upward.
-- On importance's own 0–10 scale (an ordinary memory is 1.0):
--   below 1.0: toward 1.0   delta 0.5 → new = current + (1 - current) * 0.25
--   from 1.0:  proportional delta 0.5 → new = current * 1.25   (1 → 1.25 → 1.56 …)
-- up to MISS_CEILING, so repeated misses cannot pin one memory above everything else; a memory
-- already above the ceiling is left as it is.
local MISS_CEILING = 7.0
local function _raise_importance(current, delta)
    local c = tonumber(current) or 0.5
    local d = math.abs(delta)   -- (delta is _norm_event's: a number in [-1, 1])
    local new
    if c < 1.0 then new = math.min(1.0, c + (1.0 - c) * d * 0.5)
    else new = math.min(c * (1.0 + d * 0.5), math.max(c, MISS_CEILING)) end
    return math.max(c, new)
end

-- The digest's own 0–1 relevance (_relevance) → tier, for the mistake
-- escalation of a digested cluster. (Write-time tiers, and a reversal's, use
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
-- and its tier is updated to match; a "miss" raises only its importance, in proportion (up to a ceiling of 7), so
-- retrieval finds it next time.  The event (type, delta, note) is recorded in
-- lm_reinforcements; the digest later counts the mistakes among them (escalation, tier 3).
-- ---------------------------------------------------------------------------
function M.record_event(memory_id, scope, event_type, delta, note)
    if not memory_id or not scope then return end
    if not EVENT_TYPES[event_type] then return end

    local mid, clamped_delta = _norm_event(memory_id, delta)
    if mid <= 0 then return end  -- guard against invalid / zero FK

    -- fire-and-forget: an event that cannot be stored (the memory is gone) is not an error, and has no effect either — an
    -- effect nothing records would be one the digest and the learners can never count
    if not db.run("INSERT INTO lm_reinforcements (memory_id, scope, event_type, delta, note, created_at) "
        .. "VALUES (?, ?, ?, ?, ?, ?)", mid, scope, event_type, clamped_delta, note, util.now_us()) then return end
    M.apply_event_effect(mid, scope, event_type, clamped_delta)
end

-- Raise or lower a memory's importance and tier, as the federation allows: a replica row or a directive is never changed
-- and other org rows are capped at tier 2 on the central. `tier_now`, `imp_now`: the tier and importance the row had when
-- it was read — the write only happens if it still has both (a change made meanwhile by someone else is not overwritten:
-- a miss raises the importance and leaves the tier alone). The id is a memory's: both callers have it from a row or have
-- checked it. → how many rows it changed (0: the row had changed since it was read), nil when it was not allowed or failed.
local function _set_importance_tier(scope, mem_id, tier_now, imp_now, new_imp, new_tier)
    if not policy.feedback_may_mutate(scope, tier_now) then return end
    return (db.run("UPDATE lm_memories SET importance = ?, tier = ? WHERE id = ? AND tier = ? AND importance = ?",
        new_imp, math.floor(policy.cap_tier(scope, new_tier)), mem_id, tier_now, imp_now))
end

-- ---------------------------------------------------------------------------
-- Public: apply_event_effect
-- The immediate row effect of a reinforcement event, separated from logging it
-- so the org central can apply it exactly once for an idempotent pushed event
-- (insert ON CONFLICT DO NOTHING → apply only when the row was new).
--   Reversal: importance diminishment + tier demotion.
--   Miss: importance BUMP (the tier is left alone) so the memory that retrieval
--   failed to surface becomes more findable next time.
-- Federation: replica rows and org directives are never changed; other org
-- rows are capped at tier 2 on the central.
-- ---------------------------------------------------------------------------
function M.apply_event_effect(memory_id, scope, event_type, delta)
    local mid, clamped_delta = _norm_event(memory_id, delta)
    if mid <= 0 then return end
    if event_type == "reversal" or event_type == "miss" then
        -- (importance and tier are NOT NULL columns)
        local mem = db.first("SELECT importance, tier FROM lm_memories WHERE id = ?", mid)
        if mem then
            local new_imp = (event_type == "miss")
                and _raise_importance(mem.importance, clamped_delta)
                or _lower_importance(mem.importance, clamped_delta)
            -- A miss raises importance (ranking) and never demotes; a reversal
            -- demotes to what its lowered importance supports — never raises.
            local new_tier = (event_type == "miss") and mem.tier
                or math.min(mem.tier, util.importance_to_tier(new_imp))
            _set_importance_tier(scope, mid, mem.tier, mem.importance, new_imp, new_tier)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

-- Fetch tier-0 memories that have not yet been consolidated for a scope — those with a vector: consolidate.process
-- only reads rows that have one, so a note stored without (the embedder was down, the text too long) would be folded
-- here with no observation made from it, and the review would later delete it as "no observation holds it". It stays
-- as it is until it is re-embedded (memo reembed). → rows, or nil + why (the run reports it and does nothing else with
-- the scope's notes: an empty answer would be taken for "nothing to digest").
local function _fetch_tier0(scope)
    local rows, err = db.query("SELECT id, importance, tier, embedding "
        .. "FROM lm_memories WHERE scope = ? AND tier = 0 AND " .. consolidate.UNPROCESSED_SQL .. " "
        .. "ORDER BY importance DESC, created_at ASC, id ASC LIMIT 500", scope)
    if not rows then return nil, "fetch tier-0 error: " .. tostring(err) end
    for _, r in ipairs(rows) do r.embedding = vectors.unpack(r.embedding) end
    return rows
end

-- Fetch mistake-event counts for a set of memory IDs via a single aggregate
-- query.  Returns a table keyed by memory_id (as string) → count (number), or nil + why: a count that could not be read
-- is not "no mistakes" (the cluster would be archived without the escalation its mistakes call for).
local function _fetch_mistake_counts(ids)
    if #ids == 0 then return {} end
    local rows, err = db.query("SELECT memory_id, COUNT(*) AS n FROM lm_reinforcements "
        .. "WHERE memory_id IN (" .. db.placeholders(#ids) .. ") "
        .. "AND event_type IN " .. feedback.MISTAKE_SQL .. " GROUP BY memory_id", unpack(ids, 1, #ids))
    if not rows then return nil, "mistake counts error: " .. tostring(err) end
    local by_id = {}
    for _, r in ipairs(rows) do
        by_id[tostring(r.memory_id)] = tonumber(r.n) or 0
    end
    return by_id
end


-- Promote by proof and by mistake history; each step is ONE statement, the ids never pass through Lua (a statement's
-- variables and LuaJIT's unpack both stop at a few thousand: an observation that absorbed that many memories would
-- otherwise make this raise and stop the review that follows). Returns the counts of tier-1→2 and tier-2→3 promotions,
-- and a list of what went wrong (a statement that failed: one observation with malformed evidence_ids fails the first).
local function _promote(scope)
    -- (a replica scope never gets here: run returns on maintenance_skip first)
    local tier2_at = settings.number(_cfg, "digest_promote_tier2_at")
    local tier3_at = settings.number(_cfg, "digest_promote_tier3_at")
    local errors = {}

    -- Tier-1 → tier-2: memories whose consolidated observation has enough proof
    -- (proof_count >= tier2_at, trend != stale).
    local promoted2, err2 = db.run("UPDATE lm_memories SET tier = 2 WHERE scope = ? AND tier = 1 AND id IN ("
        .. "SELECT CAST(e.value AS INTEGER) FROM lm_observations o, json_each(o.evidence_ids) e "
        .. "WHERE o.scope = ? AND o.proof_count >= ? AND o.freshness_trend != 'stale')", scope, scope, tier2_at)
    if promoted2 == nil then errors[#errors + 1] = "promote tier 2: " .. tostring(err2) end

    -- Tier-2 → tier-3: memories with enough mistake-escalated reinforcements.
    -- Never on a protected org scope: there the core tier is directive-only.
    local promoted3 = 0
    if not policy.protected(scope) then
        local err3
        promoted3, err3 = db.run("UPDATE lm_memories SET tier = 3 WHERE scope = ? AND tier = 2 AND id IN ("
            .. "SELECT memory_id FROM lm_reinforcements WHERE scope = ? AND event_type IN " .. feedback.MISTAKE_SQL
            .. " GROUP BY memory_id HAVING COUNT(*) >= ?)", scope, scope, tier3_at)
        if promoted3 == nil then errors[#errors + 1] = "promote tier 3: " .. tostring(err3) end
    end

    return promoted2 or 0, promoted3 or 0, errors
end

-- Each cluster of the scope's unconsolidated rows as a plan entry: { size, ids, best, best_id, mistake_n } — `best` the
-- cluster's first member: the rows are fetched highest importance first and util.cluster keeps the order, so it is the
-- highest-importance one (consolidate.process pivots on the first of its own id-ordered rows: the same vector for a
-- cluster of near-identical notes, not always); mistake_n the mistake / direct-command events behind the cluster (the
-- counts of every row in one query). → the plan, or nil + why when the counts could not be read.
local function _plan(clusters)
    local plan, all_ids = {}, {}
    for _, cluster in ipairs(clusters) do
        local ids = {}
        for _, m in ipairs(cluster) do
            ids[#ids + 1] = math.floor(tonumber(m.id) or 0)
            all_ids[#all_ids + 1] = ids[#ids]
        end
        plan[#plan + 1] = { size = #ids, ids = ids, best = cluster[1], best_id = ids[1], mistake_n = 0 }
    end
    local counts, err = _fetch_mistake_counts(all_ids)
    if not counts then return nil, err end
    for _, c in ipairs(plan) do
        for _, id in ipairs(c.ids) do c.mistake_n = c.mistake_n + (counts[tostring(id)] or 0) end
    end
    return plan
end

-- A cluster with mistakes behind it that no observation is close enough to (by the threshold consolidate.process
-- reinforces at, on the cluster's best member's vector): raise the importance of its best member and bump its tier with the mistake count
-- (the tier comes from _relevance(mistakes), a 0–1 value, through the relevance thresholds — at the default alpha 2
-- mistakes → 1, 4 → 2, 15 → 3; never below where it is — and not from the row's importance, which is on a 0–10 scale;
-- the importance is raised to that relevance only if it is lower). A cluster the consolidation will reinforce into an observation is not
-- escalated. The observations are asked BEFORE the consolidation makes one out of each cluster's own rows, in one pass
-- for all the clusters that have mistakes. If that lookup fails every asked cluster is escalated: a mistake is not left
-- unmarked for want of an answer (escalation only raises, so a later run does no harm).
local function _escalate_clusters(scope, plan)
    local asked, vecs = {}, {}
    for _, c in ipairs(plan) do
        if c.mistake_n > 0 then
            asked[#asked + 1] = c
            vecs[#asked] = type(c.best.embedding) == "table" and c.best.embedding or false
        end
    end
    if #asked == 0 then return end
    local ok, matched = pcall(consolidate.would_reinforce, scope, vecs)
    for i, c in ipairs(asked) do
        if not (ok and matched[i]) then
            local rel = _relevance(c.mistake_n)
            local function escalate(row)   -- → rows changed (0: the row changed since it was read)
                return _set_importance_tier(scope, c.best_id, row.tier, row.importance,
                    math.max(tonumber(row.importance) or 0.0, rel), math.max(row.tier, _tier_from_relevance(rel)))
            end
            if escalate(c.best) == 0 then
                -- the row changed since it was read (an event raised its importance): read it as it is now and try once
                -- more — left at tier 0 the cluster would be archived, and its mistaken note deleted at the review. (A
                -- second race on the same row in that moment is not chased: the note is then archived like its copies.)
                local cur = db.first("SELECT importance, tier FROM lm_memories WHERE id = ?", c.best_id)
                if cur then escalate(cur) end
            end
        end
    end
end

-- Archive the processed tier-0 rows (luamemo.fold: hidden, kept through the grace period, then reviewed against the
-- observation that holds them before they are deleted) — the rows still as the digest read them (fold.archive,
-- digest mode): at tier 0 (a member this run just promoted stays visible at its new tier), in this scope, and
-- consolidated (a note rewritten while the consolidation ran was not made into an observation: it waits for the next
-- run). A cluster whose rows could not be archived is not processed: the next run looks at it.
local function _archive_clusters(scope, plan, summary)
    for _, c in ipairs(plan) do
        local archived, aerr = fold.archive(c.ids, "observation", nil, nil, scope)
        if archived == nil then
            summary.errors[#summary.errors + 1] = "archive error: " .. tostring(aerr)
        else
            summary.processed = summary.processed + c.size
        end
    end
end

-- ---------------------------------------------------------------------------
-- Public: run
-- ---------------------------------------------------------------------------
-- Runs the full digest pipeline for a scope. Returns a summary table:
--   { processed, promoted2, promoted3, deleted, errors, skipped }
-- (processed: the rows of the clusters the run took — a member it escalated stays visible at its new tier and counts too;
-- with dry_run, the rows it would take. skipped: why the scope is not maintained — "no scope", an org replica, the code
-- index — and then nothing else was done. deleted: the folded memories the review deleted. errors: what went wrong, one
-- string each — the notes or their mistake counts that could not be read ("fetch tier-0 error: …" / "mistake counts
-- error: …": nothing was clustered, consolidated or archived), the consolidation ("consolidate error: …": nothing was
-- archived), a cluster that could not be archived ("archive error: …"), a promotion statement ("promote tier 2: …" /
-- "promote tier 3: …"; the other one still runs), the review ("review: …"); the promotion and the review run after a
-- failed consolidation, so errors does not mean nothing was done. What the consolidation reports for one cluster is
-- there too, as "consolidate: …", of two kinds: an observation it could not write or reinforce, a mark that failed, a
-- synthesis that gave no text, a read that checks a cluster is unchanged that failed ("could not check the cluster: …")
-- — those rows are left unconsolidated and unarchived, and the next run tries them again —
-- and notices about how an observation was made ("embed obs body: …": the cluster's own vector is used;
-- "synthesize: <the summarizer's error>", with MEMO_CONSOLIDATE_LOG_ERRORS: the best member's text is used) — they report
-- the embedder or the summarizer, and stand even if the cluster then waited because it changed meanwhile; the rows of a
-- cluster that went through are archived)
--
-- opts (optional table):
--   dry_run      — if true, skip all writes (inspection only)
--   no_llm       — never ask a model for an observation's wording (maintenance sets it for a remote summarizer)
--   threshold    — cosine at which the digest groups the tier-0 rows (which cluster is escalated, which rows are archived
--                  together; not consolidate.process's own grouping). Default: MEMO_CONSOLIDATE_THRESHOLD, else the dedup threshold
--   deadline     — os.time() the review of folded memories at the end stops at (memo maintain's time box)
-- ---------------------------------------------------------------------------
function M.run(scope, opts)
    scope = scope or ""
    opts  = opts or {}
    local dry_run   = opts.dry_run and true or false
    local threshold = tonumber(opts.threshold) or settings.same_memory(_cfg, "consolidate_threshold")
    local summary = {
        processed  = 0,
        promoted2  = 0,
        promoted3  = 0,
        deleted    = 0,
        errors     = {},
    }

    -- A dev's org replica mirrors the central — the central runs the digest for it (and ships the result); the code
    -- index is not memory (nothing to digest, promote or review; memo index rebuilds it from the source).
    summary.skipped = policy.maintenance_skip(scope)
    if summary.skipped then return summary end

    -- 1. Fetch unconsolidated tier-0 memories.
    -- (no tier-0 memories: no clusters, and the promotion and the review at the end still run)
    local tier0, read_err = _fetch_tier0(scope)

    -- 2. Cluster by embedding similarity, each cluster a plan entry.
    local plan = {}
    if tier0 then
        local clustered, plan_err = _plan(util.cluster(tier0, threshold))
        if clustered then plan = clustered else read_err = plan_err end
    end
    if read_err then
        -- the notes or their mistake counts could not be read: nothing is clustered, escalated, consolidated or archived
        -- (a cluster archived without the escalation its mistakes call for is hidden for good); the promotion and the
        -- review below still run, and the next run tries again
        summary.errors[#summary.errors + 1] = read_err
    end

    if dry_run then
        for _, c in ipairs(plan) do summary.processed = summary.processed + c.size end   -- (just count)
    elseif #plan > 0 then
        -- 3. a. escalate the clusters with mistakes behind them; b. consolidate, ONCE: consolidate.process takes every
        -- unconsolidated row of the scope that has a vector (consolidate.UNPROCESSED_SQL), reinforcing the observation that matches
        -- or synthesising a new one. If it RAISES, or reports that it did nothing (`failed`: not configured, or it could
        -- not read the rows), nothing is archived (the next run tries again). A cluster whose own step failed (its
        -- observation could not be written or reinforced) is left unconsolidated by process, so c. archive — which takes
        -- only consolidated rows — leaves it too.
        _escalate_clusters(scope, plan)
        local ok_c, c_res = pcall(consolidate.process, scope, { no_llm = opts.no_llm })
        local c_failed   -- what went wrong: the error it raised, or why it says it did nothing (nil: it ran)
        if not ok_c then c_failed = tostring(c_res) elseif c_res.failed then c_failed = c_res.failed end
        if c_failed then
            summary.errors[#summary.errors + 1] = "consolidate error: " .. c_failed
        else
            -- (what it reports for one cluster is reported too: a cluster it could not make an observation of, or mark,
            -- stays unconsolidated, so the archive below leaves it for the next run; a notice about an observation made
            -- all the same — its vector, its wording — leaves its rows consolidated and archived)
            for _, e in ipairs(c_res.errors or {}) do summary.errors[#summary.errors + 1] = "consolidate: " .. e end
            _archive_clusters(scope, plan, summary)
        end
    end

    -- 4 & 5. Tier promotion (skip in dry_run).
    if not dry_run then
        local p2, p3, perrs = _promote(scope)
        summary.promoted2 = p2
        summary.promoted3 = p3
        for _, e in ipairs(perrs) do summary.errors[#summary.errors + 1] = e end

        -- 6. Review the folded raw rows whose grace period is over: deleted only when they were not useful or the
        -- observation holds their facts, else the observation is corrected and they wait again (luamemo.fold). What
        -- went wrong with a row goes to summary.errors (the digest reports the deletes; `memo maintain --review` has
        -- the other counts).
        local review = fold.run(scope, { deadline = tonumber(opts.deadline) })
        for _, e in ipairs(review.errors or {}) do summary.errors[#summary.errors + 1] = "review: " .. e end
        summary.deleted = review.deleted or 0
    end

    return summary
end

return M
