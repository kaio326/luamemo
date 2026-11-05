---
name: memo-run-eval
description: Run luamemo's retrieval benchmarks on this machine with `memo eval` and read the results out — R@1/R@5/R@10, MRR, the miss rate and the bytes an agent reads before the right memory. Use when the user asks how well luamemo finds memories, wants to check an embedder or a change, or asks for benchmark numbers.
---

# memo-run-eval — luamemo's benchmark workflow

Use this skill when the user wants to know how well luamemo retrieves the right
memory on their machine: after changing the embedder or a setting, before a release,
or to compare embedders. It is the same workflow the maintainers publish the numbers
with.

**It needs a terminal** (it runs `memo eval …`). If your client gives you no shell
tool, tell the user the commands below and read the output they paste back.

## What is measured

Each benchmark is a set of questions with one right memory each. luamemo searches,
and the benchmark records where the right memory came:

| Number | What it means for the agent |
|---|---|
| **R@1** | The first result is the right one: the agent can answer without reading further. |
| **R@5 / R@10** | The right memory is among the first 5 / 10 results. |
| **MRR** | The average of 1/rank: one number for "how high up". |
| **Miss rate** | The right memory is not in the 10 results the agent gets (1 − R@10). The agent then has to search again, grep or read whole files. It is R@10 seen from the other side, as the event that costs the agent. |
| **Bytes to hit** | What the agent reads before the right memory: the compact rows 1..rank as the MCP server returns them (mean / median / p90). Tokens ≈ bytes / 4. |

Retrieval only: no generated answers are scored, so the numbers are luamemo's part,
not the model's.

## 1. Preflight

```bash
memo eval status --json
```

Read it:

- `kit.installed` false → the **eval kit** is missing: the benchmark runners, the
  project-personalization questions, the fixtures and the published baselines. It is
  not part of the luamemo install. `memo eval install` downloads it from this
  release's GitHub assets and refuses it unless it matches the checksum the install
  ships. **Ask the user before installing it.** Explain what it is first. If
  `kit.release_asset` is false (luamemo run from a checkout), the command is
  `memo eval install --from <the checkout>`.
- `datasets.<name>.present` false → that dataset is not downloaded. `tiers.<tier>`
  says what each tier still needs and how many bytes.
- `embedder.label` → the embedder this project uses (`mine`). When `runnable` is
  false, `why` says why: an HTTP API embedder is never run by `memo eval`.
- `gguf_model` → the GGUF model file, if one is found.
- `history` → the results kept from earlier runs (`results`, the newest `last`). To
  compare without running anything: `memo eval history`.

## 2. Choose what to run

**Tier** — from what the user wants:

| Tier | Benchmarks | Download | When |
|---|---|---|---|
| `quick` | project personalization (36 questions), the session's fixed cost, the code map (40 questions) — all in the kit | none | a sanity check after a change |
| `standard` | quick + LoCoMo, ConvoMem, LongMemEval oracle | ≈ 55 MB | an embedder change; before a release |
| `full` | standard + MemBench (8,500), LongMemEval _s, speed and footprint (`perf`) | ≈ 840 MB | publishing numbers |

What the newer ones measure:
- **`session`:** the bytes an agent receives before its first search (usage rules, tool
  definitions with all tools and with `MEMO_MCP_TOOLS=core`, the brief). Not per embedder.
- **`codemap`:** "where is X done?" over luamemo's own modules. The `index_search` columns
  are as for memories; "grep instead" is what reading files in grep's order costs to reach
  the same answer.
- **`perf`:** this machine's search latency (1k / 20k / 100k memories), embedding and write
  speed, the server's start and memory, the database's size. It is never compared with
  the baseline, only with this machine's own earlier runs.

