# Changelog

## 0.2.5 — 2026-05-09

- **LSH ANN backend (`luamemo/lsh.lua`) — new module.**
  Random-hyperplane Locality-Sensitive Hashing (Charikar 2002) for cosine
  similarity. Pure Lua 5.1, zero new dependencies. Activates automatically
  on the bruteforce backend when a scope's corpus exceeds `lsh_rebuild_at`
  rows (default 10 000). Reduces the candidate fetch from 1 000 rows to
  ≈100–300, cutting search latency proportionally. Tunable via
  `lsh_enabled`, `lsh_rebuild_at`, `lsh_tables` (default 8),
  `lsh_bits` (default 12). `_get_lsh()` hooks into `_find_near_duplicate()`
  and `_search_bruteforce()`; insert/update paths keep the in-process index
  current without a full rebuild.

- **Batch dedup for `write_many()` — O(1) DB queries instead of O(N).**
  Previously each row in a `write_many()` call with `dedup_strategy != "append"`
  issued one `_find_near_duplicate()` DB round-trip.  Now: (1) an intra-batch
  dedup pass compares all pairs in the embed queue using the in-process
  `_cosine()` function; (2) one `SELECT ... LIMIT <dedup_candidate_limit>`
  per distinct scope fetches all candidates; (3) cosine matching runs in Lua
  memory.  New config key: `dedup_candidate_limit` (default 1 000).

- **Parallel async embedding for `write_many()` (`luamemo/async.lua`) — new
  module.** When running outside OpenResty and the batch has more than one
  row, embeddings are fetched concurrently via `luamemo.async.run_all()` —
  a pure-Lua coroutine scheduler built on non-blocking `socket.tcp()`.
  `luamemo.http.request_async()` and `luamemo.embed.embed_async()` are the
  public async entry-points.  Falls back to sequential embedding when
  inside OpenResty (resty.http is already non-blocking) or when using HTTPS
  or a local embedder.

- **`tune_weights` sampling fix.** For corpora > 10 000 rows,
  `_sample_rows()` now issues `TABLESAMPLE BERNOULLI` with 3× oversampling
  instead of a full-table `ORDER BY random()` scan, capping I/O while
  keeping the sample representative.

- **`migrations/005_composite_indexes.sql` — new migration.**
  Adds `CREATE INDEX IF NOT EXISTS lm_memories_scope_kind_idx ON lm_memories (scope, kind)`
  to accelerate scope+kind filtered queries on the bruteforce backend.

- **Shared helper modules (code quality).**
  `luamemo/rerankers/_common.lua` (`build_candidates`) and
  `luamemo/summarizers/_common.lua` (`build_memory_lines`) extracted from
  the Ollama/OpenAI adapters to eliminate duplication.  All callers updated.

- **`util.shell_quote`, `util.require_str` — new helpers.**
  `shell_quote(s)` wraps a value in POSIX single-quotes with `'` → `'\''`
  escaping, replacing all ad-hoc quoting in `calibrate.lua` and `secrets.lua`.
  `require_str(v, name)` validates a non-empty string argument, returning
  `nil, err` on failure.

- **Security hardening.**
  - `secrets.execute_with_secret`: SSRF guard extended with a live DNS
    re-validation pass (`socket.dns.toip`) after the hostname string-match
    check to catch bypasses via numeric-looking hostnames; multipart symlink
    guard uses `util.shell_quote`; `os.execute` exit-code check corrected for
    Lua 5.1 semantics.
  - `routes.lua`: all boolean query-param coercions delegated to
    `util.to_bool()`; `recent` limit capped at 100 (was unbounded).
  - `kg.lua`: `require_str` replaces the local duplicate validation function.
  - `hooks.lua`: `clip` alias corrected (was `trim`, which shadowed the wrong
    function), fixing silent body truncation in all 5 hook call sites.

## 0.2.5 — 2026-05-08

- **Direct DB access — HTTP layer removed.** `MEMO_DB_URL` (PostgreSQL URL)
  replaces `MEMO_URL` + `MEMO_TOKEN` for all CLI and MCP operations.
  Accepts `postgresql://[user[:pass]@][host][:port][/db]`; falls back to
  individual `PGHOST`/`PGPORT`/`PGDATABASE`/`PGUSER`/`PGPASSWORD` env vars
  or `luamemo.config` `pg_*` keys.
- **`luamemo/db.lua` — pgmoon only.** `lapis.db` detection and all HTTP
  adapters removed. A URL parser (`parse_db_url`) handles `MEMO_DB_URL`.
  `M.reset()` forces reconnect (useful in long-lived processes after a
  config change). Public API unchanged: `query`, `escape_literal`,
  `escape_identifier`, `interpolate_query`, `delete`.
