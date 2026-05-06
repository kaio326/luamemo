-- Voyage AI embedder adapter.
--
-- Voyage is the embedding provider officially recommended by Anthropic
-- (https://docs.anthropic.com/claude/docs/embeddings). Use this adapter
-- when you want "Anthropic-quality" embeddings.
--
-- Configure setup() with:
--   embedder_url     = "https://api.voyageai.com/v1/embeddings"
--   embedder_adapter = "voyage"
--   embedder_model   = "voyage-3"          -- or voyage-3-lite, voyage-large-2, etc.
--   embedder_headers = { Authorization = "Bearer " .. os.getenv("VOYAGE_API_KEY") }
--   embed_dim        = 1024                 -- voyage-3 default; check model docs
--
-- Optional: cfg.embedder_input_type = "document" | "query"
--   Voyage models support an asymmetric "input_type" hint that improves
--   retrieval quality. Stored memories should be embedded as "document";
--   search queries as "query". The library does not auto-distinguish, so
--   set this per call by overriding the global embedder if you need it.

local cjson = require("cjson.safe")

return {
    extra_headers = {},

    url = function(cfg) return cfg.embedder_url end,

    build_request = function(text, cfg)
        local body = {
            model = cfg.embedder_model or "voyage-3",
            input = { text },
        }
        if cfg.embedder_input_type then
            body.input_type = cfg.embedder_input_type
        end
        return cjson.encode(body)
    end,

    parse_response = function(payload, cfg)
        if type(payload.data) ~= "table" or not payload.data[1]
            or type(payload.data[1].embedding) ~= "table" then
            return nil, "Voyage response missing data[0].embedding"
        end
        return payload.data[1].embedding
    end,
}
