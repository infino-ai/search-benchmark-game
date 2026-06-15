#!/usr/bin/env bash
# One-time environment setup for the benchmark box.
#
# Target: AWS c7i.2xlarge, Amazon Linux 2023 (matches turbopuffer's published
# environment: Rust 1.89, Adoptium Temurin 21.0.8+9). Re-running is safe.
set -euo pipefail

echo "--- system packages ---"
sudo dnf install -y git make gcc gcc-c++ cmake clang bzip2 python3 unzip

echo "--- Rust 1.95 ---"
if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
# shellcheck disable=SC1090
source "$HOME/.cargo/env"
rustup toolchain install 1.95.0
rustup default 1.95.0
rustc --version

echo "--- JDK 21.0.8+9 (Temurin, for the lucene engine) ---"
JDK=OpenJDK21U-jdk_x64_linux_hotspot_21.0.8_9.tar.gz
if [ ! -d "$HOME/jdk-21.0.8+9" ]; then
  cd "$HOME"
  wget -q "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.8%2B9/$JDK"
  tar xzf "$JDK"
fi
echo
echo "Add these to your shell (or run before benchmarking):"
echo '  source "$HOME/.cargo/env"'
echo '  export JAVA_HOME="$HOME/jdk-21.0.8+9"'
echo '  export PATH="$PATH:$JAVA_HOME/bin"'
echo
echo "Done. Next: scripts/run-bench.sh"
