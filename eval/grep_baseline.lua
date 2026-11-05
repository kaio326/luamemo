-- eval/grep_baseline.lua — what an agent without the code map does: grep the question's words.
--
-- The files that hold the most of the question's words come first (then the most hits), and
-- each is read whole until the one that answers it. Shared by the codemap benchmark (luamemo's
-- own modules) and the corpus' task-cost suite (the projects the corpus was built from).
--
--   words_of(question) → { word, … }                         lower-case, 3+ characters, no stop words
--   rank(files, question, gold, limit) → rank, bytes | nil   files = { { path, text (lower-case) }, … },
--                                                            gold = { [path] = true }

local M = {}

local STOP = {}
for w in ("the a an and or of to in on for is are be by with what which where when how does do from "
    .. "into its it this that as at an one ones their there whether may can"):gmatch("%S+") do STOP[w] = true end

function M.words_of(q)
    local out, seen = {}, {}
    for w in q:lower():gmatch("[%w_]+") do
        if #w >= 3 and not STOP[w] and not seen[w] then seen[w] = true; out[#out + 1] = w end
    end
    return out
end

--- → the gold file's position among the files grep would open, and the bytes read to get there;
--- nil when it is not among the first `limit` files.
function M.rank(files, q, gold, limit)
    local words = M.words_of(q)
    local scored = {}
    for _, f in ipairs(files) do
        local distinct, hits = 0, 0
        for _, w in ipairs(words) do
            local n = select(2, f.text:gsub(w:gsub("%p", "%%%0"), ""))
            if n > 0 then distinct = distinct + 1; hits = hits + n end
        end
        if distinct > 0 then scored[#scored + 1] = { f = f, d = distinct, h = hits } end
    end
    table.sort(scored, function(a, b)
        if a.d ~= b.d then return a.d > b.d end
        if a.h ~= b.h then return a.h > b.h end
        return a.f.path < b.f.path
    end)
    local bytes = 0
    for i, s in ipairs(scored) do
        if i > limit then break end
        bytes = bytes + #s.f.text
        if gold[s.f.path] then return i, bytes end
    end
    return nil
end

return M
