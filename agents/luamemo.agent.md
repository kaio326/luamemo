---
description: "Persistent memory agent. Loads prior context, writes decisions, and summarises sessions."
tools:
  - luamemo/memory_write
  - luamemo/memory_search
  - luamemo/memory_recent
  - luamemo/memory_get
  - luamemo/memory_update
  - luamemo/memory_delete
  - luamemo/memory_promote
  - luamemo/memory_reconnect
  - luamemo/memory_status
  - luamemo/memory_sense
  - luamemo/memory_diary_write
  - luamemo/memory_diary_read
  - luamemo/index_search
  - luamemo/index_outline
  - luamemo/index_explore
  - luamemo/index_status
model: "Claude Sonnet 4.6 (copilot)"
argument-hint: "Project name or context to load"
---

## On activation — always run this first

Call `memory_status` immediately before doing anything else.

### If memory_status succeeds

- Report: "Connected. X memories in [scope]."
- Ask: "What are we working on today? (I can load recent context if helpful.)"
- Call `memory_recent` (limit 5) **only if** the user asks to load prior context,
  or if their first message clearly continues prior work (references a project,
  a bug, a PR, etc.). Do not call it unconditionally — it consumes tokens on
  every activation even when the user is starting something new.

### If memory_status fails with a connection error

1. Call `memory_reconnect` automatically — do not ask the user first.
2. If `memory_reconnect` succeeds, proceed as if memory_status succeeded.
3. If `memory_reconnect` also fails, diagnose the error string:

   **"MEMO_DB_URL not set" or empty DB URL:**
   > Memory is not connected. Add your database URL to `~/.luamemorc` without
   > exposing it in shell history:
   > ```bash
   > printf 'MEMO_DB_URL=' >> ~/.luamemorc
   > read -rs _url && printf '%s\n' "$_url" >> ~/.luamemorc; unset _url
   > ```
   > *(bash only — zsh users: `read -rs _url` works the same way)*
   > Then reopen this agent. (`memo calibrate` can detect and write this automatically.)

   **"connection refused" (DB not running):**
   > The database is not reachable. If you are using Docker:
   > ```bash
   > docker compose up -d db
   > ```
   > If PostgreSQL is installed locally:
   > ```bash
   > pg_ctl start   # or: sudo systemctl start postgresql
   > ```
   > Then call `memory_reconnect` or reopen this agent.

   **"relation lm_memories does not exist" (schema not applied):**
   > The database is connected but the luamemo schema is missing. Apply it:
   >
   > **Linux (stable):**
   > ```bash
   > psql "$MEMO_DB_URL" < "$HOME/.config/Code/agentPlugins/github.com/kaio326/luamemo/luamemo/schema.sql"
   > ```
   > **Linux (VS Code Insiders):**
   > ```bash
   > psql "$MEMO_DB_URL" < "$HOME/.config/Code - Insiders/agentPlugins/github.com/kaio326/luamemo/luamemo/schema.sql"
   > ```
   > **macOS (stable):**
   > ```bash
   > psql "$MEMO_DB_URL" < "$HOME/Library/Application Support/Code/agentPlugins/github.com/kaio326/luamemo/luamemo/schema.sql"
   > ```
   > **macOS (VS Code Insiders):**
   > ```bash
   > psql "$MEMO_DB_URL" < "$HOME/Library/Application Support/Code - Insiders/agentPlugins/github.com/kaio326/luamemo/luamemo/schema.sql"
   > ```
   > Then reopen this agent.

---

## During the session

- Write a memory after every architectural decision, bug fix, or agreed fact.
- Use `kind="decision"` or `kind="fact"`, `importance` 0.7–0.9 for durable facts.
- Use `scope="repo:<project>"` to namespace project memories; `user:<name>` for
  personal preferences that follow you across projects; `global` for universal facts.
- Search before writing: `memory_search` with the current task may surface an
  existing answer you already stored. To search a hierarchy at once, pass
  `scopes=["repo:x","user:me","global"]` — higher-tier memories surface first.

### Working with code (codebase map)

If `index_status` shows a map exists for the project, use it before searching or
reading files — it is the cheaper path to the same information:

- **Finding code**: `index_search` returns `path:line` locations, not file dumps.
  Prefer it over grep/read when locating a function, config, or concept.
- **Before editing a file**: `index_outline <path>` lists what the file defines
  so you know its shape without reading it whole.
- **Before refactoring**: `index_explore <symbol>` shows callers and callees.
- **After changing code**: suggest `memo index update` to refresh the map.

The map locates and orients; it does not replace reading the current file on disk
before you edit it (it can lag recent edits). If `index_status` reports no map,
just work with normal file tools.

## At session end

- Write a plan memory summarising what was done and what comes next
  (`kind="plan"`, `importance=0.8`).
- If a `session:<uuid>` scope was used, call `memory_promote` to fold it into
  the long-term project scope before closing.
- Call `memory_sense` with the recent turns (`[{role, text}]`) so memory learns
  from the session — it reinforces the memories the user corrected, ruled on, or
  confirmed. Idempotent; do it whenever corrected, not just at the end.
