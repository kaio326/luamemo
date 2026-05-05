-- eval/datasets/locomo
--
-- Pure-Lua loader for the LoCoMo dataset (Maharana et al., 2024 —
-- "Evaluating Very Long-Term Conversational Memory of LLM Agents").
--
-- Public download:
--   curl -sL -o eval/data/locomo.json \
--     https://huggingface.co/datasets/snap-research/locomo/resolve/main/locomo10.json
--
-- Expected per-row schema (verified against the public release as of
-- 2026-05; if the upstream schema has changed, adjust this loader and
-- re-run the smoke test before a live bench run):
--
--   {
--     "sample_id": "conv-12",
--     "conversation": {
--       "session_1":           [ { "speaker": "Caroline", "text": "...", "dia_id": "D1:1" }, ... ],
--       "session_1_date_time": "1:56 pm on 8 May, 2023",
--       "session_2":           [ ... ],
--       "session_2_date_time": "...",
--       ...
--     },
--     "qa": [
--       {
--         "question": "When did Caroline last visit Paris?",
--         "answer":   "March 2024",
--         "category": 1,                  -- 1=single-hop, 2=multi-hop,
--                                         -- 3=temporal, 4=open-domain, 5=adversarial
--         "evidence": ["D2:3", "D5:7"]    -- dia_ids; first integer = session number
--       }
--     ]
--   }
--
-- One memory per (sample_id, session_id) pair. Gold evidence is per-turn
-- (`dia_id = "D<sess_no>:<turn_no>"`); we map each evidence dia_id to its
-- session number, so gold is the *set of session IDs* containing the
-- answer. This matches the way LongMemEval's `answer_session_ids`
-- already work, so the bench runner can stay symmetric.
--
-- License: MIT (snap-research/locomo). Public dataset.

local cjson = require("cjson.safe")

local M = {}

--- Read & decode the dataset file.
function M.load(path)
    assert(path, "locomo.load: path required")
    local fh, ferr = io.open(path, "rb")
    if not fh then error("locomo: cannot open " .. path .. ": " .. ferr) end
    local raw = fh:read("*a")
    fh:close()
    local rows, jerr = cjson.decode(raw)
    if not rows then error("locomo: invalid JSON in " .. path .. ": " .. tostring(jerr)) end
    if type(rows) ~= "table" then
        error("locomo: expected JSON array, got " .. type(rows))
    end
    return rows
end

--- Parse a dia_id like "D2:3" -> session number 2.
-- Returns nil on malformed input (caller should skip).
function M.session_no_from_dia_id(dia_id)
    if type(dia_id) ~= "string" then return nil end
    local n = dia_id:match("^[Dd](%d+):")
    return n and tonumber(n) or nil
end

--- Iterate session_id, turns over a row's `conversation` table.
-- Yields `("session_<n>", turns_array)` for every key matching `session_<n>`,
-- in numeric order. Skips `*_date_time` sibling keys.
function M.iter_sessions(row)
    local conv = row.conversation or {}
    local nums = {}
    for k, _ in pairs(conv) do
        local n = k:match("^session_(%d+)$")
        if n then nums[#nums + 1] = tonumber(n) end
    end
    table.sort(nums)
    local i = 0
    return function()
        i = i + 1
        if i > #nums then return nil end
        local n   = nums[i]
        local sid = "session_" .. tostring(n)
        return sid, conv[sid]
    end
end

--- Flatten a single session into a memory body. One line per turn,
--- "SPEAKER: text" — same shape as longmemeval.session_to_body so the
--- two benches embed comparable strings.
function M.session_to_body(turns)
    if type(turns) ~= "table" then return "" end
    local lines = {}
    for _, t in ipairs(turns) do
        local who = (t.speaker or "?"):upper()
        lines[#lines + 1] = who .. ": " .. (t.text or "")
    end
    return table.concat(lines, "\n")
end

--- Build the gold session-id set from a QA's `evidence` array.
-- Evidence dia_ids like "D2:3" -> "session_2".
function M.qa_gold_sessions(qa)
    local out = {}
    for _, dia in ipairs(qa.evidence or {}) do
        local n = M.session_no_from_dia_id(dia)
        if n then out["session_" .. tostring(n)] = true end
    end
    return out
end

--- Iterate (qa_index, qa) pairs over a row. Skips entries missing a
--- question or evidence array (adversarial unanswerable items still
--- have evidence pointing at the contradiction).
function M.iter_qa(row)
    local qa_list = row.qa or {}
    local i = 0
    return function()
        i = i + 1
        if i > #qa_list then return nil end
        return i, qa_list[i]
    end
end

--- Map LoCoMo numeric category -> human-readable string. Used in
--- `by_type` reporting so the writeup stays comparable across datasets.
local CATEGORIES = {
    [1] = "single-hop",
    [2] = "multi-hop",
    [3] = "temporal",
    [4] = "open-domain",
    [5] = "adversarial",
}
function M.category_name(c)
    if type(c) == "string" then return c end
    return CATEGORIES[tonumber(c) or -1] or "unknown"
end

return M
