# Importance & decay scoring

luamemo weights search results by each memory's `importance` and an optional
`decay_rate`, so recent, important memories outrank stale or low-value ones —
without any filtering on the client's side.

## The math

For every candidate at search time:

```
weight = importance × exp(−decay_rate × days_since_updated)
score  = (vector_weight × vector_score + fts_weight × text_score) × weight
```

| Field | Range | Default | Notes |
|---|---|---|---|
| `importance` | 0–10 | 1.0 | A static multiplier; higher = more pull. It also sets the tier: `< 0.3` → 0 (ephemeral, hidden from search by default), `< 5` → 1, `< 9` → 2, `≥ 9` → 3 |
| `decay_rate` | 0–1 per day | 0.0 | Exponential decay; 0 turns it off |

`days_since_updated` counts from `updated_at`, so editing a memory restarts its
decay clock. The defaults for new memories are settings:
`MEMO_DEFAULT_IMPORTANCE`, `MEMO_DEFAULT_DECAY_RATE`.

## Picking a decay rate

By half-life (`half_life_days = ln(2) / decay_rate`):

| Decay rate | Half-life | Use |
|---|---|---|
| 0.005 | ~138 days | Big architectural decisions — slow forgetting |
| 0.05  | ~14 days  | This sprint's facts |
| 0.1   | ~7 days   | Last week's working state |
| 0.5   | ~1.4 days | Today's scratchpad |
| 1.0   | ~17 hours | Gone from the top within a day |

## End-to-end (CLI)

```bash
memo write --scope demo --title low  --body "how to deploy"         --importance 1
memo write --scope demo --title med  --body "how to deploy the app" --importance 5
memo write --scope demo --title high --body "how to deploy it"      --importance 10 --decay-rate 0.1

memo search deploy --scope demo | jq -c '.results[] | {title, weight, score, tier}'
# {"title":"high","weight":9.99…,"score":9.67…,"tier":3}
# {"title":"med","weight":5,"score":4.45…,"tier":2}
# {"title":"low","weight":1,"score":1,"tier":1}

memo search deploy --scope demo --ignore-decay 1     # raw hybrid scores, for debugging
```

Each result carries its `weight`, so you can check the math: in a month the
`high` memory weighs `10 × e^(−0.1 × 30) ≈ 0.50` and falls below `low`.

## End-to-end (MCP)

`memory_write` and `memory_update` take `importance` and `decay_rate`;
`memory_search` takes `ignore_decay`. Just ask the agent:

> "Save this as an important architectural decision (importance 8) that
> shouldn't decay much."

The model passes the right arguments.

## Expected weights

- `importance = 5, decay_rate = 0`, any age → 5
- `importance = 5, decay_rate = 0.1`, 30 days → ≈ 0.249 (5·e⁻³)
- `importance = 5, decay_rate = 0.5`, 10 days → ≈ 0.034 (5·e⁻⁵)

Faded memories aren't deleted by decay alone: maintenance (`memo consolidate`,
`memory_consolidate`) expires the ones whose weight has fallen below its
threshold, and the summarizer can fold old, light ones into summaries.
