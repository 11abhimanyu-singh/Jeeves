#!/bin/bash
# Autonomous Tier 1 trajectory runs: real model, real tools, in-memory store,
# no human.
#
# SAMPLED BY DEFAULT. Six single runs on near-identical code produced
# 25/21/14/11/23/11 tool calls, so one run is a smoke test, not a verdict.
# Each repetition writes its own artifact; the summary reports the
# deterministic invariants as a pass RATE (which must be 100%) and the spread
# of tool calls, which is the honest signal about model variance.
#
# The key comes from, in order: -k <file>, $ANTHROPIC_API_KEY, or the login
# Keychain (`security add-generic-password -s jeeves-anthropic -a jeeves -w`).
# It is passed to the test runner as an environment variable and never printed.
#
# Usage:
#   tools/run-trajectories.sh [-n repeats] [-o outdir] [-k keyfile]
set -euo pipefail

REPEATS=3
OUT="/tmp/jeeves-trajectories"
KEY_FILE=""

while getopts "n:o:k:" opt; do
  case $opt in
    n) REPEATS="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    k) KEY_FILE="$OPTARG" ;;
    *) echo "usage: run-trajectories.sh [-n repeats] [-o outdir] [-k keyfile]" >&2; exit 2 ;;
  esac
done

# Back-compat: the old signature was <key-file> [outdir].
shift $((OPTIND - 1))
if [ -z "$KEY_FILE" ] && [ $# -ge 1 ] && [ -s "${1:-}" ]; then
  KEY_FILE="$1"; shift
  [ $# -ge 1 ] && OUT="$1"
fi

if [ -n "$KEY_FILE" ]; then
  [ -s "$KEY_FILE" ] || { echo "key file missing/empty: $KEY_FILE" >&2; exit 1; }
  KEY="$(cat "$KEY_FILE")"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  KEY="$ANTHROPIC_API_KEY"
elif KEY="$(security find-generic-password -s jeeves-anthropic -w 2>/dev/null)"; then
  : # from the login Keychain
else
  echo "No Anthropic key. Provide one of:" >&2
  echo "  -k <file>, \$ANTHROPIC_API_KEY, or a Keychain entry:" >&2
  echo "  security add-generic-password -s jeeves-anthropic -a jeeves -w" >&2
  exit 1
fi
case "$KEY" in
  sk-ant-*) : ;;
  *) echo "That key is not an Anthropic key (expected sk-ant-…) — refusing to" >&2
     echo "send it to api.anthropic.com." >&2; exit 1 ;;
esac

cd "$(dirname "$0")/.."
mkdir -p "$OUT"

artifacts=()
statuses=()

for i in $(seq 1 "$REPEATS"); do
  echo "── run $i/$REPEATS ──"
  # A stale artifact from an earlier run must never count as this one's.
  start_marker=$(mktemp)
  log=$(mktemp)
  status=0
  TEST_RUNNER_ANTHROPIC_API_KEY="$KEY" \
  TEST_RUNNER_TRAJECTORY_OUT="$OUT" \
  xcodebuild test -project Jeeves.xcodeproj -scheme Jeeves \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:JeevesTests/TrajectoryTests > "$log" 2>&1 || status=$?

  grep -E "TRAJECTORY ARTIFACT|Executed .* tests" "$log" || true

  latest=$(find "$OUT" -name 'tier1-*.json' -newer "$start_marker" 2>/dev/null | sort | tail -1)
  rm -f "$start_marker"
  if [ -z "$latest" ]; then
    echo "  !! no artifact from this run (xcodebuild exit $status). Log: $log" >&2
    statuses+=("$status")
    continue
  fi
  rm -f "$log"
  artifacts+=("$latest")
  statuses+=("$status")
done

if [ ${#artifacts[@]} -eq 0 ]; then
  echo "No artifacts produced by any run — refusing to summarize." >&2
  exit 1
fi

echo
echo "═══ sampled summary over ${#artifacts[@]} run(s) ═══"
python3 - "${artifacts[@]}" <<'EOF'
import json, statistics, sys, collections

paths = sys.argv[1:]
runs = []
for p in paths:
    d = json.load(open(p))
    runs.append({
        "path": p,
        "tools": len(d["toolCalls"]),
        "turns": len(d["transcript"]),
        "failures": d["failures"],
        "trips": len(d["endState"]["trips"]),
        "stays": len(d["endState"]["stays"]),
        "journeys": len(d["endState"]["journeys"]),
    })

clean = [r for r in runs if not r["failures"]]
print(f"deterministic invariants: {len(clean)}/{len(runs)} clean "
      f"({100*len(clean)//len(runs)}%) — must be 100%")

tools = [r["tools"] for r in runs]
print(f"tool calls: min {min(tools)}  median {int(statistics.median(tools))}  max {max(tools)}"
      + (f"  (spread {max(tools)-min(tools)} — model variance, not a code change)"
         if max(tools) != min(tools) else ""))
for key in ("trips", "stays", "journeys"):
    vals = [r[key] for r in runs]
    flag = "" if len(set(vals)) == 1 else "  << varies between runs"
    print(f"{key:>9}: {vals}{flag}")

seen = collections.Counter()
for r in runs:
    for f in r["failures"]:
        seen[f.split(":")[0].strip()] += 1
if seen:
    print("\nfailures by kind (how many runs hit each):")
    for kind, n in seen.most_common():
        print(f"  {n}/{len(runs)}  {kind}")
else:
    print("\nno invariant failures in any run.")

print("\nartifacts:")
for r in runs:
    print(f"  {r['path']}  tools={r['tools']} failures={len(r['failures'])}")
print("\nJudge each with: tools/trajectory-judge.py <artifact>")
EOF

for s in "${statuses[@]}"; do
  [ "$s" -ne 0 ] && { echo; echo "NOTE: at least one run reported test failures — not green." >&2; exit 1; }
done
