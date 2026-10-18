# luamemo eval harness

The test suite, and the benchmarks that measure how well luamemo retrieves the
right memory — none of it is shipped in the rock.

## Running the test suite

```bash
eval "$(luarocks --lua-version 5.1 path)"     # the rocks the tests load (luasocket, …)
luajit eval/tests/run.lua                     # every eval/tests/test_*.lua
luajit eval/tests/run.lua --only core,cli     # a subset (names with or without test_)
luajit eval/tests/run.lua --list              # what would run
```

Run it from the repository root. It needs LuaJIT and the native libraries
(SQLite, libsodium) — no database server. Each file runs on its own, in a clean
environment:

- its own new database — `MEMO_DB` is a fresh SQLite file in the run's
  temporary directory (tests create further databases there);
- a temporary `HOME` and XDG directories, so your `~/.memorc`, `~/.luamemorc`,
  data directory and federation keyring are never touched;
- `MEMO_PROJECT` pointing at an empty directory, so the checkout's own
  `.luamemorc` never redirects a `memo` the tests run from the repository root;
- every `MEMO_*` variable from your shell removed (the optional `MEMO_GGUF_*`,
  `MEMO_GEN_*`, `MEMO_LIB_*` and `MEMO_LIVE_*` knobs are kept) and `MEMO_EMBEDDER=hash`.

It prints one line per file and the totals and exits 1 when anything fails; the
logs of a failing run are kept and their directory is printed. Options:
`--timeout SECONDS` (per file, default 600), `--keep` (keep the logs), `--lua
BIN` (the interpreter for the tests; default: the one running the runner).
Don't edit repository files while it runs — some tests index the live checkout.
A few tests are skipped unless their optional piece is there (e.g. the
generative sensor needs `MEMO_GEN_MODEL`). The optional ones:

| Test | Runs when | Knobs |
|---|---|---|
| `test_gguf_ffi` | the shim is built and a GGUF model is found | `MEMO_GGUF_MODEL`, `MEMO_GGUF_SHIM` |
| `test_gguf_bundle` (its last part) | a prebuilt runtime is given | `MEMO_LIVE_GGUF_BUNDLE` (built by `eval/release/gguf_bundle.sh`) |
| `test_embedders_live` | Ollama / TEI answer | `MEMO_LIVE_OLLAMA_URL` / `_MODEL` / `_DIM`, `MEMO_LIVE_TEI_URL` / `_DIM` |
| `test_rock` | `luarocks`, `git`, `jq`, `tar` are installed | — |

## Release tools (`eval/release/`)

| Script | What it does |
|---|---|
| `rockspec.lua VERSION [--check \| --print]` | Generates the rockspec (every `luamemo/**/*.lua`), or checks the committed one |
| `smoke.sh ROCKSPEC \| SRC.ROCK` | Installs the rock into a fresh tree and uses it: modules, `memo`, `memo mcp` |
| `gguf_bundle.sh VERSION [OUT]` | Builds the prebuilt GGUF runtime for this machine |
| `write_bundles.lua VERSION DIR` | Writes the runtimes' checksums into `bundles.lua` (the release workflow) |

The workflows that use them are in `.github/workflows/`; the steps are in
[RELEASING.md](../RELEASING.md).

## Benchmarks

Retrieval only: does the memory that answers a question come back in the top k?
Generated answers are not scored, so the numbers isolate luamemo's part from the
LLM's.

