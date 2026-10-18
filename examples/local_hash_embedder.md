# Local-first: the pure-Lua hash embedder

The `hash` embedder runs **in-process**, in pure Lua, and needs:

- no network
- no Python
- no model files
- no service

The process that writes or searches also produces the embedding, in
microseconds. It is luamemo's default: with no embedder configured, `hash` is
used (384 dimensions).

## Quality trade-off

`hash` uses **signed feature hashing** over word tokens and character trigrams.
That captures **lexical** similarity — shared words and sub-strings — but not
meaning: it can't tell that "car" and "automobile" are related.

That matters less than it sounds, because every luamemo search is hybrid: the
vector score is blended with full-text ranking, and `hash` mostly reinforces
what the text index already finds.

| Use | Embedder | Notes |
|---|---|---|
| Tests, offline, air-gapped, a first try | `hash` | nothing to set up, instant |
| Everyday use on a workstation | `gguf_ffi` (in-process) or Ollama `nomic-embed-text` | semantic, local |
| Best measured recall | TEI `bge-m3` | semantic, local service |
| Hosted | OpenAI / Voyage / Cohere | an API key in the vault |

## Setup

Nothing — or explicitly:

```bash
memo config set MEMO_EMBEDDER hash
memo config set MEMO_EMBED_DIM 384
memo ping --embedder
memo embed "deploy the app" --compare-to "deploying the application"
```

`memo calibrate` normally picks a semantic embedder when one works on the
machine; `--allow-hash` lets it settle for `hash`.

## Switching to a real embedder later

Change the settings (see [EMBEDDERS.md](../EMBEDDERS.md) for each option), then
re-embed what is stored:

```bash
memo config set MEMO_EMBEDDER_ADAPTER ollama
memo config set MEMO_EMBEDDER_URL http://localhost:11434/api/embeddings
memo config set MEMO_EMBEDDER_MODEL nomic-embed-text
memo config set MEMO_EMBED_DIM 768
memo reembed --all
```

Every vector is rebuilt from the stored text — nothing is lost — and the
database moves to the new dimension once every scope is re-embedded. Nothing
else changes: the same tools, the same commands.
