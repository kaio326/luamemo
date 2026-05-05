# Auto-Capture Hooks

> **TL;DR:** wire chat agents into `lapis-memory` in two lines per turn
> with `lapis_memory.hooks`. Captures user messages, assistant
> messages, tool calls, and durable decisions into the right scope with
> sensible dedup defaults.

---

## Why this exists

Hand-rolled memory wiring tends to look like this on every project:

```lua
-- 1. construct the scope string by hand
local scope = "user:" .. uid .. ":session:" .. sid
-- 2. invent a metadata blob
local meta = { role = "user", session_id = sid, user_id = uid, ... }
-- 3. invent a title trim
local title = "user: " .. content:sub(1, 80) .. "..."
-- 4. pick a dedup strategy from memory
memory.write({ scope=scope, kind="chat", title=title, body=content,
               tags={"chat","user"}, metadata=meta,
               dedup_strategy="append", importance=1.0 })
```

Every project gets that wrong in slightly different ways, which makes
cross-project tooling (summarizer, promotion, replay) brittle.

`hooks.lua` is the **canonical** version of all four common writes:

| Helper                          | What it captures                          |
|---------------------------------|-------------------------------------------|
| `capture_user_message`          | A user-authored chat turn                 |
| `capture_assistant_message`     | An assistant-authored chat turn (with optional `tool_calls`) |
| `capture_tool_call`             | One tool invocation: tool, args, result, success |
| `capture_decision`              | A durable fact / preference / decision (long-term scope) |

All four return the same `(row, err)` tuple as `store.write`.

---

## Quick start

```lua
local memory = require("lapis_memory")
local hooks  = require("lapis_memory.hooks")   -- or memory.hooks

memory.setup({ db_table = "lapis_memory", embedder_local = "ollama" })

-- per-turn, in your chat loop:
hooks.capture_user_message{
    user_id    = "user-42",
    session_id = "session-abc",
    content    = user_input,
}

local reply, tool_calls = run_agent(user_input)

hooks.capture_assistant_message{
    user_id    = "user-42",
    session_id = "session-abc",
    content    = reply,
    tool_calls = tool_calls,    -- optional, stored verbatim in metadata
}

for _, tc in ipairs(tool_calls or {}) do
    hooks.capture_tool_call{
        user_id    = "user-42",
        session_id = "session-abc",
        tool       = tc.name,
        args       = tc.args,
        result     = tc.result,
        success    = tc.ok,
    }
end
```

To save a durable fact (writes to `user:<uid>:long_term`, not the
session scope):

```lua
hooks.capture_decision{
    user_id    = "user-42",
    session_id = "session-abc",   -- only used for metadata trail
    content    = "User prefers Tailwind v4 utilities over hand-rolled CSS.",
    title      = "preference: tailwind v4",   -- optional
    importance = 3.0,                          -- optional, default 3.0
}
```

---

## Scope conventions

The hooks generate scope strings via two helpers — use them directly
if you need to query later:

```lua
hooks.session_scope("user-42", "session-abc")
-- => "user:user-42:session:session-abc"

hooks.long_term_scope("user-42")
-- => "user:user-42:long_term"
```

This matches the convention documented in
[SESSION_CONTINUITY.md](SESSION_CONTINUITY.md): nesting under
`:session:<sid>` so promoting a session to long-term is a clean prefix
swap, and `summarizer.promote` can target either scope without
guessing.

| Scope                              | Use for                                 |
|------------------------------------|-----------------------------------------|
| `user:<uid>:session:<sid>`         | Hot, short-lived working memory         |
| `user:<uid>:long_term`             | Promoted summaries + decisions          |
| `global`                           | Shared facts visible to all users       |

---

## Defaults & dedup

Every helper picks a sensible `dedup_strategy` you can override:

| Helper                          | Default dedup |  Why                                    |
|---------------------------------|---------------|------------------------------------------|
| `capture_user_message`          | `append`      | Same opener twice ≠ same intent         |
| `capture_assistant_message`     | `append`      | Replies vary even when prompts repeat   |
| `capture_tool_call`             | `update`      | Same tool+args is often retried; collapse to a "called N times" view |
| `capture_decision`              | `update`      | A new statement of the same preference replaces the old one |

All can be overridden per call: `dedup_strategy = "skip"`,
`importance = 5.0`, `metadata = {...}`, etc.

Long content is trimmed for the human-readable `title` field (80 chars
for chat, 400 chars for tool args/result inside the body), but the
**full content** is always written to `body` — nothing is silently
dropped.

---

## What about retrieval?

These hooks are write-only. To read what was captured, use
`memory.search` with the same scope — it works exactly as documented
in [README.md](README.md) and [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md):

```lua
local hits = memory.search{
    query = current_user_input,
    scope = hooks.session_scope("user-42", "session-abc"),
    limit = 5,
    rerank = true,             -- optional, see RETRIEVAL_TUNING.md §4
}
```

Combine with `memory.search{ scope = hooks.long_term_scope("user-42") }`
to fold in promoted long-term facts. The two scopes can be queried
in parallel and merged in your prompt builder.

---

## See also

- [SESSION_CONTINUITY.md](SESSION_CONTINUITY.md) — promoting session
  scopes to long-term.
- [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md) — making the writes you
  capture here actually findable at search time.
