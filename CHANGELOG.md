# Changelog

## [0.5.1] — unreleased

### macOS

- **luamemo finds Homebrew's libraries itself:** on Apple silicon Homebrew installs
  outside the system's library search path, so after `brew install libsodium` luamemo
  said libsodium was not found unless `MEMO_LIB_SODIUM` named it. It now also looks in
  `/opt/homebrew/lib`, `/usr/local/lib` and `/opt/local/lib` (MacPorts).
- **Install with Homebrew's LuaRocks:** it is for Lua 5.4 — `luarocks --lua-version 5.1
  --lua-dir "$(brew --prefix luajit)" install luamemo` (README).
- `memo` read a `.luamemorc` value with an escaped quote (`MEMO_X='it'\''s'`) as `it\'s`
  under bash 3.2, macOS's own.
- `memo calibrate` found no file types in a project on macOS (its scan used a GNU sed
  pattern), and `memo calibrate --role org` stopped after the status, before the
  "Next:" steps: the LAN address lookup (`hostname -I`) is Linux-only, and its failure
  ended memo. macOS asks `ipconfig`; no lookup can end memo — nor, on Linux, a logged-out
  `tailscale`.

### Development

- The test suite runs on macOS: the runner and the tests use GNU or BSD tools
  (`timeout` / `gtimeout`, `stat -c` / `-f`, `script -qec` / `-q`) through
  `eval/tests/_harness.lua`; the macOS CI job passes. A failed CI run uploads its
  per-file test logs.

## [0.5.0] — 2026-10-18

luamemo is now an MCP server with a local database: private memory for AI
agents, set up and governed with the `memo` CLI. No database server, no
password, no Docker.

### ⚠ New foundation: SQLite through LuaJIT, libsodium (set each project up again)

- **No database server.** Each project's memory is one SQLite file in
  `~/.local/share/luamemo` (`$XDG_DATA_HOME/luamemo`; directory 0700, files 0600),
  reached through LuaJIT's FFI; several processes (the MCP server, `memo`, the
  hooks) use it at once (WAL). `MEMO_DB` names it — a name in the data directory or
  a path; `memo calibrate` gives each project its own (`<dir>-<checksum>`, `--db`
  to choose). Nothing secret is left in `.luamemorc` or an MCP client config.
- **LuaJIT is the only interpreter** (Lua 5.1 – 5.5 support is gone; Windows
  through WSL). Two system libraries: libsqlite3 ≥ 3.35 (FTS5, JSON) and
  libsodium ≥ 1.0.18 — found by their versioned names, or where
  `MEMO_LIB_SQLITE3` / `MEMO_LIB_SODIUM` point; a missing one is named with the
  package to install. `memo ping` shows which copies it loaded.
- **Search is exact at every size**: every vector in scope is scored (float32
  BLOBs), and the candidates are the vector top-N plus the full-text top-N.
  Full text is FTS5 ranked with Postgres' cover-density `ts_rank_cd`,
  reimplemented as an FTS5 function (BM25 measured 0.7 points worse). Recall is
  unchanged: on the same vectors, every benchmark within +0.4 / −0.1 points of
  the Postgres store (README → Benchmarks). Search is faster: 1,000 memories
  3.9 ms (was 136), 5,000 18.3 ms (was 167), 100,000 233 ms.
- **One embedding space per database**: the first vector fixes the dimension; a
  vector of another size is refused, naming `memo reembed`. `memo reembed --all`
  re-embeds every scope (an org replica re-syncs) and the database moves to the
  new size when it's done.
- **An embedder that rejects an input as too long no longer loses the memory**:
  the text is halved and retried, the memory flagged `was_truncated` with its
  full text kept; one still refused is stored without a vector (found by its
  words) and the write says so. The in-process GGUF embedder fed llama.cpp an
  unfilled token buffer for an over-long input ("failed to initialize batch") —
  fixed in the shim, which also reports truncation.
- **The vault moved into the database** (`lm_secrets`): XChaCha20-Poly1305 with
  each value bound to its name, writes in a transaction (two processes storing at
  once lost a write before). Its key is `~/.config/luamemo/vault.key` — the first
  `memo secret-store` creates it — or `MEMO_MASTER_KEY_PATH` / `MEMO_MASTER_KEY_ENV`.
  `MEMO_SECRETS_FILE` is gone.
- **Crypto is libsodium** (the pure-Lua X25519 / Ed25519 / AES are gone).
  Identities carry over: existing device keys, fingerprints and pairings stay
  valid.
- **New:** `memo backup [PATH]` (a consistent copy while in use, 0600; says the
  vault key and keyring aren't in it), `memo export` / `memo import` (JSON Lines:
  memories and facts; vectors reused when the embedder matches, else embedded
  again; a second import of an export adds nothing; one memory per line from any
  tool), `memo calibrate --db`.
- **Removed:** PostgreSQL, pgvector, the brute-force and LSH backends and their
  settings, `memo migrate`, the schema files and migrations, `MEMO_DB_URL`, the
  `pgmoon` dependency, `memo doctor --setup`, calibrate's `--hosted`,
  `--no-migrate`, `--docker-compose`. luamemo warns about an old setting name and
  says what replaced it. `hooks/cursor/pre_compact.sh` is gone too: it targeted a
  hook interface Cursor doesn't offer and couldn't be tested — Cursor gets
  luamemo through MCP; a Cursor hook is a future goal.
- **No automatic migration from 0.4** (pre-1.0): run `memo calibrate` in each
  project; README → *Upgrading from 0.4* has a `psql` → `memo import` recipe for
  the old memories and facts.

### The Lua API is internal — every capability is on `memo` and MCP

`require("luamemo")` is no longer documented or promised to other programs; the
CLI, the MCP server, `memo serve` and the maintenance are built on it. Everything
it could do is reachable from `memo` **and** an MCP tool (a parity test keeps it
so); people change settings, agents only read them. The operations both offer —
search, recent, update, embed, maintenance, learning — read their arguments in one
place (`luamemo/ops.lua`), as text from `memo`'s flags or typed values from MCP, so
the two surfaces can't drift apart.

