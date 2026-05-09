-- luamemo.hooks
--
-- Auto-capture helpers for chat agents. These are thin convenience
-- wrappers over `store.write` / scope conventions so a host application
-- can record turns, tool calls, and decisions in two lines of code
-- instead of hand-building scope strings and metadata blobs.
--
-- Usage
-- -----
--   local hooks  = require("luamemo.hooks")
--   local memory = require("luamemo")
--   memory.setup({ ... })
--
--   local scope = hooks.session_scope("user-42", "session-abc")
--   -- => "user:user-42:session:session-abc"
--
--   hooks.capture_user_message({
--       user_id    = "user-42",
--       session_id = "session-abc",
--       content    = "I want to refactor the auth helper.",
--   })
--
--   hooks.capture_assistant_message({
--       user_id    = "user-42",
--       session_id = "session-abc",
--       content    = "Here is the refactor plan...",
--       tool_calls = { { name = "read_file", args = {...} } },
--   })
--
--   hooks.capture_tool_call({
--       user_id    = "user-42",
--       session_id = "session-abc",
--       tool       = "read_file",
--       args       = { filename = "auth.lua" },
--       result     = "<file body>",
--       success    = true,
--   })
--
-- Scope conventions (recommended, not enforced):
--   * "user:<uid>:session:<sid>"  — hot, short-lived working memory.
--   * "user:<uid>:long_term"      — promoted summaries (via summarizer.promote).
--   * "global"                    — shared facts visible to all users.
--
-- All capture helpers return the same `(row, err)` tuple as `store.write`
-- so callers can inspect or log failures.

local store = require("luamemo.store")
local util  = require("luamemo.util")

local clip = util.clip   -- truncate to n chars with ellipsis (2-arg: clip(s, n))

local M = {}

local function nonempty(s)
    return type(s) == "string" and s ~= ""
end

--- Build a session scope string. Sticks to the convention used in the
--- session-continuity guide (SESSION_CONTINUITY.md): user-prefixed,
--- nested under `:session:<sid>` so promoting to long-term is a simple
--- prefix swap.
function M.session_scope(user_id, session_id)
    assert(nonempty(user_id),    "session_scope: user_id required")
    assert(nonempty(session_id), "session_scope: session_id required")
    return "user:" .. user_id .. ":session:" .. session_id
end

--- Build a long-term scope string for the same user.
function M.long_term_scope(user_id)
    assert(nonempty(user_id), "long_term_scope: user_id required")
    return "user:" .. user_id .. ":long_term"
end

-- --- internal: shared writer -------------------------------------------
--
-- Every capture_* helper funnels through this so they share dedup,
-- importance defaults, and error handling. Per-call overrides win over
-- defaults; defaults win over library config.
local function _write(opts)
    local args = {
        scope          = opts.scope,
        kind           = opts.kind,
        title          = opts.title,
        body           = opts.body,
        tags           = opts.tags,
        metadata       = opts.metadata,
        importance     = opts.importance,
        decay_rate     = opts.decay_rate,
        dedup_strategy = opts.dedup_strategy,
    }
    return store.write(args)
end

--- Record a user-authored chat turn.
-- @param opts.user_id     string
-- @param opts.session_id  string
-- @param opts.content     string
-- @param opts.metadata    table (optional)
-- @param opts.importance  number (optional, default 1.0)
-- @return row, err
function M.capture_user_message(opts)
    opts = opts or {}
    if not nonempty(opts.content) then
        return nil, "capture_user_message: content required"
    end
    local meta = opts.metadata or {}
    meta.role       = "user"
    meta.session_id = opts.session_id
    meta.user_id    = opts.user_id
    return _write({
        scope      = M.session_scope(opts.user_id, opts.session_id),
        kind       = "chat",
        title      = "user: " .. clip(opts.content, 80),
        body       = opts.content,
        tags       = { "chat", "user" },
        metadata   = meta,
        importance = opts.importance or 1.0,
        -- Chat turns dedup poorly (same opener twice = different intent).
        dedup_strategy = opts.dedup_strategy or "append",
    })
end

--- Record an assistant-authored chat turn.
-- Optional `opts.tool_calls` is stored verbatim in metadata so the
-- next turn / replay can reconstruct tool intent.
function M.capture_assistant_message(opts)
    opts = opts or {}
    if not nonempty(opts.content) then
        return nil, "capture_assistant_message: content required"
    end
    local meta = opts.metadata or {}
    meta.role       = "assistant"
    meta.session_id = opts.session_id
    meta.user_id    = opts.user_id
    if opts.tool_calls then meta.tool_calls = opts.tool_calls end
    return _write({
        scope      = M.session_scope(opts.user_id, opts.session_id),
        kind       = "chat",
        title      = "assistant: " .. clip(opts.content, 80),
        body       = opts.content,
        tags       = { "chat", "assistant" },
        metadata   = meta,
        importance = opts.importance or 1.0,
        dedup_strategy = opts.dedup_strategy or "append",
    })
end

--- Record a tool call (name + args + result). Useful for "what did the
--- agent already try?" recall, which dramatically cuts repeated work.
function M.capture_tool_call(opts)
    opts = opts or {}
    if not nonempty(opts.tool) then
        return nil, "capture_tool_call: tool required"
    end
    local meta = opts.metadata or {}
    meta.role       = "tool"
    meta.tool       = opts.tool
    meta.success    = (opts.success ~= false)   -- default true
    meta.session_id = opts.session_id
    meta.user_id    = opts.user_id
    if opts.args   ~= nil then meta.args   = opts.args   end
    if opts.result ~= nil then meta.result = opts.result end

    -- Body is human-readable so it embeds well; metadata carries the
    -- structured replay payload.
    local body = string.format(
        "tool: %s\nsuccess: %s\nargs: %s\nresult: %s",
        opts.tool,
        tostring(meta.success),
        clip(tostring(opts.args   or ""), 400),
        clip(tostring(opts.result or ""), 400)
    )
    return _write({
        scope      = M.session_scope(opts.user_id, opts.session_id),
        kind       = "tool_call",
        title      = "tool: " .. opts.tool,
        body       = body,
        tags       = { "tool", opts.tool },
        metadata   = meta,
        importance = opts.importance or 1.0,
        -- Tool calls are often repeated identically; let the dedup pass
        -- collapse them into a "called N times" view via "update".
        dedup_strategy = opts.dedup_strategy or "update",
    })
end

--- Record a high-value durable fact decided during the session
--- (preferences, configuration, decisions). These live in long-term
--- scope from the start so they survive session promotion.
function M.capture_decision(opts)
    opts = opts or {}
    if not nonempty(opts.content) then
        return nil, "capture_decision: content required"
    end
    local meta = opts.metadata or {}
    meta.role       = "decision"
    meta.user_id    = opts.user_id
    meta.session_id = opts.session_id   -- provenance, not scope

    return _write({
        scope      = M.long_term_scope(opts.user_id),
        kind       = "decision",
        title      = opts.title or clip(opts.content, 80),
        body       = opts.content,
        tags       = opts.tags or { "decision" },
        metadata   = meta,
        -- Decisions are pulled in by future searches; lean on importance
        -- to keep them ranked above casual chat.
        importance = opts.importance or 3.0,
        decay_rate = opts.decay_rate or 0.0,
        -- Default to "update" so re-stating the same decision merges
        -- instead of multiplying the same row.
        dedup_strategy = opts.dedup_strategy or "update",
    })
end

return M
