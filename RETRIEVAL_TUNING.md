# Retrieval tuning — getting the most out of luamemo

> **TL;DR:** the biggest cost lever in a memory-backed agent is `K` — how many
> memories go into the prompt. The levers below are ordered by how much they
> move answer quality and prompt size, highest first. Each one exists to make the
> top K trustworthy enough that a smaller K is safe.

---

## Why this matters: prompt size is dominated by K

Every memory-backed turn looks roughly like:

```
prompt = [system] + [conversation] + top_K(memory_search(query)) + [user turn]
```

At ~200 tokens per memory, every result you add costs ~200 prompt tokens on
every turn, for every session:

| K dropped | tokens saved per turn | saved per 1M sessions* |
|---|---|---|
| 10 → 5 | 1,000 | ~$25,000 |
| 10 → 3 | 1,400 | ~$35,000 |
| 10 → 1 | 1,800 | ~$45,000 |

\* ~200 tokens per memory, 10 turns per session, ~$2.50 per 1M input tokens.

**You can't safely drop K unless the top K is trustworthy.** Everything below
serves that.

---

## Priority 1 — use a real embedder

**The biggest single win, by far.** The default `hash` embedder is fast,
deterministic and needs nothing, but it matches words, not meaning: it can't
tell that "car" and "automobile" are related. Any real embedding model — the
in-process GGUF embedder, Ollama, TEI, a hosted API — gains more than every
other change in this document combined. Until you switch, treat the tuning
below as polishing the rim of a shallow bowl.

`memo calibrate` picks the best embedder that works on your machine;
[EMBEDDERS.md](EMBEDDERS.md) covers the choices and the switch
(`memo reembed --all` afterwards).

---

## Priority 2 — scope your writes

`scope` is a hard filter. Memories in the wrong scope are worse than none: they
fill the top K with rows that can't answer.

- One scope per *thing the agent reasons about* — `repo:my-app`,
  `user:me`, `session:<id>` — not one for everything.
- Prefer narrow scopes; search several at once when an answer could be in any
  of them (`memory_search` with `scopes = ["repo:my-app", "user:me"]`, or
  `memo search --scopes repo:my-app,user:me`). Higher-tier memories rank first
  across the set.
- If you keep adding `kind` or `metadata_filter` filters at search time, the
  scope is probably too wide.

This is free. Do it before tuning anything.

---

## Priority 3 — time filters

When the question is about a period ("what did we decide this week?"), say so:
`since` / `until` cut the candidates **before** ranking, so a small K stays
trustworthy.

```bash
memo search "decisions" --scope repo:my-app --since 2026-10-01
```

Over MCP: `memory_search` with `since` / `until` (ISO 8601 or Unix seconds). A
query that merely *mentions* a time ("last week", "in June") already favours
memories from then (`MEMO_TEMPORAL_ALPHA` sets how strongly).

---

## Priority 4 — tune the search blend

Every search blends a vector score and a full-text score:
`MEMO_HYBRID_WEIGHTS='{"vector": 0.7, "fts": 0.3}'` by default. **That blend is
a guess**, and the right one depends on the corpus:

- lots of exact tokens — codes, ids, product names, file names — want more `fts`;
- free-form prose — chat, notes, docs — wants more `vector`.

luamemo measures it for a scope with **no labelling work**: each sampled memory
is searched for by its own title (or the start of its body), at every blend from
1.0 / 0.0 to 0.0 / 1.0, and the report counts how often it comes back first, in
the top 3, 5, 10.

```bash
memo tune-weights --scope repo:my-app
```

```
repo:my-app — 50 memories, each searched for by its title (or the start of its body) at 11 blends, no model calls

vector   fts     R@1     R@3     R@5    R@10    MRR
 0.40   0.60   72.0%   88.0%   92.0%   96.0%  0.812
 0.30   0.70   70.0%   86.0%   90.0%   96.0%  0.793
 ...
 0.70   0.30   62.0%   80.0%   86.0%   94.0%  0.731   ← in force

Best for R@1: vector 0.40 / fts 0.60 — 72.0% (+10.0 points over the blend in force)
Safe K: 3 — the fewest results that still hold the right memory 85% of the time.
Apply it: memo config set MEMO_HYBRID_WEIGHTS '{"fts":0.6,"vector":0.4}'
```

`--samples N` (default 50) and `--metric r_at_1 | r_at_3 | r_at_5 | r_at_10 |
mrr` (what "best" maximises); `--json` for the raw report. Over MCP:
`memory_tune_weights` returns the same report — an agent shows it, and the
person applies it (settings are changed by people).

**Apply it** for every search of the project:

```bash
memo config set MEMO_HYBRID_WEIGHTS '{"fts":0.6,"vector":0.4}'
```

— or for one search: `memo search … --hybrid-weights '{"vector":0.4,"fts":0.6}'`,
or `hybrid_weights` on `memory_search`.

**Safe K** is the smallest K whose recall reaches 85 % at the best blend — the K
an agent can ask for without losing answers.

