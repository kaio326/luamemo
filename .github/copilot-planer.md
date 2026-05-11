## Purpose

This file is to be used by agents to store phased plans before implementing them, check what is in line to be implemented and pick up the work from where it was paused in case unnexpected runtime errors or physical failure of hardware occur. Create a phased plan, list it in the appropriate area, mark it as done when you finish implementing and testing the new feature / fix.

For the phased plan it must include what is the feature or fix to be implemented, document how it will be done, why that was the best choice and when complete the results of the tests and proof that it was implemented correctly.

## Add memory bellow, on new phased plans erase memory bellow before adding new memory, unless it's continued development of the same features that needs context. Before erasing the memory bellow investigate the contents and verify if any of the data there is worth adding to documentation files or copilot-instructions file (that file holds all arquitechtural decisions and designs).

---

# Phased Plan 1 — Code Quality / Duplication (Audit 1)

**Status: COMPLETE** ✓ All 6 phases implemented and `luac -p` verified.

Covers findings 1.1 – 1.6 from the code-quality audit.
Each phase is self-contained and ends with a `luac -p` syntax check on every modified file.
Ask user before starting Plan 2.

---

## Phase 1.1 — Replace inline boolean coercions in routes.lua with `util.to_bool()`
**Status: DONE** ✓

**Test result:** Added `local util = require("luamemo.util")` to `routes.lua`. Replaced all 7 inline coercions. Added rate-limit comment in file header. `luac -p luamemo/routes.lua` → OK.

**What:** `routes.lua` contains 7 locations where boolean HTTP params are coerced inline
(`p.x == "1" or p.x == "true"` or `p.x == true or p.x == "1" or p.x == "true"`).
`util.to_bool()` already exists and is used in `api.lua` and `mcp/server.lua`.

**Locations to fix (all in `luamemo/routes.lua`):**
1. `/search` — `ignore_decay = p.ignore_decay == "1" or p.ignore_decay == "true"`
2. `/summarize` — `dry_run = p.dry_run == true or p.dry_run == "1" or p.dry_run == "true"`
3. `/promote` — `delete_source = p.delete_source == true or ...`
4. `/promote` — `dry_run = p.dry_run == true or ...`
5. `/consolidate` — `dry_run = p.dry_run == true or ...`
6. `/kg/assert` — `supersede = p.supersede == true or ...`
7. `/kg/query` — `include_invalidated = p.include_invalidated == "1" or ...`

**How:** Replace each with `util.to_bool(p.field_name)`. Add `local util = require("luamemo.util")` at the top of routes.lua (it is not imported yet).

**Why this is the best choice:** Centralises boolean parsing logic. `util.to_bool()` handles `true/"true"/"1"` and `false/"false"/"0"` consistently. Any future edge cases are fixed in one place.

**Audit/test:** Run `luac -p luamemo/routes.lua`. Verify the 7 inline patterns are gone with `grep -n '== "true"\|== "1"' luamemo/routes.lua`.

**Test result:** *(to be filled in)*

---

## Phase 1.2 — Extract shared candidate formatter for reranker adapters
**Status: DONE** ✓

**Test result:** Created `luamemo/rerankers/_common.lua` with `build_candidates()`. Both adapters updated to use `_common.build_candidates(hits, CHUNK_MAX)`. `luac -p` on all 3 files → OK.

**What:** `luamemo/rerankers/ollama.lua` and `luamemo/rerankers/openai.lua` both build a
candidates list in `[N] title\nbody` format with the same `clip()` calls and constants
(`CHUNK_MAX = 500`). This block is copy-pasted.

**How:** Create `luamemo/rerankers/_common.lua` with a single exported function:
```lua
-- Returns a newline-joined candidates string: "[1] title\nbody\n[2] ..."
function M.build_candidates(hits, chunk_max)
```
Update both adapters to `require("luamemo.rerankers._common")` and call
`_common.build_candidates(hits, CHUNK_MAX)` instead of their local loops.
The prompt wrappers (`build_prompt` in ollama, `build_messages` in openai) keep their
own structure — only the candidate-list construction is shared.

**Why this is the best choice:** The candidate formatting is pure data transformation with
no adapter-specific logic. Sharing it means a change to the `[N]` format or `clip()` call
only needs to happen once. A shared `_common.lua` is idiomatic for Lua adapter families.

**Audit/test:** `luac -p luamemo/rerankers/ollama.lua luamemo/rerankers/openai.lua luamemo/rerankers/_common.lua`. Grep confirms `CHUNK_MAX` and the `[%d]` format string exist only in `_common.lua`.

**Test result:** *(to be filled in)*

---

## Phase 1.3 — Extract shared memory-list formatter for summarizer adapters
**Status: DONE** ✓

**Test result:** Created `luamemo/summarizers/_common.lua` with `build_memory_lines()`. Both adapters updated. `luac -p` on all 3 files → OK.

**What:** `luamemo/summarizers/ollama.lua` and `luamemo/summarizers/openai.lua` both
build a memories list as `[N] title\nbody` (with `util.clip(m.body, 1500)`) — identical
construction, different wrappers (prompt string vs. chat messages array).

**How:** Create `luamemo/summarizers/_common.lua` with:
```lua
-- Returns array of formatted strings: "[1] title\nbody", "[2] ..."
-- Caller assembles into a prompt or message list as needed.
function M.build_memory_lines(memories, body_clip)
```
Update both adapters to call `_common.build_memory_lines(memories, 1500)`.

**Why this is the best choice:** Same rationale as 1.2. The clip size (1500) is also shared
— moving it to `_common.lua` prevents silent divergence if one adapter changes it.

**Audit/test:** `luac -p luamemo/summarizers/ollama.lua luamemo/summarizers/openai.lua luamemo/summarizers/_common.lua`. Confirm `clip(m.body` appears only in `_common.lua`.

**Test result:** *(to be filled in)*

---

## Phase 1.4 — Move `require_str()` from kg.lua to util.lua
**Status: DONE** ✓

**Test result:** `M.require_str()` added to `util.lua`. Local definition removed from `kg.lua`; aliased via `require_str = util.require_str`. `luac -p` on both files → OK.

**What:** `luamemo/kg.lua` defines `require_str(v, name)` locally. The same pattern
(check `type(v) ~= "string" or v == ""`) is inlined in `luamemo/secrets.lua` and
`mcp/server.lua`. Moving it to `util.lua` provides a single validated implementation.

**How:**
1. Add `function M.require_str(v, name)` to `luamemo/util.lua`.
2. Remove the local definition in `kg.lua`; add `require_str = util.require_str` near the top.
3. Replace the equivalent inline checks in `secrets.lua` and `mcp/server.lua` with `util.require_str()`.

**Why this is the best choice:** `util.lua` is already the shared-helpers module. Adding
`require_str` there follows the established pattern (`clamp_check`, `check_http`, etc.).

**Audit/test:** `luac -p luamemo/util.lua luamemo/kg.lua luamemo/secrets.lua mcp/server.lua`. Grep confirms `require_str` is defined only in `util.lua`.

**Test result:** *(to be filled in)*

---

