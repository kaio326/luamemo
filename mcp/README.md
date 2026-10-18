# luamemo MCP server

`memo mcp` runs luamemo's [Model Context Protocol](https://modelcontextprotocol.io/)
server (`mcp/server.lua`) over stdio. An MCP client — Claude Code, VS Code (Copilot
agent mode), Cursor, Claude Desktop, Continue.dev, … — starts it and calls its tools
to search, write and maintain memories, read the codebase map and use stored
secrets. It works on the project's database (a SQLite file) in-process: there is no
server to run beside it and no network connection to a database.

## The entry

Every client gets the same entry, and nothing secret is in it:

```json
{ "mcpServers": { "luamemo": { "command": "/usr/local/bin/memo", "args": ["mcp"] } } }
```

`memo mcp --print-config` prints it with `memo`'s absolute path (an app started from
the desktop may not have your `PATH`), in the shapes clients use, and the
`claude mcp add` line. `memo calibrate` writes it for the clients it finds (asking
first) and replaces the entry it wrote before `memo mcp` — `luajit …/mcp/server.lua`
with `MEMO_*` settings in `env`; an entry you wrote yourself is kept.

| Client | Where | Notes |
|---|---|---|
| Claude Code | the luamemo plugin (`.claude-plugin/`, starts `memo mcp` and adds the session-start hook), or `claude mcp add luamemo -s user -- /path/to/memo mcp` | started in the project's folder — one registration serves every project |
| VS Code | `.vscode/mcp.json`: `"servers"`, with `"type": "stdio"` | `"args": ["mcp", "--project", "${workspaceFolder}"]`; add `"chat.mcp.autoStart": true` to VS Code's settings |
| Cursor | `~/.cursor/mcp.json`: `"mcpServers"` | `"args": ["mcp", "--project", "${workspaceFolder}"]` |
| Claude Desktop | `claude_desktop_config.json` — macOS `~/Library/Application Support/Claude/`, Linux `~/.config/Claude/` | no project of its own: one entry per project, `"args": ["mcp", "--project", "/path/to/project"]` |
| Continue.dev | `~/.continue/config.yaml` | `experimental.modelContextProtocolServers: [{ transport: { type: stdio, command: /path/to/memo, args: [mcp] } }]` |

Restart (reconnect) the client after adding it; the tools appear in its tool list.

## Which project, which settings

`memo mcp` reads the settings like every `memo` command
([SETTINGS.md](../SETTINGS.md)): the project's `.luamemorc` over `~/.luamemorc` over
the environment. **The project** is `--project PATH`, else `MEMO_PROJECT`, else the
nearest folder upward from where the client starts the server that holds a
`.luamemorc` (`memo calibrate` writes it) — so a client that starts it in the open
project needs no `--project`. A `.luamemorc` memo didn't write (committed to git,
downloaded with the project, edited by hand) is used only after `memo config trust`.

Settings are read when the server starts — after `memo config set`, restart the
server in your client. The tools read every setting (`memory_status` with
`details: true`) but change none. A setting you keep only in your shell's
environment doesn't reach a server a GUI app starts: `memo calibrate` offers to
save the ones the server needs in `.luamemorc`.

