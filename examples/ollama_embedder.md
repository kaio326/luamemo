# Using Ollama as the embedder

[Ollama](https://ollama.com/) runs embedding models locally with no Python or
GPU required. Recommended for self-hosted setups.

## 1. Install + pull a model

```bash
# Linux:  curl -fsSL https://ollama.com/install.sh | sh
# macOS:  brew install ollama
ollama serve &              # background daemon on :11434
ollama pull nomic-embed-text   # 768-dim, recommended
# or:
ollama pull all-minilm          # 384-dim, smaller/faster
```

## 2. Configure luamemo

```lua
local memory = require("luamemo")
memory.setup({
    embedder_url     = "http://localhost:11434/api/embeddings",
    embedder_adapter = "ollama",
    embedder_model   = "nomic-embed-text",   -- or "all-minilm"
    embed_dim        = 768,                  -- 768 for nomic, 384 for minilm
    auth_fn          = function(self) return is_admin(self) end,
})
```

If you change `embed_dim`, update the `vector(N)` declaration in
`schema.sql` **before** running the migration.

## 3. Verify

```bash
curl -s http://localhost:11434/api/embeddings \
     -d '{"model":"nomic-embed-text","prompt":"hello world"}' \
     | jq '.embedding | length'
# => 768
```
