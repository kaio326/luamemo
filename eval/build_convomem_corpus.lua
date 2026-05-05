-- eval/build_convomem_corpus.lua
--
-- Phase 16.6b: convert raw ConvoMem `batched_NNN.json` files (HF schema)
-- into the superset shape expected by `eval/datasets/convomem.lua`.
--
-- Input: eval/data/convomem_raw/<tag>_b<NNN>.json
--   Each file is an array of test cases:
--     {
--       "contextSize": <int>,
--       "evidenceItems": [{
--         "question", "answer", "category",
--         "message_evidences": [{ "speaker", "text" }]
--       }, ...],
--       "conversations": [
--         { "messages": [{ "speaker", "text" }, ...] },
--         ... contextSize entries (mix of evidence-bearing + filler)
--       ]
--     }
--
-- Output: eval/data/convomem.json (single JSON array of rows shaped
-- as { dialogue_id, sessions, qa }). One row per test case. Each
-- conversation in the case becomes a session "s<i>". Gold session
-- IDs are derived by exact-substring matching every
-- `evidenceItems[*].message_evidences[*].text` against
-- `case.conversations[i].messages[*].text`. The first conversation
-- containing the evidence text becomes part of the gold set.
--
-- Usage:
--   lua5.1 eval/build_convomem_corpus.lua \
--     --in eval/data/convomem_raw \
--     --out eval/data/convomem.json
--
-- The script is intentionally pure-Lua (cjson only) so it can run
-- inside the same OpenResty/luarocks environment as the bench.

local cjson = require("cjson")

-- ----- args ---------------------------------------------------------
local in_dir  = "eval/data/convomem_raw"
local out_path = "eval/data/convomem.json"
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--in" then in_dir = arg[i + 1]; i = i + 2
    elseif a == "--out" then out_path = arg[i + 1]; i = i + 2
    else i = i + 1 end
end

-- ----- helpers ------------------------------------------------------
local function read_file(path)
    local fh, ferr = io.open(path, "rb")
    if not fh then error("cannot open " .. path .. ": " .. tostring(ferr)) end
    local raw = fh:read("*a"); fh:close()
    return raw
end

local function list_files(dir)
    local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
    if not p then return {} end
    local files = {}
    for line in p:lines() do
        if line:match("%.json$") then files[#files + 1] = line end
    end
    p:close()
    return files
end

-- Build the index of which top-level conversation contains each
-- evidence text (substring match). Returns a set keyed by session id
-- "s<i>" (1-based to align with iter_sessions default).
local function find_gold_session_ids(conversations, message_evidences)
    local hit = {}
    for _, ev in ipairs(message_evidences or {}) do
        local needle = ev.text
        if needle and needle ~= "" then
            for ci, conv in ipairs(conversations) do
                local found = false
                for _, m in ipairs(conv.messages or {}) do
                    if m.text and m.text:find(needle, 1, true) then
                        found = true; break
                    end
                end
                if found then hit["s" .. tostring(ci)] = true; break end
            end
        end
    end
    return hit
end

local function set_to_list(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- ----- main ---------------------------------------------------------
local files = list_files(in_dir)
table.sort(files)
print(string.format("[build] in_dir=%s files=%d out=%s", in_dir, #files, out_path))

local rows = {}
local total_cases, total_qas, total_unmatched = 0, 0, 0
local cs_hist = {}

for _, fname in ipairs(files) do
    local tag, batch = fname:match("^(.-)_b(%d+)%.json$")
    if not tag then
        print("[build] skip (bad name): " .. fname)
    else
        local path = in_dir .. "/" .. fname
        print(string.format("[build] reading %s ...", fname))
        local raw = read_file(path)
        local cases = cjson.decode(raw)
        if type(cases) ~= "table" then
            error("expected JSON array in " .. fname)
        end
        for ci, case in ipairs(cases) do
            local cs = case.contextSize or 0
            cs_hist[cs] = (cs_hist[cs] or 0) + 1
            local sessions = {}
            for si, conv in ipairs(case.conversations or {}) do
                sessions[#sessions + 1] = {
                    session_id = "s" .. tostring(si),
                    turns = conv.messages or {},
                }
            end
            local qa_list = {}
            for _, ev in ipairs(case.evidenceItems or {}) do
                local gold = find_gold_session_ids(case.conversations or {}, ev.message_evidences or {})
                local gold_list = set_to_list(gold)
                if #gold_list == 0 then total_unmatched = total_unmatched + 1 end
                qa_list[#qa_list + 1] = {
                    question             = ev.question or "",
                    answer               = ev.answer or "",
                    category             = ev.category or tag,
                    evidence_session_ids = gold_list,
                }
                total_qas = total_qas + 1
            end
            rows[#rows + 1] = {
                dialogue_id = string.format("%s-b%s-c%04d", tag, batch, ci),
                sessions    = sessions,
                qa          = qa_list,
            }
            total_cases = total_cases + 1
        end
    end
end

print(string.format("[build] cases=%d qas=%d unmatched_gold=%d",
    total_cases, total_qas, total_unmatched))
local cs_keys = {}
for k in pairs(cs_hist) do cs_keys[#cs_keys + 1] = k end
table.sort(cs_keys)
for _, k in ipairs(cs_keys) do
    print(string.format("[build]   contextSize=%d -> %d cases", k, cs_hist[k]))
end

local out_fh, oerr = io.open(out_path, "wb")
if not out_fh then error("cannot write " .. out_path .. ": " .. tostring(oerr)) end
out_fh:write(cjson.encode(rows))
out_fh:close()
print("[build] wrote " .. out_path)
