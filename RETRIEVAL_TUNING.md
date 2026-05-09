# Retrieval Tuning — How to Get the Most Out of `luamemo`

> **TL;DR:** the biggest cost lever in any memory-backed agent is `K`
> (how many memory rows you stuff into the prompt). The work below is
> ordered by how much it actually moves agent answer quality and prompt
> token spend — top to bottom, highest impact first.

---

## Why this matters: token cost is dominated by K

Every memory-backed agent turn looks roughly like:

```
prompt = [system] + [conversation] + top_K(memory.search(query)) + [user_turn]
```

If your average memory row is ~200 tokens, every `K` you add costs
~200 prompt tokens *every single turn, every single user, forever*.

| K dropped | tokens saved / turn | $ saved per 1M sessions* |
|-----------|---------------------|--------------------------|
| 10 → 5    | 1,000               | ~$25,000                 |
| 10 → 3    | 1,400               | ~$35,000                 |
| 10 → 1    | 1,800               | ~$45,000                 |

\* assumes ~200 token/row, 10 turns/session, ~$2.50 per 1M input tokens.

**You can't safely drop K unless your top-K is trustworthy.** Everything
below is in service of making top-K trustworthy enough that you can ship
with a smaller K.

---

## Priority 1 — use a real embedder

**Biggest single win, by far.**

The default `embedder_local = "hash"` is fast, deterministic, and
dependency-free, but it is essentially keyword matching with extra
steps. It does not capture semantic similarity. If you have any room
in your stack for a real embedding model (a small sentence-transformer,
an OpenAI/Voyage/Cohere embedding endpoint, etc.) you will gain more
accuracy by switching the embedder than from any other change in this
document.

Until you switch off `hash`, treat all the tuning below as
"polishing the rim of a shallow bowl."

---

## Priority 2 — scope your writes properly

`scope` is a hard filter. Two memories in the wrong scope are worse
than no memories at all, because they fill up your top-K with
irrelevant rows.

Rules of thumb:

- One scope per *concept the agent reasons about*, not one scope per
  user. A user can have memories across many scopes.
- Prefer narrow scopes (`user_42:billing_history`) over wide scopes
  (`user_42:all`).
- If you find yourself adding lots of `kind` or `tags` filters at
  read-time, that is a smell that the scope is too wide.

This is free. Do this before you tune anything.

---

## Priority 3 — tune `hybrid_weights`

`hybrid_weights = { vector = 0.7, fts = 0.3 }` is the library default.
**That number is a guess.** The right blend is corpus-specific:

- Corpora with lots of named-entity / exact-token hits (codes, IDs,
  product names, SKUs) want more `fts`.
- Corpora that are mostly free-form prose (chat, notes, docs) want
  more `vector`.

The library ships a runner that figures out the right blend
empirically, with **zero labeling work** — your existing rows are the
gold pairs (leave-one-out self-retrieval).

### How to run it

```bash
# Local Postgres pointing at your real (or test) database:
PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=mydb PGUSER=postgres \
  lua5.1 eval/tune_weights.lua --scope <your_scope>
```

Optional flags:

- `--samples N` — how many rows to sweep (default: 50).
- `--primary r_at_1 | r_at_3 | r_at_5 | r_at_10 | mrr` — which
  metric to optimize for (default: `r_at_1`).

### How to read the output

```
blend(v/f)   R@1     R@3     R@5     R@10    MRR
 0.4 / 0.6   72.0%   88.0%   92.0%   96.0%   0.812
 0.3 / 0.7   70.0%   86.0%   90.0%   96.0%   0.793
 0.7 / 0.3   62.0%   80.0%   86.0%   94.0%   0.731   <-- default
 ...
```

The columns are **Recall@K** — what fraction of the time the
"correct" row landed in the top-K results. Higher is better.

The recommendation block at the bottom tells you:

1. The best blend.
2. How much it gains over the default.
3. The smallest K where R@K ≥ 85% — i.e. the smallest K you can ship
   without losing answers.
