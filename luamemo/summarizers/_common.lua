-- luamemo.summarizers._common
--
-- Shared helpers for LLM-based summarizer adapters (ollama, openai, ...).
-- Centralises memory-list formatting so both adapters produce identical
-- output and any future change to the body clip length or line format
-- only needs to happen in one place.

local util = require("luamemo.util")

local M = {}

--- Build an array of formatted memory lines for inclusion in a prompt.
-- Each entry is of the form "[N] Title\nBody (clipped)".
-- The caller is responsible for joining and wrapping in a prompt or
-- chat-messages array as appropriate for their API.
-- @param memories   table   Array of {title, body} memory rows
-- @param body_clip  number  Maximum characters per body (default 1500)
-- @return table             Array of strings, one per memory
function M.build_memory_lines(memories, body_clip)
    body_clip = body_clip or 1500
    local lines = {}
    for i, m in ipairs(memories) do
        lines[#lines + 1] = string.format("[%d] %s\n%s",
            i,
            m.title or "",
            util.clip(m.body or "", body_clip))
    end
    return lines
end

return M
