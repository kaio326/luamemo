-- luamemo.sensing.extract  (Phase 9 — generative "dreams" extraction sensor)
--
-- The heuristic sensor (sensing.heuristics) catches EXPLICIT signals via surface
-- patterns ("no, that's wrong", "always ..."). This sensor uses the in-process
-- instruct model (sensing.generate) to catch signals the patterns miss —
-- implicit corrections, paraphrased rules, confirmations — reading the whole
-- conversation at once. Same output shape as heuristics.detect, so the
-- orchestrator treats both uniformly.
--
-- Degrades to {} (no signals) whenever generation is unavailable (PUC lua5.1,
-- no model, no shim) — the pipeline then runs heuristics-only. Deterministic
-- (greedy decode), so the same transcript yields the same signals.
--
-- OPT-IN / experimental: enabled via opts.generative on sensing.process. The prompt
-- is tuned precision-first (a wrong reinforcement corrupts the shared signal), so the
-- small default model (gemma-3-1b-it) is conservative — it favours NONE over a guess.
-- Recall scales with model size: point MEMO_GEN_MODEL at a larger instruct GGUF to
-- catch more of the implicit/paraphrased signals the heuristics miss.

local generate = require("luamemo.sensing.generate")

local M = {}

-- Few-shot is load-bearing: a 1B model, told only the schema, fills EVERY label on
-- every turn. The examples (one of them NONE) teach it that most turns carry no
-- signal and to quote the user rather than describe them.
local INSTRUCTION = [[You extract feedback signals from a conversation between a USER and an AI assistant on a software project.
A signal is ONLY when the USER: corrects a mistake (CORRECTION), gives a standing rule/instruction (COMMAND), or explicitly confirms something is right (PRAISE).
Most turns carry NO signal. Quote the USER's own words. Never describe the user, never invent a signal. If there are none, output exactly: NONE

Example 1
Conversation:
USER: Where is search defined?
ASSISTANT: In store.lua.
Signals:
NONE

Example 2
Conversation:
USER: How do we connect to Postgres?
ASSISTANT: With luadbi.
USER: No — we use pgmoon, not luadbi.
Signals:
CORRECTION: we use pgmoon, not luadbi

Example 3
Conversation:
USER: From now on, never edit an existing migration — add a new one.
Signals:
COMMAND: never edit an existing migration, add a new one

Now extract the signals for the conversation below.]]

-- label -> (kind, reinforcement event_type)  [same vocabulary as heuristics]
local LABELS = {
    CORRECTION = { kind = "correction", event_type = "mistake" },
    COMMAND    = { kind = "command",    event_type = "direct_command" },
    PRAISE     = { kind = "praise",     event_type = "praise" },
}

local GEN_CONF = 0.7   -- generative signals: medium-high (> orchestrator's 0.6 floor)

local function turn_text(t)
    if type(t) == "string" then return t end
    return t.text or t[1] or ""
end

--- Build a gemma-instruct chat prompt from the relayed turns.
function M.build_prompt(turns)
    local lines = {}
    for _, t in ipairs(turns) do
        local role = (type(t) == "table" and t.role == "assistant") and "ASSISTANT" or "USER"
        lines[#lines + 1] = role .. ": " .. turn_text(t)
    end
    local body = INSTRUCTION .. "\n\nConversation:\n" .. table.concat(lines, "\n") .. "\n\nSignals:"
    return "<start_of_turn>user\n" .. body .. "<end_of_turn>\n<start_of_turn>model\n"
end

--- Parse the model completion into signal events (tolerant of markdown / quoting).
function M.parse(text)
    local out = {}
    if not text or text == "" then return out end
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local label, rest = line:match("^%s*%*?%*?(%u+)%*?%*?%s*:%s*(.+)$")
        if label and LABELS[label] then
            rest = rest:gsub('^[%s"\'%*%-]+', ''):gsub('[%s"\'%*]+$', '')
            if rest ~= "" and rest:upper() ~= "NONE" then
                local m = LABELS[label]
                out[#out + 1] = {
                    kind       = m.kind,
                    event_type = m.event_type,
                    text       = rest,
                    confidence = GEN_CONF,
                    source     = "generative",
                }
            end
        end
    end
    return out
end

-- Grounding: reject the model's meta-commentary ("The user is teaching...") and any
-- signal whose wording isn't rooted in what the USER actually said. Precision guard —
-- a bogus reinforcement corrupts the tier/learning signal, so we err toward dropping.
local META = { "^the user", "^the assistant", "^this ", "previous statement", "clarified" }

local function is_meta(low)
    for _, p in ipairs(META) do if low:find(p) then return true end end
    return false
end

local function content_words(s, into)
    into = into or {}
    for w in s:lower():gmatch("[%a][%w_%-]+") do if #w >= 4 then into[w] = true end end
    return into
end

local function user_vocab(turns)
    local set = {}
    for _, t in ipairs(turns) do
        if type(t) == "string" or t.role ~= "assistant" then content_words(turn_text(t), set) end
    end
    return set
end

local function grounded(text, user_set)
    if is_meta(text:lower()) then return false end
    local n = 0
    for w in pairs(content_words(text)) do if user_set[w] then n = n + 1 end end
    return n >= 2   -- shares at least two content words with the user's turns
end

--- run(turns, cfg) -> list of signal events (possibly empty). Never throws.
function M.run(turns, cfg)
    if not turns or #turns == 0 then return {} end
    if not generate.available(cfg) then return {} end
    local ok, res = pcall(function()
        local raw  = M.parse(generate.complete(M.build_prompt(turns), cfg))
        local vocab = user_vocab(turns)
        local kept = {}
        for _, e in ipairs(raw) do
            if grounded(e.text, vocab) then kept[#kept + 1] = e end
        end
        return kept
    end)
    if not ok then return {} end
    return res
end

return M
