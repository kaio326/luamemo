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

local cjson = require("luamemo.json")

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
--- the session into luamemo at run time.
--- Strip invalid UTF-8 (embedders reject it, as Postgres did).
--- The corpus contains truncated multi-byte sequences (e.g. 0xEF 0x27).
--- Replace any non-ASCII byte that is not followed by a valid
--- continuation byte with a space.
local function sanitize_utf8(s)
    if type(s) ~= "string" then return s end
    -- Fast path: all ASCII
    if not s:find("[\128-\255]") then return s end
    local out = {}
    local i = 1
    local len = #s
    while i <= len do
        local b = s:byte(i)
        if b < 0x80 then
            -- single-byte ASCII
            out[#out+1] = s:sub(i, i)
            i = i + 1
        elseif b >= 0xF0 then
            -- 4-byte sequence: need 3 continuation bytes
            local b2 = i+1 <= len and s:byte(i+1) or 0
            local b3 = i+2 <= len and s:byte(i+2) or 0
            local b4 = i+3 <= len and s:byte(i+3) or 0
            if b2 >= 0x80 and b2 < 0xC0 and b3 >= 0x80 and b3 < 0xC0
               and b4 >= 0x80 and b4 < 0xC0 then
                out[#out+1] = s:sub(i, i+3)
                i = i + 4
            else
                out[#out+1] = " "
                i = i + 1
            end
        elseif b >= 0xE0 then
            -- 3-byte sequence: need 2 continuation bytes
            local b2 = i+1 <= len and s:byte(i+1) or 0
            local b3 = i+2 <= len and s:byte(i+2) or 0
            if b2 >= 0x80 and b2 < 0xC0 and b3 >= 0x80 and b3 < 0xC0 then
                out[#out+1] = s:sub(i, i+2)
                i = i + 3
            else
                out[#out+1] = " "
                i = i + 1
            end
        elseif b >= 0xC0 then
            -- 2-byte sequence: need 1 continuation byte
            local b2 = i+1 <= len and s:byte(i+1) or 0
            if b2 >= 0x80 and b2 < 0xC0 then
                out[#out+1] = s:sub(i, i+1)
                i = i + 2
            else
                out[#out+1] = " "
                i = i + 1
            end
        else
            -- stray continuation byte
            out[#out+1] = " "
            i = i + 1
        end
    end
    return table.concat(out)
end

function M.session_to_body(turns)
    if type(turns) ~= "table" then return "" end
    local lines = {}
    for _, t in ipairs(turns) do
        local role = (t.role or "?"):upper()
        lines[#lines + 1] = role .. ": " .. sanitize_utf8(t.content or "")
    end
    return table.concat(lines, "\n")
end

--- Iterate (session_id, turns, date_string_or_nil) pairs for a single
--- question, zipping the parallel `haystack_session_ids`,
--- `haystack_sessions`, and `haystack_dates` arrays.
-- Pass `date_string` to `parse_session_date()` to get a Unix epoch.
function M.iter_sessions(q)
    local ids   = q.haystack_session_ids or {}
    local sess  = q.haystack_sessions or {}
    local dates = q.haystack_dates or {}
    local i     = 0
    return function()
        i = i + 1
        if i > #ids then return nil end
        return ids[i], sess[i], dates[i]
    end
end

--- Parse a LongMemEval date string to a Unix epoch (UTC).
-- Accepts format: "2023/05/20 (Sat) 02:21"
-- Returns nil on parse failure.
function M.parse_session_date(s)
    if type(s) ~= "string" then return nil end
    local year, month, day, h, m =
        s:match("(%d%d%d%d)/(%d%d)/(%d%d)%s+%(%a+%)%s+(%d%d):(%d%d)")
    if not year then return nil end
    return os.time({
        year  = tonumber(year),
        month = tonumber(month),
        day   = tonumber(day),
        hour  = tonumber(h),
        min   = tonumber(m),
        sec   = 0,
    })
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
