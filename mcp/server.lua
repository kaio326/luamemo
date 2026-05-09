#!/usr/bin/env lua
-- luamemo MCP stdio server (pure Lua, single-file)
--
-- Implements the Model Context Protocol (https://modelcontextprotocol.io/)
-- stdio transport: newline-delimited JSON-RPC 2.0 over stdin/stdout. Connects
-- directly to PostgreSQL via pgmoon — no HTTP intermediary required.
--
-- Configuration (env vars)
-- ------------------------
--   MEMO_DB_URL       REQUIRED  PostgreSQL connection URL,
--                               e.g. postgresql://user:pass@localhost:5432/luamemo
--                               (Individual PG* vars also accepted; see luamemo.db)
--   MEMO_SCOPE        optional  Default scope applied when a tool call omits it
--   MEMO_SECRETS_FILE optional  Path to the JSON secrets file
--   MEMO_MASTER_KEY   optional  64-hex-char master key for the secrets module
--   MEMO_DEBUG        optional  If "1", logs raw JSON-RPC frames to stderr
--
-- Run manually for testing:
--   echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
--     | MEMO_DB_URL=postgresql://postgres:@127.0.0.1:5432/luamemo lua mcp/server.lua

local cjson = require("cjson.safe")
local util  = require("luamemo.util")

math.randomseed(os.time() + math.floor(os.clock() * 1e6))

-- ===========================================================================
-- Config
-- ===========================================================================
local MEMO_DB_URL = os.getenv("MEMO_DB_URL")
local MEMO_SCOPE  = os.getenv("MEMO_SCOPE")
local DEBUG       = os.getenv("MEMO_DEBUG") == "1"

local PROTOCOL_VERSION = "2024-11-05"
local SERVER_NAME      = "luamemo"
local SERVER_VERSION   = "0.2.5"

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
local function ensure_setup()
    if _setup_done then return end
    _setup_done = true
    local ok, luamemo = pcall(require, "luamemo")
    if not ok then
        fatal("luamemo library not found — install via: luarocks install luamemo\n" .. tostring(luamemo))
    end
    local cfg = {
        embedder_local = os.getenv("MEMO_EMBEDDER") or "hash",
    }
    if MEMO_DB_URL and MEMO_DB_URL ~= "" then cfg.db_url = MEMO_DB_URL end
    local master_key = os.getenv("MEMO_MASTER_KEY")
    if master_key and master_key ~= "" then cfg.master_key = master_key end
    local secrets_file = os.getenv("MEMO_SECRETS_FILE")
    if secrets_file and secrets_file ~= "" then cfg.secrets_file = secrets_file end
    local pok, perr = pcall(luamemo.setup, cfg)
    if not pok then
        io.stderr:write("[luamemo-mcp] setup warning: " .. tostring(perr) .. "\n")
    end
end

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

local Tools = {}

Tools.memory_write = {
    description = "Store a new memory in the persistent vector store. "
        .. "Call this whenever you make an architectural decision, resolve a bug, "
        .. "choose a design pattern, or establish any fact that should survive to "
        .. "the next session. Also call at the end of a session to write a brief "
        .. "summary of what was done and what comes next.",
    inputSchema = {
        type = "object",
        properties = {
            scope    = { type = "string", description = "Bucket: 'global', 'repo:<name>', 'session:<id>', or custom." },
            kind     = { type = "string", description = "One of: decision | fact | plan | snippet | (custom)." },
            title    = { type = "string", description = "Short label for the memory." },
            body     = { type = "string", description = "Full content; this is what gets embedded and searched." },
            tags     = { type = "array", items = { type = "string" }, description = "Optional tags." },
            metadata = { type = "object", description = "Arbitrary structured metadata." },
            importance = {
                type = "number", minimum = 0, maximum = 10,
                description = "Search-ranking weight (0..10). Higher = more pull. Default 1.0.",
            },
            decay_rate = {
                type = "number", minimum = 0, maximum = 1,
                description = "Per-day exponential decay (0..1). 0 disables decay. Default 0.0.",
            },
            dedup_strategy = {
                type = "string", enum = { "update", "skip", "append" },
                description = "Override per-call dedup behaviour. 'update' (default) merges a near-duplicate; 'skip' returns the existing row unchanged; 'append' forces a new row.",
            },
        },
        required = { "title", "body" },
    },
    handler = function(args)
        ensure_setup()
        local store = require("luamemo.store")
        local row, err, action = store.write(with_default_scope({
            scope          = args.scope,
            kind           = args.kind,
            title          = args.title,
            body           = args.body,
            tags           = args.tags,
            metadata       = args.metadata,
            importance     = tonumber(args.importance),
            decay_rate     = tonumber(args.decay_rate),
            dedup_strategy = args.dedup_strategy,
        }))
        if not row then return nil, err end
        return { ok = true, memory = row, action = action }
    end,
}

Tools.memory_search = {
    description = "Hybrid search (vector + full-text) across stored memories. "
        .. "Returns top-K matches ordered by blended score, weighted by each "
        .. "memory's importance and time-decay. "
        .. "CALL THIS AT THE START OF EVERY SESSION with a broad query such as "
        .. "'recent decisions and context' to reload what was decided in prior "
        .. "sessions before starting any work.",
    inputSchema = {
        type = "object",
        properties = {
            query = { type = "string", description = "Natural-language query." },
            scope = { type = "string", description = "Restrict to a scope." },
            kind  = { type = "string", description = "Restrict to a kind." },
            limit = { type = "integer", description = "Max results (default 10).", minimum = 1, maximum = 100 },
            ignore_decay = {
                type = "boolean",
                description = "If true, bypass importance/decay weighting and rank purely by hybrid similarity (debug aid).",
            },
            since = {
                type = "string",
                description = "Only return memories with updated_at >= this bound. Accepts an ISO 8601 date (YYYY-MM-DD) or full RFC3339 timestamp.",
            },
            ["until"] = {
                type = "string",
                description = "Only return memories with updated_at < this bound. Half-open interval [since, until).",
            },
        },
        required = { "query" },
    },
    handler = function(args)
        ensure_setup()
        local store = require("luamemo.store")
        local scope = args.scope or MEMO_SCOPE
        local rows, err = store.search({
            query        = args.query,
            scope        = scope,
            kind         = args.kind,
            limit        = tonumber(args.limit),
            ignore_decay = to_bool(args.ignore_decay),
            since        = args.since,
            ["until"]    = args["until"],
        })
        if not rows then return nil, err end
        return { ok = true, results = rows }
    end,
}

Tools.memory_recent = {
    description = "List the most recently created memories in a scope. "
        .. "Use at session start alongside memory_search to quickly orient "
        .. "yourself on the latest stored context.",
    inputSchema = {
        type = "object",
        properties = {
            scope = { type = "string" },
            limit = { type = "integer", minimum = 1, maximum = 200 },
        },
    },
    handler = function(args)
        ensure_setup()
        local store = require("luamemo.store")
        local scope = args.scope or MEMO_SCOPE
        local rows, err = store.recent({
            scope = scope,
            limit = tonumber(args.limit),
        })
        if not rows then return nil, err end
        return { ok = true, results = rows }
    end,
}

Tools.memory_get = {
    description = "Fetch a single memory by its numeric ID.",
    inputSchema = {
        type = "object",
        properties = { id = { type = "integer" } },
        required = { "id" },
    },
    handler = function(args)
        ensure_setup()
        local store = require("luamemo.store")
        local row, err = store.get(tonumber(args.id))
        if not row then return nil, err end
        return { ok = true, memory = row }
    end,
}

Tools.memory_update = {
    description = "Update fields of an existing memory by ID. Re-embeds if "
        .. "title or body changed.",
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
            importance = {
                type = "number", minimum = 0, maximum = 10,
                description = "Search-ranking weight (0..10).",
            },
            decay_rate = {
                type = "number", minimum = 0, maximum = 1,
                description = "Per-day exponential decay (0..1).",
            },
        },
        required = { "id" },
    },
    handler = function(args)
        ensure_setup()
        local store = require("luamemo.store")
        local id = tonumber(args.id)
        local row, err = store.update(id, {
            title      = args.title,
            body       = args.body,
            tags       = args.tags,
            metadata   = args.metadata,
            importance = tonumber(args.importance),
            decay_rate = tonumber(args.decay_rate),
            kind       = args.kind,
            scope      = args.scope,
        })
        if not row then return nil, err end
        return { ok = true, memory = row }
    end,
}

