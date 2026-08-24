#!/bin/bash
# EC2 bootstrap for an AVX2 (c7i) query PROFILE run. Independent of the nightly
# bench: it signals completion via a distinct S3 key (profile-done.txt) and
# writes its own S3 result keys, so it can run alongside a nightly/same-box
# bench (which uses SSM /sbg-bench/done) without colliding.
#
# Builds do_query for BOTH codecs — the branch (256-doc blocks, path dep
# ../../../infino) and main (128-doc blocks, ../../../infino-main) — builds an
# index with each, then profiles do_query over the real query set in four modes
# (TOP_10 / TOP_100 / TOP_1000 / COUNT) with perf: hardware counters (cycles,
# IPC, L1 + branch misses) via `perf stat` and a flat function profile via
# `perf record`, plus a branch-vs-main comparison summary. Real AVX2 counters —
# the thing a Mac / NEON sampler cannot measure.
exec >> /var/log/sbg-profile.log 2>&1

REGION="us-east-1"
BUCKET="sbg-bench-corpus"
# Completion is signalled via an S3 object rather than SSM: the sbg-ci /
# sbg-bench-instance roles are scoped to /sbg-bench/* in SSM, but both already
# have S3 access to this bucket. The key is unique per run (run id substituted
# by the workflow) so a prior failed run's signal can never be misread as this
# run's — the roles lack s3:DeleteObject, so a fixed key cannot be cleared. This
# also keeps it isolated from the nightly/same-box bench (SSM /sbg-bench/done).
DONE_KEY="s3://$BUCKET/__DONE_OBJ__"
EC2_HOME="/home/ec2-user"

signal_done() {
  aws s3 cp /var/log/sbg-profile.log "s3://$BUCKET/profile-log.txt" \
    --region "$REGION" 2>/dev/null || true
  printf '%s' "$1" > /tmp/profile-done.txt
  aws s3 cp /tmp/profile-done.txt "$DONE_KEY" --region "$REGION" 2>/dev/null || true
}
trap 'echo "=== disk usage at exit ==="; df -h; signal_done error' EXIT

# system deps + perf (AL2023 ships perf in the `perf` package)
dnf install -y git make gcc gcc-c++ cmake clang bzip2 python3 unzip wget perf

# Allow non-root perf profiling of ec2-user's process.
sysctl -w kernel.perf_event_paranoid=-1 || true
sysctl -w kernel.kptr_restrict=0 || true

mkdir -p /run/sbg
printf '%s' '__GH_TOKEN__' > /run/sbg/gh-token
chmod 644 /run/sbg/gh-token

cat > /tmp/profile.sh << 'PROF_EOF'
#!/bin/bash
set -euo pipefail
mkdir -p "$HOME/tmp"; export TMPDIR="$HOME/tmp"

INFINO_BRANCH="__INFINO_BRANCH__"
INFINO_REPO="__INFINO_REPO__"
SBG_BRANCH="__SBG_BRANCH__"

if ! command -v rustup &>/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source "$HOME/.cargo/env"
rustup toolchain install 1.95.0

GH_TOKEN=$(cat /run/sbg/gh-token)

# branch (256) + main (128) checkouts — the two engines path-dep these.
git clone "https://github.com/${INFINO_REPO}.git" "$HOME/infino"
git -C "$HOME/infino" checkout "$INFINO_BRANCH"
git clone "https://github.com/infino-ai/infino.git" "$HOME/infino-main"
git -C "$HOME/infino-main" checkout main
git clone "https://x-access-token:${GH_TOKEN}@github.com/infino-ai/search-benchmark-game.git" \
  "$HOME/search-benchmark-game"
git -C "$HOME/search-benchmark-game" checkout "$SBG_BRANCH"

SBG="$HOME/search-benchmark-game"
cd "$SBG"
aws s3 cp "s3://sbg-bench-corpus/corpus.json" corpus.json

# Match the nightly build flags exactly (production AVX2). No `-g`: the engine
# release profile sets `-C lto -C codegen-units=1` and `-C strip=debuginfo`, so
# `-g` only inflates peak LTO memory (it OOM-kills rustc on the 16 GB c7i) and
# is stripped anyway. perf still symbolicates functions from the retained ELF
# symbol table (plain sampling, no call-graph — LBR/DWARF unavailable here).
export RUSTFLAGS='-C target-cpu=native'
( cd "$SBG/engines/infino-0.1"  && cargo build --release --bin build_index --bin do_query )
( cd "$SBG/engines/infino-main" && cargo build --release --bin build_index --bin do_query )

# Build one index per codec.
"$SBG/engines/infino-0.1/target/release/build_index"  "$SBG/idx256" < corpus.json
"$SBG/engines/infino-main/target/release/build_index" "$SBG/idx128" < corpus.json

# Real query set per command, repeated so each profiled run is long enough that
# preload is a small amortized fraction of the counters (per-mode reps because a
# TOP_1000 query costs ~10x a COUNT). Four modes: TOP_10 / TOP_100 / TOP_1000
# (ranked search at each k) and COUNT (pure posting-list decode, no scoring —
# isolates the decode cost the AVX2 instruction-count delta points at).
python3 - <<'PY'
import json
qs=[json.loads(l)['query'] for l in open('queries-full.txt') if l.strip()]
modes={'TOP_10':('/tmp/top10.txt',150),'TOP_100':('/tmp/top100.txt',60),
       'TOP_1000':('/tmp/top1000.txt',25),'COUNT':('/tmp/count.txt',300)}
