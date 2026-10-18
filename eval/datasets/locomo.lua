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

local cjson = require("luamemo.json")

local M = {}

local MONTH_NAMES = {
    january=1, february=2, march=3, april=4, may=5, june=6,
    july=7, august=8, september=9, october=10, november=11, december=12,
}

--- Parse a LoCoMo session date string to a Unix epoch (UTC).
-- Accepts format: "1:56 pm on 8 May, 2023" (case-insensitive month).
-- Returns nil on parse failure.
function M.parse_session_date(s)
    if type(s) ~= "string" then return nil end
    local h, m, ampm, day, mon_name, year =
        s:match("(%d+):(%d+)%s+([aApP][mM])%s+on%s+(%d+)%s+(%a+),?%s+(%d+)")
    if not h then return nil end
    h = tonumber(h); m = tonumber(m); day = tonumber(day); year = tonumber(year)
    local month = MONTH_NAMES[mon_name:lower()]
    if not month then return nil end
    local lo = ampm:lower()
    if lo == "pm" and h ~= 12 then h = h + 12
    elseif lo == "am" and h == 12 then h = 0 end
    return os.time({ year=year, month=month, day=day, hour=h, min=m, sec=0 })
end

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
-- Yields `("session_<n>", turns_array, date_string_or_nil)` for every
-- key matching `session_<n>`, in numeric order. Skips `*_date_time`
-- sibling keys. The `date_string` value is the raw "1:56 pm on 8 May,
-- 2023" string from the dataset; pass it to `parse_session_date()` to
-- convert to a Unix epoch for timestamp-replay writes.
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
        local n        = nums[i]
        local sid      = "session_" .. tostring(n)
        local date_str = conv["session_" .. tostring(n) .. "_date_time"]
        return sid, conv[sid], date_str
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
