# Embedders — Switch Off `hash` in 5 Minutes

> **TL;DR:** the default `embedder_local = "hash"` is a fallback, not a
> peer of a real embedding model. Switching to a real embedder is the
> single biggest accuracy lever in this library — see
> [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md) for why.

This guide shows the recommended setup and the gotchas. Every path
ends with the same `memory.setup({...})` snippet — pick one and paste.

> **Don't want to read?** Run `memo calibrate` from your project root. It
> probes your host (GPU, Docker, Ollama, RAM) and prints a ready-to-paste
> `setup({...})` snippet tailored to your hardware. On subsequent runs it
> also ingests architectural decisions into the memory store. After
> ingesting some rows, run `memo doctor` to verify the fit (truncation count, p95 row size,
> backend scale).

---

## Why this matters

The `hash` embedder is a feature-hashing trick: fast, deterministic,
zero deps, no network, but **semantically blind**. It treats `"docker
deploy"` and `"docker compose up"` as nearly unrelated. A real embedder
puts them right next to each other.

That difference shows up directly in the agent's prompt:

- **Weak embedder** → top-K is unreliable → either the agent
  hallucinates (wrong row in context) or it compensates by stuffing
  K=15 into the prompt (token waste).
- **Real embedder** → top-K is trustworthy → you can safely lower K
  (see `eval/tune_weights.lua`).

In short: every other tuning lever in the library multiplies the
embedder's quality. If you skip this step the others are polishing the
rim of a shallow bowl.

---

## Recommended path: Ollama + `nomic-embed-text` (free, local)

Best default for self-hosted setups. Runs alongside your Postgres in
Docker, no API key, no per-call cost.

### 1. Run Ollama

```bash
docker run -d --name ollama -p 11434:11434 -v ollama:/root/.ollama ollama/ollama
docker exec -it ollama ollama pull nomic-embed-text
```

### 2. Configure `luamemo`

```lua
require("luamemo").setup({
    db_table         = "lapis_memory",
    embedder_url     = "http://localhost:11434/api/embeddings",
    embedder_adapter = "ollama",
    embedder_model   = "nomic-embed-text",
    embed_dim        = 768,                -- nomic-embed-text dim
    auth_fn          = function(self) return your_auth_check(self) end,
})
```

That's it. The library does a one-shot probe at startup; if Ollama is
down or `embed_dim` is wrong, `setup()` fails fast with a clear error
before the app accepts any writes.

### Going further: `bge-m3` via TEI sidecar (high-accuracy)

`nomic-embed-text` is a great default but has two limits worth knowing:
its **context window is ~2,048 tokens** (long sessions get truncated)
and it is **English-tuned** (recall drops on non-English content).

