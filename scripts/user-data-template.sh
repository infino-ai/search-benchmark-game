#!/bin/bash
# EC2 bootstrap for nightly CI bench.
# __GH_TOKEN__ is substituted by the GitHub Actions workflow at launch time.
exec >> /var/log/sbg-bench.log 2>&1

REGION="us-east-1"
BUCKET="sbg-bench-corpus"
DONE_PARAM="/sbg-bench/done"
EC2_HOME="/home/ec2-user"

signal_done() {
  # upload log to S3 first so failures are always inspectable
  aws s3 cp /var/log/sbg-bench.log "s3://$BUCKET/bench-log.txt" \
    --region "$REGION" 2>/dev/null || true
  aws ssm put-parameter \
    --name "$DONE_PARAM" \
    --value "$1" \
    --type String \
    --overwrite \
    --region "$REGION" 2>/dev/null || true
}

trap 'signal_done error' EXIT

# system deps (gradle needs unzip; bzip2 for corpus fallback)
dnf install -y git make gcc gcc-c++ cmake clang bzip2 python3 unzip wget

# write the GitHub token to tmpfs so bench.sh can read it for git clone
mkdir -p /run/sbg
printf '%s' '__GH_TOKEN__' > /run/sbg/gh-token
chmod 644 /run/sbg/gh-token   # ec2-user needs to read this

# write per-user bench script
cat > /tmp/bench.sh << 'BENCH_EOF'
#!/bin/bash
set -euo pipefail

# Rust toolchain (infino + tantivy engines both need it; rust-toolchain.toml
# in infino/ pins the exact version, rustup resolves it automatically)
if ! command -v rustup &>/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source "$HOME/.cargo/env"
# pre-install the pinned version so the first cargo build doesn't stall
rustup toolchain install 1.95.0

# JDK 21 (lucene engine)
if [ ! -d "$HOME/jdk-21.0.8+9" ]; then
  wget -q \
    "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.8%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.8_9.tar.gz" \
    -O /tmp/jdk.tar.gz
  tar xzf /tmp/jdk.tar.gz -C "$HOME" && rm /tmp/jdk.tar.gz
fi
export JAVA_HOME="$HOME/jdk-21.0.8+9"
export PATH="$PATH:$JAVA_HOME/bin"

GH_TOKEN=$(cat /run/sbg/gh-token)

# infino source is a path dep for engines/infino-0.1 (../../../infino)
git clone "https://x-access-token:${GH_TOKEN}@github.com/infino-ai/infino.git" \
  "$HOME/infino"
git clone "https://x-access-token:${GH_TOKEN}@github.com/infino-ai/search-benchmark-game.git" \
  "$HOME/search-benchmark-game"

cd "$HOME/search-benchmark-game"

# corpus from S3
aws s3 cp "s3://sbg-bench-corpus/corpus.json" corpus.json

# compile + index once, then run both bench modes without re-indexing.
# bench-full runs first: it writes results.json then renames it to results-full.json.
# bench runs second: writes a fresh results.json (turbopuffer comparison).
# Both files exist for the S3 upload.
make compile
make index
make bench-full   # full 962-query standard → results-full.json
make bench        # turbopuffer comparison → results.json

# upload both results for the workflow to fetch
aws s3 cp results.json      "s3://sbg-bench-corpus/results.json"
aws s3 cp results-full.json "s3://sbg-bench-corpus/results-full.json"
BENCH_EOF

chmod +x /tmp/bench.sh

# -H sets HOME to ec2-user's home (/home/ec2-user) so rustup, cargo, git
# all install and resolve paths under the correct home directory
if sudo -H -u ec2-user bash /tmp/bench.sh; then
  trap - EXIT
  signal_done ok
else
  exit 1   # EXIT trap fires → signal_done error + log upload
fi
