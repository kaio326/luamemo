rockspec_format = "3.0"
package = "luamemo"
version = "0.4.1-1"

source = {
    url = "git+https://github.com/kaio326/luamemo.git",
    tag = "v0.4.1",
}

description = {
    summary  = "Private, local memory for AI agents — an MCP server, with the memo CLI to set it up and govern it",
    detailed = [[
        luamemo gives AI coding agents a memory that lives on your machine. The
        agent writes decisions, facts and plans as it works and finds them again
        in later sessions, through the Model Context Protocol: Claude Code,
        VS Code (Copilot agent mode), Cursor, Claude Desktop and other MCP
        clients use it. The `memo` CLI sets it up and keeps the decisions that
        belong to people: settings, backups, which devices join a team's memory
        and which knowledge the team shares.

        No database server, no Docker, no account: each project's memory is one
        SQLite file in ~/.local/share/luamemo. Runs on LuaJIT with two system
        libraries, libsqlite3 and libsodium (Linux, macOS, Windows through WSL).

          * MCP server (mcp/server.lua, 26 tools): write, search (with the
            knowledge-graph facts the query is about), recent, update, delete
            (bulk deletes behind a preview + confirmation token), session
            promotion, maintenance, feedback, the learned reranker, the codebase
            map, the secrets vault.
          * Hybrid search, exact at every size: every vector in scope is scored,
            plus FTS5 full-text ranking (Postgres-style cover density), blended
            and weighted by importance, age and tier; multi-scope search, time
            filters, metadata filters, optional rerankers.
          * Embedders: an in-process GGUF model (EmbeddingGemma via llama.cpp,
            no service), Ollama, TEI, OpenAI / Voyage / Cohere / any
            OpenAI-compatible endpoint, and a pure-Lua hash embedder.
          * Codebase index (`memo index`): files, symbols, dependencies and
            commit diffs, so an agent finds where code lives before grepping.
            Pure-Lua parsers for Lua, Python, JS/TS; universal-ctags for others.
          * Learns from use (opt-in): corrections, rules, praise and retrieval
            misses train a per-scope learned reranker, promoted only when it
            beats the current one on held-out data.
          * Self-maintaining: tiers, consolidation, decay and summarization run
            on writes.
          * Secrets vault: keys encrypted with libsodium; agents use them via
            secret_execute without ever seeing them; settings refer to them as
            {secret:NAME}.
          * Team memory on your LAN / VPN: an org central with protected
            directives, admin-reviewed knowledge proposals and collective
            learning; devices pair with a key and a spoken code over an
            encrypted channel — no passwords, no tokens, no hosted service.
          * `memo config`: every setting checked before it is written; settings
            files are data, and one committed to a repository must be trusted.
          * `memo backup`, `memo export` / `memo import` (JSON Lines).

        Benchmarks (R@5, bge-m3): LongMemEval _s 96.4%, LoCoMo 84.6%,
        ConvoMem 96.5%. Search over 1,000 memories: ~4 ms.
    ]],
    homepage   = "https://github.com/kaio326/luamemo",
    issues_url = "https://github.com/kaio326/luamemo/issues",
    license    = "MIT",
    maintainer = "Kaio Fernandes <contact@kaiofernandes.com>",
    labels     = { "memory", "agents", "ai", "mcp", "embeddings", "rag",
                   "sqlite", "luajit", "ffi", "libsodium", "secrets", "temporal",
                   "code-index", "code-search", "ctags", "federation" },
}

dependencies = {
    -- LuaJIT only: its FFI reaches SQLite (the database) and libsodium (the
    -- vault, federation) — system libraries; luamemo.native.loader names the
    -- package to install when one is missing. LuaRocks provides "luajit" when
    -- it runs under LuaJIT (rockspec format 3.0).
    "luajit >= 2.1",
    -- lua-cjson is optional: luamemo.json tries it first (faster), then falls
    -- back to the bundled dkjson — so `luarocks install luamemo` needs no C
    -- compiler for JSON. luasec (ssl.https) is needed only for HTTPS.
    "luasocket >= 3.0",
}

