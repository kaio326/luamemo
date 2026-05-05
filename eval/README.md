# lapis-memory eval harness

Quantify how well lapis-memory retrieves the right session against the
[LongMemEval](https://huggingface.co/datasets/xiaoyangwu/longmemeval)
benchmark (Lin et al., 2024). The harness is the only piece in the
project that is not fully self-contained — it needs the published dataset
file and a running pgvector instance.

## What it measures

- **Recall@k** for k ∈ {1, 5, 10}: a question is a "hit" at k when any of
  its `answer_session_ids` appears in the top-k retrieved sessions.
- Per `question_type` breakdown so you can tell where lexical similarity
  shines (single-session-user, IDs) vs. where it falls down
  (multi-session, knowledge-update).

## Files

| File | Purpose |
|---|---|
| `datasets/longmemeval.lua` | Pure-Lua dataset loader + session→memory flattener |
| `run.lua` | Ingest + query loop; writes `results.json` |
| `score.lua` | Reads `results.json`, prints R@k table |
| `../scripts/download_eval.sh` | Curl the dataset from Hugging Face |

## Recipe

```bash
# 1. Get the dataset (oracle subset is ~1 MB and enough for smoke tests)
scripts/download_eval.sh eval/data

# 2. Run the harness with the pure-Lua hash embedder (zero deps, fast)
resty -I . eval/run.lua \
    --dataset eval/data/longmemeval_oracle.json \
    --out     eval/results/oracle_hash.json \
    --embedder hash

# 3. Score
lua eval/score.lua eval/results/oracle_hash.json

# 4. Compare against an HTTP embedder
resty -I . eval/run.lua \
    --dataset eval/data/longmemeval_oracle.json \
    --out     eval/results/oracle_ollama.json \
    --embedder ollama \
    --embedder_url http://localhost:11434/api/embeddings \
    --embedder_model nomic-embed-text \
    --embed_dim 768

lua eval/score.lua eval/results/oracle_ollama.json
```

## CLI flags (run.lua)

| Flag | Default | Purpose |
|---|---|---|
| `--dataset` | `eval/data/longmemeval_oracle.json` | JSON dataset file |
| `--out` | `eval/results/results.json` | Where to write results |
| `--embedder` | `hash` | `hash` (in-process) or any HTTP adapter name |
| `--embedder_url` | _none_ | Required for HTTP adapters |
| `--embedder_model` | _none_ | Optional model name |
| `--embed_dim` | `384` | Must match the embedder's output dim |
| `--top_k` | `10` | How many candidates to retrieve per question |
| `--limit` | _none_ | Cap N questions (smoke testing) |

## Notes & limitations

- Decay weighting is bypassed in eval (`ignore_decay = true`) so all
  candidates are scored on raw hybrid similarity.
- Dedup is disabled; every haystack session must land as its own row.
- Each question gets its own scope (`longmemeval:<question_id>`) so the
  table can be reused across questions without cross-contamination.
- The harness uses a dedicated `lapis_memory_eval` table that is
  `TRUNCATE`'d at the start of every run.

## Comparing to MemPalace

MemPalace publishes 96.6% R@5 on LongMemEval-S using a custom
LLM-summarisation pipeline. Our hybrid (vector + FTS, no LLM) baseline
should land in the 50–80% range with the hash embedder and 80–90% with a
proper sentence-transformer embedder, depending on the subset. Numbers
will be filled in once the harness is run end-to-end against a real
pgvector instance.
