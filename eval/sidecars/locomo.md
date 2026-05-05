# LoCoMo bench — download + run protocol

LoCoMo (Maharana et al., 2024) is a public conversational-memory
benchmark with very long, multi-session conversations and per-row QA
pairs categorised as single-hop, multi-hop, temporal, open-domain, and
adversarial. Live numbers are gated on a download; the loader, runner,
and smoke test are shipped without it (see Phase 16.6a in
`.github/upgrades-memory`).

## Provenance & licence

- Source: `snap-research/locomo` on **GitHub** (the `snap-research/locomo`
  Hugging Face dataset referenced in older docs **does not exist** as of
  2026-05; the corpus is GitHub-only).
- Canonical raw URL (no auth required):
  `https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json`
- Citation: Maharana, Lee, Tulyakov, Bansal — *Evaluating Very
  Long-Term Conversational Memory of LLM Agents* (NAACL 2024)
- Licence: MIT (verify against the upstream repo before redistributing)

## Schema verified by the loader

```jsonc
{
  "sample_id": "...",
  "conversation": {
    "session_1":            [ { "speaker", "text", "dia_id" }, ... ],
    "session_1_date_time":  "...",
    "session_2":            [ ... ],
    "session_2_date_time":  "...",
    ...
  },
  "qa": [
    {
      "question": "...",
      "answer":   "...",
      "category": 1,       // 1=single-hop 2=multi-hop 3=temporal 4=open-domain 5=adversarial
      "evidence": ["D1:5", "D2:3"]
    }
  ]
}
```

`evidence` strings are dialogue ids in `D<sess_no>:<turn_no>` form;
the loader converts them to `session_<sess_no>` ids that match the
ingested memories. If the upstream JSON shape differs from this
contract, fix `eval/datasets/locomo.lua` first and re-run
`eval/smoke_locomo.lua` before any live bench.

## Download

The corpus is a single JSON file on GitHub raw — **no auth required**:

```bash
mkdir -p eval/data
curl -sL -o eval/data/locomo.json \
  https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json
```

Expected size as of 2026-05: ~2.8 MB, 10 dialogues, 292 sessions, 1986 QAs
(282 single-hop, 321 multi-hop, 96 temporal, 841 open-domain, 446 adversarial).

Verify the schema matches the loader before running:

```bash
lua5.1 -e 'local cjson=require"cjson.safe"; local f=io.open("eval/data/locomo.json","rb"); \
  local rows=cjson.decode(f:read("*a")); print(#rows, "rows"); \
  local r=rows[1]; print("keys:"); for k in pairs(r) do print("  "..k) end; \
  print("conversation keys:"); for k in pairs(r.conversation or {}) do print("  "..k) end; \
  print("qa[1] keys:"); for k in pairs((r.qa or {})[1] or {}) do print("  "..k) end'
```

Expected top-level keys per row: `sample_id`, `conversation`, `qa`.
Expected per-QA keys: `question`, `answer`, `category`, `evidence`.

## Run

Smoke (uses the hand-crafted fixture, no download needed):

```bash
PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=lm_bruteforce_test \
  PGUSER=postgres PGPASSWORD=postgres lua5.1 eval/smoke_locomo.lua
```

Live, after download — hash baseline:

```bash
PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test \
  lua5.1 eval/locomo_run.lua --embedder hash \
  --out eval/results/locomo_hash.json
```

Live, ollama (`nomic-embed-text`, 768d):

```bash
ollama pull nomic-embed-text
PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test \
  OLLAMA_URL=http://127.0.0.1:11434/api/embeddings \
  OLLAMA_MODEL=nomic-embed-text OLLAMA_DIM=768 \
  lua5.1 eval/locomo_run.lua --embedder ollama \
  --out eval/results/locomo_ollama.json
```

Cross-validate against ConvoMem (`eval/sidecars/convomem.md`): both
benches must agree on the relative ordering of embedders. Divergence
> 5 pp R@1 on the same embedder is a signal to investigate the
ingest path or the loader, not to publish.

## Decision rule for promotion

Promote a configuration (e.g. swap default embedder) only when:

1. R@10 on LoCoMo `overall` ≥ current default + 3 pp, AND
2. ConvoMem `overall` agrees within ±2 pp on the same delta, AND
3. No category bucket regresses by > 5 pp R@10, AND
4. The CI guard (`eval/recall_bench.lua --mode ci`) stays green.

Otherwise the run is recorded in `eval/results/locomo.md` but the
default stays unchanged.
