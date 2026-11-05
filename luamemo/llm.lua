-- luamemo.llm
--
-- The language model luamemo uses for everything generative, behind ONE setting: MEMO_GEN_MODEL (an instruct .gguf,
-- run in-process through the same llama.cpp shim as the embedder). Picking a model once picks it for every feature
-- that needs one — sensing's generative step, the summarizer (adapter `gguf`, and `auto` when this is set) and with
-- it consolidate's merge and the digest's synthesis; a feature's own setting (MEMO_SUMMARIZER_ADAPTER=ollama, its URL
-- and model) overrides only when it is set. The reranker stays opt-in (an LLM rerank costs seconds per search), and
-- if turned on it is the one that names its own model.
--
--   model(cfg)             → the .gguf path | nil
--   available(cfg)         → true when the model file and the runtime are both there
--   chat(prompt, cfg, opts)→ the model's answer to `prompt` (wrapped in the model's own turn markup) | nil, err
--                            opts.max_tokens (default 600)
--   basename(cfg)          → the model's file name, for metadata

local M = {}

local function generate() return require("luamemo.sensing.generate") end

function M.model(cfg)
    local m = cfg and cfg.gen_model
    if m == nil or m == "" then m = os.getenv("MEMO_GEN_MODEL") end
    if m == nil or m == "" then return nil end
    return m
end

function M.available(cfg)
    if not M.model(cfg) then return false end
    local ok, usable = pcall(function() return generate().available(cfg) end)
    return ok and usable == true
end

function M.basename(cfg)
    local m = M.model(cfg)
    return m and m:match("([^/]+)$") or nil
end

function M.chat(prompt, cfg, opts)
    if not M.model(cfg) then return nil, "llm: no language model configured (MEMO_GEN_MODEL)" end
    local g = generate()
    local cfg_ = cfg or {}
    return g.complete(g.wrap(prompt, g.markup(cfg_)), cfg_, { max_tokens = tonumber(opts and opts.max_tokens) or 600 })
end

return M
