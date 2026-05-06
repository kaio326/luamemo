#!/usr/bin/env lua
-- luamemo MCP stdio server (pure Lua, single-file)
--
-- Implements the Model Context Protocol (https://modelcontextprotocol.io/)
-- stdio transport: newline-delimited JSON-RPC 2.0 over stdin/stdout. Bridges
-- MCP clients (Claude Desktop, Cursor, Continue.dev, Copilot Agent Mode,
-- ...) to a running luamemo HTTP API.
--
-- Lua-First Policy
-- ----------------
-- This file is 100% Lua except for the HTTP transport, which shells out to
-- `curl` (see `http_request` below). See LIMITATION block there for the
-- reason and a future-work pointer.
--
-- Configuration (env vars)
-- ------------------------
--   MEMO_URL     REQUIRED  Base URL of the luamemo HTTP API,
--                          e.g. https://app.example.com/api/memory
--   MEMO_TOKEN   optional  Bearer token sent as Authorization header
--   MEMO_SCOPE   optional  Default scope applied when a tool call omits it
--   MEMO_DEBUG   optional  If "1", logs raw JSON-RPC frames to stderr
--
-- Run manually for testing:
--   echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
--     | MEMO_URL=http://localhost:8080/api/memory lua mcp/server.lua

local cjson = require("cjson.safe")

-- Seed the PRNG once at startup.  Seeding inside a function (as was done
-- previously) resets the sequence on every call; two requests within the
-- same second would produce identical temp filenames.
math.randomseed(os.time() + math.floor(os.clock() * 1e6))

-- ===========================================================================
-- Config
-- ===========================================================================
local MEMO_URL   = os.getenv("MEMO_URL")
local MEMO_TOKEN = os.getenv("MEMO_TOKEN")
local MEMO_SCOPE = os.getenv("MEMO_SCOPE")
local DEBUG      = os.getenv("MEMO_DEBUG") == "1"

local PROTOCOL_VERSION = "2024-11-05"
local SERVER_NAME      = "luamemo"
local SERVER_VERSION   = "0.2.0"

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
-- HTTP transport
-- ===========================================================================
-- LIMITATION (Lua-First exception): There is no ubiquitous, dependency-free,
-- pure-Lua HTTPS client suitable for a self-contained CLI. Options reviewed:
--   * lua-resty-http  -- requires OpenResty cosocket; not available outside
--                        nginx workers.
--   * lua-socket + lua-sec  -- requires LuaSocket and LuaSec rocks; LuaSec
--                              additionally requires OpenSSL headers at
--                              install time. Not safe to assume on user
--                              laptops where MCP clients run.
--   * lua-http  -- requires LuaJIT or Lua 5.3+ and several rocks.
--
-- Until a "lua-http-mini" library exists that ships as a single file with
-- no native deps and supports HTTPS, this server shells out to `curl`,
-- which is preinstalled on macOS, Linux, and modern Windows. When such a
-- library is built, replace `http_request()` with a pure-Lua call and
-- delete this comment.
-- ---------------------------------------------------------------------------

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- query: table of { key=value } pairs to URL-encode
local function urlencode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function build_query(tbl)
    if not tbl or not next(tbl) then return "" end
    local parts = {}
    for k, v in pairs(tbl) do
        if v ~= nil then
            parts[#parts + 1] = urlencode(k) .. "=" .. urlencode(v)
        end
    end
    if #parts == 0 then return "" end
    return "?" .. table.concat(parts, "&")
end

--- Make an HTTP request via curl.
-- @param method "GET" | "POST"
-- @param path   string  appended to MEMO_URL
-- @param query  table|nil  query params
-- @param body   table|nil  JSON body
-- @return decoded_body table | nil
-- @return err          string | nil
local function http_request(method, path, query, body)
    if not MEMO_URL then
        return nil, "MEMO_URL env var is not set"
    end

    local url = MEMO_URL .. path .. build_query(query)
    local cmd = { "curl", "-sS", "-X", method, "-H", "Accept: application/json" }
    if MEMO_TOKEN and MEMO_TOKEN ~= "" then
        table.insert(cmd, "-H")
        table.insert(cmd, "Authorization: Bearer " .. MEMO_TOKEN)
    end

    -- Lua's stock io.popen is unidirectional, so when there is a body we
    -- materialize it to a temp file and pass it to curl with --data-binary @file.
    local tmpname
    if body then
        -- Build the temp path ourselves instead of using os.tmpname() to
        -- avoid the TOCTOU window between os.tmpname() returning a path and
        -- io.open() creating the file (a local attacker could plant a symlink
        -- in that window on world-writable /tmp).
        local tmpdir = os.getenv("TMPDIR") or "/tmp"
        tmpname = tmpdir .. "/lm_mcp_"
            .. tostring(os.time()) .. "_"
            .. tostring(math.random(100000000, 999999999)) .. ".json"
        local tmpf, terr = io.open(tmpname, "wb")
        if not tmpf then return nil, "tempfile: " .. tostring(terr) end
        tmpf:write(cjson.encode(body))
        tmpf:close()
        table.insert(cmd, "-H")
        table.insert(cmd, "Content-Type: application/json")
        table.insert(cmd, "--data-binary")
        table.insert(cmd, "@" .. tmpname)
    end
    table.insert(cmd, url)

    local quoted = {}
    for _, arg in ipairs(cmd) do quoted[#quoted + 1] = shell_quote(arg) end
    local shell_cmd = table.concat(quoted, " ") .. " 2>/dev/null"

    log("HTTP " .. method .. " " .. url)

    local rh, rerr = io.popen(shell_cmd, "r")
    if not rh then
        if tmpname then os.remove(tmpname) end
        return nil, "popen failed: " .. tostring(rerr)
    end
    local resp = rh:read("*a")
    rh:close()
    if tmpname then os.remove(tmpname) end

    if not resp or resp == "" then
        return nil, "empty response from server"
    end

    local decoded, derr = cjson.decode(resp)
    if not decoded then
        return nil, "invalid JSON response: " .. tostring(derr)
            .. " (raw: " .. resp:sub(1, 200) .. ")"
    end
    return decoded
end

-- ===========================================================================
-- Tool implementations (1:1 with HTTP API)
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
        .. "Use this to record decisions, facts, plans, or snippets the "
        .. "agent should remember across sessions.",
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
        return http_request("POST", "/write", nil, with_default_scope(args))
    end,
}

Tools.memory_search = {
    description = "Hybrid search (vector + full-text) across stored memories. "
        .. "Returns top-K matches ordered by blended score, weighted by each "
        .. "memory's importance and time-decay.",
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
                description = "Only return memories with updated_at >= this bound. Accepts an ISO 8601 date (YYYY-MM-DD) or full RFC3339 timestamp. Use to ask 'what did we discuss this week' instead of all-time.",
            },
            ["until"] = {
                type = "string",
                description = "Only return memories with updated_at < this bound. Same format as since. Half-open interval semantics: [since, until).",
            },
        },
        required = { "query" },
    },
    handler = function(args)
        local q = { q = args.query }
        if args.scope then q.scope = args.scope
        elseif MEMO_SCOPE then q.scope = MEMO_SCOPE end
        if args.kind  then q.kind  = args.kind  end
        if args.limit then q.limit = tostring(args.limit) end
        if args.ignore_decay then q.ignore_decay = "1" end
        if args.since then q.since = args.since end
        if args["until"] then q["until"] = args["until"] end
        return http_request("GET", "/search", q, nil)
    end,
}

