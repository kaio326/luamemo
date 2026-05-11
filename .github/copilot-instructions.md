# Copilot Instructions — luamemo

## Identity
Your name is **Momo**.

## Project Overview
`luamemo` is a persistent semantic memory library for AI agents. It works in
**any Lua 5.1+ runtime** — Lapis / OpenResty is supported but not required. The
library is a LuaRocks package installed via `luarocks-5.1 install luamemo`.
It is **not** a runnable app by itself — it is consumed by a host app or eval harness.

- **GitHub**: https://github.com/kaio326/luamemo
- **LuaRocks package name**: `luamemo`
- **Current version**: `0.2.7-1` (tag `v0.2.7`)
- **Primary consumers**: any Lua application or AI agent that needs persistent semantic memory — Lapis/OpenResty apps, standalone Lua scripts, MCP-bridged agents (Claude Desktop, Cursor, Copilot Agent Mode), and eval harnesses

## Stack
- **Language**: Lua 5.1 / LuaJIT (OpenResty or plain Lua 5.1+)
- **Runtime APIs**: `luamemo.crypto` (pure-Lua AES-256-CBC + HMAC-SHA256), `luasocket`/`resty.http` (HTTP), `ngx.*` (OpenResty only)
- **DB**: PostgreSQL 15 via `luamemo.db` — pgmoon direct connection always; configured via `MEMO_DB_URL` URL or individual `PG*` env vars
- **Protocol**: MCP (Model Context Protocol) stdio JSON-RPC 2.0 via `mcp/server.lua`
- **No Node, no Python runtime** — pure Lua

## Repository Layout

```
luamemo/           Core library modules
  init.lua              Entry point / M.setup() / re-exports
  json.lua              Portable JSON shim — tries cjson.safe (OpenResty), falls back to vendor/dkjson
  util.lua              Shared helpers (trim, read_file, to_bool, load_submodule,
                          check_http, sql_id_list, clamp_check, clip, parse_scores)
  store.lua             Vector + FTS memory storage
  embed.lua             Embedder dispatch
  db.lua                Portable PostgreSQL adapter (pgmoon only; MEMO_DB_URL or PG* env vars)
  http.lua              Portable HTTP client (resty.http in OpenResty; socket.http outside)
  routes.lua            Lapis HTTP route factory (M.register)
  kg.lua                Knowledge-graph (lm_kg_facts)
  rerank.lua            Reranker dispatch
  secrets.lua           AES-256-CBC encrypted secret storage (pure-Lua via luamemo.crypto)
  crypto.lua            Pure-Lua AES-256-CBC + HMAC-SHA256 + CSPRNG (zero C deps)
  summarizer.lua        Background summarizer
  async.lua             Pure-Lua coroutine scheduler (run_all, wait) for parallel embedding
  lsh.lua               Random-hyperplane LSH index for bruteforce backend ANN acceleration
  vendor/
    dkjson.lua          Bundled dkjson 2.5 (pure Lua, MIT) — JSON fallback when cjson absent
  adapters/             Embedder adapters (ollama, openai, tei, …)
  embedders/            hash (pure-Lua, zero-deps)
  rerankers/            noop, ollama, openai, cross_encoder, _common (shared build_candidates)
  summarizers/          noop, ollama, openai, _common (shared build_memory_lines)
  cli/                  memo calibrate / memo doctor / api dispatcher support modules
    api.lua               Single-operation Lua dispatcher (stdin JSON → lib call → stdout JSON)
mcp/
  server.lua            Standalone CLI stdio MCP server (11 tools, direct lib calls)
cli/
  memo                  Shell entrypoint (all subcommands, no curl — uses luamemo.cli.api)
examples/               Usage documentation
luamemo-0.2.7-1.rockspec
```

## Architecture

### HTTP routes (`luamemo/routes.lua`)
`M.register(app, opts)` registers all routes under `prefix` (default `/api/memory`).
- `authorise(self)` guards every route — calls `cfg.before_request` then `cfg.auth_fn`
- `decode_body(self)` normalises POST params / JSON body
- `json(status, body)` returns a Lapis response table

Route groups (all under `prefix`):
| Group | Routes |
|-------|--------|
| Core memory | CRUD + search + recent + promote |
| Knowledge graph | `/kg/*` — query, invalidate, timeline |
| Secrets | `/secrets`, `/secrets/:name/delete`, `/secrets/:name/execute` |

### MCP server (`mcp/server.lua`)
Standalone CLI process — JSON-RPC 2.0 over stdio. Calls `store.*`, `summarizer.*`, `secrets.*` directly via `require` — no HTTP intermediary.

Config via env vars: `MEMO_DB_URL` (required), `MEMO_SCOPE`, `MEMO_MASTER_KEY`, `MEMO_SECRETS_FILE`, `MEMO_DEBUG`.