4. The dollar amount that K reduction saves you per 1M sessions.

### How to apply the result

Set the recommended blend in your `memory.setup({...})`:

```lua
memory.setup({
    -- ...
    hybrid_weights = { vector = 0.4, fts = 0.6 },
})
```

Or, if different scopes have different blends, override per call:

```lua
memory.search({
    query = q,
    scope = "billing_history",
    limit = 5,                     -- the new lower K
    hybrid_weights = { vector = 0.4, fts = 0.6 },
})
```

### When to re-run

- After any major embedder change.
- After you load substantially different content into a scope.
- Periodically (quarterly is plenty for stable corpora).

It is cheap: pure SQL + Lua, no LLM calls.

---

## Priority 4 — rerank the top-N

If `tune_weights` says "no blend reaches R@5 ≥ 85%" on a scope you
care about, the next lever is a **reranker** — a second pass that
takes the top-N candidates from hybrid search and re-scores them
against the query using a smarter (and more expensive) model.

Since v0.2 this is built into `luamemo`. Three adapters ship:

| Adapter  | Cost / latency       | Notes                                    |
|----------|----------------------|------------------------------------------|
| `noop`   | ~zero, in-process    | Lexical token-overlap. Surprisingly strong baseline. No external calls. |
| `ollama` | local LLM, ~1 call   | Calls a local Ollama model with `format=json`; default model `llama3.2`. |
| `openai` | hosted LLM, ~1 call  | Calls OpenAI Chat Completions with `response_format=json_object`. |

### Configure once at setup

```lua
memory.setup({
    -- ...
    rerank_adapter  = "noop",   -- "noop" | "ollama" | "openai"
    rerank_top_n    = 20,       -- candidate pool size before rerank
    rerank_enabled  = false,    -- global default; opt-in per call below
    -- adapter-specific (only needed for ollama / openai):
    rerank_url      = "http://127.0.0.1:11434/api/generate",
    rerank_model    = "llama3.2",
    rerank_headers  = { Authorization = "Bearer ..." },  -- openai
    rerank_timeout_ms = 30000,
})
```

### Opt-in per search

```lua
memory.search({
    query  = q,
    scope  = "billing_history",
    limit  = 5,           -- final K
    rerank = true,        -- overrides cfg.rerank_enabled for this call
})
```

The store over-fetches `max(limit, rerank_top_n)` candidates from the
hybrid pass, hands them to the adapter, and trims to `limit` after
rerank. If the adapter fails (network error, malformed JSON, etc.) the
search **falls back to the baseline ranking** and logs a warning — it
never hard-errors.

Returned rows gain two extra fields:

- `rerank_score` — normalised to [0, 1].
- `rerank_rank`  — 1-based position in the reranked list.

### Measured impact (LongMemEval `_s` first-50, single-session-user)

| Mode                 | R@1   | R@5   | R@10  | R@20  | MRR   | elapsed |
|----------------------|-------|-------|-------|-------|-------|---------|
| baseline (ollama)    | 0.560 | 0.760 | 0.800 | 0.860 | 0.648 | 299 s   |
| `+ rerank=noop`      | 0.680 | 0.800 | 0.840 | 0.860 | 0.736 | 310 s   |

Even the lexical `noop` adapter lifted R@1 by **+12 pts** and MRR by
**+0.088** at ~4 % wall-clock overhead. R@20 is unchanged because rerank
only **reorders** the existing candidate pool — it cannot recall what
hybrid search missed. To improve R@20 you must improve the embedder or
the hybrid blend (Priorities 1 and 3).

Reproduce:

```bash
lua5.1 eval/longmemeval_run.lua --embedder ollama \
    --corpus eval/data/longmemeval_s.json --n 50 \
    --out eval/results/baseline.json

lua5.1 eval/longmemeval_run.lua --embedder ollama \
    --corpus eval/data/longmemeval_s.json --n 50 \
    --rerank --rerank-adapter noop --rerank-top-n 20 \
    --out eval/results/rerank-noop.json
```