- **Settings:** one registry of every setting (87) — `MEMO_<NAME>` in the
  project's `.luamemorc`, `~/.luamemorc` (now read by `memo` too) or the
  environment. `memo config list | get | set | unset | check | trust` checks a
  value before writing it; `memo config list --markdown` generates
  [SETTINGS.md](SETTINGS.md) (a test keeps the two equal). The MCP server reads the
  `.luamemorc` files itself (the client's environment wins); `memory_status
  {details}` lists every setting and where it came from. A mistyped embedder,
  dimension, role or org-share value stops luamemo instead of falling back; an
  unknown `MEMO_` name is named with the closest setting. 39 options that only the
  Lua API reached are settings now — authenticated embedders, the cross-encoder
  reranker, the LLM summarizer, dedup, search boosts, defaults.
- **Settings files are data; a project's must be memo's own or trusted.** `memo`
  used to `source` the project's `.luamemorc` as shell, so a cloned repository could
  run code on any `memo` call (the session-start hook's included); and the MCP server
  reading project files would have let a committed one redirect the embedder.
  Values are now parsed, never run, and a project's `.luamemorc` memo didn't write —
  committed to git, or in a downloaded folder (a zip, a tarball), or edited by hand —
  is ignored until `memo config trust` (checksum per machine; a changed file needs
  trusting again; memo's own writes keep it trusted). A downloaded project's file
  could otherwise point the embedder at its own server, with the vault's keys in the
  headers (`{secret:NAME}`). An ignored file is named in `memory_brief` and
  `memory_status`, so the agent tells the user — its memories would otherwise go,
  unsaid, into the user's own database.
- **A project's settings never name code to run.** `MEMO_LUA` (the interpreter memo
  runs), `MEMO_LIB_SQLITE3`, `MEMO_LIB_SODIUM` and `MEMO_GGUF_SHIM` (libraries
  luamemo loads) come only from the environment and `~/.luamemorc`: from a project's
  file, a downloaded folder's `MEMO_LUA='./tools/x.sh'` ran its own script on
  `memo brief` — that is, when the folder was opened with the plugin installed.
- **Credentials in headers come from the vault:** `{secret:NAME}` in
  `MEMO_EMBEDDER_HEADERS` / `MEMO_RERANK_HEADERS` / `MEMO_SUMMARIZER_HEADERS` is
  filled in when the request is made and masked in errors; `memo config set`
  refuses a plain-text credential, and calibrate prints the recipe when an
  embedder answers 401 / 403.
- **MCP: 27 tools** (was 22): `memory_summarize`, `memory_learn` (run / status /
  rollback), `memory_embed`, `memory_tune_weights`, `memory_brief`.
- **Facts come with every search.** `memory_search` and `memo search` return the
  knowledge-graph facts the query is about (current value, since when, the
  previous value) next to the memories — no separate fact tool. Measured on a
  project memory full of outdated notes: with facts recorded, Gemma 4 e4b went
  from 60 % to 94 % correct and llama3.1:8b from 44 % to 77 %; a separate fact
  tool changed little (small models rarely called it, and guessed the names
  wrong when they did). Agents still can't write facts (they recorded stale
  ones); people and their scripts do, with `memo kg`.
- **More per-call options on MCP:** `memory_delete` deletes by filter after a
  preview and a 5-minute confirmation token; `memory_write` takes `items` (up to
  100), `created_at` and `tier`; `memory_search` takes `metadata_filter`, `rerank`,
  `hybrid_weights`, `min_score` (now a real cut-off) and `tier_max`;
  `memory_recent` takes `kind` and `offset`.
- **CLI:** `memo kg assert | query | invalidate | timeline`, `memo embed`,
  `memo tune-weights` (the best search blend for a scope — `eval/tune_weights.lua`
  is gone, and it embedded with `hash` whatever the database used), `memo delete
  --scope … [--kind] [--meta] [--yes]`, `memo learn --status | --rollback`,
  `memo write --created-at | --tier`, `memo search --scopes a,b | --metadata-filter |
  --min-score | --rerank | --hybrid-weights`; `--metadata` is parsed as JSON.
- **Summarization without OpenResty:** with `MEMO_SUMMARIZER_INTERVAL_SECONDS`
  set, writes summarize old, light memories at most that often (as auto-digest
  does).

### Connecting MCP clients: `memo mcp`

- **`memo mcp [--project PATH]`** runs the MCP server with the project's settings,
  found as for every `memo` command — so a client's entry is the same everywhere
  and holds nothing secret: `{"command": "/path/to/memo", "args": ["mcp"]}`.
  `memo mcp --print-config` prints it (the `mcpServers` and VS Code `servers`
  shapes, and the `claude mcp add` line). It finds `mcp/server.lua` next to itself
  in a checkout, or in the LuaRocks tree it was installed in.
- **The project is found from any subfolder:** the nearest directory upward that
  holds a `.luamemorc` (never the home directory's own `~/.luamemorc`, the user
  file); `memo calibrate --root DIR` / `memo mcp --project DIR` name one and win
  over `MEMO_PROJECT`.
- **No settings → the server still starts**, and every tool answers with what to
  do (run `memo calibrate`, pass `--project`, or trust a committed `.luamemorc`).
- **`~/.memorc` is no longer read:** `memo calibrate` moves its settings into
  `~/.luamemorc` (a setting already there is kept) and removes it; until then every
  command says so.
- **`memo calibrate` writes the generic entry** for VS Code (`.vscode/mcp.json`,
  `--project ${workspaceFolder}`), Cursor and Claude Desktop (one entry per project,
  its folder pinned), replaces the entries it wrote before (`luajit …/mcp/server.lua`
  with `MEMO_*` settings in `env`) and keeps one you wrote yourself; it always
  prints the entry for other clients. It no longer copies settings into client
  configs: a setting the server needs that only your shell sets (e.g. `MEMO_CA_FILE`,
  `MEMO_ORG_IDENTITY`) is offered for `.luamemorc` instead. The Claude Code plugin
  starts `memo mcp`, and its session-start hook no longer runs `~/.luamemorc` as
  shell (memo reads it).
- **MCP 2026-07-28** (stateless: `_meta` on every request, `server/discover`,
  `resultType`, caching hints, error -32022 for an unknown version) alongside the
  `initialize`-based 2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05 — each client
  at its own version (was: 2024-11-05 for everyone); JSON-RPC batches are answered;
  a line that isn't JSON gets a parse error instead of silence.
- **Usage rules in the connection:** the server sends `mcp/instructions.md` as MCP
  `instructions` — start with the brief, search before answering, write as you go,
  keep secrets out of the chat, leave approvals and settings to people — so a
  client without luamemo's skill, agent or hooks still knows how to use it. The
  skill and the agent carry the same rules, word for word.
- **`memory_brief`** — the session brief (`memo brief`) as a tool, for clients
  without hooks.
- **Old clients are named:** the server records each client's name, version,
  protocol and capability names (`~/.config/luamemo/clients.json`); `memo doctor`
  and `memo calibrate` name a client too old for the usage rules (before
  2025-03-26), and the first brief of a session tells the agent.

### Fewer tokens per session

- **The tool list is 39 % smaller** (24 KB → 15 KB of JSON, every tool kept): the
  descriptions no longer repeat the usage rules the server sends once as instructions.
  `MEMO_MCP_TOOLS=core` offers only the 16 everyday tools (10 KB); the others stay on
  `memo`.
- **Compact answers:** `memory_search` / `memory_recent` / `memory_get` rows leave out
  the scoring internals (`vec_score`, `fts_score`, `weight`, `decay_rate`, …) and empty
  fields — a 10-result search went from 4.5 KB to 2.5 KB; `verbose: true` returns whole
  rows. `memory_write` and `memory_update` answer with the memory's id, scope, kind,
  title and tier (and a `warning` when the store kept it otherwise) instead of echoing
  the text they were sent — an update of the importance alone sent the whole body back
  (2.3 KB → 95 bytes); `memory_status` no longer repeats the total in every scope's row.
- **A long memory doesn't cost its whole length in every search:** in `memory_search` /
  `memory_recent` rows a body is at most 2,000 bytes (`truncated`; `memory_get` has it
  whole). And the capture hooks save at tier 0 — the digest's raw input — so their
  conversation chunks stay out of searches: at tier 1 a search without a scope returned
  them whole (three saves: 30 KB, about 7,700 tokens). Tier 0 now stays out everywhere an
  agent reads: `memory_recent` hides it as search does (`tier_min`; a session scope's
  newest 20 were all transcript chunks — 27 KB → 1 KB), `memory_promote` leaves it out of
  the summary (a session's chunks made a 122 KB "summary" searches then returned; they
  stay for the digest), a search no longer distils it into observations (they got past
  its tier filter), and its lines no longer become "User has mentioned …" memories at
  tier 1 (the assistant's lines among them).
- **No answer says the same thing twice:** with the default summarizer an observation is
  a memory's own text, appended after that memory in the same search; one repeating a
  result is left out.
- **Org searches without the bookkeeping:** compact rows leave out luamemo's own metadata
  (`lm_org_id`, sync clocks, proposal links) and an org memory's `proposers` — people's
  e-mail identities, sent to the model on every call; together half of an org search's
  answer (4.1 → 2.2 KB for 10 results). `verbose` keeps them.
- **Code-map answers are plain text:** `index_search` / `index_outline` /
  `index_explore` / `index_status` sent their lines inside JSON
  (`{"ok":true,"text":"…\n…"}`, `index_status` its counts twice), every line break and
  `/` escaped; they now send the text itself (2–4 % smaller). JSON answers no longer
  write `/` as `\/` (lua-cjson does), a character per path or URL separator.
- **Less work per write and search:** a batch write's duplicate check scores the
  stored vectors in place, as a single write does (it unpacked up to 1,000 of them
  into Lua tables); the facts lookup that comes with every search skips code-map scopes
  and asks SQLite only for the facts naming a query word (it scanned a scope's 1,000
  newest in Lua); the observations every search consults are scored where they are stored,
  not unpacked into a Lua table each per search (12.7 → 3 ms at 482 observations, the same
  results) — and so are they when the first search after a write consolidates it (8.2 →
  2.7 ms at 486 observations, 36.6 → 7.1 ms at 1,575; the same observations reinforced
  or made). `memo write` / `search` / `recent` build their request with one `jq`
  instead of one per option (jq 1.6 or newer).
- **Half the embedder calls:** a new observation the default summarizer makes is a
  memory's own text — it was embedded again (one more call per memory written, all
  inside the first search after the writes: 101 calls after 100 writes); it now takes
  that memory's vector. On a paid embedding API, that was the cost of every write twice.
- **An org central answers a dev's push in constant time:** its lookups by proposal ref
  (each status check, withdrawal and proposal) matched inside every proposal's
  proposers list — 22 ms a ref at 20,000 proposals, 1.1 s for a push's 50 checks while
  the central served one request at a time. An indexed mirror (migration `005`, kept by
  triggers) answers them: 0.3 ms a ref, whatever the count.
- **`memo index ingest` runs ctags once per 200 files** (Go, Rust, Java, … — the
  languages without a built-in parser), not once per file: 200 Go files index in 0.3 s
  instead of 1.3 s.
- **Indexing a big project no longer slows down with its size:** `memo index ingest` /
  `update` replace each file's rows by its path, and nothing indexed the path — every
  file searched the whole code map (2,000 files: 47 s; now 6.7 s, ~3 ms a file however
  large the map). `index_outline` read every symbol of the project to find one file's
  (59 ms at 5,000 files; now 0.1 ms), as did `index_explore` per neighbouring module.
  A new index (migration `004`, applied when a database is next opened) answers these;
  metadata filters on text (`memory_search` / `memory_delete`) can use it too.

### Install, CI and releases

- **`luarocks install luamemo` works with the LuaRocks systems package.** The
  rockspec required `luajit >= 2.1`, which a LuaRocks running on Lua 5.1 (Debian's
  and Ubuntu's `apt install luarocks`) can never provide, so the rock didn't
  install. It now depends on `lua ~> 5.1`; `memo` runs LuaJIT itself.
- **The rock carries every module:** the rockspec is generated
  (`eval/release/rockspec.lua`). 0.4.1's hand-kept list missed 16 modules; a test
  keeps the two equal.
- **A `--local` or custom LuaRocks tree works without `luarocks path`:** `memo`
  finds its modules in the tree it's installed in.
- **The in-process GGUF embedder without a compiler:** each release ships a
  prebuilt runtime for Linux x86_64 and macOS arm64 (the shim plus llama.cpp b9976).
  `memo calibrate` offers it and `memo gguf install` gets it. The download is
  checked against the checksum the installed rock carries; `memo gguf status`
  shows what is in use.
- **CI on every push** (GitHub Actions): the suite on Ubuntu, with and without
  lua-cjson, then a smoke test of the rock installed into a fresh tree. A
  **Release** workflow runs the checks, CI and the GGUF runtimes, tags the release,
  smoke-tests the packed rock, creates the GitHub Release and uploads to
  luarocks.org on request. See [RELEASING.md](RELEASING.md).
- **New tests:** live Ollama / TEI embedders (`test_embedders_live`, skipped when
  nothing answers), the installed rock (`test_rock`), the rockspec, the prebuilt
  GGUF runtime.

### Security

- **`memo secret-store` put the secret on a command line:** the value went to `jq` as an
  argument, readable by any local user while it ran (`ps`, `/proc/<pid>/cmdline`). It goes
  on stdin now.
- **A project's own Lua files could run as luamemo's (0.4.x and earlier — update).**
  LuaJIT searches the working directory first (`./?.lua`, `./?.so`), and `memo` put
  `./?/init.lua` in front as well. So in a project holding a `luamemo/init.lua`, a
  `cjson/safe.lua` and the like, that file ran instead of luamemo's code: from any
  `memo` command, from an MCP server started in the project, and from the Claude Code
  plugin's session-start hook as soon as the project was opened. `memo`, `memo mcp`
  and the server now keep only absolute entries on the module paths; a test keeps it
  so.
- **`secret_execute` can't hand a secret, or a credential file, to the agent.** The
  response is masked (the value as sent, URL-encoded and JSON-escaped — a server that
  echoes the request used to return it) and bounded (MCP: 64 KB by default, up to
  1 MB with `max_bytes`; `truncated` says so). Files the MCP tool uploads must be
  regular files inside the project (symlinks resolved), never hidden or credential
  files (`.env`, keys, `.luamemorc`, …), at most 50 MB together, and none when the
  server runs outside a project. Before, any path relative to the server's working
  directory was read. A multipart field name or content type can't carry a line break
  into the part's headers.
- **Credentials are scrubbed from every memory before it is stored.** The capture
  hooks now really save the conversation (see Fixed), so a key pasted into the chat
  would have been kept and come back in every search. Private-key blocks (also cut
  off), JWTs, tokens with a known prefix (`sk-`, `ghp_`, `AKIA`, `xoxb-`, …), Bearer /
  Basic credentials, URL credentials and `password=…`-style values that mix letters and
  digits become `[redacted]` — in the title, the body, tags and metadata, however the
  memory is written (MCP, `memo`, hooks, import, updates). Commit SHAs, UUIDs and code
  are left alone. The hooks hand the
  conversation to `memo write --body -` on stdin, not on its command line, where `ps`
  shows it to other users. The org-proposal filter shares the scrubber's list of key
  formats, so the central now also refuses proposals holding GitLab tokens or Basic
  credentials.
- **An agent can't replace or silently delete a stored secret.** Over MCP,
  `secret_store` adds new secrets only (replacing one is `memo secret-store`), and
  `secret_delete` takes two calls — a preview with a confirm token, then the delete.
- **HTTPS is TLS 1.2 or newer** (1.1 was still allowed; RFC 8996 deprecates it).
- **`memo import` can't plant facts in a dev's org replica:** an imported fact for the
  read-only `org:` scope was inserted (`memo kg add` refuses it), and searches reported it
  as the org's current truth. Such a line is now refused, by line number.
- **`memo calibrate`'s project scan quotes the project's path:** it went into `find`
  as it is — a directory named `x$(…)y` (a downloaded archive's) ran that command, and
  one with a space in its path scanned nothing.
- **Smaller hardening:** credentials in URLs (`user:password@`, `?key=…`, `&access_token=…`)
  are masked wherever luamemo shows a URL, `memory_status` details included; the
  capture hook keeps its cooldown file in `~/.cache/luamemo/hooks` (0700), not the
  shared `/tmp`; an MCP client's name and version are stored and printed without
  control characters; every private file luamemo writes (settings files, the trust
  list, the org registry, the client record) is created 0600 from the start — none
  is world-readable for the instant between writing and `chmod` any more — under a
  random temporary name; a symlinked `~/.luamemorc` (a dotfiles manager's) is written
  where it points, while a project's settings file that is a symlink is left alone (a
  downloaded folder could point it at any file of the user's, and writing through the
  link would rewrite that file); the CI and release workflows pin GitHub's actions by
  commit.

### Fixed (found during the rebuild)

- **Opening a database no longer changes the mode of its directory.** luamemo made
  whatever directory held the database 0700: `MEMO_DB=/tmp/x.db` locked down `/tmp`,
  a relative path the current directory, a path under `/dev/null` `/dev/null` itself
  (other programs then failed to open it). Only a directory luamemo creates is 0700
  now; the default data directory still is.
- **Without lua-cjson, the learned reranker and the projection trainer failed to
  load**, as did several benchmark scripts: they loaded `cjson` directly, but
  lua-cjson is optional. They now use `luamemo.json` (lua-cjson when installed,
  else the bundled dkjson); a test keeps it that way. Found by the first CI run on
  a clean machine.
- **The bundled JSON fallback now encodes like lua-cjson.** It treated a numeric
  field `n` as an array length (metadata `{n = 7}` was written as seven nulls) and
  wrote an empty table as `[]` (MCP capabilities went out as `"tools": []`).
- **`memo write` without `--scope` ignored the project's `MEMO_SCOPE`.** The memory
  landed in `global`, where the agent's searches, scoped to the project, never
  found it.
- **MCP results encoded an empty list as `{}`** (search, recent, secrets, diary);
  they now return `[]`.
- **The Claude Code capture hooks never saved a conversation.** They read
  `CLAUDE_TRANSCRIPT_PATH` / `CLAUDE_SESSION_ID`, which Claude Code doesn't set
  (it passes the hook input as JSON on stdin), and a transcript shape it doesn't
  write — given the variable, they saved "ASSISTANT: " lines with every word lost.
  They now read stdin and Claude Code's transcript (text only — no tool calls,
  tool results, meta or subagent lines); they also needed `MEMO_DB_URL` and
  printed `memo write`'s output.
- **`memo` run outside its checkout loaded no luamemo — or an older installed
  copy.** It now puts the modules next to it first (as the MCP server does), so
  a plugin's clone works from any project.
- **The plugin's session-start hook failed on a fresh clone**: git checks
  `cli/memo` out without its executable bit; the hook now runs it with `bash`.
- `memo summarize --weight-threshold` was ignored; digest ignored
  `MEMO_CONSOLIDATE_THRESHOLD` (always 0.80); `MEMO_RERANK_EPSILON` never reached
  the learned reranker.
- A metadata filter with a value it couldn't compare was silently dropped — a
  bulk delete would have matched the whole scope. Booleans are compared now;
  anything else is refused.
- `memo kg … --at` refused Unix seconds; `memo search` / `recent` / `kg query`
  printed `"results": {}` instead of `[]` when nothing matched.
- A search's `facts` never included a fact older than the scope's 1,000 newest.
- **Search got slower with every memory in the scope:** its text step let SQLite walk
  every row of the scope and run the full-text match per row (a plan chosen for the bound
  `LIMIT ?`) — 0.5–2 s a search at 5,000 memories, whatever matched. It now starts from
  the full-text index: about 15–25 ms. And a batch write's duplicate check sorted the
  whole scope to find its newest candidates: a new index (scope, updated_at) — migration
  `003`, applied when a database is next opened — reads them directly (28 → 7 ms at 5,000
  memories). And the first search after a bulk write ran the whole pending consolidation
  inline (clustering every new memory: 9 s after 5,000 rows); a search now consolidates
  at most 100 of them, the rest over the next searches (or `memo digest`).
- **Every MCP tool checks its arguments against its own schema** before it runs: a
  wrong-typed argument (an object as a scope, a number as the diary's agent name, null for
  a required field) was a Lua error in the handler — 45 bare "Internal error"s across 9
  tools in 720 wrong-typed calls; each is now a tool error naming the argument. A number
  for a string, `"5"` for a number and `"true"` for a boolean are taken as meant; JSON
  text for an object or a list is parsed by the tool, as before. A list or an object
  holds at most 200 entries unless its schema says otherwise: 10,000 scopes or
  metadata-filter keys overran LuaJIT's argument limit or SQLite's expression depth.
- **A wrong-typed field in a write gave a bare "Internal error":** an object or a null as
  the title or body crashed deep in the store, a string as metadata surfaced a raw SQLite
  message. Each is now refused with what is wrong (`body must be text`, `metadata must be
  an object`, `tags must be a list of words`); a number is taken as text.
- **A malformed answer from an LLM reranker failed the whole search:** an index like `2.5`
  passed the range check and crashed it, and an error an adapter raised escaped too. Such
  an index is refused, and search falls back to its own ranking whenever the reranker
  fails (as documented — reranking is best-effort).
- **Text cut to a length could end inside a character** (`decisão` → `decis` + a stray
  byte): titles calibrate makes from commit subjects, index rows, sensing notes, the brief,
  `index_search` docstrings, and text sent to embedders, rerankers and summarizers — which
  may refuse what isn't valid UTF-8. Every cut ends on a character now (`util.cut_utf8`),
  and whatever the MCP server sends is valid UTF-8 (a stray byte from an earlier version
  goes out as U+FFFD).
- `memo calibrate` read a hand-edited, double-quoted value (`MEMO_DB="…"`) with its
  quotes: it had a reader of its own that knew single quotes only.
- A batch write (`memory_write` with `items`, dedup `update`) lost text: of two
  near-duplicates in the batch, the second was reported merged into the first but its
  body never stored; with a first one that had no body, the batch failed.
- `memo write` / `update` / `search` / `recent` looped forever when the last option
  had no value (`memo write --title`); they now exit 2 with a message.
- A dev whose embedder changed size could never finish the switch (the replica
  re-sync and `memo reembed` waited on each other).
- `memo reembed` left a scope's observations (what consolidation distils from its
  memories) in the old embedder's space: after a switch of size no search found them
  again. They are re-embedded with the scope's memories now (`observations` in the result).
- **A deleted memory went on reaching agents:** consolidation distils observations from
  memories, and with the default summarizer an observation is a memory's own text — after
  `memory_delete` (a confidential note, say) searches still returned it, and after
  `memory_update` the old text came back beside the new. An observation now goes with the
  memory it came from (a delete, a delete by filter, new text), and so do the
  "Preference: …" memories written from its text; an updated memory is consolidated
  again. `memory_get` of a missing id says "not found" (it said "Error: nil").
- **Acting on an observation reached another memory:** a search's observation rows carried
  their own table's id as `id`, which `memory_get` / `memory_update` / `memory_delete` read
  as a memory id — an agent deleting "that result" deleted an unrelated memory, in any
  scope. They carry `observation_id` now. And a search filtered on `kind`, metadata, time
  or tier no longer has observations appended whatever the filter (they have none of
  those); `min_score` holds for them too.
- **A decision could vanish into a hook's transcript chunk:** a write nearly the same as a
  tier-0 row (the raw conversation the hooks save) merged into it and stayed tier 0 —
  hidden from search, then deleted by the digest; the other way round, a chunk merged into
  a memory overwrote its text. Near-duplicates merge only within tier 0 or within tier ≥ 1.
- **The MCP server could be stopped by one message** when lua-cjson isn't installed (it is
  optional): the bundled JSON parser recursed per nesting level and a deeply nested line
  overflowed the stack, out of the server's loop. It is a parse error now, and nothing a
  message raises ends the server.
- **`memo index ingest` built a map nobody read:** it wrote `codeindex:default`, while the
  brief and the `index_*` tools looked in `codeindex:<project>` — following the brief's
  "build with: memo index ingest" changed nothing, and the agent went back to grepping and
  reading files. One rule now: the project of `MEMO_SCOPE` (`repo:x` → `codeindex:x`).
- `memory_write` with `items`: a duplicate inside the batch was reported as failed
  ("merged into batch item 1", `ok: false`), so an agent sent it again; it is answered
  with the row it joined (`merged_into`).
- **One far-off time made a scope unreadable:** a backdated `created_at` past what the
  clock functions show (a nanosecond count read as seconds) was stored, and every
  `memory_search` / `memory_recent` of that scope then failed; a millisecond count gave a
  5-digit year an export couldn't read back. Times outside the years 1000–9999 are
  refused (writes, imports, facts), and a stored one no longer breaks a read.
- With the lua-cjson a distribution packages (2.1.0 — Ubuntu's `lua-cjson`) every empty
  list went out as `{}`: `"results": {}` for no results. That version can't write an
  empty array; luamemo uses its bundled JSON code with it (lua-cjson 2.1.0.6 or newer,
  as luarocks installs, is used as before).
- `memory_update` with `scope: ""` moved the memory into the empty scope, where only its
  id found it; an empty scope or kind is now no change. `memo write-many` ignored a
  line's `tier` and `created_at` (`memo write` and `memory_write` took them): the three
  read a memory's fields in one place now.
- **An edit whose text the embedder rejected as too long was lost** (`memory_update`,
  `memo update`, a dedup merge, synced directives, accepted proposals): it failed with
  `update: db error: nil`, while a write of the same text is kept without a vector. An
  update keeps it the same way now (`was_truncated`, a warning). `memo reembed` failed on
  such a memory too and left its old vector — after a change of vector size the switch
  could never finish.
- `memo export --out` onto an existing world-readable file kept its mode (now
  0600); `memo learn --rollback` now records its own audit row.
- `recall_bench --mode ci` was flaky under LuaJIT (scope iteration order) — it
  writes in a fixed order now.

### Federation (org mode)

- **One binary, three roles** (config only, never auto-detected): *solo*
  (default, unchanged — one database per project), *dev* (`memo calibrate
  --org-url URL --org-fingerprint FP`) and *org central* (`memo calibrate --role
  org --org-name NAME`). Devs talk to the central through `memo serve`, never its
  database. See README → Federation.
- **Local network / VPN only — no hosted anything.** `memo serve` binds only to
  loopback / private / Tailscale addresses and drops public peers; a dev refuses a
  central that resolves to a public IP (new `luamemo.netguard`: IPv4 + IPv6,
  CGNAT 100.64/10, ULA, link-local, every resolved address). `memo serve` is an
  event loop: a client that sends or reads slowly can't hold it up for others;
  open connections are capped (overall and per address, the longest-idle one
  closed to make room) and request bodies in flight share a memory budget.
- **No passwords or tokens: keys + a pairing code (SSH model).** The central's
  Ed25519 identity has a public fingerprint the admin hands out; each dev machine
  creates its own key (per-user keyring `~/.config/luamemo`, 0700 / 0600,
  encrypted, never leaves the machine). Pairing pins the central's key; both sides
  show the same short code derived from both public keys; the admin approves that
  code (`memo org devs pending | approve CODE | remove REF`; a code matching two
  pending requests is refused, not approved for both). Pairing is limited per
  address (IPv6: per /64) — a few pending requests and a few requests a minute,
  checked before any signature work — so one machine can't crowd the queue; a
  request claiming someone's identity from another address can't remove theirs;
  the queue is storage-bounded (the oldest pending request makes room), requests
  expire after 24 h, and `memo org devs clear-pending` drops them all. An
  approval that races with the device re-sending its request is kept.
  Nothing secret is typed, printed or transported.
- **Built-in encrypted channel (protocol 3, libsodium).** One-round handshake
  (Ed25519-signed transcripts, ephemeral X25519, HKDF-SHA256 → forward secrecy),
  then XChaCha20-Poly1305 envelopes under one key per direction, every message
  numbered (a nonce never repeats under a key; replay / reorder refused),
  DB-backed sessions (survive restarts). Unknown / pending / removed keys are
  refused before expensive crypto; each hello also carries a MAC under a key only
  that device and the central can derive (static X25519 agreement of their
  identity keys, Ed25519 → X25519), checked with one HMAC before any signature
  work — knowing a device's public key lets nobody force signature work or lock
  the device out; a replayed handshake is refused. The central's signed welcome
  names the approved identity. Peers of another protocol version refuse each
  other, saying which side to upgrade.
- **Secrets store: internal secrets + per-user stores.** Store instances
  (`secrets.open`), internal entries under the reserved `luamemo.` prefix that
  only luamemo's code can read — `secret_execute` refuses them before any request
  and listings mark them.
- **One org database per machine; project tags; switching.** The first project of
  an org records its database (and embedder) as the org's database on this
  machine; later projects join it (their `.luamemorc` gets its `MEMO_DB` and
  embedder keys), each keeping its `repo:` scope; a project with its own memories is
  offered `memo org adopt` (copies memories, reinforcements, retrieval events,
  graph facts, observations and learned weights — idempotent, re-embedded when
  the embedders differ, the source never modified). A database belongs to one
  org. A different central fingerprint = a different org: calibrate leaves the old
  one first (last push; replica, weights and sync state go with the last project
  using them); `memo calibrate --role solo` leaves too. `metadata.project` tags
  (`memo org directives --project`), and `memory_search project=…` narrows `org:`
  scopes to one project + org-wide rows (all search legs). Existing MCP entries
  get their database / embedder / org settings synced by calibrate.
- **Knowledge proposals (dev → admin → org).** Devs never push memories
  wholesale. A deterministic filter proposes a `repo:` fact / decision only when
  it's proven by use, secret-free, free of first-person preference / style
  language, grounded in the project's code index and not already in the org
  (`memo org proposals [candidates --explain | withdraw | private]`); triples mode
  only, `MEMO_ORG_PROPOSE=0` / `MEMO_ORG_PROPOSE_SCOPES` to limit. The central
  re-checks, merges the same knowledge from several devs (support), suppresses
  rejected content until it changes, and the admin decides (`memo org review
  [show | approve | approve --top N | reject | remove]`). Approved knowledge lands
  at tier 1, tagged with its project, decaying (`MEMO_ORG_KNOWLEDGE_DECAY`, 0.01/day);
  a changed source is re-proposed as an update of the same org memory.
- **No silent loss.** Use of approved knowledge (praise / direct command / miss,
  top of a pushed search, the proposer's use of its original) raises its
  importance and restarts its decay clock; decay, summarization, bulk deletes and
  digest purges never remove it, and corrections never drop it below tier 1. Only
  the admin removes it.
- **Session brief:** a dev's brief says when the device isn't paired yet or the
  last sync failed; the central's brief says what waits for the admin (pairing
  requests, proposals — the admin decides).
- **Protected core tier.** `memo org directives <path>` ingests Markdown standards
  as org directives (tier 3, never decaying; one per `#`/`##` section; idempotent
  re-sync with in-place updates and pruning — never after a skipped or unreadable
  file). Nothing else can write that tier on the central, and every `org:` scope is
  a read-only replica on a dev. Enforced on every mutation path (write / bulk /
  update / delete / dedup-merge / digest / consolidation / summarizer) through
  unforgeable in-process capabilities.