Tools table (each entry: `{ description, inputSchema, handler }`):
- `memory_write`, `memory_search`, `memory_recent`, `memory_get`, `memory_update`, `memory_delete`, `memory_promote`
- `secret_list`, `secret_store`, `secret_delete`, `secret_execute` ← NEW in 0.1.2

Prompts table (each entry: `{ description, arguments?, text-builder }`):
- `session_start` — instructs the agent to load context at session start, write decisions during work, and summarise at end. Accepts optional `scope` and `project` arguments.

### Config (`M.setup(config)`)
All config keys set on `M.config`. `M.setup()` is called once by the host app at startup. Key fields:

| Key | Purpose |
|-----|---------|
| `embedder_local` | Which embedder to use (`"hash"`, `"ollama"`, `"openai"`, …) |
| `auth_fn` | Function `(self) → bool` — return truthy to allow, false/nil to deny |
| `before_request` | Pre-auth hook — the correct place for rate limiting, CSRF checks, and request logging. Called on every route before `auth_fn`. |
| `master_key_path` | Path to a file containing a 64-hex-char master key for secrets |
| `pg_host` | PostgreSQL host (plain-Lua / non-OpenResty only; ignored under OpenResty) |
| `pg_port` | PostgreSQL port (default 5432; plain-Lua only) |
| `pg_database` | PostgreSQL database name (plain-Lua only) |
| `pg_user` | PostgreSQL user (plain-Lua only) |
| `pg_password` | PostgreSQL password (plain-Lua only) |
| `master_key_env` | Name of an env var containing the master key |
| `master_key` | Explicit master key string (dev/CI only) |
| `dedup_candidate_limit` | Max candidates fetched per scope for batch dedup in `write_many()` (default 1000) |
| `lsh_enabled` | `false` to disable LSH globally (default `true`) |
| `lsh_rebuild_at` | Row count per scope at which LSH index is built (default 10000) |
| `lsh_tables` | LSH table count L — higher recall vs more memory (default 8) |
| `lsh_bits` | LSH bits per key K — smaller buckets vs lower recall (default 12) |
| `embed_dim` | Fallback embedding dimension for LSH when inference unavailable (default 384) |

## Secrets Module (`luamemo/secrets.lua`) — v0.2.1+

### Design principle: execute_with_secret
The raw secret value **never crosses the LLM context boundary**. Only the HTTP response is returned.

### Key points
- AES-256-CBC + HMAC-SHA256 via `luamemo.crypto` (pure Lua, zero C deps)
- Secrets stored in a **JSON file on disk** (`secrets_file` config key). No database table.
- Stored format per entry: `"<32-char iv_hex>:<ciphertext_hex>:<64-char mac_hex>"`
- HMAC comparison is constant-time (always iterates the full expected length).
- Multipart boundary generated via `luamemo.crypto.random_bytes` (CSPRNG, not `math.random`).
- SSRF guard: `execute_with_secret` blocks non-http/https schemes **and** known private IP
  ranges (`localhost`, `127.x`, `169.254.x`, `10.x`, `192.168.x`, `172.16-31.x`, `::1`).
  The hostname is also **DNS-resolved** at call time and the resolved IP is re-checked
  against the same blocklist (closes DNS-rebinding bypasses). Unresolvable hosts are
  rejected (fail-closed). Multipart file paths are validated: no `..` traversal and no
  symlinks (`test ! -L`); fail-closed on Windows.
- Master key resolution order: `master_key_path` file → `master_key_env` env var → `master_key` explicit. If none set, module is disabled; all other library features continue to work.
- No `get_secret` API exists — values cannot be retrieved through the HTTP or MCP layer

### Public API
```lua
local secrets = require("luamemo.secrets")

secrets.configure(config)            -- called automatically by M.setup()
secrets.enabled()                    -- → bool
secrets.store(name, value, desc)     -- → row, err
secrets.list()                       -- → [{id, name, description, ...}]  (no ciphertext)
secrets.delete(name)                 -- → bool, err
secrets.execute_with_secret(name, opts)  -- → response_body, err
```

`execute_with_secret` opts: `{ url, method?, headers?, body?, timeout_ms? }`.
Write `{secret}` anywhere in `url`, header values, or `body` — it is substituted server-side.

### Config keys for secrets
| Key | Purpose |
|-----|---------|
| `secrets_file` | Writable path for the JSON secrets file (auto-created). Required to enable secrets. |
| `master_key_path` | Path to a file containing the 64-hex-char master key |
| `master_key_env` | Name of an env var containing the master key |
| `master_key` | Explicit master key string (dev/CI only) |

## Migrations Pattern
- `migrations/001_init.sql` runs `\i schema.sql` for fresh installs
- `schema.sql` / `schema_bruteforce.sql` define only the base `lm_memories` table
- All addons (KG) live in numbered migration files
- Migrations must be idempotent (`IF NOT EXISTS`, `IF EXISTS`)
- Apply sequentially: `psql -d mydb < luamemo/migrations/003_kg.sql`
- Secrets have **no migration** — they use a JSON file, not a DB table