Tools.memory_delete = {
    description = "Permanently delete a memory by ID.",
    inputSchema = {
        type = "object",
        properties = { id = { type = "integer" } },
        required = { "id" },
    },
    handler = function(args)
        ensure_setup()
        local store = require("luamemo.store")
        local ok, err = store.delete(tonumber(args.id))
        if not ok then return nil, err end
        return { ok = true }
    end,
}

Tools.memory_promote = {
    description = "Roll all memories from a session scope into a single "
        .. "summary in a long-term scope. Call this at end of session to "
        .. "promote `session:<uuid>` rows into `user:<id>:long_term` so "
        .. "the next session can find them. Solves the 'memory loss when "
        .. "session changes' problem.",
    inputSchema = {
        type = "object",
        properties = {
            from_scope = {
                type = "string",
                description = "Source scope, e.g. 'session:abc123'.",
            },
            to_scope = {
                type = "string",
                description = "Target scope, e.g. 'user:42:long_term'. Must differ from from_scope.",
            },
            delete_source = {
                type = "boolean",
                description = "If true, hard-delete source rows after summary is written. Default false.",
            },
            dry_run = {
                type = "boolean",
                description = "If true, report what would happen without writing. Default false.",
            },
            limit = {
                type = "integer", minimum = 1, maximum = 1000,
                description = "Max source rows to fold (default 200).",
            },
            min_rows = {
                type = "integer", minimum = 1,
                description = "Bail with reason='no_rows' if source has fewer rows (default 1).",
            },
        },
        required = { "from_scope", "to_scope" },
    },
    handler = function(args)
        ensure_setup()
        local summarizer = require("luamemo.summarizer")
        local result, err = summarizer.promote({
            from_scope    = args.from_scope,
            to_scope      = args.to_scope,
            delete_source = to_bool(args.delete_source),
            dry_run       = to_bool(args.dry_run),
            limit         = tonumber(args.limit),
            min_rows      = tonumber(args.min_rows),
        })
        if not result then return nil, err end
        local ok_flag = (result.promoted == 1 or result.reason == "no_rows")
        return { ok = ok_flag, result = result }
    end,
}