**Re-run it** after switching embedders, after loading very different content
into the scope, or now and then (it's cheap: searches only, no model calls).

---

## Priority 5 — rerank the top results

If no blend reaches the recall you need, the next lever is a **reranker**: a
second pass that re-scores the hybrid top N against the query.

| Adapter | Cost | Notes |
|---|---|---|
| `noop` | ~zero, in-process | Word overlap between query and memory. A surprisingly strong baseline |
| `learned` | ~zero, in-process | Trained per scope on how memories were used ([README → Learning from use](README.md#learning-from-use)); `memo learn` promotes it only when it beats the current one |
| `ollama` | a local LLM call | Ollama with JSON output (`MEMO_RERANK_MODEL`, default `llama3.2`) |
| `openai` | a hosted LLM call | OpenAI chat completions with JSON output; the key as `{secret:NAME}` in `MEMO_RERANK_HEADERS` |
| `cross_encoder` | a sidecar call | A TEI / Cohere / Jina `/rerank` endpoint |

```bash
memo config set MEMO_RERANK_ADAPTER noop
memo config set MEMO_RERANK_TOP_N 20         # results the reranker sees (a cost cap)
memo config set MEMO_RERANK_ENABLED true     # every search (a call can still turn it off)
```

Or per search: `memo search … --rerank on` / `memory_search` with `rerank: true`.
The search fetches `max(limit, MEMO_RERANK_TOP_N)` candidates, the reranker
reorders them, the result is cut to `limit`. If the reranker fails (network,
malformed answer), the search keeps the hybrid order — it never fails because of
it. Reranked rows carry `rerank_score` (0–1) and `rerank_rank`.

### Measured impact (LongMemEval `_s`, first 50, single-session-user)

| Mode | R@1 | R@5 | R@10 | R@20 | MRR | elapsed |
|---|---|---|---|---|---|---|
| baseline (ollama nomic-embed-text) | 0.560 | 0.760 | 0.800 | 0.860 | 0.648 | 299 s |
| + rerank `noop` | 0.680 | 0.800 | 0.840 | 0.860 | 0.736 | 310 s |

The free `noop` reranker lifted R@1 by **12 points** and MRR by **0.088** at ~4 %
more time. R@20 doesn't move: a reranker only **reorders** the candidates — it
can't recall what the hybrid search missed. For that, improve the embedder or the
blend (priorities 1 and 4).

Reproduce (any scratch database — the runner wipes its own scopes):

```bash
MEMO_DB=bench luajit eval/longmemeval_run.lua --embedder ollama \
    --corpus eval/data/longmemeval_s.json --n 50 --out /tmp/baseline.json
MEMO_DB=bench luajit eval/longmemeval_run.lua --embedder ollama \
    --corpus eval/data/longmemeval_s.json --n 50 \
    --rerank --rerank-adapter noop --rerank-top-n 20 --out /tmp/rerank-noop.json
```

### When to enable it

- You have done priorities 1–4 and the top result is still often wrong.
- You need a better top 1–3 (a single "best answer") without a bigger prompt.
- **`noop` first** (free, often enough), and **not on top of a strong
  embedder**: with bge-m3 the word-overlap pass shuffles good candidates down
  (R@1 −7.5 points measured).

### Cross-encoders — a measured negative result

`cross_encoder` was benched with `bge-m3` embeddings and the `bge-reranker-v2-m3`
reranker (n = 200, `longmemeval_s`):

| Config | R@1 | R@5 | MRR |
|---|---:|---:|---:|
| bge-m3, no rerank | 0.800 | 0.935 | 0.862 |
| bge-m3, rerank `noop`, top 20 | 0.725 | 0.925 | 0.809 |
| **bge-m3 + bge-reranker-v2-m3, top 20** | **0.800** | **0.935** | **0.862** |

**No gain**: the reranker is fine-tuned from the same base as the embedder and
agrees with its order point for point, at +0.43 s per query. A cross-encoder from
a **different** model family (Cohere Rerank, Jina Reranker on top of bge-m3) may
help — not yet measured.

---

## Search cost

Search is **exact** at every size: every vector in the searched scopes is
scored (a float32 scan in LuaJIT), and the full-text index adds its own top
matches. There is no approximate index to tune and no candidate cap that could
hide the right memory. Measured (one scope, 384 dimensions, median of 15
searches):

| Memories in scope | 1,000 | 5,000 | 20,000 | 100,000 |
|---|---|---|---|---|
| search | 3.9 ms | 18.3 ms | 71 ms | 233 ms |

Above ~100,000 memories in one scope, narrower scopes keep searches fast — the
time grows with the memories searched, not with the database.

---

## Lever priority — quick reference

| # | Lever | Impact on answer quality | Effort |
|---|---|---|---|
| 1 | A real embedder | Huge | Medium (`memo calibrate`) |
| 2 | Scope writes properly | Large | Free |
| 3 | `since` / `until` | Large, when the question has a period | Trivial |
| 4 | Tune the blend (`memo tune-weights`) | Medium | Trivial |
| 5 | A reranker | Medium (+12 points R@1 with `noop` on nomic) | Trivial |

Work top-down. Don't tune a lever below one you haven't done yet.
