#!/usr/bin/env python3
"""Build one engine's index and record how long the whole build took.

Usage:
    time_index.py <engine>

Runs `make index` in engines/<engine> and writes engines/<engine>/index-time.json:

    {"index_secs": 142.7, "finished_utc": "...", "corpus_bytes": 1234567890}

The number is the wall clock of the complete build, from the first document
read to an index that is ready to serve: ingest plus whatever the engine does
afterwards to reach its benched shape (infino's optimize, Lucene's and
tantivy's force-merge to one segment). That is the time a user waits for, so
it is what the page reports; a per-phase split would say more about one engine
and nothing comparable about the next.

Compilation is deliberately outside the clock. `make compile` runs before
`make index` (scripts/user-data-template.sh), and every engine's `index`
target is written so that an already-built binary is not rebuilt.

`corpus_bytes` identifies the corpus that was indexed, so a timing left behind
by a build of some other corpus is not reported against this one
(src/client.py checks it against $CORPUS).
"""
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from os import path


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    engine = sys.argv[1]
    root = path.dirname(path.dirname(path.abspath(__file__)))
    engine_dir = path.join(root, "engines", engine)
    out_path = path.join(engine_dir, "index-time.json")
    # A failed build leaves no timing: a stale one beside a half-built index
    # would be reported as if it were this run's.
    try:
        os.remove(out_path)
    except FileNotFoundError:
        pass

    started = time.monotonic()
    done = subprocess.run(["make", "--no-print-directory", "index"], cwd=engine_dir)
    secs = time.monotonic() - started
    if done.returncode != 0:
        print("--- %s: index build failed after %.1fs" % (engine, secs), file=sys.stderr)
        sys.exit(done.returncode)

    record = {
        "index_secs": round(secs, 3),
        "finished_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    }
    corpus = os.environ.get("CORPUS")
    if corpus:
        try:
            record["corpus_bytes"] = os.stat(corpus).st_size
        except OSError:
            pass
    with open(out_path, "w") as f:
        json.dump(record, f)
    print("--- %s: index built in %.1fs" % (engine, secs), file=sys.stderr)


if __name__ == "__main__":
    main()
