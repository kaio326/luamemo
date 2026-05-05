-- eval/datasets/convomem
--
-- Pure-Lua loader for ConvoMem-style conversational-memory datasets.
--
-- ConvoMem is a public conversational-memory benchmark family. The
-- field uses several schemas (the original snap-research/locomo, the
-- MemoryBank style, the MSC (Multi-Session Chat) style). Rather than
-- hard-code a single upstream schema, this loader accepts a SUPERSET
-- shape and tolerates missing fields. The exact upstream schema MUST
-- be verified against the file fetched in `eval/sidecars/convomem.md`
-- before a live bench run.
--
-- Expected per-row schema (the loader works against any subset that
-- includes `dialogue_id`, `sessions`, and `qa`):
--
--   {
--     "dialogue_id": "conv-001",
--     "sessions": [
--       {
--         "session_id": "s1",      -- if absent, derived from index
--         "timestamp":  "...",     -- optional
--         "turns": [
--           { "speaker": "A", "text": "..." },
--           { "speaker": "B", "text": "..." }
--         ]
--       },
--       { ... }
--     ],
--     "qa": [
--       {
--         "question":            "...",
--         "answer":              "...",
--         "category":            "factual" | "temporal" | "multi-hop" | ...,
--         "evidence_session_ids": ["s1", "s3"]   -- gold sessions
--       }
--     ]
--   }
--
-- One memory per (dialogue_id, session_id). Gold is the set of
-- `evidence_session_ids` per QA. This shape is intentionally aligned
-- with both LongMemEval (`answer_session_ids`) and LoCoMo
-- (`qa_gold_sessions`) so the bench runner stays symmetric.

local cjson = require("cjson.safe")

local M = {}

--- Read & decode the dataset file.
function M.load(path)
    assert(path, "convomem.load: path required")
    local fh, ferr = io.open(path, "rb")
    if not fh then error("convomem: cannot open " .. path .. ": " .. ferr) end
    local raw = fh:read("*a")
    fh:close()
    local rows, jerr = cjson.decode(raw)
    if not rows then error("convomem: invalid JSON in " .. path .. ": " .. tostring(jerr)) end
    if type(rows) ~= "table" then
        error("convomem: expected JSON array, got " .. type(rows))
    end
    return rows
end

--- Iterate (session_id, turns) pairs over a row's `sessions` array.
-- Falls back to `s<index>` when an explicit `session_id` is missing.
function M.iter_sessions(row)
    local sessions = row.sessions or {}
    local i = 0
    return function()
        i = i + 1
        local s = sessions[i]
        if not s then return nil end
        local sid = s.session_id or ("s" .. tostring(i))
        local turns = s.turns or {}
        return sid, turns
    end
end

--- Flatten a single session into a memory body. "SPEAKER: text" per
--- turn, mirroring longmemeval.session_to_body / locomo.session_to_body
--- so embedded strings are comparable across all three benches.
function M.session_to_body(turns)
    if type(turns) ~= "table" then return "" end
    local lines = {}
    for _, t in ipairs(turns) do
        local who = (t.speaker or "?"):upper()
        lines[#lines + 1] = who .. ": " .. (t.text or "")
    end
    return table.concat(lines, "\n")
end

--- Build the gold session-id set from a QA's `evidence_session_ids`.
function M.qa_gold_sessions(qa)
    local out = {}
    for _, sid in ipairs(qa.evidence_session_ids or {}) do
        if type(sid) == "string" and sid ~= "" then
            out[sid] = true
        end
    end
    return out
end

--- Iterate (qa_index, qa) pairs over a row.
function M.iter_qa(row)
    local qa_list = row.qa or {}
    local i = 0
    return function()
        i = i + 1
        if i > #qa_list then return nil end
        return i, qa_list[i]
    end
end

--- Normalize a category to a string. ConvoMem-family datasets vary in
--- whether they encode categories as numbers or strings; we keep
--- strings as-is and stringify numbers.
function M.category_name(c)
    if c == nil then return "unknown" end
    if type(c) == "string" and c ~= "" then return c end
    return tostring(c)
end

return M
