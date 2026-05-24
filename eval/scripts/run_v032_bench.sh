#!/usr/bin/env bash
# v0.3.2 benchmark suite — reproduces canonical v0.3.1 run conditions.
#
# Runs all three benchmarks (LongMemEval, LoCoMo, ConvoMem) with hash and
# ollama embedders. Results are written to eval/results/*_v032.json.
#
# Estimated wall time:
#   LoCoMo hash (~36s) + ollama (~105s)
#   ConvoMem hash (~110s) + ollama (~290s)
#   LME hash (~520s / ~9 min) + ollama (~3300s / ~55 min)
#   Total: ~70 min
#
# Usage:
#   bash eval/scripts/run_v032_bench.sh [--hash-only] [--lme-only]
#
set -euo pipefail
cd "$(dirname "$0")/../.."

export PGHOST=127.0.0.1
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD=postgres
export PGDATABASE=lm_bruteforce_test
export OLLAMA_MODEL=nomic-embed-text
export OLLAMA_DIM=768
export LUA=lua5.1

HASH_ONLY=0; LME_ONLY=0
for a in "$@"; do
    [[ "$a" == "--hash-only" ]] && HASH_ONLY=1
    [[ "$a" == "--lme-only"  ]] && LME_ONLY=1
done

OUT=eval/results
LOG=/tmp/bench_v032.log
> "$LOG"

ts() { date +%H:%M:%S; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

log "=== v0.3.2 benchmark suite start ==="
log "DB: $PGHOST:$PGPORT/$PGDATABASE"
log "Ollama model: $OLLAMA_MODEL (dim=$OLLAMA_DIM)"
echo ""

# ── LoCoMo ─────────────────────────────────────────────────────────────────
if [[ "$LME_ONLY" == "0" ]]; then
    log "LoCoMo  [1/2]  hash …"
    $LUA eval/locomo_run.lua \
        --embedder hash \
        --backend bruteforce \
        --out "$OUT/locomo_hash_v032.json" \
        2>>"$LOG"
    log "LoCoMo  [1/2]  hash done."

    if [[ "$HASH_ONLY" == "0" ]]; then
        log "LoCoMo  [2/2]  ollama ($OLLAMA_MODEL) …"
        $LUA eval/locomo_run.lua \
            --embedder ollama \
            --backend bruteforce \
            --out "$OUT/locomo_ollama_v032.json" \
            2>>"$LOG"
        log "LoCoMo  [2/2]  ollama done."
    fi
fi

# ── ConvoMem ────────────────────────────────────────────────────────────────
if [[ "$LME_ONLY" == "0" ]]; then
    log "ConvoMem [1/2]  hash …"
    $LUA eval/convomem_run.lua \
        --embedder hash \
        --backend bruteforce \
        --out "$OUT/convomem_hash_v032.json" \
        2>>"$LOG"
    log "ConvoMem [1/2]  hash done."

    if [[ "$HASH_ONLY" == "0" ]]; then
        log "ConvoMem [2/2]  ollama ($OLLAMA_MODEL) …"
        $LUA eval/convomem_run.lua \
            --embedder ollama \
            --backend bruteforce \
            --out "$OUT/convomem_ollama_v032.json" \
            2>>"$LOG"
        log "ConvoMem [2/2]  ollama done."
    fi
fi

# ── LongMemEval ─────────────────────────────────────────────────────────────
log "LME      [1/2]  hash  (longmemeval_s, n=500) …"
$LUA eval/longmemeval_run.lua \
    --embedder hash \
    --backend bruteforce \
    --corpus eval/data/longmemeval_s.json \
    --out "$OUT/longmemeval_hash_v032.json" \
    2>>"$LOG"
log "LME      [1/2]  hash done."

if [[ "$HASH_ONLY" == "0" ]]; then
    log "LME      [2/2]  ollama ($OLLAMA_MODEL) …"
    $LUA eval/longmemeval_run.lua \
        --embedder ollama \
        --backend bruteforce \
        --corpus eval/data/longmemeval_s.json \
        --out "$OUT/longmemeval_ollama_v032.json" \
        2>>"$LOG"
    log "LME      [2/2]  ollama done."
fi

log "=== v0.3.2 benchmark suite complete. Results in $OUT/*_v032.json ==="

# ── Quick comparison summary ─────────────────────────────────────────────────
echo ""
echo "=== v0.3.2 vs v0.3.1 comparison ==="
python3 - <<'PYEOF'
import json, os, sys

pairs = [
    ("LME hash",       "eval/results/longmemeval_hash_v031.json",        "eval/results/longmemeval_hash_v032.json"),
    ("LME ollama",     "eval/results/longmemeval_ollama_v031_realistic.json","eval/results/longmemeval_ollama_v032.json"),
    ("LoCoMo hash",    "eval/results/locomo_hash_v031.json",              "eval/results/locomo_hash_v032.json"),
    ("LoCoMo ollama",  "eval/results/locomo_ollama_v031_realistic.json",  "eval/results/locomo_ollama_v032.json"),
    ("ConvoMem hash",  "eval/results/convomem_hash_v031.json",            "eval/results/convomem_hash_v032.json"),
    ("ConvoMem ollama","eval/results/convomem_ollama_v031_realistic.json","eval/results/convomem_ollama_v032.json"),
]

print(f"{'Benchmark':<18} {'metric':<8} {'v0.3.1':>8} {'v0.3.2':>8} {'delta':>8}")
print("-" * 56)
for name, old_f, new_f in pairs:
    if not os.path.exists(new_f):
        print(f"{name:<18} (no v0.3.2 result yet)")
        continue
    for old_path in [old_f]:
        if not os.path.exists(old_path): continue
        old = json.load(open(old_path)).get('overall', {})
        new = json.load(open(new_f)).get('overall', {})
        for k, label in [('recall@1','R@1'),('recall@10','R@10'),('mrr','MRR')]:
            ov = float(old.get(k, 0)); nv = float(new.get(k, 0))
            d = nv - ov
            sign = '+' if d >= 0 else ''
            print(f"{name:<18} {label:<8} {ov:>8.3f} {nv:>8.3f} {sign}{d:>7.3f}")
        print()
PYEOF
