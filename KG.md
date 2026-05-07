# Knowledge-graph layer (`luamemo.kg`)

> Status: Phase 16.5 — shipped 2026-05-04. Adjunct to the vector memory
> table. Not a replacement.

## Why a KG layer?

Vector memory answers "what is *similar* to this query?". That's the
wrong shape for two important question types:

1. **Directive memory** — *"What is the current CSP rule for inline
   styles?"*. The latest answer must override older ones; vector
   search will happily return a 2-year-old superseded rule that
   happens to be more cosine-similar.
2. **Entity memory** — *"What is user 42's preferred theme?"*. The
   value changes between sessions and we need the *currently valid*
   value, not the *most-similar-looking* one.

The KG layer stores `(subject, predicate, object)` triples with a
**bitemporal validity window** (`valid_from`, `valid_until`). Queries
default to *currently valid* rows, which is the right answer for both
of the patterns above. Cost is one indexed SQL lookup — no embedding
call, no rerank.

This is intentionally *not* a full RDF / SPARQL graph. There are no
inferences, no transitive closures, no ontology. It is a fact store
with time semantics, deliberately scoped to the patterns vector
search handles poorly.

---

## Schema

Migration: [`luamemo/migrations/003_kg.sql`](luamemo/migrations/003_kg.sql)

```sql
CREATE TABLE lm_kg_facts (
    id               BIGSERIAL PRIMARY KEY,
    scope            TEXT        NOT NULL,
    subject          TEXT        NOT NULL,
    predicate        TEXT        NOT NULL,
    object           TEXT        NOT NULL,
    valid_from       TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_until      TIMESTAMPTZ,                          -- NULL = currently valid
    source_memory_id BIGINT      REFERENCES lm_memories(id) ON DELETE SET NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT lm_kg_facts_validity_window
        CHECK (valid_until IS NULL OR valid_until >= valid_from)
);

-- Indexes
CREATE INDEX lm_kg_facts_scope_idx   ON lm_kg_facts (scope);
CREATE INDEX lm_kg_facts_sp_idx      ON lm_kg_facts (subject, predicate);
CREATE INDEX lm_kg_facts_current_idx ON lm_kg_facts (subject, predicate)
                                     WHERE valid_until IS NULL;     -- hot path
```

`scope` mirrors `luamemo.scope` semantics — every query is
implicitly scope-filtered, so multi-tenant deployments cannot leak
across tenants.

`source_memory_id` is the optional back-reference to the
`luamemo` row that asserted this fact (e.g. the chat message or
summary that contained it). `ON DELETE SET NULL` means deleting a
memory does **not** delete the derived facts — useful for audit but
worth knowing if you expect cascading cleanup.

---

## Validity-window semantics

Every fact has a half-open interval `[valid_from, valid_until)`.

- **`valid_until IS NULL`** — the fact is currently valid.
- **Closed interval** — the fact was valid during that window only.

Three query modes are supported:

| `query` arg                        | Returns                                                          |
| ---------------------------------- | ---------------------------------------------------------------- |
| *(default)*                        | Rows where `valid_until IS NULL`. Hot path, uses partial index. |
| `at = <timestamp>`                 | Rows where `valid_from <= at < valid_until` (or `valid_until IS NULL`). |
| `include_invalidated = true`       | All rows, no validity filter. Useful for audit / debugging.     |

**`assert_fact{... supersede = true}`** is the convenience flow for
entity-state updates: it `UPDATE`s the currently-valid row's
`valid_until` to the new fact's `valid_from`, then inserts the new
row in one logical step.

**`invalidate{...}`** is the standalone version: it just closes the
currently-valid row(s) without inserting a replacement. Use this for
"the rule no longer applies" scenarios where there is no successor.

---

## API

All functions return `value, nil` on success or `nil, "error message"`
on failure. Every function takes one table argument so call-sites stay
self-documenting.

### `kg.assert_fact{ scope, subject, predicate, object, ... }`

Insert a new fact.

```lua
local row, err = memory.kg.assert_fact({
    scope     = "user:42",
    subject   = "user:42",
    predicate = "theme",
    object    = "dark",
    -- optional:
    valid_from       = "2025-01-01T00:00:00Z",  -- nil = now()
    source_memory_id = 1234,                    -- nil = no back-ref
    supersede        = true,                    -- close prior open row first
})
```

### `kg.query{ scope, subject?, predicate?, object?, at?, include_invalidated?, limit? }`

Read facts. `subject` / `predicate` / `object` are all optional
filters; `scope` is mandatory.

```lua
-- "What is currently true?"
local rows = memory.kg.query({
    scope = "user:42", subject = "user:42", predicate = "theme",
})
-- -> { { object = "light", valid_from = ..., valid_until = nil, ... } }

-- "What was true on 2025-04-01?"
local rows = memory.kg.query({
    scope = "user:42", subject = "user:42", predicate = "theme",
    at = "2025-04-01T00:00:00Z",
})
```

`limit` defaults to 100, capped at 1000.

### `kg.invalidate{ scope, subject, predicate, object?, at? }`

