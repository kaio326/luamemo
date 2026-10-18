-- luamemo.kg
--
-- Lightweight knowledge-graph layer. Stores (subject, predicate, object)
-- triples with bitemporal validity windows. Used for facts whose truth
-- value changes over time and where the *currently valid* answer must
-- override older ones — a query pattern vector search handles poorly.
--
-- Design constraints:
--   * Plain SQL via `luamemo.db`, parameters bound. No ORM. Same convention as
--     `store.lua`.
--   * Scopes mirror `luamemo.scope` semantics — you assert and
--     query under a scope, and queries never leak across scopes.
--   * `assert_fact` does *not* automatically invalidate a previous
--     value. The caller decides whether to call `invalidate` first
--     (typical for entity-state updates) or to leave both rows valid
--     (typical for append-only audit logs). Two helper convenience
--     methods cover both shapes:
--       - `assert_fact{... supersede = true}`  — invalidate then assert
--       - `query{at = timestamp}`              — point-in-time read
--
-- Timestamps (valid_from, valid_until, at) are given as Unix epoch seconds or
-- ISO 8601 text; rows come back with them as text ("2026-10-08 03:03:14.831072+00").
--
-- Public API (all functions return value, err on failure):
--
--   M.assert_fact{ scope, subject, predicate, object,
--                  valid_from = now(), source_memory_id = nil,
--                  supersede = false }
--     -> row, nil    on success
--     -> nil, "..."  on validation/SQL error
--
--   M.query{ scope, subject = nil, predicate = nil, object = nil,
--            at = nil,             -- point-in-time; nil = "currently valid"
--            include_invalidated = false,
--            limit = 100 }
--     -> { row, row, ... }, nil
--
--   M.invalidate{ scope, subject, predicate, object = nil,
--                 at = now() }
--     -> n_rows_invalidated, nil
--
--   M.timeline{ scope, subject, predicate }
--     -> { row, row, ... } ordered by valid_from ASC
--
--   M.for_query(scopes | scope | nil (every scope but codeindex:*), query, limit = 3)
--     -> { { subject, predicate, value, since, previous = { value, until } | nil }, … }
--     The currently valid facts whose subject / predicate words appear in a search
--     query — memory_search and `memo search` add them to their results (KG spike 2,
--     2026-10-10: agents rarely ask a separate fact tool, but read facts that come with
--     the search; with facts recorded a small model answered 94 % instead of 60 %).
--
-- All public functions accept ONE table argument so call-sites stay
-- self-documenting. The argument table is never mutated.

local util  = require("luamemo.util")
local db    = require("luamemo.db")
-- Federation: a dev's org: scope is the org's read-only replica — no local facts there.
local policy = require("luamemo.federation.policy")

local M = {}

local TBL = "lm_kg_facts"

-- ---------------------------------------------------------------------------
-- Validation helpers
-- ---------------------------------------------------------------------------
local require_str = util.require_str

-- A timestamp argument → µs.
-- Accept: nil (now), number or digits (unix epoch seconds — `memo kg --at 1735689600`),
-- string (ISO 8601), or `false` (explicit "leave it null" → returns false).
local function ts_us(v)
    if v == nil  then return util.now_us() end
    if v == false then return false end
    if type(v) == "string" and v:match("^%s*%d+%.?%d*%s*$") then v = tonumber(v) end
    if type(v) == "number" or type(v) == "string" then
        return util.iso_to_us(v)
    end
    return nil, "unsupported type " .. type(v)
end

local function row_to_lua(r)
    if not r then return nil end
    return util.iso_fields(r, { "valid_from", "valid_until", "created_at" })
end

local RETURN_COLS = "id, scope, subject, predicate, object, "
                 .. "valid_from, valid_until, source_memory_id, created_at"

