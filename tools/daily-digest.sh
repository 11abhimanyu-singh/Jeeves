#!/bin/bash
#
# daily-digest.sh — the mechanical half of the daily Jeeves health routine.
#
# WHY THIS EXISTS
#
# The scheduled routine fires at 08:36 with nobody at the keyboard. Every shell
# command it improvises — an `ls` here, a `date` there — hits the permission
# prompt and the run does not fail, it HANGS. A literal allowlist can never
# catch up, because the improvised commands differ slightly every morning.
#
# So the mechanics live here instead: one command, one allowlist rule, no
# improvisation. Everything the routine needs to know is printed to stdout, so
# the agent never has to read a file either.
#
# Composing the digest prose stays with the agent — that is the part that
# actually needs judgement.
#
# EXIT CODES (passed through from icloud-diagnose.py, deliberately)
#   0  clean
#   1  findings
#   2  export channel stale/missing — a DIFFERENT report, never a clean bill
#
# Anything this script does to the filesystem is confined to /tmp and the
# iCloud Documents folder. It never touches the repo and never writes to the
# phone's exported data files.

set -uo pipefail

TOOLS="/Users/abhimanyusingh/Downloads/My projects/Jeeves/tools"
DIGEST="/tmp/jeeves-digest.md"
PREV="/tmp/jeeves-digest-prev.md"
ICLOUD="$HOME/Library/Mobile Documents/iCloud~abhimanyusingh~me~Jeeves/Documents"

# Yesterday's digest is rotated BEFORE the new one is written, so the
# comparison the routine makes is against a file that can't be half-overwritten
# if the run dies partway.
if [ -f "$DIGEST" ]; then
  cp -f "$DIGEST" "$PREV" 2>/dev/null || true
fi

echo "=== RUN CONTEXT ==="
date "+%A %Y-%m-%d %H:%M %Z"
if [ "$(date +%u)" = "7" ]; then
  echo "weekday: Sunday — weekly cross-check is in scope"
else
  echo "weekday: not Sunday — skip the weekly cross-check"
fi

if [ -f "$PREV" ]; then
  echo "previous digest: present ($(date -r "$PREV" "+%Y-%m-%d %H:%M"))"
else
  echo "previous digest: none — first run, nothing to compare against"
fi

echo
echo "=== DIAGNOSIS ==="
python3 "$TOOLS/icloud-diagnose.py" --markdown "$DIGEST"
STATUS=$?

echo
echo "=== EXIT STATUS: $STATUS ==="
case "$STATUS" in
  0) echo "meaning: clean" ;;
  1) echo "meaning: findings present" ;;
  2) echo "meaning: EXPORT CHANNEL STALE OR MISSING — app health was NOT checked" ;;
  *) echo "meaning: unexpected exit $STATUS — treat as a failed run, not a clean one" ;;
esac

# The markdown is echoed rather than left for the agent to open: one fewer
# permission surface, and the routine can't drift onto a stale file.
if [ -f "$DIGEST" ]; then
  echo
  echo "=== DIGEST MARKDOWN ($DIGEST) ==="
  cat "$DIGEST"
fi

if [ -f "$PREV" ]; then
  echo
  echo "=== PREVIOUS DIGEST (for comparison) ==="
  cat "$PREV"
fi

# Sunday's cable cross-check lives here rather than as a second command the
# routine has to decide to run: a conditional second command is a conditional
# second permission prompt, i.e. a hang that only happens on Sundays and is
# therefore the last one anyone would find.
#
# The phone usually isn't cabled. That is expected, not an error — it must not
# change the exit code, which belongs to the health verdict alone.
if [ "$(date +%u)" = "7" ]; then
  echo
  echo "=== WEEKLY CROSS-CHECK + SCENARIOS (Sunday) ==="
  # --tier1 3 plays every permanent scenario against the real model three
  # times and judges each artifact. It is here, not in the daily run, for one
  # reason: the scenarios test the CODE, which changes on ship days, not on
  # days the user simply used the app — so a daily sweep would spend real
  # money re-answering a question nothing had changed. Sampling three times
  # matters more than sampling often: single runs of a probabilistic system
  # are noise (six runs once gave 25/21/14/11/23/11 tool calls).
  #
  # It does NOT need the phone: the scenarios build their own store in
  # memory, so an uncabled Sunday still exercises them.
  if python3 "$TOOLS/diagnose.py" /tmp/jeeves-weekly --pull --tier1 3 2>&1; then
    echo "cross-check: completed — compare its audit against the iCloud-based one above"
  else
    echo "cross-check: findings or partial (exit $?) — read the TIER 1 and SUMMARY sections above;"
    echo "             a failed PULL alone is expected when the phone isn't cabled"
  fi
fi

# Mirror to the phone's Files-app folder, but only into a container that
# already exists — creating the ubiquity container from the Mac side would
# make a folder iCloud never syncs.
echo
echo "=== DELIVERY ==="
if [ -d "$ICLOUD" ]; then
  if cp -f "$DIGEST" "$ICLOUD/daily-digest.md" 2>/dev/null; then
    echo "iCloud copy: written to $ICLOUD/daily-digest.md"
  else
    echo "iCloud copy: FAILED to write (container present but not writable)"
  fi
else
  echo "iCloud copy: skipped — container folder does not exist on this Mac"
fi

exit "$STATUS"
