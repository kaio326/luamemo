-- luamemo.embedders.hash
--
-- Pure-Lua, in-process embedder. Zero external dependencies, zero network,
-- zero model files. Deterministic. Suitable for:
--   - offline / air-gapped deployments
--   - dev mode with no embedder service running
--   - the "local-first" tier of a fallback chain
--
-- Algorithm: signed feature hashing over word tokens + character trigrams.
-- Quality: LEXICAL similarity only (n-gram overlap). Not semantic.
-- It cannot tell that "car" and "automobile" are related — but it pairs
-- well with the FTS half of the hybrid query, and beats nothing.
--
-- Vectors are L2-normalised so cosine distance is meaningful in pgvector.
--
-- Reference: Weinberger et al., "Feature Hashing for Large Scale Multitask
-- Learning" (2009).

local M = {}

-- djb2 string hash. Pure Lua, no bit library required.
local function djb2(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 2147483647
    end
    return h
end

local function tokenize(text)
    local tokens = {}
    local lower = text:lower()

    -- 1. Whole words (length >= 2)
    for w in lower:gmatch("[%w]+") do
        if #w >= 2 then
            tokens[#tokens + 1] = "w:" .. w
        end
    end

    -- 2. Character trigrams within each word (padded with spaces so word
    --    boundaries influence the hash). Captures sub-word similarity:
    --    "running" vs "runner" share "run", "unn".
    for w in lower:gmatch("[%w]+") do
        local padded = " " .. w .. " "
        if #padded >= 3 then
            for i = 1, #padded - 2 do
                tokens[#tokens + 1] = "g:" .. padded:sub(i, i + 2)
            end
        end
    end

    return tokens
end

--- Embed a string into a deterministic, L2-normalised vector.
-- @param text string
-- @param cfg  table  (uses cfg.embed_dim; default 384)
-- @return table  vector of length cfg.embed_dim
function M.embed(text, cfg)
    local dim = (cfg and cfg.embed_dim) or 384
    local vec = {}
    for i = 1, dim do vec[i] = 0 end

    if type(text) ~= "string" or #text == 0 then
        return vec  -- zero vector for empty input
    end

    local tokens = tokenize(text)
    for _, tok in ipairs(tokens) do
        -- Two independent hashes: one for bucket, one for sign.
        -- Signed hashing keeps the expected dot product unbiased
        -- (collisions cancel on average).
        local h_bucket = djb2(tok)
        local h_sign   = djb2(tok .. "#sign")
        local bucket = (h_bucket % dim) + 1
        local sign   = (h_sign % 2 == 0) and 1 or -1
        vec[bucket] = vec[bucket] + sign
    end

    -- L2 normalisation — required for cosine distance to behave as similarity.
    local norm_sq = 0
    for i = 1, dim do norm_sq = norm_sq + vec[i] * vec[i] end
    if norm_sq > 0 then
        local inv = 1 / math.sqrt(norm_sq)
        for i = 1, dim do vec[i] = vec[i] * inv end
    end

    return vec
end

--- Self-test helper. Returns true if the embedder produces stable, normalised
--- vectors for two non-empty inputs. Useful in CI / setup scripts.
function M.selftest(cfg)
    local v1 = M.embed("the quick brown fox", cfg or { embed_dim = 384 })
    local v2 = M.embed("the quick brown fox", cfg or { embed_dim = 384 })
    if #v1 ~= #v2 then return false, "dim mismatch" end
    for i = 1, #v1 do
        if v1[i] ~= v2[i] then return false, "non-deterministic" end
    end
    local n = 0
    for i = 1, #v1 do n = n + v1[i] * v1[i] end
    if math.abs(n - 1.0) > 1e-6 then return false, "not normalised" end
    return true
end

return M
