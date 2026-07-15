-- luamemo.sensing  (Phase 9 — signal capture orchestrator)
--
-- Turns a conversation's interaction log into reinforcement events, closing the
-- learned-from-usage loop. Given the session's turns (relayed by the agent — luamemo
-- can't read the chat itself), it:
--   1. runs the sensors (heuristics now; local-generative "dreams" extraction and
--      retrieval-miss are additive later),
--   2. resolves each signal to the memory it is about (nearest memory in the scope),
--   3. records a reinforcement on that memory via digest.record_event — the SINGLE
--      canonical writer, so tier `proof_count` and learner labels never double-count,
--   4. is idempotent: a deterministic marker in the note skips re-recording the same
--      signal on re-processing.
--
-- Safe to call from the idle "dreams" pass or explicitly. Fail-soft: never throws.

local heuristics = require("luamemo.sensing.heuristics")
local util       = require("luamemo.util")

local M = {}

-- Optional generative sensor (in-process instruct model). Required lazily and
-- gated by opts.generative so the default pipeline stays heuristics-only
-- (zero-regression) and this stays a precision-filtered enhancement.
local function gather_signals(turns, opts)
    local signals = heuristics.detect(turns)
    if opts.generative == true then
        local ok_ext, extract = pcall(require, "luamemo.sensing.extract")
        if ok_ext then
            local ok, gen = pcall(extract.run, turns, opts)
            if ok and type(gen) == "table" then
                for _, e in ipairs(gen) do signals[#signals + 1] = e end
            end
        end
    end
    return signals
end

-- A correction whose target memory was NOT retrieved is a RANKING miss, not a
-- content mistake: the agent never saw the memory, so retrieval — not its content
-- — caused the error. Reclassify mistake → miss only when the retrieval-feedback
-- log is active for the scope AND the memory has never been a candidate there;
-- otherwise keep the correction as a mistake (conservative — can't prove a miss).
local function reclassify_if_miss(db, scope, mem_id, event_type)
    if event_type ~= "mistake" then return event_type end
    local mid = math.floor(tonumber(mem_id) or 0)
    if mid == 0 then return event_type end
    local lok, lrows = pcall(db.query,
        "SELECT 1 FROM lm_retrieval_feedback WHERE scope = "
        .. db.escape_literal(scope) .. " LIMIT 1")
    if not (lok and lrows and #lrows > 0) then return event_type end  -- log inactive
    local rok, rrows = pcall(db.query,
        "SELECT 1 FROM lm_retrieval_feedback WHERE scope = " .. db.escape_literal(scope)
        .. " AND candidate_ids @> ARRAY[" .. mid .. "]::bigint[] LIMIT 1")
    if rok and rrows and #rrows > 0 then return event_type end  -- was retrieved → real mistake
    return "miss"                                                -- existed but never surfaced
end

-- Resolve a signal to the memory it refers to: the nearest memory in the scope.
-- Returns (memory_id, score) or nil.
local function resolve_memory(store, scope, text, min_sim)
    local rows = store.search({
        query = text, scope = scope, limit = 3,
        skip_temporal = true, skip_observations = true,
    })
    if not rows or not rows[1] then return nil end
    local top = rows[1]
    local sim = tonumber(top.vec_score) or tonumber(top.score) or 0
    if top.id and sim >= min_sim then return top.id, sim end
    return nil
end

-- process(scope, turns, opts) -> { recorded, skipped, signals }
--   turns: array of { role, text } (see heuristics.detect)
--   opts.min_confidence (0.6)  signal confidence floor
--   opts.min_similarity (0.15) memory-resolution floor (precision knob)
--   opts.delta_scale    (1.0)  scales the reinforcement delta (= confidence * scale)
function M.process(scope, turns, opts)
    opts = opts or {}
    local out = { recorded = 0, skipped = 0, signals = 0 }
    if type(scope) ~= "string" or scope == "" then return out end

    local ok_store, store  = pcall(require, "luamemo.store")
    local ok_dig,   digest = pcall(require, "luamemo.digest")
    local ok_db,    db     = pcall(require, "luamemo.db")
    if not (ok_store and ok_dig and ok_db) then return out end

    local min_conf = tonumber(opts.min_confidence) or 0.6
    local min_sim  = tonumber(opts.min_similarity) or 0.15
    local scale    = tonumber(opts.delta_scale)    or 1.0

    -- Sensors: heuristics always; generative extract when opts.generative (opt-in).
    local signals = gather_signals(turns, opts)
    out.signals = #signals

    -- Dedup within this call: if two sensors (heuristic + generative) both point at
    -- the same memory with the same event_type, record it once — the reinforcement
    -- log is a shared signal and double-counting would skew proof_count/learners.
    local seen = {}

    for _, sig in ipairs(signals) do
        if (sig.confidence or 0) >= min_conf then
            local mem_id = resolve_memory(store, scope, sig.text, min_sim)
            -- A correction whose target was never retrieved is a ranking miss.
            local ev_type = mem_id and reclassify_if_miss(db, scope, mem_id, sig.event_type)
                or sig.event_type
            local dedup_key = mem_id and (tostring(math.floor(mem_id)) .. "|" .. ev_type)
            if mem_id and seen[dedup_key] then
                out.skipped = out.skipped + 1
            elseif mem_id then
                seen[dedup_key] = true
                local marker = "sensing:" .. util.djb2_hex(scope .. "|" .. sig.text .. "|" .. ev_type)
                -- idempotency: skip if this exact signal is already on this memory.
                local existed = false
                local eok, erows = pcall(db.query,
                    "SELECT 1 FROM lm_reinforcements WHERE memory_id = " .. tostring(math.floor(mem_id))
                    .. " AND scope = " .. db.escape_literal(scope)
                    .. " AND note LIKE " .. db.escape_literal(marker .. "%") .. " LIMIT 1")
                if eok and erows and #erows > 0 then existed = true end
                if existed then
                    out.skipped = out.skipped + 1
                else
                    local delta = (sig.confidence or 0.7) * scale
                    local note  = marker .. " " .. sig.text:sub(1, 80)
                    local rok = pcall(digest.record_event, mem_id, scope, ev_type, delta, note)
                    if rok then out.recorded = out.recorded + 1 else out.skipped = out.skipped + 1 end
                end
            else
                out.skipped = out.skipped + 1
            end
        else
            out.skipped = out.skipped + 1
        end
    end
    return out
end

return M