## Rockspec Conventions
- File naming: `luamemo-<version>-<revision>.rockspec`
- `source.tag` must match the Git tag exactly (e.g. `"v0.2.0"`)
- All new `luamemo/*.lua` modules must be added to `build.modules`
- After creating a new rockspec: `git tag v<version> && git push origin v<version>`, then `luarocks upload luamemo-<version>-<revision>.rockspec`

## Example Consumer Wiring (Lapis/OpenResty app)
A Lapis app calls `M.setup()` wrapped in `pcall` — failures log to `ngx.ERR` and never block app startup. To enable secrets:
1. Add `secrets_file = "/app/data/lm_secrets.json"` and `master_key_path = "/run/secrets/lm_master_key"` to the `setup({})` call in `helpers/memory.lua`
2. Generate key: `openssl rand -hex 32 > secrets/lm_master_key.txt`
3. Add `lm_master_key` to `docker-compose.yml` secrets section
4. Mount a persistent volume for `/app/data/` so the secrets file survives container restarts
5. Bump `luarocks-5.1 install luamemo` version in your `Dockerfile` to `0.2.7-1`

## Implementation Philosophy
When making changes to this codebase, always build things the right way — no shortcuts, no deferred abstractions, no "we'll fix it later." If a component needs to be rewritten to be correct, rewrite it. Leaving known technical debt in place is never acceptable. The goal is a codebase that does not need to be revisited for the same problem twice.

## Developer Workflow
```bash
# The library has no runnable dev server — test via a host Lapis app.
# For quick Lua syntax checks:
luac -p luamemo/secrets.lua

# Calibrate (host probe + codebase ingest) — run whenever the codebase changes:
MEMO_DB_URL=postgresql://postgres:@127.0.0.1:5432/luamemo_dev \
  memo calibrate --scope repo:luamemo
# First run (no DB): probe-only mode (prints config snippet)
memo calibrate --probe-only

# Push a new version
git tag v0.2.X && git push origin main v0.2.X
luarocks upload luamemo-0.2.X-1.rockspec  # requires API key
```

## File Editing Rule
**Never edit workspace files via terminal commands** (`sed -i`, `echo >`, `tee`, etc.). Always use the dedicated file editing tools (`replace_string_in_file`, `multi_replace_string_in_file`, `create_file`). Terminal commands are for reading/inspecting only.

## Commit Message Format
Follow conventional commits:
```
<type>: <short summary in imperative mood>

- <bullet: what changed and why>
```
Types: `feat`, `fix`, `refactor`, `chore`, `docs`.

## Key Files
| File | Purpose |
|------|--------|
| `luamemo/init.lua` | Entry point; `M.setup()`, config defaults, re-exports |
| `luamemo/json.lua` | Portable JSON shim: tries `cjson.safe`, falls back to `luamemo.vendor.dkjson` |
| `luamemo/vendor/dkjson.lua` | Bundled dkjson 2.5 (pure Lua, MIT) — JSON fallback when cjson absent |
| `luamemo/util.lua` | Shared helpers used across all modules (trim, read_file, to_bool, load_submodule, check_http, sql_id_list, clamp_check, clip) |
| `luamemo/routes.lua` | HTTP route factory; `M.register(app, opts)` |
| `luamemo/db.lua` | Portable PostgreSQL adapter (pgmoon only) |
| `luamemo/http.lua` | Portable HTTP client (resty.http → OpenResty; socket.http → plain Lua); `request_async` for non-blocking HTTP |
| `luamemo/async.lua` | Coroutine scheduler: `run_all(tasks)` fans out N tasks concurrently; `wait(sock, event)` yields inside a coroutine |
| `luamemo/lsh.lua` | Random-hyperplane LSH: `new(dim,L,K)`, `insert`, `remove` (lazy), `query`, `rebuild`; auto-activated by store.lua at >lsh_rebuild_at rows |
| `luamemo/crypto.lua` | Pure-Lua AES-256-CBC + HMAC-SHA256 + CSPRNG |
| `luamemo/secrets.lua` | AES-256-CBC secret storage (JSON file) + execute_with_secret |
| `luamemo/kg.lua` | Knowledge-graph fact store |
| `luamemo/rerankers/_common.lua` | Shared `build_candidates(hits, chunk_max)` used by ollama + openai rerankers |
| `luamemo/summarizers/_common.lua` | Shared `build_memory_lines(memories, body_clip)` used by ollama + openai summarizers |
| `luamemo/cli/calibrate.lua` | Host probe + embedder recommendation + codebase ingest (replaces init) |
| `luamemo/cli/api.lua` | Single-operation Lua dispatcher (stdin JSON → lib call → stdout JSON) |
| `mcp/server.lua` | Standalone MCP stdio server (11 tools) |
| `cli/memo` | CLI entrypoint (memo calibrate, doctor, and all HTTP-API commands) |
| `luamemo-0.2.7-1.rockspec` | Current LuaRocks package spec |
| `CHANGELOG.md` | Release notes |
