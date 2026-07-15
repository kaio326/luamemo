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

-- ---------------------------------------------------------------------------
-- Self-locate the bundled luamemo modules. Derive the repo/plugin root from
-- this script's own path (".../mcp/server.lua" → root) and prepend it to
-- package.path so `require("luamemo.*")` resolves to the code shipped next to
-- this server — no reliance on a LUA_PATH env var, and a stale system LuaRocks
-- install can't shadow the bundled modules. Falls back to the ambient path if
-- the root can't be derived (e.g. arg[0] unavailable).
-- ---------------------------------------------------------------------------
do
    local self_path = arg and arg[0]
    if self_path then
        local root = self_path:gsub("\\", "/"):match("^(.-)/?mcp/[^/]+$")
        if root then
            if root == "" then root = "." end
            package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
        end
    end
end

local json  = require("luamemo.json")
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
local SERVER_VERSION   = "0.3.1"

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
    -- api/CLI path uses the same). No auth=true: the MCP server makes direct,
    -- already-trusted store calls, so auth_fn stays the deny-by-default (the tools
    -- never consult it) and the embed probe behaviour is unchanged.
    local cfg = require("luamemo.cli._common").config_from_env({ secrets = true })
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
            scope = { type = "string", description = "Restrict to a single scope." },
            scopes = {
                type = "array",
                description = "Search a SET of scopes as a hierarchy (e.g. org ∪ repo ∪ user). "
                    .. "Returns the union; higher-tier memories (e.g. org directives) surface first. "
                    .. "Overrides `scope` when provided.",
                items = { type = "string" },
            },
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
            tier_min = {
                type = "integer",
                description = "Minimum tier (0–3) to include. Default 1 — excludes ephemeral (tier=0) raw events. Pass 0 to see all tiers.",
                minimum = 0, maximum = 3,
            },
        },
        required = { "query" },
    },
    handler = function(args)
        ensure_setup()
        local store = require("luamemo.store")
        local scope = args.scope or MEMO_SCOPE
        -- Default tier_min=1 so ephemeral events are hidden from MCP callers
        -- unless they explicitly pass tier_min=0.
        local tier_min = (args.tier_min ~= nil) and tonumber(args.tier_min) or 1
        local rows, err = store.search({
            query        = args.query,
            scope        = scope,
            scopes       = (type(args.scopes) == "table" and #args.scopes > 0) and args.scopes or nil,
            kind         = args.kind,
            limit        = tonumber(args.limit),
            ignore_decay = to_bool(args.ignore_decay),
            since        = args.since,
            ["until"]    = args["until"],
            tier_min     = tier_min,
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

Tools.memory_digest = {
    description = "Run hippocampus digest for a scope: consolidate ephemeral tier-0 "
        .. "memories, reinforce matching observations, and promote tier-1/2 memories "
        .. "when proof_count or mistake-event thresholds are met. "
        .. "Returns a summary of actions taken (processed, promoted2, promoted3, deleted). "
        .. "Use dry_run=true to preview without writing.",
    inputSchema = {
        type = "object",
        properties = {
            scope = {
                type = "string",
                description = "Scope to digest. Defaults to the server's configured scope.",
            },
            dry_run = {
                type = "boolean",
                description = "If true, report what would happen without writing (default false).",
            },
            threshold = {
                type = "number", minimum = 0.5, maximum = 1.0,
                description = "Cosine clustering threshold for ephemeral grouping (default 0.80).",
            },
        },
    },
    handler = function(args)
        ensure_setup()
        local digest = require("luamemo.digest")
        local scope = args.scope or MEMO_SCOPE
        local result = digest.run(scope, {
            dry_run   = to_bool(args.dry_run),
            threshold = tonumber(args.threshold),
        })
        return { ok = true, result = result }
    end,
}

Tools.memory_sense = {
    description = "Capture feedback signals from the recent conversation and record them as "
        .. "reinforcements on the memories they concern — this is how memory LEARNS from use. "
        .. "luamemo cannot read the chat itself, so the agent RELAYS the recent turns as "
        .. "{role, text} objects (oldest first). Heuristics detect explicit corrections "
        .. "(\"no, we use X not Y\"), standing commands (\"always/never …\"), and praise; each is "
        .. "attributed to the nearest memory in scope and logged once (idempotent — re-relaying "
        .. "the same turns records nothing new). Set generative=true to ALSO run the in-process "
        .. "instruct model for implicit/paraphrased signals (opt-in; needs MEMO_GEN_MODEL + LuaJIT; "
        .. "precision-first, so it stays quiet when unsure). Call this at a natural session boundary "
        .. "or after the user corrects you. Returns {recorded, skipped, signals}.",
    inputSchema = {
        type = "object",
        properties = {
            turns = {
                type = "array",
                description = "Recent conversation turns, oldest first. Only USER turns are scanned "
                    .. "for signals; assistant turns give context to the generative extractor.",
                items = {
                    type = "object",
                    properties = {
                        role = { type = "string", description = "'user' or 'assistant'." },
                        text = { type = "string", description = "The turn's text." },
                    },
                },
            },
            scope = {
                type = "string",
                description = "Scope whose memories may be reinforced. Defaults to the server's scope.",
            },
            generative = {
                type = "boolean",
                description = "Also run the in-process generative extractor (opt-in; default false).",
            },
            min_similarity = {
                type = "number", minimum = 0, maximum = 1,
                description = "Memory-resolution floor (default 0.15). Higher = stricter attribution.",
            },
        },
        required = { "turns" },
    },
    handler = function(args)
        ensure_setup()
        local sensing = require("luamemo.sensing")
        local scope = args.scope or MEMO_SCOPE
        local result = sensing.process(scope, args.turns or {}, {
            generative     = to_bool(args.generative),
            min_similarity = tonumber(args.min_similarity),
        })
        return { ok = true, result = result }
    end,
}

-- ===========================================================================
-- Secrets tools
-- ===========================================================================

Tools.secret_list = {
    description = "List all stored secrets (names and metadata only). "
        .. "Secret VALUES are never returned — not by this tool, not by any other tool. "
        .. "If the user needs to store a new API key or token, instruct them to run "
        .. "'memo secret-store NAME --desc DESCRIPTION' in their terminal (NOT in chat). "
        .. "Explain that typing a secret value in chat would expose it to the LLM and "
        .. "potentially log it with the AI provider. "
        .. "The terminal command prompts with no echo, keeping the value out of chat entirely. "
        .. "Once stored, use secret_execute to make authenticated HTTP requests "
        .. "with {secret} substituted server-side.",
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
        .. "be retrieved — only used via secret_execute. "
        .. "WARNING: do NOT call this tool from the chat window. "
        .. "The 'value' parameter would enter the LLM context and may be "
        .. "logged by the AI provider. Use the terminal CLI instead: "
        .. "'memo secret-store NAME --desc DESCRIPTION' prompts for the value "
        .. "with no echo and stores it without the value ever entering chat. "
        .. "Requires the server to be configured with MEMO_MASTER_KEY and MEMO_SECRETS_FILE.",
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

Tools.memory_status = {
    description = "Return a DB health snapshot: total row count, per-scope row counts, "
        .. "and a summary of the active configuration (embedder, backend, features).",
    inputSchema = {
        type       = "object",
        properties = {
            verbose = {
                type        = "boolean",
                description = "When true, include internal config details "
                    .. "(embedder, backend, embed_dim) in the response.",
            },
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
        local lm    = require("luamemo")  -- single local reference
        local resp  = {
            connected  = true,
            total_rows = total,
            top_scopes = scopes,
            version    = lm.VERSION or "unknown",
        }
        -- expose internal config only when the caller explicitly requests
        -- it (verbose=true).  Guards against architecture reconnaissance if the
        -- server is ever fronted by HTTP/SSE transport instead of local stdio.
        if args.verbose == true then
            local cfg_ref = lm.config or {}
            resp.config = {
                embedder     = cfg_ref.embedder_local,
                embed_dim    = cfg_ref.embed_dim,
                backend      = cfg_ref.backend,
                patterns_en  = cfg_ref.patterns_enabled ~= false,
                tier_min_mcp = 1,
            }
        end
        return resp
    end,
}

Tools.memory_reconnect = {
    description = "Force re-open the database connection. "
        .. "Useful after an external script modified lm_memories directly, "
        .. "or after a transient connection drop.",
    inputSchema = {
        type       = "object",
        properties = {},
    },
    handler = function(_)
        ensure_setup()
        local db_mod    = require("luamemo.db")
        local store_mod = require("luamemo.store")
        db_mod.reset()
        local ok, res = pcall(db_mod.query, "SELECT COUNT(*) AS n FROM " .. store_mod.table_name())
        return {
            success    = ok,
            rows_after = ok and tonumber(res[1].n) or nil,
            error      = (not ok) and tostring(res) or nil,
        }
    end,
}

Tools.memory_diary_write = {
    description = "Write a personal diary entry for a named agent. "
        .. "Each agent_name gets its own isolated scope (diary:<agent_name>). "
        .. "Use this to log reflections, session summaries, or ongoing thoughts.",
    inputSchema = {
        type       = "object",
        properties = {
            agent_name = {
                type        = "string",
                description = "Agent identifier (e.g. 'momo', 'assistant').",
            },
            entry = {
                type        = "string",
                description = "The diary entry text to store.",
            },
            topic = {
                type        = "string",
                description = "Optional topic tag (default: 'general').",
            },
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
    description = "Read recent diary entries for a named agent in chronological order "
        .. "(newest first). Returns up to last_n entries (max 50).",
    inputSchema = {
        type       = "object",
        properties = {
            agent_name = {
                type        = "string",
                description = "Agent identifier matching what was used in memory_diary_write.",
            },
            last_n = {
                type        = "integer",
                description = "Maximum number of entries to return (default 10, max 50).",
                minimum     = 1,
                maximum     = 50,
            },
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
            "ORDER BY created_at DESC LIMIT ?",
            scope, limit)
        if not rows then return nil, err end
        local entries = {}
        for _, r in ipairs(rows) do
            local meta = (type(r.metadata) == "table") and r.metadata or {}
            entries[#entries + 1] = {
                entry_id  = r.id,
                timestamp = r.created_at,
                topic     = meta.topic or "general",
                content   = r.body,
            }
        end
        return { agent = args.agent_name, entries = entries, total = #entries, scope = scope }
    end,
}

-- ===========================================================================
-- Codebase map tools (index_*) — token-lean access to the code index.
-- Return compact text (`{ ok, text }`) instead of full rows so an agent spends
-- ~30 tokens locating code rather than reading files or parsing JSON.
-- ===========================================================================

-- Resolve the codeindex scope for an index_* call. Explicit `scope` wins;
-- else `codeindex:<project>` where project comes from the `project` arg or is
-- derived from MEMO_SCOPE (strip a leading "repo:"), defaulting to "default".
local function index_scope(args)
    if args.scope and args.scope ~= "" then return args.scope end
    local project = args.project
    if not project or project == "" then
        if MEMO_SCOPE and MEMO_SCOPE ~= "" then
            project = MEMO_SCOPE:gsub("^repo:", "")
        else
            project = "default"
        end
    end
    return "codeindex:" .. project
end

Tools.index_search = {
    description = "Search the codebase MAP (symbols, files, dependencies) — call this "
        .. "BEFORE grepping or reading files to find WHERE code lives. Returns compact "
        .. "'path:line  name (type) — doc' lines, not file contents. Use it to locate the "
        .. "right file/function, then read only that region. Requires a built index "
        .. "(run `memo index ingest`).",
    inputSchema = {
        type       = "object",
        properties = {
            query   = { type = "string",  description = "Natural-language or identifier query, e.g. 'where is dedup handled'." },
            project = { type = "string",  description = "Project name → scope codeindex:<project>. Defaults from MEMO_SCOPE." },
            scope   = { type = "string",  description = "Explicit codeindex:<project> scope (overrides project)." },
            kind    = { type = "string",  description = "Restrict to 'symbol', 'file', 'dependency', or 'diff'." },
            limit   = { type = "integer", description = "Max results (default 15, max 50).", minimum = 1, maximum = 50 },
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
        return { ok = true, text = index.format.results(rows) }
    end,
}

Tools.index_outline = {
    description = "List everything defined in ONE file (symbol names, line numbers, one-line "
        .. "docs) — call before editing a file instead of reading it whole. Returns a compact "
        .. "outline; the file on disk remains the source of truth to read before writing.",
    inputSchema = {
        type       = "object",
        properties = {
            path    = { type = "string", description = "Repo-relative file path, e.g. 'luamemo/store.lua'." },
            project = { type = "string", description = "Project name → scope codeindex:<project>. Defaults from MEMO_SCOPE." },
            scope   = { type = "string", description = "Explicit codeindex:<project> scope (overrides project)." },
        },
        required = { "path" },
    },
    handler = function(args)
        ensure_setup()
        local index = require("luamemo.index")
        local res, err = index.outline(args.path, { scope = index_scope(args) })
        if not res then return nil, err end
        return { ok = true, text = index.format.outline(res.file, res.symbols) }
    end,
}

Tools.index_explore = {
    description = "Impact/blast-radius query over the dependency graph: given a query, return "
        .. "matched symbols PLUS the modules that depend on them (callers) and that they depend "
        .. "on (callees). Use before refactoring to see what a change touches. One hop.",
    inputSchema = {
        type       = "object",
        properties = {
            query   = { type = "string",  description = "Symbol or concept to explore, e.g. 'store.write'." },
            project = { type = "string",  description = "Project name → scope codeindex:<project>. Defaults from MEMO_SCOPE." },
            scope   = { type = "string",  description = "Explicit codeindex:<project> scope (overrides project)." },
            limit   = { type = "integer", description = "Max matched symbols before expansion (default 10, max 30).", minimum = 1, maximum = 30 },
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
        return { ok = true, text = index.format.explore(res) }
    end,
}

Tools.index_status = {
    description = "Report whether a codebase map exists for this project and its size "
        .. "(file / symbol / dependency / diff row counts). Call at session start to learn "
        .. "if index_search/index_outline are available.",
    inputSchema = {
        type       = "object",
        properties = {
            project = { type = "string", description = "Project name → scope codeindex:<project>. Defaults from MEMO_SCOPE." },
            scope   = { type = "string", description = "Explicit codeindex:<project> scope (overrides project)." },
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
        return { ok = true, text = text, counts = counts, scope = scope }
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
    local enc = json.encode(msg)
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

    local pretty = json.encode(result)
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
local function dispatch(line)
    local msg, derr = json.decode(line)
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
