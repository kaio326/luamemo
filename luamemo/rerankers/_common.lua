-- luamemo.rerankers._common
--
-- Shared helpers for LLM-based reranker adapters (ollama, openai, ...).
-- Centralises the candidate-list formatting so both adapters format
-- identically and any future change (e.g. a different [N] prefix or
-- clip length) only needs to happen in one place.

local util = require("luamemo.util")

local M = {}

--- Build the candidates block used in reranker prompts.
-- Returns a newline-joined string of the form:
--   "[1] Title\nBody (clipped)\n[2] ..."
-- @param hits       table   Array of {title, body} memory rows
-- @param chunk_max  number  Maximum characters per body (default 500)
-- @return string
function M.build_candidates(hits, chunk_max)
    chunk_max = chunk_max or 500
    local lines = {}
    for i, h in ipairs(hits) do
        lines[#lines + 1] = string.format("[%d] %s\n%s",
            i,
            util.clip(h.title or "", 120),
            util.clip(h.body  or "", chunk_max))
    end
    return table.concat(lines, "\n")
end

return M