- **Dev replica + sync.** Paged, resumable, time-boxed pulls with a versioned
  manifest (rows that left the org are removed, missed versions re-fetched);
  the central's vectors are reused when both sides run the same embedder, else
  rows are re-embedded locally. Triggers: session start (`memo brief` also
  announces the replica), a stale org-scope search (`MEMO_ORG_SYNC_TTL`, 900 s),
  `memo org pull|push|sync|status`. Offline-safe: a failed pull keeps the replica.
- **Feedback push.** Reinforcements on org memories, plus (default
  `MEMO_ORG_SHARE=triples`) their retrieval triples, attributed to the identity
  bound to the paired key (never to what a push claims) and idempotent on the
  central. `signals` mode never sends query text, event notes or proposals, not
  even after switching back.
- **Central learning.** `memo org aggregate` digests the org scope and runs the
  promotion harness over all devs' feedback with a **directives gate** (a
  candidate reranker may not push any directive out of the top results the
  incumbent keeps it in); devs pull promoted weights on their next sync.
  `promote.run` gained pluggable `gates`.
- **Serving.** `memo serve` (pure-Lua luasocket HTTP; bounded reads, strict
  Content-Length, binary bodies, request log without query strings) is the one
  federation endpoint — `GET /key`, `POST /pair`, `POST /hello`, `POST /call`
  (encrypted RPC: info / snapshot / feedback / proposals). Protocol 3.
