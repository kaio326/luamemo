-- Generic embedder adapter.
-- Contract:
--   POST <embedder_url>  { "text": "..." }  -> { "vector": [...] }

local cjson = require("cjson.safe")

return {
    extra_headers = {},

    url = function(cfg) return cfg.embedder_url end,

    build_request = function(text, cfg)
        return cjson.encode({ text = text })
    end,

    parse_response = function(payload, cfg)
        if type(payload.vector) ~= "table" then
            return nil, "response missing 'vector' array"
        end
        return payload.vector
    end,
}
