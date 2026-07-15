-- luamemo.feedback — learned-from-usage substrate (Phase 3)
--
-- Turns real usage into training data for the learned reranker (Phase 4) and
-- projection (Phase 5). Two tables cooperate:
--   * lm_retrieval_feedback (migration 010) — one row per retrieval event:
--     the query and the ordered candidate memory ids that were surfaced.
--   * lm_reinforcements (migration 009) — corrections/outcomes on a memory
--     (mistake / reversal / direct_command / praise).
--
-- harvest() joins them: for each reinforced memory, it finds retrieval events
-- whose candidate set contained that memory and emits a (query, positive,
-- negatives, weight, signal) triple. Because a positive requires a
-- reinforcement, RAW ACCESS FREQUENCY YIELDS NO TRAINING SIGNAL — corrections
-- and outcomes are the only thing that labels data, exactly as the plan requires.
--
-- log_retrieval() is fail-silent and append-only; store.search calls it only
-- when config.feedback_enabled is true, so it is inert by default.

local db = require("luamemo.db")

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

-- pgmoon returns BIGINT[] as a Lua array; tolerate a "{1,2,3}" string too.
local function parse_bigint_array(v)
    local out = {}
    if type(v) == "table" then
        for _, x in ipairs(v) do out[#out + 1] = tonumber(x) end
    elseif type(v) == "string" then
        for n in v:gmatch("%-?%d+") do out[#out + 1] = tonumber(n) end
    end
    return out
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
        if n then parts[#parts + 1] = string.format("%d", n) end
    end
    if #parts == 0 then return false end
    local sql = "INSERT INTO lm_retrieval_feedback (scope, query, candidate_ids) VALUES ("
        .. db.escape_literal(scope) .. ", " .. db.escape_literal(query)
        .. ", '{" .. table.concat(parts, ",") .. "}')"
    local ok = pcall(db.query, sql)
    return ok == true
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
    local sql = "INSERT INTO lm_reinforcements (memory_id, scope, event_type, delta, note) VALUES ("
        .. string.format("%d", mid) .. ", " .. db.escape_literal(scope) .. ", "
        .. db.escape_literal(event_type) .. ", " .. string.format("%.6f", d) .. ", "
        .. (note and db.escape_literal(note) or "NULL") .. ")"
    local ok, err = pcall(db.query, sql)
    if not ok then return nil, err end
    return true
end

--- Harvest (query, positive, negatives, weight, signal) triples for a scope by
--- joining reinforcements to the retrieval events that surfaced them.
--- Deduplicated by (query, positive), keeping the highest-weight signal, so a
--- single strong correction outranks many weak repeats.
-- @param opts.limit         max reinforcement events to consider (default 1000)
-- @param opts.recent_events retrieval events scanned per positive (default 5)
-- @return array of { query, positive, negatives[], weight, signal }
function M.harvest(scope, opts)
    opts = opts or {}
    local ev_limit = tonumber(opts.limit) or 1000
    local per_pos  = tonumber(opts.recent_events) or 5

    local reinf = db.query(
        "SELECT memory_id, event_type FROM lm_reinforcements WHERE scope = "
        .. db.escape_literal(scope) .. " ORDER BY created_at DESC LIMIT " .. ev_limit)
    if not reinf then return {} end

    local best = {}   -- "query\0positive" -> triple (highest weight wins)
    for _, r in ipairs(reinf) do
        local pos = tonumber(r.memory_id)
        local w   = REINFORCE_WEIGHT[r.event_type] or 1.0
        if pos then
            local events = db.query(
                "SELECT query, candidate_ids FROM lm_retrieval_feedback WHERE scope = "
                .. db.escape_literal(scope) .. " AND candidate_ids @> ARRAY["
                .. string.format("%d", pos) .. "]::bigint[] ORDER BY created_at DESC LIMIT " .. per_pos)
            for _, e in ipairs(events or {}) do
                local negs = {}
                for _, cid in ipairs(parse_bigint_array(e.candidate_ids)) do
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
