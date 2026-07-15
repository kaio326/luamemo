-- Back-compat alias.
--
-- The OpenAI-compatible embeddings protocol adapter was renamed to
-- `luamemo.adapters.openai_compatible` to make clear it is NOT OpenAI-only —
-- it works with any /v1/embeddings-compatible endpoint (OpenAI, Azure, and
-- self-hosted vLLM / LM Studio / LocalAI / llama-server). Existing configs that
-- set embedder_adapter = "openai" keep working via this alias.
return require("luamemo.adapters.openai_compatible")
