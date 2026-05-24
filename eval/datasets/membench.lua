-- eval/datasets/membench.lua
--
-- Loader for the MemBench dataset (ACL 2025).
-- "MemBench: Towards More Comprehensive Evaluation on the Memory of LLM-based Agents"
-- Source: https://github.com/import-myself/Membench
--
-- Real dataset schema:
--   One JSON file per category in MemData/FirstAgent/.
--   Top-level keys are topics: "roles"/"events" (role-keyed) or
--     "movie"/"food"/"book" (topic-keyed) or "multi_agent".
--   Each item: { tid, message_list, QA }
--     message_list: list of sessions, each session is a list of turns.
--     turn: { sid, user_message, assistant_message, time, place, ... }
--     QA:   { qid, question, answer, target_step_id, choices,
--             ground_truth, time }
--     target_step_id: [[sid_as_int, ...], ...]  -- list of [int, ...] pairs;
--       target_step_id[i][1] (Lua index) is the turn sid that contains the
--       answer.
--
-- M.load(data_dir, opts) reads all category files from data_dir and returns
-- an array of normalised question objects:
--   { id, question, category, topic, turns, target_sids }
-- where:
--   turns        = array of { sid, text }  (one entry per turn)
--   target_sids  = string-keyed set of correct turn sids (e.g. {"119"=true})
--
-- Category files included in the standard 8500-question "movie" run:
--   role-keyed (roles+events, all):  aggregative, comparative, conditional,
--     knowledge_update, noisy, post_processing, simple  → 1000 q each
--   topic-keyed (movie only):        highlevel, highlevel_rec, lowlevel_rec
--     → 500 q each
--   (RecMultiSession excluded)
--   Total: 7×1000 + 3×500 = 8500

local cjson = require("cjson.safe")

-- All category file names (without .json) in MemData/FirstAgent/.
local ALL_CATS = {
    "aggregative", "comparative", "conditional", "highlevel",
    "highlevel_rec", "knowledge_update", "lowlevel_rec",
    "noisy", "post_processing", "simple", "RecMultiSession",
}

-- Role-keyed files use all topics (roles + events) regardless of --topic.
-- Topic-keyed files are filtered to the specified topic (default "movie").
local ROLE_KEYED = {
    aggregative=true, comparative=true, conditional=true,
    knowledge_update=true, noisy=true, post_processing=true, simple=true,
}

local M = {}
M.ALL_CATS = ALL_CATS

--- Load all category files from data_dir.
-- opts.topic  (string)  topic filter for topic-keyed files (default "movie")
-- opts.cats   (table)   list of categories to load (default: all except RecMultiSession)
-- opts.limit  (number)  stop after this many total questions
-- Returns sorted array of question objects.
function M.load(data_dir, opts)
    assert(data_dir, "membench.load: data_dir required")
    opts = opts or {}
    local topic_filter = opts.topic or "movie"
    local cats = opts.cats
    if not cats then
        -- Default: standard 8500-item run (excludes RecMultiSession).
        cats = {}
        for _, c in ipairs(ALL_CATS) do
            if c ~= "RecMultiSession" then cats[#cats+1] = c end
        end
    end
    local limit = opts.limit
    local questions = {}
    local q_id = 0

    for _, cat in ipairs(cats) do
        local path = data_dir .. "/" .. cat .. ".json"
        local fh, ferr = io.open(path, "rb")
        if not fh then
            io.stderr:write("membench: skipping " .. path .. ": " .. tostring(ferr) .. "\n")
        else
            local raw = fh:read("*a")
            fh:close()
            local file_data, jerr = cjson.decode(raw)
            if not file_data then
                io.stderr:write("membench: bad JSON in " .. path .. ": " .. tostring(jerr) .. "\n")
            else
                for topic_key, items in pairs(file_data) do
                    -- For topic-keyed files, only load the requested topic.
                    if not ROLE_KEYED[cat] and topic_key ~= topic_filter then
                        -- skip
                    else
                        for _, item in ipairs(items) do
                            local qa = item.QA
                            if qa and qa.question and qa.question ~= "" then
                            -- Flatten message_list to a list of turns.
                            local turns = {}
                            local ml = item.message_list or {}
                            for _, session in ipairs(ml) do
                                if type(session) == "table" then
                                    for _, turn in ipairs(session) do
                                        -- topic-keyed turns use 'mid' and 'user'/'assistant';
                                        -- role-keyed turns use 'sid' and 'user_message'/'assistant_message'
                                        local sid_str = tostring(turn.sid or turn.mid or "")
                                        local user = turn.user_message or turn.user or ""
                                        local asst = turn.assistant_message or turn.assistant or ""
                                        local text = "User: " .. user
                                            .. "\nAssistant: " .. asst
                                        turns[#turns+1] = { sid = sid_str, text = text }
                                    end
                                end
                            end
                            -- Build target_sids set from target_step_id.
                            -- target_step_id is an array of [sid_int, ...] pairs.
                            local target_sids = {}
                            for _, step in ipairs(qa.target_step_id or {}) do
                                if type(step) == "table" and step[1] ~= nil then
                                    target_sids[tostring(step[1])] = true
                                end
                            end
                            q_id = q_id + 1
                            questions[#questions+1] = {
                                id          = q_id,
                                question    = qa.question,
                                category    = cat,
                                topic       = topic_key,
                                turns       = turns,
                                target_sids = target_sids,
                            }
                            end -- if qa and question
                        end
                    end
                end
            end
        end
    end

    if limit and limit < #questions then
        local trimmed = {}
        for i = 1, limit do trimmed[i] = questions[i] end
        return trimmed
    end
    return questions
end

--- Return the unique categories present in a loaded dataset.
function M.categories(data)
    local seen, cats = {}, {}
    for _, q in ipairs(data) do
        local cat = q.category or "unknown"
        if not seen[cat] then seen[cat] = true; cats[#cats+1] = cat end
    end
    table.sort(cats)
    return cats
end

return M
