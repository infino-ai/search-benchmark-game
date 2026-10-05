#!/usr/bin/env python3
"""What produced a results.json: the corpus, the queries, and the code.

A results file on its own says how fast each engine was and nothing about what
was measured. Two pages can differ because the corpus differs, because the
query set differs, or because one column was built from a different commit, and
none of that was previously recorded anywhere.

Two levels, because one does not cover the other:

* **Run level** — corpus, document count, query set, when it ran. One run, one
  answer.
* **Per engine** — which code the column was built from. A single page can
  carry several infino columns built from *different* sources (the published
  crate, the tip of main, a dispatched branch), so a single run-level commit
  would be wrong for all but one of them. Engines whose version is already in
  their column name (lucene-10.5.0, tantivy-0.26) record nothing.

Nothing in here is allowed to fail a bench run. A run costs hours; provenance
is a label on it. Every lookup degrades to an absent field rather than raising,
and the page renders whatever is present.
"""

import json
import os
import re
import subprocess
from datetime import datetime, timezone
from os import path

# `infino = { path = "../../../infino", features = [...] }` — a checkout whose
# git metadata is the provenance.
PATH_DEP = re.compile(r'^\s*infino\s*=\s*\{[^}]*\bpath\s*=\s*"([^"]+)"', re.M)
# `infino = { version = "=0.8.9", ... }` — a published crate, which has no
# checkout and no commit; the version is the whole story.
VERSION_DEP = re.compile(r'^\s*infino\s*=\s*\{[^}]*\bversion\s*=\s*"=?([^"]+)"', re.M)
# Both SSH (git@host:owner/repo.git) and HTTPS (https://host/owner/repo.git).
REMOTE = re.compile(r'[:/]([^/:]+)/([^/]+?)(?:\.git)?$')


def _git(repo_dir, *args):
    """A git command's stdout, or None if git or the repo is not usable."""
    try:
        out = subprocess.run(
            ["git", "-C", repo_dir, *args],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip() or None


def _repo_from_remote(url):
    """`owner/repo` from a remote URL, or None if it does not look like one."""
    if not url:
        return None
    m = REMOTE.search(url.strip())
    return "%s/%s" % (m.group(1), m.group(2)) if m else None


def checkout_provenance(repo_dir):
    """Repo, branch, commit and commit date for a checkout the engine builds from."""
    sha = _git(repo_dir, "rev-parse", "HEAD")
    if sha is None:
        return None
    prov = {"commit": sha}
    repo = _repo_from_remote(_git(repo_dir, "remote", "get-url", "origin"))
    if repo:
        prov["repo"] = repo
    # Detached HEAD reports "HEAD", which names nothing; the workflow's own
    # branch input is the better answer there.
    branch = _git(repo_dir, "rev-parse", "--abbrev-ref", "HEAD")
    if branch == "HEAD":
        branch = os.environ.get("INFINO_BRANCH") or None
    if branch:
        prov["branch"] = branch
    date = _git(repo_dir, "log", "-1", "--format=%cI")
    if date:
        prov["commit_date"] = date
    return prov


def engine_provenance(engines_dir, engine):
    """How this engine's infino was obtained, or None if it does not use one.

    Read from the engine's own Cargo.toml rather than passed in, so an engine
    added later is covered without touching this file.
    """
    manifest = path.join(engines_dir, engine, "Cargo.toml")
    try:
        with open(manifest, "r") as f:
            text = f.read()
    except OSError:
        return None

    path_dep = PATH_DEP.search(text)
    if path_dep:
        repo_dir = path.normpath(path.join(engines_dir, engine, path_dep.group(1)))
        prov = checkout_provenance(repo_dir)
        if prov:
            prov["source"] = "checkout"
            return prov
        # The checkout is gone (cleaned up after the build, say). Say so
        # rather than claim the column has no provenance at all.
        return {"source": "checkout", "unavailable": True}

    version_dep = VERSION_DEP.search(text)
    if version_dep:
        return {"source": "crate", "version": version_dep.group(1)}

    return None


def _line_count(file_path):
    """Documents in a corpus: one JSON document per line."""
    try:
        count = 0
        with open(file_path, "rb") as f:
            for _ in f:
                count += 1
        return count
    except OSError:
        return None


def run_provenance(engines, engines_dir, query_path, commands, started_utc):
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

    engine_prov = {}
    for engine in engines:
        prov = engine_provenance(engines_dir, engine)
        if prov:
            engine_prov[engine] = prov
    if engine_prov:
        run["engines"] = engine_prov

    return run


def collect(engines, engines_dir, query_path, commands, started_utc):
    """`run_provenance`, with any failure reduced to an empty block.

    The caller is a bench run that has already spent hours; it must finish and
    write its results whatever happens here.
    """
    try:
        return run_provenance(engines, engines_dir, query_path, commands, started_utc)
    except Exception as e:  # noqa: BLE001 - deliberately total
        return {"error": "provenance collection failed: %s" % e}


def utc_now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


if __name__ == "__main__":
    import sys

    here = path.dirname(path.dirname(path.abspath(__file__)))  # repo root
    engines = sys.argv[1:] or sorted(os.listdir(path.join(here, "engines")))
    print(json.dumps(
        collect(engines, path.join(here, "engines"),
                os.environ.get("QUERIES", "queries.txt"), None, utc_now()),
        indent=2,
    ))
