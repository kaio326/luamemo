-- luamemo.cli.recommend
--
-- Pure decision tree. Given a host/project profile, returns a recommended
-- embedder configuration plus a human-readable rationale. No I/O, no
-- requires beyond Lua stdlib — safe to unit test in isolation.
--
-- Inputs (all optional, sane fallbacks):
--   profile.has_gpu       boolean   nvidia GPU detected
--   profile.gpu_free_mb   number    free VRAM in MiB
--   profile.has_docker    boolean
--   profile.has_ollama    boolean   reachable Ollama server
--   profile.ram_mb        number    free system RAM in MiB
--   profile.multilingual  boolean   non-English content expected
--   profile.long_rows     boolean   typical title+body > 4_000 chars
--   profile.allow_hosted  boolean   user OK paying for hosted API
--   profile.allow_hash    boolean   user explicitly opted into hash
--
-- Output: { adapter, model, dim, embed_max_chars, setup_keys, rationale }
--   setup_keys is the table that should be passed to setup() verbatim.
--   rationale is an array of strings explaining each decision branch.

local M = {}

-- Per-embedder safe character ceilings. Conservative ~3 chars/token.
-- Used as default `embed_max_chars`. Operators can override.
M.SAFE_CHARS = {
    ["nomic-embed-text"]      = 6000,    -- 2048 tok ctx
    ["bge-m3"]                = 24000,   -- 8192 tok ctx
    ["text-embedding-3-small"] = 24000,  -- 8191 tok ctx
    ["text-embedding-3-large"] = 24000,
    ["voyage-3"]              = 90000,   -- 32k tok ctx
    ["embed-english-v3.0"]    = 1500,    -- 512 tok ctx
}

local function recommend_tei_image(has_gpu, gpu_free_mb)
    -- TEI ships per-architecture images. We can't probe compute capability
    -- from here cheaply, so we recommend the broadest GPU image (Turing,
    -- works on every NVIDIA GPU since 2018) when GPU is present, else CPU.
    if has_gpu and (gpu_free_mb or 0) >= 2048 then
        return "ghcr.io/huggingface/text-embeddings-inference:turing-1.7"
    end
    return "ghcr.io/huggingface/text-embeddings-inference:cpu-1.7"
end

function M.decide(profile)
    profile = profile or {}
    local rationale = {}
    local function note(msg) table.insert(rationale, msg) end

    -- has_gpu is true only when a GPU is detected AND has ≥ 2,048 MiB free VRAM.
    -- When the GPU exists but free VRAM is below the threshold, log a clear note
    -- so the rationale doesn't misleadingly say "No GPU".
    local has_gpu       = profile.has_gpu and (profile.gpu_free_mb or 0) >= 2048
    if profile.has_gpu and not has_gpu then
        note(string.format(
            "GPU detected but only %d MiB VRAM free (≥ 2,048 MiB required for GPU inference) — falling back to CPU path",
            profile.gpu_free_mb or 0))
    end
    local has_docker    = profile.has_docker
    local has_ollama    = profile.has_ollama
    local has_ram       = (profile.ram_mb or 0) >= 4096
    local multilingual  = profile.multilingual
    local long_rows     = profile.long_rows
    local allow_hosted  = profile.allow_hosted
    local allow_hash    = profile.allow_hash

    local result = nil

    if has_gpu and has_docker then
        if multilingual or long_rows then
            note("GPU + Docker available; multilingual or long rows detected -> bge-m3 via TEI sidecar")
            result = {
                adapter = "tei",
                model   = "BAAI/bge-m3",
                dim     = 1024,
                embed_max_chars = M.SAFE_CHARS["bge-m3"],
                tei_image = recommend_tei_image(has_gpu, profile.gpu_free_mb),
                setup_keys = {
                    embedder_adapter = "tei",
                    embedder_url     = "http://lapis-tei-embed:80",
                    embedder_model   = "BAAI/bge-m3",
                    embed_dim        = 1024,
                    embed_max_chars  = M.SAFE_CHARS["bge-m3"],
                },
            }
        else
            note("GPU + Docker available; English short rows -> nomic-embed-text via Ollama (lighter)")
            result = {
                adapter = "ollama",
                model   = "nomic-embed-text",
                dim     = 768,
                embed_max_chars = M.SAFE_CHARS["nomic-embed-text"],
                setup_keys = {
                    embedder_adapter = "ollama",
                    embedder_url     = "http://host.docker.internal:11434",
                    embedder_model   = "nomic-embed-text",
                    embed_dim        = 768,
                    embed_max_chars  = M.SAFE_CHARS["nomic-embed-text"],
                },
            }
        end
    elseif has_docker and has_ram then
        if multilingual or long_rows then
            note("No GPU (or insufficient free VRAM); Docker + 4GB RAM; multilingual or long rows -> bge-m3 via TEI (CPU)")
            result = {
                adapter = "tei",
                model   = "BAAI/bge-m3",
                dim     = 1024,
                embed_max_chars = M.SAFE_CHARS["bge-m3"],
                tei_image = recommend_tei_image(has_gpu, profile.gpu_free_mb),
                setup_keys = {
                    embedder_adapter = "tei",
                    embedder_url     = "http://lapis-tei-embed:80",
                    embedder_model   = "BAAI/bge-m3",
                    embed_dim        = 1024,
                    embed_max_chars  = M.SAFE_CHARS["bge-m3"],
                },
            }
        elseif has_ollama then
            note("No GPU but Ollama reachable -> nomic-embed-text (CPU, slower)")
            result = {
                adapter = "ollama",
                model   = "nomic-embed-text",
                dim     = 768,
                embed_max_chars = M.SAFE_CHARS["nomic-embed-text"],
                setup_keys = {
                    embedder_adapter = "ollama",
                    embedder_url     = "http://host.docker.internal:11434",
                    embedder_model   = "nomic-embed-text",
                    embed_dim        = 768,
                    embed_max_chars  = M.SAFE_CHARS["nomic-embed-text"],
                },
            }
        end
    end

    if not result and allow_hosted then
        note("Falling back to hosted API (OpenAI text-embedding-3-small)")
        result = {
            adapter = "openai",
            model   = "text-embedding-3-small",
            dim     = 1536,
            embed_max_chars = M.SAFE_CHARS["text-embedding-3-small"],
            setup_keys = {
                embedder_adapter = "openai",
                embedder_url     = "https://api.openai.com/v1/embeddings",
                embedder_model   = "text-embedding-3-small",
                embed_dim        = 1536,
                embed_max_chars  = M.SAFE_CHARS["text-embedding-3-small"],
                embedder_headers = { Authorization = "Bearer ${OPENAI_API_KEY}" },
            },
        }
    end

    if not result then
        if allow_hash then
            note("No suitable embedder; --allow-hash given -> hash (semantically blind, FTS-only fallback)")
            result = {
                adapter = "hash",
                model   = "hash",
                dim     = 384,
                embed_max_chars = nil,
                setup_keys = {
                    embedder_local = "hash",
                    embed_dim      = 384,
                },
            }
        else
            note("No GPU, no Docker+RAM, no hosted budget. Re-run with --allow-hash for FTS-only mode, or install Docker/Ollama, or pass --hosted.")
            return nil, table.concat(rationale, "\n")
        end
    end

    result.rationale = rationale
    return result, nil
end

return M
