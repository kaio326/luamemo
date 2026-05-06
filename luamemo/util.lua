-- luamemo.util
-- Shared helpers used across multiple modules.

local M = {}

--- Truncate a string to n characters, appending a UTF-8 horizontal ellipsis
--- (U+2026) if the string was clipped.  Returns "" for non-string input.
function M.clip(s, n)
    if type(s) ~= "string" then return "" end
    if #s <= n then return s end
    return s:sub(1, n) .. "\xe2\x80\xa6"
end

--- Parse a { scores = [{index, score}, ...] } LLM response table into a
--- normalised output array.  Used by the ollama and openai reranker adapters.
--- @param tbl  table  the `scores` array from the decoded LLM response
--- @return table      array of { index = number, score = number }
function M.parse_scores(tbl)
    local out = {}
    for _, s in ipairs(tbl) do
        out[#out + 1] = {
            index = tonumber(s.index),
            score = tonumber(s.score) or 0,
        }
    end
    return out
end

return M
