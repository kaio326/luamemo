<!-- The guidance the MCP server sends every client (`instructions`, in initialize and
server/discover) — the fallback for clients without luamemo's skill, agent or hooks.
HTML comments are not sent. The core-rules block is kept identical in
skills/session-memory/SKILL.md and agents/luamemo.agent.md (a test fails when they
drift): change it here, then copy it there. Keep it short — clients put it in every
session's context. -->
luamemo is this project's persistent memory: decisions, facts and plans from earlier
sessions, and a map of the codebase.

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

If a tool answers that luamemo has no database, tell the user what it says to do.
