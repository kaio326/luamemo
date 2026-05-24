-- luamemo.patterns
-- Zero-cost preference / habit / sentiment extraction at write time.
--
-- Scans each sentence of a memory body for first-person preference signals
-- ("I usually prefer X", "I always avoid Y", etc.) and returns a list of
-- synthetic companion sentences that embed better for preference-style queries.
--
-- Called from store.write() when cfg.patterns_enabled ~= false.  Companion
-- memories are stored with metadata.is_synthetic = true so they are excluded
-- from recursive extraction and can be filtered by callers if needed.
--
-- Zero external dependencies — pure Lua 5.1.

local M = {}

-- Shared prefix for all synthetic companion sentences.
local _P = "User has mentioned: "

-- Max body length (bytes) that will be scanned.  Bodies larger than this are
-- skipped entirely to bound CPU cost on large writes.  Configurable via
-- M.setup({ patterns_max_body_chars = N }).
local _max_body_chars = 5000

-- Shared regex for trimming trailing punctuation and whitespace from captures.
local _TRIM_CAP = "^%s*(.-)%s*[%.%!%?]?%s*$"

-- Named builder functions shared by pattern entries that produce identical output.
-- Defined once here rather than as 11 separate anonymous closures in the table.
local function _pref(x)     return _P .. "preference for " .. x end
local function _likes(x)    return _P .. "likes " .. x end
local function _dislikes(x) return _P .. "dislikes " .. x end

-- ---------------------------------------------------------------------------
-- Pattern table
-- Each entry: { pattern, builder }
--   pattern  — Lua string.find pattern, applied to a lowercased sentence
--   builder  — function(...captures...) -> string | nil
--
-- Patterns are tried in order; the first match per sentence wins.
-- Lua 5.1 has no non-capturing groups (?:...) — use .* / .- alternatives or
-- split into two patterns.  Single-char wildcards (.) handle apostrophes and
-- typographic quotes in contractions (don't, i'm, etc.).
-- ---------------------------------------------------------------------------
local PATTERNS = {
    -- "i switched from X to Y" — most specific first
    {
        "i%s+switched%s+from%s+(.-)%s+to%s+(.+)",
        function(a, b) return _P .. "switched from " .. a .. " to " .. b end,
    },
    -- "i prefer X over Y"
    {
        "i%s+prefer%s+(.-)%s+over%s+(.+)",
        function(a, b) return _P .. "prefers " .. a .. " over " .. b end,
    },
    -- "i usually prefer X" / "i prefer X" / "my preference is X"
    { "i%s+usually%s+prefer%s+(.+)",  _pref },
    { "i%s+prefer%s+(.+)",            _pref },
    { "my%s+preference%s+is%s+(.+)",  _pref },
    -- "i always X"
    {
        "i%s+always%s+(.+)",
        function(x) return _P .. "always " .. x end,
    },
    -- "i never X"
    {
        "i%s+never%s+(.+)",
        function(x) return _P .. "never " .. x end,
    },
    -- "i tend to X"
    {
        "i%s+tend%s+to%s+(.+)",
        function(x) return _P .. "tends to " .. x end,
    },
    -- "i (really) love/like X"
    { "i%s+really%s+love%s+(.+)", _likes },
    { "i%s+love%s+(.+)",          _likes },
    { "i%s+really%s+like%s+(.+)", _likes },
    { "i%s+like%s+(.+)",          _likes },
    -- "i (really) hate / don't like / dislike X"
    { "i%s+really%s+hate%s+(.+)", _dislikes },
    { "i%s+hate%s+(.+)",          _dislikes },
    { "i%s+don.t%s+like%s+(.+)",  _dislikes },  -- . matches apostrophe / smart quote
    { "i%s+dislike%s+(.+)",       _dislikes },
    -- "i avoid X"
    {
        "i%s+avoid%s+(.+)",
        function(x) return _P .. "avoids " .. x end,
    },
    -- "i find X adjective" — capture thing + trailing single word (adjective)
    {
        "i%s+find%s+(.-)%s+(%a+)$",
        function(t, adj) return _P .. "finds " .. t .. " " .. adj end,
    },
    -- "i'm comfortable with X"  (. matches apostrophe)
    {
        "i.m%s+comfortable%s+with%s+(.+)",
        function(x) return _P .. "comfortable with " .. x end,
    },
    -- "i still remember X"
    {
        "i%s+still%s+remember%s+(.+)",
        function(x) return _P .. "nostalgic about " .. x end,
    },
    -- "i used to X"
    {
        "i%s+used%s+to%s+(.+)",
        function(x) return _P .. "used to " .. x end,
    },
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Split body into sentences on ". ", "! ", "? " or end-of-string.
-- Returns a list of trimmed, lowercased sentences.
local function split_sentences(body)
    local lower = body:lower()
    local sentences = {}
    -- Walk through the string splitting on sentence-ending punctuation.
    local start = 1
    local len   = #lower
    while start <= len do
        -- Find next sentence boundary: [.!?] followed by %s or end
        local e = lower:find("[%.%!%?]%s", start)
        local seg
        if e then
            seg   = lower:sub(start, e)
            start = e + 2
        else
            seg   = lower:sub(start)
            start = len + 1
        end
        -- Trim leading/trailing whitespace
        seg = seg:match("^%s*(.-)%s*$")
        if seg and seg ~= "" then
            sentences[#sentences + 1] = seg
        end
    end
    return sentences
end

-- Try a single pattern entry against a sentence.
-- Returns the synthetic sentence string on match, nil otherwise.
local function try_pattern(sentence, entry)
    local pat, builder = entry[1], entry[2]
    local s, e, c1, c2, c3 = sentence:find(pat)
    if not s then return nil end
    -- Trim captures
    if c1 then c1 = c1:match(_TRIM_CAP) or c1 end
    if c2 then c2 = c2:match(_TRIM_CAP) or c2 end
    if c3 then c3 = c3:match(_TRIM_CAP) or c3 end
    local ok, result = pcall(builder, c1, c2, c3)
    if not ok or not result or result == "" then return nil end
    return result
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Apply runtime configuration.  Called automatically by luamemo.setup().
-- @param cfg table  luamemo config table
function M.configure(cfg)
    _max_body_chars = cfg.patterns_max_body_chars or 5000
end

--- Extract synthetic preference/habit sentences from a memory body.
-- Returns a list (possibly empty) of short synthetic strings ready to write
-- as companion memories.  Callers MUST guard against re-running on synthetic
-- bodies: check metadata.is_synthetic before calling.
-- @param body string
-- @return table  list of strings (may be empty)
function M.extract(body)
    if type(body) ~= "string" or body == "" then return {} end
    if #body > _max_body_chars then return {} end
    local results = {}
    local seen    = {}   -- deduplicate identical synthetic sentences in one body
    local sentences = split_sentences(body)
    for _, sentence in ipairs(sentences) do
        -- Fast pre-filter: all patterns require "i " / "i'" / "my " — skip
        -- sentences lacking these tokens to avoid 22 needless find() calls.
        if sentence:find("i[%s']") or sentence:find("my%s") then
            for _, entry in ipairs(PATTERNS) do
                local syn = try_pattern(sentence, entry)
                if syn and not seen[syn] then
                    seen[syn]            = true
                    results[#results+1] = syn
                    break  -- first match wins per sentence
                end
            end
        end
    end
    return results
end

return M
