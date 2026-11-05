-- luamemo.summarizers.gguf
--
-- The in-process summarizer: the shared language model (MEMO_GEN_MODEL, luamemo.llm) answers the same prompt the
-- Ollama adapter sends, with nothing to run beside luamemo. Chosen over Ollama as the default by measuring both on
-- twelve batches of real notes (eval/summarizer_bench.lua): slower on a CPU (78 s a batch against 17 s on a GPU),
-- but it invents fewer facts (3.9 % of its tokens against 9.4 %) and needs no server or GPU memory — and scheduled
-- maintenance runs in a background process, where speed matters less.
--
-- The model has no constrained decoding, so it often wraps its JSON (a code fence, a sentence before it): the object
-- is taken from the first {…} of the answer. The prompt has to fit the context the model was loaded with
-- (MEMO_GEN_NCTX, 4096 unless set), so each memory's body is clipped to its share of what is left.
--
-- Contract: summarize(memories, cfg) -> { title, body, metadata }, err

local json    = require("luamemo.json")
local llm     = require("luamemo.llm")
local _common = require("luamemo.summarizers._common")

local M = {}

local MAX_TOKENS = 600     -- the answer: a title and a note
local PER_TOKEN  = 3.5     -- characters a token holds, on average, in these notes (a clip errs short)
local OVERHEAD   = 300     -- tokens of instructions and turn markup

--- How many characters of each memory fit: the context, less the answer and the instructions, shared out;
--- never above the usual 1,500 nor below 200.
function M._fit_clip(n_memories, n_ctx)
    n_ctx = tonumber(n_ctx) or 4096
    local budget = math.max(0, n_ctx - MAX_TOKENS - OVERHEAD) * PER_TOKEN
    local clip = math.floor(budget / math.max(n_memories, 1))
    return math.max(200, math.min(1500, clip))
end

--- The {title, body} object an answer holds, or nil.
function M._parse(text)
    local s = tostring(text or ""):gsub("^%s*```%a*%s*", ""):gsub("%s*```%s*$", "")
    local a, b = s:find("%b{}")
    if not a then return nil end
    local t = json.decode(s:sub(a, b))
    if type(t) == "table" and type(t.title) == "string" and type(t.body) == "string" and t.body ~= "" then return t end
end

function M.summarize(memories, cfg)
    if type(memories) ~= "table" or #memories == 0 then return nil, "gguf.summarize: no memories" end
    if not llm.available(cfg) then
        return nil, "gguf.summarize: no language model (set MEMO_GEN_MODEL; memo gguf status shows the runtime)"
    end
    local clip = M._fit_clip(#memories, cfg and cfg.gen_n_ctx)
    local out, err = llm.chat(_common.summary_prompt(memories, clip), cfg, { max_tokens = MAX_TOKENS })
    if not out then return nil, "gguf.summarize: " .. tostring(err) end
    local parsed = M._parse(out)
    if not parsed then return nil, "gguf.summarize: the model's answer holds no {title, body} object" end
    return {
        title    = parsed.title,
        body     = parsed.body,
        metadata = { summarizer = "gguf", model = llm.basename(cfg), source_count = #memories },
    }
end

return M