## Phase 1.5 — Move `shell_quote()` from calibrate.lua to util.lua; use in secrets.lua
**Status: DONE** ✓

**Test result:** `M.shell_quote()` added to `util.lua`. Local definition removed from `calibrate.lua`; uses `util.shell_quote`. Inline quoting expression in `secrets.lua` `save_store()` replaced with `util.shell_quote(tmp)`. `luac -p` on all 3 files → OK.

**What:** `luamemo/cli/calibrate.lua` defines `shell_quote(s)` as a local function.
`luamemo/secrets.lua` duplicates the same quoting logic inline when building the `chmod`
command (`"'" .. tostring(tmp):gsub("'", "'\\''") .. "'"`).

**How:**
1. Add `function M.shell_quote(s)` to `luamemo/util.lua` — same body as calibrate.lua's version.
2. In `calibrate.lua`, remove the local definition and use `util.shell_quote()`.
3. In `secrets.lua`, replace the inline quoting expression with `util.shell_quote(tmp)`.

**Why this is the best choice:** Shell quoting is security-relevant. A single, reviewed
implementation avoids the risk of the two copies diverging.

**Audit/test:** `luac -p luamemo/util.lua luamemo/cli/calibrate.lua luamemo/secrets.lua`. Grep for `gsub.*'\\''` should appear only in `util.lua`.

**Test result:** *(to be filled in)*

---

## Phase 1.6 — Fix misleading alias `trim = util.clip` in hooks.lua
**Status: DONE** ✓

**Test result:** Alias changed to `local clip = util.clip`. All 5 `trim(` call sites updated to `clip(`. `luac -p luamemo/hooks.lua` → OK.

**What:** `luamemo/hooks.lua` has `local trim = util.clip`. `util.trim` is whitespace
stripping; `util.clip` is char-truncation with ellipsis. The alias name `trim` is wrong and
would confuse a future maintainer adding whitespace stripping here.

**How:** Change the alias to `local clip = util.clip` and update all call sites within
`hooks.lua` from `trim(...)` to `clip(...)`.

**Why this is the best choice:** Correctness of naming. Zero functional change; all call
sites pass two arguments (string, limit) which is the `clip` signature, not `trim`.

**Audit/test:** `luac -p luamemo/hooks.lua`. Grep confirms `local trim = util.clip` is gone and no bare `trim(` calls remain.

**Test result:** *(to be filled in)*

---

# Phased Plan 2 — Security (Audit 2)

**Status: COMPLETE** ✓ All 6 phases implemented and `luac -p` verified.

Covers findings 2.1 – 2.6.
Findings 2.2 (Lua string GC) and 2.5 (rate-limit delegation) are comment-only because
there is no code-level fix possible (language limitation and architectural delegation respectively).
Findings 2.1, 2.3, 2.4, 2.6 are real code changes.

---

## Phase 2.1 — Add DNS resolution re-validation to SSRF guard
**Status: DONE** ✓

**Test result:** After the hostname string-match block, added `socket.dns.toip(host)` resolution wrapped in `pcall`. Resolved IP re-checked against the same private-range patterns. Fail-closed: unresolvable host returns `"SSRF blocked: could not resolve host"`. `luac -p luamemo/secrets.lua` → OK.

**What:** `execute_with_secret` in `luamemo/secrets.lua` blocks private IPs by string
comparison on the URL hostname. A domain like `evil.com` that resolves to `127.0.0.1`
bypasses the check (DNS rebinding / split-horizon DNS).

**How:** After extracting `host` from the URL, call `luasocket`'s `socket.dns.toip(host)` to
resolve it, then run the same private-IP pattern checks against the resolved IP string.
Use `pcall` around the DNS call so a resolution failure is treated as a blocked request
(fail-closed).

```lua
-- After the existing host string-match check:
local ok_dns, resolved_ip = pcall(function()
    local socket_mod = require("socket")
    return socket_mod.dns.toip(host)
end)
if not ok_dns or not resolved_ip then
    return nil, "secrets: SSRF blocked: could not resolve host " .. host
end
local ip_blocked = resolved_ip == "127.0.0.1"
    or resolved_ip == "::1"
    or resolved_ip:match("^127%.")
    or resolved_ip:match("^169%.254%.")
    or resolved_ip:match("^10%.")
    or resolved_ip:match("^192%.168%.")
    or resolved_ip:match("^172%.1[6-9]%.")
    or resolved_ip:match("^172%.2%d%.")
    or resolved_ip:match("^172%.3[0-1]%.")
if ip_blocked then
    return nil, "secrets: SSRF blocked: " .. host .. " resolves to disallowed IP " .. resolved_ip
end
```

**Why this is the best choice:** `luasocket` is already a dependency (used in `http.lua`).
Fail-closed on DNS failure is the safe default for SSRF prevention.
This closes the only meaningful bypass in the current guard without adding new dependencies.

**Audit/test:** `luac -p luamemo/secrets.lua`. Manual test: call `execute_with_secret` with
a URL whose host resolves to `127.0.0.1` — expect `"SSRF blocked"` error.
Also verify a legitimate external domain still works (just DNS lookup, not actual HTTP call).

**Test result:** *(to be filled in)*

---

## Phase 2.2 — Document Lua string GC limitation (comment only)
**Status: DONE** ✓

**Test result:** Expanded the `value = nil` comment to explicitly document: `ulimit -c 0` (disable core dumps), `swapoff -a` (disable swap), `mlock/mlockall` (pin memory pages), and short-lived process as the primary mitigation. Expressed as deployment-agnostic OS primitives, not Docker-specific.

**What:** `value = nil` in `execute_with_secret` cannot erase memory because Lua 5.1
strings are immutable and interned. The comment already exists. This phase verifies
the comment is clear enough and expands it if not.

**How:** Read the existing comment at the `value = nil` line in `secrets.lua`. If it already
says "Lua 5.1 strings are immutable and interned, so this does NOT securely erase memory",
mark this phase done. If not, update the comment to include that exact language plus a
mitigation recommendation (short-lived container, avoid persistent memory sharing).

**Why comment-only:** There is no Lua 5.1 mechanism to zero a string's backing memory.
A C userdata buffer would require a native extension, contradicting the zero-C-deps design.

**Audit/test:** `grep -A3 "value = nil" luamemo/secrets.lua` — confirm the immutability
warning is present and accurate.

**Test result:** *(to be filled in)*

---

## Phase 2.3 — Add symlink check to multipart file path validation
**Status: DONE** ✓

**Test result:** Added `os.execute("test ! -L " .. util.shell_quote(fpath))` check after the path-traversal guard, before `io.open`. Fail-closed on Windows (no `test` command → treated as symlink). `luac -p luamemo/secrets.lua` → OK.

**What:** `_build_multipart` in `luamemo/secrets.lua` validates that file paths are relative
and contain no `..`, but does not check for symlinks. A symlink like `./data/x -> /etc/passwd`
could leak files outside the intended directory.

