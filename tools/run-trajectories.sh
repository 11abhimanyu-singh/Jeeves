#!/bin/bash
# Autonomous Tier 1 trajectory run: real model, real tools, in-memory store,
# no human. The Anthropic key comes from a stash file created by the user
# (read -rs KEY && printf '%s' "$KEY" > <stash>) and is passed only through
# the environment — never stored in the repo or printed.
#
# Usage:
#   tools/run-trajectories.sh /path/to/.anthropic_key [outdir]
set -euo pipefail

KEY_FILE="${1:?usage: run-trajectories.sh <key-file> [outdir]}"
OUT="${2:-/tmp/jeeves-trajectories}"
[ -s "$KEY_FILE" ] || { echo "key file missing/empty: $KEY_FILE" >&2; exit 1; }

cd "$(dirname "$0")/.."
mkdir -p "$OUT"

# A stale artifact from a previous run must never be presented as this run's
# result: only files newer than this marker count.
start_marker=$(mktemp)
log=$(mktemp)

status=0
TEST_RUNNER_ANTHROPIC_API_KEY="$(cat "$KEY_FILE")" \
TEST_RUNNER_TRAJECTORY_OUT="$OUT" \
xcodebuild test -project Jeeves.xcodeproj -scheme Jeeves \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:JeevesTests/TrajectoryTests > "$log" 2>&1 || status=$?

grep -E "TRAJECTORY ARTIFACT|Test Case|TEST|failures:" "$log" || true

latest=$(find "$OUT" -name 'tier1-*.json' -newer "$start_marker" 2>/dev/null | sort | tail -1)
rm -f "$start_marker"

if [ -z "$latest" ]; then
  echo >&2
  echo "NO artifact produced by THIS run (xcodebuild exit $status) — refusing" >&2
  echo "to summarize stale output. Full log: $log" >&2
  exit $((status == 0 ? 1 : status))
fi
rm -f "$log"

echo
echo "=== artifact: $latest ==="
python3 - "$latest" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"turns: {len(d['transcript'])}  tool calls: {len(d['toolCalls'])}  failures: {len(d['failures'])}")
for f in d["failures"]:
    print("  FAIL:", f)
print("end state:")
for k in ("trips", "stays", "journeys", "events"):
    for row in d["endState"][k]:
        print(f"  {k[:-1]}: {row}")
EOF

if [ $status -ne 0 ]; then
  echo
  echo "NOTE: xcodebuild exited $status — the artifact above is from THIS run," >&2
  echo "but the suite reported failures. Do not record this run as green." >&2
  exit $status
fi