- **`luamemo/cli/api.lua`** — new single-operation Lua dispatcher.
  Each invocation reads a JSON object from stdin, calls the appropriate
  `luamemo.*` library function, and writes the JSON result to stdout.
  Commands: `write`, `write-many` (NDJSON stream), `search`, `recent`,
  `get`, `update`, `delete`, `summarize`, `promote`, `consolidate`,
  `kg-query`, `kg-assert`, `kg-invalidate`, `kg-timeline`, `secret-list`,
  `secret-store`, `secret-delete`, `secret-execute`, `context`.
  Used by both `cli/memo` (Bash → Lua pipe) and `mcp/server.lua` (direct
  `require` calls).
- **`mcp/server.lua` — direct lib calls, no curl.** All 11 tool handlers
  now call `store.*`, `summarizer.*`, `secrets.*` directly. Removed:
  `MEMO_URL`, `MEMO_TOKEN`, `http_request()`, `shell_quote()`,
  `urlencode()`, `build_query()`. Config: `MEMO_DB_URL`, `MEMO_SCOPE`,
  `MEMO_MASTER_KEY`, `MEMO_SECRETS_FILE`, `MEMO_DEBUG`.
- **`cli/memo` — all curl removed.** Every subcommand now pipes a JSON
  payload through `lua -e "require('luamemo.cli.api').dispatch('cmd')"`.
  `memo calibrate` Phase 4 pipes `calibrate.run({--scan})` output directly
  into `api.dispatch('write-many')`. No HTTP server running required.
- **Pre-release security and correctness audit — all findings fixed:**
  - `secrets`: constant-time HMAC comparison; key length stripped from error
    messages; path traversal guard in `execute_with_secret` multipart upload;
    full SSRF IP-range blocking (localhost, 127.x, 169.254.x, 10.x,
    192.168.x, 172.16–31.x, ::1) added alongside existing scheme guard;
    multipart boundary now uses `crypto.random_bytes` (CSPRNG) instead of
    `math.random`; `os.execute` chmod exit-code check fixed for Lua 5.1
    (non-zero integer is a failure, not `false`); `_read_file` deduplication
    removed (delegates to `util.read_file`).
  - `store`: `M.recent` now honours `kind` filter and `offset` pagination
    arguments (previously silently ignored); temporal `until` bound key
    corrected to `args["until"]` (was `args.until_`, never matched callers).
  - `store`, `cli/api`, `mcp/server`: `store.write` returns `(row, err, action)`;
    all three callers now destructure in the correct order (previously `action`
    and `err` were swapped, causing error messages to be silently discarded).
  - `calibrate`: all three `io.popen` sites shell-quote the `root` and
    `range`/`dir` arguments to prevent command injection via CLI flags.
  - `mcp/server`: DB password redacted from `MEMO_DEBUG=1` startup log;
    `tools/list` and `prompts/list` responses are now sorted alphabetically
    (deterministic across runs).
  - `summarizers`: memory body clipped to 1500 chars before sending to
    summarizer LLM to prevent oversized prompts.
- **`luamemo/util.lua` — centralised shared helpers.** All previously
  duplicated one-liners across adapters, CLI modules, and dispatchers now
  delegate to a single source of truth:
  `trim`, `read_file`, `to_bool`, `load_submodule`, `check_http`,
  `sql_id_list`, `clamp_check`, `clip`, `parse_scores`.
  Every module that previously had its own copy now `require("luamemo.util")`.

## 0.2.4 — 2026-05-07

- **`memo context QUERY`** — new CLI subcommand that assembles a compact,
  prompt-injection-ready context block from `memory_search` + optional KG
  facts in a single call. Zero cloud dependency: uses the already-configured
  local embedder. Supports `--scope`, `--limit`, `--no-kg`, and
  `--format text|json`.
- **KG facts injected into `session_start` prompt** — `prompts/get` now
  fetches live facts from `/kg/query` for the requested scope and prepends
  a "Ground truth facts (knowledge graph — treat as authoritative)" block
  before the free-text memory guidance. Degrades silently when no facts exist
  or the KG table has not been migrated.
- **`memo consolidate`** — new CLI subcommand backed by `POST /consolidate`
  and `memory_consolidate` MCP tool. Runs three maintenance phases:
  - Phase 1 (always): set `importance = 0` on memories whose effective
    importance (after decay) has fallen below `decay_threshold` (default 0.05).
  - Phase 2 (always): fetch up to `max_rows` memories, compute pairwise cosine
    similarity via union-find, report near-duplicate clusters
    (`similarity_threshold` default 0.85).
  - Phase 3 (only if a non-noop summarizer is configured): merge each cluster
    into a single summary row via `replace_with_summary`.
  Use `--dry-run` to inspect without applying any changes.
