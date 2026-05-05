#!/usr/bin/env python3
"""Aggregate sweep results from longmemeval_run.lua sweep mode.

Reads two JSON outputs (baseline, rerank-on) produced by
`eval/longmemeval_run.lua --sweep-weights ...` and prints a markdown
table suitable for appending to eval/results/longmemeval.md.
"""
import json
import sys


def load(path):
    with open(path) as fh:
        return json.load(fh)


def fmt_pct(x):
    return f"{x*100:5.1f}%"


def row(label, m):
    return (f"| {label:<20s} | {fmt_pct(m['recall@1']):>7} | "
            f"{fmt_pct(m['recall@5']):>7} | {fmt_pct(m['recall@10']):>7} | "
            f"{fmt_pct(m['recall@20']):>7} | {m['mrr']:.3f} | "
            f"{m['tail_misses']:>3} |")


def render_run(report, label):
    print(f"\n### {label}\n")
    print(f"- elapsed: {report['elapsed_sec']} s")
    print(f"- n_questions: {report['overall']['n_questions']}")
    print(f"- backend: {report['backend']}, embedder: {report['embedder']}, "
          f"rerank: {report['rerank']}\n")
    print("| weights (v, f)       |     R@1 |     R@5 |    R@10 |    R@20 |   MRR | mis |")
    print("|----------------------|---------|---------|---------|---------|-------|-----|")
    best = (None, -1)
    for pt in report["sweep"]["points"]:
        label = f"v={pt['vector']:.2f}, f={pt['fts']:.2f}"
        m = pt["metrics"]
        print(row(label, m))
        if m["recall@5"] > best[1]:
            best = (label, m["recall@5"])
    print(f"\n**Best R@5:** `{best[0]}` -> {fmt_pct(best[1])}")


def main():
    if len(sys.argv) != 3:
        print("usage: sweep_table.py <baseline.json> <rerank.json>",
              file=sys.stderr)
        sys.exit(2)
    baseline = load(sys.argv[1])
    rerank = load(sys.argv[2])
    render_run(baseline, "Baseline (rerank=off)")
    render_run(rerank, "With rerank=noop top-20")

    # Side-by-side delta on the best baseline point
    print("\n### Side-by-side R@5 by weight pair\n")
    print("| weights (v, f)       | baseline R@5 | + rerank R@5 |   Δ |")
    print("|----------------------|--------------|--------------|-----|")
    base_pts = {p["key"]: p for p in baseline["sweep"]["points"]}
    rer_pts = {p["key"]: p for p in rerank["sweep"]["points"]}
    for key in sorted(base_pts.keys()):
        b = base_pts[key]["metrics"]["recall@5"]
        r = rer_pts.get(key, {}).get("metrics", {}).get("recall@5", 0)
        label = f"v={base_pts[key]['vector']:.2f}, f={base_pts[key]['fts']:.2f}"
        delta = r - b
        sign = "+" if delta >= 0 else ""
        print(f"| {label:<20s} | {fmt_pct(b):>12} | {fmt_pct(r):>12} | "
              f"{sign}{delta*100:.1f} pp |")


if __name__ == "__main__":
    main()
