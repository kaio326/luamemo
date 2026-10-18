# Embedders — switch off `hash`

> **TL;DR:** the default `hash` embedder is a fallback, not a peer of a real
> embedding model. Switching to a real one is the single biggest accuracy lever
> luamemo has — see [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md) for why.

**Don't want to read?** Run `memo calibrate` in your project. It looks at the
machine (GPU, RAM, Docker, a running Ollama or TEI, the in-process GGUF
embedder), picks the best embedder that **answers a real embedding here**, and
writes its settings into the project's `.luamemorc`. When it can't find a
working one, it says what to start. Afterwards `memo ping` checks the embedder,
and `memo doctor` reports how well it fits your memories (how many were cut to
fit, row sizes).

Everything below is set with `memo config set NAME VALUE` (the project's
`.luamemorc`; `--user` for every project) — [SETTINGS.md](SETTINGS.md) has every
embedder setting.

---

## Why this matters

`hash` is feature hashing: fast, deterministic, nothing to install, no network —
and **semantically blind**. It sees `"docker deploy"` and `"docker compose up"`
as nearly unrelated; a real embedder puts them side by side. That shows up in
the agent's prompt:

- **weak embedder** → the top K is unreliable → the agent either answers from
  the wrong memory or compensates by asking for K = 15 (wasted tokens);
- **real embedder** → the top K is trustworthy → a smaller K is safe
  (`memo tune-weights` measures it).

Every other lever multiplies the embedder's quality.

---

## The options

| Embedder | Runs | Quality | Setup |
|---|---|---|---|
| `hash` | in-process, pure Lua | lexical only | none (the default) |
| `gguf_ffi` (EmbeddingGemma) | in-process, CPU (GPU optional) | semantic, bge-m3 class | a one-time build + a 320 MB model |
| Ollama `nomic-embed-text` | a local service | semantic, English-tuned, 2,048-token context | `ollama pull nomic-embed-text` |
| TEI `bge-m3` | a local service (GPU or CPU) | the best measured; 8,192 tokens, 100+ languages | one `docker run` |
| OpenAI, Voyage, Cohere, OpenAI-compatible | hosted | semantic | an API key in the vault |

On LongMemEval `_s` (n = 200), switching `nomic-embed-text` → `bge-m3` lifted
**R@5 from 81.5 % to 93.5 %** and **R@1 from 62 % to 80 %** with no other change
([eval/results/longmemeval.md](eval/results/longmemeval.md)).

---

## In-process: `gguf_ffi` (no service)

A GGUF embedding model runs inside luamemo's own process through LuaJIT's FFI and
a small C shim over llama.cpp — no HTTP service, no vendor API, weights you keep.
The default model is **EmbeddingGemma-300M** (768 dimensions); any
llama.cpp-compatible GGUF embedding model works.

`memo calibrate` picks it only once it actually works on the machine (the
runtime installed, model present, a test embedding succeeds). Until then it
configures a working embedder and prints this setup as an optional upgrade.

The runtime — `gguf_shim.so` and the llama.cpp libraries — comes prebuilt with
each release for Linux x86_64 (a CPU with AVX2) and macOS arm64: `memo calibrate`
offers it, or run `memo gguf install`. It is downloaded from the release's GitHub
assets, checked against the SHA-256 the installed rock ships, unpacked into
`~/.local/share/luamemo/native/<version>-<platform>/` and recorded as
`MEMO_GGUF_SHIM` in `~/.luamemorc`. `memo gguf status` shows what is in use.
Elsewhere (or with a CUDA build), step 1 builds it — a C toolchain and cmake, and
the llama.cpp release luamemo is tested against:

```bash
# 1. the runtime: memo gguf install — or llama.cpp (shared libraries) and the shim
git clone --depth 1 --branch b9976 https://github.com/ggml-org/llama.cpp ~/llama.cpp
cmake -B ~/llama.cpp/build -S ~/llama.cpp -DBUILD_SHARED_LIBS=ON -DGGML_CUDA=OFF -DLLAMA_CURL=OFF \
      -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF \
      -DLLAMA_BUILD_TOOLS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build ~/llama.cpp/build --target llama -j
LLAMA_DIR=~/llama.cpp bash <luamemo>/luamemo/embedders/native/build.sh

# 2. the model (~320 MB)
mkdir -p ~/models && curl -sL -o ~/models/embeddinggemma-300M-Q8_0.gguf \
  https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf

# 3. check: the GGUF line must say "ready"
memo calibrate --probe-only

# 4. switch the project, then re-embed what is stored
memo config set MEMO_EMBEDDER gguf_ffi
memo config set MEMO_GGUF_MODEL ~/models/embeddinggemma-300M-Q8_0.gguf
memo config set MEMO_EMBED_DIM 768
memo config unset MEMO_EMBEDDER_URL
memo reembed --all
```

`MEMO_GGUF_NGL` offloads layers to a GPU when llama.cpp is built with CUDA;
`MEMO_GGUF_NCTX` sets the context (2,048). `--no-gguf` keeps calibrate from
suggesting it.

---

## Ollama + `nomic-embed-text` (local, free)

```bash
ollama pull nomic-embed-text          # Linux: curl -fsSL https://ollama.com/install.sh | sh
memo config set MEMO_EMBEDDER_ADAPTER ollama
memo config set MEMO_EMBEDDER_URL http://localhost:11434/api/embeddings
memo config set MEMO_EMBEDDER_MODEL nomic-embed-text
memo config set MEMO_EMBED_DIM 768
memo ping --embedder
```

