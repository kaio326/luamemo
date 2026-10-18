---
name: session-memory
description: Load and maintain persistent memory across sessions using luamemo. Teaches the start/end workflow — search context on open, write decisions during work, summarise on close.
---

# Session Memory Workflow

Use this skill when you want to persist knowledge across sessions, resume work
where you left off, or ensure key decisions are not forgotten.

## The rules

<!-- luamemo:core-rules:begin -->
- **Session start:** if your context doesn't already hold the luamemo brief (a
  `=== LUAMEMO ===` block), call `memory_brief` first — it names the project's scope,
  its latest memories, the codebase map and anything waiting for the user.
- **Before answering about earlier work, decisions or this codebase:** call
  `memory_search` (the scope the brief names; several at once with `scopes`). When a
  result carries `facts`, they are authoritative for what is true now — memories may
  repeat an older value.
- **Write as you go:** `memory_write` after a decision (`kind="decision"`), an
  established fact (`kind="fact"`) or a plan (`kind="plan"`), with a title and a body
  that stand on their own. Near-duplicates are merged for you; give importance 3–7
  only to what must stay on top.
- **Code:** when the brief shows a map, use `index_search` / `index_outline` before
  grepping or reading whole files — and still read a file before you edit it.
- **Learning:** when the user corrects you, sets a standing rule or confirms
  something, call `memory_sense` with the recent turns.
- **Secrets:** never ask for a key, token or password in the chat. The user stores
  it with `memo secret-store NAME` in a terminal; you use it through `secret_execute`,
  which fills it in server-side.
- **The user decides:** never approve org pairing codes or knowledge proposals, and
  don't try to change settings — tell the user the `memo` command instead. An `org:`
  scope is a read-only replica: search it, never write to it.
<!-- luamemo:core-rules:end -->

The rest of this skill is the detail behind them.

---

## At session start

1. The brief (from the session-start hook, or `memory_brief`) names the project's
   scope — e.g. `repo:<project-name>` — and its latest memories.
2. Call `memory_search` with a query describing the current task (e.g.
   `"recent decisions [module]"`, `"architecture [module]"`) in that scope.
3. Call `memory_recent` (limit 5–10) if you need more of the latest entries.
4. Briefly announce what relevant prior context was found before proceeding.

---

## During work

- After every **architectural decision**, **bug fix rationale**, **chosen
  pattern**, or **agreed requirement** — call `memory_write`.
- Use `kind="decision"` for choices and trade-offs.
- Use `kind="fact"` for confirmed facts about the codebase or domain.
- `importance` runs 0–10 and defaults to 1 — leave it there for routine notes.
  Give `3`–`7` to things that must stay on top in later sessions; below `0.3` a
  memory is ephemeral (tier 0, hidden from search by default).
- Always use a consistent scope to keep project memories namespaced.

```
memory_write({
  title  = "Session tokens are refreshed by the gateway",
  body   = "Chose to refresh tokens in the API gateway, not in each service: one place to rotate keys.",
  scope  = "repo:myproject",
  kind   = "decision",
  importance = 3
})
```

Several memories at once: `memory_write({ items = [ {…}, {…} ] })` (up to 100).

---

## At session end

1. Call `memory_write` with a brief summary of what was done and what comes next.
   Use `kind="plan"`, `importance=3` so it surfaces at the next session start.
2. If a `session:<uuid>` scope was used for ephemeral notes, call `memory_promote`
   to fold the session rows into the long-term project scope before closing.
3. Call `memory_sense` with the recent turns (`[{role, text}]`, oldest first) so
   memory LEARNS from the session: it detects where the user corrected you, gave a
   standing rule, or confirmed something, and reinforces the memory each signal is
   about. This is how retrieval improves over time — do it whenever the user
   corrects you, not only at the very end. It is idempotent, so re-relaying overlapping
   turns is safe.

---

## Scope conventions