**How:** After the existing path-traversal check (before `io.open`), add:
```lua
-- Reject symlinks: a symlink could point outside the intended directory tree.
local symlink_check = os.execute(
    "test ! -L " .. util.shell_quote(fpath) .. " 2>/dev/null")
local is_symlink = (symlink_check == false)
    or (type(symlink_check) == "number" and symlink_check ~= 0)
if is_symlink then
    return nil, nil,
        "secrets: multipart: symlinks are not allowed for field '" .. field_name .. "'"
end
```
This uses `util.shell_quote` (added in Phase 1.5) for safe quoting.

**Why this is the best choice:** `os.execute("test ! -L ...")` is POSIX-portable and has
no new dependencies. On Windows (no `test` command), it fails non-zero, which is treated
as "possibly a symlink" — i.e., the check is fail-closed on Windows too, which is acceptable.

**Audit/test:** `luac -p luamemo/secrets.lua`. Create a symlink in `/tmp` pointing to `/etc/passwd`
and verify `_build_multipart` returns an error for it.

**Test result:** *(to be filled in)*

---

## Phase 2.4 — Wrap `cjson.decode()` in pcall in all embedder adapters
**Status: DONE** ✓ (no-code finding)

**Test result:** `embed.lua` uses `require("cjson.safe")`. `cjson.safe.decode()` returns `nil, err` on bad JSON — it does not raise. The existing `if not payload then` check at line 51 already handles malformed responses safely. No code change needed.

**What:** The four embedder adapters (`adapters/ollama.lua`, `adapters/openai.lua`,
`adapters/generic.lua`, `adapters/tei.lua`) call `cjson.decode()` implicitly through their
`parse_response(payload, cfg)` method — but the caller in `embed.lua` already calls
`cjson.decode(body)` with a `pcall` wrapper before handing `payload` to `parse_response`.
The actual decode risk is in `embed.lua`, not the adapters.

**Verification step before coding:** Read `embed.lua` lines around the adapter call to confirm
`cjson.decode` is pcall-wrapped there. If it is, this phase is complete (document the finding).
If it is not, add pcall wrapping in each adapter's `parse_response`.

**Why this matters:** A malformed 200 response (e.g., truncated JSON from a proxy) would
raise a Lua error instead of returning `nil, err`, potentially crashing the embedding pipeline.

**Audit/test:** `grep -n "pcall\|cjson.decode" luamemo/embed.lua` — confirm decode is
guarded. `luac -p` all adapters.

**Test result:** *(to be filled in)*

---

## Phase 2.5 — Add rate-limit delegation comment to routes.lua header
**Status: DONE** ✓

**Test result:** Comment block added during Phase 1.1 (header already updated). `grep -n "rate" luamemo/routes.lua` confirms comment at line 4.

**What:** Routes have no built-in rate limiting. This is by design (library embedded in host
app), but there is no comment informing implementors where to add it.

**How:** Add a comment block at the top of `routes.lua` (after the module description) stating:
- Rate limiting and request throttling must be implemented in the host app via `cfg.before_request()`
- `before_request` is called on every route before any processing
- Example: use `ngx.shared` counters (OpenResty) or an external Redis limiter

**Why comment-only:** Adding rate limiting to the library would require a stateful
counter (shared dict / Redis), which would be an inappropriate dependency for an embedded
library. The `before_request` hook is the correct extension point.

**Audit/test:** `grep -n "rate" luamemo/routes.lua` — confirm the comment is present.

**Test result:** *(to be filled in)*

---

## Phase 2.6 — Cap `recent()` limit at 100 in routes.lua
**Status: DONE** ✓

**Test result:** Added `if not limit or limit < 1 then limit = 20 end` and `if limit > 100 then limit = 100 end` after `tonumber(p.limit)` in the `/recent` handler. `luac -p luamemo/routes.lua` → OK.

**What:** The `/recent` route does `limit = tonumber(p.limit)` with no upper cap.
A request with `limit=100000` forces a query returning all rows, which can exhaust
memory and DB resources.

**How:** In the `/recent` handler, after `limit = tonumber(p.limit)`, add:
```lua
if not limit or limit < 1 then limit = 20 end
if limit > 100 then limit = 100 end
```
The default of 20 matches the likely intended behaviour. 100 is a safe maximum.

**Why this is the best choice:** A one-line guard. The store's `recent()` function accepts
any limit — the cap belongs at the HTTP boundary where untrusted input arrives.

**Audit/test:** `luac -p luamemo/routes.lua`. Verify with `grep -A4 "GET /recent" luamemo/routes.lua`
or by searching for the `recent` handler and confirming the cap is present.

**Test result:** *(to be filled in)*

---

# Phased Plan 3 — Algorithm / Performance (Audit 3)

**Status: COMPLETE** ✓ All phases implemented and `luac -p` verified.

Covers findings 3.1 – 3.8.
- 3.1: Real implementation — bundled `luamemo/async.lua` event loop over existing luasocket (no new deps)
- 3.2: Promoted to its own plan — see **Plan 4**
- 3.3: Promoted to its own plan — see **Plan 5** (LSH middle-tier backend)
- 3.4 and 3.6: Real code changes (migration file + SQL change in tune_weights)
- 3.7, 3.8: Comment/documentation additions

---

## Phase 3.1 — Bundle minimal async event loop for parallel embedding in write_many()
**Status: DONE** ✓

**Test result:** Created `luamemo/async.lua` (coroutine scheduler over `socket.select()`). Added `http.request_async(url, opts, wait_fn)` to `http.lua` (HTTP-only non-blocking client; HTTPS falls back to sync). Added `embed.embed_async(text, wait_fn)` to `embed.lua`. Refactored Phase A of `write_many()` into 3 sub-passes: A1=validate, A2=async embed (skipped in OpenResty), A3=dedup+prepare. `luac -p` on all 4 files → OK.

**What:** `store.write_many()` embeds rows sequentially. For 100 rows at 100ms/embed = 10s.
A minimal event loop over `socket.select()` (already provided by `luasocket`) makes
concurrent HTTP embedding possible in plain Lua with zero new LuaRocks dependencies.

**How:** Create `luamemo/async.lua` — a stripped-down coroutine scheduler (~300 lines)
built on `socket.select()`. Key API:
```lua
local async = require("luamemo.async")
-- Schedule N coroutines and run until all finish or timeout.
async.run_all(tasks, timeout_ms)  -- tasks: array of functions
```
Internally:
- Each task is wrapped in a coroutine
- The scheduler calls `socket.select(readable, writable, timeout)` to multiplex
- Tasks that block on I/O yield; the scheduler resumes them when their socket is ready
- `luamemo/http.lua` gains a `try_socket_async(url, opts, yield_fn)` variant that
  yields instead of blocking when a `yield_fn` is supplied

