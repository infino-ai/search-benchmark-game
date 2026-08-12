#!/usr/bin/env python3
"""Build a per-fork `/full`-style dashboard page for a branch bench run.

Usage:
    publish_branch_full.py \
        --main-full   results-full.json \
        --branch-full results-full-branch-<slug>.json \
        --template    web/build/full/index.html \
        --out-dir     web/build/<fork_user>/full \
        --label       "<repo>@<branch>"

A branch/fork run only benches infino-0.1. To make the published page a true
full-benchmark comparison (not a lone column), we splice the branch's infino
column into the committed main baseline — which already carries the competitor
engines and main's own infino — as a new engine `infino-0.1 @<branch>`. The page
then shows the branch side by side with tantivy, lucene, and main's infino.

The page reuses the prebuilt `/full` index.html verbatim (same JS bundle, which
fetches `./results.json` relative to the page URL). We only rewrite the static
asset paths for the extra directory depth and retitle the page so it is
self-identifying.
"""
import argparse
import json
import re
import sys
from pathlib import Path


def branch_engine_key(label: str) -> str:
    """Column label for the branch's infino, e.g. `infino-0.1 @my-branch`."""
    branch = label.split("@", 1)[1] if "@" in label else label
    return f"infino-0.1 @{branch}"


def merge(main_full: dict, branch_full: dict, engine_key: str, label: str) -> dict:
    """Return main_full with the branch's infino column added as `engine_key`."""
    branch_results = branch_full["results"]
    for mode, engines in main_full["results"].items():
        branch_col = branch_results.get(mode, {}).get("infino-0.1")
        if branch_col is None:
            print(f"  warning [{mode}]: branch run has no infino-0.1 column; "
                  f"skipping this mode for the branch", file=sys.stderr)
            continue
        engines[engine_key] = branch_col
    main_full.setdefault("details", {})[engine_key] = [
        f"infino-0.1 built from {label} (this fork's latest branch run)."
    ]
    return main_full


def render_index(template_html: str, label: str) -> str:
    """Adapt the prebuilt /full page for one extra directory level + retitle."""
    # /full sits one level under the site root and references `../static/...`.
    # The fork page sits at `<fork_user>/full`, one level deeper, so bump every
    # relative asset path up an extra directory.
    html = template_html.replace("../static/", "../../static/")
    html = re.sub(
        r"<title>.*?</title>",
        f"<title>Search benchmark — {label}</title>",
        html,
        count=1,
    )
    html = re.sub(
        r"<h1>.*?</h1>",
        f"<h1>Search Benchmark, the Game — {label}</h1>",
        html,
        count=1,
    )
    return html


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--main-full", required=True)
    p.add_argument("--branch-full", required=True)
    p.add_argument("--template", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--label", required=True)
    args = p.parse_args()

    main_full = json.load(open(args.main_full))
    branch_full = json.load(open(args.branch_full))
    engine_key = branch_engine_key(args.label)

    merged = merge(main_full, branch_full, engine_key, args.label)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    json.dump(merged, open(out_dir / "results.json", "w"))
    index_html = render_index(Path(args.template).read_text(), args.label)
    (out_dir / "index.html").write_text(index_html)

    print(f"published {args.label} -> {out_dir}/ (engine column: {engine_key})")


if __name__ == "__main__":
    main()
