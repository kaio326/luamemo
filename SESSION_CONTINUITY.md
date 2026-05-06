# Session Continuity

> **The problem this solves:** when an agent session ends, anything
> written under `session:<uuid>` is invisible to the next session
> because the new session has a different uuid. Without intervention,
> every new session starts cold.

`luamemo` solves this with one helper — `memory.promote()` — that
folds a hot session scope into a long-term scope at session end. The
next session searches the long-term scope and finds the carried-over
context.

No new tables, no new columns. Pure convention on top of `scope` plus
the existing summarizer.

---

## The convention

| Scope                       | Lifetime          | Read by               | Written by             |
|-----------------------------|-------------------|-----------------------|------------------------|
| `session:<uuid>`            | One session       | Current session only  | Agent during session   |
| `user:<id>:long_term`       | Forever           | Every future session  | `promote()` at exit    |

You're free to pick any names — `session:<uuid>` and `user:<id>:long_term`
are recommendations, not requirements.

---

## End-of-session recipe

When your host detects the session is ending (last message timestamp,
explicit `/end` command, websocket close, etc.), call `promote()`:

### From Lua

```lua
local memory = require("luamemo")

local result = memory.promote({
    from_scope    = "session:" .. session_uuid,
    to_scope      = "user:" .. user_id .. ":long_term",
    delete_source = true,   -- session rows are no longer useful
})

if result.promoted == 1 then
    ngx.log(ngx.INFO, "promoted session ", session_uuid,
        " -> summary id=", result.summary_id,
        " (", #result.source_ids, " source rows)")
end
```

### From HTTP

```bash
curl -sS -X POST https://your-app/api/memory/promote \
  -H "Authorization: Bearer $MEMO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "from_scope":    "session:abc-123",
        "to_scope":      "user:42:long_term",
        "delete_source": true
      }' | jq .
```

### From the CLI

```bash
memo promote \
    --from session:abc-123 \
    --to   user:42:long_term \
    --delete-source
```

### From an MCP-aware agent

Tool name: `memory_promote`.

```json
{
  "from_scope":    "session:abc-123",
  "to_scope":      "user:42:long_term",
  "delete_source": true
}
```

The tool description in the MCP schema explicitly tells agents
**when** to call it ("at end of session"), so capable models invoke it
on their own once it's exposed.

---

## Next-session retrieval

The promoted summary lives in `user:<id>:long_term`. Search it as a
default scope at session start:

```lua
local hits = memory.search({
    q     = user_first_message,
    scope = "user:" .. user_id .. ":long_term",
    limit = 5,
})
```

Or pass `scope = nil` to search everywhere — the long-term summary
will rank naturally alongside other memories.

---

## Worked example: two sessions

**Session 1** (Tuesday, uuid `abc-123`):

```lua
memory.write({ scope="session:abc-123", body="user prefers Postgres over MySQL" })
memory.write({ scope="session:abc-123", body="user is building a Lua/Lapis SaaS" })
memory.write({ scope="session:abc-123", body="user wants single-instance deploy on OVH VPS" })
-- ... 12 more notes during the chat ...

-- on session end:
memory.promote({
    from_scope    = "session:abc-123",
    to_scope      = "user:42:long_term",
    delete_source = true,
})
```

After promotion the long-term scope contains one row with
`title = "[promoted] Summary: ..."`,
`metadata.promoted_from = "session:abc-123"`, and
`metadata.source_ids = {1, 2, 3, ...}` — useful for audit and rollback.

**Session 2** (Thursday, uuid `xyz-789`) — user opens the chat and
asks "what database should I use again?":

```lua
local hits = memory.search({
    q     = "what database should I use",
    scope = "user:42:long_term",
    limit = 3,
})
-- hits[1].body contains the promoted summary including
-- "user prefers Postgres over MySQL" → agent answers correctly.
```

The new session knows the previous session's content. No memory loss.

---

## Provenance metadata

Every promoted summary row carries:

```json
{
  "promoted_from": "session:abc-123",
  "source_ids":    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
}
```

Use `metadata.promoted_from` to audit which session a summary came
from. Use `metadata.source_ids` if you kept `delete_source = false`
and later want to fetch the raw history.

The title is prefixed with `[promoted] ` so promoted summaries are
visually distinct from background-summarizer summaries.

---

## API reference

```lua
memory.promote({
    from_scope    = "session:abc",       -- required
    to_scope      = "user:42:long_term", -- required, must differ from from_scope
    delete_source = false,               -- default false; true hard-deletes source rows
    dry_run       = false,               -- default false; true reports without writing
    limit         = 200,                 -- max source rows to fold (cap 1000)
    min_rows      = 1,                   -- bail with reason="no_rows" below this
})
-- returns:
--   { promoted = 1, summary_id = N, source_ids = {...},
--     dry_run = false, deleted_source = true }
-- or on no-op:
--   { promoted = 0, source_ids = {}, reason = "no_rows" }
-- or on error:
--   { promoted = 0, errors = {"..."} }
```

The HTTP endpoint, MCP tool, and CLI command accept the same fields
and return the same shape (wrapped in `{ ok, result }` for HTTP).

---

## When NOT to promote

- **One-off scratch sessions** (debugging a bot, smoke-testing the
  API). The session content has no long-term value — just let
  `session:<uuid>` rows expire via the background summarizer +
  retention sweep, or delete them outright.
- **Sessions that contain secrets** (passwords typed in chat, etc.)
  that you do not want to persist. Either skip `promote()` or
  pre-filter the source rows with `delete()` before promoting.
- **Agent loops that never "end"** (always-on assistants). Promote on
  a time-based trigger instead — e.g. every 24 hours roll the last
  24 h of session rows into long-term.

---

## Cost & quality notes

- The summary quality depends entirely on your configured
  `summarizer_adapter`. The default `noop` adapter concatenates source
  bodies (zero cost, perfect fidelity, no compression). For real
  compression configure `ollama` or `openai`.
- `promote()` makes **one** adapter call regardless of how many source
  rows you have (capped by `limit`). If your adapter has a context
  window smaller than the session, lower `limit` or pre-summarize via
  `memory.summarize()` first, then promote the resulting summaries.
- Promoted summaries bypass dedup (`dedup_strategy = "append"`) so
  back-to-back promotions of related sessions never silently merge.

---

## See also

- [EMBEDDERS.md](EMBEDDERS.md) — pick the right embedder so the
  next-session search actually finds the promoted summary.
- [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md) — `since` / `until`
  filters pair well with promoted summaries: "what did we discuss
  this week" = `search({ scope="user:42:long_term", since=epoch_now-7d })`.
