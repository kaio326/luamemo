-- luamemo.consolidate
--
-- Plan 9: Observation Consolidation — Evidence-Tracked Beliefs.
--
-- Clusters unprocessed memories for a scope by cosine similarity, then
-- either reinforces an existing observation (cheap UPDATE) or synthesises a
-- new one via the configured summarizer adapter (an LLM call only for a new
-- cluster of two or more, and never when opts.no_llm: a search, or scheduled
-- work with a remote summarizer). Also provides a search leg that surfaces
-- observations alongside regular memories in store.search().
--
-- Public API:
--   consolidate.configure(config)         -- called by M.setup()
--   consolidate.notify(scope)             -- fast, no DB; sets pending flag
--   consolidate.pending(scope)            -- has a write been notified, or a run left rows (more remain, or a fetch failed)?
--   consolidate.process(scope [, opts])   -- runs clustering + reinforcement (opts: limit, tier_min, no_llm) →
--                                            { reinforced, synthesised, errors, skipped?, failed? }: check `failed` (nothing
--                                            was read or done) before treating the rows as consolidated
--   consolidate.search(scope, qvec, lim)  -- observation search leg
--   consolidate.would_reinforce(scope, vecs) -- per vector: is an observation close enough that process would
--                                              reinforce it? (the digest asks before it escalates a mistake)
--   consolidate.UNPROCESSED_SQL           -- the SQL condition for "a memory process takes" (the digest's fetch shares it)

local db      = require("luamemo.db")
local embed   = require("luamemo.embed")
local util    = require("luamemo.util")
local settings = require("luamemo.settings")   -- (same_memory: one definition of "the same memory")
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
    local days = (os.time() - last_epoch) / util.DAY_S
    if days < 7  and proof_count >= 3 then return "strengthening" end
    if days < 30                       then return "stable"        end
    if days < 90                       then return "weakening"     end
    return "stale"
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
    return math.floor(us / util.DAY_US) * util.DAY_S
end

local _ids = util.ints

-- ---------------------------------------------------------------------------
-- Summarizer dispatch (reuses summarizers adapter cache pattern)
-- ---------------------------------------------------------------------------
local function _load_adapter(name)
    return util.load_submodule(_adapter_cache, "luamemo.summarizers", name, "summarize")
end

-- The text of a memory (or of a summarizer's answer): its body, else its title — a note written with a title only has a
-- vector (its title is embedded), so it is taken, and an empty text would leave it unconsolidated for good. → the text, or
-- nil when it has none.
local function _text_of(t)
    if t.body ~= nil and t.body ~= "" then return t.body end
    if t.title ~= nil and t.title ~= "" then return t.title end
end

-- Synthesise a belief body from a cluster of memories.
-- Uses the configured summarizer when available and not "noop".
-- Falls back to the text of the highest-importance memory in the cluster. → the text ("" when there is none: the caller
-- reports it) and, when the fallback was taken because the summarizer failed, why.
local function _synthesize(cluster, no_llm)
    -- The fallback: the text of the highest-importance member.
    local function best_text(err)
        local best = cluster[1]
        for _, m in ipairs(cluster) do
            if (m.importance or 0) > (best.importance or 0) then best = m end
        end
        return _text_of(best) or "", err
    end

    -- Fall back when no LLM is configured — or when the caller is a search (no_llm): a search waits on this call,
    -- and a language model takes tens of seconds; the observation is the best member's text, and the model's
    -- phrasing is for the background run (memo maintain) to give.
    -- A cluster of one has nothing to summarize: its own words are the observation (a model's rewording of a single
    -- memory took 15 s and said the same thing — and most clusters are single).
    if no_llm or #cluster < 2 then return best_text() end
    local adapter_name = require("luamemo.summarizers._common").adapter_name(cfg)   -- (`auto` resolved: it looks at the disk)
    if adapter_name == "noop" then return best_text() end

    local adapter, aerr = _load_adapter(adapter_name)
    if not adapter then return best_text(aerr) end   -- unavailable: fall back gracefully

    local result, serr = adapter.summarize(cluster, cfg)
    if not result then return best_text(serr) end   -- failed: fall back to the best member's text

    -- (an answer with no text — "body": "" and no title — is no observation: reported by `process`, and the cluster waits)
    return _text_of(result) or "", nil
end

-- ---------------------------------------------------------------------------
-- DB helpers
-- ---------------------------------------------------------------------------

-- The one definition of "a memory consolidate.process takes": not consolidated yet, and with a vector (a note stored
-- without one — the embedder was down, the text too long — is left until it is re-embedded). The digest's own fetch of
-- the rows to archive uses it too: a row archived without an observation made from it would be deleted at its review.
M.UNPROCESSED_SQL = "consolidated_at IS NULL AND embedding IS NOT NULL"

-- Fetch the scope's unprocessed memories (M.UNPROCESSED_SQL) of tier `tier_min` or above — the oldest `limit` of them —
-- with their embedding vectors unpacked → rows, or nil + why (a read that failed is not "nothing to process").
local function _fetch_unprocessed(scope, limit, tier_min)
    local sql = "SELECT id, body, title, importance, updated_at, embedding FROM lm_memories "
        .. "WHERE scope = ? AND " .. M.UNPROCESSED_SQL
        .. (tier_min and (" AND tier >= " .. math.floor(tier_min)) or "") .. " ORDER BY id"
    local rows, err
    if limit then rows, err = db.query(sql .. " LIMIT ?", scope, limit) else rows, err = db.query(sql, scope) end
    if not rows then return nil, tostring(err) end
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
-- each pivot's closest one (n pivots: float tables, or false for none): a single pass, every stored vector scored
-- where it lies against each pivot (vectors.cosine_ptr). They were all unpacked into Lua
-- tables and scored in Lua on every run — the first search after any write: 37 ms at
-- 1,575 observations. → observations, closest[i] = { obs = row, sim = cosine }
local function _observations_near(scope, pivots, n)
    local qs = {}
    for i = 1, n do
        local v = pivots[i]
        qs[i] = type(v) == "table" and #v > 0 and vectors.query(v) or false
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

-- The one definition of "an observation close enough to reinforce": the closest one's raw cosine (an entry of
-- _observations_near's `closest`, or nil) against MEMO_CONSOLIDATE_REINFORCE_THRESHOLD (`need`, from _reinforce_need).
local function _reinforce_need() return settings.same_memory(cfg or {}, "consolidate_reinforce_threshold") end
local function _close_enough(entry, need) return entry ~= nil and entry.sim >= need end

-- A cluster's memories as `process` read them (id and updated_at): the condition "still as they were read" and its two
-- parameters, ONE each whatever the cluster's size (a cluster has no limit; a bound variable per memory stops at LuaJIT's
-- unpack, near 8,000). The stamps are text: json.encode rounds an integer of microseconds.
local STILL_AS_READ = "id IN (SELECT value FROM json_each(?)) AND printf('%d:%d', id, updated_at) IN (SELECT value FROM json_each(?))"
local function _as_read(cluster)
    local ids, stamps = {}, {}
    for _, m in ipairs(cluster) do
        local id = math.floor(tonumber(m.id))
        ids[#ids + 1] = id
        stamps[#stamps + 1] = ("%d:%d"):format(id, tonumber(m.updated_at) or 0)
    end
    return db.json(ids), db.json(stamps)
end

-- Are all of the cluster's memories still unconsolidated, of the scope and as they were read? One rewritten since
-- (store.update moved its updated_at; its new text is in no observation), moved to another scope or otherwise touched
-- makes the cluster wait: no observation made from a read that is out of date, and the next run reads them again.
-- A read that fails is an error, never "changed" (a failing database must not look like a quiet one).
local function _unchanged(scope, cluster)
    local ids_json, stamps_json = _as_read(cluster)
    local count, err = db.value("SELECT count(*) FROM lm_memories WHERE scope = ? AND consolidated_at IS NULL AND " .. STILL_AS_READ,
        scope, ids_json, stamps_json)
    if count == nil then error("could not check the cluster: " .. tostring(err), 0) end
    return tonumber(count) == #cluster
end

-- Is the cluster already known to be out of date? (a pure shortcut before a model or embedder call: `_commit` checks again,
-- inside its transaction, and is the authority; a read that fails is "not known")
local function _known_stale(scope, cluster)
    local ok, still = pcall(_unchanged, scope, cluster)
    return ok and not still
end

-- Mark a cluster's memories as consolidated (consolidated_at = now) — those still as `process` read them.
local function _mark_consolidated(cluster)
    local ids_json, stamps_json = _as_read(cluster)
    assert(db.run("UPDATE lm_memories SET consolidated_at = ? WHERE " .. STILL_AS_READ, util.now_us(), ids_json, stamps_json))
end

-- A cluster's write, ONE transaction: its memories are still as they were read (else nothing is written and the cluster
-- waits), `write()` makes or reinforces the observation (it raises its error, worded), and the memories are marked. Any
-- error undoes all of it: never an observation without its memories marked, nor memories marked without their observation.
-- → "made", write()'s result | "changed" | nil, why
local function _commit(scope, cluster, write)
    local ok, flag, out = db.transaction(function()
        if not _unchanged(scope, cluster) then return "changed" end
        local result = write()
        local okm, merr = pcall(_mark_consolidated, cluster)
        if not okm then error("mark consolidated: " .. tostring(merr), 0) end
        return "made", result
    end)
    if not ok then return nil, tostring(flag) end
    return flag, out
end

local function _append(list, more)
    local out = {}
    for _, v in ipairs(type(list) == "table" and list or {}) do out[#out + 1] = v end
    for _, v in ipairs(more or {}) do out[#out + 1] = v end
    return out
end

-- Reinforce an existing observation: increment proof_count, update evidence_ids, stamp last_reinforced = now and write
-- the freshness_trend that follows from that (it is being reinforced now, with its new proof count) → the observation as it
-- now is, { proof_count, last_reinforced, freshness_trend }: the numbers written, for the caller's in-memory copy. Only
-- the memories the observation's evidence does not hold yet are added and counted (a cluster read again after an unfinished
-- run is not counted twice); a cluster all of whose memories it holds still stamps last_reinforced.
local function _reinforce(obs_id, new_ids, new_quotes)
    local now_is
    local id = math.floor(tonumber(obs_id) or 0)
    local ok, err = db.transaction(function(h)
        local cur = h.first("SELECT proof_count, evidence_ids, evidence_quotes FROM lm_observations WHERE id = ?", id)
        if not cur then error("observation " .. tostring(obs_id) .. " not found", 0) end
        -- only the memories its evidence does not hold yet count (a cluster read again after a run that did not finish
        -- would otherwise be counted twice: its proof, its evidence and its quotes)
        local held = {}
        for _, v in ipairs(type(cur.evidence_ids) == "table" and cur.evidence_ids or {}) do held[tonumber(v)] = true end
        local fresh_ids, fresh_quotes = {}, {}
        for i, mid in ipairs(new_ids) do
            if not held[tonumber(mid)] then
                fresh_ids[#fresh_ids + 1] = mid
                fresh_quotes[#fresh_quotes + 1] = new_quotes and new_quotes[i]
            end
        end
        local proof = tonumber(cur.proof_count) + #fresh_ids   -- (NOT NULL, read inside this transaction)
        now_is = { proof_count = proof, last_reinforced = util.now_us(), freshness_trend = _freshness_trend(os.time(), proof) }
        local n, uerr = h.run("UPDATE lm_observations SET proof_count = ?, evidence_ids = ?, "
            .. "evidence_quotes = ?, freshness_trend = ?, last_reinforced = ? WHERE id = ?",
            proof, db.json(_append(cur.evidence_ids, _ids(fresh_ids))),
            db.json(_append(cur.evidence_quotes, fresh_quotes)), now_is.freshness_trend,
            now_is.last_reinforced, id)
        if not n then error(uerr, 0) end
    end)
    if not ok then error(tostring(err), 0) end   -- (the caller names the observation)
    return now_is
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
    if not n then error(tostring(qerr), 0) end   -- (the caller says it is the insert)
end

-- The result of a call that read or did nothing: `failed` says why, and the one error in `errors` says it with the
-- module's name (a caller must not go on as if the rows were consolidated).
local function _did_nothing(why)
    return { reinforced = 0, synthesised = 0, errors = { "consolidate: " .. why }, failed = why }
end

-- (Clustering is util.cluster: greedy, each memory joins the first cluster whose first member it is as close to as the
-- threshold, else starts one.)

-- A cluster's ids, quote snippets (200 chars of each) and average importance — what an observation is made of.
local function _describe(cluster)
    local ids, quotes, avg_imp = {}, {}, 0
    for _, m in ipairs(cluster) do
        ids[#ids + 1] = m.id
        quotes[#quotes + 1] = util.clip(m.body or "", 200)
        avg_imp = avg_imp + (tonumber(m.importance) or 0.5)
    end
    return ids, quotes, avg_imp / #cluster
end

-- The reinforcement path of a cluster: the closest observation is close enough, so no summarizer is needed. Ends in
-- `_commit`: a cluster whose memories changed since they were read waits for the next run without a word; one whose write
-- failed waits with its error in `result`. `obs` is the observation as `_observations_near` read it: updated in memory to
-- what was written (for the clusters after this one and the trend refresh).
local function _reinforce_cluster(scope, cluster, obs, result)
    local ids, quotes = _describe(cluster)
    local state, res = _commit(scope, cluster, function()
        local ok, reinforced = pcall(_reinforce, obs.id, ids, quotes)   -- (the observation as it now is, or the error)
        if not ok then error("reinforce obs " .. tostring(obs.id) .. ": " .. tostring(reinforced), 0) end
        return reinforced
    end)
    if state == "made" then
        result.reinforced = result.reinforced + 1
        obs.proof_count, obs.last_reinforced, obs.freshness_trend = res.proof_count, res.last_reinforced, res.freshness_trend
    elseif state == nil then
        result.errors[#result.errors + 1] = res
    end
end

-- The synthesis path of a cluster: one summarizer call (or the best member's text), a new observation. `pivot`: the
-- cluster's vector, the fallback when the observation's own text cannot be embedded. Ends in `_commit` like the other path;
-- a summarizer that gave no text makes no observation and the cluster waits — said, not silent.
local function _synthesize_cluster(scope, cluster, pivot, no_llm, result)
    local ids, quotes, avg_imp = _describe(cluster)
    local body, serr = _synthesize(cluster, no_llm)
    if serr and cfg.consolidate_log_errors then
        result.errors[#result.errors + 1] = "synthesize: " .. tostring(serr)
    end
    if not body or body == "" then
        result.errors[#result.errors + 1] = "synthesize: empty body"
        return
    end
    -- The default summarizer keeps a member's text: its stored vector serves (an embedder call per new memory went to that
    -- text again). Else embed it.
    local obs_vec
    for _, m in ipairs(cluster) do
        if _text_of(m) == body and type(m.embedding) == "table" then obs_vec = m.embedding; break end
    end
    if not obs_vec then
        local everr
        obs_vec, everr = embed.embed(body)
        if not obs_vec then
            result.errors[#result.errors + 1] = "embed obs body: " .. tostring(everr)
            obs_vec = pivot
        end
    end
    local state, why = _commit(scope, cluster, function()
        local ok, ierr = pcall(_insert_obs, scope, body, ids, quotes, obs_vec, avg_imp)
        if not ok then error("insert obs: " .. tostring(ierr), 0) end
    end)
    if state == "made" then
        result.synthesised = result.synthesised + 1
    elseif state == nil then
        result.errors[#result.errors + 1] = why
    end
end

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

--- Check whether a scope has pending unprocessed writes — a write notified and not processed yet, or rows a run left
--- (a limited run with more remaining, a fetch that failed).
function M.pending(scope)
    return _pending[scope] == true
end

--- Run the consolidation pipeline for a scope.
--- Fetches the memories of M.UNPROCESSED_SQL (not consolidated yet, and with a vector: a note stored without one is
--- left unconsolidated until it is re-embedded), clusters them by cosine
--- similarity, then either reinforces an existing observation or synthesises
--- a new one.  Each cluster ends in ONE transaction: its memories are still as they were read (not rewritten, moved or
--- otherwise touched meanwhile — else the cluster waits for the next run, silently), the observation is made or reinforced,
--- and the memories are marked consolidated. Any error undoes all of it: the cluster waits, with the error in `errors`
--- ("insert obs: …", "reinforce obs N: …", "mark consolidated: …"; "synthesize: empty body" when the summarizer gave no
--- text; "could not check the cluster: …" when the read that tells it is unchanged failed). A notice about HOW an
--- observation was made ("embed obs body: …" — the cluster's own vector is used —, "synthesize: …" with
--- MEMO_CONSOLIDATE_LOG_ERRORS — the best member's text is used) is in `errors` too: it reports what happened to the
--- embedder or the summarizer, and its memories are marked only if the cluster then went through — one that changed
--- meanwhile waits, and the notice still stands.
---
--- opts.limit: at most that many memories (the oldest), the scope left pending while more
--- remain — what a search runs inline: the whole backlog there (clustering is O(n ×
--- clusters) in Lua) stalled the search after a bulk write (9 s after 5,000 rows).
--- opts.tier_min: only memories of that tier or above (a search: 1 — tier 0 is the digest's).
--- opts.no_llm: never ask the summarizer — a new observation is its best member's text (what a search runs, and
--- the digest when the summarizer is a remote model).
---
--- Returns a summary table:
---   { reinforced = N, synthesised = N, errors = {...}, skipped = why, failed = why }
--- (skipped: the scope is not maintained — a replica, the code index — and nothing was done. failed: nothing was read
--- or done, not configured or the memories could not be fetched — a caller that goes on as if they were consolidated
--- must not: the digest would archive rows no observation holds. A failed fetch leaves the scope pending for the next
--- call; "not configured" changes no flag — M.configure resets them all.)
function M.process(scope, opts)
    if not cfg then return _did_nothing("not configured") end

    -- Clear the pending flag first so concurrent writes queue a follow-up run.
    _pending[scope] = nil

    -- A dev's org replica mirrors the central, which consolidates it; the code index is not memory (observations of
    -- its symbols and dependency edges would be noise).
    local skip = require("luamemo.federation.policy").maintenance_skip(scope)
    if skip then return { reinforced = 0, synthesised = 0, errors = {}, skipped = skip } end

    local result = { reinforced = 0, synthesised = 0, errors = {} }

    local limit = opts and tonumber(opts.limit)
    local memories, ferr = _fetch_unprocessed(scope, limit, opts and tonumber(opts.tier_min))
    if not memories then
        _pending[scope] = true   -- (not read: the next call tries again)
        return _did_nothing("fetch error: " .. ferr)
    end
    if #memories == 0 then return result end
    if limit and #memories >= limit then _pending[scope] = true end   -- more remain: the next call goes on

    -- Cluster unprocessed memories.
    local threshold = settings.same_memory(cfg, "consolidate_threshold")
    local clusters  = util.cluster(memories, threshold)
    local pivots = {}
    for ci, cluster in ipairs(clusters) do pivots[ci] = cluster[1].embedding end
    local observations, closest = _observations_near(scope, pivots, #clusters)
    local need = _reinforce_need()

    for ci, cluster in ipairs(clusters) do
        -- Is the closest existing observation (to the cluster's pivot, its first member's vector: pivots[ci]) close
        -- enough to reinforce? If not, a new one is made — unless the cluster changed while the others before it were
        -- summarized: it waits for the next run, and no model call is made for it.
        if _close_enough(closest[ci], need) then
            _reinforce_cluster(scope, cluster, closest[ci].obs, result)
        elseif _known_stale(scope, cluster) then
            -- (waits)
        else
            _synthesize_cluster(scope, cluster, pivots[ci], opts and opts.no_llm, result)
        end
    end

    -- Refresh freshness trends for all existing observations.
    for _, obs in ipairs(observations) do
        pcall(_refresh_trend, obs)
    end

    return result
end

--- For each vector of `vecs` (float tables, or false for none: no holes), is there an observation of the scope close
--- enough that `process` would reinforce it? The decision `process` takes — the raw cosine of the closest observation
--- against MEMO_CONSOLIDATE_REINFORCE_THRESHOLD — for all of them in one pass over the observations → a list of booleans.
function M.would_reinforce(scope, vecs)
    local _, closest = _observations_near(scope, vecs, #vecs)
    local need, out = _reinforce_need(), {}
    for i = 1, #vecs do out[i] = _close_enough(closest[i], need) end
    return out
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
