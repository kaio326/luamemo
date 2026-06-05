-- luamemo.cli.ping
--
-- `memo ping` — standalone connectivity check.
--
-- Verifies three things without requiring setup() to have been called:
--   1. DB connection  — opens a pgmoon connection and runs SELECT 1.
--   2. Table exists   — queries lm_memories; distinguishes "missing table"
--                       from other DB errors.
--   3. Embedder URL   — if MEMO_EMBEDDER_URL is set, sends a probe embed
--                       request and reports the detected dimension.
--
-- Exit codes: 0 = all selected checks passed, 1 = any check failed.
--
-- Flags:
--   --db           run only the DB-connection check
--   --table        run only the table-existence check (implies --db)
--   --embedder     run only the embedder check
--   (no flags)     run all three checks

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Mask the password in a postgresql:// URL for safe display.
local function mask_url(url)
    if not url or url == "" then return "(not set)" end
    return (url:gsub("(postgresql?://[^:@]*:)[^@]*(@)", "%1***%2"))
end

-- Classify a pgmoon/db error to detect "relation does not exist".
local function is_missing_table(err)
    return err and (err:match("does not exist") or err:match("relation") or err:match("42P01"))
end

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
    local url = os.getenv("MEMO_DB_URL") or ""
    local rows, err = db.query("SELECT 1 AS ok")
    if rows then
        result("PASS", "DB connection", mask_url(url))
        return true
    else
        result("FAIL", "DB connection", (err or "unknown error") .. " — URL: " .. mask_url(url))
        return false
    end
end

local function check_table(db_ok)
    if not db_ok then
        result("SKIP", "Table exists", "(DB not reachable)")
        return false
    end
    local db = require("luamemo.db")
    local rows, err = db.query("SELECT count(*) AS n FROM lm_memories")
    if rows then
        local n = rows[1] and tonumber(rows[1].n) or 0
        result("PASS", "Table exists", "lm_memories (" .. n .. " rows)")
        return true
    elseif is_missing_table(err) then
        result("FAIL", "Table exists", "lm_memories not found — run: memo migrate")
        return false
    else
        result("FAIL", "Table exists", tostring(err))
        return false
    end
end

local function check_embedder()
    local url = os.getenv("MEMO_EMBEDDER_URL")
    if not url or url == "" then
        result("SKIP", "Embedder", "(MEMO_EMBEDDER_URL not set)")
        return true  -- not a failure — hash embedder needs no network
    end

    -- Load the same config vars as the rest of the CLI so that ping results
    -- are a reliable proxy for write/calibrate behaviour.
    local adapter      = os.getenv("MEMO_EMBEDDER_ADAPTER") or "generic"
    local model        = os.getenv("MEMO_EMBEDDER_MODEL")
    local cfg_embed_dim = tonumber(os.getenv("MEMO_EMBED_DIM"))
    local max_chars    = tonumber(os.getenv("MEMO_EMBED_MAX_CHARS"))

    local embed = require("luamemo.embed")
    embed.configure({
        embedder_url      = url,
        embedder_adapter  = adapter,
        embedder_model    = model,
        embed_dim         = cfg_embed_dim,  -- may be nil; embed.lua guards for nil
        embed_max_chars   = max_chars,
    })

    local dim, err = embed.probe()
    if dim then
        result("PASS", "Embedder", url .. " \226\134\146 dim=" .. dim)
        return true
    else
        result("FAIL", "Embedder", tostring(err))
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
