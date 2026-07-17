# Changelog

## [0.4.1] — hotfix (7 issues from 0.4.0-1 beta testing)

A focused patch fixing everything found during real-world upgrade testing of
0.4.0-1 (upgrading an existing project, switching to the in-process `gguf_ffi`
embedder). All seven issues confirmed and fixed with an isolated repro for each.

- **Fix: `memo calibrate` died silently (exit 1, no error) whenever stdin
  wasn't a terminal** — e.g. run from a script, CI, or an AI agent's shell
  tool. Root cause: several `read` prompts in the MCP-config and
  schema-apply phases had no TTY guard; under `set -e`, a `read` that hits
  EOF kills the script instantly with no message. All prompts now detect a
  non-interactive shell and skip with a visible note instead of dying.
- **Fix: the published rock omitted `gguf_shim.c` / `build.sh`**, so the
  in-process embedder could not be built from a stock `luarocks install` —
  the flagship 0.4.0 feature was unusable out of the box. Both files now
  ship via `copy_directories`; `build.sh` also no longer assumes its own
  directory is the Lua module path (it isn't, under LuaRocks' packaging
  layout) — it now asks the Lua interpreter's own module resolution where
  `ffi_shim.lua` actually lives and builds the shim there, verified
  end-to-end against a real local `luarocks install`.
- **Fix: `memo ping --embedder` never checked local embedders** (`hash`,
  `gguf_ffi`, …) — it only probed `MEMO_EMBEDDER_URL` and unconditionally
  reported `[SKIP]` otherwise, even when a local embedder was badly
  misconfigured (wrong model path, unbuilt native shim, wrong architecture).
  Now calls the embedder module's own `selftest()`.
- **Fix: `MEMO_EMBED_MAX_CHARS` was silently ignored by every CLI write /
  search call** — `cli/_common.lua`'s environment bootstrap never read it
  into `cfg.embed_max_chars`, so the truncation safety knob `memo calibrate`
  recommends and persists had no effect where it mattered (`memo doctor`
  reported it as `unset` even when configured).
- **Fix: `memo doctor` was the only subcommand that required `--setup PATH`**
  — it now bootstraps from the environment (`MEMO_DB_URL`/`MEMO_EMBEDDER`/
  `.luamemorc`) exactly like `write`/`search`/etc. already do; `--setup` is
  still available for a custom `setup()` call.
- **Fix: the MCP server reported a stale hardcoded version** (`"0.3.1"`,
  predating several releases) in both `initialize`'s `serverInfo.version`
  and the `memory_status` tool. Added `luamemo.VERSION` as the single source
  of truth; both now report it correctly (the `memory_status` field was
  actually always `"unknown"` before this, since the field it read never
  existed — a second bug the version-string report incidentally surfaced).
- **New: `memo reembed --scope SCOPE [--batch N] [--dry-run]`** — re-embeds
  every memory in a scope with the currently configured embedder.
  Switching embedders (including `memo calibrate` re-picking a different
  "best fit" on a new host) leaves existing rows with a different, never-
  comparable vector space **even at the same `embed_dim`**, silently
  degrading vector-search relevance with no error (FTS still partially
  covers for it, which is exactly why this is easy to miss). Verified
  end-to-end: a query's top-hit `vec_score` went from ~0.10 (noise floor)
  to 0.79 (correctly ranked) after `reembed`.
- **New: `memo calibrate` now warns when the embedder is about to change**
  and the target scope already has existing memories — both when switching
  away from a locally-known prior embedder, and (softer wording) when a
  fresh `.luamemorc` connects to a database that already has rows from
  elsewhere. Points at `memo reembed`.

### Also fixed while verifying the above
- `eval/tests/test_index_parse.lua`: the store.lua spot-check matched any
  file ending in `store.lua`, which also caught the new (0.4.0)
  `luamemo/learner_store.lua` — a false-negative regression risk, not a
  product bug. Matched on the exact path instead.

## [0.4.0] — unreleased

Major unreleased release covering two arcs: the codebase index / agent-delivery
layer + hybrid-search rewrite (below), and the learned-from-usage / in-process
embedder / self-maintenance work described here.

### Learned-from-usage, in-process embedder, self-maintenance

A large arc that makes retrieval **learn from real usage** (opt-in, with
zero-regression guardrails), adds an **in-process semantic embedder**, and lets
memory **maintain itself** without an external trigger.

- **In-process semantic embedder (`gguf_ffi`).** Runs EmbeddingGemma directly via
  a tiny LuaJIT-FFI shim over llama.cpp (`luamemo/embedders/native/gguf_shim.c`) —
  bge-m3-class recall on CPU, no HTTP sidecar. `memo calibrate` recommends it when
  the host can build it (LuaJIT + C toolchain), persists `MEMO_EMBEDDER=gguf_ffi`,
  and launches `luajit`; `--no-gguf` opts out. Optional GPU offload via
  `MEMO_GGUF_NGL` / `MEMO_GEN_NGL` (activates when llama.cpp is built with CUDA).
  The `openai` adapter is reframed as `openai_compatible` (serves OpenAI or any
  self-hosted vLLM / LM Studio / TEI endpoint); `openai` kept as an alias.
- **Learned-from-usage retrieval.** Opt-in `feedback_enabled`: retrieval events and
  reinforcements (`lm_reinforcements`) become training triples for a pure-Lua
  **learned reranker** and **projection** (`luamemo.rerank_train` /
  `projection_train`). Corrections/outcomes label the data — raw frequency never
  does. Frozen base models; only small learned layers adapt.
