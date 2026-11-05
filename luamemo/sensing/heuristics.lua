-- luamemo.sensing.heuristics  (Phase 9 — signal capture, cheap no-LLM layer)
--
-- Pure-Lua detection of feedback signals in a conversation: the USER correcting,
-- commanding, or confirming the assistant. High-precision, zero deps, no LLM —
-- the cheap floor beneath the local-generative "dreams" extraction. Emits signal
-- events that the sensing orchestrator resolves to a memory + records as a
-- reinforcement (mistake / direct_command / praise) via digest.record_event.
--
-- Only USER turns are scanned (the user is the one grading the assistant). Each
-- returned event carries the turn's text, so the orchestrator can resolve WHICH memory
-- it refers to (nearest memory in the scope), and `context`: the assistant turn the
-- user was answering. rule_text says which sentences of a command turn state a
-- standing rule worth a memory of its own.

local M = {}

-- Ordered signal patterns. Each: { pat = Lua pattern (applied lowercased),
-- kind = correction|command|praise, conf = base confidence }. `%f[%a]`/`%f[%A]`
-- are frontier patterns for rough word boundaries.
M.PATTERNS = {
    -- corrections -> "mistake" (a memory should have prevented this)
    { pat = "^%s*no[,%.%s]",            kind = "correction", conf = 0.85 },
    { pat = "that'?s?%s+wrong",         kind = "correction", conf = 0.9  },
    { pat = "that'?s?%s+not%s+right",   kind = "correction", conf = 0.9  },
    { pat = "that'?s?%s+incorrect",     kind = "correction", conf = 0.9  },
    { pat = "%f[%a]incorrect%f[%A]",    kind = "correction", conf = 0.8  },
    { pat = "%f[%a]actually%f[%A]",     kind = "correction", conf = 0.6  },
    { pat = "we%s+don'?t",              kind = "correction", conf = 0.75 },
    { pat = "we%s+do%s+not",            kind = "correction", conf = 0.75 },
    { pat = "not%s+how%s+we",           kind = "correction", conf = 0.85 },
    { pat = "instead%s+of",             kind = "correction", conf = 0.6  },
    { pat = "should%s+have",            kind = "correction", conf = 0.7  },
    { pat = "shouldn'?t%s+have",        kind = "correction", conf = 0.75 },
    -- commands/directives -> "direct_command"
    { pat = "%f[%a]always%f[%A]",       kind = "command",    conf = 0.8  },
    { pat = "%f[%a]never%f[%A]",        kind = "command",    conf = 0.8  },
    { pat = "make%s+sure",              kind = "command",    conf = 0.75 },
    { pat = "you%s+have%s+to",          kind = "command",    conf = 0.75 },
    { pat = "do%s+not%s+ever",          kind = "command",    conf = 0.8  },
    { pat = "don'?t%s+ever",            kind = "command",    conf = 0.8  },
    { pat = "remember%s+to",            kind = "command",    conf = 0.75 },
    { pat = "from%s+now%s+on",          kind = "command",    conf = 0.8  },
    { pat = "going%s+forward",          kind = "command",    conf = 0.7  },
    { pat = "you%s+must",               kind = "command",    conf = 0.75 },
    -- confirmations/praise -> "praise"
    { pat = "%f[%a]exactly%f[%A]",      kind = "praise",     conf = 0.8  },
    { pat = "that'?s?%s+right",         kind = "praise",     conf = 0.85 },
    { pat = "that'?s?%s+correct",       kind = "praise",     conf = 0.85 },
    { pat = "%f[%a]perfect%f[%A]",      kind = "praise",     conf = 0.7  },
    { pat = "well%s+done",              kind = "praise",     conf = 0.7  },
    { pat = "%f[%a]yes%f[%A].-thank",   kind = "praise",     conf = 0.7  },
}

-- Map a signal kind -> lm_reinforcements event_type.
M.EVENT_TYPE = { correction = "mistake", command = "direct_command", praise = "praise" }

local function is_user(role)
    return role == nil or role == "user" or role == "human"
end

-- ── Standing rules ──────────────────────────────────────────────────────────
-- A command signal is a feedback on a memory; a STANDING RULE is the user telling the agent how to work from now on,
-- and it is worth a memory of its own when none holds it. The gate is strict — a stored rule nobody gave is worse
-- than a missed one: the turn must be short, with no question and no pasted code, and it must BEGIN with the rule (a
-- sentence that opens with the rule's words, after a few lead-in words; at most a short greeting before it) — a line of
-- a longer text the user pasted is not theirs. The openers are the command PATTERNS' phrases (a rule needs a command
-- signal to reach here); what follows an opener decides too: "never mind" and "always happy to help" are no rule.
M.RULE_OPENERS = { "always", "never", "from now on", "going forward", "make sure", "remember to", "you must",
    "you have to", "you should always", "you should never", "do not ever", "don't ever" }
