-- luamemo.probes — does a memory's own title still find it?
--
-- Every training label is a case where a reinforced memory should win, so the labels cannot say whether a model hurts
-- the queries the ranking already got right. A probe can: it asks for a memory by its title and needs no usage at all.
-- The promotion gate (luamemo.promote) trains on half of them and refuses a model that finds fewer of the other half first
-- than the current ranking; the organization's directives gate (federation.aggregate) probes its directives the same way.

local db       = require("luamemo.db")
local feedback = require("luamemo.feedback")
local learned  = require("luamemo.rerankers.learned")

local M = {}

M.MAX = 200        -- memories probed per scope (each one is a search)
M.MIN_GATE = 5     -- with fewer on the gate side, a result says nothing about harm

--- Rank (1-based) of the example's memory under `weights` (ties rank it first).
function M.rank_of(weights, ex)
    local sp = learned.score_one(weights, ex.features[ex.positive])
    local r = 1
    for j, fv in ipairs(ex.features) do
        if j ~= ex.positive and learned.score_one(weights, fv) > sp then r = r + 1 end
    end
    return r
end

--- How many of `examples` have their memory first under `weights`.
function M.count_first(weights, examples)
    local n = 0
    for _, ex in ipairs(examples) do if M.rank_of(weights, ex) == 1 then n = n + 1 end end
    return n
end

--- One example per row ({ id, title }) whose pool contains it and something to compete with → examples, unreachable (rows
--- search does not bring back: no reranker can fix those). A search that fails raises: "not found" must mean not found.
function M.examples(scope, rows, opts)
    local out, unreachable = {}, 0
    for _, row in ipairs(rows) do
        local hits = {}
        if row.title and row.title ~= "" then
            local err
            hits, err = learned.pool(scope, row.title, opts)
            if not hits then error("probes.examples: " .. tostring(err), 0) end
        end
        local ex = learned.example(hits, row.id)
        if ex and #hits > 1 then
            ex.id, ex.title = tonumber(row.id), row.title
            out[#out + 1] = ex
        elseif not ex then
            unreachable = unreachable + 1
        end
    end
    return out, unreachable
end

--- The memories to probe → rows for training, rows for the gate ({ id, title }; an id decides the side). Titled, visible to a
--- search and never confirmed useful (a confirmed one has a reuse count, which would make its probe easy); the newest M.MAX.
function M.sample(scope)
    local rows, err = db.query("SELECT id, title FROM lm_memories m WHERE scope = ? AND tier >= 1 AND title IS NOT NULL AND title <> '' "
        .. "AND NOT EXISTS (SELECT 1 FROM lm_reinforcements r WHERE r.memory_id = m.id AND r.event_type IN "
        .. feedback.POSITIVE_SQL .. ") ORDER BY id DESC LIMIT ?", scope, M.MAX)
    if not rows then error("probes.sample: " .. tostring(err), 0) end
    local train, gate = {}, {}
    for _, row in ipairs(rows) do
        if tonumber(row.id) % 2 == 0 then train[#train + 1] = row else gate[#gate + 1] = row end
    end
    return train, gate
end

return M
