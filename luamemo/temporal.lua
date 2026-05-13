-- luamemo.temporal
-- Natural-language temporal expression parser + proximity boost helper.
--
-- Public API:
--   temporal.parse(query_str)
--     → { since = epoch, until_ = epoch, center = epoch, half_secs = N } | nil
--
--   temporal.proximity_boost(row_created_at_epoch, window, alpha)
--     → multiplier   (1 + alpha*(prox - 0.5), default alpha = 0.2)
--
-- Zero external dependencies.  Pure Lua 5.1.

local M = {}

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

local function now()
    return os.time()
end

-- Return seconds since epoch for midnight of a date given as a table
-- { year, month, day }.
local function date_epoch(y, m, d)
    return os.time({ year = y, month = m, day = d, hour = 0, min = 0, sec = 0 })
end

-- Build a {since, until_} window centred at `center_epoch` with
-- `half_secs` seconds on each side.
local function sym_window(center_epoch, half_secs)
    return {
        since   = center_epoch - half_secs,
        until_  = center_epoch + half_secs,
        center  = center_epoch,
        half_secs = half_secs,
    }
end

-- Return a window spanning a whole calendar month (y, m).
local function month_window(y, m)
    local since  = date_epoch(y, m, 1)
    -- Next month's first day minus one second.
    local next_m = m == 12 and 1 or m + 1
    local next_y = m == 12 and y + 1 or y
    local until_ = date_epoch(next_y, next_m, 1) - 1
    local half   = math.floor((until_ - since) / 2)
    return {
        since     = since,
        until_    = until_,
        center    = since + half,
        half_secs = half,
    }
end

-- Return a window spanning a whole year y.
local function year_window(y)
    local since  = date_epoch(y, 1, 1)
    local until_ = date_epoch(y + 1, 1, 1) - 1
    local half   = math.floor((until_ - since) / 2)
    return {
        since     = since,
        until_    = until_,
        center    = since + half,
        half_secs = half,
    }
end

-- Month name → number.
local MONTH_NUM = {
    january = 1, february = 2, march = 3, april = 4, may = 5, june = 6,
    july = 7, august = 8, september = 9, october = 10, november = 11,
    december = 12,
    jan = 1, feb = 2, mar = 3, apr = 4, jun = 6, jul = 7, aug = 8,
    sep = 9, oct = 10, nov = 11, dec = 12,
}

-- Season → {start_month, end_month} in the Northern Hemisphere.
local SEASON = {
    spring = { 3,  5 },
    summer = { 6,  8 },
    autumn = { 9, 11 },
    fall   = { 9, 11 },
    winter = { 12, 2 },  -- December–February (wraps year)
}

local function season_window(season_name, reference_year)
    local s = SEASON[season_name:lower()]
    if not s then return nil end
    local sm, em = s[1], s[2]
    local sy = reference_year
    local ey = reference_year
    if sm > em then
        -- winter: Dec ref_year .. Feb (ref_year+1)
        ey = sy + 1
        local since  = date_epoch(sy, sm, 1)
        local until_ = date_epoch(ey, em + 1, 1) - 1
        local half   = math.floor((until_ - since) / 2)
        return { since = since, until_ = until_, center = since + half, half_secs = half }
    end
    local since  = date_epoch(sy, sm, 1)
    local until_ = date_epoch(ey, em + 1, 1) - 1
    local half   = math.floor((until_ - since) / 2)
    return { since = since, until_ = until_, center = since + half, half_secs = half }
end

-- ---------------------------------------------------------------------------
-- Rule table  { pattern, resolver(captures, now_epoch) → window | nil }
-- Rules are tried in order; the first match wins.
-- Pattern matching uses string.lower(query) so case is irrelevant.
-- Captures in patterns use () for plain Lua patterns.
-- ---------------------------------------------------------------------------

local RULES = {}

