-- luamemo.kg
--
-- Lightweight knowledge-graph layer. Stores (subject, predicate, object)
-- triples with bitemporal validity windows. Used for facts whose truth
-- value changes over time and where the *currently valid* answer must
-- override older ones — a query pattern vector search handles poorly.
--
-- Design constraints:
--   * Pure SQL via `lapis.db` (pgmoon under OpenResty / pgmoon shim
--     under plain Lua). No ORM. Same convention as `store.lua`.
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
-- All public functions accept ONE table argument so call-sites stay
-- self-documenting. The argument table is never mutated.

local cjson = require("cjson.safe")

local M = {}

-- luamemo.db delegates to lapis.db in OpenResty and pgmoon in
-- plain-Lua environments. No circular dependency: db.lua only reads
-- luamemo.config lazily at query time, not at module load.
local db = require("luamemo.db")
local function cfg() return require("luamemo").config end

local function tbl()
    -- Hard-coded for now; matches migration 003. We don't follow
    -- `cfg().db_table` because that points at the vector table and
    -- we don't want a single global `db_kg_table` knob until a real
    -- caller asks for it.
    return "lm_kg_facts"
end

-- ---------------------------------------------------------------------------
-- Validation helpers
-- ---------------------------------------------------------------------------
local function require_str(v, name)
    if type(v) ~= "string" or v == "" then
        return nil, name .. " is required (non-empty string)"
    end
    return v
end

local function ts_literal(v)
    -- Accept: nil (caller wants now()), number (unix epoch), string
    -- (ISO-8601 already), or `false` (explicit "leave it null").
    if v == nil  then return "now()" end
    if v == false then return "NULL" end
    if type(v) == "number" then
        return db.escape_literal(os.date("!%Y-%m-%dT%H:%M:%SZ", v))
            .. "::timestamptz"
    end
    if type(v) == "string" then
        return db.escape_literal(v) .. "::timestamptz"
    end
    return nil
end

-- Map a pgmoon row to a Lua-friendly shape (cast nullables, decode JSON
-- if any). For now the table has no JSON column, so this is a passthrough
-- with explicit nil normalisation for `valid_until` / `source_memory_id`.
local function row_to_lua(r)
    if not r then return nil end
    if r.valid_until == cjson.null      then r.valid_until = nil end
    if r.source_memory_id == cjson.null then r.source_memory_id = nil end
    return r
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

    local vf = ts_literal(args.valid_from)
    if not vf then return nil, "valid_from has unsupported type" end

    -- Optional supersede: invalidate any currently-valid (subject,
    -- predicate) row in this scope BEFORE inserting the new fact.
    -- Validity-window invariant means we set valid_until = valid_from
    -- of the new row.
    if args.supersede then
        local upd_sql = string.format([[
            UPDATE %s
               SET valid_until = %s
             WHERE scope = %s
               AND subject = %s
               AND predicate = %s
               AND valid_until IS NULL
        ]], tbl(), vf, db.escape_literal(scope),
            db.escape_literal(subject),
            db.escape_literal(predicate))
        local _ok, uerr = pcall(db.query, upd_sql)
        if not _ok then return nil, "kg.assert_fact: supersede failed: " .. tostring(uerr) end
    end

    local src = "NULL"
    if args.source_memory_id then
        local id_n = tonumber(args.source_memory_id)
        if not id_n then return nil, "source_memory_id must be numeric" end
        src = tostring(math.floor(id_n))
    end

    local sql = string.format([[
        INSERT INTO %s
            (scope, subject, predicate, object, valid_from, source_memory_id)
        VALUES (%s, %s, %s, %s, %s, %s)
        RETURNING %s
    ]], tbl(),
        db.escape_literal(scope),
        db.escape_literal(subject),
        db.escape_literal(predicate),
        db.escape_literal(object),
        vf,
        src,
        RETURN_COLS)

    local ok, rows = pcall(db.query, sql)
    if not ok then return nil, "kg.assert_fact: " .. tostring(rows) end
    if not rows or not rows[1] then
        return nil, "kg.assert_fact: insert returned no row"
    end
    return row_to_lua(rows[1])
end

-- ---------------------------------------------------------------------------
-- query
-- ---------------------------------------------------------------------------
function M.query(args)
    args = args or {}
    local scope, err = require_str(args.scope, "scope")
    if not scope then return nil, err end

    local where = { "scope = " .. db.escape_literal(scope) }

    if args.subject then
        if type(args.subject) ~= "string" then
            return nil, "subject must be a string"
        end
        where[#where + 1] = "subject = " .. db.escape_literal(args.subject)
    end
    if args.predicate then
        if type(args.predicate) ~= "string" then
            return nil, "predicate must be a string"
        end
        where[#where + 1] = "predicate = " .. db.escape_literal(args.predicate)
    end
    if args.object then
        if type(args.object) ~= "string" then
            return nil, "object must be a string"
        end
        where[#where + 1] = "object = " .. db.escape_literal(args.object)
    end

    -- Validity filter:
    --   default                         -> "currently valid" (valid_until IS NULL)
    --   args.at = <timestamp>           -> point-in-time
    --   args.include_invalidated = true -> no validity filter
    if not args.include_invalidated then
        if args.at ~= nil then
            local at_lit = ts_literal(args.at)
            if not at_lit or at_lit == "NULL" then
                return nil, "`at` must be a timestamp"
            end
            where[#where + 1] = "valid_from <= " .. at_lit
            where[#where + 1] = "(valid_until IS NULL OR valid_until > "
                                .. at_lit .. ")"
        else
            where[#where + 1] = "valid_until IS NULL"
        end
    end

    local limit = tonumber(args.limit) or 100
    if limit < 1 then limit = 1 end
    if limit > 1000 then limit = 1000 end

    local sql = string.format([[
        SELECT %s FROM %s
         WHERE %s
         ORDER BY valid_from DESC, id DESC
         LIMIT %d
    ]], RETURN_COLS, tbl(), table.concat(where, " AND "), limit)

    local ok, rows = pcall(db.query, sql)
    if not ok then return nil, "kg.query: " .. tostring(rows) end
    local out = {}
    for i, r in ipairs(rows or {}) do out[i] = row_to_lua(r) end
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

    local at_lit = ts_literal(args.at)   -- nil -> now()

    local where = {
        "scope = " .. db.escape_literal(scope),
        "subject = " .. db.escape_literal(subject),
        "predicate = " .. db.escape_literal(predicate),
        "valid_until IS NULL",
    }
    if args.object then
        if type(args.object) ~= "string" then
            return nil, "object must be a string"
        end
        where[#where + 1] = "object = " .. db.escape_literal(args.object)
    end

    local sql = string.format([[
        UPDATE %s SET valid_until = %s
         WHERE %s
        RETURNING id
    ]], tbl(), at_lit, table.concat(where, " AND "))

    local ok, rows = pcall(db.query, sql)
    if not ok then return nil, "kg.invalidate: " .. tostring(rows) end
    return #(rows or {})
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

    local sql = string.format([[
        SELECT %s FROM %s
         WHERE scope = %s AND subject = %s AND predicate = %s
         ORDER BY valid_from ASC, id ASC
    ]], RETURN_COLS, tbl(),
        db.escape_literal(scope),
        db.escape_literal(subject),
        db.escape_literal(predicate))

    local ok, rows = pcall(db.query, sql)
    if not ok then return nil, "kg.timeline: " .. tostring(rows) end
    local out = {}
    for i, r in ipairs(rows or {}) do out[i] = row_to_lua(r) end
    return out
end

return M
