# Local-first: pure-Lua hash embedder

The `hash` embedder runs **in-process**, in pure Lua. It needs:

- no network
- no Python
- no model files
- no extra LuaRocks
- no LuaJIT bit ops

It is the truly local-first option: the same OpenResty worker that handles
the HTTP request also produces the embedding. Latency is microseconds.

## Quality trade-off

The hash embedder uses **signed feature hashing** over word tokens and
character trigrams. This captures **lexical** similarity (shared words,
shared sub-strings) but **not semantic** similarity — it cannot tell that
"car" and "automobile" are related.

In practice this matters less than it sounds, because `lapis-memory`
already runs a hybrid query: vector cosine **plus** Postgres FTS. The
hash embedder mostly reinforces what FTS already finds, while still
benefiting from pgvector's HNSW index for fast top-K filtering.

**Recommended use:**

| Tier | Embedder | Notes |
|------|----------|-------|
| Dev / offline / air-gapped | `hash` | zero deps, instant |
| Self-hosted production     | `ollama` (`nomic-embed-text`) | local, semantic |
| Cloud / highest quality    | `openai` (`text-embedding-3-small`) | paid |

You can swap tiers at any time **without re-creating the table** — just
re-embed existing rows by running `UPDATE lapis_memory SET body = body`
through your app, or call `memory.update(id, {body = row.body})` for each row.

## Setup

```lua
local memory = require("lapis_memory")
memory.setup({
    embedder_local = "hash",     -- enables in-process embedder
    embed_dim      = 384,        -- must match your schema's vector(N)
    default_scope  = "repo:my-app",
    auth_fn        = function(self) return is_admin(self) end,
})
memory.routes.register(app, { prefix = "/api/memory" })
```

That's the entire integration. No embedder service to run, no extra
container in `docker-compose.yml`, no API keys.

## Self-test

```lua
local hash = require("lapis_memory.embedders.hash")
local ok, err = hash.selftest({ embed_dim = 384 })
assert(ok, err)
```

## Switching to a real embedder later

When you outgrow lexical-only similarity, change two lines in `setup()`:

```lua
memory.setup({
    -- embedder_local = "hash",
    embedder_url     = "http://localhost:11434/api/embeddings",
    embedder_adapter = "ollama",
    embedder_model   = "nomic-embed-text",
    embed_dim        = 768,         -- and update schema's vector(768)
    ...
})
```

Then re-embed your existing rows once. The schema, API, and clients
don't change.
