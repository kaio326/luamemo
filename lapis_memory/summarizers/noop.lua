-- lapis_memory.summarizers.noop
--
-- Pure-Lua, in-process summarizer that produces a deterministic summary by
-- concatenating the input memories' titles + bodies with a separator. No
-- network, no LLM. Useful for:
--   * dev / CI runs where you don't want to call a real model
--   * smoke-testing the selection + replacement plumbing
--   * environments where summarisation is desired only for compaction (not
--     paraphrasing)
--
-- All summarizer adapters share the same contract:
--   summarize(memories, cfg) -> { title, body, metadata }, err
-- where memories is the array returned by store.select_for_summarization.

local M = {}

function M.summarize(memories, _cfg)
    if type(memories) ~= "table" or #memories == 0 then
        return nil, "noop.summarize: no memories to summarise"
    end

    local titles, bodies = {}, {}
    for _, m in ipairs(memories) do
        if m.title and m.title ~= "" then
            titles[#titles + 1] = m.title
        end
        if m.body and m.body ~= "" then
            bodies[#bodies + 1] = "- " .. m.body
        end
    end

    local title
    if #titles > 0 then
        title = "Summary: " .. table.concat(titles, " | "):sub(1, 200)
    else
        title = "Summary of " .. tostring(#memories) .. " memories"
    end

    local body = table.concat(bodies, "\n")

    return {
        title    = title,
        body     = body,
        metadata = { summarizer = "noop", source_count = #memories },
    }
end

return M
