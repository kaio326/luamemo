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
--      signal on re-processing,
--   5. with opts.capture, STORES a standing rule the user stated that no memory holds
--      (a decision memory of its own) — the one place sensing writes a memory.
--
-- Safe to call from the idle "dreams" pass or explicitly. Fail-soft: never throws.

local heuristics = require("luamemo.sensing.heuristics")
local util       = require("luamemo.util")

local M = {}

M.CAPTURE_MIN_CONFIDENCE = 0.7   -- (a command signal below it is feedback only: "going forward" is 0.7, "actually" 0.6)

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
    -- (a search that found nothing says nothing about which memories surface: it does not make the log active)
    local lok, active = pcall(db.value, "SELECT 1 FROM lm_retrieval_feedback WHERE scope = ? AND candidate_ids <> ? LIMIT 1",
        scope, require("luamemo.feedback").EMPTY)
    if not (lok and active) then return event_type end  -- log inactive
    local rok, seen = pcall(db.value, "SELECT 1 FROM lm_retrieval_candidates c "
        .. "JOIN lm_retrieval_feedback f ON f.id = c.feedback_id WHERE c.memory_id = ? AND f.scope = ? LIMIT 1",
        mid, scope)
    if rok and seen then return event_type end  -- was retrieved → real mistake
    return "miss"                               -- existed but never surfaced
end

-- Resolve a signal to the memory it refers to: the nearest memory in the scope.
-- Returns (memory_id | nil, score, vec_score): the id only when the score reaches `min_sim`; vec_score is how close
-- the nearest memory is by meaning alone (0 when it has no vector score).
local function resolve_memory(store, scope, text, min_sim)
    local rows = store.search({
        query = text, scope = scope, limit = 3,
        skip_temporal = true, skip_observations = true,
        -- a lookup of which memory a correction is about, not a retrieval anyone acted on: logged, it would
        -- make the memory a "candidate" and so never a miss (reclassify_if_miss asks exactly that)
        skip_feedback = true,
    })
    if not rows or not rows[1] then return nil, 0, 0 end
    local top = rows[1]
    local sim = tonumber(top.vec_score) or tonumber(top.score) or 0
    -- (the third value: how close the memory is by meaning alone — the fused score of a hybrid search is not a similarity)
    local vec = tonumber(top.vec_score) or 0
    if top.id and sim >= min_sim then return top.id, sim, vec end
    return nil, sim, vec
end

-- A standing rule the user stated that no memory holds is a memory of its own: stored as a decision, with the assistant's
-- words before it for context, once (the marker is in the metadata). `covered` is how close the nearest memory is: a
-- rule it already holds is reinforced by the signal, not stored again. → the memory's id | nil
local function capture_rule(store, db, scope, sig, covered, cap_opts)
    if sig.kind ~= "command" or (sig.confidence or 0) < cap_opts.min_confidence then return nil end
    local rule = heuristics.rule_text(sig.text)
    if not rule then return nil end
    if covered >= cap_opts.similarity then return nil end
    local marker = "sensing-rule:" .. util.djb2_hex(scope .. "|" .. rule)
    local eok, hit = pcall(db.value, "SELECT 1 FROM lm_memories WHERE scope = ? AND json_extract(metadata, '$.sensing_marker') = ? LIMIT 1",
        scope, marker)
    if eok and hit then return nil end
    local body = "Standing rule, stated by the user (captured automatically from the conversation):\n" .. rule
    if type(sig.context) == "string" and sig.context ~= "" then
        body = body .. "\n\nThe assistant had just said: " .. util.clip(sig.context, 300)
    end
    local ok, row = pcall(store.write, {
        scope = scope, kind = "decision", title = util.cut_utf8(rule, 100), body = body, importance = 3,
        tags = { "auto-captured", "standing-rule" }, metadata = { source = "sensing", sensing_marker = marker },
        no_miss = true,   -- (luamemo's own write: not a search that missed)
    })
    return ok and type(row) == "table" and row.id or nil
end

-- process(scope, turns, opts) -> { recorded, skipped, signals, captured }
--   turns: array of { role, text } (see heuristics.detect)
--   opts.min_confidence (0.6)  signal confidence floor
--   opts.min_similarity (0.15) memory-resolution floor (precision knob)
--   opts.delta_scale    (1.0)  scales the reinforcement delta (= confidence * scale)
--   opts.capture (false)       also store a standing rule no memory holds (settings: MEMO_SENSE_CAPTURE — the callers pass it)
--   opts.capture_similarity (0.6)  a memory this close (by meaning) already holds the rule
--   (a command signal of at least 0.7 confidence is what capture looks at: CAPTURE_MIN_CONFIDENCE)
--   captured: how many rules were stored; captured_ids: their ids (present when any)
function M.process(scope, turns, opts)
    opts = opts or {}
    local out = { recorded = 0, skipped = 0, signals = 0, captured = 0 }
    if type(scope) ~= "string" or scope == "" then return out end

    local ok_store, store  = pcall(require, "luamemo.store")
    local ok_dig,   digest = pcall(require, "luamemo.digest")
    local ok_db,    db     = pcall(require, "luamemo.db")
    if not (ok_store and ok_dig and ok_db) then return out end

    local min_conf = tonumber(opts.min_confidence) or 0.6
    local min_sim  = tonumber(opts.min_similarity) or 0.15
    local scale    = tonumber(opts.delta_scale)    or 1.0
    local cap_opts = { min_confidence = M.CAPTURE_MIN_CONFIDENCE, similarity = tonumber(opts.capture_similarity) or 0.6 }
    -- (one search per distinct text: a turn with several signals carries the same text in each)
    local nearest = {}
    local function resolve(text)
        nearest[text] = nearest[text] or { resolve_memory(store, scope, text, min_sim) }
        return nearest[text][1], nearest[text][3]
    end

    -- Sensors: heuristics always; generative extract when opts.generative (opt-in).
    local signals = gather_signals(turns, opts)
    out.signals = #signals

    -- Dedup within this call: if two sensors (heuristic + generative) both point at
    -- the same memory with the same event_type, record it once — the reinforcement
    -- log is a shared signal and double-counting would skew proof_count/learners.
    local seen = {}

    for _, sig in ipairs(signals) do
        if (sig.confidence or 0) >= min_conf then
            local mem_id, covered = resolve(sig.text)
            if opts.capture == true then
                local new_id = capture_rule(store, db, scope, sig, covered, cap_opts)
                if new_id then
                    out.captured = out.captured + 1
                    out.captured_ids = out.captured_ids or {}
                    out.captured_ids[#out.captured_ids + 1] = new_id
                end
            end
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
                local eok, hit = pcall(db.value, "SELECT 1 FROM lm_reinforcements WHERE memory_id = ? "
                    .. "AND scope = ? AND substr(note, 1, ?) = ? LIMIT 1",
                    math.floor(mem_id), scope, #marker, marker)
                if eok and hit then existed = true end
                if existed then
                    out.skipped = out.skipped + 1
                else
                    local delta = (sig.confidence or 0.7) * scale
                    -- (what the user typed may hold a credential: scrubbed first, then cut, so a cut cannot leave half of one;
                    -- the note is pushed to an org central under the default share mode)
                    local note  = marker .. " " .. util.cut_utf8(util.redact_secrets(sig.text), 80)
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

M._reclassify_if_miss = reclassify_if_miss   -- (tests)

return M
