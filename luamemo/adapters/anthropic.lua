-- Anthropic adapter — TEMPLATE / PLACEHOLDER.
--
-- IMPORTANT: As of this release, Anthropic does NOT offer a public
-- embeddings API. Their official documentation recommends Voyage AI as
-- the embedding provider for use with Claude:
--   https://docs.anthropic.com/claude/docs/embeddings
--
-- This file exists so that the day Anthropic ships an embeddings endpoint,
-- you can flip a single line and use it. Until then, selecting this adapter
-- will return a clear error pointing you at Voyage.
--
-- When Anthropic releases embeddings, update build_request() / url() /
-- parse_response() to match their schema and remove the guard below.

local cjson = require("cjson.safe")

return {
    extra_headers = {
        ["anthropic-version"] = "2023-06-01",
    },

    url = function(cfg)
        return cfg.embedder_url
            or "https://api.anthropic.com/v1/embeddings"  -- speculative
    end,

    build_request = function(text, cfg)
        return nil, "Anthropic does not currently offer an embeddings API. "
            .. "Use embedder_adapter = 'voyage' (Anthropic's recommended "
            .. "provider) or 'openai' / 'cohere' / 'ollama' / embedder_local "
            .. "= 'hash' instead."
    end,

    parse_response = function(payload, cfg)
        -- Speculative: shape matches the OpenAI-style response many
        -- providers converge on. Verify against official docs when released.
        if type(payload.data) ~= "table" or not payload.data[1]
            or type(payload.data[1].embedding) ~= "table" then
            return nil, "Anthropic embeddings response missing data[0].embedding"
        end
        return payload.data[1].embedding
    end,
}