- **Fix (affects solo too): `store.update` corrupted a "?" inside metadata or
  tags** (`{"q": "why?"}` had its "?" replaced by a parameter). Every value is
  bound as a parameter now.
- **Fix (affects solo too): almost every memory was "core" (tier 3).** Tiers were
  derived from importance with 0–1 thresholds (0.3 / 0.6 / 0.85) although
  importance runs 0–10 with a default of 1.0, so a normal write landed in tier 3:
  digest's promotion (1 → 2 → 3) had nothing left to do, and the federation
  proposal filter's "tier 2 = proven by use" held for nearly everything. Writes
  now derive `< 0.3` → 0 · `< 5` → 1 · `< 9` → 2 · `≥ 9` → 3; a write with the
  directive capability is always tier 3; digest keeps its own 0–1 relevance scale
  for escalation / reversal (a miss never demotes, a reversal never raises).
  Imported memories land in the tier their importance gives them; learned
  reranker weights should be retrained (`memo learn`) since the tier feature now
  varies.
- **Fix (affects solo too): documented `memo` flags were silently ignored.**
  `memo write` / `update` / `search` / `recent` passed multi-word flags on with
  their hyphens (`--decay-rate` never reached `decay_rate`), `memo search`
  dropped `--since`, `--until`, `--tier-min`, `--tier-max` and `--ignore-decay`,
  and `memo update` dropped `--scope`. All are honoured now.