| Runner | Dataset | Measures |
|---|---|---|
| `longmemeval_run.lua` | [LongMemEval](https://huggingface.co/datasets/xiaowu0162/longmemeval) — `oracle` (default) or `_s` (`--corpus eval/data/longmemeval_s.json`) | R@k / MRR per question type |
| `locomo_run.lua` | LoCoMo (`eval/data/locomo.json`) | R@k / MRR |
| `convomem_run.lua` | ConvoMem (`eval/data/convomem.json`, built from the raw batches by `build_convomem_corpus.lua`) | R@k / MRR |
| `membench_run.lua` | MemBench (`eval/data/membench/`) | R@k / MRR per category |
| `personalization_run.lua` | the project-personalization set (`eval/personalization/`) — questions about one project's own conventions | R@k / MRR by lexical overlap |
| `recall_bench.lua` | a synthetic, paraphrased corpus (`helpers.lua` generates it) | `--mode ci` asserts the locked baseline |
| `rerank_bench.lua`, `projection_bench.lua` | the personalization set | the learned reranker / projection, cross-validated |
| `embedder_compare.lua`, `portability_check.lua` | — | embedders side by side; the same results across environments |

Every runner writes into the database `MEMO_DB` names — use a scratch one; each
run wipes its own scopes (e.g. `lme:<embedder>:<question id>`):

```bash
# hash (in-process, no GPU, a few seconds on oracle)
MEMO_DB=bench luajit eval/longmemeval_run.lua --embedder hash --out /tmp/lme_hash.json

# Ollama (nomic-embed-text)
MEMO_DB=bench OLLAMA_MODEL=nomic-embed-text OLLAMA_DIM=768 \
  luajit eval/longmemeval_run.lua --embedder ollama --out /tmp/lme_ollama.json

# bge-m3 on a TEI sidecar (see sidecars/)
docker compose -f eval/sidecars/docker-compose.yml up -d
MEMO_DB=bench TEI_URL=http://127.0.0.1:8081/embed TEI_DIM=1024 \
  luajit eval/longmemeval_run.lua --embedder tei --corpus eval/data/longmemeval_s.json --out /tmp/lme_tei.json
```

`longmemeval_run.lua` flags: `--embedder` (`hash`, `ollama`, `tei`, `openai`,
`gguf`), `--corpus`, `--out`, `--n N` (the first N questions), `--k-max`
(20), `--rerank` with `--rerank-adapter` (`noop`, `ollama`, `openai`,
`cross_encoder`) and `--rerank-top-n`, `--sweep-weights 0.25,0.5,0.75` (vector
weights to compare), `--with-observations` / `--skip-temporal` /
`--no-timestamps` (ablations), `--summarizer-model`. `locomo_run.lua` and
`convomem_run.lua` take the same flags; `membench_run.lua` takes `--embedder`,
`--out`, `--n`, `--k-max`, `--cats`, `--topic`, `--scope-prefix`;
`personalization_run.lua` `--embedder` and `--out`.

Environment the runners read: `OLLAMA_URL` / `OLLAMA_MODEL` / `OLLAMA_DIM`,
`TEI_URL` / `TEI_MODEL` / `TEI_DIM`, `OPENAI_URL` / `OPENAI_MODEL` /
`OPENAI_DIM` / `OPENAI_API_KEY`, `MEMO_GGUF_MODEL` / `MEMO_GGUF_DIM`,
`RERANK_URL` / `RERANK_MODEL` / `RERANK_API_KEY` (cross-encoder),
`EMBED_MAX_CHARS` (default 6000), `EMBED_TIMEOUT_MS`, `INGEST_BATCH_SIZE`
(rows per `write_many` batch, 50), `INGEST_MODE=perrow` (one write per row).

Datasets live in the gitignored `eval/data/`; each runner's header says where to
download its data. Small fixtures for the smoke tests are tracked in
`eval/fixtures/`.

## Results

The current numbers (October 2026, this store — the same vectors as the previous
Postgres store, within ±0.4 points of it everywhere):

| Benchmark | hash R@1 / R@5 / R@10 | nomic-embed-text | bge-m3 (TEI) |
|---|---|---|---|
| Project personalization (36) | 58.3 / 88.9 / 94.4 | 72.2 / 97.2 / 100 | 94.4 / 100 / 100 |
| LongMemEval oracle (500) | 100 / 100 / 100 | 99.8 / 99.8 / 99.8 | 100 / 100 / 100 |
| LoCoMo | 45.3 / 68.8 / 82.6 | 52.9 / 77.3 / 87.7 | 58.3 / 84.6 / 92.3 |
| ConvoMem | 82.8 / 96.5 / 96.5 | 90.2 / 96.5 / 96.5 | 92.0 / 96.5 / 96.5 |
| MemBench (8,500) | 42.5 / 72.9 / 83.6 | | |

LongMemEval `_s` (500 questions, ~50 sessions of haystack each), measured on the
previous store:

| Embedder | n | R@1 | R@5 | R@10 | R@20 | MRR |
|---|---|---|---|---|---|---|
| hash | 500 | 49.0 % | 69.4 % | 81.0 % | 91.2 % | 0.586 |
| nomic-embed-text 768d (Ollama) | 500 | 64.8 % | 81.8 % | 90.0 % | 94.4 % | 0.733 |
| **bge-m3 1024d (TEI)** | **500** | **87.0 %** | **96.4 %** | **98.6 %** | **99.6 %** | **0.913** |

- **The embedder is the dominant lever.** `nomic-embed-text` → `bge-m3` adds
  about 15 points of R@5 with no other change.
- **Same-family cross-encoder reranking adds nothing**: `bge-m3` +
  `bge-reranker-v2-m3` agree point for point.
- **`noop` reranking hurts a strong embedder** (R@1 −7.5 points on bge-m3) while
  it lifts a weaker one (+12 points R@1 on nomic).

Phase-by-phase analyses and every reproduce command:
[results/longmemeval.md](results/longmemeval.md), [results/locomo.md](results/locomo.md),
[results/convomem.md](results/convomem.md), [results/recall_bench.md](results/recall_bench.md).
The JSON files in `results/` are kept as measured, including older runs on the
previous store.

## Notes

- Decay weighting is off in the runners (`ignore_decay`), so every candidate is
  scored on raw hybrid similarity; dedup is off, so every haystack session lands
  as its own memory.
- Each question gets its own scope, isolated across questions and embedders.
- An embedder that rejects a session as too long gets it shortened and retried
  (the memory is flagged as truncated); one it still refuses is stored without a
  vector, found by its words only.
