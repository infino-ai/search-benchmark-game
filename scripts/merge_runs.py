#!/usr/bin/env python3
"""Merge engine columns measured in separate runs into one results file.

Usage:
    merge_runs.py <out.json> <in1.json> <in2.json> [...]
                  [--index-size ENGINE=BYTES ...]

`--index-size` corrects a size an input recorded wrongly, which a completed run
cannot be asked to redo. It is needed because an engine whose index lives in
object storage has nothing to measure locally, and a stale `engines/<e>/idx`
symlink left over from an earlier run measures confidently and reports that
earlier index instead.

The standard benchmark runs every engine in one process so the columns share a
machine, a moment and a page cache. At scale that is not always possible: a
billion-document index may take hours per engine, and an engine whose index is
already built should not be re-run just to sit beside a new one.

So this splices columns together, and is explicit that it has done so. Each
column carries a note naming the run it came from, because a cross-run
comparison is a weaker claim than a same-run one: the engines did not contend
for the same page cache, and anything that changed on the box between the runs
is inside the difference.

Alignment is by exact query string, as `merge_turbopuffer.py` does. A command
present in only one input keeps the columns it has.
"""
import json
import sys
from os import path


def queries_of(column):
    return [q.get("query") for q in column]


def merge(inputs, index_sizes=None):
    """Union the engine columns of several results files, by command."""
    out = {"run": {}, "details": {}, "index_sizes": {}, "results": {}}
    runs = []

    for name, doc in inputs:
        run = doc.get("run") or {}
        engines = sorted({e for cmd in doc.get("results", {}).values() for e in cmd})
        runs.append({
            "file": path.basename(name),
            "engines": engines,
            "started_utc": run.get("started_utc"),
            "commands": run.get("commands"),
        })
        # Corpus and query set must agree, or the columns are not comparable at
        # all; the first file's values stand and a disagreement is reported.
        for key in ("corpus", "queries"):
            if key in run:
                if key in out["run"] and out["run"][key] != run[key]:
                    print(f"WARNING: {key} differs in {name}:\n"
                          f"  have {out['run'][key]}\n  got  {run[key]}", file=sys.stderr)
                out["run"].setdefault(key, run[key])

        for engine, detail in (doc.get("details") or {}).items():
            out["details"][engine] = list(detail)
        for engine, size in (doc.get("index_sizes") or {}).items():
            if size is not None:
                out["index_sizes"][engine] = size

        for cmd, columns in doc.get("results", {}).items():
            dest = out["results"].setdefault(cmd, {})
            for engine, column in columns.items():
                if dest and queries_of(next(iter(dest.values()))) != queries_of(column):
                    print(f"WARNING: {cmd}/{engine} in {name} has a different query "
                          f"set from the columns already merged; the page will "
                          f"align rows that are not the same query", file=sys.stderr)
                dest[engine] = column

    for engine, size in (index_sizes or {}).items():
        was = out["index_sizes"].get(engine)
        out["index_sizes"][engine] = size
        print(f"index size for {engine}: {was} -> {size} (overridden)", file=sys.stderr)

    out["run"]["merged_from"] = runs
    # Say it on the columns too: details render on the page today, the run block
    # does not render on every published bundle.
    if len(runs) > 1:
        for r in runs:
            when = (r["started_utc"] or "an earlier run")[:19].replace("T", " ")
            for engine in r["engines"]:
                out["details"].setdefault(engine, []).append(
                    f"Measured in a separate run ({when} UTC), not alongside the "
                    f"other columns on this page."
                )
    return out


def main():
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    args = sys.argv[1:]
    overrides = {}
    while "--index-size" in args:
        i = args.index("--index-size")
        engine, _, raw = args[i + 1].partition("=")
        overrides[engine] = int(raw)
        del args[i:i + 2]
    out_path, in_paths = args[0], args[1:]
    inputs = [(p, json.load(open(p))) for p in in_paths]
    merged = merge(inputs, overrides)
    with open(out_path, "w") as f:
        json.dump(merged, f)
    cmds = sorted(merged["results"])
    engines = sorted({e for c in merged["results"].values() for e in c})
    print(f"wrote {out_path}: {len(cmds)} commands, engines {engines}")
    for r in merged["run"]["merged_from"]:
        print(f"  {r['file']}: {r['engines']} at {r['started_utc']}")


if __name__ == "__main__":
    main()
