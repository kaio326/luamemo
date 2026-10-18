# Knowledge graph — facts that change over time

Memories answer *"what is similar to this?"*. Some questions need *"what is true
now?"* — the current value of something that changes: a team rule, a preference,
the version a service runs. Search can't settle those: a two-year-old rule that
was superseded may well be the most similar match.

luamemo keeps such values as **facts**: `(subject, predicate, object)` triples,
each valid over a time window. A query returns the facts valid now (or at a time
you name); asserting a new value can close the old one, so the history stays and
the current answer is unambiguous. A lookup costs one indexed query — no
embedding call, no rerank.

It is a fact store with time semantics, deliberately small: no inference, no
ontology, no SPARQL. It sits beside the memories; it doesn't replace them.

---

## Validity windows

Every fact is valid over `[valid_from, valid_until)`. An empty `valid_until`
means the fact holds now.

| Query | Returns |
|---|---|
| *(default)* | the facts valid now |
| `at = T` | the facts valid at time T |
| `include_invalidated = true` | every fact, closed ones included (audit) |

- **assert with `supersede`** — for a value that changes: closes the
  currently valid fact of that subject + predicate at the new fact's
  `valid_from`, then records the new one.
- **invalidate** — closes the currently valid fact(s) without a successor
  ("this rule no longer applies").
- **timeline** — the whole history of one subject + predicate, oldest first.

Every fact belongs to a scope, like memories: a query never sees another scope's
facts. A fact may point at the memory it came from (`source_memory_id`);
deleting that memory keeps the fact and clears the reference.

Times are ISO 8601 (`2025-07-01T00:00:00Z`) or Unix seconds.

---

## Writing facts — `memo kg` (people and their scripts)

```bash
memo kg assert --subject csp --predicate inline_styles_allowed --object false \
    --supersede --scope team:eng
memo kg invalidate --subject csp --predicate inline_styles_allowed --scope team:eng
```

`assert` takes `--valid-from T` (default: now), `--source-memory ID` and
`--supersede`; `invalidate` takes `--object O` (close only that value) and
`--at T` (default: now). `--scope` defaults to `MEMO_SCOPE`. Output is JSON
(`{"ok": true, "fact": {…}}`); the exit status is 1 on failure.

**Agents can't write facts.** There is deliberately no MCP tool for `assert` or
`invalidate`. This was measured: an agent (llama3.1:8b, 12 scripted
conversations in which facts are stated, changed and corrected, then 16
questions in a fresh session) answered half the questions wrong when it could
write facts, and left stale facts marked valid. Write facts from your own
scripts or by hand, where the invalidation logic is explicit.

---

## How agents see facts — inside `memory_search`

There is no separate fact tool on MCP. Every `memory_search` (and `memo search`)
also returns the facts its question is about: the currently valid facts of the
searched scopes whose subject or predicate words appear in the query (words are
compared lowercased, `payments_team` as "payments team", a plural "s" ignored),
up to three, each with when it took effect and the value it replaced:

```json
"facts": [
  { "subject": "payments_team", "predicate": "tech_lead", "value": "Bruno",
    "since": "2026-09-30 …", "scope": "repo:acme",
    "previous": { "value": "Ana", "until": "2026-09-30 …" } }
]
```

The tool's description tells the agent that facts, when present, are
authoritative for what is true now — memories may still repeat an older value.
A search of no particular scope looks at every scope's facts except the code
maps' (`codeindex:`).

**Why this shape — measured** (2026-10-10). One project memory of 555 entries:
400 unrelated notes, and per topic the conversation's memories plus ten older
notes repeating the old value — what a project's history looks like. 16
questions about values that changed; facts recorded as `memo kg assert
--supersede` would. Correct answers:

| | Gemma 4 e4b | llama3.1:8b | Claude Sonnet |
|---|---|---|---|
| search only | 60 % | 44 % | 16/16 |
| a separate `memory_facts` tool | 60 % | 60 % | 16/16 |
| facts inside the search results | **94 %** | **77 %** | 16/16 |

