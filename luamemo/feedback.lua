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
-- harvest() joins them: for each reinforced memory, it finds retrieval events
-- whose candidate set contained that memory and emits a (query, positive,
-- negatives, weight, signal) triple. Because a positive requires a
-- reinforcement, RAW ACCESS FREQUENCY YIELDS NO TRAINING SIGNAL — corrections
-- and outcomes are the only thing that labels data, exactly as the plan requires.
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

-- harvest() reads the newest HARVEST_EVENTS searches that offered a reinforced memory; KEEP_PER_REINFORCED of them
-- are kept per such memory, past the retention, so the learner still has more than it reads (the setting's text in
-- settings.lua names the number; test_log_retention checks it says the same).
M.HARVEST_EVENTS = 5
M.KEEP_PER_REINFORCED = 4 * M.HARVEST_EVENTS

--- Remove the searches older than the retention that nothing learns from. → rows removed | nil, err (the delete failed)
-- Kept: the newest KEEP_PER_REINFORCED searches (per scope) that offered each memory someone reinforced (feedback.harvest turns
-- exactly those into training triples), and a row adopted from an organization (source set: not ours to drop).
-- A search that found nothing offered no memory, so it goes at the same age.
function M.prune()
    local days = M.retention_days()
    if days <= 0 then return 0 end
    local ok, n, err = pcall(db.run, "DELETE FROM lm_retrieval_feedback WHERE source IS NULL AND created_at < ? AND id NOT IN ("
        .. "SELECT feedback_id FROM (SELECT c.feedback_id AS feedback_id, row_number() OVER ("
        .. "PARTITION BY c.memory_id, f.scope ORDER BY f.created_at DESC, f.id DESC) AS rn "
        .. "FROM lm_retrieval_candidates c JOIN lm_retrieval_feedback f ON f.id = c.feedback_id "
        .. "WHERE c.memory_id IN (SELECT DISTINCT memory_id FROM lm_reinforcements)) WHERE rn <= ?)",
        util.now_us() - days * DAY_US, M.KEEP_PER_REINFORCED)
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

M.MISS_WINDOW_MINUTES = 10

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
--- last MISS_WINDOW_MINUTES. → "no-search" (nobody looked: a habit, not the ranking's fault) | "offered" (a search
--- offered it and it was written anyway) | "not-offered" (a search ran and did not offer it: the ranking missed it)
function M.miss_kind(scope, memory_id)
    local since = util.now_us() - M.MISS_WINDOW_MINUTES * 60 * 1000000
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

--- Harvest (query, positive, negatives, weight, signal) triples for a scope by
--- joining reinforcements to the retrieval events that surfaced them.
--- Deduplicated by (query, positive), keeping the highest-weight signal, so a
--- single strong correction outranks many weak repeats.
-- @param opts.limit         max reinforcement events to consider (default 1000)
-- @param opts.recent_events retrieval events scanned per positive (default HARVEST_EVENTS)
-- @return array of { query, positive, negatives[], weight, signal }
function M.harvest(scope, opts)
    opts = opts or {}
    local ev_limit = tonumber(opts.limit) or 1000
    local per_pos  = tonumber(opts.recent_events) or M.HARVEST_EVENTS

    local reinf = db.query("SELECT memory_id, event_type FROM lm_reinforcements WHERE scope = ? "
        .. "ORDER BY created_at DESC, id DESC LIMIT ?", scope, ev_limit)
    if not reinf then return {} end

    local best = {}   -- "query\0positive" -> triple (highest weight wins)
    for _, r in ipairs(reinf) do
        local pos = tonumber(r.memory_id)
        local w   = REINFORCE_WEIGHT[r.event_type] or 1.0
        if pos then
            local events = db.query("SELECT f.query, f.candidate_ids FROM lm_retrieval_candidates c "
                .. "JOIN lm_retrieval_feedback f ON f.id = c.feedback_id "
                .. "WHERE c.memory_id = ? AND f.scope = ? ORDER BY f.created_at DESC, f.id DESC LIMIT ?",
                pos, scope, per_pos)
            for _, e in ipairs(events or {}) do
                local negs = {}
                for _, cid in ipairs(id_list(e.candidate_ids)) do
                    if cid ~= pos then negs[#negs + 1] = cid end
                end
                if #negs > 0 then
                    local key  = tostring(e.query) .. "\0" .. tostring(pos)
                    local prev = best[key]
                    if not prev or w > prev.weight then
                        best[key] = { query = e.query, positive = pos, negatives = negs,
                                      weight = w, signal = r.event_type }
                    end
                end
            end
        end
    end

    local out = {}
    for _, t in pairs(best) do out[#out + 1] = t end
    return out
end

return M