Tools.memory_consolidate = {
    description = "Maintenance: expire fully-decayed memories, detect near-duplicate clusters, "
        .. "and optionally merge them via the configured summarizer. "
        .. "Run periodically to keep the store compact and retrieval quality high. "
        .. "With dry_run=true, reports what would change without modifying anything.",
    inputSchema = {
        type = "object",
        properties = {
            scope = { type = "string", description = "Scope to consolidate. Omit to consolidate all scopes." },
            dry_run = {
                type = "boolean",
                description = "Report changes without applying them (default false).",
            },
            similarity_threshold = {
                type = "number", minimum = 0.5, maximum = 1.0,
                description = "Cosine similarity above which two memories are near-duplicates (default 0.85).",
            },
            decay_threshold = {
                type = "number", minimum = 0, maximum = 1,
                description = "Effective importance below which a decayed memory is expired (default 0.05).",
            },
            max_rows = {
                type = "integer", minimum = 1, maximum = 5000,
                description = "Max memories to inspect per run (default 500).",
            },
        },
    },
    handler = function(args)
        ensure_setup()
        local summarizer = require("luamemo.summarizer")
        local result, err = summarizer.consolidate({
            scope                = args.scope,
            dry_run              = to_bool(args.dry_run),
            similarity_threshold = tonumber(args.similarity_threshold),
            decay_threshold      = tonumber(args.decay_threshold),
            max_rows             = tonumber(args.max_rows),
        })
        if not result then return nil, err end
        return { ok = true, result = result }
    end,
}

