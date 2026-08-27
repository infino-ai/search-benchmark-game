#!/usr/bin/env python3
"""
Compare infino-0.1 performance between two results.json files.

Usage:
  compare_results.py <baseline.json> <experiment.json> [--label <name>]

Outputs GitHub-flavored markdown for GITHUB_STEP_SUMMARY.
"""
import json
import math
import sys


def median(durations):
    if not durations:
        return None
    s = sorted(durations)
    return s[len(s) // 2]


def fmt_bytes(n):
    if n is None:
        return "n/a"
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.2f} {unit}"
        n /= 1024.0


def load_index_sizes(path):
    with open(path) as f:
        return json.load(f).get("index_sizes", {}) or {}


def load_infino(path):
    with open(path) as f:
        data = json.load(f)
    results = data.get("results", data)
    out = {}
    for metric, engines in results.items():
        infino = engines.get("infino-0.1", [])
        out[metric] = {q["query"]: median(q["duration"]) for q in infino if q.get("duration")}
    return out


def compare(baseline_path, experiment_path, label):
    baseline = load_infino(baseline_path)
    experiment = load_infino(experiment_path)

    lines = [f"## infino-0.1: `{label}` vs main\n"]

    all_ratios = []

    for metric in sorted(baseline.keys()):
        if metric not in experiment:
            continue
        b_queries = baseline[metric]
        e_queries = experiment[metric]

        rows = []
        for query in sorted(b_queries.keys()):
            if query not in e_queries:
                continue
            b_us = b_queries[query]
            e_us = e_queries[query]
            if b_us is None or e_us is None or b_us == 0:
                continue
            ratio = e_us / b_us
            all_ratios.append(ratio)
            pct = (ratio - 1) * 100
            sign = "+" if pct > 0 else ""
            flag = " ⚠️" if pct > 5 else (" ✅" if pct < -5 else "")
            rows.append((query, b_us, e_us, pct, sign, flag))

        if not rows:
            continue

        lines.append(f"### {metric}\n")
        lines.append("| query | main µs | branch µs | Δ% |")
        lines.append("|---|---:|---:|---:|")
        for query, b_us, e_us, pct, sign, flag in sorted(rows, key=lambda r: r[3]):
            lines.append(f"| `{query}` | {b_us} | {e_us} | {sign}{pct:.1f}%{flag} |")
        lines.append("")

    b_sizes = load_index_sizes(baseline_path)
    e_sizes = load_index_sizes(experiment_path)
    if b_sizes or e_sizes:
        lines.append("### Index size\n")
        lines.append("| engine | main | branch | Δ% |")
        lines.append("|---|---:|---:|---:|")
        # Preserve the ENGINES / results.json order (branch first, then any
        # baseline-only engine) so this matches the latency ordering rather
        # than alphabetizing.
        for engine in dict.fromkeys(list(e_sizes) + list(b_sizes)):
            b = b_sizes.get(engine)
            e = e_sizes.get(engine)
            if b and e:
                pct = (e / b - 1) * 100
                delta = f"{'+' if pct > 0 else ''}{pct:.2f}%"
            else:
                delta = "—"
            lines.append(f"| {engine} | {fmt_bytes(b)} | {fmt_bytes(e)} | {delta} |")
        lines.append("")

    if all_ratios:
        gmean = math.exp(sum(math.log(r) for r in all_ratios) / len(all_ratios))
        gpct = (gmean - 1) * 100
        sign = "+" if gpct > 0 else ""
        verdict = "faster ✅" if gpct < -1 else ("slower ⚠️" if gpct > 1 else "no change")
        lines.append(f"**Geometric mean: {sign}{gpct:.1f}% ({verdict} vs main)**\n")

    print("\n".join(lines))


if __name__ == "__main__":
    args = sys.argv[1:]
    label = "experiment"
    if "--label" in args:
        idx = args.index("--label")
        label = args[idx + 1]
        args = args[:idx] + args[idx + 2:]

    if len(args) < 2:
        print("Usage: compare_results.py <baseline.json> <experiment.json> [--label <name>]",
              file=sys.stderr)
        sys.exit(1)

    compare(args[0], args[1], label)
