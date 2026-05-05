# lapis-memory

A drop-in **persistent memory store for AI agents** built on
[Lapis](https://leafo.net/lapis/) + [OpenResty](https://openresty.org/) +
plain PostgreSQL. [pgvector](https://github.com/pgvector/pgvector) is
auto-detected and used when available, but **not required** — the default
backend is a pure-Lua brute-force search that runs on any Postgres 15+.

> Give your agent a real memory that survives session crashes, JSON-overflow
> errors in chat clients, container restarts, and device switches — without
> taking on any new runtime services beyond what your Lapis app already runs.

**Lua-first.** Every component — embedder, store, routes, Web UI, MCP
server, summarizer — is written in Lua. The only non-Lua hard dependencies
are PostgreSQL and OpenResty (and OpenResty is optional for CLI / MCP use).

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
- **Auto-capture hooks**: `lapis_memory.hooks` wires chat agents into
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
          │  HTTP routes  │  CLI (memo)  │  │
          │  Web UI       │  MCP server  │  │
          └──────┬───────────┬──────────────────┘
                 │           │
                 ▼           ▼
          ┌──────────────────────────────────┐
          │  init.lua  —  setup() + config  │
          └───┬────────────────────────────────┘
              │
     ┌───────┼───────────────┐
     ▼               ▼                ▼
  store.lua       embed.lua       summarizer.lua
  (write/get/    (in-process     (timer + adapters
   search/        hash OR HTTP    in summarizers/)
   recent/         adapter in
   delete/         adapters/)
   dedup)
     │
     ▼
  PostgreSQL  (pgvector if present, REAL[] otherwise)
```

### Module map

| Module                              | Role                                            |
|-------------------------------------|-------------------------------------------------|
| `lapis_memory.init`                 | Public entry point. `setup()`, re-exports, `start_background_jobs()`. |
| `lapis_memory.store`                | All SQL. Write / get / search / recent / update / delete / dedup / summary replacement. |
| `lapis_memory.embed`                | Embedder dispatcher. Picks in-process embedder or HTTP adapter. |
| `lapis_memory.embedders.hash`       | Pure-Lua feature-hashing embedder. Zero deps.   |
| `lapis_memory.adapters.*`           | HTTP embedder adapters (Ollama, OpenAI, Voyage, Cohere, generic). |
| `lapis_memory.routes`               | Lapis route factory. 7 endpoints under one prefix. |
| `lapis_memory.web`                  | Server-rendered admin browser. Pure-Lua HTML, double-submit-cookie CSRF. |
| `lapis_memory.summarizer`           | Selection + adapter dispatch + transactional replacement. |
| `lapis_memory.summarizers.*`        | LLM adapters for summarisation (`noop`, `ollama`, `openai`). |
| `lapis_memory.schema.sql`           | Fresh-install schema for the **pgvector** backend. |
| `lapis_memory.schema_bruteforce.sql`| Fresh-install schema for the **brute-force** backend (no extension). |
| `lapis_memory.migrations/`          | Idempotent ALTERs for live DBs.                 |
| `cli/memo`                          | Bash CLI; calls the HTTP API with bearer token. |
| `mcp/server.lua`                    | Pure-Lua stdio MCP server. 6 tools.             |

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
4. Rows returned in a backend-agnostic shape so HTTP / Web UI / CLI / MCP
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

## 5-minute setup

### 1. Database

**Default (zero infra):** any PostgreSQL 15+. No extension required.
```bash
psql -U postgres -d mydb -f lapis_memory/schema_bruteforce.sql
```

**Faster path (when you can install extensions):** the official
`pgvector/pgvector:pg15` image, the `postgresql-15-pgvector` Debian/Ubuntu
package, or a managed Postgres that allows `CREATE EXTENSION vector`.
```bash
psql -U postgres -d mydb -f lapis_memory/schema.sql
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
local memory = require("lapis_memory")
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

That's it. You now have:

| Method | Path                          | Purpose                       |
|--------|-------------------------------|-------------------------------|
| POST   | `/api/memory/write`           | Insert a memory               |
| GET    | `/api/memory/search?q=...`    | Hybrid search                 |
| GET    | `/api/memory/recent`          | Recent memories               |
| GET    | `/api/memory/:id`             | Fetch one                     |
| POST   | `/api/memory/:id/update`      | Update (re-embeds if changed) |
| POST   | `/api/memory/:id/delete`      | Hard delete                   |

---

## Programmatic API

```lua
local memory = require("lapis_memory")

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

A self-contained, server-rendered admin browser at `/memory/ui` (mount
prefix configurable). List, search, scope/kind filter, inline edit, and
delete with double-submit-cookie CSRF. Pure-Lua HTML rendering, zero
template-engine dependency on the host app:

```lua
memory.routes.register(app, { prefix = "/api/memory" })
memory.web.register(app,    { prefix = "/memory/ui" })
```

See [examples/web_ui.md](examples/web_ui.md) for the full QA recipe.

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

Adapters in `lapis_memory.adapters.*` translate this contract to
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
| `lapis_memory/schema.sql`              | `pgvector`  | `vector` (HNSW for fast ANN) |
| `lapis_memory/schema_bruteforce.sql`   | `bruteforce`| none                        |

Both define the same columns. The only differences are the type of
`embedding` (`vector(N)` vs `REAL[]`) and whether an HNSW index is created.
The table is opinionated but extensible via the `metadata JSONB` column.
The default embedding dimension is **384** (matches `all-MiniLM-L6-v2` and
`nomic-embed-text`); change it before running the migration if you use a
different model.

---

## Backends & cost

`lapis-memory` ships two backends. Both are first-class — the HTTP API,
Web UI, CLI, and MCP server work identically against either.

### `bruteforce` (default, zero infra)

- Storage: `embedding REAL[]` column on plain Postgres.
- Search: SQL pre-filters by `scope` / `kind` / FTS rank, returns up to
  `bruteforce_candidate_limit` (default **1000**) candidate rows; Lua
  computes cosine and ranks them.
- **Pros**
  - `luarocks install lapis-memory` + any Postgres 15 = working install.
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
lives in [`eval/`](eval/README.md). Run:

```bash
scripts/download_eval.sh eval/data
resty -I . eval/run.lua --dataset eval/data/longmemeval_oracle.json \
    --out eval/results/oracle_hash.json --embedder hash
lua eval/score.lua eval/results/oracle_hash.json
```

Reports R@1 / R@5 / R@10 globally and per `question_type`. Results are
embedder-dependent; see `eval/README.md` for the comparison recipe across
`hash`, `ollama`, and `openai` embedders.

---

## Why this exists

AI coding agents lose context constantly:

- Chat session JSON files exceed V8's `kMaxLength` and crash the editor.
- Compaction summaries drop critical decisions.
- A new device or new session = total amnesia.
- Cloud-only memory tools don't survive offline work or org policies.

`lapis-memory` makes the chat transcript **disposable**. The agent writes
durable summaries / decisions / facts to your own Postgres, then searches
them on demand. Survives crashes, devices, and editor bugs.

---

## License

MIT. See [LICENSE](LICENSE).
