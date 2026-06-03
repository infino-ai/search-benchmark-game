#!/usr/bin/env python3
"""Merge turbopuffer's published `turbopuffer` column into our results.json.

Usage:
    merge_turbopuffer.py <ours.json> <turbopuffer_snapshot.json> <out.json>

We run infino / tantivy / lucene ourselves on turbopuffer's exact query set
(see `queries-tpuf.txt`, derived from the snapshot). turbopuffer is a remote
service, so we don't run it — we splice in its published per-query numbers.

Only commands present in BOTH files get a turbopuffer column. Per-query
alignment is by exact query string; a mismatch is reported (it would mean the
local query set drifted from the snapshot).
"""
import json
import sys


def main():
    ours_path, tpuf_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    ours = json.load(open(ours_path))
    tpuf = json.load(open(tpuf_path))

    # Carry over turbopuffer's engine description so the dashboard labels it.
    ours.setdefault("details", {})["turbopuffer"] = (
        tpuf.get("details", {}).get("turbopuffer", ["Remote service (published numbers)."])
    )

    merged_cmds = []
    for cmd, engines in ours["results"].items():
        tpuf_cmd = tpuf["results"].get(cmd, {})
        tpuf_col = tpuf_cmd.get("turbopuffer")
        if not tpuf_col:
            continue

        # Sanity: our query strings for this command should match the snapshot's.
        our_engine = next(iter(engines.values()))
        our_qs = {q["query"] for q in our_engine}
        tpuf_qs = {q["query"] for q in tpuf_col}
        missing = our_qs - tpuf_qs
        if missing:
            print(
                f"  warning [{cmd}]: {len(missing)} local queries absent from "
                f"turbopuffer snapshot (e.g. {sorted(missing)[:2]}) — they will "
                f"show no turbopuffer datapoint",
                file=sys.stderr,
            )

        engines["turbopuffer"] = tpuf_col
        merged_cmds.append(cmd)

    json.dump(ours, open(out_path, "w"),
              default=lambda o: o.__dict__)
    print(f"merged turbopuffer into commands: {merged_cmds} -> {out_path}")


if __name__ == "__main__":
    main()