- `store.find_decayed(opts)` and `store.find_clusters(opts)` added.
- `summarizer.consolidate(opts)` added.
- **MCP `prompts` capability** added to `mcp/server.lua`. Advertises
  `prompts: {}` in `initialize` capabilities and implements `prompts/list`
  and `prompts/get`. A single built-in prompt, `session_start`, gives any
  MCP client (Claude Desktop, Cursor, Copilot Agent Mode, …) a standard
  hook to load persistent context at the start of every session and write
  key decisions as work progresses. Accepts optional `scope` and `project`
  arguments; defaults to `MEMO_SCOPE` env var.
- **Tighter tool descriptions**: `memory_search`, `memory_write`, and
  `memory_recent` now include explicit guidance on *when* to call them
  so clients that don't invoke `session_start` still get nudged correctly.
- `SERVER_VERSION` bumped to `"0.2.4"` to match library version.
- **`memo calibrate`** replaces `memo init` entirely. Three-phase command:
  - Phase 1 (no server required): host probe (GPU, Docker, Ollama, RAM) +
    embedder recommendation + ready-to-paste `setup({...})` snippet.
  - Phase 2: corpus health check (requires `MEMO_URL`).
  - Phase 3: codebase ingest — automatically scans agent instruction files
    (`.github/copilot-instructions.md`, `AGENTS.md`, `.cursorrules`, …),
    ADR/decision documents, top-level markdown (`README`, `ARCHITECTURE`, …),
    tagged source comments (`ARCH:`, `DECISION:`, `DESIGN:`), and recent git
    commits. Uses `dedup_strategy = "update"` so reruns refresh content
    without duplicating. KG cursor (`calibrate last_commit`) makes git
    scanning incremental on subsequent runs. Scope auto-detected from
    `MEMO_SCOPE` → git remote basename → directory name.
  `luamemo.cli.init` removed; `luamemo.cli.calibrate` added to rockspec.

---

## 0.2.3 — 2026-05-07

- **Remove web UI** (`luamemo/web.lua` deleted). The `memo` CLI already
  covers all web UI functionality (`search`, `recent`, `get`, `update`,
  `delete`) with better agent ergonomics (pipeable, no browser needed).
  `M.web` removed from `init.lua`.
- **Drop `lapis` dependency** from rockspec. The library never `require("lapis")`
  — `routes.lua` accepts a Lapis `app` object supplied by the host, and
  `db.lua` pcall-detects `lapis.db` opportunistically. Lapis remains supported
  as a host framework; it is no longer a required install.
- **Fix `db_table` default**: `"lapis_memory"` → `"lm_memories"` in
  `init.lua`. The table was renamed in 0.2.0 but the default config value
  was not updated, causing fresh installs to query the wrong table name.
- **Fix `memo migrate` SQL**: all `lapis_memory` table/index/trigger names
  updated to `lm_memories` to match `schema.sql` and the migration files.
- **Fix `memo` CLI `require` path**: `require('lapis_memory.cli…')` →
  `require('luamemo.cli…')` — the old path has never worked since the
  package rename.
- README: removed `lua-openssl` from the hard-dependencies description;
  updated architecture diagram and flow descriptions to remove Web UI
  references.

---

## 0.2.2 — 2026-05-07

- **Fix `decode_body` in `routes.lua`**: the old early-return on
  `next(self.params)` caused the JSON request body to be silently ignored
  on any route that has URL path params (e.g. `:name`). This broke
  `POST /secrets/:name/execute` — the `url`, `method`, `headers`, and
  `body` fields from the JSON body were never read. The fix merges URL
  params first, then overlays JSON body fields so both are always available.

---

## 0.2.1 — 2026-05-07

- **`luamemo.crypto`**: new pure-Lua AES-256-CBC + HMAC-SHA256 module.
  Zero C dependencies — uses `bit` (LuaJIT/OpenResty), `bit32` (Lua 5.2),
  or a pure-Lua fallback with a precision-safe `lshift`. CSPRNG reads
  `/dev/urandom` with an xorshift64* fallback.
- **`luamemo.secrets` rewritten** to use `luamemo.crypto` exclusively.
  Removes the `resty.aes` / `lua-openssl` multi-backend detection block.
  ⚠ Secrets encrypted with the `lua-openssl` backend (v0.2.0) must be
  re-stored after upgrading — the on-disk format is the same
  (`iv_hex:ct_hex:mac_hex`) but the AES implementation differs.
