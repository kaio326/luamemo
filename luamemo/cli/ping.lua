-- luamemo.cli.ping
--
-- `memo ping` — standalone connectivity check.
--
-- Verifies three things without requiring setup() to have been called:
--   1. Database       — opens the configured database file (creating it and
--                       applying the schema when new) and reports the file, its
--                       journal mode, and the native libraries (which copy, version).
--   2. Memories       — counts lm_memories.
--   3. Embedder URL   — if MEMO_EMBEDDER_URL is set, sends a probe embed
--                       request and reports the detected dimension.
--
-- Exit codes: 0 = all selected checks passed, 1 = any check failed.
--
-- Flags:
--   --db           run only the database + libraries check
--   --table        run only the memories check (implies --db)
--   --embedder     run only the embedder check
--   (no flags)     run all three checks

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Print one result line.
local function result(status, label, detail)
    -- status: "PASS", "FAIL", "SKIP", "WARN"
    io.write(string.format("[%s] %-16s %s\n", status, label, detail or ""))
end

-- ---------------------------------------------------------------------------
-- Individual checks
-- ---------------------------------------------------------------------------

local function check_db()
    local db = require("luamemo.db")
    local loader = require("luamemo.native.loader")
    local ok_all = true

    local sq_ok, sq_ver = pcall(function() return require("luamemo.native.sqlite").version() end)
    if sq_ok then
        local _, where = loader.load("sqlite3")
        result("PASS", "SQLite", ("%s (%s)"):format(sq_ver, tostring(where)))
    else
        result("FAIL", "SQLite", tostring(sq_ver))
        return false
    end
    local so_ok, so_ver = pcall(function() return require("luamemo.native.sodium").version() end)
    if so_ok then
        local _, where = loader.load("sodium")
        result("PASS", "libsodium", ("%s (%s)"):format(so_ver, tostring(where)))
    else
        result("FAIL", "libsodium", tostring(so_ver))
        ok_all = false
    end

    local path, perr = db.path()
    if not path then
        result("FAIL", "Database", tostring(perr))
        return false
    end
    local h, err = db.get()
    if not h then
        result("FAIL", "Database", tostring(err))
        return false
    end
    result("PASS", "Database", ("%s (journal: %s)"):format(path, tostring(h.value("PRAGMA journal_mode"))))
    return ok_all
end

local function check_table(db_ok)
    if not db_ok then
        result("SKIP", "Memories", "(database not available)")
        return false
    end
    local db = require("luamemo.db")
    local n, err = db.value("SELECT count(*) FROM lm_memories")
    if n then
        result("PASS", "Memories", tostring(n) .. " rows")
        return true
    end
    result("FAIL", "Memories", tostring(err))
    return false
end

local function check_embedder()
    local cfg = require("luamemo.cli._common").config_from_env({ warn = false })
    if cfg.settings_errors then
        result("FAIL", "Embedder", table.concat(cfg.settings_errors, "; "))
        return false
    end
    local url = cfg.embedder_url
    if url then
        -- The config every other command uses — headers included (a {secret:…} in
        -- them is read from the vault) — so ping is a reliable proxy for writes and
        -- calibrate.
        local full = require("luamemo.settings").defaults()
        for k, v in pairs(cfg) do full[k] = v end
        require("luamemo.secrets").configure(full)
        local embed = require("luamemo.embed")
        embed.configure(full)

        local dim, err = embed.probe()
        if dim then
            result("PASS", "Embedder", url .. " \226\134\146 dim=" .. dim)
            return true
        else
            result("FAIL", "Embedder", tostring(err))
            return false
        end
    end

    -- No HTTP embedder configured: MEMO_EMBEDDER selects a LOCAL (in-process)
    -- embedder — "hash" (the zero-dependency default) or an in-process model
    -- such as "gguf_ffi". Actually exercise it via the module's own
    -- selftest() rather than unconditionally SKIPping: hash needs no network
    -- and always passes trivially, but gguf_ffi (and any future local
    -- embedder) CAN fail — a wrong MEMO_GGUF_MODEL path, an unbuilt/missing
    -- native shim, a wrong architecture, OOM, etc. `memo ping` is the one
    -- command whose job is to catch exactly that before a real write fails.
    local name = os.getenv("MEMO_EMBEDDER")
    if not name or name == "" then name = "hash" end

    local ok_mod, mod = pcall(require, "luamemo.embedders." .. name)
    if not ok_mod then
        result("FAIL", "Embedder", "local embedder '" .. name .. "' not found: " .. tostring(mod))
        return false
    end
    if type(mod.selftest) ~= "function" then
        result("SKIP", "Embedder", "(local embedder '" .. name .. "' has no selftest)")
        return true
    end

    local ok, err = mod.selftest()
    if ok then
        result("PASS", "Embedder", name .. " (local, in-process)")
        return true
    else
        result("FAIL", "Embedder", name .. ": " .. tostring(err))
        return false
    end
end

-- ---------------------------------------------------------------------------
-- Flag parser
-- ---------------------------------------------------------------------------

local function parse_flags(argv)
    local f = { db = false, table = false, embedder = false }
    local explicit = false
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if     a == "--db"       then f.db = true; explicit = true
        elseif a == "--table"    then f.table = true; explicit = true
        elseif a == "--embedder" then f.embedder = true; explicit = true
        else
            io.stderr:write("memo ping: unknown flag: " .. a .. "\n")
            io.stderr:write("Usage: memo ping [--db] [--table] [--embedder]\n")
            os.exit(2)
        end
        i = i + 1
    end
    -- No explicit flags → run all checks.
    if not explicit then
        f.db = true; f.table = true; f.embedder = true
    end
    -- --table implies --db (table check needs DB to be reachable).
    if f.table then f.db = true end
    return f
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

function M.run(argv)
    local flags = parse_flags(argv or {})

    local any_fail = false

    local db_ok = true

    if flags.db then
        db_ok = check_db()
        if not db_ok then any_fail = true end
    end

    if flags.table then
        local tbl_ok = check_table(db_ok)
        if not tbl_ok then any_fail = true end
    end

    if flags.embedder then
        local emb_ok = check_embedder()
        if not emb_ok then any_fail = true end
    end

    os.exit(any_fail and 1 or 0)
end

return M
