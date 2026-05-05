#!/usr/bin/env bash
# Phase 16.2 — three-config rerank head-to-head bench.
# Runs against longmemeval_s.json (the original 1214s baseline corpus).
set -u
cd "$(dirname "$0")/.."
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE=lm_bruteforce_test
export OLLAMA_MODEL=nomic-embed-text OLLAMA_DIM=768
export INGEST_BATCH_SIZE=100
N=200
CORPUS=eval/data/longmemeval_s.json
OUT=eval/results

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a /tmp/phase162.log; }

log "=== Phase 16.2 bench start (n=$N corpus=$CORPUS) ==="

log "Run 1/3: no rerank"
lua5.1 eval/longmemeval_run.lua --embedder ollama --corpus "$CORPUS" --n $N \
  --out "$OUT/longmemeval_ollama_s_n${N}_norerank.json" >> /tmp/phase162.log 2>&1
log "Run 1/3 done."

log "Run 2/3: rerank=noop top_n=20"
lua5.1 eval/longmemeval_run.lua --embedder ollama --corpus "$CORPUS" --n $N \
  --rerank --rerank-adapter noop --rerank-top-n 20 \
  --out "$OUT/longmemeval_ollama_s_n${N}_rerank-noop.json" >> /tmp/phase162.log 2>&1
log "Run 2/3 done."

log "Run 3/3: rerank=ollama llama3.2:1b top_n=20"
OLLAMA_RERANK_MODEL=llama3.2:1b lua5.1 eval/longmemeval_run.lua --embedder ollama --corpus "$CORPUS" --n $N \
  --rerank --rerank-adapter ollama --rerank-top-n 20 \
  --out "$OUT/longmemeval_ollama_s_n${N}_rerank-ollama-llama3.2-1b.json" >> /tmp/phase162.log 2>&1
log "Run 3/3 done."

log "=== Phase 16.2 bench complete ==="
