# Knowledge-graph layer — Phase 16.5

> Historical record (May 2026, luamemo 0.3 on the previous PostgreSQL store; the
> migration and commands named here are that era's). The knowledge graph today:
> [KG.md](../../KG.md).

> 2026-05-04 · `luamemo.kg` shipped. Adjunct to vector memory,
> not a replacement.

## What shipped

- **Migration:** `luamemo/migrations/003_kg.sql`
- **Module:** `luamemo/kg.lua` — `assert_fact{}`, `query{}`,
  `invalidate{}`, `timeline{}`
- **HTTP routes:** `POST /kg/assert`, `GET /kg/query`,
  `POST /kg/invalidate`, `GET /kg/timeline`
- **Smoke test:** `eval/smoke_kg.lua` (6 cases)
- **Docs:** [`luamemo/KG.md`](../../KG.md)

## Smoke-test outcome

| # | Test                                       | Result |
|---|--------------------------------------------|--------|
| 1 | `assert_fact` + currently-valid `query`    | PASS   |
| 2 | `supersede=true` + `timeline` shape        | PASS   |
| 3 | Scope isolation (queries don't leak)       | PASS   |
| 4 | Point-in-time `query{ at = ... }`          | PASS   |
| 5 | Standalone `invalidate` + `include_invalidated` | PASS |
| 6 | Validation errors (missing scope/object)   | PASS   |

```
=== assert_fact + query (currently valid) ===
  inserted id=1 (user:42 theme = dark)
  current = dark OK

=== supersede + timeline ===
  superseded: dark(id=2) -> light(id=3)
  current = light OK
  timeline: dark[invalidated] -> light[open] OK

=== scope isolation ===
  scopes do not leak OK

=== point-in-time query ===
  at=2025-04-01 -> dark OK
  at=2025-08-01 -> light OK

=== explicit invalidate ===
  invalidate -> 0 current, 1 historical OK

=== validation errors ===
  missing object rejected OK
  missing scope rejected OK

All Phase 16.5 KG smoke tests passed.
```

## Why this layer exists

Vector search returns *similar* rows. For two important question
shapes the right answer is the *currently valid* one:

1. **Directive memory** — "what is the current CSP rule for inline
   styles?" — older, superseded rules can still be more
   cosine-similar than the latest one.
2. **Entity memory** — "what is user 42's preferred theme?" — the
   value changes session-to-session and embeddings have no
   notion of "freshness wins ties".

The KG layer answers both with one indexed SQL lookup at the cost
of zero LLM calls. See [`KG.md`](../../KG.md) for the full
decision matrix and end-to-end recipes.

## Reproduction

```bash
cd luamemo
docker exec -i portfolio-db psql -U postgres -c \
  'DROP DATABASE IF EXISTS lm_bruteforce_test; CREATE DATABASE lm_bruteforce_test;'
docker exec -i portfolio-db psql -U postgres -d lm_bruteforce_test \
  < luamemo/schema_bruteforce.sql
docker exec -i portfolio-db psql -U postgres -d lm_bruteforce_test \
  < luamemo/migrations/003_kg.sql
PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=lm_bruteforce_test \
  PGUSER=postgres PGPASSWORD=postgres \
  lua5.1 eval/smoke_kg.lua
```

## Limitations / scope

- No transitive closure, no inferences, no ontology — by design.
- `source_memory_id` is `ON DELETE SET NULL`: deleting a memory does
  **not** cascade-delete derived facts (audit-friendly, but worth
  knowing if you expect cleanup).
- Open-ended search is still vector memory's job — KG is for
  *latest authoritative value* questions only.

## Follow-ups (not on the roadmap, tracked here)

- A small benchmark dataset for "directive supersession" and "entity
  state change" question types would let us quantify how much KG
  beats vector retrieval for those shapes. Today the value is
  qualitative: the API exists and the smoke test proves the
  semantics. Worth doing as part of Phase 16.6's bench expansion.
