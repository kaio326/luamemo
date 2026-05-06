-- Cohere embedder adapter.
--
-- Configure setup() with:
--   embedder_url     = "https://api.cohere.com/v2/embed"
--   embedder_adapter = "cohere"
--   embedder_model   = "embed-english-v3.0"   -- or embed-multilingual-v3.0
--   embedder_headers = { Authorization = "Bearer " .. os.getenv("COHERE_API_KEY") }
--   embed_dim        = 1024                    -- v3 models = 1024 dims
--
-- Cohere requires an "input_type" parameter:
--   "search_document" for stored memories, "search_query" for searches.
-- Default below is "search_document"; override via cfg.embedder_input_type
-- if you wire a separate query-time embedder.

local cjson = require("cjson.safe")

return {
    extra_headers = {},

    url = function(cfg) return cfg.embedder_url end,

    build_request = function(text, cfg)
        return cjson.encode({
            model           = cfg.embedder_model or "embed-english-v3.0",
            texts           = { text },
            input_type      = cfg.embedder_input_type or "search_document",
            embedding_types = { "float" },
        })
    end,

    parse_response = function(payload, cfg)
        -- Cohere v2 returns { embeddings = { float = { [1] = [...] } } }
        local embs = payload.embeddings
        if type(embs) ~= "table" then
            return nil, "Cohere response missing 'embeddings'"
        end
        local floats = embs.float or embs["float"]
        if type(floats) ~= "table" or type(floats[1]) ~= "table" then
            return nil, "Cohere response missing embeddings.float[0]"
        end
        return floats[1]
    end,
}
