# TEI sidecar — `bge-reranker-v2-m3` for `cross_encoder` rerank adapter

The `lapis_memory.rerankers.cross_encoder` adapter requires an
external rerank service (Ollama does not host cross-encoder models
as of 0.23.x). The reference target is HuggingFace's
[`text-embeddings-inference`](https://github.com/huggingface/text-embeddings-inference)
(TEI), which exposes a native `POST /rerank` endpoint.

## docker-compose stub

Append to your `docker-compose.yml`:

```yaml
services:
  tei-reranker:
    # CPU image; for GPU use ghcr.io/huggingface/text-embeddings-inference:1.5
    image: ghcr.io/huggingface/text-embeddings-inference:cpu-1.5
    container_name: lapis-tei-reranker
    environment:
      MODEL_ID: BAAI/bge-reranker-v2-m3
      MAX_CLIENT_BATCH_SIZE: 32
      MAX_BATCH_TOKENS: 16384
    ports:
      - "127.0.0.1:8080:80"
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:80/health || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
```

Pull and start:

```bash
docker compose up -d tei-reranker
docker compose logs -f tei-reranker   # wait for "Ready"
```

## Quick sanity check

```bash
curl -s -X POST http://127.0.0.1:8080/rerank \
  -H 'Content-Type: application/json' \
  -d '{"query":"who painted the Mona Lisa?",
       "texts":["Leonardo da Vinci painted the Mona Lisa.",
                "Bananas are yellow.",
                "The Mona Lisa hangs in the Louvre."],
       "raw_scores":false}'
# -> [{"index":0,"score":0.99},{"index":2,"score":0.71},{"index":1,"score":0.01}]
```

## Wiring into `lapis-memory`

```lua
local memory = require("lapis_memory")
memory.setup({
    -- ... regular config ...
    rerank_url   = "http://127.0.0.1:8080/rerank",
    rerank_model = "BAAI/bge-reranker-v2-m3",   -- ignored by TEI; sent for Cohere/Jina compat
})

local hits = memory.search({
    query  = "...",
    scope  = "...",
    limit  = 20,
    rerank = "cross_encoder",
    rerank_top_n = 20,
})
```

For a Cohere or Jina hosted endpoint, point `rerank_url` at
`https://api.cohere.com/v1/rerank` (or the Jina equivalent), set
`rerank_model = "rerank-english-v3.0"` (or jina equivalent) and pass
the API key via `rerank_headers = { Authorization = "Bearer ..." }`.

## Resource cost

- **Image size:** ~1.6 GB (CPU), ~3.2 GB (GPU).
- **Model weights:** `bge-reranker-v2-m3` is 568 MB on disk
  (multilingual, 8192-token context).
- **Latency:** CPU ~50–200 ms per (query, 20 candidates) batch on
  modern x86; GPU ~5–20 ms.
- **RAM:** ~3 GB resident on CPU; ~2 GB VRAM on GPU.

## Bench protocol (Phase 16.3)

The Phase 16.3 head-to-head against `noop` is **deferred** until the
sidecar is brought up. Once running, repeat the Phase 16.2 protocol:

```bash
# config 1: rerank=noop, top_n=20    (already measured in Phase 16.2)
# config 2: rerank=cross_encoder, top_n=20
PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test \
  OLLAMA_MODEL=nomic-embed-text OLLAMA_DIM=768 \
  RERANK_URL=http://127.0.0.1:8080/rerank \
  lua5.1 eval/longmemeval_run.lua --embedder ollama \
    --corpus eval/data/longmemeval_s.json --n 200 \
    --rerank --rerank-adapter cross_encoder --rerank-top-n 20 \
    --out eval/results/longmemeval_ollama_s_n200_rerank-bge-v2-m3.json
```

**Decision rule:** if cross_encoder beats noop by ≥ +5 pp R@1 *and*
p95 latency stays under 1.5 s/query, document as the recommended
high-quality config in `RETRIEVAL_TUNING.md`. Otherwise mark adapter
shipped but not recommended.

## LIMITATION (2026-05-04)

This sidecar is not currently running in any deployment. The adapter
file `lapis_memory/rerankers/cross_encoder.lua` is shipped and
unit-testable against any TEI-compatible HTTP endpoint, but the
end-to-end LongMemEval head-to-head bench has not yet been executed.
Phase 16.3 will close out only after the sidecar bench is measured.
