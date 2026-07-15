#!/usr/bin/env lua5.1
-- Phase 5 — learned projection evaluation via k-fold CV on the project-
-- personalization set. In-memory bruteforce cosine over the corpus (the
-- projection changes vectors, so we re-embed queries+corpus with W directly;
-- no DB round-trip). The learned W never sees the test fold's labels — training
-- triples come only from the train folds, so any lift is generalisation.
--
--   baseline: rank corpus by cos(hash(q), hash(body))
--   learned : rank corpus by cos(norm(W·hash(q)), norm(W·hash(body)))
--
-- Usage:
--   lua5.1 eval/projection_bench.lua [--dim 128] [--folds 4] [--epochs 30] [--l2 0.05]

package.path = "./?/init.lua;./?.lua;" .. package.path
local cjson   = require("cjson.safe")
local hash    = require("luamemo.embedders.hash")
local proj    = require("luamemo.projection_train")

local DIM, K, EPOCHS, L2, LR, NEG = 128, 4, 30, 0.05, 0.05, 3
do local i=1 while i<=#arg do local a=arg[i]
    if a=="--dim" then DIM=tonumber(arg[i+1]); i=i+2
    elseif a=="--folds" then K=tonumber(arg[i+1]); i=i+2
    elseif a=="--epochs" then EPOCHS=tonumber(arg[i+1]); i=i+2
    elseif a=="--l2" then L2=tonumber(arg[i+1]); i=i+2
    elseif a=="--lr" then LR=tonumber(arg[i+1]); i=i+2
    elseif a=="--neg" then NEG=tonumber(arg[i+1]); i=i+2
    else i=i+1 end end end

local function load_jsonl(p) local f=assert(io.open(p)); local r={}
    for line in f:lines() do if line:match("%S") then local o=cjson.decode(line); if o then r[#r+1]=o end end end
    f:close(); return r end
local corpus  = load_jsonl("eval/personalization/corpus.jsonl")
local queries = load_jsonl("eval/personalization/queries.jsonl")

-- precompute raw hash vectors
for _,m in ipairs(corpus) do m.vec = hash.embed(m.body or "", { embed_dim=DIM }) end
local idx_of={}; for i,m in ipairs(corpus) do idx_of[m.id]=i end
for _,q in ipairs(queries) do q.vec = hash.embed(q.query, { embed_dim=DIM }); q.gold_idx = idx_of[q.gold_id] end

local function dot(a,b) local s=0; for i=1,#a do s=s+a[i]*b[i] end; return s end
local function matvec(W,x) local d,m=W.dim,W.m; local y={}
    for i=1,d do local base,s=(i-1)*d,0; for j=1,d do s=s+m[base+j]*x[j] end; y[i]=s end; return y end
local function normed(v) local s=0; for i=1,#v do s=s+v[i]*v[i] end
    if s>0 then local inv=1/math.sqrt(s); local o={}; for i=1,#v do o[i]=v[i]*inv end; return o end; return v end

-- rank the corpus for a query vector; return 1-based rank of gold_idx (or nil)
local function rank_of(qv, gold_idx, mvecs)
    local scores={}
    for i=1,#corpus do scores[i]={ i=i, s=dot(qv, mvecs[i]) } end
    table.sort(scores, function(a,b) if a.s==b.s then return a.i<b.i end return a.s>b.s end)
    for r=1,#scores do if scores[r].i==gold_idx then return r end end
end

local raw_mvecs={}; for i=1,#corpus do raw_mvecs[i]=corpus[i].vec end

-- metrics
local KS={1,3,5,10}
local function bucket() local b={n=0,mrr=0,hit={}}; for _,k in ipairs(KS) do b.hit[k]=0 end; return b end
local function add(b,r) b.n=b.n+1; if r then b.mrr=b.mrr+1/r; for _,k in ipairs(KS) do if r<=k then b.hit[k]=b.hit[k]+1 end end end end
local function fin(b) local o={n=b.n,mrr=b.n>0 and b.mrr/b.n or 0}; for _,k in ipairs(KS) do o[k]=b.n>0 and b.hit[k]/b.n or 0 end; return o end
local base={all=bucket()}; local lrn={all=bucket()}
local function ov(t,n) t[n]=t[n] or bucket(); return t[n] end

for f=1,K do
    -- training triples from train folds: gold positive, hard negatives by raw rank
    local examples={}
    for i,q in ipairs(queries) do
        if ((i-1)%K)+1 ~= f and q.gold_idx then
            local ranked={}
            for j=1,#corpus do ranked[j]={ i=j, s=dot(q.vec, corpus[j].vec) } end
            table.sort(ranked, function(a,b) return a.s>b.s end)
            local negs={}
            for _,e in ipairs(ranked) do
                if e.i ~= q.gold_idx then negs[#negs+1]=corpus[e.i].vec end
                if #negs>=NEG then break end
            end
            examples[#examples+1]={ q=q.vec, p=corpus[q.gold_idx].vec, negs=negs }
        end
    end
    local W = proj.train(examples, { dim=DIM, epochs=EPOCHS, l2=L2, lr=LR, margin=0.1 })

    -- project corpus once for this fold
    local proj_mvecs={}; for i=1,#corpus do proj_mvecs[i]=normed(matvec(W, corpus[i].vec)) end

    for i,q in ipairs(queries) do
        if ((i-1)%K)+1 == f and q.gold_idx then
            local br = rank_of(q.vec, q.gold_idx, raw_mvecs)
            local qp = normed(matvec(W, q.vec))
            local lr = rank_of(qp, q.gold_idx, proj_mvecs)
            add(base.all,br); add(lrn.all,lr)
            add(ov(base,q.lexical_overlap or "?"),br); add(ov(lrn,q.lexical_overlap or "?"),lr)
        end
    end
end

local function line(tag,b,l) local B,L=fin(b),fin(l)
    print(string.format("%-9s  base R@1=%.1f%% R@5=%.1f%% MRR=%.3f  |  learned R@1=%.1f%% R@5=%.1f%% MRR=%.3f  |  dR@1=%+.1f dMRR=%+.3f",
        tag,100*B[1],100*B[5],B.mrr,100*L[1],100*L[5],L.mrr,100*(L[1]-B[1]),L.mrr-B.mrr)) end
print(string.format("\nprojection %d-fold CV  dim=%d epochs=%d l2=%.3f neg=%d  (%d queries, %d corpus)\n",
    K,DIM,EPOCHS,L2,NEG,#queries,#corpus))
line("OVERALL",base.all,lrn.all)
for _,n in ipairs({"low","med","high"}) do if base[n] then line("  "..n,base[n],lrn[n]) end end
