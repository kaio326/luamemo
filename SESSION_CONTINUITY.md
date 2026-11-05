# Session Continuity

> **The problem this solves:** when an agent session ends, anything
> written under `session:<uuid>` is invisible to the next session
> because the new session has a different uuid. Without intervention,
> every new session starts cold.

luamemo solves this with one operation — **promote** (`memory_promote` over
MCP, `memo promote` in a terminal) — that folds a hot session scope into a
long-term scope at session end. The next session searches the long-term scope
and finds the carried-over context.

Nothing else is needed: a convention on top of `scope`, plus the summarizer.

---

## The convention

| Scope                       | Lifetime          | Read by               | Written by             |
|-----------------------------|-------------------|-----------------------|------------------------|
| `session:<uuid>`            | One session       | Current session only  | Agent (and the capture hooks) during the session |
| `user:<id>:long_term`       | Forever           | Every future session  | promote, at the end    |

You're free to pick any names — `session:<uuid>` and `user:<id>:long_term`
are recommendations, not requirements. A coding agent usually keeps its
long-term memories in the project's scope (`repo:<project>`).

---

## Capture conventions

Recording a conversation as it happens takes four kinds of write — every one is
a plain `memo write` (CLI) or `memory_write` (MCP) with these fields. Turns go
to the session scope `user:<id>:session:<sid>`; decisions go straight to
`user:<id>:long_term`, so they survive the session even without a promotion.

| What | scope | kind | title | tags | metadata | dedup |
|---|---|---|---|---|---|---|
| user turn | session | `chat` | `user: <first 80 chars>` | `chat,user` | `role: "user"`, `user_id`, `session_id` | `append` |
| assistant turn | session | `chat` | `assistant: <first 80 chars>` | `chat,assistant` | `role: "assistant"`, `user_id`, `session_id`, `tool_calls` | `append` |
| tool call | session | `tool_call` | `tool: <name>` | `tool,<name>` | `role: "tool"`, `tool`, `args`, `result`, `success`, `user_id`, `session_id` | `update` |
| decision | long-term | `decision` | the decision's title | `decision` | `role: "decision"`, `user_id`, `session_id` | `update` |

- The body is the turn's text; for a tool call it is
  `tool: <name>\nsuccess: <true|false>\nargs: <args>\nresult: <result>` (args and
  result cut at 400 characters), which embeds well while the metadata keeps the
  full structured call.
- Decisions get `--importance 3` (they outrank chat in later searches) and no decay.
- `append` for chat: the same words twice can mean different things. `update` for
  tool calls and decisions: repeating one merges into the existing memory instead
  of piling up copies.
- An empty turn is not written.

```bash
memo write --scope user:42:session:abc --kind chat --title "user: I want to refactor the auth helper." \
    --body "I want to refactor the auth helper." --tags chat,user --dedup-strategy append \
    --metadata '{"role":"user","user_id":"42","session_id":"abc"}'

memo write --scope user:42:long_term --kind decision --title "preference: tailwind v4" \
    --body "User prefers Tailwind v4 utilities." --tags decision --importance 3 --dedup-strategy update \
    --metadata '{"role":"decision","user_id":"42","session_id":"abc"}'
```

Over MCP, `memory_write` takes the same fields (`tags` as a list, `metadata` as an
object, `dedup_strategy`); `items` writes several turns in one call.

In Claude Code the capture hooks do the session part for you: they save the last
messages into `session:<session id>` before a compaction and every few minutes
while the agent works (`memo agent install --with-transcripts`; README → *Session
continuity and hooks*). Those saves are tier 0 — raw material for `memo digest`;
`memory_promote` folds what the agent wrote itself (tier 1 and up). `memo calibrate`
sets up the rest by itself: what you say
reaches memory (a correction, a standing rule), the brief opens each session, and
Claude Code's own file memory gives way to luamemo in the project.

---

## End-of-session recipe

When the session is ending (the user says so, an explicit `/end`, the last
message of the day…), promote the session scope.

### From an MCP-aware agent

Tool `memory_promote`:

```json
{
  "from_scope":    "session:abc-123",
  "to_scope":      "user:42:long_term",
  "delete_source": true
}
```

Its description tells agents **when** to call it ("at end of session"), so
capable models invoke it on their own; the luamemo agent and the session-memory
skill say so too.

### From a terminal or a script

```bash
memo promote --from session:abc-123 --to user:42:long_term --delete-source
memo promote --from session:abc-123 --to user:42:long_term --dry-run   # what would be folded
```

---

## Next-session retrieval

The promoted summary lives in `user:<id>:long_term`. Search it at session start
— alone, or with the other scopes the answer could be in:

