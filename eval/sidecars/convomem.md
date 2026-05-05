# ConvoMem bench — download + run protocol

ConvoMem is the second cross-validation dataset for Phase 16.6. The
canonical corpus is the Hugging Face dataset
[`Salesforce/ConvoMem`](https://huggingface.co/datasets/Salesforce/ConvoMem)
(Apache-2.0, anonymous-accessible, no token required). The GitHub
repo at <https://github.com/SalesforceAIResearch/ConvoMem> is the
Scala/Gradle eval framework — it does not host the data.

Paper: *ConvoMem: A Comprehensive Benchmark for Conversational
Memory* (arXiv:2511.10523). 75,336 QA pairs across six evidence
categories (`user_evidence`, `assistant_facts_evidence`,
`changing_evidence`, `abstention_evidence`, `preference_evidence`,
`implicit_connection_evidence`).

## Status — Phase 16.6b live bench DONE (2026-05)

Schema verified. Converter `eval/build_convomem_corpus.lua` maps the
HF schema to the loader contract. Both hash and ollama benches
completed against a 3-batch sample (1239 cases / 2478 QAs) of
`user_evidence/1_evidence` at contextSize ∈ {1, 2, 3}.

## Upstream schema (as of 2026-05)

Each `core_benchmark/pre_mixed_testcases/<category>/<n>_evidence/batched_NNN.json`
is a JSON array of test cases shaped as:

```jsonc
{
  "contextSize": 3,                    // # of haystack conversations
  "evidenceItems": [{
    "question":          "...",
    "answer":            "...",
    "category":          "Personal Life",
    "message_evidences": [{ "speaker": "user", "text": "..." }],
    "conversations":     [...],        // subset of top-level (evidence-bearing only)
    "scenario_description": "...", "personId": "...", ...
  }, ...],
  "conversations": [
    { "messages": [{ "speaker": "user", "text": "..." }, ...] },
    ...                                // contextSize entries (mix of evidence + filler)
  ]
}
```

Gold session ids are derived by exact-substring matching every
`evidenceItems[*].message_evidences[*].text` against the messages of
each top-level conversation. The first conversation containing the
evidence text becomes the gold session for that QA.

File-size profile (`user_evidence/1_evidence/batched_NNN.json`)
grows geometrically with batch index because each batch maps to a
different `contextSize`:

| batch | contextSize | file size |
|-------|-------------|-----------|
| 000–015 | 1 | ~6 MB |
| 020 | 2 | 12 MB |
| 030 | 3 | 18 MB |
| 040 | ~5 | 30 MB |
| 049 | 300 | **852 MB** |

Downloading the entire dataset (~50 batches × 6 categories × 6
evidence-counts) is infeasible without object storage. The Phase
16.6b live run uses a 3-batch sample of one category to validate the
pipeline; expanding to higher contextSizes or other categories is a
straight `eval/data/convomem_raw/<tag>_b<NNN>.json` re-fetch + a
re-run of `eval/build_convomem_corpus.lua`.

## Loader contract

```jsonc
{
  "dialogue_id": "...",
  "sessions": [
    {
      "session_id": "s1",          // optional; falls back to s<index>
      "timestamp":  "...",         // optional
      "turns": [
        { "speaker": "A", "text": "..." },
        { "speaker": "B", "text": "..." }
      ]
    }
  ],
  "qa": [
    {
      "question":             "...",
      "answer":               "...",
      "category":             "factual",       // optional, free string or number
      "evidence_session_ids": ["s1", "s3"]    // gold sessions for retrieval scoring
    }
  ]
}
```

The runner ingests one memory per `(dialogue_id, session_id)` and
scores retrieval by checking that at least one of
`evidence_session_ids` appears in the top-K results. Cross-bench
symmetry with `locomo_run.lua` is intentional.

## Schema verification before live run

After downloading a candidate JSON file:

```bash
lua5.1 -e 'local cjson=require"cjson.safe"; local f=io.open("eval/data/convomem.json","rb"); \
  local rows=cjson.decode(f:read("*a")); print(#rows, "rows"); \
  local r=rows[1]; print("top-level keys:"); for k in pairs(r) do print("  "..k) end; \
  print("session[1] keys:"); for k in pairs((r.sessions or {})[1] or {}) do print("  "..k) end; \
  print("qa[1] keys:"); for k in pairs((r.qa or {})[1] or {}) do print("  "..k) end'
```

Required top-level keys: `dialogue_id`, `sessions`, `qa`. Required
per-QA keys: `question`, `evidence_session_ids` (or any field that
maps to gold sessions — adjust the loader if the upstream uses
`evidence`, `gold_sessions`, or similar).

If the candidate file uses different field names, **edit the loader
once** so that `iter_sessions`, `qa_gold_sessions`, and `iter_qa`
return the same Lua-side shape as today, then re-run
`eval/smoke_convomem.lua`. The runner does not need to change.

## Run

Smoke (uses the hand-crafted fixture, no download needed):

```bash
PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=lm_bruteforce_test \
  PGUSER=postgres PGPASSWORD=postgres lua5.1 eval/smoke_convomem.lua
```

### Live download + corpus build

```bash
mkdir -p eval/data/convomem_raw
# Sample three batches from user_evidence/1_evidence (cs=1,2,3; ~36 MB total).
for n in 005 020 030; do
  curl -sL --max-time 120 \
    -o "eval/data/convomem_raw/ue1_b${n}.json" \
    "https://huggingface.co/datasets/Salesforce/ConvoMem/resolve/main/core_benchmark/pre_mixed_testcases/user_evidence/1_evidence/batched_${n}.json"
done
# Convert HF schema → loader contract (writes eval/data/convomem.json)
lua5.1 eval/build_convomem_corpus.lua
```

To expand the sample (e.g. add `assistant_facts_evidence` or higher
contextSizes), drop more `<tag>_b<NNN>.json` files into
`eval/data/convomem_raw/` and re-run the converter — `<tag>` is used
verbatim as part of `dialogue_id`.

### Live bench

Hash baseline:

```bash
PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test \
  lua5.1 eval/convomem_run.lua --embedder hash \
  --out eval/results/convomem_hash.json
```

Ollama:

```bash
PGHOST=127.0.0.1 PGDATABASE=lm_bruteforce_test \
  OLLAMA_URL=http://127.0.0.1:11434/api/embeddings \
  OLLAMA_MODEL=nomic-embed-text OLLAMA_DIM=768 \
  lua5.1 eval/convomem_run.lua --embedder ollama \
  --out eval/results/convomem_ollama.json
```

## Decision rule for promotion

Same as the LoCoMo decision rule: a config is promoted only when both
benches agree within ±2 pp R@1 / ±5 pp R@10 on the same embedder
delta, no category regresses materially, and the CI guard stays
green. ConvoMem alone is not sufficient — it is the cross-validator.
