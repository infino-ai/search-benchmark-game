#!/bin/bash
# Bootstrap for a LONG-LIVED, SSH-debuggable AVX2 (c7i) profiling box. Unlike
# the ephemeral x86-profile run, this instance is NOT terminated: it builds
# do_query for both codecs and one index per codec ONCE, then stays up so
# profiling can be re-run against the persisted indexes without rebuilding.
#
# SSH access (no AWS creds needed for the operator): the launcher workflow
# injects an ed25519 public key here and opens port 22. Log in as ec2-user and
# watch /var/log/setup.log; once "SETUP DONE" appears, both indexes and both
# do_query binaries are ready under /home/ec2-user/search-benchmark-game.
exec >> /var/log/box-bootstrap.log 2>&1
set -x

EC2_HOME="/home/ec2-user"

# 1) SSH key for the operator + allow non-root perf.
mkdir -p "$EC2_HOME/.ssh"
printf '%s\n' '__SSH_PUBKEY__' >> "$EC2_HOME/.ssh/authorized_keys"
chmod 700 "$EC2_HOME/.ssh"; chmod 600 "$EC2_HOME/.ssh/authorized_keys"
chown -R ec2-user:ec2-user "$EC2_HOME/.ssh"
sysctl -w kernel.perf_event_paranoid=-1 || true
sysctl -w kernel.kptr_restrict=0 || true

# 2) System deps + perf.
dnf install -y git make gcc gcc-c++ cmake clang bzip2 python3 unzip wget perf tmux

printf '%s' '__GH_TOKEN__' > /run/gh-token; chmod 644 /run/gh-token

# 3) Build engines + indexes in the background as ec2-user, logging to a file
#    the operator can tail over SSH. The box is reachable as soon as sshd is up.
cat > /tmp/setup.sh <<'SETUP_EOF'
#!/bin/bash
set -euxo pipefail
exec >> /var/log/setup.log 2>&1
mkdir -p "$HOME/tmp"; export TMPDIR="$HOME/tmp"
INFINO_BRANCH="__INFINO_BRANCH__"; INFINO_REPO="__INFINO_REPO__"; SBG_BRANCH="__SBG_BRANCH__"

if ! command -v rustup &>/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source "$HOME/.cargo/env"
rustup toolchain install 1.95.0

GH_TOKEN=$(cat /run/gh-token)
git clone "https://github.com/${INFINO_REPO}.git" "$HOME/infino"
git -C "$HOME/infino" checkout "$INFINO_BRANCH"
git clone "https://github.com/infino-ai/infino.git" "$HOME/infino-main"
git -C "$HOME/infino-main" checkout main
git clone "https://x-access-token:${GH_TOKEN}@github.com/infino-ai/search-benchmark-game.git" \
  "$HOME/search-benchmark-game"
git -C "$HOME/search-benchmark-game" checkout "$SBG_BRANCH"

SBG="$HOME/search-benchmark-game"; cd "$SBG"
aws s3 cp "s3://sbg-bench-corpus/corpus.json" corpus.json

export RUSTFLAGS='-C target-cpu=native'
( cd "$SBG/engines/infino-0.1"  && cargo build --release --bin build_index --bin do_query )
( cd "$SBG/engines/infino-main" && cargo build --release --bin build_index --bin do_query )
"$SBG/engines/infino-0.1/target/release/build_index"  "$SBG/idx256" < corpus.json
"$SBG/engines/infino-main/target/release/build_index" "$SBG/idx128" < corpus.json

# Query sets per mode, for perf runs.
python3 - <<'PY'
import json
qs=[json.loads(l)['query'] for l in open('queries-full.txt') if l.strip()]
modes={'TOP_10':('top10.txt',30),'TOP_100':('top100.txt',12),
       'TOP_1000':('top1000.txt',4),'COUNT':('count.txt',60)}
for cmd,(path,reps) in modes.items():
    with open('/home/ec2-user/'+path,'w') as f:
        for _ in range(reps):
            for q in qs: f.write(cmd+'\t'+q+'\n')
PY
echo "SETUP DONE"
SETUP_EOF
chmod +x /tmp/setup.sh
chown ec2-user:ec2-user /tmp/setup.sh
sudo -H -u ec2-user bash -c 'nohup /tmp/setup.sh >/dev/null 2>&1 &'
echo "BOOTSTRAP DONE — setup building in background; tail /var/log/setup.log"