local function rule(pat, fn)
    RULES[#RULES + 1] = { pat = pat, fn = fn }
end

-- "today"
rule("today", function(_, t)
    local d = os.date("*t", t)
    local since  = date_epoch(d.year, d.month, d.day)
    local until_ = since + 86399
    return { since = since, until_ = until_, center = since + 43200, half_secs = 43200 }
end)

-- "yesterday"
rule("yesterday", function(_, t)
    local d = os.date("*t", t - 86400)
    local since  = date_epoch(d.year, d.month, d.day)
    local until_ = since + 86399
    return { since = since, until_ = until_, center = since + 43200, half_secs = 43200 }
end)

-- "recently" → last 30 days
rule("recently", function(_, t)
    return sym_window(t - 15 * 86400, 15 * 86400)
end)

-- "last N days/weeks/months/years"
rule("last (%d+) days?", function(caps, t)
    local n = tonumber(caps[1])
    if not n then return nil end
    return sym_window(t - n * 86400 / 2, math.floor(n * 86400 / 2))
end)
rule("last (%d+) weeks?", function(caps, t)
    local n = tonumber(caps[1])
    if not n then return nil end
    return sym_window(t - n * 7 * 86400 / 2, math.floor(n * 7 * 86400 / 2))
end)
rule("last (%d+) months?", function(caps, t)
    local n = tonumber(caps[1])
    if not n then return nil end
    local half = math.floor(n * 30.44 * 86400 / 2)
    return sym_window(t - half, half)
end)
rule("last (%d+) years?", function(caps, t)
    local n = tonumber(caps[1])
    if not n then return nil end
    local half = math.floor(n * 365.25 * 86400 / 2)
    return sym_window(t - half, half)
end)

-- "last week"  → the most-recent full Mon–Sun week
rule("last week", function(_, t)
    return sym_window(t - 10.5 * 86400, math.floor(3.5 * 86400))
end)

-- "last month" → the most-recent calendar month
rule("last month", function(_, t)
    local d  = os.date("*t", t)
    local pm = d.month - 1
    local py = d.year
    if pm < 1 then pm = 12; py = py - 1 end
    return month_window(py, pm)
end)

-- "last year"  → the previous calendar year
rule("last year", function(_, t)
    local d = os.date("*t", t)
    return year_window(d.year - 1)
end)

-- "this week"
rule("this week", function(_, t)
    return sym_window(t - 3.5 * 86400, math.floor(3.5 * 86400))
end)

-- "this month"
rule("this month", function(_, t)
    local d = os.date("*t", t)
    return month_window(d.year, d.month)
end)

-- "this year"
rule("this year", function(_, t)
    local d = os.date("*t", t)
    return year_window(d.year)
end)

-- "past week / past month / past year"
rule("past week", function(_, t)
    return sym_window(t - 3.5 * 86400, math.floor(3.5 * 86400))
end)
rule("past month", function(_, t)
    local d = os.date("*t", t)
    local pm = d.month - 1
    local py = d.year
    if pm < 1 then pm = 12; py = py - 1 end
    return month_window(py, pm)
end)
rule("past year", function(_, t)
    local d = os.date("*t", t)
    return year_window(d.year - 1)
end)

-- "last spring / summer / autumn / fall / winter"
rule("last (spring)", function(caps, t)
    local d = os.date("*t", t)
    return season_window(caps[1], d.year - 1)
end)
rule("last (summer)", function(caps, t)
    local d = os.date("*t", t)
    return season_window(caps[1], d.year - 1)
end)
rule("last (autumn)", function(caps, t)
    local d = os.date("*t", t)
    return season_window(caps[1], d.year - 1)
end)
rule("last (fall)", function(caps, t)
    local d = os.date("*t", t)
    return season_window(caps[1], d.year - 1)
end)
rule("last (winter)", function(caps, t)
    local d = os.date("*t", t)
    return season_window(caps[1], d.year - 1)
end)

-- "in <month name>" → most recent occurrence of that month
rule("in (january)", function(caps, t)
    local mn = MONTH_NUM[caps[1]]
    if not mn then return nil end
    local d = os.date("*t", t)
    local y = d.year
    if d.month <= mn then y = y - 1 end
    return month_window(y, mn)
end)
for _, mname in ipairs({
    "february","march","april","may","june","july",
    "august","september","october","november","december",
    "jan","feb","mar","apr","jun","jul","aug","sep","oct","nov","dec",
}) do
    rule("in (" .. mname .. ")", function(caps, t)
        local mn = MONTH_NUM[caps[1]]
        if not mn then return nil end
        local d = os.date("*t", t)
        local y = d.year
        if d.month <= mn then y = y - 1 end
        return month_window(y, mn)
    end)
end

-- "in <4-digit year>"
rule("in (%d%d%d%d)", function(caps, t)
    local y = tonumber(caps[1])
    if not y or y < 1900 or y > 2100 then return nil end
    return year_window(y)
end)

-- "<4-digit year>" bare (lower priority: only matches if nothing else does)
rule("^(%d%d%d%d)$", function(caps, t)
    local y = tonumber(caps[1])
    if not y or y < 1900 or y > 2100 then return nil end
    return year_window(y)
end)

-- ---------------------------------------------------------------------------
-- parse(query_str) → window | nil
-- ---------------------------------------------------------------------------
function M.parse(query)
    if type(query) ~= "string" or query == "" then return nil end
    local q = query:lower()
    local t = now()
    for _, r in ipairs(RULES) do
        -- Collect captures from the pattern.
        local caps = { q:match(r.pat) }
        -- caps[1] is non-nil when there is at least one capture that matched.
        -- For capture-less patterns, fall back to find().
        local matched = (caps[1] ~= nil) or (q:find(r.pat) ~= nil)
        if matched then
            if caps[1] == nil then caps = {} end  -- pattern had no captures
            local w = r.fn(caps, t)
            if w then return w end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- proximity_boost(row_created_at_epoch, window, alpha)
-- Returns a multiplier in the range [1 - alpha/2, 1 + alpha/2].
-- When the row is exactly at the window centre → prox=1.0 → boost = 1 + alpha*0.5
-- When the row is at or beyond the window edge → prox=0.0 → boost = 1 - alpha*0.5
-- Default alpha = 0.2  → range [0.90, 1.10].
-- ---------------------------------------------------------------------------
function M.proximity_boost(row_epoch, window, alpha)
    if not window or not row_epoch then return 1.0 end
    alpha = alpha or 0.2
    local half = window.half_secs
    if half <= 0 then return 1.0 end
    local dist = math.abs(row_epoch - window.center)
    local prox = math.max(0.0, 1.0 - dist / half)
    return 1.0 + alpha * (prox - 0.5)
end

-- ---------------------------------------------------------------------------
-- rrf_merge(ranked_lists, k)
-- Reciprocal Rank Fusion over a table of ranked lists.
-- Each list is an array of rows that respond to row.id.
-- Returns a merged list sorted by descending RRF score.
-- k defaults to 60 (standard RRF constant).
-- ---------------------------------------------------------------------------
function M.rrf_merge(ranked_lists, k)
    k = k or 60
    local scores = {}   -- [id] = accumulated RRF score
    local rows_by_id = {}  -- [id] = row table (first occurrence wins)
    for _, list in ipairs(ranked_lists) do
        for rank, row in ipairs(list) do
            local id = tostring(row.id)
            scores[id]   = (scores[id] or 0) + 1.0 / (k + rank)
            if not rows_by_id[id] then rows_by_id[id] = row end
        end
    end
    -- Build sorted result.
    local result = {}
    for id, score in pairs(scores) do
        local row = rows_by_id[id]
        -- Attach rrf_score; preserve original score for debugging.
        local merged = {}
        for key, val in pairs(row) do merged[key] = val end
        merged.rrf_score = score
        merged.score     = score  -- overwrite score with RRF value
        result[#result + 1] = merged
    end
    table.sort(result, function(a, b) return (a.rrf_score or 0) > (b.rrf_score or 0) end)
    return result
end

return M
