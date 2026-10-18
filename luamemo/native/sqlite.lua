-- luamemo.native.sqlite
-- SQLite through LuaJIT's FFI. Values only ever reach SQL as bound parameters.
--
--   local sqlite = require("luamemo.native.sqlite")
--   local db = assert(sqlite.open(path))            -- WAL, busy timeout, new files 0600
--   db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT)")   -- scripts, no parameters
--   db:run("INSERT INTO t (body) VALUES (?)", { "hello" })          -- → changes, last rowid
--   local rows = db:query("SELECT id, body FROM t WHERE id > ?", { 0 })
--   db:transaction(function() ... end)              -- BEGIN IMMEDIATE … COMMIT (or ROLLBACK) → true | nil, err
--   db:scan(sql, params, function(r) ... r:blob_ptr(1) ... end)     -- fast row loop
--   db:vacuum_into(path)                            -- a consistent copy (new file, 0600)
--   db:close()
--
-- Errors from SQLite come back as nil, "sqlite: <what>: <SQLite's message>" — never with a
-- parameter value in them. Misuse (a closed database, a value that can't be bound) raises.
--
-- Values: INTEGER → Lua number (a decimal string past ±2^53), REAL → number, TEXT and BLOB →
-- Lua string (copied: SQLite's pointer dies at the next step), NULL → nil. Bind nil (or
-- sqlite.NULL) for NULL, sqlite.blob(s) for a BLOB, an int64 cdata for an exact big integer;
-- pass params.n when trailing parameters are nil.
--
-- Lua callbacks: SQLite may call back into Lua (functions registered with create_function
-- or create_fts5_function). LuaJIT aborts ("bad callback") when that happens under a
-- JIT-compiled sqlite3_step, so every stepping path here runs interpreted — except
-- scan(), the hot loop, which refuses SQL that names a registered function (scan runs
-- SELECTs, so a function used only by triggers never reaches it).

local loader = require("luamemo.native.loader")
local ffi = loader.ffi

pcall(ffi.cdef, [[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef long long sqlite3_int64;
typedef void (*sqlite3_destructor_type)(void*);
const char *sqlite3_libversion(void);
int sqlite3_libversion_number(void);
int sqlite3_compileoption_used(const char *zOptName);
int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close_v2(sqlite3*);
int sqlite3_exec(sqlite3*, const char *sql, void *callback, void *arg, char **errmsg);
void sqlite3_free(void*);
const char *sqlite3_errmsg(sqlite3*);
int sqlite3_extended_errcode(sqlite3*);
int sqlite3_busy_timeout(sqlite3*, int ms);
int sqlite3_get_autocommit(sqlite3*);
int sqlite3_changes(sqlite3*);
sqlite3_int64 sqlite3_last_insert_rowid(sqlite3*);
int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_finalize(sqlite3_stmt *pStmt);
int sqlite3_reset(sqlite3_stmt *pStmt);
int sqlite3_clear_bindings(sqlite3_stmt*);
int sqlite3_step(sqlite3_stmt*);
int sqlite3_bind_parameter_count(sqlite3_stmt*);
int sqlite3_bind_int64(sqlite3_stmt*, int, sqlite3_int64);
int sqlite3_bind_double(sqlite3_stmt*, int, double);
int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, sqlite3_destructor_type);
int sqlite3_bind_blob(sqlite3_stmt*, int, const void*, int n, sqlite3_destructor_type);
int sqlite3_bind_null(sqlite3_stmt*, int);
int sqlite3_column_count(sqlite3_stmt *pStmt);
const char *sqlite3_column_name(sqlite3_stmt*, int N);
int sqlite3_column_type(sqlite3_stmt*, int iCol);
sqlite3_int64 sqlite3_column_int64(sqlite3_stmt*, int iCol);
double sqlite3_column_double(sqlite3_stmt*, int iCol);
const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);
const void *sqlite3_column_blob(sqlite3_stmt*, int iCol);
int sqlite3_column_bytes(sqlite3_stmt*, int iCol);

typedef struct sqlite3_context sqlite3_context;
typedef struct sqlite3_value sqlite3_value;
void sqlite3_result_double(sqlite3_context*, double);
void sqlite3_result_int64(sqlite3_context*, sqlite3_int64);
void sqlite3_result_null(sqlite3_context*);
void sqlite3_result_text(sqlite3_context*, const char*, int, sqlite3_destructor_type);
void sqlite3_result_error(sqlite3_context*, const char*, int);
int sqlite3_value_type(sqlite3_value*);
sqlite3_int64 sqlite3_value_int64(sqlite3_value*);
double sqlite3_value_double(sqlite3_value*);
const unsigned char *sqlite3_value_text(sqlite3_value*);
int sqlite3_value_bytes(sqlite3_value*);
typedef void (*lm_sql_function)(sqlite3_context*, int, sqlite3_value**);
int sqlite3_create_function_v2(sqlite3 *db, const char *zFunctionName, int nArg, int eTextRep, void *pApp,
                               lm_sql_function xFunc, void *xStep, void *xFinal, void(*xDestroy)(void*));
int sqlite3_bind_pointer(sqlite3_stmt*, int, void*, const char*, void(*)(void*));

typedef struct Fts5Context Fts5Context;
typedef struct Fts5ExtensionApi Fts5ExtensionApi;
struct Fts5ExtensionApi {
  int iVersion;
  void *(*xUserData)(Fts5Context*);
  int (*xColumnCount)(Fts5Context*);
  int (*xRowCount)(Fts5Context*, sqlite3_int64 *pnRow);
  int (*xColumnTotalSize)(Fts5Context*, int iCol, sqlite3_int64 *pnToken);
  int (*xTokenize)(Fts5Context*, const char *pText, int nText, void *pCtx, void *xToken);
  int (*xPhraseCount)(Fts5Context*);
  int (*xPhraseSize)(Fts5Context*, int iPhrase);
  int (*xInstCount)(Fts5Context*, int *pnInst);
  int (*xInst)(Fts5Context*, int iIdx, int *piPhrase, int *piCol, int *piOff);
  sqlite3_int64 (*xRowid)(Fts5Context*);
  int (*xColumnText)(Fts5Context*, int iCol, const char **pz, int *pn);
  int (*xColumnSize)(Fts5Context*, int iCol, int *pnToken);
};
typedef void (*fts5_extension_function)(const Fts5ExtensionApi *pApi, Fts5Context *pFts,
                                        sqlite3_context *pCtx, int nVal, sqlite3_value **apVal);
typedef struct fts5_api {
  int iVersion;
  void *xCreateTokenizer;
  void *xFindTokenizer;
  int (*xCreateFunction)(struct fts5_api *pApi, const char *zName, void *pUserData,
                         fts5_extension_function xFunction, void (*xDestroy)(void*));
} fts5_api;
]])

