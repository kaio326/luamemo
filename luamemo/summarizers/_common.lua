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

--- The instruction a summarizer model is given for a batch of memories — one text for every backend (Ollama,
--- the in-process model), so what differs between them is the model, not the prompt. Asks for JSON
--- `{ "title": …, "body": … }`.
function M.summary_prompt(memories, body_clip)
    local lines = {
        "Summarise the following memories into a single concise note.",
        "Preserve concrete facts (names, IDs, dates, decisions).",
        "Output JSON: { \"title\": \"...\", \"body\": \"...\" }.",
        "",
        "Memories:",
    }
    for _, line in ipairs(M.build_memory_lines(memories, body_clip or 1500)) do
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
end

--- The adapter a config means: its summarizer_adapter, with `auto` resolved — the shared language model
--- (MEMO_GEN_MODEL, luamemo.llm) when one is configured and the runtime loads, else noop. ONE place decides, so
--- the summarizer, consolidate's merge and the digest's synthesis cannot disagree.
function M.adapter_name(cfg)
    local name = cfg and cfg.summarizer_adapter
    if name == nil or name == "" then return "noop" end
    if name == "auto" then
        return require("luamemo.llm").available(cfg) and "gguf" or "noop"
    end
    return name
end

return M