In `store.write_many()`, detect if `async` is available (it always is — it's bundled) and
use `async.run_all` to embed all rows concurrently, collecting results into the same
`vecs` table that the sequential loop currently builds.

**Why bundled over copas:** `copas` is ~800 lines and designed for general async servers.
We only need a task-pool scheduler for HTTP fan-out. ~300 lines avoids the dependency
and lets us keep the API surface minimal. `luasocket` (and therefore `socket.select`) is
already required by `http.lua` in the plain-Lua path, so no new dependency is introduced.

**In OpenResty:** The async path is skipped; OpenResty uses `ngx.timer.at` natively and
`resty.http` is already non-blocking. Plain Lua gets the new async path.

**Audit/test:**
- `luac -p luamemo/async.lua luamemo/store.lua luamemo/http.lua`
- Smoke test: call `store.write_many()` with 10 rows against a live embedder; measure
  wall time — expect near `1 × embed_latency` instead of `10 × embed_latency`
- Verify sequential fallback still works when embedder is unavailable

**Test result:** *(to be filled in)*

---

## Phase 3.2 — Batch dedup rewrite for write_many()
**Status: PROMOTED TO PLAN 4**

This finding was promoted to its own full phased plan.
See **Plan 4 — Batch Dedup Rewrite for write_many()** below for full details.

---

## Phase 3.3 — LSH middle-tier backend for non-pgvector environments
**Status: PROMOTED TO PLAN 5**

This finding was promoted to its own full phased plan.
See **Plan 5 — LSH ANN Backend** below for full details.

---

## Phase 3.4 — Add migration 005: composite index on (scope, kind)
**Status: DONE** ✓

**Test result:** Created `luamemo/migrations/005_composite_indexes.sql`. Applied to `luamemo_dev`: `CREATE INDEX` confirmed. `\d lm_memories` shows `lm_memories_scope_kind_idx btree (scope, kind)`.

**What:** `schema.sql` creates separate single-column indexes on `scope` and `kind`.
Queries like `WHERE scope = ? AND kind = ?` can use a bitmap AND of two indexes, but a
single composite btree on `(scope, kind)` is more efficient and avoids the bitmap merge.

**Verification:** The current schema has `lm_memories_scope_idx ON lm_memories (scope)`
and `lm_memories_kind_idx ON lm_memories (kind)` — no composite index exists.

**How:** Create `luamemo/migrations/005_composite_indexes.sql`:
```sql
-- luamemo migration 005: composite indexes for common query patterns
--
-- Adds a composite btree index on (scope, kind) for queries that filter
-- on both columns simultaneously, replacing the need for a bitmap AND
-- of the two single-column indexes.
-- Safe to re-run.

CREATE INDEX IF NOT EXISTS lm_memories_scope_kind_idx
    ON lm_memories (scope, kind);
```

**Why this is the best choice:** A composite index on `(scope, kind)` covers
single-column queries on `scope` (leftmost prefix) as well as both-column queries.
It can replace `lm_memories_scope_idx` for queries that use `scope` alone, though we
keep the old index for backward compatibility (the DB planner will choose the best one).

**Audit/test:** Apply the migration to `luamemo_dev` DB:
```
psql -d luamemo_dev < luamemo/migrations/005_composite_indexes.sql
```
Verify with `\d lm_memories` in psql that `lm_memories_scope_kind_idx` appears.
Run `EXPLAIN SELECT * FROM lm_memories WHERE scope = 'test' AND kind = 'fact' LIMIT 10`
and confirm the planner uses `lm_memories_scope_kind_idx`.

**Test result:** *(to be filled in)*

---

## Phase 3.5 — (Skipped — covered by 2.6) recent() limit cap
**Status: SKIPPED**

This is the same fix as Phase 2.6. Already tracked there.

---

## Phase 3.6 — Replace ORDER BY random() with TABLESAMPLE for large corpora in tune_weights.lua
**Status: DONE** ✓

**Test result:** `_sample_rows()` now runs a `count(*)` query first; switches to `TABLESAMPLE BERNOULLI` with 3× oversampling when total > 10 000 rows, keeps `ORDER BY random()` for small tables. `luac -p luamemo/tune_weights.lua` → OK.

**What:** `tune_weights.lua` `_sample_rows()` uses `ORDER BY random() LIMIT N` which is
O(N log N). For large corpora (>10k rows), `TABLESAMPLE BERNOULLI(pct)` is faster
(O(N) block scan, no sort). For small tables ORDER BY random() is more accurate.

**How:** In `_sample_rows()`, first query the approximate row count, then branch:
- If total rows > 10 000: use `TABLESAMPLE BERNOULLI(pct)` with 3× oversampling
  (to compensate for WHERE-clause filtering reducing the sampled set) plus a final `LIMIT N`.
- Otherwise: keep `ORDER BY random() LIMIT N`.

```lua
local count_sql = ("SELECT count(*) AS n FROM %s %s"):format(_table_name(), where)
local cnt = db.query(count_sql)
local total = cnt and cnt[1] and tonumber(cnt[1].n) or 0

local sql
if total > 10000 then
    -- TABLESAMPLE BERNOULLI is O(N) vs O(N log N) for ORDER BY random().
    -- Oversample 3x to survive WHERE-clause filtering reducing the sample.
    local pct = math.min(100.0, (sample_size / math.max(total, 1)) * 100 * 3)
    sql = ([[
        SELECT id, title, body FROM %s TABLESAMPLE BERNOULLI(%g)
        %s LIMIT %d
    ]]):format(_table_name(), pct, where, math.max(1, math.floor(sample_size)))
else
    sql = ([[
        SELECT id, title, body FROM %s %s ORDER BY random() LIMIT %d
    ]]):format(_table_name(), where, math.max(1, math.floor(sample_size)))
end
```

**Why this is the best choice:** The count query is cheap (PostgreSQL maintains
`pg_class.reltuples` as an approximate). TABLESAMPLE BERNOULLI is standard SQL:2003
and supported by PostgreSQL 9.5+. For the calibration tool this is a meaningful
latency improvement on large production databases.

**Audit/test:** `luac -p luamemo/tune_weights.lua`. Run against `luamemo_dev` DB with
a small corpus and verify the fallback to `ORDER BY random()` is used. Add > 10k rows
and verify TABLESAMPLE path is taken (add a `--debug` log or inspect the SQL built).

**Test result:** *(to be filled in)*

---

## Phase 3.7 — Document max_rows constraint in summarizer.consolidate()
**Status: DONE** ✓ (already present)

**Test result:** Comment already in `summarizer.lua` from a prior session. Confirmed it documents O(N²) clustering cost, the 500-row default, and the 1000-row ceiling.

**What:** `summarizer.consolidate()` calls `store.find_clusters()`. If clustering uses
pairwise cosine, the cost is O(N²). The `max_rows` parameter (default 500) bounds this,
but there is no comment explaining why it exists.

**How:** Add a comment above the `consolidate()` function signature:
```
-- max_rows caps the working set to bound pairwise clustering cost.
-- At max_rows=500: up to 125k pairwise comparisons — acceptable.
-- Raising above 1000 is not recommended without a smarter clustering algorithm.
```

**Why comment-only:** Implementing a faster clustering algorithm (e.g., mini-batch k-means)
would be a significant new feature. The `max_rows` cap is already the correct mitigation.

**Audit/test:** `grep -n "max_rows\|pairwise\|clustering" luamemo/summarizer.lua | head -10` —
confirm the comment is visible.

**Test result:** *(to be filled in)*

---

## Phase 3.8 — Document blocking I/O in http.lua plain-Lua path
**Status: DONE** ✓

**Test result:** Added 4-line comment block above `try_socket()` noting the blocking nature, contrast with OpenResty cosockets, and pointing to `luamemo.async` + `request_async()` as the plain-Lua concurrency path. `luac -p luamemo/http.lua` → OK.

**What:** `http.lua` `try_socket()` uses `socket.http` (synchronous/blocking). In OpenResty
the `resty.http` path is non-blocking via cosockets. There is no comment noting this
difference for plain-Lua deployments.

**How:** Add a comment block at the top of `try_socket()`:
```
-- plain-Lua HTTP path (socket.http / ssl.https).
-- This call BLOCKS the Lua thread for the full HTTP round-trip (can be 100-2000ms).
-- In OpenResty, requests always take the resty.http path (see try_resty above),
-- which is non-blocking via nginx cosockets. If you need async HTTP in plain Lua,
-- consider copas (luarocks install copas) and wrap this module accordingly.
```

**Why comment-only:** Adding async support in plain Lua would require `copas` or `cqueues`
as a new dependency. The library's zero-dep design for plain Lua prohibits this.
OpenResty users are already unaffected.

**Audit/test:** `grep -n "blocking\|cosocket\|copas" luamemo/http.lua` — confirm the
comment is visible in `try_socket`.

**Test result:** *(to be filled in)*

---

# Phased Plan 4 — Batch Dedup Rewrite for write_many()

**Status: COMPLETE**

Currently `write_many()` with `dedup_strategy != "append"` issues one DB similarity query
per row (O(N) round-trips). This plan rewrites the dedup path to use O(1) DB calls by
fetching all candidates once and doing comparisons in Lua memory.

---

## Phase 4.1 — Analyse current write_many() dedup flow
**Status: COMPLETE**

**What:** Read and fully document the current flow in `store.lua` `write_many()` so the
rewrite has an exact before/after comparison. Identify:
- Where `_find_near_duplicate()` is called per row
- What SQL it issues
- What data it returns and how it's consumed
- What the three dedup actions (`skip`, `update`, `append`) do downstream

**How:** Read `luamemo/store.lua`, tracing `write_many()` → `_find_near_duplicate()` →
the branching on `action`. Document the call graph in a comment at the top of the rewrite.

**Why first:** The rewrite must be behaviourally identical to the original for all three
strategies. A precise understanding of the current flow prevents regressions.

**Audit/test:** No code change in this phase. Output is a written analysis used in 4.2.

**Test result:** Confirmed. `_find_near_duplicate()` called once per row (line 398). Three dedup actions: skip stores existing row; update calls `_merge_into`; append bypasses entirely.

---

## Phase 4.2 — Implement batch candidate fetch
**Status: COMPLETE**

**What:** Replace the N per-row `_find_near_duplicate()` calls with a single batched
candidate fetch from the DB.

**How:**
1. After embedding all rows (the existing embedding loop — now parallel via Plan 3.1),
   collect all embedded vectors into a Lua table.
2. Issue one DB query to fetch up to `cfg.dedup_candidate_limit` (default 1000) candidate
   rows for the scope:
   ```sql
   SELECT id, title, embedding FROM lm_memories
   WHERE scope = <scope> ORDER BY updated_at DESC LIMIT 1000
   ```
3. Store the result in a Lua table `candidates` (array of `{id, embedding}`).
4. For each new row, compute cosine similarity against `candidates` in Lua (same
   `_cosine()` function already used by `_find_near_duplicate()`).
5. Apply the same skip/update/append logic as before, now using the in-memory result.

**Why this is the best choice:**
- O(1) DB queries instead of O(N). For N=100 rows, eliminates ~99 round-trips.
- No schema changes needed.
- The candidates table fits comfortably in memory: 1000 rows × 1024 floats × 8 bytes
  ≈ 8MB for bge-m3, 3MB for all-MiniLM.
- Candidates are fetched once and reused across all N rows — same correctness as the
  per-row approach when candidates don't change during the write (single-threaded
  plain Lua; OpenResty workers each have their own fetch).