```json
{ "query": "what was decided last time", "scopes": ["user:42:long_term", "repo:my-app"], "limit": 5 }
```

```bash
memo search "what was decided last time" --scopes user:42:long_term,repo:my-app --limit 5
```

---

## Worked example: two sessions

**Session 1** (Tuesday, `session:abc-123`) — the agent notes what it learns as
it goes:

```bash
memo write --scope session:abc-123 --title "db choice" --body "user prefers SQLite over MySQL for this app"
memo write --scope session:abc-123 --title "stack" --body "user is building a Lua web service"
memo write --scope session:abc-123 --title "deploy" --body "user wants a single-instance deploy on a VPS"
# … a dozen more notes during the chat …

# at the end:
memo promote --from session:abc-123 --to user:42:long_term --delete-source
```

The long-term scope now holds one memory titled `[promoted] …` (kind `summary`)
with `metadata.promoted_from = "session:abc-123"` and `metadata.source_ids` —
useful for audit.

**Session 2** (Thursday, `session:xyz-789`) — the user asks "which database
should I use again?":

```bash
memo search "which database should I use" --scope user:42:long_term --limit 3
# the first result is the promoted summary, including
# "user prefers SQLite over MySQL" → the agent answers correctly.
```

The new session knows what the previous one knew.

---

## Provenance metadata

Every promoted summary carries:

```json
{
  "promoted_from": "session:abc-123",
  "source_ids":    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
}
```

`promoted_from` says which session a summary came from; `source_ids` lets you
fetch the raw notes later if you kept them (no `delete_source`). The title is
prefixed with `[promoted] ` so promoted summaries stand apart from the
summarizer's.

---

## Reference

| Parameter (`memory_promote`) | `memo promote` | Default | Meaning |
|---|---|---|---|
| `from_scope` | `--from` | required | the session scope |
| `to_scope` | `--to` | required | the long-term scope (must differ) |
| `delete_source` | `--delete-source` | false | delete the memories that were folded (tier 1 and up) |
| `dry_run` | `--dry-run` | false | report what would happen, write nothing |
| `limit` | `--limit N` | 200 (at most 1,000) | the most memories folded, oldest first |
| `min_rows` | `--min-rows N` | 1 | do nothing below this many |

Result: `{ ok, result = { promoted = 1, summary_id, source_ids, dry_run, deleted_source } }`
(`ok` is true when `promoted` is 1 or there was nothing to fold); nothing to fold:
`result = { promoted = 0, source_ids = [], reason = "no_rows" }`; an error:
`ok = false`, `result = { promoted = 0, errors = [...] }`. Only memories of tier 1 or
higher are folded: the transcript chunks the capture hooks save
(`--with-transcripts`) are tier 0, so promotion leaves them alone, `delete_source`
does not delete them (a session with only chunks answers `reason = "no_rows"`),
and `memo digest` turns them into notes (`memo delete --scope session:<id> --yes`
removes them). Summaries already in the session scope (kind `summary`) are not
folded again. A dev's read-only org replica can be
promoted from, but `delete_source` is refused there.

---

## When NOT to promote

- **One-off scratch sessions** (debugging, smoke tests). The content has no
  long-term value — delete the scope (`memo delete --scope session:<id> --yes`)
  or let it age out (give such notes a `decay_rate`).
- **Sessions that contain secrets** (a key pasted into the chat by mistake) you
  don't want to keep. Delete those memories first, or skip the promotion.
- **Agents that never "end"** (always-on assistants). Promote on a schedule
  instead — e.g. every 24 hours.

---

## Cost & quality notes

- The summary's quality depends on the summarizer (`MEMO_SUMMARIZER_ADAPTER`).
  The default `auto` uses your `MEMO_GEN_MODEL` when one is configured (a call
  in this process: seconds to a minute on a CPU) and otherwise joins the source
  memories (no cost, nothing lost, no compression); `noop` always joins them;
  `gguf` uses the in-process model; `ollama` and `openai` compress them with the
  model at `MEMO_SUMMARIZER_URL` / `MEMO_SUMMARIZER_MODEL` (see
  [SETTINGS.md](SETTINGS.md) → Summarizer).
- Promotion makes **one** summarizer call however many memories it folds (up to
  `limit`). If your model's context is smaller than the session, lower `limit`
  and promote in several passes.
- Promoted summaries are never merged by dedup, so back-to-back promotions of
  related sessions stay separate.

---

## See also

- [EMBEDDERS.md](EMBEDDERS.md) — the right embedder makes the next session's
  search find the promoted summary.
- [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md) — `since` / `until` pair well with
  promoted summaries: "what did we discuss this week" =
  `memo search "…" --scope user:42:long_term --since 2026-10-03`.
