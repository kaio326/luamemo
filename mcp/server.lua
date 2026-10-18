#!/usr/bin/env luajit
-- luamemo MCP stdio server (LuaJIT, single-file)
--
-- Implements the Model Context Protocol (https://modelcontextprotocol.io/)
-- stdio transport: newline-delimited JSON-RPC 2.0 over stdin/stdout. Works on
-- the luamemo database (a SQLite file, luamemo.db) in-process — no server.
--
-- Configuration: the MEMO_* settings (luamemo.settings; `memo config list`), from the
-- environment the client passes and the .luamemorc files (read at startup — the
-- environment wins). The ones that matter most:
--   MEMO_DB           The database: a name (kept in ~/.local/share/luamemo)
--                     or a path (see luamemo.db)
--   MEMO_SCOPE        Default scope applied when a tool call omits it
--   MEMO_DEBUG        If "1", logs raw JSON-RPC frames to stderr
--
-- Run manually for testing:
--   echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
--     | MEMO_DB=scratch luajit mcp/server.lua

-- ---------------------------------------------------------------------------
-- Self-locate the bundled luamemo modules. Derive the repo/plugin root from
-- this script's own path (".../mcp/server.lua" → root) and prepend it to
-- package.path so `require("luamemo.*")` resolves to the code shipped next to
-- this server — no reliance on a LUA_PATH env var, and a stale system LuaRocks
-- install can't shadow the bundled modules. Falls back to the ambient path if
-- the root can't be derived (e.g. arg[0] unavailable).
-- ---------------------------------------------------------------------------
local SERVER_DIR   -- this script's directory (mcp/: instructions.md is next to it)
do
    -- The module paths keep absolute entries only (the root below is added after):
    -- LuaJIT's defaults begin with ./?.lua and ./?.so — the working directory, which
    -- for an MCP server is the user's project — so a luamemo/init.lua (or cjson.lua, …)
    -- there would run in luamemo's place.
    for _, k in ipairs({ "path", "cpath" }) do
        local kept = {}
        for e in package[k]:gmatch("[^;]+") do if e:sub(1, 1) == "/" then kept[#kept + 1] = e end end
        package[k] = table.concat(kept, ";")
    end
    local self_path = arg and arg[0]
    if self_path then
        SERVER_DIR = self_path:gsub("\\", "/"):match("^(.*)/[^/]+$") or "."
        local root = self_path:gsub("\\", "/"):match("^(.-)/?mcp/[^/]+$")
        if root then
            if root == "" then root = "." end
            package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
        end
    end
end

-- Settings: `memo mcp` (what client configs start) has read the .luamemorc files into
-- the environment already. Started directly, the server reads them here — the
-- project's (MEMO_PROJECT, else the nearest directory from the working directory up
-- that holds one) over ~/.luamemorc; a variable the client's config passes wins.
if os.getenv("MEMO__SETTINGS_LOADED") ~= "1" then
    require("luamemo.settings").load_files()
end

local json  = require("luamemo.json")
local ops   = require("luamemo.ops")   -- the operations memo offers too (their arguments read once)
local util  = require("luamemo.util")

math.randomseed(os.time() + math.floor(os.clock() * 1e6))

-- ===========================================================================
-- Config
-- ===========================================================================
local MEMO_SCOPE  = os.getenv("MEMO_SCOPE")
local DEBUG       = os.getenv("MEMO_DEBUG") == "1"

-- MEMO_MCP_TOOLS=core: only the everyday tools are offered — every tool's description sits
-- in each session's context; the maintenance, diary and vault-admin ones stay on memo.
local CORE_TOOLS = {
    memory_brief = true, memory_search = true, memory_write = true, memory_recent = true,
    memory_get = true, memory_update = true, memory_delete = true, memory_promote = true,
    memory_sense = true, memory_status = true, index_search = true, index_outline = true,
    index_explore = true, index_status = true, secret_list = true, secret_execute = true,
}
local TOOL_PROFILE = (os.getenv("MEMO_MCP_TOOLS") == "core") and "core" or "all"
local function offered(name) return TOOL_PROFILE == "all" or CORE_TOOLS[name] == true end

-- MCP revisions, newest first. Modern (2026-07-28 on): stateless — every request carries
-- its version and the client's capabilities in _meta. Legacy: an initialize handshake
-- picks the version for the whole process. The server speaks both (dual-era).
local MODERN_VERSIONS = { "2026-07-28" }
local LEGACY_VERSIONS = { "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" }
local SUPPORTED_VERSIONS = {}
for _, v in ipairs(MODERN_VERSIONS) do SUPPORTED_VERSIONS[#SUPPORTED_VERSIONS + 1] = v end
for _, v in ipairs(LEGACY_VERSIONS) do SUPPORTED_VERSIONS[#SUPPORTED_VERSIONS + 1] = v end
local function member(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end
local META = "io.modelcontextprotocol/"
local SERVER_NAME      = "luamemo"
-- Single source of truth: luamemo.VERSION (luamemo/init.lua) — was a
-- hardcoded literal here that silently went stale every release; require()
-- is safe at load time (no setup() / DB dependency for a plain constant).
local SERVER_VERSION   = (function()
    local ok, lm = pcall(require, "luamemo")
    return (ok and lm.VERSION) or "unknown"
end)()

-- The guidance sent to every client (initialize / server/discover `instructions`):
-- mcp/instructions.md, without its HTML comments (notes for whoever edits it).
local INSTRUCTIONS = (function()
    local f = SERVER_DIR and io.open(SERVER_DIR .. "/instructions.md", "r")
    if not f then return nil end
    local text = f:read("*a"); f:close()
    text = text:gsub("<!%-%-.-%-%->\n?", ""):gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
    return text ~= "" and text or nil
end)()

-- ===========================================================================
-- Logging (stderr only — stdout is reserved for JSON-RPC frames)
-- ===========================================================================
local function log(...)
    if not DEBUG then return end
    io.stderr:write("[luamemo-mcp] ")
    for i = 1, select("#", ...) do
        if i > 1 then io.stderr:write(" ") end
        io.stderr:write(tostring((select(i, ...))))
    end
    io.stderr:write("\n")
    io.stderr:flush()
end

local function fatal(msg)
    io.stderr:write("[luamemo-mcp] FATAL: " .. tostring(msg) .. "\n")
    io.stderr:flush()
    os.exit(1)
end

-- ===========================================================================
-- Library bootstrap
-- ===========================================================================
local _setup_done = false

--- Validate an agent_name string used to namespace diary scopes.
-- Returns nil on success, or an error string on failure.
-- Rules: non-empty, letters/digits/hyphens/underscores/dots only, max 64 chars.
local function validate_agent_name(name)
    if not name or name == "" then
        return "agent_name is required"
    end
    if #name > 64 or not name:match("^[%w%-_%.]+$") then
        return "agent_name must contain only letters, digits, hyphens, underscores, "
            .. "or dots and be at most 64 characters"
    end
    return nil
end

local function ensure_setup()
    if _setup_done then return end
    _setup_done = true
    local ok, luamemo = pcall(require, "luamemo")
    if not ok then
        fatal("luamemo library not found — install via: luarocks install luamemo\n" .. tostring(luamemo))
    end
    -- Build the config from the MEMO_* environment via the shared helper, so the
    -- embedder / DB / secrets / learning-flag parsing lives in ONE place (the
    -- api/CLI path uses the same).
    local cfg = require("luamemo.cli._common").config_from_env({
        warn = function(line) io.stderr:write("[luamemo-mcp] ", line, "\n") end })
    local pok, perr = pcall(luamemo.setup, cfg)
    if not pok then
        io.stderr:write("[luamemo-mcp] setup warning: " .. tostring(perr) .. "\n")
    end
end

--- nil when a database is configured, else what to do about it — the answer to every
--- tool call (the configuration doesn't change while the server runs).
local _unconfigured
local function not_configured()
    if _unconfigured == nil then
        _unconfigured = false
        if not require("luamemo.db").path() then
            local settings = require("luamemo.settings")
            local files = settings.files()
            local f = io.open(files.paths.project, "r")
            if f then f:close() end
            local restart = " Then restart luamemo in the MCP client."
            if files.untrusted then
                _unconfigured = "luamemo has no database: it is " .. settings.untrusted_message(
                    files.paths.project, files.untrusted) .. " (in that folder)." .. restart
            else
                _unconfigured = "luamemo has no database for this project yet: "
                    .. (f and (files.paths.project .. " names none (MEMO_DB).")
                        or ("no .luamemorc in " .. files.dir .. " or the folders above it (the "
                            .. "project is found from the directory the MCP client starts luamemo in)."))
                    .. " To set it up, run `memo calibrate` in the project's folder; for a project "
                    .. "elsewhere, start the server with `memo mcp --project /path/to/project` in "
                    .. "this MCP client's config." .. restart
            end
        end
    end
    return _unconfigured or nil
end

local list = json.list   -- an empty list encodes as []

-- What an agent reads of a memory (search, recent, get): its text and where it lives —
-- not the scoring internals (vec_score, fts_score, weight, decay_rate, …), empty tags /
-- metadata left out, the time to the second. About half the tokens of the whole row;
-- `verbose` returns the whole row. In a list (search, recent) a body is at most
-- BODY_CAP bytes (`truncated`: memory_get has it whole) — one long memory (an imported
-- document) cost its full length in every search it matched.
local BODY_CAP = 2000
local function compact(r, cap)
    local out = { id = r.id, observation_id = r.observation_id, title = r.title, body = r.body, kind = r.kind,
                  scope = r.scope, tier = r.tier }
    if cap and type(r.body) == "string" and #r.body > cap then
        out.body, out.truncated = util.cut_utf8(r.body, cap) .. "…", true
    end
    if type(r.tags) == "table" and next(r.tags) ~= nil then out.tags = r.tags end
    -- luamemo's own bookkeeping (lm_*: replica ids, sync clocks, proposal links) and an org
    -- memory's proposers (people's e-mail identities) stay out: half of an org search's
    -- answer, sent to the model on every call (verbose keeps them).
    if type(r.metadata) == "table" then
        local m
        for k, v in pairs(r.metadata) do
            if type(k) ~= "string" or (k:sub(1, 3) ~= "lm_" and k ~= "proposers") then
                m = m or {}
                m[k] = v
            end
        end
        out.metadata = m
    end
    if r.created_at ~= nil then out.created_at = tostring(r.created_at):sub(1, 19) end
    if tonumber(r.score) then out.score = tonumber(("%.3f"):format(tonumber(r.score))) end
    return out
end
local function rows_out(rows, verbose)
    if verbose or type(rows) ~= "table" then return list(rows) end
    local out = {}
    for i, r in ipairs(rows) do out[i] = type(r) == "table" and compact(r, BODY_CAP) or r end
    return list(out)
end
-- What a write / update answers (the agent sent the text): the row's handle, and the
-- store's note when it kept the row otherwise (no vector: too long for the embedder).
local function ack(r)
    return { id = r.id, scope = r.scope, kind = r.kind, title = r.title, tier = r.tier, warning = r.warning }
end
local VERBOSE = { type = "boolean", description = "Whole rows (scores, decay, timestamps) instead of the "
    .. "compact ones (default false)." }

-- Coerce "true"/"1" strings to booleans (tool input always comes as JSON,
-- so this is mainly for robustness when values are passed as strings).
local to_bool = util.to_bool

-- ===========================================================================
-- Tool implementations — direct library calls
-- ===========================================================================
local function with_default_scope(args)
    if MEMO_SCOPE and (not args.scope or args.scope == "") then
        args.scope = MEMO_SCOPE
    end
    return args
end

-- The scope a call works on: its own, else the project's (MEMO_SCOPE) — nil without either.
local function scope_of(args)
    local s = (type(args.scope) == "string" and args.scope ~= "") and args.scope or MEMO_SCOPE
    return (s and s ~= "") and s or nil
end

local Tools = {}

Tools.memory_write = {
    description = "Store a memory: a decision, a bug's cause, a chosen pattern, a fact or a plan that "
        .. "should outlive the session (and, at its end, a summary of what was done and what comes next). "
        .. "A near-duplicate is merged into the memory it repeats.",
    inputSchema = {
        type = "object",
        properties = {
            scope    = { type = "string", description = "e.g. repo:<name>, user:<name>, session:<id>." },
            kind     = { type = "string", description = "decision, fact, plan, … (any word)." },
            title    = { type = "string" },
            body     = { type = "string", description = "What is embedded and searched." },
            tags     = { type = "array", items = { type = "string" } },
            metadata = { type = "object" },
            importance = { type = "number", minimum = 0, maximum = 10, description = "Ranking weight (default 1)." },
            decay_rate = { type = "number", minimum = 0, maximum = 1, description = "Per day (default 0)." },
            dedup_strategy = {
                type = "string", enum = { "update", "skip", "append" },
                description = "A near-duplicate: update merges (default), skip keeps it, append adds anyway.",
            },
            created_at = { type = "string", description = "When it happened, if not now (ISO 8601)." },
            tier = { type = "integer", minimum = 0, maximum = 3, description = "Default: from importance." },
            items = {
                type = "array", maxItems = 100,
                description = "Up to 100 memories (objects with the fields above) instead of title / body.",
                items = { type = "object" },
            },
            verbose = { type = "boolean", description = "Answer with the whole stored memory." },
        },
    },
    handler = function(args)
        ensure_setup()
        local store = require("luamemo.store")
        local function fields(a)
            local f, err = ops.write_fields(a, a.scope)
            if not f then return nil, err end
            f.dedup_strategy = args.dedup_strategy   -- (the call's, for each of its items)
            return with_default_scope(f)
        end
        if args.items ~= nil then
            if type(args.items) ~= "table" or #args.items == 0 then return nil, "items: a list of memories" end
            if #args.items > 100 then return nil, "items: at most 100 per call" end
            local rows = {}
            for i, it in ipairs(args.items) do
                if type(it) ~= "table" then return nil, ("items[%d]: a memory object"):format(i) end
                local f, ferr = fields(it)
                if not f then return nil, ("items[%d]: %s"):format(i, ferr) end
                rows[i] = f
            end
            local res, err = store.write_many(rows, {
                dedup_strategy = args.dedup_strategy or require("luamemo").config.dedup_strategy })
            if not res then return nil, err end
            local out, written, failed = {}, 0, 0
            for i, r in ipairs(res) do
                if r.row then
                    written = written + 1
                    out[i] = { id = r.row.id, action = r.action, merged_into = r.merged_into }
                else
                    failed = failed + 1
                    out[i] = { error = tostring(r.error) }
                end
            end
            return { ok = failed == 0, written = written, failed = failed, results = out }
        end
        if (args.title == nil or args.title == "") and (args.body == nil or args.body == "") then
            return nil, "memory_write: title and body (or items)"
        end
        local f, ferr = fields(args)
        if not f then return nil, ferr end
        local row, err, action = store.write(f)
        if not row then return nil, err end
        -- The agent sent the text: echoing it back costs tokens for nothing.
        return { ok = true, memory = to_bool(args.verbose) and row or ack(row), action = action }
    end,
}

Tools.memory_search = {
    description = "Search memories (meaning + words), ranked by relevance, importance and age — call it "
        .. "before answering about earlier work or decisions. `facts` in the result: the current values "
        .. "of things that change over time — authoritative for what is true now; memories may be older.",
    inputSchema = {
        type = "object",
        properties = {
            query = { type = "string" },
            scope = { type = "string" },
            scopes = {
                type = "array",
                description = "Several scopes as one (e.g. repo + user + the brief's org: replica); "
                    .. "higher tiers first. Instead of scope.",
                items = { type = "string" },
            },
            kind  = { type = "string" },
            limit = { type = "integer", description = "Default 10.", minimum = 1, maximum = 100 },
            ignore_decay = { type = "boolean", description = "Rank by similarity only." },
            since = { type = "string", description = "Updated at or after (ISO 8601 or a date)." },
            ["until"] = { type = "string", description = "Updated before." },
            tier_min = { type = "integer", minimum = 0, maximum = 3, description = "Default 1 (hides tier 0)." },
            project = { type = "string", description = "Narrow org: scopes to one project (+ org-wide)." },
            tier_max = { type = "integer", minimum = 0, maximum = 3 },
            metadata_filter = { type = "object", description = "Metadata values to match, e.g. {\"source\": \"import\"}." },
            min_score = { type = "number", description = "Drop results scoring below this." },
            rerank = { type = "boolean", description = "Default: MEMO_RERANK_ENABLED." },
            hybrid_weights = { type = "object", description = "e.g. {\"vector\": 0.7, \"fts\": 0.3}." },
            verbose = VERBOSE,
        },
        required = { "query" },
    },
    handler = function(args)
        ensure_setup()
        -- The project's scope when the call names none; tier_min 1 hides ephemeral events
        -- unless the call passes tier_min = 0.
        local rows, facts = ops.search(args, { scope = MEMO_SCOPE, tier_min = 1 })
        if not rows then return nil, facts end
        local res = { ok = true, results = rows_out(rows, to_bool(args.verbose)) }
        -- The facts the query is about ride along (KG spike 2: agents read them here;
        -- they rarely ask a separate fact tool).
        if #facts > 0 then res.facts = facts end
        return res
    end,
}

Tools.memory_recent = {
    description = "The newest memories of a scope.",
    inputSchema = {
        type = "object",
        properties = {
            scope  = { type = "string" },
            limit  = { type = "integer", minimum = 1, maximum = 200 },
            kind   = { type = "string" },
            offset = { type = "integer", minimum = 0, description = "Skip this many (paging)." },
            tier_min = { type = "integer", minimum = 0, maximum = 3, description = "Default 1 (hides tier 0)." },
            verbose = VERBOSE,
        },
    },
    handler = function(args)
        ensure_setup()
        -- tier_min 1, as search: tier 0 is raw conversation the hooks save for the digest
        -- (a session scope's newest 20 were all transcript chunks — 26 KB).
        local rows, err = ops.recent(args, { scope = MEMO_SCOPE, tier_min = 1 })
        if not rows then return nil, err end
        return { ok = true, results = rows_out(rows, to_bool(args.verbose)) }
    end,
}

Tools.memory_get = {
    description = "Fetch a single memory by its numeric ID.",
    inputSchema = {
        type = "object",
        properties = { id = { type = "integer" }, verbose = VERBOSE },
        required = { "id" },
    },
    handler = function(args)
        ensure_setup()
        local store = require("luamemo.store")
        local row, err = store.get(tonumber(args.id))
        if not row then return nil, err or ("memory " .. tostring(args.id) .. " not found") end
        return { ok = true, memory = args.verbose and row or compact(row) }   -- as a list row, the body whole
    end,
}

Tools.memory_update = {
    description = "Change fields of a memory by id (re-embedded when the text changes).",
    inputSchema = {
        type = "object",
        properties = {
            id       = { type = "integer" },
            scope    = { type = "string" },
            kind     = { type = "string" },
            title    = { type = "string" },
            body     = { type = "string" },
            tags     = { type = "array", items = { type = "string" } },
            metadata = { type = "object" },
            importance = { type = "number", minimum = 0, maximum = 10 },
            decay_rate = { type = "number", minimum = 0, maximum = 1 },
            verbose  = { type = "boolean", description = "Answer with the whole stored memory." },
        },
        required = { "id" },
    },
    handler = function(args)
        ensure_setup()
        local row, err = ops.update(args.id, args)
        if not row then return nil, err end
        -- As memory_write: the agent sent the change — the whole row back (its body) costs tokens.
        return { ok = true, memory = to_bool(args.verbose) and row or ack(row) }
    end,
}

-- Bulk delete by filter goes in two calls (owner, 2026-10-08): the first only previews
-- (count + a few titles) and returns a confirmation token; the second, with the same
-- filter and the token, deletes. The token is an HMAC (a key random to this server
-- process) over the database, the filter, the count and an expiry 5 minutes out — it
-- can't be made up, reused for another filter, or used after the matches changed.
local DELETE_TOKEN_SECS = 300
local _delete_key

local function canonical(v)
    if type(v) ~= "table" then return json.encode(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = json.encode(k) .. ":" .. canonical(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function delete_token(filter, count, expires)
    local sodium = require("luamemo.native.sodium")
    _delete_key = _delete_key or sodium.random_bytes(32)
    local db_id = require("luamemo.db").value("SELECT value FROM lm_meta WHERE key = 'db_id'")
    local mac = sodium.hmac_sha256(_delete_key, table.concat({ tostring(db_id), canonical(filter),
        tostring(count), tostring(expires) }, "\n"))
    return ("%s.%d.%d"):format(util.to_hex(mac):sub(1, 32), count, expires)
end

-- nil when `token` confirms deleting `count` rows matching `filter` now, else why not.
local function token_problem(token, filter, count)
    local _, was, expires = tostring(token):match("^(%x+)%.(%d+)%.(%d+)$")
    if not expires then return "that confirm token isn't one a preview gave" end
    if tonumber(expires) < os.time() then return "the confirm token expired (they last 5 minutes)" end
    if delete_token(filter, tonumber(was), tonumber(expires)) ~= token then
        return "the confirm token was given for another filter"
    end
    if tonumber(was) ~= count then
        return ("the matching memories changed since the preview (%s then, %d now)"):format(was, count)
    end
    return nil
end

Tools.memory_delete = {
    description = "Delete one memory by `id`, or every memory matching a filter (`scope`, optionally "
        .. "`kind` / `metadata_filter`): a filter's first call only previews and returns a `confirm` "
        .. "token — show the user, then call again with it to delete.",
    inputSchema = {
        type = "object",
        properties = {
            id = { type = "integer" },
            scope = { type = "string", description = "A filter's scope." },
            kind = { type = "string" },
            metadata_filter = { type = "object", description = "Metadata values to match." },
            confirm = { type = "string", description = "The preview's token (5 minutes)." },
        },
    },
    handler = function(args)
        ensure_setup()
        local store = require("luamemo.store")
        if args.id ~= nil then
            local ok, err = store.delete(tonumber(args.id))
            if not ok then return nil, err end
            return { ok = true }
        end
        if type(args.scope) ~= "string" or args.scope == "" then
            return nil, "memory_delete: give an id — or a scope (and optionally kind / metadata_filter) to "
                .. "delete by filter"
        end
        local filter = { scope = args.scope, kind = args.kind, metadata_filter = args.metadata_filter }
        local m, err = store.match_where(filter, 5)
        if not m then return nil, err end
        local why
        if args.confirm ~= nil then
            why = token_problem(args.confirm, filter, m.count)
            if not why then
                local n, derr = store.delete_where(filter)
                if not n then return nil, derr end
                return { ok = true, deleted = n }
            end
        end
        if m.count == 0 then
            return { ok = true, count = 0, deleted = 0, note = (why and (why .. ". ") or "") .. "Nothing matches." }
        end
        local expires = os.time() + DELETE_TOKEN_SECS
        return {
            ok = true, preview = true, deleted = 0, count = m.count, titles = m.titles,
            confirm = delete_token(filter, m.count, expires), expires_in_seconds = DELETE_TOKEN_SECS,
            note = (why and (why .. ". ") or "") .. ("Nothing was deleted. To delete these %d memories, call "
                .. "memory_delete again with the same filter and this confirm token."):format(m.count),
        }
    end,
}

Tools.memory_promote = {
    description = "At a session's end: fold a session scope (session:<id>) into one summary in a "
        .. "long-term scope, so the next session finds it.",
    inputSchema = {
        type = "object",
        properties = {
            from_scope = { type = "string" },
            to_scope = { type = "string" },
            delete_source = { type = "boolean", description = "Delete the folded rows (default false)." },
            dry_run = { type = "boolean" },
            limit = { type = "integer", minimum = 1, maximum = 1000, description = "Rows folded at most (200)." },
            min_rows = { type = "integer", minimum = 1, description = "Fewer rows: nothing done (default 1)." },
        },
        required = { "from_scope", "to_scope" },
    },
    handler = function(args) ensure_setup(); return ops.promote(args) end,
}

Tools.memory_consolidate = {
    description = "Maintenance (when the user asks): expire decayed memories, group near-duplicates "
        .. "(merged by the summarizer). dry_run=true previews.",
    inputSchema = {
        type = "object",
        properties = {
            scope = { type = "string", description = "Default: every scope." },
            dry_run = { type = "boolean" },
            similarity_threshold = { type = "number", minimum = 0.5, maximum = 1.0, description = "Default 0.85." },
            decay_threshold = { type = "number", minimum = 0, maximum = 1, description = "Default 0.05." },
            max_rows = { type = "integer", minimum = 1, maximum = 5000, description = "Default 500." },
        },
    },
    handler = function(args) ensure_setup(); return ops.consolidate(args) end,
}

Tools.memory_summarize = {
    description = "Maintenance (when the user asks): fold old, low-weight memories of a scope into "
        .. "summaries (MEMO_SUMMARIZER_ADAPTER). dry_run=true previews.",
    inputSchema = {
        type = "object",
        properties = {
            scope = { type = "string" },
            dry_run = { type = "boolean" },
            weight_threshold = { type = "number", minimum = 0, description = "Fold memories weighing less." },
            retention_days = { type = "integer", minimum = 0, description = "… and older than this." },
            batch_size = { type = "integer", minimum = 1, description = "Memories per summary." },
            max_batches = { type = "integer", minimum = 1, description = "Summaries per call." },
        },
    },
    handler = function(args)
        ensure_setup()
        -- Over MCP one scope at a time (the project's by default) — memo can do them all.
        local scope = scope_of(args)
        if not scope then return nil, "memory_summarize: scope required" end
        return ops.summarize(args, scope)
    end,
}

Tools.memory_embed = {
    description = "The embedder's model and vector size for a text; with compare_to, how similar two "
        .. "phrasings are to it (cosine).",
    inputSchema = {
        type = "object",
        properties = {
            text = { type = "string" },
            compare_to = { type = "string" },
            include_vector = { type = "boolean", description = "Also the vector (long)." },
        },
        required = { "text" },
    },
    handler = function(args)
        ensure_setup()
        local res, err = ops.embed(args)
        if not res then return nil, err end
        res.ok = true
        return res
    end,
}

Tools.memory_tune_weights = {
    description = "Measure the vector / full-text blend that finds a scope's memories best (no model "
        .. "calls). A report for the user, who applies it with the `apply` command.",
    inputSchema = {
        type = "object",
        properties = {
            scope = { type = "string" },
            samples = { type = "integer", minimum = 5, maximum = 1000, description = "Default 50." },
            metric = { type = "string", enum = { "r_at_1", "r_at_3", "r_at_5", "r_at_10", "mrr" } },
        },
    },
    handler = function(args)
        ensure_setup()
        local report, err = ops.tune_weights(args, scope_of(args))
        if not report then return nil, err end
        report.ok = true
        return report
    end,
}

Tools.memory_learn = {
    description = "The scope's learned reranker: run (train on the feedback; promoted only if it beats "
        .. "the current one), status, rollback.",
    inputSchema = {
        type = "object",
        properties = {
            action = { type = "string", enum = { "run", "status", "rollback" }, description = "Default run." },
            scope = { type = "string" },
            dry_run = { type = "boolean", description = "run: compare, promote nothing." },
            min_samples = { type = "integer", minimum = 1, description = "Default 20." },
            margin = { type = "number", minimum = 0, description = "How much better it must be (0)." },
        },
    },
    handler = function(args) ensure_setup(); return ops.learn(args, scope_of(args)) end,
}

Tools.memory_digest = {
    description = "Maintenance (when the user asks): group ephemeral memories, promote proven ones to "
        .. "higher tiers. dry_run=true previews.",
    inputSchema = {
        type = "object",
        properties = {
            scope = { type = "string" },
            dry_run = { type = "boolean" },
            threshold = { type = "number", minimum = 0.5, maximum = 1.0, description = "Default 0.80." },
        },
    },
    handler = function(args) ensure_setup(); return ops.digest(args, scope_of(args)) end,
}

Tools.memory_sense = {
    description = "How memory learns from use: relay the recent turns (oldest first) after the user "
        .. "corrects you, sets a standing rule or confirms something; corrections, rules and praise are "
        .. "recorded on the memories they concern. Re-sending the same turns records nothing new.",
    inputSchema = {
        type = "object",
        properties = {
            turns = {
                type = "array",
                description = "{role: user | assistant, text}, oldest first.",
                items = {
                    type = "object",
                    properties = { role = { type = "string" }, text = { type = "string" } },
                },
            },
            scope = { type = "string" },
            generative = { type = "boolean", description = "Also the in-process model (MEMO_GEN_MODEL)." },
            min_similarity = { type = "number", minimum = 0, maximum = 1, description = "Default 0.15." },
        },
        required = { "turns" },
    },
    handler = function(args) ensure_setup(); return ops.sense(args, scope_of(args)) end,
}

-- ===========================================================================
-- Secrets tools
-- ===========================================================================

Tools.secret_list = {
    description = "The stored secrets: names and metadata, never values. A new key: the user runs "
        .. "`memo secret-store NAME` in a terminal (never in the chat); then use it with secret_execute.",
    inputSchema = {
        type       = "object",
        properties = {},
    },
    handler = function(_)
        ensure_setup()
        local secrets = require("luamemo.secrets")
        if not secrets.enabled() then
            return nil, secrets.NOT_CONFIGURED
        end
        local rows = secrets.list()
        return { ok = true, secrets = list(rows) }
    end,
}

-- The vault over MCP: an agent may add a secret but never replace one, and deletes in two
-- calls (a preview, then a confirm token) — a prompt-injected agent could otherwise swap
-- the user's API key for its own or destroy it. Replacing: `memo secret-store NAME`.
local function secret_meta(name)
    for _, s in ipairs(require("luamemo.secrets").list() or {}) do
        if s.name == name then return s end
    end
    return nil
end

Tools.secret_store = {
    description = "Add a NEW encrypted secret (never replaces one). Not with a value from the chat — it "
        .. "would reach the model: the user runs `memo secret-store NAME` in a terminal instead.",
    inputSchema = {
        type = "object",
        properties = {
            name = { type = "string", description = "Letters, digits, - _ . (at most 128)." },
            value = { type = "string" },
            description = { type = "string", description = "Stored in plain text." },
        },
        required = { "name", "value" },
    },
    handler = function(args)
        ensure_setup()
        local secrets = require("luamemo.secrets")
        if not secrets.enabled() then
            return nil, secrets.NOT_CONFIGURED
        end
        if not args.name or args.name == "" then return nil, "name is required" end
        if not args.value or args.value == "" then return nil, "value is required" end
        if secret_meta(tostring(args.name)) then
            return nil, ("a secret named %s exists — replacing it is the user's step, in a terminal: "
                .. "memo secret-store %s"):format(args.name, args.name)
        end
        local row, err = secrets.store(args.name, args.value, args.description)
        if not row then return nil, err end
        return { ok = true, secret = row }
    end,
}

Tools.secret_delete = {
    description = "Permanently delete a stored secret, in two calls: the first only shows which secret "
        .. "and returns a `confirm` token; call again with that token to delete. Ask the user first.",
    inputSchema = {
        type = "object",
        properties = {
            name    = { type = "string", description = "Secret name to delete." },
            confirm = { type = "string", description = "The token the first call returned (valid 5 minutes)." },
        },
        required = { "name" },
    },
    handler = function(args)
        ensure_setup()
        local secrets = require("luamemo.secrets")
        local name = tostring(args.name)
        local meta = secret_meta(name)
        if not meta then return nil, "secrets: not found: " .. name end
        local filter = { secret = name }
        if args.confirm == nil then
            local expires = os.time() + DELETE_TOKEN_SECS
            return { ok = false, preview = { name = meta.name, description = meta.description,
                         used_count = meta.used_count, last_used_at = meta.last_used_at },
                     confirm = delete_token(filter, 1, expires), expires_in_seconds = DELETE_TOKEN_SECS,
                     note = "Nothing deleted yet. Ask the user; to delete, call secret_delete again with "
                         .. "this confirm token." }
        end
        local why = token_problem(args.confirm, filter, 1)
        if why then return nil, why end
        local ok, err = secrets.delete(name)
        if not ok then return nil, err end
        return { ok = true, deleted = name }
    end,
}

Tools.secret_execute = {
    description = "An HTTP request with a stored secret filled in server-side: write {secret} in the "
        .. "URL's path or query, a header or the body. Returns the response body (the value masked).",
    inputSchema = {
        type = "object",
        properties = {
            name = { type = "string" },
            url = { type = "string", description = "http[s]://public-host[:port]/… — {secret} in path / query only." },
            method = { type = "string", enum = { "GET", "POST", "PUT", "PATCH", "DELETE" },
                       description = "Default GET (POST with multipart)." },
            headers = { type = "object", description = "e.g. {\"Authorization\": \"Bearer {secret}\"}." },
            body = { type = "string", description = "May hold {secret}. Or multipart." },
            multipart = {
                type        = "object",
                description = "Form fields: text (may hold {secret}), or {file = 'path/in/the/project', "
                    .. "content_type?} — project files only, never hidden or credential files.",
                additionalProperties = true,
            },
            timeout_ms = { type = "integer", minimum = 100, maximum = 120000, description = "Default 10000." },
            max_bytes = {
                type        = "integer",
                description = "Response bytes returned at most (default 65536; then `truncated`).",
                minimum     = 1024,
                maximum     = 1048576,
            },
        },
        required = { "name", "url" },
    },
    handler = function(args)
        ensure_setup()
        local secrets = require("luamemo.secrets")
        local name = tostring(args.name)
        -- A bounded answer: a whole web page or file would fill the agent's context.
        local max = math.max(1024, math.min(tonumber(args.max_bytes) or 65536, 1048576))
        local body, err, info = secrets.execute_with_secret(name, {
            url        = args.url,
            method     = args.method,
            headers    = args.headers,
            body       = args.body,
            multipart  = args.multipart,
            timeout_ms = tonumber(args.timeout_ms),
            max_bytes  = max,
            restrict_uploads = true,   -- the agent picks the files: the project's, never credentials
        })
        if not body then return nil, err end
        return { ok = true, response = body, truncated = (info and info.truncated) or nil }
    end,
}

-- Knowledge-graph facts, READ-only (owner, 2026-10-08/09, decided by a spike: with a facts
-- tool an agent tends to call it first, find nothing and answer "unknown" without searching
-- memories; writes added stale / wrong facts). The description and the empty-result hint
-- are the measured ones (77 % vs 50 % for read/write) — keep them. Writes: `memo kg`.
-- The knowledge graph reaches agents through memory_search's `facts` (owner, 2026-10-10,
-- KG spike 2: a separate fact tool went almost unused and hurt when asked first); facts are
-- recorded, queried at a time and traced through their history with `memo kg`.

Tools.memory_status = {
    description = "Memory counts per scope and the active configuration.",
    inputSchema = {
        type       = "object",
        properties = {
            verbose = { type = "boolean", description = "Also the embedder and its size." },
            details = { type = "boolean", description = "Every setting and where it comes from (read-only)." },
        },
    },
    handler = function(args)
        ensure_setup()
        local db_mod    = require("luamemo.db")
        local store_mod = require("luamemo.store")
        -- P3: single query — window function gives grand total alongside per-scope counts.
        local scopes, serr = db_mod.query(
            "SELECT scope, COUNT(*) AS n, SUM(COUNT(*)) OVER () AS grand_total " ..
            "FROM " .. store_mod.table_name() .. " GROUP BY scope ORDER BY n DESC LIMIT 20")
        if not scopes then return nil, tostring(serr) end
        local total = tonumber(scopes[1] and scopes[1].grand_total or 0)
        for _, r in ipairs(scopes) do r.grand_total = nil end   -- that is total_rows, once
        local lm    = require("luamemo")  -- single local reference
        local resp  = {
            connected  = true,
            total_rows = total,
            top_scopes = scopes,
            version    = lm.VERSION or "unknown",
            settings_warning = require("luamemo.brief").settings_note(),   -- an ignored project file
        }
        -- expose internal config only when the caller explicitly requests
        -- it (verbose=true).  Guards against architecture reconnaissance if the
        -- server is ever fronted by HTTP/SSE transport instead of local stdio.
        if args.verbose == true then
            local cfg_ref = lm.config or {}
            resp.config = {
                embedder     = cfg_ref.embedder_local or cfg_ref.embedder_adapter,
                embed_dim    = cfg_ref.embed_dim,
                patterns_en  = cfg_ref.patterns_enabled ~= false,
                tier_min_mcp = 1,
            }
        end
        if args.details == true then
            resp.settings = require("luamemo.settings").view(lm.config)
            resp.settings_note = "Settings are changed by people, not over MCP: memo config set KEY VALUE "
                .. "(or the project's .luamemorc). This server reads them when it starts."
        end
        return resp
    end,
}

-- The clients this process has served (what they say about themselves): recorded for
-- memo calibrate / memo doctor (luamemo.clients), and named in the brief when one is too
-- old for something luamemo needs — once per process (a session).
local seen_clients, noted = {}, false
local function client_seen(info, version, caps)
    local clip = require("luamemo.clients")._clip
    local rec = { name = clip(type(info) == "table" and info.name or nil) or "unknown client",
        version = clip(type(info) == "table" and info.version or nil) or "?", protocol = clip(version, 20) }
    seen_clients[tostring(rec.name) .. "|" .. tostring(rec.version) .. "|" .. tostring(version)] = rec
    pcall(require("luamemo.clients").record, info, version, caps)
end
local function client_notes()
    if noted then return {} end
    noted = true
    local out = {}
    for _, rec in pairs(seen_clients) do
        local w = require("luamemo.clients").warning(rec)
        if w then out[#out + 1] = "client: " .. w .. " Tell the user." end
    end
    table.sort(out)
    return out
end

Tools.memory_brief = {
    description = "The session brief — the project's scope and latest memories, its code map, what waits "
        .. "for the user. Call it first in a session unless the context holds a `=== LUAMEMO ===` block.",
    inputSchema = {
        type       = "object",
        properties = {
            scope = { type = "string", description = "Default: the project's." },
        },
    },
    handler = function(args)
        ensure_setup()
        local scope = (args.scope ~= nil and args.scope ~= "") and args.scope or MEMO_SCOPE
        return require("luamemo.brief").text(scope, { extra = client_notes() })
    end,
}

Tools.memory_reconnect = {
    description = "Re-open the database file (after a restore). Returns its memory count.",
    inputSchema = {
        type       = "object",
        properties = {},
    },
    handler = function(_)
        ensure_setup()
        local db_mod    = require("luamemo.db")
        local store_mod = require("luamemo.store")
        db_mod.reset()
        local n, err = db_mod.value("SELECT COUNT(*) FROM " .. store_mod.table_name())
        return {
            success    = n ~= nil,
            rows_after = tonumber(n),
            error      = (n == nil) and tostring(err) or nil,
        }
    end,
}

Tools.memory_diary_write = {
    description = "An entry in a named agent's own diary (scope diary:<agent_name>).",
    inputSchema = {
        type       = "object",
        properties = {
            agent_name = { type = "string" },
            entry = { type = "string" },
            topic = { type = "string", description = "Default general." },
        },
        required = { "agent_name", "entry" },
    },
    handler = function(args)
        ensure_setup()
        local name_err = validate_agent_name(args.agent_name)
        if name_err then return nil, name_err end
        if not args.entry or args.entry == "" then
            return nil, "entry is required"
        end
        -- S3: cap entry at 50,000 chars to prevent oversized embedding requests.
        if #args.entry > 50000 then
            return nil, "entry exceeds maximum length of 50,000 characters"
        end
        local store = require("luamemo.store")
        local scope = "diary:" .. args.agent_name
        local topic = tostring(args.topic or "general")
        if #topic > 200 then return nil, "topic exceeds 200-character limit" end
        local row, err = store.write({
            scope      = scope,
            kind       = "diary",
            title      = "Diary entry — " .. topic,
            body       = args.entry,
            importance = 0.5,
            metadata   = { agent = args.agent_name, topic = topic, diary = true },
        })
        if not row then return nil, err end
        return {
            success  = true,
            entry_id = row.id,
            agent    = args.agent_name,
            topic    = topic,
            scope    = scope,
        }
    end,
}

Tools.memory_diary_read = {
    description = "A named agent's latest diary entries, newest first.",
    inputSchema = {
        type       = "object",
        properties = {
            agent_name = { type = "string" },
            last_n = { type = "integer", minimum = 1, maximum = 50, description = "Default 10." },
        },
        required = { "agent_name" },
    },
    handler = function(args)
        ensure_setup()
        local name_err = validate_agent_name(args.agent_name)
        if name_err then return nil, name_err end
        local db_mod    = require("luamemo.db")
        local store_mod = require("luamemo.store")
        local scope  = "diary:" .. args.agent_name
        local limit  = math.max(1, math.min(math.floor(tonumber(args.last_n) or 10), 50))
        local rows, err = db_mod.query(
            "SELECT id, body, importance, metadata, created_at " ..
            "FROM " .. store_mod.table_name() .. " WHERE scope = ? " ..
            "ORDER BY created_at DESC, id DESC LIMIT ?",
            scope, limit)
        if not rows then return nil, err end
        local entries = {}
        for _, r in ipairs(rows) do
            local meta = (type(r.metadata) == "table") and r.metadata or {}
            entries[#entries + 1] = {
                entry_id  = r.id,
                timestamp = require("luamemo.util").us_to_iso(r.created_at),
                topic     = meta.topic or "general",
                content   = r.body,
            }
        end
        return { agent = args.agent_name, entries = list(entries), total = #entries, scope = scope }
    end,
}

-- ===========================================================================
-- Codebase map tools (index_*) — token-lean access to the code index.
-- Return compact text (`{ ok, text }`) instead of full rows so an agent spends
-- ~30 tokens locating code rather than reading files or parsing JSON.
-- ===========================================================================

-- The codeindex scope for an index_* call: explicit `scope`, else codeindex:<project> —
-- the `project` arg, else MEMO_SCOPE's project (luamemo.index.scope_for: memo index's rule).
local function index_scope(args) return require("luamemo.index").scope_for(args) end

-- The index_* tools' project / scope parameters.
local INDEX_PROJECT = { type = "string", description = "Default: this project." }
local INDEX_SCOPE   = { type = "string", description = "codeindex:<project>, instead of project." }

Tools.index_search = {
    description = "Find WHERE code lives in the codebase map (symbols, files, dependencies) — before "
        .. "grepping or reading files. Returns 'path:line name (type) — doc' lines. Needs `memo index ingest`.",
    inputSchema = {
        type       = "object",
        properties = {
            query   = { type = "string",  description = "Words or an identifier, e.g. 'where is dedup handled'." },
            project = INDEX_PROJECT,
            scope   = INDEX_SCOPE,
            kind    = { type = "string",  description = "symbol, file, dependency or diff." },
            limit   = { type = "integer", description = "Default 15.", minimum = 1, maximum = 50 },
        },
        required = { "query" },
    },
    handler = function(args)
        ensure_setup()
        local index = require("luamemo.index")
        local rows, err = index.search(args.query, {
            scope = index_scope(args),
            kind  = args.kind,
            limit = math.max(1, math.min(math.floor(tonumber(args.limit) or 15), 50)),
        })
        if not rows then return nil, err end
        return index.format.results(rows)   -- prose, sent as it is (no JSON escapes)
    end,
}

Tools.index_outline = {
    description = "Everything one file defines (names, lines, one-line docs) — instead of reading it "
        .. "whole. Read the file itself before editing it.",
    inputSchema = {
        type       = "object",
        properties = {
            path    = { type = "string", description = "Relative to the repository." },
            project = INDEX_PROJECT,
            scope   = INDEX_SCOPE,
        },
        required = { "path" },
    },
    handler = function(args)
        ensure_setup()
        local index = require("luamemo.index")
        local res, err = index.outline(args.path, { scope = index_scope(args) })
        if not res then return nil, err end
        return index.format.outline(res.file, res.symbols)
    end,
}

Tools.index_explore = {
    description = "A symbol's callers and callees (one hop) — what a change touches. Use before refactoring.",
    inputSchema = {
        type       = "object",
        properties = {
            query   = { type = "string",  description = "A symbol or concept, e.g. 'store.write'." },
            project = INDEX_PROJECT,
            scope   = INDEX_SCOPE,
            limit   = { type = "integer", description = "Matched symbols (default 10).", minimum = 1, maximum = 30 },
        },
        required = { "query" },
    },
    handler = function(args)
        ensure_setup()
        local index = require("luamemo.index")
        local res, err = index.explore(args.query, {
            scope = index_scope(args),
            limit = math.max(1, math.min(math.floor(tonumber(args.limit) or 10), 30)),
        })
        if not res then return nil, err end
        return index.format.explore(res)
    end,
}

Tools.index_status = {
    description = "Whether a codebase map exists for this project, and its size.",
    inputSchema = {
        type       = "object",
        properties = {
            project = INDEX_PROJECT,
            scope   = INDEX_SCOPE,
        },
    },
    handler = function(args)
        ensure_setup()
        local index = require("luamemo.index")
        local scope = index_scope(args)
        local counts, err = index.status({ scope = scope })
        if not counts then return nil, err end
        local total = (counts.file or 0) + (counts.symbol or 0)
            + (counts.dependency or 0) + (counts.diff or 0)
        local text
        if total == 0 then
            text = "No codebase map for " .. scope .. ". Build one with: memo index ingest"
        else
            text = ("codebase map %s — files=%d symbols=%d dependencies=%d diffs=%d"):format(
                scope, counts.file or 0, counts.symbol or 0,
                counts.dependency or 0, counts.diff or 0)
        end
        return text   -- the counts are in it (they were sent twice)
    end,
}

-- ===========================================================================
-- Prompts  (MCP prompts capability — session workflow guidance)
-- ===========================================================================
local Prompts = {}

Prompts.session_start = {
    description = "Load persistent memory context at the start of a session. "
        .. "Instructs the agent to search stored memories before starting work, "
        .. "write key decisions as it goes, and summarise at the end.",
    arguments = {
        {
            name        = "scope",
            description = "Memory scope to load (e.g. 'repo:myproject', 'global'). "
                .. "Defaults to MEMO_SCOPE env var.",
            required    = false,
        },
        {
            name        = "project",
            description = "Short project or task name used to focus the search query.",
            required    = false,
        },
    },
}

-- ===========================================================================
-- JSON-RPC framing
-- ===========================================================================
local function send(msg)
    -- Valid UTF-8 always: text stored by an earlier version (cut inside a character) or
    -- from elsewhere reaches the client with U+FFFD in place of a broken byte — a strict
    -- JSON reader refuses the whole message otherwise.
    local enc = util.fix_utf8(json.encode(msg))
    log("<<", enc)
    io.stdout:write(enc, "\n")
    io.stdout:flush()
end

-- A tool's result as the text the model reads. lua-cjson writes every "/" as "\/" (paths
-- and URLs cost a character each, for nothing); undone here. Only when the encoder
-- escapes all of them: then a "\" before "/" is always that escape (a "\" of the text is
-- "\\"), so nothing else changes. dkjson leaves "/" alone.
local ESCAPES_SLASH = json.encode("/") == '"\\/"'
local function encode_result(result)
    local text = json.encode(result)
    return ESCAPES_SLASH and (text:gsub("\\/", "/")) or text
end

-- ===========================================================================
-- MCP method handlers
-- ===========================================================================
local Methods = {}

local SERVER_INFO  = { name = SERVER_NAME, version = SERVER_VERSION }
local CAPABILITIES = { tools = {}, prompts = {} }
-- How long a client may keep tools/list, prompts/list, server/discover (modern caching
-- hints): they don't change while the process runs; an upgrade restarts it.
local CACHE_TTL_MS = 3600000

-- The legacy version this process speaks once a client sent initialize (nil before).
local legacy_version

-- Legacy handshake: the client's version when we speak it, else our newest legacy one
-- (the client then decides whether it can go on).
function Methods.initialize(params, _)
    params = params or {}
    local asked = params.protocolVersion
    legacy_version = member(LEGACY_VERSIONS, asked) and asked or LEGACY_VERSIONS[1]
    client_seen(params.clientInfo, legacy_version, params.capabilities)
    return {
        protocolVersion = legacy_version,
        serverInfo      = SERVER_INFO,
        capabilities    = CAPABILITIES,
        instructions    = INSTRUCTIONS,   -- since 2025-03-26; older clients ignore it
    }
end

-- Modern discovery (2026-07-28): versions, capabilities, identity, guidance.
Methods["server/discover"] = function(_, _)
    return {
        supportedVersions = SUPPORTED_VERSIONS,
        capabilities      = CAPABILITIES,
        instructions      = INSTRUCTIONS,
        ttlMs = CACHE_TTL_MS, cacheScope = "public",
    }
end

function Methods.ping(_, _)
    return {}
end

Methods["tools/list"] = function(_, _)
    local list  = {}
    local names = {}
    for name in pairs(Tools) do if offered(name) then names[#names + 1] = name end end
    table.sort(names)
    for _, name in ipairs(names) do
        local def = Tools[name]
        list[#list + 1] = {
            name        = name,
            description = def.description,
            inputSchema = def.inputSchema,
        }
    end
    return { tools = list }
end

-- A tool's arguments, checked against its own inputSchema before its handler runs: a
-- wrong-typed argument (an object as a scope, a number as a name, null as a required
-- field) was a Lua error inside the handler — a bare "Internal error" (720 wrong-typed
-- calls: 45 of them, in 9 tools). Now a tool error naming the argument. JSON null is an
-- absent argument; safe coercions: a number for a string, "5" for a number, "true" /
-- "false" for a boolean. Arguments the schema doesn't name are left alone.
-- A list or an object holds at most its schema's maxItems / maxProperties, else MAX_ENTRIES:
-- 10,000 scopes or metadata-filter keys overran LuaJIT's unpack / SQLite's expression depth.
local MAX_ENTRIES = 200
local function entries(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function is_list(t) return entries(t) == #t end   -- (an empty table is either)
local function check_value(name, v, spec)
    if type(v) == "table" and entries(v) > (spec.maxItems or spec.maxProperties or MAX_ENTRIES) then
        return nil, ("%s holds at most %d entries"):format(name, spec.maxItems or spec.maxProperties or MAX_ENTRIES)
    end
    local ty = spec.type
    if ty == "string" then
        if type(v) == "number" then v = tostring(v) end
        if type(v) ~= "string" then return nil, name .. " must be a string" end
    elseif ty == "integer" or ty == "number" then
        local n = (type(v) == "number" or type(v) == "string") and tonumber(v) or nil
        if not n then return nil, name .. " must be a number" end
        if ty == "integer" and n ~= math.floor(n) then return nil, name .. " must be a whole number" end
        v = n
    elseif ty == "boolean" then
        if v == "true" then v = true elseif v == "false" then v = false end
        if type(v) ~= "boolean" then return nil, name .. " must be true or false" end
    elseif (ty == "object" or ty == "array") and type(v) == "string" then
        return v   -- JSON text: the handler parses it, as it always did (metadata, scopes, …)
    elseif ty == "object" then
        if type(v) ~= "table" or (next(v) ~= nil and is_list(v)) then return nil, name .. " must be an object" end
    elseif ty == "array" then
        if type(v) ~= "table" or not is_list(v) then return nil, name .. " must be a list" end
        if (spec.items or {}).type == "string" then
            for i, e in ipairs(v) do
                if type(e) == "number" then v[i] = tostring(e)
                elseif type(e) ~= "string" then return nil, name .. " must be a list of strings" end
            end
        end
    end
    if spec.enum then
        for _, e in ipairs(spec.enum) do if e == v then return v end end
        return nil, name .. " must be one of: " .. table.concat(spec.enum, ", ")
    end
    return v
end
local function check_args(def, args)
    local schema = def.inputSchema or {}
    for k, v in pairs(args) do if v == json.null then args[k] = nil end end
    for k, spec in pairs(schema.properties or {}) do
        if args[k] ~= nil then
            local v, err = check_value(k, args[k], spec)
            if err then return err end
            args[k] = v
        end
    end
    for _, r in ipairs(schema.required or {}) do
        if args[r] == nil then return r .. " is required" end
    end
end

Methods["tools/call"] = function(params, _)
    local name = params and params.name
    local args = (params and params.arguments) or {}
    local def = name and Tools[name]
    if not def then
        return nil, { code = -32601, message = "Unknown tool: " .. tostring(name) }
    end
    if not offered(name) then
        return { isError = true, content = { { type = "text", text = name .. " isn't offered here "
            .. "(MEMO_MCP_TOOLS=core): run it with memo, or set MEMO_MCP_TOOLS=all (memo config set)." } } }
    end
    local bad = type(args) ~= "table" and "arguments must be an object" or check_args(def, args)
    if bad then
        return { isError = true, content = { { type = "text", text = "Error: " .. bad } } }
    end
    -- No database configured: every tool says what to do (the client shows it).
    local unconfigured = not_configured()
    if unconfigured then
        return { isError = true, content = { { type = "text", text = unconfigured } } }
    end

    local result, err = def.handler(args)
    if not result then
        return {
            isError = true,
            content = { { type = "text", text = "Error: " .. tostring(err) } },
        }
    end

    -- A tool that answers in prose (memory_brief, index_*) returns a string: sent as it is.
    local text = type(result) == "string" and result or encode_result(result)
    return {
        isError = false,
        content = { { type = "text", text = text } },
    }
end

Methods["prompts/list"] = function(_, _)
    local list  = {}
    local names = {}
    for name in pairs(Prompts) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local def   = Prompts[name]
        local entry = { name = name, description = def.description }
        if def.arguments then entry.arguments = def.arguments end
        list[#list + 1] = entry
    end
    return { prompts = list }
end

Methods["prompts/get"] = function(params, _)
    local name = params and params.name
    local args = (params and params.arguments) or {}
    if not (name and Prompts[name]) then
        return nil, { code = -32602, message = "Unknown prompt: " .. tostring(name) }
    end

    local scope   = args.scope   or MEMO_SCOPE or "global"
    local project = args.project or scope

    -- Fetch KG ground-truth facts for the scope (best-effort; fails silently).
    local kg_section = ""
    local ok, kg = pcall(require, "luamemo.kg")
    if ok then
        ensure_setup()
        local facts, _ = kg.query({ scope = scope, limit = 20 })
        if facts and type(facts) == "table" and #facts > 0 then
            local lines = {
                "",
                "Ground truth facts (knowledge graph — treat as authoritative):",
            }
            for _, f in ipairs(facts) do
                local line = string.format("- %s %s %s",
                    tostring(f.subject   or "?"),
                    tostring(f.predicate or "?"),
                    tostring(f.object    or "?"))
                if f.valid_from then
                    line = line .. " [since " .. tostring(f.valid_from):sub(1, 10) .. "]"
                end
                table.insert(lines, line)
            end
            kg_section = table.concat(lines, "\n")
        end
    end

    local text = table.concat({
        "You are starting a new working session. Before doing anything else:",
        "",
        "1. Call memory_search with query=\"recent decisions and context\" "
            .. "and scope=\"" .. scope .. "\" to reload what was decided in previous sessions.",
        "2. Call memory_recent with scope=\"" .. scope .. "\" and limit=10 "
            .. "to see the latest stored memories.",
        "",
        "As you work:",
        "- Call memory_write whenever you make an architectural decision, fix a bug root-cause, "
            .. "choose a design pattern, or establish any fact that should survive to the next session.",
        "- Use kind=\"decision\" for choices made, kind=\"fact\" for established truths, "
            .. "kind=\"plan\" for future work.",
        "- Set importance 3-7 for things that matter; leave the default (1) for routine notes.",
        "",
        "At the end of the session:",
        "- Call memory_write with a brief session summary: what was done, what was decided, what is next.",
        "- If working in a temporary scope (e.g. session:<id>), call memory_promote to "
            .. "roll it into a long-term scope so the next session can find it.",
        "",
        "Security guidance — secrets:",
        "- If the user needs to store an API key or token, do NOT ask them to type it in chat.",
        "- Instead, instruct them to run in their terminal:",
        "    memo secret-store NAME --desc 'description'",
        "  This prompts for the value with no echo, keeping it out of the LLM context entirely.",
        "- You can then use secret_execute to make authenticated HTTP requests "
            .. "with {secret} substituted server-side — the raw value never enters chat.",
        "- Proactively mention this workflow whenever the user discusses API keys, tokens, "
            .. "passwords, or any credential they might need the agent to use.",
        "",
        "Scope for this session: " .. scope,
        "Project: "              .. project,
        kg_section,
    }, "\n")

    return {
        description = Prompts[name].description,
        messages = {
            { role = "user", content = { type = "text", text = text } },
        },
    }
end

-- Notifications (no response)
local Notifications = {}
Notifications["notifications/initialized"] = function() log("client initialized") end
Notifications["notifications/cancelled"]   = function() end

-- ===========================================================================
-- Main loop
-- ===========================================================================
-- Results that carry caching hints in the modern protocol.
local CACHEABLE = { ["server/discover"] = true, ["tools/list"] = true, ["prompts/list"] = true }

local function err_response(id, code, message, data)
    local e = { code = code, message = message }
    if data ~= nil then e.data = data end
    return { jsonrpc = "2.0", id = id, error = e }
end

--- One message → its response (nil for a notification). The protocol version is the
--- request's own (_meta, modern) or else the one initialize picked (legacy); a modern
--- result says it is complete and who answered.
local function handle(msg)
    if type(msg) ~= "table" then
        return err_response(json.null, -32600, "Invalid Request")
    end
    local method, id, params = msg.method, msg.id, msg.params
    if id == nil then
        local nh = Notifications[method]
        if nh then nh(params) end
        return nil
    end

    local meta = type(params) == "table" and type(params._meta) == "table" and params._meta or nil
    local version = meta and meta[META .. "protocolVersion"]
    local modern = false
    if method ~= "initialize" and version ~= nil then
        if not member(SUPPORTED_VERSIONS, version) then
            return err_response(id, -32022, "Unsupported protocol version",
                { supported = SUPPORTED_VERSIONS, requested = version })
        end
        modern = member(MODERN_VERSIONS, version)
        if modern then
            if type(meta[META .. "clientCapabilities"]) ~= "table" then
                return err_response(id, -32602, "Invalid params: _meta is missing \""
                    .. META .. "clientCapabilities\"")
            end
            client_seen(meta[META .. "clientInfo"], version, meta[META .. "clientCapabilities"])
        end
    elseif method == "server/discover" then
        return err_response(id, -32602, "Invalid params: _meta is missing \"" .. META .. "protocolVersion\"")
    end

    local handler = Methods[method]
    if not handler then
        return err_response(id, -32601, "Method not found: " .. tostring(method))
    end
    local ok, result, err = pcall(handler, params, msg)
    if not ok then
        return err_response(id, -32603, "Internal error: " .. tostring(result))
    end
    if err then
        return err_response(id, err.code or -32603, err.message or "error", err.data)
    end
    if modern then
        result.resultType = result.resultType or "complete"
        result._meta = result._meta or {}
        result._meta[META .. "serverInfo"] = SERVER_INFO
        if CACHEABLE[method] and result.ttlMs == nil then
            result.ttlMs, result.cacheScope = CACHE_TTL_MS, "public"
        end
    end
    return { jsonrpc = "2.0", id = id, result = result }
end

local function dispatch(line)
    local msg, derr = json.decode(line)
    if msg == nil then
        log("decode error:", derr, "line:", line)
        return send(err_response(json.null, -32700, "Parse error"))
    end
    log(">>", line)
    -- A JSON-RPC batch (2025-03-26 clients may send one): the answers, as one array.
    if type(msg) == "table" and msg[1] ~= nil and msg.jsonrpc == nil then
        local out = {}
        for _, m in ipairs(msg) do
            local r = handle(m)
            if r then out[#out + 1] = r end
        end
        if #out > 0 then send(out) end
        return
    end
    local r = handle(msg)
    if r then send(r) end
end

local function main()
    local db_path, db_err = require("luamemo.db").path()
    if not db_path then
        io.stderr:write("[luamemo-mcp] WARNING: " .. tostring(db_err) .. "\n")
        io.stderr:flush()
    end
    log("started"
        .. (db_path and (" database=" .. db_path) or "")
        .. (MEMO_SCOPE  and (" MEMO_SCOPE=" .. MEMO_SCOPE)  or ""))

    while true do
        local line = io.read("*l")
        if not line then break end
        if line ~= "" then
            -- One message that raises (outside a tool handler, which answers -32603 itself)
            -- must not end the server: the client's later calls would go unanswered.
            local ok, err = pcall(dispatch, line)
            if not ok then
                log("dispatch error:", err)
                pcall(send, err_response(json.null, -32603, "Internal error"))
            end
        end
    end
    log("stdin closed; exiting")
end

main()
