-- eval/datasets/longmemeval
--
-- Pure-Lua loader for the LongMemEval dataset. The dataset is a JSON file
-- (one of `longmemeval_oracle.json`, `longmemeval_s.json`,
-- `longmemeval_m.json`) where each row has the shape:
--
--   {
--     "question_id":           "...",
--     "question":              "When did I last visit Paris?",
--     "answer":                "March 2024",
--     "question_type":         "single-session-user" | "multi-session" | ...,
--     "question_date":         "2023/04/10 (Mon) 23:07",
--     "haystack_session_ids":  ["sess_07", "sess_42", "sess_71", ...],
--     "haystack_sessions":     [
--                                 [ { "role": "user", "content": "..." }, ... ],
--                                 [ ... ],
--                                 ...
--                              ],
--     "haystack_dates":        ["2023/01/15 (Sun) 14:22", ...],
--     "answer_session_ids":    ["sess_42", "sess_71"]
--   }
--
-- `haystack_session_ids[i]` and `haystack_sessions[i]` are parallel arrays.
-- `to_memories()` zips them into `(session_id, turns)` pairs.
--
-- License: Apache-2.0 (Lin et al., 2024). Public dataset; download with:
--   curl -sL -o eval/data/longmemeval_oracle.json \
--     https://huggingface.co/datasets/xiaowu0162/longmemeval/resolve/main/longmemeval_oracle

local cjson = require("cjson.safe")

local M = {}

--- Read & decode the dataset file.
-- @param path string
-- @return table  array of rows
function M.load(path)
    assert(path, "longmemeval.load: path required")
    local fh, ferr = io.open(path, "rb")
    if not fh then error("longmemeval: cannot open " .. path .. ": " .. ferr) end
    local raw = fh:read("*a")
    fh:close()
    local rows, jerr = cjson.decode(raw)
    if not rows then error("longmemeval: invalid JSON in " .. path .. ": " .. tostring(jerr)) end
    if type(rows) ~= "table" then
        error("longmemeval: expected JSON array, got " .. type(rows))
    end
    return rows
end

--- Flatten a single session into a memory body. Each session is a chat
--- transcript; we serialise it into a "USER: ... | ASSISTANT: ..." block
--- so it embeds as one document. This matches the way agents would write
--- the session into lapis-memory at run time.
function M.session_to_body(turns)
    if type(turns) ~= "table" then return "" end
    local lines = {}
    for _, t in ipairs(turns) do
        local role = (t.role or "?"):upper()
        lines[#lines + 1] = role .. ": " .. (t.content or "")
    end
    return table.concat(lines, "\n")
end

--- Iterate (session_id, turns) pairs for a single question, zipping the
--- parallel `haystack_session_ids` / `haystack_sessions` arrays.
function M.iter_sessions(q)
    local ids   = q.haystack_session_ids or {}
    local sess  = q.haystack_sessions or {}
    local i     = 0
    return function()
        i = i + 1
        if i > #ids then return nil end
        return ids[i], sess[i]
    end
end

--- Flatten the dataset into a list of session-memory records ready to write
--- via store.write. One memory per (question_id, session_id) pair so each
--- question's haystack stays scoped.
function M.to_memories(rows, opts)
    opts = opts or {}
    local out = {}
    for _, q in ipairs(rows) do
        local scope = "longmemeval:" .. tostring(q.question_id)
        for sid, turns in M.iter_sessions(q) do
            out[#out + 1] = {
                scope    = scope,
                kind     = "session",
                title    = sid,
                body     = M.session_to_body(turns),
                metadata = { session_id = sid, question_id = q.question_id },
            }
        end
    end
    return out
end

return M
