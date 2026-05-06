-- Ollama embedder adapter.
-- Configure setup() with:
--   embedder_url = "http://localhost:11434/api/embeddings"
--   embedder_adapter = "ollama"
--   embedder_model = "nomic-embed-text"   -- via cfg.embedder_model

local cjson = require("cjson.safe")

return {
    extra_headers = {},

    url = function(cfg) return cfg.embedder_url end,

    build_request = function(text, cfg)
        local body = {
            model  = cfg.embedder_model or "nomic-embed-text",
            prompt = text,
        }
        local num_ctx = tonumber(os.getenv("OLLAMA_NUM_CTX") or "")
            or cfg.embedder_num_ctx
        if num_ctx then
            body.options = { num_ctx = num_ctx }
        end
        return cjson.encode(body)
    end,

    parse_response = function(payload, cfg)
        if type(payload.embedding) ~= "table" then
            return nil, "Ollama response missing 'embedding'"
        end
        return payload.embedding
    end,
}
