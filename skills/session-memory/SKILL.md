---
name: session-memory
description: Load and maintain persistent memory across sessions using luamemo. Teaches the start/end workflow — search context on open, write decisions during work, summarise on close.
---

# Session Memory Workflow

Use this skill when you want to persist knowledge across sessions, resume work
where you left off, or ensure key decisions are not forgotten.

---

## At session start

1. Call `memory_search` with a query describing the current project or task
   (e.g. `"recent decisions [project name]"`, `"architecture [module]"`).
   Use the project scope: `scope="repo:<project-name>"`.
2. Call `memory_recent` (limit 5–10) to surface the latest stored entries.
3. Briefly announce what relevant prior context was found before proceeding.

---

## During work

- After every **architectural decision**, **bug fix rationale**, **chosen
  pattern**, or **agreed requirement** — call `memory_write`.
- Use `kind="decision"` for choices and trade-offs.
- Use `kind="fact"` for confirmed facts about the codebase or domain.
- Set `importance` to `0.7–0.9` for things that must survive to the next session.
  Use `0.5` for useful-but-disposable observations.
- Always use a consistent scope to keep project memories namespaced.

```
memory_write({
  body   = "Chose pgmoon over luadbi: pgmoon is pure-Lua and ships in LuaRocks",
  scope  = "repo:myproject",
  kind   = "decision",
  importance = 0.8
})
```

---

## At session end

1. Call `memory_write` with a brief summary of what was done and what comes next.
   Use `kind="plan"`, `importance=0.8` so it surfaces at the next session start.
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

**Searching a hierarchy.** `memory_search` accepts `scopes` (a list) as well as a
single `scope`: pass `scopes=["repo:x","user:me","global"]` to search them as one
union — higher-tier memories (e.g. standing rules) surface first. Use this when
what you need could live in the project, your personal notes, or global facts.

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

## Tips

- **Search before writing**: run `memory_search` with the current task as query
  before writing a new fact — you may already have stored the answer.
- **Map before grepping**: if `index_status` shows a map exists, reach for
  `index_search`/`index_outline` before shell search or reading files — it is the
  cheaper path to the same answer.
- **Tier hint**: newly written memories default to tier 1 (working). Memories
  promoted via `memory_promote` move to tier 3 (core). Use `tier_min=2` in
  search to filter to consolidated + core memories when you want reliable answers
  only.
- **Dedup**: `memory_write` deduplicates against recent memories in the same
  scope. Near-duplicate content is silently skipped — you do not need to check
  before writing.