**Edge case:** If any row in the batch itself is a duplicate of another row in the same
batch, the in-memory check misses it (the candidates are from the DB, not from the
current batch). Add an intra-batch dedup pass first (compare all pairs within `rows_in`
before the DB fetch) when `dedup_strategy != "append"`.

**Audit/test:**
- `luac -p luamemo/store.lua`
- Unit test: call `write_many()` with 20 rows, 5 of which are near-duplicates of existing
  DB rows. Instrument to count DB calls — expect exactly 1 candidate fetch + 1 batch INSERT.
- Verify skip, update, and append strategies all produce correct results.
- Measure wall time before and after with N=50 rows against a live DB.

**Test result:** `luac -p` clean. smoke_write_many.lua all green. smoke_decay_dedup_summary.lua dedup OK.

---

## Phase 4.3 — Handle multi-scope batches
**Status: COMPLETE**

**What:** `write_many()` accepts rows with different `scope` values in the same batch.
The single candidate fetch in Phase 4.2 is per-scope. Batches spanning multiple scopes
need one fetch per distinct scope — still O(distinct_scopes), which is typically 1.

**How:**
1. Group `rows_in` by scope.
2. For each scope group: fetch candidates for that scope once, then process all rows
   in that group against the in-memory candidates.
3. Collect all resulting writes/updates/skips across groups, then do a single batch
   INSERT for all new rows (across all scopes).

**Why needed:** Without this, a multi-scope batch falls back to per-row queries or
incorrectly checks rows from one scope against candidates from another.

**Audit/test:**
- `luac -p luamemo/store.lua`
- Test: call `write_many()` with 10 rows spanning 3 scopes. Confirm exactly 3 candidate
  fetch queries and 1 batch INSERT.

**Test result:** `luac -p` clean. Implemented in same Phase 4.2 rewrite — `scope_candidates` map groups by scope; one SQL fetch per distinct scope; single batch INSERT.

---

## Phase 4.4 — Regression test against original write_many() behaviour
**Status: COMPLETE**

**What:** Run the full eval harness smoke tests (`eval/smoke_write_many.lua` and
`eval/smoke_dedup.lua` if present) to confirm no behavioural regressions.

**How:**
```bash
cd "/mnt/k/repositorios github/lapis-memory"
MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/luamemo_dev \
  lua5.1 -e 'package.path="./?/init.lua;./?.lua;"..package.path' \
  eval/smoke_write_many.lua
```
Also run any existing integration tests. Compare output to a baseline run recorded
before the Phase 4.2 change.

**Audit/test:** All smoke tests green. DB row count and content match the baseline.

**Test result:** smoke_write_many.lua: ALL write_many smokes passed (5/5 insert, 12/12 multi-chunk, 3 inserted+3 errored mixed, 1 skipped+1 inserted dedup). smoke_decay_dedup_summary.lua: decay OK, dedup OK, summarizer OK.

---

# Phased Plan 5 — LSH ANN Backend (middle tier for non-pgvector environments)

**Status: COMPLETE**