local SQLITE_ROW, SQLITE_DONE = 100, 101
local OPEN_READONLY, OPEN_READWRITE, OPEN_CREATE, OPEN_NOMUTEX = 0x1, 0x2, 0x4, 0x8000
local MIN_VERSION, MIN_VERSION_TEXT = 3035000, "3.35"   -- RETURNING, UPSERT, FTS5, JSON
local MAX_CACHED = 64
local TWO53 = 9007199254740992
local TWO53_I = ffi.new("int64_t", TWO53)

local M = {}
M.NULL = setmetatable({}, { __tostring = function() return "sqlite.NULL" end })
-- A JSON null (a CLI / MCP argument sent as null) binds as NULL too.
local JSON_NULL = require("luamemo.json").null

local lib
local TRANSIENT

--- The loaded library (checked once: version, FTS5, JSON) | raises with the fix.
local function L()
    if lib then return lib end
    local l = loader.require("sqlite3")
    local v = l.sqlite3_libversion_number()
    local missing = {}
    if v < MIN_VERSION then missing[#missing + 1] = "version " .. MIN_VERSION_TEXT .. "+" end
    if l.sqlite3_compileoption_used("ENABLE_FTS5") == 0 then missing[#missing + 1] = "FTS5" end
    if v < 3038000 and l.sqlite3_compileoption_used("ENABLE_JSON1") == 0 then missing[#missing + 1] = "JSON" end
    if l.sqlite3_compileoption_used("ENABLE_MATH_FUNCTIONS") == 0 then missing[#missing + 1] = "math functions" end
    if #missing > 0 then
        error(("native: the SQLite library found (%s) lacks %s — install a current one (%s) or set %s")
            :format(ffi.string(l.sqlite3_libversion()), table.concat(missing, ", "), loader.LIBS.sqlite3.install,
                loader.LIBS.sqlite3.env), 3)
    end
    lib = l
    TRANSIENT = ffi.cast("sqlite3_destructor_type", -1)
    return lib
end
M._lib = L

function M.version() return ffi.string(L().sqlite3_libversion()) end

--- A BLOB parameter: a Lua string, or a pointer plus its length.
function M.blob(data, len) return { __blob = true, data = data, len = len or #data } end

local function snippet(sql)
    local s = tostring(sql):gsub("%s+", " ")
    return #s > 70 and (require("luamemo.util").cut_utf8(s, 67) .. "...") or s
end

local function bind(h, i, v)
    local t = type(v)
    if v == nil or v == M.NULL or v == JSON_NULL then return lib.sqlite3_bind_null(h, i)
    elseif t == "number" then
        if v == math.floor(v) and v >= -TWO53 and v <= TWO53 then return lib.sqlite3_bind_int64(h, i, v) end
        return lib.sqlite3_bind_double(h, i, v)
    elseif t == "string" then return lib.sqlite3_bind_text(h, i, v, #v, TRANSIENT)
    elseif t == "boolean" then return lib.sqlite3_bind_int64(h, i, v and 1 or 0)
    elseif t == "cdata" and (ffi.istype("int64_t", v) or ffi.istype("uint64_t", v)) then
        return lib.sqlite3_bind_int64(h, i, v)
    elseif t == "table" and v.__blob then
        return lib.sqlite3_bind_blob(h, i, v.data, v.len, TRANSIENT)
    end
    error(("sqlite: cannot bind a %s (parameter %d)"):format(t, i), 4)
end

local function column(h, i)
    local ct = lib.sqlite3_column_type(h, i)
    if ct == 1 then
        local v = lib.sqlite3_column_int64(h, i)
        -- compare as int64: converting first would round 2^53 + 1 down into range
        if v >= -TWO53_I and v <= TWO53_I then return tonumber(v) end
        return (tostring(v):gsub("U?LL$", ""))
    elseif ct == 2 then return lib.sqlite3_column_double(h, i)
    elseif ct == 3 then
        local p = lib.sqlite3_column_text(h, i)
        local n = lib.sqlite3_column_bytes(h, i)
        return (n > 0 and p ~= nil) and ffi.string(p, n) or ""
    elseif ct == 4 then
        local p = lib.sqlite3_column_blob(h, i)
        local n = lib.sqlite3_column_bytes(h, i)
        return n > 0 and ffi.string(p, n) or ""
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Connection
-- ---------------------------------------------------------------------------
local DB = {}
DB.__index = DB

--- Open (or create) a database file. opts: readonly, busy_ms (5000), wal (true).
-- New files are created 0600. → db | nil, err
function M.open(path, opts)
    opts = opts or {}
    local ok, l = pcall(L)
    if not ok then return nil, (tostring(l):gsub("^.-native:", "native:")) end
    local flags = (opts.readonly and OPEN_READONLY or (OPEN_READWRITE + OPEN_CREATE)) + OPEN_NOMUTEX
    local pp = ffi.new("sqlite3*[1]")
    local rc = opts.readonly and l.sqlite3_open_v2(path, pp, flags, nil)
        or require("luamemo.util").with_umask("077", l.sqlite3_open_v2, path, pp, flags, nil)   -- files 0600
    if rc ~= 0 then
        local msg = pp[0] ~= nil and ffi.string(l.sqlite3_errmsg(pp[0])) or ("error " .. rc)
        if pp[0] ~= nil then l.sqlite3_close_v2(pp[0]) end
        return nil, ("sqlite: open %s: %s"):format(path, msg)
    end
    local self = setmetatable({ h = ffi.gc(pp[0], l.sqlite3_close_v2), path = path,
        stmts = {}, order = {}, fns = {}, cbs = {} }, DB)
    l.sqlite3_busy_timeout(self.h, opts.busy_ms or 5000)
    local pragmas = "PRAGMA foreign_keys = ON;"
    if not opts.readonly and path ~= ":memory:" and opts.wal ~= false then
        pragmas = "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; " .. pragmas
    end
    local pok, perr = self:exec(pragmas)
    if not pok then self:close(); return nil, perr end
    return self
end

function DB:_check()
    if not self.h then error("sqlite: the database is closed", 3) end
end

function DB:_err(what, sql)
    return ("sqlite: %s: %s [%s]"):format(what, ffi.string(lib.sqlite3_errmsg(self.h)), snippet(sql))
end

--- Run an SQL script (one or more statements, no parameters). → true | nil, err
function DB:exec(sql)
    self:_check()
    local errp = ffi.new("char*[1]")
    local rc = lib.sqlite3_exec(self.h, sql, nil, nil, errp)
    if rc ~= 0 then
        local msg = errp[0] ~= nil and ffi.string(errp[0]) or ffi.string(lib.sqlite3_errmsg(self.h))
        if errp[0] ~= nil then lib.sqlite3_free(errp[0]) end
        return nil, ("sqlite: exec: %s [%s]"):format(msg, snippet(sql))
    end
    return true
end
jit.off(DB.exec)

function DB:_prepare(sql)
    self:_check()
    local h = self.stmts[sql]
    if h then return h end
    local pp, tail = ffi.new("sqlite3_stmt*[1]"), ffi.new("const char*[1]")
    if lib.sqlite3_prepare_v2(self.h, sql, #sql, pp, tail) ~= 0 then return nil, self:_err("prepare", sql) end
    if pp[0] == nil then return nil, ("sqlite: empty statement [%s]"):format(snippet(sql)) end
    if tail[0] ~= nil and ffi.string(tail[0]):find("%S") then
        lib.sqlite3_finalize(pp[0])
        return nil, ("sqlite: one statement per call — use exec() for scripts [%s]"):format(snippet(sql))
    end
    if #self.order >= MAX_CACHED then
        local victim = table.remove(self.order, 1)
        lib.sqlite3_finalize(self.stmts[victim])
        self.stmts[victim] = nil
    end
    self.stmts[sql] = pp[0]
    self.order[#self.order + 1] = sql
    return pp[0]
end

local function bind_all(h, params)
    -- Start clean: a previous call that raised mid-bind must not leave values behind.
    lib.sqlite3_reset(h); lib.sqlite3_clear_bindings(h)
    if not params then return end
    local n = params.n or #params
    local want = lib.sqlite3_bind_parameter_count(h)
    if n > want then error(("sqlite: %d parameters given, the statement takes %d"):format(n, want), 4) end
    for i = 1, n do
        if bind(h, i, params[i]) ~= 0 then return false end
    end
    return true
end

-- Steps a statement to completion (interpreted on purpose: see the header).
-- want_rows: nil = no rows kept, 1 = first row only, true = all rows.
local function run_stmt(self, sql, params, want_rows)
    local h, perr = self:_prepare(sql)
    if not h then return nil, perr end
    if bind_all(h, params) == false then
        local e = self:_err("bind", sql)
        lib.sqlite3_reset(h); lib.sqlite3_clear_bindings(h)
        return nil, e
    end
    local rows, names, nc = want_rows and {} or nil, nil, 0
    while true do
        local rc = lib.sqlite3_step(h)
        if rc == SQLITE_ROW then
            if want_rows then
                if not names then
                    nc = lib.sqlite3_column_count(h)
                    names = {}
                    for i = 0, nc - 1 do names[i] = ffi.string(lib.sqlite3_column_name(h, i)) end
                end
                local r = {}
                for i = 0, nc - 1 do r[names[i]] = column(h, i) end
                rows[#rows + 1] = r
                if want_rows == 1 then break end
            end
        elseif rc == SQLITE_DONE then
            break
        else
            local e = self:_err("step", sql)
            lib.sqlite3_reset(h); lib.sqlite3_clear_bindings(h)
            return nil, e
        end
    end
    lib.sqlite3_reset(h); lib.sqlite3_clear_bindings(h)
    return rows or true
end
jit.off(run_stmt)

--- All rows as tables (column name → value). → rows | nil, err
function DB:query(sql, params) return run_stmt(self, sql, params, true) end

--- The first row, or nil when there is none. → row | nil | nil, err
function DB:first(sql, params)
    local rows, err = run_stmt(self, sql, params, 1)
    if not rows then return nil, err end
    return rows[1]
end

--- The first column of the first row. → value | nil | nil, err
function DB:value(sql, params)
    local h, perr = self:_prepare(sql)
    if not h then return nil, perr end
    local row, err = self:first(sql, params)
    if err then return nil, err end
    if not row then return nil end
    return row[ffi.string(lib.sqlite3_column_name(h, 0))]
end

--- Run a statement for its effect. → changes, last_insert_rowid | nil, err
function DB:run(sql, params)
    local ok, err = run_stmt(self, sql, params, nil)
    if not ok then return nil, err end
    return lib.sqlite3_changes(self.h), tonumber(lib.sqlite3_last_insert_rowid(self.h))
end

-- ---------------------------------------------------------------------------
-- scan(): the hot loop. fn(r) per row; r reads columns by 0-based index. Pointers from
-- r:blob_ptr / r:text_ptr are valid only inside that call. Return false from fn to stop.
-- ---------------------------------------------------------------------------
local Reader = {}
Reader.__index = Reader
function Reader:type(i) return lib.sqlite3_column_type(self.h, i) end   -- 1 int 2 real 3 text 4 blob 5 null
function Reader:int(i) return tonumber(lib.sqlite3_column_int64(self.h, i)) end
function Reader:double(i) return lib.sqlite3_column_double(self.h, i) end
function Reader:value(i) return column(self.h, i) end
function Reader:blob_ptr(i) return lib.sqlite3_column_blob(self.h, i), lib.sqlite3_column_bytes(self.h, i) end
function Reader:bytes(i) return lib.sqlite3_column_bytes(self.h, i) end

function DB:scan(sql, params, fn)
    local lower = sql:lower()
    for name in pairs(self.fns) do
        if lower:find("%f[%w_]" .. name .. "%f[^%w_]") then
            error("sqlite: scan() can't run SQL that calls the Lua function " .. name .. " — use query()", 2)
        end
    end
    local h, perr = self:_prepare(sql)
    if not h then return nil, perr end
    if bind_all(h, params) == false then
        local e = self:_err("bind", sql)
        lib.sqlite3_reset(h); lib.sqlite3_clear_bindings(h)
        return nil, e
    end
    local r = setmetatable({ h = h }, Reader)
    local n, serr = 0, nil
    -- one pcall around the loop (not one per row): fn may raise — the statement is
    -- reset either way and the error re-raised
    local okf, ferr = pcall(function()
        while true do
            local rc = lib.sqlite3_step(h)
            if rc == SQLITE_ROW then
                n = n + 1
                if fn(r) == false then return end
            elseif rc == SQLITE_DONE then return
            else serr = self:_err("step", sql); return end
        end
    end)
    lib.sqlite3_reset(h); lib.sqlite3_clear_bindings(h)
    if not okf then error(ferr, 0) end
    if serr then return nil, serr end
    return n
end

-- ---------------------------------------------------------------------------
-- Transactions
-- ---------------------------------------------------------------------------
local sp_seq = 0

--- Run fn(db) in a transaction: COMMIT when it returns, ROLLBACK when it raises.
-- Outermost: BEGIN <mode> (IMMEDIATE by default — take the write lock up front, so a
-- busy database waits on busy_ms instead of failing at the first write). Nested: a
-- SAVEPOINT. → true, fn's results… | nil, err
function DB:transaction(fn, mode)
    self:_check()
    local outer = lib.sqlite3_get_autocommit(self.h) ~= 0
    local sp
    if outer then
        local ok, err = self:exec("BEGIN " .. (mode or "IMMEDIATE"))
        if not ok then return nil, err end
    else
        sp_seq = sp_seq + 1
        sp = "lm_sp_" .. sp_seq
        local ok, err = self:exec("SAVEPOINT " .. sp)
        if not ok then return nil, err end
    end
    local res = { pcall(fn, self) }
    if res[1] then
        local ok, err = self:exec(outer and "COMMIT" or ("RELEASE " .. sp))
        if not ok then
            self:exec(outer and "ROLLBACK" or ("ROLLBACK TO " .. sp .. "; RELEASE " .. sp))
            return nil, err
        end
        return true, unpack(res, 2, table.maxn(res))
    end
    self:exec(outer and "ROLLBACK" or ("ROLLBACK TO " .. sp .. "; RELEASE " .. sp))
    return nil, (tostring(res[2]):gsub("^sqlite: ", "sqlite: transaction rolled back: ", 1))
end

--- Number of result columns the statement produces (0 for INSERT/UPDATE/DELETE without RETURNING).
function DB:column_count(sql)
    local h, err = self:_prepare(sql)
    if not h then return nil, err end
    return lib.sqlite3_column_count(h)
end

function DB:user_version() return tonumber(self:value("PRAGMA user_version")) or 0 end

function DB:set_user_version(n)
    n = math.floor(tonumber(n) or -1)
    if n < 0 then error("sqlite: user_version must be a non-negative integer", 2) end
    return self:exec("PRAGMA user_version = " .. n)
end

function DB:in_transaction() self:_check(); return lib.sqlite3_get_autocommit(self.h) == 0 end
function DB:changes() self:_check(); return lib.sqlite3_changes(self.h) end
function DB:last_insert_rowid() self:_check(); return tonumber(lib.sqlite3_last_insert_rowid(self.h)) end

--- Write a consistent copy of the database to `path`, a file that must not exist yet
--- (created 0600). Safe while other connections read and write: VACUUM INTO copies one
--- snapshot. Not inside a transaction. → true | nil, err
function DB:vacuum_into(path)
    self:_check()
    local ok, err = require("luamemo.util").with_umask("077", run_stmt, self, "VACUUM INTO ?", { path, n = 1 })
    if not ok then return nil, err end
    return true
end

-- ---------------------------------------------------------------------------
-- Scalar SQL functions written in Lua
--   db:create_function("my_fn", 2, function(a, b) ... return value end)
-- Arguments arrive as Lua values (INTEGER/REAL → number, TEXT → string, BLOB → string,
-- NULL → nil); return a number, a string, a boolean or nil. Registered deterministic and
-- innocuous, so triggers, indexes and views may use it. An error raised by fn becomes the
-- statement's error.
-- ---------------------------------------------------------------------------
local UTF8, DETERMINISTIC, INNOCUOUS = 1, 0x800, 0x200000

local function value_of(v)
    local t = lib.sqlite3_value_type(v)
    if t == 1 then return tonumber(lib.sqlite3_value_int64(v))
    elseif t == 2 then return lib.sqlite3_value_double(v)
    elseif t == 3 or t == 4 then
        local p, n = lib.sqlite3_value_text(v), lib.sqlite3_value_bytes(v)
        return (n > 0 and p ~= nil) and ffi.string(p, n) or ""
    end
    return nil
end

function DB:create_function(name, nargs, fn)
    self:_check()
    if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then error("sqlite: bad function name", 2) end
    local args = {}
    local cb = ffi.cast("lm_sql_function", function(sctx, argc, argv)
        for i = 1, argc do args[i] = value_of(argv[i - 1]) end
        local ok, v = pcall(fn, unpack(args, 1, argc))
        for i = 1, argc do args[i] = nil end
        if not ok then
            local msg = tostring(v)
            lib.sqlite3_result_error(sctx, msg, #msg)
        elseif type(v) == "number" then
            if v == math.floor(v) and v >= -TWO53 and v <= TWO53 then lib.sqlite3_result_int64(sctx, v)
            else lib.sqlite3_result_double(sctx, v) end
        elseif type(v) == "string" then lib.sqlite3_result_text(sctx, v, #v, TRANSIENT)
        elseif type(v) == "boolean" then lib.sqlite3_result_int64(sctx, v and 1 or 0)
        else lib.sqlite3_result_null(sctx) end
    end)
    local rc = lib.sqlite3_create_function_v2(self.h, name, nargs, UTF8 + DETERMINISTIC + INNOCUOUS, nil, cb,
        nil, nil, nil)
    if rc ~= 0 then cb:free(); return nil, "sqlite: could not register " .. name .. ": " .. ffi.string(lib.sqlite3_errmsg(self.h)) end
    self.cbs[#self.cbs + 1] = cb
    self.fns[name:lower()] = true
    return true
end

-- ---------------------------------------------------------------------------
-- FTS5 auxiliary functions written in Lua
--   db:create_fts5_function("my_rank", function(x) ... return number end)
-- x:phrase_count(), x:inst_count(), x:inst(i) → phrase, column, token offset (0-based),
-- x:rowid(). Usable from query()/first()/value()/run() — not from scan().
-- ---------------------------------------------------------------------------
local Ext = {}
Ext.__index = Ext
local ip, cp, op, np = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("int[1]")
function Ext:phrase_count() return self.api.xPhraseCount(self.ctx) end
function Ext:inst_count() self.api.xInstCount(self.ctx, np); return np[0] end
function Ext:inst(i) self.api.xInst(self.ctx, i, ip, cp, op); return ip[0], cp[0], op[0] end
function Ext:rowid() return tonumber(self.api.xRowid(self.ctx)) end

function DB:create_fts5_function(name, fn)
    self:_check()
    if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then error("sqlite: bad function name", 2) end
    local pp = ffi.new("fts5_api*[1]")
    local sp = ffi.new("sqlite3_stmt*[1]")
    if lib.sqlite3_prepare_v2(self.h, "SELECT fts5(?1)", -1, sp, nil) ~= 0 then
        return nil, "sqlite: FTS5 is not available in this SQLite"
    end
    lib.sqlite3_bind_pointer(sp[0], 1, pp, "fts5_api_ptr", nil)
    lib.sqlite3_step(sp[0])
    lib.sqlite3_finalize(sp[0])
    if pp[0] == nil then return nil, "sqlite: FTS5 is not available in this SQLite" end
    local x = setmetatable({}, Ext)
    local cb = ffi.cast("fts5_extension_function", function(api, ctx, sctx)
        x.api, x.ctx = api, ctx
        local ok, v = pcall(fn, x)
        if ok and type(v) == "number" then lib.sqlite3_result_double(sctx, v) else lib.sqlite3_result_null(sctx) end
    end)
    local rc = pp[0].xCreateFunction(pp[0], name, nil, cb, nil)
    if rc ~= 0 then cb:free(); return nil, "sqlite: could not register " .. name end
    self.cbs[#self.cbs + 1] = cb
    self.fns[name:lower()] = true
    return true
end

--- Finalize every statement and close. Safe to call twice.
function DB:close()
    if not self.h then return end
    for _, h in pairs(self.stmts) do lib.sqlite3_finalize(h) end
    self.stmts, self.order = {}, {}
    local h = self.h
    self.h = nil
    ffi.gc(h, nil)
    lib.sqlite3_close_v2(h)
    for _, cb in ipairs(self.cbs) do cb:free() end   -- after close: SQLite no longer calls them
    self.cbs, self.fns = {}, {}
end

return M