- **Docs: the MCP server's "HTTP mode" is gone from the docs** — it was removed
  from the server in 0.2.5 (`MEMO_URL` / `MEMO_TOKEN` do nothing); the CLI and
  the MCP server always use the database directly. The MCP README lists every
  tool.
- **Hardening (affects solo too): `secret_execute`'s SSRF guard** now blocks
  Tailscale / CGNAT (100.64/10) and IPv6 private ranges and checks every resolved
  address, not just the first. It also closes these bypasses: a `user@` part
  (`http://8.8.8.8:80@127.0.0.1/` was checked as 8.8.8.8 but went to loopback —
  such URLs are now refused), leading-zero IPv4 (`0177.0.0.1` is 127.0.0.1 to the
  resolver), IPv6 forms embedding a private IPv4 (`::127.0.0.1`, NAT64, 6to4),
  site-local `fec0::/10`, DNS rebinding for `http://` (the request connects to
  the address that was checked), and **redirects** (a public server answering
  302 → `http://127.0.0.1/…` had the request, `Authorization` header included,
  followed to the internal host and its answer returned — now no redirect is
  followed and a 3xx is reported). A failed request's error no longer quotes the
  URL with the secret substituted in.
- **Security fix (affects solo too): HTTPS was never verified.** luasec's
  `ssl.https` checks nothing by default (and never the host name), so anyone able
  to intercept traffic could read an `https://` `secret_execute` request or an
  embedder / reranker / summarizer API key. Every https server is now verified —
  certificate chain against the system CAs (`SSL_CERT_FILE` / `SSL_CERT_DIR`, else
  the OS bundle) plus the new **`MEMO_CA_FILE`** (a self-hosted server's CA or
  self-signed certificate, trusted in addition), and the certificate against the
  URL's host. No CA found → https refuses with a message naming what to set. No
  switch turns verification off. `luamemo.http` no longer follows redirects for
  any caller.
