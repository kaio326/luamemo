-- luamemo.db
-- The luamemo database: one SQLite file, through luamemo.native.sqlite.
--
-- Which file (first set wins): luamemo.setup{ db = … } (config.db), MEMO_DB.
--   A NAME ("myproject") lives in the data directory, $XDG_DATA_HOME/luamemo/<name>.db
--   (default ~/.local/share/luamemo, created 0700; database files are created 0600).
--   A value with a "/" is a path. ":memory:" is an in-memory database.
-- Opening registers the FTS functions (luamemo.fts: the ranker ts_cd and lm_fts_doc, which
-- the schema's triggers call) and applies the pending schema migrations (luamemo.schema).
--
-- Parameters are always bound (`?`), never spliced into the SQL:
--   db.query(sql, ...)        → rows | { affected_rows = n } (no result columns) | nil, err
--   db.first(sql, ...)        → row | nil | nil, err
--   db.value(sql, ...)        → value | nil | nil, err
--   db.run(sql, ...)          → changes, last_insert_rowid | nil, err
--   db.scan(sql, params, fn)  → rows visited | nil, err   (the hot row loop; see native.sqlite)
--   db.transaction(fn)        → true, fn's results… | nil, err   (nested → savepoint)
-- JSON columns (tags, metadata, …) come back decoded; pass tables through db.json().
-- Timestamps are integer microseconds (util.now_us).
--
--   db.open(path, opts) → another luamemo database (same methods + close()); opts.readonly
--                         opens without migrating (a source that must not change)
--   db.path() → the configured file | nil, err     db.data_dir()     db.reset()
--   db.vacuum_into(path) → a consistent copy of the database (new file, 0600)
--   db.private_dir(dir) → creates dir (the last component 0700)
--   db.placeholders(n) → "?, ?, …"
--   db.in_list(values) → "(SELECT value FROM json_each(?))", json — a list of any length
--                         as ONE parameter (for lists that grow with the data)

local sqlite = require("luamemo.native.sqlite")
local json   = require("luamemo.json")

local M = {}

M.JSON_COLUMNS = {
    tags = true, metadata = true, weights = true, proposers = true, grounding = true,
    evidence_ids = true, evidence_quotes = true, candidate_ids = true,
}

-- ---------------------------------------------------------------------------
-- Where the database lives
-- ---------------------------------------------------------------------------
function M.data_dir()
    local base = os.getenv("XDG_DATA_HOME")
    if not base or base == "" then base = (os.getenv("HOME") or ".") .. "/.local/share" end
    return base .. "/luamemo"
end

--- Create a database's directory and its missing parents (a directory luamemo creates is
--- 0700; one that already exists is left as it is). luamemo.util.private_dir.
M.private_dir = require("luamemo.util").private_dir

--- Name or path → file path.
function M.resolve(v)
    if v == ":memory:" or tostring(v):find("/", 1, true) then return v end
    if not tostring(v):match("^[%w][%w%._%-]*$") then
        return nil, "db: a database name is letters, digits, '.', '_' or '-' (or give a path with a '/'): " .. tostring(v)
    end
    return M.data_dir() .. "/" .. v .. (v:match("%.db$") and "" or ".db")
end

local function configured()
    local ok, m = pcall(require, "luamemo")
    local v = ok and type(m) == "table" and type(m.config) == "table" and m.config.db or nil
    if v == nil or v == "" then v = os.getenv("MEMO_DB") end
    if v == nil or v == "" then
        return nil, "db: no database configured — run `memo calibrate` in your project, or set MEMO_DB "
            .. "(a name, kept in " .. M.data_dir() .. ", or a path)"
    end
    return M.resolve(v)
end

function M.path() return configured() end

-- ---------------------------------------------------------------------------
-- Opening: migrations, identity, ranker
-- ---------------------------------------------------------------------------
local random_hex = require("luamemo.util").random_hex

local function migrate(conn, migrations)
    migrations = migrations or require("luamemo.schema").MIGRATIONS
    local done = {}
    if conn:value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'lm_migrations'") then
        for _, r in ipairs(conn:query("SELECT name FROM lm_migrations") or {}) do done[r.name] = true end
    end
    local applied = 0
    for i, m in ipairs(migrations) do
        if not done[m.name] then
            local ok, err = conn:transaction(function(c)
                assert(c:exec(m.sql))
                assert(c:exec("CREATE TABLE IF NOT EXISTS lm_migrations (name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)"))
                assert(c:run("INSERT INTO lm_migrations (name, applied_at) VALUES (?, ?)",
                    { m.name, require("luamemo.util").now_us() }))
                if m.name == "001_init" then
                    assert(c:run("INSERT OR IGNORE INTO lm_meta (key, value) VALUES ('db_id', ?)", { random_hex(16) }))
                end
                assert(c:set_user_version(i))
            end)
            if not ok then return nil, ("db: migration %s failed: %s"):format(m.name, tostring(err)) end
            applied = applied + 1
        end
    end
    return applied
