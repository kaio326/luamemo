# luamemo

A drop-in **persistent memory store for AI agents** built on plain
PostgreSQL. Works in any Lua 5.1+ runtime — [pgvector](https://github.com/pgvector/pgvector) is
auto-detected and used when available, but **not required** — the default
backend is a pure-Lua brute-force search that runs on any Postgres 15+.

> Give your agent a real memory that survives session crashes, JSON-overflow
> errors in chat clients, container restarts, and device switches — without
> taking on any new runtime services beyond what your app already runs.

**Lua-first.** Every component — embedder, store, routes, MCP server,
summarizer — is written in Lua. "Works in any Lua 5.1+ runtime" means no
OpenResty, no Node, no Python — but it does not mean zero dependencies.
Two LuaRocks packages are required:

| Package | Why |
|---------|-----|
| `pgmoon` | Pure-Lua PostgreSQL driver (no C extension needed) |
| `luasocket` | HTTP client for embedder calls and `execute_with_secret`; also used by pgmoon for the DB connection outside OpenResty |

`luarocks install luamemo` pulls both automatically. **`lua-cjson` is no
longer required.** JSON is handled by `luamemo.json`, a portable shim that
tries `cjson.safe` first (always present in OpenResty / LuaJIT) and falls
back to the bundled `luamemo.vendor.dkjson` (pure Lua, MIT, zero C deps)
when cjson is absent. This means install succeeds on minimal Alpine images
and CI runners without a C compiler. Crypto (AES-256-CBC + HMAC-SHA256)
is implemented in pure Lua (`luamemo.crypto`) — no lua-openssl needed.
pgvector is optional — the default backend runs on any Postgres 15+.

---

## Features

- **Hybrid search**: cosine vector similarity (pgvector / HNSW) **+** Postgres
  full-text search, blended via configurable weights.
- **Local-first**: ships with a **pure-Lua in-process embedder** (`hash`) —
  zero network, zero Python, zero model files, zero new dependencies.
  Latency is microseconds.
- **Embedder-agnostic upgrade path**: when you outgrow lexical similarity,
  swap to **Ollama**, **OpenAI-compatible** endpoints, or any HTTP service that
  returns a JSON vector — without touching the schema, API, or clients. See
  [EMBEDDERS.md](EMBEDDERS.md) for the 5-minute switch and the dim-mismatch trap,
  [eval/results/recall_bench.md](eval/results/recall_bench.md) for a
  measured hash-vs-Ollama recall comparison on a synthetic corpus, and
  [eval/results/longmemeval.md](eval/results/longmemeval.md) for the
  full 500-question LongMemEval `_s` retrieval-recall run.
- **In-process semantic embedder (no sidecar)**: an optional `gguf_ffi` embedder
  runs **EmbeddingGemma** directly in the process via a tiny LuaJIT-FFI shim over
  llama.cpp — bge-m3-class recall, on CPU, no HTTP service. `memo calibrate`
  recommends it automatically when the host can build it (LuaJIT + a C toolchain);
  `--no-gguf` opts out. It is a swappable default, not a hard dependency — the
  pure-Lua `hash` embedder remains the zero-setup fallback.
- **Learns from usage (opt-in)**: with `feedback_enabled`, luamemo captures
  corrections/commands/praise from your sessions and *retrieval misses* (a memory
  that should have surfaced but didn't), then a per-scope **promotion harness**
  (`memo learn <scope>`) trains a learned reranker and promotes it **only if it
  beats the incumbent on a held-out gate** — so retrieval improves over time with
  zero-regression guardrails. The base models stay frozen; only small learned
  layers adapt. See [Learned-from-usage](#learned-from-usage) below.
- **Self-maintaining**: `memo calibrate` enables a debounced auto-digest that
  piggybacks on writes, so tier promotion / consolidation / decay run without any
  agent or scheduler having to call `memo digest`.
- **Hierarchical scopes**: search a *set* of scopes at once (`scopes = {org, repo,
  user}`) and higher-tier memories (e.g. org directives) surface first across the
  union — the foundation for multi-project and org-shared memory.
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
  free `noop` adapter. A pure-Lua **learned** reranker can also be trained
  per-scope from usage and gated-promoted (see Learned-from-usage). See
  [RETRIEVAL_TUNING.md §4](RETRIEVAL_TUNING.md).
- **Tiny surface**: one `setup()` call, one `routes.register()` call, six
  HTTP endpoints, six Lua functions.
- **CLI included**: `memo write`, `memo search`, `memo recent`, plus
  `memo sense` / `memo learn` for the learn-from-usage loop, from any shell.
- **MCP-native**: a pure-Lua [Model Context Protocol](https://modelcontextprotocol.io/)
  stdio server (22 tools) lets Claude Desktop, Cursor, Continue.dev, and Copilot
  Agent Mode read/write memories, **query the codebase index**, and feed the
  learn-from-usage loop (`memory_sense`) directly. See
  [`mcp/README.md`](mcp/README.md).
- **Codebase index**: `memo index` maps a whole repository into queryable memory
  rows (files, symbols, dependencies, diffs) under `codeindex:<project>` scopes, so
  an agent can find *where* code lives (`path:line`) and *what* a file defines
  without grepping or reading files. Pure-Lua parsers for Lua/Python/JS-TS, plus
  universal-ctags for any other language when present. See
  [Codebase Index](#codebase-index) below.
- **Importance + time decay**: each memory carries an `importance` weight
  (0..10) and an optional `decay_rate` (0..1 per day). Search ranks by
  `(hybrid_score × importance × e^(-decay_rate · days))` so fresh,
  high-value notes outrank stale low-value ones automatically. See
  [examples/decay_importance.md](examples/decay_importance.md).

---

## Security and alignment design

LuaMemo includes a secrets subsystem designed for AI agents. API keys and tokens are stored AES‑encrypted on the server, with the master key held only in memory. Agents never see raw secret values: there is no read API, and secrets are only injected server‑side into HTTP requests via execute_with_secret. This makes it much harder for prompt injection, jailbreaks, or compromised agents to exfiltrate credentials.

The HTTP execution path also defends against common agent‑mediated attacks such as SSRF and path traversal (scheme and private‑IP blocking, DNS‑rebinding checks, and strict file path validation). This is intended as a practical pattern for least‑privilege tool use and safer integration of LLM agents into real systems.

Check out *Secrets management* section for more info.

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
| `luamemo.json`                 | Portable JSON shim. Tries `cjson.safe` first (present in OpenResty); falls back to bundled `dkjson` 2.5. Single require point for all JSON operations in the library. |
| `luamemo.vendor.dkjson`        | Bundled dkjson 2.5 (pure Lua, MIT). Used only when `cjson.safe` is unavailable. |
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

### → 0.4.0 (run `memo migrate`)

Run **`memo migrate`** to add the new tables (all idempotent, additive — no
existing data touched): `lm_retrieval_feedback`, the `miss` reinforcement type,
`lm_digest_state`, `lm_learner_weights`, `lm_promotion_runs`. Everything new is
**opt-in and off by default** — existing behaviour is unchanged until you enable
`feedback_enabled` / `auto_digest_enabled` (or re-run `memo calibrate`, which
turns on self-maintenance and recommends the in-process embedder). If you adopt
the `gguf_ffi` embedder, the `memo` CLI now runs under LuaJIT automatically.

### 0.2.6 → 0.2.7

Drop-in upgrade — no schema changes, no migrations, no config changes.
Bump `luarocks install luamemo` to `0.2.7-1`.

`lua-cjson` is no longer a hard dependency. If you have it installed it
continues to be used automatically (OpenResty always has it built-in).
If you do not have it, the bundled `dkjson` fallback kicks in transparently.
You do not need to install or uninstall anything.

### 0.2.5 → 0.2.6

Drop-in upgrade — no schema changes, no migrations, no config changes.
Bump `luarocks install luamemo` to `0.2.6-1`. The new `memo calibrate`
phases (schema auto-apply, IDE/MCP detection) and MCP security guidance
are active automatically after the upgrade.

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

### Choose your access path

Before installing, pick the path that matches your use case. They are
orthogonal and can be combined.

| What you want | What you need | What you can skip |
|---|---|---|
| **AI agent memory only** (Copilot, Cursor, Claude Desktop) | PostgreSQL + `memo calibrate` + MCP config | `memory.setup()`, HTTP routes, Lapis |
| **In-app memory** (your Lua code calls `store.write` / `store.search`) | `memory.setup()` | MCP server |
| **Both** (app code + AI agent through your auth layer) | `memory.setup()` + `routes.register()` + MCP server with `MEMO_URL` | — |
| **Both** (app code + AI agent with direct DB access) | `memory.setup()` + MCP server with `MEMO_DB_URL` | HTTP routes |

> **Using Copilot Agent Mode, Cursor, or Claude Desktop?**
> Run `memo calibrate` — it applies the schema, detects your IDE, and writes
> the MCP config for you. You do not need to wire `memory.setup()` or
> `routes.register()` unless your application code also needs the HTTP routes.

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

**In-process semantic (no sidecar, recommended when the host can build it):**
```lua
embedder_local = "gguf_ffi"   -- EmbeddingGemma via LuaJIT-FFI over llama.cpp
```
Runs a real semantic embedder (bge-m3-class recall) directly in-process on CPU —
no HTTP service. Requires **LuaJIT** + a one-time build of the tiny C shim
(`luamemo/embedders/native/build.sh`, needs a C toolchain + cmake + llama.cpp) and
the model file (`MEMO_GGUF_MODEL`). `memo calibrate` detects capability and wires
this up for you (persisting `MEMO_EMBEDDER=gguf_ffi` and launching `luajit`);
pass `--no-gguf` to stay on a lighter option. An optional GPU offload
(`MEMO_GGUF_NGL` / `MEMO_GEN_NGL`) activates when llama.cpp is built with CUDA.

**Or one of the HTTP options:**

- **Ollama** (local, semantic): `ollama pull nomic-embed-text` — see
  [examples/ollama_embedder.md](examples/ollama_embedder.md).
- **OpenAI-compatible** (`openai_compatible` adapter): OpenAI itself, or any
  self-hosted vLLM / LM Studio / TEI endpoint that speaks the same protocol.
- **Bundled Python sidecar** (`examples/python_embedder/`):
  ```bash
  cd examples/python_embedder && docker build -t memo-embedder .
  docker run -p 8000:8000 memo-embedder
  ```

### 3. Wire into your Lapis app

> **Only needed if** your application code calls `store.write()` /
> `store.search()` in-process, or you want the `/api/memory` HTTP routes
> available. For AI-agent-only use (Copilot, Cursor, Claude Desktop) you
> can skip to the MCP section below.

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

### Starting before the embedder is ready

If your embedder (Ollama, TEI, OpenAI) starts **after** your app — for example
because of GPU warm-up, a Docker cold-start, or a slow sidecar — add
`skip_embed_probe = true` to your `setup()` config. This lets `setup()` succeed
even when the embedder is not yet reachable:

```lua
memory.setup({
    skip_embed_probe = true,   -- required for GPU sidecars or slow-starting embedders
    embedder_adapter = "tei",
    embedder_url     = "http://tei:8080",
    embed_dim        = 768,
    ...
})
```

`setup()` completes immediately. The first `store.write()` call will probe the
embedder via `ensure_ready()`. If the embedder is now up, the write succeeds. If
not, `write()` returns `nil, "luamemo not ready (embedder unavailable)"` — a clear
error the caller can log and retry.

### 3c. Docker / containerized setup

When your Postgres instance runs in a Docker container, `127.0.0.1` is
**not** the right host — it resolves to the container running your Lua
app, not the database container. Set `pg_host` to the service name
defined in your `docker-compose.yml`:

```lua
memory.setup({
    embedder_local = "hash",
    embed_dim      = 384,
    auth_fn        = function(self) return self.current_user ~= nil end,

    -- Docker: use the Compose service name, not localhost
    pg_host     = lapis_cfg.postgres.host,   -- e.g. "db"
    pg_port     = lapis_cfg.postgres.port or 5432,
    pg_database = lapis_cfg.postgres.database,
    pg_user     = lapis_cfg.postgres.user,
    pg_password = lapis_cfg.postgres.password,
})
```

Or set `MEMO_DB_URL=postgresql://user:pass@db:5432/mydb` and `luamemo`
reads it automatically without any `pg_*` keys. This is also the URL that
`memo calibrate` writes into the MCP client config — make sure it is
correct for the network context where the **MCP client** runs (Claude
Desktop, VS Code, or Cursor), which is typically the Docker host, not
inside a container.

#### Embedding service on WSL2 with GPU

When running a local embedder such as
[Text Embeddings Inference](https://github.com/huggingface/text-embeddings-inference)
on WSL2 with a CUDA GPU, two non-obvious flags are required to avoid OOM
crashes:

```bash
CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=0 \
  docker run --gpus all -p 8080:80 \
  ghcr.io/huggingface/text-embeddings-inference:turing-1.5 \
  --model-id BAAI/bge-small-en-v1.5 \
  --dtype float16 \
  --max-batch-tokens 2048
```

`--dtype float16` halves VRAM usage; `--max-batch-tokens 2048` prevents a
single large batch from exhausting memory. Without these, TEI silently
crashes on the first batch request.

---

That's it. You now have:

| Method | Path                          | Purpose                       |
|--------|-------------------------------|-------------------------------|
| POST   | `/api/memory/write`           | Insert a memory               |
| GET    | `/api/memory/search?q=...`    | Hybrid search                 |
| GET    | `/api/memory/recent`          | Recent memories (HTTP: hard-capped at 100 rows) |
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
- **SSRF guard**: `execute_with_secret` rejects non-`http`/`https` schemes and
  blocks all known private IP ranges (`localhost`, `127.x`, `169.254.x`,
  `10.x`, `192.168.x`, `172.16–31.x`, `::1`). The hostname is also
  **resolved via DNS** and the resolved IP is re-checked against the same
  blocklist — closing the DNS-rebinding bypass where a public-looking domain
  resolves to an internal address at request time. Unresolvable hosts are
  rejected (fail-closed).
- **Multipart file path guard**: when `execute_with_secret` sends a multipart
  body with a local file field, the path is validated for no `..` traversal
  and no symlinks. A symlink pointing outside the intended directory is
  rejected before `io.open` is called.

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
> and executes them via the MCP server (which connects to PostgreSQL directly
> or through your HTTP API, depending on your transport configuration).

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
# memo secret-store talks to the DB directly (not HTTP) — set these env vars:
export MEMO_DB_URL=postgresql://user:pass@localhost:5432/mydb
export MEMO_MASTER_KEY=<64-hex-char key>   # or set MEMO_SECRETS_FILE + MEMO_MASTER_KEY
export MEMO_SECRETS_FILE=/app/data/lm_secrets.json

memo secret-store openai-key --desc "OpenAI API key"
# Secret value for "openai-key": ████████  (hidden, no echo)
```

Or read the value from a file (e.g. a password manager export):

```bash
memo secret-store openai-key --file ~/.secrets/openai-key.txt --desc "OpenAI API key"
```

Or call the HTTP API directly from the terminal if you use the HTTP-mode setup
(value stays in your terminal, never in chat):

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

### `store.write()` return convention

`store.write()` (and `memory.write{}`) **never throws a Lua error**. Both embed
failures and DB errors surface as a `nil, err` return. Check the returned row,
not a `pcall` result:

```lua
-- Correct:
local row, err = memory.write{ scope = "s", body = "fact" }
if not row then
    ngx.log(ngx.ERR, "write failed: ", err)
end

-- Wrong — pcall always succeeds; the error is hidden:
local ok = pcall(memory.write, { scope = "s", body = "fact" })
```

Return values:

| Value | Type | Meaning |
|-------|------|---------|
| `row` | table | The inserted/updated `lm_memories` row on success; `nil` on any failure |
| `err` | string | Error message on failure; `nil` on success |
| `action` | string | `"inserted"`, `"updated"`, or `"deduped"` when `row ~= nil` |

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

# maintenance + learning (see Learned-from-usage)
memo digest  --scope repo:my-app           # tier promotion / consolidation / decay
memo learn   repo:my-app --dry-run         # train + gate the learned reranker (no promote)
echo '[{"role":"user","text":"No, we use pgmoon, not luadbi."}]' \
  | memo sense --scope repo:my-app         # record a correction as a reinforcement

# switched embedders? old and new vectors are never comparable, even at the
# same embed_dim — re-embed the scope so vector search stays accurate:
memo reembed --scope repo:my-app --dry-run # preview: how many rows would be touched
memo reembed --scope repo:my-app           # re-embed with the currently configured embedder
```

`memo calibrate` sets up the database, recommends an embedder, and enables
self-maintenance (auto-digest) for you.

---

## Learned-from-usage

Opt-in (`feedback_enabled = true`, or `MEMO_FEEDBACK_ENABLED=1`). When on, luamemo
turns real usage into a signal that makes retrieval better over time — while the
base embedder stays **frozen** (only small learned layers adapt, and only when
they demonstrably help).

**1. Capture (how memory learns what matters).** Signals become `lm_reinforcements`:
- **Corrections / commands / praise** — relayed from a session via `memo sense` or
  the `memory_sense` MCP tool (luamemo can't read your chat, so the agent relays
  the recent turns). Explicit-pattern heuristics run always; an optional in-process
  instruct model (`MEMO_GEN_MODEL`) can also extract implicit signals (experimental).
- **Retrieval misses** — fully automatic, no LLM: a near-duplicate write means an
  existing memory *should* have surfaced but didn't, so it's marked a "miss" (the
  opposite of a content mistake) and made more findable. A correction whose target
  was never retrieved is likewise reclassified from mistake → miss.

**2. Consolidate (self-maintaining).** A debounced auto-digest piggybacks on writes
(enabled by `memo calibrate`) so tier promotion, consolidation, and decay run
without anything having to remember to call `memo digest`.

**3. Promote (safely, per scope).** `memo learn <scope>` harvests the scope's
feedback into training triples, trains a learned reranker, and evaluates it on a
**held-out gate** — promoting the new weights **only if they beat the incumbent**,
else rejecting. Weights are versioned per-scope in the DB (`lm_learner_weights`)
and every attempt is audited (`lm_promotion_runs`); `rollback` restores the prior
version. This is a no-op until enough signal exists — by design.

> The learned layers ride the **same** reinforcement log the tier/consolidation
> system uses, so "this memory keeps getting corrected/needed" strengthens both
> its tier and the ranker. Nothing fine-tunes the embedding model itself.

---

## Codebase Index

`memo index` maps a whole repository into queryable memory rows so an agent can
find **where** code lives and **what** a file defines — without grepping or
reading files. The index lives in its own `codeindex:<project>` scopes, separate
from your regular memories, and never enters an agent's context until queried.

**Build / refresh the map:**

```bash
# Index the current repo (whole-repo: every text file → a file row; symbols
# extracted where a parser exists). Scope defaults to codeindex:<dirname>.
memo index ingest --scope codeindex:my-app

# Incremental refresh — only changed / new / deleted files are touched.
memo index update --scope codeindex:my-app

# Narrow the walk, or store file rows only (skip symbol extraction):
memo index ingest --extensions lua,py --scope codeindex:my-app
memo index ingest --no-symbols --scope codeindex:my-app
```

**Query it:**

```bash
memo index status  --scope codeindex:my-app          # row counts by kind
memo index search  "where is dedup handled" --scope codeindex:my-app
memo index explore "store.write"  --scope codeindex:my-app   # callers + callees
memo index invalidate luamemo/store.lua --scope codeindex:my-app
# Ingest a commit's diff as searchable, symbol-attributed rows:
memo index diff --commit HEAD --scope codeindex:my-app
```

**Row kinds** (all in `codeindex:<project>`): `file` (one per tracked file,
stored FTS-only to bound embed cost), `symbol` (functions/classes/methods with
`path`, `line`, `symbol_type`, `exported`), `dependency` (import/require edges,
also mirrored into the knowledge graph for `index explore`), and `diff` (git-diff
hunks).

**Languages.** Pure-Lua pattern parsers cover **Lua, Python, and
JavaScript/TypeScript** out of the box. For any other language, if the
[`universal-ctags`](https://github.com/universal-ctags/ctags) binary is on PATH it
is used automatically to extract symbols; when it is absent those files are still
indexed at the file level. luamemo itself runs on **just Lua** — ctags is optional
enrichment, never required.

### Agent integration (MCP + session digest)

The bundled MCP server exposes four codebase-map tools that return compact
`path:line — name (type) — doc` text (not full file contents):

| Tool | Use |
|------|-----|
| `index_search`  | Find where code lives — call **before** grepping/reading files |
| `index_outline` | List everything a file defines — call **before** editing it |
| `index_explore` | Blast radius — callers and callees of a symbol |
| `index_status`  | Is a map available for this project, and how big |

`memo brief` prints a tiny session-start digest (memory count + map size + tool
hints). Wired to a **SessionStart hook** (see `hooks/hooks.json`), it is injected
automatically at the start of a session so the agent knows a map exists without
being asked — then pulls specifics on demand. The map locates and orients; the
file on disk remains the source of truth to read before editing.

---

## Auto-save hooks (Claude Code / Cursor)

luamemo ships shell hooks that wire automatic session persistence without any
manual `memory_write` calls. Set them up once and every Claude Code or Cursor
session is saved to your memory store.

### Claude Code

Add to `.claude/settings.json` in your project root:

```json
{
  "hooks": {
    "PreCompact": [
      { "command": "/absolute/path/to/hooks/claude/pre_compact.sh" }
    ],
    "PostToolUse": [
      { "command": "/absolute/path/to/hooks/claude/post_message.sh" }
    ]
  }
}
```

| Hook | Fires | What it saves |
|------|-------|---------------|
| `pre_compact.sh` | Before context compression | Last 20 messages, `importance=0.5` |
| `post_message.sh` | After each tool use (with cooldown) | Last 20 messages, `importance=0.4` |

Both hooks require `MEMO_DB_URL` in your shell environment (same value as the MCP
server). They also require `jq` on `PATH`. Hooks are fail-open: they exit `0`
silently on any error and never block the model.

**Cooldown**: `post_message.sh` saves at most once per `MEMO_HOOK_COOLDOWN_SECS`
(default `300` = 5 min) per session, preventing redundant writes during
high-frequency sessions.

**Scope**: defaults to `session:<CLAUDE_SESSION_ID>`. Override by setting
`MEMO_SCOPE` in your environment before launching Claude Code.

### Cursor

Cursor (0.43+) uses the same hook format. Add to `.cursor/mcp.json`:

```json
{
  "hooks": {
    "PreCompact": [
      { "command": "/absolute/path/to/hooks/cursor/pre_compact.sh" }
    ]
  }
}
```

`hooks/cursor/pre_compact.sh` is functionally identical to the Claude Code version
but reads `CURSOR_SESSION_ID` and `CURSOR_TRANSCRIPT_PATH`.

### VS Code Copilot Agent Mode

VS Code Copilot Agent Mode does not expose lifecycle hooks (`PreCompact`,
`PostToolUse`). The correct integration point is the `session_start` MCP prompt
already built into `mcp/server.lua`. When called at conversation start, it instructs
the agent to load recent memories, write key decisions during the session, and
summarise before closing. Wire it into your system prompt for automatic activation.

### VS Code Agent Plugin (Preview)

Install luamemo as a VS Code agent plugin for instant access to memory skills,
a pre-configured memory agent, and all 17 MCP tools in Agent Mode — without
writing any config files manually.

#### Quickstart (recommended)

Run `memo calibrate` in your project — it installs the plugin automatically
alongside the workspace MCP config:

```bash
memo calibrate
```

Then add `"chat.mcp.autoStart": true` to your VS Code settings so the MCP
server starts automatically when VS Code opens.

#### Manual install

In VS Code Chat, run **Chat: Install Plugin From Source** and enter:

```
https://github.com/kaio326/luamemo
```

VS Code clones the repo and activates the plugin. The `luamemo` agent and
`session-memory` skill appear immediately; the MCP server starts on first use.

#### Prerequisites

- VS Code 1.100+ with GitHub Copilot
- `lua5.1` binary on PATH (`apt install lua5.1` / `brew install lua`)
- `luarocks install pgmoon luasocket` (required by the MCP server)
- `MEMO_DB_URL` exported in your shell **or** written to `~/.luamemorc`
  by `memo calibrate`
- `~/.luamemorc` should be readable only by your user:
  ```bash
  chmod 600 ~/.luamemorc
  ```
  The MCP server loads this file at startup; restricting its permissions
  prevents other local users from reading your database credentials.

#### What you get

| Component | Description |
|-----------|-------------|
| `luamemo` agent | Activates automatically, calls `memory_status`, loads recent context, guides setup if DB is unreachable |
| `session-memory` skill | On-demand workflow guide: search on open, write decisions during work, summarise on close |
| 17 MCP tools | `memory_write`, `memory_search`, `memory_recent`, and all others — available in every VS Code workspace |

#### How it relates to `memo calibrate`

They work together. `memo calibrate` sets up per-project embedder config and
writes a workspace-level MCP entry that takes precedence over the plugin's
bundled server when working in that project. The plugin provides the agent UX
and a fallback MCP server in every other workspace. Running `memo calibrate`
once gives you both.

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

## Future direction — centralized agent collaboration

The long-term goal for `luamemo` is to serve as the memory backbone for a
**centralized, organization-wide agent collaboration system**.

The idea: a shared memory store holds the project's design principles,
architectural decisions, coding conventions, and accumulated context —
ingested and kept current across the entire team's work. Any agent connected
to that store, regardless of which developer is driving it, starts with
the same grounded understanding of the project.

The first concrete application of this is **automated code review**. When a
developer pushes to the company repository, an agent with deep knowledge of
the project's memory — its established patterns, past decisions, and known
constraints — reviews the diff and flags issues directly, before a human
reviewer ever sees it. Not a generic linter, but a reviewer that knows *why*
a particular abstraction exists, *what* trade-offs were made when the module
was designed, and *which* conventions the team has agreed to enforce.

This turns the memory store into shared institutional knowledge that
persists independently of any individual developer or session.

### Value for individual developers along the way

The collaboration goal is a destination, not a prerequisite. Every component
built toward it is immediately useful for a single developer working alone:

- **Persistent project memory** — the agent remembers decisions, conventions,
  and context across all sessions. You never re-explain your architecture.
- **Cross-session continuity** — `session_start` reconstructs context instantly,
  so a new chat is as productive as one that has been running for weeks.
- **Architecture-aware suggestions** — the KG and calibrated memory allow the agent
  to catch inconsistencies in your own code against your own past decisions, without
  needing a team or a push event.
- **Local-first by default** — everything runs on your own Postgres. No cloud account,
  no shared infrastructure required.

The individual setup is also the natural on-ramp: calibrate a project, use it for
a while, verify that the memory is accurate and useful — then connect it to a shared
store when the team is ready.

### Features needed to reach the collaboration goal

The following capabilities will need to be built before the full collaboration system
is viable. Each is independently useful and will be available as a standalone feature
regardless of whether the broader collaboration layer is ever adopted:

| Feature | Individual benefit | Collaboration role |
|---------|-------------------|-------------------|
| **Commit/diff digestion** — chunking and embedding diffs associated with the relevant code context | Agent understands *what changed* and *why*, grounding its suggestions in actual history | Powers the automated review agent's retrieval for any pushed change |
| **Privileges layer** — scope-level read/write access control per agent or team | Lets you define which parts of memory the agent can modify vs. only read | Required for safe multi-team, multi-repository shared stores |
| **Memory invalidation on refactor** — detecting when a large structural change makes old memories stale | Prevents the agent from applying outdated decisions to rewritten modules | Ensures the shared store stays accurate as the project evolves |
| **Digest scheduling** — periodic re-ingestion triggered by commits or CI events | Keeps individual project memory current without manual `memo calibrate` runs | The automated backbone for keeping the shared store synchronized |

### What is still to be defined

Two components of the collaboration system have no specification yet and are
actively open for input:

- **Digest method** — how diffs and commits are chunked, embedded, and associated
  with the relevant memory entries so the review agent retrieves the right context
  for each changed file or function
- **Privileges layer** — which agents can read which scopes, which can write,
  and how organization-level policies are enforced across teams and repositories
  sharing the same store

These specifications will be driven by real usage. If you are building something
in this direction, feedback and collaboration are welcome via
[GitHub Issues](https://github.com/kaio326/luamemo/issues).

---

## License

MIT. See [LICENSE](LICENSE).