| Scope | When to use |
|-------|-------------|
| `repo:<name>` | Project-specific decisions and facts (most common) |
| `user:<name>` | Personal preferences/notes that follow you across projects |
| `global` | Facts true across all projects (e.g. your preferred tools) |
| `session:<uuid>` | Ephemeral scratch notes for a single session |
| `diary:<agent>` | Agent personal reflections and meta-observations |
| `org:<name>` | Your organization's shared memory — directives (standards) + collective notes. **Read-only** here (a synced replica): search it, never write to it |

**Searching a hierarchy.** `memory_search` accepts `scopes` (a list) as well as a
single `scope`: pass `scopes=["repo:x","user:me","global"]` to search them as one
union — higher-tier memories (e.g. standing rules) surface first. Use this when
what you need could live in the project, your personal notes, or global facts.
If the session brief shows an `org:` line, add that scope (e.g.
`scopes=["repo:x","org:acme"]`) so the org's directives apply to your work;
reinforcing an org memory (`memory_sense`) is fine — it feeds the org's learning.

---

## Organization memory (federation)

If the user's team runs an org central, this machine can join it. Everything you
handle is **public** — there is no password, token or key to type, paste or keep
secret; the device's key is created and kept by luamemo itself.

**Joining (the user is a dev):**
1. Ask the user for two values from their org admin: the central's address (e.g.
   `http://100.64.0.10:8765` — local network / Tailscale only) and its fingerprint
   (`XXXX-XXXX-XXXX-XXXX-XXXX`).
2. Run `memo calibrate --org-url <address> --org-fingerprint <fingerprint>`. It pins
   the central, creates this device's key and asks to pair.
3. It prints a **pairing code** (`XXXX-XXXX`). The user reads that code to their org
   admin (call, chat, in person). You can't approve it — that's the admin's check.
4. Once approved: `memo org sync` (or `memo org pair --wait 180` to wait). Verify with
   `memo org status`.
5. Other projects of the same org: run the same `memo calibrate` there. They share this
   machine's org database (no new pairing); a project that already has memories is
   offered a copy into it (`memo org adopt`). `memo calibrate --role solo` leaves the org.