- **Hardening (affects solo too): `.luamemorc` and the CLI.** A value with a
  newline is refused; inside a git work tree `memo calibrate` adds `.luamemorc` to
  `.gitignore` (or says how to untrack it); a `.luamemorc` memo writes to is made
  0600 (appending to a hand-made 0644 file kept it world-readable). Command-line
  arguments reach the Lua side hex-encoded in the environment instead of spliced
  into Lua source, so a crafted argument is always data. (Settings files are now
  parsed as data — see *The Lua API is internal* above.)
- **Fix (affects solo too): training / gating / tuning searches logged
  themselves as retrieval feedback.** `memo learn` re-ran every harvested query
  through `store.search`, which appended it to `lm_retrieval_feedback` — the
  table grew on every run and learning fed on its own probes. Internal searches
  now pass `skip_feedback`.
- `cli/memo` runs Lua subcommands with `exec`, so a SIGTERM to `memo serve`
  reaches the server.

### Removed — Lapis / OpenResty and the Lua capture helpers

luamemo is used through the `memo` CLI and the MCP server; nothing in either
(nor in the agent hooks or `memo serve`) used these, so they are gone:

- the Lapis HTTP routes (`luamemo.routes`, `memory.routes.register`) and the
  `auth_fn` / `before_request` settings that guarded them;
