# Importance & decay scoring

`luamemo` weights search results by a per-row `importance` and an
optional `decay_rate`. This makes recent, important memories outrank stale
or low-value ones automatically — without any client-side filtering.

## The math

For every candidate row at search time:

```
weight = importance * exp(-decay_rate * days_since_updated)
score  = (vector_weight * vec_score + fts_weight * fts_score) * weight
```

| Field | Range | Default | Notes |
|---|---|---|---|
| `importance` | 0..10 | 1.0 | Static multiplier; higher = more pull. |
| `decay_rate` | 0..1 per day | 0.0 | Exponential decay; 0 disables it. |

`days_since_updated` is computed from `updated_at`, so editing a memory
also resets its decay clock.

## Picking a decay rate

Pick by half-life:

| Decay rate | Half-life | Use case |
|---|---|---|
| 0.005 | ~138 days | "Big architectural decisions" — slow forgetting |
| 0.05  | ~14 days  | "This sprint's facts" |
| 0.1   | ~7 days   | "Last week's working state" |
| 0.5   | ~1.4 days | "Today's scratchpad" |
| 1.0   | ~17 hours | "Aggressive — drops out within a day" |

Math: `half_life_days = ln(2) / decay_rate`.

## End-to-end recipe (HTTP)

Assumes you've completed the 5-minute setup in the project root README and
have an embedder configured.

```bash
export MEMO_URL=http://localhost:8080/api/memory
export MEMO_TOKEN=your-token

# 1. Three memories, same body, different weights
curl -sS -X POST "$MEMO_URL/write" \
  -H "Authorization: Bearer $MEMO_TOKEN" -H "Content-Type: application/json" \
  -d '{"scope":"demo","title":"low",  "body":"how to deploy", "importance":1}'

curl -sS -X POST "$MEMO_URL/write" \
  -H "Authorization: Bearer $MEMO_TOKEN" -H "Content-Type: application/json" \
  -d '{"scope":"demo","title":"med",  "body":"how to deploy", "importance":5}'

curl -sS -X POST "$MEMO_URL/write" \
  -H "Authorization: Bearer $MEMO_TOKEN" -H "Content-Type: application/json" \
  -d '{"scope":"demo","title":"high", "body":"how to deploy", "importance":10}'

# 2. Search returns them ordered high → med → low
curl -sS "$MEMO_URL/search?q=deploy&scope=demo" \
  -H "Authorization: Bearer $MEMO_TOKEN" | jq '.results[] | {title, importance, weight, score}'

# 3. Same query with decay disabled returns them by raw similarity (≈ tied)
curl -sS "$MEMO_URL/search?q=deploy&scope=demo&ignore_decay=1" \
  -H "Authorization: Bearer $MEMO_TOKEN" | jq '.results[] | {title, score}'
```

## End-to-end recipe (CLI)

```bash
export MEMO_URL=http://localhost:8080/api/memory
export MEMO_TOKEN=your-token

memo write --scope demo --title low  --body "how to deploy" --importance 1
memo write --scope demo --title med  --body "how to deploy" --importance 5
memo write --scope demo --title high --body "how to deploy" --importance 10

memo search "deploy" --scope demo
```

> Note: `memo write` may need the `--importance` / `--decay-rate` flags
> wired up in your `cli/memo` script depending on its version. The HTTP
> API always accepts them.

## End-to-end recipe (MCP / Claude Desktop)

The `memory_write` and `memory_update` tools accept optional `importance`
and `decay_rate` params; `memory_search` accepts `ignore_decay`. Just ask
the agent in plain English:

> "Save this as an important architectural decision (importance 8) that
> shouldn't decay much."

The model will pass the right arguments.

## Verifying the math

The weight expression evaluated by Postgres is:

```sql
importance * exp(-decay_rate * (EXTRACT(EPOCH FROM (now() - updated_at)) / 86400.0))
```

Quick sanity check:

```sql
SELECT title, importance, decay_rate,
       ROUND((importance * exp(-decay_rate *
              (EXTRACT(EPOCH FROM (now() - updated_at))/86400.0)))::numeric, 4) AS weight
FROM lm_memories
ORDER BY weight DESC
LIMIT 20;
```

Expected behaviour:

- `importance=5, decay_rate=0,   any age`     → weight = 5.0000
- `importance=5, decay_rate=0.1, age=30 days` → weight ≈ 0.2489 (= 5·e⁻³)
- `importance=5, decay_rate=0.5, age=10 days` → weight ≈ 0.0337 (= 5·e⁻⁵)