build = {
    type    = "builtin",
    modules = {
        ["luamemo"]                    = "luamemo/init.lua",
        ["luamemo.json"]               = "luamemo/json.lua",
        ["luamemo.vendor.dkjson"]      = "luamemo/vendor/dkjson.lua",
        ["luamemo.db"]                 = "luamemo/db.lua",
        ["luamemo.http"]               = "luamemo/http.lua",
        ["luamemo.async"]              = "luamemo/async.lua",
        ["luamemo.store"]              = "luamemo/store.lua",
        ["luamemo.embed"]              = "luamemo/embed.lua",
        ["luamemo.temporal"]           = "luamemo/temporal.lua",
        ["luamemo.consolidate"]        = "luamemo/consolidate.lua",
        ["luamemo.digest"]             = "luamemo/digest.lua",
        ["luamemo.feedback"]           = "luamemo/feedback.lua",
        ["luamemo.sensing"]            = "luamemo/sensing/init.lua",
        ["luamemo.sensing.heuristics"] = "luamemo/sensing/heuristics.lua",
        ["luamemo.sensing.generate"]   = "luamemo/sensing/generate.lua",
        ["luamemo.sensing.extract"]    = "luamemo/sensing/extract.lua",
        ["luamemo.patterns"]           = "luamemo/patterns.lua",
        ["luamemo.kg"]                 = "luamemo/kg.lua",
        ["luamemo.rerank"]             = "luamemo/rerank.lua",
        ["luamemo.rerank_train"]       = "luamemo/rerank_train.lua",
        ["luamemo.projection_train"]   = "luamemo/projection_train.lua",
        ["luamemo.learner_store"]      = "luamemo/learner_store.lua",
        ["luamemo.promote"]            = "luamemo/promote.lua",
        ["luamemo.secrets"]            = "luamemo/secrets.lua",
        ["luamemo.summarizer"]         = "luamemo/summarizer.lua",
        ["luamemo.tune_weights"]       = "luamemo/tune_weights.lua",
        ["luamemo.util"]               = "luamemo/util.lua",
        ["luamemo.adapters.ollama"]    = "luamemo/adapters/ollama.lua",
        ["luamemo.adapters.openai_compatible"] = "luamemo/adapters/openai_compatible.lua",
        ["luamemo.adapters.openai"]    = "luamemo/adapters/openai.lua",
        ["luamemo.adapters.generic"]   = "luamemo/adapters/generic.lua",
        ["luamemo.adapters.voyage"]    = "luamemo/adapters/voyage.lua",
        ["luamemo.adapters.cohere"]    = "luamemo/adapters/cohere.lua",
        ["luamemo.adapters.anthropic"] = "luamemo/adapters/anthropic.lua",
        ["luamemo.adapters.deepseek"]  = "luamemo/adapters/deepseek.lua",
        ["luamemo.adapters.tei"]       = "luamemo/adapters/tei.lua",
        ["luamemo.embedders.hash"]     = "luamemo/embedders/hash.lua",
        ["luamemo.embedders.hash_learned"] = "luamemo/embedders/hash_learned.lua",
        ["luamemo.embedders.projected"]    = "luamemo/embedders/projected.lua",
        ["luamemo.embedders.gguf_ffi"]    = "luamemo/embedders/gguf_ffi.lua",
        ["luamemo.embedders.native.ffi_shim"] = "luamemo/embedders/native/ffi_shim.lua",
        ["luamemo.rerankers.noop"]          = "luamemo/rerankers/noop.lua",
        ["luamemo.rerankers.ollama"]        = "luamemo/rerankers/ollama.lua",
        ["luamemo.rerankers.openai"]        = "luamemo/rerankers/openai.lua",
        ["luamemo.rerankers.cross_encoder"] = "luamemo/rerankers/cross_encoder.lua",
        ["luamemo.rerankers.learned"]       = "luamemo/rerankers/learned.lua",
        ["luamemo.rerankers._common"]       = "luamemo/rerankers/_common.lua",
        ["luamemo.summarizers.noop"]   = "luamemo/summarizers/noop.lua",
        ["luamemo.summarizers.ollama"] = "luamemo/summarizers/ollama.lua",
        ["luamemo.summarizers.openai"] = "luamemo/summarizers/openai.lua",
        ["luamemo.summarizers._common"] = "luamemo/summarizers/_common.lua",
        -- CLI support modules
        ["luamemo.cli.recommend"]      = "luamemo/cli/recommend.lua",
        ["luamemo.cli.probe"]          = "luamemo/cli/probe.lua",
        ["luamemo.cli.calibrate"]      = "luamemo/cli/calibrate.lua",
        ["luamemo.cli.doctor"]         = "luamemo/cli/doctor.lua",
        ["luamemo.cli.api"]            = "luamemo/cli/api.lua",
        ["luamemo.cli.ping"]           = "luamemo/cli/ping.lua",
        ["luamemo.cli.index"]          = "luamemo/cli/index.lua",
        ["luamemo.cli._common"]        = "luamemo/cli/_common.lua",
        -- Codebase index subsystem
        ["luamemo.index"]                    = "luamemo/index/init.lua",
        ["luamemo.index.walker"]             = "luamemo/index/walker.lua",
        ["luamemo.index.parser"]             = "luamemo/index/parser.lua",
        ["luamemo.index.checksum"]           = "luamemo/index/checksum.lua",
        ["luamemo.index.differ"]             = "luamemo/index/differ.lua",
        ["luamemo.index.resolver"]           = "luamemo/index/resolver.lua",
        ["luamemo.index.digester"]           = "luamemo/index/digester.lua",
        ["luamemo.index.format"]             = "luamemo/index/format.lua",
        ["luamemo.index.ctags"]              = "luamemo/index/ctags.lua",
        ["luamemo.index.parsers.common"]     = "luamemo/index/parsers/common.lua",
        ["luamemo.index.parsers.lua"]        = "luamemo/index/parsers/lua.lua",
        ["luamemo.index.parsers.python"]     = "luamemo/index/parsers/python.lua",
        ["luamemo.index.parsers.javascript"] = "luamemo/index/parsers/javascript.lua",
    },
    install = {
        bin = { ["memo"] = "cli/memo" },
    },
    -- luamemo/embedders/native ships gguf_shim.c + build.sh (source for the
    -- in-process gguf_ffi embedder's native shim — NOT auto-compiled by
    -- LuaRocks; built on demand via build.sh, which self-locates its output
    -- next to the installed ffi_shim.lua regardless of where this directory
    -- lands on disk). gguf_shim.so itself is never shipped (build artifact,
    -- host/arch specific) — see .gitignore. (v0.4.1 fix: previously omitted
    -- entirely, so the in-process embedder could not be built from a stock
    -- `luarocks install`.)
    copy_directories = { "examples", "mcp", "luamemo/embedders/native" },
}