- **Drop `lua-openssl` dependency** from rockspec. Pure-Lua crypto makes
  the C extension unnecessary.

---

## 0.2.0 — 2026-05-06

- `luamemo/util.lua`: extracted `clip()` and `parse_scores()` helpers shared
  across `store.lua` and `rerank.lua`.
- `luamemo/db.lua`: portable PostgreSQL adapter — delegates to `lapis.db`
  inside OpenResty; creates a direct `pgmoon` connection outside (plain Lua,
  CLI, eval harnesses). Config keys: `pg_host`, `pg_port`, `pg_database`,
  `pg_user`, `pg_password`; falls back to standard `PG*` env vars.
- `luamemo/http.lua`: portable HTTP client — uses `resty.http` inside
  OpenResty workers; falls back to `ssl.https` / `socket.http` outside.
- Security hardening: constant-time token comparison in `routes.lua`;
  HMAC-SHA256 authentication tag on all encrypted secrets; CSRF double-submit
  cookie in `web.lua`; input length caps on all HTTP endpoints.

---

## 0.1.3 — 2026-05-05

### ⚠ Breaking changes (upgrade from 0.1.2)

- **Secrets ciphertext format changed.** `secrets.lua` now stores secrets as
  `iv_hex:ct_hex:mac_hex` (16-byte IV + HMAC-SHA256 authentication tag).
  The v0.1.2 format was `salt_hex:ct_hex` (8-byte salt, no MAC).
  **Existing secrets stored with v0.1.2 cannot be decrypted by v0.1.3.**
  Before upgrading: record the plaintext values of any stored secrets,
  delete them from the `lm_secrets` table, upgrade the library, then
  re-store them with the new version. The v0.1.3 format adds integrity
  verification (HMAC) that the v0.1.2 format lacked.

- **Portability refactor** — the library no longer requires OpenResty at runtime:
  - `luamemo/http.lua`: new portable HTTP client abstraction. Uses
    `resty.http` (non-blocking cosockets) when running inside an OpenResty
    worker; falls back to `ssl.https` / `socket.http` (luasec / luasocket)
    in plain-Lua environments such as CLI tools, test harnesses, and non-web
    Lua apps. `resty.http` cannot be used outside OpenResty (no cosocket API),
    and `socket.http` cannot be used inside OpenResty (blocking I/O stalls the
    worker). Both paths are therefore required — they are not redundant.
  - All HTTP adapters (`embed.lua`, every reranker, every summarizer) and
    `secrets.lua` now use `luamemo.http` instead of `resty.http` directly.
  - `luamemo/secrets.lua`: all `resty.aes` / `resty.random` /
    `resty.string` replaced with `lua-openssl` (`openssl.cipher`,
    `openssl.rand`, `openssl.hmac`). Ciphertext format updated to
    `iv_hex:ct_hex:mac_hex` (16-byte IV; was 8-byte salt). Pure-Lua hex
    helpers; no OpenResty dependency at all.
  - `luamemo/db.lua`: new portable PostgreSQL abstraction. In
    OpenResty, delegates to `lapis.db` (nginx connection pool, type
    coercion). Outside OpenResty, creates a pgmoon connection from
    `pg_host`/`pg_port`/`pg_database`/`pg_user`/`pg_password` config
    keys or the standard `PGHOST`/`PGPORT`/`PGDATABASE`/`PGUSER`/
    `PGPASSWORD` env vars. All modules (`store`, `kg`, `summarizer`,
    `tune_weights`, `init`, `web`) now use `luamemo.db` instead of
    `lapis.db` directly. pgmoon already handles type coercion
    (int→number, bool→boolean, NULL→nil) identically to lapis.db, so
    no adapter layer is needed.
  - Rockspec: added `luamemo.db` module; added `pgmoon >= 1.13`
    dependency; updated summary to reflect Lua-first portability.

- **Secrets management** (`luamemo.secrets`): encrypted API-key storage
  with the `execute_with_secret` design principle. Secrets are AES-256-CBC
  encrypted at rest with a master key that is never persisted in the database.
  `execute_with_secret` substitutes `{secret}` server-side in HTTP request
  URLs, headers, and bodies — the raw value never crosses the LLM context
  boundary. There is no `get_secret` API.
  - Key resolution: `master_key_path` (file/Docker secret) →
    `master_key_env` (env var name) → `master_key` (explicit in config).
    No key = secrets disabled; all other features work normally.
  - Lua API: `M.secrets.store()`, `M.secrets.list()`,
    `M.secrets.delete()`, `M.secrets.execute_with_secret()`,
    `M.secrets.enabled()`. Re-exported as `memory.secrets.*`.
  - HTTP routes: `GET /secrets`, `POST /secrets`,
    `POST /secrets/:name/delete`, `POST /secrets/:name/execute`.
  - MCP tools: `secret_list`, `secret_store`, `secret_delete`,
    `secret_execute` — all bridging to the HTTP routes.
  - Migration `005_lm_secrets.sql` adds the `lm_secrets` table.
  - Documented in README "Secrets Management" section.