local LEAD_INS = { please = true, ok = true, okay = true, also = true, ["and"] = true, so = true, now = true,
    btw = true, but = true, ["then"] = true, yes = true, yeah = true, well = true }
-- (the word after an opener that makes it a remark, not a rule; an opener with no word after it — "Always." — is one too)
local NOT_A_RULE_AFTER = { mind = true, again = true, been = true, happy = true, glad = true, fine = true, welcome = true,
    was = true, were = true, said = true, meant = true, knew = true, thought = true, did = true,
    thanks = true, thank = true, cheers = true, ok = true, okay = true, works = true, worked = true, sounds = true,
    looks = true }
M.RULE_MAX_CHARS = 600
M.RULE_MAX_SENTENCES = 3
local GREETING_WORDS = 3   -- (a sentence this short before the rule — "Thanks!", "Got it." — is skipped)

-- A sentence without its lead-in words ("ok, and always …"), in its own case and in lower case
local function opening(s)
    local low = s:lower()
    while true do
        local lead = low:match("^(%a+)[%s,]+")
        if not (lead and LEAD_INS[lead]) then break end
        local cut = #low:match("^%a+[%s,]+")
        s, low = s:sub(cut + 1), low:sub(cut + 1)
    end
    return s, low
end

local function states_a_rule(low)
    for _, opener in ipairs(M.RULE_OPENERS) do
        if low:sub(1, #opener) == opener and not low:sub(#opener + 1, #opener + 1):match("%a") then
            -- What follows the opener, past everything that is not an ASCII letter or digit — spaces, ASCII punctuation, and
            -- any multibyte mark (dashes, ellipsis, quotes, arrows, emoji, a no-break space): "Always, thanks" -> "thanks".
            -- Nothing left: a remark. An ASCII word of the deny list: a remark. Anything else is the rule's own text, a digit
            -- included ("Always 2 spaces", "Never 100% trust it"); a letter beyond ASCII is skipped like a mark, which only
            -- matters when the word after it is a remark word.
            local rest = low:sub(#opener + 1):match("^[^%w]*(.*)$")
            if rest == "" then return false end
            return not NOT_A_RULE_AFTER[rest:match("^(%a+)") or ""]
        end
    end
    return false
end

-- rule_text(text) -> the rule sentences that begin the turn (joined by ". ") | nil
function M.rule_text(text)
    if type(text) ~= "string" or #text < 12 or #text > M.RULE_MAX_CHARS then return nil end
    if text:find("?", 1, true) or text:find("```", 1, true) then return nil end
    local rules = {}
    -- (sentences end at ". ", "! " or a line break: not at the dot of memo.lua)
    local normalized = text:gsub("\r", ""):gsub("([%.!])%s+", "%1\n")
    for sentence in (normalized .. "\n"):gmatch("([^\n]+)\n") do
        local s, low = opening(sentence:gsub("^[%s%p]+", ""):gsub("[%s%.!\"]+$", ""))
        if states_a_rule(low) then
            rules[#rules + 1] = s
            if #rules >= M.RULE_MAX_SENTENCES then break end
        elseif #rules > 0 then break                                            -- (the rule ended)
        elseif select(2, s:gsub("%S+", "")) > GREETING_WORDS then return nil end   -- (it does not begin with one)
    end
    if #rules == 0 then return nil end
    return table.concat(rules, ". ")
end

-- detect(turns) -> array of { kind, event_type, text, confidence, context }
--   turns: array of { role = "user"|"assistant", text = "..." }  (strings also OK,
--   treated as user turns). At most one event per (turn, kind), highest-confidence.
--   context: the assistant turn just before the user's (what the user was answering), if any.
function M.detect(turns)
    local out = {}
    if type(turns) ~= "table" then return out end
    local prev_assistant
    for _, t in ipairs(turns) do
        local role, text
        if type(t) == "string" then role, text = "user", t
        else role, text = t.role, t.text end
        if not is_user(role) and type(text) == "string" then prev_assistant = text end
        if is_user(role) and type(text) == "string" and text ~= "" then
            local low = text:lower()
            local best = {}   -- kind -> best event this turn
            for _, p in ipairs(M.PATTERNS) do
                if low:find(p.pat) then
                    local cur = best[p.kind]
                    if not cur or p.conf > cur.confidence then
                        best[p.kind] = { kind = p.kind, event_type = M.EVENT_TYPE[p.kind],
                                         text = text, confidence = p.conf, context = prev_assistant }
                    end
                end
            end
            for _, ev in pairs(best) do out[#out + 1] = ev end
            prev_assistant = nil
        end
    end
    return out
end

return M