-- ---------------------------------------------------------------------------
-- assert_fact
-- ---------------------------------------------------------------------------
function M.assert_fact(args)
    args = args or {}
    local scope, err = require_str(args.scope, "scope")
    if not scope then return nil, err end
    local subject; subject, err = require_str(args.subject, "subject")
    if not subject then return nil, err end
    local predicate; predicate, err = require_str(args.predicate, "predicate")
    if not predicate then return nil, err end
    local object; object, err = require_str(args.object, "object")
    if not object then return nil, err end
    local ok_p, perr = policy.check_insert(scope)
    if not ok_p then return nil, "kg.assert_fact: " .. perr end

    local vf, verr = ts_us(args.valid_from)
    if not vf then return nil, "valid_from: " .. tostring(verr or "must be a timestamp") end

    local src = nil
    if args.source_memory_id then
        local id_n = tonumber(args.source_memory_id)
        if not id_n then return nil, "source_memory_id must be numeric" end
        src = math.floor(id_n)
    end

    local row
    local ok, terr = db.transaction(function(h)
        -- Optional supersede: invalidate any currently-valid (subject,
        -- predicate) row in this scope BEFORE inserting the new fact.
        -- Validity-window invariant means we set valid_until = valid_from
        -- of the new row.
        if args.supersede then
            local n, uerr = h.run("UPDATE " .. TBL .. " SET valid_until = ? WHERE scope = ? AND subject = ? "
                .. "AND predicate = ? AND valid_until IS NULL", vf, scope, subject, predicate)
            if not n then error("supersede failed: " .. tostring(uerr), 0) end
        end
        local r, ierr = h.first("INSERT INTO " .. TBL .. " (scope, subject, predicate, object, valid_from, "
            .. "source_memory_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING " .. RETURN_COLS,
            scope, subject, predicate, object, vf, src, util.now_us())
        if not r then error(ierr or "insert returned no row", 0) end
        row = r
    end)
    if not ok then return nil, "kg.assert_fact: " .. tostring(terr) end
    return row_to_lua(row)
end

