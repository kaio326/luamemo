#!/usr/bin/env lua5.1
-- Phase 4 — learned reranker evaluation via k-fold cross-validation on the
-- project-personalization set. Honest methodology: the learned model NEVER sees
-- the test fold's labels. The `reuse` feature for a test query is derived only
-- from TRAIN-fold golds (a memory that answered a *related* question), so any
-- lift is generalisation, not leakage.
--
--   for each fold: train on the other folds' (query -> gold) triples, then
--   rerank the SAME retrieved pool for the held-out queries and compare the
--   gold's rank vs the baseline order.
--
-- Usage:
--   PGHOST=127.0.0.1 PGDATABASE=luamemo_dev PGUSER=postgres PGPASSWORD=postgres \
--     lua5.1 eval/rerank_bench.lua [--folds 4] [--epochs 300]

package.path = "./?/init.lua;./?.lua;" .. package.path
local cjson   = require("cjson.safe")
local memory  = require("luamemo")
local db      = require("luamemo.db")
local learned = require("luamemo.rerankers.learned")
local trainer = require("luamemo.rerank_train")

local K, EPOCHS, L2, LR = 4, 300, 0.02, 0.1
do local i=1 while i<=#arg do
    if arg[i]=="--folds" then K=tonumber(arg[i+1]); i=i+2
    elseif arg[i]=="--epochs" then EPOCHS=tonumber(arg[i+1]); i=i+2
    elseif arg[i]=="--l2" then L2=tonumber(arg[i+1]); i=i+2
    elseif arg[i]=="--lr" then LR=tonumber(arg[i+1]); i=i+2
    else i=i+1 end end end

local function load_jsonl(p)
    local f=assert(io.open(p,"r")); local r={}
    for line in f:lines() do if line:match("%S") then local o=cjson.decode(line); if o then r[#r+1]=o end end end
    f:close(); return r
end
local corpus  = load_jsonl("eval/personalization/corpus.jsonl")
local queries = load_jsonl("eval/personalization/queries.jsonl")

memory.setup({ embedder_local="hash", embed_dim=384, backend="auto",
    auth_fn=function() return true end, skip_embed_probe=true })
local SCOPE = "perso:rrbench"

-- Ingest corpus; map item_id -> memory row id.
db.query("DELETE FROM lm_memories WHERE scope = " .. db.escape_literal(SCOPE))
local id_of = {}
for _, m in ipairs(corpus) do
    local row = memory.write({ scope=SCOPE, kind=m.kind or "fact", title=m.title or m.id,
        body=m.body or "", tags=m.tags, importance=1.0, metadata={ item_id=m.id } })
    id_of[m.id] = row and row.id
end

local function search(q)
    return memory.store.search({ query=q, scope=SCOPE, limit=20,
        skip_temporal=true, skip_observations=true }) or {}
end
local function gold_rank(rows, gold_id)   -- 1-based index of the gold, or nil
    for i, r in ipairs(rows) do
        local md=r.metadata; if type(md)=="string" then md=cjson.decode(md) end
        if md and md.item_id==gold_id then return i end
    end
end
local function reorder(rows, scored)      -- apply {index,score} -> new row order
    local idx={}; for i=1,#rows do idx[i]=i end
    table.sort(idx, function(a,b)
        local sa,sb=scored[a].score,scored[b].score
        if sa==sb then return a<b end; return sa>sb end)
    local out={}; for i=1,#idx do out[i]=rows[idx[i]] end; return out
end

-- metrics accumulators
local KS={1,3,5,10}
local function bucket() local b={n=0,mrr=0,hit={}}; for _,k in ipairs(KS) do b.hit[k]=0 end; return b end
local function add(b,rank) b.n=b.n+1; if rank then b.mrr=b.mrr+1/rank; for _,k in ipairs(KS) do if rank<=k then b.hit[k]=b.hit[k]+1 end end end end
local function fin(b) local o={n=b.n,mrr=b.n>0 and b.mrr/b.n or 0}; for _,k in ipairs(KS) do o[k]=b.n>0 and b.hit[k]/b.n or 0 end; return o end

local base = { all=bucket() }; local lrn = { all=bucket() }
local function ov(t,name) t[name]=t[name] or bucket(); return t[name] end

for f=1,K do
    -- reuse feature: count how often each memory is a TRAIN-fold gold.
    local reuse={}
    for i,q in ipairs(queries) do
        if ((i-1)%K)+1 ~= f then
            local mid=id_of[q.gold_id]; if mid then reuse[mid]=(reuse[mid] or 0)+1 end
        end
    end
    local function enrich(rows) for _,r in ipairs(rows) do r.reuse_count=reuse[r.id] or 0 end end

    -- build training examples from the train folds
    local examples={}
    for i,q in ipairs(queries) do
        if ((i-1)%K)+1 ~= f then
            local rows=search(q.query); enrich(rows)
            local p=gold_rank(rows,q.gold_id)
            if p then examples[#examples+1]={ features=learned.pool_features(rows), positive=p, weight=2.0 } end
        end
    end
    local w=trainer.train(examples,{epochs=EPOCHS,lr=LR,l2=L2})

    -- evaluate held-out fold
    for i,q in ipairs(queries) do
        if ((i-1)%K)+1 == f then
            local rows=search(q.query); enrich(rows)
            local br=gold_rank(rows,q.gold_id)
            local scored=learned.rerank(q.query, rows, { rerank_weights=w })
            local lr=gold_rank(reorder(rows,scored), q.gold_id)
            add(base.all,br); add(lrn.all,lr)
            add(ov(base,q.lexical_overlap or "?"),br); add(ov(lrn,q.lexical_overlap or "?"),lr)
        end
    end
end

db.query("DELETE FROM lm_memories WHERE scope = " .. db.escape_literal(SCOPE))

-- report
local function line(tag,b,l) local B,L=fin(b),fin(l)
    print(string.format("%-9s  base R@1=%.1f%% R@5=%.1f%% MRR=%.3f   |  learned R@1=%.1f%% R@5=%.1f%% MRR=%.3f   |  dR@1=%+.1f dMRR=%+.3f",
        tag,100*B[1],100*B[5],B.mrr, 100*L[1],100*L[5],L.mrr, 100*(L[1]-B[1]), L.mrr-B.mrr)) end
print(string.format("\n%d-fold CV, %d epochs, %d queries, %d-item corpus (hash embedder)\n", K, EPOCHS, #queries, #corpus))
line("OVERALL", base.all, lrn.all)
for _,name in ipairs({"low","med","high"}) do if base[name] then line("  "..name, base[name], lrn[name]) end end
