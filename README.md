# luamemo

A drop-in **persistent memory store for AI agents** built on plain
PostgreSQL. Works in any Lua 5.1+ runtime — [pgvector](https://github.com/pgvector/pgvector) is
auto-detected and used when available, but **not required** — the default
backend is a pure-Lua brute-force search that runs on any Postgres 15+.

> Give your agent a real memory that survives session crashes, JSON-overflow
> errors in chat clients, container restarts, and device switches — without
> taking on any new runtime services beyond what your app already runs.

**Lua-first.** Every component — embedder, store, routes, MCP server,
summarizer — is written in Lua. Hard dependencies are PostgreSQL and
`luasocket` (HTTP outside OpenResty). Crypto (AES-256-CBC + HMAC-SHA256)
is implemented in pure Lua (`luamemo.crypto`) — no C extension required.
OpenResty is optional — the library runs in any Lua 5.1+ runtime.

---

## Features

- **Hybrid search**: cosine vector similarity (pgvector / HNSW) **+** Postgres
  full-text search, blended via configurable weights.
- **Local-first**: ships with a **pure-Lua in-process embedder** (`hash`) —
  zero network, zero Python, zero model files, zero new dependencies.
  Latency is microseconds.
- **Embedder-agnostic upgrade path**: when you outgrow lexical similarity,
  swap to **Ollama**, **OpenAI**, or any HTTP service that returns a JSON
  vector — without touching the schema, API, or clients. See
  [EMBEDDERS.md](EMBEDDERS.md) for the 5-minute switch and the dim-mismatch trap,
  [eval/results/recall_bench.md](eval/results/recall_bench.md) for a
  measured hash-vs-Ollama recall comparison on a synthetic corpus, and
  [eval/results/longmemeval.md](eval/results/longmemeval.md) for the
  full 500-question LongMemEval `_s` retrieval-recall run.
- **Auth-agnostic**: you supply an `auth_fn(self) -> bool`. The library never
  assumes a session model, role table, or CSRF mechanism.
- **Scoped**: every memory has a `scope` (`global`, `repo:<name>`,
  `session:<id>`, or anything you want). Multiple projects safely share one DB.
- **Session continuity**: end-of-session `promote()` rolls a hot
  `session:<uuid>` scope into a single summary in a long-term scope —
  the next session starts knowing what the previous one knew. See
  [SESSION_CONTINUITY.md](SESSION_CONTINUITY.md).
  Auto-capture hooks**: `luamemo.hooks` wires chat agents into
  the store with two lines per turn — user/assistant messages, tool
  calls, and durable decisions land in the right scope with sane
  dedup defaults. See [HOOKS.md](HOOKS.md).
- **Built-in reranker**: opt-in second pass over the hybrid top-N
  using `noop` (lexical), `ollama`, or `openai` adapters. Lifted R@1
  by **+12 pts** on LongMemEval `_s` (n=50) at ~4 % overhead with the
  free `noop` adapter. See [RETRIEVAL_TUNING.md §4](RETRIEVAL_TUNING.md).
- **Tiny surface**: one `setup()` call, one `routes.register()` call, six
  HTTP endpoints, six Lua functions.
- **CLI included**: `memo write`, `memo search`, `memo recent` from any shell.
- **MCP-native**: a pure-Lua [Model Context Protocol](https://modelcontextprotocol.io/)
  stdio server lets Claude Desktop, Cursor, Continue.dev, and Copilot Agent Mode
  read/write memories directly. See [`mcp/README.md`](mcp/README.md).
- **Importance + time decay**: each memory carries an `importance` weight
  (0..10) and an optional `decay_rate` (0..1 per day). Search ranks by
  `(hybrid_score × importance × e^(-decay_rate · days))` so fresh,
  high-value notes outrank stale low-value ones automatically. See
  [examples/decay_importance.md](examples/decay_importance.md).

---

## Architecture

```
          ┌──────────────────────────────────┐
          │  Caller surfaces                  │
          │  HTTP routes  │  CLI (memo)  │   │
          │               │  MCP server  │   │
          └──────┬───────────┬───────────────┘
                 │           │
                 ▼           ▼
          ┌──────────────────────────────────┐
          │  init.lua  —  setup() + config   │
          └───┬──────────────────────────────┘
              │
     ┌────────┼───────────────┐
     ▼        ▼               ▼
  store.lua  embed.lua    summarizer.lua
  (write/    (in-process  (timer + adapters
   search/    hash OR      in summarizers/)
   recent/    HTTP via
   delete/    http.lua)
   dedup)
     │            │
     │            └──► http.lua ─► resty.http (OpenResty)
     │                             └► socket.http (plain Lua)
     ▼
  db.lua ──► lapis.db (OpenResty)  OR  pgmoon (plain Lua)
     │
     ▼
  PostgreSQL  (pgvector if present, REAL[] otherwise)
```

### Module map

| Module                              | Role                                            |
|-------------------------------------|-------------------------------------------------|
| `luamemo.init`                 | Public entry point. `setup()`, re-exports, `start_background_jobs()`. |
| `luamemo.store`                | All SQL. Write / get / search / recent / update / delete / dedup / summary replacement. |
| `luamemo.db`                   | Portable PostgreSQL adapter. Delegates to `lapis.db` under OpenResty; falls back to `pgmoon` in plain Lua 5.1+. All other library modules go through this layer — no direct `lapis.db` dependency. |
| `luamemo.http`                 | Portable HTTP client. Uses `resty.http` (non-blocking cosockets) under OpenResty; falls back to `socket.http` / `ssl.https` (LuaSocket) in plain Lua 5.1+. Used by embedder adapters, rerankers, and `execute_with_secret`. |
| `luamemo.embed`                | Embedder dispatcher. Picks in-process embedder or HTTP adapter. |
| `luamemo.embedders.hash`       | Pure-Lua feature-hashing embedder. Zero deps.   |
| `luamemo.adapters.*`           | HTTP embedder adapters (Ollama, OpenAI, Voyage, Cohere, generic). |
| `luamemo.routes`               | HTTP route factory. Mounts all memory, KG, and secrets endpoints under one prefix. |
| `luamemo.secrets`              | AES-256-CBC encrypted secret storage + `execute_with_secret`. Requires `master_key_*` config. |
| `luamemo.kg`                   | Knowledge-graph fact store (`lm_kg_facts` table). |
| `luamemo.summarizer`           | Selection + adapter dispatch + transactional replacement. |
| `luamemo.summarizers.*`        | LLM adapters for summarisation (`noop`, `ollama`, `openai`). |
| `luamemo.rerankers.*`          | Reranker adapters (`noop`, `ollama`, `openai`, `cross_encoder`). |
| `luamemo.schema.sql`           | Fresh-install schema for the **pgvector** backend. |
| `luamemo.schema_bruteforce.sql`| Fresh-install schema for the **brute-force** backend (no extension). |
| `luamemo.async`                | Pure-Lua coroutine scheduler. `run_all(tasks)` fans out N embed calls concurrently; used by `write_many()` outside OpenResty. |
| `luamemo.lsh`                  | Random-hyperplane LSH index (Charikar 2002). Auto-activated by `store.lua` when a scope's corpus exceeds `lsh_rebuild_at` rows. |
| `luamemo.migrations/`          | Idempotent ALTERs for live DBs. Apply sequentially; each file is safe to re-run. |
| `cli/memo`                          | Bash CLI. Most subcommands (`write`, `search`, `calibrate`, …) call `luamemo.cli.api` directly — no running HTTP server required. |
| `mcp/server.lua`                    | Pure-Lua stdio MCP server. 11 tools, direct DB access via `MEMO_DB_URL`. |

### Request flow (write)

1. Caller hits `POST /api/memory/write` (or `memory.write{...}` directly).
2. `routes.lua` runs `before_request` (CSRF/rate-limit hook) then `auth_fn`.
3. `store.write` validates inputs, calls `embed.embed(title."\n".body)` to
   get the vector.
4. If `dedup_enabled`, `store.write` runs a top-1 similarity search in the
   same scope. Above `dedup_threshold` it merges the existing row instead
   of inserting.
5. INSERT (or UPDATE on merge) returns the row.

### Request flow (search)

1. Caller hits `GET /api/memory/search?q=...`.
2. `embed.embed(q)` produces a query vector.
3. `store.search` issues a single SQL query that:
   - selects candidates (vector ANN if pgvector available, FTS-ranked
     scope-scoped fetch otherwise),
   - normalises vector and FTS scores per batch,
   - blends them by `hybrid_weights`,
   - multiplies by `importance · exp(-decay_rate · days_since_updated)`,
   - sorts and limits.
4. Rows returned in a backend-agnostic shape so HTTP / CLI / MCP
   are unaffected by which backend ran.

### Backends

- **`auto`** (default) — probe `pg_extension` at `setup()` time and pick
  `pgvector` if the extension is installed, otherwise `bruteforce`.
- **`pgvector`** — `embedding vector(N)` column, HNSW index,
  `ORDER BY embedding <=> $vec` for ANN.
- **`bruteforce`** — `embedding REAL[]` column, no extension. SQL
  pre-filters by `scope`/`kind`/FTS into `bruteforce_candidate_limit`
  rows; Lua computes cosine over the candidate set.

See “Backends & cost” below for the trade-off.

---
## Upgrading

### 0.2.4 → 0.2.5

Apply one new migration (adds a composite index — safe to run on a live DB,
no table rewrites, no downtime required):

```bash
psql -d mydb < luamemo/migrations/005_composite_indexes.sql
```

No schema changes to `lm_memories` or `lm_kg_facts`. No config changes
required. LSH activates automatically once a scope's corpus exceeds
`lsh_rebuild_at` (default 10 000 rows).

---
## 5-minute setup

### 1. Database

**Default (zero infra):** any PostgreSQL 15+. No extension required.
```bash
psql -U postgres -d mydb -f luamemo/schema_bruteforce.sql
```

**Faster path (when you can install extensions):** the official
`pgvector/pgvector:pg15` image, the `postgresql-15-pgvector` Debian/Ubuntu
package, or a managed Postgres that allows `CREATE EXTENSION vector`.
```bash
psql -U postgres -d mydb -f luamemo/schema.sql
```
The library auto-detects which is in use — no config change.

### 2. Pick an embedder

**Local-first (recommended for getting started):** no service required.
```lua
embedder_local = "hash"   -- pure Lua, in-process
```
See [examples/local_hash_embedder.md](examples/local_hash_embedder.md).

**Or one of the HTTP options:**

- **Ollama** (local, semantic): `ollama pull nomic-embed-text` — see
  [examples/ollama_embedder.md](examples/ollama_embedder.md).
- **OpenAI**: `text-embedding-3-small` with your API key.
- **Bundled Python sidecar** (`examples/python_embedder/`):
  ```bash
  cd examples/python_embedder && docker build -t memo-embedder .
  docker run -p 8000:8000 memo-embedder
  ```

### 3. Wire into your Lapis app

```lua
local lapis  = require("lapis")
local memory = require("luamemo")
local app    = lapis.Application()

memory.setup({
    -- Local-first: zero external services
    embedder_local = "hash",
    embed_dim      = 384,
    default_scope  = "repo:my-app",
    auth_fn        = function(self)
        return self.current_user and self.current_user.is_admin
    end,
})

memory.routes.register(app, { prefix = "/api/memory" })

return app
```

### 3b. Wire into a plain Lua 5.1+ app (outside OpenResty)

`luamemo` runs in any Lua 5.1+ runtime — no OpenResty or Lapis required.
The `luamemo.db` module detects the absence of `ngx` and falls back to
a direct pgmoon connection. Configure PostgreSQL via `pg_*` keys or the
standard `PG*` environment variables.

```lua
local memory = require("luamemo")

memory.setup({
    embedder_local = "hash",
    embed_dim      = 384,
    default_scope  = "repo:my-app",
    auth_fn        = function() return true end,   -- no HTTP auth context outside Lapis

    -- PostgreSQL connection — ignored under OpenResty (lapis.db manages it)
    pg_host     = "127.0.0.1",
    pg_port     = 5432,
    pg_database = "mydb",
    pg_user     = "myuser",
    pg_password = "mypass",
})

-- Now use memory.write / memory.search / memory.recent directly
memory.write{
    scope = "repo:my-app",
    title = "First note from plain Lua",
    body  = "Works without a web server.",
}
```

Alternatively, set the standard `PGHOST` / `PGDATABASE` / `PGUSER` /
`PGPASSWORD` environment variables and omit the `pg_*` keys entirely.

That's it. You now have:

| Method | Path                          | Purpose                       |
|--------|-------------------------------|-------------------------------|
| POST   | `/api/memory/write`           | Insert a memory               |
| GET    | `/api/memory/search?q=...`    | Hybrid search                 |
| GET    | `/api/memory/recent`          | Recent memories               |
| GET    | `/api/memory/:id`             | Fetch one                     |
| POST   | `/api/memory/:id/update`      | Update (re-embeds if changed) |
| POST   | `/api/memory/:id/delete`      | Hard delete                   |

### Batch writes — `write_many()`

For ingestion pipelines and calibration runs, use `memory.write_many(rows)`
instead of looping over `memory.write`. It is more efficient in every
dimension:

- **Embeddings** — fetched concurrently (parallel coroutine fan-out via
  `luamemo.async`) when running outside OpenResty. Under OpenResty the
  existing non-blocking cosocket path is already concurrent.
- **Dedup** — a single `SELECT … LIMIT <dedup_candidate_limit>` per
  distinct scope fetches all candidates once; cosine matching runs in Lua
  memory. Cost is O(1) DB round-trips per batch regardless of batch size.
- **Intra-batch dedup** — rows within the same batch are cosine-compared
  against each other before touching the DB, so duplicate inputs in the
  same call are collapsed immediately.

```lua
local rows, err = memory.write_many(
    {
        { scope = "repo:my-app", title = "Alpha", body = "First fact.",  kind = "fact" },
        { scope = "repo:my-app", title = "Beta",  body = "Second fact.", kind = "fact" },
    },
    {
        dedup_strategy  = "update",   -- "append" | "update" | "skip" | nil
        dedup_threshold = 0.92,
    }
)
-- rows is a list of { id, action } where action is "insert", "update", or "skip"
```

---

## Secrets Management

`luamemo` can store encrypted API keys and tokens server-side and
inject them into HTTP requests without ever exposing the raw value to the
LLM. Secrets are built on the `execute_with_secret` design principle.

### Security model

- Secrets are stored **AES-256-CBC encrypted** in a local JSON file on the
  server. No database table is required — the file is the entire store.
- The master key is **never persisted on disk**. It is held in memory only
  while the server process is running (loaded from a Docker secret, env var,
  or config at startup).
- `list_secrets` / `secret_list` returns names and metadata only — no values.
- `execute_with_secret` / `secret_execute` substitutes `{secret}` in URL,
  headers, and body **server-side**, makes the HTTP request, and returns
  only the response body. The decrypted value never crosses the LLM context
  boundary.
- There is **no `get_secret` tool** — raw values cannot be retrieved
  through the API.

### Setup

**1. Generate a master key**

```bash
openssl rand -hex 32        # → 64-char hex string
```

**2. Choose a writable path for the secrets file**

Pick any path that is writable by the OpenResty process and that you want
to persist across restarts. The file is created automatically on the first
`store()` call.

```
/run/secrets/lm_secrets.json        # Docker secret volume mount
/app/data/lm_secrets.json           # App data directory (mount a volume here)
/tmp/lm_secrets.json                # Ephemeral (dev / testing only)
```

**3. Configure `secrets_file` and the key source**

Both `secrets_file` and a master key must be set for the feature to activate.
If either is absent, secrets are **disabled** — all other luamemo features
continue to work normally.

```lua
-- Recommended (production): Docker secrets for both the key and the file path
memory.setup({
    embedder_local  = "hash",
    auth_fn         = ...,
    secrets_file    = "/app/data/lm_secrets.json",   -- writable path; file is auto-created
    master_key_path = "/run/secrets/lm_master_key",  -- file containing the 64-hex-char key
})

-- Option B — environment variable for the key
memory.setup({
    embedder_local = "hash",
    auth_fn        = ...,
    secrets_file   = "/app/data/lm_secrets.json",
    master_key_env = "LM_MASTER_KEY",   -- name of the env var
})

-- Option C — explicit key value (CI / dev only; never commit production keys)
memory.setup({
    embedder_local = "hash",
    auth_fn        = ...,
    secrets_file   = "/tmp/lm_secrets.json",
    master_key     = "abcdef0123456789...",   -- 64 hex chars
})
```

Key resolution order: `master_key_path` → `master_key_env` → `master_key`.

**4. Persist the file across container restarts (Docker)**

Mount the directory containing the secrets file as a named volume so it
survives container rebuilds:

```yaml
# docker-compose.yml
services:
  app:
    volumes:
      - lm_secrets_data:/app/data   # persists lm_secrets.json

volumes:
  lm_secrets_data:
```

> ⚠️ If the file is not on a persistent volume, all stored secrets are lost
> when the container is removed. Back up the file or use a bind-mount to a
> host path if you need durability without a named volume.

**No migration needed** — there is no database table. `memo migrate` output
does not include any `lm_secrets` DDL.

### Usage (Lua API)

```lua
local memory = require("luamemo")

-- Store a secret (value is encrypted before writing to the JSON file)
memory.secrets.store("openai-key", "sk-...", "OpenAI API key")

-- List secrets (names and metadata only — values never returned)
local list = memory.secrets.list()

-- Execute an HTTP request with {secret} substituted server-side
local body, err = memory.secrets.execute_with_secret("openai-key", {
    url     = "https://api.openai.com/v1/models",
    method  = "GET",
    headers = { Authorization = "Bearer {secret}" },
})

-- Delete a secret
memory.secrets.delete("openai-key")

-- Check if secrets are enabled (secrets_file + master key both configured)
if memory.secrets.enabled() then ... end
```

### Usage (MCP tools)

> **These are not terminal commands.** You type them in the chat window of your
> AI assistant (Claude Desktop, Copilot Agent Mode, Cursor, Continue.dev, etc.)
> while the MCP server is connected. The assistant recognises them as tool calls
> and executes them against the running luamemo HTTP API.

Three tools are safe to call from the chat window (no raw values involved):

| Tool | Safe in chat? | Description |
|------|:---:|-------------|
| `secret_list` | ✅ | List stored secrets (names + metadata only — no values) |
| `secret_delete(name)` | ✅ | Permanently delete a secret |
| `secret_execute(name, url, ...)` | ✅ | HTTP request with `{secret}` substituted server-side |
| ~~`secret_store`~~ | ❌ | **Use `memo secret-store` from terminal instead** (see below) |

**`secret_store` must never be called from the chat window.** The value would enter the LLM context and could be logged by the AI provider. Store secrets from the terminal only (see the section below).

#### Adding a new API key

> ⚠️ **Never type a secret value in the chat window.** The chat is processed by
> the LLM (and potentially logged by the AI provider). Use the terminal instead.

Store secrets from the terminal using `memo secret-store`. It prompts for the
value with **no echo** — the key never appears on screen, in shell history, or
in the chat context:

```bash
# Prompted, no echo — safest
export MEMO_URL=https://your-app.example.com/api/memory
export MEMO_TOKEN=your-bearer-token   # if auth is enabled

memo secret-store openai-key --desc "OpenAI API key"
# Secret value for "openai-key": ████████  (hidden, no echo)
```

Or read the value from a file (e.g. a password manager export):

```bash
memo secret-store openai-key --file ~/.secrets/openai-key.txt --desc "OpenAI API key"
```

Or call the HTTP API directly from the terminal (value stays in your terminal, never in chat):

```bash
curl -sS -X POST "$MEMO_URL/secrets" \
  -H "Authorization: Bearer $MEMO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"openai-key","value":"sk-proj-...","description":"OpenAI API key"}'
```

The value is encrypted server-side immediately. **It can never be retrieved** — not by
you, not by the agent, not through any API. If you lose it you must store a new one.

#### Verify what is stored

```
secret_list()
```

Returns names, descriptions, and timestamps — no values.

#### Use a stored secret in an HTTP request

```
secret_execute("openai-key",
  url    = "https://api.openai.com/v1/models",
  method = "GET",
  headers = { Authorization = "Bearer {secret}" })
```

Write `{secret}` anywhere in `url`, header values, or `body`. The server substitutes
the decrypted value before making the request. Only the HTTP response body is returned
to the agent — the raw key never enters the chat context.

#### Real-world examples

**Call OpenAI chat completions:**
```
secret_execute("openai-key",
  url    = "https://api.openai.com/v1/chat/completions",
  method = "POST",
  headers = { Authorization = "Bearer {secret}", Content-Type = "application/json" },
  body   = '{"model":"gpt-4o","messages":[{"role":"user","content":"hello"}]}')
```

**Send a message via Slack webhook:**
```
secret_execute("slack-webhook",
  url    = "https://hooks.slack.com/services/{secret}",
  method = "POST",
  headers = { Content-Type = "application/json" },
  body   = '{"text":"Deploy complete"}')
```

**Query GitHub API with a personal access token:**
```
secret_execute("github-token",
  url    = "https://api.github.com/repos/myorg/myrepo/issues",
  headers = { Authorization = "Bearer {secret}", Accept = "application/vnd.github+json" })
```

**Send email via SendGrid:**
```
secret_execute("sendgrid-key",
  url    = "https://api.sendgrid.com/v3/mail/send",
  method = "POST",
  headers = { Authorization = "Bearer {secret}", Content-Type = "application/json" },
  body   = '{"personalizations":[{"to":[{"email":"you@example.com"}]}],"from":{"email":"noreply@example.com"},"subject":"Hello","content":[{"type":"text/plain","value":"Hi!"}]}')
```

#### Remove a secret

```
secret_delete("openai-key")
```

Permanently deletes from the secrets file. Cannot be undone.

### HTTP API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/memory/secrets` | List secrets (no values) |
| POST | `/api/memory/secrets` | Create / update a secret (`name`, `value`, optional `description`) |
| POST | `/api/memory/secrets/:name/delete` | Delete a secret |
| POST | `/api/memory/secrets/:name/execute` | Execute HTTP request with secret substituted |

---

## Programmatic API

```lua
local memory = require("luamemo")

memory.write{
    scope = "repo:my-app",
    kind  = "decision",
    title = "Use FTS+pgvector hybrid for memory",
    body  = "Picked hybrid over pure vector because lexical recall ...",
    tags  = { "architecture", "memory" },
    metadata = { author = "kaio", phase = 5 },
}

local results = memory.search{
    query = "how did we handle CCA half-year rule",
    scope = "repo:my-app",
    limit = 10,
    hybrid_weights = { vector = 0.7, fts = 0.3 },
}

local one  = memory.get(42)
local list = memory.recent{ scope = "repo:my-app", limit = 20 }
memory.update(42, { body = "..." })
memory.delete(42)
```

---

## Web UI

Use `memory.routes.register(app, { prefix = "/api/memory" })` to mount all endpoints, then interact via the `memo` CLI or the MCP server — both talk to the same HTTP API.

---

## CLI

```bash
export MEMO_URL=https://my-app.example.com/api/memory
export MEMO_TOKEN=your-bearer-token

memo write --scope repo:my-app --kind decision \
    --title "Switched embedder to Ollama" \
    --body  "Local-only, removes OpenAI dep, ~50 ms/call."

memo search "embedder choice"
memo recent --scope repo:my-app --limit 5
memo get 42
memo delete 42
```

---

## Embedder contract

Any HTTP service that accepts:

```http
POST /embed
Content-Type: application/json

{ "text": "string to embed" }
```

and returns:

```json
{ "vector": [0.012, -0.345, ...] }
```

is a valid embedder. The vector length **must** match `embed_dim` from
`setup()`.

Adapters in `luamemo.adapters.*` translate this contract to
provider-specific formats:

| Adapter      | Status        | Notes                                           |
|--------------|--------------|-------------------------------------------------|
| `generic`    | working       | The contract above; for custom embedders        |
| `ollama`     | working       | Local, free, semantic                           |
| `openai`     | working       | `text-embedding-3-small` / `-large`             |
| `voyage`     | working       | Anthropic's officially recommended provider     |
| `cohere`     | working       | `embed-english-v3.0` / `embed-multilingual-v3.0`|
| `anthropic`  | template only | Anthropic has no embeddings API yet — use Voyage|
| `deepseek`   | template only | DeepSeek has no embeddings API yet              |
| `hash`       | working (in-process, not HTTP) | Pure Lua, lexical only       |

---

## Schema

Two schema files ship in the repo:

| File                         | Backend     | Postgres extension required |
|------------------------------|-------------|-----------------------------|
| `luamemo/schema.sql`              | `pgvector`  | `vector` (HNSW for fast ANN) |
| `luamemo/schema_bruteforce.sql`   | `bruteforce`| none                        |

Both define the same columns. The only differences are the type of
`embedding` (`vector(N)` vs `REAL[]`) and whether an HNSW index is created.
The table is opinionated but extensible via the `metadata JSONB` column.
The default embedding dimension is **384** (matches `all-MiniLM-L6-v2` and
`nomic-embed-text`); change it before running the migration if you use a
different model.

---

## Backends & cost

`luamemo` ships three backends. All are first-class — the HTTP API,
CLI, and MCP server work identically against any of them.

| Backend | Activation | Complexity | Notes |
|---------|-----------|------------|-------|
| **pgvector** | `vector` extension present | O(log N) HNSW | Best for production |
| **LSH** | bruteforce + corpus > `lsh_rebuild_at` (default 10 000) | ~O(N^0.9) | Automatic middle tier, pure Lua |
| **bruteforce** | always available | O(N) | Default; works on any Postgres 15 |

### `bruteforce` (default, zero infra)

- Storage: `embedding REAL[]` column on plain Postgres.
- Search: SQL pre-filters by `scope` / `kind` / FTS rank, returns up to
  `bruteforce_candidate_limit` (default **1000**) candidate rows; Lua
  computes cosine and ranks them.
- **Pros**
  - `luarocks install luamemo` + any Postgres 15 = working install.
  - Same code on dev, CI, and prod.
  - No extension privileges needed; works on managed Postgres that
    forbids `CREATE EXTENSION`.
- **Cons**
  - Per-query cost is `O(N · D)` over the candidate set, executed in the
    Lua VM. Comfortable up to roughly **10k–50k memories per scope** at
    384 dimensions on a modern CPU.
  - Embeddings travel over the wire from Postgres into Lua for each
    search. Fine on `localhost`, noticeable over a slow link.
  - Quality drops if the candidate cap is hit and the relevant memory
    sits outside the FTS-ranked top 1000. Mitigated by always passing a
    meaningful `scope` (and ideally a `kind`).

### LSH (automatic middle tier — bruteforce backend only)

When the corpus for a scope exceeds `lsh_rebuild_at` rows (default
**10 000**) and the backend is `bruteforce`, `luamemo` automatically
builds a **random-hyperplane LSH index** in Lua memory.

- **Algorithm**: Charikar (2002) sign-random-projection. `L` hash tables
  (default 8), each keyed by `K` bits (default 12) from `sign(v · h_i)`
  for random unit hyperplanes `h_i`. Vectors that share a bucket are
  cosine-similar with high probability.
- **Effect**: the candidate fetch shrinks from 1 000 rows to ≈100–300
  rows, reducing both the DB wire transfer and the Lua cosine loop
  proportionally.
- **Recall**: ~95% for 50k vectors at 384 dims with default `L=8, K=12`.
- **Memory**: index size ≈ L × 2^K bucket slots, each holding a list of
  IDs. For 50k rows at L=8 and K=12 this is a few MB.
- **Tuning config keys**:
  | Key | Default | Effect |
  |-----|---------|--------|
  | `lsh_enabled` | `true` | Set `false` to disable LSH entirely |
  | `lsh_rebuild_at` | `10000` | Row count to trigger first build |
  | `lsh_tables` | `8` | L: more → higher recall, more memory |
  | `lsh_bits` | `12` | K: more → smaller buckets, lower recall |
  | `embed_dim` | `384` | Fallback dim when inferred dim is unavailable |
- **No config required**: LSH activates silently when the threshold is
  crossed and degrades silently back to full-scan when not worth it.

### `pgvector` (auto-upgrade when extension present)

- Storage: `embedding vector(N)` column + HNSW index.
- Search: native pgvector cosine ANN, FTS rank blended in SQL.
- **Pros**
  - Sub-linear ANN; scales to millions of rows with stable latency.
  - All ranking happens inside Postgres in a single query.
- **Cons**
  - Requires the `vector` extension installed and `CREATE EXTENSION`
    permission.
  - One more dependency to keep in sync across environments.

### Picking a backend

Leave `backend = "auto"` and let the library decide at startup. Override
with `backend = "pgvector"` or `"bruteforce"` only if you want to force
the choice (e.g. lock a deployment to brute-force for portability even
when the extension is available).

### Future mitigations (Lua-first)

The brute-force cons above have a roadmap. Each item below is intended
to stay pure-Lua in the host process and add zero runtime services:

- **Smarter pre-filter.** Today the candidate set is FTS-ranked then
  capped. A future revision will combine FTS + tag-prefix + recency to
  push more relevant rows into the top-1000 bucket before Lua sees them.
- **Pure-Lua ANN index** (`HNSW` or `IVF`) over the `REAL[]` column,
  built and maintained in Lua. Lets the brute backend keep working
  beyond the 50k-row crossover without taking on pgvector.
- **SQLite + sqlite-vec adapter.** Optional second persistence layer for
  single-user / desktop / MCP-only deployments where Postgres itself is
  overkill. Not a replacement — a sibling backend selected the same way
  via `backend = "sqlite_vec"`.
- **Embedder caching.** A small in-process LRU on `embed()` so repeated
  search-then-write loops (common in agent flows) don’t re-embed the
  same query / body.

None of these change the public API. Pick the simplest backend that fits
today — the upgrade path is purely a `setup()` switch.

---

## Importance & decay

Every row carries two numeric weights used at search time:

| Column | Range | Default | Purpose |
|---|---|---|---|
| `importance` | 0..10 | 1.0 | Static multiplier on the hybrid score. |
| `decay_rate` | 0..1 per day | 0.0 | Exponential time-decay; 0 disables it. |

The effective ranking weight applied to each candidate is:

```
weight = importance * exp(-decay_rate * days_since_updated)
score  = (vector_weight * vec_score + fts_weight * fts_score) * weight
```

Defaults preserve the original behaviour: every row has weight 1.0 and
ordering is pure hybrid similarity.

Write a high-importance, slowly-decaying memory:

```lua
memory.write{
    title = "Production DB password rotation policy",
    body  = "...",
    importance = 8.0,    -- pin near the top for a long time
    decay_rate = 0.005,  -- ~half-life of 138 days
}
```

Write a session-scratch memory that fades within days:

```lua
memory.write{
    scope = "session:abc",
    title = "Working hypothesis: cache invalidation off-by-one",
    body  = "...",
    importance = 1.0,
    decay_rate = 0.5,    -- ~half-life of 1.4 days
}
```

App-wide defaults are configurable via `setup()`:

```lua
memory.setup({
    -- ...
    default_importance = 1.0,
    default_decay_rate = 0.0,
})
```

For debugging, pass `ignore_decay = true` (Lua) or `?ignore_decay=1` (HTTP)
to `search` to bypass the multiplier and inspect raw hybrid scores.

See [examples/decay_importance.md](examples/decay_importance.md) for an
end-to-end recipe.

---

## Benchmarks

A pure-Lua eval harness against
[LongMemEval](https://huggingface.co/datasets/xiaoyangwu/longmemeval)
lives in [`eval/`](eval/README.md). Results are on the `_s` (short-session)
corpus, bruteforce backend, default hybrid weights (`vector=0.7, fts=0.3`).

### LongMemEval `_s` — retrieval recall (latest numbers)

| Embedder | n | R@1 | R@5 | R@10 | R@20 | MRR |
|---|---|---|---|---|---|---|
| hash (pure Lua, in-process) | 200 | ~40% | ~60% | ~70% | ~80% | ~0.50 |
| nomic-embed-text 768d (Ollama) | 200 | 62.0% | 81.5% | 87.5% | 92.5% | 0.706 |
| **bge-m3 1024d (TEI sidecar)** | **500** | **87.0%** | **96.4%** | **98.6%** | **99.6%** | **0.913** |

Similar memory systems using LLM-summarisation pipelines report **96.6% R@5** on
LongMemEval-S. The bge-m3 result above (96.4%) is at parity — with no LLM
summarisation, no training data, and single-stage retrieval.

The **bge-m3** result requires a GPU sidecar (see [eval/sidecars/tei.md](eval/sidecars/tei.md))
but no other code or schema changes — just swap the embedder in `setup()`.
See [eval/results/longmemeval.md](eval/results/longmemeval.md) for full
phase-by-phase details, reproduce commands, and the weight-sweep analysis.

Quick start:
```bash
# zero-deps benchmark (hash embedder, no GPU needed)
PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test \
  lua5.1 eval/longmemeval_run.lua --embedder hash \
    --corpus eval/data/longmemeval_s.json --n 50 \
    --out eval/results/smoke.json

# GPU benchmark (requires TEI sidecars — see eval/sidecars/)
PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test \
  TEI_URL=http://127.0.0.1:8081/embed TEI_DIM=1024 \
  lua5.1 eval/longmemeval_run.lua --embedder tei \
    --corpus eval/data/longmemeval_s.json \
    --out eval/results/my_run.json
```

---

## Why this exists

AI coding agents lose context constantly:

- Chat session JSON files exceed V8's `kMaxLength` and crash the editor.
- Compaction summaries drop critical decisions.
- A new device or new session = total amnesia.
- Cloud-only memory tools don't survive offline work or org policies.

`luamemo` makes the chat transcript **disposable**. The agent writes
durable summaries / decisions / facts to your own Postgres, then searches
them on demand. Survives crashes, devices, and editor bugs.

---

## License

MIT. See [LICENSE](LICENSE).
