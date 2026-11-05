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
| `eval_kit.sh VERSION [OUT]` | Packs the eval kit `memo eval install` downloads (the files `luamemo/cli/eval.lua` lists) |
| `write_evalkit.lua VERSION DIR [OUT]` | Writes the kit's checksum into `luamemo/evalkit.lua` (the release workflow) |

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

Beside R@k and MRR, every dataset runner reports what retrieval costs the agent
(`metrics.lua`, measured at the 10 results an agent gets by default):

- **miss rate**: the share of questions whose right memory is not in those 10
  (1 − R@10; a rank past 10 counts). The agent then searches again, greps or reads
  files. It is R@10 seen from the other side, reported as the event that costs.
- **bytes to hit**: the bytes the agent reads up to the right memory. These are the
  compact rows 1..rank exactly as the MCP server returns them (`luamemo.ops.compact_row`,
  bodies capped at 2000), over the questions answered within 10: mean, median, p90. A
  token estimate is bytes / 4; tokenizers differ, so the bytes are the figure.
  `bytes_on_miss_mean` is what a miss returns, wasted.

The JSON keys are `miss_rate`, `bytes_to_hit_mean|median|p90`, `est_tokens_to_hit_mean`,
`bytes_on_miss_mean` and `limit`, next to the older ones.

## `memo eval` — the benchmarks from an install

The runners are not in the rock. `memo eval` runs them from the **eval kit**: the
runners, their loaders, the personalization set, the fixtures, `baselines.json` and
`datasets.json`. It is attached to each GitHub release and checked against the
checksum the rock ships (`luamemo/evalkit.lua`).

```bash
memo eval status                      # the kit, the datasets, the embedder, what each tier needs
memo eval install                     # the release's kit (or --from a checkout of the same version)
memo eval fetch locomo convomem longmemeval_oracle    # datasets, each file checked (big ones: --yes)
memo eval run --tier standard         # quick | standard | full; --embedder mine,hash (default)
memo eval history                     # the last 3 results kept, without running
```

