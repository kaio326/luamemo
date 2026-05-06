# Brute-force backend (no pgvector)

The brute-force backend lets you run `luamemo` against a stock PostgreSQL
install — no extensions, no superuser, no `apt install postgresql-NN-pgvector`.
This is the path to use when:

- you cannot install Postgres extensions (managed databases, shared tenancy,
  hardened images);
- you are bootstrapping locally and don't want to rebuild your image;
- your corpus is small (rough cutover: 10k–50k rows, then revisit).

## How it works

| Concern    | pgvector path                          | brute-force path                                       |
|------------|----------------------------------------|--------------------------------------------------------|
| Storage    | `embedding vector(N)`                  | `embedding REAL[]` (plain array)                       |
| ANN index  | HNSW on `embedding`                    | none — full scan inside the SQL pre-filter             |
| Search     | SQL CTE with `<=>` cosine + FTS blend  | SQL fetches FTS-ranked candidates, Lua cosines them    |
| Dedup      | SQL `<=>` ORDER BY                     | Lua cosine over recent scope-scoped rows               |

Cosine, normalisation, weight, and decay are computed in Lua for the
brute-force path. The result row shape is identical to the pgvector path, so
the Web UI, HTTP, CLI, and MCP surfaces don't care which backend ran.

## Setup

### 1. Apply the no-extension schema

```bash
docker exec -i my-postgres \
  psql -U postgres -d my_db < luamemo/schema_bruteforce.sql
```

This is the same schema as `schema.sql` minus `CREATE EXTENSION vector` and
the HNSW index. The trigger, FTS column, and CHECK constraints are unchanged.

### 2. Configure the library

```lua
local memory = require("luamemo")

memory.setup({
    db_table       = "lapis_memory",
    embedder_local = "hash",        -- or your model of choice
    embed_dim      = 384,
    backend        = "auto",        -- "auto" | "pgvector" | "bruteforce"
    bruteforce_candidate_limit = 1000,
})
```

`backend = "auto"` (the default) probes
`SELECT 1 FROM pg_extension WHERE extname='vector'` once at startup and picks
the right path. Force a backend with `"pgvector"` or `"bruteforce"` to
override the probe.

The choice is logged at startup:

```
[info] luamemo: backend=bruteforce
```

### 3. Use the same API

`memory.write`, `memory.search`, `memory.recent`, `memory.update`,
`memory.delete`, dedup, decay, and the Web UI all behave the same. The only
visible difference is per-search latency (see "When to switch" below).

## Tuning

`bruteforce_candidate_limit` (default `1000`) caps how many rows the SQL
pre-filter pulls into Lua per search. The pre-filter orders by
`ts_rank_cd(fts, plainto_tsquery(query))` so lexically-relevant rows survive
the cap. Lower it for hot paths if your scope/kind filters are not selective.

## When to switch to pgvector

The brute-force path scales linearly: at the candidate cap you do `cap`
cosine multiplications per search in Lua. With `cap = 1000` and 384-dim
vectors that is ~384k mults — comfortably sub-millisecond on LuaJIT.

Switch to pgvector when:

- you outgrow your candidate cap (results start feeling stale because the
  SQL pre-filter is dropping relevant rows);
- you exceed roughly 10k–50k rows per scope and want sub-100 ms p99;
- you can install the extension.

The migration is non-destructive:

```bash
psql -U postgres -d my_db -c "CREATE EXTENSION vector;"
psql -U postgres -d my_db < luamemo/schema.sql
```

The `schema.sql` migration is idempotent — it adds the HNSW index and
converts the `embedding` column. Then drop the explicit `backend = "..."`
override (or set it to `"auto"`) and restart; the probe will pick pgvector.

## Smoke test

A reference end-to-end exercise lives at `eval/smoke_bruteforce.lua`. Run it
against a throwaway database:

```bash
docker exec -i <postgres-container> psql -U postgres -c \
  'DROP DATABASE IF EXISTS lm_bruteforce_test; CREATE DATABASE lm_bruteforce_test;'
docker exec -i <postgres-container> psql -U postgres -d lm_bruteforce_test \
  < luamemo/schema_bruteforce.sql
PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=postgres \
  PGDATABASE=lm_bruteforce_test lua5.1 eval/smoke_bruteforce.lua
```

It exercises write / near-duplicate merge / forced append / semantic search /
lexical search / payload stripping and prints `ALL PASS` on success.
