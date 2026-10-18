# Using Ollama as the embedder

[Ollama](https://ollama.com/) runs embedding models locally — no Python, and a
GPU only if you have one. A good choice for a workstation.

## 1. Install and pull a model

```bash
# Linux:  curl -fsSL https://ollama.com/install.sh | sh
# macOS:  brew install ollama
ollama serve &                   # the daemon on :11434 (the installers usually start it)
ollama pull nomic-embed-text     # 768 dimensions, recommended
# or:
ollama pull all-minilm           # 384 dimensions, smaller and faster
```

## 2. Point luamemo at it

`memo calibrate` finds a running Ollama that serves `nomic-embed-text` and sets
this up by itself. By hand:

```bash
memo config set MEMO_EMBEDDER_ADAPTER ollama
memo config set MEMO_EMBEDDER_URL http://localhost:11434/api/embeddings
memo config set MEMO_EMBEDDER_MODEL nomic-embed-text    # or all-minilm
memo config set MEMO_EMBED_DIM 768                      # 384 for all-minilm
memo config set MEMO_EMBED_MAX_CHARS 6000               # nomic's context is 2,048 tokens
```

If the project already has memories from another embedder, re-embed them:
`memo reembed --all`. Then restart the MCP server in your client (`memo mcp`
reads `.luamemorc` when it starts).

## 3. Verify

```bash
memo ping --embedder                                  # [PASS] Embedder … ollama
memo embed "hello world"                              # embedder, model, dimension: 768
curl -s http://localhost:11434/api/embeddings \
     -d '{"model":"nomic-embed-text","prompt":"hello world"}' | jq '.embedding | length'
```

Don't use Ollama for `bge-m3` (it returns NaN vectors on long inputs) — run it
on TEI instead ([EMBEDDERS.md](../EMBEDDERS.md)).
