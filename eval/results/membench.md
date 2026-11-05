# MemBench — retrieval-side recall through luamemo

> Historical record, kept as measured: runs on luamemo 0.3 and the previous (PostgreSQL)
> store, so the reproduce commands are that era's (`MEMO_DB_URL`, `lua5.1`). The current
> numbers, and how to measure them with `memo eval run`, are in
> [eval/README.md](../README.md#results).

[Zhang et al., 2025](https://github.com/import-myself/Membench) ACL 2025 benchmark.
We evaluate retrieval-only recall: for each question, we write all conversation
turns as individual memories, issue `memory.search`, and check whether the
target turn SID appears in the top-K results.

## Methodology

- **Corpus:** `MemData/FirstAgent` — 11 JSON category files, 8,500 questions total.
  Topic-keyed categories (`movie`, `music`, `game`) filtered to `movie` only
  (the standard 8,500-question protocol).
  `RecMultiSession` excluded (cross-session recommendation task).
- **Turn schema:** `{sid = tostring(turn.sid), text = "User: … \nAssistant: …"}`
  from `message_list[i].user` + `message_list[i].assistant`.
- **Storage:** one memory per turn, `metadata.sid = turn.sid`, under scope
  `mb:<embedder>`. Scope wiped before each category run.
- **Search call:** `store.search({ query, scope, limit = 20, tier_min = 0 })`.
  Hit = any returned `metadata.sid` matches `target_sids[q]`.
- **Categories (8,500 total):**

  | Category | N | Avg turns | Type |
  |----------|--:|----------:|------|
  | aggregative | 1000 | 136.6 | role-keyed |
  | comparative | 1000 | 136.8 | role-keyed |
  | conditional | 1000 | 145.4 | role-keyed |
  | highlevel | 500 | 16.1 | role-keyed |
  | highlevel_rec | 500 | 35.5 | role-keyed |
  | knowledge_update | 1000 | 153.3 | role-keyed |
  | lowlevel_rec | 500 | 18.0 | role-keyed |
  | noisy | 500 | 35.8 | topic-keyed (movie) |
  | post_processing | 500 | 35.8 | topic-keyed (movie) |
  | simple | 500 | 35.8 | topic-keyed (movie) |

- **Backend:** `bruteforce` (cosine over Postgres `real[]`), `dedup_enabled=false`.

---

## v0.3.2 — patterns module + score boosts (2026-05)

> **Patterns note:** All runs have `person_name_boost` and `quoted_phrase_boost`
> active (search-time, default `true`). Write-time extraction (`patterns_enabled`)
> is disabled: companion memories lack target SIDs so they only dilute the haystack,
> and with TEI they trigger extra embed calls (~5× runtime overhead). The
> `--patterns` flag exists for ablation studies.

### Hash embedder (`hash`, dim=384, in-process, zero deps)

Full 8,500-question run, ~62 min wall. Output: `eval/results/membench_hash_v032.json`.

| Category | n | R@1 | R@5 | R@10 | MRR |
|----------|--:|----:|----:|-----:|----:|
| aggregative | 1000 | 76.0% | 90.6% | 95.0% | 0.825 |
| comparative | 1000 | 67.0% | 95.3% | 99.2% | 0.786 |
| conditional | 1000 | 28.9% | 61.3% | 78.0% | 0.437 |
| highlevel | 500 | 21.4% | 71.6% | 97.6% | 0.419 |
| highlevel_rec | 500 | 27.0% | 71.8% | 87.2% | 0.466 |
| knowledge_update | 1000 | 55.3% | 89.0% | 94.3% | 0.690 |
| lowlevel_rec | 500 | 59.2% | 78.8% | 93.0% | 0.680 |
| noisy | 1000 | 10.6% | 29.9% | 43.3% | 0.205 |
| post_processing | 1000 | 29.0% | 63.3% | 77.8% | 0.446 |
| simple | 1000 | 41.0% | 77.1% | 83.9% | 0.574 |
| **OVERALL** | **8500** | **42.5%** | **72.7%** | **83.6%** | **0.558** |

Elapsed: **3709 s** (~62 min). Misses: 812.

**Reproduction:**

```bash
MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/lm_bruteforce_test \
  lua5.1 eval/membench_run.lua \
    --embedder hash \
    --out eval/results/membench_hash_v032.json
```

---

### TEI bge-m3 (`tei`, dim=1024, BAAI/bge-m3, GPU)

Full 8,500-question run. Output: `eval/results/membench_tei_bge-m3_v032.json`.

| Category | n | R@1 | R@5 | R@10 | R@20 | MRR |
|----------|--:|----:|----:|-----:|-----:|----:|
| aggregative | 1000 | 96.7% | 100.0% | 100.0% | 100.0% | 0.983 |
| comparative | 1000 | 74.9% | 99.5% | 100.0% | 100.0% | 0.851 |
| conditional | 1000 | 44.1% | 80.6% | 95.0% | 98.7% | 0.600 |
| highlevel | 500 | 53.4% | 99.4% | 100.0% | 100.0% | 0.727 |
| highlevel_rec | 500 | 31.6% | 85.0% | 96.8% | 99.2% | 0.528 |
| knowledge_update | 1000 | 71.5% | 99.6% | 100.0% | 100.0% | 0.832 |
| lowlevel_rec | 500 | 97.0% | 100.0% | 100.0% | 100.0% | 0.984 |
| noisy | 1000 | 25.0% | 49.2% | 68.5% | 88.5% | 0.374 |
| post_processing | 1000 | 46.0% | 79.5% | 91.3% | 95.8% | 0.606 |
| simple | 1000 | 86.5% | 99.6% | 99.8% | 100.0% | 0.925 |
| **OVERALL** | **8500** | **63.0%** | **88.3%** | **94.5%** | **98.0%** | **0.740** |

Elapsed: **28,678 s** (~8 h). Misses: 174 (all in `noisy` 115, `post_processing` 42, `conditional` 13, `highlevel_rec` 4).

**Reproduction:**

```bash
TEI_URL=http://127.0.0.1:8081/embed TEI_DIM=1024 EMBED_TIMEOUT_MS=120000 \
  MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/lm_bruteforce_test \
  lua5.1 eval/membench_run.lua \
    --embedder tei \
    --out eval/results/membench_tei_bge-m3_v032.json
```