[BAAI/bge-m3](https://huggingface.co/BAAI/bge-m3) supports an
**8,192-token context** (4× nomic) and **100+ languages**, and on
LongMemEval it lifts **R@5 from 81.5% → 93.5% (+12 pp)** and
**R@1 from 62% → 80% (+18 pp)** vs `nomic-embed-text` with no other
code changes (Phase 16.1, n=200, see
[`eval/results/longmemeval.md`](eval/results/longmemeval.md)).

> **Don't run `bge-m3` on Ollama.** Ollama's `bge-m3` server returns
> NaN embeddings on long inputs (issues #15582, #14657, #11856,
> #9639, PR #14739). Use the
> [text-embeddings-inference](https://github.com/huggingface/text-embeddings-inference)
> sidecar instead — it honors the model and truncates correctly.

#### 1. Run TEI

```bash
docker run -d --name lapis-tei-embed --gpus all \
  -p 127.0.0.1:8081:80 \
  -e MODEL_ID=BAAI/bge-m3 \
  -e DTYPE=float16 \
  -e MAX_BATCH_TOKENS=4096 \
  ghcr.io/huggingface/text-embeddings-inference:1.7
```

For Turing-class GPUs (RTX 2060 / Quadro RTX, sm_75) use
`:turing-1.7`. For CPU-only hosts use `:cpu-1.7` and drop `--gpus`.
Resident VRAM with fp16 is ~2 GB. A reference standalone compose is
shipped at
[`eval/sidecars/docker-compose.yml`](eval/sidecars/docker-compose.yml)
and the operator notes are at
[`eval/sidecars/tei.md`](eval/sidecars/tei.md).

#### 2. Configure `luamemo`

```lua
require("luamemo").setup({
    db_table         = "lapis_memory",
    embedder_url     = "http://localhost:8081/embed",
    embedder_adapter = "tei",
    embedder_model   = "BAAI/bge-m3",
    embed_dim        = 1024,                -- bge-m3 dim, NOT 768
    auth_fn          = function(self) return your_auth_check(self) end,
})
```

> **Dim mismatch is fatal.** Switching from `nomic-embed-text` (768) to
> `bge-m3` (1024) means existing rows have the wrong-sized vector.
> Either start a fresh DB or re-embed every row with
> `memory.maintenance.reembed_scope()`. The startup probe will catch
> this before any new write goes in.

> **Don't add a noop reranker on top of bge-m3.** With a strong
> embedder the lexical token-overlap reranker shuffles good
> candidates downward (Phase 16.1: R@1 −7.5 pp). Rerank only adds
> value on top of weaker embedders like `nomic-embed-text`.

---

## Hosted path: OpenAI `text-embedding-3-small`

Best when you don't want to operate Ollama. ~$0.02 per 1M input
tokens, well-understood quality.

```lua
require("luamemo").setup({
    db_table         = "lapis_memory",
    embedder_url     = "https://api.openai.com/v1/embeddings",
    embedder_adapter = "openai",
    embedder_model   = "text-embedding-3-small",
    embed_dim        = 1536,
    embedder_headers = {
        Authorization = "Bearer " .. os.getenv("OPENAI_API_KEY"),
    },
    auth_fn          = function(self) return your_auth_check(self) end,
})
```

For `text-embedding-3-large` use `embed_dim = 3072`.

---

## Other adapters

The library ships these out of the box. Each adapter's source file at
the path below documents its exact `setup()` shape.

| Adapter   | Source                                         | Typical model + dim                         |
|-----------|------------------------------------------------|---------------------------------------------|
| TEI       | [`luamemo/adapters/tei.lua`](luamemo/adapters/tei.lua) | `BAAI/bge-m3` / 1024 (sidecar, see above)   |
| Voyage    | [`luamemo/adapters/voyage.lua`](luamemo/adapters/voyage.lua)   | `voyage-3` / 1024                           |
| Cohere    | [`luamemo/adapters/cohere.lua`](luamemo/adapters/cohere.lua)   | `embed-english-v3.0` / 1024                 |
| Anthropic | [`luamemo/adapters/anthropic.lua`](luamemo/adapters/anthropic.lua) | placeholder (no first-party embedding API as of writing) |
| DeepSeek  | [`luamemo/adapters/deepseek.lua`](luamemo/adapters/deepseek.lua) | placeholder                                 |
| generic   | [`luamemo/adapters/generic.lua`](luamemo/adapters/generic.lua) | any OpenAI-shaped endpoint                   |

If your provider is not listed, copy `generic.lua` and override the
two functions (`build_request`, `parse_response`).

---

## Startup health check

When `embedder_local` is anything other than `"hash"`, `setup()`
automatically embeds the string `"probe"` and verifies the returned
vector dimension matches `embed_dim`. On mismatch it raises a clear
error and refuses to start:

```
setup() embed probe failed: HTTP 401: { "error": "invalid_api_key" }
  Check embedder_url / embedder_model / network access.
  To bypass during offline testing, pass `skip_embed_probe = true`.
```

This catches the three classic foot-guns: wrong URL, wrong API key,
wrong dim. Fail-fast in production; opt-out (`skip_embed_probe =
true`) in offline tests.

### Corpus health check (`memo doctor`)

A second, **runtime** check looks at the corpus you've already written
and asks: *does the embedder still fit the data?* Set
`corpus_health_check = true` in `setup()` and the library runs one
read-only aggregate query at boot, emitting `ngx.log(WARN)` lines when
thresholds trip:

- ≥ 1% of rows had their input truncated by the embedder client (see
  `embed_max_chars` below) — switch to a larger-context embedder.
- The brute-force backend is holding > 100k rows — install pgvector.

The same query is exposed as `M.corpus_health_check()` and rendered as
a structured report by `memo doctor`. Doctor exits non-zero (CI-friendly)
when truncation exceeds 10%.

### Per-embedder safe input length (`embed_max_chars`)

Most embedders have a hard token-context limit (nomic-embed-text 2048;
bge-m3 8192; OpenAI v3 8191). Sending a longer payload either errors
or, worse, silently truncates without telling you. Setting
`embed_max_chars = N` makes the library clip text to `N` characters
*before* embedding and flag the row's `was_truncated` column so
`memo doctor` can count them.

| Embedder                  | Recommended `embed_max_chars` |
|---------------------------|-------------------------------|
| `nomic-embed-text`        | 6000                          |
| `bge-m3` (TEI)            | 24000                         |
| `text-embedding-3-*`      | 24000                         |
| `voyage-3`                | 90000                         |
| `embed-english-v3.0`      | 1500                          |

`memo calibrate` writes the right value into the snippet automatically.

---

## The dim-mismatch trap

If you switch embedders **after** writing rows you have a problem:

1. Existing rows have vectors of the **old** embedder's dimension.
2. New writes have vectors of the **new** embedder's dimension.
3. Cosine similarity between them is meaningless / errors out.

There are two correct ways to handle this:

### Option A — drop and rebuild (easiest, lossy)

If the data is regenerable (test data, scratch scope, etc.):

```sql
-- pgvector backend: column type encodes dim, must be re-created
DROP TABLE lapis_memory;
-- then re-run luamemo/schema_pgvector.sql with the new VECTOR(N)
```

For the brute-force backend (`REAL[]`) the column has no fixed dim so
you can just `TRUNCATE lapis_memory` and re-write your data.

### Option B — re-embed in place (preserves data)

Run the helper:

```bash
PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=mydb \
  lua5.1 eval/reembed.lua --scope your_scope
```

This walks every row, calls `embed.embed(title || body)`, and updates
the `embedding` column in batches. For pgvector users with a different
target dim, drop+re-create the column first (see EMBEDDERS.md
recipes), then run `reembed.lua`.

Re-runs are idempotent: rows whose title+body fingerprint is already
recorded as up-to-date are skipped.

---

## Verification after switching

1. Pick a query you know the right answer to. Run it with `memo
   search` (or the Web UI) **before** the switch and note the top-5.
2. Switch the embedder and re-embed.
3. Run the same query. Top-5 should now include semantically related
   rows that the hash embedder would have missed (synonyms, paraphrases,
   different wording of the same concept).
4. Re-run `eval/tune_weights.lua --scope your_scope` — with a real
   embedder you should see R@5 climb sharply on most corpora.

> See [eval/results/recall_bench.md](eval/results/recall_bench.md) for a
> reproducible side-by-side run on a 33-question paraphrased corpus —
> swapping `hash` → `nomic-embed-text` lifts recall@1 from 63.6% to
> 84.8% with no other code changes.

---

## Lever order

| # | Lever                | Where it's documented            |
|---|----------------------|----------------------------------|
| 1 | Real embedder        | **this file**                    |
| 2 | Scope writes properly| [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md) |
| 3 | Tune `hybrid_weights`| [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md) |
| 4 | Reranker             | future                           |

Work top-down. Don't tune things below something you haven't done yet.
