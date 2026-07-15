-- OpenAI-COMPATIBLE embeddings protocol adapter (NOT OpenAI-the-vendor only).
--
-- Implements the de-facto-standard `/v1/embeddings` shape:
--     request:  { "model": "...", "input": "..." }
--     response: { "data": [ { "embedding": [...] } ] }
-- That shape is spoken by a large ecosystem, INCLUDING self-hosted / local
-- servers — so this is a local-first-friendly protocol adapter, not a cloud lock-in:
--   * self-hosted:  vLLM, LM Studio, LocalAI, llama.cpp `llama-server`, text-gen-webui
--   * hosted:       OpenAI, Azure OpenAI, Together, Fireworks, DeepSeek (when they ship it)
--
-- Selected via embedder_adapter = "openai_compatible"  (or the back-compat alias
-- "openai"). Not auto-recommended by calibrate — luamemo defaults to a local
-- embedder (gguf_ffi / hash). Use this when you want to point at any OpenAI-
-- compatible endpoint, cloud or self-hosted.
--
-- Configure setup() with, e.g.:
--   embedder_url = "https://api.openai.com/v1/embeddings"   -- or http://localhost:8000/v1/embeddings (vLLM), etc.
--   embedder_adapter = "openai_compatible"
--   embedder_model = "text-embedding-3-small"               -- or whatever the endpoint serves
--   embedder_headers = { Authorization = "Bearer " .. os.getenv("OPENAI_API_KEY") }  -- if the endpoint needs auth

local json = require("luamemo.json")

return {
    extra_headers = {},

    url = function(cfg) return cfg.embedder_url end,

    build_request = function(text, cfg)
        return json.encode({
            model = cfg.embedder_model or "text-embedding-3-small",
            input = text,
        })
    end,

    parse_response = function(payload, cfg)
        if type(payload.data) ~= "table" or not payload.data[1]
            or type(payload.data[1].embedding) ~= "table" then
            return nil, "OpenAI response missing data[0].embedding"
        end
        return payload.data[1].embedding
    end,
}
