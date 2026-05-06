-- DeepSeek adapter — TEMPLATE / PLACEHOLDER.
--
-- IMPORTANT: As of this release, DeepSeek's public API exposes chat
-- completions only — there is no documented embeddings endpoint
-- (https://api-docs.deepseek.com/). DeepSeek's API is OpenAI-compatible,
-- so when/if they add embeddings the OpenAI adapter will likely "just work"
-- by pointing embedder_url at https://api.deepseek.com/v1/embeddings and
-- using embedder_adapter = "openai".
--
-- This file is a stub kept for symmetry. Selecting it returns a clear
-- error directing you at the working alternatives.

local cjson = require("cjson.safe")

return {
    extra_headers = {},

    url = function(cfg)
        return cfg.embedder_url
            or "https://api.deepseek.com/v1/embeddings"  -- speculative
    end,

    build_request = function(text, cfg)
        return nil, "DeepSeek does not currently offer an embeddings API "
            .. "(chat completions only). When they add one, switch to "
            .. "embedder_adapter = 'openai' with embedder_url pointed at "
            .. "the DeepSeek embeddings endpoint. For now use 'voyage', "
            .. "'openai', 'cohere', 'ollama', or embedder_local = 'hash'."
    end,

    parse_response = function(payload, cfg)
        -- DeepSeek mirrors the OpenAI response shape for parity.
        if type(payload.data) ~= "table" or not payload.data[1]
            or type(payload.data[1].embedding) ~= "table" then
            return nil, "DeepSeek embeddings response missing data[0].embedding"
        end
        return payload.data[1].embedding
    end,
}
