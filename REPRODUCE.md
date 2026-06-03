# Reproducing & publishing the infino benchmark

This fork compares **infino** against **tantivy** and **lucene** (run locally)
plus **turbopuffer** (published numbers merged in), and publishes the dashboard
to <https://infino-ai.github.io/search-benchmark-game>.

## Engines & queries

| | value |
|---|---|
| Engines we run | `infino-0.1`, `tantivy-0.26`, `lucene-10.4.0` |
| turbopuffer | not run — its published column is merged from `data/turbopuffer-2026-05-20.json` |
| Box | AWS **c7i.2xlarge** (matches turbopuffer's published environment) |
| Toolchain | Rust 1.89, Temurin 21.0.8+9 |

Two benchmark modes:
- `make bench` — **turbopuffer comparison.** Query set `queries-tpuf.txt`
  (turbopuffer's exact 31 queries, derived from their snapshot), commands
  `TOP_10 TOP_100 TOP_1000 COUNT` (the ones all three engines support), then
  merges turbopuffer's column into `results.json`.
- `make bench-full` — **standard benchmark.** Query set `queries-full.txt`
  (962 queries incl. phrase/negated), commands incl. `TOP_100_COUNT`.

infino reports `UNSUPPORTED` for phrase, negation, and the `*_FILTER_%`
commands (no positional index, no NOT operator, no FTS+filter path). `COUNT`
is supported but unoptimized (full search + count).

## One-time: prepare the box

```bash
scripts/setup-aws.sh          # installs Rust 1.89, Temurin 21, build deps
source "$HOME/.cargo/env"
export JAVA_HOME="$HOME/jdk-21.0.8+9" && export PATH="$PATH:$JAVA_HOME/bin"
```

## Each run

On the c7i.2xlarge:
```bash
scripts/run-bench.sh          # turbopuffer comparison (default)
# or: scripts/run-bench.sh full
```
This downloads the corpus (first time), compiles + indexes the three engines,
benchmarks, and writes a **merged `results.json`** at the repo root.

## Publish (the easy loop)

1. Copy the `results.json` produced on the box into this repo on your laptop:
   ```bash
   scp ec2-user@<box>:~/search-benchmark-game/results.json ./results.json
   ```
2. Commit & push:
   ```bash
   git add results.json && git commit -m "bench: <date> run" && git push
   ```
3. The **Deploy benchmark site** GitHub Action publishes it automatically.
   New numbers appear at <https://infino-ai.github.io/search-benchmark-game>
   within ~1–2 minutes.

That's it — **bench → copy `results.json` → push → live.** No web build step:
the dashboard (`web/build/`) is prebuilt and committed; the workflow just drops
`results.json` next to it and deploys.

## Refreshing turbopuffer's numbers

If turbopuffer publishes a newer snapshot, update the vendored copy and the
`queries-tpuf.txt` it implies:
```bash
curl -s https://turbopuffer.github.io/search-benchmark-game/<NEW>/results.json \
  -o data/turbopuffer-<NEW>.json
# regenerate queries-tpuf.txt from it, and point TPUF_RESULTS at the new file
```
