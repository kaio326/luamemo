-- eval.paraphrase
--
-- Deterministic adversarial paraphrase generator for `recall_bench`.
-- Produces N variants per input string by chaining cheap transforms:
--
--   v1  synonym swap   — replace a small fixed set of common nouns/
--                        verbs/qualifiers with synonyms.
--   v2  reorder flip   — move trailing prepositional phrases to the
--                        front, or swap subject/object phrasing.
--   v3  drop function  — strip a small set of non-content words
--                        ("the", "a", "an", "of", "is", "do", "did",
--                        "have", "you", "I", "my", ...).
--
-- All transforms are deterministic and pure-Lua; no LLM calls.
-- Optional `--ollama-paraphrase` mode (handled in recall_bench.lua) can
-- override these with LLM-generated variants for harder evals.
--
-- Contract:
--   M.variants(text, n) -> { string, string, ..., string }   (length n)

local M = {}

-- Small, intentionally limited synonym table. Keys must be lowercase.
-- Replacements preserve the first letter's case if the source token
-- is capitalized at the start of a sentence.
local SYN = {
    -- nouns
    ["address"]   = "location",
    ["car"]       = "vehicle",
    ["job"]       = "position",
    ["company"]   = "employer",
    ["doctor"]    = "physician",
    ["meeting"]   = "appointment",
    ["movie"]     = "film",
    ["restaurant"] = "diner",
    ["house"]     = "home",
    ["place"]     = "location",
    -- verbs
    ["bought"]    = "purchased",
    ["buy"]       = "purchase",
    ["got"]       = "received",
    ["get"]       = "receive",
    ["told"]      = "informed",
    ["said"]      = "stated",
    ["saw"]       = "witnessed",
    ["went"]      = "traveled",
    ["like"]      = "enjoy",
    ["likes"]     = "enjoys",
    ["want"]      = "desire",
    ["wants"]     = "desires",
    -- qualifiers
    ["big"]       = "large",
    ["small"]     = "tiny",
    ["fast"]      = "quick",
    ["good"]      = "great",
    ["bad"]       = "poor",
    ["happy"]     = "pleased",
}

-- Small drop-list. Function words only — never drop content words.
local DROP = {
    ["the"]  = true, ["a"] = true, ["an"] = true, ["of"] = true,
    ["is"]   = true, ["do"] = true, ["did"] = true,
    ["have"] = true, ["had"] = true, ["has"] = true,
    ["you"]  = true, ["i"] = true,  ["my"] = true,
    ["that"] = true, ["this"] = true,
}

-- Tokenize keeping punctuation as separate tokens. Returns a list of
-- { text=..., is_word=bool } records so we can reassemble cleanly.
local function tokenize(s)
    local out = {}
    for word, sep in s:gmatch("([%w']+)(%s*[%p]?%s*)") do
        out[#out + 1] = { text = word, is_word = true }
        if sep ~= "" then
            out[#out + 1] = { text = sep, is_word = false }
        end
    end
    return out
end

local function detok(toks)
    local buf = {}
    for _, t in ipairs(toks) do buf[#buf + 1] = t.text end
    return table.concat(buf)
end

local function preserve_case(orig, replacement)
    if orig:sub(1, 1):match("%u") then
        return replacement:sub(1, 1):upper() .. replacement:sub(2)
    end
    return replacement
end

-- v1: synonym swap. Replace EVERY matching token (small dict, low
-- collision risk). Always returns a different string than the input
-- if any synonym applied.
local function synonym_swap(text)
    local toks = tokenize(text)
    local changed = false
    for _, t in ipairs(toks) do
        if t.is_word then
            local syn = SYN[t.text:lower()]
            if syn then
                t.text   = preserve_case(t.text, syn)
                changed  = true
            end
        end
    end
    if not changed then
        -- Fallback: append a paraphrastic prefix so we still vary.
        return "Specifically, " .. text
    end
    return detok(toks)
end

-- v2: reorder. If the sentence contains a trailing PP starting with
-- "in", "on", "at", "from", or "with", move it to the front. Else
-- prepend "Regarding " to the noun phrase. Deterministic.
local function reorder(text)
    -- Look for a trailing " <prep> ..." segment before the final punct.
    local body, punct = text:match("^(.-)([%.%?%!]?)$")
    body  = body or text
    punct = punct or ""
    -- Find LAST occurrence of " (in|on|at|from|with) <rest>"
    local prep_re = "%s+([Ii]n%s+[%w%s,'\"]+)$"
              -- start_pos, end_pos, captured_segment
    local s, e, seg
    for _, prep in ipairs({"in", "on", "at", "from", "with"}) do
        local pat = "%s+(" .. prep .. "%s+[%w%s,'\"]+)$"
        local s2, e2, cap = body:find(pat)
        -- prefer the latest (rightmost) match across all preps
        if s2 and (not s or s2 > s) then s, e, seg = s2, e2, cap end
        -- also try capitalized form at sentence start
        local Pat = "%s+(" .. prep:sub(1,1):upper() .. prep:sub(2)
            .. "%s+[%w%s,'\"]+)$"
        local s3, e3, cap3 = body:find(Pat)
        if s3 and (not s or s3 > s) then s, e, seg = s3, e3, cap3 end
    end
    if s then
        local lhs = body:sub(1, s - 1)
        -- Capitalize first letter of moved segment.
        local moved = seg:sub(1, 1):upper() .. seg:sub(2)
        return moved .. ", " .. lhs:sub(1, 1):lower() .. lhs:sub(2) .. punct
    end
    -- Fallback: prepend a topical frame.
    return "Regarding the topic, " .. text
end

-- v3: drop function words. Always preserves at least the first noun
-- phrase and any quoted strings.
local function drop_function_words(text)
    local toks = tokenize(text)
    local out = {}
    local dropped = 0
    for _, t in ipairs(toks) do
        if t.is_word and DROP[t.text:lower()] then
            dropped = dropped + 1
            -- skip this token AND a following whitespace token if any
        else
            out[#out + 1] = t
        end
    end
    if dropped == 0 then
        -- Fallback: add a leading discourse marker so we still vary.
        return "Note: " .. text
    end
    -- Collapse double spaces.
    local s = detok(out):gsub("%s+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local TRANSFORMS = { synonym_swap, reorder, drop_function_words }

-- Generate `n` deterministic variants. Cycles through TRANSFORMS in
-- order; for n > 3 variants 4+ are reapplied to the previous variant
-- (so v4 = synonym_swap(v3), etc).
function M.variants(text, n)
    n = n or 3
    if n <= 0 then return {} end
    local out = {}
    local prev = text
    for i = 1, n do
        local t = TRANSFORMS[((i - 1) % #TRANSFORMS) + 1]
        local v = t(prev)
        if v == prev then v = "Specifically, " .. v end
        out[#out + 1] = v
        prev = v
    end
    return out
end

return M
