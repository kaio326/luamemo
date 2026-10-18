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
--   profile.has_ollama    boolean   reachable Ollama server (setup hints only)
--   profile.ollama_ready  table     { url, model, dim } — Ollama answered a real embedding
--   profile.ollama_not_ready string why a reachable Ollama did not (e.g. model not pulled)
--   profile.tei_ready     table     { url, model, dim, container } — a running TEI answered
--   profile.ram_mb        number    free system RAM in MiB
--   profile.multilingual  boolean   non-English content expected
--   profile.long_rows     boolean   typical title+body > 4_000 chars
--   profile.allow_hash    boolean   user explicitly opted into hash
--   profile.gguf_capable  boolean   LuaJIT + C toolchain present (can BUILD the gguf path)
--   profile.gguf_ready    boolean   gguf path works NOW: shim built, model found, live selftest passed
--   profile.gguf_model    string    path of the .gguf that passed the selftest
--   profile.gguf_dim      number    its native embedding dim (default 768)
--   profile.gguf_not_ready string   why a capable host is not ready (for the rationale)
--
-- Output: { adapter, model, dim, embed_max_chars, setup_keys, rationale, gguf, gguf_upgrade }
--   setup_keys: the embedder settings calibrate records (as config keys: embedder_local /
--   _adapter / _url / _model, embed_dim, embed_max_chars); for HTTP services
--   embedder_url is the host-side endpoint that was tested.
--   rationale is an array of strings explaining each decision branch.
--   gguf_upgrade = true when the host could run the gguf embedder but it is not
--   set up yet — the result is a working interim pick and the caller should show
--   the one-time gguf setup guide.
--
-- Invariant: never recommend an embedder that cannot run right now. A persisted
-- gguf_ffi without a loadable model, or a service URL that doesn't answer from
-- this host, leaves every write/search failing.

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
    local allow_hash    = profile.allow_hash
    local gguf_capable  = profile.gguf_capable        -- LuaJIT + C toolchain present
    local allow_gguf    = profile.allow_gguf ~= false -- opt-out via --no-gguf / --embedder
    local gguf_ready    = profile.gguf_ready and profile.gguf_model ~= nil

    local result = nil
    local gguf_upgrade = false

    -- Preferred default: in-process GGUF embedder (llama.cpp via LuaJIT FFI).
    -- Self-contained (no sidecar/service), owned pinned weights (durable across
    -- provider changes — goal 1), and high quality (EmbeddingGemma-300M scores
    -- far above hash, near a bge-m3-class model). Chosen only once it is actually
    -- set up (shim built + model present + selftest passed); a capable host that
    -- is not set up yet gets a working interim pick plus the setup guide
    -- (gguf_upgrade). The model is swappable — any open-weights GGUF embedding model.
    if gguf_capable and allow_gguf then
        if gguf_ready then
            local dim = tonumber(profile.gguf_dim) or 768
            note("In-process GGUF embedder is set up (shim built, model found, selftest passed) -> "
                .. "self-contained, no sidecar, owned weights -> recommended default")
            result = {
                adapter = "gguf",
                model   = profile.gguf_model:match("[^/\\]+$") or profile.gguf_model,
                dim     = dim,
                embed_max_chars = 8000,          -- ~2048-token context
                gguf = true,
                setup_keys = {
                    embedder_local  = "gguf_ffi",
                    embedder_model  = profile.gguf_model,
                    embed_dim       = dim,
                    embed_max_chars = 8000,
                },
            }
        else
            gguf_upgrade = true
            note("LuaJIT + C toolchain detected -> the in-process GGUF embedder is the best fit but is "
                .. "not set up yet (" .. (profile.gguf_not_ready or "shim/model missing")
                .. ") -> recommending a working embedder now; follow the one-time GGUF setup to upgrade")
        end
    end

    -- HTTP embedding services: only ones that are RUNNING and answered a real
    -- embedding through the luamemo adapter (probe.ollama_ready / tei_ready).
    -- The persisted URL is the host-side endpoint that was tested — memo and the
    -- MCP server run on the host. Hardware (GPU / Docker / RAM) no longer
    -- selects a service to recommend; it only shapes the setup hints below.
    local tei       = profile.tei_ready      -- { url, model, dim, container } or nil
    local ollama    = profile.ollama_ready   -- { url, model, dim } or nil
    local want_long = multilingual or long_rows

    local function service_result(adapter, svc)
        local short = svc.model:match("[^/]+$") or svc.model
        local max_chars = M.SAFE_CHARS[short] or 6000
        return {
            adapter = adapter,
            model   = svc.model,
            dim     = svc.dim,
            embed_max_chars = max_chars,
            setup_keys = {
                embedder_adapter = adapter,
                embedder_url     = svc.url,
                embedder_model   = svc.model,
                embed_dim        = svc.dim,
                embed_max_chars  = max_chars,
            },
        }
    end

    if not result then
        if tei and (want_long or not ollama) then
            note("TEI sidecar '" .. (tei.container or "?") .. "' is serving " .. tei.model .. " at "
                .. tei.url .. (want_long and " -> fits multilingual / long rows" or "") .. " -> TEI")
            result = service_result("tei", tei)
        elseif ollama then
            note("Ollama is serving " .. ollama.model .. " at " .. ollama.url .. " -> Ollama"
                .. (want_long and " (a TEI bge-m3 sidecar would suit multilingual / long rows better)" or ""))
            result = service_result("ollama", ollama)
        end
    end

    -- Setup hints: services that would fit this host but are not answering yet.
    if not tei and want_long and has_docker and (has_gpu or has_ram) then
        note("A TEI sidecar serving BAAI/bge-m3 fits multilingual / long rows but none is running — start one: "
            .. "docker run -d --name luamemo-tei " .. (has_gpu and "--gpus all " or "")
            .. "-p 127.0.0.1:8081:80 " .. recommend_tei_image(has_gpu, profile.gpu_free_mb)
            .. " --model-id BAAI/bge-m3   (then re-run memo calibrate)")
    end
    if not ollama and not result then
        if has_ollama then
            note("Ollama is reachable but not serving embeddings: "
                .. (profile.ollama_not_ready or "embedding test failed") .. " (then re-run memo calibrate)")
        elseif has_docker or has_gpu then
            note("No embedding service is running — install Ollama and `ollama pull nomic-embed-text`, "
                .. "or start a TEI sidecar, then re-run memo calibrate")
        end
    end

    -- NOTE: the hosted-API branch was removed from the auto-recommendation ladder
    -- (2026-07-12). Defaulting to a cloud vendor contradicts the durability /
    -- local-first goal, and the in-process GGUF path now covers the "capable, no
    -- service" niche for free. The OpenAI-COMPATIBLE protocol adapter
    -- (embedder_adapter="openai_compatible") remains available for explicit manual
    -- config — it points at ANY /v1/embeddings endpoint, cloud OR self-hosted
    -- (vLLM / LM Studio / LocalAI) — it is simply not recommended by default.

    if not result then
        if allow_hash or gguf_upgrade then
            -- Interim hash on a gguf-capable host runs at the gguf dim (768), so
            -- the later switch needs no schema change — only `memo reembed`.
            local dim = gguf_upgrade and 768 or 384
            if allow_hash then
                note("No suitable embedder; --allow-hash given -> hash (semantically blind, FTS-only fallback)")
            else
                note("No other working embedder on this host -> hash as an INTERIM embedder (semantically "
                    .. "blind, FTS-grade) at dim 768, so the GGUF upgrade needs no schema change")
            end
            result = {
                adapter = "hash",
                model   = "hash",
                dim     = dim,
                embed_max_chars = nil,
                setup_keys = {
                    embedder_local = "hash",
                    embed_dim      = dim,
                },
            }
        else
            local gguf_hint
            if gguf_capable and not allow_gguf then
                gguf_hint = "drop --no-gguf to get the in-process GGUF embedder (calibrate prints its setup)"
            else
                gguf_hint = "install LuaJIT + a C toolchain for the recommended in-process GGUF embedder"
            end
            note("No working embedder on this host: no set-up in-process GGUF embedder and no running "
                .. "Ollama / TEI answering embeddings. Options: " .. gguf_hint
                .. "; start Ollama (`ollama pull nomic-embed-text`) or a TEI sidecar; "
                .. "or re-run with --allow-hash for FTS-only mode.")
            return nil, table.concat(rationale, "\n")
        end
    end

    result.rationale = rationale
    result.gguf_upgrade = gguf_upgrade or nil
    return result, nil
end

return M
