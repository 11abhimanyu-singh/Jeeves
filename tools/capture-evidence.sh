#!/bin/bash
#
# capture-evidence.sh — photograph the shipped app, unattended.
#
# WHY THIS EXISTS
#
# Every other GPT eval in this repo grades an artifact Claude wrote. ux-eval.py
# says so in its own docstring: the walkthrough it judges is "reconstructed from
# the shipped code". That can catch things built WRONG; it is structurally
# incapable of catching things left OUT, because a screen that was never built
# produces no artifact and therefore no finding.
#
# This script removes the author from the evidence path. It drives the real app
# on a simulator and captures what is actually on the glass.
#
# WHAT THE PREAMBLE IS FOR — every line is load-bearing:
#   simctl erase    the simulator keychain SURVIVES uninstall, and a leftover
#                   API key would send the planner to the network mid-capture
#   unset *_API_KEY KeychainService also reads these from the environment
#   status_bar      pins the clock/battery/wifi so screenshots diff cleanly
#
# Usage:  tools/capture-evidence.sh [udid]
# Output: evidence/<timestamp>/{steps/,walkthrough.json,evidence.xcresult}

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UDID="${1:-0114B838-4BE0-4C50-8662-AA827C8D43F0}"
OUT="$REPO/evidence/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# The app must not be able to reach a model mid-walk: an offline plan is
# deterministic and instant, a live one is neither.
unset ANTHROPIC_API_KEY OPENAI_API_KEY

echo "==> resetting $UDID"
xcrun simctl shutdown "$UDID" >/dev/null 2>&1
xcrun simctl erase "$UDID" || exit 1
xcrun simctl boot "$UDID" || exit 1
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1

xcrun simctl status_bar "$UDID" override \
  --time "09:41" --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4 --dataNetwork wifi --operatorName "" >/dev/null 2>&1

echo "==> walking the app"
xcodebuild test \
  -project "$REPO/Jeeves.xcodeproj" \
  -scheme JeevesEvidence \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:JeevesUITests/EvidenceWalkthroughTests/testEveryScreenShallow \
  -resultBundlePath "$OUT/evidence.xcresult" \
  -parallel-testing-enabled NO \
  2>&1 | grep -E "Test Case|error:|Executed" | tail -20

# The walk deliberately does not fail on an unreachable screen, so a non-zero
# exit here means the RUN broke, not that a screen was missing.
if [ ! -d "$OUT/evidence.xcresult" ]; then
  echo "No result bundle — the run itself failed." >&2
  exit 1
fi

echo "==> exporting attachments"
xcrun xcresulttool export attachments \
  --path "$OUT/evidence.xcresult" --output-path "$OUT/raw" >/dev/null || exit 1

python3 "$REPO/tools/evidence-collate.py" "$OUT" || exit 1
echo "==> $OUT"