-- ===========================================================================
-- Secrets tools
-- ===========================================================================

Tools.secret_list = {
    description = "List all stored secrets (names and metadata only). "
        .. "Secret VALUES are never returned. Use secret_store to add a secret, "
        .. "secret_execute to use one, and secret_delete to remove one.",
    inputSchema = {
        type       = "object",
        properties = {},
    },
    handler = function(_)
        ensure_setup()
        local secrets = require("luamemo.secrets")
        if not secrets.enabled() then
            return nil, "secrets: not configured (secrets_file or master_key not set)"
        end
        local rows = secrets.list()
        return { ok = true, secrets = rows }
    end,
}

Tools.secret_store = {
    description = "Store (create or replace) an encrypted secret by name. "
        .. "The value is AES-256-CBC encrypted before writing; it can never "
        .. "be retrieved — only used via secret_execute. Requires the server "
        .. "to be configured with a master_key.",
    inputSchema = {
        type = "object",
        properties = {
            name = {
                type        = "string",
                description = "Unique identifier. Alphanumeric, hyphens, underscores, and dots; max 128 chars.",
            },
            value = {
                type        = "string",
                description = "The plaintext secret value (API key, token, password, …).",
            },
            description = {
                type        = "string",
                description = "Optional human-readable description (stored in plaintext alongside the ciphertext).",
            },
        },
        required = { "name", "value" },
    },
    handler = function(args)
        ensure_setup()
        local secrets = require("luamemo.secrets")
        if not secrets.enabled() then
            return nil, "secrets: not configured (secrets_file or master_key not set)"
        end
        if not args.name or args.name == "" then return nil, "name is required" end
        if not args.value or args.value == "" then return nil, "value is required" end
        local row, err = secrets.store(args.name, args.value, args.description)
        if not row then return nil, err end
        return { ok = true, secret = row }
    end,
}

Tools.secret_delete = {
    description = "Permanently delete a stored secret by name.",
    inputSchema = {
        type = "object",
        properties = {
            name = { type = "string", description = "Secret name to delete." },
        },
        required = { "name" },
    },
    handler = function(args)
        ensure_setup()
        local secrets = require("luamemo.secrets")
        local ok, err = secrets.delete(tostring(args.name))
        if not ok then return nil, err end
        return { ok = true }
    end,
}

