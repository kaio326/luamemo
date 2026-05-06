rockspec_format = "3.0"
package = "lapis-memory"
version = "0.1.3-1"

source = {
    url = "git+https://github.com/kaio326/lapis-memory.git",
    tag = "v0.1.3",
}

description = {
    summary  = "Persistent semantic memory for AI agents on Lapis / OpenResty (PostgreSQL + pgvector)",
    detailed = [[
        lapis-memory is a persistent semantic memory store for AI agents
        and conversational apps running on Lapis / OpenResty.

        Features:
          * Hybrid vector + full-text retrieval over PostgreSQL.
          * Two backends: pgvector (recommended) or pure brute-force REAL[]
            (zero extension dependency).
          * Pluggable embedders: Ollama, OpenAI, Voyage, Cohere, DeepSeek,
            Anthropic, generic HTTP, TEI (Hugging Face text-embeddings-
            inference), and a built-in pure-Lua "hash" embedder with no
            external dependencies.
          * Pluggable rerankers (Ollama, OpenAI, cross-encoder via TEI).
          * Background summarizer + decay/importance scoring.
          * Knowledge-graph adjunct (lm_kg_facts) for currently-valid
            facts with temporal validity.
          * Encrypted secrets management (lm_secrets): AES-256-CBC storage
            for API keys/tokens with execute_with_secret — substitutes
            {secret} server-side without ever returning the raw value.
          * memo secret-store: no-echo terminal prompt for storing keys
            safely (value never enters chat context or shell history).
          * MCP server bundled (mcp/server.lua) so models can read/write
            memory and execute secrets directly through Model Context Protocol.
          * `memo init` wizard: probes host (GPU, Docker, Ollama, RAM),
            asks two questions, and prints a setup({}) snippet for the
            best-fit embedder.
          * `memo doctor`: corpus health report with truncation counts,
            p95 row size, and backend scale warnings.
          * was_truncated column: per-row flag when embed_max_chars clips
            input before embedding; surfaced by memo doctor.

        Benchmarks (R@10, LongMemEval):
          * hash embedder:         81.5%
          * nomic-embed-text:      83.0%
          * bge-m3 via TEI (GPU):  93.5%  (+12 pp over nomic)
    ]],
    homepage   = "https://github.com/kaio326/lapis-memory",
    issues_url = "https://github.com/kaio326/lapis-memory/issues",
    license    = "MIT",
    maintainer = "Kaio Fernandes <contact@kaiofernandes.com>",
    labels     = { "memory", "agents", "ai", "embeddings", "pgvector",
                   "rag", "lapis", "openresty", "postgresql", "mcp",
                   "tei", "bge-m3", "secrets" },
}

dependencies = {
    "lua >= 5.1",
    "lapis >= 1.8.0",
    "lua-cjson >= 2.1.0",
    -- lua-resty-http is only needed when using an HTTP embedder
    -- (Ollama / OpenAI / TEI / generic). The pure-Lua "hash" embedder
    -- works without it. It is bundled with OpenResty by default.
    "lua-resty-http >= 0.17",
}

build = {
    type    = "builtin",
    modules = {
        ["lapis_memory"]                    = "lapis_memory/init.lua",
        ["lapis_memory.store"]              = "lapis_memory/store.lua",
        ["lapis_memory.embed"]              = "lapis_memory/embed.lua",
        ["lapis_memory.routes"]             = "lapis_memory/routes.lua",
        ["lapis_memory.web"]                = "lapis_memory/web.lua",
        ["lapis_memory.hooks"]              = "lapis_memory/hooks.lua",
        ["lapis_memory.kg"]                 = "lapis_memory/kg.lua",
        ["lapis_memory.rerank"]             = "lapis_memory/rerank.lua",
        ["lapis_memory.secrets"]            = "lapis_memory/secrets.lua",
        ["lapis_memory.summarizer"]         = "lapis_memory/summarizer.lua",
        ["lapis_memory.tune_weights"]       = "lapis_memory/tune_weights.lua",
        ["lapis_memory.adapters.ollama"]    = "lapis_memory/adapters/ollama.lua",
        ["lapis_memory.adapters.openai"]    = "lapis_memory/adapters/openai.lua",
        ["lapis_memory.adapters.generic"]   = "lapis_memory/adapters/generic.lua",
        ["lapis_memory.adapters.voyage"]    = "lapis_memory/adapters/voyage.lua",
        ["lapis_memory.adapters.cohere"]    = "lapis_memory/adapters/cohere.lua",
        ["lapis_memory.adapters.anthropic"] = "lapis_memory/adapters/anthropic.lua",
        ["lapis_memory.adapters.deepseek"]  = "lapis_memory/adapters/deepseek.lua",
        ["lapis_memory.adapters.tei"]       = "lapis_memory/adapters/tei.lua",
        ["lapis_memory.embedders.hash"]     = "lapis_memory/embedders/hash.lua",
        ["lapis_memory.rerankers.noop"]          = "lapis_memory/rerankers/noop.lua",
        ["lapis_memory.rerankers.ollama"]        = "lapis_memory/rerankers/ollama.lua",
        ["lapis_memory.rerankers.openai"]        = "lapis_memory/rerankers/openai.lua",
        ["lapis_memory.rerankers.cross_encoder"] = "lapis_memory/rerankers/cross_encoder.lua",
        ["lapis_memory.summarizers.noop"]   = "lapis_memory/summarizers/noop.lua",
        ["lapis_memory.summarizers.ollama"] = "lapis_memory/summarizers/ollama.lua",
        ["lapis_memory.summarizers.openai"] = "lapis_memory/summarizers/openai.lua",
        -- CLI support modules (used by `memo init` and `memo doctor`)
        ["lapis_memory.cli.recommend"]      = "lapis_memory/cli/recommend.lua",
        ["lapis_memory.cli.probe"]          = "lapis_memory/cli/probe.lua",
        ["lapis_memory.cli.init"]           = "lapis_memory/cli/init.lua",
        ["lapis_memory.cli.doctor"]         = "lapis_memory/cli/doctor.lua",
    },
    install = {
        bin = { ["memo"] = "cli/memo" },
    },
    copy_directories = { "examples", "mcp" },
}
