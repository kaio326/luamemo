-- luamemo.fts
-- Full-text search on SQLite FTS5, ranked the way luamemo ranked it on Postgres.
--
--   fts.match_query(text)  → the FTS5 MATCH expression for a free-text query, or nil
--       Like plainto_tsquery('english', text): words are lowercased, English stopwords
--       dropped, and every remaining word is required. Each word is quoted, so nothing in
--       the query is FTS5 syntax.
--   fts.register(conn)     → adds the ranking function ts_cd(<fts table>) to a connection
--       Postgres's ts_rank_cd (cover density, unweighted lexemes, normalization 0), computed
--       from FTS5's token offsets. The 14.0 spike measured it against Postgres on stored
--       documents and on the retrieval benchmarks (99.2–100 % same rank); FTS5's own bm25
--       lost 0.7 pp R@1 there.
--
-- Postgres caps positions at 16383 and keeps at most 256 positions per word; so does this.

local M = {}

-- PostgreSQL's english.stop (PostgreSQL License, © The PostgreSQL Global Development Group).
local STOP = {}
for w in ([[i me my myself we our ours ourselves you your yours yourself yourselves he him his himself
she her hers herself it its itself they them their theirs themselves what which who whom this that these
those am is are was were be been being have has had having do does did doing a an the and but if or
because as until while of at by for with about against between into through during before after above
below to from up down in out on off over under again further then once here there when where why how all
any both each few more most other some such no nor not only own same so than too very s t can will just
don should now]]):gmatch("%S+") do STOP[w] = true end
M.STOPWORDS = STOP

--- Free text → FTS5 MATCH expression (all words required) | nil when no word is left.
function M.match_query(text)
    if type(text) ~= "string" then return nil end
    local seen, words = {}, {}
    for w in text:lower():gmatch("[%w\128-\255]+") do
        if not STOP[w] and not seen[w] then
            seen[w] = true
            words[#words + 1] = '"' .. w .. '"'
        end
    end
    if #words == 0 then return nil end
    return table.concat(words, " ")
end

local MAXNUMPOS, MAXENTRYPOS = 256, 16383

-- ts_rank_cd method 0 over entries sorted by position. Every lexeme has weight D
-- (0.1) because the indexed text carries no setweight().
local function rank_cd(pos, terms, n, nterms)
    local Wdoc, start = 0.0, 1
    while true do
        local seen, cnt, e, q = {}, 0, nil, 0
        for i = start, n do
            for t in pairs(terms[i]) do if not seen[t] then seen[t] = true; cnt = cnt + 1 end end
            if cnt == nterms then if pos[i] > q then q = pos[i]; e = i end; break end
        end
        if not e then break end
        seen, cnt = {}, 0
        local b, p
        for j = e, start, -1 do
            for t in pairs(terms[j]) do if not seen[t] then seen[t] = true; cnt = cnt + 1 end end
            if cnt == nterms then b = j; p = pos[j]; break end
        end
        local k = e - b
        local nNoise = (q - p) - k
        if nNoise < 0 then nNoise = math.floor(k / 2) end
        Wdoc = Wdoc + 0.1 / (1 + nNoise)
        start = b + 1
    end
    return Wdoc
end
M._rank_cd = rank_cd

local ffi = require("luamemo.native.loader").ffi
local bit = require("bit")
local F4 = ffi.new("float[1]")
local function float4(v) F4[0] = v; return tonumber(F4[0]) end   -- ts_rank_cd returns float4

-- The reference implementation: any input order, any number of query terms.
local function ts_cd_tables(x)
    local nterms = x:phrase_count()
    local by, perterm = {}, {}
    for i = 0, x:inst_count() - 1 do
        local t, _, off = x:inst(i)
        perterm[t] = (perterm[t] or 0) + 1
        if perterm[t] <= MAXNUMPOS then
            local p = math.min(off + 1, MAXENTRYPOS)   -- Postgres positions start at 1
            local s = by[p]
            if not s then s = {}; by[p] = s end
            s[t] = true
        end
    end
    local pos, terms, n = {}, {}, 0
    for p in pairs(by) do n = n + 1; pos[n] = p end
    if n == 0 then return 0 end
    table.sort(pos)
    for i = 1, n do terms[i] = by[pos[i]] end
    return float4(rank_cd(pos, terms, n, nterms))
end
M._ts_cd_tables = ts_cd_tables

-- The same ranking without allocating: FTS5 hands the instances over in position order,
-- so equal positions are adjacent; each position keeps a bitmask of the query terms at
-- it. It runs once per matching row, so this is what the text step costs. Falls back to
-- the reference for more than 30 terms or out-of-order input.
local POS, MASK, PER = {}, {}, {}
local band, bor, lshift = bit.band, bit.bor, bit.lshift
local function ts_cd(x)
    local nterms = x:phrase_count()
    if nterms > 30 then return ts_cd_tables(x) end
    for t = 0, nterms - 1 do PER[t] = 0 end
    local n = 0
    for i = 0, x:inst_count() - 1 do
        local t, _, off = x:inst(i)
        local c = PER[t] + 1
        PER[t] = c
        if c <= MAXNUMPOS then
            local p = off + 1
            if p > MAXENTRYPOS then p = MAXENTRYPOS end
            if n > 0 and POS[n] == p then
                MASK[n] = bor(MASK[n], lshift(1, t))
            elseif n > 0 and p < POS[n] then
                return ts_cd_tables(x)
            else
                n = n + 1; POS[n] = p; MASK[n] = lshift(1, t)
            end
        end
    end
    if n == 0 then return 0 end
    local full = lshift(1, nterms) - 1
    local Wdoc, start = 0.0, 1
    while true do
        local seen, e, q = 0, nil, 0
        for i = start, n do
            seen = bor(seen, MASK[i])
            if band(seen, full) == full then q = POS[i]; e = i; break end
        end
        if not e then break end
        seen = 0
        local b, p
        for j = e, start, -1 do
            seen = bor(seen, MASK[j])
            if band(seen, full) == full then b = j; p = POS[j]; break end
        end
        local k = e - b
        local nNoise = (q - p) - k
        if nNoise < 0 then nNoise = math.floor(k / 2) end
        Wdoc = Wdoc + 0.1 / (1 + nNoise)
        start = b + 1
    end
    return float4(Wdoc)
end
M._ts_cd = ts_cd

-- What a stopword becomes in the indexed text: it keeps its position (a Postgres
-- tsvector leaves a gap there too) and never matches a query word (queries drop
-- stopwords, but the stemmer could map a query word onto one).
local PLACEHOLDER = "zzstopzz"

--- The text indexed for a memory: title + " " + body, stopwords replaced.
-- CHANGING the stopword list or PLACEHOLDER changes the indexed text of existing rows:
-- the contentless FTS table can then no longer delete them — it needs a migration that
-- rebuilds lm_memories_fts.
function M.doc_text(title, body)
    local d = (title or "") .. " " .. (body or "")
    return (d:gsub("[%w\128-\255]+", function(w) if STOP[w:lower()] then return PLACEHOLDER end end))
end

--- Register ts_cd() and lm_fts_doc() (used by the FTS triggers) on a
--- luamemo.native.sqlite connection. → true | nil, err
function M.register(conn)
    local ok, err = conn:create_function("lm_fts_doc", 2, M.doc_text)
    if not ok then return nil, err end
    return conn:create_fts5_function("ts_cd", ts_cd)
end

return M