for cmd,(path,reps) in modes.items():
    with open(path,'w') as f:
        for _ in range(reps):
            for q in qs: f.write(cmd+'\t'+q+'\n')
PY

profile_one() {  # $1=engine-dir  $2=index  $3=label  $4=query-file
  local dq="$SBG/engines/$1/target/release/do_query" idx="$2" lbl="$3" qf="$4"
  echo "############################################################"
  echo "### PROFILE $lbl  ($dq $idx)"
  echo "############################################################"
  # Sanity: the index must open and produce output. A panic here (e.g. wrong
  # index path) would otherwise leave perf profiling the startup/crash path and
  # silently report garbage — abort loudly instead.
  if [ -z "$("$dq" "$idx" < "$qf" 2>/dev/null | head -1)" ]; then
    echo "ERROR: $dq $idx produced no output (index open failed / panicked)"
    exit 1
  fi
  # Warm the page cache + branch predictors first (untimed); the query set is
  # large (see the generator) so preload is a small, amortized fraction of the
  # counters below — the delta is dominated by per-query work.
  "$dq" "$idx" < "$qf" > /dev/null 2>&1 || true
  echo "===== perf stat ($lbl) ====="
  # LLC-* are <not supported> on the virtualized c7i; drop them. Add branches /
  # branch-misses — the ranked walk is branchy, so a mispredict gap would show.
  perf stat -e cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,branches,branch-misses \
    -- "$dq" "$idx" < "$qf" > /dev/null 2> "/tmp/perfstat_$lbl.txt" || true
  cat "/tmp/perfstat_$lbl.txt"
  echo "===== perf record + report top functions ($lbl) ====="
  # Plain sampling (no call-graph): LBR is unsupported on the virtualized c7i and
  # produced an empty report. Function-level self-time comes from the retained
  # ELF symbol table (the release profile strips debuginfo but keeps symbols).
  perf record -F 1999 -o "/tmp/perf_$lbl.data" \
    -- "$dq" "$idx" < "$qf" > /dev/null 2>&1 || true
  perf report --stdio --no-children --percent-limit 0.3 -i "/tmp/perf_$lbl.data" 2>/dev/null \
    | grep -vE "^#|^\s*$" | head -45 > "/tmp/perfreport_$lbl.txt" || true
  cat "/tmp/perfreport_$lbl.txt"
  aws s3 cp "/tmp/perfstat_$lbl.txt"   "s3://sbg-bench-corpus/profile-perfstat-$lbl.txt"   2>/dev/null || true
  aws s3 cp "/tmp/perfreport_$lbl.txt" "s3://sbg-bench-corpus/profile-perfreport-$lbl.txt" 2>/dev/null || true
}

# main + branch per mode. Instruction / branch / load counts are deterministic
# (same code + data), so one run per engine suffices for those; cycles/IPC carry
# mild thermal noise but the modes run back-to-back on one instance.
for m in top10 top100 top1000 count; do
  profile_one infino-main "$SBG/idx128" "main128_$m" "/tmp/$m.txt"
  profile_one infino-0.1  "$SBG/idx256" "branch256_$m" "/tmp/$m.txt"
done

# Compact branch-vs-main comparison from the perf-stat files, all four modes.
python3 - <<'PY'
import re
def parse(lbl):
    d={}
    try: t=open(f"/tmp/perfstat_{lbl}.txt").read()
    except FileNotFoundError: return d
    for line in t.splitlines():
        m=re.match(r'\s*([\d,]+)\s+([A-Za-z0-9_-]+)\s', line+' ')
        if m: d[m.group(2)]=int(m.group(1).replace(',',''))
        for pat,key in [(r'#\s+([\d.]+)\s+insn per cycle','ipc'),
                        (r'([\d.]+)% of all L1-dcache','l1_miss_pct'),
                        (r'([\d.]+)% of all branches','br_miss_pct')]:
            mm=re.search(pat,line)
            if mm: d[key]=float(mm.group(1))
    return d
rows=["instructions","cycles","ipc","L1-dcache-loads","l1_miss_pct","branches","branch-misses","br_miss_pct"]
print("\n"+"="*66)
print("COMPARISON SUMMARY  (branch=256-block, main=128-block; b/m ratio)")
print("="*66)
for mode in ["top10","top100","top1000","count"]:
    m=parse(f"main128_{mode}"); b=parse(f"branch256_{mode}")
    print(f"\n--- {mode.upper()} ---")
    print(f"  {'metric':<20}{'main(128)':>16}{'branch(256)':>16}{'b/m':>8}")
    for k in rows:
        if k in m and k in b and m[k]:
            print(f"  {k:<20}{m[k]:>16,.0f}{b[k]:>16,.0f}{b[k]/m[k]:>8.3f}")
print("="*66)
PY
PROF_EOF

chmod +x /tmp/profile.sh
if sudo -H -u ec2-user bash /tmp/profile.sh; then
  trap - EXIT
  signal_done ok
else
  exit 1
fi