Small models almost never called a separate fact tool — and when they did, they
guessed names (`payments team` for `payments_team`) and found nothing. Facts
inside the search reach them without asking, and with no facts recorded the
search behaves exactly as before. Claude widened its searches and compared dates,
so it answered right every way at this size; facts save it that work as the
history grows.

## Reading facts from a terminal

```bash
memo kg query --subject csp --scope team:eng                 # valid now
memo kg query --subject csp --at 2025-04-01T00:00:00Z --scope team:eng
memo kg query --subject csp --include-invalidated --scope team:eng
memo kg timeline --subject csp --predicate inline_styles_allowed --scope team:eng
memo context "inline styles" --scope team:eng                # search + facts in one block
```

The MCP `session_start` prompt also lists a scope's current facts as ground
truth for the agent.

---

## Recipes

### A rule that changes ("may we use inline styles?")

```bash
# January: allowed.
memo kg assert --subject csp --predicate inline_styles_allowed --object true \
    --valid-from 2025-01-01T00:00:00Z --scope team:eng

# July: forbidden — supersede closes the January fact at July 1st.
memo kg assert --subject csp --predicate inline_styles_allowed --object false \
    --valid-from 2025-07-01T00:00:00Z --supersede --scope team:eng

memo kg query --subject csp --scope team:eng
#   → object "false", valid from 2025-07-01, no valid_until
memo kg query --subject csp --at 2025-04-01T00:00:00Z --scope team:eng
#   → object "true",  valid 2025-01-01 … 2025-07-01
memo kg timeline --subject csp --predicate inline_styles_allowed --scope team:eng
#   → true (2025-01-01 … 2025-07-01), false (2025-07-01 … now)
```

### A preference ("which theme does user 42 use?")

```bash
memo kg assert --subject user:42 --predicate theme --object dark  --supersede --scope user:42
memo kg assert --subject user:42 --predicate theme --object light --supersede --scope user:42
memo kg query  --subject user:42 --predicate theme --scope user:42   # → light
```

---

## Memories or facts?

| Question | Use |
|---|---|
| "What did we discuss about X?" | memories (`memory_search`) |
| "Find the note about the renovation invoice" | memories |
| "What is currently true about Y?" | facts (they come with `memory_search`) |
| "What was the rule about Z on date D?" | facts (`memo kg query --at`) |
| "How did X's preference change over time?" | facts (`memo kg timeline`; a search shows the previous value) |
| Open-ended summary or synthesis | memories (+ the summarizer) |

If the *latest* answer must beat the *most similar* one, it is a fact.

---

## Storage

Facts live in the project's database (the same SQLite file as its memories), in
`lm_kg_facts`; times are integer microseconds since the Unix epoch:

```sql
CREATE TABLE lm_kg_facts (
    id               INTEGER PRIMARY KEY,
    scope            TEXT NOT NULL,
    subject          TEXT NOT NULL,
    predicate        TEXT NOT NULL,
    object           TEXT NOT NULL,
    valid_from       INTEGER NOT NULL,
    valid_until      INTEGER,                 -- NULL: valid now
    source_memory_id INTEGER REFERENCES lm_memories (id) ON DELETE SET NULL,
    created_at       INTEGER NOT NULL,
    CHECK (valid_until IS NULL OR valid_until >= valid_from)
);
CREATE INDEX lm_kg_facts_scope_idx   ON lm_kg_facts (scope);
CREATE INDEX lm_kg_facts_sp_idx      ON lm_kg_facts (subject, predicate);
CREATE INDEX lm_kg_facts_current_idx ON lm_kg_facts (subject, predicate) WHERE valid_until IS NULL;
```

`memo export` / `memo import` carry a scope's facts along with its memories (a
fact keeps its link to the memory it came from). The codebase index also records
its dependency edges here (`memo index explore` walks them).

---

## Tests

The knowledge graph is covered by `eval/tests/test_features.lua` (semantics),
`test_surfaces.lua` (`memo kg`, and the facts `memory_search` returns) and `test_golden.lua`:

```bash
luajit eval/tests/run.lua --only features,surfaces,golden
```