Each runner runs in a new scratch database, without the `MEMO_*` settings of the
shell or the project; only the GGUF runtime's and the libraries' paths are kept. The
run keeps the newest three results of each benchmark × embedder in the project's
memory, one memory each in the scope `eval:<project>` (a partial `--n` run isn't kept).
It prints them side by side with the change from each to the one before. That is the
record: no log to keep. The run also writes `report.md` (the same table) and
`summary.json`, and flags a drop against `baselines.json`: 1 point or more of R@1, or
10 % more bytes to hit, for the same benchmark, embedder and question count. Datasets go in
`~/.local/share/luamemo/eval-data` (`--data DIR` elsewhere); the
`skills/memo-run-eval` skill is the same workflow for the agent.

Every runner writes into the database `MEMO_DB` names — use a scratch one; each
run wipes its own scopes (e.g. `lme:<embedder>:<question id>`). Also set
`MEMO_NO_MAINTENANCE=1` when you run one directly (`memo eval` does it for you):
the writes would otherwise claim the digest slot and start a `memo maintain` on
the scratch database.

```bash
# hash (in-process, no GPU, a few seconds on oracle)
MEMO_NO_MAINTENANCE=1 MEMO_DB=bench luajit eval/longmemeval_run.lua --embedder hash --out /tmp/lme_hash.json

# Ollama (nomic-embed-text)
MEMO_NO_MAINTENANCE=1 MEMO_DB=bench OLLAMA_MODEL=nomic-embed-text OLLAMA_DIM=768 \
  luajit eval/longmemeval_run.lua --embedder ollama --out /tmp/lme_ollama.json

# bge-m3 on a TEI sidecar (see sidecars/)
docker compose -f eval/sidecars/docker-compose.yml up -d
MEMO_NO_MAINTENANCE=1 MEMO_DB=bench TEI_URL=http://127.0.0.1:8081/embed TEI_DIM=1024 \
  luajit eval/longmemeval_run.lua --embedder tei --corpus eval/data/longmemeval_s.json --out /tmp/lme_tei.json
```

`longmemeval_run.lua` flags: `--embedder` (`hash`, `ollama`, `tei`, `openai`,
`gguf`), `--corpus`, `--out`, `--n N` (the first N questions), `--k-max`
(20), `--rerank` with `--rerank-adapter` (`noop`, `ollama`, `openai`,
`cross_encoder`) and `--rerank-top-n`, `--sweep-weights 0.25,0.5,0.75` (vector
weights to compare), `--with-observations` / `--skip-temporal` /
`--no-timestamps` (ablations), `--summarizer-model`. `locomo_run.lua` and
`convomem_run.lua` take the same flags except `--sweep-weights` (LongMemEval only;
ConvoMem also lacks `--skip-observations`, which is its default);
`membench_run.lua` takes `--embedder`, `--out`, `--n`, `--k-max`, `--data-dir`,
`--cats`, `--topic`, `--scope-prefix`, `--with-observations` and `--patterns`;
`personalization_run.lua` takes `--embedder`, `--out`, `--corpus`, `--queries` and
the `--rerank*` flags.

Environment the runners read: `OLLAMA_URL` / `OLLAMA_MODEL` / `OLLAMA_DIM`,
`TEI_URL` / `TEI_MODEL` / `TEI_DIM`, `OPENAI_URL` / `OPENAI_MODEL` /
`OPENAI_DIM` / `OPENAI_API_KEY`, `MEMO_GGUF_MODEL` / `MEMO_GGUF_DIM`,
`RERANK_URL` / `RERANK_MODEL` / `RERANK_API_KEY` (cross-encoder),
`EMBED_MAX_CHARS` (the longest text sent; default 0 = no cap — `memo eval` uses 8000
for ollama and 24000 for TEI), `EMBED_TIMEOUT_MS`, `INGEST_BATCH_SIZE`
(rows per `write_many` batch, 50), `INGEST_MODE=perrow` (one write per row).

Datasets live in the gitignored `eval/data/`; each runner's header says where to
download its data. Small fixtures for the smoke tests are tracked in
`eval/fixtures/`.

## Results

The current numbers come from luamemo 0.5.2 (2026-10-22), measured with `memo eval
run`. Every figure, with p90 and the bytes a miss returns, is in
[baselines.json](baselines.json), which `memo eval` compares runs against.

The machine was Linux x86_64 (WSL2): EmbeddingGemma on the CPU, nomic-embed-text and
bge-m3 on an RTX 2060. `EMBED_MAX_CHARS` was 8000 for nomic-embed-text and 24000 for
bge-m3 (`memo eval`'s defaults); hash and EmbeddingGemma ran uncapped (EmbeddingGemma
truncates at its 2048-token context).

| Benchmark | Embedder | R@1 | R@5 | R@10 | MRR | Miss rate | Bytes to hit mean / median / p90 | ≈ Tokens |
|---|---|---|---|---|---|---|---|---|
| Project personalization (36) | hash | 58.3 | 88.9 | 94.4 | 0.702 | 5.6 % | 1,117 / 564 / 2,495 | 279 |
| | EmbeddingGemma (GGUF) | 94.4 | 100 | 100 | 0.964 | 0 % | 583 / 512 / 573 | 146 |
| | nomic-embed-text | 80.6 | 100 | 100 | 0.881 | 0 % | 711 / 514 / 1,090 | 178 |
| | bge-m3 (TEI) | 94.4 | 100 | 100 | 0.965 | 0 % | 568 / 511 / 572 | 142 |
| LongMemEval oracle (500) | hash | 100 | 100 | 100 | 1.000 | 0 % | 2,235 / 2,240 / 2,256 | 559 |
| | EmbeddingGemma (GGUF) | 100 | 100 | 100 | 1.000 | 0 % | 2,234 / 2,239 / 2,256 | 558 |
| | nomic-embed-text | 100 | 100 | 100 | 1.000 | 0 % | 2,236 / 2,241 / 2,259 | 559 |
| | bge-m3 (TEI) | 100 | 100 | 100 | 1.000 | 0 % | 2,233 / 2,238 / 2,255 | 558 |
| LoCoMo (1,986) | hash | 45.3 | 68.9 | 82.6 | 0.565 | 17.4 % | 5,983 / 2,222 / 15,521 | 1,496 |
| | EmbeddingGemma (GGUF) | 59.0 | 84.6 | 93.1 | 0.702 | 6.9 % | 4,676 / 2,220 / 11,092 | 1,169 |
| | nomic-embed-text | 53.2 | 79.3 | 88.4 | 0.649 | 11.6 % | 4,910 / 2,223 / 12,383 | 1,228 |
| | bge-m3 (TEI) | 58.5 | 84.6 | 92.3 | 0.699 | 7.7 % | 4,619 / 2,219 / 11,077 | 1,155 |
| ConvoMem (2,478) | hash | 83.0 | 96.5 | 96.5 | 0.892 | 3.5 % | 2,486 / 2,211 / 4,420 | 622 |
| | EmbeddingGemma (GGUF) | 91.8 | 96.5 | 96.5 | 0.940 | 3.5 % | 2,227 / 2,211 / 2,217 | 557 |
| | nomic-embed-text | 91.0 | 96.5 | 96.5 | 0.935 | 3.5 % | 2,260 / 2,213 / 2,219 | 565 |
| | bge-m3 (TEI) | 92.7 | 96.5 | 96.5 | 0.945 | 3.5 % | 2,209 / 2,210 / 2,215 | 552 |
| MemBench (8,500) | hash | 42.7 | 73.0 | 83.8 | 0.560 | 16.2 % | 894 / 517 / 2,194 | 224 |
| LongMemEval `_s` (500) | hash | 54.2 | 73.6 | 83.4 | 0.632 | 16.6 % | 5,070 / 2,250 / 13,401 | 1,267 |

### Other things the agent pays for (0.5.2, 2026-10-23)

**Session's fixed cost** — what luamemo sends before the first search (`memo eval run session`; re-measured 2026-11-05):

| Usage rules | Tool definitions (all 27 / `MEMO_MCP_TOOLS=core` 16) | Brief | Total | ≈ Tokens |
|---|---|---|---|---|
| 1,944 | 16,019 / 11,072 | 338 | 18,301 / 13,354 bytes | 4,575 / 3,339 |

**Code map** — 40 "where is X done?" questions over luamemo's own modules, `index_search` against grep
(grep: files ranked by how many of the question's words they hold, read whole):

| | R@1 | R@5 | R@10 | Miss rate | Bytes to hit (mean / median) |
|---|---|---|---|---|---|
| hash | 40.0 | 70.0 | 72.5 | 27.5 % | 294 / 172 |
| EmbeddingGemma-300M | 52.5 | 82.5 | 92.5 | 7.5 % | 291 / 172 |
| EmbeddingGemma-300M, task prompts | 62.5 | 77.5 | 92.5 | 7.5 % | 307 / 161 |
| grep | — | — | — | 5.0 % | 86,125 / 60,005 |

The code map reaches the right file in about 290 bytes where grep reads about 86 KB (300×).
grep misses less often (5 %): it finds a file by its words, but it hands over the whole file.

**Speed and footprint** (`memo eval run perf`, this machine: 12 CPU cores, RTX 2060, WSL2):

| Search p50 / p95 ms at 1k · 20k · 100k memories (768-d) | Query embed: hash / gguf | Writes/s: hash / gguf | Server: start / first search | Server RSS: idle / after a search / with the GGUF model | Database |
|---|---|---|---|---|---|
| 5.1/6.3 · 75/100 · 297/383 | 0.05 ms / 39 ms | 1,687 / 2.9 | 247 / 277 ms | 4 / 10 / 375 MB | 4.3 MB per 1k |

Every search scores every vector in scope, so its time is linear in the memories.

**Task prompts and a second EmbeddingGemma**, on the GPU (vectors differ from the CPU's by cosine
0.9995, so these are `@gpu` rows of their own; a local CUDA build of llama.cpp b11829 made them,
which the release's prebuilt runtime, CPU only, does not). R@1 / R@5 / R@10 and miss rate:

| Benchmark | 300M | 300M + prompts | EmbeddingGemma 2 | EG2 + prompts |
|---|---|---|---|---|
| Personalization | 94.4 / 100 / 100 · 0 % | 94.4 / 97.2 / 100 · 0 % | 91.7 / 100 / 100 · 0 % | 94.4 / 100 / 100 · 0 % |
| Code map | 52.5 / 85 / 92.5 · 7.5 % | 62.5 / 77.5 / 92.5 · 7.5 % | 47.5 / 75 / 85 · 15 % | 55 / 85 / 87.5 · 12.5 % |
| LoCoMo | 59.0 / 84.7 / 93.1 · 6.9 % | 57.9 / 84.6 / 93.0 · 7.0 % | 48.6 / 71.7 / 82.7 · 17.3 % | 61.2 / 85.2 / 93.4 · 6.6 % |
| ConvoMem | 92.0 / 96.5 / 96.5 · 3.5 % | 92.5 / 96.5 / 96.5 · 3.5 % | 90.8 / 96.5 / 96.5 · 3.5 % | 93.6 / 96.5 / 96.5 · 3.5 % |
| LongMemEval oracle | 100 | 100 | 100 | 100 |

- **Prompts help little on the 300M model** (code map +10 R@1, the rest within ±1) and **a lot on
  EmbeddingGemma 2**: its LoCoMo R@1 goes from 48.6 to 61.2 and its miss rate from 17.3 % to 6.6 %.
- **EmbeddingGemma 2 needs its prompts.** With them it is the best on LoCoMo (61.2 / 85.2 / 93.4)
  and ConvoMem (93.6), at 2.5× the CPU cost of the 300M model; without them it is worse than the old one.
- The setting's own default stays `MEMO_EMBED_PROMPTS=none`, and the baselines above are without prompts;
  `memo calibrate` writes `auto` for a project with EmbeddingGemma 2.

**An LLM reranker** (`gemma4:e4b` through Ollama, top 20, thinking off) on EmbeddingGemma-300M,
GPU, against the same without it:

| Benchmark | Without | With gemma4 | Rerank per search |
|---|---|---|---|
| Personalization (36) | R@1 94.4 · 583 bytes | R@1 77.8 · 714 bytes | 7.5 s · 1,929 tokens |
| LoCoMo (1,986) | R@1 59.0 · miss 6.9 % · 4,676 bytes | R@1 42.1 · miss 9.2 % · 5,939 bytes | 5.8 s · 3,092 tokens |

It lowers R@1 by 17 points (personalization) and 17 (LoCoMo), raises the miss rate, and costs seconds and
thousands of model tokens on every search. A 7.5B model asked to score twenty candidates ranks them worse
than the embedder alone did; the May 2026 result for a 1B model (−20 points) holds at 7.5B.
The learned reranker (cross-validated on the personalization set) is also not an improvement over
EmbeddingGemma: R@1 94.4 → 91.7 (hash: 58.3 → 44.4); the learned projection leaves it unchanged (91.7 → 91.7).

MemBench and LongMemEval `_s` with the other embedders aren't measured on this
store yet. A miss returns ~22 KB on LoCoMo and `_s` (10 whole sessions), ~4.6 KB on
ConvoMem and ~3.4 KB on MemBench. Run times on that machine, standard tier:

| Embedder | personalization | LoCoMo | ConvoMem | LME oracle |
|---|---|---|---|---|
| hash | < 1 s | 3 s | 14 s | 10 s |
| EmbeddingGemma (CPU) | 6 s | 7 min | 1 h 56 min | 1 h 1 min |
| nomic-embed-text (GPU) | 43 s | 1.5 min | 4.5 min | 1 min |
| bge-m3 (GPU) | 2 s | 1 min | 9 min | 14 min |

MemBench with hash took 21 minutes, and LongMemEval `_s` 5 minutes.

LongMemEval `_s` with all three embedders, measured on the previous (Postgres)
store:

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
The published numbers are in `baselines.json` and the `.md` files in `results/`
(older runs on the previous store are labelled as such); the raw JSON of each run
stays on the machine that ran it (gitignored).

## The 100,000-entry corpus

The public benchmarks have one question per conversation and no history of use. To measure what only
a long-lived store has — scale, the learned reranker, maintenance — `memo eval build-corpus` makes a
database of luamemo's own rows, kept apart from every project (`$XDG_DATA_HOME/luamemo/eval-data/bench-100k.db`;
named `bench*.db`, labelled `lm_meta bench = 1`; the builder and the runners refuse any other file).

| Part | Where the rows come from |
|---|---|
| Code (`codeindex:<project>`) | `memo index ingest`'s own code over real trees: the owner's repositories, the Python / Ruby / Perl standard libraries as huge single scopes (sampled with a seeded order), Node packages, Lua rocks |
| Documents, instructions, ADRs, `ARCH:` / `DECISION:` comments, git history (`repo:<project>`) | `memo calibrate`'s scan (`luamemo.cli.calibrate.scan`) over the same projects and the READMEs under `/usr/share/doc` |
| Agent-written decisions, plans, facts | the owner's own notes (planner, change-log, research, per-project memory notes), split into sections as calibrate splits a README |
| Vectors | the configuration in use (EmbeddingGemma 2, task prompts, 24,000 characters), in the real `embedding` column |

Nothing is invented from random words; the mix follows what two real databases hold (98 % code rows).
The stages: `build` (resumable; hours), `rescan`, `queries` (labelled questions with a measured overlap),
`paraphrase` (a model rewrites a sample in other words; cached in `<db>.paraphrases.jsonl`), `simulate` (a
history written by the real code from a click model with recorded parameters). The benchmarks, in the
`corpus` tier: `scale` and `learned`. Raw chat transcripts and personal notes are not read.

The questions that busy projects are asked more than once: `simulate` asks every history question of a scope
with 200 or more of them (`--heavy-min`) six times (`--heavy-cycles`), a week apart, so the largest scopes
reach 1,000 and ~10,000 logged searches. Only four scopes are that large; the rest stay at one pass.

**Measurement** (2026-10-25, under the shipped defaults — importance curve `sqrt`, "the same memory" at 0.95 —
EmbeddingGemma 2 with task prompts, 114,927 rows, 898 sources, 13,104 labelled questions, 22,499 simulated
searches with 8,260 corrections / confirmations / misses):

| Benchmark | Eval questions | R@1 | R@5 | R@10 | MRR | Miss rate | Bytes to hit (mean / median) | Search ms (p50 / p95) |
|---|---|---|---|---|---|---|---|---|
| scale | 4,920 | 65.6 | 82.0 | 85.9 | 0.724 | 14.1 % | 624 / 148 | 49 / 118 |

By kind of question (R@1 / R@10): a symbol from its docstring 81.1 / 94.6 (88.8 / 99.6 when the question quotes
the docstring); a README section 71.7 / 96.3; a file from two names it defines 70.1 / 92.9; who requires a
module 31.9 / 73.4 (up to eight right answers); a note's content 46.4 / 54.4 and its heading 11.0 / 43.8 (the
planner repeats headings); a commit 1.1 / 18.9; **questions a model wrote in other words, sharing almost
none of their answer's words: 18.2 / 50.7** — the average above blends them with the easy ones. The commit
rows used to lose outright to the "Agent instructions" rows (importance 5 against 2): a result's score is the
similarity times the row's importance weight, and under `linear` that spread (30x) was wider than the
similarity ever covers; `sqrt` (5.5x) narrows it (the section on the curve below). Two things made an earlier
version of this table (R@1 52.3) worse than the store deserved, both of the benchmark's making and both fixed:
a file question's answer was only the file's own row (the symbols it defines, which name the file, count now),
and a rescan had written the README rows twice, so half of those questions had an identical twin ranked first.

| Learned reranker, R@1 without it | after 100 outcomes | after 1,000 | after 10,000 |
|---|---|---|---|
| under `sqrt` (the default), 63.9 without: ΔR@1 (95 % CI), 2,607 questions | +3.38 (±1.12) | +3.38 (±1.17) | +1.99 (±1.07) |
| under `linear`, 61.7 without | +0.38 (±0.93) | +5.56 (±1.30) | +6.44 (±1.36) |
| scopes promoted / rejected / skipped | 76 / 0 / 308 | 76 / 0 / 308 | 76 / 0 / 308 |

The default curve already does part of what the learner learned (it stops a heavy memory covering a better
match), so under `sqrt` the learned reranker adds about 3½ points of R@1 at 100 and 1,000 outcomes and less at
10,000 (+2.0): the scopes that reach 10,000 are the ones the simulation asks the same questions six times
over (`--heavy-cycles`), and a learner fed the same questions again probably fits them rather than learning more
(not tested: the drop could also be noise at the edge of the interval). Under
`linear` it moved nothing at 100 outcomes and gained 5½ to 6½ points at 1,000 and 10,000. Read both with the
caveats: the person is simulated (a
click model that the learner may fit — a real person's corrections are noisier), the gain is pooled over the
76 scopes the gate promoted (it skips a scope with too few outcomes, which is most of them), and a point
trains on the newest N outcomes *of each scope*, so a scope with fewer outcomes than N contributes all it
has: the step from 1,000 to 10,000 comes from the handful of scopes that have more than 1,000 (the largest
has 9,654), repeated six times each (`--heavy-cycles`). An earlier version of this table showed the same
number at every point; the benchmark had not cleared the reranker's in-memory weights between points.

**The other four suites** (same database and day):

| `task_cost` — bytes read before the file that answers (214 small projects) | n | code map R@1 / R@10 | code map bytes to hit | grep bytes to hit / miss |
|---|---|---|---|---|
| all | 300 | 74.3 / 90.3 | 177 | 75,772 / 12.3 % |
| questions written in other words by a model | 52 | 23.1 / 55.8 | 324 | 133,774 / 48.1 % |
| verbatim fragments (what grep is made for) | 248 | 83.5 / 97.6 | 165 | 69,137 / 4.8 % |

| `multiscope` — 800 questions | 1 scope | 2 | 4 | 8 |
|---|---|---|---|---|
| R@1 | 65.9 | 62.1 | 62.0 | 62.4 |
| R@10 | 86.4 | 79.4 | 80.6 | 80.2 |
| search ms, p50 (p95 at 8) | 48 | | | 65 (134) |

The right scope plus its project's other scope (`repo:` + `codeindex:`, 203 questions): R@1 49.8 against 50.2
for the right scope alone, R@10 77.8 against 78.3. The extra scopes are other projects of the same kind
(another project's code for a code question). Widening costs rank because a result's score is the similarity
times the row's importance weight, and a bigger pool holds more heavy rows with weak matches; under `sqrt` the
cost is 3½ points over eight scopes (under `linear` it was 15½). A row of another scope that says exactly what
the gold row says counts as a hit.

| `maintenance` (a copy) | rows | consolidate ms over 500 · 1000 · 2000 · 5000 | redundant rows over 1000 / 5000 | R@10 before → after collapsing the groups, at 0.85 (at 0.95) |
|---|---|---|---|---|
| the largest scope (`codeindex:cpython-stdlib`, re-scoped as memory in the copy) | 23,094 | 194 · 567 · 2,282 · 15,225 | 277 / 1,193 | 99.7 → 90.3 (99.0) |
| largest `repo:` scope (`repo:luamemo`) | 450 | 148 · 122 · 118 | 288 | 78.0 → 26.3 (78.0) |

The code index is out of consolidation's reach by design, so the benchmark treats the Python standard library's
rows as a 23,000-memory scope in its copy of the database to measure what the near-duplicate search costs at
that size. Consolidation looks only at the `max_rows` most important rows (at most 5,000; the pairwise search is
O(n²)). The old default similarity threshold, 0.85, did not mean "near-duplicate" with EmbeddingGemma 2 and
task prompts: single-link grouping chained the scope's rows into one group (251 of the 450 in `repo:luamemo`,
918 of the first 1,000 in the Python standard library); at 0.95 the largest group has 3 rows and 3 rows are
flagged there (28 in the standard library, where the same docstring really does repeat). The default is 0.95
now, with a limit on how large a group may be before it is only reported. "Collapsing" here keeps the first row
of each group and writes no summary — the worst case; a merge with a summarizer keeps what the rows said, and
the original is archived and reviewed before it is deleted.

### How importance weighs in ranking (`MEMO_IMPORTANCE_CURVE`)

The same benchmarks under each curve (`MEMO_IMPORTANCE_CURVE=sqrt luajit eval/corpus_run.lua --suite scale …`),
same database, same questions. `linear` is the importance itself: 0.2 to 6 is a 30x spread; `sqrt`, the default
since this measurement, is 5.5x, and `log` (log2(1+x)) 11x:

| | linear | sqrt | log |
|---|---|---|---|
| scale, R@1 / R@10 / miss rate | 63.9 / 85.0 / 15.0 % | 65.6 / 85.9 / 14.1 % | 65.2 / 85.7 / 14.3 % |
| a note's content, R@1 / R@10 | 22.4 / 47.7 | 46.4 / 54.4 | 43.9 / 54.4 |
| a README section's sentence, R@1 / R@10 | 42.6 / 86.9 | 89.3 / 100 | 84.4 / 100 |
| a commit, R@1 / R@10 | 0.0 / 7.4 | 1.1 / 18.9 | 1.1 / 16.8 |
| a symbol from its docstring, R@1 | 80.9 | 81.1 | 80.9 |
| multi-scope, R@1 over 1 · 2 · 4 · 8 scopes | 59.6 · 48.2 · 45.1 · 44.1 | 65.9 · 62.1 · 62.0 · 62.4 | 63.4 · 58.1 · 56.9 · 56.5 |
| code map against grep (task cost), R@1 | 73.0 | 74.3 | 73.0 |

Where the gain is, it is large (a note or a sentence that the match finds but a more important memory used to
cover); where there was nothing to gain, nothing moved, and no kind of question got worse. What this does not
say: the questions are generated, the importances are the ones calibrate and the code index assign, and a
person's memories mix them differently. On two real databases (copies of the owner's) 14 realistic questions
changed their first result in 1 case, and in 6 of 7 questions of the larger project the lower ranks lost rows
that did not belong (an importance-9 session summary appearing fourth for a question about a server login).
It is a reason to check `sqrt` on a real usage log (`memo usage`), not a measurement of real use.

### Which model should summarize (`eval/summarizer_bench.lua`)

Twelve batches of six consecutive sections of real notes, through each backend with the identical prompt and parser:

| | in-process gemma-4-E4B-it Q4_0 (CPU) | Ollama gemma4:e4b Q4_K_M (RTX 2060) |
|---|---|---|
| seconds per batch (mean · median · range) | 78.0 · 78.5 · 36–139 (+28 s load once) | 16.6 · 13.2 · 10–35 |
| answer parsed | 0 % as it comes (it wraps the JSON), 100 % taking the first `{…}` | 92 % (one "prediction aborted") |
| concrete tokens kept (numbers, identifiers, file names) | 16.5 % | 24.0 % |
| tokens in the summary found in no source | 3.9 % | 9.4 % |
| summary length / source length | 17 % | 28 % |

Neither wins on quality (Ollama keeps more and invents more). Either keeps a quarter or less of the concrete tokens of what
it folds, which is why a folded memory is archived and reviewed before it is deleted, not deleted at once.

### What a similarity threshold means (`eval/clustering_probe.lua`)

`memo consolidate` groups memories by **single link** (A~B and B~C put all three together, however unlike A
and C are); the digest groups by **pivot** (a memory joins the first group whose first member it matches, so a
group cannot chain). The probe asks both the same question on the same rows: 529 distinct memories (the
READMEs, instructions and notes of two projects — any group of two or more is a false merge), and for every
tenth one a near-duplicate (a sentence added) and a snapshot (its first three quarters, what the session hooks
save as a conversation grows) that should be grouped with it. EmbeddingGemma 2 with task prompts:

| threshold | consolidate: largest group · rows in mixed groups · copies found | digest: largest group · rows in mixed groups · near-duplicates / snapshots found |
|---|---|---|
| 0.75 | 529 · 529 · 100 % | 120 · 523 · 87 % / 89 % |
| 0.80 (the digest's default then) | 493 · 509 · 100 % | 36 · 467 · 89 % / 78 % |
| 0.85 (consolidate's default then) | 299 · 371 · 100 % | 9 · 309 · 100 % / 87 % |
| 0.90 | 5 · 77 · 100 % | 5 · 72 · 98 % / 98 % |
| 0.95 | 3 · 3 · 100 % | 3 · 3 · 100 % / 100 % |

The probe also asks the question that dedup (0.95), the miss signal (0.90) and the reinforce rule (0.75) all
ask — *is the nearest existing memory at least t similar?* — and counts how often a **distinct** memory is wrongly
matched against how often a near-duplicate or snapshot finds its own original:

| t | distinct memory wrongly matched | near-duplicate found | snapshot found |
|---|---|---|---|
| 0.75 (reinforce) | 99.5 % | 100 % | 100 % |
| 0.80 | 95.0 % | 100 % | 100 % |
| 0.85 | 69.8 % | 100 % | 100 % |
| 0.90 (miss) | 13.4 % | 100 % | 100 % |
| 0.93 | 2.3 % | 100 % | 100 % |
| 0.95 (dedup) | 0.7 % | 100 % | 100 % |
| 0.97 | 0.7 % | 100 % | 88.9 % |

At 0.75 nearly everything "matches" something, so a reinforce at that value reinforces whatever observation is
nearest; at 0.90 one write in eight that is not a duplicate would count as a missed search. The reinforce rule
compares a group with an observation about the same topic, which may legitimately be looser than "the same
memory"; the probe has duplicates and snapshots as ground truth, so it shows 0.75 is far too loose, not what the
right topical value is.

Both (they were the defaults when this was measured; since 0.5.2 every one of these thresholds follows the dedup
threshold, 0.95) were far below the point where "similar" means "the same memory" for this embedder: the memories
of one project are all about the same things, so their cosines sit high, and from 0.95 up only the copies are
grouped. The digest does not chain — its largest group at 0.80 is 36 — but it merges 467 of the 529 distinct
memories into groups of different ones, and misses a fifth of the snapshots it should group. Read it with the
caveat that these are documents of one project, not conversation transcripts (which are raw tier-0 rows and
were not read); the measurement says how close a project's own texts sit, not how a real conversation splits.

## Notes

- Decay weighting is on, as in normal use. But every memory of a question was
  written seconds before the search, so it moves no score that matters. Dedup is off
  (the runners append; MemBench turns it off), so every haystack session lands as its
  own memory.
- The runs are deterministic: the same luamemo, embedder and data give the same numbers.
  Before 0.5.2, a tie in the temporal leg's rank fusion was ordered by Lua's hash order,
  which changes per process; ConvoMem's R@1 moved by about 0.1–0.2 points between
  identical runs.
- Each question gets its own scope, isolated across questions and embedders.
- An embedder that rejects a session as too long gets it shortened and retried
  (the memory is flagged as truncated); one it still refuses is stored without a
  vector, found by its words only.
