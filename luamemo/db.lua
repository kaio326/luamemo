-- luamemo.db
-- Portable PostgreSQL abstraction — pgmoon only.
--
-- Works in any Lua 5.1+ environment: plain Lua scripts, OpenResty workers,
-- LuaJIT, CI pipelines. No lapis.db dependency.
--
-- Connection config resolution order (first wins):
--   1. MEMO_DB_URL env var  —  postgresql://user:pass@host:port/db
--   2. Individual config keys set via M.setup() / luamemo.setup():
--        pg_host, pg_port, pg_database, pg_user, pg_password
--   3. Standard PostgreSQL env vars: PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
--   4. Hard defaults: 127.0.0.1 : 5432 / luamemo / postgres / ""
--
-- Public API:
--   db.query(sql [, ...])           → rows, err
--   db.escape_literal(val)          → string
--   db.escape_identifier(name)      → string
--   db.interpolate_query(sql, ...)  → string
--   db.delete(table_name, where)    → result, err

local M = {}

-- ---------------------------------------------------------------------------
-- Pure-Lua escape helpers
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
-- MEMO_DB_URL parser
-- Handles: postgresql://[user[:pass]@][host][:port][/db][?...]
-- ---------------------------------------------------------------------------
local function parse_db_url(url)
    if not url or url == "" then return nil end
    -- strip scheme
    local rest = url:match("^postgres%a*://(.+)$")
    if not rest then return nil end

    local cfg = {}

    -- strip query string (ignore it)
    rest = rest:gsub("%?.*$", "")

    -- extract userinfo
    local userinfo, hostpart = rest:match("^([^@]+)@(.+)$")
    if not userinfo then hostpart = rest end

    if userinfo then
        local user, pass = userinfo:match("^([^:]*):?(.*)$")
        if user and user ~= "" then cfg.user     = user end
        if pass and pass ~= "" then cfg.password = pass end
    end

    -- extract /database
    local host_port, dbname = hostpart:match("^([^/]*)/(.+)$")
    if not host_port then host_port = hostpart end
    if dbname and dbname ~= "" then cfg.database = dbname end

    -- extract host:port
    -- handle IPv6 [::1]:5432
    local ipv6, port_after = host_port:match("^%[([^%]]+)%]:?(%d*)$")
    if ipv6 then
        cfg.host = ipv6
        if port_after and port_after ~= "" then cfg.port = tonumber(port_after) end
    else
        local h, p = host_port:match("^([^:]*):?(%d*)$")
        if h and h ~= "" then cfg.host = h end
        if p and p ~= "" then cfg.port = tonumber(p) end
    end

    return cfg
end

-- ---------------------------------------------------------------------------
-- pgmoon connection management
-- A single persistent connection reused across calls. One reconnect attempt
-- on failure before propagating the error.
-- ---------------------------------------------------------------------------
local _pg = nil

local function pg_connect_config()
    -- MEMO_DB_URL takes top priority.
    local url_cfg = parse_db_url(os.getenv("MEMO_DB_URL")) or {}

    -- Lazy-load luamemo config (avoids circular dependency).
    local lib_cfg = {}
    local ok, m = pcall(require, "luamemo")
    if ok and m and type(m.config) == "table" then lib_cfg = m.config end

    -- Also honour MEMO_DB_URL stored in luamemo config (set by memo calibrate).
    if not next(url_cfg) and type(lib_cfg.db_url) == "string" then
        url_cfg = parse_db_url(lib_cfg.db_url) or {}
    end

    return {
        host     = url_cfg.host     or lib_cfg.pg_host     or os.getenv("PGHOST")     or "127.0.0.1",
        port     = url_cfg.port     or tonumber(lib_cfg.pg_port or os.getenv("PGPORT") or 5432),
        database = url_cfg.database or lib_cfg.pg_database or os.getenv("PGDATABASE") or "luamemo",
        user     = url_cfg.user     or lib_cfg.pg_user     or os.getenv("PGUSER")     or "postgres",
        password = url_cfg.password or lib_cfg.pg_password or os.getenv("PGPASSWORD") or "",
    }
end

local function connect_pg()
    local pgmoon = require("pgmoon")
    local conn   = pgmoon.new(pg_connect_config())
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

-- Allow callers to force a new connection (e.g. after fork or config change).
function M.reset()
    _pg = nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.escape_literal(val)
    return escape_literal_raw(val)
end

function M.escape_identifier(name)
    return escape_identifier_raw(name)
end

function M.interpolate_query(sql, ...)
    local args = {...}
    local i = 0
    return (sql:gsub("%?", function()
        i = i + 1
        return escape_literal_raw(args[i])
    end))
end

function M.query(sql, ...)
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

function M.delete(table_name, where)
    local parts = {}
    for k, v in pairs(where) do
        parts[#parts + 1] = escape_identifier_raw(k) .. " = " .. escape_literal_raw(v)
    end
    if #parts == 0 then
        return nil, "db.delete: empty where clause (would delete all rows)"
    end
    local sql = "DELETE FROM " .. escape_identifier_raw(table_name)
        .. " WHERE " .. table.concat(parts, " AND ")
    return M.query(sql)
end

return M
