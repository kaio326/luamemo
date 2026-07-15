#!/usr/bin/env luajit
-- Phase 7 — embedder quality comparison on the project-personalization set,
-- in-memory (bruteforce cosine, no DB). Measures whether the in-process
-- EmbeddingGemma (owned, no vendor) delivers real semantic quality vs the
-- lexical hash embedder — especially on the low-lexical-overlap bucket.
--
-- EmbeddingGemma is used with its task prompts (query vs document).
--
--   luajit eval/embedder_compare.lua --embedder hash|gemma
--   MEMO_GGUF_MODEL=~/models/embeddinggemma-300M-Q8_0.gguf

package.path = "./?.lua;./?/init.lua;" .. package.path
local cjson = require("cjson.safe")

local EMB = "hash"
do local i=1 while i<=#arg do if arg[i]=="--embedder" then EMB=arg[i+1]; i=i+2 else i=i+1 end end end

local function load_jsonl(p) local f=assert(io.open(p)); local r={}
    for line in f:lines() do if line:match("%S") then local o=cjson.decode(line); if o then r[#r+1]=o end end end
    f:close(); return r end
local corpus  = load_jsonl("eval/personalization/corpus.jsonl")
local queries = load_jsonl("eval/personalization/queries.jsonl")
local idx_of={}; for i,m in ipairs(corpus) do idx_of[m.id]=i end

-- embedder functions: return an L2-normalised Lua vector for (text, role)
local embed_doc, embed_query
if EMB == "hash" then
    local hash = require("luamemo.embedders.hash")
    embed_doc   = function(t) return hash.embed(t, { embed_dim = 384 }) end
    embed_query = embed_doc
elseif EMB == "gemma" then
    local g = require("luamemo.embedders.gguf_ffi")
    local model = os.getenv("MEMO_GGUF_MODEL") or (os.getenv("HOME").."/models/embeddinggemma-300M-Q8_0.gguf")
    local cfg = { embedder_model = model }
    -- EmbeddingGemma task prompts (retrieval)
    embed_doc   = function(t) return (assert(g.embed("title: none | text: " .. t, cfg))) end
    embed_query = function(t) return (assert(g.embed("task: search result | query: " .. t, cfg))) end
else
    io.stderr:write("unknown --embedder\n"); os.exit(2)
end

local function dot(a,b) local s=0; for i=1,#a do s=s+a[i]*b[i] end; return s end

-- embed corpus once
local t0=os.clock()
local mvec={}; for i,m in ipairs(corpus) do mvec[i]=embed_doc(m.body or "") end
print(string.format("embedder=%s  embedded %d corpus docs in %.1fs (dim=%d)", EMB, #corpus, os.clock()-t0, #mvec[1]))

local KS={1,3,5,10}
local function bucket() local b={n=0,mrr=0,hit={}}; for _,k in ipairs(KS) do b.hit[k]=0 end; return b end
local function add(b,r) b.n=b.n+1; if r then b.mrr=b.mrr+1/r; for _,k in ipairs(KS) do if r<=k then b.hit[k]=b.hit[k]+1 end end end end
local function fin(b) local o={n=b.n,mrr=b.n>0 and b.mrr/b.n or 0}; for _,k in ipairs(KS) do o[k]=b.n>0 and b.hit[k]/b.n or 0 end; return o end
local all=bucket(); local by={}
local function ov(n) by[n]=by[n] or bucket(); return by[n] end

for _,q in ipairs(queries) do
    local gi=idx_of[q.gold_id]
    if gi then
        local qv=embed_query(q.query)
        local scored={}; for i=1,#corpus do scored[i]={i=i,s=dot(qv,mvec[i])} end
        table.sort(scored, function(a,b) if a.s==b.s then return a.i<b.i end return a.s>b.s end)
        local rank; for r=1,#scored do if scored[r].i==gi then rank=r break end end
        add(all,rank); add(ov(q.lexical_overlap or "?"),rank)
    end
end

local function line(tag,b) local o=fin(b)
    print(string.format("%-9s n=%2d  R@1=%.1f%%  R@3=%.1f%%  R@5=%.1f%%  R@10=%.1f%%  MRR=%.3f",
        tag,o.n,100*o[1],100*o[3],100*o[5],100*o[10],o.mrr)) end
print("")
line("OVERALL",all)
for _,n in ipairs({"low","med","high"}) do if by[n] then line("  "..n,by[n]) end end