Tools.memory_recent = {
    description = "List the most recently created memories in a scope.",
    inputSchema = {
        type = "object",
        properties = {
            scope = { type = "string" },
            limit = { type = "integer", minimum = 1, maximum = 200 },
        },
    },
    handler = function(args)
        local q = {}
        if args.scope then q.scope = args.scope
        elseif MEMO_SCOPE then q.scope = MEMO_SCOPE end
        if args.limit then q.limit = tostring(args.limit) end
        return http_request("GET", "/recent", q, nil)
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
        return http_request("GET", "/" .. tonumber(args.id), nil, nil)
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
        local id = tonumber(args.id); args.id = nil
        return http_request("POST", "/" .. id .. "/update", nil, args)
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
        return http_request("POST", "/" .. tonumber(args.id) .. "/delete", nil, {})
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
        return http_request("POST", "/promote", nil, args)
    end,
}

-- ===========================================================================
-- Secrets tools
-- These tools manage encrypted API keys and other credentials stored server-
-- side. The raw secret value is NEVER returned to the LLM; use
-- secret_execute to make HTTP requests with it substituted server-side.
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
        return http_request("GET", "/secrets", nil, nil)
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
        return http_request("POST", "/secrets", nil, args)
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
        local name = tostring(args.name)
        return http_request("POST", "/secrets/" .. name .. "/delete", nil, {})
    end,
}

Tools.secret_execute = {
    description = "Execute an HTTP request with a stored secret substituted "
        .. "server-side. Write {secret} anywhere in the url, header values, "
        .. "or body — the server replaces it with the decrypted value before "
        .. "making the request. Only the response body is returned; the raw "
        .. "secret NEVER appears in the tool result.",
    inputSchema = {
        type = "object",
        properties = {
            name = {
                type        = "string",
                description = "Secret name to use.",
            },
            url = {
                type        = "string",
                description = "Request URL. May contain {secret}, e.g. 'https://api.example.com/data?key={secret}'.",
            },
            method = {
                type        = "string",
                enum        = { "GET", "POST", "PUT", "PATCH", "DELETE" },
                description = "HTTP method (default GET).",
            },
            headers = {
                type        = "object",
                description = "Header map. Any value may contain {secret}, e.g. { Authorization = 'Bearer {secret}' }.",
            },
            body = {
                type        = "string",
                description = "Request body. May contain {secret}.",
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
        local name = tostring(args.name)
        args.name  = nil
        return http_request("POST", "/secrets/" .. name .. "/execute", nil, args)
    end,
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
            tools = {},  -- presence of the key advertises tool support
        },
    }
end

function Methods.ping(_, _)
    return {}
end

Methods["tools/list"] = function(_, _)
    local list = {}
    for name, def in pairs(Tools) do
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

    -- MCP tools/call returns content array. Render the JSON for the model.
    local pretty = cjson.encode(result)
    return {
        isError = false,
        content = { { type = "text", text = pretty } },
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

    -- Notifications have no id and require no response.
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
    if not MEMO_URL then
        fatal("MEMO_URL env var is required")
    end
    log("started; MEMO_URL=" .. MEMO_URL
        .. (MEMO_SCOPE and (" MEMO_SCOPE=" .. MEMO_SCOPE) or "")
        .. (MEMO_TOKEN and " (token set)" or " (no token)"))

    -- Line-delimited JSON over stdin.
    while true do
        local line = io.read("*l")
        if not line then break end
        if line ~= "" then dispatch(line) end
    end
    log("stdin closed; exiting")
end

main()