### When to enable

- You've exhausted Priorities 1–3 and R@1 is still leaking answers.
- You need a higher-quality top-1/top-3 (e.g. for a single "best answer"
  feed) without expanding the prompt budget.
- Rule of thumb: **`noop` first** (free, often enough). Move to `cross_encoder`
  only if your reranker comes from a **different model family** than your embedder.

### Cross-encoder adapter (`cross_encoder`) — measured negative result

`luamemo/rerankers/cross_encoder.lua` exposes a TEI / Cohere / Jina
`POST /rerank` sidecar as a drop-in reranker. It was benched
(2026-05-06) with `bge-m3` embeddings + `bge-reranker-v2-m3` reranker,
n=200, `longmemeval_s`:

| Config                                   | R@1   | R@5   | MRR   |
|------------------------------------------|------:|------:|------:|
| bge-m3, no rerank (Phase 16.1 baseline)  | 0.800 | 0.935 | 0.862 |
| bge-m3, rerank=noop top_n=20             | 0.725 | 0.925 | 0.809 |
| **bge-m3 + bge-reranker-v2-m3 top_n=20**| **0.800** | **0.935** | **0.862** |

**Result: zero net improvement.** `bge-reranker-v2-m3` is fine-tuned
from the same `bge-m3` base and agrees with bi-encoder ordering
point-for-point. Cross-encoder adds +0.43 s per query overhead with
no quality gain when used with its own-family embedder.

**When cross-encoder IS worth enabling:** pair it with a
*different-family* reranker — e.g. Cohere Rerank v3 or
Jina Reranker v2 on top of `bge-m3` embeddings. Those combinations
are not yet benched; the negative result here is specific to the
same-family `bge-m3` + `bge-reranker-v2-m3` pairing.

---

## Footnote — `bruteforce_candidate_limit` and LSH

The brute-force backend has a `bruteforce_candidate_limit` config knob
(default 5,000) that caps how many rows the in-Lua cosine pass
considers. Tuning this knob is a **latency** decision, not an accuracy
or token-cost decision.

For corpora beyond ~10 000 rows per scope, `luamemo` automatically
activates its built-in **LSH (Locality-Sensitive Hashing) index**
(`luamemo.lsh`) which pre-filters the candidate pool to ≈100–300
rows before cosine ranking, eliminating most of the I/O cost without
changing the scoring or result shape. This is transparent — no config
change needed. You can tune `lsh_rebuild_at` (default 10 000),
`lsh_tables` (default 8), and `lsh_bits` (default 12), or set
`lsh_enabled = false` to opt out.

Beyond LSH, the correct fix for very large corpora is still to install
pgvector (HNSW O(log N)) or to scope writes more narrowly — not to
raise `bruteforce_candidate_limit` and pay the CPU bill on every search.

---

## Lever priority — quick reference

| # | Lever                       | Impact on agent quality | Effort  |
|---|-----------------------------|--------------------------|---------|
| 1 | Real embedder               | Huge                     | Medium  |
| 2 | Scope writes properly       | Large                    | Free    |
| 3 | `since` / `until` filters   | Large (when applicable)  | Trivial |
| 4 | `tune_weights` hybrid blend | Medium                   | Trivial |
| 5 | Reranker (built-in)         | Medium (+12pt R@1 noop)  | Trivial |
| — | `bruteforce_candidate_limit`| Latency only             | n/a     |
| — | LSH (auto at >10k rows)     | Latency only (automatic) | None    |

Work top-down. Don't tune things below something you haven't done yet.

> **Temporal filters first, K second.** When the agent asks "what did
> we discuss this week" it is cheaper and more accurate to pass
> `since = 7 days ago` than to bump K hoping recent rows survive the
> all-time blend. `since` / `until_` shrink the candidate pool BEFORE
> the ANN/FTS rank step, so top-K stays trustworthy at a smaller K.
> See the inline `since` / `until_` args on `memory.search()` and the
> matching HTTP / MCP / CLI surface.
