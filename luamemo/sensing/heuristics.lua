-- luamemo.sensing.heuristics  (Phase 9 — signal capture, cheap no-LLM layer)
--
-- Pure-Lua detection of feedback signals in a conversation: the USER correcting,
-- commanding, or confirming the assistant. High-precision, zero deps, no LLM —
-- the cheap floor beneath the local-generative "dreams" extraction. Emits signal
-- events that the sensing orchestrator resolves to a memory + records as a
-- reinforcement (mistake / direct_command / praise) via digest.record_event.
--
-- Only USER turns are scanned (the user is the one grading the assistant). Each
-- returned event carries the turn text as context so the orchestrator can resolve
-- WHICH memory it refers to (nearest memory in the scope).

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
    { pat = "make%s+sure%s+to",         kind = "command",    conf = 0.75 },
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

-- detect(turns) -> array of { kind, event_type, text, confidence }
--   turns: array of { role = "user"|"assistant", text = "..." }  (strings also OK,
--   treated as user turns). At most one event per (turn, kind), highest-confidence.
function M.detect(turns)
    local out = {}
    if type(turns) ~= "table" then return out end
    for _, t in ipairs(turns) do
        local role, text
        if type(t) == "string" then role, text = "user", t
        else role, text = t.role, t.text end
        if is_user(role) and type(text) == "string" and text ~= "" then
            local low = text:lower()
            local best = {}   -- kind -> best event this turn
            for _, p in ipairs(M.PATTERNS) do
                if low:find(p.pat) then
                    local cur = best[p.kind]
                    if not cur or p.conf > cur.confidence then
                        best[p.kind] = { kind = p.kind, event_type = M.EVENT_TYPE[p.kind],
                                         text = text, confidence = p.conf }
                    end
                end
            end
            for _, ev in pairs(best) do out[#out + 1] = ev end
        end
    end
    return out
end

return M
