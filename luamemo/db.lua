-- luamemo.db
-- Portable PostgreSQL abstraction.
--
-- In OpenResty / Lapis (ngx global is present):
--   Delegates entirely to lapis.db — nginx connection pooling, type
--   coercion, and all SQL helpers are provided by lapis as before.
--   No behaviour change for existing Lapis deployments.
--
-- Outside OpenResty (plain Lua — CLI tools, scripts, background workers,
-- non-web apps):
--   Creates a pgmoon connection using config supplied to M.setup() or
--   standard PostgreSQL environment variables:
--
--     Config key    Env var      Default
--     ----------    ---------    -----------
--     pg_host       PGHOST       127.0.0.1
--     pg_port       PGPORT       5432
--     pg_database   PGDATABASE   luamemo
--     pg_user       PGUSER       postgres
--     pg_password   PGPASSWORD   (empty)
--
-- Public API — mirrors lapis.db exactly:
--   db.query(sql [, ...])           → rows, err
--   db.escape_literal(val)          → string
--   db.escape_identifier(name)      → string
--   db.interpolate_query(sql, ...)  → string
--   db.delete(table_name, where)    → result, err
--
-- Dependency for the pgmoon path: pgmoon >= 1.13 (luasocket-backed;
-- available as the Alpine package lua5.1-pgmoon or via luarocks).

local M = {}

-- ---------------------------------------------------------------------------
-- lapis.db detection
--
-- ngx is always a table in every OpenResty Lua phase (init_by_lua,
-- init_worker_by_lua, content handlers, timers, …). It is never present
-- in plain Lua. Using it as the discriminator is more reliable than
-- trying to pcall-load lapis.db, which may or may not be installed.
-- ---------------------------------------------------------------------------
local _lapis_db   -- nil = not yet checked; false = not available; table = module

local function get_lapis_db()
    if _lapis_db ~= nil then return _lapis_db end
    if type(ngx) ~= "table" then
        _lapis_db = false
        return false
    end
    local ok, mod = pcall(require, "lapis.db")
    _lapis_db = ok and mod or false
    return _lapis_db
end

-- ---------------------------------------------------------------------------
-- Pure-Lua escape helpers
--
-- Used on the pgmoon path and inside interpolate_query. Rules:
--   string  → 'value' with single-quotes doubled
--   number  → bare number literal (no quotes)
--   boolean → TRUE / FALSE
--   nil     → NULL
-- ---------------------------------------------------------------------------
local function escape_literal_raw(val)
    local t = type(val)
    if t == "string"  then return "'" .. val:gsub("'", "''") .. "'" end
    if t == "number"  then return tostring(val) end
    if t == "boolean" then return val and "TRUE" or "FALSE" end
    if t == "nil"     then return "NULL" end
    error("db.escape_literal: unsupported type " .. t, 2)
end

local function escape_identifier_raw(name)
    return '"' .. tostring(name):gsub('"', '""') .. '"'
end

-- ---------------------------------------------------------------------------
-- pgmoon connection management
--
-- A single persistent connection is used for non-OpenResty environments.
-- If the server closes the connection between calls, one reconnect attempt
-- is made before propagating the error.
-- ---------------------------------------------------------------------------
local _pg = nil

local function pg_connect_config()
    -- Lazy-read so this works even when called before M.setup().
    -- luamemo is required lazily to avoid a circular dependency:
    --   luamemo → kg → db → luamemo
    local cfg = {}
    local ok, m = pcall(require, "luamemo")
    if ok and m and type(m.config) == "table" then cfg = m.config end
    return {
        host     = cfg.pg_host     or os.getenv("PGHOST")     or "127.0.0.1",
        port     = tonumber(cfg.pg_port or os.getenv("PGPORT") or 5432),
        database = cfg.pg_database or os.getenv("PGDATABASE") or "luamemo",
        user     = cfg.pg_user     or os.getenv("PGUSER")     or "postgres",
        password = cfg.pg_password or os.getenv("PGPASSWORD") or "",
    }
end

local function connect_pg()
    local pgmoon = require("pgmoon")
    local conn = pgmoon.new(pg_connect_config())
    local ok, err = conn:connect()
    if not ok then
        return nil, "db: pgmoon connect failed: " .. tostring(err)
    end
    _pg = conn
    return _pg
end

local function get_pg()
    if _pg then return _pg end
    return connect_pg()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Escape a value as a SQL literal.
-- Delegates to lapis.db in OpenResty; uses pure-Lua escaping otherwise.
function M.escape_literal(val)
    local ldb = get_lapis_db()
    if ldb then return ldb.escape_literal(val) end
    return escape_literal_raw(val)
end

--- Escape a name as a SQL identifier (double-quoted).
function M.escape_identifier(name)
    local ldb = get_lapis_db()
    if ldb then return ldb.escape_identifier(name) end
    return escape_identifier_raw(name)
end

--- Substitute ? placeholders in sql with properly escaped values.
-- Returns the interpolated SQL string without executing it.
function M.interpolate_query(sql, ...)
    local ldb = get_lapis_db()
    if ldb then return ldb.interpolate_query(sql, ...) end
    local args = {...}
    local i = 0
    return (sql:gsub("%?", function()
        i = i + 1
        return escape_literal_raw(args[i])
    end))
end

--- Execute a SQL statement, optionally with ? placeholder substitution.
-- Returns (rows_or_true, nil) on success, (nil, err_string) on failure.
-- pgmoon already applies PostgreSQL type coercion: ints → number,
-- booleans → boolean, NULL → nil. No post-processing needed.
function M.query(sql, ...)
    local ldb = get_lapis_db()
    if ldb then return ldb.query(sql, ...) end

    -- Apply ? substitution when extra args are provided.
    if select("#", ...) > 0 then
        sql = M.interpolate_query(sql, ...)
    end

    local pg, cerr = get_pg()
    if not pg then return nil, cerr end

    local res, qerr = pg:query(sql)
    if res == nil then
        -- One reconnect attempt — handles dropped idle connections.
        _pg = nil
        pg, cerr = connect_pg()
        if not pg then return nil, cerr end
        res, qerr = pg:query(sql)
    end

    if res == nil then return nil, qerr end
    return res
end

--- DELETE FROM table_name WHERE col = val [AND ...].
-- Mirrors lapis.db.delete(table_name, where_tbl).
function M.delete(table_name, where)
    local ldb = get_lapis_db()
    if ldb then return ldb.delete(table_name, where) end

    local parts = {}
    for k, v in pairs(where) do
        parts[#parts + 1] = escape_identifier_raw(k)
            .. " = " .. escape_literal_raw(v)
    end
    if #parts == 0 then
        return nil, "db.delete: empty where clause (would delete all rows)"
    end
    local sql = "DELETE FROM " .. escape_identifier_raw(table_name)
        .. " WHERE " .. table.concat(parts, " AND ")
    return M.query(sql)
end

return M