- every OpenResty path: the `resty.http` transport (HTTP now always goes through
  luasocket + luasec, always verified), the `ngx.timer` summarizer
  (`start_background_jobs`), the `ngx.shared` vault lock and the `ngx.log` calls;
- `luamemo.hooks` and `HOOKS.md` (Lua auto-capture helpers — `memo write` /
  `memory_write` take the same kind, tags, metadata and dedup strategy);
- the `dev/` Docker Lapis app and `examples/lapis_app.lua`.

What the routes and helpers did is recorded in
`eval/fixtures/golden_routes_hooks.json`; every one of those capabilities is
reachable through `memo` and the MCP server.

Side effects: a misconfigured vault (bad master key, failed `chmod 600`) is now
reported on stderr instead of only to nginx's log, and `corpus_health_check =
true` writes its warnings to stderr at startup.

### Fixes & compatibility

- **Fix: `eval/recall_bench.lua` could not build its corpus** — it ran the
  long-gone `eval/_make_synthetic.lua`; it now runs `eval/helpers.lua` with its
  own interpreter.
- **The luamemo agent no longer pins a model.** `agents/luamemo.agent.md` named
  `Claude Sonnet 4.6 (copilot)` in its `model:` line, so VS Code switched to
  that model whenever the agent was picked. The line is gone: the agent now
  runs on whatever model you have selected.
- **New: `MEMO_PROJECT=DIR`** — the project whose `.luamemorc` `memo` reads and
  writes (and that `memo org link|adopt|leave` act on). Unset or empty: the
  current directory, as before.
- **Fix: `memo calibrate` persisted a garbage `MEMO_EMBEDDER_ADAPTER`** (e.g.
  `8000`) when the probe recommended an embedder with no adapter/url/model —
  i.e. the default `gguf_ffi` recommendation. The probe fields were joined
  with tabs and split with `IFS=$'\t'`; tab is IFS whitespace, so `read`
  collapsed the run of empty fields and every later value shifted left
  (`embed_max_chars` landed in the adapter slot). Fields are now joined and
  split on `\037` (ASCII unit separator), which never collapses; verified
  under awk, mawk and gawk with both a sparse (gguf) and a full (ollama)
  probe snippet.
- **Fix: codebase-index exclude patterns matched as character subsequences,
  silently dropping real files from the map.** `walker._glob_match` parked
  `**` on a `"\0"` sentinel, but a Lua 5.1 pattern ends at an embedded NUL,
  so `gsub("\0", ".*")` matched the empty pattern and inserted `.*` between
  every character — even the built-in `.git` default then excluded any path
  containing g…i…t in order (e.g. `luamemo/sensing/init.lua` and
  `sensing/heuristics.lua` were missing from every `memo index ingest`). The
  sentinel is now `"\1"`. Regression test added to `test_index_parse.lua`
  (fails on the old walker, passes on the fix); index + brief suites 233/0
  under both lua5.1 and LuaJIT. Re-run `memo index ingest` to pick up the
  files earlier ingests skipped.
- **Security: the codebase map could store credentials.** File rows keep each
  file's first line and the map is served to agents (`index_search`), but the
  walker indexed `.env`, `.luamemorc` (0.4 wrote the database URL on its first
  line), key files, etc. — reproduced on a fresh project: the DB password
  and an API key landed in agent-retrievable rows. Now:
  - credential files are **always** skipped, whatever the flags: `.env` /
    `.env.*` (templates `.env.example|sample|template|dist` kept), `.envrc`,
    `.luamemorc`, `.memorc`, `.pgpass`, `.netrc`, `.npmrc`, `.pypirc`,
    `.htpasswd`, `.git-credentials`, `.dockercfg`, `*.pem|key|p12|pfx|jks|keystore`,
    SSH private keys, `lm_master_key*`, and anything under `.ssh/`, `.aws/`,
    `.gnupg/` (`walker.is_secret`);
  - inside a git work tree, gitignored files are skipped (tracked files and
    submodule contents kept; a root that is itself gitignored is walked
    unfiltered); opt out with `memo index … --no-gitignore` /
    `respect_gitignore = false`;
  - `memo index ingest|update --exclude` now **adds** to the defaults
    (`.git`, `vendor/`, `node_modules/`) instead of replacing them — before,
    `--exclude dist/` silently re-included `.git/` internals.
  An existing map is purged of such files by the next `memo index update`.
  New `eval/tests/test_index_walker.lua` (67 checks, 35 of them fail on the
  old walker).
- **Fix: `memo calibrate` persisted `gguf_ffi` on any LuaJIT + C-toolchain host
  even when the shim wasn't built / no model was downloaded** — every
  write/search then failed until the user finished a manual setup. The gguf
  embedder is now picked only when `probe.gguf_ready()` passes (shim built,
  model found via `MEMO_GGUF_MODEL` or `~/models/`, and one real embedding
  succeeds under `luajit`); calibrate then persists `MEMO_GGUF_MODEL` and the
  model's native dim. A capable-but-not-set-up host gets a working embedder
  (service ladder, else an interim `hash` at 768 dims, the GGUF model's size) plus
  the setup guide as an optional upgrade, with the switch steps (`memo config set`,
  `memo reembed --all`).
- **Fix: calibrate's own codebase scan never used the embedder it had just
  chosen.** Later phases kept the environment from before the probe, so on a
  fresh install the scan embedded with the 384-dim `hash` default while the
  chosen embedder was 768-dim (`expected 768 dimensions, not 384`, 0 memories
  written), `gguf_ffi` ran under lua5.1 (no FFI), and the generated MCP env
  lacked the model path / `MEMO_EMBED_DIM`. calibrate now re-reads
  `.luamemorc` after persisting (and re-picks the interpreter).
- **Fix: calibrate reported "0 errors" when writes failed** — `write-many`
  printed only successes to stdout; failures now stream as `{ok=false,error}`.
- **Fix: `memo calibrate --no-gguf` was rejected** ("unknown arg") by the shell
  wrapper although the probe supports it and its own guide recommends it.
- **Fix: calibrate's Ollama / TEI recommendations could not embed.** The
  service ladder chose by hardware (GPU/Docker/RAM) without checking anything
  was running (Ollama was recommended even when unreachable), persisted
  container-only hostnames (`host.docker.internal:11434`, `lapis-tei-embed:80`)
  into `.luamemorc` and the MCP env although the CLI and MCP server run on the
  host, and omitted the endpoint path the adapters POST to (`/api/embeddings`,
  `/embed`). Now a service is chosen only if it answers a real embedding through
  the luamemo adapter (`probe.ollama_ready`, `probe.tei_ready` — running TEI
  containers are found via `docker ps`, model from `/info`); the tested host
  endpoint and live dim are persisted, and the in-container URL is printed as a
  comment in the app snippet. When nothing answers, calibrate prints what to
  start (`ollama pull …`, a `docker run` line for TEI bge-m3) and — with no gguf
  interim available — exits with the options instead of persisting a dead URL.
- **Fix: `luamemo.http` returned status `1` for every plain-Lua (luasocket)
  request.** The table form of `socket.http.request` returns
  `(1, code, headers, status)`; the success flag was read as the HTTP status,
  so `util.check_http` never saw a 404/500 — embedders, rerankers and
  summarizers parsed error bodies as data (e.g. a missing Ollama model surfaced
  as "response missing 'embedding'" instead of the 404), and transport errors
  lost their message. New `eval/tests/test_http.lua` (throwaway local server;
  7 of 10 checks fail on the old code).
- **New: `MEMO_LUA`** — the LuaJIT interpreter `memo` runs (a name or a path).
- **Fix: the codebase-index walker crashed whenever luafilesystem was
  installed** (any Lua version): it dropped the directory object `lfs.dir`
  returns, which luafilesystem ≥ 1.8 requires ("directory metatable expected,
  got nil"). New lfs-vs-`find` parity test so both walker backends stay covered.

### Development (eval harness / test suite — no effect on the installed tool)

- **Committed test runner: `luajit eval/tests/run.lua`** (see `eval/README.md`). It runs every
  `eval/tests/test_*.lua` in a clean environment — a fresh SQLite database per file,
  a temporary `HOME`, no inherited `MEMO_*` — prints one line per file and exits 1 on any
  failure. It also fixes a test-isolation bug: tests that run `./cli/memo` from the
  repository root picked up the checkout's own `.luamemorc`, so they wrote to the developer's
  database instead of the one they passed; and the ConvoMem / LoCoMo smoke tests defaulted to
  a shared benchmark database.
- The ConvoMem / LoCoMo / MemBench smoke tests read their fixtures from the
  gitignored `eval/data/`, so they failed on a fresh clone. Fixtures now live in
  the tracked `eval/fixtures/` (`convomem_tiny.json`, `locomo_tiny.json`,
  `membench_tiny/`); smoke outputs go to a temp file instead of `eval/results/`,
  and the runners are launched with the test's own interpreter (LuaJIT runs now
  exercise them under LuaJIT).
- `test_membench.lua` was rewritten for the current loader (the old one called
  the removed `iter_questions` / `iter_sessions`); `membench_tiny/` uses the real
  per-category layout and the test runs the real `membench_run.lua` on it.
- `membench.load` iterated topic keys with `pairs()`, so question ids — and which
  questions a `--n` subset picks — differed between lua5.1 and LuaJIT; keys are
  now sorted. New `membench_run.lua --scope-prefix P` (default `mb`) so tests
  never wipe real `mb:<embedder>:*` benchmark scopes. Integral MemBench ids are
  formatted as integers (Lua 5.3+ decoded them as `"1.0"`).

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
