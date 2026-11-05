# TEI sidecar — `bge-reranker-v2-m3` for `cross_encoder` rerank adapter

The `luamemo.rerankers.cross_encoder` adapter requires an
external rerank service (Ollama does not host cross-encoder models
as of 0.23.x). The reference target is HuggingFace's
[`text-embeddings-inference`](https://github.com/huggingface/text-embeddings-inference)
(TEI), which exposes a native `POST /rerank` endpoint.

> **Note:** This file documents **two** TEI sidecars:
> 1. **Rerank**  (`bge-reranker-v2-m3` on port 8082) — bench port; 8080 is reserved on this host (portfolio app).
> 2. **Embed** (`bge-m3` on port 8081) — added for Phase 16.1 because
>    Ollama's `bge-m3` path returns NaN on inputs >~600 chars
>    ([ollama/ollama#15582](https://github.com/ollama/ollama/issues/15582)).
>
> Ollama is **not** replaced by either sidecar — it remains the
> documented default for `nomic-embed-text` and any model that works
> there. TEI runs **alongside** Ollama purely for `bge-m3` and
> cross-encoder rerank.

---

## Part 1 — Rerank sidecar (`bge-reranker-v2-m3`, port 8082)

## docker-compose stub

The reference is the shipped file, [`docker-compose.yml`](docker-compose.yml)
(service `tei-reranker`: image `turing-1.7`, or `cpu-1.7` without a GPU;
`MAX_BATCH_TOKENS: "4096"`; port 8082). Use it as it is, or copy that service
into your own compose file.

Pull and start:

```bash
docker compose -f eval/sidecars/docker-compose.yml up -d tei-reranker
docker compose -f eval/sidecars/docker-compose.yml logs -f tei-reranker   # wait for "Ready"
```

## Quick sanity check

```bash
curl -s -X POST http://127.0.0.1:8082/rerank \
  -H 'Content-Type: application/json' \
  -d '{"query":"who painted the Mona Lisa?",
       "texts":["Leonardo da Vinci painted the Mona Lisa.",
                "Bananas are yellow.",
                "The Mona Lisa hangs in the Louvre."],
       "raw_scores":false}'
# -> [{"index":0,"score":0.99},{"index":2,"score":0.71},{"index":1,"score":0.01}]
```

## Wiring into `luamemo`

```bash
memo config set MEMO_RERANK_ADAPTER cross_encoder
memo config set MEMO_RERANK_URL http://127.0.0.1:8082/rerank
memo config set MEMO_RERANK_MODEL BAAI/bge-reranker-v2-m3   # ignored by TEI; sent for Cohere/Jina
memo config set MEMO_RERANK_TOP_N 20
memo search "…" --scope repo:my-app --rerank on              # or MEMO_RERANK_ENABLED true
```

For a Cohere or Jina hosted endpoint, point `MEMO_RERANK_URL` at
`https://api.cohere.com/v1/rerank` (or the Jina equivalent), set
`MEMO_RERANK_MODEL` to `rerank-english-v3.0` (or the Jina equivalent), store
the API key with `memo secret-store cohere` and set
`MEMO_RERANK_HEADERS '{"Authorization": "Bearer {secret:cohere}"}'`.

## Resource cost

- **Image size:** ~1.6 GB (CPU), ~3.2 GB (GPU).
- **Model weights:** `bge-reranker-v2-m3` is ~2.3 GB on disk
  (same architecture as bge-m3; multilingual, 8192-token context).
- **Latency:** GPU ~5–20 ms per (query, 20 candidates) batch on
  RTX 2060; overhead per query vs. no-rerank measured at ~0.43 s.
- **VRAM:** ~2.3 GB on GPU (float16), same as bge-m3 embedder.

## Bench results (Phase 16.3, 2026-05-06)

(Measured in May 2026 on the previous PostgreSQL store; the current numbers are
in [`eval/README.md`](../README.md) and `eval/baselines.json`.)

Bench executed. `bge-m3` (TEI, port 8081) + `bge-reranker-v2-m3`
(TEI, port 8082), n=200, `longmemeval_s`.

| Config                              | elapsed | R@1   | R@5   | R@10  | R@20  | MRR   |
|-------------------------------------|--------:|------:|------:|------:|------:|------:|
| TEI bge-m3, no rerank               |  1508 s | 0.800 | 0.935 | 0.965 | 0.995 | 0.862 |
| TEI bge-m3, rerank=noop top_n=20    |  1492 s | 0.725 | 0.925 | 0.975 | 0.995 | 0.809 |
| TEI bge-m3 + cross_encoder top_n=20 |  1594 s | 0.800 | 0.935 | 0.965 | 0.995 | 0.862 |

**Result: NEUTRAL — cross-encoder matched no-rerank exactly.**
Zero improvement over bge-m3 no-rerank. The reranker and embedder
share the same bge-m3 base; they carry the same information and
agree on ordering. Adapter remains shipped for non-same-family
pairings (Cohere Rerank v3, Jina Reranker v2, domain-fine-tuned),
but is not recommended with `bge-m3` + `bge-reranker-v2-m3`.

See `eval/results/longmemeval.md` § Phase 16.3 for full analysis.

---

## Part 2 — Embed sidecar (`bge-m3`, port 8081)

The `luamemo.adapters.tei` embedder adapter targets a TEI
sidecar hosting `BAAI/bge-m3` (1024-dim, 8192-token context, 100+
languages). Reason this exists: Ollama's `bge-m3` path returns NaN
embeddings on inputs >~600 chars (upstream bug). TEI hosts the same
HF reference weights and produces faithful, comparable-to-published
numbers.

### docker-compose stub

> A working standalone compose for both sidecars (rerank + embed) is
> shipped at `eval/sidecars/docker-compose.yml`. It is intentionally
> separate from any host project's `docker-compose.yml` so the
> bench-only sidecars do not pollute production deployments.

The reference for the embed sidecar is that file (service `tei-embed`: image
`turing-1.7` for Turing cards, `1.7` for Ampere/Ada, `hopper-1.7` for Hopper,
`cpu-1.7` without a GPU — drop `deploy.resources` then; `DTYPE: float16`, which
halves VRAM; port 8081). Its `MAX_BATCH_TOKENS: "7168"` and `AUTO_TRUNCATE: "true"`
matter: with a lower `MAX_BATCH_TOKENS` TEI hangs, without an error, on any input
longer than that many tokens (LongMemEval sessions reach ~7k).

Pull and start (standalone compose):

```bash
# Verify free VRAM before pulling (bge-m3 needs ~3 GB free).
nvidia-smi --query-gpu=name,memory.free --format=csv,noheader,nounits 2>/dev/null \
    || echo "nvidia-smi not available — use the cpu-1.7 image tag instead"

cd luamemo
docker compose -f eval/sidecars/docker-compose.yml up -d tei-embed
docker compose -f eval/sidecars/docker-compose.yml logs -f tei-embed   # wait for "Ready"
```

> **TEI 1.5 is broken** for `bge-m3`: it fails the `config.json`
> download with `relative URL without a base`. Use `:turing-1.7`
> (Turing) or `:1.7` (Ampere+) — both are the canonical builds.
>
> **First boot downloads `pytorch_model.bin` (~2.3 GB)** because
> `bge-m3` does not publish a `model.safetensors`. TEI logs a 404
> WARN about it — this is benign. Total first-boot wall-clock is
> ~2 min (download) + ~10 s (GPU init).

### Quick sanity check (the input that breaks Ollama bge-m3)

```bash
# A >700-char input — Ollama's bge-m3 returns NaN on this; TEI does not.
TEXT=$(python3 -c "print('lorem ipsum dolor sit amet '*40)")
curl -s -X POST http://127.0.0.1:8081/embed \
  -H 'Content-Type: application/json' \
  -d "{\"inputs\":\"$TEXT\"}" | jq '.[0] | length'
# -> 1024
```

### Wiring into `luamemo`

```bash
memo config set MEMO_EMBEDDER_ADAPTER tei
memo config set MEMO_EMBEDDER_URL http://127.0.0.1:8081/embed
memo config set MEMO_EMBEDDER_MODEL BAAI/bge-m3   # documentation only
memo config set MEMO_EMBED_DIM 1024
memo reembed --all                                # if the project already has memories
```

(`memo calibrate` finds a running TEI container and sets this up by itself.)

### Resource cost (measured 2026-05-05, RTX 2060 6 GB)

- **Image size:** ~1.6 GB (CPU), ~3.0 GB (GPU `turing-1.7`).
- **Model weights:** `bge-m3` is ~2.2 GB (`pytorch_model.bin`,
  no safetensors published upstream).
- **VRAM:** ~2.0 GB resident on GPU with `DTYPE=float16` (measured with
  `MAX_BATCH_TOKENS=4096`; the shipped file uses 7168, which is the ceiling on
  a 6 GB card).
- **Latency:** GPU ~5–20 ms per single embed; CPU ~80–250 ms.
- **First-boot:** ~2 min weight download + ~10 s GPU init.

### Bench protocol (Phase 16.1)

```bash
cd luamemo
docker compose -f eval/sidecars/docker-compose.yml up -d tei-embed
# wait for "Ready" in `docker compose logs tei-embed`

# bench: bge-m3 via TEI, baseline (no rerank) — MEMO_DB: a scratch database
MEMO_NO_MAINTENANCE=1 MEMO_DB=bench TEI_URL=http://127.0.0.1:8081/embed TEI_DIM=1024 \
  luajit eval/longmemeval_run.lua --embedder tei \
    --corpus eval/data/longmemeval_s.json --n 200 \
    --out eval/results/longmemeval_tei_bge-m3_s_n200.json

# bench: bge-m3 via TEI + noop rerank
MEMO_NO_MAINTENANCE=1 MEMO_DB=bench TEI_URL=http://127.0.0.1:8081/embed TEI_DIM=1024 \
  luajit eval/longmemeval_run.lua --embedder tei \
    --corpus eval/data/longmemeval_s.json --n 200 \
    --rerank --rerank-adapter noop --rerank-top-n 20 \
    --out eval/results/longmemeval_tei_bge-m3_s_n200_rerank-noop.json
```

**Result (closed 2026-05-05, measured on the previous PostgreSQL store; the
current numbers are in [`eval/README.md`](../README.md)):** `bge-m3` via TEI lifts R@5 from
81.5% → 93.5% (+12 pp) and R@1 from 62% → 80% (+18 pp) over the
`nomic-embed-text` baseline at n=200. See
[`eval/results/longmemeval.md`](../results/longmemeval.md) Phase
16.1 section. `bge-m3` + TEI is now the recommended high-accuracy
embedder in [`EMBEDDERS.md`](../../EMBEDDERS.md); `nomic-embed-text`
+ Ollama remains the budget option (no extra container, no GPU).