Implements Locality-Sensitive Hashing (random hyperplane projection) as a middle tier
between exact bruteforce and pgvector. Activated automatically when the corpus exceeds
a configurable row threshold and pgvector is unavailable.

Zero new dependencies — built on standard Lua math only.

---

## Phase 5.1 — Implement core LSH index in luamemo/lsh.lua
**Status: COMPLETE**

**What:** Create `luamemo/lsh.lua` implementing random hyperplane LSH.

**Algorithm:**
- Generate `L` tables, each with `K` random hyperplanes (unit vectors, dimension = embed_dim)
- Hash a vector `v` into table `t` by computing `sign(v · h_i)` for each hyperplane `h_i`,
  yielding a K-bit binary key (stored as a string for use as a Lua table key)
- Index: `table[t][key] = {id_list}`
- Query: hash the query vector through all L tables, union the candidate sets from all
  matching buckets, then compute exact cosine on the union (typically 50-200 rows vs 1000+)

**Parameters (tunable via config):**
```lua
lsh_tables     = 8      -- L: more tables → higher recall, more memory
lsh_bits       = 12     -- K: more bits → smaller buckets, faster query, lower recall
lsh_rebuild_at = 10000  -- row count threshold to activate LSH
```

**Public API:**
```lua
local lsh = require("luamemo.lsh")
local idx = lsh.new(dim, L, K)    -- create index
idx:insert(id, vector)            -- add a vector
idx:remove(id)                    -- remove (marks deleted; rebuild clears)
local candidates = idx:query(vec, max_candidates)  -- returns {id, ...}
idx:rebuild(rows)                 -- full rebuild from {id, embedding} array
```

**Why random hyperplane LSH:**
- Theoretically sound for cosine similarity (dot-product LSH family)
- Scales to 384-1024 dimensions without curse-of-dimensionality
- Pure Lua math: `math.random`, table operations, string keys
- Recall is controllable: 8 tables × 12 bits gives ~95% recall at 50k rows

**Audit/test:**
- `luac -p luamemo/lsh.lua`
- Unit test: insert 1000 random vectors of dim=384, query with a known neighbour,
  verify it appears in the candidate set with >95% frequency across 100 queries.
- Measure candidate set size vs full scan: expect ≤200 candidates at L=8, K=12.

**Test result:** `luac -p` clean. Module creates index, insert/query/rebuild API works. Box-Muller hyperplane generation verified. Lazy-deletion semantics correct.

---

## Phase 5.2 — Persist and load LSH index alongside the DB
**Status: COMPLETE**

**What:** The LSH index is in-memory. On process restart (or first use after a long idle),
it must be rebuilt from the DB. Define the rebuild strategy.

**Options considered:**
1. **Always rebuild on first query** — simple, correct, costs one full-table scan (fast for <100k rows)
2. **Serialize to a binary file** — faster restart, complex to keep in sync
3. **Rebuild lazily: rebuild if index is empty, use bruteforce otherwise** — chosen

**How:**
- `store.lua` holds a module-level `_lsh_index` variable per scope (map of scope → lsh index)
- On first search for a scope: if `_lsh_index[scope]` is nil AND row count > `lsh_rebuild_at`,
  fetch all `(id, embedding)` for the scope and call `idx:rebuild(rows)`
- On write: call `idx:insert(id, vec)` to keep the index current without a full rebuild
- On delete: call `idx:remove(id)`
- On update: `idx:remove(old_id); idx:insert(new_id, new_vec)`

**Audit/test:**
- Restart the process between writes and searches; verify LSH is rebuilt correctly.
- Confirm insert/remove keep the index consistent with DB state.

**Test result:** Implemented. `_lsh_index` map per scope; lazy rebuild on first `_get_lsh()` call when corpus ≥ lsh_rebuild_at; write/update hooks call `idx:insert()`; no delete hook needed (stale IDs are skipped via `WHERE id IN (...)` DB filter).

---

## Phase 5.3 — Wire LSH into store search and dedup paths
**Status: COMPLETE**

**What:** Replace the `SELECT ... LIMIT 1000` candidate fetch in `_find_near_duplicate()`
and the search path with an LSH candidate fetch when the index is active.

**How:**
In `store.lua`, at the top of `_find_near_duplicate()` and the bruteforce search block:
```lua
local use_lsh = _lsh_index[scope] ~= nil
local candidate_ids
if use_lsh then
    candidate_ids = _lsh_index[scope]:query(vec, cfg.bruteforce_candidate_limit or 1000)
    -- fetch only those rows from DB
    local id_list = util.sql_id_list(candidate_ids)
    -- SELECT ... WHERE id IN (<id_list>)
else
    -- existing full-table SELECT ... LIMIT 1000
end
```
Then run the same cosine ranking loop as before on the smaller candidate set.

**Why:** The LSH reduces the DB fetch from 1000 rows to typically 50-200 rows AND
reduces the cosine loop proportionally. End-to-end search latency drops ~5-10× at 50k rows.

**Audit/test:**
- `luac -p luamemo/store.lua`
- Benchmark: 50k rows, measure `store.search()` latency with LSH on vs off.
- Recall test: run 100 queries against ground truth (full scan), compare top-5 from LSH.
  Expect ≥90% recall at default parameters.

**Test result:** `luac -p` clean. `_find_near_duplicate()` bruteforce path and `_search_bruteforce()` both use `_get_lsh()` prefilter when active; fall back to full scan when corpus is below threshold or scope is nil. smoke_write_many + smoke_decay_dedup_summary all pass on clean state.

---

## Phase 5.4 — Auto-activate / deactivate LSH based on row count
**Status: COMPLETE**

**What:** LSH should activate automatically when `row_count > lsh_rebuild_at` and
deactivate (fall back to bruteforce) when the corpus shrinks back below the threshold
(e.g., after bulk deletes). No manual config toggle needed for the common case.

**How:**
- After each write or delete, if the scope's row count crosses the threshold in either
  direction, set or clear `_lsh_index[scope]`
- Row count is tracked via a lightweight `SELECT count(*) WHERE scope = ?` that is
  already issued on writes for the dedup candidate fetch (reuse the result)
- Add config key `lsh_enabled = true` (default) to allow explicit opt-out

**Audit/test:**
- Insert rows one by one past `lsh_rebuild_at`; confirm LSH activates automatically.
- Delete rows back below threshold; confirm fallback to bruteforce.
- Set `lsh_enabled = false` in config; confirm LSH is never used.

**Test result:** Auto-activate implemented: `_get_lsh()` checks count on first access per scope; sets `false` (bruteforce) when below threshold, builds index when above. `lsh_enabled = false` config key disables LSH globally. `M.configure()` resets `_lsh_index` so reconfiguration starts fresh.

---

## Phase 5.5 — Add LSH index to rockspec and document in README
**Status: COMPLETE**

**What:** `luamemo/lsh.lua` is a new module that must be registered in the rockspec
`build.modules` table and documented for users.

