#!/usr/bin/env python3
"""
Jeeves anomaly digest: render the phone's mirrored anomaly scan as a readable
daily summary.

The app scans at every launch (behavioral rules over the AppEvent stream,
structural rules over all history) and mirrors the result to iCloud Drive —
no cable needed. This renders that file for the daily digest (terminal, or
--markdown for the mail body).

Usage:
    python3 tools/anomaly-digest.py [--markdown out.md] [path-to-json]
Default path:
    ~/Library/Mobile Documents/iCloud~abhimanyusingh~me~Jeeves/Documents/jeeves-anomalies.json
"""
import json
import sys
from pathlib import Path

DEFAULT = (Path.home() / "Library/Mobile Documents/iCloud~abhimanyusingh~me~Jeeves"
           / "Documents/jeeves-anomalies.json")
ORDER = {"high": 0, "medium": 1, "low": 2}
MARK = {"high": "🔴", "medium": "🟡", "low": "⚪️"}


def main() -> None:
    args = sys.argv[1:]
    md_out = None
    if "--markdown" in args:
        i = args.index("--markdown")
        md_out = Path(args[i + 1])
        args = args[:i] + args[i + 2:]
    path = Path(args[0]) if args else DEFAULT
    if not path.exists():
        sys.exit(f"No anomaly file at {path} — has the app launched since the "
                 "anomaly scan shipped, and is iCloud Drive synced?")

    d = json.loads(path.read_text())
    anomalies = d.get("anomalies", [])
    lines = [f"# Jeeves anomaly digest",
             f"Exported {d.get('exportedAt', '?')} · {len(anomalies)} anomaly(ies) · "
             f"{d.get('eventCount', 0)} events in the log", ""]

    if not anomalies:
        lines.append("Clean — no anomalies in the whole store.")
    else:
        by_day = {}
        for a in anomalies:
            by_day.setdefault(a.get("day", "?"), []).append(a)
        for day in sorted(by_day, reverse=True):
            lines.append(f"## {day}")
            for a in sorted(by_day[day], key=lambda x: ORDER.get(x.get("severity"), 3)):
                lines.append(f"- {MARK.get(a.get('severity'), '')} **{a.get('title', '')}** "
                             f"`{a.get('rule', '')}`")
                lines.append(f"  {a.get('detail', '')}")
            lines.append("")

    text = "\n".join(lines)
    print(text)
    if md_out:
        md_out.write_text(text)
        print(f"\n→ {md_out}")
    sys.exit(0 if not anomalies else 1)


if __name__ == "__main__":
    main()
