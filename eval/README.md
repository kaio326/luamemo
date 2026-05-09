# luamemo eval harness

Quantify how well luamemo retrieves the right session against the
[LongMemEval](https://huggingface.co/datasets/xiaoyangwu/longmemeval)
benchmark (Lin et al., 2024). The harness runs with plain `lua5.1` — no
OpenResty or Lapis runtime required. All PostgreSQL access goes through
`luamemo.db`, which falls back to a direct pgmoon connection when
`ngx` is absent.

## What it measures

- **Recall@k** for k ∈ {1, 5, 10, 20}: a question is a "hit" at k when
  any of its `answer_session_ids` appears in the top-k retrieved sessions.
- **MRR** (Mean Reciprocal Rank).
- Per `question_type` breakdown: `multi-session`, `single-session-user`,
  `single-session-preference`.

## Files

| File | Purpose |
|---|---|
| `longmemeval_run.lua` | Main eval entry point. Ingest + query loop; writes a JSON result file. |
| `datasets/longmemeval.lua` | Pure-Lua dataset loader + session→memory flattener. |
| `score.lua` | Reads a result JSON file, prints R@k / MRR table. |
| `recall_bench.lua` | Synthetic recall benchmark (hash vs. HTTP embedder head-to-head). |
| `_resty_http_shim.lua` | LuaSocket-backed `resty.http` shim. Preloaded by eval scripts so `luamemo.http`'s `resty.http` path works in plain Lua. |
| `sidecars/` | Docker Compose file + docs for the TEI GPU sidecars (bge-m3 embedder, bge-reranker-v2-m3). |
| `results/longmemeval.md` | Full phase-by-phase results, reproduce commands, and analysis. |

> **`_smoke_lapis_db.lua`** is a legacy file kept for reference only.
> No current eval script uses it — `luamemo.db` now handles the
> pgmoon path internally using `PGHOST` / `PGDATABASE` / `PGUSER` /
> `PGPASSWORD` env vars when `ngx` is absent.

## Quick start

### Prerequisites

```bash
# PostgreSQL reachable at 127.0.0.1:5432 with a test database
PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test PGUSER=postgres PGPASSWORD=postgres \
  psql -c "SELECT 1"

# Apply the bruteforce schema (one-time)
PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test PGUSER=postgres PGPASSWORD=postgres \
  psql < luamemo/schema_bruteforce.sql

# Dataset (longmemeval_s.json, ~266 MB)
# Download from HuggingFace if not present:
# https://huggingface.co/datasets/xiaoyangwu/longmemeval
```

### Run with the hash embedder (zero GPU, ~1 min for n=50)

```bash
cd /path/to/luamemo

PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test PGUSER=postgres PGPASSWORD=postgres \
  lua5.1 eval/longmemeval_run.lua --embedder hash \
    --corpus eval/data/longmemeval_s.json --n 50 \
    --out eval/results/smoke_hash.json

lua5.1 eval/score.lua eval/results/smoke_hash.json
```

### Run with Ollama (nomic-embed-text, ~12 min for n=200)

```bash
PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test PGUSER=postgres PGPASSWORD=postgres \
  OLLAMA_MODEL=nomic-embed-text OLLAMA_DIM=768 \
  lua5.1 eval/longmemeval_run.lua --embedder ollama \
    --corpus eval/data/longmemeval_s.json --n 200 \
    --out eval/results/longmemeval_ollama_s_n200.json
```

### Run with bge-m3 via TEI GPU sidecar (~25 min for n=200)

```bash
# Bring up both TEI sidecars (requires NVIDIA GPU + Docker with GPU access)
docker compose -f eval/sidecars/docker-compose.yml up -d

# Wait for both sidecars to be ready
docker compose -f eval/sidecars/docker-compose.yml logs tei-embed | grep -m1 Ready
docker compose -f eval/sidecars/docker-compose.yml logs tei-reranker | grep -m1 Ready

# Run
PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test PGUSER=postgres PGPASSWORD=postgres \
  TEI_URL=http://127.0.0.1:8081/embed TEI_DIM=1024 \
  lua5.1 eval/longmemeval_run.lua --embedder tei \
    --corpus eval/data/longmemeval_s.json \
    --out eval/results/longmemeval_tei_bge-m3_s.json
```

See [sidecars/tei.md](sidecars/tei.md) for sidecar setup and resource requirements.

## CLI flags (`longmemeval_run.lua`)

| Flag | Default | Purpose |
|---|---|---|
| `--embedder` | _(required)_ | `hash`, `ollama`, `tei`, `openai` |
| `--corpus` | _(required)_ | Path to `longmemeval_s.json` |
| `--out` | _(required)_ | Output JSON path |
| `--n` | all | Cap to N questions (for smoke runs) |
| `--k-max` | `20` | Max candidates to retrieve per question |
| `--rerank` | off | Enable reranker pass |
| `--rerank-adapter` | `noop` | `noop`, `ollama`, `openai`, `cross_encoder` |
| `--rerank-top-n` | `20` | Candidates passed to the reranker |
| `--sweep-weights` | off | Comma-separated vector weights (e.g. `"0.25,0.5,0.75"`) |

Environment variables used:

| Var | Purpose |
|---|---|
| `PGHOST` / `PGDATABASE` / `PGUSER` / `PGPASSWORD` | PostgreSQL connection (read by `luamemo.db`) |
| `OLLAMA_URL` / `OLLAMA_MODEL` / `OLLAMA_DIM` | Ollama embedder config |
| `TEI_URL` / `TEI_DIM` / `TEI_MODEL` | TEI embedder config |
| `RERANK_URL` / `RERANK_MODEL` / `RERANK_API_KEY` | Cross-encoder reranker config |
| `EMBED_MAX_CHARS` | Truncate session bodies at this length (default 6000) |
| `INGEST_BATCH_SIZE` | INSERT chunk size for `write_many` (default 50) |
| `INGEST_MODE=perrow` | Fall back to per-row `write` loop (A/B speedup measurement) |

## Benchmark results summary

Full analysis in [results/longmemeval.md](results/longmemeval.md).

| Embedder | n | R@1 | R@5 | R@10 | R@20 | MRR | Phase |
|---|---|---|---|---|---|---|---|
| hash (in-process, lexical) | 200 | ~40% | ~60% | ~70% | ~80% | ~0.50 | — |
| nomic-embed-text 768d (Ollama) | 200 | 62.0% | 81.5% | 87.5% | 92.5% | 0.706 | 15.3 |
| bge-m3 1024d (TEI), n=200 slice | 200 | 80.0% | 93.5% | 96.5% | 99.5% | 0.862 | 16.1 |
| **bge-m3 1024d (TEI), full corpus** | **500** | **87.0%** | **96.4%** | **98.6%** | **99.6%** | **0.913** | **17.2** |

Key observations:

- **The embedder is the dominant accuracy lever.** Switching
  `nomic-embed-text` → `bge-m3` adds +14.9 pp R@5 (n=500) with zero
  other changes.
- **Full-corpus results are more representative.** The n=200 slice
  contained only 3 of 6 question types, all on the harder end. At
  n=500, `single-session-assistant` (100% R@5) and `knowledge-update`
  (100% R@5) lift the overall mean, reaching parity with LLM-summarisation
  pipelines that report ~96.6% R@5 on the same benchmark.
- **Cross-encoder reranking with same-family models adds nothing.** When
  the bi-encoder (`bge-m3`) and the reranker (`bge-reranker-v2-m3`) share
  the same model family, the reranker agrees with the bi-encoder ordering
  and produces no measurable recall improvement (Phase 16.3).
- **Rerank=noop regresses R@1.** The `noop` adapter retrieves `top_n=20`
  before the pass; with a stronger embedder the extra candidates introduce
  ordering noise. Recommended: no reranker with bge-m3.
- **3 misses in 500** (all outside top-20). One persistent `single-session-user`
  truncation case; two in `temporal-reasoning`. These are the hard ceiling
  for the current single-stage retrieval path.

## Notes & limitations

- Decay weighting is bypassed in eval (`ignore_decay = true`) so all
  candidates are scored on raw hybrid similarity.
- Dedup is disabled; every haystack session must land as its own row.
- Each question gets its own scope (`lme:<embedder>:<question_id>`) so
  rows are isolated across questions and across embedder runs.
- ~30–40 sessions per full run fail with
  `ERROR: invalid byte sequence for encoding "UTF8"` from pgmoon on
  corpus rows with mixed-encoding bytes. Failed sessions are skipped;
  recall numbers are over the surviving population.
