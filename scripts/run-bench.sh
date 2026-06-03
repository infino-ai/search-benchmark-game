#!/usr/bin/env bash
# Reproducible benchmark run on the c7i.2xlarge box.
#
# Produces a merged results.json at the repo root (infino + tantivy + lucene
# on turbopuffer's query set, with turbopuffer's published column merged in).
# Copy that results.json into the repo on your laptop, commit + push, and the
# Pages workflow publishes it.
#
# Usage:
#   scripts/run-bench.sh           # turbopuffer comparison (default)
#   scripts/run-bench.sh full      # full 962-query standard benchmark
set -euo pipefail
cd "$(dirname "$0")/.."

# Toolchains (no-ops if your shell already has them).
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
[ -d "$HOME/jdk-21.0.8+9" ] && export JAVA_HOME="$HOME/jdk-21.0.8+9" && export PATH="$PATH:$JAVA_HOME/bin"

MODE="${1:-tpuf}"
BENCH_TARGET="bench"
[ "$MODE" = "full" ] && BENCH_TARGET="bench-full"

echo "=== rustc: $(rustc --version 2>/dev/null) | java: $(java -version 2>&1 | head -1) ==="

if [ ! -s corpus.json ]; then
  echo "--- corpus.json missing; downloading (one-time, ~8 GB) ---"
  make corpus
fi

echo "--- compile ---"; make compile
echo "--- index ---";   make index
echo "--- bench ($BENCH_TARGET) ---"; make "$BENCH_TARGET"

echo
echo "Done. Result: $(pwd)/results.json"
echo "Next: copy results.json into the repo on your laptop, commit + push."
