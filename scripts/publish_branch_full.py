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


def is_same_box(branch_full: dict) -> bool:
    """True when the branch run re-benched the baseline engines alongside the
    branch on one instance (the default same-box A/B). Its own results then
    carry `infino-main` / `lucene` / `tantivy` columns from the *same* run, so
    they are the variance-free comparison and must be used directly — splicing
    the branch column into the committed baseline instead would compare it
    against a different nightly on a different box (cross-run variance that
    reads as a spurious regression on unchanged query classes)."""
    for engines in branch_full.get("results", {}).values():
        if any(k != "infino-0.1" for k in engines):
            return True
    return False


def relabel_same_box(branch_full: dict, engine_key: str, label: str) -> dict:
    """Same-box path: publish the branch run's own multi-engine results, with
    its `infino-0.1` column (the branch build) relabeled `engine_key` so it is
    self-identifying next to the same-run `infino-main` / lucene / tantivy."""
    for engines in branch_full["results"].values():
        if "infino-0.1" in engines:
            engines[engine_key] = engines.pop("infino-0.1")
    details = branch_full.setdefault("details", {})
    details.pop("infino-0.1", None)
    details[engine_key] = [
        f"infino-0.1 built from {label} (this fork's latest branch run), benched "
        f"on the same instance as the infino-main / lucene / tantivy columns "
        f"here — so branch-vs-main is variance-free."
    ]
    return branch_full


def merge(main_full: dict, branch_full: dict, engine_key: str, label: str) -> dict:
    """Return main_full with the branch's infino column added as `engine_key`.

    Fallback for a branch-only run (same-box A/B off): the run produced no
    same-instance baseline, so the branch column is compared against the
    committed baseline. This is a *cross-run* comparison — unchanged query
    classes can drift by the box-to-box delta between the two nightlies."""
    branch_results = branch_full["results"]
    for mode, engines in main_full["results"].items():
        branch_col = branch_results.get(mode, {}).get("infino-0.1")
        if branch_col is None:
            print(f"  warning [{mode}]: branch run has no infino-0.1 column; "
                  f"skipping this mode for the branch", file=sys.stderr)
            continue
        engines[engine_key] = branch_col
    main_full.setdefault("details", {})[engine_key] = [
        f"infino-0.1 built from {label} (this fork's latest branch run; compared "
        f"against the committed baseline — cross-run, not same-box)."
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

    branch_full = json.load(open(args.branch_full))
    engine_key = branch_engine_key(args.label)

    if is_same_box(branch_full):
        # The branch run re-benched all engines on one instance: use its own
        # results so the page is a true same-box comparison.
        merged = relabel_same_box(branch_full, engine_key, args.label)
    else:
        # Branch-only run: splice the lone infino column into the committed
        # baseline (cross-run — see merge()'s docstring).
        main_full = json.load(open(args.main_full))
        merged = merge(main_full, branch_full, engine_key, args.label)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    json.dump(merged, open(out_dir / "results.json", "w"))
    index_html = render_index(Path(args.template).read_text(), args.label)
    (out_dir / "index.html").write_text(index_html)

    print(f"published {args.label} -> {out_dir}/ (engine column: {engine_key})")


if __name__ == "__main__":
    main()