-- ---------------------------------------------------------------------------
-- query
-- ---------------------------------------------------------------------------
function M.query(args)
    args = args or {}
    local scope, err = require_str(args.scope, "scope")
    if not scope then return nil, err end

    local where, params = { "scope = ?" }, { scope }
    for _, k in ipairs({ "subject", "predicate", "object" }) do
        if args[k] then
            if type(args[k]) ~= "string" then return nil, k .. " must be a string" end
            where[#where + 1] = k .. " = ?"
            params[#params + 1] = args[k]
        end
    end

    -- Validity filter:
    --   default                         -> "currently valid" (valid_until IS NULL)
    --   args.at = <timestamp>           -> point-in-time
    --   args.include_invalidated = true -> no validity filter
    if not args.include_invalidated then
        if args.at ~= nil then
            local at = args.at ~= false and ts_us(args.at) or nil
            if not at then return nil, "`at` must be a timestamp" end
            where[#where + 1] = "valid_from <= ?"
            where[#where + 1] = "(valid_until IS NULL OR valid_until > ?)"
            params[#params + 1] = at
            params[#params + 1] = at
        else
            where[#where + 1] = "valid_until IS NULL"
        end
    end

    local limit = tonumber(args.limit) or 100
    if limit < 1 then limit = 1 end
    if limit > 1000 then limit = 1000 end
    params[#params + 1] = math.floor(limit)

    local rows, qerr = db.query("SELECT " .. RETURN_COLS .. " FROM " .. TBL .. " WHERE "
        .. table.concat(where, " AND ") .. " ORDER BY valid_from DESC, id DESC LIMIT ?",
        unpack(params, 1, #params))
    if not rows then return nil, "kg.query: " .. tostring(qerr) end
    local out = {}
    for i, r in ipairs(rows) do out[i] = row_to_lua(r) end
    return out
end

-- ---------------------------------------------------------------------------
-- invalidate
-- ---------------------------------------------------------------------------
function M.invalidate(args)
    args = args or {}
    local scope, err = require_str(args.scope, "scope")
    if not scope then return nil, err end
    local subject; subject, err = require_str(args.subject, "subject")
    if not subject then return nil, err end
    local predicate; predicate, err = require_str(args.predicate, "predicate")
    if not predicate then return nil, err end
    local ok_p, perr = policy.check_mutation(scope)
    if not ok_p then return nil, "kg.invalidate: " .. perr end

    local at, aerr = ts_us(args.at)   -- nil -> now
    if at == nil then return nil, "`at`: " .. tostring(aerr) end
    if at == false then return nil, "`at` must be a timestamp" end

    local where = { "scope = ?", "subject = ?", "predicate = ?", "valid_until IS NULL" }
    local params = { at, scope, subject, predicate }
    if args.object then
        if type(args.object) ~= "string" then
            return nil, "object must be a string"
        end
        where[#where + 1] = "object = ?"
        params[#params + 1] = args.object
    end

    local n, qerr = db.run("UPDATE " .. TBL .. " SET valid_until = ? WHERE " .. table.concat(where, " AND "),
        unpack(params, 1, #params))
    if not n then return nil, "kg.invalidate: " .. tostring(qerr) end
    return n
end

-- ---------------------------------------------------------------------------
-- timeline
-- ---------------------------------------------------------------------------
function M.timeline(args)
    args = args or {}
    local scope, err = require_str(args.scope, "scope")
    if not scope then return nil, err end
    local subject; subject, err = require_str(args.subject, "subject")
    if not subject then return nil, err end
    local predicate; predicate, err = require_str(args.predicate, "predicate")
    if not predicate then return nil, err end

    local rows, qerr = db.query("SELECT " .. RETURN_COLS .. " FROM " .. TBL
        .. " WHERE scope = ? AND subject = ? AND predicate = ? ORDER BY valid_from ASC, id ASC",
        scope, subject, predicate)
    if not rows then return nil, "kg.timeline: " .. tostring(qerr) end
    local out = {}
    for i, r in ipairs(rows) do out[i] = row_to_lua(r) end
    return out
end

-- ---------------------------------------------------------------------------
-- for_query: the facts a search query is about
-- ---------------------------------------------------------------------------
-- Words of a text: lowercased, split on anything not a letter or digit (so
-- payments_team → payments, team), stopwords dropped, a plural "s" trimmed.
local function words(text)
    local stop = require("luamemo.fts").STOPWORDS
    local out = {}
    for w in tostring(text or ""):lower():gmatch("[%w]+") do
        if #w >= 2 and not stop[w] then
            if #w > 3 and w:sub(-1) == "s" and w:sub(-2) ~= "ss" then w = w:sub(1, -2) end
            out[#out + 1] = w
        end
    end
    return out
end
M._words = words

function M.for_query(scopes, query, limit)
    if type(scopes) == "string" then scopes = { scopes } end
    if scopes == nil then   -- a search of every scope: every scope's facts but the code maps'
        scopes = {}
        for _, r in ipairs(db.query("SELECT DISTINCT scope FROM " .. TBL
                .. " WHERE valid_until IS NULL AND scope NOT GLOB 'codeindex:*'") or {}) do
            scopes[#scopes + 1] = r.scope
        end
    end
    if type(scopes) ~= "table" or type(query) ~= "string" then return {} end
    local qw = {}
    for _, w in ipairs(words(query)) do qw[w] = true end
    if next(qw) == nil then return {} end
    -- Only the current facts naming a query word come back from SQLite: LIKE keeps every
    -- row the word match below can (a word is lower-case ASCII letters and digits, found
    -- whole or with a plural "s" in the subject or predicate; LIKE ignores ASCII case). It
    -- was the scope's 1,000 newest facts, scanned here — older ones were never found.
    -- 100 words per query: a long query (an agent may search with a whole paragraph)
    -- would pass SQLite's expression-depth limit (~500 words: the facts were lost) and
    -- LuaJIT's unpack limit (~4,000: the search failed).
    local list = {}
    for w in pairs(qw) do list[#list + 1] = w end
    local chunks = {}
    for c = 1, #list, 100 do
        local likes, params = {}, {}
        for i = c, math.min(c + 99, #list) do
            likes[#likes + 1] = "subject LIKE ? OR predicate LIKE ?"
            params[#params + 1] = "%" .. list[i] .. "%"
            params[#params + 1] = params[#params]
        end
        chunks[#chunks + 1] = { params = params, sql = "SELECT " .. RETURN_COLS .. " FROM " .. TBL
            .. " WHERE scope = ? AND valid_until IS NULL AND (" .. table.concat(likes, " OR ")
            .. ") ORDER BY valid_from DESC, id DESC LIMIT 1000" }
    end
    local found = {}
    for _, scope in ipairs(scopes) do
        -- (a code map's scope holds its dependency edges, not facts: never scanned here)
        if type(scope) == "string" and scope ~= "" and not scope:match("^codeindex:") then
            local had = {}
            for _, chunk in ipairs(chunks) do
                for _, r in ipairs(db.query(chunk.sql, scope, unpack(chunk.params)) or {}) do
                    if not had[r.id] then
                        had[r.id] = true
                        local f, seen, n = row_to_lua(r), {}, 0
                        for _, w in ipairs(words(f.subject .. " " .. f.predicate)) do
                            if qw[w] and not seen[w] then seen[w] = true; n = n + 1 end
                        end
                        if n > 0 then found[#found + 1] = { n = n, f = f } end
                    end
                end
            end
        end
    end
    table.sort(found, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return tostring(a.f.valid_from) > tostring(b.f.valid_from)
    end)
    local out = {}
    for i = 1, math.min(tonumber(limit) or 3, #found) do
        local f = found[i].f
        local item = { scope = f.scope, subject = f.subject, predicate = f.predicate, value = f.object,
                       since = f.valid_from }
        local prev
        for _, h in ipairs(M.timeline({ scope = f.scope, subject = f.subject, predicate = f.predicate }) or {}) do
            if h.id ~= f.id and h.valid_until ~= nil and tostring(h.valid_from) <= tostring(f.valid_from) then prev = h end
        end
        if prev then item.previous = { value = prev.object, ["until"] = prev.valid_until } end
        out[#out + 1] = item
    end
    return out
end

return M