No settings at all: the server still starts, and every tool answers with what to
do (run `memo calibrate`, pass `--project`, or trust the project's file).

Started directly — `luajit mcp/server.lua`, as entries before `memo mcp` did — the
server reads the same files, but there a variable the client's `env` passes wins.

## Protocol

The server speaks MCP **2026-07-28** — stateless: each request carries its version
and the client's capabilities in `_meta`; `server/discover` names the versions,
capabilities and usage rules; results say `resultType` and carry caching hints —
and the earlier, `initialize`-based revisions **2025-11-25, 2025-06-18, 2025-03-26
and 2024-11-05**, each client at the version it asks for (a version it doesn't know
gets 2025-11-25 from `initialize`, or error -32022 with the supported list). JSON-RPC
batches (2025-03-26) are answered as one array.

**Usage rules.** `initialize` and `server/discover` return
[instructions.md](instructions.md) as `instructions`: call `memory_brief` at the
start unless the session-start hook already put the brief in context, search before
answering, write as you go, keep secrets out of the chat, leave the people's
decisions to them. The skill (`skills/session-memory/SKILL.md`) and the agent
(`agents/luamemo.agent.md`) carry the same rules, word for word (a test checks).

**Old clients.** The server records what each client says about itself — name,
version, protocol, the names of its capabilities — in `~/.config/luamemo/clients.json`
(nothing secret). A client older than 2025-03-26 can't receive the usage rules:
`memo doctor` and `memo calibrate` name it, and the first `memory_brief` of a
session tells the agent, so it can tell you. (Roots are not used — deprecated since
2026-07-28; the project comes from the folder or `--project`.)

Check it by hand:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  | memo mcp
```

One line of JSON comes back with `protocolVersion`, `serverInfo`, `capabilities`
and `instructions`.

## Tools

27 tools. When a call names no scope, the project's `MEMO_SCOPE` applies (else
`MEMO_DEFAULT_SCOPE`).

**Token cost.** A client puts every tool's description in each session's context (an
API-billed agent pays for it on every request unless it is cached), so they are short —
the usage rules come once, as the server's instructions. The whole list is about
15 KB of JSON; `MEMO_MCP_TOOLS=core` offers only the 16 everyday tools (brief, search,
write, recent, get, update, delete, promote, sense, status, the `index_*` tools,
`secret_list`, `secret_execute`; about 10 KB) and leaves the rest on `memo`. Answers are
compact too: search, recent and get rows carry the text and where it lives, not the
scoring internals (`verbose: true` returns whole rows), a write answers with the new
memory's id, scope, kind, title and tier, not the text the agent just sent, and the
`index_*` tools answer in plain text.

### Memories

| Tool | Parameters | Notes |
|---|---|---|
| `memory_brief` | `scope` | The session brief, as text: the scope and its latest memories, the codebase map, what waits for the user (org pairing, proposals) — what the session-start hook injects. Call it at the start when the brief isn't in context |
| `memory_search` | `query`; `scope` or `scopes` (a list, searched together); `kind`, `limit`, `since`, `until` (ISO 8601 or Unix seconds), `tier_min` (default 1 — hides ephemeral tier 0), `tier_max`, `metadata_filter` (`{"key": value}`), `min_score`, `rerank` (true / false), `hybrid_weights` (`{"vector": …, "fts": …}`), `project` (narrows an `org:` scope to one project), `ignore_decay`, `verbose` | Hybrid vector + full-text search, weighted by importance, age and tier. Compact rows (id, title, body, kind, scope, tier, created_at, score; tags / metadata when set). The result also carries `facts`: the knowledge-graph facts the query is about — current value, since when, the previous value ([KG.md](../KG.md)) |
| `memory_write` | `title`, `body`, `scope`, `kind`, `tags`, `metadata`, `importance` (0–10, default 1), `decay_rate` (per day), `tier` (0–3), `dedup_strategy` (`update` merges a near-duplicate, `skip`, `append`), `created_at`, `verbose` — or `items`: up to 100 memories, each answered on its own | Answers with the memory's id, scope, kind, title and tier (`verbose`: the whole row) |
| `memory_recent` | `scope`, `kind`, `limit`, `offset`, `tier_min` (default 1 — hides ephemeral tier 0), `verbose` | The newest first, compact rows as search's |
| `memory_get` | `id`, `verbose` | A compact row as search's (`verbose`: the whole row) |
| `memory_update` | `id` + the fields to change, `verbose` | Re-embedded when title or body change; answers with the memory's id, scope, kind, title and tier (`verbose`: the whole row) |
| `memory_delete` | `id` — or `scope` (+ `kind`, `metadata_filter`) to delete by filter | By filter, the first call previews (how many, a few titles) and returns a `confirm` token; the same call with the token deletes. The token is bound to the filter, the count and the database and lasts 5 minutes. A dev's org replica and approved org knowledge never match |

### Sessions and maintenance

| Tool | Parameters | Notes |
|---|---|---|
| `memory_promote` | `from_scope`, `to_scope`, `delete_source`, `dry_run`, `limit`, `min_rows` | Fold a session scope into one summary in a long-term scope ([SESSION_CONTINUITY.md](../SESSION_CONTINUITY.md)) |
| `memory_digest` | `scope`, `threshold`, `dry_run` | Consolidate ephemeral memories, promote proven ones |
| `memory_consolidate` | `scope`, `similarity_threshold`, `decay_threshold`, `max_rows`, `dry_run` | Expire decayed memories, group near-duplicates (merged by the summarizer) |
| `memory_summarize` | `scope`, `weight_threshold`, `retention_days`, `batch_size`, `max_batches`, `dry_run` | Fold old, low-weight memories into summaries (`MEMO_SUMMARIZER_ADAPTER`; `noop` joins them without a model) |
| `memory_status` | `verbose`, `details` | Rows per scope; `details`: every setting, its value and where it came from |
| `memory_reconnect` | — | Re-open the database file (after a restore) |
| `memory_diary_write` / `memory_diary_read` | `agent_name`, `entry`, `topic` / `agent_name`, `last_n` | A named agent's own diary in `diary:<agent_name>` |

### Learning and tuning

| Tool | Parameters | Notes |
|---|---|---|
| `memory_sense` | `turns` (`[{role, text}]`, oldest first), `scope`, `generative`, `min_similarity` | Corrections, standing rules and praise from the conversation the agent relays, recorded on the memories they concern. Idempotent |
| `memory_learn` | `action` (`run`, `status`, `rollback`), `scope`, `dry_run`, `min_samples`, `margin` | The scope's learned reranker: trained on that feedback, promoted only if it beats the current one on held-out data |
| `memory_tune_weights` | `scope`, `samples` (50), `metric` (`r_at_1`, `r_at_3`, `r_at_5`, `r_at_10`, `mrr`) | Which vector / full-text blend finds the scope's memories best — a report with the `memo config set` command a person runs to apply it |
| `memory_embed` | `text`, `compare_to`, `include_vector` | The embedder's model and vector size; the cosine of two texts |

### Code, secrets

(The knowledge graph has no tool of its own: its facts come with `memory_search`,
and people record and query them with `memo kg`.)

| Tool | Parameters | Notes |
|---|---|---|
| `index_search` | `query`, `kind`, `limit`, `scope`, `project` | Where code lives: `path:line — name (type) — doc` lines |
| `index_outline` | `path`, `scope`, `project` | Everything one file defines |
| `index_explore` | `query`, `limit`, `scope`, `project` | A symbol's callers and callees |
| `index_status` | `scope`, `project` | Whether a code map exists, and its size |
| `secret_list` | — | Names and metadata only |
| `secret_execute` | `name`, `url`, `method`, `headers`, `body`, `multipart`, `timeout_ms`, `max_bytes` | An HTTP request with `{secret}` filled in server-side; only the response body comes back, the value masked in it, at most `max_bytes` (default 64 KB; `truncated` says it was cut). Uploads: regular files inside the project only, never hidden or credential files |
| `secret_delete` | `name`, `confirm` | Two calls: the first shows which secret and returns a `confirm` token (5 minutes); the second, with it, deletes |
| `secret_store` | `name`, `value`, `description` | Adds a new secret — never replaces one (the user's `memo secret-store NAME`). Don't call it from chat — the value would reach the model. People run `memo secret-store NAME` in a terminal (it prompts without echo) |

### Prompt

`session_start` (arguments `scope`, `project`): the instructions for a session —
reload context with `memory_search` and `memory_recent`, write decisions as you
go, summarize at the end, keep secrets out of the chat — plus the scope's
current knowledge-graph facts.

## Troubleshooting

Run with `MEMO_DEBUG=1` to log every JSON-RPC message to stderr (your client's
MCP log shows it — VS Code: **MCP: List Servers → Show Output**; Claude Desktop:
**Developer → MCP**).

- **"luamemo has no database for this project yet"** — no `.luamemorc` from the
  folder the client started the server in upward (or it names no `MEMO_DB`). Run
  `memo calibrate` in the project, or add `--project /path/to/project` to the
  entry's `args`; then restart the server in the client.
- **"… is ignoring …/.luamemorc — it is committed to the repository" / "memo didn't
  write it"** — review the file, then `memo config trust` in the project.
- **The tools don't appear** — the client can't start `memo`: GUI apps often don't
  see your shell's `PATH` (macOS especially); use the full path
  (`memo mcp --print-config` prints it).
- **"memo mcp: mcp/server.lua not found"** — the rock is incomplete or moved:
  reinstall it (`luarocks install luamemo`).
- **A library message** (`libsqlite3` / `libsodium` not found or too old, or
  "luamemo runs on LuaJIT") — install the package it names, or point
  `MEMO_LIB_SQLITE3` / `MEMO_LIB_SODIUM` at a copy. `memo ping` shows what it loads.
- **A setting refused** (e.g. "MEMO_EMBEDDER must be one of …") — `memo config
  check` names every problem; an invalid embedder, dimension, role or org-share
  value stops luamemo rather than fall back.
- **Writes fail, search works** — usually the embedder: `memo ping` checks it.
- **The agent never calls `memory_brief`** — an old client may not pass the usage
  rules on: `memo doctor` says so; until it's updated, the skill, the agent or the
  hook carry them.

See also: the main [README](../README.md) and the
[MCP specification](https://modelcontextprotocol.io/specification).