> **Don't run `bge-m3` on Ollama.** Ollama's `bge-m3` returns NaN embeddings on
> long inputs (issues #15582, #14657, #11856, #9639). Use TEI for it.

## TEI + `bge-m3` (the best measured)

[text-embeddings-inference](https://github.com/huggingface/text-embeddings-inference):

```bash
docker run -d --name tei-embed --gpus all -p 127.0.0.1:8081:80 \
  -e MODEL_ID=BAAI/bge-m3 -e DTYPE=float16 -e MAX_BATCH_TOKENS=4096 \
  ghcr.io/huggingface/text-embeddings-inference:1.7

memo config set MEMO_EMBEDDER_ADAPTER tei
memo config set MEMO_EMBEDDER_URL http://127.0.0.1:8081/embed
memo config set MEMO_EMBEDDER_MODEL BAAI/bge-m3
memo config set MEMO_EMBED_DIM 1024
```

Turing GPUs (RTX 20xx, sm_75) use the `:turing-1.7` image; CPU-only hosts
`:cpu-1.7` without `--gpus`. With fp16 it needs ~2 GB of VRAM; on WSL2 with a
GPU, `--dtype float16` and a bounded `--max-batch-tokens` avoid out-of-memory
crashes. A reference compose file is in
[eval/sidecars/](eval/sidecars/docker-compose.yml) ([notes](eval/sidecars/tei.md)).
calibrate finds a running TEI container by itself.

> **No `noop` reranker on top of bge-m3**: with a strong embedder the
> word-overlap pass shuffles good candidates down (R@1 −7.5 points measured).

## Hosted: OpenAI, Voyage, Cohere

The API key goes into the vault, never into a settings file:

```bash
memo secret-store openai --desc "OpenAI API key"      # prompts, no echo
memo config set MEMO_EMBEDDER_ADAPTER openai
memo config set MEMO_EMBEDDER_URL https://api.openai.com/v1/embeddings
memo config set MEMO_EMBEDDER_MODEL text-embedding-3-small
memo config set MEMO_EMBED_DIM 1536                    # text-embedding-3-large: 3072
memo config set MEMO_EMBEDDER_HEADERS '{"Authorization": "Bearer {secret:openai}"}'
```

`{secret:openai}` is read from the vault when each request is made and masked
in errors; `memo config set` refuses a header holding a key in plain text. If
calibrate meets an embedder that answers 401 / 403, it prints this recipe.

| Adapter | Typical model / dimension | Notes |
|---|---|---|
| `openai` | `text-embedding-3-small` / 1536 | |
| `openai_compatible` | any | vLLM, LM Studio, … — the OpenAI request shape |
| `voyage` | `voyage-3` / 1024 | `MEMO_EMBEDDER_INPUT_TYPE` |
| `cohere` | `embed-english-v3.0` / 1024 | `MEMO_EMBEDDER_INPUT_TYPE` (default `search_document`) |
| `generic` | any | `POST {"text": …}` → `{"vector": […]}` — e.g. [examples/python_embedder](examples/python_embedder/) |
| `anthropic`, `deepseek` | — | placeholders: no embeddings API yet |

A provider that isn't listed: copy `luamemo/adapters/generic.lua` and change its
two functions (`build_request`, `parse_response`).

---

## Startup check

With any embedder but `hash`, luamemo embeds the word `"probe"` at startup and
checks the vector's size against `MEMO_EMBED_DIM`; a wrong URL, key, model or
dimension fails there with a clear message (the dimension one says the
`memo config set` that fixes it). While the embedder is down, luamemo retries it at
most every `MEMO_ENSURE_READY_RETRY_SECS` (10) instead of on every call;
`MEMO_SKIP_EMBED_PROBE=true` skips the startup check (offline tests, a slow
GPU sidecar).

## Inputs too long for the model

Most models have a context limit (nomic-embed-text 2,048 tokens; bge-m3 8,192;
OpenAI 8,191). When an embedder rejects an input as too long, luamemo halves it
and retries (a few times, never below 256 characters), flags the memory
`was_truncated` and keeps its full text; if the embedder still refuses, the
memory is stored without a vector — found by its words — and the write says so.
Nothing is dropped.

`MEMO_EMBED_MAX_CHARS` cuts text up front instead (calibrate sets it to fit the
model it picks):

| Embedder | `MEMO_EMBED_MAX_CHARS` |
|---|---|
| `nomic-embed-text` | 6000 |
| `bge-m3` (TEI) | 24000 |
| `text-embedding-3-*` | 24000 |
| `voyage-3` | 90000 |
| `embed-english-v3.0` | 1500 |

`memo doctor` counts the truncated memories (and exits non-zero above 10 %);
`MEMO_CORPUS_HEALTH_CHECK=true` prints its warning at startup. Many truncated
memories mean the model's context is too small for what you store.

---

## Switching embedders

A database holds **one embedding space**: vectors from two models never compare,
even at the same dimension. The first vector stored fixes the database's
dimension, and a vector of another size is refused with the fix:

```
this database holds 384-dimension vectors and the embedder gave 768 — use the
database's embedder, or move the database to this one with `memo reembed` (every scope)
```

To switch, change the settings, then:

```bash
memo reembed --all            # every scope (an org replica re-syncs by itself)
memo reembed --scope repo:x   # or one scope at a time; --dry-run counts first
```

Each memory's vector is rebuilt from its stored text — nothing is lost. Once no
vector of the old size is left, the database takes the new dimension. Until
then, memories not re-embedded yet are still found by their words. A model with
the **same** dimension isn't refused, but its old vectors are just as stale:
re-embed then too. `memo config set` reminds you whenever an embedder setting
changes; restart the MCP server in your client so it picks the new settings up
(`memo mcp` reads `.luamemorc` when it starts).

## Checking the switch

1. Before switching, pick a query whose right answer you know and note the top 5
   of `memo search`.
2. Switch and re-embed.
3. Run it again: the top 5 should now hold memories that say the same thing in
   other words (synonyms, paraphrases).
4. `memo tune-weights --scope your_scope` — with a real embedder, recall
   usually climbs sharply, and the best blend may move toward `vector`.

`memo embed "deploy the app" --compare-to "ship to production"` shows how close
two phrasings are to the embedder.

> [eval/results/recall_bench.md](eval/results/recall_bench.md) has a
> reproducible run on a 33-question paraphrased corpus: `hash` →
> `nomic-embed-text` lifts R@1 from 63.6 % to 84.8 %.

---

## Lever order

| # | Lever | Where |
|---|---|---|
| 1 | A real embedder | **this file** |
| 2 | Scope writes properly | [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md) |
| 3 | `since` / `until` | [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md) |
| 4 | Tune the blend (`memo tune-weights`) | [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md) |
| 5 | A reranker | [RETRIEVAL_TUNING.md](RETRIEVAL_TUNING.md) |
