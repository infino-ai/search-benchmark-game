#!/usr/bin/env python3
"""Fetch the latest turbopuffer results snapshot from their gh-pages branch.

Writes to data/turbopuffer-latest.json and prints the timestamp fetched.
Falls back to the most recent data/turbopuffer-*.json already in the repo
if the fetch fails (network down, rate-limited, etc.).
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO_API = "https://api.github.com/repos/turbopuffer/search-benchmark-game/contents/build?ref=gh-pages"
RAW_BASE = "https://raw.githubusercontent.com/turbopuffer/search-benchmark-game/gh-pages/build"
OUT = Path(__file__).parent.parent / "data" / "turbopuffer-latest.json"
TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}$")


def fetch_latest():
    req = urllib.request.Request(REPO_API, headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        items = json.load(r)

    dirs = [i["name"] for i in items if i["type"] == "dir" and TIMESTAMP_RE.match(i["name"])]
    if not dirs:
        raise RuntimeError("no timestamp dirs found in turbopuffer gh-pages build/")

    latest = max(dirs)
    url = f"{RAW_BASE}/{latest}/results.json"
    print(f"fetching turbopuffer snapshot: {latest}", flush=True)

    with urllib.request.urlopen(url, timeout=30) as r:
        data = r.read()

    OUT.write_bytes(data)
    print(f"saved → {OUT}", flush=True)
    return latest


def fallback():
    data_dir = Path(__file__).parent.parent / "data"
    snapshots = sorted(data_dir.glob("turbopuffer-*.json"))
    # exclude turbopuffer-latest.json itself
    snapshots = [p for p in snapshots if p.name != "turbopuffer-latest.json"]
    if not snapshots:
        raise RuntimeError("no fallback turbopuffer snapshot found in data/")
    best = snapshots[-1]
    print(f"fallback: using {best.name}", file=sys.stderr, flush=True)
    OUT.write_bytes(best.read_bytes())


if __name__ == "__main__":
    try:
        fetch_latest()
    except Exception as e:
        print(f"fetch failed ({e}), trying fallback", file=sys.stderr, flush=True)
        fallback()
