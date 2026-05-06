-- OpenAI embedder adapter.
-- Configure setup() with:
--   embedder_url = "https://api.openai.com/v1/embeddings"
--   embedder_adapter = "openai"
--   embedder_model = "text-embedding-3-small"
--   embedder_headers = { Authorization = "Bearer " .. os.getenv("OPENAI_API_KEY") }

local cjson = require("cjson.safe")

return {
    extra_headers = {},

    url = function(cfg) return cfg.embedder_url end,

    build_request = function(text, cfg)
        return cjson.encode({
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