- **Retrieval-miss sensor** (migration 011, `miss` event type). A "miss" = retrieval
  failed to surface a needed memory (the opposite of a content mistake): detected
  automatically from near-duplicate writes and from corrections whose target was
  never retrieved. A miss bumps the memory's importance (more findable next time)
  and trains the ranker — it never diminishes the memory.
- **Per-scope promotion harness** (migration 013; `luamemo.promote` +
  `learner_store`). `memo learn <scope>` harvests feedback → trains → evaluates on a
  **held-out gate** → promotes the new weights only if they beat the incumbent, else
  rejects; weights are versioned per-scope in the DB with rollback + an audit log
  (`lm_promotion_runs`). The reranker loads a scope's own promoted weights at search
  time.
- **Signal capture.** `memory_sense` MCP tool + `memo sense` CLI relay a session's
  turns (luamemo can't read chat) into reinforcements — explicit-pattern heuristics
  always, plus an optional in-process instruct model (`MEMO_GEN_MODEL`, gemma-3) for
  implicit signals (experimental, precision-first). Idempotent.
- **Self-maintaining digest** (migration 012, `lm_digest_state`). A debounced
  auto-digest piggybacks on writes (`auto_digest_enabled`, enabled by `memo
  calibrate`) so tier promotion / consolidation / decay run without an agent or
  scheduler calling `memo digest`. Race-safe (atomic per-scope claim).
- **Hierarchical multi-scope search.** `store.search{ scopes = {…} }` (and MCP
  `memory_search.scopes`) searches a set of scopes as one union; higher-tier
  memories (e.g. org directives) surface first via the existing weight.
  `store.resolve_scopes{org,repo,user,global}` composes the effective set.
- **Fix:** `memo`'s interpreter selection now prefers LuaJIT when
  `MEMO_EMBEDDER=gguf_ffi`, so every embedder-backed CLI command works under the
  in-process embedder (previously failed under PUC lua5.1's missing FFI).
- Env bridge for the opt-in switches (`MEMO_FEEDBACK_ENABLED`, `MEMO_AUTO_DIGEST`,
  `MEMO_AUTO_DIGEST_INTERVAL`, `MEMO_MISS_THRESHOLD`), shared by the api/CLI and MCP.

### Codebase index, agent delivery & hybrid-search rewrite

A whole-repository **codebase index** plus an **agent-delivery layer** (MCP tools
+ auto-injected session digest), and a **hybrid-search rewrite** that improves
lexical recall for all searches.

- **Codebase index (`luamemo.index` / `memo index`).** Indexes a repository into
  queryable memory rows under `codeindex:<project>` scopes:
  - `kind="file"` (one per tracked file), `kind="symbol"` (functions/classes/
    methods), `kind="dependency"` (import/require edges), `kind="diff"` (git-diff
    hunks). Symbols carry `path`, `line`, `symbol_type`, `exported`, `arity`, etc.
  - **Whole-repo by default** — every text file (any language, plus extensionless
    files) gets a `file` row; symbols are extracted where a parser exists.
  - **Multi-language symbols**: pure-Lua pattern parsers for Lua, Python and
    JavaScript/TypeScript, dispatched by extension. **universal-ctags** enrichment
    covers any other language when the `ctags` binary is present, with graceful
    fallback to file-only when it is absent.
  - **Incremental** `update` via per-file checksums (unchanged files skipped;
    deleted files removed). File-level delete-before-write makes ingest idempotent
    and crash-safe.
  - **Dependency graph** mirrored into the knowledge graph (`requires` /
    `required_by`), powering one-hop blast-radius traversal: `index.explore`.
  - **Diff ingestion**: `memo index diff --commit SHA | --file FILE | --stdin`
    parses unified diffs into searchable `diff` rows with symbol attribution.
  - CLI: `memo index ingest|update|search|explore|status|invalidate|diff` with
    `--extensions csv|*`, `--no-symbols`, `--embed-file-rows`, `--exclude`.

- **MCP server: 21 tools (was 17).** Four new codebase-map tools return compact,
  token-lean text (path:line — name (type) — doc), not full JSON:
  `index_search`, `index_outline` (list a file's symbols before editing),
  `index_explore` (callers/callees), `index_status`. The server now **self-locates
  its bundled modules from its own script path** — no `LUA_PATH` needed, and a
  stale system install can't shadow the bundled code.

- **Session digest (`memo brief`) + SessionStart hook.** A tiny, fail-soft,
  timeout-capped summary (memory count + latest titles + codebase-map size + tool
  hints) meant to be auto-injected at session start so an agent knows what
  persistent context exists without being asked. The plugin `hooks/hooks.json`
  emits it as `hookSpecificOutput.additionalContext` (verified injecting into a
  live Claude Code session).

- **Hybrid-search rewrite (affects all `store.search`).** The pgvector candidate
  pool is now the **union of the vector-nearest rows and the top FTS matches**
  (previously vector-nearest only, then re-ranked). Lexical/FTS-only hits are now
  found regardless of vector distance — including rows stored without an embedding.
  `COALESCE`-guards keep NULL-embedding rows from corrupting rank order.

- **Embed-cost control.** `store.write_many` accepts a per-row `no_embed` flag →
  the row is inserted with a `NULL` embedding (no embed call), surfaced via the
  FTS leg. The codebase index stores `file` rows FTS-only by default; their body
  is enriched with split path words + a `defines: <symbol names>` digest so
  path/multi-word lexical queries match. Opt back in with `--embed-file-rows`.

- **Store additions**: `store.search({ metadata_filter = {…} })` (JSONB WHERE
  predicates) and `store.delete_where({ scope, kind, metadata_filter })` (bulk
  delete without an embed call). Skill + agent docs updated with the codebase-map
  workflow.

- **Recall benchmarks — re-run, no regression.** Per the pre-commit checklist
  (`store.lua` changed), the LongMemEval / LoCoMo / ConvoMem hash/bruteforce
  benchmarks were re-run (`*_hash_v040.json`; version sections added to
  `eval/results/{longmemeval,locomo,convomem}.md`):

  | benchmark (hash, bruteforce) | R@1 | R@10 | MRR | vs v0.3.2 |
  |------------------------------|----:|-----:|----:|-----------|
  | LongMemEval (n=500) | 54.0% | 83.4% | 0.630 | identical |
  | LoCoMo              | 45.2% | 82.5% | 0.565 | identical |
  | ConvoMem            | 82.5% | 96.5% | 0.890 | R@1 −0.1pp (≈1 q of 2,478; noise) |

  The candidate-union rewrite is on the **pgvector** path; the brute-force path
  (which these runs use, for continuity with the historical baseline) is
  unchanged — so the table above is the regression guard.

- **pgvector path validated (new).** Two follow-up sweeps confirm the pgvector
  backend is sound and the hybrid rewrite is safe:

  1. *Hybrid-union A/B (hash, pgvector).* Union candidate pool vs the old
     vector-nearest-only pool: **≤0.1pp on all three benchmarks** (LME/LoCoMo/
     ConvoMem identical to within 1 question). On prose NL-QA the vector-nearest
     pool already contains the top-FTS rows, so the union is a no-op there; its
     value is the FTS-only / lexically-distant case (the code index, `no_embed`
     rows) which these prose sets don't exercise.

  2. *pgvector-vs-bruteforce at real embedders* (bge-m3 1024-dim via TEI, and
     ollama `nomic-embed-text` 768-dim), each backend pair sharing identical
     embedder config so only storage/search differs:

     | benchmark | embedder | pgvector R@1 / MRR | bruteforce R@1 / MRR | Δ R@1 |
     |-----------|----------|-------------------:|---------------------:|------:|
     | LoCoMo    | bge-m3   | 58.3% / 0.698 | 58.4% / 0.698 | −0.1pp |
     | LoCoMo    | nomic    | 52.9% / 0.639 | 52.8% / 0.638 | +0.1pp |
     | ConvoMem  | bge-m3   | 91.7% / 0.940 | 92.1% / 0.942 | −0.4pp |
     | ConvoMem  | nomic    | 90.2% / 0.931 | 90.2% / 0.931 | −0.0pp |
     | LME       | bge-m3   | 100% / 1.000  | 100% / 1.000  |  0.0pp |
     | LME       | nomic    | 99.8% / 0.998 | 99.8% / 0.998 |  0.0pp |

     **HNSW approximate search matches exact cosine to ≤0.4pp R@1 / 0.002 MRR**
     across 768- and 1024-dim — the pgvector backend costs essentially no recall.
     Full results in `eval/results/{longmemeval,locomo,convomem}.md`.

  - *Eval-infra fix (`eval/sidecars/docker-compose.yml`).* The TEI bge-m3 sidecar
    hung the full request timeout (no error) on any single input exceeding
    `MAX_BATCH_TOKENS`; ~30% of LME oracle sessions exceed the old 4096 default.
    Raised to 7168 (the 6 GB RTX 2060 VRAM ceiling; 8192 OOMs), added
    `AUTO_TRUNCATE` (hang → fast 424), and capped eval bodies via
    `EMBED_MAX_CHARS` (24000 bge-m3 / 8000 nomic). bge-m3's longest ~2% of
    sessions are tail-truncated as a result.

## [0.3.6] — 2026-06-05

- **VS Code Agent Plugin (Preview).** The luamemo repo is now a valid VS Code
  agent plugin installable via **Chat: Install Plugin From Source →
  `https://github.com/kaio326/luamemo`**. Ships five files (no Lua changes,
  not part of the LuaRocks package):
  - `plugin.json` — Copilot-format manifest (skills + agents)
  - `.claude-plugin/plugin.json` — Claude-format manifest (adds MCP server)
  - `skills/session-memory/SKILL.md` — on-demand skill: load context on open,
    write decisions during work, summarise on close
  - `agents/luamemo.agent.md` — memory-focused agent with on-activation
    diagnostic flow (calls `memory_status`, auto-retries via `memory_reconnect`,
    prints exact OS-specific fix commands for all four error states)
  - `.mcp.json` — MCP server definition; uses `envFile: ${env:HOME}/.luamemorc`
    so users who ran `memo calibrate` get DB connectivity automatically

- **`memo calibrate` now installs the VS Code plugin automatically.**
  A new `_calibrate_plugin_phase` step clones the repo into the VS Code
  agentPlugins directory (`~/.config/Code/agentPlugins/github.com/kaio326/luamemo`
  on Linux; `~/Library/Application Support/Code/agentPlugins/...` on macOS).
  On subsequent runs it runs `git pull --ff-only` to keep the plugin current.
  Skips silently if `git` is not on PATH or VS Code is not installed.
  Pass `--no-plugin` to opt out.

- **`memo calibrate --help` / `-h` flag.** Prints a concise reference of all
  supported flags and exits 0. Previously there was no discoverable flag
  reference without reading the source or README.

## 0.3.6 — 2026-05-31

- **Bug fix — `memo ping --embedder` crashed when `MEMO_EMBED_DIM` was not set.**
  `ping.lua`'s `check_embedder()` called `embed.configure()` without `embed_dim`.
  Inside `embed.lua`, the dimension-mismatch guard ran unconditionally: when
  `cfg.embed_dim` is nil, `#vec ~= nil` evaluates to `true` and the branch falls
  through to `string.format("%d", nil)`, raising a hard Lua error.  The embedding
  itself had already succeeded.  Fix: guard the check with
  `cfg.embed_dim and cfg.embed_dim > 0` so it only fires when a dimension
  expectation was actually configured.  Applied to both `M.embed()` and the async
  variant `M.embed_async()` in `luamemo/embed.lua`.

- **`memo ping --embedder` now reads the full embedder config from env.**
  `ping.lua` previously read only `MEMO_EMBEDDER_URL` and `MEMO_EMBEDDER_ADAPTER`,
  ignoring `MEMO_EMBED_DIM`, `MEMO_EMBEDDER_MODEL`, and `MEMO_EMBED_MAX_CHARS`.
  This made `memo ping` an unreliable proxy for whether `write`/`calibrate` would
  work.  `check_embedder()` now reads all five env vars and passes them to
  `embed.configure()`, matching the config surface used by the rest of the CLI.

- **HTTP errors now include the target URL and raw socket error.**
  `http.lua`'s `try_socket()` returned generic strings such as
  `"http: request failed (network error)"` with no indication of which URL was
  attempted or what the underlying socket error was.  All three error paths in
  `try_socket()` now append `" — <url>"` and, where available, the socket-level
  error string (e.g. `"connection refused"`, `"timeout"`).

- **`memo calibrate --keep-embedder` flag added.**
  Passing `--keep-embedder` skips the probe-and-persist step so that an existing
  working embedder config in `.luamemorc` is preserved.  Useful when re-running
  calibrate to ingest new commits on a machine where the GPU probe would recommend
  a TEI endpoint that is not running.

## 0.3.5 — 2026-05-28

- **`memo setup` subcommand.** Creates a `SETUP_CHECK` file in the project root
  with agent-readable step-by-step first-run verification instructions.  Running
  `memo calibrate` on a fully-configured project deletes `SETUP_CHECK`
  automatically.  `--root DIR` sets the target directory; `--force` overwrites an
  existing file.

- **`memo calibrate` now persists auto-derived `MEMO_DB_URL` to `.luamemorc`.**
  All four auto-derive paths (`DATABASE_URL`, `POSTGRES_*`, `PG*`, and
  docker-compose auto-detect) previously set `MEMO_DB_URL` only in the current
  shell.  After a restart the derive ran again and sometimes selected the wrong
  database.  All paths now call `_save_rc_key` immediately after deriving the URL,
  consistent with the existing manual-prompt path.

- **`memo calibrate` now persists probe-recommended embedder config to `.luamemorc`.**
  The host probe writes a Lua config snippet listing the recommended
  `embedder_adapter`, `embedder_url`, `embedder_model`, `embed_dim`, and
  `embed_max_chars`.  All five are now extracted and written to `.luamemorc`
  using **write-if-absent** semantics: written on the first run from the system
  recommendation, preserved unchanged on all subsequent runs.  This prevents
  calibrate from clobbering a working host-side `MEMO_EMBEDDER_URL` with a
  Docker-internal hostname, and from resetting `MEMO_EMBED_DIM` to 384 when the
  probe cannot reach the embedder on re-runs.

- **TEI CPU sidecar healthcheck now uses `curl` instead of `wget`.**
  `eval/sidecars/docker-compose.yml` used `wget -qO-` in both service
  healthchecks.  `wget` is not present in the TEI CPU image (`cpu-1.7`), causing
  the healthcheck to always fail.  Changed to `curl -fsS` (already used by the
  reranker stub in `tei.md`).  Also corrected the remaining `wget` reference
  inside `eval/sidecars/tei.md`'s standalone compose snippet.

- **VRAM pre-check note added to `eval/sidecars/tei.md`.**
  Added a `nvidia-smi` command before the "Pull and start" block in the bge-m3
  embed sidecar section so users know to verify free VRAM (~3 GB) before pulling
  the GPU image.

## 0.3.4 — 2026-05-26

- **Bug fix — `memo calibrate` ingest wrote 0 memories.**
  `luamemo.cli.api.dispatch()` called `read_json_stdin()` (which drains all of
  stdin via `io.read("*a")`) before invoking the `write-many` handler.  Because
  `write-many` streams NDJSON row-by-row via `io.lines()`, stdin was already
  exhausted and `json.decode()` threw "Expected the end but found T_OBJ_BEGIN"
  on the multi-object stream.  Fix: `dispatch()` skips `read_json_stdin()` and
  passes `{}` directly when the command is `write-many`.

- **Bug fix — MCP tools `memory_status` and `memory_reconnect` rejected by client.**
  Both tool `inputSchema` blocks contained `required = {}`.  Lua's empty table
  serialises as a JSON object `{}`, but JSON Schema requires the `required` field
  to be an array.  VS Code Copilot (and other strict MCP clients) rejected the
  schema with "Incorrect type. Expected 'array' at /required" and omitted both
  tools.  Fix: removed the empty `required` field from both schemas; absent
  `required` is equivalent to `required: []` per JSON Schema spec.

## 0.3.3 — 2026-05-25

- **Eval test suite — consolidated smoke tests into 7 grouped files.**
  All 21 individual `eval/tests/smoke_*.lua` files and `eval/tests/test_bug_fixes.lua`
  are merged into 7 domain-grouped test files under `eval/tests/`:
  - `test_pure.lua` — pure-Lua tests (bug fixes, recommend, paraphrase, cross-encoder)
  - `test_core.lua` — DB-backed core tests (bruteforce, write_many, tiers, promote, decay/dedup/summary)
  - `test_features.lua` — feature tests (KG, patterns, query boosts, temporal, embed probe)
  - `test_pipeline.lua` — pipeline tests (consolidate, digest, MCP tools)
  - `test_convomem.lua` — ConvoMem dataset loader + end-to-end runner smoke
  - `test_locomo.lua` — LoCoMo dataset loader + end-to-end runner smoke
  - `test_membench.lua` — MemBench dataset loader + integration mini-run
- **Eval helpers — two shared modules replace three ad-hoc scripts.**
  `eval/helpers.lua` replaces `eval/_resty_http_shim.lua` (resty.http shim for
  plain `lua5.1`) and `eval/_make_synthetic.lua` (LongMemEval synthetic-set
  generator). `eval/utils.lua` replaces `eval/paraphrase.lua` as the
  deterministic paraphrase generator; both are `require`-able from any eval harness.
  All runner files (`convomem_run.lua`, `locomo_run.lua`, `longmemeval_run.lua`,
  `membench_run.lua`, `recall_bench.lua`) updated to use the new names.

- **Bug fixes (carried from v0.3.2 working tree).**
  - `pg_array()` — backslash / double-quote / single-quote escaping to prevent
    SQL injection through user-supplied tag values.
  - SSRF dot-pattern fix in `luamemo.secrets` — `^172%.3[0-1].` corrected to
    `^172%.3[0-1]%.` so `172.30X0.0` is no longer wrongly blocked.
  - `_ts_to_epoch()` UTC offset — `os.time({UTC table}) - _tz_offset` had the
    wrong sign and doubled the error on non-UTC machines (off by 2×tz_offset).
    Corrected to `+ _tz_offset`; verified on a UTC-5 host that the result equals
    the known epoch for 2024-01-01 00:00:00 UTC (1704067200). Test updated with
    a hard correctness assertion.
  - `_probe_backend()` column-type check — queries `pg_attribute` for the actual
    `typname` instead of relying on a hard-coded string comparison.
  - `http.lua request_async` — URL parser now handles IPv6 bracket notation
    (`http://[::1]:8080/path`); previously all IPv6 embedder URLs failed to parse.
  - `cli/api.lua` + `mcp/server.lua` — `MEMO_EMBEDDER_ADAPTER` and `MEMO_EMBEDDER`
    env vars now fall back to defaults when set to an explicit empty string
    (Lua `""` is truthy, so bare `or "default"` accepted `""`).
  - `eval/helpers.lua` — `mkdir -p` now single-quote-escapes the output path
    to prevent shell injection from command-line argument.


## 0.3.2 — 2026-05-15

- **`luamemo.patterns` — new module: preference extraction + query-time boosts.**
  Scans each `store.write()` body for first-person preference/habit/sentiment
  signals ("I prefer X", "I always Y", "I hate Z") and inserts synthetic companion
  memories at `importance = 0.4` in the same scope. At query time, scores are
  boosted by `person_name_boost` (default +0.15) for capitalised tokens from the
  query that appear in a memory body, and by `quoted_phrase_boost` (default +0.40)
  for single- or double-quoted phrase matches. Both extraction and each boost can
  be independently disabled. New config keys: `patterns_enabled` (default `true`),
  `patterns_max_body_chars` (default 5 000), `person_name_boost` (0.15),
  `person_name_boost_enabled` (true), `quoted_phrase_boost` (0.40),
  `quoted_phrase_boost_enabled` (true).

- **MCP server — 4 new tools (17 total).**
  - `memory_status`: returns a DB health snapshot — total row count, per-scope
    breakdown via a single window-function query, and optional config details
    (embedder, backend, `embed_dim`) when `verbose = true`.
  - `memory_reconnect`: resets the pgmoon connection and verifies it with a row
    count. Useful after external scripts modify `lm_memories` directly.
  - `memory_diary_write`: writes a personal diary entry for a named agent into
    an isolated `diary:<agent_name>` scope. `agent_name` is validated
    (letters/digits/hyphens/underscores/dots only, max 64 chars; enforced in both
    diary tools to prevent scope injection).
  - `memory_diary_read`: reads the most recent N diary entries for an agent
    (default 10, max 50), newest first.

- **`luamemo.init` — `ensure_ready()` probe retry backoff.**
  When the embedder is unreachable at `setup()` time and `skip_embed_probe = true`
  is set, `store.write()` probes the embedder on each call. Without a backoff this
  hammered the embedder on every write when it was slow to start. A
  `_last_probe_ts` guard now limits retries to at most once per
  `ensure_ready_retry_secs` seconds (default 10). New config key:
  `ensure_ready_retry_secs` (default 10).

- **`store.lua` — LSH filter bypass (bug fix).**
  When a scope contained ≥ `lsh_rebuild_at` rows, the LSH SQL path emitted
  `WHERE id IN (...)` without appending the extra `kind`/`tier`/time filter
  clauses and without a `LIMIT` cap. Filters were silently dropped on large
  scopes. Both the filter clause and `LIMIT %d` are now correctly appended to
  the LSH path.

- **`store.lua` — pgvector CTE LIMIT now scales with `fetch_limit` (bug fix).**
  The inner pgvector CTE used a hardcoded `LIMIT 50` regardless of the caller's
  `limit` parameter. With high reranker candidate counts the CTE silently
  truncated the candidate set before reranking. The CTE now uses
  `LIMIT math.max(50, limit)` so the pool size tracks the request.

- **`store.lua` — `store.delete()` error string propagation (bug fix).**
  A single-variable capture pattern (`local res = db.delete(...); return res`)
  dropped the DB error string — callers received `nil, nil` on failure instead
  of `nil, "<error>"`. Fixed to return `db.delete(...)` directly.

- **`store.lua` — dead `_get_luamemo()` call outside guard (code quality).**
  `_get_luamemo()` was called unconditionally at the top of `M.write()` before
  the `if _has_ensure_ready then` guard, doing a module lookup on every write
  even when ensure_ready was not wired. Call moved inside the guard.

- **`mcp/server.lua` — hardcoded `lm_memories` table name (bug fix).**
  `memory_status`, `memory_reconnect`, and `memory_diary_read` all contained
  the literal string `"lm_memories"`. Each now calls `store_mod.table_name()`,
  respecting any custom table configuration.

- **`luamemo.http` — pre-load `ltn12` before `socket.http` (bug fix).**
  LuaSocket's lazy `_G` assignment for `ltn12` triggered OpenResty's
  `__newindex` guard when the module was loaded for the first time inside an
  OpenResty request context. Fixed by pre-loading `ltn12` via `pcall(require,
  "ltn12")` before `socket.http`.

- **`cli/memo` — `_MEMO_REQUIRED_COLS` as single source of truth.**
  The required-column list was duplicated across multiple `schema-check` paths.
  A single `_MEMO_REQUIRED_COLS` array and `_check_mem_columns()` helper now
  serve all paths. DB URL password is redacted in all credential error messages
  to prevent accidental exposure in logs.

- **`cli/calibrate` — GPU VRAM threshold note.**
  When a GPU is detected but free VRAM is below 2 048 MiB, the calibrate output
  now logs the exact VRAM figure and explains the CPU fallback instead of
  printing "No GPU".

- **`README.md` — `skip_embed_probe` and `store.write()` return convention.**
  Added a dedicated section for slow-starting embedder sidecars (`skip_embed_probe
  = true`) and a reference table documenting that `store.write()` never throws —
  failures always surface as `nil, err`.

## 0.3.1 — 2026-05-14

- **`luamemo.temporal` — word-boundary fix for month-name rules.**
  `rule("in (march)", ...)` previously fired inside any word containing
  `" in "` followed by a month abbreviation — e.g. `"classic gin martini?"`
  triggered `"in mar"` (March), and `"contain 2024"` triggered `"in 2024"`.
  All three `"in <month>"` rules (`january` standalone, the month-name loop,
  and the 4-digit year rule) now use the Lua frontier pattern `%f[%a]in%s+`
  to require that `"in"` starts at a word boundary. False-positive temporal
  windows no longer fire on non-temporal queries.
  Benchmark impact (LongMemEval n=500, hash embedder): +1.4pp R@10 vs v0.3.0
  on the skip-temporal ablation; final v0.3.1 result: **79.8% R@10** (vs
  75.0% in v0.3.0 with both regression causes present; vs 81.0% baseline).

- **`luamemo.http` — chunked transfer-encoding decode in `request_async`.**
  Ollama's `/api/embeddings` endpoint returns `Transfer-Encoding: chunked`
  with no `Content-Length`. The v0.3.0 `request_async` path read raw TCP bytes
  without decoding chunked framing, producing garbled JSON that failed to parse.
  The synchronous `socket.http` path (used in v0.2.x) handles chunked encoding
  transparently, which is why the bug was invisible until the async parallel
  embedding path was introduced. Fix: after reading the full response body,
  `request_async` now checks for a `Transfer-Encoding: chunked` header and
  decodes the chunked framing before returning. Impact: 100% of Ollama
  `write_many` calls silently failed in v0.3.0; all succeed in v0.3.1.

- **Benchmark runners — `skip_observations` defaults to `true`.**
  `consolidate.process()` (new in v0.3.0) runs during `store.search()` and
  merges synthesised observation rows into results via RRF. These rows lack
  `session_id` metadata, so they never match the gold in retrieval benchmarks —
  but they occupy rank slots, pushing actual session rows down. In ConvoMem's
  2–3-session scopes this degraded R@1 from ~85% to ~44%. All three benchmark
  runners (`longmemeval_run.lua`, `locomo_run.lua`, `convomem_run.lua`) now
  default to `skip_observations = true`. Pass `--with-observations` to opt in.

- **`store.search()` — slot-partitioned observation supplement (precision@1 fix).**
  The v0.3.0 observation search leg merged observation rows symmetrically with
  memory rows via RRF. Synthesised observations (distillations of multiple related
  sessions) scored higher than any single source session and landed at rank 1,
  collapsing R@1 by 13–45pp across all three eval corpora when `--summarizer-model`
  was passed. Root cause: RRF treats a rank-1 observation as equal to a rank-1
  memory, but observations are beliefs — they should never displace primary evidence.
  Fix: the observation merge is replaced with a **slot-append** — after all memory
  results are ranked (and reranked if enabled), up to `obs_max_slots` (default 3)
  observation rows are appended at the end of the result list. Observations
  supplement but never displace original evidence. New config key: `obs_max_slots`
  (default 3). Regression smoke: R@1 restored from 51.2% → 100% on 5-question
  LME sample with `llama3.1:8b` synthesis enabled.

- **`luamemo.http` — `socket.http` timeout now correctly honoured.**
  The `try_socket()` fallback path previously set the TCP timeout via a `create`
  callback (`sock:settimeout()`), which `socket.http` silently ignores — it only
  reads its own `TIMEOUT` module-level global. The fix sets and restores
  `socket.http.TIMEOUT` (in seconds) around each request, so per-call
  `opts.timeout_ms` is actually enforced. Without this fix, any embed call that
  exceeded the library default 10 s TCP-connect grace returned a generic
  network error instead of a timeout, making the request appear to fail
  immediately rather than waiting.

- **Default `embed_timeout_ms` raised from 5 000 ms to 30 000 ms.**
  The previous 5 s default was set for lightweight hash-embedder benchmarks and
  was far too low for any real HTTP embedder, especially CPU-hosted models.
  `luamemo.init` default, `luamemo.embed` fallback, and `luamemo.store` async
  deadline are all updated to 30 000 ms. Users running large models on CPU
  (e.g. bge-m3 via TEI without a GPU) should override via
  `setup({ embed_timeout_ms = 120000 })`.

## 0.3.0 — 2026-05-13

- **`luamemo.temporal` — natural-language temporal retrieval.**
  New module parses time expressions ("last month", "in June", "last spring",
  "recently", "yesterday", "last 30 days", etc.) directly from the query string
  and fires a temporal SQL leg alongside vector + FTS. All legs are fused via
  Reciprocal Rank Fusion (RRF). Zero new external dependencies.
  Migration: `luamemo/migrations/006_temporal_index.sql` (adds `created_at` index).

- **`luamemo.consolidate` — evidence-tracked observations.**
  New module clusters unprocessed memories by cosine similarity and either
  reinforces an existing observation (cheap UPDATE) or synthesises a new one via
  the configured summarizer. Observations surface as first-class results in
  `store.search()` with `type = "observation"`. Proof count, freshness trend, and
  evidence IDs are tracked per observation.
  Migration: `luamemo/migrations/007_observations.sql` (adds `lm_observations` table
  and `consolidated_at` column on `lm_memories`).

- **Memory tiers (0–3) — structural importance hierarchy.**
  New `tier SMALLINT` column on `lm_memories`. Tier is derived automatically from
  `importance` on write, or overridden explicitly. `store.search()` accepts
  `tier_min` / `tier_max` filters. MCP `memory_search` defaults to `tier_min = 1`,
  hiding ephemeral noise from AI agents by default (pass `tier_min = 0` to override).
  Migration: `luamemo/migrations/008_tiers.sql` (adds column, backfills, adds index).

- **`luamemo.digest` — hippocampus idle-triggered digest.**
  New module: idle-triggered pipeline that clusters tier-0 ephemeral memories,
  reinforces observations, escalates importance on repeated corrections, and promotes
  tiers. `record_event("reversal", ...)` immediately diminishes the target memory's
  importance and demotes its tier. `digest.run()` supports `dry_run` mode.
  Migration: `luamemo/migrations/009_reinforcements.sql` (adds `lm_reinforcements`
  table with FK→lm_memories).
  CLI: `memo digest [--scope SCOPE] [--dry-run] [--threshold F]`.
  MCP: new `memory_digest` tool.

- **Code quality — shared helpers in `util`.**
  `util.cosine`, `util.cluster`, `util.importance_to_tier`, and `util.table_exists`
  replace three independent copies of each in `store`, `consolidate`, and `digest`.
  `util.table_exists` caches results process-wide, eliminating repeated
  `information_schema.tables` queries.

- **Security — `record_event` delta clamped to `[-1.0, 1.0]`.**
  Previously an unclamped `tonumber(delta)` on a very large string (e.g. `"1e308"`)
  would produce `Infinity` in the `REAL` column. Delta is now clamped before insert.

- **Reversal handling fully wired.**
  `record_event(..., "reversal", delta, ...)` now immediately applies importance
  diminishment to the target memory and demotes its tier in the same call, in
  addition to recording the event.

## 0.2.9 — 2026-05-11

- **`memo ping` — standalone connectivity check.**
  New subcommand that tests DB connection, table existence, and embedder
  reachability independently, without requiring `luamemo.setup()`. Exits 0
  if all checks pass, 1 if any fail. Suitable for CI healthchecks.
  Flags: `--db`, `--table`, `--embedder`.

- **`memo calibrate --docker-compose FILE` — read Postgres credentials from Compose file.**
  New flag that parses a `docker-compose.yml` file to extract Postgres
  credentials (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, host port)
  and sets `MEMO_DB_URL` automatically, eliminating manual credential copying.

- **`memo calibrate` — block MCP config write when server path unresolvable.**
  Previously `calibrate` warned about a missing `mcp/server.lua` path but
  still wrote the broken config. Now it prompts interactively for the correct
  path, or skips the write entirely in non-interactive mode.

## 0.2.8 — 2026-05-11

- **`memo doctor` crash fix.**
  `memo doctor` crashed with `bad argument #2 to 'format' (string expected, got nil)`
  when `setup()` had not been called, because the setup-guard checked
  `lm.config.db_table` (which always has a non-nil default). The guard now
  checks `lm.store.backend()`, which returns `nil` until `store.configure()`
  completes inside `setup()`. Added `or '?'` on the backend format call as
  defence-in-depth.

- **Better error when `embedder_adapter` set without `embedder_url`.**
  Previously `setup()` emitted a generic `"either embedder_local or embedder_url
  is required"` error even when `embedder_adapter` was set (which looks like a
  complete config). The error now names the adapter and explains that
  `embedder_adapter` selects the HTTP request format while `embedder_url` is
  still required.

- **`memo calibrate` — robust MCP server path resolution.**
  The generated MCP config contained a broken server path
  (`/usr/local/bin/../mcp/server.lua`) when luamemo was installed via LuaRocks
  (the `memo` binary lands in `bin/` far from `mcp/`). Path resolution now
  tries four strategies in order: (1) relative to the script (dev/git-clone
  mode), (2) `luarocks show luamemo` install prefix, (3) `find` in common
  LuaRocks tree roots, (4) the original relative path with a visible warning.

- **`memo calibrate` — warn on empty `MEMO_DB_URL`.**
  If `MEMO_DB_URL` is unset when `calibrate` runs, the generated MCP config
  gets an empty connection string and the MCP server silently fails to connect.
  `calibrate` now warns loudly before writing the config and instructs the
  operator to set the variable or fix the field manually.

- **`memo calibrate` — Docker/containerized deployment note.**
  After writing the MCP config, `calibrate` now prints a reminder that
  `MEMO_DB_URL=postgresql://...@127.0.0.1:...` is wrong inside Docker — the
  MCP client runs on the host, not in the container, and should use the
  Compose service name (e.g. `@db:5432`).

- **README — Docker / containerized setup section (§3c).**
  New section documents `pg_host` and `MEMO_DB_URL` for Docker deployments,
  including a worked example reading credentials from the Lapis config object.
  Also documents the WSL2 GPU flags required to avoid OOM crashes with TEI
  (`--dtype float16`, `--max-batch-tokens 2048`, `CUDA_DEVICE_ORDER`).



- **`lua-cjson` is now an optional dependency.**
  `luamemo.json` (new module) is a portable JSON shim: it tries `cjson.safe`
  first (always present in OpenResty / LuaJIT environments, zero overhead),
  then falls back to the bundled `luamemo.vendor.dkjson` (dkjson 2.5,
  pure Lua, MIT). This means `luarocks install luamemo` now succeeds on
  minimal Alpine images and CI runners that lack a C compiler. All library
  modules now `require("luamemo.json")` instead of `require("cjson.safe")`.

- **Bundled `luamemo/vendor/dkjson.lua`.**
  Verbatim copy of dkjson 2.5 (David Kolf, MIT). Used only when `cjson.safe`
  is not available. No modifications — SHA-256:
  `9d3e5c82dcd572a6a4b764d705f72b948094124b0e338cec0d6dfefea59693b7`.

- **`luamemo/json.lua` shim.**
  `pcall(require, "cjson.safe")` + type-table guard to detect a live module
  (Lua 5.1's `require` returns `true` for nil-returning loaders, so a simple
  truthy check is insufficient). `decode()` wraps dkjson's three-return-value
  signature into the `nil, err` contract used throughout the library.

## 0.2.6 — 2026-05-09

- **`memo calibrate` auto-bootstrap — Phase 2.5 (schema check + apply).**
  `calibrate` now calls the new `schema-check` API command (which queries
  `information_schema.columns`) to verify that both `lm_memories` and
  `lm_kg_facts` are present with all expected columns. If incomplete, it
  shows what is missing, checks for `psql`, prompts `Apply schema now? [y/N]`,
  and runs `cmd_migrate | psql` automatically. New flag: `--no-migrate` skips
  this phase.

- **`memo calibrate` IDE/MCP detection — Phase 5.**
  After codebase ingest, `calibrate` now detects `.vscode/`, `~/.cursor/`,
  and the Claude Desktop config path (platform-aware). For each detected IDE
  it offers to write or update the MCP config file with a pre-built
  `luamemo` server entry (direct DB mode via `MEMO_DB_URL`). New helper:
  `_calibrate_mcp_phase()`. New flag: `--no-mcp` skips this phase.

- **`luamemo.cli.api` — `schema-check` command.**
  New handler queries `information_schema.columns` for `lm_memories` and
  `lm_kg_facts`, returns `{ ok, tables: { <tbl>: { present, missing_cols } } }`.
  Used internally by `calibrate` Phase 2.5.

- **MCP server — proactive secrets security guidance.**
  `secret_store` tool description now includes an explicit WARNING against
  asking users to paste credentials in chat, and instructs the agent to
  recommend the `memo secret-store NAME` terminal workflow instead.
  `secret_list` description similarly guides agents to suggest the terminal
  workflow when a user needs to store a new key.
  `session_start` prompt text now includes a "Security guidance — secrets"
  section so agents carry this behaviour from the very start of every session:
  never ask for credentials in chat; always redirect to the terminal command;
  proactively raise the topic when API keys or tokens are discussed.

- **Documentation — transport modes and access paths.**
  `mcp/README.md`: opening two-mode decision table (Direct DB vs HTTP API),
  "most users want direct DB" recommendation, split env-var table, new
  Transport modes section.
  `README.md`: access-path decision table before the setup steps; callout
  for Copilot/Cursor/Claude Desktop users; `--no-migrate`/`--no-mcp` flags
  documented; `memo secret-store` example corrected to use
  `MEMO_DB_URL`/`MEMO_MASTER_KEY`/`MEMO_SECRETS_FILE` (was showing HTTP
  transport vars by mistake).

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
