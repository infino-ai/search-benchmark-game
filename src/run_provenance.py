#!/usr/bin/env python3
"""What produced a results.json: the corpus, the queries, and when it ran.

A results file on its own says how fast each engine was and nothing about what
was measured. Two pages can differ because the corpus differs or because the
query set differs, and none of that was previously recorded anywhere.

One run, one answer: this is per-run metadata, not per-engine.

Nothing in here is allowed to fail a bench run. A run costs hours; this is a
label on it. Every lookup degrades to an absent field rather than raising, and
the page renders whatever is present.
"""

import json
import os
from datetime import datetime, timezone
from os import path


def _line_count(file_path):
    """Documents in a corpus, or queries in a query set: one per line."""
    try:
        count = 0
        with open(file_path, "rb") as f:
            for _ in f:
                count += 1
        return count
    except OSError:
        return None


def run_provenance(query_path, commands, started_utc):
    """The `run` block written beside details/index_sizes/results."""
    run = {
        "started_utc": started_utc,
        "queries": {"name": path.basename(query_path), "count": _line_count(query_path)},
    }
    if commands:
        run["commands"] = list(commands)

    corpus_path = os.environ.get("CORPUS")
    if corpus_path:
        corpus = {"name": path.basename(corpus_path), "path": corpus_path}
        docs = _line_count(corpus_path)
        if docs is not None:
            corpus["docs"] = docs
        try:
            corpus["bytes"] = os.stat(corpus_path).st_size
        except OSError:
            pass
        run["corpus"] = corpus

    return run


def collect(query_path, commands, started_utc):
    """`run_provenance`, with any failure reduced to an error string.

    The caller is a bench run that has already spent hours; it must finish and
    write its results whatever happens here.
    """
    try:
        return run_provenance(query_path, commands, started_utc)
    except Exception as e:  # noqa: BLE001 - deliberately total
        return {"error": "run metadata collection failed: %s" % e}


def utc_now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


if __name__ == "__main__":
    print(json.dumps(
        collect(os.environ.get("QUERIES", "queries.txt"), None, utc_now()),
        indent=2,
    ))
