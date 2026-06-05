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

---

## Scope conventions

| Scope | When to use |
|-------|-------------|
| `repo:<name>` | Project-specific decisions and facts (most common) |
| `global` | Facts true across all projects (e.g. your preferred tools) |
| `session:<uuid>` | Ephemeral scratch notes for a single session |
| `diary:<agent>` | Agent personal reflections and meta-observations |

---

## Tips

- **Search before writing**: run `memory_search` with the current task as query
  before writing a new fact — you may already have stored the answer.
- **Tier hint**: newly written memories default to tier 1 (working). Memories
  promoted via `memory_promote` move to tier 3 (core). Use `tier_min=2` in
  search to filter to consolidated + core memories when you want reliable answers
  only.
- **Dedup**: `memory_write` deduplicates against recent memories in the same
  scope. Near-duplicate content is silently skipped — you do not need to check
  before writing.