end
M._migrate = migrate

local function decode_row(r)
    for k, v in pairs(r) do
        if M.JSON_COLUMNS[k] and type(v) == "string" and v:match("^%s*[%[{]") then
            local ok, d = pcall(json.decode, v)
            if ok and d ~= nil then r[k] = d end
        end
    end
    return r
end

local function pack(...) return { n = select("#", ...), ... } end

-- Wrap a native connection in the luamemo API.
local function wrap(conn, path)
    local W = { conn = conn, path = path }
    function W.query(sql, ...)
        local rows, err = conn:query(sql, pack(...))
        if not rows then return nil, err end
        if #rows == 0 and conn:column_count(sql) == 0 then return { affected_rows = conn:changes() } end
        for _, r in ipairs(rows) do decode_row(r) end
        return rows
    end
    function W.first(sql, ...)
        local r, err = conn:first(sql, pack(...))
        if err then return nil, err end
        return r and decode_row(r) or nil
    end
    function W.value(sql, ...)
        local r, err = W.first(sql, ...)
        if err then return nil, err end
        if not r then return nil end
        local _, v = next(r)
        if conn:column_count(sql) ~= 1 then
            error("db.value: the statement must return exactly one column", 2)
        end
        return v
    end
    function W.run(sql, ...) return conn:run(sql, pack(...)) end
    function W.scan(sql, params, fn) return conn:scan(sql, params, fn) end
    function W.vacuum_into(path) return conn:vacuum_into(path) end
    function W.transaction(fn) return conn:transaction(function() return fn(W) end) end
    function W.in_transaction() return conn:in_transaction() end
    function W.close() conn:close() end
    return W
end

--- Open a luamemo database file (not the configured one). → handle | nil, err
--- opts.readonly: open without migrating. opts.migrations: another schema than
--- luamemo's (e.g. luamemo.schema.SECRETS_MIGRATIONS for a secrets store file).
function M.open(path, opts)
    opts = opts or {}
    local p, perr = M.resolve(path)
    if not p then return nil, perr end
    if p ~= ":memory:" and not opts.readonly then M.private_dir(p:match("^(.*)/[^/]*$") or ".") end
    local conn, err = sqlite.open(p, { readonly = opts.readonly, busy_ms = opts.busy_ms })
    if not conn then return nil, err end
    -- the FTS functions first: the schema's triggers call lm_fts_doc
    local rok, rerr = require("luamemo.fts").register(conn)
    if not rok then conn:close(); return nil, rerr end
    if not opts.readonly then
        local ok, merr = migrate(conn, opts.migrations)
        if not ok then conn:close(); return nil, merr end
    end
    return wrap(conn, p)
end

-- ---------------------------------------------------------------------------
-- The configured database (one connection per process, opened on first use)
-- ---------------------------------------------------------------------------
local _db

local function get()
    if _db then return _db end
    local p, err = configured()
    if not p then return nil, err end
    local h, oerr = M.open(p)
    if not h then return nil, oerr end
    _db = h
    return _db
end
M.get = get

function M.reset()
    if _db then pcall(_db.close) end
    _db = nil
end

--- After the configuration changed: close the open database if it is no longer the
--- configured one (the next use opens the right one).
function M.reconfigure()
    if not _db then return end
    local p = configured()
    if p ~= _db.path then M.reset() end
end

local function via(name)
    return function(...)
        local h, err = get()
        if not h then return nil, err end
        return h[name](...)
    end
end
M.query, M.first, M.value, M.run, M.scan, M.transaction = via("query"), via("first"), via("value"), via("run"),
    via("scan"), via("transaction")
M.vacuum_into = via("vacuum_into")

--- Is the configured database inside a transaction right now? (false when not open)
function M.in_transaction() return _db ~= nil and _db.in_transaction() end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
function M.json(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    return json.encode(v)
end

--- A BLOB parameter (a plain Lua string binds as TEXT).
function M.blob(s) return s ~= nil and sqlite.blob(s) or nil end

function M.placeholders(n)
    if n < 1 then return "" end
    return ("?, "):rep(n - 1) .. "?"
end

--- A list of any length for `x IN …`, as ONE parameter: returns the SQL
--- "(SELECT value FROM json_each(?))" and its JSON value. For lists that grow
--- with the data — `placeholders` binds one variable per value, and SQLite caps
--- a statement's variables (32,766) while LuaJIT's unpack stops near 8,000.
function M.in_list(values)
    return "(SELECT value FROM json_each(?))", json.encode(values)
end

return M