**`--tier corpus`** (a separate tier, never part of the others): five benchmarks on a local
100,000-row database that `memo eval build-corpus` makes from luamemo's own ingestion of real
source trees on this machine — `scale` (R@k, miss rate, bytes to hit and search time at that
size), `task_cost` (bytes an agent reads with the code map against grep, on the corpus' small
projects), `multiscope` (the same questions over 1, 2, 4 and 8 scopes), `maintenance`
(consolidation cost, redundant rows and recall, on a copy) and `learned` (the learned
reranker's change in R@1 after 100 / 1,000 / 10,000 simulated outcomes). The database is not
built by default: without it these are skipped with one line, and `build-corpus` takes hours
(embedding on the CPU) — **ask before starting it**, and run it in the background; it resumes
where it stopped. `learned` takes ≈ 45 minutes. Read `learned` as a simulated person's
corrections, not a real one's (the caveat is in `eval/README.md`).

Options, each a label of its own in the history:
- `--rerank ollama:<model>` (e.g. `ollama:gemma4:e4b`), `learned`, `noop`, `cross_encoder`:
  a reranker on the retrieval benchmarks. Its table column is its own cost per search
  (ms / model tokens / failed calls). A model on Ollama is slow (seconds per search), so
  run LoCoMo / ConvoMem with it in the background.
- `--prompts auto`: the embedder's task prompts (`MEMO_EMBED_PROMPTS`). Compare it with the
  same embedder without them.
- `--embedder gguf:<model>`: another GGUF embedding model, e.g. `gguf:embeddinggemma-2-Q8_0`.

Every run first checks each runner on tiny fixtures (a few seconds).

**Embedders:** the default `--embedder mine,hash` runs the project's own embedder
plus `hash` as the floor; `hash` is fast and always available. Others are `gguf` (the
in-process model), `ollama` and `tei` (only when that service is running). Only local
embedders run. Never set an API key or switch to a paid embedder for a benchmark.

**Datasets:** before `memo eval fetch NAME …`, tell the user the sizes and sources
(`status` lists them; each dataset has its own license) and **ask**. Downloads over
50 MB need `--yes`; add it only once the user agreed. Each file is checked against
the copy the baselines were measured on; one that differs is refused.

## 3. Run

```bash
memo eval run --tier standard            # or: --tier quick, or benchmarks by name
memo eval run locomo convomem --embedder gguf
memo eval run --tier quick --n 50        # a partial run: compared with nothing, not kept
```

- The runners never touch the user's memories: each one gets a new scratch database
  and none of the project's `MEMO_*` settings. Don't set `MEMO_DB` for it, and never
  point a runner at the user's database yourself.
- What a run keeps: the newest 3 results of each benchmark × embedder, as one memory
  each in the project's database (scope `eval:<project>`, out of the project's own
  searches). That is the record. Don't copy results into notes, logs or other memories.
- `standard` takes about half a minute with `hash`, 7–25 minutes with ollama or TEI on
  a GPU, and about 3 hours with `gguf` on a CPU (ConvoMem alone takes about 2). `full`
  adds MemBench (about 20 minutes with hash) and LongMemEval _s. Run the long ones in
  the background and wait for completion. Don't poll in a loop; tell the user roughly
  how long it will take.
- The output ends with **the last 3 measurements**: for each benchmark × embedder, this
  run (marked `*` / "now") and the two before it, each with its change from the one
  below. The last lines name the results directory: `report.md` (the same table in
  Markdown, ready to show), `summary.json` and each runner's JSON and log, for when
  something failed.

## 4. Report

**Show the user the "The last 3 measurements" table from `report.md`** (Markdown), then
read it, benchmark by benchmark:

- **R@1** → how often the agent's first result is the answer.
- **Miss rate** → how often the agent has to fall back to searching again or reading
  files.
- **Bytes to hit** → the context the agent spends before it reaches the answer.
- **The change column** → what moved since the previous run. Say what changed in
  between when you know it: a luamemo version (the `luamemo` column), an embedder, a
  setting. Identical numbers are expected when nothing changed, because the benchmarks
  are deterministic. A first run has nothing to compare with yet.
- **Rerank** → set its cost against its gain: seconds and model tokens per search, against
  points of R@1 and bytes to hit saved. Failed calls mean the search kept its own order;
  many failures make that row a baseline row.
- **Code map** → `index_search`'s bytes to hit against grep's: the context the agent saves
  when it looks the code up instead of reading files.
- **Session's fixed cost** → paid every session, before any search. Reading it: the
  tool definitions dominate it, and `MEMO_MCP_TOOLS=core` is the lever.

The run also compares each result with the published baseline for the same benchmark,
embedder and question count. It flags a drop of 1 point or more of R@1, or 10 % more
bytes to hit; repeat those flags. Then:

- Never average across benchmarks: they measure different things (a project's own
  conventions, long chats, updates over time).
- A row with no baseline is a new combination, not a failure.
- If a number looks too good (100 % on the LongMemEval oracle), say that this set is
  easy: it holds only the sessions with the answer. Don't celebrate it.

## 5. Boundaries

- Results stay on this machine unless the user asks otherwise. Publishing numbers
  (README tables, `eval/baselines.json`) is the maintainer's step. When asked, keep
  the exact command, the luamemo version and the embedder with the numbers;
  `summary.json` has all three.
- Don't write the results into memory yourself: `memo eval run` already keeps the last
  3. Asked about earlier results, use `memo eval history` (or `memory_search` in the
  scope `eval:<project>`).

## 6. Troubleshooting

| What you see | What to do |
|---|---|
| `no eval kit for luamemo X` | `memo eval install` (ask first), or `--from <checkout>` |
| `missing dataset(s) … memo eval fetch …` | the printed fetch command (ask first; sizes are printed) |
| `no GGUF model found` / gguf runs fail | `memo gguf status`, `memo ping` |
| `smoke … FAILED — <log>` | read that log: the runners don't run on this machine; show the user the error |
| a runner `FAILED after Ns — <log>` | read the log; the other rows are still valid |
| `ollama` / `tei` rows fail | the service isn't running at its URL (`OLLAMA_URL` / `TEI_URL`) |
| a scratch database left behind (`--keep-db`, or a crash) | it is in the results directory's `scratch/`; it is safe to delete |
