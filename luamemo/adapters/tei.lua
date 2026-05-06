-- HuggingFace text-embeddings-inference (TEI) embedder adapter.
--
-- Why this exists:
--   `bge-m3` (and a handful of other long-context embedders) returns
--   NaN vectors when hosted via Ollama on inputs >~600 chars
--   (upstream bug, see ollama/ollama#15582 / #14657 / #11856 / #9639;
--   fix in flight at PR #14739). Until that lands, the only way to
--   embed with bge-m3's faithful HF reference weights is to host the
--   model in TEI (or vLLM) and point this adapter at it.
--
-- Configure setup() with:
--   embedder_url     = "http://localhost:8081/embed"
--   embedder_adapter = "tei"
--   embedder_model   = "BAAI/bge-m3"   -- documentation only; TEI is
--                                      -- launched with MODEL_ID=...
--                                      -- and ignores per-request model.
--   embed_dim        = 1024            -- bge-m3 = 1024
--
-- TEI native endpoint contract:
--   POST /embed
--     request : { "inputs": "<text>" }   (string, OR array of strings)
--     response: [[v0, v1, ...]]          (array of vectors, one per input)
--
-- TEI also exposes an OpenAI-compatible /v1/embeddings endpoint; if you
-- need that shape instead, use the existing `openai` adapter with the
-- TEI URL and pass any string as embedder_model — TEI ignores it.

local cjson = require("cjson.safe")

return {
    extra_headers = {},

    url = function(cfg) return cfg.embedder_url end,

    build_request = function(text, cfg)
        return cjson.encode({ inputs = text })
    end,

    parse_response = function(payload, cfg)
        -- Native /embed returns [[...]] for a single string input.
        if type(payload) ~= "table" or type(payload[1]) ~= "table" then
            return nil, "TEI response missing outer/inner array"
        end
        return payload[1]
    end,
}