Close all currently-valid rows matching the filter. Returns the count.

```lua
local n = memory.kg.invalidate({
    scope = "team:eng", subject = "csp", predicate = "inline_styles_allowed",
})
```

### `kg.timeline{ scope, subject, predicate }`

Full chronological history for one (subject, predicate) pair.

```lua
local rows = memory.kg.timeline({
    scope = "user:42", subject = "user:42", predicate = "theme",
})
-- -> { dark[t1..t2], light[t2..nil] }
```

---

## HTTP routes

All routes live under the same `prefix` you passed to
`memory.routes.register(app, { prefix = "/api/memory" })`:

| Method | Path             | Body / params                                                                                  |
| ------ | ---------------- | ---------------------------------------------------------------------------------------------- |
| POST   | `/kg/assert`     | `scope`, `subject`, `predicate`, `object`, `valid_from?`, `source_memory_id?`, `supersede?`    |
| GET    | `/kg/query`      | `scope`, `subject?`, `predicate?`, `object?`, `at?`, `include_invalidated?`, `limit?`          |
| POST   | `/kg/invalidate` | `scope`, `subject`, `predicate`, `object?`, `at?`                                              |
| GET    | `/kg/timeline`   | `scope`, `subject`, `predicate`                                                                |

All routes go through the same `auth_fn` / `before_request` gate as
the rest of the memory routes.

> **No MCP tool is provided** for the destructive write paths
> (`assert`, `invalidate`). Same reasoning as the summarizer: an LLM
> with the `kg/assert` tool would happily spam contradictory facts
> the moment a user said "actually, never mind". Keep it human-driven
> or driven by app code that has explicit invalidation logic.

---

## Recipes

### Recipe 1 — Directive memory ("the CSP rule for inline styles")

```lua
local kg = require("luamemo").kg

-- Day 1: the rule allows inline styles.
kg.assert_fact({
    scope = "team:eng", subject = "csp",
    predicate = "inline_styles_allowed", object = "true",
    source_memory_id = some_chat_message_id,
})

-- 6 months later: the rule changes. Supersede the prior assertion.
kg.assert_fact({
    scope = "team:eng", subject = "csp",
    predicate = "inline_styles_allowed", object = "false",
    source_memory_id = newer_chat_message_id,
    supersede = true,
})

-- An LLM agent assembling a system prompt asks: "what's the current rule?"
local cur = kg.query({
    scope = "team:eng", subject = "csp",
    predicate = "inline_styles_allowed",
})
-- -> [{ object = "false", valid_from = "2025-07-01...", valid_until = nil }]
-- The agent injects "inline styles are forbidden" into the prompt.

-- Auditor asks: "when did this change?"
local history = kg.timeline({
    scope = "team:eng", subject = "csp",
    predicate = "inline_styles_allowed",
})
-- -> [ true (2025-01-01..2025-07-01), false (2025-07-01..nil) ]
```

### Recipe 2 — Entity memory ("user 42's preferred theme")

```lua
-- User toggles dark mode in settings.
kg.assert_fact({
    scope = "user:42", subject = "user:42",
    predicate = "theme", object = "dark",
    supersede = true,    -- close any prior theme assertion
})

-- Later: user toggles back.
kg.assert_fact({
    scope = "user:42", subject = "user:42",
    predicate = "theme", object = "light",
    supersede = true,
})

-- On every page load: fetch the current theme.
local rows = kg.query({
    scope = "user:42", subject = "user:42", predicate = "theme",
})
local theme = rows[1] and rows[1].object or "light"
```

---

## When to use vector memory vs. KG

| Question shape                                      | Use                                            |
| --------------------------------------------------- | ---------------------------------------------- |
| "What did we discuss about X?"                      | Vector memory (`memory.search`)                |
| "Find the email about the renovation invoice"       | Vector memory                                  |
| "What is currently true about Y?"                   | KG (`kg.query`)                                |
| "What was the rule about Z on date D?"              | KG (`kg.query{ at = ... }`)                    |
| "Show me how user X's preference changed over time" | KG (`kg.timeline`)                             |
| Open-ended summary / synthesis                      | Vector memory + summarizer                     |
| Latest authoritative value, no synthesis            | KG                                             |

When in doubt: if the *latest* answer must beat the *most similar*
answer, use the KG.

---

## Reproducing the smoke test

```bash
cd luamemo

# Reset DB and apply migrations
docker exec -i <postgres-container> psql -U postgres -c \
  'DROP DATABASE IF EXISTS lm_bruteforce_test; CREATE DATABASE lm_bruteforce_test;'
docker exec -i <postgres-container> psql -U postgres -d lm_bruteforce_test \
  < luamemo/schema_bruteforce.sql
docker exec -i <postgres-container> psql -U postgres -d lm_bruteforce_test \
  < luamemo/migrations/003_kg.sql

# Run the 6-test suite
PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=lm_bruteforce_test \
  PGUSER=postgres PGPASSWORD=postgres \
  lua5.1 eval/smoke_kg.lua
```

Expected output: `All Phase 16.5 KG smoke tests passed.`