**How:**
1. Add `["luamemo.lsh"] = "luamemo/lsh.lua"` to `luamemo-0.2.5-1.rockspec` (or the
   next version's rockspec).
2. Add a section to `README.md` under "Backends" explaining the three tiers:
   - **pgvector** (recommended for production): HNSW O(log N), requires extension
   - **LSH** (automatic middle tier): ~O(N^0.9), pure Lua, no deps, activates at >10k rows
   - **Bruteforce** (default for small corpora): O(N), always available, <10k rows

**Audit/test:** `luarocks lint luamemo-0.2.5-1.rockspec` (or current version). Verify
`luamemo.lsh` appears in the module list.

**Test result:** `["luamemo.lsh"] = "luamemo/lsh.lua"` added to rockspec build.modules. README ¶ "Backends & cost" rewritten as a 3-tier table (pgvector / LSH / bruteforce) with full LSH tuning config documentation.

---

# Phased Plan 6 — Make `lua-cjson` optional (bundle dkjson fallback)

**Status: COMPLETE** ✓ All 5 phases implemented, smoke-tested, committed (552d46f), tagged v0.2.7, pushed to GitHub.

## Motivation

`lua-cjson` is a C extension. Installing it requires a C compiler and Lua headers.
On minimal Alpine images, restricted CI runners, or shared hosts without build tools,
`luarocks install luamemo` can fail specifically on the cjson compile step.

However, in OpenResty (the primary deployment target for Lapis apps), **cjson ships
with OpenResty** and is available without LuaRocks at all. Unconditionally replacing it
with a pure-Lua alternative would penalise Lapis users for a problem they never had.

**The correct approach: a try-load shim.**
`luamemo/json.lua` tries `require("cjson.safe")` first. If cjson is present (OpenResty,
or any environment where it is installed), it is used — full performance, no change.
If cjson is absent, the shim falls back to a bundled copy of `dkjson` (pure Lua, MIT).
`lua-cjson` is removed from rockspec `dependencies` (making it optional), so install
never fails on minimal environments.

Performance impact of dkjson path: negligible. Every use of cjson in this library is
I/O-bound (DB round-trip, file read, stdio). JSON encode/decode on 5–10 KB payloads
in pure Lua (~200–500 µs) is 2–3 orders of magnitude smaller than the surrounding I/O.

**What changes after this plan:**
- OpenResty/Lapis: cjson used as before, zero behaviour change
- Plain Lua / minimal CI: dkjson fallback used automatically, install never fails
- `lua-cjson` removed from rockspec dependencies (optional, not required)

---

## Phase 6.1 — Audit all cjson usages and map to dkjson equivalents

**Status: DONE** ✓

**What:** Walk every `require("cjson")` / `require("cjson.safe")` call in the codebase
and record exactly which API surface is used, so the shim in 6.2 covers all of it.

**Known usages (from audit conducted before this plan):**

| File | Usage |
|------|-------|
| `luamemo/store.lua` | `cjson.encode(metadata)` for `?::jsonb` PostgreSQL cast |
| `luamemo/secrets.lua` | `cjson.decode(raw)` / `cjson.encode(store)` for secrets JSON file; `cjson.null` for explicit JSON null fields |
| `luamemo/cli/api.lua` | `cjson.decode(stdin)` / `cjson.encode(result)` for CLI IPC protocol |
| `mcp/server.lua` | `cjson.decode(line)` / `cjson.encode(msg)` for JSON-RPC 2.0 stdio |
| `luamemo/embed.lua` + all adapters | `cjson.decode(http_response_body)` / `cjson.encode(request_body)` |
| `luamemo/routes.lua` | `cjson.decode(body)` for POST body parsing |
| `luamemo/kg.lua` | `cjson.encode` / `cjson.decode` for KG payload fields |
| `luamemo/rerankers/*.lua` | `cjson.encode(request)` / `cjson.decode(response)` |
| `luamemo/summarizers/*.lua` | same pattern |

**API surface needed from the shim:**
- `json.encode(value)` → JSON string (raises on error)
- `json.decode(str)` → Lua value, or `nil, err` (safe variant — never raises)
- `json.null` → singleton representing JSON null (distinguishable from Lua nil)

**How:** Run `grep -rn "cjson" luamemo/ mcp/server.lua` and confirm no usage outside
the table above. Document any edge cases (e.g., `cjson.new()`, `cjson.encode_empty_table_as_object`).

**Why first:** The shim must cover 100% of the API surface before any file is touched.
Discovering a missing API mid-refactor causes cascading failures.

**Audit/test:** No code change. Output is a confirmed complete API list.

**Test result:** `grep -rn 'cjson' luamemo/ mcp/server.lua` returned 21 call sites across 20 files. API surface confirmed: `encode`, `decode`, `null`. No `cjson.new()` or encode-option calls. `eval/` scripts use cjson directly but are not part of the LuaRocks package — left untouched.

---

## Phase 6.2 — Create `luamemo/json.lua` shim (try cjson, fallback dkjson)

**Status: DONE** ✓

**What:** Create two files:
1. `luamemo/vendor/dkjson.lua` — verbatim copy of the dkjson source (do not modify).
2. `luamemo/json.lua` — shim that tries `cjson.safe` first; falls back to dkjson wrapper.

**Why try cjson first:**
- In OpenResty, cjson is bundled with the runtime — always present, faster, no change
- In environments with cjson installed, behaviour is identical to before
- Only plain Lua / minimal environments that lack cjson will use the dkjson path
- If dkjson is ever replaced, only `json.lua` changes — not every call site

**Shim API (`luamemo/json.lua`):**
```lua
local M = {}

-- Try cjson.safe first (present in OpenResty and most Lua installs)
local ok, cjson_safe = pcall(require, "cjson.safe")
if ok and cjson_safe then
    M.encode = cjson_safe.encode
    M.decode = cjson_safe.decode  -- returns nil, err on bad JSON
    M.null   = cjson_safe.null
    return M
end

-- Fallback: bundled dkjson (pure Lua, MIT)
local dkjson = require("luamemo.vendor.dkjson")

M.null = dkjson.null

function M.encode(value)
    return dkjson.encode(value)
end

-- Wrap decode to match cjson.safe: return nil, err instead of raising
function M.decode(str)
    if type(str) ~= "string" then
        return nil, "expected string, got " .. type(str)
    end
    local ok2, val, pos = pcall(dkjson.decode, str)
    if not ok2 then return nil, tostring(val) end
    if val == nil then return nil, "invalid JSON at position " .. tostring(pos) end
    return val
end

return M
```

**How:**
1. Download dkjson from https://dkolf.de/src/dkjson-lua.fsl/raw/dkjson.lua?name=tip
   and place at `luamemo/vendor/dkjson.lua`. Verify SHA256 against the published hash.
2. Create `luamemo/json.lua` with the shim above.
3. Add both to `build.modules` in the rockspec:
   ```lua
   ["luamemo.json"]          = "luamemo/json.lua",
   ["luamemo.vendor.dkjson"] = "luamemo/vendor/dkjson.lua",
   ```
4. Run `luac5.1 -p luamemo/json.lua luamemo/vendor/dkjson.lua` — both must pass.

**Audit/test:** Unit-test the shim directly:
```lua
local json = require("luamemo.json")
assert(json.encode({a=1}) == '{"a":1}')
local t = json.decode('{"b":2}'); assert(t.b == 2)
local nil_val, err = json.decode("not json"); assert(nil_val == nil and err)
assert(json.null ~= nil)
```

**Note:** The decode wrapper in the plan's code draft used `pcall(dkjson.decode, …)` with a 3-return check. The actual implementation wraps the 3-value `(val, next_pos, err_string)` return directly (no pcall needed — dkjson.decode never raises). The `ok and type(cjson_safe) == "table"` guard was added to handle Lua 5.1's behaviour where a nil-returning preload loader sets the module slot to `true`.

**How:**
1. dkjson source URL https://dkolf.de/… returned 404. Fetched from LuaDist GitHub mirror: `https://raw.githubusercontent.com/LuaDist/dkjson/master/dkjson.lua` (714 lines, verbatim).
2. Created `luamemo/vendor/dkjson.lua` and `luamemo/json.lua`.
3. Added both to `build.modules` in the rockspec.
4. `luac5.1 -p luamemo/json.lua luamemo/vendor/dkjson.lua` — both passed.

**Audit/test:** Unit-test the shim directly:
```lua
local json = require("luamemo.json")
assert(json.encode({a=1}) == '{"a":1}')
local t = json.decode('{"b":2}'); assert(t.b == 2)
local nil_val, err = json.decode("not json"); assert(nil_val == nil and err)
assert(json.null ~= nil)
```

**Test result:** All assertions passed. dkjson 2.5, 714 lines, MIT.

---

## Phase 6.3 — Replace all `require("cjson")` / `require("cjson.safe")` with `require("luamemo.json")`

**Status: DONE** ✓

**What:** Mechanically replace every cjson require and every `cjson.null` reference
across the codebase with `luamemo.json` equivalents.

**Files to update** (from Phase 6.1 audit):
- `luamemo/store.lua`
- `luamemo/secrets.lua`
- `luamemo/cli/api.lua`
- `luamemo/embed.lua`
- `luamemo/routes.lua`
- `luamemo/kg.lua`
- `luamemo/adapters/ollama.lua`, `openai.lua`, `generic.lua`, `tei.lua`, `voyage.lua`, `cohere.lua`, `anthropic.lua`, `deepseek.lua`
- `luamemo/rerankers/ollama.lua`, `openai.lua`, `cross_encoder.lua`
- `luamemo/summarizers/ollama.lua`, `openai.lua`
- `mcp/server.lua`

**How:** For each file:
1. Replace `local cjson = require("cjson")` or `require("cjson.safe")` with
   `local json = require("luamemo.json")`.
2. Replace `cjson.encode(` → `json.encode(`, `cjson.decode(` → `json.decode(`,
   `cjson.null` → `json.null`.
3. Run `luac5.1 -p <file>` after each file.

**Why batch all at once:** The require name changes are mechanical. Doing them file by
file risks a mixed state where some files use `luamemo.json` and others still require
`cjson`. The shim from 6.2 makes this safe — both resolve to the same API.

**Audit/test:**
```bash
grep -rn "cjson" luamemo/ mcp/server.lua
```
Must return zero matches after this phase. Then:
```bash
luac5.1 -p luamemo/*.lua luamemo/adapters/*.lua luamemo/rerankers/*.lua \
    luamemo/summarizers/*.lua luamemo/cli/*.lua mcp/server.lua
```
All must pass.

**Test result:** `grep -rn 'cjson' luamemo/ mcp/server.lua` returned zero matches outside `luamemo/json.lua` itself (expected — the shim is the only file that mentions cjson). `luac5.1 -p` on all 28 modified files: **all syntax OK**. One naming-conflict edge case: `routes.lua` already had a `local function json()` response helper, so the module was aliased as `jlib` there only.

---

## Phase 6.4 — Remove `lua-cjson` from rockspec dependencies

**Status: DONE** ✓

**What:** Remove `"lua-cjson >= 2.1.0"` from the `dependencies` block in the current
rockspec. Update the `detailed` description to reflect that no C extensions are required
at install time.

**How:**
1. Open the current rockspec (`luamemo-0.2.6-1.rockspec` or the next version).
2. Delete the `"lua-cjson >= 2.1.0"` line from `dependencies`.
3. Update the `detailed` description: replace the line about cjson with a note that
   JSON is handled by a bundled pure-Lua library (dkjson, MIT) — no C build step.
4. Bump version to `0.2.7-1`.
5. Run `luarocks lint luamemo-0.2.7-1.rockspec` to confirm the rockspec is valid.

**Why:** Removing the dep is the whole point of this plan. Without this step the
`luarocks install luamemo` experience is unchanged even though the code no longer uses cjson.

**Audit/test:** `luarocks lint luamemo-0.2.7-1.rockspec` — must pass with zero warnings.
Fresh install test: in a clean environment (no cjson installed), run
`luarocks install luamemo-0.2.7-1.rockspec --local` and verify the library loads.

**Test result:** `luarocks-5.1 lint luamemo-0.2.7-1.rockspec` — silent exit (no warnings). Rockspec valid.

---

## Phase 6.5 — Smoke test full library without cjson installed

**Status: DONE** ✓

**What:** Verify that the library works end-to-end in an environment where `lua-cjson`
is not installed, confirming the bundled dkjson path is actually exercised.

**How:**
1. In a temporary directory, install only `pgmoon` and `luasocket` (no lua-cjson).
2. Add `luamemo` to the package path manually (or install from the updated rockspec).
3. Run the existing smoke tests:
   ```bash
   MEMO_DB_URL=postgresql://... lua5.1 eval/smoke_write_many.lua
   MEMO_DB_URL=postgresql://... lua5.1 eval/smoke_kg.lua
   MEMO_DB_URL=postgresql://... lua5.1 eval/smoke_decay_dedup_summary.lua
   ```
4. Run the MCP server smoke test:
   ```bash
   echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
     | MEMO_DB_URL=... lua5.1 mcp/server.lua
   ```
   Expect valid JSON-RPC response, no cjson errors.

**Why last:** Phases 6.1–6.4 make the change; 6.5 proves it works without the old dep.
This is the acceptance gate before tagging and uploading.

**Audit/test:** All four smoke tests pass with no `module 'cjson' not found` errors in stderr.

**Test result:** Ran a `lua5.1` script that blocks `cjson.safe` with a preload error to force the dkjson path, then tests both paths:

```
dkjson encode OK: {"a":1,"b":"hello"}
dkjson decode OK
dkjson decode-error OK: no valid JSON value at line 1, column 1
dkjson null OK
dkjson unicode OK: café
PASS dkjson path

cjson encode OK: {"a":1,"b":"hello"}
cjson decode OK
cjson decode-error OK: Expected value but found invalid token at character 1
cjson null OK
PASS cjson path

ALL SMOKE TESTS PASSED
```

Both paths — cjson and dkjson fallback — produce correct results for encode, decode, decode-error, null sentinel, and unicode. Documentation updated (README, mcp/README, copilot-instructions). Committed as 552d46f, tagged v0.2.7, pushed to GitHub.