**Using org memory (dev):** include the `org:` scope in `scopes`; pass `project="<name>"`
to leave out the org knowledge of the org's other projects. With each push luamemo
*proposes* filtered project knowledge (proven by use, grounded in the code, nothing
personal or secret) — the org admin approves or rejects it. `memo org proposals` lists
what was proposed, `memo org proposals candidates --explain` shows what would be and why
the rest isn't; if the user wants a memory kept to themselves: `memo org proposals private
<id>`. Nothing is proposed in `MEMO_ORG_SHARE=signals` mode.

**Running the org central (the user is the admin):**
1. `memo calibrate --role org --org-name <name>` — prints the central's fingerprint and
   the exact join command for devs (safe to share).
2. `memo serve --host <LAN / Tailscale IP>` — keep it running.
3. `memo org directives <docs-path> --source <project> --project <project>` per project's
   standards, and `memo org directives <path>` for org-wide ones (re-run when they change).
   The central memory is built this way, on request — nothing is ingested automatically.
4. Per dev: `memo org devs pending`, then approve **only after the dev reads the same
   code**: `memo org devs approve <CODE>`. Never approve a code the user hasn't confirmed
   with the dev — the code comparison is the security check. Junk in the queue:
   `memo org devs clear-pending` — only when the admin asks for it.
5. Knowledge proposals: `memo org review` (and `show <id>`) — you may summarise the queue
   for the admin, but run `approve` / `reject` / `remove` only for the items the admin
   decided, never on your own judgement.
6. Schedule `memo org aggregate` (e.g. hourly).

If the session brief says the device isn't paired, a sync failed, or pairing requests /
proposals await the admin, tell the user which step is theirs.

---

## Codebase map (index_* tools)

luamemo can also hold a **map of the codebase** — every file, and the symbols
(functions, classes, methods) defined in each — so you can locate code without
grepping or reading whole files. The map is separate from memories: it lives in
`codeindex:<project>` scopes and is reached through the `index_*` tools.

**Workflow:**

1. **At session start** — call `index_status`. It tells you whether a map exists
   and how big it is. If it reports "No codebase map", the project has not been
   indexed (the user can build one with `memo index ingest`); fall back to normal
   file reading.
2. **Before searching the codebase** — call `index_search` with what you are
   looking for (e.g. `"where is dedup handled"`, `"http retry logic"`). It returns
   compact `path:line  name (type) — doc` lines. Jump straight to that location
   instead of grepping the whole repo.
3. **Before editing a file** — call `index_outline` with the file path to see
   everything defined in it (names, line numbers, one-line docs) in one compact
   response, instead of reading the entire file.
4. **Before refactoring** — call `index_explore` with a symbol to see its blast
   radius: what depends on it (callers) and what it depends on (callees).
5. **After you change code** — suggest the user run `memo index update` so the
   map reflects the edit.

**Ground-truth rule:** the map tells you *where* code is and *what* is there — it
does not replace reading the current file before you edit it. The map can lag
recent edits; always read the actual file region on disk before modifying it.

The map costs nothing until you query it, and each query is far cheaper than a
grep-and-read loop — prefer it whenever you need to find or orient in code.

---

## Facts that change over time

Some values change — a team rule, a version, who leads a team. People (and their
scripts) record those as knowledge-graph facts with `memo kg assert`. You don't
need a separate tool: `memory_search` results include `facts` — the current value
of what your query is about, since when, and the value it replaced. **When a fact
is present, it is authoritative for what is true now**; memories may still repeat
an older value. You can't record facts yourself; if one should change, tell the
user the `memo kg assert … --supersede` command.

---

## Maintenance (when the user asks)

Self-maintenance usually runs on its own (calibrate turns it on), so these are
for when the user asks:

| Tool | Use |
|---|---|
| `memory_digest`, `memory_consolidate` | Tidy a scope: promote proven memories, group related ones, expire decayed ones. `dry_run=true` first |
| `memory_summarize` | Fold old, low-weight memories into summaries. `dry_run=true` first |
| `memory_learn` | The scope's learned reranker: `run` (promoted only if it beats the current one), `status`, `rollback` |
| `memory_tune_weights` | Measure the best vector / full-text blend for a scope. Show the report — applying it is the user's `memo config set` command |
| `memory_embed` | Check how similar two phrasings are to the embedder (`compare_to`) |
| `memory_delete` with `scope` (+ `kind` / `metadata_filter`) | Bulk delete: the first call only previews — show the user the count and titles, and send the `confirm` token only when they agree |

Settings can't be changed through these tools: `memory_status` with
`details=true` shows them; the user changes them with `memo config set`.

---

## Tips

- **Search before writing**: run `memory_search` with the current task as query
  before writing a new fact — you may already have stored the answer.
- **Map before grepping**: if `index_status` shows a map exists, reach for
  `index_search`/`index_outline` before shell search or reading files — it is the
  cheaper path to the same answer.
- **Tiers**: 0 ephemeral, 1 working, 2 consolidated, 3 core. A new memory's tier
  follows its importance (`< 0.3` → 0, `< 5` → 1, `< 9` → 2, else 3); use and
  maintenance raise it later. Search and recent hide tier 0 unless you pass `tier_min=0`;
  `tier_min=2` keeps only consolidated and core memories when you want reliable
  answers only.
- **Dedup**: `memory_write` checks the scope for a near-identical memory and, by
  default, merges into it instead of adding a copy — no need to check before
  writing (`dedup_strategy="append"` keeps both).
- **Secrets**: never ask the user to type a key or token in the chat. They store
  it with `memo secret-store NAME` in a terminal; you use it through
  `secret_execute`, which fills in `{secret}` server-side.