- **Web UI (read-only)**: new sub-app `luamemo.web` mountable via
  `memory.web.register(app, { prefix = "/memory/ui" })`. Pure-Lua HTML
  rendering (no etlua dependency on the host), inline CSS, paginated
  list (`GET /memory/ui`) and detail (`GET /memory/ui/:id`) pages.
  Reuses `cfg.auth_fn` and `cfg.before_request` for authorisation. Shows
  importance, decay-adjusted weight, and the JSON tags/metadata blobs.
  Search box + scope dropdown + kind filter on the list page: with `?q=`
  the page runs hybrid `store.search`; without it, scope/kind filter the
  paginated browse.
  Inline edit form (title, body, importance, decay_rate, tags JSON,
  metadata JSON) and a delete button on the detail page. Both POST routes
  protected by a double-submit-cookie CSRF token (`lm_csrf` cookie +
  hidden form field, constant-ish-time compare). Invalid tags/metadata
  JSON redirects with an inline flash error.
  Documented in `examples/web_ui.md` (mount + QA recipe).
- **Eval harness vs LongMemEval**: pure-Lua benchmark harness under
  `eval/`. `eval/datasets/longmemeval.lua` loads the published dataset
  and flattens chat sessions into per-question scoped memories. `eval/run.lua`
  ingests the haystack into a dedicated `luamemo_eval` table, runs
  hybrid search, and writes a `results.json`. `eval/score.lua` reports
  R@1 / R@5 / R@10 overall and per `question_type`. Dataset download via
  `scripts/download_eval.sh` (Apache-2.0). Decay weighting is bypassed in
  eval (`ignore_decay = true`); dedup is disabled so every haystack
  session lands as its own row. See `eval/README.md`.
- **Background summarizer**: pluggable summarizer adapters
  (`noop` / `ollama` / `openai`) compress old, low-weight memories into a
  single `kind="summary"` row whose `metadata.summarized_ids` records what
  it replaced. Triggered by an OpenResty `ngx.timer.every` on worker 0
  (configurable interval; 0 disables), the manual `POST
  /api/memory/summarize` endpoint, or the new `memo summarize` CLI
  command. Selection criterion: `weight < threshold` AND age > retention
  days. Replacement is transactional (BEGIN/COMMIT) so a failed summary
  cannot lose the originals. See `luamemo/summarizer.lua` and
  `luamemo/summarizers/`.
- **Dedup on write**: `store.write` now runs a top-1 vector pre-search in
  the same scope; near-duplicates (default cosine ≥ 0.95) are merged
  into the existing row instead of creating a new one. Configurable via
  `dedup_enabled`, `dedup_threshold`, `dedup_strategy` (`update` / `skip`
  / `append`). The HTTP `/write` response now includes `action`
  (`inserted` | `merged` | `skipped`); existing clients only consume
  `memory` so the change is backwards compatible. MCP `memory_write`
  exposes a per-call `dedup_strategy` override.
- **Importance + time decay**: every memory now carries `importance`
  (0..10, default 1.0) and `decay_rate` (0..1/day, default 0.0). Search
  ranks by `(hybrid_score × importance × exp(-decay_rate · days_since_updated))`.
  Migration `002_decay_importance.sql` adds the columns + CHECK constraints
  idempotently. Surfaced through the HTTP API, Lua API, and MCP tool
  schemas (`memory_write`, `memory_update`, `memory_search`'s new
  `ignore_decay` debug flag). See `examples/decay_importance.md`.
- **MCP server**: pure-Lua stdio Model Context Protocol bridge
  (`mcp/server.lua`) exposing 6 tools to Claude Desktop, Cursor,
  Continue.dev, Copilot Agent Mode. See `mcp/README.md`.

## 0.1 — Initial release

- pgvector-backed Lapis library
- Hybrid search (vector cosine + Postgres FTS)
- Embedder adapters: generic, Ollama, OpenAI
- HTTP API + programmatic API
- `memo` CLI
- Bundled Python embedder example (sentence-transformers)
