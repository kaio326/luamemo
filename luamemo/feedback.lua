-- luamemo.feedback — learned-from-usage substrate (Phase 3), and the usage log
--
-- Turns real usage into training data for the learned reranker (Phase 4) and
-- projection (Phase 5). Two tables cooperate:
--   * lm_retrieval_feedback — one row per retrieval event: the query and the
--     ordered candidate memory ids that were surfaced (a JSON array; the schema
--     mirrors it into lm_retrieval_candidates for the "which retrievals surfaced
--     memory X" lookup).
--   * lm_reinforcements — corrections/outcomes on a memory
--     (mistake / reversal / direct_command / miss / praise).
--
-- harvest() joins them: a reinforcement labels the search just before it that
-- offered the memory, and emits a (query, positive, negatives, weight, signal, at)
-- triple. Because a positive requires a reinforcement, RAW ACCESS FREQUENCY YIELDS
-- NO TRAINING SIGNAL — corrections and outcomes are the only thing that labels data,
-- exactly as the plan requires.
--
-- log_retrieval() / log_no_result() are fail-silent; store.search calls them only
-- when config.feedback_enabled is true, so the log is inert by default. The log
-- only grows by appending, except prune() (MEMO_FEEDBACK_RETENTION_DAYS), and the
-- module also owns the note a miss is recorded with (miss_note / miss_kind) and
-- what `memo doctor` says about the log (status_lines).

local db       = require("luamemo.db")
local util     = require("luamemo.util")
local settings = require("luamemo.settings")

local M = {}

-- Signal weights. Corrections and explicit commands are highest; a confirmed
-- outcome is high. There is deliberately no "frequency" weight — frequency
-- never produces a positive (see harvest()).
local REINFORCE_WEIGHT = {
    mistake        = 3.0,  -- memory should have prevented an error (correction)
    reversal       = 3.0,  -- a prior belief was contradicted (correction)
    direct_command = 3.0,  -- explicit instruction about this memory
    miss           = 3.0,  -- retrieval failed to surface a needed memory (should have ranked)
    praise         = 2.0,  -- outcome: memory confirmed correct/useful
}
M.REINFORCE_WEIGHT = REINFORCE_WEIGHT

-- The groups of event types the rest of luamemo asks about, as SQL lists: a memory "confirmed useful", one that "turned
-- out wrong", and the events the digest counts as mistakes behind a memory (a direct command too). (A new event type is
-- added to REINFORCE_WEIGHT, to federation.common.EVENT_TYPES and the schema's CHECK, and here if it belongs to a group.)
M.POSITIVE_SQL = "('praise', 'direct_command')"
M.NEGATIVE_SQL = "('mistake', 'reversal')"
M.MISTAKE_SQL  = "('mistake', 'direct_command')"   -- the digest's: the mistakes behind a memory (escalation, the core tier)
M.LABEL_SQL    = "('praise', 'direct_command', 'mistake', 'miss')"   -- the learner's: a reversal is not one (the digest lowers that memory, the fold counts it as wrong)

-- candidate_ids comes back decoded (a Lua array); tolerate a "[1,2,3]" string too.
local function id_list(v)
    local out = {}
    if type(v) == "table" then
        for _, x in ipairs(v) do out[#out + 1] = tonumber(x) end
    elseif type(v) == "string" then
        for n in v:gmatch("%-?%d+") do out[#out + 1] = tonumber(n) end
    end
    return out
end
M._id_list = id_list

-- One row of the log (the trigger fills lm_retrieval_candidates from candidate_ids). Fail-silent. → true | false
local function insert_row(scope, query, candidate_ids)
    local ok, n = pcall(db.run, "INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids, created_at) "
        .. "VALUES (?, ?, ?, ?)", scope, query, candidate_ids, util.now_us())
    return ok and n ~= nil
end

--- Append-only log of one retrieval event.
-- @param scope string
-- @param query string
-- @param ids   array of candidate memory ids, in rank order
-- @return boolean  true if written; fail-silent (never raises)
function M.log_retrieval(scope, query, ids)
    if not scope or not query or query == "" or type(ids) ~= "table" or #ids == 0 then
        return false
    end
    local parts = {}
    for i = 1, #ids do
        local n = tonumber(ids[i])
        if n then parts[#parts + 1] = math.floor(n) end
    end
    if #parts == 0 then return false end
    return insert_row(scope, query, db.json(parts))
end

-- A search that found nothing. It is a fact about how luamemo is used — the question had no answer in
-- memory — and the clearest sign of a gap, for `memo usage`; it is NOT a memory and nothing learns from it:
-- it lives only in this log table (candidate_ids "[]"), not in lm_memories; it has no candidates, so
-- harvest (the learners' training set) and the org push, which both go through them, never see it; sensing
-- does not count it as the log being "active".
M.EMPTY = "[]"
local DAY_US = util.DAY_US

local _cfg = {}
function M.configure(cfg) _cfg = cfg or {} end

--- How many days a search stays in the log (MEMO_FEEDBACK_RETENTION_DAYS; 0: forever). cfg: default the configured one.
function M.retention_days(cfg)
    return settings.number(cfg or _cfg, "feedback_retention_days")
end

-- "Just before": the one definition, for a reinforcement's label and for a miss.
M.JUST_BEFORE_MINUTES = 10
local JUST_BEFORE_US = M.JUST_BEFORE_MINUTES * 60 * 1000000

-- The search a reinforcement `r` labels, as a scalar subquery: the newest at or before it, within the window, that offered
-- the memory in the same scope and from the same place (this device, or the same dev on a central). harvest trains on
-- this row and prune keeps this row, so they agree on which search a reinforcement labels. (harvest reads only each scope's
-- newest 1000 reinforcements; prune keeps the older ones' searches too, at most one each.)
local LABELLED_SEARCH_SQL = "SELECT f.id FROM lm_retrieval_candidates c JOIN lm_retrieval_feedback f ON f.id = c.feedback_id "
    .. "WHERE c.memory_id = r.memory_id AND f.scope = r.scope AND f.source IS r.source AND f.created_at <= r.created_at "
    .. ("AND f.created_at >= r.created_at - %d ORDER BY f.created_at DESC, f.id DESC LIMIT 1"):format(JUST_BEFORE_US)

--- Remove the searches older than the retention that nothing learns from. → rows removed | nil, err (the delete failed)
-- Kept: a search a reinforcement labels, and a row adopted from an organization (source set: not ours to drop). A
-- reinforcement arrives within the window, so a search older than the retention can never gain a label. A search that found
-- nothing offered no memory, so it goes at the same age.
function M.prune()
    local days = M.retention_days()
    if days <= 0 then return 0 end
    local ok, n, err = pcall(db.run, "DELETE FROM lm_retrieval_feedback WHERE source IS NULL AND created_at < ? AND id NOT IN ("
        .. "SELECT id FROM (SELECT (" .. LABELLED_SEARCH_SQL .. ") AS id FROM lm_reinforcements r WHERE r.event_type IN "
        .. M.LABEL_SQL .. ") WHERE id IS NOT NULL)", util.now_us() - days * DAY_US)
    if not ok then return nil, tostring(n) end
    if n == nil then return nil, tostring(err) end
    return tonumber(n) or 0
end

--- Log one search that returned nothing. → true | false (fail-silent, like log_retrieval)
function M.log_no_result(scope, query)
    if not scope or not query or query == "" then return false end
    -- (the log's prune is not run from here: a search waits for it. `memo maintain` prunes once a day, started by a
    -- write's maintenance or by the session brief.)
    return insert_row(scope, query, M.EMPTY)
end

-- The kinds of miss, and how one is written in the note of its lm_reinforcements row (store writes it, memo usage reads it).
M.MISS_KINDS = { "not-offered", "offered", "no-search" }
local MISS_NOTE = "miss:duplicate-write:"
local MISS_NOTE_PATTERN = "^" .. MISS_NOTE:gsub("%p", "%%%0") .. "([%a%-]+)$"
function M.miss_note(kind) return MISS_NOTE .. kind end
--- → the kind a note records | nil (an older note, written before the kinds)
function M.parse_miss_note(note)
    local kind = tostring(note or ""):match(MISS_NOTE_PATTERN)
    for _, k in ipairs(M.MISS_KINDS) do if k == kind then return kind end end
    return nil
end

--- A memory was written again (a near-duplicate): was it a ranking miss? Looks at the searches in that scope in the
--- last JUST_BEFORE_MINUTES. → "no-search" (nobody looked: a habit, not the ranking's fault) | "offered" (a search
--- offered it and it was written anyway) | "not-offered" (a search ran and did not offer it: the ranking missed it)
function M.miss_kind(scope, memory_id)
    local since = util.now_us() - JUST_BEFORE_US
    local ok, row = pcall(db.first, "SELECT count(*) AS n, COALESCE(sum(EXISTS(SELECT 1 FROM lm_retrieval_candidates c "
        .. "WHERE c.feedback_id = f.id AND c.memory_id = ?)), 0) AS offered FROM lm_retrieval_feedback f "
        .. "WHERE f.scope = ? AND f.created_at >= ?", math.floor(tonumber(memory_id) or 0), scope, since)
    if not ok or not row or (tonumber(row.n) or 0) == 0 then return "no-search" end
    return (tonumber(row.offered) or 0) > 0 and "offered" or "not-offered"
end

--- What `memo doctor` says about the usage log: whether it is on, what that keeps, and what it enables. → array of lines
function M.status_lines(cfg)
    local days = M.retention_days(cfg)
    local kept = days > 0 and ("for %d days"):format(days) or "forever"
    if not cfg.feedback_enabled then
        return { ("    usage log:    off (the default). MEMO_FEEDBACK_ENABLED=true keeps the text of every search in this database %s;"):format(kept),
                 "                  it enables `memo usage`, miss detection and the learned reranker (MEMO_RERANK_ADAPTER=learned)." }
    end
    local row = db.first("SELECT count(*) AS n, min(created_at) AS t0 FROM lm_retrieval_feedback") or {}
    local n, t0 = tonumber(row.n) or 0, tonumber(row.t0)
    local out = { ("    usage log:    on, %d search%s kept %s%s; the text of each search is stored in this database"):format(n,
        n == 1 and "" or "es", kept, t0 and (", the oldest %d days old"):format(math.floor((util.now_us() - t0) / DAY_US)) or "") }
    local share = tostring(cfg.org_share or "triples")
    if share ~= "signals" and cfg.org_url and cfg.org_url ~= "" then
        out[#out + 1] = ("                  this project is joined to an organization with MEMO_ORG_SHARE=%s: the queries behind confirmed memories are sent to it"):format(share)
    end
    local grace = math.max(settings.number(cfg, "fold_grace_days") or 0, settings.number(cfg, "digest_grace_days") or 0)
    if days > 0 and days < grace then
        out[#out + 1] = ("                  note: searches are kept %d days, a folded memory is reviewed after up to %d (MEMO_FOLD_GRACE_DAYS, MEMO_DIGEST_GRACE_DAYS): what offered it before that no longer counts as 'shown useful'"):format(days, grace)
    end
    local learned
    if cfg.rerank_adapter ~= "learned" then learned = "not chosen"
    elseif cfg.learn_auto == false then learned = "chosen (MEMO_LEARN_AUTO=false: trained only when you ask)"
    else learned = ("chosen (trains from this log every %d days)"):format(settings.number(cfg, "learn_interval_days")) end
    out[#out + 1] = "                  learned reranker: " .. learned
    return out
end

--- Prune at most once a day per database (every maintenance run calls it) → rows removed | nil (not due) | nil, err.
function M.prune_daily()
    -- (lazy: luamemo.maintenance requires this module at its top)
    if not require("luamemo.maintenance").claim("lm_meta", "key", "value", "feedback_pruned_at", util.DAY_S) then return nil end
    return M.prune()
end

--- Record a reinforcement (correction/outcome) on a memory. Thin wrapper over
--- lm_reinforcements so callers/tests can label without the digest pipeline.
-- @return true | nil, err
function M.record_reinforcement(memory_id, scope, event_type, delta, note)
    local mid = tonumber(memory_id)
    if not mid then return nil, "record_reinforcement: memory_id required" end
    if not REINFORCE_WEIGHT[event_type] then
        return nil, "record_reinforcement: unknown event_type " .. tostring(event_type)
    end
    local d = tonumber(delta) or REINFORCE_WEIGHT[event_type]
    local n, err = db.run("INSERT INTO lm_reinforcements (memory_id, scope, event_type, delta, note, created_at) "
        .. "VALUES (?, ?, ?, ?, ?, ?)", math.floor(mid), scope, event_type, d, note, util.now_us())
    if not n then return nil, err end
    return true
end

--- Harvest (query, positive, negatives, weight, signal, at) triples for a scope: each reinforcement labels the newest
--- search at or before it, within the window, that offered the memory and came from the same place (this device, or
--- the same dev on a central). `at` is when that search ran: what search could have known then is what the example
--- may use. Deduplicated by (query, positive), keeping the highest-weight signal, so a single strong correction
--- outranks many weak repeats. In a fixed order, so the same database always trains the same model.
-- @param opts.limit  max reinforcement events to consider (default 1000)
-- @return array of { query, positive, negatives[], weight, signal, at }
function M.harvest(scope, opts)
    opts = opts or {}
    local ev_limit = tonumber(opts.limit) or 1000

    local labels = db.query("SELECT r.memory_id, r.event_type, f.query, f.candidate_ids, f.created_at FROM ("
        .. "SELECT * FROM lm_reinforcements WHERE scope = ? AND event_type IN " .. M.LABEL_SQL
        .. " ORDER BY created_at DESC, id DESC LIMIT ?) r JOIN lm_retrieval_feedback f ON f.id = (" .. LABELLED_SEARCH_SQL
        .. ") ORDER BY r.created_at DESC, r.id DESC", scope, ev_limit)
    if not labels then return {} end

    local best = {}   -- "query\0positive" -> triple (highest weight wins)
    for _, e in ipairs(labels) do
        local pos = tonumber(e.memory_id)
        local w = REINFORCE_WEIGHT[e.event_type] or 1.0
        local negs = {}
        for _, cid in ipairs(id_list(e.candidate_ids)) do
            if cid ~= pos then negs[#negs + 1] = cid end
        end
        if #negs > 0 then
            local key  = tostring(e.query) .. "\0" .. tostring(pos)
            local prev = best[key]
            if not prev or w > prev.weight then
                best[key] = { query = e.query, positive = pos, negatives = negs,
                              weight = w, signal = e.event_type, at = tonumber(e.created_at) }
            end
        end
    end

    local out = {}
    for _, t in pairs(best) do out[#out + 1] = t end
    table.sort(out, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        if a.positive ~= b.positive then return a.positive < b.positive end
        return a.query < b.query
    end)
    return out
end

return M
