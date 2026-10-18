# luamemo

**Private, local memory for AI agents — an MCP server.**

Coding agents forget: a new session starts cold, compaction drops the decisions
that mattered, another machine knows nothing. luamemo gives your agent a memory
that lives on your computer. The agent writes down decisions, facts and plans as
it works, and finds them again in later sessions — through the
[Model Context Protocol](https://modelcontextprotocol.io/), so Claude Code,
VS Code (Copilot agent mode), Cursor, Claude Desktop and other MCP clients can
use it. The `memo` command-line tool sets it up and keeps the decisions that
belong to people: settings, backups, which devices join your team's memory and
which knowledge the team shares.

- **Nothing to run, nothing to sign up for.** Each project's memory is one
  SQLite file in your home directory. No database server, no Docker, no account,
  no telemetry.
- **No credentials in config files.** API keys live in an encrypted vault; the
  agent can use them without ever seeing them, and settings refer to them by name.
- **Small.** LuaJIT and two system libraries (SQLite, libsodium) — on Linux,
  macOS, and Windows through WSL.

[Quick start](#quick-start) · [What it does](#what-it-does) · [MCP tools](#mcp-tools) ·
[Connect a client](#connect-any-mcp-client) ·
[memo](#the-memo-cli) · [Settings](#settings) · [Your data](#where-your-data-lives) ·
[Team memory](#team-memory-federation) · [Security](#security) · [Benchmarks](#benchmarks)

---

## Quick start

```bash
# Debian / Ubuntu / WSL (other systems: see Install)
sudo apt install luajit luarocks libsqlite3-0 libsodium23 jq git
sudo luarocks install luamemo

cd ~/code/my-app
memo calibrate
```

`memo calibrate`, run once per project:

1. looks at this machine — GPU, RAM, Docker, a running Ollama or TEI, the
   in-process GGUF embedder — and picks the best embedder that **answers a real
   embedding here** (see [Embedders](#embedders));
2. creates the project's database (`~/.local/share/luamemo/my-app-<checksum>.db`)
   and records it with the embedder in the project's `.luamemorc`, which it keeps
   out of git;
3. reads what the project already knows into memories — agent instruction files,
   ADRs, the README, `ARCH:` / `DECISION:` comments, architectural commit
   messages (later runs read only new commits);
4. writes the MCP entry for the clients it finds (VS Code, Cursor, Claude
   Desktop) — `memo mcp`, nothing secret in it — prints it for any other client,
   and installs the VS Code agent plugin.

Then:

```bash
memo ping           # SQLite, libsodium, the database, the embedder — PASS / FAIL each
memo index ingest   # optional: the codebase map behind the index_* tools
```

Open your agent and ask what it remembers about the project. From there it
searches and writes on its own — the tool descriptions tell it when.

**Claude Code**: install the luamemo plugin, or register the server once for
every project — Claude Code starts it in the project's folder, and `memo mcp`
reads that project's `.luamemorc`:

```bash
claude mcp add luamemo -s user -- "$(command -v memo)" mcp
```

Other clients: [Connect any MCP client](#connect-any-mcp-client).

---

## What it does

**Remembers across sessions.** The agent writes memories — a `title`, a `body`,
a `kind` (`decision`, `fact`, `plan`, `summary`, anything you like), `tags`,
`metadata` — into a **scope** (`repo:my-app`, `user:me`, `session:<id>`, …) and
searches them later. Search is hybrid: exact vector similarity over every memory
in scope **plus** full-text ranking, blended, then weighted by each memory's
importance and age. Several scopes can be searched at once; a query that names a
time ("last week", "in June") favours memories from then, and `since` / `until`
cut by date; metadata filters, tier filters and an optional reranker refine. A near-duplicate write merges into the memory it
repeats instead of piling up copies.

**Keeps what matters on top.** Every memory has an `importance` (0–10, default
1) and an optional daily `decay_rate`, and sits in a **tier**: 0 ephemeral,
1 working, 2 consolidated, 3 core. With self-maintenance on (calibrate turns it
on), writes trigger a debounced digest that promotes memories proven useful,
folds related ones into observations and lets stale scratch notes fade —
nothing has to schedule it. Old, low-weight memories can be summarized (with or
without an LLM).

**Maps your codebase.** `memo index` turns a repository into searchable rows —
files, functions/classes/methods with their line numbers, import edges, commit
diffs — so the agent finds *where* code lives (`index_search`) and *what* a file
defines (`index_outline`) before grepping or reading files. See
[Codebase index](#codebase-index).

**Learns from use (opt-in).** The agent relays corrections ("no, we use X"),
standing rules and praise (`memory_sense`); a write that duplicates an existing
memory reveals a search that missed it. A per-scope learned reranker trains on
those signals and is promoted only when it beats the current one on held-out
data. See [Learning from use](#learning-from-use).

**Knows what is true now.** Facts that change over time — a rule, a preference,
a version — are kept as `(subject, predicate, object)` triples with validity
windows: the current value, the value on a date, the whole history. A search
returns the facts its question is about alongside the memories, so an agent sees
the current value even when old memories still repeat the previous one. See
[KG.md](KG.md).

**Uses secrets without seeing them.** API keys are stored encrypted; the agent
makes HTTP requests with `{secret}` filled in server-side and gets only the
response. See [Secrets](#secrets).

**Shares with your team, on your network.** One instance can serve as the org's
central on your LAN or VPN: it holds the org's standards as protected
directives, reviews knowledge the devs' machines propose, and learns from
everyone's feedback; each dev keeps a read-only, offline copy. Devices pair with
a key and a spoken code — no passwords, no tokens. See
[Team memory](#team-memory-federation).

---

## Install

luamemo needs:

| | Version | For |
|---|---|---|
| LuaJIT | 2.1 | running luamemo; its FFI loads the two libraries below |
| SQLite (`libsqlite3`) | 3.35 or newer, with FTS5 and JSON (the usual builds) | the databases |
| libsodium | 1.0.18 or newer | the vault, device keys, the federation channel |
| luasocket (luasec for `https://`) | | embedder and API calls, federation |
| bash, jq, git | jq 1.6 or newer | `memo` and `memo calibrate` |

Optional: `lua-cjson` 2.1.0.6 or newer (faster JSON — `luarocks install lua-cjson`; a
pure-Lua fallback is bundled, and used with an older one),
[universal-ctags](https://github.com/universal-ctags/ctags) (code-map symbols for
languages beyond Lua, Python and JS/TS), and for the in-process GGUF embedder
either nothing (`memo gguf install` downloads the release's prebuilt runtime for
Linux x86_64 and macOS arm64, checked against the checksum the rock ships) or a C
toolchain + cmake to build it (`luamemo/embedders/native/build.sh`).

| System | Packages |
|---|---|
| Debian, Ubuntu, WSL | `sudo apt install luajit luarocks libsqlite3-0 libsodium23 jq git` |
| Fedora | `sudo dnf install luajit luarocks sqlite-libs libsodium jq git` |
| macOS (Homebrew) | `brew install luajit luarocks sqlite libsodium jq` — Homebrew's LuaRocks is for Lua 5.4: install the rock with `luarocks --lua-version 5.1 --lua-dir "$(brew --prefix luajit)" install luamemo` (luamemo finds Homebrew's libraries itself) |
| Windows | WSL (Ubuntu), then as above. Keep the data on the Linux side (the default): a database on a Windows drive (`/mnt/c/…`) works but is about 47× slower. |

Then install the rock — with the LuaRocks your system packages (Lua 5.1 or LuaJIT;
`memo` runs LuaJIT itself), system-wide or for your user only:

```bash
sudo luarocks install luamemo          # or: luarocks --local install luamemo
sudo luarocks install luasec           # only for https:// embedders and APIs
memo ping                              # (--local: ~/.luarocks/bin on your PATH)
```

`memo ping` says which copy of each library it loaded and its version. To use
another copy, point `MEMO_LIB_SQLITE3` / `MEMO_LIB_SODIUM` at it.

---

## Where your data lives

| Path | What |
|---|---|
| `~/.local/share/luamemo/<name>.db` | one database per project (`$XDG_DATA_HOME/luamemo`; the directory is 0700, the files 0600). An org's projects on one machine share one. |
| `~/.local/share/luamemo/backups/` | `memo backup`'s copies |
| `~/.config/luamemo/` | `vault.key` (the vault's key), `keyring.db` / `keyring.key` (this device's identity), `orgs.json` (which database each org uses), `trusted_rc` (settings files you trusted), `clients.json` (the MCP clients that started luamemo: names and versions) — `MEMO_FEDERATION_DIR` moves it |
| `<project>/.luamemorc` | the project's settings: which database, which embedder (kept out of git) |
| `~/.luamemorc` | settings for every project |

A database holds the project's memories and their vectors, knowledge-graph
facts, observations, feedback, learned weights and the vault's encrypted
secrets. SQLite's write-ahead log lets the MCP server, `memo` and the hooks use
it at the same time.

```bash
memo backup                           # a consistent copy, safe while agents use the database
memo backup ~/safe/my-app.db
memo export > my-app.jsonl            # memories + facts as JSON Lines (vectors too, unless --no-vectors)
memo import my-app.jsonl --db other   # into another database — re-embedded if its embedder differs
```

A backup is the database alone: keep `~/.config/luamemo/vault.key` too, or the
secrets in it can't be read. Importing the same export twice adds nothing.
Moving to another embedder: `memo config set …` then `memo reembed --all`
([EMBEDDERS.md](EMBEDDERS.md)).

---

## MCP tools

The server (`memo mcp`, stdio) gives a client 27 tools:

| Tool | What it does |
|---|---|
| `memory_brief` | The session brief: the project's scope and latest memories, its codebase map, what waits for the user — the same text the session-start hook injects |
| `memory_search` | Hybrid search: `query`, `scope` or `scopes`, `kind`, `limit`, `since` / `until`, `tier_min` / `tier_max`, `metadata_filter`, `min_score`, `rerank`, `hybrid_weights`, `project`, `ignore_decay`. Results carry `facts` — the current values (and previous ones) of what the query is about |
| `memory_write` | Store a memory — or up to 100 at once (`items`); `importance`, `decay_rate`, `tier`, `dedup_strategy`, `created_at` |
| `memory_recent` | The newest memories of a scope (`kind`, `limit`, `offset`, `tier_min`) |
| `memory_get` / `memory_update` | One memory by id; change its fields (re-embedded when the text changes) |
| `memory_delete` | Delete one by `id` — or every memory matching a filter, in two calls: a preview with a confirmation token, then the delete |
| `memory_promote` | Fold a session scope into one summary in a long-term scope ([SESSION_CONTINUITY.md](SESSION_CONTINUITY.md)) |
| `memory_digest` / `memory_consolidate` | Maintenance: promote proven memories, group related ones, expire decayed ones (`dry_run` to preview) |
| `memory_summarize` | Fold old, low-weight memories into summaries (`dry_run` first) |
| `memory_sense` | Record corrections, rules and praise from the conversation the agent relays — how memory learns |
| `memory_learn` | The scope's learned reranker: `run` (train, promote only if better), `status`, `rollback` |
| `memory_embed` | What the embedder makes of a text; how similar two texts are |
| `memory_tune_weights` | Which vector / full-text blend finds this scope's memories best (a report — people apply it) |
| `memory_status` | Row counts per scope; with `details`, every setting in force and where it came from |
| `memory_reconnect` | Re-open the database file (after a restore) |
| `memory_diary_write` / `memory_diary_read` | A named agent's own diary (`diary:<agent>`) |
| `index_search` / `index_outline` / `index_explore` / `index_status` | The codebase map: find code, outline a file, a symbol's callers and callees, whether a map exists |
| `secret_list` / `secret_execute` / `secret_delete` | The vault: names only / an HTTP request with `{secret}` filled in server-side / remove one |
| `secret_store` | Store a secret — **from the terminal instead** (`memo secret-store`): a value typed in chat reaches the model |

When a call names no scope, the tools use `MEMO_SCOPE` (calibrate sets it to
`repo:<project>`). With the tools, the server sends every client its usage rules
as MCP `instructions` ([mcp/instructions.md](mcp/instructions.md): start with the
brief, search before answering, write as you go, never ask for a secret in chat —
the same rules the skill and the agent carry). It also offers a `session_start`
prompt. Settings are read-only over MCP — people change them with `memo config`.

What it costs an agent in tokens is kept down: the tool list is about 15 KB
(`MEMO_MCP_TOOLS=core` offers the 16 everyday tools in about 10 KB), search and
recent rows leave out the scoring internals (`verbose: true` for whole rows), and a
write doesn't echo back the text it was sent. More in [mcp/README.md](mcp/README.md).

---

## Connect any MCP client

Every client gets the same entry — `memo`, with `mcp` — and nothing else: no
database path, no `MEMO_*` variables, nothing secret. `memo mcp` reads the
project's `.luamemorc` (over `~/.luamemorc`) like every `memo` command.
`memo mcp --print-config` prints it with `memo`'s absolute path (an app started
from the desktop may not have your `PATH`):

```json
{ "mcpServers": { "luamemo": { "command": "/usr/local/bin/memo", "args": ["mcp"] } } }
```

**Which project.** The nearest folder upward from where the client starts the
server that holds a `.luamemorc`. Clients that start it in the open project need
nothing more; where a client has a workspace variable, pass it —
`"args": ["mcp", "--project", "${workspaceFolder}"]` — and for a client with no
project at all, the folder itself: `["mcp", "--project", "/path/to/project"]`.
Without settings the server still starts, and every tool answers with what to do.

| Client | Its config | The entry |
|---|---|---|
| Claude Code | the luamemo plugin, or `claude mcp add luamemo -s user -- /path/to/memo mcp` | started in the project's folder |
| VS Code | `.vscode/mcp.json` (`"servers"`, `"type": "stdio"`) | `--project ${workspaceFolder}` |
| Cursor | `~/.cursor/mcp.json` (`"mcpServers"`) | `--project ${workspaceFolder}` |
| Claude Desktop | `claude_desktop_config.json` (`"mcpServers"`) | `--project /path/to/project`, one entry per project |
| others | their MCP settings | `mcp`, or `--project` |

`memo calibrate` writes the entry for VS Code, Cursor and Claude Desktop when it
finds them (asking first), replaces the entry it wrote before `memo mcp` (a server
path and `MEMO_*` settings) and keeps one you wrote yourself.

**Protocol.** The server speaks MCP 2026-07-28 (stateless, `server/discover`) and
the earlier revisions down to 2024-11-05, each client at its own version. A client
older than 2025-03-26 can't receive the usage rules; `memo doctor` (and calibrate)
name such a client, and the brief tells the agent. Clients that never connected
are listed by neither — open the client once, then run `memo doctor`.

---

## The memo CLI

`memo help` lists every flag. The commands:

| Command | What it does |
|---|---|
| `memo calibrate` | Set up a project: embedder, database, existing knowledge, MCP clients (`--help`) |
| `memo mcp [--project P]` · `--print-config` | The MCP server, as clients start it / the entry that starts it ([Connect any MCP client](#connect-any-mcp-client)) |
| `memo gguf [status / install]` | The in-process GGUF embedder's runtime: what is in use; install the release's prebuilt one |
| `memo ping` / `memo doctor` | Health check (libraries, database, embedder) / corpus health (truncation, row sizes) and MCP clients too old for something luamemo needs |
| `memo write` / `search` / `recent` / `get` / `update` | The memories, as the MCP tools do |
| `memo delete ID` · `memo delete --scope S [--kind K] [--meta JSON] [--yes]` | Delete one, or preview a filter and delete it with `--yes` |
| `memo context QUERY` | Search + current facts in one block, formatted for an agent |
| `memo brief` | The session-start digest a hook injects (memories, code map, pending org decisions) |
| `memo kg assert / query / invalidate / timeline` | The knowledge graph — recording facts is for people and their scripts; `memo search` and `memory_search` return the current ones ([KG.md](KG.md)) |
| `memo promote` / `summarize` / `digest` / `consolidate` | Session promotion and maintenance |
| `memo sense` / `memo learn SCOPE [--status / --rollback]` | Feedback signals; the learned reranker |
| `memo embed TEXT [--compare-to TEXT]` | The embedder's view of a text |
| `memo tune-weights --scope S` | Measure the best search blend; prints the `memo config set` that applies it |
| `memo reembed --scope S / --all` | Re-embed after switching embedders |
| `memo index ingest / update / search / explore / status / invalidate / diff` | The codebase map |
| `memo backup` / `export` / `import` | Copies and transfers ([Your data](#where-your-data-lives)) |
| `memo config list / get / set / unset / check / trust` | Settings ([SETTINGS.md](SETTINGS.md)) |
| `memo secret-store / secret-list / secret-delete / secret-execute` | The vault |
| `memo org …` / `memo serve` | Team memory: a dev's replica and proposals; the central's pairing, review, directives |
| `memo setup` | Write first-run instructions for an agent (`SETUP_CHECK`) |

`memo` works on the database the project's `.luamemorc` names (the project is
`calibrate --root` / `mcp --project` when given, else `MEMO_PROJECT`, else the
nearest directory from here upward with a `.luamemorc`, so any subfolder works). Output is JSON unless a command says
otherwise; exit status 1 means it failed.

---

## Settings

Every setting is a `MEMO_<NAME>` line in the project's `.luamemorc`, in
`~/.luamemorc` (every project), or an environment variable — the project's file
wins. `memo config` reads and changes them:

```bash
memo config list                          # every setting, its value and where it comes from
memo config set MEMO_DEDUP_THRESHOLD 0.9  # checked (type, range), then written
memo config set MEMO_RERANK_TOP_N 10 --user
memo config check                         # values that don't parse, names luamemo doesn't read
```

- Settings files are **data**: nothing in them runs.
- A project's `.luamemorc` is used only when **memo wrote it** (`memo calibrate`,
  `memo config set`) **or you trusted it**: one committed to git, downloaded with
  the project or edited by hand is ignored until you review it and run
  `memo config trust` (again whenever it changes).
- A project's file never names code to run: `MEMO_LUA`, `MEMO_LIB_SQLITE3`,
  `MEMO_LIB_SODIUM` and `MEMO_GGUF_SHIM` are read only from the environment and
  `~/.luamemorc`.
- A credential never goes into a setting: store it with `memo secret-store NAME`
  and refer to it — `MEMO_EMBEDDER_HEADERS='{"Authorization": "Bearer {secret:NAME}"}'`.

[SETTINGS.md](SETTINGS.md) lists every setting with its default and meaning —
generated from the code (`memo config list --markdown`), so it can't fall behind.

---

## Embedders

An embedder turns text into the vectors search compares. luamemo works with:

| Embedder | Setting | Notes |
|---|---|---|
| `hash` | `MEMO_EMBEDDER=hash` (the default) | Pure Lua, in-process, instant; lexical only — matches words, not meaning |
| `gguf_ffi` | `MEMO_EMBEDDER=gguf_ffi`, `MEMO_GGUF_MODEL=…/embeddinggemma.gguf` | A real semantic model (EmbeddingGemma) run in-process on CPU through llama.cpp — no service. Its runtime: `memo gguf install` (prebuilt, Linux x86_64 / macOS arm64) or a one-time build of a small C shim |
| Ollama | `MEMO_EMBEDDER_ADAPTER=ollama`, `MEMO_EMBEDDER_URL=http://localhost:11434/api/embeddings`, `MEMO_EMBEDDER_MODEL=nomic-embed-text` | Local and free |
| TEI | `MEMO_EMBEDDER_ADAPTER=tei`, `MEMO_EMBEDDER_URL=http://localhost:8081/embed` | Hugging Face text-embeddings-inference — bge-m3 is the strongest option measured |
| OpenAI, Voyage, Cohere, any OpenAI-compatible endpoint | `MEMO_EMBEDDER_ADAPTER=openai` / `voyage` / `cohere` / `openai_compatible` + `MEMO_EMBEDDER_HEADERS` with a `{secret:NAME}` key | Hosted |

`memo calibrate` picks one that works on this machine and writes its settings;
`memo config set` changes them. A database holds one embedding space: after a
switch, `memo reembed --all` rebuilds every vector from the stored text (nothing
is lost). An embedder that rejects an input as too long gets it shortened and
retried; if it still refuses, the memory is kept without a vector (found by its
words) and the write says so. The full guide: [EMBEDDERS.md](EMBEDDERS.md).
Ranking, reranking and the search blend: [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md).

---

## Codebase index

`memo index` maps a whole repository into searchable rows so an agent can find
**where** code lives and **what** a file defines without grepping or reading
files. The map lives in its own `codeindex:<project>` scope, apart from your
memories, and costs nothing until queried.

```bash
memo index ingest                         # the whole repository (scope codeindex:<project>: MEMO_SCOPE without its repo:)
memo index update                         # only changed / new / deleted files
memo index ingest --extensions lua,py     # narrow the walk
memo index ingest --exclude dist/,fixtures/   # skip more (added to .git, vendor/, node_modules/)
memo index search "where is dedup handled"
memo index explore "store.write"          # callers and callees
memo index diff --commit HEAD             # a commit's hunks, attributed to symbols
```

**Rows:** `file` (one per file, kept out of vector search to bound embedding
cost), `symbol` (functions, classes, methods — `path`, `line`, type, exported),
`dependency` (import / require edges, also in the knowledge graph for `explore`)
and `diff` (commit hunks).

**Languages:** pure-Lua parsers for Lua, Python and JavaScript/TypeScript; for
any other language universal-ctags is used when it is on `PATH` (files are
indexed either way).

**Never indexed:** files git ignores (tracked files are kept; `--no-gitignore`
turns this off) and, whatever the flags, credential files — `.env` / `.env.*`
(templates like `.env.example` are kept), `.envrc`, `.luamemorc`, `.memorc`,
`.pgpass`, `.netrc`, `.npmrc`, `.pypirc`, `.htpasswd`, `.git-credentials`,
`*.pem` / `*.key` / `*.p12` / `*.pfx` / `*.jks` / `*.keystore`, SSH private keys,
and anything under `.ssh/`, `.aws/` or `.gnupg/`. The map is served to agents and
file rows keep each file's first line, so a credential must never land there; a
map that holds such a file is purged by the next `memo index update`.

**For agents:** `index_status` (is there a map?), `index_search` (find code —
compact `path:line — name (type) — doc` lines, not file contents),
`index_outline` (everything a file defines, before editing it), `index_explore`
(blast radius before refactoring). The map locates; the file on disk stays the
truth to read before editing.

---

## Learning from use

Turned on with `memo config set MEMO_FEEDBACK_ENABLED true`. The base embedder
never changes — only small learned layers adapt, and only when they demonstrably
help.

1. **Signals.** The agent relays the recent turns with `memory_sense` (or
   `memo sense`): explicit corrections, standing rules ("always …", "never …")
   and praise are attributed to the memories they concern (an optional
   in-process instruct model, `MEMO_GEN_MODEL`, also catches paraphrased ones).
   **Misses** are automatic: a new write that nearly duplicates an existing
   memory means a search should have found it; a correction about a memory that
   was never retrieved counts as a miss, not a mistake.
2. **Self-maintenance.** The debounced digest (`MEMO_AUTO_DIGEST_ENABLED`, on
   after calibrate) promotes memories that keep proving useful and escalates
   recurring mistakes into the core tier.
3. **Gated promotion.** `memo learn <scope>` (or `memory_learn`) turns the
   scope's feedback into training examples, trains a learned reranker and
   compares it with the current one on held-out data — promoting it **only if
   it is better**. Versions are kept per scope; `--status` lists them,
   `--rollback` goes back one; every run is recorded.

---

## Session continuity and hooks

A memory written in `session:<id>` is invisible to the next session.
`memory_promote` folds a session scope into one summary in a long-term scope at
the end, so the next session finds it — see
[SESSION_CONTINUITY.md](SESSION_CONTINUITY.md), which also lists the conventions
for capturing a conversation (scopes, kinds, dedup per kind).

**Claude Code** — besides MCP, three hooks:

- **SessionStart** (in the plugin, `hooks/hooks.json`): injects `memo brief` —
  how many memories, whether a code map exists, what waits for the org admin —
  so the agent knows what it can draw on without being asked. (Clients without
  hooks get the same text from the `memory_brief` tool; the server's instructions
  tell the agent to call it when the brief isn't in its context already.)
- **PreCompact** and **PostToolUse** (`hooks/claude/pre_compact.sh`,
  `post_message.sh`): save the last messages of the conversation into
  `session:<session id>` before Claude Code compacts the context, and at most
  every 5 minutes while it works (`MEMO_HOOK_COOLDOWN_SECS`). Add them to
  `.claude/settings.json`:

  ```json
  {
    "hooks": {
      "PreCompact": [
        { "hooks": [ { "type": "command", "command": "bash /path/to/luamemo/hooks/claude/pre_compact.sh" } ] }
      ],
      "PostToolUse": [
        { "matcher": "*", "hooks": [ { "type": "command", "command": "bash /path/to/luamemo/hooks/claude/post_message.sh" } ] }
      ]
    }
  }
  ```

  They need `memo` and `jq` on `PATH` (and `_save.sh`, which both source, beside
  them) and never block or fail the session. Anything in the conversation that
  looks like a credential is stored as `[redacted]`, as in every memory.

**VS Code** — `memo calibrate` installs the luamemo agent plugin (or run
**Chat: Install Plugin From Source** with `https://github.com/kaio326/luamemo`):
the `luamemo` agent (checks the connection, loads context on request, writes
decisions, relays feedback) and the `session-memory` skill. Add
`"chat.mcp.autoStart": true` to VS Code's settings so the server starts with
VS Code. The workspace entry calibrate writes in `.vscode/mcp.json` starts
`memo mcp --project ${workspaceFolder}`: the project's own settings and database.

---

## Secrets

The vault keeps API keys and tokens encrypted (XChaCha20-Poly1305, each value
bound to its name) in the project's database, under a key that never enters the
database: `~/.config/luamemo/vault.key`, which the first `memo secret-store`
creates. Agents can **use** a secret but never read it: there is no tool that
returns a value.

```bash
memo secret-store github-token --desc "GitHub PAT, repo scope"   # prompts; nothing echoed
memo secret-list                                                 # names and metadata, no values
```

From the agent:

```
secret_execute(name = "github-token",
               url = "https://api.github.com/repos/me/my-app/issues",
               headers = { Authorization = "Bearer {secret}" })
```

`{secret}` goes in the URL's path or query, a header value or the body — never
the host or port; the server fills it in, makes the request and returns only the
response body, with every copy of the value masked (a service that echoes the
request can't hand it back) and, over MCP, at most 64 KB of it unless the call asks
for more (`max_bytes`, up to 1 MB). A failed request's error shows your template,
never the value. **Never type a secret into the chat** — the chat is processed (and
possibly logged) by the model's provider; `secret_store` exists, but the terminal
command keeps the value out of the conversation. Over MCP an agent can add a secret
but never replace one (that is `memo secret-store`), and `secret_delete` first
shows which secret and asks for a confirm token.

The same vault serves luamemo's own HTTP calls: an embedder, reranker or
summarizer that needs a key gets a header like `Bearer {secret:openai}`, filled
in when the request is made and masked in errors. Instead of `vault.key`, the
key can come from a file you name (`MEMO_MASTER_KEY_PATH`) or an environment
variable (`MEMO_MASTER_KEY_ENV`).

**Guards on `secret_execute`:** only `http(s)://host[:port]/…` URLs without a
`user@` part; the host is resolved and **every** address must be public —
loopback, private networks, Tailscale / CGNAT, link-local, multicast and IPv6
forms that embed a private IPv4 are refused, as is a host that doesn't resolve;
an `http://` request connects to the address that was checked (DNS rebinding
can't redirect it); redirects are never followed; a file the MCP tool uploads
must be a regular file inside the project (symlinks resolved) and never a hidden or
credential file (`.env`, keys, `.luamemorc`, …) — and there are no uploads when the
server runs outside a project.

---

## Team memory (federation)

One binary, three roles — chosen by configuration, never detected:

| Role | Set up with | What it does |
|---|---|---|
| **solo** (default) | nothing | Everything local, one database per project. Federation is inert. |
| **dev** | `memo calibrate --org-url URL --org-fingerprint FP` | Joins the org's central on your network: a **read-only local replica** of `org:<name>` (searchable offline), the org's promoted reranker, feedback on org memories pushed up, and filtered project knowledge **proposed** for the admin to approve. All of one org's projects on the machine share one database. |
| **org central** | `memo calibrate --role org --org-name NAME` | Serves the org (`memo serve`), holds its **directives** in a protected tier, reviews the devs' proposals and learns from everyone's feedback. |

**Local network only — we hold no servers.** `memo serve` binds only to
loopback, private (10/8, 172.16/12, 192.168/16, IPv6 ULA / link-local) or
Tailscale (100.64/10, fd7a:115c:a1e0::/48) addresses and drops public peers; a
dev refuses a central whose address resolves to a public IP. It serves many
connections at once — a slow client can't hold up the others.

**No passwords, no tokens — keys and a pairing code (the SSH model).** The
central has an Ed25519 identity whose **fingerprint** (`XXXX-XXXX-XXXX-XXXX-XXXX`)
is public: the admin hands it out with the address. A dev's machine creates its
own key on first join (`~/.config/luamemo`, encrypted at rest, never leaves the
machine). Joining pins the central's key and asks to pair: both sides derive the
same short **pairing code** (`XXXX-XXXX`) from the two public keys, the dev reads
it to the admin, and the admin approves exactly that code (`memo org devs
approve <CODE>`) — a man in the middle would produce a different code. Nothing
secret is typed, printed or sent, which is also why an agent can run every step
but the admin's approval. Pairing requests are limited per address, expire
after 24 h, and `memo org devs clear-pending` drops them all.

**Encrypted, mutually authenticated channel** (protocol 3, libsodium). A
one-round handshake — Ed25519-signed transcripts, ephemeral X25519 keys,
HKDF-SHA256 session keys, so past sessions stay safe if a key leaks later — then
every message is sealed with XChaCha20-Poly1305 under a key per direction, with
numbered messages so none can be replayed or reordered. Unknown, pending or
removed keys are refused before any expensive work, and so is anyone who merely
knows a device's public key: each handshake carries a MAC only that device and
the central can compute (a static X25519 agreement of their identity keys). A
central and a dev of different protocol versions refuse each other with a
message saying which side to upgrade.

**One org database per machine; project tags.** A dev's first project of an org
records its database as the org's on this machine (with the embedder it was
built with); later projects of the org join it, each keeping its own
`repo:<project>` scope. A project that already has memories is offered a copy
into it (`memo org adopt`; the old database is never modified). Org memories can
carry a project tag: `memory_search` with `project = "api"` narrows the `org:`
scope to that project's memories plus the org-wide ones.

**Directives — the protected core tier.** On the central, `memo org directives
./standards` turns Markdown standards into org directives (tier 3, never
decaying; one per `#` / `##` section; re-run on change — edited sections update
in place, removed ones go; a skipped or unreadable file stops the pruning).
`--project api` tags them for one project. Nothing else can write that tier, and
on a dev every `org:` scope is read-only.

**Down (sync).** A dev refreshes the replica at session start (`memo brief`), on
an org-scope search once it is stale (`MEMO_ORG_SYNC_TTL`, 15 min), or with `memo
org sync`. Pulls are paged, resumable and time-boxed; a versioned manifest keeps
the replica exact. The central's vectors are reused when both sides embed alike,
else rows are re-embedded locally. A failed pull keeps the last replica.

**Up (feedback).** Reinforcements on org memories — and, with the default
`MEMO_ORG_SHARE=triples`, the searches behind them — are pushed and attributed
to the identity the device paired with, never to what a push claims. With
`MEMO_ORG_SHARE=signals` no query text, note or proposal ever leaves the
machine.

**Knowledge proposals (dev → admin → org).** A dev never pushes its memories
wholesale. A deterministic filter (no LLM) proposes a memory only if it is a fact
or decision of a `repo:` scope, **proven by use**, free of anything
secret-looking and of first-person preference or style, **grounded in the code**
(it names a file or symbol of the project's code map), and new to the org. The
central re-checks, merges the same knowledge from several devs, and keeps
rejected content rejected until it changes; the admin decides (`memo org review`
→ `approve` / `reject` / `approve --top N`). Approved knowledge enters the org at
tier 1 with its project tag and decays unless used (`MEMO_ORG_KNOWLEDGE_DECAY`,
0.01/day); use revives it, and only the admin removes it. Devs see their side
with `memo org proposals [candidates --explain | withdraw | private]`.

**Central learning.** `memo org aggregate` (schedule it) digests the org scope
and runs the promotion gate over every dev's feedback, plus a **directives
gate**: a candidate reranker that pushes any directive out of the results the
current one keeps it in is rejected. Devs pull a promoted reranker on their next
sync.

```bash
# the admin — the central's memory is built by hand, nothing is ingested automatically
memo calibrate --role org --org-name acme        # identity + the join command for devs
memo serve --host 100.64.0.10 --port 8765        # a LAN / Tailscale address
memo org directives ./standards                  # org-wide; --project api for one project
memo org devs pending
memo org devs approve K7Q2-9XRM                  # ONLY after the dev read you the same code
memo org review                                  # proposals: show / approve / reject
memo org aggregate                               # schedule it (cron / systemd timer)

# a dev — per project; the first one pairs, the others join the same org database
memo calibrate --org-url http://100.64.0.10:8765 --org-fingerprint ABCD-EFGH-JKMN-PQRS-TVWX
memo org status | sync | proposals
memo calibrate --role solo                       # leave the org
```

Then search the org with the project: `memory_search` with `scopes =
["repo:my-app", "org:acme"]` (and `project = "my-app"`) — directives rank first.

---

## Security

- **Local by default.** Memories stay in files only you can read (directory
  0700, files 0600). luamemo connects only where you point it: the embedder,
  reranker or summarizer you configure, `secret_execute`'s targets, your org's
  central; calibrate also probes local services (Ollama, TEI, Docker) and clones
  the VS Code plugin from GitHub. No telemetry.
- **Settings files are data, and a project's must be memo's or trusted.** A
  `.luamemorc` is parsed, never run; one memo didn't write (it came with a
  repository or a download, or was edited) is ignored until you review it
  (`memo config trust`), so a cloned or downloaded project can't point your
  embedder or database elsewhere — or send your vault's keys there. Nor can it name
  a program or library for luamemo to load: only your own settings do.
- **Secrets stay out of the model's context and out of files** — the vault
  (above): no tool returns a value, headers refer to secrets by name, errors
  mask them.
- **HTTPS is always verified**: the certificate chain against the system's CAs
  (`SSL_CERT_FILE` / `SSL_CERT_DIR`, else the OS bundle) and the certificate
  against the host name. A self-hosted service with its own CA:
  `MEMO_CA_FILE=/path/ca.pem` (trusted in addition). No CA found → https is
  refused, saying what to set. There is no switch to turn verification off, and
  redirects are never followed.
- **The codebase map never stores credential files** (above).
- **Bulk deletes over MCP need a confirmation**: a preview and a token bound to
  that filter, count and database, valid 5 minutes. A dev's org replica and the
  org's approved knowledge are never matched.
- **Team memory** is LAN/VPN-only, key-paired, end-to-end encrypted, and leaves
  the admin's decisions (pairing, proposals) to the admin.

---

## Benchmarks

Retrieval recall — does the memory that answers the question come back in the
top k? — on four public conversational-memory benchmarks and a project-specific
one, with three embedders. Measured on this version's store (October 2026, the
same vectors as the previous Postgres store, which the change matched within
±0.4 points on every number):

| Benchmark | hash (pure Lua) R@1 / R@5 / R@10 | nomic-embed-text (Ollama) | bge-m3 (TEI) |
|---|---|---|---|
| Project personalization (36 questions) | 58.3 / 88.9 / 94.4 | 72.2 / 97.2 / 100 | 94.4 / 100 / 100 |
| LongMemEval, oracle (500) | 100 / 100 / 100 | 99.8 / 99.8 / 99.8 | 100 / 100 / 100 |
| LoCoMo | 45.3 / 68.8 / 82.6 | 52.9 / 77.3 / 87.7 | 58.3 / 84.6 / 92.3 |
| ConvoMem | 82.8 / 96.5 / 96.5 | 90.2 / 96.5 / 96.5 | 92.0 / 96.5 / 96.5 |
| MemBench (8,500, hash) | 42.5 / 72.9 / 83.6 | | |

On the harder LongMemEval `_s` split (500 questions, ~50 sessions of haystack
each), measured on the previous store: bge-m3 **87.0 % R@1, 96.4 % R@5, 98.6 %
R@10** — on par with systems that summarize every session with an LLM, with
single-stage retrieval and no LLM at all.

**Search latency** (one scope, 384-dimension vectors, median of 15 searches;
every search exact — every vector in scope is scored):

| Memories in scope | 1,000 | 5,000 | 20,000 | 100,000 |
|---|---|---|---|---|
| this version | 3.9 ms | 18.3 ms | 71 ms | 233 ms |
| previous store (Postgres, brute force) | 136 ms | 167 ms | approximate above 10k | — |

The harness, datasets and how to reproduce: [eval/README.md](eval/README.md);
full analyses in [eval/results/](eval/results/).

---

## How it works

```
  MCP client ──stdio──▶ memo mcp ──▶ mcp/server.lua ─┐
                                                     ├─▶ luamemo (Lua) ──FFI──▶ SQLite file (WAL)
  you / hooks ────────▶ memo (bash) ─────────────────┘        │        └─FFI──▶ libsodium
                                                              └──▶ embedder: in-process (hash, GGUF) or HTTP
  org central ◀──encrypted channel (LAN/VPN)──▶ memo serve
```

- **Storage:** one SQLite file per database through LuaJIT's FFI — memories with
  their float32 vectors as BLOBs, an FTS5 full-text index kept in step by
  triggers, the knowledge graph, feedback, learned weights, the vault.
  Timestamps are integer microseconds; JSON columns are text.
- **Search:** the candidates are the exact vector top-N **plus** the full-text
  top-N (N ≥ 50). Text is ranked with Postgres' cover-density `ts_rank_cd`,
  reimplemented as an FTS5 function (BM25 measured worse here). The two scores are
  normalised and blended (`MEMO_HYBRID_WEIGHTS`, 0.7 / 0.3), boosted for quoted
  phrases, names and time expressions, and weighted by
  `importance × e^(−decay_rate × days)` and the tier (so across several scopes
  an org directive outranks a working note); then the optional reranker and the
  limit.
- **Writes:** embedded, checked for a near-duplicate in the scope (merged by
  default), scanned for stated preferences, and — with feedback on — checked for
  an existing memory a search should have found (a miss). A database holds one
  embedding space (fixed by its first vector).
- **The Lua API is internal.** The CLI, the MCP server, `memo serve` and the
  maintenance are built on it; programs should use `memo` or MCP, which carry
  every capability.

Main modules: `store` (writes, search, dedup, tiers), `db` / `native.sqlite`
(the database), `fts` (the text ranker), `embed` + `embedders/` + `adapters/`,
`kg`, `digest` / `consolidate` / `summarizer` (maintenance), `feedback` /
`sensing` / `promote` / `learner_store` (learning), `index/` (the code map),
`secrets` / `native.sodium` (the vault), `settings` (every setting),
`transfer` (export / import), `federation/` (team memory), `ops` (the operations
`memo` and the MCP server share — their arguments read in one place), `cli/`
(`memo`'s commands) and `mcp/server.lua`.

---

## Upgrading from 0.4

This version is a new foundation: SQLite through LuaJIT instead of PostgreSQL.
There is no database server, no `memo migrate` and no `MEMO_DB_URL` any more —
luamemo warns about the old names and says what replaced them. Pre-1.0, an old
database isn't converted automatically. Per project:

1. Install this version (LuaJIT + SQLite + libsodium, [Install](#install)) and
   run `memo calibrate` — it creates the project's new database.
2. To bring the old memories along, export them from Postgres as JSON Lines and
   import them (they are embedded again; facts keep their link to their memory):

   ```bash
   psql -At -d your_old_db -c "SELECT row_to_json(m) FROM (SELECT id, scope, kind, title, body, tags,
       metadata, importance, decay_rate, created_at, updated_at FROM lm_memories
       WHERE scope LIKE 'repo:my-app%') m" > memories.jsonl
   psql -At -d your_old_db -c "SELECT row_to_json(f) FROM (SELECT 'fact' AS type, scope, subject,
       predicate, object, valid_from, valid_until, source_memory_id AS memory FROM lm_kg_facts
       WHERE scope LIKE 'repo:my-app%') f" >> memories.jsonl
   memo import memories.jsonl --dedup skip     # --dedup skip: running it twice adds nothing
   ```

3. Secrets: store them again with `memo secret-store` (the old vault file isn't
   read).

Tiers now follow importance (`< 0.3` → 0 · `< 5` → 1 · `< 9` → 2 · `≥ 9` → 3), so
imported memories land in the tier their importance gives them.

---

## Known issues

Limitations we know about and intend to fix are listed here, each with what to
do meanwhile. None are open right now; fixed ones are in the
[CHANGELOG](CHANGELOG.md).

---

## Why this exists

AI coding agents lose context constantly: chat sessions crash or grow too long
for the editor, compaction summaries drop the decisions that mattered, a new
device or session means starting over, and cloud memory services don't survive
offline work or an organization's rules about where data goes.

luamemo makes the chat transcript **disposable**. The agent keeps durable
summaries, decisions and facts in a file on your machine and searches them on
demand — surviving crashes, devices and editor bugs.

---

## Where it's going

The long-term goal is a memory backbone for **organization-wide agent
collaboration**: a shared store of a project's design principles, architectural
decisions and conventions, kept current from the whole team's work, so every
agent — whoever drives it — starts from the same grounded understanding.

Much of the base exists: team memory with protected directives, reviewed
knowledge proposals and collective learning; commit and diff digestion
(`memo index diff`); per-scope learned ranking. The next concrete application is
**automated code review**: when a developer pushes, an agent that knows the
project's established patterns, past decisions and constraints reviews the diff
— not a generic linter, but a reviewer that knows *why* an abstraction exists and
which conventions the team agreed on. Still open: how diffs and commits feed the
reviewer's retrieval, and finer-grained privileges (which agents read or write
which scopes) across teams and repositories. Ideas and collaboration are welcome
in [GitHub Issues](https://github.com/kaio326/luamemo/issues).

---

## License

MIT. See [LICENSE](LICENSE).