Tools.secret_execute = {
    description = "Execute an HTTP request with a stored secret substituted "
        .. "server-side. Write {secret} anywhere in the url, header values, "
        .. "or body — the server replaces it with the decrypted value before "
        .. "making the request. Only the response body is returned; the raw "
        .. "secret NEVER appears in the tool result. "
        .. "For multipart/form-data uploads (e.g. file uploads to an API), "
        .. "use the multipart field instead of body.",
    inputSchema = {
        type = "object",
        properties = {
            name = {
                type        = "string",
                description = "Secret name to use.",
            },
            url = {
                type        = "string",
                description = "Request URL. May contain {secret}, e.g. 'https://api.example.com/1/{secret}/upload'.",
            },
            method = {
                type        = "string",
                enum        = { "GET", "POST", "PUT", "PATCH", "DELETE" },
                description = "HTTP method (default GET, or POST when multipart is set).",
            },
            headers = {
                type        = "object",
                description = "Header map. Any value may contain {secret}, e.g. { Authorization = 'Bearer {secret}' }.",
            },
            body = {
                type        = "string",
                description = "Request body string. May contain {secret}. Mutually exclusive with multipart.",
            },
            multipart = {
                type        = "object",
                description = "Multipart/form-data fields. Each key is a field name. "
                    .. "String values are plain fields (may contain {secret}). "
                    .. "File fields must be objects: { file = '/absolute/path', content_type? = '...' }. "
                    .. "Mutually exclusive with body.",
                additionalProperties = true,
            },
            timeout_ms = {
                type        = "integer",
                description = "Request timeout in milliseconds (default 10000).",
                minimum     = 100,
                maximum     = 120000,
            },
        },
        required = { "name", "url" },
    },
    handler = function(args)
        ensure_setup()
        local secrets = require("luamemo.secrets")
        local name = tostring(args.name)
        local body, err = secrets.execute_with_secret(name, {
            url        = args.url,
            method     = args.method,
            headers    = args.headers,
            body       = args.body,
            multipart  = args.multipart,
            timeout_ms = tonumber(args.timeout_ms),
        })
        if not body then return nil, err end
        return { ok = true, response = body }
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
    local enc = cjson.encode(msg)
    log("<<", enc)
    io.stdout:write(enc, "\n")
    io.stdout:flush()
end

local function reply_result(id, result)
    send({ jsonrpc = "2.0", id = id, result = result })
end

local function reply_error(id, code, message, data)
    local err = { code = code, message = message }
    if data then err.data = data end
    send({ jsonrpc = "2.0", id = id, error = err })
end

-- ===========================================================================
-- MCP method handlers
-- ===========================================================================
local Methods = {}

function Methods.initialize(_, _)
    return {
        protocolVersion = PROTOCOL_VERSION,
        serverInfo = {
            name    = SERVER_NAME,
            version = SERVER_VERSION,
        },
        capabilities = {
            tools   = {},
            prompts = {},
        },
    }
end

function Methods.ping(_, _)
    return {}
end

Methods["tools/list"] = function(_, _)
    local list  = {}
    local names = {}
    for name in pairs(Tools) do names[#names + 1] = name end
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

Methods["tools/call"] = function(params, _)
    local name = params and params.name
    local args = (params and params.arguments) or {}
    local def = name and Tools[name]
    if not def then
        return nil, { code = -32601, message = "Unknown tool: " .. tostring(name) }
    end

    local result, err = def.handler(args)
    if not result then
        return {
            isError = true,
            content = { { type = "text", text = "Error: " .. tostring(err) } },
        }
    end

    local pretty = cjson.encode(result)
    return {
        isError = false,
        content = { { type = "text", text = pretty } },
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
local function dispatch(line)
    local msg, derr = cjson.decode(line)
    if not msg then
        log("decode error:", derr, "line:", line)
        return
    end

    log(">>", line)

    local method = msg.method
    local id     = msg.id
    local params = msg.params

    if id == nil then
        local nh = Notifications[method]
        if nh then nh(params) end
        return
    end

    local handler = Methods[method]
    if not handler then
        return reply_error(id, -32601, "Method not found: " .. tostring(method))
    end

    local ok, result, err = pcall(handler, params, msg)
    if not ok then
        return reply_error(id, -32603, "Internal error: " .. tostring(result))
    end
    if err then
        return reply_error(id, err.code or -32603, err.message or "error", err.data)
    end
    reply_result(id, result)
end

local function main()
    local have_db = (MEMO_DB_URL and MEMO_DB_URL ~= "")
        or os.getenv("PGHOST") or os.getenv("PGDATABASE")
    if not have_db then
        io.stderr:write("[luamemo-mcp] WARNING: no database config found. "
            .. "Set MEMO_DB_URL=postgresql://user:pass@host:5432/db "
            .. "or individual PGHOST/PGDATABASE/PGUSER/PGPASSWORD env vars.\n")
        io.stderr:flush()
    end
    local db_display = MEMO_DB_URL
        and MEMO_DB_URL:gsub(":[^:@]+@", ":***@")  -- redact password from URL
        or nil
    log("started"
        .. (db_display and (" MEMO_DB_URL=" .. db_display) or "")
        .. (MEMO_SCOPE  and (" MEMO_SCOPE=" .. MEMO_SCOPE)  or ""))

    while true do
        local line = io.read("*l")
        if not line then break end
        if line ~= "" then dispatch(line) end
    end
    log("stdin closed; exiting")
end

main()
